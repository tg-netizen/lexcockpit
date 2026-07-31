#!/bin/bash
# Assemble a distributable LexCockpit.app from the SwiftPM build.
# Usage: bash scripts/make-app.sh [version]
# Keep the default in sync with AppVersion.fallback (UpdateCheck.swift);
# release.yml overrides it with the pushed tag.
set -euo pipefail

VERSION="${1:-0.24.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "── Building release binary…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

# Assemble + sign in a PRIVATE temp dir. On iCloud-synced folders (like
# ~/Desktop) the file provider keeps stamping extended attributes that make
# codesign fail with "resource fork, Finder information, or similar
# detritus not allowed" — /tmp is outside any file-provider domain.
STAGE="$(mktemp -d /tmp/lexcockpit-app.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/LexCockpit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ditto --noextattr --noqtn "$BIN/LexCockpit" "$APP/Contents/MacOS/LexCockpit"

# SwiftPM resource bundle (bundled projects.json) — Bundle.module finds it
# in Contents/Resources next to the executable's expectations.
if [ -d "$BIN/LexCockpit_LexCockpit.bundle" ]; then
  ditto --noextattr --noqtn "$BIN/LexCockpit_LexCockpit.bundle" "$APP/Contents/Resources/LexCockpit_LexCockpit.bundle"
fi

sed "s/__VERSION__/$VERSION/g" "$ROOT/scripts/Info.plist" > "$APP/Contents/Info.plist"

# App icon (generate on the fly if missing — e.g. on a fresh CI runner)
if [ ! -f "$ROOT/scripts/AppIcon.icns" ]; then
  echo "── Generating AppIcon.icns…"
  swift "$ROOT/scripts/make-icon.swift"
fi
ditto --noextattr --noqtn "$ROOT/scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Prefer the stable "LexCockpit Dev" identity (scripts/make-dev-cert.sh) —
# keeps the signature constant across rebuilds so keychain approvals stick.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'LexCockpit Dev' | head -1 | awk '{print $2}' || true)"
echo "── Codesigning (${IDENTITY:+stable identity}${IDENTITY:-ad-hoc})…"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep -s "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

rm -rf "$ROOT/dist"
mkdir -p "$ROOT/dist"
ditto "$APP" "$ROOT/dist/LexCockpit.app"

echo "── Done: $ROOT/dist/LexCockpit.app (version $VERSION, ${IDENTITY:+stable-identity}${IDENTITY:-ad-hoc} signed)"
