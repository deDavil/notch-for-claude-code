#!/usr/bin/env bash
# Verify the single-instance guard: a second app on the same port must exit 0
# quickly with a clear message, while the first instance keeps serving.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT=8803
FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }
BIN="$(swift build --show-bin-path)/NotchApp"

NOTCH_PORT=$PORT NOTCH_TOKEN=t NOTCH_AUTO=allow NOTCH_VIRTUAL=1 "$BIN" >/dev/null 2>&1 &
A=$!
trap 'kill "$A" 2>/dev/null || true' EXIT
for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -s "http://127.0.0.1:$PORT/v1/health" | grep -q '"ok":true' && pass "instance A healthy" || fail "A not healthy"

# Second instance on the same port: must exit 0 within ~10s with the message.
ERRLOG="$(mktemp)"
NOTCH_PORT=$PORT NOTCH_TOKEN=t NOTCH_VIRTUAL=1 "$BIN" 2>"$ERRLOG" &
B=$!
B_EXIT=""
for _ in $(seq 1 40); do
  if ! kill -0 "$B" 2>/dev/null; then wait "$B"; B_EXIT=$?; break; fi
  sleep 0.25
done
if [ -z "$B_EXIT" ]; then
  kill "$B" 2>/dev/null; fail "instance B did not exit (zombie duplicate)"
else
  [ "$B_EXIT" = "0" ] && pass "instance B exited 0" || fail "instance B exit code $B_EXIT"
  grep -q "another instance is already serving" "$ERRLOG" \
    && pass "clear duplicate message on stderr" || fail "message missing: $(cat "$ERRLOG")"
fi

# A must still be serving.
curl -s "http://127.0.0.1:$PORT/v1/health" | grep -q '"ok":true' \
  && pass "instance A unaffected" || fail "A died"

rm -f "$ERRLOG"
echo
[ "$FAILED" = "0" ] && echo "single-instance test passed" || echo "SINGLE-INSTANCE TEST FAILED"
exit "$FAILED"
