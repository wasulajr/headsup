#!/bin/bash
# Pull latest headsup and re-apply the Codex install.

set -u

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_DIR="$CODEX_HOME/hooks"
REPO_MARKER="$HOOK_DIR/.headsup-repo"
HEADSUP_DIR=""

if [ -f "$REPO_MARKER" ]; then
    cand="$(cat "$REPO_MARKER" 2>/dev/null)"
    [ -n "$cand" ] && [ -d "$cand/.git" ] && HEADSUP_DIR="$cand"
fi
if [ -z "$HEADSUP_DIR" ]; then
    src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        d="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"; [ "${src#/}" = "$src" ] && src="$d/$src"
    done
    cand="$(cd "$(dirname "$src")/.." && pwd)"
    [ -d "$cand/.git" ] && HEADSUP_DIR="$cand"
fi
if [ -z "$HEADSUP_DIR" ]; then
    for cand in "$HOME/.claude/headsup" "$HOME/headsup"; do
        [ -d "$cand/.git" ] && { HEADSUP_DIR="$cand"; break; }
    done
fi

GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
ok() { printf '%s✓%s  %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s⚠%s  %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%s✗%s  %s\n' "$RED" "$RESET" "$*"; }
info() { printf '   %s%s%s\n' "$DIM" "$*" "$RESET"; }

printf '%sheadsup Codex update%s\n' "$BOLD" "$RESET"
printf '%s%s%s\n\n' "$DIM" "$HEADSUP_DIR" "$RESET"

if [ -z "$HEADSUP_DIR" ] || [ ! -d "$HEADSUP_DIR/.git" ]; then
    fail "headsup repo not found"
    info "Set its location with: echo /path/to/headsup > $REPO_MARKER"
    exit 1
fi

printf 'Checking for updates...\n'
if ! git -C "$HEADSUP_DIR" fetch origin --quiet 2>/dev/null; then
    fail "git fetch failed — check network or remote"
    exit 1
fi

LOCAL=$(git -C "$HEADSUP_DIR" rev-parse HEAD)
REMOTE=$(git -C "$HEADSUP_DIR" rev-parse origin/main 2>/dev/null)

if [ "$LOCAL" != "$REMOTE" ]; then
    COUNT=$(git -C "$HEADSUP_DIR" rev-list HEAD..origin/main --count)
    printf '\nPulling %d commit%s:\n' "$COUNT" "$([ "$COUNT" -eq 1 ] && echo '' || echo 's')"
    while IFS= read -r line; do info "$line"; done < <(git -C "$HEADSUP_DIR" log --oneline HEAD..origin/main)
    echo
    git -C "$HEADSUP_DIR" pull origin main --quiet || { fail "git pull failed"; exit 1; }
    ok "Updated to $(git -C "$HEADSUP_DIR" log -1 --format='%h %s')"
else
    ok "Already up to date — $(git -C "$HEADSUP_DIR" log -1 --format='%h %s')"
fi

if [ -x "$HEADSUP_DIR/setup-codex.sh" ]; then
    "$HEADSUP_DIR/setup-codex.sh" --no-prereq-summary >/dev/null 2>&1 || "$HEADSUP_DIR/setup-codex.sh"
    ok "Re-applied Codex install"
else
    fail "setup-codex.sh missing from repo"
    exit 1
fi

echo
ok "Done"
