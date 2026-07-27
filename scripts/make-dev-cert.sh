#!/bin/bash
# One-time: create a STABLE self-signed code-signing identity "LexCockpit Dev".
# Ad-hoc signing changes with every rebuild, so macOS keychain treats each
# build as a new app and re-prompts for token access. A stable identity keeps
# the signature constant → "Always Allow" sticks forever.
set -euo pipefail
NAME="LexCockpit Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Identity '$NAME' already exists ✓"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" -passout pass:lexcockpit >/dev/null 2>&1
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P lexcockpit -T /usr/bin/codesign >/dev/null
# Trust for code signing (macOS may ask for your login password ONCE here):
security add-trusted-cert -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"
echo "Identity '$NAME' created ✓ — make-app.sh will use it automatically."
