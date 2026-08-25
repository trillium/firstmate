#!/usr/bin/env bash
# Single owner of the absorbed-wake triage debug log (state/.watch-triage.log).
#
# Two supervision layers absorb wakes and must leave the SAME auditable trail:
# the always-on watcher's cheap per-wake triage (bin/fm-push-transition-lib.sh,
# loaded by bin/fm-watch.sh) and the sub-supervisor's attended queue triage
# (bin/fm-attended-triage-lib.sh). Extracting the appender here keeps one
# definition of the log path, the size cap, and the timestamp format instead of
# a second copy drifting inside the daemon.
#
# The log is best-effort debug evidence only. Nothing reads it back as an
# authority, so every failure path returns success rather than propagating.

# TRIAGE_LOG is resolved at source time when the state dir is already known
# (bin/fm-push-transition-lib.sh sources this after fm-wake-lib.sh, which sets
# STATE). A caller that sources this earlier gets the lazy per-call resolution
# in _fm_triage_log_path below instead, so no source order is load-bearing.
if [ -z "${TRIAGE_LOG:-}" ] && [ -n "${FM_STATE_OVERRIDE:-}${STATE:-}" ]; then
  TRIAGE_LOG="${FM_STATE_OVERRIDE:-${STATE:-}}/.watch-triage.log"
fi
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}

_fm_triage_log_path() {
  if [ -n "${TRIAGE_LOG:-}" ]; then
    printf '%s' "$TRIAGE_LOG"
    return 0
  fi
  printf '%s/.watch-triage.log' "${FM_STATE_OVERRIDE:-${STATE:-.}}"
}

# Append one bounded best-effort line for an absorbed supervision event.
triage_log() {
  local sz path
  path=$(_fm_triage_log_path)
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$path" 2>/dev/null || return 0
  sz=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$path" > "$path.tmp" 2>/dev/null && mv -f "$path.tmp" "$path" 2>/dev/null
    rm -f "$path.tmp" 2>/dev/null || true
  fi
}
