#!/usr/bin/env bash
# Fire-and-forget notification hook for Claude Code. Feeds the notch app's
# session cockpit (SessionStart / UserPromptSubmit / Stop / SessionEnd / idle
# notifications). FAIL-OPEN and truly non-blocking: the POST is backgrounded so
# it adds ZERO latency to high-frequency events like UserPromptSubmit, even if
# the app is down. Always exits 0 immediately.
set -u

PORT="${NOTCH_PORT:-8790}"
TOKEN_FILE="${HOME}/.config/klavs-notch/token"
token=""
[ -r "${TOKEN_FILE}" ] && token="$(cat "${TOKEN_FILE}" 2>/dev/null || true)"
input="$(cat 2>/dev/null || true)"

# Background subshell: the hook returns instantly; the POST completes on its own.
(
  printf '%s' "${input}" | curl -sS --connect-timeout 1 --max-time 3 \
    -H "Content-Type: application/json" \
    -H "X-Notch-Token: ${token}" \
    --data-binary @- \
    "http://127.0.0.1:${PORT}/v1/notify" >/dev/null 2>&1 || true
) &

exit 0
