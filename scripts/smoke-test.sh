#!/usr/bin/env bash
# Headless protocol smoke test. Builds the app, runs it with NOTCH_AUTO=allow on
# an ephemeral port + token, and exercises every endpoint via curl. No UI, no
# real Claude session. Exits non-zero on the first failed assertion.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${NOTCH_PORT:-8791}"
TOKEN="smoke-$$-token"
FAILED=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

echo "building..."
swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }
BIN="$(swift build --show-bin-path)/NotchApp"

echo "unit self-tests..."
if NOTCH_SELFTEST=1 "$BIN" | sed 's/^/  /'; then :; else fail "self-tests"; fi


echo "starting app on port ${PORT} (NOTCH_AUTO=allow)..."
NOTCH_PORT="$PORT" NOTCH_TOKEN="$TOKEN" NOTCH_AUTO=allow NOTCH_VIRTUAL=1 "$BIN" &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT

# wait for listener
for _ in $(seq 1 40); do
  curl -s "http://127.0.0.1:${PORT}/v1/health" >/dev/null 2>&1 && break
  sleep 0.25
done

# 1. health
h="$(curl -s "http://127.0.0.1:${PORT}/v1/health")"
echo "$h" | grep -q '"ok":true' && pass "health 200 ok" || fail "health: $h"

# 2. notify with token
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "X-Notch-Token: $TOKEN" \
  --data '{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"s1"}' \
  "http://127.0.0.1:${PORT}/v1/notify")"
[ "$code" = "200" ] && pass "notify 200" || fail "notify code=$code"

# 3. permission with token -> allow JSON echoing updatedInput
r="$(curl -s -X POST -H "X-Notch-Token: $TOKEN" \
  --data '{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"echo hi","description":"d"}}' \
  "http://127.0.0.1:${PORT}/v1/permission")"
echo "$r" | grep -q '"behavior":"allow"' && \
  echo "$r" | grep -q '"command":"echo hi"' && \
  pass "permission allow + updatedInput echoed" || fail "permission body: $r"

# 4. permission without token -> 403
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  --data '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' \
  "http://127.0.0.1:${PORT}/v1/permission")"
[ "$code" = "403" ] && pass "no-token 403" || fail "no-token code=$code"

# 5. garbage body -> 400
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Notch-Token: $TOKEN" \
  --data 'not json' \
  "http://127.0.0.1:${PORT}/v1/permission")"
[ "$code" = "400" ] && pass "garbage 400" || fail "garbage code=$code"

echo
[ "$FAILED" = "0" ] && echo "all smoke tests passed" || echo "SMOKE TESTS FAILED"
exit "$FAILED"
