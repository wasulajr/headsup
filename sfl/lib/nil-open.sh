#!/bin/bash
# nil-open.sh — "now is later". Open one iTerm2 tab per selected /sfl checkpoint
# in ~/.claude/sfl/*.md. Each tab cds to the window's dir, restores its headsup
# label, and launches claude with a resume prompt that points at that window's
# (already archived) entry file.
#
# Selective launch: by default every checkpoint is launched, but a selection of
# entry numbers (as shown by --list) can be passed to launch only some. Only the
# LAUNCHED entries are archived; un-selected entries stay live in ~/.claude/sfl/
# so a later /nil can still open them.
#
# Archiving happens HERE, at launch time: each launched entry is moved into
# archive/ before the tabs open, and the resume prompts point at the archived
# paths. After a run, the launched entries are gone from ~/.claude/sfl/ so a
# second /nil can never relaunch the same window twice. (Earlier design had each
# child session archive its own entry; entries leaked whenever a tab was closed
# before resuming.) If the AppleScript fails (iTerm not running, Automation
# denied), the moves are rolled back so nothing is lost.
#
# Usage:
#   nil-open.sh                open ALL the tabs (default)
#   nil-open.sh all            same as above, explicit
#   nil-open.sh 1,3,4          open only entries 1, 3 and 4 (numbers from --list);
#                              commas or spaces both work (e.g. "1 3 4")
#   nil-open.sh --list         print each entry NUMBERED with its
#                              window/project/cwd/saved_at, open nothing (used by
#                              the /nil skill's step 1, so the single nil-open.sh
#                              allowlist rule covers the whole skill and the user
#                              is never prompted)
#   nil-open.sh --dry-run [SEL] print the generated AppleScript and the entry
#                              list for the selection, open nothing (for testing)
#
# Prints one "opening: <window>  (<cwd>)" line per launched entry. Prints
# "no-entries" and exits 0 if there are no live checkpoints.

set -euo pipefail

SFL_DIR="$HOME/.claude/sfl"
SET_LABEL="$HOME/.claude/hooks/headsup-set-label.sh"
DRY_RUN=0
LIST=0
case "${1:-}" in
    --dry-run) DRY_RUN=1; shift ;;
    --list)    LIST=1; shift ;;
esac
# Anything left on the command line is the selection: "all"/empty for every
# entry, or a list of 1-based entry numbers (comma- or space-separated).
SELECTION="$*"

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

# ── --list: show what would be reopened, NUMBERED, open nothing ──────────────
# This is the allowlisted replacement for the ad-hoc for/awk loop that used to
# live in the /nil skill doc (which prompted because it had no allowlist rule).
# The numbers printed here are the selection numbers accepted by this script.
if [ "$LIST" -eq 1 ]; then
    n=0
    for f in "${entries[@]}"; do
        n=$((n + 1))
        echo "$n. ── $(basename "$f")"
        for k in window project cwd saved_at; do
            v=$(frontval "$f" "$k")
            [ -n "$v" ] && printf '   %s: %s\n' "$k" "$v"
        done
    done
    exit 0
fi

# ── Resolve the selection into a per-entry launch mask (want[i], 0-based) ────
total=${#entries[@]}
sel_norm="${SELECTION//,/ }"          # commas -> spaces
read -r -a sel_tokens <<< "$sel_norm" # split on whitespace, drop empties
declare -a want
for ((i = 0; i < total; i++)); do want[$i]=0; done

if [ ${#sel_tokens[@]} -eq 0 ] || { [ ${#sel_tokens[@]} -eq 1 ] && [ "${sel_tokens[0]}" = "all" ]; }; then
    for ((i = 0; i < total; i++)); do want[$i]=1; done
else
    for tok in "${sel_tokens[@]}"; do
        if ! [[ "$tok" =~ ^[0-9]+$ ]]; then
            echo "nil-open: invalid selection '$tok' (use numbers like 1,3,4 or 'all')" >&2
            exit 2
        fi
        if [ "$tok" -lt 1 ] || [ "$tok" -gt "$total" ]; then
            echo "nil-open: selection $tok out of range (1-$total)" >&2
            exit 2
        fi
        want[$((tok - 1))]=1
    done
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
for i in "${!entries[@]}"; do
    [ "${want[$i]}" = "1" ] || continue   # un-selected entries stay live
    f="${entries[$i]}"
    win=$(frontval "$f" window)
    cwd=$(frontval "$f" cwd)
    base=$(basename "$f")
    slug="${base%.md}"
    arch_base="${slug}-${STAMP}.md"
    # Only the SELECTED entries get archived this run (launched or skipped for a
    # missing cwd); un-selected entries are left live in ~/.claude/sfl/.
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

if [ ${#move_src[@]} -eq 0 ]; then
    echo "no-selection (nothing matched; ~/.claude/sfl/ left untouched)"
    rm -f "$SCPT"
    exit 0
fi

remaining=$(( total - ${#move_src[@]} ))

if [ "$DRY_RUN" -eq 1 ]; then
    echo "--- generated AppleScript ($SCPT) ---"
    cat "$SCPT"
    echo "--- end ($count tab(s); $remaining entr(y/ies) would stay live; dry run, nothing archived) ---"
    rm -f "$SCPT"
    exit 0
fi

# Archive the selected entries BEFORE opening tabs, so the resume prompts (which
# point at the archived paths) are valid the moment each tab's claude starts.
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
if [ "$remaining" -gt 0 ]; then
    echo "opened $count tab(s); archived ${#move_src[@]} selected entr(y/ies); $remaining left live in ~/.claude/sfl/"
else
    echo "opened $count tab(s); archived ${#move_src[@]} entr(y/ies) — ~/.claude/sfl/ is now empty"
fi
exit 0
