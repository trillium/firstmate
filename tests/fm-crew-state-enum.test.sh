#!/usr/bin/env bash
# tests/fm-crew-state-enum.test.sh - the single enumeration of the states
# bin/fm-crew-state.sh can emit (FM_CREW_STATES in bin/fm-classify-lib.sh).
#
# A new state value must be placed in exactly one consumer group before it can
# be emitted, so fleet health cannot silently mis-render it:
#   (a) every enumerated state belongs to exactly one group, and every group
#       member is enumerated;
#   (b) the consumer helpers (shell predicate and jq array) agree with the groups;
#   (c) fm-crew-state.sh refuses to emit a state missing from the enumeration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-state-enum)

GROUPS_ALL="$FM_CREW_STATES_WORKING $FM_CREW_STATES_HOLD $FM_CREW_STATES_TERMINAL $FM_CREW_STATES_QUIESCENT $FM_CREW_STATES_UNKNOWN"

test_every_state_is_in_exactly_one_group() {
  local s g n
  for s in $FM_CREW_STATES; do
    n=0
    for g in "$FM_CREW_STATES_WORKING" "$FM_CREW_STATES_HOLD" "$FM_CREW_STATES_TERMINAL" "$FM_CREW_STATES_QUIESCENT" "$FM_CREW_STATES_UNKNOWN"; do
      fm_crew_state_in "$s" "$g" && n=$((n + 1))
    done
    assert_equals "1" "$n" "state '$s' must be in exactly one consumer group"
  done
  for s in $GROUPS_ALL; do
    fm_crew_state_known "$s" || fail "group member '$s' is missing from FM_CREW_STATES"
  done
  for s in $FM_CREW_STATES_DECISION_OPEN; do
    fm_crew_state_in "$s" "$FM_CREW_STATES_HOLD" || fail "decision-open state '$s' must be a hold state"
  done
  fm_crew_state_known bogus && fail "an unlisted value must not be known"
  pass "every state is in exactly one group"
}

test_json_helper_matches_group() {
  assert_equals '["parked","paused","blocked"]' "$(fm_crew_states_json "$FM_CREW_STATES_HOLD")" "hold group renders as a JSON array"
  assert_equals '[]' "$(fm_crew_states_json "")" "an empty group renders as an empty array"
  pass "jq helper matches the groups"
}

test_crew_state_refuses_unlisted_state() {
  local d out rc
  d="$TMP_ROOT/refuse"
  mkdir -p "$d/state"
  cp -R "$ROOT/bin" "$d/bin"
  # Drop `unknown` from the copy's enumeration; a missing-meta read emits it.
  perl -0pi -e 's/ \$FM_CREW_STATES_UNKNOWN"\n/"\n/' "$d/bin/fm-classify-lib.sh"
  out=$(FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" "$d/bin/fm-crew-state.sh" nosuch 2>&1)
  rc=$?
  assert_equals "1" "$rc" "an unlisted state makes fm-crew-state.sh exit 1"
  assert_contains "$out" "missing from FM_CREW_STATES" "the refusal names the enumeration"
  out=$(FM_HOME="$ROOT" FM_STATE_OVERRIDE="$d/state" "$ROOT/bin/fm-crew-state.sh" nosuch 2>&1)
  assert_contains "$out" "state: unknown" "the real enumeration still emits unknown"
  pass "fm-crew-state.sh refuses a state outside the enumeration"
}

test_every_state_is_in_exactly_one_group
test_json_helper_matches_group
test_crew_state_refuses_unlisted_state

echo "all fm-crew-state-enum tests passed"
