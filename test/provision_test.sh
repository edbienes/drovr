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
assert_ok   _drovr_reusable idle    "idle is reusable"
assert_ok   _drovr_reusable done    "done is reusable (just-finished turn)"
assert_ok   _drovr_reusable blocked "blocked is reusable"
assert_ok   _drovr_reusable unknown "unknown is reusable (present pane)"
assert_fail _drovr_reusable working "working is NOT reusable (busy → escalate)"

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
assert_ok   declare -F _drovr_settle
assert_fail grep -qF 'herdr wait output' "$PROV"
assert_ok   grep -qF 'herdr wait agent-status' "$PROV"
# Two real call sites settle on a genuine absent→idle boot: the fresh-launch in provision_role and the
# relaunch in _drovr_reset (Claude reset is now /exit→cd→relaunch, which reboots the agent). The old
# /clear reset never settled — that era is gone. (comment/definition mentions don't match the leading-call form.)
assert_eq "$(grep -cE '^[[:space:]]*_drovr_settle \"' "$PROV")" "2" "_drovr_settle called twice (fresh-launch boot + relaunch reset)"

# --- drovr_send_prompt: long triggers are delivered as send-text + a SEPARATE `Enter` keypress, NOT
# the bundled `herdr pane run` (whose Enter is absorbed into a long-text bracketed-paste pill, leaving
# the prompt UNSUBMITTED and the pane idle — observed live 2026-06-10). herdr's key name is `Enter`,
# NOT `Return` (a send-keys Return is a silent no-op, which is why an early recovery attempt failed). ---
assert_ok   declare -F drovr_send_prompt
assert_ok   grep -qE 'herdr pane send-text "\$pid"' "$PROV"
assert_ok   grep -qE 'herdr pane send-keys "\$pid" Enter' "$PROV"
assert_fail grep -qE 'send-keys "\$pid" Return' "$PROV"

# --- drovr_send_slash: dropdown-proof slash-command reset delivery (added 2026-07-06). A leading-slash
#     TUI command arms the slash-autocomplete dropdown, which consumed the bundled `pane run` Enter live —
#     /clear sat unsubmitted and wedged the pane (review-iter delivery bug #2). The helper sends text +
#     discrete Enter (via drovr_send_prompt) + a SECOND idempotent Enter, and both reset verbs route
#     through it (a bundled-Enter drovr_send of /new or /exit must never come back). ---
assert_ok   declare -F drovr_send_slash
assert_ok   grep -qE "drovr_send_slash \"\\\$id\" '/new'"  "$PROV"
assert_ok   grep -qE "drovr_send_slash \"\\\$id\" '/exit'" "$PROV"
assert_fail grep -qE "drovr_send \"\\\$id\" '/(new|exit|clear)'" "$PROV"
# functional: dead-count the Enters — stub the primitives, dropdown-proof = exactly 2 discrete Enters, 1 text send.
enters=0; texts=0
drovr_assert_ours() { return 0; }
herdr() { case "$2" in send-keys) enters=$((enters+1));; send-text) texts=$((texts+1));; esac; }
drovr_send_slash "w0-9" '/new'
assert_eq "$texts"  "1" "send_slash sends the command text exactly once (never a re-send)"
assert_eq "$enters" "2" "send_slash sends two discrete Enters (submit + dropdown-eaten fallback)"

# --- role panes land on labeled herdr tabs, not a 2x2 split of the orchestrator tab ---
# Live scar (2026-08-18): Slice C review stage split impl-safety, impl-volume, claude-code-review,
# and grok-pressure-test onto the ktor "main" tab (5 panes, unreadable). Intended shape is
# tab "main" (orchestrator only) / tab "implementation" / tab "reviews".
TAB_SCOPED="$DIR/fixtures/tab_list_scoped.json"
TAB_GLOBAL="$DIR/fixtures/tab_list_global.json"
PANE_TABS="$DIR/fixtures/pane_list_tabs.json"
TAB_CREATE="$DIR/fixtures/tab_create.json"

assert_eq "$(_drovr_tab_for claude-code-review)" "reviews" "claude-code-review sits on tab reviews"
assert_eq "$(_drovr_tab_for grok-pressure-test)" "reviews" "grok-pressure-test sits on tab reviews"
assert_eq "$(_drovr_tab_for claude-implementation)" "implementation" "claude-implementation sits on tab implementation"
assert_eq "$(_drovr_tab_for grok-implementation)" "implementation" "grok-implementation sits on tab implementation"
assert_eq "$(_drovr_tab_for grok-headless-implementation)" "implementation" "grok-headless-implementation sits on tab implementation"
assert_eq "$(_drovr_tab_for grok-plan-tui)" "implementation" "grok-plan-tui sits on tab implementation"
assert_fail _drovr_tab_for claude-orchestrator "orchestrator is not a provisioned tab role"

rid="$(tab_id_for_label reviews < "$TAB_SCOPED")"
assert_eq "$rid" "w0:t3" "scoped tab list resolves reviews in THIS workspace"
assert_eq "$(tab_id_for_label implementation < "$TAB_SCOPED")" "w0:t2" "scoped tab list resolves implementation"
assert_eq "$(tab_id_for_label main < "$TAB_SCOPED")" "w0:t1" "scoped tab list resolves main"
out="$(tab_id_for_label no-such-tab < "$TAB_SCOPED")"
assert_eq "$out" "" "absent tab label → empty"
assert_fail bash -c "tab_id_for_label no-such-tab < '$TAB_SCOPED'" "absent tab label → nonzero exit"
# A global list can return a FOREIGN reviews tab (wK:t2) as well as ours. Live code must
# scope via `herdr tab list --workspace` so we never resolve that foreign id.
foreign="$(python3 -c 'import json,sys; tabs=json.load(open(sys.argv[1]))["result"]["tabs"]; print(any(t.get("tab_id")=="wK:t2" for t in tabs))' "$TAB_SCOPED")"
assert_eq "$foreign" "False" "scoped tab fixture has no foreign reviews tab"
assert_eq "$(python3 -c 'import json,sys; tabs=json.load(open(sys.argv[1]))["result"]["tabs"]; print(any(t.get("tab_id")=="wK:t2" for t in tabs))' "$TAB_GLOBAL")" "True" "global tab fixture includes a colliding foreign reviews tab"

# root pane of tab create JSON (live herdr 0.8.0: result.root_pane.pane_id)
assert_eq "$(root_pane_id_from_tab_create < "$TAB_CREATE")" "w0:p9" "tab create JSON yields result.root_pane.pane_id"

# adopt an unlabeled reusable pane on a tab; skip labeled children (those are other roles)
assert_eq "$(unlabeled_pane_on_tab w0:t2 < "$PANE_TABS")" "w0:p2" "implementation tab root is the unlabeled pane"
assert_eq "$(unlabeled_pane_on_tab w0:t3 < "$PANE_TABS")" "" "reviews tab has no unlabeled pane (both roles labeled)"
assert_eq "$(first_pane_on_tab w0:t3 < "$PANE_TABS")" "w0:p3" "reviews tab split-anchor is a labeled child on THAT tab"
assert_eq "$(first_pane_on_tab w0:t1 < "$PANE_TABS")" "w0:p1" "main tab's only pane is the orchestrator"

# Source pins: new role panes use tab create --no-focus; never steal focus; never 2x2-split main.
assert_ok   grep -qF 'herdr tab list --workspace' "$PROV"
assert_ok   grep -qE 'herdr tab create .*--no-focus' "$PROV"
assert_fail grep -qE 'herdr tab create .*[[:space:]]--focus([[:space:]]|$)' "$PROV"
assert_fail grep -qF 'herdr tab focus' "$PROV"
assert_fail grep -qF '_drovr_anchor_for' "$PROV"
assert_fail grep -qF 'claude-orchestrator right' "$PROV"
assert_fail grep -qF 'claude-orchestrator down' "$PROV"
# pane split remains ONLY as a within-tab split (two reviewers / impl+plan), never the create path's first move
assert_ok   grep -qF 'herdr pane split' "$PROV"
# Never list tabs or panes globally
assert_fail grep -qE 'herdr tab list[[:space:]]*$' "$PROV"
assert_fail grep -qE 'herdr pane list[[:space:]]*$' "$PROV"

# --- provision_role create/reuse paths (stubbed herdr) ---
# Command substitution runs provision_role in a subshell, so counters must be files.
LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT

_stub_common() {
  : >"$LOGDIR/herdr"
  : >"$LOGDIR/reset"
  drovr_workspace_id() { echo w0; }
  drovr_self_pane_id() { echo w0:p1; }   # must NOT be used as a split anchor
  drovr_assert_ours() { return 0; }
  _drovr_settle() { :; }
  drovr_send() { return 0; }
  _drovr_reset() { printf 'reset %s\n' "$*" >>"$LOGDIR/reset"; }
}

_herdr_count() { # _herdr_count <prefix>  (grep -c prints 0 on no match; ignore its rc)
  grep -c "^$1" "$LOGDIR/herdr" 2>/dev/null || true
}

# 1) role absent + tab absent → tab create --no-focus, use root_pane, no split, no focus
_stub_common
drovr_panes() { printf '%s\n' '{"result":{"panes":[{"label":"claude-orchestrator","pane_id":"w0:p1","tab_id":"w0:t1","workspace_id":"w0","agent_status":"working"}]}}'; }
drovr_tabs()  { printf '%s\n' '{"result":{"tabs":[{"label":"main","tab_id":"w0:t1","workspace_id":"w0"}]}}'; }
herdr() {
  printf '%s\n' "$*" >>"$LOGDIR/herdr"
  case "$1 $2" in
    "tab create") cat "$TAB_CREATE" ;;
    "pane split") printf '%s\n' '{"result":{"pane":{"pane_id":"w0:p99"}}}' ;;
    *) ;;
  esac
}
newid="$(provision_role claude-code-review)"
assert_eq "$newid" "w0:p9" "absent reviews tab → adopt tab-create root_pane"
assert_eq "$(_herdr_count 'tab create')" "1" "absent tab → exactly one tab create"
assert_eq "$(_herdr_count 'pane split')" "0" "absent tab → no pane split (do not split main)"
assert_eq "$(grep -c 'w0:p1' "$LOGDIR/herdr" || true)" "0" "never addresses the orchestrator pane"
assert_eq "$(_herdr_count 'tab focus')" "0" "tab create must not steal focus"
assert_contains "$(grep '^tab create' "$LOGDIR/herdr")" "--no-focus" "tab create carries --no-focus"
assert_contains "$(grep '^tab create' "$LOGDIR/herdr")" "--label reviews" "tab create labels the reviews tab"

# 2) role absent + reviews tab exists with unlabeled root → adopt, no new tab, no split
_stub_common
drovr_panes() { printf '%s\n' '{"result":{"panes":[{"label":"claude-orchestrator","pane_id":"w0:p1","tab_id":"w0:t1","workspace_id":"w0","agent_status":"working"},{"pane_id":"w0:p8","tab_id":"w0:t3","workspace_id":"w0","agent_status":"unknown"}]}}'; }
drovr_tabs() { cat "$TAB_SCOPED"; }
herdr() {
  printf '%s\n' "$*" >>"$LOGDIR/herdr"
  case "$1 $2" in
    "tab create") cat "$TAB_CREATE" ;;
    "pane split") printf '%s\n' '{"result":{"pane":{"pane_id":"w0:p99"}}}' ;;
    *) ;;
  esac
}
newid="$(provision_role grok-pressure-test)"
assert_eq "$newid" "w0:p8" "existing reviews tab → adopt unlabeled root pane"
assert_eq "$(_herdr_count 'tab create')" "0" "existing labeled tab → do not create another"
assert_eq "$(_herdr_count 'pane split')" "0" "unlabeled root present → do not split"
assert_contains "$(grep '^pane rename' "$LOGDIR/herdr")" "w0:p8" "adopted pane is renamed to the role"

# 3) role absent + reviews tab exists with labeled sibling → split WITHIN that tab, never main
_stub_common
drovr_panes() { cat "$PANE_TABS" | python3 -c '
import sys,json
d=json.load(sys.stdin)
d["result"]["panes"]=[p for p in d["result"]["panes"] if p.get("label")!="grok-pressure-test"]
json.dump(d, sys.stdout)
'; }
drovr_tabs() { cat "$TAB_SCOPED"; }
herdr() {
  printf '%s\n' "$*" >>"$LOGDIR/herdr"
  case "$1 $2" in
    "tab create") cat "$TAB_CREATE" ;;
    "pane split") printf '%s\n' '{"result":{"pane":{"pane_id":"w0:p10"}}}' ;;
    *) ;;
  esac
}
newid="$(provision_role grok-pressure-test)"
assert_eq "$newid" "w0:p10" "second reviewer is a within-tab split"
assert_eq "$(_herdr_count 'tab create')" "0" "reviews tab already exists → no second reviews tab"
assert_eq "$(_herdr_count 'pane split')" "1" "labeled sibling → split inside the reviews tab"
assert_contains "$(grep '^pane split' "$LOGDIR/herdr")" "w0:p3" "split anchor is the labeled child on reviews, not main"
assert_fail grep -q 'pane split w0:p1' "$LOGDIR/herdr" "split anchor is not the orchestrator"

# 4) role present + reusable → reset, no tab create, no split (reuse-by-label still holds)
_stub_common
drovr_panes() { cat "$PANE_TABS"; }
drovr_tabs() { cat "$TAB_SCOPED"; }
herdr() {
  printf '%s\n' "$*" >>"$LOGDIR/herdr"
  case "$1 $2" in
    "tab create") cat "$TAB_CREATE" ;;
    "pane split") printf '%s\n' '{"result":{"pane":{"pane_id":"w0:p99"}}}' ;;
    *) ;;
  esac
}
newid="$(provision_role claude-code-review)"
assert_eq "$newid" "w0:p3" "present reusable reviewer is reused by label"
assert_eq "$(grep -c '^reset' "$LOGDIR/reset")" "1" "reuse path still resets at the task boundary"
assert_eq "$(_herdr_count 'tab create')" "0" "reuse path does not create a tab"
assert_eq "$(_herdr_count 'pane split')" "0" "reuse path does not split"

# 5) role present + working → escalate rc=2, no duplicate, no reset
_stub_common
drovr_panes() { printf '%s\n' '{"result":{"panes":[{"label":"claude-code-review","pane_id":"w0:p3","tab_id":"w0:t3","workspace_id":"w0","agent_status":"working"}]}}'; }
drovr_tabs() { cat "$TAB_SCOPED"; }
herdr() {
  printf '%s\n' "$*" >>"$LOGDIR/herdr"
  case "$1 $2" in
    "tab create") cat "$TAB_CREATE" ;;
    "pane split") printf '%s\n' '{"result":{"pane":{"pane_id":"w0:p99"}}}' ;;
    *) ;;
  esac
}
out="$(provision_role claude-code-review 2>/dev/null)"; rc=$?
assert_eq "$rc" "2" "working role pane escalates (rc=2)"
assert_eq "$(grep -c '^reset' "$LOGDIR/reset" || true)" "0" "working pane is never reset"
assert_eq "$(_herdr_count 'tab create')" "0" "working pane is never duplicated via tab create"
assert_eq "$(_herdr_count 'pane split')" "0" "working pane is never duplicated via split"

assert_summary
