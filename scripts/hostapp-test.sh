#!/usr/bin/env bash
# Verify notch-notify.sh augments the payload with host_pid/host_comm from its
# process ancestry, without disturbing the original fields. Uses a tiny capture
# server on an ephemeral port; no app involved.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT=8801
STATE="$(mktemp -d)"
trap 'kill "$SRV" 2>/dev/null; rm -rf "$STATE"' EXIT
FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

python3 - "$STATE" $PORT <<'PY' &
import http.server, json, sys, os
STATE, PORT = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        open(os.path.join(STATE, 'captured.json'), 'wb').write(self.rfile.read(n))
        self.send_response(200); self.end_headers()
http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
PY
SRV=$!
sleep 0.5

printf '{"hook_event_name":"SessionStart","session_id":"host-test","cwd":"/tmp/x"}' \
  | NOTCH_PORT=$PORT bash hooks/notch-notify.sh
# the hook backgrounds its POST; give it a moment
for _ in $(seq 1 20); do [ -s "$STATE/captured.json" ] && break; sleep 0.25; done

if [ ! -s "$STATE/captured.json" ]; then
  fail "hook never POSTed"
else
  orig_ok="$(jq -r '.session_id == "host-test" and .cwd == "/tmp/x"' "$STATE/captured.json")"
  host_pid="$(jq -r '.host_pid // empty' "$STATE/captured.json")"
  host_comm="$(jq -r '.host_comm // empty' "$STATE/captured.json")"
  [ "$orig_ok" = "true" ] && pass "original fields intact" || fail "original fields changed"
  case "$host_pid" in
    ''|*[!0-9]*) fail "host_pid missing/non-numeric: '$host_pid'" ;;
    *) ps -p "$host_pid" >/dev/null 2>&1 && pass "host_pid ($host_pid) is a live process" \
        || fail "host_pid $host_pid not alive" ;;
  esac
  [ -n "$host_comm" ] && pass "host_comm present: $host_comm" || fail "host_comm missing"
fi

echo
[ "$FAILED" = "0" ] && echo "hostapp test passed" || echo "HOSTAPP TEST FAILED"
exit "$FAILED"
