#!/bin/bash
# headsup-newtab-args.sh: get/set the extra args the "New Claude Tab" (or, with
# --codex, the "New Codex Tab") Quick Action passes to the agent when it launches
# a new tab.
#
# The value is stored as NEWTAB_CLAUDE_ARGS (claude) or NEWTAB_CODEX_ARGS (codex)
# in the corresponding headsup config, which the workflow sources at launch.
# Empty = normal interactive mode (the default). Set it to start every
# shortcut-launched session in a different mode.
#
# Usage:
#   headsup-newtab-args.sh [--codex] [MODE]
#
#   --codex                 target the New Codex Tab (~/.codex conf) instead of
#                           claude (~/.claude conf). Must be the FIRST argument.
#
# claude MODEs:
#   off | none              interactive mode (clears the value)
#   acceptEdits | on | auto "--permission-mode acceptEdits"
#   plan                    "--permission-mode plan"
#   full | skip | yolo      "--dangerously-skip-permissions"
#
# codex MODEs (--codex):
#   off | none              interactive mode (clears the value)
#   full-auto | full | auto "--full-auto"
#   yolo | bypass           "--dangerously-bypass-approvals-and-sandbox"
#   never|on-request|on-failure|untrusted   "--ask-for-approval <policy>"
#   approval <policy>       "--ask-for-approval <policy>"
#
# either:
#   (no MODE) | --show      show the current value
#   -- <raw args>           set the value verbatim
#   "--foo bar"             a value starting with - is taken raw
#
# Prints the resulting value. The change takes effect on the NEXT new tab
# (it does not affect already-running sessions).

set -euo pipefail

# ── target selection (claude default; --codex switches everything) ──────────
TARGET="claude"
if [ "${1:-}" = "--codex" ]; then TARGET="codex"; shift; fi

if [ "$TARGET" = "codex" ]; then
    CONF="$HOME/.codex/hooks/headsup-status.conf"
    KEY="NEWTAB_CODEX_ARGS"
    BIN="codex"
    TABNAME="Codex"
    SKILLREF="/headsup-config codextabs"
else
    CONF="$HOME/.claude/hooks/headsup-status.conf"
    KEY="NEWTAB_CLAUDE_ARGS"
    BIN="claude"
    TABNAME="Claude"
    SKILLREF="/headsup-config newtabs"
fi

# Resolve through a symlink so we edit the real file in place and never replace
# the symlink with a regular file (setup.sh symlinks the claude conf into the repo).
realpath_of() {
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null \
        || readlink -f "$1" 2>/dev/null \
        || printf '%s' "$1"
}

current_value() {
    [ -f "$CONF" ] || { printf ''; return; }
    awk -v k="$KEY" '
        $0 ~ "^"k"=" { v=$0; sub("^"k"=","",v); val=v }
        END { print val }
    ' "$CONF" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

show() {
    local v; v="$(current_value)"
    if [ -z "$v" ]; then
        echo "$KEY is unset (new tabs launch $BIN in normal interactive mode)"
    else
        echo "$KEY=\"$v\"  (new tabs launch: $BIN $v)"
    fi
}

# ── parse the requested mode ─────────────────────────────────────────────────
mode="${1:-}"
case "$mode" in
    ""|--show|show|status|get)
        show; exit 0 ;;
    off|none|interactive)
        val="" ;;
    --)
        shift; val="$*" ;;
    -*)
        val="$*" ;;                       # starts with a dash: treat all args as raw
    *)
        if [ "$TARGET" = "codex" ]; then
            case "$mode" in
                full-auto|fullauto|full|auto)        val="--full-auto" ;;
                yolo|bypass|danger|dangerous)        val="--dangerously-bypass-approvals-and-sandbox" ;;
                never|on-request|on-failure|untrusted) val="--ask-for-approval $mode" ;;
                approval)                            shift; val="--ask-for-approval ${1:-on-request}" ;;
                *)
                    echo "headsup-newtab-args: unknown codex mode '$mode'." >&2
                    echo "Use: off | full-auto | yolo | never|on-request|on-failure|untrusted | approval <policy> | -- <raw>  (or --show)" >&2
                    exit 2 ;;
            esac
        else
            case "$mode" in
                on|auto|autorun|accept|acceptedits|acceptEdits) val="--permission-mode acceptEdits" ;;
                plan)                                           val="--permission-mode plan" ;;
                full|skip|yolo|danger|dangerous)                val="--dangerously-skip-permissions" ;;
                *)
                    echo "headsup-newtab-args: unknown mode '$mode'." >&2
                    echo "Use: off | acceptEdits | plan | full | -- <raw args>  (or --show)" >&2
                    exit 2 ;;
            esac
        fi ;;
esac

# ── write the value into the conf, preserving the symlink + everything else ──
REAL="$(realpath_of "$CONF")"
mkdir -p "$(dirname "$REAL")"
[ -f "$REAL" ] || { printf '# headsup status hook configuration (global).\n' > "$REAL"; }

tmp="$(mktemp "${TMPDIR:-/tmp}/headsup-newtab-args.XXXXXX")"
VAL="$val" SKILLREF="$SKILLREF" BIN="$BIN" awk -v k="$KEY" '
    BEGIN { v=ENVIRON["VAL"]; ref=ENVIRON["SKILLREF"]; bin=ENVIRON["BIN"]; done=0 }
    $0 ~ "^"k"=" { if (!done) { print k"=\"" v "\""; done=1 } ; next }   # replace (drop dupes)
    { print }
    END { if (!done) {
            print ""
            print "# New " (bin=="codex"?"Codex":"Claude") " Tab shortcut (Cmd-Opt-C): extra args passed to `" bin "` on"
            print "# launch. Empty = normal interactive mode. Managed by " ref "."
            print k"=\"" v "\""
          } }
' "$REAL" > "$tmp"

# Overwrite the target file CONTENTS (not via mv) so a $CONF symlink survives.
cat "$tmp" > "$REAL"
rm -f "$tmp"

show
echo "(takes effect on your next New $TABNAME Tab / Cmd-Opt-C; running sessions are unaffected)"
