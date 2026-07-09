# Draft upstream issue (herdr): `agent_status` sustained false-idle for Grok Build TUI panes

Status: DRAFT — file against herdr when P4 goes public (reliability lobbying only; devloop
does not depend on the fix — see `docs/herdr-touchpoints.md` deferred item (d)).

## Title

`agent_status` reports `idle` while a Grok Build pane is actively generating (sustained false-idle)

## Environment

- herdr 0.7.3 (macOS, darwin arm64)
- Grok Build CLI 0.2.93 (stable) running in a herdr-managed pane (first observed on 0.2.87)
- Claude Code panes in the same workspace report `agent_status` correctly (control)

## Repro

1. `herdr pane split --no-focus` → in the new pane, launch `grok`.
2. Send a prompt long enough to generate for >30s:
   `herdr pane send-text <pid> "<long prompt>"` then `herdr pane send-keys <pid> Enter`.
3. While the Grok TUI is visibly streaming (footer shows `Ctrl+c:cancel`, token counter `⇣n`
   incrementing), poll `herdr pane list --workspace <ws>` (or `pane get <pid>`).

## Expected

`agent_status: working` for the duration of generation, `idle` only after the response
completes.

## Actual

`agent_status: idle` for sustained stretches **mid-generation** (not a transient flap — it
persists across many consecutive polls while the footer still shows an active run). As a
result `herdr wait agent-status --status idle` returns immediately / long before completion,
so idle-wait is unusable as a completion or readiness signal for Grok panes.

Related, lesser variant: on the Grok Build fresh-boot home screen (no footer rendered yet),
status/liveness heuristics also misread the pane — a just-launched healthy pane is
indistinguishable from a dead one via `agent_status`.

## Impact

Any consumer building on `agent_status` events or `wait agent-status` (including the
documented plugin pattern, e.g. `agent-telegram-notify`) gets false completion signals for
Grok panes. We currently work around it by scraping `pane read --source visible` for footer
markers, which is version-fragile.

## Workaround in use

Busy = `pane read --source visible` matches `Ctrl+c:cancel` / `⇣n`; alive additionally
accepts home-screen anchors (`│ ❯`, `Grok Build <ver>`). Works, but couples us to Grok TUI
rendering details.
