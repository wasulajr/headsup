#!/bin/bash
# nil-open.sh — "now is later". Open one terminal tab per selected /sfl
# checkpoint in ~/.claude/sfl/*.md. Each tab cds to the window's dir, restores
# its headsup label, and launches the selected agent with a resume prompt that
# points at that window's (already archived) entry file.
#
# Terminal provider:
#   - HEADSUP_NIL_PROVIDER=ai-power-term: open AI Power Term tabs
#   - run from WezTerm (WEZTERM_PANE set): open WezTerm tabs
#   - run from iTerm2 (ITERM_SESSION_ID set): open iTerm2 tabs
#   - otherwise: keep the legacy iTerm2 default
# Agent target:
#   - HEADSUP_NIL_AGENT=auto: use Codex when run from Codex, else Claude
#   - HEADSUP_NIL_AGENT=claude|codex: force the LLM CLI used for each resume
# Override for tests/one-offs:
#   HEADSUP_NIL_PROVIDER=ai-power-term|wezterm|iterm nil-open.sh ...
#   HEADSUP_NIL_AGENT=codex nil-open.sh ...
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
# before resuming.) If launch fails, the script rolls back entries that were not
# successfully launched so nothing selected is silently lost.
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
#   nil-open.sh --chat-list    print a compact, assistant-message-friendly list
#                              using the same selection numbers as --list
#   nil-open.sh --dry-run [SEL] print the generated terminal launch plan, open
#                              nothing, archive nothing (for testing)
#
# Prints one "opening: <window>  (<cwd>)" line per launched entry. Prints
# "no-entries" and exits 0 if there are no live checkpoints.

set -euo pipefail

SFL_DIR="$HOME/.claude/sfl"
SET_LABEL="$HOME/.claude/hooks/headsup-set-label.sh"
CODEX_SET_LABEL="$HOME/.codex/hooks/headsup-codex-set-label.sh"
AI_POWER_TERM_BIN="${AI_POWER_TERM_BIN:-$HOME/code/ai-power-term/bin/ai-power-term}"
DRY_RUN=0
LIST=0
CHAT_LIST=0
case "${1:-}" in
    --dry-run) DRY_RUN=1; shift ;;
    --list)    LIST=1; shift ;;
    --chat-list|--list-chat|--list-compact) LIST=1; CHAT_LIST=1; shift ;;
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

shorten() {  # $1=text  $2=max chars
    /usr/bin/python3 - "$1" "$2" <<'PY'
import sys
text = sys.argv[1]
limit = int(sys.argv[2])
if len(text) <= limit:
    print(text)
elif limit <= 1:
    print(text[:limit])
else:
    print(text[: limit - 1] + "...")
PY
}

homepath() {
    case "$1" in
        "$HOME") printf '~\n' ;;
        "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# --list: show what would be reopened, NUMBERED, open nothing.
# This is the allowlisted replacement for the ad-hoc for/awk loop that used to
# live in the /nil skill doc (which prompted because it had no allowlist rule).
# The numbers printed here are the selection numbers accepted by this script.
if [ "$LIST" -eq 1 ]; then
    out="$(mktemp "${TMPDIR:-/tmp}/nil-list.XXXXXX")"
    if [ "$CHAT_LIST" -eq 1 ]; then
        {
            echo "Saved /sfl windows (choose numbers):"
            n=0
            for f in "${entries[@]}"; do
                n=$((n + 1))
                base=$(basename "$f")
                win=$(frontval "$f" window)
                project=$(frontval "$f" project)
                cwd=$(frontval "$f" cwd)
                saved_at=$(frontval "$f" saved_at)
                [ -n "$win" ] || win="${base%.md}"
                [ -n "$project" ] || project="(no project)"
                [ -n "$saved_at" ] || saved_at="unknown saved_at"
                project_short=$(shorten "$project" 64)
                printf '%2d. %-14s %s\n' "$n" "$win" "$project_short"
                printf '    saved: %s\n' "$saved_at"
                [ -n "$cwd" ] && printf '    cwd:   %s\n' "$(homepath "$cwd")"
            done
        } > "$out"
    else
        {
            n=0
            for f in "${entries[@]}"; do
                n=$((n + 1))
                printf '%d. %s\n' "$n" "$(basename "$f")"
                for k in window project cwd saved_at; do
                    v=$(frontval "$f" "$k")
                    [ -n "$v" ] && printf '   %s: %s\n' "$k" "$v"
                done
            done
        } > "$out"
    fi
    cat "$out"
    # Claude/Codex tool output can be collapsed in terminal UIs. When there is
    # a controlling terminal and stdout is captured, mirror the list directly
    # to the terminal so the chooser is still visible to Steve.
    if [ "${NIL_LIST_TTY:-1}" != "0" ] && ! [ -t 1 ] && [ -e /dev/tty ]; then
        { printf '\n'; cat "$out"; printf '\n'; } > /dev/tty 2>/dev/null || true
    fi
    rm -f "$out"
    exit 0
fi

detect_provider() {
    case "${HEADSUP_NIL_PROVIDER:-auto}" in
        auto|"")
            if [ -n "${AI_POWER_TERM_SESSION_ID:-}" ]; then
                echo "ai-power-term"
            elif [ -n "${WEZTERM_PANE:-}" ]; then
                echo "wezterm"
            elif [ -n "${ITERM_SESSION_ID:-}" ]; then
                echo "iterm"
            else
                echo "iterm"
            fi
            ;;
        wezterm|WezTerm|wez) echo "wezterm" ;;
        iterm|iTerm|iterm2|iTerm2) echo "iterm" ;;
        ai-power-term|aipt|powerterm) echo "ai-power-term" ;;
        *)
            echo "nil-open: HEADSUP_NIL_PROVIDER must be 'auto', 'ai-power-term', 'wezterm', or 'iterm'" >&2
            exit 2
            ;;
    esac
}

detect_agent() {
    case "${HEADSUP_NIL_AGENT:-auto}" in
        auto|"")
            case "${AI_POWER_TERM_KIND:-}" in
                claude|codex) echo "$AI_POWER_TERM_KIND"; return ;;
            esac
            if [ -n "${CODEX_SHELL:-}" ] || [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_HOME:-}" ]; then
                echo "codex"
            else
                echo "claude"
            fi
            ;;
        claude|Claude|anthropic) echo "claude" ;;
        codex|Codex|openai) echo "codex" ;;
        *)
            echo "nil-open: HEADSUP_NIL_AGENT must be 'auto', 'claude', or 'codex'" >&2
            exit 2
            ;;
    esac
}

find_wezterm() {
    if command -v wezterm >/dev/null 2>&1; then
        command -v wezterm
    elif [ -x "$HOME/.local/bin/wezterm" ]; then
        printf '%s\n' "$HOME/.local/bin/wezterm"
    elif [ -x "/Applications/WezTerm.app/Contents/MacOS/wezterm" ]; then
        printf '%s\n' "/Applications/WezTerm.app/Contents/MacOS/wezterm"
    else
        return 1
    fi
}

label_helper_for_agent() {
    if [ "$AGENT" = "codex" ] && [ -x "$CODEX_SET_LABEL" ] && [ -n "${ITERM_SESSION_ID:-}" ]; then
        printf '%s\n' "$CODEX_SET_LABEL"
    else
        printf '%s\n' "$SET_LABEL"
    fi
}

agent_launch_command() {
    local mode="$1" prompt="$2" launch
    case "$AGENT" in
        codex)
            printf 'codex %q' "$prompt"
            ;;
        claude)
            launch="claude"
            case "$mode" in
                default|acceptEdits|auto|dontAsk|plan|bypassPermissions) launch="claude --permission-mode $mode" ;;
            esac
            printf '%s %q' "$launch" "$prompt"
            ;;
    esac
}

# Resolve the selection into a per-entry launch mask (want[i], 0-based).
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

PROVIDER="$(detect_provider)"
AGENT="$(detect_agent)"
LABEL_HELPER="$(label_helper_for_agent)"
ARCHIVE_DIR="$SFL_DIR/archive"
mkdir -p "$ARCHIVE_DIR"
STAMP="$(date '+%Y%m%d-%H%M%S')"
move_src=()
move_dst=()
launch_win=()
launch_cwd=()
launch_shellcmd=()
launch_move_idx=()

for i in "${!entries[@]}"; do
    [ "${want[$i]}" = "1" ] || continue   # un-selected entries stay live
    f="${entries[$i]}"
    win=$(frontval "$f" window)
    cwd=$(frontval "$f" cwd)
    mode=$(frontval "$f" mode | tr -d '[:space:]')
    base=$(basename "$f")
    slug="${base%.md}"
    arch_base="${slug}-${STAMP}.md"

    # Only the SELECTED entries get archived this run (launched or skipped for a
    # missing cwd); un-selected entries are left live in ~/.claude/sfl/.
    move_src+=("$f")
    move_dst+=("$ARCHIVE_DIR/$arch_base")
    move_idx=$((${#move_src[@]} - 1))

    [ -n "$win" ] || win="$slug"
    if [ -z "$cwd" ]; then
        echo "skip (no cwd, archiving entry): $base" >&2
        continue
    fi
    # Expand a leading ~ in the recorded cwd.
    case "$cwd" in "~"*) cwd="$HOME${cwd#\~}";; esac

    prompt="Resume my saved-for-later checkpoint for this window. Read and follow ~/.claude/sfl/archive/$arch_base (the Checkpoint section plus the How to restart steps), then read its gov_memory file for fuller context. The entry was already archived by /nil at launch, so do not archive anything. Give me a 3 to 5 line catch-up of where we left off and the single recommended next step. Do not start the work until I confirm."

    # Relaunch in the current/forced agent CLI. Claude can restore its saved
    # permission mode. Codex uses its normal local config and approval policy.
    launch=$(agent_launch_command "$mode" "$prompt")

    # Shell line typed/spawned into the fresh tab: cd, restore label, launch
    # the selected agent. set-label always exits 0, so && chaining is safe.
    shellcmd="cd $(printf '%q' "$cwd") && $(printf '%q' "$LABEL_HELPER") $(printf '%q' "$win") && $launch"

    launch_win+=("$win")
    launch_cwd+=("$cwd")
    launch_shellcmd+=("$shellcmd")
    launch_move_idx+=("$move_idx")
    echo "opening: $win  ($cwd)"
done

if [ ${#move_src[@]} -eq 0 ]; then
    echo "no-selection (nothing matched; ~/.claude/sfl/ left untouched)"
    exit 0
fi

remaining=$(( total - ${#move_src[@]} ))
count=${#launch_win[@]}

# Escape a string for embedding inside an AppleScript double-quoted literal.
asesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

SCPT=""
build_iterm_script() {
    SCPT="$(mktemp "${TMPDIR:-/tmp}/nil-open.XXXXXX")"
    mv "$SCPT" "$SCPT.scpt"; SCPT="$SCPT.scpt"

    # Cold-start fix: if iTerm2 is NOT already running, `activate` launches it
    # and auto-creates one empty default tab. Reuse that first tab for entry #1.
    iterm_running="$(osascript -e 'tell application "System Events" to return (count of (processes whose name contains "iTerm"))' 2>/dev/null || echo 0)"
    [ -n "$iterm_running" ] || iterm_running=0
    if [ "$iterm_running" -gt 0 ] 2>/dev/null; then
        REUSE_FIRST="false"   # already running: every entry gets a new tab
    else
        REUSE_FIRST="true"    # cold start: reuse the auto-created tab
    fi

    printf 'property reuseFirst : %s\n\n' "$REUSE_FIRST" > "$SCPT"
    cat >> "$SCPT" <<'AS'
on openTab(dirPath, tabName, shellCmd)
	tell application "iTerm2"
		activate
		if (count of windows) = 0 then
			create window with default profile
			set reuseFirst to false
		else if reuseFirst then
			-- iTerm cold-started and auto-made an empty default tab; reuse it
			-- for this first entry instead of leaving it as a stray extra tab.
			set reuseFirst to false
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

    for j in "${!launch_win[@]}"; do
        printf 'my openTab("%s", "%s", "%s")\n' \
            "$(asesc "${launch_cwd[$j]}")" \
            "$(asesc "${launch_win[$j]}")" \
            "$(asesc "${launch_shellcmd[$j]}")" >> "$SCPT"
    done
}

print_wezterm_dry_run() {
    echo "--- generated WezTerm launch plan (provider: wezterm) ---"
    echo "agent: $AGENT"
    echo "target: current WezTerm window when WEZTERM_PANE is set; otherwise first WezTerm window"
    for j in "${!launch_win[@]}"; do
        printf 'wezterm tab: %s\n' "${launch_win[$j]}"
        printf '  cwd: %s\n' "${launch_cwd[$j]}"
        printf '  cmd: %s\n' "${launch_shellcmd[$j]}"
    done
    echo "--- end ($count tab(s); $remaining entr(y/ies) would stay live; dry run, nothing archived) ---"
}

print_ai_power_term_dry_run() {
    echo "--- generated AI Power Term launch plan (provider: ai-power-term) ---"
    echo "agent: $AGENT"
    echo "target: $AI_POWER_TERM_BIN"
    for j in "${!launch_win[@]}"; do
        printf 'ai-power-term tab: %s\n' "${launch_win[$j]}"
        printf '  cwd: %s\n' "${launch_cwd[$j]}"
        printf '  cmd: %s\n' "${launch_shellcmd[$j]}"
    done
    echo "--- end ($count tab(s); $remaining entr(y/ies) would stay live; dry run, nothing archived) ---"
}

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$PROVIDER" = "wezterm" ]; then
        print_wezterm_dry_run
    elif [ "$PROVIDER" = "ai-power-term" ]; then
        print_ai_power_term_dry_run
    else
        build_iterm_script
        echo "--- generated AppleScript ($SCPT; provider: iterm) ---"
        echo "agent: $AGENT"
        cat "$SCPT"
        echo "--- end ($count tab(s); $remaining entr(y/ies) would stay live; dry run, nothing archived) ---"
        rm -f "$SCPT"
    fi
    exit 0
fi

# Archive the selected entries BEFORE opening tabs, so the resume prompts (which
# point at the archived paths) are valid the moment each tab's claude starts.
for i in "${!move_src[@]}"; do
    mv -f "${move_src[$i]}" "${move_dst[$i]}"
done

if [ "$PROVIDER" = "iterm" ]; then
    build_iterm_script
    if ! osascript "$SCPT"; then
        echo "osascript failed — restoring live entries so nothing is lost" >&2
        for i in "${!move_src[@]}"; do
            mv -f "${move_dst[$i]}" "${move_src[$i]}"
        done
        rm -f "$SCPT"
        exit 1
    fi
    rm -f "$SCPT"
elif [ "$PROVIDER" = "ai-power-term" ]; then
    if [ ! -x "$AI_POWER_TERM_BIN" ]; then
        echo "nil-open: AI Power Term CLI not found at $AI_POWER_TERM_BIN; restoring live entries" >&2
        for i in "${!move_src[@]}"; do
            mv -f "${move_dst[$i]}" "${move_src[$i]}"
        done
        exit 1
    fi

    if ! "$AI_POWER_TERM_BIN" open >/dev/null; then
        echo "nil-open: AI Power Term did not start; restoring live entries" >&2
        for i in "${!move_src[@]}"; do
            mv -f "${move_dst[$i]}" "${move_src[$i]}"
        done
        exit 1
    fi

    declare -a launched
    for ((i = 0; i < ${#move_src[@]}; i++)); do launched[$i]=0; done

    for j in "${!launch_win[@]}"; do
        if "$AI_POWER_TERM_BIN" new-tab \
            --kind "$AGENT" \
            --cwd "${launch_cwd[$j]}" \
            --title "${launch_win[$j]}" \
            --shell-command "${launch_shellcmd[$j]}" >/dev/null; then
            move_idx="${launch_move_idx[$j]}"
            launched[$move_idx]=1
        else
            echo "ai-power-term spawn failed for ${launch_win[$j]} — restoring unlaunched live entries" >&2
            for i in "${!move_src[@]}"; do
                if [ "${launched[$i]:-0}" != "1" ] && [ -e "${move_dst[$i]}" ]; then
                    mv -f "${move_dst[$i]}" "${move_src[$i]}"
                fi
            done
            exit 1
        fi
    done
else
    WEZTERM_BIN="$(find_wezterm || true)"
    if [ -z "$WEZTERM_BIN" ]; then
        echo "nil-open: WezTerm CLI not found; restoring live entries" >&2
        for i in "${!move_src[@]}"; do
            mv -f "${move_dst[$i]}" "${move_src[$i]}"
        done
        exit 1
    fi

    launch_shell="${SHELL:-/bin/zsh}"
    [ -x "$launch_shell" ] || launch_shell="/bin/zsh"
    declare -a launched
    for ((i = 0; i < ${#move_src[@]}; i++)); do launched[$i]=0; done

    for j in "${!launch_win[@]}"; do
        spawn_args=()
        if [ -n "${WEZTERM_PANE:-}" ]; then
            spawn_args+=(--pane-id "$WEZTERM_PANE")
        elif [ -n "${HEADSUP_NIL_WEZTERM_WINDOW_ID:-}" ]; then
            spawn_args+=(--window-id "$HEADSUP_NIL_WEZTERM_WINDOW_ID")
        else
            winid=$("$WEZTERM_BIN" cli list 2>/dev/null | awk 'NR > 1 {print $1; exit}' || true)
            if [ -n "$winid" ]; then
                spawn_args+=(--window-id "$winid")
            else
                spawn_args+=(--new-window)
            fi
        fi

        if pane_id=$("$WEZTERM_BIN" cli spawn "${spawn_args[@]}" --cwd "${launch_cwd[$j]}" -- "$launch_shell" -lic "${launch_shellcmd[$j]}"); then
            move_idx="${launch_move_idx[$j]}"
            launched[$move_idx]=1
            [ -n "$pane_id" ] && "$WEZTERM_BIN" cli set-tab-title --pane-id "$pane_id" "${launch_win[$j]}" >/dev/null 2>&1 || true
        else
            echo "wezterm spawn failed for ${launch_win[$j]} — restoring unlaunched live entries" >&2
            for i in "${!move_src[@]}"; do
                if [ "${launched[$i]:-0}" != "1" ] && [ -e "${move_dst[$i]}" ]; then
                    mv -f "${move_dst[$i]}" "${move_src[$i]}"
                fi
            done
            exit 1
        fi
    done
fi

if [ "$remaining" -gt 0 ]; then
    echo "opened $count $PROVIDER tab(s); archived ${#move_src[@]} selected entr(y/ies); $remaining left live in ~/.claude/sfl/"
else
    echo "opened $count $PROVIDER tab(s); archived ${#move_src[@]} entr(y/ies); ~/.claude/sfl/ is now empty"
fi

# Daily maintenance sweep. Steve runs /nil at least once a day, so this is the
# heartbeat that keeps memory indexes, hook logs, and Cliff storage from growing
# unbounded. Fail-open and reversible: archived files are moved, not deleted.
"$HOME/.claude/maintenance/daily-sweep.sh" 2>/dev/null || true

exit 0
