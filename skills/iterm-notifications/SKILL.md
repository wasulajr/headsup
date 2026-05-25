---
name: iterm-notifications
description: Manage the macOS notification that fires when a Claude Code tab has been waiting on the user for more than N minutes. Use when the user types /iterm-notifications, asks to enable/disable the "Claude is waiting" notification, wants to change how long it waits before notifying, or wants to test that notifications are working. Accepts on/off, a numeric threshold (minutes), "test" to fire a one-off notification, and "sound <name|none>" to change the alert sound.
---

# iTerm waiting-notifications

The launchd watchdog (`claude-code.iterm-watchdog`) runs every 30 seconds. When it finds a tab whose state file has been orange (waiting) for longer than `THRESHOLD_MIN` minutes, it fires a macOS notification via `osascript`. This skill is the user-friendly way to toggle the feature, change the threshold, change the sound, or test that it works.

## Usage forms

| Form                              | Effect                                                                 |
|-----------------------------------|------------------------------------------------------------------------|
| `/iterm-notifications`            | Show current state (enabled / threshold / sound)                       |
| `/iterm-notifications on`         | Enable notifications                                                   |
| `/iterm-notifications off`        | Disable notifications                                                  |
| `/iterm-notifications <N>`        | Set threshold to N minutes (positive integer)                          |
| `/iterm-notifications <N> on`     | Set threshold AND enable                                               |
| `/iterm-notifications <N> off`    | Set threshold AND disable                                              |
| `/iterm-notifications test`       | Fire a test notification right now (doesn't change config)             |
| `/iterm-notifications sound <name>` | Set sound — any macOS system sound name (Glass, Ping, Submarine, …)  |
| `/iterm-notifications sound none` | Silence the notification                                               |

## What to do when invoked

Run the helper script with the user's args. Don't try to parse the args yourself — pass them through unchanged. The helper updates the config in place and prints the resulting state.

```bash
~/.claude/hooks/iterm-notifications.sh "$@"
```

If the user just said "turn on notifications" or "enable", pass `on`. "Turn them off" or "disable" → `off`. "Set the threshold to 10 minutes" or "wait 10 minutes" → `10`. "Test it" or "send me a test" → `test`.

After the helper prints the new state, **don't add a long explanation** — the output is clear enough. One short confirmation sentence if the change is non-obvious (e.g., "Notifications will now fire after 10 minutes of waiting").

## First-run macOS permissions caveat

The notifications come from `osascript`, which macOS attributes to **Script Editor**. The first time, the user may need to:

1. Run `/iterm-notifications test`
2. macOS will prompt to allow notifications from "Script Editor"
3. Click Allow

If notifications don't appear after the first test: System Settings → Notifications → Script Editor → ensure "Allow Notifications" is on.

(Better attribution would require installing `terminal-notifier` and switching the helper to use it. Not done by default to keep the install dep-free.)

## How the threshold actually applies

`THRESHOLD_MIN` is matched against the `.state` file's mtime via `find -mmin +N`. The watchdog runs every 30s, so the actual notification fires at `THRESHOLD_MIN` to `THRESHOLD_MIN + 30s` after Claude started waiting.

The wait period is identified by:
- `.state` color matches `WAIT_COLOR` (orange)
- `.state` mtime is older than `THRESHOLD_MIN` minutes
- No `.notified` sidecar exists, OR `.notified` is older than `.state` (= a fresh wait period started)

When you respond (UserPromptSubmit), the state file gets rewritten with a new color and mtime; the next wait period restarts the cycle.

## What this skill DOESN'T do

- Doesn't change tab colors or the dock-attention behavior — those still work whether notifications are on or off.
- Doesn't notify per-event during Claude's normal turn-end (the tab going orange already handles fast feedback). Notifications are for the "I walked away, Claude finished, I forgot to come back" case.
- Doesn't bundle / batch notifications across multiple tabs — each waiting tab gets its own.

## Where the supporting files live

- `~/.claude/hooks/iterm-notifications.sh` — this script (the skill helper)
- `~/.claude/hooks/iterm-notifications.conf` — the persisted config
- `~/.claude/hooks/iterm-notify-waiting.sh` — the actual notifier (called from the watchdog)
- `~/.claude/hooks/iterm-watchdog.sh` — calls the notifier every 30s

All under version control at `github.com/wasulajr/lookout`.
