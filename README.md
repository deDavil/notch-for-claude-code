# Notch for Claude Code

*A macOS notch overlay that makes Claude Code's permission prompts glanceable — and answerable from your phone.*

A macOS menu-bar/notch app that surfaces Claude Code's **permission prompts** as a
native card sliding out of the MacBook notch. Approve/Deny from the notch (or a
hotkey), and the decision flows back to Claude Code through its hook protocol.
Every prompt is also mirrored to the operator's iPhone over a dedicated Telegram
bot — **first answer wins**, whichever device taps first, and the other is
dismissed. Passive toasts for idle / session-finished notifications.

Target device is a MacBook with a real notch. On a Mac without one, the app
falls back to a virtual-notch pill, so it develops and runs fine anywhere.

## Requirements

- macOS 14 or later (Apple silicon or Intel)
- Swift 6.1+ toolchain (Xcode Command Line Tools is enough — no Xcode project)
- Claude Code, for the hooks to fire against
- *Optional:* a Telegram bot token, only if you want the phone mirror

## Why

Claude Code sessions stall silently when they need a permission decision — the
prompt sits in a terminal tab the operator isn't looking at. This app makes the
"Claude needs you" moment glanceable and answerable from the notch or the phone.

## Features

**Decisions**
- Rich cards per tool: **red/green diff** (Edit/Write/MultiEdit), the full Bash
  command, working directory, and Claude's stated reason.
- **AskUserQuestion** → an answer form (single/multi-select options + free text,
  one Send). **ExitPlanMode** → the plan rendered readably with Approve/Reject.
- Buttons: **Deny · Session · Always · Allow**, plus **✕** (no opinion → falls
  back to the terminal prompt). Hotkeys **⌃⌥Y / ⌃⌥N / ⌃⌥U**.
  - *Session* = auto-approve matching calls for this session; *Always* =
    persist a per-project rule (menu → *Project rules* to list/revoke).
- Multi-session FIFO queue with a badge; a Ctrl-C'd session's card drops on its own.

**Telegram mirror** — every prompt also goes to the operator's phone (dedicated
bot); first answer across devices wins, the message is edited with the outcome.

**Session cockpit** — click the collapsed pill to see every live session
(needs-approval / waiting / working / idle); click a row to **jump to its
hosting app** (Terminal / iTerm / VS Code…).

**Privacy** — menu → *Pause approvals* routes everything to the terminal;
*Auto-pause during calls* does it automatically whenever the mic is in use.

**Audit** — every decision (incl. auto-allows and paused fall-throughs) is
appended to `~/.config/notch-cc/decisions.jsonl` (menu → *Open decision log*).

## Architecture

```
Claude Code (interactive) ──PermissionRequest hook──▶ notch-permission.sh
    └─ POST /v1/permission (long-poll, curl --max-time 590) ─▶ NotchApp
         NotchApp = SwiftUI/AppKit LSUIElement app, NWListener on 127.0.0.1:8790
         ├─ shows notch card + mirrors to Telegram (inline Approve/Deny buttons)
         ├─ first decision (notch click / hotkey / Telegram tap) wins, idempotent
         └─ answers the parked HTTP response with the decision JSON ─▶ hook stdout ─▶ Claude Code
Claude Code ──Notification / Stop hooks──▶ notch-notify.sh ─▶ POST /v1/notify (fire-and-forget) ─▶ toast/status dot
```

Fail-open everywhere: if the app is down / unreachable / slow, the hook script
exits 0 with **no stdout**, and Claude Code falls back to its normal terminal
prompt. The app is an enhancement, never a gate.

## Verified hook facts (probed against Claude Code 2.1.146 / 2.1.217, macOS 15.7, 2026-07-22)

Empirically captured by registering `tee`-style hooks in a scratch project and
driving both headless (`claude -p`) and interactive (expect-driven TUI) sessions,
cross-checked against the CLI binary's own decision-parsing code.

### `PermissionRequest` — the primary hook (interactive only)

- **Fires only in interactive sessions**, exactly when a permission dialog would
  appear (i.e. the tool isn't already allowed/denied by config). It does **not**
  fire under `claude -p` headless — confirmed across multiple runs. This is fine:
  our product path is interactive terminal sessions.
- **Input payload** (captured, verbatim minus `transcript_path`):
  ```json
  {"session_id":"08c8e46d-…","cwd":"/path","permission_mode":"default",
   "effort":{"level":"xhigh"},"hook_event_name":"PermissionRequest",
   "tool_name":"Bash","tool_input":{"command":"echo …","description":"…"},
   "transcript_path":"/Users/…/<session>.jsonl"}
  ```
  Note: **no `tool_use_id`** in the PermissionRequest payload (unlike PreToolUse).
- **Output schema** (from the CLI's own consumer — `H.hookSpecificOutput.decision`):
  ```json
  {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
    "decision":{"behavior":"allow","updatedInput":{…}}}}
  ```
  - `behavior:"allow"` → runs the tool. `updatedInput` optional; if present it
    **replaces** `tool_input` (must round-trip the original faithfully when we
    don't intend to change it), else the original input is used.
  - `behavior:"deny"` → blocks. `message` is the reason shown to Claude
    (`buildDeny(D.message || "Permission denied by hook", …)`). Optional
    `interrupt:true` **aborts the whole turn** (`abortController.abort()`) — we do
    NOT set this; a plain deny lets Claude continue and explain.
  - `behavior:"ask"` → reprompts the user with the normal dialog. Equivalent to
    "no opinion". Our timeout/late-answer path returns **no output** instead
    (exit 0, empty stdout), which is the cleanest fall-through.
- **Registration** uses `"timeout"` (seconds). We set `"timeout": 600` so the app
  can hold the prompt open while the human decides.

### `PreToolUse` — fallback / not used in v1

- Fires on **every** tool call, both headless and interactive. Payload includes
  `tool_use_id`. Output shape differs: `permissionDecision: "allow"|"deny"|"ask"`
  + `permissionDecisionReason`. Because it fires on every call (including
  already-allowed ones), it's noisy for our use — we rely on `PermissionRequest`
  and keep PreToolUse only as a documented fallback for older CLIs.

### `Stop` — session-finished notification

- Fires when Claude finishes responding. Payload:
  `{session_id, cwd, permission_mode, hook_event_name:"Stop", stop_hook_active,
    last_assistant_message, background_tasks:[], session_crons:[], transcript_path}`.

### `Notification`

- Present in the binary (`permission_prompt`, `idle_prompt` types) but did not
  fire in headless probes; treated as best-effort passive input to `/v1/notify`.

## End-to-end verification (walking skeleton, 2026-07-22)

Proven live against a real interactive Claude Code session (`notch-permission.sh`
→ app → decision → Claude):

- **Deny** → the tool is blocked and Claude receives the app's message verbatim:
  transcript shows `{"is_error":true,"content":"Denied via notch (auto)"}`.
- **HTTP protocol** (headless `scripts/smoke-test.sh`, 5/5): health 200; notify
  200; permission **allow echoes `updatedInput` faithfully**
  (`"behavior":"allow"` + original `tool_input`); missing token → 403; malformed
  body → 400.
- **Fail-open**: app down → `notch-permission.sh` returns empty → Claude shows
  its normal terminal prompt (curl `--connect-timeout 1`).

The allow decision uses the identical transport and a schema verified against the
CLI's own consumer; it is validated live by the operator once the notch UI lands.

## Build & run

No Xcode required — pure SwiftPM (Swift 6.1+, macOS 15 SDK) plus a hand-rolled
`.app` assembler.

```bash
# dev on a no-notch Mac (virtual notch pill, runs from source)
scripts/dev-run.sh

# build a distributable .app bundle  -> build/Notch.app (+ .zip)
bundle/make-app.sh

# install on the MacBook (app + hooks + settings merge + LaunchAgent + health check)
./install.sh

# remove everything (add --purge to also delete the app + token)
./uninstall.sh
```

**Deploy to the MacBook:** build here (or on the MacBook), `scp`/`rsync` the
`build/` folder + `hooks/` + `launchd/` + `install.sh`/`uninstall.sh` +
`bundle/` over (scp/rsync set no quarantine xattr), then run `install.sh`. Or
just check out the repo on the MacBook and run `install.sh` (it builds the
bundle if missing). If Gatekeeper ever complains: `xattr -dr
com.apple.quarantine "~/Applications/Notch.app"`.

## Runtime knobs (env)

| Var | Meaning |
|---|---|
| `NOTCH_PORT` | loopback port (default 8790); hook scripts honor it too |
| `NOTCH_TOKEN` | shared token; else `~/.config/notch-cc/token` |
| `NOTCH_VIRTUAL=1` | force the virtual notch pill (dev on no-notch Macs) |
| `NOTCH_DIALOG=1` | use an `osascript` dialog instead of the notch UI |
| `NOTCH_AUTOPAUSE=0` | disable auto-pause-during-calls (mic-in-use) at launch |
| `NOTCH_AUTO=allow\|deny\|noop` | headless auto-resolve (CI/smoke) |
| `NOTCH_SELFTEST=1` | run unit self-tests and exit |
| `NOTCH_TELEGRAM_BASE` | override Bot API base (mock tests) |

## Tests

```bash
scripts/verify.sh                # ← run everything: build + self-tests + all suites (one gate)
scripts/verify.sh --install-hook # gate every push on the suite (git pre-push hook)

# individual suites:
scripts/smoke-test.sh            # unit self-tests + HTTP protocol (health/allow/403/400)
scripts/telegram-mock-test.sh    # relay round-trip vs a mock Bot API
scripts/settings-merge-test.sh   # install/uninstall jq merge: idempotent + clean round-trip
scripts/hostapp-test.sh          # notify hook attaches hosting-app pid/comm
scripts/single-instance-test.sh  # duplicate instance exits cleanly, first keeps serving
```

There is no cloud CI — the suites drive a real loopback server and a real app
bundle, so they want a Mac. `verify.sh` is the gate: run it before pushing, or
install it as a pre-push hook.

## Layout

```
notch/
  Package.swift                Sources/NotchApp/{Models,Server,State,Remote,Window,Views,Support}
  hooks/notch-permission.sh    hooks/notch-notify.sh          # fail-open curl bridges
  bundle/make-app.sh           bundle/Info.plist.template     # no-Xcode .app assembler
  launchd/…notch.plist.template
  install.sh  uninstall.sh     scripts/{dev-run,smoke-test,telegram-mock-test,settings-merge-test}.sh
```

## Telegram relay

Every pending prompt is mirrored to the operator's phone as a Telegram message
with **Approve / Session / Deny** inline buttons. The Mac app stays the single
arbiter: a tap calls `store.resolve` (idempotent), so **the first answer — notch
click, hotkey, or phone tap — wins**, the notch card dismisses, and the Telegram
message is edited to the outcome ("✅ Approved · from iPhone"); a late tap on the
other device gets "Already handled".

Setup (operator, one-time):

1. Create a **dedicated** bot with [@BotFather](https://t.me/BotFather) →
   `/newbot`. Do **not** reuse the runtime's bot — Telegram allows only one
   `getUpdates` consumer per token.
2. Get your numeric user id (e.g. via [@userinfobot](https://t.me/userinfobot))
   and start a chat with your new bot.
3. Write `~/.config/notch-cc/telegram.json` (chmod 600):
   ```json
   { "token": "123456:ABC-…", "chat_id": <your id>, "operator_id": <your id> }
   ```
   `operator_id` restricts who may tap the buttons. Absent file → relay silently
   off, Mac-only path fully works.

Validated end-to-end against a mock Bot API (`scripts/telegram-mock-test.sh`):
announce → `sendMessage` (3 buttons) → scripted callback resolves the parked
permission (allow, first-wins) → `editMessageText` settle → `answerCallbackQuery`.

## Licence

MIT — see [LICENSE](LICENSE).

## Notes

Not affiliated with, endorsed by, or supported by Anthropic. It talks to Claude
Code purely through the documented hook protocol, and it is deliberately
fail-open: if the app is not running, Claude Code prompts in the terminal as
usual.

The hook behaviour documented above was probed empirically against specific
Claude Code builds (noted inline). Treat those findings as observations with a
date on them, not as a stable public contract.
