#!/usr/bin/env bash
set -euo pipefail

# Wraps build/TidyDrive.app in build/TidyDrive.dmg: open it, drag TidyDrive
# onto the Applications shortcut. Signs the disk image when SIGN_IDENTITY is
# a real identity, so it can be notarized and stapled.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO_ROOT/build/TidyDrive.app"
DMG="$REPO_ROOT/build/TidyDrive.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

[[ -d "$APP" ]] || { echo "✗ $APP not found, run scripts/build.sh first"; exit 1; }

echo "→ Staging disk image contents..."
ditto "$APP" "$STAGING/TidyDrive.app"
ln -s /Applications "$STAGING/Applications"

echo "→ Creating $DMG..."
rm -f "$DMG"
hdiutil create -volname "TidyDrive" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    echo "→ Signing disk image with '$SIGN_IDENTITY'..."
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

echo "✓ Built $DMG ($(du -sh "$DMG" | cut -f1))"
