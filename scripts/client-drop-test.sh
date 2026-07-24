#!/usr/bin/env bash
# Verify client-drop detection during a long-poll: a parked permission request
# whose client goes away (graceful FIN, like a Ctrl-C'd session's killed curl)
# must be removed from the queue promptly — not left to the 585s timeout.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT=8804
FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }
BIN="$(swift build --show-bin-path)/NotchApp"

# No NOTCH_AUTO → the request parks (headless: the panel path just holds it).
NOTCH_PORT=$PORT NOTCH_TOKEN=t NOTCH_VIRTUAL=1 "$BIN" >/dev/null 2>&1 &
APP=$!
trap 'kill "$APP" "${CURL:-}" 2>/dev/null || true' EXIT
for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1 && break; sleep 0.25; done

# Park a permission request in the background.
curl -sS --max-time 60 -H "X-Notch-Token: t" \
  --data '{"hook_event_name":"PermissionRequest","session_id":"drop","cwd":"/tmp/x","tool_name":"Bash","tool_input":{"command":"sleep 1"}}' \
  "http://127.0.0.1:$PORT/v1/permission" >/dev/null 2>&1 &
CURL=$!

# Confirm it parked.
parked=0
for _ in $(seq 1 20); do
  [ "$(curl -s "http://127.0.0.1:$PORT/v1/health" | grep -o '"pending":[0-9]*' | cut -d: -f2)" = "1" ] && { parked=1; break; }
  sleep 0.25
done
[ "$parked" = "1" ] && pass "request parked (pending=1)" || fail "request never parked"

# Kill curl gracefully (SIGTERM → OS closes the socket → FIN), like a Ctrl-C'd session.
kill -TERM "$CURL" 2>/dev/null; CURL=""

# The card must clear within a few seconds (NOT wait for the 585s timeout).
dropped=0
for _ in $(seq 1 24); do   # up to ~6s
  [ "$(curl -s "http://127.0.0.1:$PORT/v1/health" | grep -o '"pending":[0-9]*' | cut -d: -f2)" = "0" ] && { dropped=1; break; }
  sleep 0.25
done
[ "$dropped" = "1" ] && pass "parked request dropped promptly after client FIN" \
  || fail "parked request NOT dropped (would linger until timeout)"

echo
[ "$FAILED" = "0" ] && echo "client-drop test passed" || echo "CLIENT-DROP TEST FAILED"
exit "$FAILED"
