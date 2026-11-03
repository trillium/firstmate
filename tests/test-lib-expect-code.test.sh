#!/usr/bin/env bash
# tests/test-lib-expect-code.test.sh - the shared expect_code helper must name
# the captured command output when a status check fails, and stay silent when
# it passes, so a red run says why instead of only "expected exit 0, got 1".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Run expect_code in a child shell, because a mismatch calls fail, which exits.
run_expect_code() {
  ( # shellcheck source=tests/lib.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lib.sh" && expect_code "$@" ) 2>&1
}

test_expect_code_passing_run_is_silent() {
  local out status
  out=$(run_expect_code 0 0 "label" "captured text")
  status=$?
  [ "$status" -eq 0 ] || fail "a matching status must pass, got exit $status: $out"
  [ -z "$out" ] || fail "a passing expect_code must print nothing, got: $out"
  pass "expect_code stays silent when the status matches"
}

test_expect_code_failure_prints_captured_output() {
  local out status
  out=$(run_expect_code 0 1 "the spawn should succeed" $'boom: the real cause\nsecond line')
  status=$?
  [ "$status" -ne 0 ] || fail "a mismatched status must fail"
  assert_contains "$out" "the spawn should succeed: expected exit 0, got 1" "failure lost the label and codes"
  assert_contains "$out" "--- output ---" "failure did not mark the captured output"
  assert_contains "$out" "boom: the real cause" "failure did not print the captured output"
  assert_contains "$out" "second line" "failure truncated the captured output"
  pass "expect_code prints the captured output on a mismatch"
}

test_expect_code_failure_without_output_keeps_the_short_form() {
  local out status
  out=$(run_expect_code 0 1 "bare check")
  status=$?
  [ "$status" -ne 0 ] || fail "a mismatched status must fail"
  assert_contains "$out" "bare check: expected exit 0, got 1" "bare failure lost the label and codes"
  assert_not_contains "$out" "--- output ---" "a call without output must not print an empty output section"
  out=$(run_expect_code 0 1 "empty capture" "")
  assert_not_contains "$out" "--- output ---" "an empty capture must not print an empty output section"
  pass "expect_code keeps the short form when there is no captured output"
}

test_expect_code_passing_run_is_silent
test_expect_code_failure_prints_captured_output
test_expect_code_failure_without_output_keeps_the_short_form
