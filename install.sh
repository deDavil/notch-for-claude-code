#!/usr/bin/env bash
# Install the notch companion app on THIS Mac (intended: the MacBook with a real
# notch). Idempotent and machine-portable — runs from a repo checkout or from an
# unpacked distribution folder containing build/, hooks/, and launchd/.
#
# Does five things:
#   1. copy "Klavs Notch.app" -> ~/Applications
#   2. copy hook scripts       -> ~/.claude/hooks/notch/
#   3. ensure a shared token   -> ~/.config/klavs-notch/token   (app + hooks read it)
#   4. MERGE hook registration -> ~/.claude/settings.json       (backup + validate)
#   5. install + bootstrap the LaunchAgent, then health-check
#
# The settings.json merge is additive-only and never touches existing hooks.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Klavs Notch"
LABEL="com.atvereklavs.notch"

APPS_DIR="${HOME}/Applications"
HOOKS_DIR="${HOME}/.claude/hooks/notch"
CFG_DIR="${HOME}/.config/klavs-notch"
SETTINGS="${HOME}/.claude/settings.json"
LA_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR="${HOME}/Library/Logs/klavs-notch"
DEST_PLIST="${LA_DIR}/${LABEL}.plist"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required for the safe settings.json merge." >&2; exit 1; }

# --- 1. locate / build the app bundle --------------------------------------
# Always rebuild when a toolchain is present so `git pull && ./install.sh`
# actually ships the new code; fall back to a prebuilt bundle only if swift
# is unavailable (e.g. installing from an unpacked distribution).
APP_SRC="${HERE}/build/${APP_NAME}.app"
if command -v swift >/dev/null 2>&1 && [[ -f "${HERE}/bundle/make-app.sh" ]]; then
  echo "==> building app bundle (this can take a minute)"
  ( cd "$HERE" && bash bundle/make-app.sh >/dev/null )
elif [[ ! -d "$APP_SRC" ]]; then
  echo "ERROR: ${APP_SRC} not found and cannot build (no swift / make-app.sh)." >&2
  exit 1
fi

mkdir -p "$APPS_DIR" "$HOOKS_DIR" "$CFG_DIR" "$LA_DIR" "$LOG_DIR"

echo "==> installing app -> ${APPS_DIR}/${APP_NAME}.app"
rm -rf "${APPS_DIR}/${APP_NAME}.app"
cp -R "$APP_SRC" "${APPS_DIR}/"
APP_BIN="${APPS_DIR}/${APP_NAME}.app/Contents/MacOS/NotchApp"

echo "==> installing hook scripts -> ${HOOKS_DIR}"
cp "${HERE}/hooks/notch-permission.sh" "${HERE}/hooks/notch-notify.sh" "$HOOKS_DIR/"
chmod +x "${HOOKS_DIR}/notch-permission.sh" "${HOOKS_DIR}/notch-notify.sh"

# --- 3. shared token --------------------------------------------------------
TOKEN_FILE="${CFG_DIR}/token"
if [[ -s "$TOKEN_FILE" ]]; then
  echo "==> token already present (${TOKEN_FILE})"
else
  python3 -c 'import secrets; print(secrets.token_urlsafe(24))' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "==> generated shared token (${TOKEN_FILE})"
fi

# --- 4. merge hook registration into settings.json (safe) -------------------
PERM_CMD="${HOOKS_DIR}/notch-permission.sh"
NOTIFY_CMD="${HOOKS_DIR}/notch-notify.sh"

echo "==> merging hooks into ${SETTINGS}"
CURRENT="{}"
if [[ -f "$SETTINGS" ]]; then
  cp "$SETTINGS" "${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
  CURRENT="$(cat "$SETTINGS")"
fi

MERGED="$(printf '%s' "$CURRENT" | jq \
  --arg perm "$PERM_CMD" --arg notify "$NOTIFY_CMD" '
  def has_notch(ev): ([ (.hooks[ev] // [])[] | .hooks[]?.command ]
                      | map(select(. != null)) | any(test("hooks/notch/")));
  (.hooks //= {}) |
  (if has_notch("PermissionRequest") then .
   else .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) +
        [{matcher:"*", hooks:[{type:"command", command:$perm, timeout:600}]}]) end) |
  (if has_notch("Notification") then .
   else .hooks.Notification = ((.hooks.Notification // []) +
        [{matcher:"", hooks:[{type:"command", command:$notify}]}]) end) |
  (if has_notch("Stop") then .
   else .hooks.Stop = ((.hooks.Stop // []) +
        [{matcher:"", hooks:[{type:"command", command:$notify}]}]) end)
')" || { echo "ERROR: jq merge failed; settings.json left untouched." >&2; exit 1; }

# Validate before writing.
printf '%s' "$MERGED" | jq empty || { echo "ERROR: merged settings invalid; not written." >&2; exit 1; }
printf '%s\n' "$MERGED" > "${SETTINGS}.tmp.$$"
mv "${SETTINGS}.tmp.$$" "$SETTINGS"
echo "    hooks registered (PermissionRequest timeout=600, Notification, Stop)"

# --- 5. LaunchAgent ---------------------------------------------------------
echo "==> installing LaunchAgent ${LABEL}"
sed -e "s|__APP_BIN__|${APP_BIN}|g" -e "s|__LOG_DIR__|${LOG_DIR}|g" \
    "${HERE}/launchd/${LABEL}.plist.template" > "$DEST_PLIST"
plutil -lint "$DEST_PLIST" >/dev/null

if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
fi
launchctl bootstrap "gui/$(id -u)" "$DEST_PLIST"

# --- health check -----------------------------------------------------------
PORT="${NOTCH_PORT:-8790}"
sleep 1
if curl -s "http://127.0.0.1:${PORT}/v1/health" | grep -q '"ok":true'; then
  echo "==> ✓ app is up (http://127.0.0.1:${PORT}/v1/health)"
else
  echo "==> ⚠ app not answering yet on :${PORT} — check ${LOG_DIR}/notch.err.log"
fi

echo
echo "Done. Note: already-running Claude Code sessions must be RESTARTED to pick"
echo "up the new hooks. New sessions get the notch overlay automatically."
echo "Telegram mirror (optional): see notch/README.md → 'Telegram relay'."
echo "Uninstall: ${HERE}/uninstall.sh   (add --purge to also remove app + token)"
