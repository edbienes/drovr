# herdr touchpoints — P3 inventory freeze (2026-07-09)

P3 deliverable of the extraction spec. Posture for OSS v1: **herdr is a documented,
version-bounded prerequisite** — no runner abstraction, no plugin packaging, no upstream
feature dependency. Herdr I/O stays collocated but unabstracted; task completion stays on
the filesystem bus. Full decision record: `docs/superpowers/specs/2026-06-25-grok-consult.md`
lineage → maintainer consult 2026-07-09.

## Live invocation inventory

Every executable `herdr` call in the codebase. Verified 2026-07-09: **zero** herdr calls in
`bus.sh`, `grok-review.sh`, `forge-pretrust.sh`, `target-guard.sh`, or any template; SKILL.md
mentions are prose/safety rules only.

| # | Site | Command | Purpose | Test coverage |
|---|------|---------|---------|---------------|
| 1 | `provision.sh:13` `drovr_workspace_id` | `pane get $HERDR_PANE_ID` | own workspace id — the scoping root | env-contract; fails loudly if unset |
| 2 | `provision.sh:19` `drovr_self_pane_id` | `pane get $HERDR_PANE_ID` | own pane id (split anchor fallback) | same |
| 3 | `provision.sh:26` `drovr_panes` | `pane list --workspace <ws>` | the ONLY sanctioned pane list (workspace-scoped) | fixture `pane_list_scoped.json` |
| 4 | `provision.sh:59` `drovr_send` | `pane run` | guarded short-trigger fire (refuses cross-workspace, rc 3) | `herdr()` shell stub |
| 5 | `provision.sh:82` `drovr_send_slash` | `pane send-text` | long/slash text, no Enter (paste-pill semantics) | stub counts 1 text send |
| 6 | `provision.sh:84` `drovr_send_slash` | `pane send-keys <pid> Enter` | discrete submit (key name is `Enter`, NOT `Return`) | stub counts exactly 2 Enters |
| 7 | `provision.sh:100` | `pane send-keys <pid> Enter` | unstick a bracketed-paste pill | grep-pinned |
| 8 | `_drovr_busy` (grok arm) | `pane list --workspace` (status) | busy = `agent_status` ∈ working/blocked/unknown (reliable since grok manifest ≥ 2026.07.03.1, herdr#1055; verified live 2026-07-09 on 0.2.93) | functional stubs |
| 9 | `_drovr_alive` (grok arm) | `pane list --workspace` + `pane read` fallback | alive = any real `agent_status`; chrome scrape kept ONLY as the `unknown` fallback (fail-closed callers) | grep-pinned fallback |
| 10 | `provision.sh:282` `_drovr_settle` | `wait agent-status --status idle` | post-`/clear` settle before fire (`wait output` glyph-match is FORBIDDEN — test asserts its absence) | grep-pinned |
| 11 | `provision.sh:343` `provision_role` | `pane split --no-focus` | create role pane from its anchor (JSON → `result.pane.pane_id`) | LIVE dry-run only |
| 12 | `provision.sh:345` `provision_role` | `pane rename` | label the role pane | LIVE dry-run only |
| 13 | `dispatch.sh:132` `_drovr_fire` | `pane send-keys <pid> Enter` | retry-submit a stuck pill on delivery retry | grep count == 1 |

Indirect consumption (no direct call, reads `drovr_panes` JSON): `pane_id_for_label`,
`pane_status_for_label`, and the claude branches of `_drovr_busy`/`_drovr_alive` consume
`pane_id`, `label`, and the `agent_status` enum (`idle|working|blocked|done|unknown`).

**Grok step-1 verdict: PASS.** All herdr I/O already lives in `provision.sh` plus one line in
the fire path (`dispatch.sh:132`). Nothing to move; do NOT invent a `dl_runner_*` API.

## The actual host contract (what a herdr version bump can break)

The coupling is semantics, not CLI shape:

1. `HERDR_ENV=1` + `HERDR_PANE_ID` injected into every pane (identity + scoping root).
2. `pane list --workspace` returns only that workspace's panes (cross-workspace safety).
3. `pane run` = send-text + bundled Enter in ONE request → long text becomes an UNSUBMITTED
   paste pill. Discrete `send-text` then `send-keys Enter` is the only reliable long-text path.
4. Key name is `Enter`; `send-keys Return` is a silent no-op.
5. `agent_status` is reliable for Claude panes AND (since detection manifest ≥ 2026.07.03.1,
   herdr#1055) for Grok Build panes — verified live 2026-07-09 on 0.2.93 through
   idle→working→blocked→idle including the fresh-boot home screen. The manifest version is
   part of the host floor; a chrome scrape survives only as `_drovr_alive`'s unknown-fallback.
6. `pane read --source visible` renders the current viewport (the scrape substrate).
7. `pane split` JSON shape (`result.pane.pane_id`); `pane rename`; `wait agent-status`.

Completion is NEVER read from any of the above: task/review completion comes only from bus
file sentinels (`result.md` / `gate.md` / `reviews/*.md` + END-OF-FILE). Pane state is used
solely for delivery guarantees (don't fire into a dead shell, detect pickup, reprompt vs stall).

## Deliberately deferred (kept open, not built)

- **(b) runner seam**: the collocated layer above IS the latent seam. Extract it when a second
  host has a real user, not before.
- **(c) herdr plugin**: herdr has a plugin system (`herdr plugin install/link/action`), verified
  2026-07-09. Optional later as distribution sugar that installs/links the skill — never the
  product home (plugins don't absorb alive-detection/scoping/send semantics).
- **(d) upstream**: file sharp repro'd issues for grok false-idle and home-screen false-dead;
  reliability lobbying only, never a roadmap dependency.

## Foreclosure check (done 2026-07-09)

Skimmed the plugin surface (herdr 0.7.3 CLI + docs + `ogulcancelik/herdr-plugin-examples`:
`agent-telegram-notify` JS, `dev-layout-bootstrap` Lua, `github-link-preview` Bash,
`rust-release-check` Rust; all require herdr ≥ 0.7.0).

**Decision: drovr is NOT a herdr plugin for v1.** Reasons, recorded so we stop re-litigating:

1. Plugins are workflow packages (actions/events/panes/link handlers + build step), not a
   semantics layer. Nothing in the manifest absorbs the actual host contract above —
   paste-pill send semantics, `Enter`-not-`Return`, workspace scoping, or screen-scrape
   liveness. Repackaging as a plugin moves the files, not the coupling.
2. The event hook plugins DO get (`agent-telegram-notify` listens on agent status) is built
   on the same `agent_status` that false-idles for grok TUI panes — the exact signal drovr
   had to route around with viewport scraping (#8/#9). A plugin home would inherit the bug,
   not escape it.
3. No sandboxing, no runtime action registration, no plugin update command in plugin v1 —
   distribution via `plugin install` adds a moving prerequisite surface without removing any.
4. What a plugin IS good for later: distribution sugar — a thin manifest whose build step
   installs/links the skill + docs. Optional, post-OSS-v1, never the product home.

Foreclosure risk accepted: if herdr plugin vN later grows a stable agent-lifecycle API,
revisit (b)/(c); until then the filesystem bus + skill remain host-agnostic by construction.

Upstream repro draft (worst status bug): `docs/upstream/grok-agent-status-false-idle.md`.

## P3 steps — COMPLETE

- [x] Host-contract smoke (2026-07-09): isolated named session (`herdr --session dl-smoke
      server`, own socket/session dir — CLI targeted via `HERDR_SOCKET_PATH`), README install
      steps followed verbatim (clone → suite 150/150; caught + fixed a non-executable
      run-tests.sh), consumer = cortex (`.drovr/config`: Go gate, grok-4.5 arm, slash-y
      local base). Full cycle ran unattended: task `cortex-config-tests`, iter-1 gate PASS +
      2 real lens findings (gofmt drift, vacuous precedence assertion), iter-2 fixed both,
      gate PASS, both lenses re-reviewed, triage verdict **ready-for-human-merge**, loop
      stopped at the human gate. Host: **herdr 0.7.3, protocol 16** — load-bearing
      integrations = the 7-point contract above, now in README "Supported host". One new
      gotcha confirmed: a fresh workspace's root pane inherits the SERVER process cwd
      (workspace `--cwd` did not place the shell) — reset with cd + relaunch, same as splits.
- [x] Foreclosure check (2026-07-09): plugin examples skimmed, "not v1" recorded above,
      upstream repro drafted in `docs/upstream/`.
