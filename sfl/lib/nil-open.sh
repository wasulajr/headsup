#!/bin/bash
# nil-open.sh — "now is later". Open one iTerm2 tab per live /sfl checkpoint
# in ~/.claude/sfl/*.md. Each tab cds to the window's dir, restores its headsup
# label, and launches claude with a resume prompt that points at that window's
# (already archived) entry file.
#
# Archiving happens HERE, at launch time: every entry is moved into archive/
# before the tabs open, and the resume prompts point at the archived paths.
# After a successful run ~/.claude/sfl/ is empty, so a second /nil can never
# relaunch a window twice. (Earlier design had each child session archive its
# own entry; entries leaked whenever a tab was closed before resuming.) If the
# AppleScript fails (iTerm not running, Automation denied), the moves are
# rolled back so nothing is lost.
#
# Usage:
#   nil-open.sh            open the tabs
#   nil-open.sh --list     print each entry's window/project/cwd/saved_at,
#                          open nothing (used by the /nil skill's step 1, so the
#                          single nil-open.sh allowlist rule covers the whole
#                          skill and the user is never prompted)
#   nil-open.sh --dry-run  print the generated AppleScript and the entry list,
#                          open nothing (for testing)
#
# Prints one "opening: <window>  (<cwd>)" line per entry. Prints "no-entries"
# and exits 0 if there are no live checkpoints.

set -euo pipefail

SFL_DIR="$HOME/.claude/sfl"
SET_LABEL="$HOME/.claude/hooks/headsup-set-label.sh"
DRY_RUN=0
LIST=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    --list)    LIST=1 ;;
esac

shopt -s nullglob
entries=("$SFL_DIR"/*.md)   # does not recurse into archive/ or lib/
if [ ${#entries[@]} -eq 0 ]; then
    echo "no-entries"
    exit 0
fi

# Pull a single top-level key out of a file's YAML frontmatter.
frontval() {  # $1=file  $2=key
    awk -v k="$2" '
        NR==1 && $0=="---" {infm=1; next}
        infm && $0=="---" {exit}
        infm {
            if ($0 ~ "^"k":") { sub("^"k":[ \t]*",""); print; exit }
        }' "$1"
}

# ── --list: show what would be reopened, open nothing ───────────────────────
# This is the allowlisted replacement for the ad-hoc for/awk loop that used to
# live in the /nil skill doc (which prompted because it had no allowlist rule).
if [ "$LIST" -eq 1 ]; then
    for f in "${entries[@]}"; do
        echo "── $(basename "$f")"
        for k in window project cwd saved_at; do
            v=$(frontval "$f" "$k")
            [ -n "$v" ] && printf '%s: %s\n' "$k" "$v"
        done
    done
    exit 0
fi

# Escape a string for embedding inside an AppleScript double-quoted literal.
asesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

SCPT="$(mktemp "${TMPDIR:-/tmp}/nil-open.XXXXXX")"
mv "$SCPT" "$SCPT.scpt"; SCPT="$SCPT.scpt"

cat > "$SCPT" <<'AS'
on openTab(dirPath, tabName, shellCmd)
	tell application "iTerm2"
		activate
		if (count of windows) = 0 then
			create window with default profile
		else
			tell current window
				create tab with default profile
			end tell
		end if
		tell current session of current window
			set name to tabName
			write text shellCmd
		end tell
		delay 0.6
	end tell
end openTab

AS

ARCHIVE_DIR="$SFL_DIR/archive"
mkdir -p "$ARCHIVE_DIR"
STAMP="$(date '+%Y%m%d-%H%M%S')"
move_src=()
move_dst=()

count=0
for f in "${entries[@]}"; do
    win=$(frontval "$f" window)
    cwd=$(frontval "$f" cwd)
    base=$(basename "$f")
    slug="${base%.md}"
    arch_base="${slug}-${STAMP}.md"
    # Every entry gets archived this run — launched or skipped — so the live
    # list is guaranteed empty afterward. Skipped ones are preserved in
    # archive/, never relaunched.
    move_src+=("$f")
    move_dst+=("$ARCHIVE_DIR/$arch_base")
    [ -n "$win" ] || win="$slug"
    if [ -z "$cwd" ]; then
        echo "skip (no cwd, archiving entry): $base" >&2
        continue
    fi
    # Expand a leading ~ in the recorded cwd.
    case "$cwd" in "~"*) cwd="$HOME${cwd#\~}";; esac

    prompt="Resume my saved-for-later checkpoint for this window. Read and follow ~/.claude/sfl/archive/$arch_base (the Checkpoint section plus the How to restart steps), then read its gov_memory file for fuller context. The entry was already archived by /nil at launch, so do not archive anything. Give me a 3 to 5 line catch-up of where we left off and the single recommended next step. Do not start the work until I confirm."

    # Shell line typed into the fresh tab: cd, restore label, then launch claude.
    # set-label always exits 0, so && chaining is safe.
    shellcmd="cd $(printf '%q' "$cwd") && $(printf '%q' "$SET_LABEL") $(printf '%q' "$win") && claude $(printf '%q' "$prompt")"

    printf 'my openTab("%s", "%s", "%s")\n' \
        "$(asesc "$cwd")" "$(asesc "$win")" "$(asesc "$shellcmd")" >> "$SCPT"

    echo "opening: $win  ($cwd)"
    count=$((count + 1))
done

if [ "$DRY_RUN" -eq 1 ]; then
    echo "--- generated AppleScript ($SCPT) ---"
    cat "$SCPT"
    echo "--- end ($count tab(s); dry run, nothing archived) ---"
    exit 0
fi

# Archive every entry BEFORE opening tabs, so the resume prompts (which point
# at the archived paths) are valid the moment each tab's claude starts reading.
for i in "${!move_src[@]}"; do
    mv -f "${move_src[$i]}" "${move_dst[$i]}"
done

if ! osascript "$SCPT"; then
    echo "osascript failed — restoring live entries so nothing is lost" >&2
    for i in "${!move_src[@]}"; do
        mv -f "${move_dst[$i]}" "${move_src[$i]}"
    done
    rm -f "$SCPT"
    exit 1
fi
rm -f "$SCPT"
echo "opened $count tab(s); archived ${#move_src[@]} entr(y/ies) — ~/.claude/sfl/ is now empty"
exit 0
