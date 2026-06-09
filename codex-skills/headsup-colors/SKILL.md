---
name: headsup-colors
description: "Customize headsup's global iTerm2 tab colors for Codex sessions: idle, working, and waiting. Use when the user asks to change Codex/headsup tab colors."
---

# Codex Headsup Colors

Edit `~/.codex/hooks/headsup-status.conf`. Change only these variables:

- `IDLE_COLOR`
- `PROCESS_COLOR`
- `WAIT_COLOR`

Accept 6-character hex values without `#`, or translate common color names yourself. Preserve all other file content.

After editing, if `PROCESS_COLOR` changed, apply it immediately to the current tab because Codex is currently working:

```bash
~/.codex/hooks/headsup-codex-resync.sh
```

If only idle or waiting changed, tell the user the new color will appear on the next matching Codex state.

Do not edit Claude files under `~/.claude`.
