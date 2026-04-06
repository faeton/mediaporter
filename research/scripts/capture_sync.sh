#!/bin/bash
# Capture Finder ↔ iOS device traffic via usbmuxd socket proxy
#
# Usage:
#   sudo bash scripts/capture_sync.sh
#
# Then in Finder:
#   1. Select iPad in sidebar
#   2. Drag a video file to the iPad
#   3. Wait for sync to complete
#   4. Press Ctrl+C here to stop capture
#
# Output: /tmp/usbmux_capture.log (hex dump of all traffic)

set -e

SOCKET="/var/run/usbmuxd"
BACKUP="/var/run/usbmuxd_real"
LOGFILE="/tmp/usbmux_capture.log"

echo "=== mediaporter usbmux capture ==="
echo "Log file: $LOGFILE"
echo ""

if [ ! -S "$SOCKET" ]; then
    echo "ERROR: $SOCKET not found"
    exit 1
fi

# Move real socket aside
echo "Moving real socket to $BACKUP..."
mv "$SOCKET" "$BACKUP"

# Set up cleanup on exit
cleanup() {
    echo ""
    echo "Restoring original socket..."
    mv "$BACKUP" "$SOCKET"
    echo "Capture saved to: $LOGFILE"
    echo "Done."
}
trap cleanup EXIT

# Start proxy
echo "Starting socat proxy..."
echo ">>> NOW: Drag a video to your iPad in Finder <<<"
echo ">>> Press Ctrl+C when sync is complete <<<"
echo ""

socat -t100 -x -v \
    UNIX-LISTEN:"$SOCKET",mode=777,reuseaddr,fork \
    UNIX-CONNECT:"$BACKUP" \
    2>&1 | tee "$LOGFILE"
