#!/bin/bash
# headsup-update.sh — Pull the latest headsup from GitHub and apply it.
#
# Usage: headsup-update.sh
# Invoked via the /headsup-update skill or directly from the terminal.

# ── Locate the repo ───────────────────────────────────────────────────────────
# The installed copy of this script lives in ~/.claude/hooks, severed from the
# clone, so "parent of my own dir" is wrong for a copy install. Resolution order:
#   1. marker file written by setup.sh   2. resolve our own symlink chain
#   3. known locations                   4. parent-of-self (run from inside clone)
CLAUDE_DIR="$HOME/.claude"
REPO_MARKER="$CLAUDE_DIR/hooks/.headsup-repo"
HEADSUP_DIR=""
if [ -f "$REPO_MARKER" ]; then
    _cand="$(cat "$REPO_MARKER" 2>/dev/null)"
    [ -n "$_cand" ] && [ -d "$_cand/.git" ] && HEADSUP_DIR="$_cand"
fi
if [ -z "$HEADSUP_DIR" ]; then
    _src="${BASH_SOURCE[0]}"
    while [ -L "$_src" ]; do
        _d="$(cd -P "$(dirname "$_src")" && pwd)"
        _src="$(readlink "$_src")"; [ "${_src#/}" = "$_src" ] && _src="$_d/$_src"
    done
    _cand="$(cd "$(dirname "$_src")/.." && pwd)"
    [ -d "$_cand/.git" ] && HEADSUP_DIR="$_cand"
fi
if [ -z "$HEADSUP_DIR" ]; then
    for _cand in "$CLAUDE_DIR/headsup" "$HOME/headsup"; do
        [ -d "$_cand/.git" ] && { HEADSUP_DIR="$_cand"; break; }
    done
fi

GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
ok()   { printf '%s✓%s  %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '%s⚠%s  %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%s✗%s  %s\n' "$RED"    "$RESET" "$*"; }
info() { printf '   %s%s%s\n' "$DIM" "$*" "$RESET"; }

printf '%sheadsup update%s\n' "$BOLD" "$RESET"
printf '%s%s%s\n\n' "$DIM" "$HEADSUP_DIR" "$RESET"

# ── Sanity check ──────────────────────────────────────────────────────────────
if [ -z "$HEADSUP_DIR" ] || [ ! -d "$HEADSUP_DIR/.git" ]; then
    fail "headsup repo not found"
    info "Set its location with: echo /path/to/headsup > $REPO_MARKER"
    exit 1
fi

# ── Fetch ─────────────────────────────────────────────────────────────────────
printf 'Checking for updates...\n'
if ! git -C "$HEADSUP_DIR" fetch origin --quiet 2>/dev/null; then
    fail "git fetch failed — check network or remote"
    exit 1
fi

LOCAL=$(git -C "$HEADSUP_DIR" rev-parse HEAD)
REMOTE=$(git -C "$HEADSUP_DIR" rev-parse origin/main 2>/dev/null)

if [ "$LOCAL" = "$REMOTE" ]; then
    ok "Already up to date — $(git -C "$HEADSUP_DIR" log -1 --format='%h %s')"
    exit 0
fi

# ── Changelog ─────────────────────────────────────────────────────────────────
COUNT=$(git -C "$HEADSUP_DIR" rev-list HEAD..origin/main --count)
printf '\nPulling %d commit%s:\n' "$COUNT" "$([ "$COUNT" -eq 1 ] && echo '' || echo 's')"
while IFS= read -r line; do info "$line"; done < <(git -C "$HEADSUP_DIR" log --oneline HEAD..origin/main)
echo

# ── Note which files are changing before pulling ──────────────────────────────
CHANGED=$(git -C "$HEADSUP_DIR" diff --name-only HEAD origin/main)
DAEMON_CHANGED=$(echo "$CHANGED" | grep -c "iterm2-daemon.py" || true)
QA_CHANGED=$(echo "$CHANGED" | grep -c "headsup-new-tab-shortcut/New Claude Tab.workflow" || true)

# ── Pull ──────────────────────────────────────────────────────────────────────
if ! git -C "$HEADSUP_DIR" pull origin main --quiet; then
    fail "git pull failed"
    exit 1
fi
ok "Updated to $(git -C "$HEADSUP_DIR" log -1 --format='%h %s')"

# ── Apply pulled files to ~/.claude (copy installs) ───────────────────────────
# setup.sh copies hooks/skills into ~/.claude, so a plain pull never reaches the
# live files. Re-copy anything that differs. A symlinked entry is an in-place
# install (pull already applied) → skip it. User-owned config files are never
# overwritten. Hook files are replaced via temp+rename so this script can safely
# overwrite its own running copy (the old inode stays open for this process).
CONFIG_KEEP=" headsup-status.conf headsup-notifications.conf "
synced=0
for src in "$HEADSUP_DIR/hooks/"*; do
    [ -f "$src" ] || continue
    n="$(basename "$src")"
    case "$CONFIG_KEEP" in *" $n "*) continue ;; esac
    dst="$CLAUDE_DIR/hooks/$n"
    [ -L "$dst" ] && continue
    cmp -s "$src" "$dst" 2>/dev/null && continue
    tmp="$CLAUDE_DIR/hooks/.${n}.tmp.$$"
    if cp "$src" "$tmp" 2>/dev/null; then
        chmod +x "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$dst" && { synced=$((synced+1)); info "synced hooks/$n"; }
    fi
done
for srcdir in "$HEADSUP_DIR/skills/"headsup-*/; do
    [ -d "$srcdir" ] || continue
    n="$(basename "$srcdir")"
    dst="$CLAUDE_DIR/skills/$n"
    [ -L "$dst" ] && continue
    diff -qr "$srcdir" "$dst" >/dev/null 2>&1 && continue
    rm -rf "$dst" && cp -r "$srcdir" "$dst" && { synced=$((synced+1)); info "synced skills/$n"; }
done
if [ "$synced" -gt 0 ]; then ok "Re-synced $synced item(s) into ~/.claude"; else ok "Live files already in sync"; fi

# ── Restart daemon if its script changed ──────────────────────────────────────
if [ "$DAEMON_CHANGED" -gt 0 ]; then
    DAEMON_PID_FILE="$HOME/.claude/hooks/.state/daemon.pid"
    if [ -f "$DAEMON_PID_FILE" ]; then
        DAEMON_PID=$(cat "$DAEMON_PID_FILE")
        if kill -0 "$DAEMON_PID" 2>/dev/null; then
            kill "$DAEMON_PID" 2>/dev/null
            warn "iterm2-daemon.py changed — killed PID $DAEMON_PID; watchdog will respawn it within 30s"
        fi
    fi
fi

# ── Re-install the New Claude Tab Quick Action if the bundle changed ──────────
# ~/Library/Services must hold a real copy (not a symlink), so a pull that
# touches the bundle needs an explicit re-copy. Only re-installs if the
# Quick Action was already installed — first-time install is setup.sh's job.
QA_SRC="$HEADSUP_DIR/skills/headsup-new-tab-shortcut/New Claude Tab.workflow"
QA_DST="$HOME/Library/Services/New Claude Tab.workflow"
if [ "$QA_CHANGED" -gt 0 ] && [ -d "$QA_DST" ] && [ -d "$QA_SRC" ]; then
    rm -rf "$QA_DST"
    cp -R "$QA_SRC" "$QA_DST"
    /System/Library/CoreServices/pbs -flush
    ok "New Claude Tab Quick Action re-installed into ~/Library/Services"
fi

echo
ok "Done"
