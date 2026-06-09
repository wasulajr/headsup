---
name: headsup-diagnose
description: Actively test the Codex headsup stack by flashing idle, working, and waiting tab colors and checking daemon application.
---

# Codex Headsup Diagnose

Run the fast color-flash test:

```bash
~/.codex/hooks/headsup-codex-diagnose.sh
```

Only pass `--restart` if the user explicitly asks for a deep/full test:

```bash
~/.codex/hooks/headsup-codex-diagnose.sh --restart
```

This briefly changes the current iTerm2 tab color, then restores the previous state.
