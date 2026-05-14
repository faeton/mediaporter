#!/usr/bin/env bash
# Build a branded, signed-content DMG from a .app bundle.
#
# - .app is renamed to MediaPorter.app inside the DMG regardless of source name
#   (R2 in plan.md) so both shipping variants present the same artifact name.
# - Window layout is set via Finder AppleScript: 540×380 window, 96px icons,
#   .app on the left, Applications symlink on the right, branded background.
# - Signing happens in release.sh AFTER this script exits — we just produce
#   the UDZO file here.
#
# Usage:
#   build-dmg.sh --app /path/to/Foo.app --output /path/to/Out.dmg \
#                --volname "MediaPorter 0.6.2" \
#                --background /path/to/dmg-background.png

set -euo pipefail

APP_SRC=""
DMG_OUT=""
VOL_NAME=""
BG_PNG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)        APP_SRC="$2"; shift 2;;
        --output)     DMG_OUT="$2"; shift 2;;
        --volname)    VOL_NAME="$2"; shift 2;;
        --background) BG_PNG="$2"; shift 2;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

[[ -d "$APP_SRC" ]] || { echo "ERROR: --app must point at a .app directory" >&2; exit 2; }
[[ -n "$DMG_OUT" ]] || { echo "ERROR: --output required" >&2; exit 2; }
[[ -n "$VOL_NAME" ]] || { echo "ERROR: --volname required" >&2; exit 2; }
[[ -f "$BG_PNG" ]] || { echo "ERROR: --background file missing: $BG_PNG" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(cd "$SCRIPT_DIR/../build" && pwd)"

# Per-output staging so concurrent variant builds don't trample each other.
STAGING="$BUILD_DIR/dmg-staging-$(basename "${DMG_OUT%.dmg}")"
UDRW_DMG="$BUILD_DIR/dmg-rw-$(basename "${DMG_OUT%.dmg}").dmg"

rm -rf "$STAGING" "$UDRW_DMG"
mkdir -p "$STAGING/.background"

# R2: contained .app is always MediaPorter.app, regardless of source filename.
# ditto preserves codesign seal exactly; cp -R also works on modern macOS but
# ditto is the documented preserve-everything path.
ditto "$APP_SRC" "$STAGING/MediaPorter.app"
ln -s /Applications "$STAGING/Applications"
cp "$BG_PNG" "$STAGING/.background/background.png"

# Size the UDRW image to content + 30% slack. hdiutil rejects images too
# small for the source; the slack lets Finder write .DS_Store + metadata.
SIZE_KB=$(du -sk "$STAGING" | awk '{print $1}')
PADDED_KB=$(( SIZE_KB * 130 / 100 + 4096 ))
SIZE_ARG="${PADDED_KB}k"

# Detach any stale mount with our volume name (defensive — a prior failed
# run can leave a mounted volume that blocks `hdiutil create`).
EXISTING_MOUNT=$(mount | awk -v v="/Volumes/$VOL_NAME" '$3==v {print $1}' || true)
if [[ -n "$EXISTING_MOUNT" ]]; then
    hdiutil detach "$EXISTING_MOUNT" -force >/dev/null 2>&1 || true
fi

echo "    create UDRW image (${SIZE_ARG})"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDRW \
    -size "$SIZE_ARG" \
    "$UDRW_DMG" >/dev/null

echo "    mount UDRW image"
MOUNT_INFO=$(hdiutil attach -nobrowse -noverify "$UDRW_DMG" -plist)
# Plist has a `system-entities` array of dicts; the mountable HFS partition
# carries a `<key>mount-point</key><string>/Volumes/...</string>` pair. Grep
# the first /Volumes/ string — robust to the exact partition layout.
MOUNT_POINT=$(printf '%s\n' "$MOUNT_INFO" | grep -o '<string>/Volumes/[^<]*</string>' | head -1 | sed -E 's:^<string>::; s:</string>$::')
[[ -d "$MOUNT_POINT" ]] || { echo "ERROR: could not resolve mount point from plist" >&2; printf '%s\n' "$MOUNT_INFO" >&2; exit 1; }
echo "    mounted at $MOUNT_POINT"

# Finder AppleScript: window size 540×380, icon view, 96px icons, .app on
# the left and Applications on the right, branded background image.
# Y positions in Finder coords are from the top; matches the arrow geometry
# baked into make-dmg-background.swift.
echo "    apply Finder layout"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 740, 580}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "MediaPorter.app" of container window to {140, 200}
        set position of item "Applications" of container window to {400, 200}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

# Flush Finder's window writes to .DS_Store before we detach. Without this
# the layout sometimes evaporates because the .DS_Store is still buffered.
sync
sleep 1

echo "    detach UDRW image"
hdiutil detach "$MOUNT_POINT" -force >/dev/null

echo "    convert to compressed UDZO → $DMG_OUT"
rm -f "$DMG_OUT"
hdiutil convert "$UDRW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_OUT" >/dev/null

rm -f "$UDRW_DMG"
rm -rf "$STAGING"

echo "    done: $DMG_OUT ($(du -h "$DMG_OUT" | awk '{print $1}'))"
