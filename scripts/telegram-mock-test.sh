#!/usr/bin/env bash
# Integration test for the Telegram relay against a MOCK Bot API (no real bot).
# Validates: announce -> sendMessage (correct buttons); a scripted callback_query
# resolves the parked permission (first-wins); settle -> editMessageText.
set -uo pipefail
cd "$(dirname "$0")/.."

APP_PORT=8795
TG_PORT=8796
TOKEN="notch-http-$$"
CFG_DIR="$HOME/.config/notch-cc"
CFG="$CFG_DIR/telegram.json"
STATE="$(mktemp -d)"
FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

# --- mock Telegram Bot API -------------------------------------------------
cat > "$STATE/mock.py" <<PY
import http.server, json, sys, os, threading
STATE = sys.argv[1]
REQ_ID = {"v": None}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n) or b'{}')
        method = self.path.rsplit('/', 1)[-1]
        with open(os.path.join(STATE, 'calls.jsonl'), 'a') as f:
            f.write(json.dumps({"method": method, "body": body}) + "\n")
        result = True
        if method == 'sendMessage':
            # capture the request UUID from the first button's callback_data
            try:
                cd = body['reply_markup']['inline_keyboard'][0][0]['callback_data']
                REQ_ID['v'] = cd.split(':')[1]
            except Exception:
                pass
            result = {"message_id": 4242}
        elif method == 'getUpdates':
            # Once we know the req id, emit a single 'allow' callback, then nothing.
            off = body.get('offset', 0)
            if REQ_ID['v'] and off <= 1000:
                result = [{
                    "update_id": 1000,
                    "callback_query": {
                        "id": "cbq1",
                        "from": {"id": 777},
                        "data": "req:%s:allow" % REQ_ID['v'],
                    }
                }]
            else:
                result = []
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({"ok": True, "result": result}).encode())
httpd = http.server.HTTPServer(('127.0.0.1', ${TG_PORT}), H)
httpd.serve_forever()
PY
python3 "$STATE/mock.py" "$STATE" &
MOCK_PID=$!

# --- config the relay to point at the mock ---------------------------------
mkdir -p "$CFG_DIR"
BACKUP=""
if [ -f "$CFG" ]; then BACKUP="$CFG.bak.$$"; mv "$CFG" "$BACKUP"; fi
printf '{"token":"%s","chat_id":777,"operator_id":777}\n' "$TOKEN" > "$CFG"
chmod 600 "$CFG"

cleanup() {
  kill "$MOCK_PID" "$APP_PID" 2>/dev/null || true
  rm -f "$CFG"
  [ -n "$BACKUP" ] && mv "$BACKUP" "$CFG"
  rm -rf "$STATE"
}
trap cleanup EXIT

# --- run the app -----------------------------------------------------------
swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }
BIN="$(swift build --show-bin-path)/NotchApp"
NOTCH_PORT="$APP_PORT" NOTCH_TOKEN="apptok" NOTCH_VIRTUAL=1 \
  NOTCH_TELEGRAM_BASE="http://127.0.0.1:${TG_PORT}" "$BIN" >"$STATE/app.log" 2>&1 &
APP_PID=$!
for _ in $(seq 1 40); do curl -s "http://127.0.0.1:${APP_PORT}/v1/health" >/dev/null 2>&1 && break; sleep 0.25; done

# Park a permission request; the mock will "tap Approve" for us.
resp="$(curl -s -X POST -H "X-Notch-Token: apptok" \
  --data '{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/tmp/demo","tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
  "http://127.0.0.1:${APP_PORT}/v1/permission")"

echo "$resp" | grep -q '"behavior":"allow"' \
  && pass "telegram callback resolved the parked request (allow)" \
  || fail "expected allow from telegram tap, got: $resp"

sleep 1  # let settle() fire editMessageText
calls="$STATE/calls.jsonl"
grep -q '"method": "sendMessage"' "$calls" && pass "announce sent sendMessage" || fail "no sendMessage"
python3 - "$calls" <<'PY' && pass "sendMessage carried Approve/Deny + Session/Always rows" || fail "buttons missing"
import json,sys
for line in open(sys.argv[1]):
    c=json.loads(line)
    if c["method"]=="sendMessage":
        rows=c["body"]["reply_markup"]["inline_keyboard"]
        total=sum(len(r) for r in rows)
        verbs={b["callback_data"].rsplit(":",1)[-1] for r in rows for b in r}
        sys.exit(0 if total==4 and verbs=={"allow","deny","session","project"} else 1)
sys.exit(1)
PY
grep -q '"method": "editMessageText"' "$calls" && pass "settle edited the message" || fail "no editMessageText"
grep -q '"method": "answerCallbackQuery"' "$calls" && pass "callback acknowledged" || fail "no answerCallbackQuery"

echo
[ "$FAILED" = "0" ] && echo "telegram mock test passed" || echo "TELEGRAM MOCK TEST FAILED"
exit "$FAILED"
