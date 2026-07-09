#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/provision.sh"

FIX="$DIR/fixtures/pane_list.json"

# Resolves a present label to a non-empty pane id
rid="$(pane_id_for_label claude-code-review < "$FIX")"
assert_contains "$rid" "-" "claude-code-review id looks like a pane id"
gid="$(pane_id_for_label grok-pressure-test < "$FIX")"
assert_contains "$gid" "-" "grok-pressure-test id looks like a pane id"

# Absent label → empty string, exit nonzero
out="$(pane_id_for_label no-such-label < "$FIX")"
assert_eq "$out" "" "absent label → empty"
assert_fail bash -c "pane_id_for_label no-such-label < '$FIX'" "absent label → nonzero exit"

# pane_status_for_label returns one of the known states
st="$(pane_status_for_label claude-code-review < "$FIX")"
assert_contains " idle working blocked done unknown " " $st " "status is a known state"

# --- reuse predicate: only 'working' is non-reusable (a 'done' pane that just finished a turn
# must reuse, not get a duplicate split — the bug the live probes surfaced) ---
assert_ok   _devloop_reusable idle    "idle is reusable"
assert_ok   _devloop_reusable done    "done is reusable (just-finished turn)"
assert_ok   _devloop_reusable blocked "blocked is reusable"
assert_ok   _devloop_reusable unknown "unknown is reusable (present pane)"
assert_fail _devloop_reusable working "working is NOT reusable (busy → escalate)"

# --- workspace-ownership guard (pane_in_list) ---
# Call the sourced function directly (NOT via `bash -c`, which would start a subshell
# without the function and exit 127). Stdin redirection on the assert line feeds the fixture.
SCOPED="$DIR/fixtures/pane_list_scoped.json"   # our workspace only (4 panes)
# An OURS pane id is present in the scoped list → guard would allow
assert_ok   pane_in_list w6538552e440703-2 < "$SCOPED"
# A FOREIGN pane id is absent from the scoped list → guard REFUSES (the leak we must prevent)
assert_fail pane_in_list w653827b1ebfa61-2 < "$SCOPED"
# Sanity: the foreign id DOES exist in the unscoped GLOBAL list — so scoping is what excludes it
assert_ok   pane_in_list w653827b1ebfa61-2 < "$FIX"

# --- post-reset settle: must key on agent-status, NOT a scrollback prompt glyph (live bug: a Claude
# prompt is U+276F ❯, not '>', so `wait output --match ">"` hit stale scrollback, returned instantly,
# and the trigger fired mid-/clear and was swallowed → reviewer sat idle, review never ran) ---
PROV="$DIR/../lib/provision.sh"
assert_ok   declare -F _devloop_settle
assert_fail grep -qF 'herdr wait output' "$PROV"
assert_ok   grep -qF 'herdr wait agent-status' "$PROV"
# Two real call sites settle on a genuine absent→idle boot: the fresh-launch in provision_role and the
# relaunch in _devloop_reset (Claude reset is now /exit→cd→relaunch, which reboots the agent). The old
# /clear reset never settled — that era is gone. (comment/definition mentions don't match the leading-call form.)
assert_eq "$(grep -cE '^[[:space:]]*_devloop_settle \"' "$PROV")" "2" "_devloop_settle called twice (fresh-launch boot + relaunch reset)"

# --- devloop_send_prompt: long triggers are delivered as send-text + a SEPARATE `Enter` keypress, NOT
# the bundled `herdr pane run` (whose Enter is absorbed into a long-text bracketed-paste pill, leaving
# the prompt UNSUBMITTED and the pane idle — observed live 2026-06-10). herdr's key name is `Enter`,
# NOT `Return` (a send-keys Return is a silent no-op, which is why an early recovery attempt failed). ---
assert_ok   declare -F devloop_send_prompt
assert_ok   grep -qE 'herdr pane send-text "\$pid"' "$PROV"
assert_ok   grep -qE 'herdr pane send-keys "\$pid" Enter' "$PROV"
assert_fail grep -qE 'send-keys "\$pid" Return' "$PROV"

# --- devloop_send_slash: dropdown-proof slash-command reset delivery (added 2026-07-06). A leading-slash
#     TUI command arms the slash-autocomplete dropdown, which consumed the bundled `pane run` Enter live —
#     /clear sat unsubmitted and wedged the pane (review-iter delivery bug #2). The helper sends text +
#     discrete Enter (via devloop_send_prompt) + a SECOND idempotent Enter, and both reset verbs route
#     through it (a bundled-Enter devloop_send of /new or /exit must never come back). ---
assert_ok   declare -F devloop_send_slash
assert_ok   grep -qE "devloop_send_slash \"\\\$id\" '/new'"  "$PROV"
assert_ok   grep -qE "devloop_send_slash \"\\\$id\" '/exit'" "$PROV"
assert_fail grep -qE "devloop_send \"\\\$id\" '/(new|exit|clear)'" "$PROV"
# functional: dead-count the Enters — stub the primitives, dropdown-proof = exactly 2 discrete Enters, 1 text send.
enters=0; texts=0
devloop_assert_ours() { return 0; }
herdr() { case "$2" in send-keys) enters=$((enters+1));; send-text) texts=$((texts+1));; esac; }
devloop_send_slash "w0-9" '/new'
assert_eq "$texts"  "1" "send_slash sends the command text exactly once (never a re-send)"
assert_eq "$enters" "2" "send_slash sends two discrete Enters (submit + dropdown-eaten fallback)"

assert_summary
