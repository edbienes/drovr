#!/usr/bin/env bash
# bus.sh — file-as-IPC bus contract for the dev-loop control room (review stage).
# SOURCED by the orchestrator. Do NOT `set -e` here (would leak into the caller's shell).
# All bus I/O is by ABSOLUTE path under ~/.drovr/<repo-slug>/<task>/ — outside any checkout (spec §15).

BUS_SENTINEL="END-OF-FILE"

_bus_root()  { printf '%s\n' "${DROVR_BUS_ROOT:-$HOME/.drovr}"; }
_bus_slug()  { printf '%s\n' "${DROVR_REPO_SLUG:-$(basename "$(git rev-parse --show-toplevel)")}"; }
_bus_base()  { printf '%s/%s\n' "$(_bus_root)" "$(_bus_slug)"; }

# bus_task_dir <task> : ensure <root>/<slug>/<task>/reviews exists; echo the task dir.
bus_task_dir() {
  local dir; dir="$(_bus_base)/$1"
  mkdir -p "$dir/reviews"
  printf '%s\n' "$dir"
}

# bus_write <task> <relpath> : write stdin atomically, sentinel as last line; echo dest.
bus_write() {
  local task="$1" rel="$2" dir dest tmp
  dir="$(bus_task_dir "$task")"
  dest="$dir/$rel"
  mkdir -p "$(dirname "$dest")"
  tmp="$dest.tmp.$$"
  cat > "$tmp"
  printf '%s\n' "$BUS_SENTINEL" >> "$tmp"
  mv -f "$tmp" "$dest"          # atomic rename on the same filesystem
  printf '%s\n' "$dest"
}

# bus_ready <task> <relpath> : exit 0 iff file exists AND last non-blank line is the sentinel.
bus_ready() {
  local f; f="$(_bus_base)/$1/$2"
  [ -f "$f" ] || return 1
  [ "$(grep -v '^[[:space:]]*$' "$f" | tail -n 1)" = "$BUS_SENTINEL" ] || return 1
}

# bus_read <task> <relpath> : emit content WITHOUT the trailing sentinel; fail if not ready.
bus_read() {
  bus_ready "$1" "$2" || { printf 'bus_read: %s not ready (no sentinel)\n' "$2" >&2; return 1; }
  local f; f="$(_bus_base)/$1/$2"
  # print everything up to (not including) the last line equal to the sentinel
  awk -v s="$BUS_SENTINEL" '
    { line[NR]=$0; if ($0==s) last=NR }
    END { for (i=1;i<last;i++) print line[i] }
  ' "$f"
}

# bus_iter_dir <task> <n> : ensure <task>/iter-<n>/reviews exists; echo the iter dir abs path.
# Per-iteration subdir so a re-dispatch of the SAME task name (the impl loop reuses the name across
# fail→iterate attempts) never false-triggers bus_ready on a stale prior-iteration file.
bus_iter_dir() {
  local dir; dir="$(_bus_base)/$1/iter-$2"
  mkdir -p "$dir/reviews"
  printf '%s\n' "$dir"
}

# status_set <task> <phase> <iter> : write the durable per-task status file (phase + iter counter) at the
# TASK ROOT. Plain key=value — the orchestrator both writes AND reads it (no cross-pane sentinel handoff),
# so the cap + resume survive a re-invoke/compaction. Ensures the task dir exists first.
status_set() {
  local dir; dir="$(bus_task_dir "$1")"
  printf 'phase=%s\niter=%s\n' "$2" "$3" > "$dir/status.md"
}

# status_get <task> <key> : echo the value for key (phase|iter); exit 1 if status.md or the key is absent.
status_get() {
  local f; f="$(_bus_base)/$1/status.md"
  [ -f "$f" ] || return 1
  local v; v="$(sed -n "s/^$2=//p" "$f")"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}
