#!/bin/bash
#
# Attach LLDB to Finder or AMPDevicesAgent and log ATC-related calls.
#
# Usage:
#   ./scripts/trace_atc_sync.sh Finder
#   ./scripts/trace_atc_sync.sh AMPDevicesAgent /tmp/custom-trace.log
#
# Notes:
# - Attaching to Apple processes usually requires SIP debug relaxation:
#     csrutil enable --without debug
# - Run the script first, then trigger a manual Finder sync.
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACE_SCRIPT="$ROOT_DIR/scripts/lldb_atc_trace.py"
PROCESS_NAME="${1:-AMPDevicesAgent}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOGFILE="${2:-/tmp/mediaporter-atc-trace-${PROCESS_NAME}-${TIMESTAMP}.log}"

if ! command -v lldb >/dev/null 2>&1; then
    echo "lldb not found"
    exit 1
fi

if [ ! -f "$TRACE_SCRIPT" ]; then
    echo "trace helper missing: $TRACE_SCRIPT"
    exit 1
fi

if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "process not running: $PROCESS_NAME"
    echo "try Finder or AMPDevicesAgent"
    exit 1
fi

echo "Attaching to: $PROCESS_NAME"
echo "Log file: $LOGFILE"
echo "After LLDB continues, trigger a manual Finder sync."
echo "Press Ctrl+C in LLDB when you have enough data."
echo

exec lldb -n "$PROCESS_NAME" \
    -o "command script import $TRACE_SCRIPT" \
    -o "atc_trace_log $LOGFILE" \
    -o "atc_trace_setup" \
    -o "continue"
