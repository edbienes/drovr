# herdr `agent_status` false-idle for Grok Build panes — RESOLVED UPSTREAM

Status: **do not file — already fixed.** This was drafted as an upstream repro while the bug
was live; before filing we found herdr had already fixed it:

- **herdr#1017** — the original repro (grok panes fall back to `idle` during working turns).
- **herdr#1055** (closed 2026-07-05) — rewrote the Grok Build detection manifest for the
  current UI (verified on Grok Build 0.2.82+): working = braille spinner + `[stop]` chip with
  an `Esc:cancel` backstop; blocked = `┃`-guttered dialog rows (whose footer includes
  `Ctrl+c:cancel`); idle = `Shift+Tab:mode │ Ctrl+.:shortcuts` footer. Manifest
  `2026.07.03.1` / engine 2, distributed via the remote agent-detection fetch
  (`herdr server agent-manifests` / `update-agent-manifests`).
- Verified 2026-07-09 on this host: herdr 0.7.3 reports grok manifest `2026.07.03.1`,
  `remote_update_result: current` — the fix is live without any action.

## Consequence for drovr (the real follow-up)

drovr's grok screen-scrape heuristics (`_drovr_busy`/`_drovr_alive`, touchpoints #8/#9)
were built against the PRE-fix chrome and are now stale in the dangerous direction:

- Busy anchor `Ctrl+c:cancel` no longer appears during working turns — in current chrome it
  appears in the **blocked** dialog footer. A working grok can read as not-busy (re-delivery
  risk), and a blocked one as busy.
- With manifest ≥ 2026.07.03.1, `agent_status` should be trustworthy for grok panes,
  making the scrape unnecessary.

Migration (tracked on the drovr issue tracker): verify live idle→working→blocked→idle via
`herdr pane get` against a real Grok Build ≥0.2.9x session, then either retire the grok
scrape branches in favor of `agent_status` (with the manifest version documented as part of
the "Supported host" floor) or refresh the anchors to the new chrome. Until then the
liberal-busy design keeps the failure cost at "extra wait", not lost results — completion
still only ever comes from bus file sentinels.
