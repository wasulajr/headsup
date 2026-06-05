#!/bin/bash
# release.sh: cut a headsup release in one command.
# Bumps VERSION, prepends a CHANGELOG.md section, commits, tags vX.Y.Z,
# and pushes main with tags. The one true release path (issue #19).
#
# Usage:
#   scripts/release.sh <major|minor|patch> -m "what changed" [-m "more" ...]
#   scripts/release.sh X.Y.Z -m "what changed" [-m "more" ...]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
ok()   { printf '%s✓%s  %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '%s⚠%s  %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%s✗%s  %s\n' "$RED"    "$RESET" "$*"; exit 1; }

usage() {
    printf 'Usage: scripts/release.sh <major|minor|patch|X.Y.Z> -m "change" [-m "change" ...]\n'
    exit 1
}

# ── Parse arguments ───────────────────────────────────────────────────────
[ $# -ge 1 ] || usage
BUMP="$1"; shift

MESSAGES=()
while [ $# -gt 0 ]; do
    case "$1" in
        -m) [ $# -ge 2 ] || usage; MESSAGES+=("$2"); shift 2 ;;
        *)  usage ;;
    esac
done
[ ${#MESSAGES[@]} -ge 1 ] || fail "at least one -m \"change description\" is required"

# ── Preflight ─────────────────────────────────────────────────────────────
BRANCH="$(git branch --show-current)"
[ "$BRANCH" = "main" ] || fail "releases are cut from main (currently on '$BRANCH')"

[ -z "$(git status --porcelain)" ] || fail "working tree is dirty; commit or stash first"

git fetch origin --quiet || fail "git fetch failed; check network"
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main)"
if [ "$LOCAL" != "$REMOTE" ]; then
    BEHIND="$(git rev-list --count HEAD..origin/main)"
    [ "$BEHIND" -eq 0 ] || fail "main is $BEHIND commit(s) behind origin/main; pull first"
fi

# ── Compute the new version ───────────────────────────────────────────────
[ -f VERSION ] || fail "VERSION file not found at repo root"
CURRENT="$(tr -d '[:space:]' < VERSION)"
IFS=. read -r MAJ MIN PAT <<< "$CURRENT"

case "$BUMP" in
    major) NEW="$((MAJ + 1)).0.0" ;;
    minor) NEW="$MAJ.$((MIN + 1)).0" ;;
    patch) NEW="$MAJ.$MIN.$((PAT + 1))" ;;
    *)
        printf '%s' "$BUMP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
            || fail "'$BUMP' is not major/minor/patch or an X.Y.Z version"
        NEW="$BUMP"
        ;;
esac

git rev-parse "v$NEW" >/dev/null 2>&1 && fail "tag v$NEW already exists"

printf '%sheadsup release%s  %s%s → %s%s\n\n' "$BOLD" "$RESET" "$DIM" "$CURRENT" "$RESET" "$NEW"

# ── Update VERSION + CHANGELOG.md ─────────────────────────────────────────
printf '%s\n' "$NEW" > VERSION
ok "VERSION → $NEW"

TODAY="$(date +%Y-%m-%d)"
{
    printf '## [%s] - %s\n\n' "$NEW" "$TODAY"
    for msg in "${MESSAGES[@]}"; do
        printf -- '- %s\n' "$msg"
    done
    printf '\n'
} > /tmp/headsup-release-section.$$

if [ -f CHANGELOG.md ]; then
    # Insert the new section after the header block (before the first "## [").
    awk -v section="/tmp/headsup-release-section.$$" '
        !inserted && /^## \[/ {
            while ((getline line < section) > 0) print line
            inserted = 1
        }
        { print }
        END {
            if (!inserted) {
                while ((getline line < section) > 0) print line
            }
        }
    ' CHANGELOG.md > /tmp/headsup-changelog.$$ && mv /tmp/headsup-changelog.$$ CHANGELOG.md
else
    {
        printf '# Changelog\n\nAll notable changes to headsup. Versions follow [semver](https://semver.org/).\n\n'
        cat /tmp/headsup-release-section.$$
    } > CHANGELOG.md
fi
rm -f /tmp/headsup-release-section.$$
ok "CHANGELOG.md updated"

# ── Commit, tag, push ─────────────────────────────────────────────────────
git add VERSION CHANGELOG.md
git commit --quiet -m "release v$NEW"
ok "committed release v$NEW"

git tag -a "v$NEW" -m "${MESSAGES[0]}"
ok "tagged v$NEW"

git push --quiet origin main --follow-tags || fail "push failed; tag v$NEW exists locally, retry with: git push origin main --follow-tags"
ok "pushed main + v$NEW to origin"

printf '\n%sDone.%s headsup is now v%s\n' "$BOLD" "$RESET" "$NEW"
