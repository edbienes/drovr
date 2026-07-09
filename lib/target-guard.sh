#!/usr/bin/env bash
# target-guard.sh — pre-dispatch ENOSPC guard for the shared CARGO_TARGET_DIR volume.
# Why: the shared target dir lives on the external exFAT SSD (internal disk is at 95% — relocation
# is not an option) and grows without bound; it hit 100% mid-gate on 2026-07-07 (pace-b iter-3, a
# 170G debug tree → ENOSPC → ~45 min lost to a slow exFAT rm + cold rebuild). This runs in the IMPL
# pane's shell line before every shell-arm exec: if the volume holding CARGO_TARGET_DIR has less
# than DL_TARGET_MIN_FREE_GB (default 40) free, prune the debug tree — the largest, fully
# regenerable artifact — BETWEEN dispatches instead of mid-iteration.
# Fail-safe by contract: ALWAYS exits 0; a guard failure must never block a dispatch.
set -u
TD="${CARGO_TARGET_DIR:-}"
[ -n "$TD" ] && [ -d "$TD" ] || exit 0
MIN_GB="${DL_TARGET_MIN_FREE_GB:-40}"
free_kb="$(df -Pk "$TD" 2>/dev/null | awk 'NR==2{print $4}')"
case "$free_kb" in ''|*[!0-9]*) exit 0 ;; esac
if [ "$free_kb" -lt $((MIN_GB * 1024 * 1024)) ]; then
  echo "target-guard: only $((free_kb / 1024 / 1024))G free (< ${MIN_GB}G) on the CARGO_TARGET_DIR volume — pruning $TD/debug"
  rm -rf "$TD/debug" 2>/dev/null || true
fi
exit 0
