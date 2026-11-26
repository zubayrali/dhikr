# Nawah-ASR-60M-Max-Arabic → CoreML conversion report

**Outcome: full success.** The model is converted to CoreML, validated numerically against the
torch reference, and proven end-to-end by a Swift CLI that transcribes all three corpus files with
**exactly correct repetition counts** (10/33/11+11+12) at **RTF ≈ 0.0035 (~280× realtime)** with
the fp16 encoder running on Neural Engine/GPU.

---

## 1. Deliverables

```
eval/nawah-coreml/
├── build/                          # .mlpackage artifacts (fp16 default + fp32 reference)
│   ├── Preprocessor.mlpackage      # 2.6 MB  fp32, kaldi fbank, fixed 15 s window
│   ├── Encoder.mlpackage           # 121 MB  fp16, FastConformer 17L/d384, fixed 15 s window
│   ├── Encoder_fp32.mlpackage      # 242 MB  fp32 reference
│   ├── Decoder.mlpackage           # 4.0 MB  fp16, 2-layer LSTM predictor (manual gate math)
│   ├── Decoder_fp32.mlpackage      # 8.0 MB
│   ├── JointDecision.mlpackage     # 792 KB  fp16, additive joiner + TDT argmax + top-k
│   ├── JointDecision_fp32.mlpackage
│   ├── DecoderJoint.mlpackage      # 4.8 MB  fp16, fused decoder+joint (used by the Swift CLI)
│   ├── DecoderJoint_fp32.mlpackage
│   ├── parakeet_vocab.json         # 1024-piece BPE vocab (dict format, id→piece)
│   └── metadata.json               # shapes/layout/dimensions
├── build/compiled/                 # .mlmodelc bundles (xcrun coremlcompiler), same components
│                                   # sizes: Preprocessor 5.3M, Encoder 121M, Decoder 4.0M,
│                                   # JointDecision 800K, DecoderJoint 4.8M
├── scripts/
│   ├── nawah_modules.py            # torch reimplementations using only convertible ops
│   └── convert_nawah.py            # conversion driver (uv run python scripts/convert_nawah.py)
├── swift-cli/
│   ├── main.swift                  # the end-to-end CLI (~410 lines)
│   └── nawah-asr                   # compiled binary (swiftc -O)
├── results/                        # per-file JSON reports (segments, timing, transcripts)
├── ref/torch-oracle.md             # torch reference transcripts
└── models/                         # downloaded HF repos (torch + ONNX reference)
```

## 2. How to reproduce/run

```bash
# transcribe (paths relative to swift-cli/)
./nawah-asr "/Users/fxwalken/Documents/GitHub/dhikr counter/eval/corpus/slow10.wav" \
    --models ../build/compiled            # fp16 encoder (default), prints transcript to stdout
./nawah-asr <wav> --models ../build/compiled --json     # machine-readable per-segment report
./nawah-asr <wav> --models ../build/compiled --fp32     # fp32 encoder (identical transcripts)

# rebuild the CLI
cd swift-cli && swiftc -O -o nawah-asr main.swift -framework CoreML -framework Accelerate

# reconvert models (needs the uv venv: torch, coremltools 9.0, soundfile, tokenizers, typer)
.venv/bin/python scripts/convert_nawah.py --output-dir build
for p in Preprocessor Encoder Encoder_fp32 Decoder Decoder_fp32 JointDecision \
         JointDecision_fp32 DecoderJoint DecoderJoint_fp32; do
    xcrun coremlcompiler compile "build/$p.mlpackage" build/compiled
done
```

## 3. End-to-end results (Swift CLI, fp16 encoder, ANE-enabled)

| file | audio | segments | inference | RTF | realtime | transcript correctness |
|---|---:|---:|---:|---:|---:|---|
| slow10.wav | 17.97 s | 2 | ~64 ms | 0.0036 | ~280× | **exactly 10× سبحان الله** — perfect |
| fast33.wav | 37.73 s | 4 | ~131 ms | 0.0035 | ~288× | **exactly 33× سبحان الله** — perfect |
| mixed34.wav | 48.91 s | 6 | ~173 ms | 0.0035–0.0049 | ~280× | **exactly 11× سبحان الله + 11× الحمد لله + 12× الله اكبر** — perfect |

Transcripts are not merely "close" — every repetition is present with correct spelling and ordering,
identical to the torch fp32 reference (which itself matches the corpus ground truth). fp32 and fp16
encoder variants produce identical transcripts on all files.

Model load time in-process: ~140–170 ms total for all three components (after first compile).

**Deployment payload (fp16): Preprocessor 5.3 MB + Encoder 121 MB + DecoderJoint 4.8 MB + vocab 16 KB
= 131 MB on disk** (vs ~72 MB for Sabbih's int8 ONNX payload — see §8 for quantization options).
Short-segment latency: a 2 s single-repetition clip transcribes in 20 ms end-to-end (the fixed 15 s
window makes per-segment cost roughly constant; the decode loop scales with speech content).
fp32 and fp16 encoder variants produce identical transcripts on all three corpus files.

### Where the time goes (per ~10 s segment)

- Preprocessor (kaldi fbank): ~2 ms (CPU, fp32)
- Encoder: **4.5 ms per 15 s window with cpuAndNeuralEngine/CPU_AND_GPU — vs 17.5 ms CPU-only**,
  i.e. the fp16 encoder is offload-resident (ANE or GPU; see §7)
- Greedy decode loop: the rest, dominated by **~0.16 ms/step MLModel dispatch overhead**
  (fused DecoderJoint, measured in isolation in Swift: median 0.157 ms cpuOnly, 0.164 cpuAndNE —
  compute-unit-independent because the graph is tiny and CPU-resident). A 10 s segment needs
  ~100–140 joint steps → ~20–30 ms. **The decode loop is ~75–85% of total inference time.**
  This is structural, not a conversion defect — the math is trivial (≈2 MFLOP/step) and the cost
  is per-dispatch overhead. See recommendations §8.

## 4. Numerical validation (CoreML vs torch reference)

Validation methodology: torch reference is the authoritative oracle (`parakeet_model.py` fp32 CPU,
unpadded exact-length inputs). The fixed-window CoreML pipeline must reproduce it at valid positions.

| component | comparison | result |
|---|---|---|
| Preprocessor (torch module) | matmul-DFT reimplementation vs `torchaudio.compliance.kaldi.fbank` | cosine ≈ 1.000000, mean abs 2.4e-5, max abs 5.2e-2 (log-mel domain; max diffs confined to near-silent bins where log amplifies fp32 rounding of the power spectrum) |
| Preprocessor (CoreML vs torch module) | same input | max abs 7.7e-4 |
| **Encoder fp32** | CoreML vs torch ref, 10 s real speech | **max abs 9.3e-5, mean 5.3e-6, cosine 1.000000** |
| **Encoder fp16** | same | max abs 0.11, mean 4.8e-3, cosine 0.999985 — no NaNs; transcripts bit-identical end-to-end |
| Encoder masking correctness | fixed-window+padded vs unpadded reference, torch fp32 | **max abs 4.5e-6** for 5 s input, **exactly 0.0** for full 15 s input |
| Decoder (manual LSTM) | vs `nn.LSTM` predictor, 20 random states | max abs 8.6e-7 |
| Joiner/decision | token/duration argmax + probs | exact match |

Key correctness design points (all verified experimentally):

1. **Stride-2 conv boundary contamination.** In the unpadded reference, each subsampling conv output
   is truncated at ⌈n/2⌉ so boundary positions read implicit zero padding. In a fixed 1500-frame
   window, intermediate positions beyond the valid length are *nonzero* (their receptive field still
   covers valid input frames) and contaminate the last valid encoder frame (observed diff of 388 in
   the embedding!). Fix: length-mask the subsampling stack after *each* of the three conv levels.
   Result: valid positions exact to fp32 noise.
2. **Key padding mask in attention/conv.** Valid positions are only bit-exact because padded positions
   are masked out of attention (`-inf` scores) and zeroed before every depthwise conv, mirroring what
   zero-padding does implicitly in the unpadded computation.
3. **kaldi snip_edges=False reflection.** Valid frames read up to 199 samples beyond the end of the
   audio; torchaudio reflect-pads with the reversed waveform. The CoreML preprocessor cannot gather
   with dynamic indices (coremltools requires int32-domain indices and the traced int64 path fails),
   so the host writes the reflection fill (`buf[L+k] = seg[L-1-k]`, depth 256) when packing the
   zero-padded input buffer. Start-of-audio reflection (first 120 samples reversed) is static and
   done in-graph. Verified: last valid frames match reference to ~1e-4.
4. **No FFT in CoreML.** `torch.fft` is unsupported/fragile in coremltools; the power spectrum is
   computed as two matmuls with precomputed DFT cos/−sin matrices [257,400] (exact linear algebra,
   zero-pad tail contributes nothing). This is also why the preprocessor must stay **fp32**:
   audio is scaled ×32768 and power values reach ~1e13, far beyond fp16 range.
5. **LSTM manually unrolled.** The predictor is a single-step 2-layer LSTM reimplemented as explicit
   gate matmuls (PyTorch gate order i,f,g,o) — avoids `aten` RNN tracing issues entirely, exact to 8.6e-7.
6. **Static shapes only.** All shape unpacking (`B, T, D = x.shape`) was eliminated (coremltools
   chokes on the resulting `aten::Int`); the relative-position attention bias is precomputed as a
   constant `[layers, heads, 188, 188]` buffer at export time.

## 5. Component contracts (matches mobius/FluidAudio layout where practical)

| model | inputs | outputs |
|---|---|---|
| Preprocessor | `audio_signal` [1, 240240] f32 (segment + host reflection fill + zeros), `audio_length` [1] i32 | `mel` [1, 128, 1500] f32 (frames ≥ mel_length zeroed), `mel_length` [1] i32 |
| Encoder | `mel` [1, 128, 1500] f32, `mel_length` [1] i32 | `encoder` [1, 384, 188] f32 (frames ≥ enc len zeroed), `encoder_length` [1] i32 |
| Decoder | `targets` [1,1] i32, `target_length` [1] i32, `h_in`/`c_in` [2,1,320] f32 | `decoder` [1,384,1], `h_out`, `c_out` |
| JointDecision | `encoder_step` [1,384,1], `decoder_step` [1,384,1] | `token_id`/`token_prob`/`duration` [1,1,1], `top_k_ids`/`top_k_logits` [1,1,1,64] |
| DecoderJoint (fused) | Decoder inputs + `encoder_step` | JointDecision outputs + `h_out`/`c_out` |

Greedy TDT decode (validated identical to reference): start token = blank 0, zero h/c; per encoder
frame: argmax token over 1024 vocab logits, argmax over 5 duration logits (bins ≡ frames [0,1,2,3,4]);
blank → advance max(d,1), reset symbol cap; non-blank → emit, step the LSTM, advance d, cap
zero-duration symbols at 10/frame. On blank steps the fused model is re-fed the unchanged
(token, h, c) — the LSTM recompute is deterministic (mobius semantics). Detokenization: concatenate
pieces, replace U+2581 `▁` with space (verified byte-identical to `tokenizer.decode`).

## 6. Long-audio handling in the eval CLI

Corpus files exceed the 15 s encoder window (18–49 s). The CLI uses **quietest-point chunking**:
RMS energy per 512-sample frame, 5-frame smoothed, split at the minimum-energy point inside
[pos+4 s, pos+14 s], iterate. Splits land in inter-phrase silence so no words are clipped for these
files. This is an eval harness convenience — the production pipeline should use VAD-driven
segmentation (Sabbih-style: Silero VAD + 3-frame start + hangover + 15 s cap), which the menu-bar
app needs anyway for streaming. Note the eval proves the CoreML conversion correct on real continuous
speech regardless of the chunking policy.

## 7. ANE/offload evidence

- Encoder fp16: 4.5 ms/window with `.cpuAndNeuralEngine` or `.cpuAndGPU` vs 17.5 ms `.cpuOnly` —
  the 4× offload speedup shows the conformer graph is offload-resident. coremltools reports no
  unsupported-op failures during conversion; the encoder is pure conv/linear/softmax/layernorm.
  (Per-op device breakdown via mobius coreml-cli was not run — its uv env setup was deprioritized;
  the latency evidence stands on its own.)
- Decoder/JointDecision/DecoderJoint: tiny graphs, CPU-resident by dispatch economics
  (mobius established `ios17.lstm` has no ANE kernel at all — a non-issue here since the manual
  gate implementation doesn't even use the lstm op; still dispatch-bound either way).
- Preprocessor: fp32, runs CPU (2 ms/window — irrelevant cost).

## 8. FluidAudio compatibility — the key uncertainty, answered with evidence

**FluidAudio cannot consume custom-shape parakeet-TDT models as-is.** Evidence from
`ref/FluidAudio/Sources/FluidAudio`:

- `ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift`: `AsrModelVersion` is a closed enum
  (v2/v3/redux/ultra/phonon2/phonon25/bark3/bark3Clean/tdtCtc110m/tdtJa) with **hardcoded per-version
  dimensions** — `encoderHiddenSize` only ever 1024 or 512, `blankId` only 1024/8192/3072,
  `decoderLayers` 1 or 2. Nawah needs encoder-hidden **384**, blank **0**, vocab **1024**,
  decoder-hidden **320** — no version matches.
- `Shared/ASRConstants.swift`: `encoderHiddenSize = 1024`, `decoderHiddenSize = 640` global constants.
- `AsrModels.loadLocal(...)` exists but still requires picking a version and validates the vocabulary
  against `version.blankId`; repo/file names are centralized in `ModelNames.ASR`
  (`Preprocessor/Encoder/Decoder/JointDecisionv3.mlmodelc` + `parakeet_vocab.json`).
- Positively: the decode config *is* adapted at runtime (`AsrManager` line ~303: blankId follows
  `models.version.blankId`), `TdtConfig` is injectable, and `EncoderFrameView` auto-detects
  `[1,T,D]` vs `[1,D,T]` layout — so a **fork adding one enum case** (`.nawah` with hidden 384,
  blank 0, plus reading decoder hidden from the model) is a small, well-scoped change. Our artifacts
  already use the FluidAudio file layout and vocab format to keep that path open.

**Recommended integration path for the dhikr counter (what this eval proves): our own thin Swift
decoding loop** — which is what the product needs anyway:

- The entire runtime is: preprocessor + encoder once per segment, then a ~120-line greedy TDT loop.
  `swift-cli/main.swift` is the reference implementation (413 lines including WAV parsing and
  segmentation; the decode loop itself is ~60 lines).
- **Optimization worth doing in production**: implement the decoder+joint step in plain
  Swift/Accelerate (embedding lookup + 8 small matmuls [320×320, 384×1029] + argmax) instead of
  CoreML dispatch per step. The math is ~2 MFLOP/step; the 0.16 ms/step cost is pure MLModel dispatch
  overhead. Expected decode-loop speedup 5–10×, cutting RTF from 0.0035 to well under 0.001 —
  alternatively keep CoreML (280× realtime is already far beyond need for a menu-bar counter).
- The fused `DecoderJoint` is the right CoreML contract if staying with CoreML (one dispatch/step;
  mobius measured 1.2–1.3× vs separate decoder+joint for the same reasons).
- **Encoder size reduction**: fp16 encoder is 121 MB. mobius' `quantize_coreml.py` recipes
  (int8 per-channel or 8-bit palettization) would halve it with minimal quality loss — documented
  quality ≈0.96–0.99 for the 0.6B model. Not needed for correctness; do it if the app bundle size
  matters. The int8 ONNX encoder in the HF repo is evidence the architecture tolerates int8.

## 9. Caveats / non-goals

- Fixed 15 s window: segments longer than 15 s must be chunked (production: VAD segmenter with the
  Sabbih-style 15 s cap anyway). Encoder compute is constant-cost per window regardless of speech
  length — fine at this model size (4.5 ms).
- fp16 encoder conversion emitted a benign `overflow encountered in cast` warning (constant range
  analysis on the `-inf` attention mask); validated: no NaNs in outputs, cosine 0.999985, transcripts
  bit-identical to fp32 on all corpus files.
- The preprocessor's matmul-DFT deviates up to ~0.1 in the log-mel domain only in near-zero-energy
  bins (fp32 rounding amplified by log); mean deviation 2.4e-5, encoder-level effect ≤ 9.3e-5,
  zero observable transcript impact.
- No quantization, no streaming/chunked encoder, no VAD — all out of scope for this spike.
- torch 2.15 is newer than coremltools 9.0's tested range (2.7) but everything converted and validated.

## 10. Transcript outputs (verbatim, fp16 encoder)

**slow10.wav** (17.97 s):
```
سبحان الله سبحان الله سبحان الله سبحان الله سبحان الله سبحان الله سبحان الله سبحان الله سبحان الله سبحان الله
```

**fast33.wav** (37.73 s): 33 repetitions of سبحان الله (verbatim in results/fast33.json)

**mixed34.wav** (48.91 s):
```
سبحان الله (×11) الحمد لله (×11) الله اكبر (×12)
```
full text in results/mixed34.json — ordering exactly matches ground truth.
