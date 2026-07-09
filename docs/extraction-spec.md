# Devloop Extraction — Portable, Per-Repo, Eventually Open-Source

**Date:** 2026-07-09
**Status:** Spec — no code yet. This is its own project (not a rider on school-#2), per the round-8 conclusion in `2026-07-08-school2-python-mongo-stack-spec.md`.
**Goal:** devloop becomes a harness any repo can adopt by declaring its own policy, developed safely alongside live use, and hardened toward open-sourcing.

This spec will migrate to the extraction repo as its founding document once that repo exists; it is drafted here so it travels with the record of the debate that produced it.

## 1. Ground truth (inspected 2026-07-09)

- **The repo IS the live install.** `~/.claude/skills/devloop` is simultaneously the git repo and the deployed skill every session sources. There is no build/install step. Head is `878c98a`; the plan-first wiring (`devloop_dispatch_plan`/`DL_PLAN_FIRST`, suite 118/118) sits **uncommitted** in the working tree (`SKILL.md`, `lib/dispatch.sh`, `lib/provision.sh`, `test/dispatch_test.sh` modified; `lib/target-guard.sh`, `templates/prompt-impl-plan.txt` untracked). No remote — local history only.
- **State is already per-repo:** bus at `~/.devloop/<repo-slug>/<task>/`, worktrees per repo, Hindsight banks cwd-derived.
- **Policy is partly per-repo, partly baked in:**
  - `DL_GATE_PROFILE` seam exists (`dispatch.sh:205`): `rust` (default) and `web`. But the `rust` profile hardcodes super-school-rs policy — the five ADR-checker agents by name, the ADR-0002 OpenAPI drift oracle, `just gen-client`.
  - Worktree base hardcoded `origin/main` (`dispatch.sh:353`); known gap.
  - `DL_GATE_STEP`, `DL_WORKTREE_STEP` env overrides exist — the escape hatch that becomes the real seam.
  - Templates (`task-impl.md.tmpl` + executing-hard-tasks block, triggers) are user-scoped harness, correctly repo-agnostic.
  - Policy agents (`rls-tenant-checker`, `hex-boundary-checker`, …) live in the target repo's `.claude/agents/` — already the "bring-your-own-ADRs" shape; the gate just needs to read the roster from config instead of a baked-in list.

## 2. Target decomposition

**Portable core** (the harness): dispatch → worktree isolation → mechanical gate → two-lens adversarial review → weighted triage → human merge gate → teardown + memory. Plus the bus protocol, pane provisioning, fail-closed alive-checks, DB-env scrubbing, iteration caps, plan-first mode.

**Per-repo declaration** (the policy), read from a config file in the target repo — proposed `.devloop/config` (shell-sourceable, keeping bash-native; TOML is ceremony we don't need):

```sh
# .devloop/config — this repo's devloop policy
DL_GATE_PROFILE=rust                  # or: web, python, custom
DL_GATE_STEP="..."                    # full override when profile=custom
DL_POLICY_AGENTS="migration-reviewer rls-tenant-checker hex-boundary-checker auth-port-checker adr-compliance-reviewer"
DL_WORKTREE_BASE=origin/main          # unhardcodes dispatch.sh:353
DL_PLAN_FIRST=0                       # default; per-dispatch override still wins
```

Precedence: env var (per-dispatch intent) > `.devloop/config` (repo policy) > built-in default. Existing env-var behavior is unchanged — this is backward-compatible by construction; super-school-rs works identically before and after with an empty config.

The named profiles (`rust`, `web`, `python`) become *generic* — cargo fmt/clippy/test, pnpm lint/typecheck/test, ruff/mypy/pytest — and everything repo-specific (ADR checkers, OpenAPI drift oracle) moves into super-school-rs's own `.devloop/config` as `DL_GATE_EXTRA_STEPS` / `DL_POLICY_AGENTS`. The gate composes: profile steps + extra steps + policy-agent roster.

## 3. The live-install hazard and working protocol

The harness is shared, user-scoped, live tooling; other sessions run it while extraction proceeds. Rules:

1. **Never develop in `~/.claude/skills/devloop`.** Development happens in a separate clone (`~/Projects/Development/devloop`). The live path becomes a deploy target that only ever fast-forwards.
2. **Deploy = fast-forward at a quiet point**: no dispatch in progress (check `~/.devloop/*/` for active tasks / running panes), suite green in the dev clone first.
3. **Backward compatibility is a hard gate** per deploy: super-school-rs dispatches must behave identically with no `.devloop/config` present. The existing test suite is the oracle; extraction adds config-precedence tests.
4. Extraction work gets its own herdr workspace rooted at the dev clone — own Hindsight bank, no pollution of the super-school-rs bank.

## 4. Phases

- **P0 — Baseline (one quiet moment, ~minutes):** run the suite in the live repo; commit the pending plan-first WIP on top of `878c98a`. Nothing else starts until the live repo is clean.
- **P1 — Dev clone + config seam:** clone to `~/Projects/Development/devloop`; implement `.devloop/config` loading with the precedence above; unhardcode worktree base; genericize the `rust` profile and move super-school-rs specifics into a `.devloop/config` committed to super-school-rs. Suite extended for precedence + config parsing. Deploy via fast-forward; verify one real super-school-rs dispatch behaves identically.
- **P2 — Second consumer (proof of generality):** adopt devloop in a second real repo. The designated forcing function is school-#2 (`../super-school-py`, python profile) but it is gated behind the registrar worklist + quarter dates; if an interim proof is wanted sooner, any existing non-Rust repo (e.g. a small web/Node project) exercising `web` or a new profile via pure config counts. One full dispatch → gate → two-lens → triage cycle in that repo = P2 done.
- **P3 — The herdr question:** the biggest extraction unknown. Inventory every herdr touchpoint (provisioning, pane run/read, wait-sentinels, alive-checks, workspace scoping); decide runner-abstraction vs "herdr is a documented prerequisite" for v1. Strong prior from round 8: **v1 declares herdr a prerequisite** — abstracting the runner before a second runner exists is speculative generality. Revisit only when a concrete second runner (tmux? headless CI?) has a user.
- **P4 — OSS hardening:** fresh public repo with clean history (the private history contains client-specific briefs/paths). The hardening checklist IS the incident history: DB-env scrubbing (the prod-DATABASE_URL leak), workspace-scoped pane ops (the cross-workspace /review leak), alive-detection robustness (glob-eaten triggers, grok home-screen false-dead), the `--always-approve` permissions story, secrets/PII scan of templates. Plus: name, license (Ed decides), README with the honest threat model, and the "bring-your-own-ADRs" policy-agent docs.

P0+P1 are self-contained and safe to run in parallel with live super-school-rs work immediately. P2 partially gated (school-#2 path), P4 gated on Ed's naming/license/timing calls.

## 5. What "done" means

A repo adopts devloop by: installing the skill (user-scope), running herdr, and committing a `.devloop/config` + optional `.claude/agents/` policy roster. No devloop-core edits. Two dissimilar repos (Rust + non-Rust) demonstrably run the full cycle from pure config. Super-school-rs behavior byte-identical throughout.

## 6. Open questions (Ed)

1. Interim second consumer before school-#2 unparks, or wait for it?
2. Public repo name + license + timing for P4. **DECIDED 2026-07-09: name = `drovr`
   (drover, vowel-dropped to pair with herdr; npm/PyPI free, 1 trivial GitHub collision,
   drovr.dev registered-parked so repo/package name only), license = MIT.** Timing still open.
3. Does the extraction repo take over as source-of-truth immediately at P1 (live path = deploy target from then on)? (Recommended: yes.)
