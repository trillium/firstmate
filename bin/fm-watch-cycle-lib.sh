# shellcheck shell=bash
# Shared READER for the watcher lifecycle ledger (state/.watch-cycle-exits.log).
# Usage: . bin/fm-watch-cycle-lib.sh
#
# bin/fm-watch-arm.sh owns writing that bounded ledger, one tab-separated record
# per observed cycle. This library is the only reader. It exists because the
# ledger already classified supervision death correctly (reason=arm-interrupted)
# while nothing in the system ever ACTED on or reported that classification, so a
# harness-killed arm ended supervision silently.
#
# Two facts make the raw row unsafe to read naively, and both are handled here:
#
#   - successor= is NOT evidence. Only a persistent adapter that passes
#     FM_WATCH_PREDECESSOR_ARM_PID (the opencode plugin and the pi extension)
#     ever back-fills it, so on every other primary - including a Claude primary
#     driven by bin/fm-claude-stop-autoarm.sh - the field reads "none" even when
#     a healthy successor really did take over. Callers must judge continuity
#     from live watcher health (fm_watcher_healthy), never from this field.
#   - beacon_age= is fresh for a KILLED watcher. The beacon is touched every poll,
#     so a watcher terminated while healthy leaves a beacon 0-13s old. Freshness
#     therefore cannot distinguish "ended cleanly" from "was killed"; the reason
#     field can, and that is exactly what fm_cycle_last_was_interrupted reports.
#
# This file is sourced by scripts and has no side effects on source.

# Reasons written when a cycle ended WITHOUT propagating an actionable wake, i.e.
# the cycle stopped supervising and no wake reason carried the handoff onward.
# An actionable-* reason is excluded: that close propagated a reason and the
# adapter layer re-arms behind it on the ordinary path.
FM_CYCLE_ENDED_REASONS='arm-interrupted|attached-cycle-ended|attached-cycle-ended-benign|unexpected-clean-exit|unexpected-clean-exit-benign|confirmation-timeout|nonzero-exit|signal-exit'

# fm_cycle_last_row <state-dir>
# Populate FM_CYCLE_* from the final ledger record. Returns 1 when the ledger is
# absent, empty, or its last line is not a well-formed record, leaving every
# variable empty so a caller can never read a stale value from a prior call.
fm_cycle_last_row() {
  local state=$1 line key value field
  local -a fields=()
  FM_CYCLE_ARM_PID=
  FM_CYCLE_WATCHER_PID=
  FM_CYCLE_ORIGIN=
  FM_CYCLE_ENDED_AT=
  FM_CYCLE_EXIT_CODE=
  FM_CYCLE_SIGNAL=
  FM_CYCLE_REASON=
  FM_CYCLE_BEACON_AGE=
  FM_CYCLE_SUCCESSOR=

  line=$(tail -n 1 "$state/.watch-cycle-exits.log" 2>/dev/null) || return 1
  case "$line" in
    arm_pid=*) ;;
    *) return 1 ;;
  esac

  # Split on tabs only. The writer strips tabs from every value, so each field is
  # exactly one key=value pair; values may themselves contain "=" (lock_before).
  IFS=$'\t' read -r -a fields <<< "$line"
  for field in "${fields[@]}"; do
    key=${field%%=*}
    value=${field#*=}
    # shellcheck disable=SC2034 # every FM_CYCLE_* var is read by callers after sourcing
    case "$key" in
      arm_pid) FM_CYCLE_ARM_PID=$value ;;
      watcher_pid) FM_CYCLE_WATCHER_PID=$value ;;
      origin) FM_CYCLE_ORIGIN=$value ;;
      ended_at) FM_CYCLE_ENDED_AT=$value ;;
      exit_code) FM_CYCLE_EXIT_CODE=$value ;;
      signal) FM_CYCLE_SIGNAL=$value ;;
      reason) FM_CYCLE_REASON=$value ;;
      beacon_age) FM_CYCLE_BEACON_AGE=$value ;;
      successor) FM_CYCLE_SUCCESSOR=$value ;;
    esac
  done

  [ -n "$FM_CYCLE_REASON" ] || return 1
  return 0
}

# fm_cycle_last_was_interrupted <state-dir>
# True exactly when the last recorded cycle ended because the ARM ITSELF was
# signalled (reason=arm-interrupted): a harness stop, session teardown, or manual
# kill tore down the arm, and bin/fm-watch-arm.sh's signal handler killed the
# watcher child with it. This is supervision being TERMINATED, not ending, so it
# must never be classified from the still-fresh liveness beacon it leaves behind.
fm_cycle_last_was_interrupted() {
  fm_cycle_last_row "$1" || return 1
  [ "$FM_CYCLE_REASON" = arm-interrupted ]
}

# fm_cycle_last_ended_supervision <state-dir>
# True when the last recorded cycle ended without propagating an actionable wake
# reason. Continuity then depends entirely on some adapter re-arming; the caller
# must still confirm live watcher health before treating that as satisfied.
fm_cycle_last_ended_supervision() {
  fm_cycle_last_row "$1" || return 1
  printf '%s' "$FM_CYCLE_REASON" | grep -qE "^($FM_CYCLE_ENDED_REASONS)$"
}

# fm_cycle_describe <state-dir>
# Print one human-readable evidence line about the last recorded cycle, for
# supervision-down banners, or nothing when there is no readable record.
# Deliberately omits successor=, which is not trustworthy evidence (see header).
fm_cycle_describe() {
  local state=$1 detail
  fm_cycle_last_row "$state" || return 1
  case "$FM_CYCLE_REASON" in
    arm-interrupted)
      detail="the watcher was TERMINATED (signal ${FM_CYCLE_SIGNAL:-unknown}), not ended - a harness stop or session teardown killed the arm and its watcher together"
      ;;
    confirmation-timeout)
      detail="the arm never confirmed a healthy watcher"
      ;;
    nonzero-exit|signal-exit)
      detail="the watcher exited abnormally (exit ${FM_CYCLE_EXIT_CODE:-unknown}, signal ${FM_CYCLE_SIGNAL:-unknown})"
      ;;
    *)
      detail="reason=${FM_CYCLE_REASON}"
      ;;
  esac
  printf 'Last recorded watcher cycle (arm %s, watcher %s): %s.\n' \
    "${FM_CYCLE_ARM_PID:-unknown}" "${FM_CYCLE_WATCHER_PID:-unknown}" "$detail"
}
