#!/usr/bin/env bash
# Verify the Telegram poll loop BACKS OFF on a failing getUpdates (e.g. an
# invalid token → {"ok":false}) instead of hot-looping. A mock returns ok:false
# for every getUpdates and counts the hits over a fixed window; with backoff the
# count stays small, without it the relay would poll every ~300ms.
set -uo pipefail
cd "$(dirname "$0")/.."

APP=8805; TG=8806
STATE="$(mktemp -d)"
trap 'kill "$MOCK" "$AP" 2>/dev/null; rm -f "$HOME/.config/klavs-notch/telegram.json"; [ -n "${BACKUP:-}" ] && mv "$BACKUP" "$HOME/.config/klavs-notch/telegram.json"; rm -rf "$STATE"' EXIT
FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

# Mock Bot API: every getUpdates → 200 with an ok:false (401-style) body; count hits.
cat > "$STATE/mock.py" <<PY
import http.server, json, sys, os
STATE=sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        n=int(self.headers.get('Content-Length',0)); self.rfile.read(n)
        m=self.path.rsplit('/',1)[-1]
        if m=='getUpdates':
            with open(os.path.join(STATE,'hits'),'a') as f: f.write('.')
            body={"ok":False,"error_code":401,"description":"Unauthorized"}
        else:
            body={"ok":True,"result":True}
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
http.server.HTTPServer(('127.0.0.1',$TG),H).serve_forever()
PY
python3 "$STATE/mock.py" "$STATE" & MOCK=$!
sleep 0.4

mkdir -p "$HOME/.config/klavs-notch"
CFG="$HOME/.config/klavs-notch/telegram.json"
[ -f "$CFG" ] && { BACKUP="$CFG.bak.$$"; mv "$CFG" "$BACKUP"; }
printf '{"token":"bad","chat_id":1,"operator_id":1}' > "$CFG"; chmod 600 "$CFG"

swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }
BIN="$(swift build --show-bin-path)/NotchApp"
NOTCH_PORT=$APP NOTCH_TOKEN=t NOTCH_VIRTUAL=1 NOTCH_TELEGRAM_BASE="http://127.0.0.1:$TG" "$BIN" >/dev/null 2>&1 &
AP=$!
for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$APP/v1/health" >/dev/null 2>&1 && break; sleep 0.25; done

# Observe getUpdates hits over ~5s. Backoff schedule: t0, t1, t3 → ~3 hits.
# A hot loop (300ms) would be ~15+.
sleep 5
hits=$(wc -c < "$STATE/hits" 2>/dev/null | tr -d ' ' || echo 0)
echo "  getUpdates hits in 5s: $hits"
if [ "$hits" -ge 1 ] && [ "$hits" -le 6 ]; then
  pass "poll loop backs off on ok:false ($hits hits, not a hot loop)"
else
  fail "expected 1-6 hits with backoff, got $hits (hot loop?)"
fi

echo
[ "$FAILED" = "0" ] && echo "telegram backoff test passed" || echo "TELEGRAM BACKOFF TEST FAILED"
exit "$FAILED"
