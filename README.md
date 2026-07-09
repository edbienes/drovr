# drovr

*A drover drives the herd. drovr drives your coding agents — down the trail, through the gate,
past two reviewers, and stops at your merge.*

A watchable, multi-agent dev loop that runs as a control room inside [herdr](https://herdr.dev).
An orchestrator agent dispatches an implementation brief to a coding agent in an isolated git
worktree pane, runs a repo-declared quality gate in that worktree, fans the branch out to two
independent review lenses (Claude `/code-review` + Grok `/pressure-test`), iterates on failure
(capped), and stops at a **human-gated merge**. All coordination happens over a plain
filesystem bus (`~/.drovr/<repo>/<task>/…`, sentinel `END-OF-FILE`) — pane state is used only
for delivery guarantees, never for task completion.

The harness is repo-agnostic: everything repo-specific (gate commands, policy-checker agents,
worktree base, default implementation arm) comes from the consumer repo's `.drovr/config`.

## Supported host

drovr runs **inside herdr** — herdr is a documented, version-bounded prerequisite, not an
abstraction target. Tested against **herdr 0.7.3** (protocol 16). The load-bearing host
contract (what a herdr version bump can break):

1. `HERDR_ENV=1` + `HERDR_PANE_ID` injected into every pane (identity + workspace-scoping root).
2. `pane list --workspace <ws>` returns only that workspace's panes (multi-workspace safety —
   drovr never touches the global pane list).
3. Long text must be sent as discrete `pane send-text` + `pane send-keys <pid> Enter`
   (`pane run` bundles Enter into one request and leaves an unsubmitted paste pill).
4. The submit key name is `Enter` — `send-keys Return` is a silent no-op.
5. `agent_status` (`idle|working|blocked|done|unknown`) is reliable for Claude panes and —
   with the Grok Build detection manifest ≥ **2026.07.03.1** (herdr#1055, auto-fetched;
   check `herdr server agent-manifests`) — for Grok panes too. The manifest version is part
   of this host floor (see `docs/upstream/grok-agent-status-false-idle.md`).
6. `pane split --no-focus` JSON shape (`result.pane.pane_id`), `pane rename`,
   `wait agent-status`.

Full inventory of every herdr call site: `docs/herdr-touchpoints.md`.

## Prerequisites

- herdr ≥ 0.7.3, running (`herdr status server`)
- [Claude Code](https://claude.com/claude-code) CLI, authenticated (orchestrator + review lens;
  also the default implementation arm via forge)
- Grok CLI (optional: `grok-pressure-test` review lens + grok implementation arms)
- bash ≥ 3.2, git ≥ 2.30

## Install

The repo **is** the install — no build step. Claude Code loads it as a user-scope skill:

```sh
git clone https://github.com/edbienes/drovr ~/.claude/skills/drovr
~/.claude/skills/drovr/test/run-tests.sh   # offline; stubs herdr — safe anywhere
```

> drovr was born as an internal harness called `devloop`; everything now uses the `drovr` name
> (skill, `~/.drovr/` bus, `.drovr/config`). The `DL_*` env prefix stays — read it as **D**rovr **L**oop.

## Adopt in a consumer repo

Commit a `.drovr/config` at the repo root — static single-line `KEY=value` assignments only
(it is sourced in a sandboxed empty-env subshell; only these keys are read back):

| Key | Purpose | Default |
|-----|---------|---------|
| `DL_GATE_PROFILE` | generic gate: `rust` (fmt+clippy), `web` (pnpm install+tsc+vitest), `python` (ruff+mypy+pytest) | `rust` |
| `DL_GATE_STEP` / `DL_GATE_CONTRACT` | full gate override (repo oracles, policy agents); no `#`, `&`, `\` | profile default |
| `DL_WORKTREE_BASE` | branch worktrees off this ref (`origin/main`, `feat/x`, …) | `origin/main` |
| `DL_IMPL_AGENT` | implementation arm (`forge`, `grok-4.5`, `composer-fast`, `claude`) | `forge` |
| `DL_PLAN_FIRST` | `1` = plan-only iter-0, human-approved plan gates iter-1 | off |
| `DL_GROK_LENS` / `DL_TIER` | review-lens/tier tuning | built-in |

Precedence: caller env (non-empty) > `.drovr/config` > built-in default. Optionally add
repo policy-checker subagents under `.claude/agents/` and reference them from `DL_GATE_STEP`.

Minimal example (Go repo):

```sh
# .drovr/config
DL_GATE_STEP='from the worktree root run go vet ./..., then go test ./...; both must pass'
DL_GATE_CONTRACT='`go vet ./...`; `go test ./...`.'
```

### Bring your own policy agents

Repo-specific invariants (architecture boundaries, tenancy rules, migration discipline — your
ADRs) are enforced by checker subagents that live in **your repo's** `.claude/agents/`, not in
drovr. Name them in your `DL_GATE_STEP` and the gate spawns them on the committed diff each
iteration. The reference Rust consumer rides five such checkers plus an OpenAPI-drift oracle
entirely from its own config — zero harness edits.

## Run

Inside herdr, open a Claude Code pane at the consumer repo root (this becomes the
orchestrator) and invoke the `drovr` skill with the task brief. The orchestrator provisions
the implementation/review panes, dispatches, gates, triages — and stops at triage; **merge is
always yours**.

## Threat model (read this before adopting)

drovr coordinates **unsandboxed** coding agents. Be honest with yourself about what that means:

- **Agents run as you.** Implementation and review panes are ordinary CLI agents with your
  user, your git credentials, your cloud CLIs, and whatever your shell profile / direnv
  exports. The gate and the two review lenses are quality nets, not security boundaries.
- **Environment leakage is the #1 real-world hazard.** A direnv-exported production
  `DATABASE_URL` once leaked into a test run and seeded a prod database. Shell-arm execs are
  now wrapped in `env -u DATABASE_URL -u APP_DATABASE_URL`; if your repo exports other
  dangerous variables, scrub them too — the harness cannot know their names.
- **Headless arms auto-approve.** The default implementation arm runs with permissions
  pre-trusted (the whole point of an unattended loop). Never point drovr at a repo whose
  gate or tests can reach production systems.
- **The merge is the security boundary.** Nothing drovr does mutates your main branch; the
  human merge gate is deliberate and non-negotiable. The orchestrator never `rm -rf`s —
  teardown archives by `mv`.
- **`.drovr/config` is repo-committed shell** at the same trust level as `.githooks`: it is
  sourced in a sandboxed empty-env subshell and only whitelisted `DL_*` keys are read back,
  but you should still review it in PRs like any executable file.
- **Pane operations are workspace-scoped.** Every live pane resolution/send is scoped to the
  orchestrator's own herdr workspace and cross-workspace sends are refused — a review once
  leaked into a foreign workspace's pane before this guard existed.

## Docs

- `SKILL.md` — the orchestrator playbook (the skill itself)
- `docs/herdr-touchpoints.md` — host contract + P3 inventory
- `docs/extraction-spec.md` — how this was extracted from its first consumer
- `lib/` — bus, provisioning, dispatch; `test/` — offline suite

## License

MIT — see `LICENSE`.
