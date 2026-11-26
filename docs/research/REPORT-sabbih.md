# Sabbih (سبّح) reverse-engineering report

Target: `research/sabbih/Payload/Sabbih.app/`, bundle id `ca.kand.sabbih`, version 1.0.0 (build 3), extracted October 2025/2026-era App Store build.

## 0. Executive summary

Sabbih is **not Whisper-based** and does not use transformers.js for its ASR. It is an Expo/React Native app that downloads a custom Arabic **Nawah ASR 60M Parakeet/TDT transducer** from Hugging Face and executes it fully on-device with `onnxruntime-react-native`.

The production pipeline is:

1. Capture microphone PCM at **16 kHz, mono, float32**, in **100 ms** callbacks using `@siteed/audio-studio`.
2. Buffer samples and cut them into **512-sample / 32 ms** frames.
3. Run the bundled **Silero VAD ONNX** model on each frame, preserving a 64-sample rolling context and an LSTM state.
4. Segment speech with a finite-state segmenter: default threshold 0.5, 3 consecutive voiced frames to start, 500 ms hangover, 300 ms pre-roll, 250 ms minimum segment, 15 s maximum segment.
5. When a segment closes, compute a custom JavaScript implementation of Kaldi-style **128-bin fbank** features (25 ms window, 10 ms shift, Povey window, pre-emphasis 0.97, input scaled by 32768).
6. Run the downloaded `encoder.int8.onnx` once per segment, then greedy TDT decoding using `decoder.onnx` + `joiner.onnx` frame by frame.
7. Concatenate BPE pieces from `config.json`'s `id_to_token`, replace the SentencePiece-style `▁` marker with spaces, normalize whitespace.
8. Normalize Arabic aggressively, compact it by removing spaces, then use an edit-distance/alignment search to find **multiple non-overlapping fuzzy occurrences** of each enabled dhikr in one transcript. Each accepted occurrence calls `countDhikr` once.
9. There is no timestamped cooldown or duplicate suppression beyond the non-overlapping region search. Repetitions in one breath are intentionally counted as separate matches.

The matching strictness and VAD sensitivity are separate settings:

- recognition strictness: `low=0.65`, `medium=0.75`, `high=0.85` similarity
- VAD sensitivity: `low=0.70`, `medium=0.50`, `high=0.35` voice probability threshold

There is **no paywall, account system, ads, analytics SDK, streak system, or historical statistics system** visible in this build. State is a small persisted Zustand store (`tasbih-store`) containing adhkar, counts, current selection, mode, language, strictness, VAD sensitivity, haptics, transcript visibility, and setup completion.

---

## 1. Evidence and methodology

### 1.1 Artifacts produced during analysis

I disassembled the Hermes v98 `main.jsbundle` twice:

- `research/sabbih-hasm/` — initial `hbctool-cli` v0.18 output. Useful for the decoded Unicode string table, but its v98 instruction decode is misaligned in complex functions.
- `research/sabbih-tasm/` — correct disassembly using Talaria (`facebook/hermes@hermes-v250829098.0.10` metadata). This output has correct labels/control flow and Metro module hints.
- `research/sabbih-tasm/functions.tasm` — full correct disassembly.
- `research/sabbih-tasm-functions/` — one file per function.
- `research/decode_literals.py` — local helper written for this analysis to decode Hermes serialized object/array literals.

Important line anchors in `research/sabbih-tasm/functions.tasm`:

- store / thresholds module: line 101141 (`fn@1130`)
- default adhkar module: line 103845 (`fn@1168`)
- model download module: line 110102 (`fn@1260`)
- Silero VAD module: line 111547 (`fn@1279`)
- transcriber factory module: line 111620 (`fn@1280`)
- fbank implementation module: line 111657 (`fn@1281`)
- matcher module: line 111928 (`fn@1284`)
- Arabic normalization module: line 111967 (`fn@1285`)
- counting module: line 112034 (`fn@1286`)
- segmenter module: line 112367 (`fn@1290`)
- `useAutoCounter`: line 404434 (`fn@7445`)
- `findMatches`: line 426878 (`fn@7955`)
- `normalizeArabic`: line 427016 (`fn@7956`)
- `countDhikr`: line 427123 (`fn@7959`)
- segment emission: line 427635 (`fn@7978`)
- transcriber construction: line 659031 (`fn@12599`)
- segment frame state machine: line 660205 (`fn@12608`)
- auto-listen startup: line 671693 (`fn@12845`)
- greedy TDT transcription: line 685714 (`fn@13059`)
- audio stream callback: line 687847 (`fn@13083`)

### 1.2 Bundle/framework facts

From `EXConstants.bundle/app.config`:

- Expo SDK `57.0.0`
- platforms declared: iOS, Android, Web
- React Compiler and typed routes enabled
- plugins include:
  - `expo-router`
  - `expo-sqlite`
  - `expo-asset`
  - `onnxruntime-react-native`
  - `@siteed/audio-studio`
  - `expo-localization`
- Android permissions list only `android.permission.RECORD_AUDIO`; several permissions are explicitly blocked.
- URL schemes: `sabbih`, `ca.kand.sabbih`, `exp+sabbih`
- iOS minimum version 16.4; iPhone-only (`UIDeviceFamily=1`).

The Hermes bytecode is version 98. `main.jsbundle` is 3,356,319 bytes and contains 13,100 functions and 14,788 strings.

---

## 2. Recognition pipeline

## 2.1 Downloaded ASR model

The exact base URL embedded in the bundle is:

```text
https://huggingface.co/oddadmix/Nawah-ASR-60M-Max-Arabic-ONNX/resolve/main
```

Evidence: `s@5444`, loaded in module `fn@1260` (`functions.tasm:110102`).

The app downloads exactly four files into a local Expo FileSystem directory constructed as:

```text
<Paths.document>/nawah/models
```

Evidence: `modelDir` (`fn@7792`) and `modelFile` (`fn@7793`) construct `new Directory(Paths.document, "nawah", "models")` / `new File(dir, name)`.

The exact `MODEL_FILES` entries decoded from Hermes object literals are:

| file | exact byte size used for integrity check |
|---|---:|
| `encoder.int8.onnx` | 61,802,504 |
| `decoder.onnx` | 8,381,676 |
| `joiner.onnx` | 1,585,012 |
| `config.json` | 9,689 |

`MODEL_TOTAL_BYTES` is computed by reducing those sizes:

```text
71,778,881 bytes = 68.45 MiB = 71.78 MB decimal
```

This explains the UI/marketing copy “~72 MB”. `tokenizer_bpe1024.json` is **not** downloaded by the app; the token table is read from `config.json` (`id_to_token`).

`isModelReady` requires every configured file to exist and have the exact expected size. There is UI copy for “Delete model”, “Redownload”, “Download speech model”, “Downloading… {{percent}}%”, “Downloaded · works offline”, and “Wi-Fi recommended”.

### 2.2 Model architecture

The Hugging Face model card for `oddadmix/Nawah-ASR-60M-Max-Arabic-ONNX` describes it as:

- 62.7M-parameter Parakeet-style TDT model
- FastConformer encoder
- Arabic ASR
- ONNX export of `oddadmix/Nawah-ASR-60M-Max-Arabic`
- greedy TDT decoding
- 1024-unit BPE vocabulary plus blank and duration outputs

Its documented graph signatures are:

```text
encoder:  features [1, 128, T] float32 -> encoded [1, ceil(T/8), 384]
decoder:  token [1,1] int64, h [2,1,320], c [2,1,320]
          -> pred [1,384], h_out, c_out
joiner:   enc [1,384], pred [1,384]
          -> logits [1,1029]
```

The 1029 outputs are a 1024-token vocabulary followed by five TDT duration logits corresponding to durations `[0,1,2,3,4]`.

The app’s code reads these fields from downloaded `config.json`:

- `blank_id`
- `durations`
- `joint_dim`
- `max_symbols_per_frame`
- `pred_layers`
- `pred_hidden`
- `id_to_token`

It creates the three inference sessions in parallel with `Promise.all`:

```text
InferenceSession.create(encoder, options)
InferenceSession.create(decoder, options)
InferenceSession.create(joiner, options)
```

Evidence: `fn@12599` (`functions.tasm:659031`).

### 2.3 ONNX runtime/library reality

The app uses the ONNX Runtime React Native JS API:

- plugin `onnxruntime-react-native` in app config
- symbols `OnnxruntimeBackend`, `OnnxruntimeSessionHandler`, `InferenceSession`, `Tensor`, `OrtApi`
- sessions are created through `ort.InferenceSession.create`

I found no Whisper names, no transformers.js pipeline/tokenizer/runtime names, and no Whisper encoder/decoder cross-attention structure. Strings such as `computeMelSpectrogramWasm` and `AudioWorklet` come mostly from `@siteed/audio-studio`; they should not be interpreted as transformer inference. The ASR fbank implementation used by the recognition path is custom JavaScript/FFT in app code, not transformers.js.

### 2.4 Audio capture

Auto mode starts recording with a decoded configuration equivalent to:

```js
{
  sampleRate: 16000,
  channels: 1,
  encoding: "pcm_32bit",
  streamFormat: "float32",
  interval: 100,
  output: { primary: { enabled: false } },
  onAudioStream: ...
}
```

Evidence: object literals at `fn@12845` (`functions.tasm:671693`), especially shape 2045.

Thus audio callbacks carry up to 1,600 float samples every 100 ms. No compressed recording output is enabled; this is streaming PCM for analysis, not a persisted recording.

The stream handler serializes work by chaining a promise (`slot6.current`) and pushes each `Float32Array` into the segmenter (`fn@13083` and `fn@13096`). This avoids concurrent mutation/inference overlap. Errors route to the auto-counter error state.

The app also calls `activateKeepAwakeAsync` when auto-listening starts, so the screen stays awake during listening.

### 2.5 Silero VAD model and frame shape

Only one model is bundled in the app binary:

```text
assets/assets/models/silero_vad.onnx
```

Its ONNX metadata, measured locally:

- IR version 10
- opset 16
- inputs:
  - `input`, dynamic shape, float32
  - `state`, shape `[2, dynamic, 128]`, float32
  - `sr`, scalar int64
- outputs:
  - `output`
  - `stateN`

The app-level constants in `fn@1279` are:

```text
VAD_FRAME = 512 samples = 32 ms at 16 kHz
context length = 64 samples
state tensor shape = [2,1,128]
state element count = 256
input tensor shape = [1,576]
```

For every frame the app:

1. copies the previous 64-sample context into the start of a 576-sample input buffer;
2. copies the new 512-sample frame after it;
3. creates tensors `{input, state, sr}`;
4. invokes `session.run`;
5. stores returned `stateN` as the next `state`;
6. copies the tail of the model input into `context`;
7. returns `output.data[0]` as the speech probability.

Evidence: `fn@12597` (`?anon_0_process`) and `fn@7943`/`fn@7944`.

The constructor creates a scalar `sr` tensor as int64. The big-int table confirms the sample-rate tensor representation; the surrounding capture configuration is 16,000 Hz.

### 2.6 Speech segmentation state machine

Default segmenter object decoded exactly:

```js
{
  threshold: 0.5,
  startFrames: 3,
  hangoverMs: 500,
  preRollMs: 300,
  maxSegmentMs: 15000,
  minSegmentMs: 250
}
```

Evidence: `DEFAULT_SEGMENTER` object in `fn@1290` (`functions.tasm:112367`).

`msToFrames(ms)` is:

```js
max(1, round(ms * 16000 / 1000 / VAD_FRAME))
```

Therefore approximate/default frame counts are:

| parameter | exact frames at 16 kHz / 32 ms |
|---|---:|
| `hangoverMs=500` | 16 frames |
| `preRollMs=300` | 9 frames |
| `maxSegmentMs=15000` | 469 frames |
| `minSegmentMs=250` | 8 frames |

The sample buffering logic:

- incoming arbitrary-sized audio chunks are appended to `pending`;
- complete 512-sample slices are peeled off and passed through VAD;
- leftover samples remain in `pending` (`fn@12607`).

The speech state machine (`fn@12608`) is:

**Before speech**

- append each frame to a rolling `preRoll` array;
- retain enough frames for `preRollMs` plus `startFrames` (here 9+3 frames);
- increment `voicedRun` only when probability ≥ threshold;
- once `voicedRun >= startFrames` (3 frames, ~96 ms):
  - `inSpeech=true`
  - `silentRun=0`
  - `segment = preRoll`
  - clear `preRoll`
  - invoke `onSpeechChange(true)` if present.

On an unvoiced frame `voicedRun` is reset to zero, so the 3-frame start condition is genuinely consecutive voiced frames (about 96 ms), not merely cumulative probability mass.

**During speech**

- append each frame to `segment`;
- if probability is below threshold, increment `silentRun`; otherwise reset it to zero;
- if `silentRun >= msToFrames(hangoverMs)` (16 frames / ~500 ms), close the segment;
- independently, once segment length reaches `msToFrames(maxSegmentMs)` (~15 s), emit the segment immediately without waiting for silence.

**Emission** (`fn@7978`, `functions.tasm:427635`):

- concatenate all 512-sample frames into one `Float32Array`;
- discard the segment if shorter than `minSegmentMs` (250 ms);
- otherwise invoke `onSegment(float32Audio)`;
- clear the active segment;
- `close()` marks `inSpeech=false`, resets `voicedRun`, and invokes `onSpeechChange(false)`.

There is no overlapping sliding-window ASR. Recognition is triggered only when a segment is emitted/closed. Consequently the UI states move through listening → speaking → processing/recognizing rather than streaming partial token-by-token transcription. I found no partial-result merge/deduplication logic because there are no partial ASR hypotheses.

### 2.7 fbank feature extraction

The ASR feature code is in module `fn@1281` (`functions.tasm:111657`) and function `fbank` `fn@7948`.

Exact constants:

```text
sample window = 400 samples      (25 ms at 16 kHz)
frame shift   = 160 samples      (10 ms)
FFT size      = 512
mel bins      = 128
pre-emphasis  = 0.97
PCM scale     = 32768
log floor     = 1.1920928955078125e-07  (2^-23)
```

Frame count is computed as:

```js
floor((sampleCount + 80) / 160)
```

The `+80` is consistent with Kaldi’s `snip_edges=false` padding behavior.

Per frame:

1. reflect-pad/center the window using the same edge-repeat logic seen in the bytecode;
2. multiply input samples by 32768;
3. subtract the window mean;
4. apply pre-emphasis coefficient 0.97;
5. apply a Povey-like window computed as `pow(0.5 - 0.5*cos(2πn/399), 0.85)`;
6. run a custom radix-2 FFT (`FFT` size 512);
7. compute power spectrum over 256 bins;
8. apply 128 triangular mel filters constructed in JS;
9. write `log(max(filterEnergy, 2^-23))` into a row-major `[frame][mel]` `Float32Array`.

The filter bank construction uses constants consistent with Kaldi fbank, including:

- mel scale coefficient 1127
- low frequency 20 Hz and high frequency 8000 Hz, derived from the encoded `log(1+f/700)*1127` and 31.25 Hz bin-width math
- 129 mel points for 128 filters
- 256 power bins

The output object shape is `{ data, numFrames }`. `numFrames` is later used to create the encoder input time dimension.

This is a custom implementation, not the `@siteed` mel WASM helper, even though `@siteed`’s mel WASM string is present elsewhere in the dependency code.

### 2.8 Greedy TDT decoding

`createTranscriber` loads encoder, decoder, and joiner sessions and initializes persistent decoder state:

- initial token = `blank_id`
- hidden and cell tensors are zero-filled `Float32Array(pred_layers * pred_hidden)`
- shape `[pred_layers, 1, pred_hidden]`
- encoder output time length read from `encoded.dims[1]`
- per-frame encoder stride is `joint_dim` (384 per model card)

For each encoded frame:

1. slice `joint_dim` floats for that frame;
2. build the `enc` tensor;
3. run joiner with `{enc, pred}`;
4. argmax token logits over the vocabulary portion;
5. argmax TDT duration logits over the duration portion;
6. if the winning token is not blank:
   - append token id;
   - run one decoder step with the emitted token and current `h`/`c`;
   - update predictor state and `pred`;
   - cap repeated symbols at `max_symbols_per_frame` as configured;
7. advance time by `max(duration, 1)` when blank, or by the selected duration when a token is emitted (matching the README’s greedy TDT algorithm);
8. stop after the encoded time dimension.

Finally it maps token ids through `config.id_to_token`, joins without separators, replaces `▁` (encoded as Unicode 0x2581; string id 6083 in the bundle) with a normal space, collapses whitespace, and trims.

Evidence: `fn@13059` (`functions.tasm:685714`).

The public model card says this is approximately 55× realtime on four WASM threads in a browser. On iOS this app uses the native ONNX Runtime React Native backend; no explicit thread/execution-provider settings were visible in the small decoded config objects I inspected.

---

## 3. Arabic normalization, matching, and counting

## 3.1 Exact normalization

`normalizeArabic` (`fn@7956`, `functions.tasm:427016`) does:

1. Unicode `NFC` normalization;
2. remove Arabic diacritics/signs/tatweel matching:

   ```text
   [ؐ-ًؚ-ٰٟۖ-ۭـ]
   ```

3. apply this exact character mapping:

   | input | output |
   |---|---|
   | `أ` | `ا` |
   | `إ` | `ا` |
   | `آ` | `ا` |
   | `ٱ` | `ا` |
   | `ٲ` | `ا` |
   | `ى` | `ي` |
   | `ی` | `ي` |
   | `ئ` | `ي` |
   | `ة` | `ه` |
   | `ۃ` | `ه` |
   | `ھ` | `ه` |
   | `ہ` | `ه` |
   | `ؤ` | `و` |
   | `ک` | `ك` |

4. replace characters outside Unicode letters/numbers/whitespace (`[^\p{L}\p{N}\s]`, flags `gu`) with spaces;
5. collapse `\s+` to one space;
6. trim;
7. lowercase.

`compact` performs the same normalization then removes all remaining literal spaces. Matching therefore ignores word spacing entirely after normalization. This is important for connected repetitions such as “سبحان الله سبحان الله”.

### 3.2 Fuzzy multi-occurrence matching

`findMatches(transcript, dhikrList, threshold = 0.75)` (`fn@7955`, `functions.tasm:426878`) works on compact strings:

- compact the transcript;
- map every dhikr to `{id, c: compact(dhikr.text/ar)}`;
- discard empty patterns;
- repeatedly locate approximate occurrences;
- return matches sorted by ascending `start`.

`bestOccurrence` (`fn@7954`) is a dynamic-programming approximate substring matcher:

- rows/columns are sized by needle length + 1;
- it uses insertion/deletion/substitution edit costs;
- it traces back the best alignment start;
- it returns an object with `dist`, `start`, and `end`.

The derived similarity is:

```js
similarity = 1 - dist / needle.length
```

A candidate is accepted if its similarity meets the current strictness threshold. The outer matcher then records the region and searches the remaining non-overlapping portions of the compact transcript, so several repetitions in one utterance can produce several matches. Final result fields include:

```js
{ id, similarity, start, end }
```

and results are sorted by `start`.

Important consequences:

- multiple repetitions in one breath are intentionally counted;
- overlapping duplicate matches are prevented by consuming/excluding matched regions;
- there is no separate time-based cooldown or “same transcript hash” dedupe visible;
- because spaces are removed, the matcher can detect back-to-back repetitions even when ASR emits irregular spacing;
- because normalization converts hamza variants, teh marbuta, alef maqsura, Persian/Urdu yeh/kaf, etc., recognition is robust to common Arabic orthographic variation;
- because strictness is edit-distance over the whole compact target, short phrases are much less tolerant in absolute edits than long phrases. A one-character error in `سبحان الله` is proportionally more costly than in `لا حول ولا قوة إلا بالله`.

### 3.3 Strictness setting

The exact recognition strictness thresholds decoded from `MATCH_THRESHOLDS` are:

```js
{
  low: 0.65,
  medium: 0.75,
  high: 0.85
}
```

The store default is:

```js
strictness: "medium"
```

The UI label copy says (paraphrased): lower accepts more variation; higher avoids false counts. The bundled Arabic UI labels include `مرن` (“lenient/flexible”), `متوازن` (“balanced”), `صارم` (“strict”), plus low/medium/high wording. The keys in storage are `low`, `medium`, `high`.

### 3.4 VAD sensitivity setting

The exact `VAD_THRESHOLDS` object is:

```js
{
  low: 0.70,
  medium: 0.50,
  high: 0.35
}
```

The store default is:

```js
vadSensitivity: "medium"
```

This is not a match threshold. It directly overrides the segmenter’s VAD probability threshold (`setThreshold` and construction options). Higher sensitivity means a lower probability threshold and therefore more noise/quiet speech is treated as voiced. Lower sensitivity requires stronger VAD confidence and may miss soft speech but reduces noise-triggered segments.

The user-mentioned `settings.voiceSensitivity.noisy.label` is consistent with this separate voice activity sensitivity control; the underlying persisted values are still `low`/`medium`/`high`.

### 3.5 Count increment and feedback

`countDhikr(id)` (`fn@7959`, `functions.tasm:427123`):

1. reads `useTasbihStore.getState()`;
2. finds the dhikr by id;
3. computes the new count as `(counts[id] ?? 0) + 1` in effect;
4. invokes the store’s `increment(id)`;
5. if haptics are enabled:
   - normally calls `Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light)`;
   - when `newCount % target === 0` and target > 0, calls `Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)`.

The logic in the bytecode is slightly convoluted, but the branch clearly distinguishes target completion using modulo and gives a success notification rather than the light impact.

No sound effect asset or audio playback path is present. Feedback is haptic/visual only.

---

## 4. Dhikr/content library

Exact decoded `DEFAULT_ADHKAR` entries:

| id | Arabic | English/transliteration | target | enabled | builtin |
|---|---|---|---:|---|---|
| `subhanallah` | `سبحان الله` | `SubhanAllah` | 33 | true | true |
| `alhamdulillah` | `الحمد لله` | `Alhamdulillah` | 33 | true | true |
| `allahuakbar` | `الله أكبر` | `Allahu Akbar` | 34 | true | true |
| `tahlil` | `لا إله إلا الله` | `La ilaha illa Allah` | 100 | true | true |
| `istighfar` | `أستغفر الله` | `Astaghfirullah` | 100 | true | true |
| `subhanallah-wabihamdih` | `سبحان الله وبحمده` | `SubhanAllahi wa bihamdih` | 100 | true | true |
| `subhanallah-alazim` | `سبحان الله العظيم` | `SubhanAllahil 'Azim` | 100 | true | true |
| `hawqala` | `لا حول ولا قوة إلا بالله` | `La hawla wa la quwwata illa billah` | 100 | true | true |
| `salawat` | `اللهم صل على محمد` | `Allahumma salli 'ala Muhammad` | 100 | true | true |

Evidence: module `fn@1168` (`functions.tasm:103845`) and decoded Hermes literals.

There is no larger preset library or categorized morning/evening adhkar collection in the binary. Users can add custom adhkar; UI copy says the Arabic text is used for recognition and the English/transliteration name is optional.

---

## 5. State, persistence, stats, and streaks

The Zustand persisted store is named:

```text
tasbih-store
```

Persist config decoded as:

```js
{
  name: "tasbih-store",
  version: 1,
  storage: createJSONStorage(...)
}
```

The initial/decoded state shape is:

```js
{
  adhkar: DEFAULT_ADHKAR,
  counts: {},
  currentId: DEFAULT_ADHKAR[0].id,
  mode: "manual",
  lang: deviceLang(),
  strictness: "medium",
  vadSensitivity: "medium",
  haptics: true,
  showTranscript: true,
  setupSeen: false,
  increment, reset, resetAll, select, setMode,
  updateDhikr, addDhikr, removeDhikr, setSettings
}
```

The custom storage adapter exposes synchronous `getItemSync`, `setItemSync`, and `removeItemSync`, consistent with Expo SQLite key-value storage rather than a server or cloud sync.

There are simple per-dhikr cumulative counts and reset actions, but I found no implementation of:

- calendar-aware streaks;
- daily/weekly statistics;
- charts or history;
- session records;
- leaderboards;
- cloud backup.

Ionicons contains generic `stats-chart` glyph names because the whole icon font is bundled; that is not evidence of a stats feature.

---

## 6. UX/navigation architecture

Route source filenames embedded in the bundle:

```text
./_layout.tsx
./index.tsx
./dhikr.tsx
./settings.tsx
./setup.tsx
```

Thus the route structure is effectively:

- `/` — main counter screen (`CounterScreen`)
- `/dhikr` — dhikr list/edit selection screen (`DhikrScreen`, `DhikrRow`, `DhikrChips`)
- `/settings` — settings screen (`SettingsScreen`)
- `/setup` — first-run/setup/model onboarding (`SetupScreen`)

Major components/functions visible:

- `CounterScreen`
- `CounterRing`
- `ListenPanel`
- `useAutoCounter`
- `DhikrScreen`
- `DhikrRow`
- `DhikrChips`
- `SettingsScreen`
- `SetupScreen`
- `Segmented`
- `Section`

Observed UI states/copy include:

- `idle`
- `listening`
- `speaking`
- `processing`
- `loading`
- `denied`
- `error`
- `Hearing you…`
- `Listening…`
- `Recognizing…`
- `Loading model…`
- `Tap microphone to start` / `Start listening` / `Stop listening`
- `Tap to count`
- `Show heard text`
- `Heard`
- `No dhikr recognized`
- `No enabled tasbih; add from the list`
- `Auto mode needs the speech model (one-time download)`
- `Not now (manual mode only)`

Manual mode is a first-class fallback: tapping the ring calls the same `countDhikr` path and therefore receives the same target/haptic feedback. Auto mode and manual mode are persisted in the `mode` setting.

The app disables background audio in the `@siteed/audio-studio` plugin config:

```js
enablePhoneStateHandling: false
enableNotifications: false
enableBackgroundAudio: false
enableDeviceDetection: false
```

So listening is foreground-only.

---

## 7. Monetization and business logic

No monetization implementation was found.

Specifically absent from the bundle and native dependency list:

- RevenueCat / `react-native-purchases`
- StoreKit/in-app purchase modules
- AdMob/Firebase/ad SDKs
- subscription/paywall screens
- pricing strings other than generic Ionicons glyph names containing “pricetag”
- account/login/session backend code

All recognition functionality appears free after downloading the model. Nothing obvious is gated. The only network dependency is the one-time Hugging Face model download.

---

## 8. Privacy reality check

### 8.1 Declared privacy manifest

`PrivacyInfo.xcprivacy` at the app root declares:

```text
NSPrivacyTracking = false
NSPrivacyCollectedDataTypes = []  (empty)
```

Accessed API categories:

- User Defaults, reason `CA92.1`
- System Boot Time, reason `35F9.1`
- File Timestamp, reason `C617.1`

These are consistent with Expo/React Native/local storage/file operations rather than analytics.

### 8.2 Microphone copy

`Info.plist` microphone purpose string:

> “Sabbih listens to your dhikr on-device to count it automatically. Audio never leaves your phone.”

Arabic localized copy says the same.

### 8.3 Network endpoints found

The only product-relevant remote endpoint in the JavaScript string table is the Hugging Face model URL. Other URLs are documentation/error-message URLs, Expo/React Native references, localhost development strings, the jsDelivr prefix used by `@siteed/audio-studio` for web assets, and `classic-assets.eascdn.net` for bundled asset resolution.

I found no analytics endpoint, crash-reporting endpoint, Sentry DSN, Firebase config, Amplitude/Mixpanel/PostHog keys, or custom telemetry domain.

### 8.4 Audio retention

The decoded recording configuration disables primary/compressed output. PCM chunks exist only as in-memory typed arrays for VAD/ASR. Segments are typed arrays passed to transcription and then eligible for garbage collection. There is no evidence of writing microphone audio to disk.

The `showTranscript` option controls display of recognized text. Transcripts do not appear to be persisted as history; only counts/state are persisted.

The privacy claims are therefore broadly consistent with the static binary evidence, with the caveat that the Hugging Face download necessarily connects to Hugging Face/CDN infrastructure once and can reveal IP-level download metadata to that service.

---

## 9. Notable implementation details and weaknesses relevant to competitors

1. **Model choice is the biggest differentiator.** Nawah 60M is purpose-built for Arabic and much smaller than a general Whisper deployment. The int8 encoder is ~62 MB and the total runtime payload is ~72 MB.
2. **No streaming partial ASR.** Recognition is segment-final. This simplifies dedupe but adds latency after the user stops speaking. A competitor can improve perceived responsiveness with incremental partials or a second fast pass.
3. **Matching is transcript post-processing.** ASR does not constrain/bias decoding toward enabled adhkar. The fuzzy matcher fixes ASR variation afterward. A grammar/language-model biasing or keyword spotting approach could outperform it for known phrases.
4. **Spaces are removed before matching.** This helps repetitions but could create false positives across word boundaries. Their edit-region algorithm mitigates but does not eliminate this risk.
5. **No time-based double-count cooldown.** Non-overlapping regions are the only dedupe. Repeated segments separated by silence are new speech events and are counted independently by design.
6. **Short phrases are fragile.** Similarity is normalized by compact target length. A single insertion/deletion/substitution in a short phrase can cause misses at `high` strictness. Competitors should consider per-phrase length-aware thresholds.
7. **Segmentation controls false triggers more than strictness does.** VAD sensitivity is separate from recognition strictness, a good product decomposition worth copying.
8. **Everything is local after download.** No server cost or account complexity. The tradeoff is large initial download, device compute, and inability to improve the model server-side without client updates/download updates.
9. **Foreground-only listening.** No background task or lock-screen continuation is configured. This is a UX limitation and a privacy-positive simplification.
10. **No historical analytics.** A competitor can differentiate with privacy-preserving local statistics, streaks, and optional cloud sync, but that would move beyond Sabbih’s minimal-data posture.
11. **Model integrity check is exact file size only.** No embedded SHA-256/signature validation was evident. Size checks catch partial downloads but are not strong supply-chain integrity validation.
12. **The original tokenizer file is unnecessary.** `config.json` carries `id_to_token`, reducing the download slightly and simplifying runtime.
13. **Feature extraction is CPU JavaScript.** The custom fbank implementation is straightforward but not SIMD/GPU optimized. For 15 s segments this is probably small compared with encoder inference, but a competitor could move it into native code or reuse an optimized feature pipeline.
14. **Potential edge case:** exact-size file validation can fail if Hugging Face updates any file in place. Pinning a revision hash would be more robust than `resolve/main` for production.

---

## 10. Concise architecture diagram

```text
Microphone
  │  @siteed/audio-studio, 16 kHz mono float32, 100 ms callbacks
  ▼
pending sample buffer
  │  split into 512-sample frames
  ▼
Silero VAD ONNX (input 576 = 64 context + 512 frame, state [2,1,128])
  │ speech probability per 32 ms frame
  ▼
Segmenter (start 3 frames, pre-roll 300 ms, hangover 500 ms,
           min 250 ms, max 15 s)
  │ complete speech segment Float32Array
  ▼
custom Kaldi-style fbank JS (400/160 samples, FFT 512, 128 mel)
  │ features [1,128,T]
  ▼
encoder.int8.onnx ──► encoded [1,ceil(T/8),384]
                         │
                         ▼
        greedy TDT loop: joiner(enc,pred) → token/duration
                         │ token emissions update decoder.onnx LSTM
                         ▼
                 Arabic transcript string
                         │
                         ▼
normalize Arabic → compact/no spaces → fuzzy multi-occurrence edit matching
                         │
                         ▼
       countDhikr once per accepted non-overlapping occurrence
                         │
                         ▼
       Zustand persisted counts + light/success haptics
```

---

## 11. Confidence notes

High confidence:

- exact model URL/files/sizes;
- use of `onnxruntime-react-native`;
- audio capture constants;
- VAD frame/context/state constants;
- segmenter constants and thresholds;
- normalization map and strictness values;
- default adhkar table;
- no paywall/analytics/account system in static evidence.

Medium confidence:

- precise control-flow subtleties of the custom approximate substring matcher, because the algorithm is optimized generator/loop bytecode. The dynamic-programming edit-distance structure, similarity formula, non-overlapping multi-match behavior, and sorted output are clear; exact tie-breaking is less important and less certain.
- exact ONNX Runtime session execution-provider/thread options. No elaborate settings were evident, but small object literals can hide partially dynamic values.

No target code was executed. Embedded JavaScript/source strings were treated strictly as data.
