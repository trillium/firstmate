# shellcheck shell=bash
# bin/fm-beads-resilience-lib.sh - local mirror and durable write queue that
# keep the beads backlog backend (config/backlog-backend=beads) from wedging
# firstmate during a Dolt/beads-store outage.
# Usage: . bin/fm-beads-resilience-lib.sh
#
# Read-side mirror (beads-authority-migration Stage 5, report.md section 5):
#   fm_beads_mirror_write <view> <raw-output>   - opportunistic side effect of
#     a successful `task ...` read already performed by a caller (session-start's
#     compact listing, fm-fleet-snapshot.sh). No code path polls beads solely
#     to refresh this file, same discipline as
#     state/.last-watcher-beat. <view> is a short slug (e.g. "ready", "fleet")
#     naming which read this is a mirror of; each view gets its own file.
#   fm_beads_mirror_read <view>     - prints the last mirrored raw output for
#     <view> to stdout and sets FM_BEADS_MIRROR_WRITTEN_AT to its epoch
#     timestamp; returns 1 if no mirror exists yet or it is unreadable.
#   fm_beads_mirror_age_seconds <view>   - prints the mirror's age in seconds;
#     returns 1 if absent.
#   fm_beads_mirror_fresh <view> [<max-age-seconds>]   - true if a mirror
#     exists and is no older than <max-age-seconds> (default
#     FM_BEADS_MIRROR_MAX_AGE, 900s / 15min).
#   fm_beads_mirror_timestamp_iso <view>   - prints the mirror's write time as
#     a UTC ISO-8601 timestamp, for the "(stale mirror, beads store
#     unreachable since <ts>)" label callers prefix onto stale output.
# A mirror file is never presented as current: every caller that falls back to
# one must label the output as a stale mirror (AGENTS.md section 3's ABSENT-
# file discipline extended to "unreachable-store" fallback data).
#
# Write-side durable queue (report.md section 5 write-queue design):
#   fm_beads_write_enqueue <task-id> <description> <task-argv...>   - append a
#     failed `task <task-argv...>` write to the durable queue for later
#     replay. Beads remains sole write authority; the queue is availability,
#     not a second authority, and never resolves conflicts itself - replay is
#     strict FIFO, and a write that no longer applies cleanly is left for
#     whatever `task` itself reports on replay rather than reconciled locally,
#     with one narrow exception: fm_beads_write_queue_reconcile's close check
#     below.
#   fm_beads_write_queue_count      - prints the number of queued writes.
#   fm_beads_write_queue_reconcile   - replays every queued write against the
#     live store, dropping ones that succeed and re-queuing ones that still
#     fail; prints one BEADS_WRITE_QUEUE: line per outcome plus a summary
#     line; returns 0 only when the queue drains completely. A queued `close`
#     write whose replay fails is checked with fm_beads_close_already_applied
#     (a `task show <id> --json` reporting the bead absent or status=closed)
#     before being re-queued, so a bead the outage's original close (or
#     someone else) already closed is reconciled instead of retried forever;
#     every other write kind still leaves a genuine replay failure re-queued
#     as-is. Call sites that currently warn-and-continue on a failed beads
#     write (fm-teardown.sh's close_linked_bead, fm-bead-stamp.sh) enqueue on
#     failure instead of only warning, preserving their existing fail-open
#     posture. Called from fm-bootstrap.sh's mutating sweep block (beads
#     backend only) so an outage recovers on the next session-start bootstrap
#     without a new polling loop.
#
# Both mirror files (state/.beads-mirror-<view>.json) and the write queue
# (state/.beads-write-queue) are private runtime state (AGENTS.md section 2)
# and reuse bin/fm-wake-lib.sh's portable symlink-based lock and durable
# append/drain pattern rather than reimplementing it.

FM_BEADS_RESILIENCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_BEADS_RESILIENCE_DEFAULT_ROOT="$(cd "$FM_BEADS_RESILIENCE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BEADS_RESILIENCE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"

# fm-wake-lib.sh (fm_current_pid, fm_lock_acquire_wait, fm_lock_release) is
# loaded lazily, only by the write-path functions that actually need its
# locking primitives, because it unconditionally mkdir -p's $STATE on source.
# The read-side mirror functions never need it, and callers like
# fm-bootstrap.sh's detect-only path read the mirror without mutating
# anything - eagerly sourcing it here would create $STATE as a side effect of
# merely checking beads availability.
_FM_BEADS_WAKE_LIB_LOADED=0
fm_beads_require_wake_lib() {
  [ "$_FM_BEADS_WAKE_LIB_LOADED" = 1 ] && return 0
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$FM_BEADS_RESILIENCE_LIB_DIR/fm-wake-lib.sh"
  _FM_BEADS_WAKE_LIB_LOADED=1
}

FM_BEADS_MIRROR_MAX_AGE=${FM_BEADS_MIRROR_MAX_AGE:-900}
case "$FM_BEADS_MIRROR_MAX_AGE" in '' | *[!0-9]*) FM_BEADS_MIRROR_MAX_AGE=900 ;; esac

FM_BEADS_MIRROR_VIEWS="ready inflight fleet"
FM_BEADS_MIRROR_WRITTEN_AT=

FM_BEADS_WRITE_QUEUE="${FM_BEADS_WRITE_QUEUE:-$STATE/.beads-write-queue}"
FM_BEADS_WRITE_QUEUE_LOCK="${FM_BEADS_WRITE_QUEUE_LOCK:-$STATE/.beads-write-queue.lock}"

fm_beads_mirror_view_name_ok() {
  case "$1" in
    '' | *[!a-z0-9_-]*) return 1 ;;
  esac
  return 0
}

fm_beads_mirror_view_path() { # <view>
  fm_beads_mirror_view_name_ok "$1" || return 1
  printf '%s/.beads-mirror-%s.json\n' "$STATE" "$1"
}

fm_beads_epoch_to_iso() { # <epoch-seconds>
  date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
    date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
    printf 'epoch:%s\n' "$1"
}

fm_beads_mirror_write() { # <view> <raw-output>
  local view=$1 raw=$2 path tmp
  fm_beads_require_wake_lib
  path=$(fm_beads_mirror_view_path "$view") || return 1
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  tmp="${path}.tmp.$(fm_current_pid 2>/dev/null || echo $$)"
  if ! jq -n --argjson written_at "$(date +%s)" --arg output "$raw" \
    '{written_at: $written_at, output: $output}' >"$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  mv -f "$tmp" "$path" 2>/dev/null
}

fm_beads_mirror_read() { # <view> -> raw output on stdout, sets FM_BEADS_MIRROR_WRITTEN_AT
  local view=$1 path written output
  FM_BEADS_MIRROR_WRITTEN_AT=
  path=$(fm_beads_mirror_view_path "$view") || return 1
  [ -f "$path" ] || return 1
  written=$(jq -r '.written_at // empty' "$path" 2>/dev/null)
  case "$written" in '' | *[!0-9]*) return 1 ;; esac
  output=$(jq -r '.output // empty' "$path" 2>/dev/null) || return 1
  FM_BEADS_MIRROR_WRITTEN_AT=$written
  printf '%s\n' "$output"
}

fm_beads_mirror_age_seconds() { # <view>
  local view=$1
  fm_beads_mirror_read "$view" >/dev/null || return 1
  printf '%s\n' "$(($(date +%s) - FM_BEADS_MIRROR_WRITTEN_AT))"
}

fm_beads_mirror_fresh() { # <view> [<max-age-seconds>]
  local view=$1 max_age=${2:-$FM_BEADS_MIRROR_MAX_AGE} age
  age=$(fm_beads_mirror_age_seconds "$view") || return 1
  [ "$age" -le "$max_age" ]
}

fm_beads_mirror_timestamp_iso() { # <view>
  local view=$1
  fm_beads_mirror_read "$view" >/dev/null || return 1
  fm_beads_epoch_to_iso "$FM_BEADS_MIRROR_WRITTEN_AT"
}

fm_beads_mirror_freshest_iso() { # [<max-age-seconds>] -> ISO-8601 timestamp of
  # whichever known view has the freshest fresh mirror; returns 1 if none fresh.
  local max_age=${1:-$FM_BEADS_MIRROR_MAX_AGE} view best_age best_view age
  best_age=
  best_view=
  for view in $FM_BEADS_MIRROR_VIEWS; do
    fm_beads_mirror_fresh "$view" "$max_age" || continue
    age=$(fm_beads_mirror_age_seconds "$view") || continue
    if [ -z "$best_age" ] || [ "$age" -lt "$best_age" ]; then
      best_age=$age
      best_view=$view
    fi
  done
  [ -n "$best_view" ] || return 1
  fm_beads_mirror_timestamp_iso "$best_view"
}

fm_beads_write_enqueue() { # <task-id> <description> <argv to pass to `task`, excluding the program name itself>
  local id=$1 desc=$2 line rc
  fm_beads_require_wake_lib
  shift 2
  [ "$#" -gt 0 ] || return 1
  line=$(jq -nc --arg id "$id" --arg desc "$desc" --argjson epoch "$(date +%s)" \
    --args '{queued_at: $epoch, task_id: $id, description: $desc, argv: $ARGS.positional}' \
    -- "$@") || return 1
  mkdir -p "$STATE" 2>/dev/null || true
  fm_lock_acquire_wait "$FM_BEADS_WRITE_QUEUE_LOCK"
  printf '%s\n' "$line" >>"$FM_BEADS_WRITE_QUEUE"
  rc=$?
  fm_lock_release "$FM_BEADS_WRITE_QUEUE_LOCK"
  return "$rc"
}

fm_beads_write_queue_count() {
  if [ -s "$FM_BEADS_WRITE_QUEUE" ]; then
    grep -c . "$FM_BEADS_WRITE_QUEUE" 2>/dev/null || printf '0\n'
  else
    printf '0\n'
  fi
}

# fm_beads_close_already_applied <task-id> - true if the bead is absent or already
# closed, so a queued close whose replay failed is treated as idempotently done.
# Reads status through fm_beads_status (bin/fm-tasks-axi-lib.sh), the one owner of
# the `task show --json` array unwrap; empty (absent/unreadable) counts as already
# applied here, unlike fm_beads_is_closed which reads empty as "not closed". The
# sole caller (fm_beads_write_queue_reconcile) has already proven the store
# reachable, and both callers of this file (bin/fm-bootstrap.sh, bin/fm-session-start.sh)
# source fm-tasks-axi-lib.sh before this file, so fm_beads_status is in scope.
fm_beads_close_already_applied() { # <task-id> - true if the bead is absent or already closed
  local id=${1:-} status
  status=$(fm_beads_status "$id")
  [ -z "$status" ] || [ "$status" = closed ]
}

fm_beads_write_queue_reconcile() {
  local queue=$FM_BEADS_WRITE_QUEUE drained remaining line id desc replayed=0 failed=0
  [ -s "$queue" ] || return 0
  fm_beads_require_wake_lib

  if ! command -v task >/dev/null 2>&1; then
    echo "BEADS_WRITE_QUEUE: task CLI not found, $(fm_beads_write_queue_count) write(s) remain queued"
    return 1
  fi
  if ! task list --limit 1 >/dev/null 2>&1; then
    echo "BEADS_WRITE_QUEUE: store still unreachable, $(fm_beads_write_queue_count) write(s) remain queued"
    return 1
  fi

  drained="$queue.draining.$(fm_current_pid 2>/dev/null || echo $$)"
  fm_lock_acquire_wait "$FM_BEADS_WRITE_QUEUE_LOCK"
  if ! mv "$queue" "$drained" 2>/dev/null; then
    fm_lock_release "$FM_BEADS_WRITE_QUEUE_LOCK"
    return 0
  fi
  fm_lock_release "$FM_BEADS_WRITE_QUEUE_LOCK"

  remaining="$drained.remaining"
  : >"$remaining"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(printf '%s' "$line" | jq -r '.task_id // "?"' 2>/dev/null)
    desc=$(printf '%s' "$line" | jq -r '.description // ""' 2>/dev/null)
    local -a argv=()
    while IFS= read -r arg; do argv+=("$arg"); done < <(printf '%s' "$line" | jq -r '.argv[]? // empty' 2>/dev/null)
    if [ "${#argv[@]}" -gt 0 ] && task "${argv[@]}" >/dev/null 2>&1; then
      replayed=$((replayed + 1))
      echo "BEADS_WRITE_QUEUE: reconciled queued write for $id ($desc)"
    elif [ "${argv[0]:-}" = close ] && fm_beads_close_already_applied "$id"; then
      replayed=$((replayed + 1))
      echo "BEADS_WRITE_QUEUE: reconciled queued write for $id ($desc) (bead already closed)"
    else
      failed=$((failed + 1))
      printf '%s\n' "$line" >>"$remaining"
      echo "BEADS_WRITE_QUEUE: replay failed for $id ($desc); re-queued"
    fi
  done <"$drained"

  fm_lock_acquire_wait "$FM_BEADS_WRITE_QUEUE_LOCK"
  if [ -s "$remaining" ]; then
    if [ -e "$queue" ]; then
      cat "$remaining" "$queue" >"$queue.merge.$(fm_current_pid 2>/dev/null || echo $$)" &&
        mv "$queue.merge.$(fm_current_pid 2>/dev/null || echo $$)" "$queue"
    else
      mv "$remaining" "$queue"
    fi
  fi
  rm -f "$remaining" "$drained" 2>/dev/null
  fm_lock_release "$FM_BEADS_WRITE_QUEUE_LOCK"

  if [ "$failed" -eq 0 ] && [ "$replayed" -gt 0 ]; then
    echo "BEADS_WRITE_QUEUE: reconciliation clean, queue empty"
  fi
  [ "$failed" -eq 0 ]
}
