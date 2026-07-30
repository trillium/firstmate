#!/usr/bin/env bash
# Thin policy shim over parlay supervise: delegate task supervision to parlay,
# apply firstmate escalation policy.
# Usage: fm-watch.sh <task-id> [task-id ...]
#
# Supervises one or more tasks using parlay's native supervise primitive.
# Reads keyed status lines and applies firstmate's escalation judgment:
# routine wakes (working, paused) are absorbed; terminal wakes (done, blocked,
# needs-decision, failed) are escalated to the supervisor.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_ROOT}/state}"

parlay_bin="${FM_ROOT}/../parlay/bin/parlay"
[ -x "$parlay_bin" ] || {
  echo "error: parlay not found at $parlay_bin" >&2
  exit 1
}

usage() {
  echo "fm-watch.sh: supervise one or more tasks using parlay supervise" >&2
  echo "Usage: $0 <task-id> [task-id ...]" >&2
  exit 1
}

[ $# -ge 1 ] || usage

# Supervise each task via parlay's native primitive
supervise_task() {
  local id="$1"

  # Inject PARLAY_STATUS_FILE so parlay status appends to firstmate's
  # fleet-tracking file. This allows parlay-launched agents to signal
  # status back to firstmate's supervision loop.
  export PARLAY_STATUS_FILE="$STATE/$id.status"

  # Call parlay supervise: wakes on actionable status changes and applies
  # absorb-when-provably-working logic. The wake reason is printed to stdout.
  local wake_reason
  wake_reason=$("$parlay_bin" supervise "$id" 2>&1 || true)

  # Escalation policy: routine wakes (working, paused, resolved) are absorbed
  # and do not wake the supervisor. Terminal wakes (done, blocked, needs-decision,
  # failed) always wake. Apply firstmate's judgment here.

  case "$wake_reason" in
    working*|paused*|resolved*|captain-held*)
      # Routine — absorbed by the supervise primitive. No escalation.
      return 0
      ;;
    done*|blocked*|needs-decision*|failed*)
      # Terminal — escalate to supervisor.
      echo "Escalating $id: $wake_reason"
      return 0
      ;;
    *)
      # Unknown reason — escalate to be safe (fail loud).
      echo "Escalating $id (unknown reason): $wake_reason"
      return 0
      ;;
  esac
}

# Supervise each task ID passed as argument
for id in "$@"; do
  supervise_task "$id" || true
done
