#!/usr/bin/env python3
"""Convert Nawah-ASR-60M-Max-Arabic to CoreML components (mobius/FluidAudio-style layout).

Outputs (in --output-dir):
    Preprocessor.mlpackage   audio[1,240240] f32 + audio_length[1] i32 -> mel[1,128,1500] f32, mel_length[1] i32
    Encoder.mlpackage        mel[1,128,1500] f32 + mel_length[1] i32   -> encoder[1,384,188], encoder_length[1] i32
    Decoder.mlpackage        targets[1,1] i32, target_length[1] i32, h_in/c_in[2,1,320] f32
                             -> decoder[1,384,1], h_out, c_out
    JointDecision.mlpackage  encoder_step[1,384,1], decoder_step[1,384,1]
                             -> token_id, token_prob, duration, top_k_ids, top_k_logits
    DecoderJoint.mlpackage   fused decoder+joint decision single step
    parakeet_vocab.json      id_to_token vocabulary (dict format)

Each component is exported fp32 (reference) and fp16 (deployment) when --both-precisions.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import typer

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "models" / "torch-repo"))
sys.path.insert(0, str(HERE))

import parakeet_model as P  # noqa: E402
from nawah_modules import (  # noqa: E402
    DecoderWrapper,
    EncoderWrapper,
    FusedDecoderJoint,
    JointDecisionSingleStep,
    KaldiFbank,
)

app = typer.Typer(add_completion=False, pretty_exceptions_show_locals=False)
AUTHOR = "dhikr-counter eval (conversion of oddadmix/Nawah-ASR-60M-Max-Arabic)"


def _save(model: ct.models.MLModel, path: Path, desc: str) -> None:
    try:
        model.minimum_deployment_target = ct.target.iOS17
    except Exception:
        pass
    model.short_description = desc
    model.author = AUTHOR
    path.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(path))
    print(f"  saved {path.name}")


def _convert(traced, inputs, outputs, precision, name):
    kwargs = {
        "convert_to": "mlprogram",
        "inputs": inputs,
        "outputs": outputs,
        "compute_units": ct.ComputeUnit.CPU_ONLY,  # runtime can override; tracing constraint per mobius
        "minimum_deployment_target": ct.target.iOS17,
    }
    if precision is not None:
        kwargs["compute_precision"] = precision
    print(f"  converting {name} ({'fp16' if precision == ct.precision.FLOAT16 else 'fp32'})…")
    t0 = time.time()
    ml = ct.convert(traced, **kwargs)
    print(f"  {name} converted in {time.time()-t0:.1f}s")
    return ml


@app.command()
def convert(
    output_dir: Path = typer.Option(ROOT / "build", "--output-dir"),
    both_precisions: bool = typer.Option(True, "--both-precisions/--no-both-precisions"),
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    print("loading torch checkpoint…")
    model = P.load(str(ROOT / "models" / "torch-repo" / "nawah_asr_60m_max_arabic.pt"), device="cpu")
    model.eval()

    precisions = [ct.precision.FLOAT32] + ([ct.precision.FLOAT16] if both_precisions else [])
    tags = {ct.precision.FLOAT32: "fp32", ct.precision.FLOAT16: "fp16"}

    # ------------------------------------------------------------------ preprocessor
    print("preprocessor: trace")
    pp = KaldiFbank().eval()
    audio = torch.zeros(1, 240240)
    audio_len = torch.tensor([240000], dtype=torch.int32)
    with torch.inference_mode():
        traced_pp = torch.jit.trace(pp, (audio, audio_len), strict=False)
    traced_pp.eval()
    for prec in precisions:
        if prec == ct.precision.FLOAT16:
            # fp16 overflows on the x32768 PCM scaling / power spectrum; preprocessor stays fp32
            continue
        ml = _convert(
            traced_pp,
            [
                ct.TensorType(name="audio_signal", shape=(1, 240240), dtype=np.float32),
                ct.TensorType(name="audio_length", shape=(1,), dtype=np.int32),
            ],
            [
                ct.TensorType(name="mel", dtype=np.float32),
                ct.TensorType(name="mel_length", dtype=np.int32),
            ],
            prec,
            "Preprocessor",
        )
        _save(ml, output_dir / "Preprocessor.mlpackage", "Nawah kaldi-fbank preprocessor (15 s window)")

    # ------------------------------------------------------------------ encoder
    print("encoder: trace")
    ew = EncoderWrapper(model.transcriber).eval()
    mel = torch.zeros(1, 128, 1500)
    mel_len = torch.tensor([1500], dtype=torch.int32)
    with torch.inference_mode():
        traced_enc = torch.jit.trace(ew, (mel, mel_len), strict=False)
    traced_enc.eval()
    for prec in precisions:
        ml = _convert(
            traced_enc,
            [
                ct.TensorType(name="mel", shape=(1, 128, 1500), dtype=np.float32),
                ct.TensorType(name="mel_length", shape=(1,), dtype=np.int32),
            ],
            [
                ct.TensorType(name="encoder", dtype=np.float32),
                ct.TensorType(name="encoder_length", dtype=np.int32),
            ],
            prec,
            "Encoder",
        )
        tag = "" if prec == ct.precision.FLOAT16 else "_fp32"
        _save(ml, output_dir / f"Encoder{tag}.mlpackage", f"Nawah FastConformer encoder 15s ({tags[prec]})")

    # ------------------------------------------------------------------ decoder
    print("decoder: trace")
    dec = DecoderWrapper(model.predictor).eval()
    targets = torch.tensor([[0]], dtype=torch.int32)
    target_len = torch.tensor([1], dtype=torch.int32)
    h0 = torch.zeros(2, 1, 320)
    c0 = torch.zeros(2, 1, 320)
    with torch.inference_mode():
        traced_dec = torch.jit.trace(dec, (targets, target_len, h0, c0), strict=False)
    traced_dec.eval()
    for prec in precisions:
        ml = _convert(
            traced_dec,
            [
                ct.TensorType(name="targets", shape=(1, 1), dtype=np.int32),
                ct.TensorType(name="target_length", shape=(1,), dtype=np.int32),
                ct.TensorType(name="h_in", shape=(2, 1, 320), dtype=np.float32),
                ct.TensorType(name="c_in", shape=(2, 1, 320), dtype=np.float32),
            ],
            [
                ct.TensorType(name="decoder", dtype=np.float32),
                ct.TensorType(name="h_out", dtype=np.float32),
                ct.TensorType(name="c_out", dtype=np.float32),
            ],
            prec,
            "Decoder",
        )
        tag = "" if prec == ct.precision.FLOAT16 else "_fp32"
        _save(ml, output_dir / f"Decoder{tag}.mlpackage", f"Nawah LSTM prediction network ({tags[prec]})")

    # ------------------------------------------------------------------ joint decision
    print("joint decision: trace")
    jd = JointDecisionSingleStep(model.joiner).eval()
    enc_step = torch.randn(1, 384, 1)
    dec_step = torch.randn(1, 384, 1)
    with torch.inference_mode():
        traced_jd = torch.jit.trace(jd, (enc_step, dec_step), strict=False)
    traced_jd.eval()
    for prec in precisions:
        ml = _convert(
            traced_jd,
            [
                ct.TensorType(name="encoder_step", shape=(1, 384, 1), dtype=np.float32),
                ct.TensorType(name="decoder_step", shape=(1, 384, 1), dtype=np.float32),
            ],
            [
                ct.TensorType(name="token_id", dtype=np.int32),
                ct.TensorType(name="token_prob", dtype=np.float32),
                ct.TensorType(name="duration", dtype=np.int32),
                ct.TensorType(name="top_k_ids", dtype=np.int32),
                ct.TensorType(name="top_k_logits", dtype=np.float32),
            ],
            prec,
            "JointDecision",
        )
        tag = "" if prec == ct.precision.FLOAT16 else "_fp32"
        _save(ml, output_dir / f"JointDecision{tag}.mlpackage", f"Nawah joint+TDT decision ({tags[prec]})")

    # ------------------------------------------------------------------ fused decoder+joint
    print("fused decoder+joint: trace")
    fused = FusedDecoderJoint(model.predictor, model.joiner).eval()
    with torch.inference_mode():
        traced_fused = torch.jit.trace(fused, (targets, target_len, h0, c0, enc_step), strict=False)
    traced_fused.eval()
    for prec in precisions:
        ml = _convert(
            traced_fused,
            [
                ct.TensorType(name="targets", shape=(1, 1), dtype=np.int32),
                ct.TensorType(name="target_length", shape=(1,), dtype=np.int32),
                ct.TensorType(name="h_in", shape=(2, 1, 320), dtype=np.float32),
                ct.TensorType(name="c_in", shape=(2, 1, 320), dtype=np.float32),
                ct.TensorType(name="encoder_step", shape=(1, 384, 1), dtype=np.float32),
            ],
            [
                ct.TensorType(name="token_id", dtype=np.int32),
                ct.TensorType(name="token_prob", dtype=np.float32),
                ct.TensorType(name="duration", dtype=np.int32),
                ct.TensorType(name="top_k_ids", dtype=np.int32),
                ct.TensorType(name="top_k_logits", dtype=np.float32),
                ct.TensorType(name="h_out", dtype=np.float32),
                ct.TensorType(name="c_out", dtype=np.float32),
            ],
            prec,
            "DecoderJoint",
        )
        tag = "" if prec == ct.precision.FLOAT16 else "_fp32"
        _save(ml, output_dir / f"DecoderJoint{tag}.mlpackage", f"Nawah fused decoder+joint decision ({tags[prec]})")

    # ------------------------------------------------------------------ vocabulary + metadata
    cfg = json.load(open(ROOT / "models" / "onnx-repo" / "config.json"))
    id_to_token = cfg["id_to_token"]  # list of 1024 pieces
    vocab_dict = {str(i): t for i, t in enumerate(id_to_token)}
    with open(output_dir / "parakeet_vocab.json", "w") as fh:
        json.dump(vocab_dict, fh, ensure_ascii=False, indent=0)
    meta = {
        "model_id": "oddadmix/Nawah-ASR-60M-Max-Arabic",
        "sample_rate": 16000,
        "max_audio_seconds": 15.0,
        "max_audio_samples": 240000,
        "mel_frames": 1500,
        "mel_bins": 128,
        "encoder_frames": 188,
        "encoder_hidden": 384,
        "encoder_subsampling": 8,
        "samples_per_encoder_frame": 1280,
        "decoder_hidden": 320,
        "decoder_layers": 2,
        "joint_dim": 384,
        "vocab_size": 1024,
        "blank_id": 0,
        "durations": [0, 1, 2, 3, 4],
        "max_symbols_per_frame": 10,
        "layout": {
            "Preprocessor": {"inputs": {"audio_signal": [1, 240240], "audio_length": [1]},
                             "outputs": {"mel": [1, 128, 1500], "mel_length": [1]}},
            "Encoder": {"inputs": {"mel": [1, 128, 1500], "mel_length": [1]},
                        "outputs": {"encoder": [1, 384, 188], "encoder_length": [1]}},
            "Decoder": {"inputs": {"targets": [1, 1], "target_length": [1], "h_in": [2, 1, 320], "c_in": [2, 1, 320]},
                        "outputs": {"decoder": [1, 384, 1], "h_out": [2, 1, 320], "c_out": [2, 1, 320]}},
            "JointDecision": {"inputs": {"encoder_step": [1, 384, 1], "decoder_step": [1, 384, 1]},
                              "outputs": {"token_id": [1, 1, 1], "token_prob": [1, 1, 1], "duration": [1, 1, 1],
                                          "top_k_ids": [1, 1, 1, 64], "top_k_logits": [1, 1, 1, 64]}},
        },
        "notes": "mel frames beyond mel_length are zeroed; encoder frames beyond encoder_length are zeroed; "
                 "reflection padding inside Preprocessor mirrors kaldi snip_edges=False",
    }
    with open(output_dir / "metadata.json", "w") as fh:
        json.dump(meta, fh, indent=2)
    print(f"done — artifacts in {output_dir}")


if __name__ == "__main__":
    app()
