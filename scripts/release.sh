#!/bin/bash
# Distribution release pipeline: build universal, sign with Developer ID +
# hardened runtime, notarize with Apple, staple the ticket, package a DMG.
#
# Required environment (see RELEASING.md):
#   SIGN_IDENTITY       e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_KEY          path to AuthKey_XXXX.p8   (App Store Connect API key)
#   NOTARY_KEY_ID       the key's ID
#   NOTARY_ISSUER_ID    issuer UUID from App Store Connect
#   VERSION             e.g. 1.0.0  (required)
set -e
cd "$(dirname "$0")/.."

: "${VERSION:?set VERSION, e.g. VERSION=1.0.0}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application cert name}"
: "${NOTARY_KEY:?set NOTARY_KEY to path of AuthKey .p8}"
: "${NOTARY_KEY_ID:?}"
: "${NOTARY_ISSUER_ID:?}"

echo "== building universal =="
HARDENED_RUNTIME=1 ./build.sh

echo "== verifying signature =="
codesign --verify --deep --strict --verbose=2 Dhikr.app
spctl --assess --type execute -vv Dhikr.app 2>&1 || echo "(spctl fails pre-notarization — expected)"

echo "== notarizing =="
rm -f dist/Dhikr-$VERSION.zip
mkdir -p dist
ditto -c -k --keepParent Dhikr.app dist/Dhikr-$VERSION.zip
xcrun notarytool submit dist/Dhikr-$VERSION.zip \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout 20m

echo "== stapling =="
xcrun stapler staple Dhikr.app
xcrun stapler validate Dhikr.app

echo "== packaging DMG =="
rm -rf dist/dmg-root dist/Dhikr-$VERSION.dmg
mkdir -p dist/dmg-root
cp -R Dhikr.app dist/dmg-root/
ln -s /Applications dist/dmg-root/Applications
hdiutil create -volname "Dhikr" -srcfolder dist/dmg-root \
    -ov -format UDZO dist/Dhikr-$VERSION.dmg
rm -rf dist/dmg-root dist/Dhikr-$VERSION.zip

echo "== final gatekeeper check =="
spctl --assess --type execute -vv Dhikr.app && echo "GATEKEEPER: PASS"

echo "RELEASE READY: dist/Dhikr-$VERSION.dmg"
