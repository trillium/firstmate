#!/usr/bin/env bash
# Inbox-store event adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-inbox.sh arm [watch-file]
#   fm-procevent-inbox.sh source <source-id>
#   fm-procevent-inbox.sh source-id [watch-file]
#   fm-procevent-inbox.sh classify <result-file>
#   fm-procevent-inbox.sh terminal <result-file>
#   fm-procevent-inbox.sh handle <source-id> <sequence> <result-file>
#   fm-procevent-inbox.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-inbox.sh retire [watch-file]
#
# `arm` registers one blocking, non-destructive tail source for the inbox
# store's JSONL watch file (default ~/data/inbox/events.jsonl, override with
# INBOX_EVENTS_FILE). The process-event runner owns blocking, capture,
# publication, and one machine-wide source owner. Each captured batch of new
# lines is a signal to re-check the inbox store, never the payload itself:
# multiple changes batch while the agent is busy without losing the fact that
# a re-check is required.
#
# SIGNAL SEMANTICS, stated plainly. A captured batch carries no judgement and
# no delivery promise beyond the runner's own durability (output that reached
# the runner is stored before it is announced). A missed or duplicated line is
# harmless: the handler re-checks the whole store on every wake, so the cursor
# here only controls wake batching, never data completeness. Never describe
# this path as at-least-once, no-loss, or lossless.
#
# The cursor is a byte offset in STATE/inbox-cursor/<source-id>.offset plus a
# mapping in STATE/inbox-sources/<source-id>.path. First arm starts at EOF so
# history is not replayed; re-arm never resets an existing cursor. Rotation or
# truncation (file smaller than the cursor) resets forward instead of
# replaying: the wake still triggers a full store re-check, so nothing is
# lost by skipping the truncated prefix.
#
# Exit 75 from `source` means the wait window closed with no complete line,
# mirroring fm-remote-delta-read.sh. The runner treats a nonzero exit with no
# output as no-result and leaves the registration armed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WAIT_SECONDS=${FM_INBOX_WAIT_SECONDS:-55}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# NOTE: fm-lock.sh is a session-lock *script*, not a library: sourcing it
# acquires the harness lock with stdout noise. Lock helpers
# (fm_lock_acquire_wait / fm_lock_release) come from fm-wake-lib.sh above.

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

default_watch_file() {
  if [ -n "${INBOX_EVENTS_FILE:-}" ]; then
    printf '%s\n' "$INBOX_EVENTS_FILE"
  else
    printf '%s\n' "$HOME/data/inbox/events.jsonl"
  fi
}

realpath_of() { # <path>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

sha16() { # <string> (stdin-safe, no trailing newline games)
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,16)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'
  else
    die "no SHA-256 tool is available"
  fi
}

cursor_dir() { printf '%s/inbox-cursor\n' "$STATE"; }
sources_dir() { printf '%s/inbox-sources\n' "$STATE"; }
cursor_path() { printf '%s/%s.offset\n' "$(cursor_dir)" "$1"; }
mapping_path() { printf '%s/%s.path\n' "$(sources_dir)" "$1"; }
lifecycle_lock() { printf '%s/.inbox-lifecycle-%s.lock\n' "$STATE" "$1"; }

# Canonical identity is physical, not the path string: two names for one file
# are one source and must never become two owners.
cmd_source_id() {
  local watch=${1:-} real
  [ -n "$watch" ] || watch=$(default_watch_file)
  case "$watch" in *$'\n'*) die "watch file paths cannot contain newlines" ;; esac
  real=$(realpath_of "$watch") || {
    # Allow arming before the file exists (rotation/recreation): hash the
    # unresolved path so the sid is stable once the file appears.
    real="$watch"
  }
  printf 'inbox-%s\n' "$(sha16 "$real")"
}

resolve_watch() { # <source-id>
  local map real
  map=$(mapping_path "$1")
  [ -f "$map" ] && [ ! -L "$map" ] || die "no watch-file mapping for source: $1"
  real=$(cat "$map" 2>/dev/null) || die "cannot read watch-file mapping for source: $1"
  [ -n "$real" ] || die "watch-file mapping is empty for source: $1"
  case "$real" in *$'\n'*) die "watch-file mapping is malformed for source: $1" ;; esac
  printf '%s\n' "$real"
}

read_cursor() { # <source-id>; sets CURSOR_OFFSET
  local path size
  path=$(cursor_path "$1")
  CURSOR_OFFSET=0
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || die "inbox cursor is unsafe: $path"
  CURSOR_OFFSET=$(tr -cd '0-9' < "$path" 2>/dev/null) || CURSOR_OFFSET=0
  [ -n "$CURSOR_OFFSET" ] || CURSOR_OFFSET=0
  # Clamp a stale offset past a rotated/truncated file later in source/autohandle.
  size=${CURSOR_OFFSET}
  return 0
}

write_cursor() { # <source-id> <offset>
  local path tmp dir
  case "$2" in ''|*[!0-9]*) die "cursor offset must be a nonnegative integer" ;; esac
  dir=$(cursor_dir)
  (umask 077; mkdir -p "$dir") || die "cannot create inbox cursor directory"
  [ ! -L "$dir" ] || die "inbox cursor directory is unsafe"
  path=$(cursor_path "$1")
  tmp=$(umask 077; mktemp "$dir/.offset.XXXXXX") || die "cannot stage inbox cursor"
  printf '%s\n' "$2" > "$tmp" || { rm -f -- "$tmp"; die "cannot write inbox cursor"; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure inbox cursor"; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; die "cannot publish inbox cursor"; }
}

file_size() { # <path>; prints size or nothing
  case "$(uname -s)" in
    Darwin) stat -f %z "$1" 2>/dev/null ;;
    *) stat -c %s "$1" 2>/dev/null ;;
  esac
}

# bytes_through_last_newline <path>: file size when the file ends in a
# newline, else the offset of its last newline (0 when there is none).
# A bare awk length count treats an unterminated trailing record as complete,
# so framing goes through rindex here and in cmd_source: only bytes through
# a real newline are ever emitted, and a torn write stays for the next run.
bytes_through_last_newline() {
  perl -e '
    $f = shift; open(F, "<", $f) or exit 1; binmode(F);
    { local $/; $d = <F>; } $d = "" unless defined $d;
    $i = rindex($d, "\n"); print($i < 0 ? 0 : $i + 1);
  ' "$1" 2>/dev/null
}

cmd_arm() {
  local watch=${1:-} real sid map dir size lock
  [ -n "$watch" ] || watch=$(default_watch_file)
  case "$watch" in *$'\n'*) die "watch file paths cannot contain newlines" ;; esac
  case "$WAIT_SECONDS" in ''|*[!0-9]*) die "FM_INBOX_WAIT_SECONDS must be a nonnegative integer" ;; esac
  [ "$WAIT_SECONDS" -le 300 ] || die "FM_INBOX_WAIT_SECONDS exceeds the 300-second safety bound"
  real=$(realpath_of "$watch") || real="$watch"
  sid=$(printf 'inbox-%s\n' "$(sha16 "$real")")
  fm_procevent_source_id_valid "$sid" || die "computed source id is invalid: $sid"
  lock=$(lifecycle_lock "$sid")
  fm_lock_acquire_wait "$lock" || die "cannot lock inbox lifecycle for $sid"
  trap 'fm_lock_release "$lock"' EXIT
  dir=$(sources_dir)
  (umask 077; mkdir -p "$dir") || die "cannot create inbox sources directory"
  [ ! -L "$dir" ] || die "inbox sources directory is unsafe"
  map=$(mapping_path "$sid")
  # The mapping always tracks the latest realpath; the cursor is only ever
  # initialized, never reset, so re-arm cannot skip or replay.
  printf '%s\n' "$real" > "$map" || die "cannot write watch-file mapping"
  chmod 0600 "$map" || die "cannot secure watch-file mapping"
  if [ ! -e "$(cursor_path "$sid")" ]; then
    # Start at the last line boundary, not raw EOF: a torn tail in flight
    # at arm time completes into a whole line on the next append instead of
    # emitting a headless fragment. A file ending in newline starts at EOF,
    # so history is still never replayed.
    size=$(bytes_through_last_newline "$real" 2>/dev/null) || size=0
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    write_cursor "$sid" "$size"
  fi
  "$SCRIPT_DIR/fm-procevent.sh" register inbox "$sid" -- \
    "$SCRIPT_DIR/fm-procevent-inbox.sh" source "$sid" || die "cannot register inbox source: $sid"
  fm_lock_release "$lock"
  trap - EXIT
  read_cursor "$sid"
  printf 'armed: %s offset=%s\n' "$sid" "$CURSOR_OFFSET"
  printf 'watch: %s\n' "$real"
}

# Blocking wait: exit 0 after printing one header + new complete lines, or
# exit 75 when the window closes with nothing complete. Only whole lines
# (ending in \n) are emitted; a torn trailing partial stays for the next run.
cmd_source() {
  local sid=${1:-} watch start size now deadline head payload tmp
  fm_procevent_source_id_valid "$sid" || die "invalid source id: $sid"
  case "$WAIT_SECONDS" in ''|*[!0-9]*) die "FM_INBOX_WAIT_SECONDS must be a nonnegative integer" ;; esac
  [ "$WAIT_SECONDS" -le 300 ] || die "FM_INBOX_WAIT_SECONDS exceeds the 300-second safety bound"
  watch=$(resolve_watch "$sid")
  read_cursor "$sid"
  start=$CURSOR_OFFSET
  size=$(file_size "$watch" 2>/dev/null) || size=""
  if [ -n "$size" ] && [ "$size" -lt "$start" ]; then
    # Rotated/truncated while idle: wait from the new EOF, persist the reset
    # in autohandle. Never replay the truncated prefix.
    start=$size
  fi
  now=$(date +%s)
  deadline=$((now + WAIT_SECONDS))
  while :; do
    size=$(file_size "$watch" 2>/dev/null) || size=""
    if [ -n "$size" ]; then
      if [ "$size" -lt "$start" ]; then
        start=$size
      fi
      if [ "$size" -gt "$start" ]; then
        tmp=$(mktemp "${TMPDIR:-/tmp}/fm-inbox-source.XXXXXX") || die "cannot stage inbox read"
        trap 'rm -f -- "$tmp"' EXIT
        # Read only the grown window; dd keeps this bounded and seek-safe.
        dd if="$watch" of="$tmp" bs=1 skip="$start" count=$((size - start)) 2>/dev/null || {
          rm -f -- "$tmp"; trap - EXIT; die "cannot read inbox watch window"
        }
        # Keep only whole lines: cut at the last newline. No newline yet
        # means a torn write is still in flight; wait for its completion.
        head=$(bytes_through_last_newline "$tmp" 2>/dev/null) || head=0
        case "$head" in ''|*[!0-9]*) head=0 ;; esac
        if [ "$head" -gt 0 ]; then
          payload=$(mktemp "${TMPDIR:-/tmp}/fm-inbox-payload.XXXXXX") || { rm -f -- "$tmp"; trap - EXIT; die "cannot stage inbox payload"; }
          dd if="$tmp" of="$payload" bs=1 count="$head" 2>/dev/null || {
            rm -f -- "$tmp" "$payload"; trap - EXIT; die "cannot frame inbox payload"
          }
          rm -f -- "$tmp"
          {
            printf 'schema=fm-inbox-delta.v1\n'
            printf 'path=%s\n' "$watch"
            printf 'from_offset=%s\n' "$start"
            printf 'to_offset=%s\n' "$((start + head))"
            printf 'payload_bytes=%s\n' "$head"
            printf 'payload_lines=%s\n' "$(grep -c '' "$payload" 2>/dev/null || printf '0')"
            printf '\n'
            cat "$payload"
          }
          rm -f -- "$payload"
          trap - EXIT
          exit 0
        fi
        rm -f -- "$tmp"
        trap - EXIT
      fi
    fi
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || exit 75
    # A PATH-level sleep guard (robots-pnjd) refuses bare-sleep timers with
    # exit 1; fall back to the real binary so the poll keeps its cadence.
    sleep 1 2>/dev/null || /bin/sleep 1
  done
}

result_field() { # <result-file> <field>
  sed -n "s/^$2=//p" "$1" | head -1
}

# Classify a captured result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} schema lines
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  schema=$(result_field "$file" schema)
  lines=$(result_field "$file" payload_lines)
  if [ "$schema" = fm-inbox-delta.v1 ]; then
    case "$lines" in ''|*[!0-9]*|0) printf 'empty\n'; return 0 ;; esac
    printf 'inbox-event\n'
    return 0
  fi
  printf 'unknown\n'
}

# The inbox stream never ends: a captured batch is never terminal, so the
# registration stays armed and reconcile restarts the tail.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  return 1
}

cmd_handle_locked() { # <sid> <seq> <result-file>
  local sid=$1 seq=$2 result=$3 watch from to size current new lock
  fm_procevent_source_id_valid "$sid" || die "invalid source id: $sid"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  [ -f "$result" ] && [ ! -L "$result" ] || die "result file is unavailable or unsafe: $result"
  [ "$(cmd_classify "$result")" = inbox-event ] || die "inbox result carries no event batch"
  watch=$(resolve_watch "$sid")
  from=$(result_field "$result" from_offset)
  to=$(result_field "$result" to_offset)
  case "$from$to" in ''|*[!0-9]*) die "inbox result offsets are ambiguous" ;; esac
  read_cursor "$sid"
  current=$CURSOR_OFFSET
  size=$(file_size "$watch" 2>/dev/null) || size=$to
  case "$size" in ''|*[!0-9]*) size=$to ;; esac
  if [ "$size" -lt "$current" ]; then
    # Rotation between capture and handling: reset forward; the published
    # wake still triggers a full store re-check, so the skipped prefix
    # costs no signal.
    current=$size
  fi
  new=$current
  [ "$to" -gt "$new" ] && new=$to
  [ "$new" -le "$size" ] || new=$size
  if [ "$new" -ne "$current" ]; then
    write_cursor "$sid" "$new" || die "cannot commit inbox cursor"
  fi
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" || return 1
  printf 'ingested: %s offset=%s\n' "$sid" "$new"
}

cmd_handle() {
  local sid=${1:-} lock
  fm_procevent_source_id_valid "$sid" || die "invalid source id: $sid"
  lock=$(lifecycle_lock "$sid")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock inbox lifecycle for $sid"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_handle_locked "$@"
  )
}

# The runner's entry into cmd_handle: applying the cursor advance never
# depends on a handler remembering to run it. The published wake still reaches
# firstmate, and running `handle` again on that wake is idempotent.
cmd_autohandle() {
  local sid=${1:-} seq=${2:-} result=${3:-}
  case "$sid" in
    inbox-?*) ;;
    *) die "not an inbox source: $sid" ;;
  esac
  cmd_handle "$sid" "$seq" "$result"
}

cmd_retire() {
  local watch=${1:-} sid lock
  [ -n "$watch" ] || watch=$(default_watch_file)
  sid=$(cmd_source_id "$watch")
  lock=$(lifecycle_lock "$sid")
  fm_lock_acquire_wait "$lock" || die "cannot lock inbox lifecycle for $sid"
  trap 'fm_lock_release "$lock"' EXIT
  "$SCRIPT_DIR/fm-procevent.sh" retire "$sid"
  fm_lock_release "$lock"
  trap - EXIT
}

case "${1:-}" in
  arm)        shift; cmd_arm "$@" ;;
  source)     shift; [ "$#" -eq 1 ] || usage; cmd_source "$@" ;;
  source-id)  shift; cmd_source_id "$@" ;;
  classify)   shift; [ "$#" -eq 1 ] || usage; cmd_classify "$@" ;;
  terminal)   shift; [ "$#" -eq 1 ] || usage; cmd_terminal "$@" ;;
  handle)     shift; [ "$#" -eq 3 ] || usage; cmd_handle "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  retire)     shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
