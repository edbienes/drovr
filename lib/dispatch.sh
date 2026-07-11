#!/usr/bin/env bash
# dispatch.sh — write task.md to the bus and fire both reviewer triggers (Claude + Grok).
# SOURCED by the orchestrator.
#
# TWO live-proven constraints shape the triggers (do not "simplify" them away):
#  1. The skill name sits MID-PROSE, never as a LEADING slash command. A leading slash pushed through
#     `herdr pane run` (send-text + Enter) is mangled by the TUI autocomplete dropdown — a probed
#     plugin slash command was submitted as `/clear` instead. Mid-prose submits cleanly. So claude-code-review
#     is told to run `/code-review high` (model-invocable — no `disable-model-invocation`) and grok to
#     run `/pressure-test`; both fire reliably from a prose instruction (proven live). The roster is
#     Claude + Grok ONLY (maintainer decision 2026-07-07) — forge (Claude via ~/.forge/.forge.toml) is the default
#     implementation arm, grok-build/composer-fast the escalation arms. See drovr_dispatch_impl /
#     DL_IMPL_AGENT.
#  2. Triggers are SINGLE-LINE. herdr send-text + Enter treats an embedded newline as a submit,
#     so a multi-line trigger would fire half-typed. `$(_fill …)` strips the trailing newline;
#     the template bodies must each be exactly one physical line.
#
# Every fire goes through drovr_send (workspace-ownership guard). NEVER `herdr pane run` a
# reviewer pane directly here — that is exactly how a stray send leaked to a foreign room before.
. "$(dirname "${BASH_SOURCE[0]}")/bus.sh"
. "$(dirname "${BASH_SOURCE[0]}")/provision.sh"
_DROVR_TMPL="$(dirname "${BASH_SOURCE[0]}")/../templates"
_DROVR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # abs lib dir (for pane-side helpers like forge-pretrust.sh)

# _fill <template-file> : substitute {{VARS}} from DL_* env; echo result. `#` is the sed delimiter,
# safe because no substituted value contains `#` (paths, branch names, the target string). A caller
# overriding DL_GATE_STEP/DL_GATE_CONTRACT must likewise avoid `#`, `&`, and `\` in the gate text.
_fill() {
  sed -e "s#{{TASK}}#${DL_TASK}#g" -e "s#{{TARGET}}#${DL_TARGET}#g" \
      -e "s#{{REPO}}#${DL_REPO}#g" -e "s#{{REPO_PATH}}#${DL_REPO_PATH}#g" \
      -e "s#{{BRANCH}}#${DL_BRANCH}#g" -e "s#{{BUSDIR}}#${DL_BUSDIR}#g" \
      -e "s#{{ITERDIR}}#${DL_ITERDIR}#g" -e "s#{{WORKTREE_NAME}}#${DL_WORKTREE_NAME}#g" \
      -e "s#{{WORKTREE_STEP}}#${DL_WORKTREE_STEP}#g" -e "s#{{FEEDBACK_STEP}}#${DL_FEEDBACK_STEP}#g" \
      -e "s#{{WORKTREE_BASE}}#${DL_WORKTREE_BASE:-origin/main}#g" \
      -e "s#{{GATE_STEP}}#${DL_GATE_STEP}#g" -e "s#{{GATE_CONTRACT}}#${DL_GATE_CONTRACT}#g" "$1"
}

# _drovr_load_config : apply the target repo's .drovr/config — the repo's POLICY declaration
# (gate profile/strings, policy roster, worktree base, default arm/lens). Precedence matches the
# `:-` convention used everywhere else: caller env (non-empty) > config > built-in default, so a
# per-dispatch export still beats repo policy. The file is sourced in a SANDBOXED empty-env subshell
# and only whitelisted DL_* values are read back — a config cannot clobber task identity
# (DL_TASK/DL_REPO*/DL_BUSDIR) or anything else in the orchestrator shell. Values must be single
# physical lines (triggers are single-line; _fill sed also forbids `#`, `&`, `\` in gate text).
# It is repo-committed shell at the same trust level as .githooks: static assignments only.
_DROVR_CFG_VARS="DL_GATE_PROFILE DL_GATE_STEP DL_GATE_CONTRACT DL_WORKTREE_BASE DL_PLAN_FIRST DL_IMPL_AGENT DL_GROK_LENS DL_TIER"
_drovr_load_config() {
  local cfg="${DL_REPO_PATH:-}/.drovr/config" v val
  [ -n "${DL_REPO_PATH:-}" ] && [ -f "$cfg" ] || return 0
  while IFS='=' read -r v val; do
    [ -n "$v" ] || continue
    [ -n "${!v:-}" ] && continue          # caller env wins (non-empty, `:-` convention)
    export "$v=$val"
  done < <(
    env -i bash -c '. "$1" 2>/dev/null; for v in '"$_DROVR_CFG_VARS"'; do [ -n "${!v:-}" ] && printf "%s=%s\n" "$v" "${!v}"; done; true' _ "$cfg"
  )
  return 0
}

# _drovr_base_fetch <repo-path> <base> : echo the "git fetch -q <remote> <branch> && " prefix for a
# remote-qualified worktree base, or nothing for a local ref. The segment before the first slash counts
# as a remote ONLY if `git remote` lists it — a slash-y local branch (feat/x) is a local ref, not a
# fetch target. Always exits 0 (an unfetchable-but-listed remote still fails loudly in the pane cmd).
_drovr_base_fetch() {
  local rp="$1" base="$2"
  case "$base" in
    */*)
      case " $(git -C "$rp" remote 2>/dev/null | tr '\n' ' ') " in
        *" ${base%%/*} "*) printf 'git fetch -q %s %s && ' "${base%%/*}" "${base#*/}" ;;
      esac ;;
  esac
  return 0
}

# _drovr_set_ctx <task> : export the DL_* context for this repo + task. Used by BOTH dispatch and
# collect, so a reprompt on a fresh re-invoke (env not preserved) re-fills triggers identically.
# Needs cwd inside the repo (git rev-parse); a detached background shell should export DROVR_REPO_SLUG.
_drovr_set_ctx() {
  export DL_TASK="$1"
  export DL_REPO_PATH; DL_REPO_PATH="$(git rev-parse --show-toplevel)"
  export DL_REPO; DL_REPO="$(basename "$DL_REPO_PATH")"
  export DL_BRANCH; DL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  export DL_BUSDIR; DL_BUSDIR="$(bus_task_dir "$DL_TASK")"
  _drovr_load_config                     # repo policy (env > config > default; sandboxed)
  export DL_WORKTREE_BASE="${DL_WORKTREE_BASE:-origin/main}"
  export DL_TARGET="current branch ($DL_BRANCH) vs $DL_WORKTREE_BASE"
  # _fill references these impl/iter-only tokens for EVERY template. Default them empty here so a
  # review-stage / review-iter dispatch (which doesn't set them) doesn't trip `set -u` inside _fill
  # and emit an empty trigger. The impl/iter paths re-export real values AFTER calling this.
  export DL_ITERDIR="${DL_ITERDIR:-}"
  export DL_WORKTREE_NAME="${DL_WORKTREE_NAME:-}"
  export DL_WORKTREE_STEP="${DL_WORKTREE_STEP:-}"
  export DL_FEEDBACK_STEP="${DL_FEEDBACK_STEP:-}"
  export DL_GATE_STEP="${DL_GATE_STEP:-}"
  export DL_GATE_CONTRACT="${DL_GATE_CONTRACT:-}"
}

# _drovr_fire <pid> <label> <trigger> : deliver a trigger via drovr_send_prompt (send-text + a SEPARATE
# Enter) — NOT bundled `herdr pane run`, whose Enter gets absorbed into a long-text bracketed-paste pill,
# leaving the prompt UNSUBMITTED and the pane idle (observed live 2026-06-10). Then poll up to ~10s for the
# agent to start WORKING (return immediately once it does). If it's NOT detected working in 10s, send ONE
# discrete Enter — which submits a still-unsubmitted pill and is a HARMLESS NO-OP on an already-empty
# composer. This is deliberately NOT a re-send of the whole prompt: a full re-send DOUBLE-FIRED the LLM
# whenever _drovr_busy false-negatived a genuinely-working agent — the second copy landing ~10s later, and
# the model answering both (observed live 2026-06-25). The bare Enter can never double-send; drovr_send_prompt
# already makes the first Enter submit reliably, so the rare genuine miss is caught downstream by
# drovr_collect_one's file-sentinel reprompt (the real backstop). The "is it working?" check routes through
# _drovr_busy — agent_status for both Claude and grok panes (grok reliable since detection manifest
# ≥ 2026.07.03.1; see _drovr_busy for the verification record).
# FAIL-CLOSED on a DEAD PANE (added 2026-07-06 — a prompt was typed into a bare shell and forgotten,
# TWICE 06-24/07-06): _drovr_alive gates the send (no live agent → refuse BEFORE the prompt lands in zsh)
# and re-checks on the 10s-timeout path (agent died mid-fire → NOT DELIVERED). The pickup wait itself stays
# fail-open (a false-negative busy read must not double-fire; collect's sentinel is still the backstop).
# Returns: 3 = guarded send refused (cross-workspace); 4 = dead pane, trigger NOT delivered; 0 otherwise.
_drovr_fire() {
  local pid="$1" label="$2" trig="$3" t
  if ! _drovr_alive "$pid" "$label"; then
    echo "_drovr_fire: $label pane $pid has NO LIVE AGENT (bare/crashed shell?) — REFUSING to fire. Relaunch it (provision_role / _drovr_reset) and re-dispatch." >&2
    return 4
  fi
  drovr_send_prompt "$pid" "$trig" || return 3
  t=0
  while [ "$t" -lt 10 ]; do
    sleep 1; t=$((t+1))
    _drovr_busy "$pid" "$label" && return 0   # picked up (grok: rendered footer; claude: agent_status)
  done
  if ! _drovr_alive "$pid" "$label"; then
    echo "_drovr_fire: $label pane $pid lost its agent after send — trigger NOT DELIVERED. Relaunch and re-dispatch." >&2
    return 4
  fi
  echo "_drovr_fire: $label not detected working ~10s after send — discrete Enter (submit-pill guard, no re-send)" >&2
  drovr_assert_ours "$pid" && herdr pane send-keys "$pid" Enter >/dev/null   # submits a stuck pill; no-op on empty composer
  return 0
}

# drovr_dispatch_reviews <task> : write task.md, provision both reviewer panes, fire both PROSE
# triggers (guarded). Phase-1 MVP target = current branch vs main. Echoes the resolved pane ids.
drovr_dispatch_reviews() {
  _drovr_set_ctx "$1"
  _fill "$_DROVR_TMPL/task.md.tmpl" | bus_write "$DL_TASK" task.md >/dev/null
  echo "task.md written to $DL_BUSDIR/task.md"

  local pairs rid gid
  pairs="$(provision_reviewers)" || { echo "dispatch: provision failed" >&2; return 1; }
  rid="$(printf '%s\n' "$pairs" | sed -n 's/^claude-code-review=//p')"
  gid="$(printf '%s\n' "$pairs" | sed -n 's/^grok-pressure-test=//p')"

  # $(_fill …) strips the trailing newline → each trigger is delivered as a single line. _drovr_fire
  # confirms pickup + retries once (a trigger fired right after provision's /clear can be swallowed).
  _drovr_fire "$rid" claude-code-review      "$(_fill "$_DROVR_TMPL/trigger-review.txt")"   || { echo "dispatch: review trigger not delivered (workspace guard or DEAD PANE — see stderr)" >&2; return 3; }
  # Grok lens. DEFAULT = pane (grok-build's native /pressure-test in the resident pane) — SETTLED 2026-06-24:
  # it found a VERIFIED collections-balance bug that the opencode/grok-4.3 lens missed, both with my hand-written
  # prompt AND with the /pressure-test skill ported into opencode (the port lifted thoroughness but didn't
  # reproduce the bug-find). Set DL_GROK_LENS=opencode for the headless deep-reasoning lens (grok-review.sh writes
  # reviews/grok.md SYNCHRONOUSLY; tier1 -> grok-4.20-multi-agent — but that needs beta access, falls back to grok-4.3).
  if [ "${DL_GROK_LENS:-pane}" = opencode ]; then
    echo "grok lens: opencode (tier=${DL_TIER:-default} -> $([ "${DL_TIER:-}" = tier1 ] && echo grok-4.20-multi-agent || echo grok-4.3))"
    bash "$_DROVR_LIB/grok-review.sh" "$DL_TASK" reviews/grok.md "$DL_REPO_PATH" "$DL_TARGET" \
      || { echo "dispatch: grok-review helper failed" >&2; return 1; }
  else
    _drovr_fire "$gid" grok-pressure-test "$(_fill "$_DROVR_TMPL/trigger-pressure.txt")" || { echo "dispatch: pressure trigger not delivered (workspace guard or DEAD PANE — see stderr)" >&2; return 3; }
  fi
  echo "dispatched (guarded): claude-code-review=$rid grok-pressure-test=$gid"
}

# drovr_collect_one <task> <label> <relpath> <trigger-text> : return 0 once <relpath> is complete
# (sentinel present); if the pane reaches a RESTING state (idle/done/blocked) without a complete file
# it re-prompts the pane up to 2 times (partial/missing write → §15 verify-and-reprompt). A pane that
# is still 'working' is given more time, but bounded by an OVERALL wall-clock ceiling (SECONDS+300):
# a pane that never leaves 'working' returns 1 (STALLED) instead of spinning forever — this function
# is its own ceiling because drovr_collect_all runs on a DEADLINE re-invoke, AFTER the Task-7
# background poll has already exited (so the poll's ceiling no longer protects it). Resolves the pane
# from ONE workspace-scoped snapshot via here-strings (the `$(cmd | func)` setpgrp-flake guard) and
# re-prompts through drovr_send only. 'pstatus' not 'status' — 'status' is a read-only special var in zsh.
# The "still working → wait, don't reprompt" check routes through _drovr_busy (agent_status for both
# arms; grok reliable since detection manifest ≥ 2026.07.03.1, and grok busy also counts blocked/unknown
# so a dialog or detection gap is never reprompted into). bus_ready (the file sentinel) is still checked
# FIRST and is the authoritative completion signal.
drovr_collect_one() {
  local task="$1" label="$2" rel="$3" trigger="$4"
  local reprompts=0 id pstatus snap
  local deadline=$((SECONDS + 300))   # overall ceiling — a stuck 'working' pane returns 1 (STALLED)
  while [ "$SECONDS" -lt "$deadline" ]; do
    if bus_ready "$task" "$rel"; then return 0; fi
    snap="$(drovr_panes)"
    id="$(pane_id_for_label "$label" <<< "$snap" || true)"
    pstatus="$(pane_status_for_label "$label" <<< "$snap" 2>/dev/null || echo unknown)"   # for the log line
    if _drovr_busy "$id" "$label"; then sleep 3; continue; fi   # still reviewing — wait, don't reprompt
    if [ "$reprompts" -ge 2 ]; then break; fi                   # exhausted reprompts → STALLED
    if [ -n "$id" ]; then
      reprompts=$((reprompts+1))
      echo "reprompt $label ($reprompts/2): file not complete (status=$pstatus)" >&2
      drovr_send_prompt "$id" "$trigger" || return 3          # guarded reprompt (send-text + Enter)
      sleep 3
    else
      echo "$label pane gone; cannot reprompt" >&2; return 1
    fi
  done
  return 1   # ceiling hit or reprompts exhausted → caller escalates
}

# drovr_collect_all <task> : collect BOTH reviewers (reprompt-bounded each). Echoes one status line
# per reviewer ("<label> OK|STALLED"); returns 0 only if BOTH are OK. Re-establishes the DL_* context
# from <task> first so reprompt triggers re-fill identically on a fresh re-invoke. An overall wall-clock
# ceiling for a never-finishing 'working' reviewer is the caller's background poll (Task-7 DEADLINE).
drovr_collect_all() {
  local task="$1" rc=0
  _drovr_set_ctx "$task"
  if drovr_collect_one "$task" claude-code-review reviews/claude.md "$(_fill "$_DROVR_TMPL/trigger-review.txt")"; then
    echo "claude-code-review OK"
  else echo "claude-code-review STALLED"; rc=1; fi
  if drovr_collect_one "$task" grok-pressure-test reviews/grok.md "$(_fill "$_DROVR_TMPL/trigger-pressure.txt")"; then
    echo "grok-pressure-test OK"
  else echo "grok-pressure-test STALLED"; rc=1; fi
  return "$rc"
}

# drovr_escalate <task> <collect-output…> : human-readable escalation when a reviewer stalled.
# The orchestrator surfaces this to the human (with whatever landed) rather than hanging.
drovr_escalate() {
  local task="$1"; shift
  echo "⚠️  ESCALATION — review stage for task '$task' did not fully complete:"
  printf '%s\n' "$*"
  echo "Landed files:"; ls -1 "$(bus_task_dir "$task")/reviews" 2>/dev/null || true
  echo "Proceed with partial triage on what landed, or re-run after fixing the stalled reviewer."
}

# _drovr_set_ctx_impl <task> <iter> : impl/iteration context on top of _drovr_set_ctx. Run from the
# orchestrator's MAIN checkout — DL_REPO_PATH here is main; the impl pane discovers its OWN worktree path
# and echoes it into result.md (the orchestrator reads it back for the review dispatch). iter<=1 includes
# the EnterWorktree step; iter>=2 explicitly forbids re-entering (cannot create a worktree while in one)
# and points at the prior iteration's gate.md + triage.md as fix-this feedback.
_drovr_set_ctx_impl() {
  _drovr_set_ctx "$1"
  export DL_ITER="$2"
  export DL_WORKTREE_NAME="drovr-$1"
  export DL_ITERDIR; DL_ITERDIR="$(bus_iter_dir "$1" "$2")"
  # Gate is repo-specific. DL_GATE_PROFILE picks a GENERIC default pair: `rust` (DEFAULT — fmt+clippy),
  # `web` (pnpm install+tsc+vitest; the render-smoke a mechanical gate can't do stays an orchestrator
  # step, see SKILL.md step 5), or `python` (ruff+mypy+pytest). Repo-specific policy (extra oracles,
  # policy-checker agents) does NOT live here — it lives in the repo's .drovr/config as a full
  # DL_GATE_STEP/DL_GATE_CONTRACT override (see _drovr_load_config; e.g. the reference Rust consumer
  # carries its OpenAPI-drift oracle + five ADR checkers there). Either default is still overridable by exporting
  # DL_GATE_STEP / DL_GATE_CONTRACT explicitly before dispatch (must avoid `#`, `&`, `\` — _fill sed limits;
  # that's why the prose says "then", never `&&`). _drovr_set_ctx empties unset values, so :- here
  # re-applies the default on every impl dispatch (no cross-task leak).
  local _gate_step_default _gate_contract_default
  case "${DL_GATE_PROFILE:-rust}" in
    web)
      _gate_step_default="from the worktree root run pnpm -C web install --frozen-lockfile, then pnpm -C web check (tsc --noEmit), then pnpm -C web test (vitest run); all three must pass"
      _gate_contract_default="\`pnpm -C web install --frozen-lockfile\`; \`pnpm -C web check\` (tsc --noEmit); \`pnpm -C web test\` (vitest run)." ;;
    python)
      _gate_step_default="from the worktree root run ruff check ., then mypy ., then pytest; all three must pass"
      _gate_contract_default="\`ruff check .\`; \`mypy .\`; \`pytest\`." ;;
    *)
      _gate_step_default="cargo fmt --check, then cargo clippy --all-targets -- -D warnings; both must pass"
      _gate_contract_default="\`cargo fmt --check\`; \`cargo clippy --all-targets -- -D warnings\`." ;;
  esac
  export DL_GATE_STEP="${DL_GATE_STEP:-$_gate_step_default}"
  export DL_GATE_CONTRACT="${DL_GATE_CONTRACT:-$_gate_contract_default}"
  # DL_WORKTREE_STEP / DL_FEEDBACK_STEP are env-overridable (`:-`) so a workspace where EnterWorktree is
  # blocked (or where the base must differ from origin/main) can substitute a "branch in the current
  # checkout off <base>" instruction. _drovr_set_ctx emptied them above, so a pre-set env value survives
  # and is honored here; otherwise the original defaults apply unchanged.
  if [ "$2" -le 0 ]; then
    # plan phase (iter 0, via drovr_dispatch_plan): fresh worktree, no feedback yet.
    export DL_WORKTREE_STEP="${DL_WORKTREE_STEP:-}"
    export DL_FEEDBACK_STEP="${DL_FEEDBACK_STEP:-}"
  elif [ "$2" -le 1 ]; then
    if [ -f "$DL_BUSDIR/iter-0/plan.md" ]; then
      # plan-first task: the plan phase already created the worktree; iter-1 implements IN it,
      # bound to the human-approved plan (dispatch_impl refuses iter-1 until plan-approved.md exists).
      export DL_WORKTREE_STEP="${DL_WORKTREE_STEP:-You are already in the $DL_WORKTREE_NAME worktree from the plan phase — do NOT create or enter another worktree. }"
      export DL_FEEDBACK_STEP="${DL_FEEDBACK_STEP:-First read $DL_BUSDIR/iter-0/plan.md — the APPROVED implementation plan for this task. Implement per that plan; name any deviation from it in result.md. }"
    else
      export DL_WORKTREE_STEP="${DL_WORKTREE_STEP:-Call your EnterWorktree tool with name $DL_WORKTREE_NAME to enter a fresh worktree branched off $DL_WORKTREE_BASE. }"
      export DL_FEEDBACK_STEP="${DL_FEEDBACK_STEP:-}"
    fi
  else
    local prev; prev="$(bus_iter_dir "$1" "$(($2-1))")"
    export DL_WORKTREE_STEP="${DL_WORKTREE_STEP:-You are already in the $DL_WORKTREE_NAME worktree from the previous attempt — do NOT call EnterWorktree again. }"
    export DL_FEEDBACK_STEP="${DL_FEEDBACK_STEP:-First read $prev/gate.md and $prev/triage.md and fix every FAIL and every blocker they list. }"
  fi
}

# drovr_dispatch_impl <task> <iter> [brief] : write task.md + brief.txt (iter 1 only) + status.md,
# provision the impl pane, fire the iter-aware impl trigger (guarded). The brief is written RAW (never
# sed'd — markdown '#' headers would break the '#'-delimited _fill); task.md only references brief.txt.
drovr_dispatch_impl() {
  local task="$1" iter="$2" brief="${3:-}"
  _drovr_set_ctx_impl "$task" "$iter"
  # Plan-first gates (rc=5, fail CLOSED — added 2026-07-07, maintainer decision). The plan phase exists to PAUSE
  # for a human read of iter-0/plan.md; silently proceeding past it would defeat the checkpoint.
  if [ "$iter" = 1 ] && [ "${DL_PLAN_FIRST:-0}" = 1 ] && [ ! -f "$DL_BUSDIR/iter-0/plan.md" ]; then
    echo "dispatch_impl: DL_PLAN_FIRST=1 but no iter-0/plan.md — run drovr_dispatch_plan $task \"<brief>\" first" >&2; return 5
  fi
  if [ "$iter" = 1 ] && [ -f "$DL_BUSDIR/iter-0/plan.md" ] && [ ! -f "$DL_BUSDIR/plan-approved.md" ]; then
    echo "dispatch_impl: iter-0/plan.md exists but is not approved — human reviews the plan, then: touch $DL_BUSDIR/plan-approved.md" >&2; return 5
  fi
  if [ "$iter" -le 1 ]; then
    [ -n "$brief" ] && printf '%s\n' "$brief" > "$DL_BUSDIR/brief.txt"   # raw, atomic enough for a static brief
    _fill "$_DROVR_TMPL/task-impl.md.tmpl" | bus_write "$task" task.md >/dev/null
    echo "task.md + brief.txt written under $DL_BUSDIR"
  fi
  if [ "$iter" -le 0 ]; then
    status_set "$task" plan "$iter"
  else
    status_set "$task" impl "$iter"
  fi

  # Provision (which /clears a resting pane — a TASK-boundary reset) ONLY at iter 1. For iter>=2 the impl
  # pane must RETAIN its worktree + what it built (never clear mid-task, §15a) — resolve-and-fire WITHOUT
  # clearing. If the pane died mid-task we CANNOT recreate its worktree context → escalate, never silently
  # spawn a fresh pane that would (per the iter>=2 trigger) skip EnterWorktree and implement on main.
  # Implementor agent is selectable: DL_IMPL_AGENT=forge (DEFAULT) | composer-fast | grok-build | claude | grok.
  # The roster is Claude + Grok ONLY (the OpenAI arm was removed maintainer decision 2026-07-07 — an unknown value errors).
  # composer-fast + grok-build are HEADLESS grok arms (one-shot `grok -p -m <model>`), differing only by model;
  # forge is headless `forge -p` (the model behind it comes from ~/.forge/.forge.toml). All three are NOT
  # resident agents — each pane is a plain shell that self-provisions its worktree via a `git worktree add`
  # preamble. claude enters its worktree via the EnterWorktree TOOL (driven by a prose trigger); the legacy
  # `grok` arm uses a resident TUI + --worktree flag. forge is the DEFAULT impl arm (maintainer decision 2026-07-06);
  # grok-build / composer-fast are the ESCALATION arms.
  # All arms write the SAME gate.md + result.md bus contract, so review / triage / teardown stay arm-agnostic.
  # Shell-dispatched arms are discriminated below by an empty impl_trigger; the headless grok arms additionally
  # set $grok_model (the -m value), which routes them to the grok branch of the shell dispatch.
  local impl_label impl_trigger grok_model=""
  case "${DL_IMPL_AGENT:-forge}" in
    forge)  impl_label=forge-implementation;  impl_trigger= ;;   # DEFAULT — shell-dispatched below
    composer-fast) impl_label=grok-headless-implementation; impl_trigger=; grok_model=grok-composer-2.5-fast ;;
    # grok-build is a BACKCOMPAT ALIAS: upstream retired the grok-build model in 2026-07 (grok models
    # now lists grok-4.5 as the default; -m grok-build would error). Both names route to grok-4.5.
    grok-4.5|grok-build) impl_label=grok-headless-implementation; impl_trigger=; grok_model=grok-4.5 ;;
    grok)   impl_label=grok-implementation;   impl_trigger=trigger-impl-grok.txt ;;   # legacy resident-TUI arm
    claude) impl_label=claude-implementation; impl_trigger=trigger-impl.txt ;;
    *)      echo "dispatch_impl: unknown DL_IMPL_AGENT '$DL_IMPL_AGENT'" >&2; return 2 ;;
  esac
  local iid
  if [ "$iter" -le 1 ]; then
    iid="$(provision_role "$impl_label")" || { echo "dispatch_impl: provision failed" >&2; return 1; }
  else
    local snap; snap="$(drovr_panes)"                                   # one snapshot, then here-string (setpgrp-flake guard)
    iid="$(pane_id_for_label "$impl_label" <<< "$snap" || true)"
    [ -n "$iid" ] || { echo "dispatch_impl: impl pane gone mid-task — cannot recreate worktree context; escalate" >&2; return 1; }
  fi

  if [ -z "$impl_trigger" ]; then
    # Shell-dispatched arms (forge=DEFAULT, grok-headless): render the exec PROMPT to the bus, then send ONE shell line
    # to the (shell) pane. iter 1 self-provisions the worktree off origin/main; iter>=2 re-enters the SAME
    # persistent worktree (no resume — the prompt's FEEDBACK_STEP points the agent at the prior iter's
    # gate.md/triage.md to fix the diff cold, more robust than a "most-recent-session" assumption on a reused
    # pane). Delivery uses drovr_send (bundled pane run): a shell has no bracketed-paste-pill, so the
    # _drovr_fire/send_prompt path (a Claude-TUI workaround) does not apply. The pane shell evaluates
    # $(cat …) — kept literal here.
    # ponytail: `git worktree add` fails if the dir/branch already exists (re-run of the same task) — tasks
    # are uniquely named, so this is a non-issue; if you re-run a task, rm the stale worktree first.
    # Template: iter 0 (plan phase) renders the PLAN-ONLY prompt; iters >=1 the implementation prompt.
    local ptmpl=prompt-impl-shell.txt
    [ "$iter" -le 0 ] && ptmpl=prompt-impl-plan.txt
    _fill "$_DROVR_TMPL/$ptmpl" > "$DL_ITERDIR/impl-prompt.txt"
    local wt=".claude/worktrees/$DL_WORKTREE_NAME" cmd exec_cmd pf="$DL_ITERDIR/impl-prompt.txt"
    # fresh_wt: does THIS dispatch create the worktree? Plan phase (iter 0) and a plain iter-1 do;
    # an iter-1 AFTER a plan phase reuses the plan phase's worktree (creating again would fail).
    local fresh_wt=0
    if [ "$iter" -le 0 ] || { [ "$iter" -le 1 ] && [ ! -f "$DL_BUSDIR/iter-0/plan.md" ]; }; then fresh_wt=1; fi
    # DB-env scrub (2026-07-07 incident): the pane shell parks at repo root where direnv (.envrc) can export
    # a PRODUCTION DATABASE_URL; `just test` inherits it and its guard only greps ':5432/' — a Supabase URL
    # sails past, and a pace-b iter-2 cargo-test run seeded rows into prod that way. Strip both DB vars from
    # every headless impl exec: the isolated test recipe (:5433) provides its own URLs, so impl arms never
    # need ambient ones. Applies to forge AND the grok-headless arms (both run the gate's tests).
    local envscrub="env -u DATABASE_URL -u APP_DATABASE_URL"
    if [ -n "$grok_model" ]; then
      # grok headless (composer-fast=DEFAULT | grok-build): one-shot `grok -p`, prompt by flag, model by -m.
      # The PROMPT LEADS with the `/implement` skill command (by convention): `/implement --effort 3 <brief>` — the brief
      # FOLLOWS the command, never mixed mid-prose. NB two different "effort"s: `/implement --effort 3` is the
      # skill's REVIEWER COUNT (integer 1-5), NOT model reasoning effort. The CLI --effort flag is deliberately
      # omitted (no-op: both models report supports_reasoning_effort=false). --always-approve auto-approves all
      # tool exec (global permission_mode=always-approve too); NO pretrust step needed — verified 2026-06-23 that
      # --always-approve proceeds in an untrusted worktree path (with .mcp.json present) without a trust prompt,
      # unlike forge. iter 1 points grok at the worktree via --cwd; iter>=2 the shell already cd'd into it.
      # Plan phase (iter 0) sends the plain plan prompt — /implement is the WRONG skill for planning.
      local grok_lead="/implement --effort 3 "
      [ "$iter" -le 0 ] && grok_lead=""
      exec_cmd="$envscrub grok -p \"$grok_lead\$(cat '$pf')\" -m $grok_model --always-approve"
      # --cwd must be ABSOLUTE: the grok CLI errors "No such file or directory (os error 2)" on a
      # relative --cwd (bisected live 2026-07-09 on the cortex P2 run; same root cause as the
      # composer-fast --cwd bug noted earlier). $DL_REPO_PATH/$wt, never bare $wt.
      [ "$fresh_wt" = 1 ] && exec_cmd="$envscrub grok -p \"$grok_lead\$(cat '$pf')\" -m $grok_model --always-approve --cwd \"$DL_REPO_PATH/$wt\""
    else
      # forge (the only non-grok shell arm): headless single-shot via -p; prompt passed by flag; --agent forge
      # = the agent configured in ~/.forge/.forge.toml (the file is the only model/effort knob).
      # iter 1 sets the cwd with -C <wt>; iter>=2 the shell has already cd'd into the worktree.
      # Pre-trust the worktree's .mcp.json first (forge keys MCP trust by PATH, so a fresh worktree path
      # re-prompts even with identical content) so the headless run never blocks on the Accept/Reject prompt;
      # forge-pretrust.sh fails-safe to the prompt if it can't seed. iter>=2 reuses the already-trusted worktree.
      local pretrust="bash \"$_DROVR_LIB/forge-pretrust.sh\" \"$DL_REPO_PATH/$wt\" \"$DL_REPO_PATH\""
      exec_cmd="$pretrust; $envscrub forge -p \"\$(cat '$pf')\" --agent forge"
      [ "$fresh_wt" = 1 ] && exec_cmd="$pretrust; $envscrub forge -p \"\$(cat '$pf')\" -C \"$wt\" --agent forge"
    fi
    # ENOSPC guard (2026-07-07): prune the shared CARGO_TARGET_DIR's debug tree BETWEEN dispatches
    # when its volume runs low, instead of dying mid-gate. `;` not `&&` — the guard is fail-safe
    # (always exits 0) and must never gate the exec either way.
    local tguard="bash \"$_DROVR_LIB/target-guard.sh\";"
    if [ "$fresh_wt" = 1 ]; then
      # Worktree base comes from repo policy (DL_WORKTREE_BASE, default origin/main). Fetch first ONLY
      # when the segment before the first slash is an actual remote — a slash-y LOCAL branch (feat/x)
      # must not be misread as remote+branch (found by the cortex P2 run, 2026-07-09).
      local _base="$DL_WORKTREE_BASE" _fetch
      _fetch="$(_drovr_base_fetch "$DL_REPO_PATH" "$_base")"
      cmd="cd \"$DL_REPO_PATH\" && ${_fetch}git worktree add \"$wt\" -b \"worktree-$DL_WORKTREE_NAME\" \"$_base\" && $tguard $exec_cmd"
    else
      cmd="cd \"$DL_REPO_PATH/$wt\" && $tguard $exec_cmd"
    fi
    drovr_send "$iid" "$cmd" || { echo "dispatch_impl: $impl_label dispatch refused (workspace guard)" >&2; return 3; }
    echo "dispatched impl (guarded): $impl_label=$iid iter=$iter"
    return 0
  fi

  _drovr_fire "$iid" "$impl_label" "$(_fill "$_DROVR_TMPL/$impl_trigger")" \
    || { echo "dispatch_impl: impl trigger not delivered (workspace guard or DEAD PANE — see stderr)" >&2; return 3; }
  echo "dispatched impl (guarded): $impl_label=$iid iter=$iter"
}

# drovr_dispatch_plan <task> "<brief>" : plan-first phase (DL_PLAN_FIRST, 2026-07-07, maintainer decision). Runs the
# impl arm ONCE in plan-only mode as iter 0: it creates the task worktree, reads brief + real code, writes
# iter-0/plan.md (leading with the decisions a human may want to change) and STOPS — no code, no commits.
# Flow: dispatch_plan → poll iter-0/plan.md → orchestrator sanity-checks vs ADRs/brief + surfaces to the
# human → human `touch <bus>/plan-approved.md` → drovr_dispatch_impl <task> 1 (no brief re-pass needed;
# it auto-binds FEEDBACK_STEP to the approved plan and reuses the plan phase's worktree). dispatch_impl
# REFUSES iter-1 (rc=5) while a plan exists unapproved, and — under DL_PLAN_FIRST=1 — while no plan exists.
# Use when a slice has no plan-of-record or open high-impact decisions; skip when the brief already carries
# the decisions (a reviewed plan-of-record) — the checkpoint would be pure latency there.
# Shell arms only (forge default + grok-headless): resident TUI arms have no plan trigger wired.
drovr_dispatch_plan() {
  local task="$1" brief="${2:-}"
  case "${DL_IMPL_AGENT:-forge}" in
    forge|composer-fast|grok-build|grok-4.5) ;;
    *) echo "dispatch_plan: plan-first supports shell arms only (forge / grok-headless); DL_IMPL_AGENT='$DL_IMPL_AGENT'" >&2; return 2 ;;
  esac
  drovr_dispatch_impl "$task" 0 "$brief"
}

# drovr_dispatch_plan_tui <task> "<brief>" : INTERACTIVE plan phase (DL_PLAN_TUI, 2026-07-11, maintainer
# decision after the live issue-197 demo). Same bus contract as drovr_dispatch_plan — iter-0/plan.md +
# the plan-approved.md fail-closed gates are unchanged, and dispatch_impl iter-1 reuses the worktree
# exactly as after a headless plan — but the planner is a RESIDENT grok TUI in plan mode
# (`grok --permission-mode plan`) on a dedicated grok-plan-tui pane: mode-level plan enforcement plus a
# real approval UI. The orchestrator drives the keybar (send-text 'c'/'s'/'a', composer text + Enter) and
# reads the FULL plan from the bus mirror the template contracts — the TUI viewport is unreadable at
# length, and agent_status reads plain `idle` while the approval UI waits (both proven live 2026-07-11;
# poll with drovr_plan_tui_state, never agent-status). Yolo-within-plan is auto-enabled by sending
# "Ctrl+o" once the TUI is up — answering a permission prompt with "always approve" instead would EXIT
# plan mode (proven live; same global override as the --always-approve flag). Approval flips the session
# to always-approve: the template's no-implement clause covers that moment, and the orchestrator quits
# the session (/exit) after capturing the final mirror. Tier rules + the full orchestrator runbook live
# in SKILL.md. Headless (`grok -p`) plan mode remains broken upstream — it dies at the first interactive
# approval prompt — which is exactly why this variant is TUI-resident.
drovr_dispatch_plan_tui() {
  local task="$1" brief="${2:-}"
  _drovr_set_ctx_impl "$task" 0
  [ -n "$brief" ] && printf '%s\n' "$brief" > "$DL_BUSDIR/brief.txt"
  [ -f "$DL_BUSDIR/brief.txt" ] || { echo "dispatch_plan_tui: no brief (pass one, or pre-write brief.txt)" >&2; return 2; }
  _fill "$_DROVR_TMPL/task-impl.md.tmpl" | bus_write "$task" task.md >/dev/null
  status_set "$task" plan 0
  local iid; iid="$(provision_role grok-plan-tui)" || { echo "dispatch_plan_tui: provision failed" >&2; return 1; }
  _fill "$_DROVR_TMPL/prompt-impl-plan-tui.txt" > "$DL_ITERDIR/impl-prompt.txt"
  local wt=".claude/worktrees/$DL_WORKTREE_NAME" pf="$DL_ITERDIR/impl-prompt.txt"
  local _base="$DL_WORKTREE_BASE" _fetch; _fetch="$(_drovr_base_fetch "$DL_REPO_PATH" "$_base")"
  drovr_send "$iid" "cd \"$DL_REPO_PATH\" && ${_fetch}git worktree add \"$wt\" -b \"worktree-$DL_WORKTREE_NAME\" \"$_base\" && cd \"$wt\" && env -u DATABASE_URL -u APP_DATABASE_URL grok --permission-mode plan \"\$(cat '$pf')\"" \
    || { echo "dispatch_plan_tui: dispatch refused (workspace guard)" >&2; return 3; }
  # yolo-within-plan: wait for the resident grok to report in, then ONE Ctrl+o (herdr key name is
  # exactly "Ctrl+o" — C-o/ctrl-o/^O are rejected). Before grok is up the keypress would land in zsh
  # (a harmless accept-line), so gate on settle first; fail-open like every settle.
  _drovr_settle "$iid" 30000
  herdr pane send-keys "$iid" "Ctrl+o" >/dev/null 2>&1 || true
  echo "dispatched plan-tui (guarded): grok-plan-tui=$iid iter=0"
}

# drovr_plan_tui_state <task> : textual state of the plan-TUI pane. agent_status reads plain `idle`
# while the approval UI waits (proven 2026-07-11), so state MUST come from the pane text. Echoes
# APPROVAL (plan staged, keybar waiting) | WORKING | IDLE; rc=1 if no grok-plan-tui pane exists.
drovr_plan_tui_state() {
  local snap pid txt
  snap="$(drovr_panes)"
  pid="$(pane_id_for_label grok-plan-tui <<< "$snap" || true)"
  [ -n "$pid" ] || return 1
  txt="$(herdr pane read "$pid" --lines 25 2>/dev/null || true)"
  if grep -q "Waiting on plan approval" <<< "$txt"; then echo APPROVAL
  elif grep -qE "Thinking…|Responding…|Waiting for response" <<< "$txt"; then echo WORKING
  else echo IDLE; fi
}

# drovr_dispatch_review_iter <task> <iter> <worktree_path> : worktree-targeted two-lens review of the
# impl's committed branch, written into iter-<n>/reviews/. Each reviewer is handed its native skill plus
# the worktree LOCATION ({{BRANCH}} + {{REPO_PATH}}): claude-code-review runs `/code-review {{BRANCH}}`,
# grok runs `/pressure-test branch {{BRANCH}}` — both told "worktree at {{REPO_PATH}}". The skill owns the
# diff + the method (it reviews the named branch in that worktree vs main); the trigger only adds the bus
# write-back contract. {{BRANCH}} is the WORKTREE's checked-out branch (worktree-drovr-<task>), read from
# the worktree itself — NOT the orchestrator's HEAD (main), which is what _drovr_set_ctx defaults to.
drovr_dispatch_review_iter() {
  local task="$1" iter="$2" wt="$3"
  _drovr_set_ctx "$task"
  export DL_REPO_PATH="$wt"                                   # worktree, NOT the orchestrator's main checkout
  export DL_BRANCH; DL_BRANCH="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"   # the worktree's branch, not main
  export DL_WORKTREE_NAME="drovr-$task"
  export DL_TARGET="branch $DL_BRANCH vs $DL_WORKTREE_BASE (worktree $wt), review round $iter"
  export DL_ITERDIR; DL_ITERDIR="$(bus_iter_dir "$task" "$iter")"

  # Provision (which /clears resting reviewer panes — a TASK-boundary reset) ONLY at iter 1. For iter>=2 the
  # reviewers must RETAIN their prior-round findings (the "did my iter-1 blockers actually get fixed?" thread;
  # never clear mid-task, §15a) — reuse the warm panes WITHOUT clearing; recreate a lens only if it actually
  # died (a fresh reviewer can still review the iter-<n> diff cold). Here-string resolution (setpgrp-flake guard).
  local rid gid
  if [ "$iter" -le 1 ]; then
    local pairs; pairs="$(provision_reviewers)" || { echo "review_iter: provision failed" >&2; return 1; }
    rid="$(printf '%s\n' "$pairs" | sed -n 's/^claude-code-review=//p')"
    gid="$(printf '%s\n' "$pairs" | sed -n 's/^grok-pressure-test=//p')"
  else
    local snap; snap="$(drovr_panes)"
    rid="$(pane_id_for_label claude-code-review      <<< "$snap" || true)"
    gid="$(pane_id_for_label grok-pressure-test <<< "$snap" || true)"
    [ -n "$rid" ] || rid="$(provision_role claude-code-review)"       # recreate only if it actually died
    [ -n "$gid" ] || gid="$(provision_role grok-pressure-test)"
  fi

  _drovr_fire "$rid" claude-code-review      "$(_fill "$_DROVR_TMPL/trigger-review-iter.txt")"   || { echo "review_iter: review trigger not delivered (workspace guard or DEAD PANE — see stderr)" >&2; return 3; }
  # Grok lens (same switch as the review stage): DEFAULT pane = grok-build /pressure-test (settled 2026-06-24); DL_GROK_LENS=opencode for the deep-reasoning helper.
  # Helper reviews the WORKTREE branch ($wt) and writes iter-<n>/reviews/grok.md synchronously; collect sees it.
  if [ "${DL_GROK_LENS:-pane}" = opencode ]; then
    echo "grok lens: opencode (tier=${DL_TIER:-default} -> $([ "${DL_TIER:-}" = tier1 ] && echo grok-4.20-multi-agent || echo grok-4.3))"
    bash "$_DROVR_LIB/grok-review.sh" "$DL_TASK" "iter-$iter/reviews/grok.md" "$wt" "$DL_TARGET" \
      || { echo "review_iter: grok-review helper failed" >&2; return 1; }
  else
    _drovr_fire "$gid" grok-pressure-test "$(_fill "$_DROVR_TMPL/trigger-pressure-iter.txt")" || { echo "review_iter: pressure trigger not delivered (workspace guard or DEAD PANE — see stderr)" >&2; return 3; }
  fi
  echo "dispatched review (guarded): claude-code-review=$rid grok-pressure-test=$gid iter=$iter target=$wt"
}

# drovr_collect_iter <task> <iter> <worktree_path> : DEADLINE-branch collect for the iteration review —
# reprompt-bounded per reviewer (reuses drovr_collect_one with iter-pathed relpaths). Re-establishes the
# worktree-targeted context so a reprompt on a fresh re-invoke re-fills identically. Echoes "<label> OK|STALLED".
drovr_collect_iter() {
  local task="$1" iter="$2" wt="$3" rc=0
  _drovr_set_ctx "$task"; export DL_REPO_PATH="$wt" DL_WORKTREE_NAME="drovr-$task"
  export DL_TARGET="branch $DL_WORKTREE_NAME vs $DL_WORKTREE_BASE (worktree $wt), review round $iter"
  export DL_ITERDIR; DL_ITERDIR="$(bus_iter_dir "$task" "$iter")"
  if drovr_collect_one "$task" claude-code-review "iter-$iter/reviews/claude.md" "$(_fill "$_DROVR_TMPL/trigger-review-iter.txt")"; then
    echo "claude-code-review OK"; else echo "claude-code-review STALLED"; rc=1; fi
  if drovr_collect_one "$task" grok-pressure-test "iter-$iter/reviews/grok.md" "$(_fill "$_DROVR_TMPL/trigger-pressure-iter.txt")"; then
    echo "grok-pressure-test OK"; else echo "grok-pressure-test STALLED"; rc=1; fi
  return "$rc"
}

# drovr_gate_verdict <task> <iter> : echo PASS|FAIL parsed from iter-<n>/gate.md's machine line
# `GATE: PASS|FAIL` (the impl's gate output contract). Exit 1 if gate.md is not ready or has no GATE: line.
# Sentinel-gated via bus_read so a partial gate.md never yields a verdict.
drovr_gate_verdict() {
  bus_ready "$1" "iter-$2/gate.md" || { echo "drovr_gate_verdict: iter-$2/gate.md not ready" >&2; return 1; }
  local v; v="$(bus_read "$1" "iter-$2/gate.md" | sed -n 's/^GATE:[[:space:]]*//p' | tail -n 1)"
  case "$v" in
    PASS|FAIL) printf '%s\n' "$v" ;;
    *) echo "drovr_gate_verdict: no GATE: PASS|FAIL line in iter-$2/gate.md" >&2; return 1 ;;
  esac
}

# drovr_dispatch_teardown <task> : fire the teardown trigger to the impl pane (guarded). Only call AFTER
# approved.md is present (the human has merged-or-rejected). The impl pane (full-bypass, the worktree's
# creator) owns ExitWorktree(remove)+branch delete + the bus archive — the orchestrator never rm's.
drovr_dispatch_teardown() {
  local task="$1"
  _drovr_set_ctx "$task"
  export DL_WORKTREE_NAME="drovr-$task"
  export DL_ARCHIVE_DIR; DL_ARCHIVE_DIR="$(_bus_base)/.archive"
  # extend _fill at call-time via env for the two teardown-only tokens (ARCHIVE_DIR, reuse TASK/BUSDIR/WORKTREE_NAME)
  local trig; trig="$(sed -e "s#{{TASK}}#${DL_TASK}#g" -e "s#{{BUSDIR}}#${DL_BUSDIR}#g" \
      -e "s#{{WORKTREE_NAME}}#${DL_WORKTREE_NAME}#g" -e "s#{{ARCHIVE_DIR}}#${DL_ARCHIVE_DIR}#g" \
      "$_DROVR_TMPL/trigger-teardown.txt")"
  # Find whichever impl pane ran this task (grok-headless/forge are shell arms — the default + escalation).
  local snap iid label; snap="$(drovr_panes)"                 # one snapshot + here-string (setpgrp-flake guard)
  for label in grok-headless-implementation forge-implementation claude-implementation grok-implementation; do
    iid="$(pane_id_for_label "$label" <<< "$snap" || true)"
    [ -n "$iid" ] && break
  done
  [ -n "$iid" ] || { echo "teardown: no implementation pane found" >&2; return 1; }
  if [ "$label" = forge-implementation ] || [ "$label" = grok-headless-implementation ]; then
    # forge/grok-headless panes are shells with no ExitWorktree tool — remove the worktree + branch and archive the bus
    # directly (cd to root first: an iter>=2 shell sits INSIDE the worktree, which blocks its removal).
    local wt=".claude/worktrees/$DL_WORKTREE_NAME"
    drovr_send "$iid" "cd \"$DL_REPO_PATH\" && git worktree remove \"$wt\" --force && git branch -D \"worktree-$DL_WORKTREE_NAME\"; mkdir -p \"$DL_ARCHIVE_DIR\" && mv \"$DL_BUSDIR\" \"$DL_ARCHIVE_DIR/$DL_TASK-done\"" \
      || { echo "teardown: shell teardown refused (workspace guard)" >&2; return 3; }
    echo "teardown dispatched (guarded, shell pane) for $task"
    return 0
  fi
  # _drovr_fire (send-text + separate Enter, verify pickup) — same reason the other fires use it:
  # the bundled `pane run` can collapse a longer trigger into an unsubmitted paste pill.
  _drovr_fire "$iid" "$label" "$trig" || { echo "teardown: trigger not delivered (workspace guard or DEAD PANE — see stderr)" >&2; return 3; }
  echo "teardown dispatched (guarded) for $task"
}
