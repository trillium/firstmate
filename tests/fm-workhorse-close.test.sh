#!/usr/bin/env bash
# tests/fm-workhorse-close.test.sh - fm-workhorse-close.sh evidence-gated close.
#
# Covers: closing only when every evidence kind the bead names is supplied and
# well formed (PR link, report path, command output), the comment and close
# reason recorded on success, and every refusal - missing, malformed, or
# unrelated evidence, an unclaimed or already closed bead, an unlabelled or
# evidence-less bead, a bad id, an absent store - each of which must write
# nothing to the bead. A comment that lands before a failed close is reported.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/workhorse-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/workhorse-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-workhorse-close)
wh_world "$TMP_ROOT/w"
CLOSE="$WH_BIN/fm-workhorse-close.sh"
PR_URL="https://github.com/example/demo-project/pull/42"

close() {
  (cd "$WH_DECOY" && "$CLOSE" "$@")
}

bead_field() {  # <bead-id> <jq-field>
  jq -r --arg id "$1" ".[] | select(.id == \$id) | $2" "$WH_STORE/store.json"
}

claim_directly() {  # <bead-id>
  BEADS_DIR="$WH_STORE" task update "$1" --if-assignee '' --assignee bench-mate --status in_progress
}

# expect_untouched <label> <bead-id>: nothing written, bead still claimed.
expect_untouched() {
  assert_equals "in_progress" "$(bead_field "$2" .status)" "$1 must not close the bead"
  assert_equals "0" "$(bead_field "$2" '.comments | length')" "$1 must not comment"
}

# A bead naming a PR link and command output, one naming only a report path.
PR_CMD_BEAD=$(wh_file_valid --title "Bead that wants a PR and command output" 2>/dev/null)
REPORT_BEAD=$(wh_file_no_evidence --title "Bead that wants only a report path" \
  --evidence "report:the written findings report" 2>/dev/null)
claim_directly "$PR_CMD_BEAD"
claim_directly "$REPORT_BEAD"

test_refuses_when_named_evidence_is_missing() {
  local out rc=0
  out=$(close "$PR_CMD_BEAD" 2>&1) || rc=$?
  expect_code 2 "$rc" "no evidence at all" "$out"
  assert_contains "$out" "--pr <url>" "the missing PR link is named"
  assert_contains "$out" "--command-output" "the missing command output is named"
  expect_untouched "no evidence" "$PR_CMD_BEAD"

  rc=0; out=$(close "$PR_CMD_BEAD" --pr "$PR_URL" 2>&1) || rc=$?
  expect_code 2 "$rc" "only one of two named kinds" "$out"
  assert_contains "$out" "--command-output" "the still-missing kind is named"
  assert_not_contains "$out" "--pr <url>" "the supplied kind is not re-requested"
  expect_untouched "half the evidence" "$PR_CMD_BEAD"

  printf 'a real report\n' >"$TMP_ROOT/report.md"
  rc=0; out=$(close "$PR_CMD_BEAD" --report "$TMP_ROOT/report.md" 2>&1) || rc=$?
  expect_code 2 "$rc" "an unrelated kind standing in for the named ones" "$out"
  expect_untouched "an unrelated evidence kind" "$PR_CMD_BEAD"
  pass "close refuses until every evidence kind the bead names is supplied"
}

test_refuses_malformed_evidence() {
  local out rc
  : >"$TMP_ROOT/empty.md"
  rc=0; out=$(close "$PR_CMD_BEAD" --pr "http://example.com/pull/1" --command-output "all tests passed ok" 2>&1) || rc=$?
  expect_code 2 "$rc" "a non-https PR link" "$out"
  assert_contains "$out" "full https:// URL" "the URL rule is named"
  rc=0; out=$(close "$PR_CMD_BEAD" --pr "PR 42" --command-output "all tests passed ok" 2>&1) || rc=$?
  expect_code 2 "$rc" "a bare PR number" "$out"
  rc=0; out=$(close "$PR_CMD_BEAD" --pr "$PR_URL" --command-output "ok" 2>&1) || rc=$?
  expect_code 2 "$rc" "a token command output" "$out"
  assert_contains "$out" "no real output" "the empty output is named"
  rc=0; out=$(close "$PR_CMD_BEAD" --pr "$PR_URL" --command-output "@$TMP_ROOT/no-such-file" 2>&1) || rc=$?
  expect_code 2 "$rc" "a missing output file" "$out"
  rc=0; out=$(close "$REPORT_BEAD" --report "$TMP_ROOT/no-such-report.md" 2>&1) || rc=$?
  expect_code 2 "$rc" "a missing report" "$out"
  assert_contains "$out" "not an existing, non-empty file" "the report rule is named"
  rc=0; out=$(close "$REPORT_BEAD" --report "$TMP_ROOT/empty.md" 2>&1) || rc=$?
  expect_code 2 "$rc" "an empty report" "$out"
  expect_untouched "malformed evidence" "$PR_CMD_BEAD"
  expect_untouched "a bad report" "$REPORT_BEAD"
  pass "close refuses malformed PR links, token or missing output, and missing or empty reports"
}

test_refuses_unclaimed_unlabelled_evidenceless_and_bad_ids() {
  local open_bead plain legacy out rc
  open_bead=$(wh_file_valid --title "Bead that nobody has claimed yet" 2>/dev/null)
  plain=$(wh_seed "An ordinary bead without the label" "fleet:firstmate" "body")
  legacy=$(wh_seed "A legacy one-line workhorse bead" "workhorse")
  BEADS_DIR="$WH_STORE" task update "$legacy" --if-assignee '' --assignee bench-mate --status in_progress

  rc=0; out=$(close "$open_bead" --pr "$PR_URL" --command-output "all tests passed ok" 2>&1) || rc=$?
  expect_code 2 "$rc" "closing an unclaimed bead" "$out"
  assert_contains "$out" "only a claimed (in_progress)" "the claim rule is named"
  assert_equals "open" "$(bead_field "$open_bead" .status)" "the unclaimed bead stays open"

  rc=0; out=$(close "$plain" --pr "$PR_URL" 2>&1) || rc=$?
  expect_code 2 "$rc" "closing an unlabelled bead" "$out"
  assert_contains "$out" "does not carry the 'workhorse' label" "the label rule is named"

  rc=0; out=$(close "$legacy" --pr "$PR_URL" 2>&1) || rc=$?
  expect_code 2 "$rc" "closing a bead that names no evidence" "$out"
  assert_contains "$out" "names no evidence kind" "the missing evidence section is named"
  assert_equals "in_progress" "$(bead_field "$legacy" .status)" "the evidence-less bead stays open"

  rc=0; out=$(close "../escape" --pr "$PR_URL" 2>&1) || rc=$?
  expect_code 2 "$rc" "a path-like bead id" "$out"
  rc=0; out=$(close 2>&1) || rc=$?
  expect_code 2 "$rc" "no bead id" "$out"
  rc=0; out=$(close "$PR_CMD_BEAD" --bogus x 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown flag" "$out"
  rc=0; out=$(close "$PR_CMD_BEAD" --pr 2>&1) || rc=$?
  expect_code 2 "$rc" "a flag with no value" "$out"
  rc=0; out=$(close task-nope --pr "$PR_URL" 2>&1) || rc=$?
  expect_code 2 "$rc" "an absent bead" "$out"
  rc=0; out=$(FM_WORKHORSE_BEADS_DIR="$TMP_ROOT/nowhere/.beads" close "$PR_CMD_BEAD" --pr "$PR_URL" 2>&1) || rc=$?
  expect_code 1 "$rc" "an absent pinned store" "$out"
  assert_contains "$out" "refusing to fall back" "no fallback store"
  expect_untouched "these refusals" "$PR_CMD_BEAD"
  pass "close refuses unclaimed, unlabelled, evidence-less, absent, and badly addressed beads"
}

test_closes_with_the_named_evidence_and_records_it() {
  local out reason comment
  printf 'cmd: ./run-tests\n42 passed, 0 failed\n' >"$TMP_ROOT/output.txt"
  out=$(close "$PR_CMD_BEAD" --pr "$PR_URL" --command-output "@$TMP_ROOT/output.txt" --note "landed cleanly" 2>&1) \
    || fail "closing with the named evidence should succeed: $out"
  assert_contains "$out" "closed $PR_CMD_BEAD with evidence" "success is stated"
  assert_contains "$out" "answer-to: porter" "the filing mate to answer is printed"
  assert_equals "closed" "$(bead_field "$PR_CMD_BEAD" .status)" "the bead is closed"
  comment=$(bead_field "$PR_CMD_BEAD" '.comments[0]')
  assert_contains "$comment" "- PR link: $PR_URL" "the PR link is commented"
  assert_contains "$comment" "42 passed, 0 failed" "the command output is commented"
  assert_contains "$comment" "- Note: landed cleanly" "the note is commented"
  reason=$(bead_field "$PR_CMD_BEAD" .close_reason)
  assert_contains "$reason" "Evidence supplied:" "the close reason says evidence was supplied"
  assert_contains "$reason" "PR $PR_URL" "the close reason names the PR"
  pass "close with the named evidence comments it, closes with a reason, and names the answer-to mate"
}

test_report_evidence_and_extra_kinds() {
  local out
  printf 'findings\n' >"$TMP_ROOT/findings.md"
  out=$(close "$REPORT_BEAD" --report "$TMP_ROOT/findings.md" 2>&1) || fail "a report-evidence bead should close on a report: $out"
  assert_equals "closed" "$(bead_field "$REPORT_BEAD" .status)" "the report bead is closed"
  assert_contains "$(bead_field "$REPORT_BEAD" '.comments[0]')" "- Report path: $TMP_ROOT/findings.md" "the report path is commented"
  pass "a bead naming a report closes on that report"
}

test_closed_bead_cannot_be_closed_again() {
  local out rc=0
  out=$(close "$PR_CMD_BEAD" --pr "$PR_URL" --command-output "all tests passed ok" 2>&1) || rc=$?
  expect_code 2 "$rc" "closing a closed bead" "$out"
  assert_contains "$out" "is closed" "the closed state is named"
  assert_equals "1" "$(bead_field "$PR_CMD_BEAD" '.comments | length')" "no second comment was added"
  pass "an already closed bead is refused"
}

test_store_failures_are_reported() {
  local bead out rc=0
  bead=$(wh_file_no_evidence --title "Bead for the failed close check" --evidence "report:the findings report path" 2>/dev/null)
  claim_directly "$bead"
  out=$(FAKE_CLOSE_RC=1 close "$bead" --report "$TMP_ROOT/findings.md" 2>&1) || rc=$?
  expect_code 1 "$rc" "a close that fails after the comment" "$out"
  assert_contains "$out" "evidence is recorded" "the recorded evidence is reported"
  assert_contains "$out" "re-run this command" "the retry is named"
  assert_equals "in_progress" "$(bead_field "$bead" .status)" "the bead is not closed"
  pass "a failed close after the evidence comment is reported with the retry"
}

test_store_is_pinned() {
  assert_not_contains "$(cut -d'|' -f1,2 "$WH_LOG" | sort -u)" "$WH_DECOY" "no call used the caller's cwd or its .beads"
  assert_equals "0" "$(wh_store_count "$WH_DECOY/.beads")" "the decoy store stayed empty"
  pass "close reaches only the pinned task store"
}

fm_test_run \
  test_refuses_when_named_evidence_is_missing \
  test_refuses_malformed_evidence \
  test_refuses_unclaimed_unlabelled_evidenceless_and_bad_ids \
  test_closes_with_the_named_evidence_and_records_it \
  test_report_evidence_and_extra_kinds \
  test_closed_bead_cannot_be_closed_again \
  test_store_failures_are_reported \
  test_store_is_pinned
