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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-no-mistakes-liveness.sh
. "$SCRIPT_DIR/fm-no-mistakes-liveness.sh"

# Check if a run is live (not hung) - simplified version for single-run checks
check_run_liveness() {  # <run-id>
  local run_id=$1
  local run_out outcome awaiting_msg elapsed

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

  # Check active_steps table first (more accurate than steps table)
  local active_steps_section active_step_line last_activity_field
  active_steps_section=$(printf '%s\n' "$run_out" | sed -n '/^[[:space:]]*active_steps\[/,/^[^[:space:]]/p')

  if [ -n "$active_steps_section" ]; then
    active_step_line=$(printf '%s\n' "$active_steps_section" | grep -E '^[[:space:]]*[^,]+,(running|fixing),' | head -1 | sed 's/^[[:space:]]*//')

    if [ -n "$active_step_line" ]; then
      # Found an active running/fixing step. Extract last_activity.
      # Format: step,status,active_for,"time ago: message","pid",round
      if [[ "$active_step_line" =~ ^[^,]*,[^,]*,[^,]*,\"([^\"]*) ]]; then
        last_activity_field="${BASH_REMATCH[1]}"
        if [ -n "$last_activity_field" ]; then
          elapsed=$(parse_active_steps_time "$last_activity_field")
          if [ "$elapsed" -gt "$STALE_THRESHOLD" ]; then
            return 1  # Hung
          fi
          return 0  # Live
        fi
      fi
    fi
  fi

  # Fallback: check steps table if no active_steps found
  local step_line step_status duration
  step_line=$(printf '%s\n' "$run_out" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1 | sed 's/^ *//')

  if [ -z "$step_line" ]; then
    # No running/fixing step - not hung
    return 0
  fi

  # Extract step status and duration
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
      if [ -n "$duration" ] && [[ "$duration" =~ ^[0-9]+$ ]]; then
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
