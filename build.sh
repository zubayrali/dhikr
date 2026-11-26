#!/bin/bash
# Builds Dhikr.app (universal, macOS 14+) and signs it with the stable
# self-signed 'Dhikr Development' identity (auto-created) so TCC permissions
# survive rebuilds; falls back to ad-hoc if unavailable.
#   ./build.sh          build
#   ./build.sh run      build and open
set -e
cd "$(dirname "$0")"
# ensure stable signing identity exists (creates once, idempotent) — without it
# mic permission re-prompts on every rebuild
"$(dirname "$0")/scripts/ensure-signing-cert.sh" 2>/dev/null || true
APP=Dhikr.app
VERSION=${VERSION:-0.1.0}

rm -rf "$APP" .build/universal
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build/universal

# universal release build via SwiftPM
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1

BIN=.build/apple/Products/Release/dhikr
if [ ! -f "$BIN" ]; then BIN=$(find .build -name dhikr -type f -path "*Release*" | head -1); fi
cp "$BIN" "$APP/Contents/MacOS/Dhikr"

# CoreML model artifacts (~131MB fp16) — the on-device Arabic ASR brain
MODELS_SRC="eval/nawah-coreml/build/compiled"
if [ -d "$MODELS_SRC" ]; then
  mkdir -p "$APP/Contents/Resources/Models"
  for m in Preprocessor Encoder DecoderJoint; do
    cp -R "$MODELS_SRC/$m.mlmodelc" "$APP/Contents/Resources/Models/"
  done
  cp "$MODELS_SRC/parakeet_vocab.json" "$APP/Contents/Resources/Models/"
  echo "Models bundled"
else
  echo "WARNING: no converted models at $MODELS_SRC — voice recognition unavailable"
fi

# attribution travels inside the distributed binary
[ -f NOTICE ] && cp NOTICE "$APP/Contents/Resources/NOTICE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.dhikr.app</string>
  <key>CFBundleName</key><string>Dhikr</string>
  <key>CFBundleDisplayName</key><string>Dhikr</string>
  <key>CFBundleExecutable</key><string>Dhikr</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Dhikr counts your recited adhkar using on-device speech recognition. Audio never leaves your Mac.</string>
</dict></plist>
PLIST
# signing priority: explicit SIGN_IDENTITY (distribution) > dev cert > ad-hoc.
# distribution builds also pass HARDENED_RUNTIME=1 + entitlements.
SIGN_FLAGS=""
if [ "${HARDENED_RUNTIME:-}" = "1" ]; then
    SIGN_FLAGS="--options runtime --entitlements scripts/entitlements.plist --timestamp"
fi
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$SIGN_IDENTITY" $SIGN_FLAGS "$APP"
elif security find-certificate -c "Dhikr Development" >/dev/null 2>&1; then
    codesign --force --sign "Dhikr Development" $SIGN_FLAGS "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP $VERSION"
if [ "${1:-}" = "run" ]; then open "$APP"; fi
