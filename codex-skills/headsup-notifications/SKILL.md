---
name: headsup-notifications
description: Manage macOS notifications for Codex tabs that have been waiting longer than a configured threshold.
---

# Codex Headsup Notifications

Pass the user's requested args through to:

```bash
~/.codex/hooks/headsup-codex-notifications.sh "$@"
```

Useful forms:

- `on`
- `off`
- `<N>` for threshold minutes
- `<N> on`
- `<N> off`
- `test`
- `sound <name>`
- `sound none`

The LaunchAgent `codex.headsup-watchdog` runs the waiting sweep every 30 seconds.
