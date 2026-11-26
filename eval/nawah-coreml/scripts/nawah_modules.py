"""Torch reimplementations of the Nawah ASR pipeline using only CoreML-convertible ops.

Everything here uses fixed tensor shapes (dynamic values, static shapes) so coremltools
can convert them as mlprogram models:

- KaldiFbank: exact replica of torchaudio.compliance.kaldi.fbank(snip_edges=False,
  povey, 128 mels) for a fixed 15 s input window, with length-aware reflect padding
  and zero-masking of frames beyond the valid length.
- EncoderWrapper: fixed-window FastConformer transcription with key-padding-mask
  derived from mel_length, so valid positions match the unpadded reference exactly.
- DecoderWrapper: manual single-step 2-layer LSTM (matches nn.LSTM numerics).
- JointDecisionWrapper / FusedDecoderJoint: additive joiner + TDT decision head.
"""
from __future__ import annotations

import math
import torch
import torch.nn as nn
import torch.nn.functional as F

# Fixed export geometry: 15 s at 16 kHz.
SR = 16000
MAX_SAMPLES = 240000          # 15 s
WINDOW = 400                  # 25 ms
SHIFT = 160                   # 10 ms
NFFT = 512
NFRAMES = 1500                # (240000 + 80) // 160
NFFT_BINS = 257               # 512 // 2 + 1
NMELS = 128
TENC = 188                    # ceil^3(1500/2) subsampled encoder frames
PAD_LEFT = WINDOW // 2 - SHIFT // 2   # 120
# framing needs padded length 120 + (1500-1)*160 + 400 = 240360
PADDED_LEN = PAD_LEFT + (NFRAMES - 1) * SHIFT + WINDOW  # 240360
TAIL = PADDED_LEN - PAD_LEFT - MAX_SAMPLES              # 240 samples of end-reflection
EXT_LEN = MAX_SAMPLES + TAIL                            # 240240 gathered positions

EPS = 1.1920928955078125e-07  # float eps, kaldi's log floor


def enc_len_of(n: torch.Tensor) -> torch.Tensor:
    for _ in range(3):
        n = (n + 1) // 2
    return n


# ---------------------------------------------------------------------------
# Preprocessor
# ---------------------------------------------------------------------------

def _povey_window(window_size: int) -> torch.Tensor:
    # torch.hann_window(window_size, periodic=False) ** 0.85
    n = torch.arange(window_size, dtype=torch.float64)
    hann = 0.5 - 0.5 * torch.cos(2 * math.pi * n / (window_size - 1))
    return (hann ** 0.85).float()


def _mel_banks(num_bins: int = NMELS, window_length_padded: int = NFFT,
               sample_freq: float = 16000.0, low_freq: float = 20.0, high_freq: float = 0.0):
    """Replica of torchaudio.compliance.kaldi.get_mel_banks (no vtln), plus the zero pad column."""
    num_fft_bins = window_length_padded // 2  # 256 — note: bin 256 (the 257th) gets zero weight
    nyquist = 0.5 * sample_freq
    if high_freq <= 0.0:
        high_freq += nyquist
    fft_bin_width = sample_freq / window_length_padded

    def mel_scale_scalar(freq):
        return 1127.0 * math.log(1.0 + freq / 700.0)

    def inverse_mel_scale(mel):
        return 700.0 * ((mel / 1127.0).exp() - 1.0)

    def mel_scale(freq):
        return 1127.0 * (1.0 + freq / 700.0).log()

    mel_low = mel_scale_scalar(low_freq)
    mel_high = mel_scale_scalar(high_freq)
    mel_delta = (mel_high - mel_low) / (num_bins + 1)
    bin_idx = torch.arange(num_bins, dtype=torch.float32).unsqueeze(1)
    left_mel = mel_low + bin_idx * mel_delta
    center_mel = mel_low + (bin_idx + 1.0) * mel_delta
    right_mel = mel_low + (bin_idx + 2.0) * mel_delta
    center_freqs = inverse_mel_scale(center_mel)
    mel = mel_scale(fft_bin_width * torch.arange(num_fft_bins, dtype=torch.float32)).unsqueeze(0)
    up_slope = (mel - left_mel) / (center_mel - left_mel)
    down_slope = (right_mel - mel) / (right_mel - center_mel)
    bins = torch.max(torch.zeros(1), torch.min(up_slope, down_slope))  # [128, 256]
    # pad right column with zeros -> [128, 257]
    bins = torch.nn.functional.pad(bins, (0, 1), mode="constant", value=0)
    return bins, center_freqs


class KaldiFbank(nn.Module):
    """Fixed-window kaldi fbank, exact replica of torchaudio kaldi snip_edges=False.

    Inputs:
        audio_signal [1, 240240] float32 — raw audio in [-1, 1]. Host contract:
            copy the true segment (L <= 240000 samples) into positions [0, L),
            then write reflection fill buf[L + k] = seg[L - 1 - k] for
            k in [0, min(256, L)) clipped to the buffer end, zeros elsewhere.
            This mirrors kaldi's snip_edges=False reflect padding, which valid
            frames read up to 199 samples beyond the end of the audio.
        audio_length [1] int32 — true number of samples L.

    Outputs:
        mel [1, 128, 1500] float32 — log-mel features, frames >= mel_length zeroed.
        mel_length [1] int32 — (L + 80) // 160.
    """

    def __init__(self):
        super().__init__()
        self.register_buffer("window", _povey_window(WINDOW))  # [400]
        # DFT matrices for rfft of the zero-padded-to-512 frame. Since only the first
        # 400 entries of the 512-vector are nonzero, the composite is [257, 400].
        n = torch.arange(WINDOW, dtype=torch.float64)  # zero-pad tail contributes nothing
        k = torch.arange(NFFT_BINS, dtype=torch.float64).unsqueeze(1)
        ang = 2 * math.pi * k * n.unsqueeze(0) / NFFT
        self.register_buffer("dft_cos", torch.cos(ang).float())        # [257, 400]
        self.register_buffer("dft_neg_sin", (-torch.sin(ang)).float())  # [257, 400]  (imag part of e^{-i…})
        mel_banks, _ = _mel_banks()
        self.register_buffer("mel_fb", mel_banks)  # [128, 257]

    def forward(self, audio_signal: torch.Tensor, audio_length: torch.Tensor):
        # audio [1, 240240] float32 raw; scale to kaldi PCM units first (linear op).
        audio = audio_signal * 32768.0
        L64 = audio_length.to(torch.int64)  # [1]

        # --- kaldi snip_edges=False padding: 120 reflected samples at the start.
        pad_left = torch.flip(audio[:, :PAD_LEFT], dims=[1])                 # [1, 120]
        full = torch.cat([pad_left, audio], dim=1)                           # [1, 240360]

        # --- framing: frame m covers full[m*160 : m*160+400] ------------------
        frame_idx = (torch.arange(NFRAMES, dtype=torch.int64, device=audio.device).unsqueeze(1) * SHIFT
                     + torch.arange(WINDOW, dtype=torch.int64, device=audio.device).unsqueeze(0))  # [1500, 400]
        frames = torch.gather(full, 1, frame_idx.reshape(1, -1)).reshape(1, NFRAMES, WINDOW)  # [1, 1500, 400]

        # --- per-frame mean removal (remove_dc_offset) ----------------------
        frames = frames - frames.mean(dim=2, keepdim=True)

        # --- preemphasis 0.97 with replicated first sample ------------------
        first = frames[:, :, :1]
        shifted = torch.cat([first, frames[:, :, :-1]], dim=2)
        frames = frames - 0.97 * shifted

        # --- povey window ----------------------------------------------------
        frames = frames * self.window.unsqueeze(0).unsqueeze(0)

        # --- matmul-DFT power spectrum [1, 1500, 257] -------------------------
        re = torch.matmul(frames, self.dft_cos.t())
        im = torch.matmul(frames, self.dft_neg_sin.t())
        power = re * re + im * im

        # --- mel filterbank + log --------------------------------------------
        mel = torch.matmul(power, self.mel_fb.t())       # [1, 1500, 128]
        mel = torch.clamp(mel, min=EPS).log()

        # --- zero frames beyond mel_length ------------------------------------
        mel_length = (L64 + 80) // SHIFT                 # [1]
        frame_pos = torch.arange(NFRAMES, dtype=torch.int64, device=audio.device).unsqueeze(0)  # [1, 1500]
        keep = (frame_pos < mel_length.unsqueeze(1)).float().unsqueeze(2)  # [1, 1500, 1]
        mel = mel * keep

        # output [1, 128, 1500], length int32
        return mel.transpose(1, 2).contiguous(), mel_length.to(torch.int32)


AUDIO_BUF = EXT_LEN  # 240240 — input contract length (240000 + 240 tail)


def pack_audio(seg, target_len: int = AUDIO_BUF, reflect: int = 256):
    """Host-side audio packing: copy segment, write kaldi-style reflection fill.

    seg: 1-D numpy array or torch tensor of float32 audio in [-1, 1], len <= 240000.
    Returns (buffer [1, target_len] float32 torch, length int).
    """
    import numpy as np
    if torch.is_tensor(seg):
        seg = seg.detach().cpu().numpy()
    seg = np.asarray(seg, dtype=np.float32)
    L = len(seg)
    assert L <= 240000, f"segment too long: {L} samples > 240000"
    buf = np.zeros(target_len, dtype=np.float32)
    buf[:L] = seg
    depth = min(reflect, L, target_len - L)
    for k in range(depth):
        buf[L + k] = seg[L - 1 - k]
    return torch.from_numpy(buf).unsqueeze(0), L


# ---------------------------------------------------------------------------
# Encoder
# ---------------------------------------------------------------------------

class EncoderWrapper(nn.Module):
    """Fixed-window FastConformer transcriber output with length-derived masking.

    The stride-2 subsampling convs are length-masked after every level: in the unpadded
    reference each conv output is truncated at ceil(n/2), so boundary positions read implicit
    zero padding. Without masking, fixed-window positions beyond the valid length hold nonzero
    values (their receptive field still covers valid input frames) and contaminate the last
    valid output frame(s). Masking after each level makes valid positions exactly equal to
    the unpadded reference.

    Inputs:
        mel [1, 128, 1500] float32 — zero-padded beyond mel_length frames
        mel_length [1] int32
    Outputs:
        encoder [1, 384, 188] float32 — joint-dim projections, frames beyond enc_len zeroed
        encoder_length [1] int32
    """

    def __init__(self, transcriber: nn.Module):
        super().__init__()
        self.transcriber = transcriber
        # Precompute the static relative-position attention bias per layer.
        # In RelMHSA: idx = (arange(T)[None,:] - arange(T)[:,None]).clamp(±max_rel);
        # bias = rel[:, idx + max_rel] — fully static for fixed T, so bake it as a constant.
        enc = transcriber.enc
        blk0 = enc.blocks[0]
        max_rel = blk0.attn.max_rel
        t_idx = torch.arange(TENC)
        idx = (t_idx[None, :] - t_idx[:, None]).clamp(-max_rel, max_rel) + max_rel  # [188, 188]
        self._rel_idx = idx
        biases = []
        for b in enc.blocks:
            biases.append(b.attn.rel[:, idx].detach().clone())  # [heads, 188, 188]
        self.register_buffer("rel_bias", torch.stack(biases, dim=0))  # [layers, heads, 188, 188]

    @staticmethod
    def _zero_beyond(x: torch.Tensor, length: torch.Tensor, t_max: int) -> torch.Tensor:
        # x [B, C, F, T]; length [1] int64 — zero time positions >= length
        pos = torch.arange(t_max, dtype=torch.int64, device=x.device).unsqueeze(0)  # [1, T]
        keep = (pos < length.unsqueeze(1)).float()                                  # [1, T]
        return x * keep.reshape(1, 1, 1, t_max)

    def _attention(self, attn: nn.Module, x: torch.Tensor, kpm: torch.Tensor, layer: int) -> torch.Tensor:
        # x [1, 188, 384] — static-shape reimplementation of RelMHSA.forward
        h, dk = attn.h, attn.dk
        q, k, v = attn.qkv(x).chunk(3, dim=-1)
        q = q.view(1, TENC, h, dk).transpose(1, 2)   # [1, heads, 188, dk]
        k = k.view(1, TENC, h, dk).transpose(1, 2)
        v = v.view(1, TENC, h, dk).transpose(1, 2)
        s = torch.matmul(q, k.transpose(-1, -2)) / math.sqrt(dk)     # [1, heads, 188, 188]
        s = s + self.rel_bias[layer].unsqueeze(0)
        s = s.masked_fill(kpm[:, None, None, :], float("-inf"))
        a = s.float().softmax(-1).to(s.dtype)
        y = torch.matmul(a, v).transpose(1, 2).reshape(1, TENC, h * dk)
        return attn.out(y)

    @staticmethod
    def _conv_module(conv: nn.Module, x: torch.Tensor, kpm: torch.Tensor) -> torch.Tensor:
        x = conv.norm(x)
        a, b = conv.pw1(x).chunk(2, dim=-1)
        x = a * b.sigmoid()
        x = x.masked_fill(kpm[..., None], 0.0)
        x = conv.dw(x.transpose(1, 2))
        x = F.silu(conv.bn(x)).transpose(1, 2)
        return conv.pw2(x)

    def forward(self, mel: torch.Tensor, mel_length: torch.Tensor):
        ml64 = mel_length.to(torch.int64)                      # [1]
        l1 = (ml64 + 1) // 2
        l2 = (l1 + 1) // 2
        enc_len = (l2 + 1) // 2                                # [1]

        enc = self.transcriber.enc
        emb = enc.embed
        x = emb.conv[0](mel.unsqueeze(1))                      # [1, 256, 64, 750]
        x = self._zero_beyond(x, l1, 750)
        x = emb.conv[1](x)                                     # [1, 256, 32, 375]
        x = self._zero_beyond(x, l2, 375)
        x = emb.conv[2](x)                                     # [1, 256, 16, 188]
        x = self._zero_beyond(x, enc_len, TENC)
        x = emb.out(x.permute(0, 3, 1, 2).reshape(1, TENC, 256 * 16))   # [1, 188, 384]

        pos = torch.arange(TENC, dtype=torch.int64, device=mel.device).unsqueeze(0)  # [1, 188]
        kpm = pos >= enc_len.unsqueeze(1)                      # [1, 188] bool — True = padded
        for i, blk in enumerate(enc.blocks):
            x = x + 0.5 * blk.ff1(x)
            x = x + self._attention(blk.attn, blk.norm_attn(x), kpm, i)
            x = x + self._conv_module(blk.conv, x, kpm)
            x = x + 0.5 * blk.ff2(x)
            x = blk.norm(x)
        x = self.transcriber.proj(x)                           # [1, 188, 384]
        # zero padded positions for cleanliness
        keep = (~kpm).float().unsqueeze(2)                     # [1, 188, 1]
        x = x * keep
        # transpose to channels-first [1, 384, 188] (NeMo/mobius convention)
        return x.transpose(1, 2).contiguous(), enc_len.to(torch.int32)


# ---------------------------------------------------------------------------
# Decoder (manual single-step 2-layer LSTM)
# ---------------------------------------------------------------------------

class DecoderWrapper(nn.Module):
    """Single-step LSTM prediction network, numerically identical to nn.LSTM.

    Inputs:
        targets [1, 1] int32 — previous emitted token (blank at start)
        target_length [1] int32 — always 1 (contract compatibility)
        h_in [2, 1, 320] float32
        c_in [2, 1, 320] float32
    Outputs:
        decoder [1, 320, 1] float32 — joint-dim projection... (see note)
        h_out [2, 1, 320], c_out [2, 1, 320]

    Note: the projection output is actually joint_dim=384 wide; shapes in the
    contract come from the traced tensors, docstring is indicative only.
    """

    def __init__(self, predictor: nn.Module):
        super().__init__()
        self.embed = predictor.embed
        lstm = predictor.lstm
        self.register_buffer("w_ih_l0", lstm.weight_ih_l0.data.clone())
        self.register_buffer("w_hh_l0", lstm.weight_hh_l0.data.clone())
        self.register_buffer("b_ih_l0", lstm.bias_ih_l0.data.clone())
        self.register_buffer("b_hh_l0", lstm.bias_hh_l0.data.clone())
        self.register_buffer("w_ih_l1", lstm.weight_ih_l1.data.clone())
        self.register_buffer("w_hh_l1", lstm.weight_hh_l1.data.clone())
        self.register_buffer("b_ih_l1", lstm.bias_ih_l1.data.clone())
        self.register_buffer("b_hh_l1", lstm.bias_hh_l1.data.clone())
        self.proj = predictor.proj

    @staticmethod
    def _lstm_step(x, h, c, w_ih, w_hh, b_ih, b_hh):
        # x, h, c: [1, 320]; weights: [1280, 320], biases [1280]
        gates = torch.matmul(x, w_ih.t()) + b_ih + torch.matmul(h, w_hh.t()) + b_hh
        i, f, g, o = gates.chunk(4, dim=-1)
        i = torch.sigmoid(i)
        f = torch.sigmoid(f)
        g = torch.tanh(g)
        o = torch.sigmoid(o)
        c_new = f * c + i * g
        h_new = o * torch.tanh(c_new)
        return h_new, c_new

    def forward(self, targets, target_length, h_in, c_in):
        tok = targets.to(torch.int64).reshape(1)               # [1]
        x = self.embed(tok)                                    # [1, 320]
        h0 = h_in[0]                                           # [1, 320]
        c0 = c_in[0]
        h1 = h_in[1]
        c1 = c_in[1]
        h0n, c0n = self._lstm_step(x, h0, c0, self.w_ih_l0, self.w_hh_l0, self.b_ih_l0, self.b_hh_l0)
        h1n, c1n = self._lstm_step(h0n, h1, c1, self.w_ih_l1, self.w_hh_l1, self.b_ih_l1, self.b_hh_l1)
        out = self.proj(h1n)                                   # [1, 384]
        h_out = torch.stack([h0n, h1n], dim=0)                 # [2, 1, 320]
        c_out = torch.stack([c0n, c1n], dim=0)
        # channels-first single-step output [1, 384, 1] (mobius/NeMo convention)
        return out.unsqueeze(2), h_out, c_out


# ---------------------------------------------------------------------------
# Joiner + decision head
# ---------------------------------------------------------------------------

class JoinerCore(nn.Module):
    """Additive joiner: logits = Linear(tanh(enc + pred))."""

    def __init__(self, joiner: nn.Module):
        super().__init__()
        self.out = joiner.out

    def forward(self, encoder_step: torch.Tensor, decoder_step: torch.Tensor):
        # encoder_step [1, 384, 1], decoder_step [1, 384, 1] (channels-first)
        enc = encoder_step.squeeze(2)                          # [1, 384]
        dec = decoder_step.squeeze(2)                          # [1, 384]
        logits = self.out(torch.tanh(enc + dec))               # [1, 1029]
        return logits


class JointDecisionSingleStep(nn.Module):
    """Joint + TDT greedy decision: token argmax, duration argmax, probs, top-k.

    Outputs match the mobius/FluidAudio JointDecision(v3) contract where practical:
        token_id [1, 1, 1] int32
        token_prob [1, 1, 1] float32
        duration [1, 1, 1] int32
        top_k_ids [1, 1, 1, 64] int32
        top_k_logits [1, 1, 1, 64] float32
    """

    def __init__(self, joiner: nn.Module, vocab_size: int = 1024, num_extra: int = 5, top_k: int = 64):
        super().__init__()
        self.joiner = JoinerCore(joiner)
        self.vocab = vocab_size
        self.num_extra = num_extra
        self.top_k = top_k

    def forward(self, encoder_step: torch.Tensor, decoder_step: torch.Tensor):
        logits = self.joiner(encoder_step, decoder_step)       # [1, 1029]
        token_logits = logits[:, : self.vocab]                 # [1, 1024]
        duration_logits = logits[:, -self.num_extra :]         # [1, 5]
        token_id = torch.argmax(token_logits, dim=-1).to(torch.int32)      # [1]
        probs = torch.softmax(token_logits, dim=-1)
        token_prob = torch.gather(probs, 1, token_id.to(torch.int64).unsqueeze(1)).squeeze(1)  # [1]
        duration = torch.argmax(duration_logits, dim=-1).to(torch.int32)   # [1] (bins == frames)
        k = min(self.top_k, self.vocab)
        top_logits, top_ids = torch.topk(token_logits, k=k, dim=-1)
        # reshape to [1,1,1]/[1,1,1,64] mobius-style
        return (token_id.reshape(1, 1, 1),
                token_prob.reshape(1, 1, 1),
                duration.reshape(1, 1, 1),
                top_ids.to(torch.int32).reshape(1, 1, 1, k),
                top_logits.reshape(1, 1, 1, k))


class FusedDecoderJoint(nn.Module):
    """Decoder + joint decision in a single forward (one CoreML dispatch per step)."""

    def __init__(self, predictor: nn.Module, joiner: nn.Module, vocab_size: int = 1024, num_extra: int = 5):
        super().__init__()
        self.decoder = DecoderWrapper(predictor)
        self.decision = JointDecisionSingleStep(joiner, vocab_size, num_extra)

    def forward(self, targets, target_length, h_in, c_in, encoder_step):
        dec_out, h_out, c_out = self.decoder(targets, target_length, h_in, c_in)
        token_id, token_prob, duration, topk_ids, topk_logits = self.decision(encoder_step, dec_out)
        return token_id, token_prob, duration, topk_ids, topk_logits, h_out, c_out
