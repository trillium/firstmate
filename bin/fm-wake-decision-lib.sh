#!/usr/bin/env bash
# fm-wake-decision-lib.sh - the single owner of the stale-wake decision log:
# one JSON line per watcher verdict on a stale pane that was about to alarm
# (absorb or surface, with the deterministic rule that decided it and the cheap
# features it had in hand), plus one label line per surfaced stale wake written
# when the supervising agent acknowledges that wake, recording whether handling
# changed anything durable for the task.
#
# This is Phase 1 of the Laya stale-wake triage plan
# (docs/laya-stale-wake-triage.md): a log-only record that a later shadow
# scorer is calibrated against. Nothing here decides a wake. Every writer is
# best-effort: a failed or disabled write never changes a verdict, never blocks
# an acknowledgement, and never exits the caller.
#
# Files, all under the state directory:
#   .wake-decisions.jsonl    append-only log, trimmed to its newest
#                            FM_WAKE_DECISION_LOG_KEEP_LINES lines once it
#                            passes FM_WAKE_DECISION_LOG_MAX_BYTES
#   .wake-decisions.pending  TSV `seq<TAB>task<TAB>window<TAB>epoch<TAB>fingerprint`,
#                            one row per surfaced stale wake awaiting its label
#   .wake-decisions.lock     lock directory shared by the two writers above
#   .wake-decision-surfaced-<window-key>
#                            `<status-signature><TAB><count>`: how many stale
#                            surfaces this exact status-log state has had
#
# Decision row (event "decision"):
#   ts, kind "stale", window, task, verdict absorb|surface, rule, seq (the
#   queued wake row for a surface, null for an absorb), last_verb, last_line
#   (first 200 characters), status_age_secs, status_size, surfaced_unchanged
#   (the heartbeat-surfaced marker already covers the whole status log),
#   times_surfaced (stale surfaces already recorded for this exact status-log
#   state, before this verdict), open_decision, captain_call open|none|unread,
#   afk, busy, escalations, throttle_age_secs, fingerprint.
# Label row (event "label"):
#   ts, seq, window, task, label acted|noop|gone, ack_delay_secs,
#   fingerprint_before, fingerprint_after.
#
# Label semantics. The fingerprint is `status=<status-log signature>;inbox=<unread
# steering messages>/<handled>;meta=<metadata signature>;hold=<open captain-call
# identity, none, or unread>`. `acted` means it differs at acknowledgement from
# the one captured when the wake was queued, `noop` means it is identical, and
# `gone` means the task's status log and metadata no longer exist. It is a
# side-effect proxy for what the supervising agent did between presentation and
# acknowledgement, not a statement of intent; docs/laya-stale-wake-triage.md
# owns its limits.
#
# Knobs:
#   FM_WAKE_DECISION_LOG=off             disable every write (default on)
#   FM_WAKE_DECISION_LOG_MAX_BYTES=1048576
#   FM_WAKE_DECISION_LOG_KEEP_LINES=4000
#   FM_WAKE_DECISION_PENDING_MAX_ROWS=500  newest pending rows kept
#
# Requires bin/fm-wake-lib.sh (locks, STATE, status signatures) and
# bin/fm-classify-lib.sh (status verbs and open decisions) to be sourced first.
# The captain-call read runs bin/fm-captain-hold.sh from this library's own
# code root, against the FM_HOME in effect.

_FM_WAKE_DECISION_BIN=${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
FM_WAKE_DECISION_LOG_MAX_BYTES=${FM_WAKE_DECISION_LOG_MAX_BYTES:-1048576}
FM_WAKE_DECISION_LOG_KEEP_LINES=${FM_WAKE_DECISION_LOG_KEEP_LINES:-4000}
FM_WAKE_DECISION_PENDING_MAX_ROWS=${FM_WAKE_DECISION_PENDING_MAX_ROWS:-500}
case "$FM_WAKE_DECISION_LOG_MAX_BYTES" in ''|*[!0-9]*|0) FM_WAKE_DECISION_LOG_MAX_BYTES=1048576 ;; esac
case "$FM_WAKE_DECISION_LOG_KEEP_LINES" in ''|*[!0-9]*|0) FM_WAKE_DECISION_LOG_KEEP_LINES=4000 ;; esac
case "$FM_WAKE_DECISION_PENDING_MAX_ROWS" in ''|*[!0-9]*|0) FM_WAKE_DECISION_PENDING_MAX_ROWS=500 ;; esac

fm_wake_decision_enabled() {
  case "${FM_WAKE_DECISION_LOG:-on}" in off|0|false|no) return 1 ;; esac
  return 0
}

fm_wake_decision_log_path() {  # <state>
  printf '%s/.wake-decisions.jsonl' "$1"
}

fm_wake_decision_pending_path() {  # <state>
  printf '%s/.wake-decisions.pending' "$1"
}

_fm_wake_decision_lock_path() {  # <state>
  printf '%s/.wake-decisions.lock' "$1"
}

# JSON string body for <text>: tabs and line breaks become spaces, other
# control bytes are dropped, backslash and double quote are escaped. The
# result is printed without surrounding quotes.
fm_wake_decision_json_str() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -d '\000-\037\177' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# JSON number, or null when <value> is not plain digits.
_fm_wake_decision_json_num() {  # <value>
  case "$1" in ''|*[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac
}

_fm_wake_decision_json_bool() {  # <0|1>
  if [ "$1" = 0 ]; then printf 'true'; else printf 'false'; fi
}

_fm_wake_decision_mtime() {  # <file>
  if [ "${_FM_UNAME:-$(uname 2>/dev/null)}" = Darwin ]; then
    /usr/bin/stat -f '%m' "$1" 2>/dev/null
  else
    stat -c '%Y' "$1" 2>/dev/null
  fi
}

_fm_wake_decision_window_key() {  # <window>
  printf '%s' "$1" | tr ':/.' '___'
}

_fm_wake_decision_count_msgs() {  # <dir>
  local n=0 f
  [ -d "$1" ] || { printf '0'; return 0; }
  for f in "$1"/*.msg; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# The durable side-effect fingerprint of <task>. An optional <hold> supplies an
# already-read captain-call identity (`none` when the read found none, `unread`
# to skip the read) so a caller that just consulted the backlog does not pay for
# a second read; without it the backlog is read when FM_HOME names a home, else
# recorded as `unread`.
fm_wake_decision_fingerprint() {  # <state> <task> [<hold>]
  local state=$1 task=$2 hold=${3-} status meta status_sig meta_sig unread handled hold_bin
  status="$state/$task.status"
  meta="$state/$task.meta"
  if [ ! -e "$status" ] && [ ! -e "$meta" ]; then
    printf 'gone'
    return 0
  fi
  status_sig=$(fm_wake_signal_sig "$status" 2>/dev/null) || status_sig=absent
  [ -n "$status_sig" ] || status_sig=absent
  meta_sig=$(fm_wake_signal_sig "$meta" 2>/dev/null) || meta_sig=absent
  [ -n "$meta_sig" ] || meta_sig=absent
  unread=$(_fm_wake_decision_count_msgs "$state/$task.inbox")
  handled=$(_fm_wake_decision_count_msgs "$state/$task.inbox/handled")
  if [ -z "$hold" ]; then
    hold_bin="$_FM_WAKE_DECISION_BIN/fm-captain-hold.sh"
    if [ -n "${FM_HOME:-}" ] && [ -x "$hold_bin" ]; then
      hold=$("$hold_bin" open "$task" --identity 2>/dev/null) || hold=none
      [ -n "$hold" ] || hold=none
    else
      hold=unread
    fi
  fi
  printf 'status=%s;inbox=%s/%s;meta=%s;hold=%s' \
    "$status_sig" "$unread" "$handled" "$meta_sig" "$(printf '%s' "$hold" | LC_ALL=C tr '\t\r\n;' '____')"
}

_fm_wake_decision_append() {  # <state> <json-line>
  local log=$1 sz tmp
  log=$(fm_wake_decision_log_path "$1")
  printf '%s\n' "$2" >> "$log" 2>/dev/null || return 0
  sz=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$sz" -ge "$FM_WAKE_DECISION_LOG_MAX_BYTES" ] || return 0
  tmp="$log.tmp.$$"
  tail -n "$FM_WAKE_DECISION_LOG_KEEP_LINES" "$log" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$log" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# Times this exact status-log state of <window> has already been surfaced
# through the stale path, read from the per-window counter; 0 when the counter
# names another state or is absent.
_fm_wake_decision_times_surfaced() {  # <state> <window-key> <status-signature>
  local raw sig n
  raw=$(cat "$1/.wake-decision-surfaced-$2" 2>/dev/null) || { printf '0'; return 0; }
  sig=${raw%%$'\t'*}; n=${raw#*$'\t'}
  [ "$sig" = "$3" ] || { printf '0'; return 0; }
  case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

# Record one stale verdict. <verdict> is absorb or surface, <rule> names the
# deterministic branch that decided it, <seq> is the queued wake row for a
# surface (empty otherwise), <hold> is open|none|unread, <busy> is 0 for a busy
# pane and 1 otherwise, <escalations> is the wedge escalation count, and
# <throttle-age> is the age in seconds of the window's re-surface marker.
# Prints nothing and always returns 0.
fm_wake_decision_log_stale() {  # <state> <window> <task> <verdict> <rule> <seq> <hold> <busy> <escalations> <throttle-age>
  local state=$1 window=$2 task=$3 verdict=$4 rule=$5 seq=$6 hold=$7 busy=$8 esc=$9 tage=${10-}
  local status key sig size offset last verb age now mtime unchanged=1 open=1 afk=1 times fp hold_fp
  fm_wake_decision_enabled || return 0
  status="$state/$task.status"
  key=$(_fm_wake_decision_window_key "$window")
  sig=$(fm_wake_signal_sig "$status" 2>/dev/null) || sig=absent
  [ -n "$sig" ] || sig=absent
  size=$(_fm_status_file_size "$status" 2>/dev/null) || size=''
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) size='' ;; esac
  offset=$(status_presentation_marker_offset "$(status_heartbeat_seen_marker_path "$state" "$task")" "$status" 2>/dev/null) || offset=0
  [ -n "$size" ] && [ "$size" -gt 0 ] && [ "$offset" = "$size" ] && unchanged=0
  last=$(last_status_line "$status" 2>/dev/null) || last=''
  last=${last%$'\n'}
  verb=''
  [ -z "$last" ] || verb=$(status_line_verb "$last")
  fm_epoch_seconds_to now 2>/dev/null || now=$(date +%s)
  mtime=$(_fm_wake_decision_mtime "$status") || mtime=''
  age=''
  case "$mtime" in ''|*[!0-9]*) ;; *) [ "$mtime" -le "$now" ] && age=$((now - mtime)) ;; esac
  status_has_open_needs_decision "$status" 2>/dev/null && open=0
  [ ! -e "$state/.afk" ] || afk=0
  times=$(_fm_wake_decision_times_surfaced "$state" "$key" "$sig")
  case "$hold" in
    open) hold_fp=${CAPTAIN_CALL_IDENTITY:-open} ;;
    none) hold_fp=none ;;
    *) hold_fp=unread ;;
  esac
  fp=$(fm_wake_decision_fingerprint "$state" "$task" "$hold_fp")
  _fm_wake_decision_append "$state" "$(printf '{"event":"decision","ts":%s,"kind":"stale","window":"%s","task":"%s","verdict":"%s","rule":"%s","seq":%s,"last_verb":"%s","last_line":"%s","status_age_secs":%s,"status_size":%s,"surfaced_unchanged":%s,"times_surfaced":%s,"open_decision":%s,"captain_call":"%s","afk":%s,"busy":%s,"escalations":%s,"throttle_age_secs":%s,"fingerprint":"%s"}' \
    "$now" \
    "$(fm_wake_decision_json_str "$window")" \
    "$(fm_wake_decision_json_str "$task")" \
    "$(fm_wake_decision_json_str "$verdict")" \
    "$(fm_wake_decision_json_str "$rule")" \
    "$(_fm_wake_decision_json_num "$seq")" \
    "$(fm_wake_decision_json_str "$verb")" \
    "$(fm_wake_decision_json_str "$(printf '%s' "$last" | LC_ALL=C cut -c1-200)")" \
    "$(_fm_wake_decision_json_num "$age")" \
    "$(_fm_wake_decision_json_num "$size")" \
    "$(_fm_wake_decision_json_bool "$unchanged")" \
    "$times" \
    "$(_fm_wake_decision_json_bool "$open")" \
    "$(fm_wake_decision_json_str "$hold")" \
    "$(_fm_wake_decision_json_bool "$afk")" \
    "$(_fm_wake_decision_json_bool "$busy")" \
    "$(_fm_wake_decision_json_num "$esc")" \
    "$(_fm_wake_decision_json_num "$tage")" \
    "$(fm_wake_decision_json_str "$fp")")"
  if [ "$verdict" = surface ]; then
    printf '%s\t%s' "$sig" "$((times + 1))" > "$state/.wake-decision-surfaced-$key" 2>/dev/null || true
    case "$seq" in
      ''|*[!0-9]*) ;;
      *) _fm_wake_decision_pending_add "$state" "$seq" "$task" "$window" "$now" "$fp" ;;
    esac
  fi
  return 0
}

_fm_wake_decision_pending_add() {  # <state> <seq> <task> <window> <epoch> <fingerprint>
  local state=$1 pending lock tmp
  pending=$(fm_wake_decision_pending_path "$state")
  lock=$(_fm_wake_decision_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" >> "$pending" 2>/dev/null || true
  tmp="$pending.tmp.$$"
  if tail -n "$FM_WAKE_DECISION_PENDING_MAX_ROWS" "$pending" > "$tmp" 2>/dev/null \
    && [ "$(wc -l < "$tmp" | tr -d '[:space:]')" != "$(wc -l < "$pending" | tr -d '[:space:]')" ]; then
    mv -f "$tmp" "$pending" 2>/dev/null || true
  fi
  rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$lock"
  return 0
}

# Label every pending surfaced stale wake whose sequence is at or below <cutoff>
# and, when <rows-file> is given, named in it (one sequence per line), plus any
# pending row whose task records are gone. Each labelled row is appended to the
# log and dropped from the pending file. Always returns 0.
fm_wake_decision_label_through() {  # <state> <cutoff> [<rows-file>]
  local state=$1 cutoff=$2 rows=${3-} pending lock tmp keep now seq task window epoch fp after label delay
  fm_wake_decision_enabled || return 0
  case "$cutoff" in ''|*[!0-9]*) return 0 ;; esac
  pending=$(fm_wake_decision_pending_path "$state")
  [ -s "$pending" ] || return 0
  lock=$(_fm_wake_decision_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 0
  tmp="$pending.tmp.$$"
  keep=''
  fm_epoch_seconds_to now 2>/dev/null || now=$(date +%s)
  while IFS=$'\t' read -r seq task window epoch fp || [ -n "$seq" ]; do
    [ -n "$seq" ] || continue
    case "$seq" in *[!0-9]*) continue ;; esac
    # A row whose captain call was never read is compared without reading it
    # now, so the comparison stays between like features.
    case "$fp" in
      *';hold=unread') after=$(fm_wake_decision_fingerprint "$state" "$task" unread) ;;
      *) after=$(fm_wake_decision_fingerprint "$state" "$task") ;;
    esac
    if [ "$after" = gone ]; then
      label=gone
    elif [ "$seq" -le "$cutoff" ] \
      && { [ -z "$rows" ] || grep -qxF "$seq" "$rows" 2>/dev/null; }; then
      if [ "$after" = "$fp" ]; then label=noop; else label=acted; fi
    else
      keep="${keep}${seq}"$'\t'"${task}"$'\t'"${window}"$'\t'"${epoch}"$'\t'"${fp}"$'\n'
      continue
    fi
    delay=''
    case "$epoch" in ''|*[!0-9]*) ;; *) [ "$epoch" -le "$now" ] && delay=$((now - epoch)) ;; esac
    _fm_wake_decision_append "$state" "$(printf '{"event":"label","ts":%s,"seq":%s,"window":"%s","task":"%s","label":"%s","ack_delay_secs":%s,"fingerprint_before":"%s","fingerprint_after":"%s"}' \
      "$now" "$seq" \
      "$(fm_wake_decision_json_str "$window")" \
      "$(fm_wake_decision_json_str "$task")" \
      "$label" \
      "$(_fm_wake_decision_json_num "$delay")" \
      "$(fm_wake_decision_json_str "$fp")" \
      "$(fm_wake_decision_json_str "$after")")"
  done < "$pending"
  if printf '%s' "$keep" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$pending" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
  fm_lock_release "$lock"
  return 0
}
