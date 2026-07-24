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

# Attach the hosting GUI app (Terminal / iTerm / VS Code / …) by walking this
# script's process ancestry up to launchd: the last ancestor before pid 1 is
# the app that owns this Claude session. Powers the cockpit's jump-to-session.
# Best-effort: any failure leaves the payload untouched.
if command -v jq >/dev/null 2>&1; then
  snapshot="$(ps -axo pid=,ppid=,comm= 2>/dev/null || true)"
  if [ -n "${snapshot}" ]; then
    host="$(printf '%s\n' "${snapshot}" | awk -v start="$$" '
      # comm (macOS ps) is a full exe path that may contain spaces, so
      # reconstruct it from field 3..NF rather than taking $3 (which truncates
      # e.g. "/Applications/Visual Studio Code.app/..." at the first space).
      { pid[$1] = $2; c = ""; for (i = 3; i <= NF; i++) c = c (i > 3 ? " " : "") $i; cmd[$1] = c }
      END {
        p = start
        for (i = 0; i < 40; i++) {
          pp = pid[p]
          if (pp == "" || pp == 0) break
          if (pp == 1) { printf "%s\t%s", p, cmd[p]; break }
          p = pp
        }
      }')"
    if [ -n "${host}" ]; then
      host_pid="${host%%	*}"
      host_comm="${host#*	}"
      augmented="$(printf '%s' "${input}" | jq -c --argjson hp "${host_pid}" --arg hc "${host_comm}" \
        '. + {host_pid: $hp, host_comm: $hc}' 2>/dev/null || true)"
      [ -n "${augmented}" ] && input="${augmented}"
    fi
  fi
fi

# Background subshell: the hook returns instantly; the POST completes on its own.
(
  printf '%s' "${input}" | curl -sS --connect-timeout 1 --max-time 3 \
    -H "Content-Type: application/json" \
    -H "X-Notch-Token: ${token}" \
    --data-binary @- \
    "http://127.0.0.1:${PORT}/v1/notify" >/dev/null 2>&1 || true
) &

exit 0
