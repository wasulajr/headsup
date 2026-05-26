---
name: iterm-notifications
description: Manage the macOS notification that fires when a Claude Code tab has been waiting on the user for more than N minutes. Use when the user types /iterm-notifications, asks to enable/disable the "Claude is waiting" notification, wants to change how long it waits before notifying, or wants to test that notifications are working. Accepts on/off, a numeric threshold (minutes), "test" to fire a one-off notification, and "sound <name|none>" to change the alert sound.
---

# iTerm waiting-notifications

The launchd watchdog (`claude-code.iterm-watchdog`) runs every 30 seconds. When it finds a tab whose state file has been orange (waiting) for longer than `THRESHOLD_MIN` minutes, it fires a macOS notification. This skill is the user-friendly way to toggle the feature, change the threshold, change the sound, or test that it works.

Notifications are posted from the bundled `headsup-notifier.app` at `~/Library/Application Support/headsup/`, so Notification Center renders them with the headsup icon. The bundle is built and installed by `setup.sh` (Step 5/8). No third-party dependencies like terminal-notifier are required.

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
| `/iterm-notifications sound <name>` | Set sound, any macOS system sound name (Glass, Ping, Submarine, etc.)|
| `/iterm-notifications sound none` | Silence the notification                                               |

## What to do when invoked

Run the helper script with the user's args. Don't try to parse the args yourself; pass them through unchanged. The helper updates the config in place and prints the resulting state.

```bash
~/.claude/hooks/iterm-notifications.sh "$@"
```

If the user just said "turn on notifications" or "enable", pass `on`. "Turn them off" or "disable" becomes `off`. "Set the threshold to 10 minutes" or "wait 10 minutes" becomes `10`. "Test it" or "send me a test" becomes `test`.

After the helper prints the new state, **don't add a long explanation**; the output is clear enough. One short confirmation sentence if the change is non-obvious (e.g., "Notifications will now fire after 10 minutes of waiting").

## First-run macOS permissions

macOS requires per-bundle notification permission. The first time a notification fires (from `/iterm-notifications test` or a real wait), macOS shows "headsup wants to send notifications." Click **Allow**. The decision sticks to the bundle's codesigning identity, so future notifications fire silently.

If notifications stop appearing later: System Settings, Notifications, scroll for `headsup`, ensure "Allow Notifications" is on.

If `headsup` isn't in the list at all (rare, indicates macOS recorded a silent denial), the recovery is in the README's Troubleshooting section: bump the bundle ID in `notifier-app/Info.plist.template` and re-run `setup.sh` so macOS treats it as a fresh app.

## Notification content

What you see when a notification fires:

| Slot                 | Source                                                                            |
|----------------------|-----------------------------------------------------------------------------------|
| Top header + icon    | `headsup` (the bundle's CFBundleName) and the orange face icon                    |
| Title (large, bold)  | The per-tab badge from `~/.claude/hooks/.state/<uuid>.badge` (matches the iTerm2 watermark; defaults to the project name, override via `/iterm-label`) |
| Subtitle             | `Claude is waiting`                                                               |
| Body                 | `Idle for <N>m` (or longer)                                                       |
| Sound                | `NOTIFICATION_SOUND` from conf (default `Glass`)                                  |

The title differing from the app name is how you tell which tab needs you when multiple are waiting.

## How the threshold actually applies

`THRESHOLD_MIN` is matched against the `.state` file's mtime via `find -mmin +N`. The watchdog runs every 30s, so the actual notification fires at `THRESHOLD_MIN` to `THRESHOLD_MIN + 30s` after Claude started waiting.

The wait period is identified by:
- `.state` color matches `WAIT_COLOR` (orange)
- `.state` mtime is older than `THRESHOLD_MIN` minutes
- No `.notified` sidecar exists, OR `.notified` is older than `.state` (a fresh wait period started)

When you respond (UserPromptSubmit), the state file gets rewritten with a new color and mtime; the next wait period restarts the cycle.

## What this skill DOESN'T do

- Doesn't change tab colors or the dock-attention behavior; those still work whether notifications are on or off.
- Doesn't notify per-event during Claude's normal turn-end. The tab going orange already handles fast feedback. Notifications are for the "I walked away, Claude finished, I forgot to come back" case.
- Doesn't bundle or batch notifications across multiple tabs; each waiting tab gets its own.
- Doesn't support sub-minute thresholds. `find -mmin` is integer-minute granularity, and the watchdog cadence is 30s. Sub-minute would require additional changes to both.

## Where the supporting files live

- `~/.claude/hooks/iterm-notifications.sh` is this skill's helper script
- `~/.claude/hooks/iterm-notifications.conf` is the persisted config
- `~/.claude/hooks/iterm-notify-waiting.sh` is the actual notifier sweep (called from the watchdog)
- `~/.claude/hooks/iterm-watchdog.sh` calls the notifier every 30s
- `~/Library/Application Support/headsup/headsup-notifier.app` is the Swift binary that posts the notification (so macOS renders the headsup icon)

All under version control at `github.com/wasulajr/headsup`.
