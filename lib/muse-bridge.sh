#!/usr/bin/env bash
# muse-bridge.sh <worktree-abs-path> <iterdir-abs-path>
#
# Deliver the muse plan agent's output to the bus plan contract (iter-0/plan.md + END-OF-FILE).
#
# Why this exists (2026-07-14, maintainer decision after the live payments-polish A/B): forge's
# `muse` agent is mode-enforced read-only — no write/patch/shell tools — so unlike the forge
# agent it CANNOT write iter-0/plan.md itself. Its only file output is its `plan` tool, which
# saves under plans/ in the cwd and force-prefixes a date onto any requested filename (proven
# live: an explicit "no date prefix" instruction was overridden at the tool layer). So the
# prompt pins a distinctive STEM and this bridge, appended to the same pane launch line after
# `forge --agent muse`, moves the result onto the bus.
#
# Selection is by git status, not name-matching: the worktree is fresh off the base branch, so
# the ONLY untracked plans/*.md is muse's own (tracked repo plans can never match). mv (not cp)
# keeps the worktree clean so the plan file can never ride into a later impl-iter commit.
# Fail-closed: no untracked plan file -> write NOTHING and rc=1 (the orchestrator's poll on
# iter-0/plan.md times out and resolves, same as any stalled plan phase).
set -u
wt="${1:?usage: muse-bridge.sh <worktree> <iterdir>}"
iterdir="${2:?usage: muse-bridge.sh <worktree> <iterdir>}"

cd "$wt" || { echo "muse-bridge: worktree $wt unreachable" >&2; exit 1; }

# newest untracked plans/*.md (muse retries could leave more than one; mtime picks the final)
f=""
while IFS= read -r p; do
  [ -z "$f" ] || [ "$p" -nt "$f" ] && f="$p"
done < <(git ls-files --others --exclude-standard -- 'plans/*.md' 2>/dev/null)

[ -n "$f" ] || { echo "muse-bridge: no untracked plans/*.md in $wt — plan not delivered" >&2; exit 1; }

mkdir -p "$iterdir" || exit 1
mv "$f" "$iterdir/plan.md" || exit 1
# bus_ready keys on the trailing sentinel; muse writes it inside the document by prompt
# contract, but guarantee it here so a contract slip degrades to a late sentinel, not a hang.
tail -n 1 "$iterdir/plan.md" | grep -qx 'END-OF-FILE' || printf 'END-OF-FILE\n' >> "$iterdir/plan.md"
echo "muse-bridge: $f -> $iterdir/plan.md"
