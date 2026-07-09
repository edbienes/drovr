#!/usr/bin/env bash
# run-tests.sh — run all devloop unit tests, aggregate pass/fail.
set -u
cd "$(dirname "$0")"
rc=0
for t in *_test.sh; do
  [ -e "$t" ] || continue
  printf '== %s ==\n' "$t"
  bash "$t" || rc=1
done
exit "$rc"
