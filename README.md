# headsup

Run a fleet of Claude Code tabs without losing track of a single one. headsup makes every tab's state glanceable in iTerm2, WezTerm, or AI Power Term, tells you how close you are to Anthropic usage limits before throttling, checkpoints any window for later with `/sfl`, and restores the whole fleet where it left off with `/nil`.

Twenty tabs deep. You hear the Dock bounce. You glance at the tab bar. One tab is orange. That's [Claude Code](https://claude.com/claude-code) asking you a question. You switch over, answer it, watch it turn blue again, move on. And when you shut the lid for the night, `/sfl` saves each window's state. The next morning, one `/nil` reopens every saved window in its own labeled tab, and each one catches itself up and asks what's next.

![/nil restoring a fleet of saved Claude Code tabs](docs/nil-demo.gif)

Under the hood: Claude Code hooks, Codex hooks, a persistent iTerm2 daemon, a launchd watchdog, a tiny notifier `.app` for macOS notifications, a live status bar that surfaces session and weekly quota consumption in real time, and twelve companion skills you can run from any Claude session (including a ⌘⌥C Finder Quick Action that opens a new labeled Claude tab from any folder). macOS only, with native support for iTerm2, WezTerm, and AI Power Term. One-line install for Claude, separate opt-in install for Codex.

**Terminal support.** headsup started on iTerm2 and now drives three terminals from one codebase. Every session hook auto-detects the active terminal (`ITERM_SESSION_ID`, `WEZTERM_PANE`, or `AI_POWER_TERM_SESSION_ID`) and applies state the native way for each:

| Terminal | Tab color | Label / title | Status bar | `/nil` reopen |
|----------|-----------|---------------|------------|---------------|
| iTerm2 | daemon over the Python API | OSC badge + title | full | AppleScript |
| WezTerm | `format-tab-title` from user vars (`wezterm/wezterm.lua`) | user-var label | full | `wezterm cli` |
| AI Power Term | app server state | websocket rename | full (posted to the app server) | app server |

Set up WezTerm by pointing your config at (or copying from) `wezterm/wezterm.lua`. AI Power Term is a separate app; headsup talks to it over the local protocol it injects (`AI_POWER_TERM_HOOK_URL` plus a `/hook` POST and a `/ws` websocket), so no AI Power Term code lives in this repo.

## The three capabilities

### 1. Status colors + labels: see every tab's state at a glance

| Color  | State   | What it means                                                       |
|--------|---------|---------------------------------------------------------------------|
| white  | idle    | session is open, nothing in flight                                  |
| blue   | working | the agent is processing your prompt or running a tool               |
| orange | waiting | the agent needs you or has finished its turn                        |

The three transitions you actually care about all happen within ~50 ms of the underlying hook event when the daemon is healthy. The color is already right by the time your eye gets to the tab. (For Codex, orange means Codex has stopped or is waiting on a permission request.)

Plus:

- A **badge** in the top-right of every iTerm2 pane showing your project name (or any label you set with `/headsup-label`). Stays readable when you're screen-recording or pair-programming and the tab bar is off screen.
- A **tab title** of `Claude · <project>` or `Codex · <project>`, pinned so the agent TUI can't overwrite it mid-render.
- A **live status bar** at the bottom of every Claude Code session: account, model, context window, session and weekly quota, cost (details in [The status bar](#the-status-bar)).
- A **kill switch** (`touch ~/.claude/hooks/.disabled`) and per-event **debug logging** (`touch ~/.claude/hooks/.debug`) for when something goes sideways.

### 2. Save for later: `/sfl`

`/sfl` checkpoints the current window into `~/.claude/sfl/<slug>.md`, keyed on the tab's headsup label: what was in flight, the decisions made, and the single concrete next step on restart. One file per window, newest save wins, so any number of windows can checkpoint simultaneously with zero contention. If you keep your own memory or notes system, the entry can point at a fuller writeup there; if you don't, the entry itself is the complete checkpoint.

### 3. Now is later: `/nil`

`/nil` reopens every saved window: one iTerm2 tab per checkpoint, each tab `cd`ing into its recorded directory, restoring its headsup label, and launching `claude` with a resume prompt pointed at its checkpoint. Each reopened tab catches you up in a few lines and asks before starting work.

Entries are archived at launch time, before any tab opens, so the live list is empty after every run and a second `/nil` can never relaunch the same window twice. If the AppleScript fails (iTerm2 not running, Automation denied), the moves roll back and nothing is lost.

## Install

```bash
git clone https://github.com/wasulajr/headsup.git
cd headsup
./setup.sh
```

`setup.sh` is idempotent and safe to re-run. Re-running it pulls the latest from GitHub first, then applies any new hooks or skills. Pass `--no-pull` to skip the pull.

Each run (after the optional GitHub pull):

1. Verifies all prerequisites
2. Enables iTerm2's Python API if not already enabled
3. Creates a Python venv at `~/.claude/hooks/iterm2-venv/`
4. Copies hook scripts to `~/.claude/hooks/`, then sfl helpers to `~/.claude/sfl/lib/`
5. Compiles + installs the notifier `.app` to `~/Library/Application Support/headsup/`
6. Installs and loads the watchdog LaunchAgent
7. Copies skill folders to `~/.claude/skills/`
8. Installs the New Claude Tab Quick Action into `~/Library/Services/` and offers to bind ⌘⌥C (briefly restarts Finder)
9. Merges hook wiring into `~/.claude/settings.json` and adds the `permissions.allow` rules that make `/headsup-label`, `/sfl`, and `/nil` prompt-free

Pass `--no-permissions` to skip the `permissions.allow` merge for the sfl helpers; setup.sh prints the rules so you can paste them into settings.json yourself.

After the script finishes:

- If iTerm2's Python API was just enabled, **restart iTerm2** for it to take effect.
- Open a new iTerm2 tab and run `claude`. The first hook event triggers an iTerm2 permission dialog. Click **"Always Allow"**.
- The first time a notification fires, macOS will prompt for permission. Click **Allow**.
- Type a prompt. The tab turns blue while Claude works, orange when it stops to ask you something.

Prerequisites (`setup.sh` checks all of these and tells you the exact `brew install` command for anything missing):

- macOS (the color path is delivered natively per terminal: no Linux or Windows support)
- A supported terminal: [iTerm2](https://iterm2.com/) (`brew install --cask iterm2`), [WezTerm](https://wezterm.org/) (`brew install --cask wezterm`), or AI Power Term. iTerm2 is the default and the most fully exercised.
- [Claude Code](https://claude.com/claude-code)
- Python 3.9+: `brew install python@3.12`
- jq: `brew install jq`
- Xcode Command Line Tools: `xcode-select --install` (provides `swiftc` for the notifier app)

## How it works

### Event to color mapping

`headsup-status.sh` runs on every Claude Code hook event and decides what color the tab should be:

| Claude Code event   | Tab color | Dock attention | Why                                                                            |
|---------------------|-----------|----------------|--------------------------------------------------------------------------------|
| `SessionStart`      | white     | no             | Fresh session                                                                  |
| `UserPromptSubmit`  | blue      | no             | You sent a prompt; Claude is working                                           |
| `PreToolUse`        | blue      | no             | Claude called a tool; still working                                            |
| `PostToolUse`       | blue      | no             | Tool returned; still working                                                   |
| `Notification`      | orange    | yes            | Claude wants your attention                                                    |
| `Stop`              | orange    | yes            | Claude finished its turn                                                       |

Two synthetic events the script derives itself:

| Synthetic event         | Tab color | When                                                                                    |
|-------------------------|-----------|-----------------------------------------------------------------------------------------|
| `PreToolUseWaitForUser` | orange    | `PreToolUse` payload contains `AskUserQuestion`. Front-runs `Notification` by several seconds. |
| `PostToolUseFromWait`   | blue      | Matching `PostToolUse` after an `AskUserQuestion` resolves                              |

### Two-process architecture

A one-shot Python invocation per event took ~440 ms (cold-start for the `iterm2` package plus websocket handshake). The system splits that into two processes:

1. **`headsup-status.sh`** (bash). Fires on every hook event. Writes `<color> <attention>` to a state file at `hooks/.state/<session-uuid>.state`, then ensures the daemon is alive via PID file.
2. **`iterm2-daemon.py`** (Python, long-running). Holds one open websocket to iTerm2's API for the whole machine. Polls state files every 30 ms and injects color changes directly into iTerm2, bypassing the pty. The Claude Code TUI's concurrent writes cannot tear the bytes.

### Self-healing layers

The daemon's websocket can die quietly. Four layers catch it:

1. **Active liveness probe.** Before every heartbeat write, the daemon calls `app.async_refresh`. Failure triggers a `DEAD` heartbeat and a clean exit; the bash hook respawns it on the next event.
2. **Apply-error classification.** Websocket exceptions during `apply_state` trigger the same DEAD-exit. Non-websocket errors just log.
3. **Per-daemon reconciliation sweep.** Every ~7s the daemon re-asserts desired state for every known session. Catches drift from any cause.
4. **launchd watchdog.** `headsup-watchdog.sh` runs every 30s, completely independent of Claude Code. On the healthy path it costs a few `stat` calls. When the daemon is missing or `DEAD`, the watchdog respawns it. This layer works even when all Claude Code hook events have dried up entirely (hung process, network stall, whatever).

### /sfl checkpoints and /nil restore

- **Window identity is the headsup tab label.** `sfl/lib/window-id.sh` reads it from the per-session label conf, falling back to the cwd basename, and slugifies it into a filename. One entry file per window: `~/.claude/sfl/<slug>.md`.
- **Entries are small markdown files** with YAML frontmatter (`window`, `project`, `cwd`, `saved_at`, `gov_memory`) plus a Checkpoint section and a How to restart section. The newest save for a window overwrites its previous entry.
- **Writes go through `sfl/lib/sfl-entry.sh`** (a Bash helper) rather than Claude's Write tool, because Claude Code guards direct writes into its own config directory. The helper plus the allow rules setup.sh installs make saves promptless.
- **`/nil` archives at launch.** `sfl/lib/nil-open.sh` moves every live entry into `~/.claude/sfl/archive/` BEFORE opening any tab, and each tab's resume prompt points at the archived path. The live list is therefore empty after every run: the guarantee that nothing relaunches twice. On `osascript` failure the moves roll back. Archived entries are never auto-deleted, so a checkpoint can always be recovered.
- **Resume is checkpoint-based, not transcript-based.** Each reopened tab is a fresh `claude` that rebuilds context from the entry file (and whatever fuller notes it references), not from the old conversation transcript. This survives Claude Code version upgrades and transcript-format changes.

### End-of-turn PostToolUse suppression

Claude Code sometimes fires a stray `PostToolUse` 1-8 seconds after `Notification` or `Stop` at end of turn. Without handling this, the tab flickers from orange to blue and back to orange, making the wait state appear to take 5-15 seconds longer than it actually did.

The bash hook maintains a per-session in-flight-tool counter (`<uuid>.precount`) and a waiting marker (`<uuid>.waiting`). `PostToolUse` suppresses itself only when the waiting marker is set AND the in-flight counter is 0. That combination uniquely identifies a stray end-of-turn delivery without affecting the legitimate "Notification mid-tool" case (e.g., a tool permission prompt where the counter is still positive).

### Session and week quota tracking

`headsup-usage-windows.py` scans `~/.claude/projects/**/*.jsonl` on every status bar update, aggregating output tokens (the primary compute signal) across two time windows:

- **Session block**: the current 6-hour block, resetting at 01:40, 07:40, 13:40, and 19:40 UTC
- **Week**: from Monday 17:00 ET (21:00 UTC) to the following Monday

The percentage calculation was validated against Claude Code's built-in `/status` dialog. The limits are reverse-engineered from that dialog's "Current session" and "Current week" percentages, which Claude Code computes from the same local JSONL data:

```
session limit: ~17M output tokens per 6h block
week limit:    ~140M output tokens per week
```

Results are cached for 60 seconds so the hook stays fast on every tool call. The cache is invalidated automatically on the next status bar render after expiry.

The cost figures are API-equivalent: each JSONL entry's token counts are weighted by the model's published API pricing (per-model table in `headsup-usage-windows.py`). For Claude Max users this reflects the compute value extracted from the subscription, not the charge.

### Context window percentage accuracy

The context window percentage the status bar displays uses the API-provided `used_percentage` when present. When that field is absent, it falls back to a manual calculation that includes input tokens, cache creation tokens, cache read tokens, AND output tokens: all four token types count against the context window. This matches what Claude Code's own toolbar shows and fixes a common under-reporting bug in earlier implementations that excluded output tokens.

### Notifier .app

Wait notifications need the headsup icon, not the shell process icon. Since macOS Big Sur the only reliable way to attribute a notification to a specific icon is to post it from inside that bundle. `headsup-notifier.swift` is a small Cocoa app that calls `UNUserNotificationCenter.add()` from within `NSApplication.shared`, with activation policy `.accessory` (no Dock icon, no command-tab entry). `setup.sh` compiles it, drops it into a `.app` bundle, ad-hoc codesigns it, and registers it with Launch Services.

To swap the icon: drop a 1024x1024 PNG at `notifier-app/icon-source.png`, run `./notifier-app/build-icon.sh`, then re-run `./setup.sh`.

### Housekeeping

- **Log rotation.** When `headsup-status.log` exceeds 5 MB, the bash hook moves it to `headsup-status.log.1` on the next invocation.
- **Stale state-file GC.** Every 5 minutes the daemon sweeps `.state` files whose UUID is no longer a live iTerm2 session AND whose mtime is over 24 hours old.

## Requirements and limitations

Honest list, so you know before installing:

- **macOS only.** No Linux, Windows, or Terminal.app support. Coverage differs by terminal: iTerm2 is the most fully exercised (daemon over the Python API, OSC badge and title); WezTerm and AI Power Term are supported for colors, labels, the status bar, and `/nil`, and are newer.
- **`/nil` needs the active terminal running plus a way to open a tab in it.** On iTerm2 that is macOS Automation permission (the first run triggers a prompt; if denied, re-enable under System Settings > Privacy & Security > Automation); on WezTerm the `wezterm` CLI; on AI Power Term the app server. It also needs `claude` on the login-shell PATH.
- **The Codex port covers status colors, labels, and utilization tracking, not yet `/sfl` and `/nil`.** Those depend on Claude Code skills, allow rules, and resume prompts. Codex parity is on the roadmap.
- **Quota numbers are estimates.** The session and week limits are reverse-engineered from Claude Code's own `/status` dialog and match it in practice, but both are approximate.
- **Not supported software.** Bugs and ideas welcome at https://github.com/wasulajr/headsup/issues.

## Roadmap

- **Coordination layer.** Deploy locks and a multi-window status board for fleets where several agent windows share environments (single-writer deploy targets, who-holds-what visibility, takeover logging).
- **Codex parity for `/sfl` and `/nil`.**
- **Deeper WezTerm and AI Power Term parity** as those paths get the same real-world mileage iTerm2 has.

---

## Reference

### The status bar

```
👤 you@example.com  claude-sonnet-4-6  38%  Session: 1.5M/17M ~9%  API cost ~$77  Week: 28M/140M ~20%  API cost ~$4k  Cost: ~$1.33 est  ⎇ main
```

| Field | What it shows |
|-------|---------------|
| `👤 you@example.com` | Claude account email from `~/.claude.json`. Updates automatically on account switch. |
| `claude-sonnet-4-6` | Active model. |
| `38%` | Context window usage. Green below 70%, yellow at 70%+ with a progress bar, red at 90%+. This is per-conversation context capacity. |
| `Context: ▓▓▓░░░░░░░ 38% ⚠` | Full bar with label appears at 70%+, replacing the plain percentage. |
| `Session: 1.5M/17M ~9%` | Output tokens used in the current 6-hour rate-limit block vs the approximate block limit. Reverse-engineered from Claude Code's own `/status` dialog. |
| `API cost ~$77` | What that session window's tokens would cost at Anthropic API rates. Marked `~` because it is an estimate. |
| `Week: 28M/140M ~20%` | Output tokens used since Monday 5pm ET vs the approximate weekly limit. This is the number that tells you if Anthropic is about to throttle you or switch you to per-token billing. |
| `API cost ~$4k` | API-equivalent value of the week's tokens. On Claude Max this reflects the compute you're extracting from your subscription, not what you pay. |
| `Cost: ~$1.33 est` | Total cost of the current conversation at API rates. Tilde and "est" for Max users; bare `$1.33` for API key users. |
| `⎇ main` | Current git branch. Omitted outside git repos. |

**Context window escalating notifications.** Each threshold fires once per session and resets after `/compact` drops usage below 85%:

| Threshold | Notification |
|-----------|-------------|
| 90% | Run /compact to avoid losing context |
| 95% | Compact soon, context almost full |
| 97% | Compact immediately, context nearly gone |
| 99% | Compact NOW, you are about to lose context |

**Session and week thresholds are configurable** in `headsup-status.conf`:
```bash
HEADSUP_SESSION_LIMIT=17000000   # output tokens per 6h block
HEADSUP_WEEK_LIMIT=140000000     # output tokens per week
```

### What's in this repo

```
headsup/
├── README.md
├── setup.sh                              # Claude Code installer (idempotent, safe to re-run)
├── setup-codex.sh                        # Codex CLI installer (idempotent, safe to re-run)
├── hooks/
│   ├── headsup-status.sh                 # bash entry point: Claude Code hooks call this
│   ├── headsup-codex-status.sh           # bash entry point: Codex hooks call this
│   ├── headsup-status.conf               # color + badge defaults (edit to customize)
│   ├── headsup-context-bar.sh            # statusLine hook: account, model, context, quotas, cost
│   ├── headsup-usage-windows.py          # JSONL aggregator for session/week token counts and cost
│   ├── headsup-session-cost.py           # per-session token aggregator for /headsup-status
│   ├── headsup-codex-utilization.mjs     # Codex session/week token tracking (Codex hooks)
│   ├── headsup-codex-utilization-report.mjs  # Codex utilization status line renderer
│   ├── headsup-update.sh                 # pull latest from GitHub (/headsup-update)
│   ├── headsup-resync.sh                 # force-resync a drifted tab (/headsup-resync-tab)
│   ├── headsup-set-label.sh              # set/clear the per-session label (/headsup-label + Quick Action)
│   ├── headsup-newtab-args.sh            # New Tab launch-mode setter (/headsup-config newtabs|codextabs)
│   ├── headsup-ensure-permissions.sh     # ensures skill allow rules (shared by setup.sh + headsup-update.sh)
│   ├── headsup-watchdog.sh               # outermost safety net (launchd, every 30s)
│   ├── headsup-status-report.sh          # health snapshot (/headsup-status)
│   ├── headsup-diagnose.sh               # active end-to-end test (/headsup-diagnose)
│   ├── headsup-notify-waiting.sh         # fires macOS notification when a tab waits too long
│   ├── headsup-notifications.sh          # /headsup-notifications skill helper
│   ├── headsup-notifications.conf        # notifier config (enabled / threshold / sound)
│   ├── iterm2-daemon.py                  # persistent daemon: holds the iTerm2 websocket
│   ├── iterm2-apply-once.py              # one-shot fallback when the daemon is unavailable
│   └── iterm2-set-tab-color.py           # ad-hoc testing helper
├── wezterm/
│   └── wezterm.lua                       # WezTerm tab-color + label rendering (format-tab-title)
├── codex-bin/
│   └── headsup-label                     # Codex label CLI shim (installed to ~/.local/bin)
├── sfl/
│   └── lib/
│       ├── window-id.sh                  # resolve this window's label/slug/cwd (/sfl)
│       ├── sfl-entry.sh                  # write/archive live checkpoint entries (/sfl)
│       └── nil-open.sh                   # open one tab per saved window in the active terminal (/nil)
├── launchagents/
│   └── claude-code.headsup-watchdog.plist.template
├── notifier-app/
│   ├── headsup-notifier.swift            # Swift CLI posting via UNUserNotificationCenter
│   ├── Info.plist.template
│   ├── AppIcon.icns
│   ├── build-notifier.sh
│   └── build-icon.sh
└── skills/
    ├── headsup/                   # /headsup                   default health/status overview
    ├── sfl/                       # /sfl                       save this window for later
    ├── nil/                       # /nil                       reopen every saved window
    ├── headsup-colors/            # /headsup-colors            change idle/working/waiting colors
    ├── headsup-label/             # /headsup-label             name this tab
    ├── headsup-config/            # /headsup-config            settings hub: newtabs|codextabs|colors|label|notify
    ├── headsup-new-tab-shortcut/  # /headsup-new-tab-shortcut  ⌘⌥C Finder Quick Action (bundle ships here)
    ├── headsup-resync-tab/        # /headsup-resync-tab        fix a stuck tab
    ├── headsup-status/            # /headsup-status            passive health snapshot
    ├── headsup-diagnose/          # /headsup-diagnose          active end-to-end test
    ├── headsup-notifications/     # /headsup-notifications     toggle + threshold the wait notification
    └── headsup-update/            # /headsup-update            pull latest from GitHub
```

`setup.sh` pulls the latest from GitHub, copies hooks, sfl helpers, and skills into `~/.claude/`, builds the notifier `.app`, installs the watchdog LaunchAgent, installs the New Claude Tab Quick Action, and wires events and permissions into `~/.claude/settings.json`.

### Codex install

Codex support uses Codex lifecycle hooks and the same iTerm2 daemon. Hooks and state install into `~/.codex/`; Codex skills install into `~/.agents/skills/`, which is the user-skill directory scanned by Codex:

```bash
cd headsup
./setup-codex.sh
```

Then start a new iTerm2 tab and run `codex`. If Codex reports that hooks need review, run `/hooks` and trust the headsup hook definitions.

Codex color mapping:

| Codex event | Tab color | Dock attention | Why |
|-------------|-----------|----------------|-----|
| `SessionStart` | white | no | Fresh Codex session |
| `UserPromptSubmit` | blue | no | You sent a prompt; Codex is working |
| `PreToolUse` / `PostToolUse` | blue | no | Codex is running or returning from a tool |
| `PermissionRequest` | orange | yes | Codex is asking for approval |
| `Stop` | orange | yes | Codex finished its turn |
| `PreCompact` / `PostCompact` | blue | no | Codex is compacting context |
| `SubagentStart` / `SubagentStop` | blue | no | A subagent is active or returning |

Codex support also installs Codex-native headsup skills, wait notifications, `$headsup-colors`, `$headsup-status`, `$headsup-diagnose`, `$headsup-label`, `$headsup-resync-tab`, `$headsup-update`, and a New Codex Tab Quick Action. It tracks Codex session and week token utilization (`headsup-codex-utilization.mjs`, wired into the Codex lifecycle hooks) and installs a `headsup-label` CLI shim into `~/.local/bin` so you can relabel a Codex tab from any shell. Claude-only features are the Anthropic quota estimates, Claude JSONL cost aggregation, Claude statusLine hook, the New Claude Tab Quick Action, and the `/sfl` + `/nil` window lifecycle skills.

### Twelve skills you can run from any Claude Code session

#### `/headsup`: default overview

The bare `/headsup` command runs the read-only status report and routes you to the focused commands below. Use it when you want the quick "is this working" snapshot without remembering which specific skill to call.

#### `/sfl`: save this window for later

Checkpoints the current window to `~/.claude/sfl/<slug>.md` (keyed on the tab's headsup label): what was in flight, decisions made, and the concrete next step on restart. One file per window, newest wins. Optionally references a fuller writeup in your own memory or notes system. Ends with a green SAVED FOR LATER banner so the checkpoint is unmissable. Also has a resume mode (`/sfl resume`), which is what each tab reopened by `/nil` runs to catch itself up.

#### `/nil`: now is later

Reopens every saved window: one iTerm2 tab per entry, label restored, `claude` launched with a resume prompt pointing at the (already archived) checkpoint. Lists what it will reopen before spawning anything. Archive-at-launch guarantees nothing relaunches twice; on AppleScript failure everything rolls back.

#### `/headsup-colors`: paint your tabs

Run `/headsup-colors`, say which state (idle / working / waiting) and what hex color. The skill writes to `headsup-status.conf`, applies the color to your current tab instantly, and commits + pushes if `~/.claude/` is a git repo.

Defaults:
```bash
IDLE_COLOR="ffffff"     # white
PROCESS_COLOR="3a82f5"  # blue
WAIT_COLOR="e67e22"     # orange
```

Per-project color overrides are also supported via functions in `headsup-status.conf`:

```bash
headsup_project_process_color() {
    case "$PWD" in
        */api-server*)   printf '8a3ffc' ;;   # purple for the API project
        */frontend*)     printf 'ff6b6b' ;;   # coral for frontend
        *)               printf '' ;;         # empty = use global default
    esac
}
```

#### `/headsup-label`: name this tab

Override the default badge (basename of `$PWD`) for this iTerm2 pane only. Useful when three tabs are all working inside the same repo and you can't tell "deploy debugging" from "frontend refactor" from "prod incident" in the tab bar. Local-only, keyed to `ITERM_SESSION_ID`. Re-run after iTerm2 restart. (The label is also what `/sfl` keys its checkpoint on, and what `/nil` restores.)

All the work happens in one permanent script, `~/.claude/hooks/headsup-set-label.sh`. The skill just calls it with your label. Because every invocation starts with the same path, one permission rule in `~/.claude/settings.json` makes label changes prompt-free (`setup.sh` adds this automatically):

```json
{ "permissions": { "allow": ["Bash(~/.claude/hooks/headsup-set-label.sh:*)"] } }
```

The script also handles reverting: `~/.claude/hooks/headsup-set-label.sh --clear` removes the per-session override and re-applies the global default label.

#### `/headsup-new-tab-shortcut`: the ⌘⌥C Finder Quick Action

Select a folder in Finder, press **⌘⌥C**: a new iTerm2 tab opens, you're asked for a label (defaults to the folder name; applied as tab title + badge via `headsup-set-label.sh`), then it `cd`s into the folder and launches `claude`.

`setup.sh` installs the Quick Action automatically (step 8) and `/headsup-update` keeps it current, so the skill itself is the manual install/repair/removal path. Run it when the hotkey stopped working, the Quick Action vanished from Finder's menu, or you want a different key combo.

Configuration notes:

- **The hotkey is per-machine**, stored in macOS `pbs` preferences, not in the bundle. To rebind it (here to ⌘⌥C):

  ```bash
  defaults write pbs NSServicesStatus -dict-add '"(null) - New Claude Tab - runWorkflowAsService"' '{ key_equivalent = "@~c"; }'
  /System/Library/CoreServices/pbs -flush
  killall Finder
  ```

  Key-equivalent cheat sheet: `@` = Command, `~` = Option, `^` = Control, `$` = Shift. So `@~c` = ⌘⌥C; swap the string for a different combo. The GUI path is System Settings, Keyboard, Keyboard Shortcuts, Services, Files & Folders, New Claude Tab.
- **First run**: macOS asks to allow the Service to control iTerm2. Click OK. If you denied it, re-enable under System Settings, Privacy & Security, Automation.
- **Skipping the label**: click Skip (or leave the field empty) and the tab opens with the normal headsup default label.
- **Removal**: delete `~/Library/Services/New Claude Tab.workflow` and run `/System/Library/CoreServices/pbs -flush`.

#### `/headsup-config`: settings hub

One command for every headsup setting, with a section as the first word: `newtabs` / `codextabs` (New Tab launch mode), `colors` (idle/working/waiting), `label` (this tab's title + badge), `notify` (the wait notification). With no section it prints every current setting.

```bash
/headsup-config                 # show all current settings
/headsup-config colors wait orange
/headsup-config newtabs off
/headsup-config notify 10
```

#### `/headsup-resync-tab`: fix a stuck tab

Force-writes the correct state through all three independent delivery tiers in parallel (state file, one-shot Python API call, OSC to tty). Useful when a dropped event leaves a tab stuck on the wrong color.

#### `/headsup-status`: passive health snapshot

Read-only. Shows daemon PID and heartbeat, watchdog LaunchAgent state, every session's current color and in-flight tool count, stray `PostToolUse` suppression count, and token usage for the current session's JSONL file.

#### `/headsup-diagnose`: active end-to-end test

Flashes white, blue, and orange on the current tab over ~3 seconds, verifying each color reaches the state file AND shows a "daemon applied" log line within 2 seconds. Restores the original color on exit. Exit code 0 on all-pass, 1 on any fail.

`/headsup-diagnose --restart` also kills the daemon and waits up to 35 seconds for the launchd watchdog to respawn it.

#### `/headsup-notifications`: macOS notification when Claude waits too long

Fires a notification when a tab has been orange (waiting) for longer than a configurable threshold. Works even when you're away from the computer.

```bash
/headsup-notifications              # show current state
/headsup-notifications on           # enable
/headsup-notifications off          # disable
/headsup-notifications 10           # set threshold to 10 minutes
/headsup-notifications test         # fire a test notification right now
/headsup-notifications sound Ping   # change the alert sound
```

Defaults: enabled, 5-minute threshold, `Glass` sound. Multiple waiting tabs each get their own notification.

#### `/headsup-update`: pull the latest from GitHub

```bash
/headsup-update
```

Pulls, shows a changelog, and restarts the daemon if `iterm2-daemon.py` changed.

### Customization

#### Colors and thresholds

Edit `~/.claude/hooks/headsup-status.conf`. The file is sourced by the bash hook on every event, so changes take effect immediately (no restart needed):

```bash
# Tab colors (6-char hex, no leading #)
IDLE_COLOR="ffffff"
PROCESS_COLOR="3a82f5"
WAIT_COLOR="e67e22"

# Context window thresholds
WARN_AT=70       # yellow bar starts here
DANGER_AT=90     # red bar + notifications start here

# Quota limits (output tokens)
HEADSUP_SESSION_LIMIT=17000000
HEADSUP_WEEK_LIMIT=140000000
```

Edit `~/.claude/hooks/headsup-notifications.conf` for notification settings:

```bash
# Wait notification
NOTIFICATION_SOUND="Glass"
```

#### Per-session label

Run `/headsup-label` in any Claude Code session and type the name you want. The badge and tab title update immediately. Stored in `~/.claude/hooks/headsup-status.d/<session-key>.conf`, which is gitignored.

Under the hood the skill calls `~/.claude/hooks/headsup-set-label.sh`, which you can also run directly from any shell (the New Claude Tab Quick Action does exactly that). `--clear` reverts the pane to the global default label. Add the allow rule shown in the `/headsup-label` section above to make in-session label changes permission-prompt-free.

#### Disable without uninstalling

```bash
touch ~/.claude/hooks/.disabled
```

Both the bash hook and the launchd watchdog check for this file and no-op if present. Remove it to re-enable. To kill an already-running daemon immediately: `pkill -f iterm2-daemon.py`.

### Troubleshooting

#### First: run `/headsup-status` and `/headsup-diagnose`

`/headsup-status` shows whether each layer is healthy (passive, read-only). `/headsup-diagnose` actively exercises the stack and reports pass/fail per step. These two commands answer most questions faster than reading further.

#### "Tab color isn't changing"

1. Run `/headsup-diagnose`. Step 5-7 failure means the daemon's API connection is dead. Check `~/.claude/hooks/.state/daemon.stderr`.
2. Confirm `pgrep -f iterm2-daemon.py` returns a PID. If not, trigger any Claude Code event and re-check (the bash hook spawns it on demand).
3. Confirm the venv: `ls ~/.claude/hooks/iterm2-venv/bin/python`.
4. Enable debug logging: `touch ~/.claude/hooks/.debug`. Tail `~/.claude/hooks/headsup-status.log` while triggering events.
5. Confirm iTerm2's Python API is enabled: Settings, General, Magic, "Python API." The first connection requires manual approval in a dialog.

#### "Status bar isn't showing"

1. Confirm `statusLine` is wired in `~/.claude/settings.json` (see the settings block in *Manual install* below).
2. Restart Claude Code after changing `statusLine`.
3. Test directly: `echo '{}' | bash ~/.claude/hooks/headsup-context-bar.sh`. Should produce output.

#### "Tab stuck in attention mode"

Run `/headsup-resync-tab`. Sends `RequestAttention=no` paired with the correct color across all three delivery tiers.

#### "/nil opens no tabs or errors"

1. iTerm2 must be running before `/nil` (the opener targets the current iTerm2 window).
2. Check Automation permission: System Settings, Privacy & Security, Automation, allow control of iTerm2.
3. On `osascript` failure the opener restores all live entries and exits nonzero; fix the permission and run `/nil` again, nothing was lost.
4. `~/.claude/sfl/lib/nil-open.sh --list` shows what is saved; `--dry-run` prints the AppleScript without opening or archiving anything.

#### "Notifications show the wrong icon"

Most likely the notifier `.app` wasn't built. Re-run `setup.sh` and watch the Step 5 output. If `swiftc` is missing: `xcode-select --install`. If macOS silently denied notification permission before the icon was in place, go to System Settings, Notifications, find headsup, and flip it to Allow. If headsup isn't listed, change the bundle ID in `notifier-app/Info.plist.template` and re-run `setup.sh`. macOS treats the new ID as a fresh app and re-prompts.

#### "I want to extend it"

To add a new tab state (e.g., red on destructive tool use):

1. Add the state-detection branch to `headsup-status.sh`.
2. Call `set_tab_color "<hex>"`. The daemon picks it up from the state file; no daemon changes needed.

For new status bar segments, edit the `LINE=` assembly at the bottom of `headsup-context-bar.sh`.

For new badge or title logic, edit `headsup_badge_text()` and `headsup_title_text()` in `headsup-status.conf`. Both are bash functions.

### Manual install

If `setup.sh` doesn't fit your workflow:

#### 1. Enable iTerm2's Python API

iTerm2, Settings, General, Magic, enable "Python API."

#### 2. Create the Python venv

```bash
python3 -m venv ~/.claude/hooks/iterm2-venv
~/.claude/hooks/iterm2-venv/bin/pip install iterm2
```

#### 3. Copy hooks, sfl helpers, and skills

```bash
mkdir -p ~/.claude/hooks ~/.claude/skills ~/.claude/sfl/lib
cp hooks/* ~/.claude/hooks/
cp sfl/lib/* ~/.claude/sfl/lib/
cp -r skills/* ~/.claude/skills/
chmod +x ~/.claude/hooks/*.sh ~/.claude/hooks/*.py ~/.claude/sfl/lib/*.sh
```

#### 4. Build the notifier .app

```bash
./notifier-app/build-notifier.sh "$HOME/Library/Application Support/headsup"
```

#### 5. Install the New Claude Tab Quick Action (optional)

```bash
cp -R "skills/headsup-new-tab-shortcut/New Claude Tab.workflow" ~/Library/Services/
defaults write pbs NSServicesStatus -dict-add '"(null) - New Claude Tab - runWorkflowAsService"' '{ key_equivalent = "@~c"; }'
/System/Library/CoreServices/pbs -flush
killall Finder
```

#### 6. Install the watchdog LaunchAgent

```bash
sed "s|__HOME__|$HOME|g" \
  launchagents/claude-code.headsup-watchdog.plist.template \
  > ~/Library/LaunchAgents/claude-code.headsup-watchdog.plist

launchctl load ~/Library/LaunchAgents/claude-code.headsup-watchdog.plist
```

#### 7. Wire hooks, status bar, and permissions in settings.json

```json
{
  "permissions": {
    "allow": [
      "Bash(~/.claude/hooks/headsup-set-label.sh:*)",
      "Bash(~/.claude/sfl/lib/window-id.sh:*)",
      "Bash(~/.claude/sfl/lib/sfl-entry.sh:*)",
      "Bash(~/.claude/sfl/lib/nil-open.sh:*)",
      "Read(~/.claude/sfl/**)"
    ]
  },
  "hooks": {
    "SessionStart":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" SessionStart" }] }],
    "Notification":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" Notification" }] }],
    "Stop":             [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" Stop" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" UserPromptSubmit" }] }],
    "PreToolUse":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" PreToolUse" }] }],
    "PostToolUse":      [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" PostToolUse" }] }]
  },
  "statusLine": {
    "type": "command",
    "command": "\"$HOME/.claude/hooks/headsup-context-bar.sh\""
  }
}
```

All six hook events are load-bearing. See *Event to color mapping* above for why each matters. For `/sfl` and `/nil`, also add the `$HOME`-expanded absolute form of each sfl rule (e.g. `Bash(/Users/you/.claude/sfl/lib/sfl-entry.sh:*)`): Claude Code's permission matcher is literal, and `/nil`'s baked resume prompts can carry either form.

### Releases

headsup uses semver tags (`vX.Y.Z`). The installed version lives in `VERSION` at the repo root; changes per release are in [CHANGELOG.md](CHANGELOG.md).

To cut a release (maintainers):

```bash
scripts/release.sh <major|minor|patch> -m "what changed" [-m "more" ...]
```

One command bumps `VERSION`, prepends the changelog section, commits, tags, and pushes with tags. Convention: PATCH for fixes, MINOR for new features/skills, MAJOR for breaking conf/layout changes that require re-running `setup.sh`. Every behavior-changing push to main goes through this script.

## License

MIT. See [LICENSE](LICENSE).
