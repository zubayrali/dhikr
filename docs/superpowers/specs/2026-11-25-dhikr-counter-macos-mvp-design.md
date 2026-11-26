# Dhikr Counter — macOS MVP design spec

Date: 2026-11-25
Status: approved-by-user-direction (native Swift, macOS-only PoC, personal-use-first)

## 1. Product shape

A macOS menu bar app that counts spoken dhikr repetitions in live sessions, 100% on-device,
zero analytics, zero accounts. Personal-use proof of concept first; multiplatform expansion
(extension/mobile) is explicitly deferred until the PoC is proven by daily use.

**Core loop:** click menu bar icon → pick a guided tasbih set (or single dhikr + target) →
start session → recite → counts update live → target milestones give subtle feedback →
auto-advance through the set. Pause/resume. Unfinished sessions persist and offer resume.
Tap fallback counts through the same pipeline for silent environments.

**Out of scope for MVP:** prayer times, morning/evening adhkar collections, Arabic UI chrome,
cloud sync, auto-detection of which dhikr, ambient always-on listening, any other platform.

## 2. Evidence base (reverse-engineering findings)

Full details in `research/REPORT-sabbih.md` and `research/REPORT-lisanak.md`.

- Sabbih: Nawah-60M Arabic transducer ONNX + Silero VAD + segment-final inference +
  edit-distance multi-match. Exact constants extracted (VAD 0.35/0.5/0.7 thresholds,
  3-frame start, 500ms hangover, 300ms pre-roll, 15s cap; strictness 0.65/0.75/0.85).
- Lisanak: Apple Speech framework, ar-SA, continuous+interimResults, auto-restart loop,
  exact-substring longest-first matching with 21 salawat variants merged to canonical ids,
  fuzzy fallback only when exact count is zero (recall bug). Does NOT use contextualStrings.
- Both confirmed: milestone feedback at 33/66, tap fallback, guided counting are table stakes.
- Normalization table (proven correct in production): NFC, strip Arabic diacritics/tatweel,
  unify hamza/alef variants → ا, alef maqsura/Persian yeh → ي, teh marbuta → ه, Persian kaf → ك,
  waw-hamza → و; strip non-alphanumeric; collapse whitespace; compact form removes spaces.

## 3. Architecture

Single Xcode project (generated with XcodeGen), SwiftUI + MenuBarExtra, target macOS 14+.

```
DhikrApp/                    # the app shell (thin)
  MenuBarView, SessionView, HistoryView, Settings
DhikrCore/ (Swift package)   # all logic, fully testable headless
  Recognition/               # Recognizer protocol + backends
    Recognizer.swift         # protocol: events stream of transcripts (partial/final)
    AppleSpeechBackend.swift # SFSpeechRecognizer, ar-SA, contextualStrings, on-device
    # future: NawahONNXBackend (ort/sherpa-onnx swift bindings)
  Matching/
    Normalize.swift          # exact normalization table from RE
    Matcher.swift            # compact multi-occurrence matcher, dual scoring
    SalawatVariants.swift    # canonicalization map
  Session/
    SessionEngine.swift      # counting state machine: sets, targets, pause/resume
    DhikrLibrary.swift       # default adhkar + sets
  Store/
    Persistence.swift        # GRDB/SQLite or SwiftData — sessions, history, streaks
eval/                        # corpus + replay harness (debug builds)
  corpus/                    # wav files, labeled counts (oracle-assisted)
```

**Backend seam:** recognition is behind `protocol Recognizer`. Apple Speech is the MVP
backend. Nawah-ONNX is the fallback if dogfooding shows accuracy problems. The seam is the
only multiplatform-expensive decision preserved.

## 4. Counting pipeline (the product IP)

```
SFSpeechAudioBufferRecognitionRequest (streaming partials, ar-SA,
  requiresOnDeviceRecognition=true, contextualStrings=active dhikr forms)
  → partial transcripts stream in real time
  → normalize (RE-proven table) → compact (remove spaces)
  → dual scoring ALWAYS: exact substring count + DP edit-distance fuzzy matches
  → length-aware similarity threshold (fixes short-phrase fragility)
  → salawat variant canonicalization
  → monotonic reconciliation: cumulative confirmed count never decreases;
    matches confirmed once past stable transcript region
  → repetition events → session engine → UI + haptic/sound feedback at 33/66/target
```

Milestone feedback triggers on threshold CROSSING (fixes Lisanak's exact-hit miss bug).

## 5. Validation plan

Spike before scaffolding (this is the only gate):
1. Generate test audio: macOS `say` Arabic voices reciting tasbih at varying speeds,
   plus user-recorded real recitation samples.
2. Swift CLI script: run SFSpeechRecognizer on audio with ar-SA, verify:
   a. `requiresOnDeviceRecognition` is supported for ar-SA on this macOS version
      (if not → privacy requires Nawah backend instead; decision point)
   b. transcription accuracy on fast/mumbled tasbih — measured by count accuracy
      of the RE-derived matcher on its output (target: ≥95% counts correct at natural speed)
3. If pass → scaffold app. If marginal → add contextualStrings test. If fail → Nawah backend.

## 6. Milestones

- M0: spike validation (hours, not days)
- M1: vertical slice — mic → recognize → count visible in menu bar panel (one dhikr)
- M2: session engine — guided sets, targets, auto-advance, tap fallback, pause/resume
- M3: polish for daily use — resume flow, reminders, history/streaks, milestones feedback
- M4: one week dogfood by the user; retrospective decides v2 (Nawah backend? prayer times?
  Arabic UI? multiplatform engine extraction?)

## 7. Constraints & non-negotiables

- 100% on-device. If Apple Speech can't do ar-SA on-device, it is disqualified regardless
  of accuracy. No analytics SDKs at all. Network use: none (zero — not even model download
  for the Apple backend).
- Open items: Nawah license (none declared) — only relevant if we adopt that backend.
- Reference apps for shell patterns (mic capture, menu bar, hotkeys, permissions):
  github.com/matthartman/ghost-pepper, altic-dev/FluidVoice, Beingpax/VoiceInk, and others
  listed by the user — mined during implementation, not copied wholesale.
