#!/bin/bash
# Install dist/LexCockpit.app into /Applications (or ~/Applications).
# Copies WITHOUT extended attributes: dist/ lives on the iCloud-synced
# Desktop, whose file provider stamps xattrs that make a strict
# codesign verify fail on the copy ("detritus not allowed").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/LexCockpit.app"
[ -d "$SRC" ] || { echo "✗ $SRC missing — run scripts/make-app.sh first"; exit 1; }

if [ -w /Applications ]; then DEST="/Applications"; else DEST="$HOME/Applications"; mkdir -p "$DEST"; fi

rm -rf "$DEST/LexCockpit.app"
ditto --noextattr --noqtn "$SRC" "$DEST/LexCockpit.app"
xattr -cr "$DEST/LexCockpit.app" 2>/dev/null || true
codesign --verify --strict "$DEST/LexCockpit.app"
echo "✓ installed $DEST/LexCockpit.app ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/LexCockpit.app/Contents/Info.plist"))"
