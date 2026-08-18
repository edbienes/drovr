---
name: drovr
description: "Watchable herdr control-room dev loop: (review stage) fan a branch out to claude-code-review + grok-pressure-test and weight-triage; (implementation loop) dispatch a brief to a claude-implementation worktree pane, run an in-worktree gate (fmt+clippy+5 ADR-checkers) + the two-lens review, iterate on fail (cap 3), and stop at a human-gated merge. Use when running inside herdr as the claude-orchestrator pane to ship a non-trivial feature slice or multi-step code change — prefer this over inline single-session implementation. Not for trivial single-line edits, doc-only tweaks, or conversational turns."
when_to_use: "Reach for this on any non-trivial feature slice, vertical slice, or multi-step code change while in the herdr claude-orchestrator pane: it dispatches implementation to a worktree pane and runs the two-lens review loop before a human-gated merge. Skip it for one-line edits, doc-only changes, or conversational turns."
---

# drovr — review stage (orchestrator playbook)

Precondition: you are the orchestrator pane inside herdr (Claude or Grok). The bus is external:
`~/.drovr/<repo-slug>/<task>/` (absolute paths only). You never enter a worktree; you never
`rm -rf` (your pane is deny-ruled — clean up with `mv` to `~/.drovr/<repo>/.archive/`).
The MVP runs **two local model lenses** on the branch — Claude (claude-code-review, via `/code-review`)
+ Grok (grok-pressure-test, via `/pressure-test`). The **standing** roster is Claude + Grok (maintainer
decision 2026-07-07). The old OpenAI-CLI impl arm stays gone; do not add it back. GPT-5.6 Sol is
**on-demand only**, via `cursor-agent` (herdr `--kind cursor`) — see “On-demand cursor-agent seat”
below. It is not a third dual-lens and not a `DL_IMPL_AGENT`. Default impl is **grok-4.6**.
Forge is removed. No PR is opened —
Claude's PR-only built-in `/review` and its Phase-2/CI gate stay with the impl-loop build (§17).
MVP target = **current branch vs main**.

## Library
Source from `$DROVR_HOME` (plugin root, or `~/.claude/skills/drovr` on the clone fallback):
- `. lib/bus.sh`        → bus_task_dir, bus_write, bus_ready, bus_read  (sentinel = `END-OF-FILE`)
- `. lib/provision.sh`  → drovr_workspace_id, drovr_self_pane_id, drovr_panes / drovr_tabs
                          (workspace-scoped lists), drovr_send (GUARDED send), pane_id_for_label,
                          pane_status_for_label, provision_role, provision_reviewers
- `. lib/dispatch.sh`   → drovr_dispatch_reviews, drovr_collect_all, drovr_escalate

## Run the review stage on task <task> (target = current branch vs main)

1. **Provision (task boundary):** `provision_reviewers` — reuses ANY present, non-`working` pane
   (idle/done/blocked) and resets it (`_drovr_reset`: Claude panes `/exit`→`cd <repo root>`→relaunch,
   so a pane that hopped a worktree last task is back at the right tree; grok `/new`), or creates+launches
   one only when the pane is truly absent. Never duplicates a pane; never resets mid-iteration.
   Layout is **tabs in this workspace**, not a 2x2 split of tab `main`:
   ```
   tab main:            orchestrator only   (do not split this tab for seats)
   tab implementation:  impl / plan-tui     (split inside this tab if both)
   tab reviews:         claude-code-review | grok-pressure-test
   ```
   New seats: `tab create --no-focus` (or adopt/split inside an existing labeled tab). Never steal focus.
2. **Dispatch:** `drovr_dispatch_reviews <task>` — writes `task.md`, fires both **prose** triggers
   through `drovr_send`. claude-code-review runs `/code-review high` (review-only) and writes its findings
   to `reviews/claude.md`; grok runs `/pressure-test` and writes `reviews/grok.md`.
3. **Poll (background, never foreground):** start the dual-ready poll below as a background
   command. The harness re-invokes you on `BOTH-READY` or `DEADLINE`. See **After dispatch**.
```bash
# Slug guard (load-bearing): a detached background shell loses the repo cwd; an unpinned _bus_slug
# (git rev-parse) then collapses the path to ~/.drovr//… and the poll false-DEADLINEs while the
# reviews actually landed. Pin the slug BEFORE sourcing.
export DROVR_REPO_SLUG="<repo-slug>"
# Resolve the install you are running (plugin update vs clone). Do not hardcode ~/.claude/skills/drovr.
: "${DROVR_HOME:=${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-$HOME/.claude/skills/drovr}}}"
. "$DROVR_HOME/lib/bus.sh"
TASK="$1"
DEADLINE=$((SECONDS+600))                 # 10-min overall ceiling
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if bus_ready "$TASK" reviews/claude.md && bus_ready "$TASK" reviews/grok.md; then
    echo "BOTH-READY"; exit 0
  fi
  sleep 5
done
echo "DEADLINE"; exit 2
```
   Never append `; echo "EXIT=$?"` (it corrupts the re-invoke signal). Poll the FILES, never a pane
   sentinel match. Typical reviewer latency: grok ~135s; Claude `/code-review` similar (it
   fans out subagents over the diff).
4. **On re-invoke:** `BOTH-READY` → `bus_read` both review files. `DEADLINE` → `drovr_collect_all
   <task>` resolves per-reviewer state (reprompting an incomplete/missing file up to 2×); on any
   `STALLED` → `drovr_escalate <task> "<collect output>"` and surface to the human with what landed.
5. **Triage:** fill `templates/triage.md.tmpl` → `bus_write <task> triage.md`. Weight by mechanism
   strength + cost-to-defer; surface single-reviewer depth findings; do NOT vote-count. The
   claude-code-review file is the **Claude `/code-review`** lens; flag any stalled/partial lens.
6. **Human reads `triage.md`.** Merge is never automated — the review stage stops at triage.
7. **Cleanup (optional):** `mv ~/.drovr/<repo>/<task> ~/.drovr/<repo>/.archive/<task>-$$`.

## Workspace safety (non-negotiable)
A herdr server can host several workspaces (other sessions' rooms). NEVER resolve / `/clear` / close /
split a pane off the global `herdr pane list` (or `herdr tab list`). Every live resolution goes through
`drovr_panes` / `drovr_tabs` (scoped to our `drovr_workspace_id`, from `$HERDR_PANE_ID`); every send to
a reviewer pane goes through `drovr_send` (refuses a cross-workspace target, return 3); new role panes
land on a labeled tab in THIS workspace (`tab create --no-focus`, or adopt/split inside that tab).
Never split the orchestrator tab for a reviewer. A stray label match against a foreign room is how a
`/review` leaked before.

## After dispatch (sticky)

You own the wait. Do not stop and ask the human if a pane is done, idle, or blocked.
Do not wait on `herdr wait agent-status` / pane `done` for **completion** — that signal is
the bus file sentinel only (`END-OF-FILE`). Herdr does not inject a prompt into this pane
when another pane goes idle.

Immediately after every dispatch (reviews, impl iter, review-iter, plan-tui mirror), start
the matching bash poll as a **background** command, then yield.

- **Grok Build:** `run_terminal_command` with `background: true` (same poll script). When
  the poll exits, the harness notifies this conversation — that is the wake. Continue the
  playbook (`BOTH-READY` → read files; `DEADLINE` → collect / give more time / escalate).
- **Claude Code:** `run_in_background: true` on the same poll (same re-invoke contract).

Never run the poll in the foreground. Never skip it. If you compacted or lost the poll,
reconstruct from bus files (Resume below) and start a new background poll if work is
still in flight.

## Live-orchestration gotchas
- **Run live herdr orchestration under `bash -c`**, not the harness zsh — zsh intermittently aborts
  `$(cmd | shell_function)` with "failed to change group ID" (setpgrp/job-control under the harness).
  Capture ONE `snap="$(drovr_panes)"` then resolve with here-strings (`func <<< "$snap"`).
- **Pane ids are ephemeral** (`w…-N` renumbers on close) — resolve by **label** every time, never cache.
- **`status` is a read-only special var in zsh** — name shell locals `pstatus`.
- **Triggers are PROSE + SINGLE-LINE.** A *leading* slash command pushed through `herdr pane run` is
  mangled by the TUI autocomplete dropdown (a probed plugin slash command submitted as `/clear`); an
  embedded newline is treated as a submit. So the skill name sits **mid-prose**: claude-code-review is told
  to run `/code-review high` (model-invocable — no `disable-model-invocation`) and grok to run
  `/pressure-test`; both fire reliably from prose (proven live). Supply the target, never the methodology.

## Resume (after a background re-invoke or compaction)
State is the filesystem. Reconstruct position from which files exist in `~/.drovr/<repo>/<task>/`:
`task.md` only → reviews pending; one of `reviews/*` → still collecting; both `reviews/*` ready, no
`triage.md` → triage; `triage.md` present → done, await human. Re-resolve all pane ids by label.

## Scope (review stage)
Two local lenses (Claude `/code-review` + Grok `/pressure-test`) on a branch. Phase 2 (Claude built-in
`/review` on a draft PR + CI) and tiering by change risk are
later builds on this same dispatch→bus→triage mechanism (§17). The **implementation loop** (worktree
dispatch → in-worktree gate → review → iterate → human merge) is the branch-only MVP documented below.

## Implementation loop (branch-only MVP — builds on the review stage)

Same `dispatch→bus→triage` spine, with an implementation phase prepended and a gate + iterate-cap +
human-merge-gate appended. **You stay on `main`, never enter a worktree, never `rm`, never merge.** The
full-bypass implementation pane owns the worktree, the in-worktree gate, all git side-effects, and
teardown. Per-iteration bus subdirs (`iter-<n>/`) prevent stale-file false-ready across attempts.

**Implementor arm — `DL_IMPL_AGENT`** = `grok-4.6` (DEFAULT) | `claude` | `grok`. The only Grok model is **grok-4.6**. Stale names `grok-4.5`, `grok-build`, and `composer-fast` still dispatch, but they pin `-m grok-4.6`. **Forge is removed.** Any unknown `DL_IMPL_AGENT` value errors. Do not add `cursor` as an impl arm. Sol rides `cursor-agent` as an on-demand seat (below), not this switch.
All arms write the same `gate.md`+`result.md` bus contract. `grok-4.6` is a headless one-shot
`grok -p "/implement --effort 3 $(cat prompt)" -m grok-4.6 --always-approve` in a plain shell pane
(self-provision their worktree off the repo's DL_WORKTREE_BASE; iter 1 adds `--cwd <wt>`).
The prompt LEADS with the `/implement` skill command (never mid-prose).
`claude`/`grok` are resident-TUI arms. The Grok TUI also pins `-m grok-4.6`.

**Per-phase effort — `DL_PLAN_EFFORT` / `DL_IMPL_EFFORT` (2026-07-13, maintainer decision: plan
phases run the strongest reasoning, impl iters the cheap one — e.g. `DL_PLAN_EFFORT=xhigh` +
`DL_IMPL_EFFORT=low`).** Values `low|medium|high|xhigh`; an invalid value refuses the dispatch (rc=2)
BEFORE provisioning; unset knobs leave every arm at its own default.

*Grok arms* — a `--reasoning-effort` CLI flag on the launch/exec line (WIRED 2026-07-27; previously
omitted as a no-op, both reasons now expired: grok-4.5 reports `supports_reasoning_effort=true`, and
the flag works in the TUI as well as headless). Covers the headless impl arms, the plan-TUI
(`DL_PLAN_EFFORT`), and the legacy resident impl arm; the grok review lens is pinned at `high` by its
launch contract. Grok's menu is `low|medium|high`, so a shared `xhigh` pin **clamps to `high`**
(announced on stderr) instead of refusing — typos are still refused upstream. Unset = no flag at all,
so grok keeps its own default (`high`). NB this is a different knob from the `/implement --effort N`
that leads the grok impl prompt — that N is the skill's REVIEWER COUNT (1-5), not model effort.

**Gate profile — `DL_GATE_PROFILE`** = `rust` (DEFAULT) | `web` | `python`. Profiles are GENERIC
(2026-07-09 extraction P1): `rust` = fmt+clippy, `web` = `pnpm -C web install --frozen-lockfile` +
`pnpm -C web check` (tsc) + `pnpm -C web test` (vitest), `python` = ruff+mypy+pytest. Repo-specific
oracles live in the repo's `.drovr/config` (below), NOT here — e.g. the reference Rust consumer's OpenAPI-drift
check + five ADR checkers ride its config as a full `DL_GATE_STEP`/`DL_GATE_CONTRACT` override. The
render-smoke a mechanical gate can't do stays an orchestrator step (step 5).

**Per-repo policy — `<repo>/.drovr/config` (2026-07-09).** A repo declares its drovr policy in a
shell-sourceable config read by `_drovr_set_ctx`: whitelisted vars only (`DL_GATE_PROFILE`,
`DL_GATE_STEP`, `DL_GATE_CONTRACT`, `DL_WORKTREE_BASE`, `DL_PLAN_FIRST`, `DL_IMPL_AGENT`,
`DL_GROK_LENS`, `DL_TIER`, `DL_PLAN_EFFORT`, `DL_IMPL_EFFORT`), sourced in a sandboxed empty-env subshell (it cannot clobber task identity
or the orchestrator shell). Precedence: caller env (non-empty) > config > built-in default — a
per-dispatch export always beats repo policy. Values must be single physical lines avoiding `#`, `&`,
`\` (the `_fill` sed limits). `DL_WORKTREE_BASE` (default `origin/main`) sets what worktrees branch
off — both the EnterWorktree prose and the shell-arm `git worktree add`. No config file → built-in
defaults, byte-identical to pre-extraction behavior (guarded by the dispatch-test goldens).

**Plan-first — `DL_PLAN_FIRST` / `drovr_dispatch_plan_tui`.** For a slice with NO
plan-of-record or with open high-impact decisions, run a plan phase before any code.
`drovr_dispatch_plan` always refuses (rc=2) and points here — headless plan-first went with forge.
`drovr_dispatch_plan_tui <task> "<brief>"` creates the task worktree, launches resident grok-4.6
in plan mode, and mirrors `iter-0/plan.md`. Poll that file, sanity-check it against the brief + ADRs,
surface to the human; approval = `touch <bus>/<task>/plan-approved.md`; then
`drovr_dispatch_impl <task> 1` proceeds normally — it auto-binds the impl to the approved plan (via
FEEDBACK_STEP) and reuses the plan phase's worktree. Fail-closed gates
(rc=5): with `DL_PLAN_FIRST=1` exported, iter-1 refuses to dispatch until a plan exists; any existing
UNAPPROVED plan refuses iter-1 regardless of the flag. SKIP the plan phase when the brief already carries
the decisions from a reviewed plan-of-record.

**Interactive plan phase — `DL_PLAN_TUI` / `drovr_dispatch_plan_tui`.** Resident grok-4.6 TUI in plan
mode — real mode-level plan enforcement plus grok's native approval UI. Same bus contract: the plan mirrors to
`iter-0/plan.md`, `plan-approved.md` gates iter-1, and `drovr_dispatch_impl <task> 1` reuses the
worktree unchanged. Orchestrator runbook:
1. `drovr_dispatch_plan_tui <task> "<brief>"` — provisions a `grok-plan-tui` pane (shell-park label),
   creates the task worktree, launches `grok --permission-mode plan "$(cat prompt)"` in it, and
   auto-enables yolo-within-plan with ONE `Ctrl+o` (herdr key name is exactly `"Ctrl+o"`). NEVER answer
   a permission prompt with "always approve" — that flips the whole session OUT of plan mode (the
   interactive twin of the `--always-approve` flag override, proven live 2026-07-11).
2. Poll `drovr_plan_tui_state <task>` for `APPROVAL` — the pane's `agent_status` reads plain `idle`
   while the approval UI waits, so only the pane TEXT is trustworthy. The staged plan is mirrored to
   `iter-0/plan.md` by prompt contract (the TUI viewport is unreadable at length); verify the mirror's
   `END-OF-FILE` sentinel and mtime before triaging — a stale mirror means a revision wasn't flushed.
3. Triage the mirror against brief + ADRs, then drive the keybar with plain sends: `send-text 'c'` opens
   a line comment (type text, Enter saves; comments QUEUE), `send-text 's'` + Enter submits queued
   comments as a request-changes round (grok revises on WARM context and re-stages — the TUI's main win
   over headless), `send-text 'a'` approves (with any queued comments).
4. Approval authority is TIERED (maintainer decision 2026-07-11): tier 1 (DEFAULT) — surface the triage
   to the human and get their word before pressing `a`; tier 2 — for low-stakes slices (docs/tests/CI
   only; nothing touching money, migrations, RLS, or auth) the orchestrator triages and approves
   autonomously. When in doubt, tier 1.
5. ⚠️ Approval flips the session to `always-approve` — live execution rights. The prompt template pins
   "no implementation after approval", but do not linger: confirm the final mirror landed, `touch
   plan-approved.md`, `/exit` the grok session (pane back to shell), then `drovr_dispatch_impl <task> 1`.

Library additions (`. lib/dispatch.sh` / `. lib/bus.sh`):
`bus_iter_dir`, `status_set`/`status_get`, `drovr_dispatch_impl`, `drovr_dispatch_plan`,
`drovr_dispatch_plan_tui`, `drovr_plan_tui_state`, `drovr_dispatch_review_iter`, `drovr_collect_iter`,
`drovr_gate_verdict`, `drovr_dispatch_teardown`. Cap: `DROVR_ITER_CAP=3`.

### Run the implementation loop on task `<task>` with brief `<brief>`
1. **Dispatch impl (iter 1):** `drovr_dispatch_impl <task> 1 "<brief>"` — writes `task.md`+`brief.txt`+
   `status.md(phase=impl,iter=1)`, provisions `claude-implementation`, fires the impl trigger (EnterWorktree
   → implement → commit → in-worktree gate → `iter-1/gate.md` + `iter-1/result.md`).
2. **Poll (background, never foreground):** dual-ready on `iter-<n>/{result.md,gate.md}`.
   Start it as a background command (see **After dispatch**). Pin
   `DROVR_REPO_SLUG` before sourcing `bus.sh`. Re-invokes on `BOTH-READY` / `DEADLINE`.
```bash
export DROVR_REPO_SLUG="<repo-slug>"
: "${DROVR_HOME:=${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-$HOME/.claude/skills/drovr}}}"
. "$DROVR_HOME/lib/bus.sh"
TASK="$1"; N="$2"; DEADLINE=$((SECONDS+900))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if bus_ready "$TASK" "iter-$N/result.md" && bus_ready "$TASK" "iter-$N/gate.md"; then echo "BOTH-READY"; exit 0; fi
  sleep 5
done
echo "DEADLINE"; exit 2
```
   On `DEADLINE` resolve the impl pane: if `working`, give it more time (re-background the poll); if resting
   without the files, reprompt with `drovr_dispatch_impl <task> <n>` (no brief — task.md/brief.txt already
   exist) up to the cap, else escalate. **Iteration 1 is the slow one:** a fresh worktree off `origin/main`
   has a cold `target/`, so the first `cargo clippy --all-targets` + the 5 ADR-checker subagents routinely
   exceed the 900 s ceiling — a first `DEADLINE` while the pane is still `working` is normal cold-build
   latency, not a stall; just wait. Later iterations reuse the warm `target/` and finish far inside it.
3. **Read + route:** parse `WORKTREE:` from `iter-<n>/result.md` (the worktree abs path) and the verdict
   from `drovr_gate_verdict <task> <n>`.
4. **Review (worktree-targeted):** `drovr_dispatch_review_iter <task> <n> <worktree-path>`; start the
   dual-ready poll on `iter-<n>/reviews/{claude,grok}.md` as a background command (same poll shape
   as the review stage; see **After dispatch**). On
   `DEADLINE`, resolve each reviewer from ONE `drovr_panes` snapshot: a `working` pane just needs more time
   (re-background the poll); a *resting* pane with a missing/incomplete review file gets a single guarded
   reprompt — re-fill its iteration trigger and `drovr_send` it (the iter-aware trigger re-anchors a warm
   pane onto the CURRENT diff so it writes fresh findings, not a no-op repeat), then re-background the poll.
   This guarded single-lens reprompt is the path the acceptance proved. `drovr_collect_iter <task> <n>
   <worktree-path>` bundles the same reprompt-bounded loop for both lenses, but it BLOCKS foreground up to
   ~300 s/reviewer (its own ceiling) — past the Bash tool's 120 s default — so if you call it directly, pass
   an explicit long Bash `timeout` (≥ 660000 ms); on STALLED → `drovr_escalate`.
   **Optionally** run `cargo test` yourself (orchestrator) IFF the dev DB is up + migrated; else record
   "cargo test deferred to CI" in the triage. Triage → `bus_write <task> iter-<n>/triage.md` (weight by
   mechanism + cost-to-defer; surface single-reviewer depth; do not vote-count).
5. **Decide:**
   - `GATE: PASS` AND triage has no Blockers → **(web slices only)** first run a real render-smoke of the
     changed route(s): bring up the local stack and drive the route(s) via the playwright MCP. The mechanical
     gate (`DL_GATE_PROFILE=web`: tsc+vitest) AND both lenses are all blind to route-mount/render bugs — a
     dead route once shipped to prod that way (#164→#167). Then write a verdict line to `iter-<n>/triage.md`
     (`ready-for-human-merge`), set `status_set <task> done <n>`, and **surface to the human** (step 6).
   - `GATE: FAIL` OR triage has Blockers → if `<n> < DROVR_ITER_CAP`: `status_set <task> impl $((n+1))`
     and `drovr_dispatch_impl <task> $((n+1))` (no brief — the trigger auto-points the impl at
     `iter-<n>/gate.md` + `iter-<n>/triage.md` as fix-this feedback; it does NOT re-EnterWorktree). Loop to step 2 with `n+1`.
   - `<n> >= DROVR_ITER_CAP` and still failing → `drovr_escalate <task> "cap reached"` — surface what
     landed; the human takes over.
6. **Human-merge-gate (the only `main` mutation):** tell the human the branch is ready in the worktree
   (`WORKTREE:` path) with verdict `ready-for-human-merge`, naming the branch from `iter-<n>/result.md`'s
   `BRANCH:` line (EnterWorktree names it `worktree-drovr-<task>`, not `drovr-<task>`). The human merges
   it into `main` themselves (or rejects), then signals done by creating the marker:
   `touch ~/.drovr/<repo>/<task>/approved.md`.
7. **Teardown:** once `approved.md` exists, `drovr_dispatch_teardown <task>` — the impl pane
   `ExitWorktree(remove)` + branch delete + `mv`s the bus to `.archive/`. The orchestrator never `rm`s.

### Resume (after a background re-invoke or compaction)
State is the filesystem. `status_get <task> phase`/`iter` give the position; reconstruct the rest from which
`iter-<n>/` files exist (`gate.md`+`result.md` only → review pending; `reviews/*` → collecting; `triage.md`
+ verdict → awaiting human; `approved.md` at root → teardown). Re-resolve all pane ids by label (never cache).

### Worktree lifecycle (non-negotiable)
`EnterWorktree` once at task start (iter 1 only — the trigger omits it for iter≥2), iterate in place,
`ExitWorktree(remove)` once at teardown. Never re-enter/exit per iteration (cannot create a worktree while
in one). Mirror the "don't reset mid-task" rule — provision/`_drovr_reset` fires only at iter 1; iter≥2
reuses the warm impl + reviewer panes without resetting.

## On-demand cursor-agent seat (2026-08-17)

Standing loop is unchanged: Claude `/code-review` + Grok `/pressure-test`, then weighted triage.
GPT-5.6 Sol is **not** a third lens and **not** a `DL_IMPL_AGENT`. The orchestrator may spawn it
through **`cursor-agent`** (herdr `--kind cursor`) when a third family earns a turn.

**When to call**

- High-IQ second opinion on an open *decision* (prefer Sol when Grok planned), then re-lock.
- One logic/invariant audit when the two standing lenses **disagree**, or when Grok planned **and**
  implemented.
- Rare locked safety impl only if the consumer's cast says so. Do not make this the volume arm.

**When not to call**

- Every iter. Every docs/CI slice. As orchestrator. As a standing reviewer next to Claude+Grok.
- Via herdr `--kind` for the old OpenAI CLI, or with models `gpt-5.3-codex-*` / `cursor-grok-*` /
  `auto` (auto can pick Grok and collapse independence).

**Launch (workspace-scoped: land on a labeled tab in THIS workspace, never split tab `main`)**

```text
# Second opinion (read-only)
herdr agent start sol-second --kind cursor --pane <id> -- --model gpt-5.6-sol-high --mode plan --trust

# Disagree-audit (briefed report only; no --yolo / --force)
herdr agent start sol-audit --kind cursor --pane <id> -- --model gpt-5.6-sol-xhigh --trust

# Headless one-shot
cursor-agent -p --trust --mode ask --model gpt-5.6-sol-high "<audit brief>"
```

Ask Sol to write `iter-<n>/reviews/sol.md` (or `reviews/sol.md` on the review-only stage) with the
same `END-OF-FILE` sentinel. Weight it in triage like a single-reviewer depth finding — do **not**
vote-count three files. Poll that file; herdr's Cursor manifest often reports `blocked` while idle.

Do **not** pass `cursor-agent --worktree`. The task worktree is already drovr's. Do not add `cursor`
to `provision_reviewers` or `DL_IMPL_AGENT`.
