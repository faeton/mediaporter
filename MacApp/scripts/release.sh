#!/usr/bin/env bash
# Sign, notarize, staple, and DMG MediaPorter.app.
#
# Prereqs:
#   1. Run scripts/build-app.sh first to produce build/MediaPorter.app.
#   2. Developer ID Application cert in login keychain:
#        security find-identity -p codesigning -v
#      (Expect: "Developer ID Application: Ivan Danishevskyi (BKY9R5336T)")
#   3. notarytool keychain profile named "porter-notarization":
#        xcrun notarytool store-credentials porter-notarization \
#            --apple-id <apple-id> --team-id BKY9R5336T \
#            --password <app-specific-password>
#
# Output: build/MediaPorter-<version>.dmg, stapled + ready to ship.

set -euo pipefail

IDENTITY="${IDENTITY:-Developer ID Application: Ivan Danishevskyi (BKY9R5336T)}"
PROFILE="${PROFILE:-porter-notarization}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACAPP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIGNING_DIR="$MACAPP_DIR/Signing"
BUILD_DIR="$MACAPP_DIR/build"
APP_DIR="$BUILD_DIR/MediaPorter.app"
ENTITLEMENTS="$SIGNING_DIR/MediaPorter.entitlements"

if [[ ! -d "$APP_DIR" ]]; then
    echo "ERROR: $APP_DIR not found. Run scripts/build-app.sh first." >&2
    exit 1
fi

# Pull the short version out of Info.plist so the DMG name matches.
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist")
DMG_PATH="$BUILD_DIR/MediaPorter-${SHORT_VERSION}.dmg"

BUNDLE="$APP_DIR/Contents/Resources/MediaPorter_MediaPorterCore.bundle"
if [[ ! -d "$BUNDLE" ]]; then
    echo "ERROR: Resource bundle missing at $BUNDLE. Re-run build-app.sh." >&2
    exit 1
fi

# Sign the dylib first (Mach-O — always needs its own signature). The
# SwiftPM resource bundle directory has no Info.plist so codesign refuses
# to treat it as a bundle; that's fine — the outer .app seal covers the
# directory and its contents through the resource hashes.
echo "==> Signing libcig.dylib"
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" \
    "$BUNDLE/libcig.dylib"

echo "==> Signing app bundle (hardened runtime + entitlements)"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$APP_DIR"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
codesign --display --entitlements - --xml "$APP_DIR" > /dev/null
spctl --assess --type execute --verbose=4 "$APP_DIR" || {
    echo "WARN: spctl rejected (expected pre-notarization — Gatekeeper hasn't seen the ticket yet)."
}

echo "==> Zipping for notarization submission"
ZIP_PATH="$BUILD_DIR/MediaPorter.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo "==> Submitting to notarytool (will wait for verdict)"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$PROFILE" \
    --wait

echo "==> Stapling ticket to .app"
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

echo "==> Final Gatekeeper check (should accept now)"
spctl --assess --type execute --verbose=4 "$APP_DIR"

echo "==> Building DMG: $DMG_PATH"
rm -f "$DMG_PATH"
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "MediaPorter ${SHORT_VERSION}" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

echo "==> Signing + notarizing DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo
echo "==> Done. Ship this:"
echo "    $DMG_PATH"
echo
echo "Sanity check on a fresh Mac:"
echo "    xcrun stapler validate '$DMG_PATH'"
echo "    spctl --assess --type open --context context:primary-signature -v '$DMG_PATH'"
