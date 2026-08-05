#!/usr/bin/env bash
# Behavior tests for the watcher lifecycle ledger READER (bin/fm-watch-cycle-lib.sh).
#
# bin/fm-watch-arm.sh writes state/.watch-cycle-exits.log; this library is the
# only consumer. Its job is to let a supervision-down banner say HOW the last
# cycle ended, because the liveness beacon cannot: a watcher killed while healthy
# leaves a beacon just as fresh as one that ended cleanly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-cycle-lib)

# shellcheck source=bin/fm-watch-cycle-lib.sh
. "$ROOT/bin/fm-watch-cycle-lib.sh"

# One ledger row in the writer's exact tab-separated field order.
write_row() {  # <state> <reason> <signal> <exit_code> <successor>
  local state=$1 reason=$2 signal=$3 exit_code=$4 successor=$5
  mkdir -p "$state"
  printf 'arm_pid=111\twatcher_pid=222\torigin=started\tstarted_at=1000\tended_at=1010\texit_code=%s\tsignal=%s\treason=%s\tbeacon_age=3\tlock_before=pid:none|identity:none\tlock_after=pid:9|identity:k=v\tsuccessor=%s\n' \
    "$exit_code" "$signal" "$reason" "$successor" >> "$state/.watch-cycle-exits.log"
}

test_parses_the_final_record() {
  local state="$TMP_ROOT/parse"
  write_row "$state" actionable-signal none 0 none
  write_row "$state" arm-interrupted TERM 143 none
  fm_cycle_last_row "$state" || fail "a well-formed ledger must parse"
  [ "$FM_CYCLE_REASON" = arm-interrupted ] || fail "reason: got $FM_CYCLE_REASON"
  [ "$FM_CYCLE_SIGNAL" = TERM ] || fail "signal: got $FM_CYCLE_SIGNAL"
  [ "$FM_CYCLE_EXIT_CODE" = 143 ] || fail "exit_code: got $FM_CYCLE_EXIT_CODE"
  [ "$FM_CYCLE_ARM_PID" = 111 ] || fail "arm_pid: got $FM_CYCLE_ARM_PID"
  [ "$FM_CYCLE_WATCHER_PID" = 222 ] || fail "watcher_pid: got $FM_CYCLE_WATCHER_PID"
  [ "$FM_CYCLE_ENDED_AT" = 1010 ] || fail "ended_at: got $FM_CYCLE_ENDED_AT"
  pass "cycle-lib: reads the last record, not an earlier one"
}

# lock_before/lock_after carry "=" inside their values; splitting on the wrong
# separator would silently corrupt every field after them.
test_values_containing_equals_do_not_corrupt_later_fields() {
  local state="$TMP_ROOT/equals"
  write_row "$state" arm-interrupted TERM 143 'started:777'
  fm_cycle_last_row "$state" || fail "row with = inside a value must parse"
  [ "$FM_CYCLE_SUCCESSOR" = 'started:777' ] || fail "successor after an =-bearing value: got $FM_CYCLE_SUCCESSOR"
  pass "cycle-lib: values containing = do not corrupt fields parsed after them"
}

test_absent_or_malformed_ledger_reports_nothing() {
  local state="$TMP_ROOT/absent"
  mkdir -p "$state"
  ! fm_cycle_last_row "$state" || fail "an absent ledger must not report a record"
  [ -z "$FM_CYCLE_REASON" ] || fail "absent ledger left FM_CYCLE_REASON set: $FM_CYCLE_REASON"
  printf 'not a ledger row\n' > "$state/.watch-cycle-exits.log"
  ! fm_cycle_last_row "$state" || fail "a malformed final line must not report a record"
  ! fm_cycle_describe "$state" >/dev/null || fail "a malformed ledger must produce no evidence line"
  pass "cycle-lib: an absent or malformed ledger reports nothing rather than guessing"
}

# A stale FM_CYCLE_* value surviving a failed read would let a banner describe
# some earlier home's cycle.
test_failed_read_clears_previous_values() {
  local good="$TMP_ROOT/good" empty="$TMP_ROOT/empty"
  write_row "$good" arm-interrupted TERM 143 none
  fm_cycle_last_row "$good" || fail "seed read must succeed"
  mkdir -p "$empty"
  ! fm_cycle_last_row "$empty" || fail "empty state must fail the read"
  [ -z "$FM_CYCLE_SIGNAL" ] && [ -z "$FM_CYCLE_ARM_PID" ] \
    || fail "a failed read left stale values: signal=$FM_CYCLE_SIGNAL arm_pid=$FM_CYCLE_ARM_PID"
  pass "cycle-lib: a failed read clears every field instead of leaking the previous one"
}

test_interrupted_predicate_is_exact() {
  local killed="$TMP_ROOT/killed" woke="$TMP_ROOT/woke"
  write_row "$killed" arm-interrupted TERM 143 none
  fm_cycle_last_was_interrupted "$killed" || fail "reason=arm-interrupted must report an interrupted cycle"
  write_row "$woke" actionable-signal none 0 none
  ! fm_cycle_last_was_interrupted "$woke" || fail "an actionable close must not report an interrupted cycle"
  pass "cycle-lib: only a signalled arm counts as an interrupted cycle"
}

test_ended_supervision_predicate_separates_wakes_from_ends() {
  local state
  for state in arm-interrupted attached-cycle-ended confirmation-timeout nonzero-exit; do
    write_row "$TMP_ROOT/ended-$state" "$state" TERM 143 none
    fm_cycle_last_ended_supervision "$TMP_ROOT/ended-$state" \
      || fail "reason=$state must count as a cycle that ended supervision"
  done
  for state in actionable-signal actionable-stale actionable-check actionable-heartbeat; do
    write_row "$TMP_ROOT/wake-$state" "$state" none 0 none
    ! fm_cycle_last_ended_supervision "$TMP_ROOT/wake-$state" \
      || fail "reason=$state propagated a wake and must not count as ending supervision"
  done
  pass "cycle-lib: actionable wakes are separated from cycles that ended supervision"
}

test_describe_names_a_termination_as_a_kill() {
  local state="$TMP_ROOT/describe" out
  write_row "$state" arm-interrupted TERM 143 none
  out=$(fm_cycle_describe "$state")
  assert_contains "$out" "TERMINATED" "an interrupted cycle must be described as terminated, not ended"
  assert_contains "$out" "TERM" "the description must name the delivered signal"
  pass "cycle-lib: an interrupted cycle is described as a kill, not a clean end"
}

# successor= is only ever back-filled by an adapter that passes
# FM_WATCH_PREDECESSOR_ARM_PID (the opencode plugin and the pi extension), so on
# every other primary it reads "none" even when a healthy successor took over.
# Quoting it in a banner would assert supervision was lost on evidence that
# cannot support the claim.
test_describe_never_quotes_the_successor_field() {
  local state="$TMP_ROOT/no-successor-claim" out
  write_row "$state" arm-interrupted TERM 143 none
  out=$(fm_cycle_describe "$state")
  case "$out" in
    *successor*) fail "the evidence line must not cite the unreliable successor field: $out" ;;
  esac
  pass "cycle-lib: the evidence line never cites the unreliable successor field"
}

test_parses_the_final_record
test_values_containing_equals_do_not_corrupt_later_fields
test_absent_or_malformed_ledger_reports_nothing
test_failed_read_clears_previous_values
test_interrupted_predicate_is_exact
test_ended_supervision_predicate_separates_wakes_from_ends
test_describe_names_a_termination_as_a_kill
test_describe_never_quotes_the_successor_field
