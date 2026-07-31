#!/usr/bin/env bash
# fm-nm-run-is-live.sh - check if a specific no-mistakes run is genuinely live (not hung)
#
# Designed for use by fm-crew-state.sh: given a run ID, determine if it's genuinely
# progressing or has silently hung. This is a simpler facade over
# fm-no-mistakes-liveness.sh tuned for single-run checks during supervision.
#
# Usage:
#   fm-nm-run-is-live.sh <run-id>
#
# Exit codes:
#   0 - run is live/progressing (or not a run-step that can hang)
#   1 - run is hung (step inactive for > FM_NM_LIVENESS_STALE seconds)
#   2 - usage error or precondition failed
#
set -u

# Bounded no-mistakes call; stdout only, never fails the script.
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
nm_run() {  # <args...>
  case "$HAVE_TIMEOUT" in
    timeout)  timeout 15 no-mistakes "$@" 2>/dev/null || true ;;
    gtimeout) gtimeout 15 no-mistakes "$@" 2>/dev/null || true ;;
    perl)     perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' 15 no-mistakes "$@" 2>/dev/null || true ;;
    *)        true ;;
  esac
}

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

strip_quotes() {
  local s
  s=$(trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  trim "$s"
}

nm_field() {  # <output> <key>
  local output=$1 key=$2
  printf '%s\n' "$output" | sed -n "s/^[[:space:]]*$key:[[:space:]]*\(.*\)/\1/p" | head -1
}

get_timestamp() {
  if command -v gdate >/dev/null 2>&1; then
    gdate +%s
  else
    date +%s
  fi
}

parse_log_timestamp() {
  local line=$1
  if [[ $line =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})\ ([0-9]{2}):([0-9]{2}) ]]; then
    local year="${BASH_REMATCH[1]}"
    local month="${BASH_REMATCH[2]}"
    local day="${BASH_REMATCH[3]}"
    local hour="${BASH_REMATCH[4]}"
    local min="${BASH_REMATCH[5]}"

    if command -v gdate >/dev/null 2>&1; then
      gdate -d "$year-$month-$day $hour:$min" +%s 2>/dev/null || echo 0
    else
      date -j -f "%Y-%m-%d %H:%M" "$year-$month-$day $hour:$min" +%s 2>/dev/null || echo 0
    fi
  else
    echo 0
  fi
}

STALE_THRESHOLD=${FM_NM_LIVENESS_STALE:-300}
case "$STALE_THRESHOLD" in ''|*[!0-9]*) STALE_THRESHOLD=300 ;; esac

# Check if a run is live (not hung) - simplified version for single-run checks
check_run_liveness() {  # <run-id>
  local run_id=$1
  local run_out outcome awaiting_msg

  run_out=$(nm_run axi status --run "$run_id") || return 2

  [ -n "$run_out" ] || return 2

  outcome=$(strip_quotes "$(nm_field "$run_out" outcome)")

  # Terminal outcomes are not hung
  if [ -n "$outcome" ]; then
    return 0
  fi

  # Check if awaiting_agent (parked at gate) - not hung, deliberately waiting
  awaiting_msg=$(printf '%s\n' "$run_out" | grep -E '^[[:space:]]*awaiting_agent:' | head -1)
  if [ -n "$awaiting_msg" ]; then
    return 0
  fi

  # For running/fixing steps, check if the step duration is too old
  # Get the first running/fixing step
  local step_line
  step_line=$(printf '%s\n' "$run_out" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1 | sed 's/^ *//')

  if [ -z "$step_line" ]; then
    # No running/fixing step - not hung
    return 0
  fi

  # Extract step name and duration_ms
  local step_status duration
  step_status="${step_line#*,}"
  step_status="${step_status%,*}"
  step_status=$(strip_quotes "$(trim "$step_status")")

  # Skip findings count (third field) and get duration
  local rest="${step_line#*,}"
  rest="${rest#*,}"
  rest="${rest#*,}"
  duration=$(trim "$rest")

  case "$step_status" in
    running|fixing)
      # Convert milliseconds to seconds and check if stale
      if [ -n "$duration" ] && [[ "$duration" =~ ^[0-9]+$ ]]; then
        local elapsed
        elapsed=$((duration / 1000))
        if [ "$elapsed" -gt "$STALE_THRESHOLD" ]; then
          return 1  # Hung
        fi
      fi
      ;;
  esac

  return 0  # Live
}

# --- main

run_id=${1:-}
[ -n "$run_id" ] || { echo "usage: fm-nm-run-is-live.sh <run-id>" >&2; exit 2; }

check_run_liveness "$run_id"
