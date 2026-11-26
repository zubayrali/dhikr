# Releasing Dhikr

## The one prerequisite that cannot be automated

**Apple Developer Program membership ($99/year)** — required for a Developer ID
certificate. Without it, macOS Gatekeeper blocks every downloaded copy with
"cannot be opened because the developer cannot be verified" and there is no
legitimate workaround. Everything else in this document is automated.

## Model permission — RESOLVED ✓

The author of the Nawah ASR model granted explicit permission to bundle the
weights in Dhikr (November 2026). The permission is recorded in NOTICE, which
ships inside the app bundle. Keep the written proof of the permission (the
message/email exchange) somewhere safe — it is the legal evidence.

## One-time setup (~30 min, mostly clicking)

1. **Join the Apple Developer Program**: https://developer.apple.com/programs
2. **Create a Developer ID Application certificate**:
   Xcode → Settings → Accounts → + your Apple ID → Manage Certificates →
   "+" → Developer ID Application. (Or via developer.apple.com/certificates.)
3. **Export the cert as .p12**: Keychain Access → find "Developer ID Application:
   Your Name (TEAMID)" → right-click → Export → .p12 with a password.
4. **Create an App Store Connect API key** (for notarization):
   https://appstoreconnect.apple.com/access/integrations/api → Generate.
   Download AuthKey_XXXXXXXX.p8 (one-shot download!), note the Key ID and Issuer ID.
5. **Set GitHub secrets** (repo → Settings → Secrets and variables → Actions):

   | secret | value |
   |---|---|
   | `DEVELOPER_ID_CERT_P12_BASE64` | `base64 -i cert.p12` output |
   | `DEVELOPER_ID_CERT_PASSWORD` | the p12 password |
   | `KEYCHAIN_PASSWORD` | any random string (CI keychain password) |
   | `SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
   | `NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8` output |
   | `NOTARY_KEY_ID` | the 10-char key id |
   | `NOTARY_ISSUER_ID` | the issuer UUID |

## Cutting a release

```bash
git tag v1.0.0 && git push --tags
```

CI then: runs the full test suite → builds universal → signs with hardened
runtime → notarizes with Apple (~2-10 min) → staples the ticket → packages a DMG
with the Applications drag-link → publishes to GitHub Releases. Users download,
drag to Applications, double-click, and it just opens — no warnings.

## Local release (same pipeline, your machine)

```bash
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARY_KEY=~/keys/AuthKey_XXXX.p8
export NOTARY_KEY_ID=XXXX NOTARY_ISSUER_ID=xxxx-uuid
VERSION=1.0.0 ./scripts/release.sh
```

## Onboarding experience checklist (all already handled)

- Gatekeeper: passes silently — notarized + stapled ✓
- Mic permission: single standard system prompt on first session start;
  NSMicrophoneUsageDescription explains on-device privacy ✓
- TCC identity stability: Developer ID cert is stable across versions, so the
  mic grant survives app updates ✓
- Universal binary: one download for both Apple Silicon and Intel ✓
- Menu-bar-only app (LSUIElement): no dock confusion ✓
