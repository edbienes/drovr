#!/usr/bin/env bash
# dispatch_test.sh — panes-free unit tests for the iteration-review dispatch helpers.
# Covers the two reliability concerns raised in review of the implementation loop:
#   1. drovr_collect_iter's ready-path resolves both lenses to OK without touching panes
#      (the function was otherwise only exercised live).
#   2. the iteration review trigger re-anchors a WARM reviewer pane: it renders as a single
#      physical line, leaves no unsubstituted {{...}} slots, and carries the round number so a
#      warm pane sees a textually-distinct instruction instead of pattern-matching "already did this".
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
export HERDR_PANE_ID="w0-1"          # never used on the ready-path; set so sourcing is clean
. "$DIR/../lib/dispatch.sh"          # sources bus.sh + provision.sh via BASH_SOURCE (bash only)

# Isolated bus so we never touch a real ~/.drovr room.
TMP="$(mktemp -d)"; export DROVR_BUS_ROOT="$TMP" DROVR_REPO_SLUG="dispatch-test"
trap 'rm -rf "$TMP"' EXIT

# --- 1. drovr_collect_iter ready-path: both lenses staged complete → both OK, exit 0, no panes ---
TASK="collect-iter-probe"
printf 'claude: looks good\n' | bus_write "$TASK" "iter-1/reviews/claude.md" >/dev/null
printf 'grok: no blockers\n'  | bus_write "$TASK" "iter-1/reviews/grok.md"   >/dev/null
out="$(drovr_collect_iter "$TASK" 1 /tmp/fake-worktree 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "collect_iter ready-path returns 0 (both lenses complete)"
assert_contains "$out" "claude-code-review OK"      "collect_iter reports claude-code-review OK"
assert_contains "$out" "grok-pressure-test OK" "collect_iter reports grok-pressure-test OK"

# --- 2. iteration review trigger re-anchors a warm pane ---
export DL_TASK=demo DL_REPO=super-school-rs DL_REPO_PATH=/tmp/wt DL_WORKTREE_NAME=drovr-demo
export DL_TARGET="branch drovr-demo vs main (worktree /tmp/wt), review round 2"
export DL_ITERDIR="$TMP/dispatch-test/demo/iter-2" DL_BUSDIR="$TMP/dispatch-test/demo"
trig="$(_fill "$_DROVR_TMPL/trigger-review-iter.txt")"
assert_eq "$(printf '%s' "$trig" | grep -c '{{')" "0" "iter trigger has no unsubstituted {{ }} slots"
assert_eq "$(printf '%s' "$trig" | wc -l | tr -d ' ')" "0" "iter trigger is a single physical line"
assert_contains "$trig" "iter-2"    "iter trigger carries the round-specific path (warm-pane re-anchor)"
assert_contains "$trig" "even if a previous round" "iter trigger forces a fresh re-review each round"

# --- 3. unsubmitted-trigger guard: every trigger fire routes through _drovr_fire (confirm pickup +
#         re-deliver once), and trigger DELIVERY uses drovr_send_prompt (send-text + a SEPARATE Enter),
#         never the bundled `herdr pane run` (drovr_send) whose Enter is absorbed into a long-text
#         bracketed-paste pill, leaving the prompt unsubmitted. Regression guard for the live 2026-06-10
#         failures (impl trigger dropped; first review trigger sat as a [Pasted text] pill, pane idle). ---
SRC="$DIR/../lib/dispatch.sh"
assert_eq "$(grep -c '^_drovr_fire()' "$SRC")" "1" "_drovr_fire helper is defined"
# The unsubmitted-trigger retry is a DISCRETE Enter (submits a stuck paste-pill, no-op on an empty
# composer), NOT a re-send of the whole prompt — a full re-send double-fired the LLM whenever _drovr_busy
# false-negatived a working agent (observed live 2026-06-25). Guard the bare-Enter retry against regressing.
assert_eq "$(grep -cE 'herdr pane send-keys .* Enter' "$SRC")" "1" "_drovr_fire retry submits via a discrete Enter (no prompt re-send)"
assert_eq "$(grep -c 'for attempt in 1 2' "$SRC")" "0" "_drovr_fire does not loop a full re-send (would double-fire the LLM)"
fires="$(grep -cE '^[[:space:]]*_drovr_fire \"' "$SRC")"
assert_eq "$([ "$fires" -ge 5 ] && echo ok)" "ok" "all trigger fires route through _drovr_fire (>=5: impl + 2 review-stage + 2 review-iter; found $fires)"
# both trigger-delivery sites (_drovr_fire + the collect reprompt) use the send-text+Enter primitive.
assert_eq "$(grep -cE '^[[:space:]]*drovr_send_prompt ' "$SRC")" "2" "trigger deliveries use drovr_send_prompt (_drovr_fire + collect reprompt)"
# and none deliver a trigger via the bundled drovr_send (trailing space excludes drovr_send_prompt).
assert_eq "$(grep -cE 'drovr_send .*_fill.*trigger-' "$SRC")" "0" "no trigger is delivered via bundled drovr_send/pane run"

# --- 4. grok implementor wiring (DL_IMPL_AGENT=grok): the launch line carries the per-task worktree flag,
#         the grok trigger renders clean (single line, no {{}}, runs /implement), and dispatch + provision
#         expose the grok label/trigger arms. DL_WORKTREE_NAME=drovr-demo was exported in section 2. ---
assert_contains "$(_drovr_launch_for grok-implementation)" "--worktree=drovr-demo" "grok-implementation launch carries --worktree=<task>"
_drovr_set_ctx_impl demo 2 >/dev/null   # populate impl/iter env (FEEDBACK_STEP, GATE_STEP, ITERDIR, …)
gtrig="$(_fill "$_DROVR_TMPL/trigger-impl-grok.txt")"
assert_eq "$(printf '%s' "$gtrig" | grep -c '{{')" "0" "grok impl trigger has no unsubstituted {{ }} slots"
assert_eq "$(printf '%s' "$gtrig" | wc -l | tr -d ' ')" "0" "grok impl trigger is a single physical line"
assert_contains "$gtrig" "/implement --effort 3" "grok impl trigger runs /implement with an integer reviewer count"
# grok-build has no configurable reasoning effort + --effort is headless-only (ignored in the TUI pane),
# so the launch must NOT carry --effort. Guard against re-adding the no-op flag.
assert_eq "$(_drovr_launch_for grok-implementation | grep -c -- '--effort')" "0" "grok-implementation launch carries no --effort (no-op for grok-build / headless-only)"
assert_eq "$(grep -c 'impl_trigger=trigger-impl-grok.txt' "$SRC")" "1" "dispatch selects the grok trigger for DL_IMPL_AGENT=grok"
assert_eq "$(grep -cE 'grok-implementation\)' "$DIR/../lib/provision.sh")" "2" "provision has a grok-implementation launch arm (+ _drovr_alive case)"

# --- 5. grok HEADLESS implementor wiring (the DEFAULT arm = composer-fast). dispatch defaults to composer-fast,
#         maps both grok models onto a shared grok-headless-implementation pane label, and builds a one-shot
#         `grok -p` shell line whose PROMPT LEADS with `/implement --effort 2` (the skill's reviewer COUNT, NOT
#         the no-op CLI --effort flag), passing the model via -m. provision + teardown expose the shell arm. ---
PROV="$DIR/../lib/provision.sh"
assert_eq "$(grep -c 'DL_IMPL_AGENT:-forge' "$SRC")" "2" "dispatch defaults DL_IMPL_AGENT to forge (impl case + plan-phase arm guard)"
assert_eq "$(grep -c 'grok_model=grok-composer-2.5-fast' "$SRC")" "1" "composer-fast arm selects the grok-composer-2.5-fast model"
# upstream retired the grok-build MODEL in 2026-07 (grok-4.5 is the CLI default); grok-build stays a
# backcompat ALIAS arm routing to grok-4.5 — `-m grok-build` would error against the live CLI.
assert_eq "$(grep -c 'grok_model=grok-4.5' "$SRC")" "1" "grok-4.5 arm (and grok-build alias) select the grok-4.5 model"
assert_eq "$(grep -c 'grok_model=grok-build' "$SRC")" "0" "no arm still selects the retired grok-build model"
assert_eq "$(grep -cF 'grok-4.5|grok-build)' "$SRC")" "1" "grok-build is a backcompat alias for grok-4.5"
assert_eq "$(grep -cF 'forge|composer-fast|grok-build|grok-4.5)' "$SRC")" "1" "dispatch_plan accepts the grok-4.5 arm"
assert_eq "$(grep -c 'impl_label=grok-headless-implementation' "$SRC")" "2" "both headless grok arms share the grok-headless-implementation label"
assert_eq "$(grep -c 'grok_lead="/implement --effort 3 "' "$SRC")" "1" "grok impl prompt LEADS with /implement --effort 3 (via grok_lead; plan phase empties it)"
assert_eq "$(grep -cF 'grok -p \"$grok_lead' "$SRC")" "2" "both grok exec lines lead with \$grok_lead"
assert_eq "$(grep -cE 'grok -p .*-m \$grok_model' "$SRC")" "2" "grok arm passes the model via -m for both iters"
# the grok CLI errors (os error 2) on a RELATIVE --cwd — the flag must carry the absolute worktree path
assert_eq "$(grep -cF -- '--cwd \"$DL_REPO_PATH/$wt\"' "$SRC")" "1" "grok --cwd is absolute (\$DL_REPO_PATH/\$wt, never bare \$wt)"
assert_eq "$(grep -cF -- '--cwd \"$wt\"' "$SRC")" "0" "no grok launch uses a relative --cwd"
assert_eq "$(grep -cE -- '--always-approve.*--effort' "$SRC")" "0" "grok headless passes NO CLI --effort flag (no-op: supports_reasoning_effort=false)"
assert_eq "$(grep -c 'grok-headless-implementation)' "$PROV")" "2" "provision has a grok-headless launch arm (+ _drovr_alive case)"
assert_eq "$([ "$(grep -c 'grok-headless-implementation' "$PROV")" -ge 3 ] && echo ok)" "ok" "provision wires grok-headless across launch + busy + reset"
assert_eq "$(grep -c 'for label in grok-headless-implementation' "$SRC")" "1" "teardown searches the grok-headless arm first (default)"
assert_contains "$(_drovr_launch_for grok-headless-implementation)" "cd " "grok-headless launch parks the shell at repo root (no resident agent)"

# --- 6. forge is the only non-grok shell arm; codex is REMOVED ENTIRELY (per Ed 2026-07-07 — the roster is
#         Claude + Grok only; forge runs Claude via ~/.forge/.forge.toml). Absence guards keep codex from
#         creeping back; the shared shell-arm prompt (renamed prompt-impl-shell.txt) keeps its bus contract. ---
assert_eq "$(grep -cE 'forge -p .*--agent forge' "$SRC")" "2" "forge arm still builds forge -p for both iters"
assert_eq "$(grep -ci codex "$SRC")" "0" "dispatch.sh has no codex references (arm fully excised)"
assert_eq "$(grep -ci codex "$PROV")" "0" "provision.sh has no codex references (arm fully excised)"
assert_eq "$([ ! -f "$_DROVR_TMPL/prompt-impl-codex.txt" ] && echo ok)" "ok" "codex-named prompt template is gone (renamed prompt-impl-shell.txt)"
ctrig="$(_fill "$_DROVR_TMPL/prompt-impl-shell.txt")"
assert_eq "$(printf '%s' "$ctrig" | grep -c '{{')" "0" "impl prompt has no unsubstituted {{ }} slots"
assert_contains "$ctrig" "gate.md"   "impl prompt carries the gate.md output contract"
assert_contains "$ctrig" "result.md" "impl prompt carries the result.md output contract"
assert_contains "$ctrig" "docs/decisions" "impl prompt substitutes a self ADR-review for the Claude subagents"

# --- 6b. impl task.md carries the working-discipline block (executing-hard-tasks extract, added 2026-07-06):
#         every impl arm reads task.md, so the discipline rides the bus regardless of arm. Canonical source:
#         ~/.claude/skills/executing-hard-tasks/SKILL.md (edit there first, then sync the template block). ---
timpl="$(_fill "$_DROVR_TMPL/task-impl.md.tmpl")"
assert_eq "$(printf '%s' "$timpl" | grep -c '{{')" "0" "impl task.md renders with no unsubstituted {{ }} slots"
assert_contains "$timpl" "Working discipline" "impl task.md carries the working-discipline block"
assert_contains "$timpl" "VERIFIED" "discipline block pins verified-vs-inferred claim labeling"
assert_contains "$timpl" "watch red" "discipline block pins the red-then-green new-test proof"
assert_contains "$timpl" "entry point" "discipline block pins entry-point reachability verification"
assert_contains "$timpl" "Deviations" "discipline block requires naming brief/plan deviations in the summary"

# --- 8. plan-first (DL_PLAN_FIRST, added 2026-07-07 per Ed): drovr_dispatch_plan runs a PLAN-ONLY phase
#         (iter-0, shell arms only) that writes iter-0/plan.md and STOPS; the human approves via the
#         plan-approved.md marker; iter-1 then binds to the approved plan and reuses the plan-phase worktree.
#         Guards fail CLOSED (rc=5): DL_PLAN_FIRST=1 without a plan refuses iter-1; an unapproved plan
#         refuses iter-1. (Numbered 8 but placed before the section-7 stubs — stubs stay LAST by design.) ---
assert_eq "$(grep -c '^drovr_dispatch_plan()' "$SRC")" "1" "drovr_dispatch_plan is defined"
# 8a. resident arms (claude / legacy grok TUI) are unsupported for the plan phase
out="$(cd "$TMP" && DL_IMPL_AGENT=claude drovr_dispatch_plan planp "brief" 2>&1)"; rc=$?
assert_eq "$rc" "2" "dispatch_plan refuses resident arms (rc=2)"
assert_contains "$out" "shell arms" "dispatch_plan names the shell-arms-only constraint"
# 8b. the plan prompt template renders clean and carries the plan.md contract
export DL_TASK=planp DL_BUSDIR="$TMP/dispatch-test/planp" DL_ITERDIR="$TMP/dispatch-test/planp/iter-0"
ptrig="$(_fill "$_DROVR_TMPL/prompt-impl-plan.txt")"
assert_eq "$(printf '%s' "$ptrig" | grep -c '{{')" "0" "plan prompt has no unsubstituted {{ }} slots"
assert_contains "$ptrig" "plan.md" "plan prompt carries the plan.md output contract"
assert_contains "$ptrig" "END-OF-FILE" "plan prompt pins the END-OF-FILE sentinel"
assert_contains "$ptrig" "Decisions" "plan prompt leads with the tweakable-decisions section"
assert_contains "$ptrig" "Do NOT implement" "plan prompt forbids implementation in the plan phase"
# 8c. DL_PLAN_FIRST=1 with no plan yet refuses an iter-1 impl dispatch (fail closed, points at the fix)
mkdir -p "$TMP/dispatch-test/planp"
out="$(cd "$TMP" && DL_PLAN_FIRST=1 drovr_dispatch_impl planp 1 "brief" 2>&1)"; rc=$?
assert_eq "$rc" "5" "DL_PLAN_FIRST=1 without iter-0/plan.md refuses iter-1 (rc=5)"
assert_contains "$out" "drovr_dispatch_plan" "the refusal points at drovr_dispatch_plan"
# 8d. an existing but UNAPPROVED plan blocks iter-1 (the human pause is the point)
printf 'the plan\n' | bus_write planp "iter-0/plan.md" >/dev/null
out="$(cd "$TMP" && drovr_dispatch_impl planp 1 "brief" 2>&1)"; rc=$?
assert_eq "$rc" "5" "unapproved plan blocks iter-1 (rc=5)"
assert_contains "$out" "plan-approved.md" "the refusal names the approval marker"
# 8e. approved plan: iter-1 ctx binds to the plan and forbids re-creating the worktree
touch "$TMP/dispatch-test/planp/plan-approved.md"
unset DL_WORKTREE_STEP DL_FEEDBACK_STEP DL_GATE_STEP DL_GATE_CONTRACT
plan_ctx="$(cd "$TMP" && _drovr_set_ctx_impl planp 1 && printf 'F=%s\nW=%s\n' "$DL_FEEDBACK_STEP" "$DL_WORKTREE_STEP")"
assert_contains "$plan_ctx" "iter-0/plan.md" "iter-1-after-plan FEEDBACK_STEP points at the approved plan"
assert_contains "$plan_ctx" "do NOT" "iter-1-after-plan WORKTREE_STEP forbids re-creating the worktree"
unset DL_WORKTREE_STEP DL_FEEDBACK_STEP DL_GATE_STEP DL_GATE_CONTRACT
# 8f. source pins: the shell cmd builder keys worktree-add on plan-phase absence; grok plan phase drops /implement
assert_eq "$([ "$(grep -c 'fresh_wt' "$SRC")" -ge 3 ] && echo ok)" "ok" "shell cmd builder routes worktree-add through a fresh_wt switch"
assert_eq "$(grep -c 'status_set "$task" plan' "$SRC")" "1" "plan phase records status phase=plan"

# --- 9. target-guard (added 2026-07-07 per Ed, after the pace-b iter-3 ENOSPC): every shell-arm exec is
#         prefixed with a fail-safe CARGO_TARGET_DIR volume check that prunes the debug tree between
#         dispatches when free space is low. ALWAYS exits 0 — it must never block a dispatch. ---
TG="$DIR/../lib/target-guard.sh"
assert_eq "$([ -f "$TG" ] && echo ok)" "ok" "target-guard.sh exists"
assert_eq "$(grep -c 'target-guard.sh' "$SRC")" "1" "shell cmd builder prefixes the exec with target-guard"
assert_eq "$(grep -cF '$tguard $exec_cmd' "$SRC")" "2" "both fresh-wt and reuse cmd paths carry the guard"
# 9a. fail-safe: unset / missing target dir → rc 0, no output
out="$(CARGO_TARGET_DIR= bash "$TG" 2>&1)"; rc=$?
assert_eq "$rc" "0" "guard exits 0 with no CARGO_TARGET_DIR"
assert_eq "$out" "" "guard is silent with no CARGO_TARGET_DIR"
out="$(CARGO_TARGET_DIR="$TMP/does-not-exist" bash "$TG" 2>&1)"; rc=$?
assert_eq "$rc" "0" "guard exits 0 on a missing target dir"
# 9b. plenty of free space (threshold 0G) → debug tree survives
mkdir -p "$TMP/td/debug"; printf 'artifact' > "$TMP/td/debug/blob"
CARGO_TARGET_DIR="$TMP/td" DL_TARGET_MIN_FREE_GB=0 bash "$TG" >/dev/null 2>&1
assert_eq "$([ -f "$TMP/td/debug/blob" ] && echo kept)" "kept" "guard keeps debug when free space is above threshold"
# 9c. low free space (absurd threshold) → debug tree pruned, rc still 0
out="$(CARGO_TARGET_DIR="$TMP/td" DL_TARGET_MIN_FREE_GB=999999 bash "$TG" 2>&1)"; rc=$?
assert_eq "$rc" "0" "guard exits 0 even when it prunes"
assert_eq "$([ ! -d "$TMP/td/debug" ] && echo pruned)" "pruned" "guard prunes debug when the volume is below threshold"
assert_contains "$out" "pruning" "guard announces the prune"

# --- 10. per-repo .drovr/config (extraction P1, 2026-07-09): repo POLICY loads from
#          <repo>/.drovr/config in a sandboxed empty-env subshell, whitelisted DL_* only, precedence
#          env > config > default; gate profiles are GENERIC (rust=fmt+clippy, web, python) with repo
#          specifics moved to each repo's config; DL_WORKTREE_BASE replaces the hardcoded origin/main;
#          and the super-school-rs fixture reproduces the pre-extraction rust gate BYTE-FOR-BYTE
#          (the backcompat guarantee). Placed before the section-7 stubs — stubs stay LAST. ---
CFGREPO="$TMP/cfgrepo"
git init -q "$CFGREPO" 2>/dev/null
git -C "$CFGREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
mkdir -p "$CFGREPO/.drovr"
# 10a. no config → generic rust default; repo-specific oracles are no longer baked into the profile
out="$(unset DL_GATE_PROFILE DL_GATE_STEP DL_GATE_CONTRACT DL_WORKTREE_BASE DL_WORKTREE_STEP DL_FEEDBACK_STEP
       cd "$CFGREPO" && _drovr_set_ctx_impl cfg-none 1 >/dev/null 2>&1; printf '%s' "$DL_GATE_STEP")"
assert_contains "$out" "cargo clippy --all-targets" "no config: generic rust gate applies"
assert_eq "$(printf '%s' "$out" | grep -c 'ADR-checker')" "0" "no config: ADR checkers are NOT in the generic profile"
# 10b. python profile (new): ruff + mypy + pytest
out="$(unset DL_GATE_STEP DL_GATE_CONTRACT DL_WORKTREE_BASE DL_WORKTREE_STEP DL_FEEDBACK_STEP
       export DL_GATE_PROFILE=python; cd "$CFGREPO" && _drovr_set_ctx_impl cfg-py 1 >/dev/null 2>&1; printf '%s' "$DL_GATE_STEP")"
assert_contains "$out" "ruff check ., then mypy ., then pytest" "python profile: ruff+mypy+pytest gate"
# 10c. config sets the profile → applied when the caller env doesn't
printf 'DL_GATE_PROFILE=web\n' > "$CFGREPO/.drovr/config"
out="$(unset DL_GATE_PROFILE DL_GATE_STEP DL_GATE_CONTRACT DL_WORKTREE_BASE DL_WORKTREE_STEP DL_FEEDBACK_STEP
       cd "$CFGREPO" && _drovr_set_ctx_impl cfg-web 1 >/dev/null 2>&1; printf '%s' "$DL_GATE_STEP")"
assert_contains "$out" "pnpm -C web install" "config DL_GATE_PROFILE=web applies"
# 10d. per-dispatch env still beats repo config (`:-` convention)
out="$(unset DL_GATE_STEP DL_GATE_CONTRACT DL_WORKTREE_BASE DL_WORKTREE_STEP DL_FEEDBACK_STEP
       export DL_GATE_PROFILE=python; cd "$CFGREPO" && _drovr_set_ctx_impl cfg-envwin 1 >/dev/null 2>&1; printf '%s' "$DL_GATE_STEP")"
assert_contains "$out" "ruff check" "caller env DL_GATE_PROFILE beats repo config"
# 10e. sandbox + whitelist: a config cannot clobber task identity in the orchestrator shell
printf 'DL_GATE_PROFILE=web\nDL_TASK=evil\nDL_REPO_PATH=/pwned\n' > "$CFGREPO/.drovr/config"
out="$(unset DL_GATE_PROFILE DL_GATE_STEP DL_GATE_CONTRACT DL_WORKTREE_BASE DL_WORKTREE_STEP DL_FEEDBACK_STEP
       cd "$CFGREPO" && _drovr_set_ctx_impl cfg-sandbox 1 >/dev/null 2>&1; printf '%s|%s' "$DL_TASK" "$DL_REPO_PATH")"
assert_contains "$out" "cfg-sandbox|" "config cannot clobber DL_TASK (sandbox + whitelist)"
assert_eq "$(printf '%s' "$out" | grep -c pwned)" "0" "config cannot clobber DL_REPO_PATH"
# 10f. DL_WORKTREE_BASE: default origin/main; a config override reaches the EnterWorktree step text;
#      the shell-arm cmd builder branches off the var, never a literal.
rm -f "$CFGREPO/.drovr/config"
out="$(unset DL_GATE_PROFILE DL_GATE_STEP DL_GATE_CONTRACT DL_WORKTREE_BASE DL_WORKTREE_STEP DL_FEEDBACK_STEP
       cd "$CFGREPO" && _drovr_set_ctx_impl cfg-base 1 >/dev/null 2>&1; printf '%s' "$DL_WORKTREE_STEP")"
assert_contains "$out" "branched off origin/main" "worktree base defaults to origin/main"
printf 'DL_WORKTREE_BASE=origin/develop\n' > "$CFGREPO/.drovr/config"
out="$(unset DL_GATE_PROFILE DL_GATE_STEP DL_GATE_CONTRACT DL_WORKTREE_BASE DL_WORKTREE_STEP DL_FEEDBACK_STEP
       cd "$CFGREPO" && _drovr_set_ctx_impl cfg-base2 1 >/dev/null 2>&1; printf '%s' "$DL_WORKTREE_STEP")"
assert_contains "$out" "branched off origin/develop" "config DL_WORKTREE_BASE reaches the EnterWorktree step"
assert_eq "$(grep -c 'git worktree add .*origin/main' "$SRC")" "0" "shell cmd builder has no hardcoded origin/main base"
assert_contains "$(grep 'git worktree add' "$SRC")" '$_base' "shell cmd builder branches off \$DL_WORKTREE_BASE"
# 10f-2. _drovr_base_fetch: fetch prefix ONLY for a remote-qualified base — a slash-y LOCAL branch
#        (feat/x) must not be misread as remote+branch (found by the cortex P2 run, 2026-07-09).
assert_eq "$(_drovr_base_fetch "$CFGREPO" "feat/m8a-interactive-auth")" "" "slash-y local branch base gets NO fetch prefix (repo has no such remote)"
assert_eq "$(_drovr_base_fetch "$CFGREPO" "main")" "" "local no-slash base gets no fetch prefix"
git -C "$CFGREPO" remote add origin /nonexistent-remote 2>/dev/null
assert_eq "$(_drovr_base_fetch "$CFGREPO" "origin/develop")" "git fetch -q origin develop && " "remote-qualified base gets the fetch prefix"
assert_eq "$(_drovr_base_fetch "$CFGREPO" "feat/m8a-interactive-auth")" "" "slash-y local branch still no fetch even with a remote present"
# 10g. GOLDEN byte-identity: the super-school-rs fixture reproduces the pre-extraction rust gate exactly.
#      (The real file is <super-school-rs>/.drovr/config — keep the fixture a verbatim copy.)
cp "$DIR/fixtures/super-school-rs.drovr-config" "$CFGREPO/.drovr/config"
GOLD_STEP='cargo fmt --check, then cargo clippy --all-targets -- -D warnings, then regenerate the OpenAPI spec with cargo run --quiet --bin dump_openapi > openapi.json and run git diff --exit-code -- openapi.json (ADR-0002 contract-of-record drift: FAIL if it reports a diff — the committed spec is stale; regenerate with just gen-client and commit openapi.json plus web/src/lib/client/), then spawn the five ADR-checker subagents migration-reviewer rls-tenant-checker hex-boundary-checker auth-port-checker adr-compliance-reviewer on the committed diff'
GOLD_CONTRACT='`cargo fmt --check`; `cargo clippy --all-targets -- -D warnings`; OpenAPI contract-of-record drift (`cargo run --quiet --bin dump_openapi > openapi.json` then `git diff --exit-code -- openapi.json`, ADR-0002); and the five ADR-checker subagents (migration-reviewer, rls-tenant-checker, hex-boundary-checker, auth-port-checker, adr-compliance-reviewer) run on the committed diff.'
out="$(unset DL_GATE_PROFILE DL_GATE_STEP DL_GATE_CONTRACT DL_WORKTREE_BASE DL_WORKTREE_STEP DL_FEEDBACK_STEP
       cd "$CFGREPO" && _drovr_set_ctx_impl cfg-gold 1 >/dev/null 2>&1; printf '%s' "$DL_GATE_STEP")"
assert_eq "$out" "$GOLD_STEP" "super-school-rs config reproduces pre-extraction DL_GATE_STEP byte-for-byte"
out="$(unset DL_GATE_PROFILE DL_GATE_STEP DL_GATE_CONTRACT DL_WORKTREE_BASE DL_WORKTREE_STEP DL_FEEDBACK_STEP
       cd "$CFGREPO" && _drovr_set_ctx_impl cfg-gold2 1 >/dev/null 2>&1; printf '%s' "$DL_GATE_CONTRACT")"
assert_eq "$out" "$GOLD_CONTRACT" "super-school-rs config reproduces pre-extraction DL_GATE_CONTRACT byte-for-byte"

# --- 7. dead-pane FAIL-CLOSED (added 2026-07-06, per Ed): _drovr_fire refuses to deliver a trigger to a
#         pane with no live agent — a prompt typed into a bare shell was fired-and-forgotten TWICE live
#         (06-24, 07-06). Functional: stub _drovr_alive dead → rc=4 and NO delivery attempt; stub alive +
#         instant pickup → happy path unchanged. (Stubs are LAST in this file by design — they shadow the
#         real helpers for any test after them.) ---
assert_eq "$(grep -c '^_drovr_alive()' "$PROV")" "1" "_drovr_alive predicate is defined in provision.sh"
_drovr_alive() { return 1; }                        # stub: pane is dead
sent=0; drovr_send_prompt() { sent=1; return 0; }   # record any attempted delivery
_drovr_fire "w0-9" claude-code-review "trigger text" 2>/dev/null; rc=$?
assert_eq "$rc" "4" "_drovr_fire fails CLOSED (rc=4) on a dead pane"
assert_eq "$sent" "0" "_drovr_fire never delivers the prompt to a dead pane"
_drovr_alive() { return 0; }                        # stub: agent alive…
_drovr_busy()  { return 0; }                        # …and picks up immediately
_drovr_fire "w0-9" claude-code-review "trigger text" 2>/dev/null; rc=$?
assert_eq "$rc" "0" "_drovr_fire happy path unchanged (alive agent, instant pickup)"
assert_eq "$sent" "1" "_drovr_fire delivered the prompt to the live pane"

assert_summary
