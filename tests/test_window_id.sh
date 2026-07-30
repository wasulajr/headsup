#!/bin/bash
# test_window_id.sh - contract tests for sfl/lib/window-id.sh.
#
# Why this script is CORE-critical: window-id.sh resolves the window SLUG, and
# that slug is the key the whole fleet coordinates on. Cliff addresses mail to
# it, /sfl keys its live checkpoint entry by it, /nil reopens windows from it,
# and the coordination board joins on it. A wrong slug does not throw; it
# silently misroutes a peer's mail or strands a saved window.
#
# The stated contract, taken from the script's own header BEFORE reading its
# implementation:
#   - prints LABEL, SLUG, CWD, STAMP as KEY=value lines
#   - LABEL is the headsup tab label, or the cwd basename when none is set
#   - SLUG is a filename-safe slug of LABEL
#   - always exits 0
#
# Every case runs against a temporary HOME, so the suite never reads or writes
# Steve's real headsup configuration.
#
# Owned by apt-qa. Observes only; never edits product code.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/harness.sh
. "$HERE/lib/harness.sh"

# Suite-scoped, and deliberately not named SUT: run-tests.sh sources every
# suite into one shell, so a shared name would let the last file sourced
# silently redirect an earlier suite at its own script. That exact collision
# produced 34 false failures on the first run of this suite.
WID_SUT="$ROOT/sfl/lib/window-id.sh"

# wid_run <label-or-empty> <cwd> -> stdout of window-id.sh, with HOME sandboxed.
# When a label is given, a conf file is written the way headsup-set-label.sh does.
wid_run() {
  local label="$1" cwd="$2" sid="${3:-w1}"
  local home
  home="$(mktemp -d)"
  if [ -n "$label" ]; then
    local key conf
    key=$(printf '%s' "$sid" | tr -c '[:alnum:]-' '_')
    conf="$home/.claude/hooks/headsup-status.d/$key.conf"
    mkdir -p "$(dirname "$conf")"
    {
      printf 'headsup_title_text() { printf %s "%s"; }\n' "'%s'" "$label"
      printf 'headsup_badge_text() { printf %s "%s"; }\n' "'%s'" "$label"
    } > "$conf"
    ( cd "$cwd" && HOME="$home" ITERM_SESSION_ID="$sid" bash "$WID_SUT" )
  else
    ( cd "$cwd" && HOME="$home" ITERM_SESSION_ID="" bash "$WID_SUT" )
  fi
  rm -rf "$home"
}

wid_field() { printf '%s\n' "$1" | grep "^$2=" | head -1 | cut -d= -f2-; }

run_window_id_suite() {
  local out tmpcwd rc

  if [ ! -f "$WID_SUT" ]; then
    hs_record CORE "window-id.sh exists" FAIL "not found at $WID_SUT"
    return
  fi
  hs_record CORE "window-id.sh exists" PASS ""

  tmpcwd="$(mktemp -d)"

  # --- CORE: the four-field KEY=value contract ---
  out=$(wid_run "" "$tmpcwd")
  for k in LABEL SLUG CWD STAMP; do
    if printf '%s\n' "$out" | grep -q "^$k="; then
      hs_record CORE "emits $k= line" PASS ""
    else
      hs_record CORE "emits $k= line" FAIL "absent from output"
    fi
  done

  # --- CORE: always exits 0 ---
  ( cd "$tmpcwd" && HOME="$(mktemp -d)" ITERM_SESSION_ID="" bash "$WID_SUT" >/dev/null 2>&1 )
  rc=$?
  hs_assert_eq CORE "exits 0 with no label" "0" "$rc"

  # --- CORE: no label falls back to cwd basename ---
  local named="$tmpcwd/my-project"
  mkdir -p "$named"
  out=$(wid_run "" "$named")
  hs_assert_eq CORE "no label: LABEL is cwd basename" "my-project" "$(wid_field "$out" LABEL)"
  hs_assert_eq CORE "no label: SLUG is cwd basename" "my-project" "$(wid_field "$out" SLUG)"

  # --- CORE: label from conf wins over cwd ---
  out=$(wid_run "warren" "$named")
  hs_assert_eq CORE "conf label wins over cwd" "warren" "$(wid_field "$out" LABEL)"
  hs_assert_eq CORE "conf label slugged" "warren" "$(wid_field "$out" SLUG)"

  # --- CORE: CWD field reports the real cwd ---
  out=$(wid_run "" "$named")
  hs_assert_eq CORE "CWD field matches cwd" "$named" "$(wid_field "$out" CWD)"

  # --- CORE: a real fleet slug survives round-trip unchanged ---
  # These are live roster slugs; if any mutates, Cliff delivery breaks.
  for slug in apt-qa wsw-qa chronovix-qa hub-qa help-qa jupiter-qa nabu apollo karen; do
    out=$(wid_run "$slug" "$named")
    hs_assert_eq CORE "roster slug preserved: $slug" "$slug" "$(wid_field "$out" SLUG)"
  done

  # --- CORE: lowercasing ---
  out=$(wid_run "Warren" "$named")
  hs_assert_eq CORE "uppercase label lowercased in slug" "warren" "$(wid_field "$out" SLUG)"

  # --- EDGE: spaces become dashes ---
  out=$(wid_run "deploy debugging" "$named")
  hs_assert_eq EDGE "spaces become dashes" "deploy-debugging" "$(wid_field "$out" SLUG)"

  # --- EDGE: consecutive specials collapse to one dash ---
  out=$(wid_run "a   b" "$named")
  hs_assert_eq EDGE "consecutive specials collapse" "a-b" "$(wid_field "$out" SLUG)"

  # --- EDGE: leading and trailing separators stripped ---
  out=$(wid_run " lead and trail " "$named")
  hs_assert_eq EDGE "leading/trailing dashes stripped" "lead-and-trail" "$(wid_field "$out" SLUG)"

  # --- EDGE: an all-punctuation label still yields a usable slug ---
  out=$(wid_run "!!!" "$named")
  hs_assert_eq EDGE "all-punctuation label falls back to 'window'" "window" "$(wid_field "$out" SLUG)"

  # --- EDGE: cwd containing spaces (Steve's real workspace does) ---
  local spaced="$tmpcwd/SP - Claude"
  mkdir -p "$spaced"
  out=$(wid_run "" "$spaced")
  hs_assert_eq EDGE "spaced cwd basename slugged" "sp-claude" "$(wid_field "$out" SLUG)"

  # --- EDGE: a broken conf must not take the window down ---
  local home conf key
  home="$(mktemp -d)"
  key=$(printf '%s' "w1" | tr -c '[:alnum:]-' '_')
  conf="$home/.claude/hooks/headsup-status.d/$key.conf"
  mkdir -p "$(dirname "$conf")"
  printf 'this is ( not valid shell\n' > "$conf"
  ( cd "$named" && HOME="$home" ITERM_SESSION_ID="w1" bash "$WID_SUT" >/dev/null 2>&1 )
  rc=$?
  hs_assert_eq EDGE "broken conf still exits 0" "0" "$rc"
  out=$( cd "$named" && HOME="$home" ITERM_SESSION_ID="w1" bash "$WID_SUT" 2>/dev/null )
  hs_assert_eq EDGE "broken conf falls back to cwd basename" "my-project" "$(wid_field "$out" SLUG)"
  rm -rf "$home"

  # --- EDGE: a label containing a newline must not break KEY=value parsing ---
  # Consumers parse this output line by line. A multi-line LABEL would make the
  # STAMP/CWD lines unparseable or inject a bogus key.
  home="$(mktemp -d)"
  conf="$home/.claude/hooks/headsup-status.d/$key.conf"
  mkdir -p "$(dirname "$conf")"
  printf "headsup_title_text() { printf 'evil\\nSLUG=hijacked'; }\n" > "$conf"
  out=$( cd "$named" && HOME="$home" ITERM_SESSION_ID="w1" bash "$WID_SUT" 2>/dev/null )
  local slug_count
  slug_count=$(printf '%s\n' "$out" | grep -c '^SLUG=')
  hs_assert_eq EDGE "newline label cannot inject a second SLUG line" "1" "$slug_count"
  rm -rf "$home"

  rm -rf "$tmpcwd"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  hs_init "${1:-/tmp/headsup-window-id-results.tsv}"
  run_window_id_suite
  hs_summary
fi
