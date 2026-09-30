#!/usr/bin/env bash
# Blocking permission hook for Claude Code. Forwards the hook's stdin JSON to the
# notch app and echoes the app's decision JSON on stdout. FAIL-OPEN: if the app
# is unreachable, times out, or returns nothing, we exit 0 with no output, and
# Claude Code falls back to its normal terminal prompt. This hook never blocks
# tool execution on its own error.
#
# Registered on the PermissionRequest event (interactive sessions) with
# "timeout": 600 so the app can hold the prompt open while the human decides.
set -u

PORT="${NOTCH_PORT:-8790}"
TOKEN_FILE="${HOME}/.config/notch-cc/token"
token=""
[ -r "${TOKEN_FILE}" ] && token="$(cat "${TOKEN_FILE}" 2>/dev/null || true)"

response="$(curl -sS \
  --connect-timeout 1 --max-time 590 \
  -H "Content-Type: application/json" \
  -H "X-Notch-Token: ${token}" \
  --data-binary @- \
  "http://127.0.0.1:${PORT}/v1/permission" 2>/dev/null || true)"

# Only emit if the app returned a decision; empty => no opinion => terminal prompt.
[ -n "${response}" ] && printf '%s' "${response}"
exit 0
