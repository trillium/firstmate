#!/usr/bin/env bash
# Behavior tests for the first-turn verification contract owned by
# bin/fm-firstturn-lib.sh: given a task's semantic busy-state record, can
# firstmate prove the freshly launched agent actually STARTED a turn?
#
# The library is a sourced public interface (the same shape tests/fm-busy-state.test.sh
# uses for bin/fm-busy-lib.sh), so these drive the real functions against real
# records written by the real writer, bin/fm-busy-event.sh. Nothing here asserts
# implementation bytes: every case sets up a record shape and checks the verdict.
#
# fm-spawn.sh's use of these verdicts - the resubmit decision, the outcome log,
# and the safety property that a fired turn is never resubmitted into - is
# covered separately by tests/fm-spawn-firstturn.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-firstturn-lib.sh
. "$ROOT/bin/fm-firstturn-lib.sh"

EV="$ROOT/bin/fm-busy-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-firstturn)

# new_state <name>: a fresh empty state dir.
new_state() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

# assert_verdict <actual> <expected> <msg>
assert_verdict() {
  [ "$1" = "$2" ] || fail "$3: expected verdict '$2', got '$1'"
}

# --- which harnesses can ever be proven --------------------------------------

test_provable_harnesses_are_exactly_the_wired_adapters() {
  local h
  # Every harness whose adapter writes a semantic turn source is provable, and
  # the proving source is the adapter's own token - never a firstmate-owned one.
  for h in claude opencode pi pi-signed; do
    fm_firstturn_provable "$h" \
      || fail "$h has a wired busy adapter but is not first-turn provable"
    case "$(fm_firstturn_adapter_sources "$h")" in
      *fm-spawn*|*fm-interrupt*|*fm-recovery*)
        fail "$h's first-turn sources include a firstmate-owned source, which is not evidence of an agent turn" ;;
      '') fail "$h reported provable but has no adapter source" ;;
    esac
  done
  # Harnesses with no semantic turn source must never claim provability. A
  # fabricated verdict for these is exactly the failure this library exists to
  # avoid, so they are pinned rather than left implied.
  for h in codex grok kimi muse bogus-harness ''; do
    ! fm_firstturn_provable "$h" \
      || fail "'${h:-<empty>}' has no semantic turn source but reported first-turn provable"
  done
  pass "first-turn provability covers exactly the wired adapters and excludes firstmate-owned sources"
}

test_adapter_sources_are_derived_not_restated() {
  # The library must subtract the firstmate-owned sources from fm-busy-lib.sh's
  # own table rather than keeping a second copy of it, so opening a gated
  # adapter there extends first-turn proof in the same change. Checked
  # behaviorally: the adapter set is exactly the busy set minus the three
  # firstmate-owned tokens, for every harness.
  local h busy adapter expected
  for h in claude opencode pi pi-signed codex grok kimi muse; do
    busy=$(fm_busy_sources_for_harness "$h")
    adapter=$(fm_firstturn_adapter_sources "$h")
    expected=$(printf '%s\n' $busy | grep -vxF -e fm-spawn -e fm-interrupt -e fm-recovery | tr '\n' ' ')
    expected=${expected% }
    [ "$adapter" = "$expected" ] \
      || fail "$h: first-turn sources '$adapter' are not its busy sources minus the firstmate-owned ones ('$expected')"
  done
  pass "first-turn sources are derived from the busy-source table, not a second copy of it"
}

# --- the three verdicts ------------------------------------------------------

test_untouched_launch_seed_is_not_fired() {
  local state
  state=$(new_state seed-only)
  # Exactly what a spawn writes and nothing more: the launch-time assumption.
  "$EV" arm "$state" t1 >/dev/null
  assert_verdict "$(fm_firstturn_observe "$state" t1 claude)" 'not-fired seed' \
    "an untouched launch seed"
  pass "an untouched launch seed reads as not-fired - the launch prompt was never observed to land"
}

test_adapter_event_proves_the_turn_fired() {
  local state gen
  state=$(new_state adapter-fired)
  gen=$("$EV" arm "$state" t1)
  # The harness's own turn-lifecycle writer replaces the seed - the exact
  # transition docs/verification/supervision.md records as live-verified.
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
  assert_verdict "$(fm_firstturn_observe "$state" t1 claude)" 'fired claude-hook' \
    "a claude-hook turn event"
  pass "the harness's own adapter event proves the first turn fired"
}

test_adapter_idle_event_also_proves_the_turn_fired() {
  local state gen
  state=$(new_state adapter-idle)
  gen=$("$EV" arm "$state" t1)
  # A turn that already COMPLETED is still a turn that fired. Proof is the
  # source, never the busy/idle state - a fast first turn must not read as a
  # dropped prompt and get a second charter.
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  assert_verdict "$(fm_firstturn_observe "$state" t1 claude)" 'fired claude-hook' \
    "a completed (idle) turn"
  pass "a turn that already completed still proves the first turn fired"
}

test_other_wired_adapters_prove_their_own_turns() {
  local state gen
  state=$(new_state adapter-opencode)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source opencode-plugin --event session-busy
  assert_verdict "$(fm_firstturn_observe "$state" t1 opencode)" 'fired opencode-plugin' \
    "an opencode-plugin turn event"

  state=$(new_state adapter-pi)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source pi-ext --event agent-start
  assert_verdict "$(fm_firstturn_observe "$state" t1 pi)" 'fired pi-ext' \
    "a pi-ext turn event"
  pass "each wired adapter proves its own harness's first turn"
}

test_foreign_adapter_source_does_not_prove_this_harness() {
  local state gen
  state=$(new_state foreign-source)
  gen=$("$EV" arm "$state" t1)
  # A record written by a DIFFERENT harness's adapter says nothing about this
  # one. It must not read as fired (a false success that hides a dropped
  # prompt) and must not read as not-fired (a resubmit on no evidence).
  "$EV" apply "$state" t1 busy --gen "$gen" --source pi-ext --event agent-start
  assert_verdict "$(fm_firstturn_observe "$state" t1 claude)" 'unproven firstmate-source' \
    "another harness's adapter source"
  pass "another harness's adapter source proves nothing about this harness's first turn"
}

# --- unproven: every reason is named, never guessed --------------------------

test_unprovable_harness_reports_no_semantic_source() {
  local state
  state=$(new_state unprovable)
  "$EV" arm "$state" t1 >/dev/null
  # An armed seed exists, so the only reason this cannot be read as not-fired
  # is the harness itself. Naming that reason is what keeps the gap honest
  # instead of silently resubmitting into a harness nothing can observe.
  assert_verdict "$(fm_firstturn_observe "$state" t1 codex)" 'unproven no-semantic-source' \
    "a harness with no semantic turn source"
  pass "a harness with no semantic turn source reports unproven with that named reason"
}

test_missing_record_is_unproven_not_not_fired() {
  local state
  state=$(new_state never-armed)
  # A secondmate spawn is never armed at all (bin/fm-spawn.sh gates arming
  # behind KIND != secondmate). No record means no evidence in EITHER
  # direction - treating it as not-fired would resubmit a charter blind.
  assert_verdict "$(fm_firstturn_observe "$state" t1 claude)" 'unproven missing' \
    "a task that was never armed"
  pass "a never-armed task is unproven, never not-fired - an unarmed launch is never resubmitted into"
}

test_stale_incarnation_is_unproven() {
  local state gen
  state=$(new_state gen-mismatch)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
  # Re-arming mints a new incarnation; the record still carries the old gen and
  # is no longer binding on this launch.
  "$EV" arm "$state" t1 >/dev/null
  # The fresh arm rewrites the record at seq=1 under the new gen, so this is a
  # legitimate not-fired for the NEW incarnation.
  assert_verdict "$(fm_firstturn_observe "$state" t1 claude)" 'not-fired seed' \
    "a freshly re-armed incarnation"

  # A record whose gen does not match the armed sidecar at all cannot be read.
  printf 'v1 gen=bogus-gen seq=4 state=busy source=claude-hook event=x ts=1\n' \
    > "$state/t1.busy-state"
  assert_verdict "$(fm_firstturn_observe "$state" t1 claude)" 'unproven gen-mismatch' \
    "a record from a stale incarnation"
  pass "a stale incarnation's record is unproven, never mistaken for this launch's evidence"
}

test_malformed_record_is_unproven() {
  local state
  state=$(new_state malformed)
  "$EV" arm "$state" t1 >/dev/null
  printf 'this is not a busy-state record\n' > "$state/t1.busy-state"
  assert_verdict "$(fm_firstturn_observe "$state" t1 claude)" 'unproven malformed' \
    "an unparseable record"
  pass "an unparseable record is unproven rather than assumed either way"
}

test_firstmate_written_record_past_the_seed_is_unproven() {
  local state gen
  state=$(new_state fm-source-later)
  gen=$("$EV" arm "$state" t1)
  # An interrupt or recovery reset overwrites whatever the adapter reported, so
  # from then on firstmate can no longer rule a first turn in or out. Only the
  # untouched seq=1 seed proves nothing was ever observed.
  "$EV" apply "$state" t1 idle --gen "$gen" --source fm-interrupt --event interrupt
  assert_verdict "$(fm_firstturn_observe "$state" t1 claude)" 'unproven firstmate-source' \
    "a firstmate-written record after the seed"

  state=$(new_state fm-spawn-later)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source fm-spawn --event relaunch
  assert_verdict "$(fm_firstturn_observe "$state" t1 claude)" 'unproven unexpected-seq' \
    "a later fm-spawn record"
  pass "a firstmate-written record past the launch seed is unproven - firstmate's own actions are not evidence of an agent turn"
}

# --- the wait loop -----------------------------------------------------------

test_wait_returns_immediately_once_the_turn_is_proven() {
  local state gen out started elapsed
  state=$(new_state wait-fired)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
  started=$(date +%s)
  # A generous budget that must NOT be spent: a healthy launch costs one read.
  out=$(fm_firstturn_wait "$state" t1 claude 40 1)
  elapsed=$(( $(date +%s) - started ))
  assert_verdict "$out" 'fired claude-hook' "wait over an already-proven turn"
  [ "$elapsed" -le 3 ] \
    || fail "wait spent ${elapsed}s over an already-proven turn instead of returning immediately"
  pass "the wait returns immediately once a turn is proven - a healthy launch pays for one read"
}

test_wait_does_not_burn_the_budget_on_an_unprovable_harness() {
  local state out started elapsed
  state=$(new_state wait-unprovable)
  "$EV" arm "$state" t1 >/dev/null
  started=$(date +%s)
  out=$(fm_firstturn_wait "$state" t1 codex 40 1)
  elapsed=$(( $(date +%s) - started ))
  assert_verdict "$out" 'unproven no-semantic-source' "wait on an unprovable harness"
  [ "$elapsed" -le 3 ] \
    || fail "wait spent ${elapsed}s waiting for a verdict that can never arrive"
  pass "the wait returns immediately for a harness whose verdict can never arrive"
}

test_wait_observes_a_turn_that_starts_late() {
  local state gen out
  state=$(new_state wait-late)
  gen=$("$EV" arm "$state" t1)
  # A slow launch: the adapter reports well after the first poll. The wait must
  # keep looking rather than settling for its first read.
  (
    sleep 1
    "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
  ) &
  out=$(fm_firstturn_wait "$state" t1 claude 40 0.2)
  wait
  assert_verdict "$out" 'fired claude-hook' "wait over a late-starting turn"
  pass "the wait observes a turn that starts after the first poll"
}

test_wait_reports_not_fired_after_the_budget_is_spent() {
  local state out
  state=$(new_state wait-dropped)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_firstturn_wait "$state" t1 claude 3 0.1)
  assert_verdict "$out" 'not-fired seed' "wait over a dropped prompt"
  pass "the wait reports not-fired once the budget is spent with the seed still untouched"
}

# --- the outcome log ---------------------------------------------------------

test_log_records_each_outcome_distinguishably() {
  local state line
  state=$(new_state outcome-log)
  fm_firstturn_log "$state" t1 claude tmux fired-normally claude-hook
  fm_firstturn_log "$state" t2 claude tmux resubmitted-confirmed claude-hook
  fm_firstturn_log "$state" t3 claude tmux resubmitted-unconfirmed seed
  assert_grep 'id=t1 harness=claude backend=tmux outcome=fired-normally' \
    "$state/.firstturn.log" "the fired-normally outcome was not logged distinguishably"
  assert_grep 'id=t2 harness=claude backend=tmux outcome=resubmitted-confirmed' \
    "$state/.firstturn.log" "the resubmitted-confirmed outcome was not logged distinguishably"
  assert_grep 'id=t3 harness=claude backend=tmux outcome=resubmitted-unconfirmed' \
    "$state/.firstturn.log" "the resubmitted-unconfirmed outcome was not logged distinguishably"
  [ "$(wc -l < "$state/.firstturn.log")" -eq 3 ] \
    || fail "the outcome log did not append exactly one line per outcome"
  line=$(head -1 "$state/.firstturn.log")
  case "$line" in
    [0-9]*' id=t1 '*) : ;;
    *) fail "the outcome log line does not lead with a timestamp: $line" ;;
  esac
  pass "every first-turn outcome is logged as its own distinguishable durable record"
}

test_log_never_fails_a_spawn_it_cannot_write() {
  local state
  state=$(new_state unwritable-log)
  chmod 500 "$state"
  fm_firstturn_log "$state" t1 claude tmux fired-normally claude-hook \
    || fail "the outcome log failed the caller when it could not write"
  chmod 700 "$state"
  fm_firstturn_log '' t1 claude tmux fired-normally claude-hook \
    || fail "the outcome log failed the caller when given no state dir"
  pass "an unwritable outcome log never fails a launch that otherwise succeeded"
}

test_provable_harnesses_are_exactly_the_wired_adapters
test_adapter_sources_are_derived_not_restated
test_untouched_launch_seed_is_not_fired
test_adapter_event_proves_the_turn_fired
test_adapter_idle_event_also_proves_the_turn_fired
test_other_wired_adapters_prove_their_own_turns
test_foreign_adapter_source_does_not_prove_this_harness
test_unprovable_harness_reports_no_semantic_source
test_missing_record_is_unproven_not_not_fired
test_stale_incarnation_is_unproven
test_malformed_record_is_unproven
test_firstmate_written_record_past_the_seed_is_unproven
test_wait_returns_immediately_once_the_turn_is_proven
test_wait_does_not_burn_the_budget_on_an_unprovable_harness
test_wait_observes_a_turn_that_starts_late
test_wait_reports_not_fired_after_the_budget_is_spent
test_log_records_each_outcome_distinguishably
test_log_never_fails_a_spawn_it_cannot_write

echo "# all fm-firstturn tests passed"
