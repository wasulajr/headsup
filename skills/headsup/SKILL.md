---
name: headsup
description: "Show the default headsup health/status snapshot for Claude Code tabs. Use when the user types /headsup, asks whether headsup is working, or wants the quick overview rather than a specific focused command. For focused actions, route to /headsup-label, /headsup-config, /headsup-status, /headsup-diagnose, /headsup-colors, /headsup-notifications, or /headsup-update."
---

# /headsup

Default headsup overview for Claude Code.

## What to do

Run the read-only status report:

```bash
~/.claude/hooks/headsup-status-report.sh
```

Let the report stand on its own unless the user asks a follow-up.

## Related focused commands

- `/headsup-label`: set the current tab title/badge/watermark
- `/headsup-config`: settings hub for labels, colors, notifications, and new-tab launch modes
- `/headsup-status`: explicit passive health snapshot
- `/headsup-diagnose`: active color/status test
- `/headsup-colors`: change idle/working/waiting colors
- `/headsup-notifications`: waiting-tab notifications
- `/headsup-update`: update headsup from source
