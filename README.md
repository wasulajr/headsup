# headsup

Observability for AI-native development workflows. Makes Claude Code's state glanceable in iTerm2.

Twenty tabs deep. You hear the Dock bounce. You glance at the tab bar. One tab is orange. That's [Claude Code](https://claude.com/claude-code) asking you a question. You switch over, answer it, watch it turn blue again, move on.

Six Claude Code hooks, a persistent iTerm2 daemon, a launchd watchdog, a tiny notifier `.app` for macOS notifications, and six companion skills you can run from any session. macOS and iTerm2 only. One-line install.

## At a glance

| Color  | State   | What it means                                                       |
|--------|---------|---------------------------------------------------------------------|
| white  | idle    | session is open, nothing in flight                                  |
| blue   | working | Claude is processing your prompt or running a tool                  |
| orange | waiting | Claude needs you (and the Dock icon bounces for good measure)       |

The three transitions you actually care about all happen within ~50 ms of the underlying Claude Code event. The color is already right by the time your eye gets to the tab.

Plus:

- A **badge** in the top-right of every iTerm2 pane showing your project name. Stays readable when you're screen-recording or pair-programming and the tab bar isn't.
- A **tab title** of `Claude · <project>`, pinned so Claude Code's TUI can't overwrite it mid-render.
- A **kill switch** (`touch ~/.claude/hooks/.disabled`) and per-event **debug logging** (`touch ~/.claude/hooks/.debug`) for when something goes sideways.

## What's in this folder

```
headsup/
├── README.md                # you are here
├── setup.sh                 # one-shot installer (run me)
├── hooks/
│   ├── iterm-status.sh             # bash entry point. Claude Code hooks call this.
│   ├── iterm-status.conf           # color + badge defaults (edit to customize)
│   ├── iterm2-daemon.py            # persistent daemon that talks to iTerm2's Python API
│   ├── iterm2-apply-once.py        # one-shot fallback when the daemon isn't available
│   ├── iterm2-set-tab-color.py     # standalone helper for ad-hoc testing
│   ├── iterm-resync.sh             # force a tab back into sync (used by /iterm-resync-tab)
│   ├── iterm-watchdog.sh           # outermost safety net (run from LaunchAgent every 30s)
│   ├── iterm-status-report.sh      # health snapshot script (used by /iterm-status)
│   ├── iterm-diagnose.sh           # active end-to-end test (used by /iterm-diagnose)
│   ├── iterm-session-cost.py       # token-usage aggregator for the current session
│   ├── iterm-notify-waiting.sh     # fires macOS notifications when a tab waits too long
│   ├── iterm-notifications.sh      # /iterm-notifications skill helper (toggle / threshold)
│   └── iterm-notifications.conf    # notifier config (enabled / threshold_min / sound)
├── launchagents/
│   └── claude-code.iterm-watchdog.plist.template  # rendered + installed by setup.sh
├── notifier-app/
│   ├── headsup-notifier.swift      # Swift CLI that posts via UNUserNotificationCenter
│   ├── Info.plist.template         # bundle metadata (com.wasulajr.headsup.notifier)
│   ├── AppIcon.icns                # 10 sub-sizes Notification Center renders from
│   ├── icon-source.png             # 1024x1024 source for AppIcon.icns
│   ├── build-notifier.sh           # compiles, ad-hoc signs, and lsregisters the .app
│   └── build-icon.sh               # regenerates AppIcon.icns from icon-source.png
└── skills/
    ├── iterm-colors/         # /iterm-colors         change the global color palette
    ├── iterm-label/          # /iterm-label          set this tab's title + badge
    ├── iterm-resync-tab/     # /iterm-resync-tab     force-resync a drifted tab
    ├── iterm-status/         # /iterm-status         passive health snapshot
    ├── iterm-diagnose/       # /iterm-diagnose       active end-to-end test
    └── iterm-notifications/  # /iterm-notifications  toggle / threshold the wait notification
```

`setup.sh` copies the `hooks/` and `skills/` contents into your `~/.claude/`, builds the notifier `.app` into `~/Library/Application Support/headsup/`, installs the watchdog LaunchAgent into `~/Library/LaunchAgents/`, and wires the events into your `~/.claude/settings.json`.

## Prerequisites

`setup.sh` checks all of these for you and tells you what to do if anything is missing.

- macOS. The daemon uses iTerm2's Python API; no Linux or Windows support.
- [iTerm2](https://iterm2.com/): `brew install --cask iterm2`
- [Claude Code](https://claude.com/claude-code)
- Python 3.9+: `brew install python@3.12`
- jq: `brew install jq` (used for safe settings.json merging)
- Xcode Command Line Tools: `xcode-select --install`. Provides `swiftc` for compiling the notifier `.app`.

## Quick install

```bash
git clone https://github.com/wasulajr/headsup.git
cd headsup
./setup.sh
```

`setup.sh` is idempotent and safe to re-run. It:

1. Verifies all prereqs (and tells you the `brew install` line for anything missing)
2. Enables iTerm2's Python API if it isn't already
3. Creates a Python venv at `~/.claude/hooks/iterm2-venv/` with the `iterm2` package
4. Copies the hook scripts to `~/.claude/hooks/` (prompts before overwriting anything that exists and differs; backs up to `.bak`)
5. Compiles + installs the notifier `.app` to `~/Library/Application Support/headsup/headsup-notifier.app/`. Wait notifications fire from inside the bundle so they carry the headsup icon (see *Notifier .app* below).
6. Renders the watchdog LaunchAgent template (substituting `$HOME`) into `~/Library/LaunchAgents/claude-code.iterm-watchdog.plist` and loads it with `launchctl`. Fires every 30s as an outermost safety net (see *Self-healing* below).
7. Copies the six skill folders to `~/.claude/skills/`
8. Merges the hook wiring into `~/.claude/settings.json` (backs up to `.bak` if it already exists)

After the script finishes:

- If iTerm2's Python API was just enabled, **restart iTerm2** (or flip the Settings → General → Magic → Python API toggle off and on) for it to take effect.
- Open a new iTerm2 tab and run `claude`. The first hook event triggers an iTerm2 permission dialog. Click **"Always Allow"**.
- The first time a tab sits idle past the notification threshold (or the first time you run `/iterm-notifications test`), macOS shows "headsup wants to send notifications." Click **Allow**. From then on notifications fire silently with the headsup icon attached.
- Type a prompt. The tab should turn blue while Claude works, then orange when it's waiting for you.

## Manual install (if you prefer)

If `setup.sh` doesn't fit your workflow, here's what it does step by step.

### 1. Enable iTerm2's Python API

Open iTerm2 → **Settings → General → Magic** → enable **"Python API"**.

(Equivalent via CLI: `defaults write com.googlecode.iterm2 EnableAPIServer -bool true`. The GUI checkbox forces in-process reload so you don't have to restart iTerm2.)

### 2. Create the Python venv the daemon uses

```bash
python3 -m venv ~/.claude/hooks/iterm2-venv
~/.claude/hooks/iterm2-venv/bin/pip install iterm2
```

### 3. Copy hooks and skills

```bash
mkdir -p ~/.claude/hooks ~/.claude/skills
cp hooks/* ~/.claude/hooks/
cp -r skills/iterm-* ~/.claude/skills/
chmod +x ~/.claude/hooks/*.sh ~/.claude/hooks/*.py
```

### 4. Build + install the notifier .app

```bash
./notifier-app/build-notifier.sh "$HOME/Library/Application Support/headsup"
```

This compiles `headsup-notifier.swift` into a `.app` bundle under `~/Library/Application Support/headsup/`, ad-hoc codesigns it (so macOS persists notification permission across runs), and registers it with Launch Services.

### 5. Install + load the watchdog LaunchAgent

```bash
# Render the template (substitute $HOME) and install
sed "s|__HOME__|$HOME|g" \
  launchagents/claude-code.iterm-watchdog.plist.template \
  > ~/Library/LaunchAgents/claude-code.iterm-watchdog.plist

# Load it
launchctl load ~/Library/LaunchAgents/claude-code.iterm-watchdog.plist

# Confirm
launchctl list | grep claude-code.iterm-watchdog
```

The watchdog fires every 30s and is a no-op on the healthy path; see *Self-healing* below for what it does when things go wrong.

### 6. Approve the daemon's API connection

The first time a hook fires, iTerm2 will pop up a permission dialog asking to authorize the Python script. Click **"Always Allow"**.

### 7. Wire the hooks in `settings.json`

If you cloned the whole repo and ran `setup.sh`, this is already done. If you merged selectively, ensure your `~/.claude/settings.json` includes:

```json
{
  "hooks": {
    "SessionStart":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/iterm-status.sh\" SessionStart" }] }],
    "Notification":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/iterm-status.sh\" Notification" }] }],
    "Stop":             [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/iterm-status.sh\" Stop" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/iterm-status.sh\" UserPromptSubmit" }] }],
    "PreToolUse":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/iterm-status.sh\" PreToolUse" }] }],
    "PostToolUse":      [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/iterm-status.sh\" PostToolUse" }] }]
  }
}
```

All six events are load-bearing. See *How it works* below for why each one matters.

### 8. Test

Open a new iTerm2 tab, run `claude`, type something. The tab should turn blue while Claude is processing, then orange when it stops to ask you a question or finishes a turn. If it doesn't, see *Troubleshooting*.

## How it works

### Event → color mapping

The bash script `iterm-status.sh` runs on every Claude Code hook event and decides what color the tab should be:

| Claude Code event   | Tab color | Dock attention | Why                                                                                |
|---------------------|-----------|----------------|------------------------------------------------------------------------------------|
| `SessionStart`      | white     | no             | Fresh session                                                                      |
| `UserPromptSubmit`  | blue      | no             | You sent a prompt; Claude is working                                               |
| `PreToolUse`        | blue      | no             | Claude called a tool; still working                                                |
| `PostToolUse`       | blue      | no             | Tool returned; still working. Load-bearing for AskUserQuestion recovery (below).   |
| `Notification`      | orange    | yes (bounces)  | Claude wants your attention                                                        |
| `Stop`              | orange    | yes (bounces)  | Claude finished its turn                                                           |

There are also synthetic events the script derives itself:

| Synthetic event           | Tab color | When                                                                              |
|---------------------------|-----------|-----------------------------------------------------------------------------------|
| `PreToolUseWaitForUser`   | orange    | `PreToolUse` payload contains `"tool_name":"AskUserQuestion"`. Front-runs the slower `Notification` event so the tab goes orange the moment Claude opens a question, not when iTerm2 finally renders the notification. |
| `PostToolUseFromWait`     | blue      | Matching `PostToolUse` after an `AskUserQuestion` resolves                        |

### Two-process architecture

A one-shot Python invocation per event was too slow (~440 ms cold-start for the `iterm2` package + websocket handshake to iTerm2). So the system splits in two:

1. **`iterm-status.sh`** (bash). Fires on every hook event. Writes the desired `<color> <attention>` to a tiny state file (`hooks/.state/<session-uuid>.state`), then ensures the daemon is alive (PID file lock at `hooks/.state/daemon.pid`).
2. **`iterm2-daemon.py`** (Python, long-running). Holds one open websocket to iTerm2's API for the whole machine. Polls the state files every 30 ms and injects OSC byte sequences directly into iTerm2 when they change. Bypasses the pty entirely, so the Claude Code TUI's concurrent writes can't tear the bytes.

The daemon auto-evicts itself after an hour of inactivity. It also checks on every poll that it still owns the PID file. If it doesn't (e.g. someone wiped `.state/`), it exits cleanly so the next event spawns a fresh one.

### Self-healing layers

The daemon's websocket to iTerm2 can die quietly. The Python process stays alive, the file-based heartbeat keeps updating, but `apply_state` silently no-ops. To catch that (and the broader "events stopped firing for some reason" case), four layers run on top of the basic daemon:

1. **Active liveness probe.** Before every heartbeat write, the daemon does a round-trip API call (`app.async_refresh`). If it fails, the daemon writes a `DEAD` heartbeat and exits; the bash hook respawns it on the next event.
2. **Apply-error classification.** Websocket-class exceptions during `apply_state` trigger the same DEAD-exit. Non-WS errors just log.
3. **Per-daemon reconciliation sweep.** Every ~7s, the daemon re-asserts the desired state for every session it knows about. Idempotent OSC injection; catches drift from any cause.
4. **`launchd` watchdog.** `iterm-watchdog.sh` runs every 30s, completely independent of Claude Code. Dirt cheap on the healthy path (a few `stat`s + a heartbeat read). When the daemon is missing or `DEAD`, the watchdog respawns it and fires Tier 2 per-session as defense in depth. Logs to `~/.claude/hooks/.state/watchdog.std{out,err}`.

The watchdog is the layer that keeps things working through a wedged Claude Code process, a long-stuck tool call, or any other scenario where hook events dry up entirely. None of layers 1-3 can fire if nothing in the session is alive.

### End-of-turn `PostToolUse` suppression

Claude Code sometimes fires a stray `PostToolUse` 1-8s AFTER `Notification` or `Stop` at end of turn. Without intervention that flips the tab from orange back to blue and then to orange again, making the wait state look like it took 5-15s longer than it actually did.

The bash hook maintains a per-session in-flight-tool counter (`<uuid>.precount`) and a waiting marker (`<uuid>.waiting`):

- Every `PreToolUse` bumps the counter; every `PostToolUse` decrements it.
- `Notification` / `Stop` / `PreToolUseWaitForUser` set the waiting marker but DO NOT touch the counter.
- `PostToolUse` suppresses itself only when **both** the waiting marker is set AND the in-flight counter is 0. That combination uniquely identifies a stray end-of-turn delivery.

This preserves the legitimate "Notification mid-tool" case (e.g., tool permission prompt). The in-flight counter stays at 1 across the Notification, so the post-approval `PostToolUse` correctly flips back to blue. Suppressions are logged when `.debug` is touched; `/iterm-status` summarizes the daily count.

### Notifier .app

Wait notifications need to show the headsup icon, not the icon of whatever shell process happened to fire them. Since macOS Big Sur the only reliable way to attribute a notification to a specific icon is to post it from inside that bundle. `terminal-notifier`'s `-appIcon` flag is silently ignored, `osascript` notifications get Script Editor's icon, and a bare CLI binary calling `UNUserNotificationCenter` is refused by the framework.

The shipped solution: `notifier-app/headsup-notifier.swift` is a small Cocoa app that calls `UNUserNotificationCenter.add()` from within `NSApplication.shared`, with activation policy `.accessory` (no Dock icon, no command-tab entry). `setup.sh` compiles it with `swiftc`, drops it into a `.app` bundle alongside `Info.plist` and `AppIcon.icns`, ad-hoc codesigns the bundle so macOS persists the user's notification decision across runs, and registers the bundle with Launch Services.

**Swapping the icon.** Drop a new 1024x1024 PNG at `notifier-app/icon-source.png`, run `./notifier-app/build-icon.sh`, then re-run `./setup.sh`. The build script regenerates `AppIcon.icns` (all ten macOS sub-sizes via `sips` + `iconutil`) and reinstalls the bundle.

**First-run permission prompt.** The first time a notification fires, macOS shows "headsup wants to send notifications." Click Allow. The decision sticks to the bundle's codesigning identity, so future notifications fire silently. To change it later: System Settings → Notifications → headsup.

### Why `SetColors=tab=` and `RequestAttention=` ship together

iTerm2's "needs attention" state visually overrides the tab color. If a `Notification` puts the tab in attention-mode (orange + dock bounce), a subsequent blue `SetColors=tab=` write succeeds at the API level but the tab visually **stays orange** until `RequestAttention=no` is also sent. The daemon injects both sequences atomically on every state change to avoid this. See the comment in `iterm2-daemon.py:apply_state()` if you want to extend it.

### Tab title + badge

The tab title (`Claude · <project>`) and badge (the watermark) are written once via OSC 1337 directly to the parent tty at `SessionStart`. They don't flow through the daemon. They're single-fire, and tty writes are reliable for one-shots.

`iterm-status.sh` walks the parent process tree (`ps -o tty=`) to find a writable tty, because hook subprocesses don't inherit a controlling terminal (`/dev/tty` fails with "Device not configured").

### Housekeeping

- **Log rotation.** When `iterm-status.log` exceeds 5 MB the bash hook moves it to `iterm-status.log.1` on the next invocation. One rotation kept; no unbounded growth.
- **Stale state-file GC.** Every 5 min the daemon sweeps `.state` files whose UUID is no longer a live iTerm2 session AND whose mtime is > 24h old, dropping the file plus its `.waiting` / `.precount` sidecars. The age floor prevents deleting a state file for a tab that's briefly invisible (cold-starting, hidden window).

## Six skills you can run from any Claude Code session

### `/iterm-colors`: paint your tabs whatever you want

Don't like blue. Colorblind colleague. Want to swap the orange for hot pink. Run `/iterm-colors`, pick which state (idle / working / waiting), give it a hex. The skill writes the new value to `hooks/iterm-status.conf`, applies it to your current tab instantly, and, if you're working in your own fork, commits + pushes the change so your other machines pick it up next pull.

Defaults if you're curious:

```bash
IDLE_COLOR="ffffff"     # white
PROCESS_COLOR="3a82f5"  # blue
WAIT_COLOR="e67e22"     # orange
```

#### Per-project color overrides

The global palette can be overridden per `$PWD` via optional functions in `iterm-status.conf`. Useful when you have many projects open in parallel and want each to have a distinguishing color:

```bash
iterm_project_process_color() {
    case "$PWD" in
        */Digadop*)        printf '8a3ffc' ;;  # purple
        */headsup*)        printf 'ff6b6b' ;;  # coral
        *)                 printf '' ;;        # empty = use global default
    esac
}
```

`iterm_project_wait_color` and `iterm_project_idle_color` work the same way. Functions get no args, see `$PWD`, return a 6-char hex (no leading `#`) or empty for "no override." First match wins; uses macOS-bash-3.2-friendly syntax (no associative arrays).

### `/iterm-label`: name this tab anything

Default badge is the basename of your `$PWD`. Override it for THIS iTerm2 pane only. Useful when you've got three tabs all working inside the same `my-project/` folder and you can't tell "deploy debugging" from "frontend refactor" from "prod incident" from the tab bar alone. Run `/iterm-label`, give it a string, the badge + tab title both change.

Local-only (gitignored), keyed to `ITERM_SESSION_ID`. Re-run after iTerm2 restart since the IDs change.

### `/iterm-resync-tab`: fix a tab that got stuck

Every now and then Claude Code's hook chain drops an event and a tab ends up stuck on the wrong color. Still orange minutes after you replied, still white minutes after Claude started. The whole point of the system breaks down right when you need it.

`/iterm-resync-tab` bypasses the normal hook path entirely and force-writes the desired state through **all three independent tiers in parallel** so something gets through:

1. State file write → daemon poll picks it up next tick
2. Fresh one-shot Python invocation hits iTerm2's API directly
3. OSC byte sequence written to the parent tty as a final fallback

You shouldn't need it often, but you'll be glad it exists the day you do.

### `/iterm-status`: passive health snapshot

One command, read-only. Shows daemon PID + heartbeat status, watchdog LaunchAgent state, every session's current color and in-flight tool count, the count of stray `PostToolUse` events suppressed today, and token usage for the current `$PWD`'s Claude Code session.

Use when you suspect something's off but you don't want to actively poke the stack. Output is green-check / yellow-bang / red-cross, designed to be self-explanatory.

The token usage section sums `message.usage` across every assistant entry in the latest session JSONL for `$PWD`. No USD figure; pricing changes and the table would rot, so raw tokens are the durable signal.

### `/iterm-diagnose`: active end-to-end test

Where `/iterm-status` observes, `/iterm-diagnose` exercises. Flashes white → blue → orange on the current tab over ~3s, verifying each color both writes to the state file AND lands a "daemon applied" log entry within 2s. Restores the original color on exit. Useful right after installing/upgrading the stack to confirm everything end to end.

`/iterm-diagnose --restart` adds a daemon-respawn test: kills the daemon and waits up to 35s for the watchdog to bring it back. Slower but exercises the launchd safety net.

Exit code is 0 on all-pass, 1 on any fail. Scriptable for CI-style checks if you want to gate something on stack health.

### `/iterm-notifications`: macOS notification when Claude waits too long

The tab going orange and the dock bouncing are great when you're at the computer. They're useless when you're not. The launchd watchdog already runs every 30 seconds; this skill turns on a sweep inside that watchdog that fires a real **macOS notification** ("Claude needs you") when a tab has been waiting longer than a configurable threshold.

```bash
/iterm-notifications              # show current state
/iterm-notifications on           # enable
/iterm-notifications off          # disable
/iterm-notifications 10           # set threshold to 10 minutes
/iterm-notifications 10 on        # set + enable
/iterm-notifications test         # fire a test notification now
/iterm-notifications sound Ping   # change the sound (or `sound none` to silence)
```

Defaults: enabled, 5-minute threshold, `Glass` sound. Each wait period notifies at most once. If you reply and Claude waits again, the next period gets its own notification. Multiple waiting tabs each get their own notification (no batching).

Notifications fire from the bundled notifier `.app` and carry the headsup icon. First run prompts for permission; see *Notifier .app* under *How it works* for the full story.

## Troubleshooting

### First: run `/iterm-status` and `/iterm-diagnose`

`/iterm-status` shows whether each layer is reporting healthy (passive, read-only). `/iterm-diagnose` actively pushes the three colors through the stack and reports pass/fail per step. Most of the below items are faster to confirm by running those two skills than by reading further.

### "Tab color isn't changing at all"

1. `/iterm-diagnose`. If step 5-7 fails, the daemon's API connection is dead or absent. Check `~/.claude/hooks/.state/daemon.stderr`.
2. Confirm the daemon is alive: `pgrep -f iterm2-daemon.py`. If nothing, fire any Claude Code event and re-check (the bash hook spawns the daemon on demand). The launchd watchdog should also respawn it within 30s.
3. Check the venv exists: `ls ~/.claude/hooks/iterm2-venv/bin/python`.
4. Enable debug logging: `touch ~/.claude/hooks/.debug`. Tail `~/.claude/hooks/iterm-status.log` while triggering events. Correlate `sh fire event=X` lines with `daemon applied …` lines.
5. Confirm the Python API is enabled in iTerm2 (Settings → General → Magic → "Python API"). The first connection requires manual approval.

### "Tab stuck in attention mode (orange but should be blue)"

This is the load-bearing pairing issue documented above. Run `/iterm-resync-tab`. It sends `RequestAttention=no` along with the correct color. If a specific event consistently leaves you stuck, contribute the fix to `iterm-status.sh`'s event handlers.

### "Notifications fire but show the wrong icon (or no icon)"

Most likely the notifier `.app` wasn't built. Re-run `setup.sh` and check the *Step 5/8* output. Common causes:

- `swiftc` not on PATH. Install Xcode Command Line Tools: `xcode-select --install`.
- macOS recorded a silent denial for the bundle ID before the icon was in place. System Settings → Notifications → look for headsup. If it's there and set to "Don't Allow," flip it on. If it's not there at all, change the bundle ID in `notifier-app/Info.plist.template` (e.g. add `.v2`) and re-run `setup.sh`; macOS treats the new ID as a fresh app and re-prompts.

### "Skill is doing the wrong thing"

Each skill's `SKILL.md` is its full specification. Read it under `skills/iterm-*/SKILL.md`. They're short.

### "I want to turn the whole thing off temporarily"

```bash
touch ~/.claude/hooks/.disabled
```

Both the bash hook AND the launchd watchdog check for this file on every run and no-op if present. Remove it to re-enable. (This doesn't kill an already-running daemon; you can `pkill -f iterm2-daemon.py` if you want it gone immediately. To stop the watchdog entirely: `launchctl unload ~/Library/LaunchAgents/claude-code.iterm-watchdog.plist`.)

### "Want to see what the watchdog is doing"

`touch ~/.claude/hooks/.debug` enables logging for the bash hook, the daemon, AND the watchdog. All three write to `~/.claude/hooks/iterm-status.log`. The watchdog also writes any non-empty stdout/stderr to `~/.claude/hooks/.state/watchdog.std{out,err}` regardless of the debug flag (LaunchAgent captures, which is sometimes the only signal you get when launchd itself is refusing to run the script).

### "I want to extend it"

To add a new state (e.g. red tab on destructive `PreToolUse`):

1. Add the state-deriving branch to `iterm-status.sh`.
2. Use `set_tab_color "<hex>"` to write the state file.
3. The daemon will pick it up via the state-file format; no daemon changes needed.

For new badge/title behavior, edit `iterm_badge_text()` / `iterm_title_text()` in `hooks/iterm-status.conf`. Both are bash functions and you can put any shell logic there.

## What this isn't

- **Cross-platform.** macOS + iTerm2 only. The daemon uses iTerm2's Python API; the OSC sequences that drive title and badge are iTerm2's proprietary extensions. Other terminals need not apply.
- **Audited or supported.** Bugs welcome at https://github.com/wasulajr/headsup/issues. No SLA, no roadmap.

## License

MIT. See [LICENSE](LICENSE).
