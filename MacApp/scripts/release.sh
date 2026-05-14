#!/usr/bin/env bash
# Sign, notarize, staple, and DMG MediaPorter.app — both variants in one go.
#
# Outputs:
#   build/MediaPorter-<version>.dmg               — system-ffmpeg variant
#   build/MediaPorter-<version>-with-ffmpeg.dmg   — bundled-ffmpeg variant
#
# Both DMGs ship the same Swift binary — the difference is whether
# Contents/Helpers/{ffmpeg,ffprobe} is present. FFmpegLocator picks bundled
# first, then PATH/Homebrew. ContentView shows a persistent install banner
# when both fail (system variant on a Mac without ffmpeg).
#
# Prereqs:
#   1. Developer ID Application cert in login keychain:
#        security find-identity -p codesigning -v
#   2. notarytool keychain profile named "porter-notarization":
#        xcrun notarytool store-credentials porter-notarization \
#            --apple-id <apple-id> --team-id BKY9R5336T \
#            --password <app-specific-password>
#   3. Bundled ffmpeg + ffprobe at build/ffmpeg-bin/ — run scripts/build-ffmpeg.sh.
#      The script will auto-invoke build-ffmpeg.sh if the binaries are missing.
#
# Usage:
#   ./scripts/release.sh [short-version] [build-number]
#     e.g. ./scripts/release.sh 0.4.0 1
#   Defaults: 0.0.0-dev / 1. Always pass real values for shipping releases.

set -euo pipefail

SHORT_VERSION="${1:-0.0.0-dev}"
BUILD_NUMBER="${2:-1}"

IDENTITY="${IDENTITY:-Developer ID Application: Ivan Danishevskyi (BKY9R5336T)}"
PROFILE="${PROFILE:-porter-notarization}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACAPP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIGNING_DIR="$MACAPP_DIR/Signing"
BUILD_DIR="$MACAPP_DIR/build"
ENTITLEMENTS="$SIGNING_DIR/MediaPorter.entitlements"
FFMPEG_BIN_DIR="$BUILD_DIR/ffmpeg-bin"

SYSTEM_APP="$BUILD_DIR/MediaPorter-system.app"
WITHFF_APP="$BUILD_DIR/MediaPorter-with-ffmpeg.app"
SYSTEM_DMG="$BUILD_DIR/MediaPorter-${SHORT_VERSION}.dmg"
WITHFF_DMG="$BUILD_DIR/MediaPorter-${SHORT_VERSION}-with-ffmpeg.dmg"

echo "==> Release pipeline ($SHORT_VERSION build $BUILD_NUMBER)"

# Build ffmpeg first if it isn't on disk. Cheap when cached.
if [[ ! -x "$FFMPEG_BIN_DIR/ffmpeg" || ! -x "$FFMPEG_BIN_DIR/ffprobe" ]]; then
    echo "==> Bundled ffmpeg missing — invoking build-ffmpeg.sh"
    "$SCRIPT_DIR/build-ffmpeg.sh"
fi

# Wipe stale .app/.dmg outputs from prior runs but keep ffmpeg-bin and the
# SwiftPM cache (.build/) so we don't pay 60s of compile twice for two variants.
rm -rf "$SYSTEM_APP" "$WITHFF_APP" "$SYSTEM_DMG" "$WITHFF_DMG" "$BUILD_DIR/dmg-staging"

# ---- assemble both .app variants -----------------------------------------

echo
echo "==> [1/2] Assembling system-ffmpeg variant"
"$SCRIPT_DIR/build-app.sh" "$SHORT_VERSION" "$BUILD_NUMBER" --app-dir "$SYSTEM_APP"

echo
echo "==> [2/2] Assembling with-ffmpeg variant"
"$SCRIPT_DIR/build-app.sh" "$SHORT_VERSION" "$BUILD_NUMBER" \
    --app-dir "$WITHFF_APP" \
    --bundle-ffmpeg "$FFMPEG_BIN_DIR"

# ---- helpers -------------------------------------------------------------

# Sign every Mach-O nested in an .app, then the .app itself. Order matters:
# the outer signature hashes the nested binaries, so signing them after the
# outer would invalidate the seal.
sign_app() {
    local app="$1"
    local label="$2"
    echo
    echo "==> [$label] Signing nested binaries"

    local helpers="$app/Contents/Helpers"
    if [[ -d "$helpers" ]]; then
        for bin in ffmpeg ffprobe; do
            if [[ -f "$helpers/$bin" ]]; then
                echo "    sign Helpers/$bin"
                codesign --force --options runtime --timestamp \
                    --sign "$IDENTITY" \
                    "$helpers/$bin"
            fi
        done
    fi

    local bundle="$app/Contents/Resources/MediaPorter_MediaPorterCore.bundle"
    if [[ -f "$bundle/libcig.dylib" ]]; then
        echo "    sign libcig.dylib"
        codesign --force --options runtime --timestamp \
            --sign "$IDENTITY" \
            "$bundle/libcig.dylib"
    fi

    echo "==> [$label] Signing app bundle"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" \
        "$app"

    echo "==> [$label] Verifying signature"
    codesign --verify --deep --strict --verbose=2 "$app"
    spctl --assess --type execute --verbose=4 "$app" 2>&1 || \
        echo "    (spctl rejected — expected pre-notarization)"
}

# Submit a zip to notarytool *without* --wait, return the submission id on
# stdout. We poll separately so the two variants notarize concurrently
# instead of serially. Apple's notary throughput per account is high enough
# that two parallel polls don't trigger throttling.
submit_async() {
    local zip="$1"
    local out
    out=$(xcrun notarytool submit "$zip" \
            --keychain-profile "$PROFILE" \
            --output-format json) || die "notarytool submit failed for $zip"
    python3 -c "import sys, json; print(json.load(sys.stdin)['id'])" <<< "$out"
}

# Block until Apple returns Accepted / Invalid / Rejected for a submission.
# Sleeps 30s between polls (Apple's notary backend is happiest with that
# cadence). Dumps the failure log on Invalid/Rejected so we don't have to
# manually re-run notarytool log to debug.
wait_notary() {
    local uuid="$1" label="$2"
    while true; do
        local info status
        info=$(xcrun notarytool info "$uuid" --keychain-profile "$PROFILE" --output-format json 2>&1) \
            || { echo "  [$label] info query failed; retrying"; sleep 30; continue; }
        status=$(python3 -c "import sys, json; print(json.load(sys.stdin).get('status', '?'))" <<< "$info" 2>/dev/null) \
            || { echo "  [$label] could not parse status; retrying"; sleep 30; continue; }
        case "$status" in
            "Accepted")
                echo "  [$label] Accepted ($uuid)"
                return 0
                ;;
            "Invalid"|"Rejected")
                echo "  [$label] $status ($uuid) — fetching log:"
                xcrun notarytool log "$uuid" --keychain-profile "$PROFILE" || true
                return 1
                ;;
            "In Progress")
                echo "  [$label] In Progress ($uuid)"
                sleep 30
                ;;
            *)
                echo "  [$label] unexpected status '$status' ($uuid) — retrying"
                sleep 30
                ;;
        esac
    done
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- sign + zip both variants --------------------------------------------

sign_app "$SYSTEM_APP" "system"
sign_app "$WITHFF_APP" "with-ffmpeg"

echo
echo "==> Zipping for notarization"
SYSTEM_ZIP="$BUILD_DIR/MediaPorter-system.zip"
WITHFF_ZIP="$BUILD_DIR/MediaPorter-with-ffmpeg.zip"
rm -f "$SYSTEM_ZIP" "$WITHFF_ZIP"
ditto -c -k --keepParent "$SYSTEM_APP" "$SYSTEM_ZIP"
ditto -c -k --keepParent "$WITHFF_APP" "$WITHFF_ZIP"

# ---- submit both, poll in parallel ---------------------------------------

echo
echo "==> Submitting .app zips to notarytool (async)"
SYSTEM_UUID=$(submit_async "$SYSTEM_ZIP")
echo "    system      → $SYSTEM_UUID"
WITHFF_UUID=$(submit_async "$WITHFF_ZIP")
echo "    with-ffmpeg → $WITHFF_UUID"

echo
echo "==> Polling both submissions in parallel (30s cadence)"
wait_notary "$SYSTEM_UUID" "system" &
PID_SYS=$!
wait_notary "$WITHFF_UUID" "with-ffmpeg" &
PID_WFF=$!

# `wait <pid>` exits with that child's exit status. If either notary call
# returns non-zero (Invalid/Rejected) we abort — there's no point stapling
# a rejected ticket.
SYS_RC=0; WFF_RC=0
wait "$PID_SYS" || SYS_RC=$?
wait "$PID_WFF" || WFF_RC=$?
[[ $SYS_RC -eq 0 ]] || die "system-ffmpeg notarization failed"
[[ $WFF_RC -eq 0 ]] || die "with-ffmpeg notarization failed"

# ---- staple, DMG, sign DMG, notarize DMG ---------------------------------

build_dmg() {
    local app="$1" dmg="$2" label="$3"
    echo
    echo "==> [$label] Stapling .app"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=4 "$app"

    echo "==> [$label] Building DMG: $dmg"
    local staging="$BUILD_DIR/dmg-staging-$label"
    rm -rf "$staging"
    mkdir -p "$staging"
    # ditto preserves the codesign seal exactly; cp -R is safe on modern
    # macOS but ditto is the documented path.
    ditto "$app" "$staging/$(basename "$app")"
    ln -s /Applications "$staging/Applications"
    hdiutil create \
        -volname "MediaPorter ${SHORT_VERSION}" \
        -srcfolder "$staging" \
        -ov -format UDZO \
        "$dmg" >/dev/null

    echo "==> [$label] Signing DMG"
    codesign --force --timestamp --sign "$IDENTITY" "$dmg"
}

build_dmg "$SYSTEM_APP" "$SYSTEM_DMG" "system"
build_dmg "$WITHFF_APP" "$WITHFF_DMG" "with-ffmpeg"

echo
echo "==> Submitting DMGs to notarytool (async)"
DMG_SYS_UUID=$(submit_async "$SYSTEM_DMG")
echo "    system      → $DMG_SYS_UUID"
DMG_WFF_UUID=$(submit_async "$WITHFF_DMG")
echo "    with-ffmpeg → $DMG_WFF_UUID"

echo
echo "==> Polling DMG submissions in parallel"
wait_notary "$DMG_SYS_UUID" "system-dmg" &
PID_DSY=$!
wait_notary "$DMG_WFF_UUID" "with-ffmpeg-dmg" &
PID_DWF=$!
DSY_RC=0; DWF_RC=0
wait "$PID_DSY" || DSY_RC=$?
wait "$PID_DWF" || DWF_RC=$?
[[ $DSY_RC -eq 0 ]] || die "system DMG notarization failed"
[[ $DWF_RC -eq 0 ]] || die "with-ffmpeg DMG notarization failed"

echo
echo "==> Stapling DMGs"
xcrun stapler staple "$SYSTEM_DMG" && xcrun stapler validate "$SYSTEM_DMG"
xcrun stapler staple "$WITHFF_DMG" && xcrun stapler validate "$WITHFF_DMG"

# ---- summary -------------------------------------------------------------

echo
echo "==> Done. Ship these:"
echo "    $SYSTEM_DMG  ($(du -h "$SYSTEM_DMG" | awk '{print $1}'))"
echo "    $WITHFF_DMG  ($(du -h "$WITHFF_DMG" | awk '{print $1}'))"
echo
echo "Sanity check on a fresh Mac:"
echo "    xcrun stapler validate '$SYSTEM_DMG'"
echo "    xcrun stapler validate '$WITHFF_DMG'"
echo "    spctl --assess --type open --context context:primary-signature -v '$SYSTEM_DMG'"
echo "    spctl --assess --type open --context context:primary-signature -v '$WITHFF_DMG'"
