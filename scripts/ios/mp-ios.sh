#!/usr/bin/env bash
#
# mp-ios — drive a physical iPhone for MediaPorter test verification.
#
# Wraps the WebDriverAgent (WDA) REST API + WDA lifecycle so an agent or a human
# can see and control the device's TV.app over the shell. Built for the harness
# established 2026-06-07 (see research/docs/IOS_TEST_HARNESS.md).
#
# Capabilities: bring WDA up, screenshot, read the UI tree, launch apps, tap by
# accessibility name or coordinate, swipe, type. Screenshot + launch also work
# via pymobiledevice3 without WDA (see that doc), but tap/swipe/type need WDA.
#
# Requirements (installed per IOS_TEST_HARNESS.md):
#   - WDA built+signed for the target device (xctestrun under $WDA_DERIVED)
#   - libimobiledevice (iproxy), Xcode (xcodebuild), python3
#
# Usage: scripts/ios/mp-ios.sh <command> [args]
#   wda-up                 ensure WDA runner + port-forward are live (relaunch if needed)
#   wda-down               stop the WDA runner + port-forward
#   status                 print WDA /status
#   session [bundleId]     create a fresh session (optionally launching an app), cache id
#   launch <bundleId>      launch/activate an app (e.g. com.apple.tv)
#   screenshot [outfile]   save a PNG (default /tmp/mp-ios-shot.png)
#   source [outfile]       dump the accessibility/UI tree (XML)
#   buttons                list tappable element names (discover tap targets)
#   tap <name>             find an element by name/label and click it
#   tap-xy <x> <y>         tap at logical coordinates
#   swipe <x1> <y1> <x2> <y2> [durationSec]
#   text <string>          type into the focused field
#
# Env overrides: MP_IOS_UDID, MP_IOS_PORT, MP_IOS_WDA_DIR, MP_IOS_XCTESTRUN
set -euo pipefail

UDID="${MP_IOS_UDID:-00008140-000C14EA3862201C}"   # akm16pro
PORT="${MP_IOS_PORT:-8100}"
BASE="http://localhost:${PORT}"
WDA_DIR="${MP_IOS_WDA_DIR:-$HOME/ios-tools/WebDriverAgent}"
XCTESTRUN="${MP_IOS_XCTESTRUN:-/tmp/wda-build/Build/Products/WebDriverAgentRunner_iphoneos26.5-arm64.xctestrun}"
SESSION_FILE="/tmp/mp-ios-session-${UDID}.id"
WDA_LOG="/tmp/mp-ios-wda-${UDID}.log"

# Put the toolchain on PATH (Homebrew, uv tools, go bins).
export PATH="$HOME/go/bin:$HOME/.local/bin:$(brew --prefix 2>/dev/null || echo /opt/homebrew)/bin:$PATH"

die() { echo "mp-ios: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- JSON helpers (python3, avoids jq dependency for base64) ---------------
json_get() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }

wda_ready() {
  curl -s --max-time 5 "$BASE/status" 2>/dev/null | json_get "['value']['ready']" 2>/dev/null | grep -qi true
}

ensure_iproxy() {
  pgrep -f "iproxy ${PORT} ${PORT}" >/dev/null 2>&1 && return 0
  have iproxy || die "iproxy not found (brew install libimobiledevice)"
  iproxy "${PORT}" "${PORT}" -u "${UDID}" >/tmp/mp-ios-iproxy.log 2>&1 &
  sleep 1
}

wda_up() {
  ensure_iproxy
  if wda_ready; then echo "WDA ready on ${BASE}"; return 0; fi
  echo "Launching WDA runner (device must be unlocked; Auto-Lock off recommended)..."
  [ -f "$XCTESTRUN" ] || die "xctestrun not found: $XCTESTRUN — rebuild WDA (see IOS_TEST_HARNESS.md)"
  ( cd "$WDA_DIR" && nohup xcodebuild test-without-building \
      -xctestrun "$XCTESTRUN" -destination "id=${UDID}" >"$WDA_LOG" 2>&1 & )
  # wait for the server marker
  for _ in $(seq 1 40); do
    grep -q "ServerURLHere" "$WDA_LOG" 2>/dev/null && break
    grep -qiE "automation mode|Testing failed|TEST EXECUTE FAILED" "$WDA_LOG" 2>/dev/null && {
      tail -5 "$WDA_LOG" >&2
      die "WDA failed to start — check Settings>Developer>Enable UI Automation, and that the device is unlocked"
    }
    sleep 3
  done
  ensure_iproxy
  for _ in $(seq 1 10); do wda_ready && { echo "WDA ready on ${BASE}"; return 0; }; sleep 2; done
  die "WDA did not become ready; see $WDA_LOG"
}

wda_down() {
  pkill -f "xcodebuild test-without-building" 2>/dev/null || true
  pkill -f "iproxy ${PORT} ${PORT}" 2>/dev/null || true
  rm -f "$SESSION_FILE"
  echo "WDA runner + iproxy stopped"
}

# --- session management -----------------------------------------------------
new_session() {  # $1 optional bundleId
  local bundle="${1:-}" body
  if [ -n "$bundle" ]; then
    body="{\"capabilities\":{\"alwaysMatch\":{\"bundleId\":\"$bundle\"}}}"
  else
    body='{"capabilities":{"alwaysMatch":{}}}'
  fi
  local sid
  sid=$(curl -s -X POST "$BASE/session" -H 'Content-Type: application/json' -d "$body" \
        | json_get "['value']['sessionId']")
  [ -n "$sid" ] && [ "$sid" != "None" ] || die "could not create session (is WDA up? run: mp-ios wda-up)"
  echo "$sid" >"$SESSION_FILE"
  echo "$sid"
}

ensure_session() {
  if [ -f "$SESSION_FILE" ]; then
    local sid; sid=$(cat "$SESSION_FILE")
    # validate
    if curl -s --max-time 5 "$BASE/session/$sid/window/size" | grep -q '"width"'; then
      echo "$sid"; return 0
    fi
  fi
  new_session "$@"
}

# --- commands ---------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  wda-up)   wda_up ;;
  wda-down) wda_down ;;
  status)   curl -s "$BASE/status" | python3 -m json.tool ;;
  session)  new_session "${1:-}" ;;
  launch)   [ -n "${1:-}" ] || die "usage: launch <bundleId>"; new_session "$1" >/dev/null; echo "launched $1" ;;
  screenshot)
    out="${1:-/tmp/mp-ios-shot.png}"
    curl -s "$BASE/screenshot" | python3 -c "import sys,json,base64;open('$out','wb').write(base64.b64decode(json.load(sys.stdin)['value']))"
    echo "$out" ;;
  source)
    sid=$(ensure_session)
    out="${1:-}"
    if [ -n "$out" ]; then curl -s "$BASE/session/$sid/source" | json_get "['value']" >"$out"; echo "$out"
    else curl -s "$BASE/session/$sid/source" | json_get "['value']"; fi ;;
  buttons)
    sid=$(ensure_session)
    curl -s "$BASE/session/$sid/source" | json_get "['value']" \
      | grep -oE 'name="[^"]+"' | sed 's/name="//;s/"//' | sort -u ;;
  tap)
    [ -n "${1:-}" ] || die "usage: tap <accessibility name>"
    sid=$(ensure_session)
    eid=$(curl -s -X POST "$BASE/session/$sid/element" -H 'Content-Type: application/json' \
          -d "{\"using\":\"name\",\"value\":\"$1\"}" | json_get "['value']['ELEMENT']")
    [ -n "$eid" ] && [ "$eid" != "None" ] || die "element not found: $1 (try: mp-ios buttons)"
    curl -s -X POST "$BASE/session/$sid/element/$eid/click" -H 'Content-Type: application/json' -d '{}' >/dev/null
    echo "tapped: $1" ;;
  tap-xy)
    [ -n "${2:-}" ] || die "usage: tap-xy <x> <y>"
    sid=$(ensure_session)
    curl -s -X POST "$BASE/session/$sid/actions" -H 'Content-Type: application/json' -d "{
      \"actions\":[{\"type\":\"pointer\",\"id\":\"finger1\",\"parameters\":{\"pointerType\":\"touch\"},
      \"actions\":[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},
      {\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pause\",\"duration\":60},
      {\"type\":\"pointerUp\",\"button\":0}]}]}" >/dev/null
    echo "tapped ($1,$2)" ;;
  swipe)
    [ -n "${4:-}" ] || die "usage: swipe <x1> <y1> <x2> <y2> [durSec]"
    sid=$(ensure_session); dur="${5:-0.3}"; durms=$(python3 -c "print(int(float('$dur')*1000))")
    curl -s -X POST "$BASE/session/$sid/actions" -H 'Content-Type: application/json' -d "{
      \"actions\":[{\"type\":\"pointer\",\"id\":\"finger1\",\"parameters\":{\"pointerType\":\"touch\"},
      \"actions\":[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},
      {\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pointerMove\",\"duration\":$durms,\"x\":$3,\"y\":$4},
      {\"type\":\"pointerUp\",\"button\":0}]}]}" >/dev/null
    echo "swiped ($1,$2)->($3,$4)" ;;
  text)
    [ -n "${1:-}" ] || die "usage: text <string>"
    sid=$(ensure_session)
    curl -s -X POST "$BASE/session/$sid/wda/keys" -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json,sys;print(json.dumps({'value':list(sys.argv[1])}))" "$1")" >/dev/null
    echo "typed: $1" ;;
  *)
    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | sed -n '1,40p'
    exit 1 ;;
esac
