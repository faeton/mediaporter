#!/usr/bin/env bash
# Assemble MediaPorter.app around the SwiftPM release build.
#
# Output: build/MediaPorter.app (unsigned). Run scripts/release.sh next to
# sign, notarize, staple, and DMG.
#
# Usage: ./scripts/build-app.sh [short-version] [build-number]
#   e.g. ./scripts/build-app.sh 0.4.0 1
#
# Defaults: 0.0.0-dev / 1. Override for release builds.

set -euo pipefail

SHORT_VERSION="${1:-0.0.0-dev}"
BUILD_NUMBER="${2:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACAPP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIGNING_DIR="$MACAPP_DIR/Signing"
BUILD_DIR="$MACAPP_DIR/build"
APP_DIR="$BUILD_DIR/MediaPorter.app"
RESOURCES_DIR="$MACAPP_DIR/MediaPorter/Resources"

echo "==> Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "==> swift build -c release (arm64)"
cd "$MACAPP_DIR"
swift build -c release --arch arm64

BIN_PATH="$MACAPP_DIR/.build/arm64-apple-macosx/release/MediaPorter"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "ERROR: SwiftPM didn't produce $BIN_PATH" >&2
    exit 1
fi

echo "==> Copying executable"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/MediaPorter"

# SwiftPM emits the target's resource bundle next to the binary
# (MediaPorter_MediaPorterCore.bundle). That's where Bundle.module looks
# at runtime, so it's the only place libcig.dylib + grappa.bin need to
# live. Don't duplicate them at Contents/Resources/.
BUNDLE_SRC="$MACAPP_DIR/.build/arm64-apple-macosx/release/MediaPorter_MediaPorterCore.bundle"
if [[ ! -d "$BUNDLE_SRC" ]]; then
    echo "ERROR: SwiftPM didn't emit $BUNDLE_SRC (libcig.dylib + grappa.bin missing)" >&2
    exit 1
fi
echo "==> Copying resource bundle"
cp -R "$BUNDLE_SRC" "$APP_DIR/Contents/Resources/"

echo "==> Writing Info.plist (version $SHORT_VERSION build $BUILD_NUMBER)"
sed \
    -e "s/__SHORT_VERSION__/$SHORT_VERSION/" \
    -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/" \
    "$SIGNING_DIR/Info.plist" > "$APP_DIR/Contents/Info.plist"

# Optional: AppIcon.icns if present in brand/.
ICON_SRC="$MACAPP_DIR/../brand/appstore/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
    echo "WARN: $ICON_SRC not present — app will ship without an icon." >&2
fi

echo "==> Built $APP_DIR"
echo "    Run scripts/release.sh next to sign + notarize."
