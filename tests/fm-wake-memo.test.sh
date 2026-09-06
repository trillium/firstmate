#!/usr/bin/env bash
# tests/fm-wake-memo.test.sh - wake-drain memo round trip through the executables:
# drain emits a pending identity, the handler appends the outcome, a repeat
# consult absorbs with a citation, and genuinely new wakes pass through. Growth
# stays bounded, and raw payload bytes never land in the memo.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
MEMO="$ROOT/bin/fm-wake-memo.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-memo-tests)

memo_file() {
  printf '%s/.wake-memo' "$1"
}

test_drain_emits_pending_identity_without_raw_payload() {
  local dir state memo
  dir=$(make_case drain-pending)
  state="$dir/state"
  memo=$(memo_file "$state")
  append_wake "$state" stale "test:fm-memo" "stale: test:fm-memo SECRET-PAYLOAD-AAA" || fail "append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null || fail "drain failed"
  assert_present "$memo" "drain did not create the memo file"
  assert_no_grep "absorbed-benign" "$memo" "drain emitted an outcome instead of a pending identity"
  assert_no_grep "reconciled-idle" "$memo" "drain emitted an outcome instead of a pending identity"
  grep -F "pending" "$memo" >/dev/null || fail "drain did not emit a pending identity"
  assert_no_grep "SECRET-PAYLOAD-AAA" "$memo" "raw payload bytes leaked into the memo"
  pass "drain emits a pending identity and stores no raw payload"
}

test_pending_is_idempotent_across_drains() {
  local dir state memo count
  dir=$(make_case pending-idem)
  state="$dir/state"
  memo=$(memo_file "$state")
  append_wake "$state" stale "test:fm-idem" "stale: test:fm-idem" || fail "first append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null || fail "first drain failed"
  append_wake "$state" stale "test:fm-idem" "stale: test:fm-idem" || fail "second append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null || fail "second drain failed"
  count=$(grep -c -F "test:fm-idem" "$memo" || true)
  [ "$count" -eq 1 ] || fail "repeated drains duplicated the pending identity ($count lines)"
  pass "repeated drains keep one pending identity per wake"
}

test_outcome_then_repeat_consult_hits_with_citation() {
  local dir state cite
  dir=$(make_case consult-hit)
  state="$dir/state"
  FM_STATE_OVERRIDE="$state" "$MEMO" record stale "test:fm-hit" "stale: test:fm-hit" absorbed-benign || fail "record failed"
  cite=$(FM_STATE_OVERRIDE="$state" "$MEMO" consult stale "test:fm-hit" "stale: test:fm-hit") || fail "consult missed a previously absorbed wake"
  assert_contains "$cite" "absorbed-benign" "citation omitted the outcome"
  assert_contains "$cite" "test:fm-hit" "citation omitted the key"
  assert_not_contains "$cite" "stale: test:fm-hit" "citation leaked payload-derived text"
  pass "a repeated wake consults to a citation"
}

test_reconciled_idle_consults_as_hit() {
  local dir state
  dir=$(make_case consult-paused)
  state="$dir/state"
  FM_STATE_OVERRIDE="$state" "$MEMO" record stale "test:fm-paused" "stale: test:fm-paused" reconciled-idle || fail "record failed"
  FM_STATE_OVERRIDE="$state" "$MEMO" consult stale "test:fm-paused" "stale: test:fm-paused" >/dev/null || fail "consult missed a previously reconciled wake"
  pass "a reconciled-idle wake consults as a hit"
}

test_full_round_trip_drain_outcome_repeat() {
  local dir state memo cite
  dir=$(make_case round-trip)
  state="$dir/state"
  memo=$(memo_file "$state")
  append_wake "$state" heartbeat heartbeat "heartbeat | parlay: none held" || fail "append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null || fail "drain failed"
  FM_STATE_OVERRIDE="$state" "$MEMO" consult heartbeat heartbeat "heartbeat | parlay: none held" >/dev/null 2>&1 && fail "pending wake consulted as absorbed"
  FM_STATE_OVERRIDE="$state" "$MEMO" record heartbeat heartbeat "heartbeat | parlay: none held" absorbed-benign || fail "handler outcome record failed"
  cite=$(FM_STATE_OVERRIDE="$state" "$MEMO" consult heartbeat heartbeat "heartbeat | parlay: none held") || fail "repeat missed after the outcome landed"
  assert_contains "$cite" "memo:" "repeat citation missing the memo marker"
  assert_no_grep "parlay: none held" "$memo" "queue payload text leaked into the memo"
  pass "drain, outcome, and repeat absorption round-trip through the executables"
}

test_genuinely_new_wakes_pass_through() {
  local dir state
  dir=$(make_case consult-miss)
  state="$dir/state"
  FM_STATE_OVERRIDE="$state" "$MEMO" consult stale "test:fm-new" "stale: test:fm-new" >/dev/null 2>&1 && fail "unknown wake consulted as a hit"
  FM_STATE_OVERRIDE="$state" "$MEMO" record stale "test:fm-new" "stale: test:fm-new" absorbed-benign || fail "record failed"
  FM_STATE_OVERRIDE="$state" "$MEMO" consult stale "test:fm-new" "stale: test:fm-new-DRIFTED" >/dev/null 2>&1 && fail "drifted payload consulted as identical"
  FM_STATE_OVERRIDE="$state" "$MEMO" record stale "test:fm-acted" "stale: test:fm-acted" steered || fail "steered record failed"
  if FM_STATE_OVERRIDE="$state" "$MEMO" consult stale "test:fm-acted" "stale: test:fm-acted" >/dev/null 2>&1; then
    fail "previously steered wake consulted as absorbed"
  else
    pass "genuinely new, drifted, and previously actioned wakes pass through"
  fi
}

test_prune_bounds_growth_and_keeps_pending() {
  local dir state memo count
  dir=$(make_case prune-bound)
  state="$dir/state"
  memo=$(memo_file "$state")
  # Nothing counts as recent (KEEP_SECS=-1), so only latest-per-identity and
  # pending entries are protected and old superseded outcomes are prunable.
  FM_STATE_OVERRIDE="$state" FM_WAKE_MEMO_KEEP_SECS=-1 FM_WAKE_MEMO_MAX_LINES=5 \
    "$MEMO" record stale "test:fm-keep" "stale: test:fm-keep" pending || fail "pending record failed"
  for id in test:fm-prune-a test:fm-prune-b test:fm-prune-c; do
    FM_STATE_OVERRIDE="$state" FM_WAKE_MEMO_KEEP_SECS=-1 FM_WAKE_MEMO_MAX_LINES=100 \
      "$MEMO" record stale "$id" "stale: $id" absorbed-benign || fail "superseded record for $id failed"
    FM_STATE_OVERRIDE="$state" FM_WAKE_MEMO_KEEP_SECS=-1 FM_WAKE_MEMO_MAX_LINES=100 \
      "$MEMO" record stale "$id" "stale: $id" steered || fail "latest record for $id failed"
  done
  FM_STATE_OVERRIDE="$state" FM_WAKE_MEMO_KEEP_SECS=-1 FM_WAKE_MEMO_MAX_LINES=100 \
    "$MEMO" record stale "test:fm-prune-d" "stale: test:fm-prune-d" absorbed-benign || fail "kept absorb record failed"
  FM_STATE_OVERRIDE="$state" FM_WAKE_MEMO_KEEP_SECS=-1 FM_WAKE_MEMO_MAX_LINES=5 \
    "$MEMO" prune || fail "prune failed"
  count=$(awk 'END { print NR + 0 }' "$memo")
  [ "$count" -le 5 ] || fail "memo grew past its cap ($count lines)"
  grep -F "test:fm-keep" "$memo" >/dev/null || fail "prune deleted the unabsorbed pending entry"
  FM_STATE_OVERRIDE="$state" "$MEMO" consult stale "test:fm-prune-d" "stale: test:fm-prune-d" >/dev/null || fail "consult missed a kept identity after pruning"
  grep -F "test:fm-prune-a" "$memo" | grep -F "absorbed-benign" >/dev/null && fail "prune kept an old superseded outcome"
  pass "pruning bounds growth and never deletes unabsorbed entries"
}

test_invalid_input_fails_closed() {
  local dir state out rc
  dir=$(make_case invalid)
  state="$dir/state"
  out="$dir/record.out"
  rc=0; FM_STATE_OVERRIDE="$state" "$MEMO" record bogus "k" "p" pending >"$out" 2>&1 || rc=$?
  expect_code 2 "$rc" "record with a bad kind"
  rc=0; FM_STATE_OVERRIDE="$state" "$MEMO" record stale "k" "p" bogus >"$out" 2>&1 || rc=$?
  expect_code 2 "$rc" "record with a bad outcome"
  rc=0; FM_STATE_OVERRIDE="$state" "$MEMO" consult bogus "k" "p" >"$out" 2>&1 || rc=$?
  expect_code 2 "$rc" "consult with a bad kind"
  pass "invalid memo input fails closed"
}

test_drain_emits_pending_identity_without_raw_payload
test_pending_is_idempotent_across_drains
test_outcome_then_repeat_consult_hits_with_citation
test_reconciled_idle_consults_as_hit
test_full_round_trip_drain_outcome_repeat
test_genuinely_new_wakes_pass_through
test_prune_bounds_growth_and_keeps_pending
test_invalid_input_fails_closed
