# Dhikr — voice-first tasbih counter (macOS menu bar)

## Project status (MVP in progress)

**Product**: session-based dhikr counter. User starts a session, recites a known dhikr,
the app counts repetitions on-device. Guided tasbih sets (33/33/34), tap fallback,
resume unfinished sessions, streaks, daily reminders. Zero analytics — privacy is a
core differentiator, auditable in the binary.

## Architecture

Single SwiftPM package (no Xcode project), three layers:
- `Sources/DhikrCore` — pure logic, fully tested: normalization, positional fuzzy
  matcher, session state machine, VAD segmenter, frame chunker, JSON store.
  No AVFoundation/CoreML imports — portable.
- `Sources/DhikrApp` — macOS shell: menu bar (LSUIElement), NSPanel UI,
  AudioCapture (AVAudioEngine 16kHz mono float32), NawahRecognizer orchestrator,
  feedback (haptics/sounds), reminders (UNUserNotificationCenter).
- `Tests/DhikrCoreTests` — 39 tests, all passing.

Recognition pipeline: mic → 512-sample frames → VAD score → SpeechSegmenter
(3-frame start, 500ms hangover, 300ms pre-roll, 250ms min, 15s cap) →
SegmentTranscriber → transcript events → matcher counts repetitions.

## Key decisions (do not regress without user sign-off)

- **Apple Speech rejected**: no on-device Arabic on macOS (verified — "No Assistant
  asset for language ar-SA"). Cloud speech violates the privacy non-negotiable.
- **Nawah-60M transducer → CoreML** is the recognition backend. Conversion in
  `eval/nawah-coreml/` (scripts + build/). Model: parakeet-TDT architecture,
  beats Whisper-large on Arabic at 1/25th size. LICENSE NOT DECLARED — fine for
  personal PoC, must contact author before any public distribution.
- **Rust core + UniFFI was the original multiplatform plan** (user-approved early),
  but user pivoted to Swift-native MVP-first ("prove the concept for myself first").
  If the PoC succeeds, the multiplatform question reopens — DhikrCore is written
  to be portable pure-Swift logic in the meantime.
- Matcher design: sequential positional scanning, fixed-start Sellers alignment,
  length-aware thresholds. Sabbih's normalization table exactly. Salawat variants
  canonicalize to one dhikr id.
- Tap mode is mandatory table stakes, same event pipeline as voice.

## Build & verify

```bash
swift test          # 39 tests, must all pass
./build.sh          # produces Dhikr.app (arm64, LSUIElement), signed with the
                    # stable self-signed "Dhikr Development" identity
./build.sh run      # build + launch in menu bar
```

## Signing & TCC (hard-won, do not regress)

NEVER ship ad-hoc signed builds. Ad-hoc signatures produce a cdhash-based
designated requirement that changes on EVERY rebuild — macOS TCC treats each
build as a new app and re-prompts for mic permission. scripts/ensure-signing-cert.sh
(hooked into build.sh, idempotent) creates a self-signed "Dhikr Development"
codesigning cert in the login keychain; the cert-leaf requirement is stable across
rebuilds so mic permission is granted ONCE and persists. VoiceInk documents the
same ("ad-hoc builds may require macOS permissions again after rebuilding").
Detection quirk: `security find-identity -v -p codesigning` REJECTS untrusted
self-signed certs even though they sign fine — test usability with an actual
codesign sign-test, never with find-identity. Cert dedupe: deletion by name fails
when ambiguous — delete by SHA-1 hash (-Z).

## Hard-won: audio capture (do not regress)

AudioCapture uses AVCaptureSession, NOT AVAudioEngine — learned from reference
apps (VoiceInk uses raw CoreAudio units; ambient-voice documents installTap
never fires callbacks on Bluetooth devices). AVAudioEngine config-change resets
throw uncatchable NSExceptions, and restarting capture on Bluetooth renegotiates
HFP which itself fires config changes → restart loop = media-key chaos + dead
audio. Device switching uses the CoreAudio kAudioHardwarePropertyDefaultInputDevice
listener (the honest signal), rebuilds throttled to max once per 3s, debounced 1s.
Note: HFP profile activation when a BT mic starts capture inherently causes one
media pause/duck — that's physics, unavoidable; a LOOP of it is the bug.

## Accuracy workflow (the harness is the product's compass)

eval/harness/build.sh builds pipeline_eval (core+transcriber as one module);
eval/harness/run-corpus.sh validates the synthetic corpus — must stay 7/7.
Real accuracy work: replay session recordings
(~/Library/Application Support/Dhikr/recordings/*.wav) through
./.build/evalharness/pipeline_eval <wav> <dhikrId> and compare COUNT vs actual.

Measured truths from the user's real istighfar-100 session:
- energy VAD noise-floor adaptation is a TRAP: during continuous speech the
  estimate chases speech upward until the floor exceeds the user's voice
- silence ~0.0002 RMS, mumbled speech ~0.005+ — fixed floor 0.002, tight 3x ramp
- hangover 800 + threshold 0.3 >> sabbih defaults for fast continuous recitation
- forced cap cuts must split at quietest frame, never blindly mid-word
- count accuracy journey: 64 → 81/100 on continuous fast recitation
- remaining loss: transcription blur on mumbled speech + coverage gaps.
  Next levers: Silero VAD (neural, sabbih-proven), mid-segment partial passes.

## External knowledge

- `research/REPORT-sabbih.md` — full decode of Sabbih's pipeline (VAD constants,
  normalization table, matching algorithm, Nawah model details). The baseline we beat.
- `research/REPORT-lisanak.md` — Lisanak decode (Apple Speech + exact matching,
  milestone bugs to avoid, salawat variant list).
- `bismillah-menubar/` — MIT-licensed reference for menu bar app structure.

## Currently in flight

Nawah ONNX → CoreML conversion (eval/nawah-coreml/scripts/convert_nawah.py).
When artifacts land: implement NawahCoreMLTranscriber (SegmentTranscriber protocol)
with greedy TDT decode, wire into AppDelegate via attachRecognizer, validate with
real recitation audio. EnergyVAD is a stopgap — upgrade to Silero VAD after
first working voice loop.

## Input device architecture (hard-won, do not regress)

VoiceInk-pattern (reference: research/VoiceInk — clone with git clone --depth 1
https://github.com/Beingpax/VoiceInk.git, key file Infrastructure/Audio/Devices/AudioDeviceManager.swift):

- NEVER rely on AVCaptureDevice.default(for: .audio) — it binds at construction and
  does not follow routing. AudioDeviceManager resolves through CoreAudio (the honest
  source), AudioCapture binds explicitly by UID. Bridge: AVCaptureDevice.uniqueID IS
  the CoreAudio device UID on macOS (verified on real hardware, all devices match).
- Listen to BOTH kAudioHardwarePropertyDevices (connect/disconnect) AND
  kAudioHardwarePropertyDefaultInputDevice (routing) — a BT connect with pinned
  system input fires only the first.
- Earbuds can mint fresh UIDs across reconnects — match by modelUID as fallback.
- Rebuild throttle must RESCHEDULE, never drop (the original bug: capture stuck on
  stale device forever).
- Deadlock trap: CoreAudio listener blocks fire ON the manager queue — never
  queue.sync onto that same queue (use NSLock for shared state).
- VoiceInk matches devices for recording by inputChannels + clamshell state too —
  not ported, overkill for now.
