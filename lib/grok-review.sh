#!/usr/bin/env bash
# grok-review.sh — headless deep-reasoning Grok review lens via OpenCode (SuperGrok subscription, OAuth).
# Drop-in for the resident grok-pressure-test pane: writes adversarial findings to the SAME bus file the
# loop already polls (reviews/grok.md, END-OF-FILE sentinel via bus_write), so drovr_collect_* is unchanged.
#
# Grok has NO reasoning-effort knob (grok-CLI --effort is a no-op for grok-build/composer; OpenCode has none).
# Depth is selected by MODEL, set once at framing by the slice's tier:
#   DL_TIER=tier1  (money / migration / RLS) -> xai/grok-4.20-multi-agent-0309   (Heavy multi-agent)
#   otherwise                                -> xai/grok-4.3                      (deep default)
# Mid-run escalation (the two lenses disagree on a material finding) = re-run this with DL_TIER=tier1.
#
# Why OpenCode and not the grok CLI: the grok CLI ("Grok Build") only exposes grok-build + composer-2.5-fast
# (fast coders, no deep reasoning). The deep tiers live in OpenCode, authed via xAI OAuth = the same
# subscription (NOT a metered API key), so this is subscription-flat, no surprise bills.
#
# Usage: grok-review.sh <task> <relpath> <repo-or-worktree-path> <target-desc>
# Prompt + diff go via STDIN — proven: opencode reads stdin, banner to stderr, stdout clean; the arg form flakes.
set -uo pipefail
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_LIB/bus.sh"

task="${1:?task}"; rel="${2:?relpath}"; repo="${3:?repo path}"; target="${4:?target desc}"
export DROVR_REPO_SLUG="${DROVR_REPO_SLUG:-$(basename "$repo")}"   # so bus paths resolve in a detached shell

model="xai/grok-4.3"
[ "${DL_TIER:-}" = tier1 ] && model="xai/grok-4.20-multi-agent-0309"

# Any failure still lands a sentinel'd note so the poll returns a VISIBLE failure instead of STALLING on a
# pane that was never fired. exit 0 — a failed review is a review outcome, not a dispatch crash.
fail() { printf 'grok-review FAILED (%s): %s\n' "$model" "$1" | bus_write "$task" "$rel" >/dev/null; exit 0; }

diff="$(git -C "$repo" diff "${DL_WORKTREE_BASE:-main}...HEAD")" || fail "git diff failed"
[ -n "$diff" ] || fail "empty diff (nothing to review)"
# ponytail: 200k-char cap keeps us off any context cliff; raise if a slice ever needs the full diff.
diff="${diff:0:200000}"

prompt="You are an adversarial code reviewer pressure-testing the committed diff of ${target}.
Try to BREAK it: correctness bugs, missed edge cases, RLS/tenant-isolation holes, money-path errors,
unhandled failures, broken invariants. Be specific (file:line), skeptical, and refute your own first
impressions before reporting. If nothing material survives scrutiny, say so plainly. Output ONLY findings.

DIFF (${target}):
${diff}"

out="$(printf '%s' "$prompt" | opencode run -m "$model" 2>/dev/null)" || fail "opencode run failed"
[ -n "$out" ] || fail "opencode returned empty output"
# Trailing \n is REQUIRED: $(...) strips it, and bus_write appends the sentinel verbatim — without this the
# sentinel joins the last finding line (e.g. "...done.END-OF-FILE") and bus_ready never fires. (Caught in smoke.)
printf '%s\n' "$out" | bus_write "$task" "$rel" >/dev/null
printf 'grok-review (%s) wrote %s/%s\n' "$model" "$(bus_task_dir "$task")" "$rel" >&2
