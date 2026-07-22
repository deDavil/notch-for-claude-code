#!/usr/bin/env bash
# Fire-and-forget notification hook for Claude Code (Notification / Stop events).
# Forwards the stdin JSON to the notch app and returns immediately. FAIL-OPEN and
# fast: never blocks, always exits 0.
set -u

PORT="${NOTCH_PORT:-8790}"
TOKEN_FILE="${HOME}/.config/klavs-notch/token"
token=""
[ -r "${TOKEN_FILE}" ] && token="$(cat "${TOKEN_FILE}" 2>/dev/null || true)"

curl -sS --connect-timeout 1 --max-time 2 \
  -H "Content-Type: application/json" \
  -H "X-Notch-Token: ${token}" \
  --data-binary @- \
  "http://127.0.0.1:${PORT}/v1/notify" >/dev/null 2>&1 || true
exit 0
