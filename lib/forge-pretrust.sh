#!/usr/bin/env bash
# forge-pretrust.sh <worktree-abs-root> <repo-abs-root>
#
# Pre-trust a fresh worktree's .mcp.json so a headless `forge -p` run never blocks on the interactive
# "Untrusted MCP config — Accept/Reject" prompt. forge keys MCP trust by absolute PATH (not by content),
# so every new worktree path counts as "untrusted" even when its .mcp.json is byte-identical to the
# already-trusted repo copy (same git checkout → same content → same forge hash). We copy the repo path's
# recorded trust hash to the worktree path key in ~/.forge/.mcp_trust.json.
#
# Fail-safe by design: if jq is missing, the trust file is absent, or the repo path isn't trusted yet,
# we no-op and forge falls back to its prompt (a one-time manual Accept). Never errors the dispatch.
# ponytail: pokes forge's private trust store — a stable JSON format; if forge ever changes it, this
# silently no-ops and the prompt returns, never a crash. Drop this when forge ships a headless-trust flag.
set -euo pipefail
wt_mcp="${1:?worktree root}/.mcp.json"
repo_mcp="${2:?repo root}/.mcp.json"
trust="${HOME}/.forge/.mcp_trust.json"

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$trust" ] && [ -f "$wt_mcp" ] || exit 0
# Only proceed if the repo's .mcp.json is already trusted (one-time bootstrap accept) — else nothing to copy.
jq -e --arg r "$repo_mcp" '.trusted[$r] != null' "$trust" >/dev/null 2>&1 || exit 0

tmp="$(mktemp)"
jq --arg w "$wt_mcp" --arg r "$repo_mcp" '.trusted[$w] = .trusted[$r]' "$trust" > "$tmp" && mv "$tmp" "$trust"
