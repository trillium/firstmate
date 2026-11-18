#!/usr/bin/env bash
# tests/fm-workhorse-claim.test.sh - fm-workhorse-claim.sh list and claim.
#
# Covers: list of unclaimed workhorse beads (claimed, closed, and unlabelled
# beads excluded; legacy one-line beads flagged incomplete), the guarded claim
# and its lost-race exit, the brief seeded from the bead through the real
# fm-brief.sh, the claim released when the scaffold fails, oldest-first pick
# when no id is named, and every refusal, each of which must leave the bead
# unclaimed. The real scripts run against a fake `task` store pinned away from
# the cwd.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/workhorse-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/workhorse-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-workhorse-claim)
wh_world "$TMP_ROOT/w"
CLAIM="$ROOT/bin/fm-workhorse-claim.sh"

claim() {
  (cd "$WH_DECOY" && FM_HOME="$WH_HOME" "$CLAIM" "$@")
}

bead_field() {  # <bead-id> <jq-field>
  jq -r --arg id "$1" ".[] | select(.id == \$id) | $2" "$WH_STORE/store.json"
}

file_bead() {  # <title> [overrides...] - file a full-brief bead, print its id
  local title=$1
  shift
  wh_file_valid --title "$title" "$@" 2>/dev/null
}

test_list_with_no_beads() {
  local out
  out=$(claim list) || fail "list on an empty store should succeed"
  assert_equals "no unclaimed workhorse beads" "$out" "an empty queue says so"
  pass "list reports an empty queue plainly"
}

test_list_shows_only_unclaimed_workhorse_beads() {
  local full legacy claimed out
  full=$(file_bead "First full workhorse brief for listing")
  legacy=$(wh_seed "A legacy one-line workhorse bead" "workhorse")
  claimed=$(file_bead "Second brief that gets claimed away")
  BEADS_DIR="$WH_STORE" task update "$claimed" --if-assignee '' --assignee someone --status in_progress
  wh_seed "An unrelated ordinary bead here" "fleet:firstmate" >/dev/null
  out=$(claim list) || fail "list should succeed"
  assert_contains "$out" "unclaimed $full brief=ok First full workhorse brief for listing" "a full brief lists as ok"
  assert_contains "$out" "unclaimed $legacy brief=incomplete A legacy one-line workhorse bead" "a one-line bead lists as incomplete"
  assert_not_contains "$out" "$claimed" "a claimed bead is not listed"
  assert_not_contains "$out" "unrelated" "an unlabelled bead is not listed"
  assert_equals "2" "$(printf '%s\n' "$out" | grep -c .)" "exactly the two unclaimed workhorse beads"
  pass "list shows unclaimed workhorse beads, flags incomplete briefs, and skips claimed or unlabelled ones"
}

test_claim_refusals_leave_the_bead_unclaimed() {
  local legacy out rc plain
  legacy=$(jq -r '.[] | select(.title == "A legacy one-line workhorse bead") | .id' "$WH_STORE/store.json")
  plain=$(jq -r '.[] | select(.title == "An unrelated ordinary bead here") | .id' "$WH_STORE/store.json")

  rc=0; out=$(claim claim "$legacy" 2>&1) || rc=$?
  expect_code 2 "$rc" "claiming a one-line bead" "$out"
  assert_contains "$out" "not a complete brief" "the incomplete brief is named"
  assert_contains "$out" "bin/fm-workhorse-file.sh" "the fix is named"
  assert_equals "open" "$(bead_field "$legacy" .status)" "the incomplete bead stays open"
  assert_equals "" "$(bead_field "$legacy" .assignee)" "the incomplete bead stays unassigned"

  rc=0; out=$(claim claim "$plain" 2>&1) || rc=$?
  expect_code 2 "$rc" "claiming an unlabelled bead" "$out"
  assert_contains "$out" "does not carry the 'workhorse' label" "the label rule is named"

  rc=0; out=$(claim claim task-nope 2>&1) || rc=$?
  expect_code 2 "$rc" "claiming an absent bead" "$out"

  rc=0; out=$(claim claim --as "bad mate" 2>&1) || rc=$?
  expect_code 2 "$rc" "a bad --as" "$out"
  rc=0; out=$(claim claim --bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown flag" "$out"
  rc=0; out=$(claim bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown verb" "$out"
  rc=0; out=$(cd "$WH_DECOY" && env -u FM_HOME "$CLAIM" claim 2>&1) || rc=$?
  expect_code 2 "$rc" "no FM_HOME" "$out"
  assert_contains "$out" "set FM_HOME" "the missing home is named"
  rc=0; out=$(FM_WORKHORSE_BEADS_DIR="$TMP_ROOT/nowhere/.beads" claim list 2>&1) || rc=$?
  expect_code 1 "$rc" "an absent pinned store" "$out"
  assert_contains "$out" "refusing to fall back" "no fallback store"
  assert_absent "$WH_HOME/data/wh-$plain" "a refused claim scaffolds no brief"
  pass "claim refusals (incomplete, unlabelled, absent, bad flags, no home, no store) leave beads untouched"
}

test_claim_takes_the_oldest_and_seeds_the_brief() {
  local out first brief
  first=$(jq -r '.[] | select(.title == "First full workhorse brief for listing") | .id' "$WH_STORE/store.json")
  out=$(claim claim --as bench-mate 2>&1) || fail "claim should succeed: $out"
  assert_contains "$out" "claimed $first as bench-mate" "the oldest unclaimed full brief is taken"
  assert_equals "in_progress" "$(bead_field "$first" .status)" "status becomes in_progress"
  assert_equals "bench-mate" "$(bead_field "$first" .assignee)" "assignee is the claimer"
  assert_contains "$out" "task-id: wh-$first" "the task id is derived from the bead"
  assert_contains "$out" "project: demo-project" "the project is passed on"
  assert_contains "$out" "mode: local-only" "the delivery mode is passed on"
  assert_contains "$out" "yolo: off" "the yolo posture is passed on"
  assert_contains "$out" "answer-to: porter" "the filing mate is passed on"
  brief=$(printf '%s\n' "$out" | sed -n 's/^brief: //p')
  assert_equals "$WH_HOME/data/wh-$first/brief.md" "$brief" "the brief lands under the mate's data"
  assert_not_contains "$(cat "$brief")" "{TASK}" "the intent placeholder is filled"
  assert_not_contains "$(cat "$brief")" "{FIRSTMATE_SPEC}" "the spec placeholder is filled"
  assert_contains "$(cat "$brief")" "Make the flux capacitor configurable for each project." "the bead's intent is in the brief"
  assert_contains "$(cat "$brief")" "Add a config key that the loader reads at startup." "the bead's spec is in the brief"
  assert_contains "$(cat "$brief")" "Anything touching the billing code paths." "out of scope is in the brief"
  assert_contains "$(cat "$brief")" "Tests cover the new key and its refusal path." "the definition of done is in the brief"
  assert_contains "$(cat "$brief")" "- PR link: the merged pull request link" "the evidence the bead requires is in the brief"
  assert_contains "$(cat "$brief")" "bin/fm-workhorse-close.sh $first" "the brief names the closing command"
  assert_contains "$(cat "$brief")" "Delivery contract: mode=local-only" "the scaffold's delivery contract is intact"
  pass "claim takes the oldest unclaimed full brief, claims it, and seeds the worker brief from it"
}

test_claimed_bead_is_not_claimable_again() {
  local first out rc=0
  first=$(jq -r '.[] | select(.title == "First full workhorse brief for listing") | .id' "$WH_STORE/store.json")
  out=$(claim claim "$first" 2>&1) || rc=$?
  expect_code 2 "$rc" "re-claiming a claimed bead" "$out"
  assert_contains "$out" "not unclaimed" "the claimed state is named"
  assert_equals "bench-mate" "$(bead_field "$first" .assignee)" "the first claimer keeps it"
  pass "a claimed bead cannot be claimed again"
}

test_lost_race_exits_5_and_other_failures_exit_1() {
  local id out rc=0
  id=$(file_bead "A third brief for the race checks")
  out=$(FAKE_UPDATE_RC=13 claim claim "$id" 2>&1) || rc=$?
  expect_code 5 "$rc" "a lost race" "$out"
  assert_contains "$out" "claimed by someone else first" "the lost race is named"
  assert_equals "open" "$(bead_field "$id" .status)" "the bead is unchanged"
  rc=0
  out=$(FAKE_UPDATE_RC=1 claim claim "$id" 2>&1) || rc=$?
  expect_code 1 "$rc" "a store failure on claim" "$out"
  assert_absent "$WH_HOME/data/wh-$id" "no brief is scaffolded when the claim fails"
  pass "a lost claim race exits 5 and a store failure exits 1, both leaving no brief"
}

test_scaffold_failure_releases_the_claim() {
  local id out rc=0
  id=$(file_bead "A fourth brief whose scaffold will fail")
  mkdir -p "$WH_HOME/data/wh-$id"
  : >"$WH_HOME/data/wh-$id/brief.md"
  out=$(claim claim "$id" 2>&1) || rc=$?
  expect_code 1 "$rc" "a scaffold failure" "$out"
  assert_contains "$out" "claim released" "the release is reported"
  assert_equals "open" "$(bead_field "$id" .status)" "the bead is open again"
  assert_equals "" "$(bead_field "$id" .assignee)" "the bead is unassigned again"
  pass "a failed scaffold gives the bead back"
}

test_every_call_was_pinned_to_the_task_store() {
  assert_not_contains "$(cut -d'|' -f1,2 "$WH_LOG" | sort -u)" "$WH_DECOY" "no call used the caller's cwd or its .beads"
  assert_equals "$WH_STORE" "$(cut -d'|' -f2 "$WH_LOG" | sort -u)" "every call carried the pinned BEADS_DIR"
  assert_contains "$(cut -d'|' -f1 "$WH_LOG" | sort -u)" "$(dirname "$WH_STORE")" "script calls ran from the store's parent"
  assert_equals "0" "$(wh_store_count "$WH_DECOY/.beads")" "the decoy store stayed empty"
  pass "every store call ran from the pinned store's parent with its BEADS_DIR"
}

fm_test_run \
  test_list_with_no_beads \
  test_list_shows_only_unclaimed_workhorse_beads \
  test_claim_refusals_leave_the_bead_unclaimed \
  test_claim_takes_the_oldest_and_seeds_the_brief \
  test_claimed_bead_is_not_claimable_again \
  test_lost_race_exits_5_and_other_failures_exit_1 \
  test_scaffold_failure_releases_the_claim \
  test_every_call_was_pinned_to_the_task_store
