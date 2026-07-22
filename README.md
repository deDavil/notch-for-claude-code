# notch — Notch-overlay companion for Claude Code

A macOS menu-bar/notch app that surfaces Claude Code's **permission prompts** as a
native card sliding out of the MacBook notch. Approve/Deny from the notch (or a
hotkey), and the decision flows back to Claude Code through its hook protocol.
Every prompt is also mirrored to the operator's iPhone over a dedicated Telegram
bot — **first answer wins**, whichever device taps first, and the other is
dismissed. Passive toasts for idle / session-finished notifications.

Target device is a MacBook with a real notch. Development happens on a no-notch
Mac (this repo's Mac mini) via a virtual-notch fallback pill.

## Why

Claude Code sessions stall silently when they need a permission decision — the
prompt sits in a terminal tab the operator isn't looking at. This app makes the
"Claude needs you" moment glanceable and answerable from the notch or the phone.

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

## Build & run

No Xcode required — pure SwiftPM (Swift 6.1+, macOS 15 SDK) plus a hand-rolled
`.app` assembler.

```bash
# dev (virtual notch, runs from source)
notch/scripts/dev-run.sh

# build a distributable .app bundle
notch/bundle/make-app.sh

# install on the MacBook (app + hooks + settings merge + LaunchAgent)
notch/install.sh
```

See `bundle/make-app.sh` and `install.sh` headers for details. Shipping to the
MacBook: `scp`/`rsync` the `.app` (neither sets a quarantine xattr), then
`ditto -x -k` any zip. If Gatekeeper ever complains, `xattr -dr
com.apple.quarantine "Klavs Notch.app"`.

## Telegram relay

Optional. Configure `~/.config/klavs-notch/telegram.json`
(`{"token":"…","chat_id":123}`, chmod 600) with a **dedicated** bot from
BotFather (do not reuse the runtime's bot — Telegram allows one `getUpdates`
consumer per token). Absent config → relay silently off, Mac-only path fully
works.
