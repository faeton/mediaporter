#!/usr/bin/env bash
# Assemble MediaPorter.app around the SwiftPM release build.
#
# Output: build/MediaPorter.app (unsigned). Run scripts/release.sh next to
# sign, notarize, staple, and DMG.
#
# Usage:
#   ./scripts/build-app.sh [short-version] [build-number] [--bundle-ffmpeg <dir>] [--app-dir <path>]
#     e.g. ./scripts/build-app.sh 0.4.0 1
#          ./scripts/build-app.sh 0.4.0 1 --bundle-ffmpeg build/ffmpeg-bin
#
# Flags (after the positional version + build-number):
#   --bundle-ffmpeg <dir>
#       Copies <dir>/ffmpeg and <dir>/ffprobe into Contents/Helpers/. Use
#       the output of scripts/build-ffmpeg.sh. Without this flag the .app
#       expects ffmpeg on PATH (the smaller "system ffmpeg" variant).
#
#   --app-dir <path>
#       Override the output bundle path. Defaults to build/MediaPorter.app.
#       Used by release.sh to assemble the two release variants
#       side-by-side (build/MediaPorter-system.app, build/MediaPorter-with-ffmpeg.app)
#       from a single SwiftPM build cache.
#
# Defaults: 0.0.0-dev / 1. Override for release builds.

set -euo pipefail

SHORT_VERSION="${1:-0.0.0-dev}"
BUILD_NUMBER="${2:-1}"
shift $(( $# > 2 ? 2 : $# ))

BUNDLE_FFMPEG_DIR=""
APP_DIR_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-ffmpeg)
            BUNDLE_FFMPEG_DIR="$2"
            shift 2
            ;;
        --app-dir)
            APP_DIR_OVERRIDE="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACAPP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIGNING_DIR="$MACAPP_DIR/Signing"
BUILD_DIR="$MACAPP_DIR/build"
APP_DIR="${APP_DIR_OVERRIDE:-$BUILD_DIR/MediaPorter.app}"
RESOURCES_DIR="$MACAPP_DIR/MediaPorter/Resources"

# Bundled ffmpeg validation up front — better to fail before swift build
# than after a 60s release-mode compile.
if [[ -n "$BUNDLE_FFMPEG_DIR" ]]; then
    [[ -x "$BUNDLE_FFMPEG_DIR/ffmpeg"  ]] || { echo "ERROR: $BUNDLE_FFMPEG_DIR/ffmpeg missing or not executable" >&2; exit 1; }
    [[ -x "$BUNDLE_FFMPEG_DIR/ffprobe" ]] || { echo "ERROR: $BUNDLE_FFMPEG_DIR/ffprobe missing or not executable" >&2; exit 1; }
fi

# release.sh assembles two .apps from one swift-build cache, so we can't
# nuke the whole BUILD_DIR on every run — only the target .app.
echo "==> Preparing $APP_DIR"
rm -rf "$APP_DIR"
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
# at runtime, so it's the only place libcig.dylib + SyncAuthSeed.dat need
# to live. Don't duplicate them at Contents/Resources/.
BUNDLE_SRC="$MACAPP_DIR/.build/arm64-apple-macosx/release/MediaPorter_MediaPorterCore.bundle"
if [[ ! -d "$BUNDLE_SRC" ]]; then
    echo "ERROR: SwiftPM didn't emit $BUNDLE_SRC (libcig.dylib + SyncAuthSeed.dat missing)" >&2
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

# Optional: bundled ffmpeg + ffprobe under Contents/Helpers/. FFmpegLocator
# checks this path first; no Helpers/ dir == "system ffmpeg" variant which
# falls through to PATH/Homebrew search.
if [[ -n "$BUNDLE_FFMPEG_DIR" ]]; then
    HELPERS_DIR="$APP_DIR/Contents/Helpers"
    echo "==> Bundling ffmpeg + ffprobe from $BUNDLE_FFMPEG_DIR"
    mkdir -p "$HELPERS_DIR"
    cp "$BUNDLE_FFMPEG_DIR/ffmpeg"  "$HELPERS_DIR/ffmpeg"
    cp "$BUNDLE_FFMPEG_DIR/ffprobe" "$HELPERS_DIR/ffprobe"
    chmod +x "$HELPERS_DIR/ffmpeg" "$HELPERS_DIR/ffprobe"
fi

echo "==> Built $APP_DIR"
echo "    Run scripts/release.sh next to sign + notarize."
