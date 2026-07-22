#!/usr/bin/env bash
# Remove the notch companion app: LaunchAgent, hook registration, and hook
# scripts. Reverses install.sh. Pass --purge to also delete the app bundle and
# the shared token. The settings.json edit is backed up + validated like install.
set -euo pipefail

LABEL="com.atvereklavs.notch"
APP_NAME="Klavs Notch"
HOOKS_DIR="${HOME}/.claude/hooks/notch"
CFG_DIR="${HOME}/.config/klavs-notch"
SETTINGS="${HOME}/.claude/settings.json"
DEST_PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
APP="${HOME}/Applications/${APP_NAME}.app"

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required." >&2; exit 1; }

echo "==> unloading LaunchAgent ${LABEL}"
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
rm -f "$DEST_PLIST"

# Kill any running instance.
pkill -f "${APP_NAME}.app/Contents/MacOS/NotchApp" 2>/dev/null || true

if [[ -f "$SETTINGS" ]]; then
  echo "==> removing notch hooks from ${SETTINGS}"
  cp "$SETTINGS" "${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
  CLEANED="$(jq '
    if .hooks then
      .hooks |= (to_entries
        | map(.value |= map(select(([.hooks[]?.command // ""] | any(test("hooks/notch/"))) | not)))
        | map(select((.value | length) > 0))   # drop now-empty event arrays
        | from_entries)
    else . end
    | (if (.hooks | length) == 0 then del(.hooks) else . end)
  ' "$SETTINGS")" || { echo "ERROR: jq filter failed; settings left untouched." >&2; exit 1; }
  printf '%s' "$CLEANED" | jq empty || { echo "ERROR: result invalid; not written." >&2; exit 1; }
  printf '%s\n' "$CLEANED" > "${SETTINGS}.tmp.$$"
  mv "${SETTINGS}.tmp.$$" "$SETTINGS"
fi

echo "==> removing hook scripts ${HOOKS_DIR}"
rm -rf "$HOOKS_DIR"

if [[ "$PURGE" == "1" ]]; then
  echo "==> --purge: removing app + token"
  rm -rf "$APP"
  rm -f "${CFG_DIR}/token"
  rmdir "$CFG_DIR" 2>/dev/null || true
else
  echo "    (kept ${APP} and ${CFG_DIR}/token — pass --purge to remove)"
fi

echo "Done. Restart Claude Code sessions to drop the hooks fully."
