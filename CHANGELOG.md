# Changelog

All notable changes to headsup. Versions follow [semver](https://semver.org/): MINOR for new features and skills, PATCH for fixes, MAJOR for breaking conf/layout changes that require re-running `setup.sh`.

## [0.3.4] - 2026-06-19

- Fix daemon state-dir split-brain (#25): daemon no longer resolves its install symlink, so its heartbeat/pid/state land in ~/.claude/hooks/.state where the watchdog reads — ends the endless daemon respawn + Tier 2 fan-out and restores the fast color path

## [0.3.3] - 2026-06-19

- Fix ghost 'Claude is waiting' notifications for closed tabs: notifier now verifies the session is a live iTerm2 tab before firing and reaps stale state markers (headsup-notify-waiting.sh liveness gate)

## [0.3.2] - 2026-06-17

- Fix apply-once.py runaway that wedged iTerm2: SIGALRM hard timeout (15s) so one-shots can never hang forever on a contended iTerm2 API
- Add watchdog backpressure guard: skip the Tier 2 fan-out when >8 one-shots are already in flight, breaking the snowball at the source

## [0.3.1] - 2026-06-09

- Developer notes: document the SKILL.md YAML frontmatter quoting gotcha in CLAUDE.md (an unquoted colon in a description silently hides the skill from the menu); includes the quoting rule and a ruby one-liner to verify a skill parses before committing

## [0.3.0] - 2026-06-09

- Codex CLI support: iTerm2 tab colors, lifecycle hooks, watchdog, notifications, and the full skill set ported alongside Claude Code (setup-codex.sh, codex-skills/, headsup-codex-* hooks)
- Daemon and apply-once made provider-agnostic via HEADSUP_HOOK_DIR so one codebase drives both ~/.claude and ~/.codex installs
- Fix: quote headsup-colors and headsup-status skill descriptions so their YAML frontmatter parses (an unquoted colon made Codex silently skip both skills)
- Fix: setup-codex.sh removes stale ~/.codex/skills/headsup-* from the prior install location so skills no longer show up twice

## [0.2.0] - 2026-06-05

- Release tooling: scripts/release.sh, VERSION file, CHANGELOG.md, repo CLAUDE.md enforcing the release flow (#19)
- Status line: context bar with escalating notifications, session/week usage percentages, API cost display
- /headsup-update script + skill; setup.sh pulls latest from GitHub by default
- New Claude Tab Finder Quick Action (cmd-opt-C) with in-session label prompt and stage logging
- headsup-label routed through headsup-set-label.sh for prompt-free labeling; setup.sh auto-adds the permissions.allow rule
- Custom notifier .app with icon, wired to NSApplication runloop
- Project renamed lookout to iterm-config to headsup; public-release cleanup (personal refs and bundled icon source removed)
- Runtime state dirs gitignored; executable bits restored on scripts

## [0.1.0] - 2026-05-25

- Initial tagged release: iTerm2 tab colors driven by Claude Code hook events, launchd watchdog, waiting notifications, and the original skill set.
