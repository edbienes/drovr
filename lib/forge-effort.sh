#!/usr/bin/env bash
# forge-effort.sh <effort>
#
# Pin `[reasoning] effort` in ~/.forge/.forge.toml immediately before a headless `forge -p` launch.
# forge reads its toml once at process start and the file is forge's ONLY model/effort knob, so a
# per-phase effort (DL_PLAN_EFFORT for the plan phase, DL_IMPL_EFFORT for impl iters) can only be
# realized by editing the file. This runs INSIDE the impl pane's launch line, in sequence right
# before `forge`, so the pin is atomic with the process it configures — no orchestrator-side
# flip/revert bookkeeping, no cross-task race: every forge dispatch that wants a specific effort
# pins its own.
#
# Fail-safe by design (mirrors forge-pretrust.sh): a missing toml, an unrecognized value, or a
# missing `effort =` line warns to stderr and exits 0 — forge then runs at whatever the toml
# already says. Value validation ALSO happens fail-closed in dispatch.sh before the pane line is
# built; the case here only guards direct/manual invocation.
# FORGE_TOML overrides the toml path (tests point it at a fixture).
set -euo pipefail
eff="${1:?effort (low|medium|high|xhigh)}"
toml="${FORGE_TOML:-$HOME/.forge/.forge.toml}"

case "$eff" in
  low|medium|high|xhigh) ;;
  *) echo "forge-effort: unrecognized effort '$eff' — toml untouched" >&2; exit 0 ;;
esac
[ -f "$toml" ] || { echo "forge-effort: $toml not found — toml untouched" >&2; exit 0; }
grep -q '^effort = ' "$toml" || { echo "forge-effort: no 'effort =' line in $toml — untouched" >&2; exit 0; }

# tmp+mv (not sed -i) for BSD/GNU portability and atomic replace.
tmp="$(mktemp)"
sed "s/^effort = \".*\"/effort = \"$eff\"/" "$toml" > "$tmp" && mv "$tmp" "$toml"
