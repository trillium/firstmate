#!/usr/bin/env bash
# Behavior tests for bin/fm-ledger.sh: surfacing and closing likely_dropped
# beads (claimed, unclosed, gone quiet longer than --stale-days).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-ledger)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A fake `task` (beads CLI). `query` filters a fixed three-bead fixture by the
# --stale-days threshold embedded in the query expression's `updated<Nd` token,
# mimicking "claimed, unclosed, idle at least N days". `close <id>` logs to
# FM_TEST_LEDGER_CALLS_LOG and succeeds, except for id "bead-fail" which always
# fails, so callers can assert on the warn-and-continue path.
make_task_mock() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/task" <<'SH'
#!/usr/bin/env bash
set -u
FIXTURE='[
  {"id":"bead-a","title":"Old dropped work","status":"open","updated_at":"2026-07-01T00:00:00Z","days_idle":10},
  {"id":"bead-c","title":"Medium idle claim","status":"open","updated_at":"2026-07-27T00:00:00Z","days_idle":5},
  {"id":"bead-b","title":"Fresh claim","status":"open","updated_at":"2026-07-30T00:00:00Z","days_idle":1}
]'
case "${1:-}" in
  query)
    expr=$2
    n=$(printf '%s' "$expr" | sed -n -E 's/.*updated<([0-9]+)d.*/\1/p')
    [ -n "$n" ] || n=0
    printf '%s' "$FIXTURE" | jq --argjson n "$n" '[.[] | select(.days_idle >= $n)]'
    ;;
  close)
    id=$2
    if [ "$id" = bead-fail ]; then
      echo "mock: refusing to close $id" >&2
      exit 1
    fi
    printf '%s\n' "close $id" >> "${FM_TEST_LEDGER_CALLS_LOG:?FM_TEST_LEDGER_CALLS_LOG not set}"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/task"
  printf '%s\n' "$fb"
}

run_ledger() {  # [args...]
  "$LEDGER" "$@"
}

test_ledger_lists_likely_dropped_default_threshold() {
  local case_dir fb out rc
  case_dir="$TMP_ROOT/list-default"
  mkdir -p "$case_dir"
  fb=$(make_task_mock "$case_dir")

  set +e
  out=$(PATH="$fb:$PATH" run_ledger)
  rc=$?
  set -e

  expect_code 0 "$rc" "list-default: fm-ledger.sh should succeed"
  assert_contains "$out" "bead-a" "list-default: missing stale bead-a (idle 10d)"
  assert_contains "$out" "bead-c" "list-default: missing stale bead-c (idle 5d)"
  assert_not_contains "$out" "bead-b" "list-default: bead-b (idle 1d) should not be listed under the 2d default"
  assert_contains "$out" "--close" "list-default: missing the close hint"
  pass "fm-ledger.sh lists claimed, unclosed, idle beads under the default 2-day threshold"
}

test_ledger_json_mode_shapes_output() {
  local case_dir fb out rc ids
  case_dir="$TMP_ROOT/json-mode"
  mkdir -p "$case_dir"
  fb=$(make_task_mock "$case_dir")

  set +e
  out=$(PATH="$fb:$PATH" run_ledger --json)
  rc=$?
  set -e

  expect_code 0 "$rc" "json-mode: fm-ledger.sh --json should succeed"
  ids=$(printf '%s' "$out" | jq -r '.[].id' | sort | tr '\n' ' ')
  [ "$ids" = "bead-a bead-c " ] || fail "json-mode: expected ids 'bead-a bead-c', got '$ids'"
  [ "$(printf '%s' "$out" | jq '[.[] | .likely_dropped] | all')" = true ] \
    || fail "json-mode: every entry should have likely_dropped: true"
  pass "fm-ledger.sh --json emits only the likely_dropped beads, each flagged"
}

test_ledger_stale_days_threshold_changes_results() {
  local case_dir fb out_zero out_high rc
  case_dir="$TMP_ROOT/stale-days"
  mkdir -p "$case_dir"
  fb=$(make_task_mock "$case_dir")

  set +e
  out_zero=$(PATH="$fb:$PATH" run_ledger --stale-days 0)
  rc=$?
  set -e
  expect_code 0 "$rc" "stale-days=0: fm-ledger.sh should succeed"
  assert_contains "$out_zero" "bead-b" "stale-days=0: bead-b should appear once the threshold drops to 0"

  set +e
  out_high=$(PATH="$fb:$PATH" run_ledger --stale-days 6)
  rc=$?
  set -e
  expect_code 0 "$rc" "stale-days=6: fm-ledger.sh should succeed"
  assert_contains "$out_high" "bead-a" "stale-days=6: bead-a (idle 10d) should still appear"
  assert_not_contains "$out_high" "bead-c" "stale-days=6: bead-c (idle 5d) should drop out above the threshold"
  pass "fm-ledger.sh --stale-days changes which beads are surfaced"
}

test_ledger_close_specific_ids() {
  local case_dir fb out rc log
  case_dir="$TMP_ROOT/close-specific"
  mkdir -p "$case_dir"
  fb=$(make_task_mock "$case_dir")
  log="$case_dir/calls.log"

  set +e
  out=$(FM_TEST_LEDGER_CALLS_LOG="$log" PATH="$fb:$PATH" run_ledger --close bead-a bead-c)
  rc=$?
  set -e

  expect_code 0 "$rc" "close-specific: closing known ids should succeed"
  assert_contains "$out" "closed bead-a" "close-specific: missing confirmation for bead-a"
  assert_contains "$out" "closed bead-c" "close-specific: missing confirmation for bead-c"
  assert_grep "close bead-a" "$log" "close-specific: task close was not called for bead-a"
  assert_grep "close bead-c" "$log" "close-specific: task close was not called for bead-c"
  pass "fm-ledger.sh --close closes exactly the given bead ids"
}

test_ledger_close_requires_at_least_one_id() {
  local case_dir fb err rc
  case_dir="$TMP_ROOT/close-no-ids"
  mkdir -p "$case_dir"
  fb=$(make_task_mock "$case_dir")

  set +e
  err=$(PATH="$fb:$PATH" run_ledger --close 2>&1 >/dev/null)
  rc=$?
  set -e

  expect_code 2 "$rc" "close-no-ids: --close with no ids should error"
  assert_contains "$err" "requires at least one bead id" "close-no-ids: missing the expected error text"
  pass "fm-ledger.sh --close with no ids errors instead of closing nothing silently"
}

test_ledger_close_all_without_yes_previews_only() {
  local case_dir fb out rc log
  case_dir="$TMP_ROOT/close-all-preview"
  mkdir -p "$case_dir"
  fb=$(make_task_mock "$case_dir")
  log="$case_dir/calls.log"

  set +e
  out=$(FM_TEST_LEDGER_CALLS_LOG="$log" PATH="$fb:$PATH" run_ledger --close-all)
  rc=$?
  set -e

  expect_code 0 "$rc" "close-all-preview: preview mode should succeed"
  assert_contains "$out" "would close" "close-all-preview: missing the preview label"
  assert_contains "$out" "bead-a" "close-all-preview: missing bead-a in the preview"
  assert_contains "$out" "--yes" "close-all-preview: missing the --yes hint"
  assert_absent "$log" "close-all-preview: task close should not run without --yes"
  pass "fm-ledger.sh --close-all without --yes only previews what would close"
}

test_ledger_close_all_with_yes_closes_everything_listed() {
  local case_dir fb out rc log
  case_dir="$TMP_ROOT/close-all-yes"
  mkdir -p "$case_dir"
  fb=$(make_task_mock "$case_dir")
  log="$case_dir/calls.log"

  set +e
  out=$(FM_TEST_LEDGER_CALLS_LOG="$log" PATH="$fb:$PATH" run_ledger --close-all --yes)
  rc=$?
  set -e

  expect_code 0 "$rc" "close-all-yes: --close-all --yes should succeed"
  assert_contains "$out" "closed bead-a" "close-all-yes: bead-a was not reported closed"
  assert_contains "$out" "closed bead-c" "close-all-yes: bead-c was not reported closed"
  assert_grep "close bead-a" "$log" "close-all-yes: task close was not called for bead-a"
  assert_grep "close bead-c" "$log" "close-all-yes: task close was not called for bead-c"
  pass "fm-ledger.sh --close-all --yes closes every currently-listed likely_dropped bead"
}

test_ledger_close_all_none_found() {
  local case_dir fb out rc
  case_dir="$TMP_ROOT/close-all-none"
  mkdir -p "$case_dir"
  fb=$(make_task_mock "$case_dir")

  set +e
  out=$(PATH="$fb:$PATH" run_ledger --close-all --yes --stale-days 999)
  rc=$?
  set -e

  expect_code 0 "$rc" "close-all-none: should succeed with nothing to close"
  assert_contains "$out" "no likely-dropped beads to close" "close-all-none: missing the empty-set message"
  pass "fm-ledger.sh --close-all reports cleanly when nothing is likely_dropped"
}

test_ledger_close_failure_warns_and_exits_nonzero() {
  local case_dir fb err rc
  case_dir="$TMP_ROOT/close-failure"
  mkdir -p "$case_dir"
  fb=$(make_task_mock "$case_dir")

  set +e
  err=$(FM_TEST_LEDGER_CALLS_LOG="$case_dir/calls.log" PATH="$fb:$PATH" run_ledger --close bead-fail 2>&1 >/dev/null)
  rc=$?
  set -e

  expect_code 1 "$rc" "close-failure: a rejected close should exit nonzero"
  assert_contains "$err" "could not close bead-fail" "close-failure: missing the warning for the failed close"
  pass "fm-ledger.sh --close warns and exits nonzero when the CLI rejects a close"
}

test_ledger_missing_task_cli_errors() {
  local case_dir path_without_task err rc
  case_dir="$TMP_ROOT/missing-cli"
  mkdir -p "$case_dir"
  path_without_task=$(fm_path_without task)

  set +e
  err=$(PATH="$path_without_task" run_ledger 2>&1 >/dev/null)
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-cli: fm-ledger.sh should error without the task CLI"
  assert_contains "$err" "task CLI not found" "missing-cli: missing the expected error text"
  pass "fm-ledger.sh errors clearly when the task CLI is not on PATH"
}

test_ledger_lists_likely_dropped_default_threshold
test_ledger_json_mode_shapes_output
test_ledger_stale_days_threshold_changes_results
test_ledger_close_specific_ids
test_ledger_close_requires_at_least_one_id
test_ledger_close_all_without_yes_previews_only
test_ledger_close_all_with_yes_closes_everything_listed
test_ledger_close_all_none_found
test_ledger_close_failure_warns_and_exits_nonzero
test_ledger_missing_task_cli_errors
