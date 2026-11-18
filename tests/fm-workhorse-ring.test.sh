#!/usr/bin/env bash
# tests/fm-workhorse-ring.test.sh - fm-workhorse-ring.sh doorbell and refusals.
#
# Covers: the one-line routed send through fm-send with an explicit home and
# mate, the exit when fm-send does not confirm delivery, and the refusals that
# must ring nothing (no home chosen, bad bead id, absent bead, bead without the
# workhorse label, absent pinned store).
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/workhorse-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/workhorse-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-workhorse-ring)
wh_world "$TMP_ROOT/w"
RING="$WH_BIN/fm-workhorse-ring.sh"
WORK_BEAD=$(wh_seed "A workhorse bead for the ring" "workhorse,fleet:firstmate" "body")
PLAIN_BEAD=$(wh_seed "An ordinary bead with no workhorse label" "fleet:firstmate" "body")

# ring <args...> - run the ring from the decoy cwd with FM_HOME set.
ring() {
  (cd "$WH_DECOY" && FM_HOME="$WH_HOME" "$RING" "$@")
}

test_rings_one_routed_line_with_explicit_home() {
  local out sent
  out=$(ring "$WORK_BEAD" 2>&1) || fail "ringing a workhorse bead should succeed: $out"
  assert_contains "$out" "rang workhorse-mate for $WORK_BEAD" "success is stated"
  sent=$(cat "$WH_SEND_LOG")
  assert_equals "1" "$(printf '%s\n' "$sent" | grep -c .)" "exactly one send"
  assert_contains "$sent" "FM_HOME=$WH_HOME|workhorse-mate workhorse bead $WORK_BEAD filed: " "target, explicit home, and bead id"
  assert_contains "$sent" "bin/fm-workhorse-claim.sh list" "the line says how to find the bead"
  assert_equals "1" "$(printf '%s\n' "$sent" | wc -l | tr -d ' ')" "the doorbell is a single line"
  pass "the ring is one routed line through fm-send to the mate with FM_HOME explicit"
}

test_home_and_mate_overrides() {
  : >"$WH_SEND_LOG"
  (cd "$WH_DECOY" && FM_HOME="$WH_HOME" FM_WORKHORSE_HOME="$TMP_ROOT/other-home" FM_WORKHORSE_MATE=bench-mate "$RING" "$WORK_BEAD") >/dev/null \
    || fail "overrides should ring"
  assert_contains "$(cat "$WH_SEND_LOG")" "FM_HOME=$TMP_ROOT/other-home|bench-mate " "FM_WORKHORSE_HOME and FM_WORKHORSE_MATE win"
  pass "FM_WORKHORSE_HOME and FM_WORKHORSE_MATE select the home and mate"
}

test_unconfirmed_delivery_exits_3_with_the_cause() {
  local out rc=0
  out=$(WH_SEND_RC=1 ring "$WORK_BEAD" 2>&1) || rc=$?
  expect_code 3 "$rc" "an unconfirmed doorbell" "$out"
  assert_contains "$out" "UNCONFIRMED" "the message says the mate was not confirmed notified"
  assert_contains "$out" "fm-send exit 1" "fm-send's exit is reported"
  assert_contains "$out" "bin/fm-workhorse-ring.sh $WORK_BEAD" "the exact re-ring is named"
  assert_not_contains "$out" "rang workhorse-mate" "a failed ring is never reported as delivered"
  pass "an unconfirmed send exits 3 and says so"
}

test_refusals_ring_nothing() {
  local out rc
  : >"$WH_SEND_LOG"

  rc=0; out=$(cd "$WH_DECOY" && env -u FM_HOME -u FM_WORKHORSE_HOME "$RING" "$WORK_BEAD" 2>&1) || rc=$?
  expect_code 2 "$rc" "no home chosen" "$out"
  assert_contains "$out" "FM_WORKHORSE_HOME or FM_HOME" "the missing home is named"

  rc=0; out=$(ring "../escape" 2>&1) || rc=$?
  expect_code 2 "$rc" "a path-like bead id" "$out"
  rc=0; out=$(ring "--flag" 2>&1) || rc=$?
  expect_code 2 "$rc" "a flag-like bead id" "$out"
  rc=0; out=$(ring 2>&1) || rc=$?
  expect_code 2 "$rc" "no bead id" "$out"
  rc=0; out=$(ring "$WORK_BEAD" extra 2>&1) || rc=$?
  expect_code 2 "$rc" "an extra argument" "$out"

  rc=0; out=$(ring "task-nope" 2>&1) || rc=$?
  expect_code 1 "$rc" "an absent bead" "$out"
  assert_contains "$out" "was not found in the pinned task store" "the absent bead is named"

  rc=0; out=$(ring "$PLAIN_BEAD" 2>&1) || rc=$?
  expect_code 1 "$rc" "a bead without the workhorse label" "$out"
  assert_contains "$out" "does not carry the 'workhorse' label" "the missing label is named"

  rc=0; out=$(FM_WORKHORSE_BEADS_DIR="$TMP_ROOT/nowhere/.beads" ring "$WORK_BEAD" 2>&1) || rc=$?
  expect_code 1 "$rc" "an absent pinned store" "$out"
  assert_contains "$out" "refusing to fall back" "no fallback store"

  assert_equals "" "$(cat "$WH_SEND_LOG")" "no refusal sent anything"
  pass "refused rings send nothing: no home, bad id, absent bead, unlabelled bead, absent store"
}

test_reads_the_pinned_store_from_a_foreign_cwd() {
  assert_not_contains "$(cut -d'|' -f1,2 "$WH_LOG" | sort -u)" "$WH_DECOY" "no store call used the caller's cwd or its .beads"
  assert_contains "$(cut -d'|' -f2 "$WH_LOG" | sort -u)" "$WH_STORE" "calls carried the pinned BEADS_DIR"
  pass "the ring's bead lookup is pinned to the task store regardless of cwd"
}

fm_test_run \
  test_rings_one_routed_line_with_explicit_home \
  test_home_and_mate_overrides \
  test_unconfirmed_delivery_exits_3_with_the_cause \
  test_refusals_ring_nothing \
  test_reads_the_pinned_store_from_a_foreign_cwd
