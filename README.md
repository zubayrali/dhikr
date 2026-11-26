# Dhikr — voice-first tasbih counter for macOS

A privacy-first menu bar app that counts your recited adhkar using **fully
on-device** Arabic speech recognition. Start a session, recite naturally,
watch the count rise in your menu bar. Audio never leaves your Mac — no
cloud, no accounts, no analytics.

## Features

- **Voice counting, on-device**: Arabic ASR (Nawah parakeet-TDT, CoreML,
  Neural Engine) — works offline, nothing is uploaded
- **Guided tasbih sets**: 33/33/34 after-prayer sets, istighfar ×100, or any
  single dhikr with a custom target
- **Ambient by design**: the count lives in the menu bar; the panel appears
  when you want it and gets out of the way when you don't
- **Tap fallback**: ring tap or spacebar counting, same session pipeline
- **Device-aware**: follows your input routing, supports pinning a specific
  mic (e.g. earbuds) with automatic fallback
- **Resume unfinished sessions** — progress is never lost

## Download

Grab the latest `Dhikr-x.y.z.dmg` from
[Releases](../../releases), drag to Applications. macOS 14+, Apple Silicon
and Intel (universal binary).

## Privacy

The microphone is used solely for live on-device transcription during active
sessions. There is zero networking in the app — auditable in the source.

## Acknowledgments

- Arabic ASR: [Nawah-Parakeet-60M](https://huggingface.co/oddadmix/Nawah-Parakeet-60M)
  by oddadmix, bundled with the author's explicit permission (see NOTICE)
- Menu bar interaction design inspired by bismillah-menubar (MIT)
- Device-handling architecture informed by VoiceInk (GPL — no code copied)

## Building from source

```bash
./build.sh        # produces Dhikr.app (universal)
swift test        # core logic test suite
```

See RELEASING.md for the signed/notarized distribution pipeline.
