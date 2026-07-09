#!/usr/bin/env bash
# bus_test.sh — unit tests for lib/bus.sh. Uses a temp bus root + fake slug (no git repo needed).
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/bus.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export DEVLOOP_BUS_ROOT="$TMP/bus"
export DEVLOOP_REPO_SLUG="demo-repo"

# bus_task_dir creates <root>/<slug>/<task>/reviews and echoes the dir
d="$(bus_task_dir issue-91)"
assert_eq "$d" "$TMP/bus/demo-repo/issue-91" "bus_task_dir path"
assert_ok test -d "$d/reviews"

# bus_write writes content + sentinel atomically; echoes the dest path
dest="$(printf 'hello\nworld\n' | bus_write issue-91 task.md)"
assert_eq "$dest" "$TMP/bus/demo-repo/issue-91/task.md" "bus_write dest path"
assert_eq "$(tail -n 1 "$dest")" "END-OF-FILE" "bus_write appends sentinel last"
assert_eq "$(ls "$TMP/bus/demo-repo/issue-91"/*.tmp.* 2>/dev/null | wc -l | tr -d ' ')" "0" "no .tmp leak"

# bus_ready true when sentinel present, false when absent
assert_ok bus_ready issue-91 task.md "bus_ready true with sentinel"
printf 'partial' > "$TMP/bus/demo-repo/issue-91/reviews/grok.md"   # no sentinel
assert_fail bus_ready issue-91 reviews/grok.md "bus_ready false without sentinel"
assert_fail bus_ready issue-91 reviews/missing.md "bus_ready false when absent"

# bus_read returns content WITHOUT the sentinel line; fails when not ready
assert_eq "$(bus_read issue-91 task.md)" "$(printf 'hello\nworld')" "bus_read strips sentinel"
assert_fail bus_read issue-91 reviews/grok.md "bus_read fails when not ready"

# --- hardening edge cases ---
# Overwrite is atomic + replaces cleanly (second write wins, still one file, sentinel intact)
printf 'v2\n' | bus_write issue-91 task.md >/dev/null
assert_eq "$(bus_read issue-91 task.md)" "v2" "overwrite replaces content"
assert_eq "$(ls "$TMP/bus/demo-repo/issue-91"/*.tmp.* 2>/dev/null | wc -l | tr -d ' ')" "0" "no .tmp after overwrite"

# Trailing blank line after sentinel still counts as ready (last NON-BLANK line is sentinel)
printf 'finding A\nEND-OF-FILE\n\n' > "$TMP/bus/demo-repo/issue-91/reviews/claude.md"
assert_ok bus_ready issue-91 reviews/claude.md "ready tolerates trailing blank"
assert_eq "$(bus_read issue-91 reviews/claude.md)" "$(printf 'finding A')" "read strips sentinel + trailing blank"

# A file containing the sentinel string mid-content but NOT as last line is NOT ready
printf 'mentions END-OF-FILE inline\nmore text\n' > "$TMP/bus/demo-repo/issue-91/reviews/x.md"
assert_fail bus_ready issue-91 reviews/x.md "inline sentinel mid-file != ready"

# --- impl half: per-iteration paths + status (Task 1) ---
itd="$(bus_iter_dir issue-91 2)"
assert_eq "$itd" "$TMP/bus/demo-repo/issue-91/iter-2" "bus_iter_dir path"
assert_ok test -d "$itd/reviews"   # iteration reviews subdir is created

# per-iteration isolation: an iter-1 result must NOT satisfy iter-2 readiness (the staleness fix)
printf 'r1\n' | bus_write issue-91 iter-1/result.md >/dev/null
assert_ok   bus_ready issue-91 iter-1/result.md "iter-1 result ready"
assert_fail bus_ready issue-91 iter-2/result.md "iter-2 result NOT ready (no stale cross-iter false-ready)"

# status_set / status_get round-trip + update
status_set issue-91 impl 1
assert_eq "$(status_get issue-91 phase)" "impl" "status phase round-trips"
assert_eq "$(status_get issue-91 iter)"  "1"    "status iter round-trips"
status_set issue-91 review 2
assert_eq "$(status_get issue-91 iter)"  "2"    "status iter updates"
assert_fail status_get issue-91 nope "absent status key → nonzero exit"
assert_fail status_get no-such-task iter "absent status file → nonzero exit"

assert_summary
