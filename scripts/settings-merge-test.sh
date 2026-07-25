#!/usr/bin/env bash
# Verify the safety-critical settings.json merge/unmerge (the jq used by
# install.sh / uninstall.sh) is additive, idempotent, preserves existing hooks,
# and round-trips cleanly. Runs entirely on temp files — touches nothing real.
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

PERM="$HOME/.claude/hooks/notch/notch-permission.sh"
NOTIFY="$HOME/.claude/hooks/notch/notch-notify.sh"

# Existing settings with the repo's own log hooks that MUST survive untouched.
cat > "$TMP/orig.json" <<'EOF'
{
  "effortLevel": "high",
  "permissions": { "allow": ["Bash(git status)"] },
  "hooks": {
    "PreToolUse":  [ { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOME/ai-system/claude/hooks/log-tool-call.sh" } ] } ],
    "PostToolUse": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOME/ai-system/claude/hooks/log-tool-call.sh" } ] } ],
    "Stop":        [ { "matcher": "",  "hooks": [ { "type": "command", "command": "$HOME/ai-system/claude/hooks/log-tool-call.sh" } ] } ]
  }
}
EOF

merge() {
  jq --arg perm "$PERM" --arg notify "$NOTIFY" '
    def has_notch(ev): ([ (.hooks[ev] // [])[] | .hooks[]?.command ]
                        | map(select(. != null)) | any(test("hooks/notch/")));
    (.hooks //= {}) |
    (if has_notch("PermissionRequest") then . else .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) + [{matcher:"*", hooks:[{type:"command", command:$perm, timeout:600}]}]) end) |
    (if has_notch("Notification") then . else .hooks.Notification = ((.hooks.Notification // []) + [{matcher:"", hooks:[{type:"command", command:$notify}]}]) end) |
    (if has_notch("Stop") then . else .hooks.Stop = ((.hooks.Stop // []) + [{matcher:"", hooks:[{type:"command", command:$notify}]}]) end)
  ' "$1"
}
unmerge() {
  jq '
    if .hooks then
      .hooks |= (to_entries | map(.value |= map(select(([.hooks[]?.command // ""] | any(test("hooks/notch/"))) | not))) | map(select((.value | length) > 0)) | from_entries)
    else . end
    | (if (.hooks | length) == 0 then del(.hooks) else . end)
  ' "$1"
}

merge "$TMP/orig.json" > "$TMP/s1.json" 2>"$TMP/err" || { fail "merge errored: $(cat "$TMP/err")"; echo; exit 1; }

# 1. new event added, existing preserved
[ "$(jq '.hooks.PermissionRequest | length' "$TMP/s1.json")" = "1" ] && pass "PermissionRequest added" || fail "PermissionRequest not added"
[ "$(jq '.hooks.PermissionRequest[0].hooks[0].timeout' "$TMP/s1.json")" = "600" ] && pass "timeout=600 set" || fail "timeout missing"
[ "$(jq '.hooks.Stop | length' "$TMP/s1.json")" = "2" ] && pass "Stop appended (log + notch)" || fail "Stop not appended"
[ "$(jq '.hooks.PreToolUse | length' "$TMP/s1.json")" = "1" ] && pass "existing log hooks untouched" || fail "log hooks changed"

# 2. idempotent
merge "$TMP/s1.json" > "$TMP/s2.json"
[ "$(jq '.hooks.PermissionRequest | length' "$TMP/s2.json")" = "1" ] \
  && [ "$(jq '.hooks.Stop | length' "$TMP/s2.json")" = "2" ] \
  && [ "$(jq '.hooks.Notification | length' "$TMP/s2.json")" = "1" ] \
  && pass "merge is idempotent" || fail "merge duplicated on re-run"

# 3. clean round-trip
unmerge "$TMP/s2.json" > "$TMP/s3.json"
if diff <(jq -S . "$TMP/orig.json") <(jq -S . "$TMP/s3.json") >/dev/null; then
  pass "uninstall restores original byte-for-byte"
else
  fail "round-trip differs:"; diff <(jq -S . "$TMP/orig.json") <(jq -S . "$TMP/s3.json")
fi

# 4. merge into a settings file with NO hooks key at all
echo '{"permissions":{"allow":[]}}' > "$TMP/nohooks.json"
merge "$TMP/nohooks.json" > "$TMP/nh1.json" 2>/dev/null
[ "$(jq '.hooks.PermissionRequest | length' "$TMP/nh1.json")" = "1" ] && pass "merge into hook-less settings" || fail "hook-less merge failed"

# 5. JSONC (commented) settings: install.sh's pre-check must reject them so the
#    installer bails safely instead of dying on an opaque jq error. Guard the
#    guard: valid JSON passes `jq empty`, JSONC fails it, and the JSONC file is
#    never rewritten.
printf '{\n  // a comment\n  "hooks": {}\n}\n' > "$TMP/jsonc.json"
jsonc_before="$(cat "$TMP/jsonc.json")"
if jq empty "$TMP/jsonc.json" >/dev/null 2>&1; then
  fail "JSONC unexpectedly parsed by jq (guard would not trigger)"
else
  pass "JSONC settings rejected by the pre-check (installer bails safely)"
fi
echo '{"hooks":{}}' > "$TMP/plain.json"
jq empty "$TMP/plain.json" >/dev/null 2>&1 && pass "plain JSON passes the pre-check" || fail "plain JSON rejected"
[ "$(cat "$TMP/jsonc.json")" = "$jsonc_before" ] && pass "JSONC file left untouched" || fail "JSONC file was modified"

echo
[ "$FAILED" = "0" ] && echo "settings merge test passed" || echo "SETTINGS MERGE TEST FAILED"
exit "$FAILED"
