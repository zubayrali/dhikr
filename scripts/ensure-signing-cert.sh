#!/bin/bash
# Ensures a stable self-signed code signing identity exists in the login keychain.
# Why: ad-hoc signed apps get a cdhash-based designated requirement, which changes
# on EVERY rebuild — macOS TCC treats each build as a new app and re-prompts for
# microphone permission. A stable cert-leaf requirement keeps the identity constant
# across rebuilds, so mic permission is granted once and persists forever.
# (Same mechanism VoiceInk documents: "ad-hoc builds may require macOS permissions
# again after rebuilding" — a stable signing identity is the answer.)
# Idempotent: safe to run on every build.
set -e
CERT_NAME="Dhikr Development"

have_usable_identity() {
    security find-certificate -c "$CERT_NAME" >/dev/null 2>&1 || return 1
    # find-identity -v -p codesigning rejects untrusted self-signed certs even
    # though they sign fine — the real test is whether codesign accepts it
    echo 'int main(){return 0;}' > /tmp/.dhikr-signtest.c
    clang /tmp/.dhikr-signtest.c -o /tmp/.dhikr-signtest 2>/dev/null
    if codesign --force --sign "$CERT_NAME" /tmp/.dhikr-signtest 2>/dev/null; then
        rm -f /tmp/.dhikr-signtest /tmp/.dhikr-signtest.c
        return 0
    fi
    rm -f /tmp/.dhikr-signtest /tmp/.dhikr-signtest.c
    return 1
}

if have_usable_identity; then
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" << 'CNF'
[ req ]
distinguished_name = dn
[ dn ]
[ codesign_ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$CERT_NAME" \
    -extensions codesign_ext -config "$TMP/openssl.cnf" 2>/dev/null

openssl pkcs12 -export -out "$TMP/sign.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:dhikr-local 2>/dev/null

# -T pre-authorizes codesign/security to use the key without a GUI prompt
security import "$TMP/sign.p12" -P dhikr-local \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

if have_usable_identity; then
    echo "created signing identity: $CERT_NAME"
else
    echo "warning: could not create usable signing identity" >&2
    exit 1
fi
