#!/usr/bin/env bash
# assert.sh — tiny assertion helpers for the drovr unit tests. No bats dependency.
# Each assert prints PASS/FAIL and increments counters in the sourcing script.
ASSERT_PASS=0
ASSERT_FAIL=0

assert_eq() { # assert_eq <actual> <expected> <msg>
  if [ "$1" = "$2" ]; then ASSERT_PASS=$((ASSERT_PASS+1)); printf '  PASS %s\n' "$3"
  else ASSERT_FAIL=$((ASSERT_FAIL+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"; fi
}

assert_contains() { # assert_contains <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) ASSERT_PASS=$((ASSERT_PASS+1)); printf '  PASS %s\n' "$3" ;;
    *) ASSERT_FAIL=$((ASSERT_FAIL+1)); printf '  FAIL %s\n       [%s] does not contain [%s]\n' "$3" "$1" "$2" ;;
  esac
}

assert_ok() { # assert_ok <cmd...> : command should exit 0
  if "$@" >/dev/null 2>&1; then ASSERT_PASS=$((ASSERT_PASS+1)); printf '  PASS exit0: %s\n' "$*"
  else ASSERT_FAIL=$((ASSERT_FAIL+1)); printf '  FAIL exit0: %s (got %d)\n' "$*" "$?"; fi
}

assert_fail() { # assert_fail <cmd...> : command should exit non-zero
  if "$@" >/dev/null 2>&1; then ASSERT_FAIL=$((ASSERT_FAIL+1)); printf '  FAIL expected-nonzero: %s\n' "$*"
  else ASSERT_PASS=$((ASSERT_PASS+1)); printf '  PASS nonzero: %s\n' "$*"; fi
}

assert_summary() { # call at end; exits non-zero if any failed
  printf '%s\n' "----- $ASSERT_PASS passed, $ASSERT_FAIL failed -----"
  [ "$ASSERT_FAIL" -eq 0 ]
}
