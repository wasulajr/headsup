#!/bin/bash
# test_set_label.sh - contract tests for hooks/headsup-set-label.sh.
#
# Why this is CORE-critical: this script WRITES the conf that window-id.sh
# READS. Together they are the two halves of the window slug, and that slug is
# what Cliff addresses mail to, what /sfl keys its checkpoint by, what /nil
# reopens from, and what the coordination board joins on. Testing the reader
# without the writer covers half a contract.
#
# The stated contract, from the script's own header:
#   - usage: headsup-set-label.sh <label...>  |  --clear
#   - writes ~/.claude/hooks/headsup-status.d/<session-key>.conf
#   - writes ~/.claude/hooks/.state/<terminal-id>.badge
#   - ALWAYS exits 0, so callers can chain `... && claude`
#   - terminal detection order: AI Power Term, then iTerm2, then WezTerm
#
# Every case runs against a temporary HOME and never touches Steve's real
# configuration.
#
# Owned by apt-qa. Observes only; never edits product code.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/harness.sh
. "$HERE/lib/harness.sh"

# Suite-scoped by deliberate convention: run-tests.sh sources every suite into
# one shell, and a shared name lets the last file sourced silently redirect an
# earlier suite at the wrong script.
LABEL_SUT="$ROOT/hooks/headsup-set-label.sh"
WID_SUT_FOR_LABEL="$ROOT/sfl/lib/window-id.sh"

# label_run <home> <env-assignments...> -- <args...>
# Runs the label writer with a sandboxed HOME and no tty.
#
# NOTE: `env VAR=x -- args` does NOT work; env treats `--` as a program name
# and exits 127, which reads as a product failure when it is a harness bug.
# So the separator is parsed here and the assignments are exported in a
# subshell instead.
label_run() {
  local home="$1"; shift
  local -a assigns=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    assigns+=("$1"); shift
  done
  [ "${1:-}" = "--" ] && shift
  (
    export HOME="$home"
    local a
    for a in "${assigns[@]}"; do export "${a?}"; done
    bash "$LABEL_SUT" "$@" >/dev/null 2>&1
  )
}

run_set_label_suite() {
  local home rc conf badge out

  if [ ! -f "$LABEL_SUT" ]; then
    hs_record CORE "headsup-set-label.sh exists" FAIL "not found at $LABEL_SUT"
    return
  fi
  hs_record CORE "headsup-set-label.sh exists" PASS ""

  # --- CORE: always exits 0, even with no terminal at all -------------------
  # The header promises this so `set-label && claude` never loses the shell.
  home="$(mktemp -d)"
  ( cd "$home" && env -u AI_POWER_TERM_SESSION_ID -u STEVE_TABS_SESSION_ID \
      -u ITERM_SESSION_ID -u WEZTERM_PANE HOME="$home" bash "$LABEL_SUT" hello >/dev/null 2>&1 )
  rc=$?
  hs_assert_eq CORE "exits 0 with no terminal session" "0" "$rc"

  # --- CORE: iTerm2 writes a conf that window-id.sh can read ----------------
  # This is the round trip that matters: writer and reader must agree on the
  # session-key derivation, or a labelled window resolves to its cwd instead.
  home="$(mktemp -d)"
  label_run "$home" ITERM_SESSION_ID="w1:2:3" -- warren
  rc=$?
  hs_assert_eq CORE "iterm: exits 0" "0" "$rc"
  conf="$home/.claude/hooks/headsup-status.d/w1_2_3.conf"
  if [ -f "$conf" ]; then
    hs_record CORE "iterm: writes the session conf" PASS ""
  else
    hs_record CORE "iterm: writes the session conf" FAIL "no conf at $conf"
  fi

  # The actual round trip, through the real reader.
  local named="$home/proj"
  mkdir -p "$named"
  out=$( cd "$named" && HOME="$home" ITERM_SESSION_ID="w1:2:3" bash "$WID_SUT_FOR_LABEL" 2>/dev/null )
  local slug
  slug=$(printf '%s\n' "$out" | grep '^SLUG=' | head -1 | cut -d= -f2-)
  hs_assert_eq CORE "ROUND TRIP: set-label then window-id yields the label" "warren" "$slug"

  # --- CORE: a multi-word label survives the round trip ---------------------
  home="$(mktemp -d)"; named="$home/proj"; mkdir -p "$named"
  label_run "$home" ITERM_SESSION_ID="w1:2:3" -- deploy debugging
  out=$( cd "$named" && HOME="$home" ITERM_SESSION_ID="w1:2:3" bash "$WID_SUT_FOR_LABEL" 2>/dev/null )
  local lbl
  lbl=$(printf '%s\n' "$out" | grep '^LABEL=' | head -1 | cut -d= -f2-)
  hs_assert_eq CORE "ROUND TRIP: multi-word label preserved" "deploy debugging" "$lbl"
  slug=$(printf '%s\n' "$out" | grep '^SLUG=' | head -1 | cut -d= -f2-)
  hs_assert_eq CORE "ROUND TRIP: multi-word label slugged" "deploy-debugging" "$slug"

  # --- CORE: --clear removes the override -----------------------------------
  home="$(mktemp -d)"; named="$home/proj"; mkdir -p "$named"
  label_run "$home" ITERM_SESSION_ID="w1:2:3" -- warren
  label_run "$home" ITERM_SESSION_ID="w1:2:3" -- --clear
  rc=$?
  hs_assert_eq CORE "--clear exits 0" "0" "$rc"
  out=$( cd "$named" && HOME="$home" ITERM_SESSION_ID="w1:2:3" bash "$WID_SUT_FOR_LABEL" 2>/dev/null )
  slug=$(printf '%s\n' "$out" | grep '^SLUG=' | head -1 | cut -d= -f2-)
  # After a clear the window must fall back to its cwd basename, not keep the
  # stale label: a cleared window that still answers to its old slug would keep
  # receiving another window's Cliff mail.
  hs_assert_eq CORE "--clear falls back to cwd basename" "proj" "$slug"

  # --- CORE: AI Power Term is detected FIRST --------------------------------
  # The header is explicit: an APT session can inherit a stale ITERM_SESSION_ID
  # from the shell that launched the app server, so APT must win. If iTerm won,
  # two APT windows sharing one inherited iTerm id would collide on one conf.
  home="$(mktemp -d)"
  label_run "$home" AI_POWER_TERM_SESSION_ID="apt-sess" ITERM_SESSION_ID="stale:9:9" -- mywindow
  if [ -f "$home/.claude/hooks/headsup-status.d/apt-apt-sess.conf" ]; then
    hs_record CORE "APT wins over an inherited stale ITERM_SESSION_ID" PASS ""
  elif [ -f "$home/.claude/hooks/headsup-status.d/stale_9_9.conf" ]; then
    hs_record CORE "APT wins over an inherited stale ITERM_SESSION_ID" FAIL \
      "iTerm key won; two APT windows sharing an inherited id would collide"
  else
    hs_record CORE "APT wins over an inherited stale ITERM_SESSION_ID" FAIL "no conf written at either key"
  fi

  # --- CORE: the legacy STEVE_TABS_SESSION_ID fallback still works ----------
  home="$(mktemp -d)"
  label_run "$home" STEVE_TABS_SESSION_ID="legacy-sess" -- legacywin
  if ls "$home/.claude/hooks/headsup-status.d/"*.conf >/dev/null 2>&1; then
    hs_record CORE "legacy STEVE_TABS_SESSION_ID honored" PASS ""
  else
    hs_record CORE "legacy STEVE_TABS_SESSION_ID honored" FAIL "no conf written"
  fi

  # --- EDGE: WezTerm is detected when neither APT nor iTerm is present ------
  home="$(mktemp -d)"
  label_run "$home" WEZTERM_PANE="7" -- wezwin
  if ls "$home/.claude/hooks/headsup-status.d/"*.conf >/dev/null 2>&1; then
    hs_record EDGE "wezterm detected" PASS ""
  else
    hs_record EDGE "wezterm detected" FAIL "no conf written for WEZTERM_PANE"
  fi

  # --- EDGE: a badge file is written for the waiting notifier ---------------
  home="$(mktemp -d)"
  label_run "$home" ITERM_SESSION_ID="w1:2:3" -- warren
  if ls "$home/.claude/hooks/.state/"*.badge >/dev/null 2>&1; then
    hs_record EDGE "badge file written for the notifier" PASS ""
  else
    hs_record EDGE "badge file written for the notifier" FAIL "no .badge file"
  fi

  # --- EDGE: re-labelling replaces rather than appends ----------------------
  # Two definitions in one sourced conf means the LAST wins silently, so a
  # window could answer to a name nobody set.
  home="$(mktemp -d)"; named="$home/proj"; mkdir -p "$named"
  label_run "$home" ITERM_SESSION_ID="w1:2:3" -- first
  label_run "$home" ITERM_SESSION_ID="w1:2:3" -- second
  out=$( cd "$named" && HOME="$home" ITERM_SESSION_ID="w1:2:3" bash "$WID_SUT_FOR_LABEL" 2>/dev/null )
  slug=$(printf '%s\n' "$out" | grep '^SLUG=' | head -1 | cut -d= -f2-)
  hs_assert_eq EDGE "re-label replaces the previous label" "second" "$slug"

  # --- EDGE: a label containing shell metacharacters must not execute -------
  # The conf is SOURCED by window-id.sh and headsup-status.sh, so an unquoted
  # label is arbitrary code execution in every window that reads it.
  home="$(mktemp -d)"; named="$home/proj"; mkdir -p "$named"
  label_run "$home" ITERM_SESSION_ID="w1:2:3" -- 'x$(touch /tmp/apt-qa-pwned-'"$$"')'
  ( cd "$named" && HOME="$home" ITERM_SESSION_ID="w1:2:3" bash "$WID_SUT_FOR_LABEL" >/dev/null 2>&1 )
  if [ -f "/tmp/apt-qa-pwned-$$" ]; then
    rm -f "/tmp/apt-qa-pwned-$$"
    hs_record EDGE "label with \$() does not execute when the conf is sourced" FAIL \
      "command substitution in a label EXECUTED on read"
  else
    hs_record EDGE "label with \$() does not execute when the conf is sourced" PASS ""
  fi

  # --- EDGE: an empty label is not written as a blank override -------------
  home="$(mktemp -d)"; named="$home/proj"; mkdir -p "$named"
  label_run "$home" ITERM_SESSION_ID="w1:2:3" -- ""
  out=$( cd "$named" && HOME="$home" ITERM_SESSION_ID="w1:2:3" bash "$WID_SUT_FOR_LABEL" 2>/dev/null )
  slug=$(printf '%s\n' "$out" | grep '^SLUG=' | head -1 | cut -d= -f2-)
  if [ -n "$slug" ]; then
    hs_record EDGE "empty label does not yield an empty slug" PASS "slug=$slug"
  else
    hs_record EDGE "empty label does not yield an empty slug" FAIL "slug resolved empty"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  hs_init "${1:-/tmp/headsup-set-label-results.tsv}"
  run_set_label_suite
  hs_summary
fi
