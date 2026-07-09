#!/usr/bin/env bash
# provision.sh — pane identity + room reconcile for the dev-loop control room.
# SOURCED by the orchestrator. Pane ids are ephemeral — always resolve by LABEL right before use.
#
# WORKSPACE SAFETY: a herdr server can host MULTIPLE workspaces (other sessions' control rooms).
# Every LIVE room query MUST be scoped to OUR workspace via `devloop_panes` so we never resolve,
# /clear, close, or split a pane that belongs to someone else's room. Resolution by label across
# the global `herdr pane list` is forbidden in live code — labels can collide across workspaces.

# devloop_workspace_id : echo THIS orchestrator's own workspace_id (derived from our pane).
# Requires HERDR_PANE_ID (set inside any herdr pane). Fails loudly if unset.
devloop_workspace_id() {
  herdr pane get "${HERDR_PANE_ID:?HERDR_PANE_ID unset — not inside a herdr pane}" \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["result"]["pane"]["workspace_id"])'
}

# devloop_self_pane_id : echo our own pane_id (the list-form id, e.g. w...-1) for splitting from us.
devloop_self_pane_id() {
  herdr pane get "${HERDR_PANE_ID:?HERDR_PANE_ID unset — not inside a herdr pane}" \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])'
}

# devloop_panes : `herdr pane list` SCOPED to our workspace only. Use this everywhere a live
# resolution is needed:  devloop_panes | pane_id_for_label claude-code-review
devloop_panes() {
  herdr pane list --workspace "$(devloop_workspace_id)"
}

# pane_in_list <pane_id> : read pane-list JSON on stdin; exit 0 iff <pane_id> is present.
# PURE (stdin) — fixture-testable. The membership primitive behind the workspace guard.
pane_in_list() {
  python3 -c '
import sys, json
target = sys.argv[1]
ids = {p.get("pane_id") for p in json.load(sys.stdin).get("result", {}).get("panes", [])}
sys.exit(0 if target in ids else 1)
' "$1"
}

# devloop_assert_ours <pane_id> : exit 0 iff <pane_id> belongs to OUR workspace.
# Builds the allowed set from devloop_panes (workspace-scoped), so a foreign pane id ALWAYS fails.
devloop_assert_ours() {
  local snap; snap="$(devloop_panes)"
  pane_in_list "$1" <<< "$snap"
}

# devloop_send <pane_id> <text...> : HARD-GUARDED send. Asserts the pane is in our
# workspace, THEN `herdr pane run`. Refuses (return 3) any cross-workspace target.
# EVERY live command to a claude or grok pane MUST go through this — never call
# `herdr pane run/send-text/send-keys` on a reviewer pane directly (a stray label
# match against another room's pane is how /review leaked to a foreign workspace before).
devloop_send() {
  local pid="$1"; shift
  devloop_assert_ours "$pid" || {
    printf 'devloop_send REFUSED: pane %s is not in our workspace (%s)\n' \
      "$pid" "$(devloop_workspace_id 2>/dev/null)" >&2
    return 3
  }
  herdr pane run "$pid" "$@" >/dev/null   # fire-and-forget; drop herdr's JSON ack (rc still propagates)
}

# devloop_send_prompt <pane_id> <text> : HARD-GUARDED delivery of a LONG prompt/trigger. Same workspace
# guard as devloop_send, but delivers the text and the submit Enter as TWO SEPARATE herdr requests
# (send-text, then send-keys Enter) instead of `herdr pane run` (which bundles them).
#   WHY (observed live 2026-06-10): `herdr pane run` = send-text + a bundled Enter in ONE request. For a
#   long trigger, Claude Code's TUI collapses the text into a bracketed-paste pill (`[Pasted text #N]`)
#   and the bundled Enter is ABSORBED into the paste stream rather than submitting — the prompt sits in
#   the composer UNSUBMITTED and the pane stays idle. (Flaky: a shorter/ faster trigger sometimes does
#   submit, which masked it.) Sending the text first, letting the paste register, then a DISCRETE
#   `send-keys Enter` reliably submits the pill (proven live on the stuck claude-code-review pane).
#   NB: herdr's key name is `Enter`, NOT `Return` (a `send-keys Return` is a silent no-op). Reset
#   commands (/new,/exit) go through devloop_send_slash below — the bundled `pane run` Enter was believed
#   dropdown-safe for short slash commands, but live (2026-06-2x, review-iter) the slash-autocomplete
#   dropdown CONSUMED the bundled Enter and /clear sat unsubmitted, wedging every later send.
devloop_send_prompt() {
  local pid="$1"; shift
  devloop_assert_ours "$pid" || {
    printf 'devloop_send_prompt REFUSED: pane %s is not in our workspace (%s)\n' \
      "$pid" "$(devloop_workspace_id 2>/dev/null)" >&2
    return 3
  }
  herdr pane send-text "$pid" "$*" >/dev/null   # text only — no Enter (becomes a paste pill if long)
  sleep 1                                        # let the (possibly bracketed-paste) text register
  herdr pane send-keys "$pid" Enter >/dev/null   # discrete Enter submits the pill (key is `Enter`)
}

# devloop_send_slash <pane_id> </command> : DROPDOWN-PROOF delivery of a leading-slash TUI command
# (/new, /exit — the reset verbs). Typing a leading slash arms the TUI's slash-autocomplete dropdown,
# which can CONSUME the submitting Enter (accepting the highlighted completion instead) — observed live:
# a /clear sat unsubmitted and every later send piled up behind the open dropdown (memory: review-iter
# delivery bug #2). Fix = devloop_send_prompt (send-text + discrete Enter) followed by a SECOND discrete
# Enter after a beat. IDEMPOTENT both ways: if Enter #1 submitted, #2 is a no-op on the empty composer;
# if the dropdown ate #1 (inserting the completion), #2 submits it. Never re-sends text, so it can never
# double-fire — same safety argument as _devloop_fire's bare-Enter retry. Only for TUI slash commands;
# plain shell lines stay on devloop_send.
devloop_send_slash() {
  local pid="$1" cmd="$2"
  devloop_send_prompt "$pid" "$cmd" || return 3
  sleep 1
  devloop_assert_ours "$pid" && herdr pane send-keys "$pid" Enter >/dev/null
}

# pane_id_for_label <label> : read `herdr pane list` JSON on stdin; echo matching pane_id (exit 1 if none).
pane_id_for_label() {
  python3 -c '
import sys, json
label = sys.argv[1]
panes = json.load(sys.stdin).get("result", {}).get("panes", [])
for p in panes:
    if p.get("label") == label:
        print(p.get("pane_id", "")); sys.exit(0)
sys.exit(1)
' "$1"
}

# pane_status_for_label <label> : echo agent_status for the labeled pane (idle/working/blocked/done/unknown).
pane_status_for_label() {
  python3 -c '
import sys, json
label = sys.argv[1]
panes = json.load(sys.stdin).get("result", {}).get("panes", [])
for p in panes:
    if p.get("label") == label:
        print(p.get("agent_status", "unknown")); sys.exit(0)
print("unknown"); sys.exit(1)
' "$1"
}

# _devloop_busy <pane_id> <label> : exit 0 iff the pane must NOT be fired into. Claude panes: agent_status
# is reliable ('working'). grok: agent_status is ALSO reliable since herdr's Grok Build detection manifest
# ≥ 2026.07.03.1 (herdr#1055 rewrote it for ≥0.2.8x chrome; verified live 2026-07-09 on 0.2.93:
# idle→working→blocked→idle all correct, working SUSTAINED across polls). The old footer scrape keyed on
# `Ctrl+c:cancel` is retired — in current chrome that string renders during working AND in the blocked
# dialog footer, so it was ambiguous. Grok busy = working OR blocked OR unknown: blocked stays busy because
# firing text into a waiting dialog corrupts it (the old scrape protected this by accident — keep it on
# purpose); unknown (detection gap / manifest regression) stays busy because busy is the LIBERAL/safe
# answer — both call sites take "busy" as "wait, don't re-deliver", and grok COMPLETION is always read from
# the report-file sentinel (bus_ready), never from this predicate, so a false-busy only costs a wait, never
# a missed result. Snapshot + here-string form → setpgrp-flake-safe.
_devloop_busy() {
  local pid="$1" label="$2"
  if [ "$label" = grok-pressure-test ]; then
    local snap st
    snap="$(devloop_panes)"
    st="$(pane_status_for_label "$label" <<< "$snap" 2>/dev/null || echo unknown)"
    [ "$st" = working ] || [ "$st" = blocked ] || [ "$st" = unknown ]
  elif [ "$label" = forge-implementation ] || [ "$label" = grok-headless-implementation ]; then
    # forge/grok-headless panes are shells, not agents — busy iff the headless exec process is running. Like
    # the grok branch this is LIBERAL (completion is read from the bus_ready result.md sentinel, never from here, so
    # a false-busy only costs a wait). ponytail: host-wide pgrep; scope to the worktree if loops overlap.
    local pat='forge -p'
    [ "$label" = grok-headless-implementation ] && pat='grok -p'
    pgrep -f "$pat" >/dev/null 2>&1
  else
    local snap; snap="$(devloop_panes)"
    [ "$(pane_status_for_label "$label" <<< "$snap" 2>/dev/null || echo unknown)" = working ]
  fi
}

# _devloop_alive <pane_id> <label> : exit 0 iff the pane hosts a LIVE agent (not a bare/never-launched/
# crashed-to-zsh shell). DISTINCT from _devloop_busy: busy = "actively working" (liberal, false-busy is
# safe); alive = "an agent is present at all" (callers FAIL CLOSED on dead, so only say dead when the agent
# is really absent). Added 2026-07-06 after a prompt was fired into a bare shell and forgotten — TWICE
# (06-24, 07-06). grok TUI panes: the rendered footer is the liveness signal — idle grok shows
# `Shift+Tab:mode │ Ctrl+.:shortcuts`, a working one `Ctrl+c:cancel`/`Ctrl+Enter:interject`/`⇣<n>`; a bare
# zsh renders none of these (grok's TUI leaves the screen with it). Claude panes: any real agent_status
# (working/idle/done/blocked…) — a shell pane reads 'unknown' from the snapshot. Shell-arm labels
# (forge/grok-headless) are plain shells BY DESIGN → always alive. Same setpgrp-flake-safe forms as
# _devloop_busy (external pipeline / snapshot + here-string).
_devloop_alive() {
  local pid="$1" label="$2"
  case "$label" in
    grok-pressure-test|grok-implementation)
      # PRIMARY: agent_status — reliable for grok since manifest ≥ 2026.07.03.1 (herdr#1055), and the
      # fresh-boot home screen now detects as `idle` (verified live 2026-07-09 on 0.2.93), so the old
      # home-screen false-dead is gone. Any real status = a live grok; a bare/crashed-to-zsh shell reads
      # `unknown`. FALLBACK on `unknown` only (alive FAILS CLOSED downstream, so a detection gap must not
      # brick dispatch): scrape chrome a bare zsh can't render — mid-session footer, streaming meter, or
      # the home-screen composer/banner. Deliberately NOT `always-approve`, which a crashed-to-shell pane
      # still shows in its typed launch command.
      local snap st
      snap="$(devloop_panes)"
      st="$(pane_status_for_label "$label" <<< "$snap" 2>/dev/null || echo unknown)"
      [ "$st" != unknown ] && return 0
      herdr pane read "$pid" --source visible 2>/dev/null \
        | grep -qE 'Shift\+Tab:mode|Ctrl\+\.:shortcuts|Ctrl\+c:cancel|Ctrl\+Enter:interject|⇣[0-9]|│ ❯|Grok Build +[0-9]'
      ;;
    forge-implementation|grok-headless-implementation)
      return 0 ;;
    *)
      local snap st
      snap="$(devloop_panes)"
      st="$(pane_status_for_label "$label" <<< "$snap" 2>/dev/null || echo unknown)"
      [ -n "$st" ] && [ "$st" != unknown ]
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Room reconcile (Task 5). herdr-side-effecting — verified by LIVE dry-run, not
# unit tests (you cannot fake a real pane split/clear).
#
# SHELL-FLAKINESS NOTE (discovered live): in this exec context `$( cmd | shell_function )`
# can intermittently abort the whole eval with "failed to change group ID"
# (zsh job-control setpgrp denied under the harness). External-only pipelines
# (`herdr … | python3`) and here-string forms (`func <<< "$var"`) are reliable.
# So we capture ONE snapshot via `snap="$(devloop_panes)"` then resolve with
# here-strings — never `$(printf … | pane_id_for_label …)`.
# ---------------------------------------------------------------------------

# Launch contracts per role (authoritative; maintainer decision 2026-06-15). Orchestrator (this pane) is never
# (re)launched here. Reviewers run at peak reasoning; implementors run a notch lighter.
#   - Claude reviewer:    --effort xhigh    Claude implementor:  --effort high
#   - grok reviewer:      grok --always-approve (NO launch --effort — a no-op here; see implementor note)
#   - grok implementor:   grok --always-approve (NO launch --effort, deliberately). Two independent reasons:
#                         (1) grok-build does NOT support reasoning effort (models_cache.json:
#                             supports_reasoning_effort=false — true for grok-build AND grok-composer-2.5-fast);
#                         (2) --effort is a HEADLESS-only flag — ignored with a warning in the interactive
#                             TUI a pane runs (docs/user-guide/14-headless-mode.md). The only depth knob is
#                         the /implement skill's `--effort N` (reviewer COUNT 1-5, a skill arg that works in
#                         the TUI), set in trigger-impl-grok.txt. Revisit if a reasoning-capable model lands.
# Worktree START differs by agent:
#   - Claude implementor: launch plain; the brief tells it to use the EnterWorktree TOOL at iter 1.
#   - grok implementor:   the worktree is created by the `--worktree=<name>` LAUNCH flag (grok has no
#                         EnterWorktree tool). The name is task-specific ($DL_WORKTREE_NAME, exported by
#                         _devloop_set_ctx_impl BEFORE provision_role runs), so it re-applies on the
#                         relaunch-reset reuse path too. ASSUMES grok's flag is `--worktree=<name>` and
#                         branches off the base/main — adjust this arm if your grok build differs.
# Selection between claude-/grok-implementation is the caller's (devloop_dispatch_impl via DL_IMPL_AGENT).
_devloop_launch_for() {
  case "$1" in
    claude-code-review)    printf '%s\n' 'claude --dangerously-skip-permissions --model opus --effort xhigh' ;;
    grok-pressure-test)    printf '%s\n' 'grok --always-approve' ;;
    claude-implementation) printf '%s\n' 'claude --dangerously-skip-permissions --model opus --effort high' ;;
    grok-implementation)   printf '%s\n' "grok --always-approve --worktree=${DL_WORKTREE_NAME:-devloop-impl}" ;;
    # forge/grok-headless aren't resident agents — each pane is a plain shell. "Launch" just parks it at
    # the repo root; the actual headless exec (and its worktree) is dispatched per-iter by devloop_dispatch_impl.
    forge-implementation|grok-headless-implementation)  printf '%s\n' "cd \"$(git rev-parse --show-toplevel 2>/dev/null || echo .)\"" ;;
    *) return 1 ;;
  esac
}

# _devloop_reset <pane_id> <label> : TASK-BOUNDARY context reset for a REUSED pane. grok: /new (its only
# reset — Grok Build has no /clear). Claude panes (claude-code-review / claude-implementation) may have
# HOPPED a worktree on the prior task, and /clear is NOT a sufficient reset there: it keeps the pane's cwd
# + project-dir transcript keying, so a pane stranded in a stale worktree would review/build the WRONG tree
# (cost a false-alarm + a ~10-min branch-restoration ghost-chase live; also leaves the impl pane unable to
# EnterWorktree, since you cannot nest worktrees). Full reset = leave the session, cd back to the
# repo root, relaunch:  /exit → cd "$root" → <_devloop_launch_for>. `cd "$root"` is QUOTED so a bitten
# pane can never be left in a stale worktree even when repo paths contain spaces. Repo
# root is the orchestrator's own checkout
# (git toplevel; DL_REPO_PATH/$PWD fallback). Unlike the old /clear, the relaunch makes a REAL absent→idle
# transition, so the caller's _devloop_settle is a genuine wait again. Slash commands (/new, /exit) go
# through devloop_send_slash (dropdown-proof: send-text + Enter + idempotent Enter — the bundled `pane run`
# Enter was consumed by the slash-autocomplete dropdown live); plain shell lines stay on devloop_send.
# grok-IMPLEMENTATION (unlike grok-pressure-test) deliberately falls through to the RELAUNCH path, not /new:
# its worktree comes from the --worktree launch flag, so reuse must re-launch to re-apply it for the new
# task. ASSUMES grok quits to the shell on `/exit` (the relaunch path's quit verb) — if your grok build
# quits differently, special-case grok-implementation here with its real quit command.
_devloop_reset() {
  local id="$1" label="$2" root
  if [ "$label" = grok-pressure-test ]; then
    devloop_send_slash "$id" '/new' || return 3   # dropdown-proof (send-text + Enter + idempotent Enter)
    sleep 3   # head-start only; /new doesn't move agent-status — _devloop_fire confirms trigger pickup
    return 0
  fi
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"; root="${root:-${DL_REPO_PATH:-$PWD}}"
  if [ "$label" = forge-implementation ] || [ "$label" = grok-headless-implementation ]; then
    # forge/grok-headless panes are stateless shells — the prior task's worktree may already be torn down, so
    # just cd back to repo root (the per-iter dispatch re-creates/re-enters the worktree). No /exit, no relaunch.
    devloop_send "$id" "cd \"$root\"" || return 3
    return 0
  fi
  devloop_send_slash "$id" '/exit'  || return 3   # leave the (possibly stale-worktree) Claude session — dropdown-proof
  sleep 4                                          # let the TUI quit back to the shell before typing cd
  devloop_send "$id" "cd \"$root\"" || return 3   # back to repo root — QUOTED (repo paths contain spaces)
  sleep 1
  devloop_send "$id" "$(_devloop_launch_for "$label")" || return 3   # relaunch (same contract as fresh launch)
  _devloop_settle "$id" 30000                 # real absent→idle wait (relaunch boots the agent)
}

# _devloop_settle <pane_id> [timeout_ms] : after a /clear|/new reset (or a fresh launch), block until
# the agent reaches a resting agent-status before the caller fires the trigger. Do NOT match the prompt
# GLYPH in output: a Claude Code prompt is U+276F (❯), not '>', so `wait output --match ">"` matched
# stale SCROLLBACK and returned instantly — the trigger then fired while /clear was still processing and
# got swallowed, leaving the reviewer idle at an empty prompt with the review never running (surfaced
# live in the review stage). `wait agent-status --status idle` keys on the agent's real state instead.
# The brief pre-sleep lets the reset begin so we don't sample the as-yet-unchanged pre-reset 'idle'.
# Fail-open (|| true): if status never settles within the ceiling we proceed anyway, exactly as before.
_devloop_settle() {
  sleep 1
  herdr wait agent-status "$1" --status idle --timeout "${2:-15000}" >/dev/null 2>&1 || true
}

# Split ANCHOR + direction for a newly-created pane: "<anchor-label> <right|down>".
# A new role pane is split from its anchor so roles land in predictable slots — a 2x2 room:
#     claude-orchestrator   | claude-code-review
#     claude-implementation | grok-pressure-test
# (each agent's reviewer sits to its right). If the anchor pane is missing, provision_role
# falls back to the orchestrator pane (always present — it's us).
_devloop_anchor_for() {
  case "$1" in
    claude-code-review)      printf '%s\n' 'claude-orchestrator right' ;;
    grok-pressure-test) printf '%s\n' 'claude-implementation right' ;;
    *)                  printf '%s\n' 'claude-orchestrator down' ;;
  esac
}

# _devloop_reusable <agent_status> : exit 0 iff a PRESENT pane in this status can be reset+reused
# instead of recreated. Only an actively 'working' pane is non-reusable (busy → escalate); every
# resting state (idle/done/blocked/unknown) is reusable. Reusing only on 'idle' was a bug surfaced
# live: a pane that just finished a turn reports 'done', and would be wrongly treated as dead →
# a DUPLICATE pane gets split next to it. Anything that isn't mid-task is a safe reset+reuse target.
_devloop_reusable() {
  case "$1" in
    working) return 1 ;;
    *)       return 0 ;;
  esac
}

# provision_role <label> : ensure a ready pane labeled <label> exists running the right agent.
# Reuse if idle+present (and reset it — TASK BOUNDARY, spec §15a); else (re)create.
# Echoes the pane id. Does NOT reset mid-task — only call at task start.
provision_role() {
  # NB: 'status' is a read-only special var in zsh (aliases $?), so we use 'pstatus'.
  local label="$1" snap id pstatus
  snap="$(devloop_panes)"   # SCOPED to our workspace — single-command subst (reliable)
  id="$(pane_id_for_label "$label" <<< "$snap" || true)"             # here-string, no $(|func)
  pstatus="$(pane_status_for_label "$label" <<< "$snap" 2>/dev/null || echo unknown)"

  if [ -n "$id" ] && _devloop_reusable "$pstatus"; then
    # Guarded task-boundary reset (grok: /new + head-start; claude: /exit→cd root→relaunch + real settle).
    # _devloop_fire still verifies trigger pickup and re-sends once if a fire races the reset.
    _devloop_reset "$id" "$label" || return 3
    printf '%s\n' "$id"; return 0
  fi

  if [ -n "$id" ]; then   # present but actively working → don't reuse, don't duplicate; escalate
    printf 'provision_role: %s is BUSY (working) — not reused; escalate.\n' "$label" >&2
    return 2
  fi

  # absent or dead/unknown → create a fresh pane in OUR workspace, split from the role's
  # anchor pane for a predictable layout. Anchor is resolved from our scoped snapshot;
  # if it's missing (or somehow not ours) we fall back to the orchestrator pane (us).
  local anchor_spec anchor_label anchor_dir anchor_id newid launch
  anchor_spec="$(_devloop_anchor_for "$label")"
  anchor_label="${anchor_spec%% *}"; anchor_dir="${anchor_spec##* }"
  anchor_id="$(pane_id_for_label "$anchor_label" <<< "$snap" || true)"
  if [ -z "$anchor_id" ] || ! devloop_assert_ours "$anchor_id"; then
    anchor_id="$(devloop_self_pane_id)"   # fallback: orchestrator is always present + ours
  fi
  newid="$(herdr pane split "$anchor_id" --direction "$anchor_dir" --no-focus \
            | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
  herdr pane rename "$newid" "$label" >/dev/null 2>&1   # drop rename JSON ack (would pollute return value)
  launch="$(_devloop_launch_for "$label")" || { echo "no launch contract for $label" >&2; return 1; }
  devloop_send "$newid" "$launch" || return 3   # guarded: new pane is ours by construction (self-split)
  _devloop_settle "$newid" 30000   # wait for the fresh agent to come up to idle (agent-status, not a glyph)
  printf '%s\n' "$newid"
}

# provision_reviewers : ensure both reviewer panes are ready; echo "label=id" lines.
provision_reviewers() {
  local L id
  for L in claude-code-review grok-pressure-test; do
    id="$(provision_role "$L")" || { echo "provision FAILED for $L" >&2; return 1; }
    printf '%s=%s\n' "$L" "$id"
  done
}
