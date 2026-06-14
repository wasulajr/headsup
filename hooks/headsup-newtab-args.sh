#!/bin/bash
# headsup-newtab-args.sh: get/set the extra args the "New Claude Tab" Quick
# Action (Cmd-Opt-C) passes to `claude` when it launches a new tab.
#
# The value is stored as NEWTAB_CLAUDE_ARGS in the global headsup config
# (~/.claude/hooks/headsup-status.conf), which the workflow sources at launch.
# Empty = normal interactive mode (the default). Set it to start every
# shortcut-launched session in a different permission mode.
#
# Usage:
#   headsup-newtab-args.sh                 show the current value
#   headsup-newtab-args.sh --show          show the current value
#   headsup-newtab-args.sh off             interactive mode (clears the value)
#   headsup-newtab-args.sh acceptEdits     "--permission-mode acceptEdits"
#   headsup-newtab-args.sh plan            "--permission-mode plan"
#   headsup-newtab-args.sh full            "--dangerously-skip-permissions"
#   headsup-newtab-args.sh -- <raw args>   set the value verbatim
#   headsup-newtab-args.sh "--foo bar"     a value starting with - is taken raw
#
# Friendly aliases: on/auto/autorun = acceptEdits; none/interactive = off;
# skip/yolo/danger = full.
#
# Prints the resulting value. The change takes effect on the NEXT new tab
# (it does not affect already-running sessions).

set -euo pipefail

CONF="$HOME/.claude/hooks/headsup-status.conf"
KEY="NEWTAB_CLAUDE_ARGS"

# Resolve through a symlink so we edit the real file in place and never replace
# the symlink with a regular file (setup.sh symlinks the conf into the repo).
realpath_of() {
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null \
        || readlink -f "$1" 2>/dev/null \
        || printf '%s' "$1"
}

current_value() {
    [ -f "$CONF" ] || { printf ''; return; }
    # Last assignment wins; strip the KEY=, then surrounding quotes.
    awk -v k="$KEY" '
        $0 ~ "^"k"=" { v=$0; sub("^"k"=","",v); val=v }
        END { print val }
    ' "$CONF" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

show() {
    local v; v="$(current_value)"
    if [ -z "$v" ]; then
        echo "$KEY is unset (new tabs launch claude in normal interactive mode)"
    else
        echo "$KEY=\"$v\"  (new tabs launch: claude $v)"
    fi
}

# ── parse the request ───────────────────────────────────────────────────────
mode="${1:-}"
case "$mode" in
    ""|--show|show|status|get)
        show; exit 0 ;;
    off|none|interactive|"")
        val="" ;;
    on|auto|autorun|accept|acceptedits|acceptEdits)
        val="--permission-mode acceptEdits" ;;
    plan)
        val="--permission-mode plan" ;;
    full|skip|yolo|danger|dangerous)
        val="--dangerously-skip-permissions" ;;
    --)
        shift; val="$*" ;;
    -*)
        val="$*" ;;                       # starts with a dash: treat all args as raw
    *)
        echo "headsup-newtab-args: unknown mode '$mode'." >&2
        echo "Use: off | acceptEdits | plan | full | -- <raw args>  (or --show)" >&2
        exit 2 ;;
esac

# ── write the value into the conf, preserving the symlink + everything else ──
REAL="$(realpath_of "$CONF")"
mkdir -p "$(dirname "$REAL")"
[ -f "$REAL" ] || { printf '# headsup status hook configuration (global).\n' > "$REAL"; }

tmp="$(mktemp "${TMPDIR:-/tmp}/headsup-newtab-args.XXXXXX")"
VAL="$val" awk -v k="$KEY" '
    BEGIN { v=ENVIRON["VAL"]; done=0 }
    $0 ~ "^"k"=" { if (!done) { print k"=\"" v "\""; done=1 } ; next }   # replace (drop dupes)
    { print }
    END { if (!done) {
            print ""
            print "# New Claude Tab shortcut (Cmd-Opt-C): extra args passed to `claude` on"
            print "# launch. Empty = normal interactive mode. Managed by /headsup-config newtabs."
            print k"=\"" v "\""
          } }
' "$REAL" > "$tmp"

# Overwrite the target file CONTENTS (not via mv) so the $CONF symlink survives.
cat "$tmp" > "$REAL"
rm -f "$tmp"

show
echo "(takes effect on your next New Claude Tab / Cmd-Opt-C; running sessions are unaffected)"
