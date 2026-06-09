---
name: headsup-label
description: Set or clear the per-iTerm2-session label for the current Codex tab. Use when the user wants a custom Codex tab title or badge.
---

# Codex Headsup Label

Set one string as both the iTerm2 title and badge for this Codex pane only.

If the user supplied a label, use it. Otherwise ask one concise question for the label before running tools.

Set label:

```bash
~/.codex/hooks/headsup-codex-set-label.sh '<label>'
```

Clear label:

```bash
~/.codex/hooks/headsup-codex-set-label.sh --clear
```

The helper writes `~/.codex/hooks/headsup-status.d/<session>.conf` and `/tmp/headsup-codex-$(id -u)/.state/<uuid>.badge`.

Do not commit these per-session files.
