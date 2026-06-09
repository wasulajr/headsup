---
name: headsup-resync-tab
description: Force-resync a Codex iTerm2 tab whose headsup color/title/attention state is stale. Use when the visible tab color is wrong.
---

# Codex Headsup Resync

Resync current tab:

```bash
~/.codex/hooks/headsup-codex-resync.sh
```

Resync a specific iTerm2 session UUID:

```bash
~/.codex/hooks/headsup-codex-resync.sh <uuid>
```

Force a specific color and attention state:

```bash
~/.codex/hooks/headsup-codex-resync.sh <uuid> <hex-color> <yes|no>
```

After success, confirm in one sentence.
