#!/usr/bin/env python3
"""Convert Silero VAD v6.x 16kHz to CoreML.

Source of truth: official silero_vad_16k.safetensors + the tinygrad architecture
published in snakers4/silero-vad. The dual-rate ONNX is kept as the numerical
oracle — this script validates the PyTorch reconstruction and the CoreML artifact
against it before saving.

Output: build/SileroVAD.mlpackage
  inputs:  input [1,576] f32 (64-sample context + 512-sample frame), state [2,1,128] f32
  outputs: output [1,1] f32 speech probability, stateN [2,1,128] f32
"""
from __future__ import annotations

import json
import struct
import sys
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SAFETENSORS = ROOT / "silero_vad_16k.safetensors"
ONNX_ORACLE = ROOT / "silero_vad.onnx"


def load_safetensors_f32(path: Path) -> dict[str, np.ndarray]:
    """Minimal safetensors reader for the flat fp32 Silero checkpoint.

    Avoids a conversion-only dependency; the file format is an 8-byte little-endian
    JSON header length, a JSON header, then raw tensor bytes.
    """
    raw = path.read_bytes()
    header_len = struct.unpack("<Q", raw[:8])[0]
    header = json.loads(raw[8 : 8 + header_len])
    data = raw[8 + header_len :]
    out: dict[str, np.ndarray] = {}
    for name, meta in header.items():
        if name == "__metadata__":
            continue
        if meta["dtype"] != "F32":
            raise ValueError(f"{name}: expected F32, got {meta['dtype']}")
        begin, end = meta["data_offsets"]
        count = int(np.prod(meta["shape"]))
        arr = np.frombuffer(data[begin:end], dtype=np.float32, count=count)
        out[name] = arr.reshape(meta["shape"]).copy()
    return out


class SileroVAD16K(nn.Module):
    """PyTorch reconstruction of the official 16kHz Silero VAD.

    Mirrors src/silero_vad/tinygrad_model.py and the ONNX 16k branch exactly:
    reflect right-pad 64, STFT-as-conv magnitude, 4 conv encoder layers,
    one manually gated LSTMCell step, conv head, sigmoid probability.
    """

    def __init__(self, state_dict: dict[str, np.ndarray]):
        super().__init__()
        self.pad = 64
        self.cutoff = 129

        self.stft_conv = nn.Conv1d(1, 258, kernel_size=256, stride=128, bias=False)
        self.conv1 = nn.Conv1d(129, 128, kernel_size=3, padding=1)
        self.conv2 = nn.Conv1d(128, 64, kernel_size=3, stride=2, padding=1)
        self.conv3 = nn.Conv1d(64, 64, kernel_size=3, stride=2, padding=1)
        self.conv4 = nn.Conv1d(64, 128, kernel_size=3, padding=1)
        self.final_conv = nn.Conv1d(128, 1, kernel_size=1)

        with torch.no_grad():
            self.stft_conv.weight.copy_(torch.from_numpy(state_dict["stft_conv.weight"]))
            for key, module in [
                ("conv1", self.conv1),
                ("conv2", self.conv2),
                ("conv3", self.conv3),
                ("conv4", self.conv4),
                ("final_conv", self.final_conv),
            ]:
                module.weight.copy_(torch.from_numpy(state_dict[f"{key}.weight"]))
                module.bias.copy_(torch.from_numpy(state_dict[f"{key}.bias"]))

        # Stored as buffers so tracing treats them as constants, and so the manual
        # gate math below is visible to coremltools as plain linear algebra.
        self.register_buffer("weight_ih", torch.from_numpy(state_dict["lstm_cell.weight_ih"]))
        self.register_buffer("weight_hh", torch.from_numpy(state_dict["lstm_cell.weight_hh"]))
        self.register_buffer("bias_ih", torch.from_numpy(state_dict["lstm_cell.bias_ih"]))
        self.register_buffer("bias_hh", torch.from_numpy(state_dict["lstm_cell.bias_hh"]))

    def forward(self, x: torch.Tensor, state: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        # x: [batch,576] = 64 context samples + one 512-sample frame.
        # state: [2,batch,128] = (h,c).
        x = F.pad(x, (0, self.pad), mode="reflect").unsqueeze(1)
        x = self.stft_conv(x)
        x = torch.sqrt(x[:, : self.cutoff, :] ** 2 + x[:, self.cutoff :, :] ** 2)
        x = F.relu(self.conv1(x))
        x = F.relu(self.conv2(x))
        x = F.relu(self.conv3(x))
        x = F.relu(self.conv4(x))
        x = x.squeeze(-1)  # [batch,128]

        h_prev = state[0]
        c_prev = state[1]
        gates = (x @ self.weight_ih.t() + self.bias_ih) + (h_prev @ self.weight_hh.t() + self.bias_hh)
        i, f, g, o = torch.chunk(gates, 4, dim=1)
        i = torch.sigmoid(i)
        f = torch.sigmoid(f)
        g = torch.tanh(g)
        o = torch.sigmoid(o)
        c = f * c_prev + i * g
        h = o * torch.tanh(c)
        state_n = torch.stack((h, c), dim=0)

        y = torch.sigmoid(self.final_conv(F.relu(h.unsqueeze(-1))))
        y = y.squeeze(1).mean(dim=1).unsqueeze(1)  # [batch,1]
        return y, state_n


def validate_torch_against_onnx(model: SileroVAD16K) -> None:
    import onnxruntime as ort

    session = ort.InferenceSession(str(ONNX_ORACLE), providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(42)
    worst_prob = 0.0
    worst_state = 0.0

    # Random-state single-frame checks at whisper/normal/loud scales.
    for scale in (0.001, 0.05, 0.5):
        x = rng.normal(0, scale, (1, 576)).astype(np.float32)
        state = rng.normal(0, 0.1, (2, 1, 128)).astype(np.float32)
        with torch.inference_mode():
            yt, st = model(torch.from_numpy(x), torch.from_numpy(state))
        yo, so = session.run(None, {
            "input": x,
            "state": state,
            "sr": np.array(16000, dtype=np.int64),
        })
        worst_prob = max(worst_prob, float(np.max(np.abs(yo - yt.numpy()))))
        worst_state = max(worst_state, float(np.max(np.abs(so - st.numpy()))))

    # Streaming zero-state check: state threading must remain numerically close
    # after repeated recurrence, not just on a single step.
    state_np = np.zeros((2, 1, 128), dtype=np.float32)
    state_t = torch.zeros((2, 1, 128), dtype=torch.float32)
    for _ in range(8):
        x = rng.normal(0, 0.05, (1, 576)).astype(np.float32)
        with torch.inference_mode():
            yt, state_t = model(torch.from_numpy(x), state_t)
        yo, state_np = session.run(None, {
            "input": x,
            "state": state_np,
            "sr": np.array(16000, dtype=np.int64),
        })
        worst_prob = max(worst_prob, float(np.max(np.abs(yo - yt.numpy()))))
        worst_state = max(worst_state, float(np.max(np.abs(state_np - state_t.numpy()))))

    print(f"torch vs onnx oracle: max prob diff {worst_prob:.3g}, max state diff {worst_state:.3g}")
    if worst_prob > 1e-5 or worst_state > 1e-4:
        raise RuntimeError("PyTorch reconstruction diverges from ONNX oracle")


def convert() -> None:
    if not SAFETENSORS.exists():
        raise FileNotFoundError(f"missing {SAFETENSORS}")
    if not ONNX_ORACLE.exists():
        raise FileNotFoundError(f"missing ONNX oracle {ONNX_ORACLE}")

    print("loading silero safetensors…")
    model = SileroVAD16K(load_safetensors_f32(SAFETENSORS)).eval()
    validate_torch_against_onnx(model)

    print("tracing fixed-shape streaming step…")
    example_x = torch.zeros(1, 576)
    example_state = torch.zeros(2, 1, 128)
    with torch.inference_mode():
        traced = torch.jit.trace(model, (example_x, example_state), strict=False)
    traced.eval()

    print("converting to CoreML mlprogram fp32…")
    t0 = time.time()
    ml = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="input", shape=(1, 576), dtype=np.float32),
            ct.TensorType(name="state_in", shape=(2, 1, 128), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="output", dtype=np.float32),
            ct.TensorType(name="stateN", dtype=np.float32),
        ],
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        minimum_deployment_target=ct.target.iOS17,
    )
    print(f"converted in {time.time() - t0:.1f}s")

    try:
        ml.minimum_deployment_target = ct.target.iOS17
    except Exception:
        pass
    ml.short_description = "Silero VAD 16kHz streaming step (512 samples + 64 context)"
    ml.author = "dhikr-counter eval (conversion of snakers4/silero-vad, MIT)"

    # Validate the in-memory CoreML model against the ONNX oracle before saving.
    import onnxruntime as ort

    session = ort.InferenceSession(str(ONNX_ORACLE), providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(7)
    worst_prob = 0.0
    worst_state = 0.0
    for scale in (0.001, 0.05, 0.5):
        x = rng.normal(0, scale, (1, 576)).astype(np.float32)
        state = rng.normal(0, 0.1, (2, 1, 128)).astype(np.float32)
        pred = ml.predict({"input": x, "state_in": state})
        yo, so = session.run(None, {
            "input": x,
            "state": state,
            "sr": np.array(16000, dtype=np.int64),
        })
        worst_prob = max(worst_prob, float(np.max(np.abs(yo - pred["output"]))))
        worst_state = max(worst_state, float(np.max(np.abs(so - pred["stateN"]))))
    print(f"coreml vs onnx oracle: max prob diff {worst_prob:.3g}, max state diff {worst_state:.3g}")
    if worst_prob > 1e-4 or worst_state > 1e-3:
        raise RuntimeError("CoreML conversion diverges from ONNX oracle")

    out = ROOT / "build" / "SileroVAD.mlpackage"
    out.parent.mkdir(parents=True, exist_ok=True)
    ml.save(str(out))
    print(f"saved {out}")


if __name__ == "__main__":
    try:
        convert()
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise
