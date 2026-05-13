#!/usr/bin/env bash
# Generate brand/appstore/AppIcon.icns from the AppIcon render logic.
#
# Run this whenever the icon design changes. The output is committed to
# brand/appstore/AppIcon.icns and picked up automatically by build-app.sh.
#
# Dev mode (`swift run MediaPorter`) still relies on the runtime
# AppIcon.install() draw because there's no Info.plist + Resources/ layout
# in that path. The .icns is purely for the bundled .app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACAPP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$MACAPP_DIR/.." && pwd)"

OUT_ICNS="$REPO_DIR/brand/appstore/AppIcon.icns"
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"

echo "==> Rendering iconset PNGs"
swift "$SCRIPT_DIR/make-icon.swift" "$ICONSET_DIR"

echo "==> iconutil → $OUT_ICNS"
iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"

echo "==> Verify"
file "$OUT_ICNS"
ls -lh "$OUT_ICNS"

# Cleanup
rm -rf "$(dirname "$ICONSET_DIR")"

echo "==> Done."
