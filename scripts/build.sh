#!/usr/bin/env bash
set -euo pipefail

# TidyDrive build script.
# Builds the SwiftPM executable, wraps it into a .app bundle with Info.plist,
# and signs it. By default this is an ad-hoc signature (local dev builds).
# Set SIGN_IDENTITY to a "Developer ID Application" identity for release
# builds; that also enables the hardened runtime, required for notarization.

APP_NAME="TidyDrive"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

CONFIGURATION="${CONFIGURATION:-release}"

echo "→ Building SwiftPM executable ($CONFIGURATION)..."
cd "$REPO_ROOT"
swift build -c "$CONFIGURATION" --arch arm64

BIN_PATH="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)"
EXEC_SRC="$BIN_PATH/$APP_NAME"
if [[ ! -f "$EXEC_SRC" ]]; then
    echo "✗ Could not find built executable at $EXEC_SRC"
    exit 1
fi

echo "→ Generating app icon..."
mkdir -p "$BUILD_DIR"
if swift "$REPO_ROOT/scripts/make-icon.swift"; then
    if iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"; then
        echo "✓ AppIcon.icns created"
    else
        echo "⚠ iconutil failed, AppIcon.icns will be missing"
    fi
else
    echo "⚠ make-icon.swift failed, skipping icon generation"
fi

echo "→ Assembling $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RES"
cp "$EXEC_SRC" "$MACOS/$APP_NAME"
cp "$REPO_ROOT/Sources/TidyDrive/Resources/Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$BUILD_DIR/AppIcon.icns" ]]; then
    cp "$BUILD_DIR/AppIcon.icns" "$RES/AppIcon.icns"
    echo "✓ AppIcon.icns copied into bundle"
fi

# Resources the app reads through Bundle.main, inside Contents/Resources so
# code signing seals them (same approach as Loft).
cp "$REPO_ROOT/Sources/TidyDrive/Resources/weteling-logo.svg" "$RES/weteling-logo.svg"
echo "✓ weteling-logo.svg copied into Contents/Resources"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "→ Ad-hoc signing..."
    codesign --force --deep --sign - "$APP_DIR"
else
    echo "→ Signing with '$SIGN_IDENTITY' (hardened runtime)..."
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
fi

echo "→ Removing quarantine flag..."
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

echo "✓ Built $APP_DIR"
echo ""
echo "  Run: open '$APP_DIR'"
echo "  Install: cp -R '$APP_DIR' /Applications/"
