---
name: headsup-label
description: Set or clear the current Codex window label in AI Power Term or iTerm2. Use when the user wants a custom Codex tab title, badge, or watermark.
---

# Codex Headsup Label

Set one string as the AI Power Term tab title/watermark, or as the iTerm2 title and badge, for this Codex pane only.

If the user supplied a label, use it. Otherwise ask one concise question for the label before running tools.

Set label:

```bash
~/.codex/hooks/headsup-codex-set-label.sh '<label>'
```

Clear label:

```bash
~/.codex/hooks/headsup-codex-set-label.sh --clear
```

The helper writes `~/.codex/hooks/headsup-status.d/<session>.conf` and `/tmp/headsup-codex-$(id -u)/.state/<uuid>.badge`. In AI Power Term, it also sends a websocket rename to the app server.

Do not commit these per-session files.
