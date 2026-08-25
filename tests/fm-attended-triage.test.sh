#!/usr/bin/env bash
# tests/fm-attended-triage.test.sh - the sub-supervisor's attended background
# triage pass (bin/fm-attended-triage-lib.sh, driven from the daemon's
# housekeeping): the switch, the absorb/escalate outcome on the durable wake
# queue, every degraded model path, and the never-absorb categories.
#
# The away-mode contract is pinned here too, because attended triage is a change
# to the same daemon: with state/.afk present the pass must not touch the queue,
# and the marked/unmarked operational-input discrimination that decides whether
# the captain is back must behave identically with the feature switched on.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
ATTENDED_START="$ROOT/bin/fm-attended-start.sh"
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-attended-triage-tests)

# A fake `claude` standing in for the second-tier verdict. Behavior is chosen per
# case by env, so one binary covers the healthy answer and every degraded path.
#   FM_FAKE_MODEL_ANSWER   text printed on stdout (default "absorb routine")
#   FM_FAKE_MODEL_EXIT     exit status (default 0)
#   FM_FAKE_MODEL_SLEEP    seconds to hang before answering (default 0)
#   FM_FAKE_MODEL_CALLS    file the fake appends one line to per invocation
make_fake_model() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/claude" <<'SH'
#!/usr/bin/env bash
set -u
printf 'call\n' >> "${FM_FAKE_MODEL_CALLS:-/dev/null}"
[ "${FM_FAKE_MODEL_SLEEP:-0}" = 0 ] || sleep "$FM_FAKE_MODEL_SLEEP"
if [ "${FM_FAKE_MODEL_ANSWER+x}" = x ]; then
  [ -z "$FM_FAKE_MODEL_ANSWER" ] || printf '%s\n' "$FM_FAKE_MODEL_ANSWER"
else
  printf 'absorb routine\n'
fi
exit "${FM_FAKE_MODEL_EXIT:-0}"
SH
  chmod +x "$dir/claude"
  printf '%s\n' "$dir/claude"
}

# A case with a state dir, a fake model, and one recorded task that is plainly
# still working - the shape the pass is allowed to absorb.
attended_case() {  # <name>
  local name=$1 dir state
  dir=$(make_supercase "$name")
  state="$dir/state"
  make_fake_model "$dir/fakebin" >/dev/null
  cat > "$state/task-aa.meta" <<META
window=fm-task-aa
worktree=/tmp/task-aa
project=demo
META
  printf 'working: implementing the parser\n' > "$state/task-aa.status"
  printf '%s\n' "$dir"
}

queue_rows() {  # <state>
  cat "$1/.wake-queue" 2>/dev/null || true
}

# Run one attended pass against <state> with the feature switched on.
run_pass() {  # <dir> <state> [<env assignment>...]
  local dir=$1 state=$2
  shift 2
  ( set +e
    # shellcheck disable=SC2030,SC2031
    export FM_ATTENDED_TRIAGE=on
    # shellcheck disable=SC2030,SC2031
    export FM_ATTENDED_TRIAGE_EXEC="$dir/fakebin/claude"
    # shellcheck disable=SC2030,SC2031
    export FM_STATE_OVERRIDE="$state"
    while [ "$#" -gt 0 ]; do export "${1?}"; shift; done
    fm_attended_triage_pass "$state"
  )
}

# --- criterion 5: the switch ------------------------------------------------

test_switch_off_leaves_the_queue_and_log_untouched() {
  local dir state
  dir=$(attended_case switch-off); state="$dir/state"
  append_wake "$state" signal task-aa.status "signal: task-aa.status"

  ( set +e
    unset FM_ATTENDED_TRIAGE
    # shellcheck disable=SC2030,SC2031
    export FM_ATTENDED_TRIAGE_EXEC="$dir/fakebin/claude"
    # shellcheck disable=SC2030,SC2031
    export FM_STATE_OVERRIDE="$state" FM_HOME="$dir"
    fm_attended_triage_pass "$state"
  )

  assert_grep 'task-aa.status' "$state/.wake-queue" "attended triage absorbed a wake while switched off"
  assert_absent "$state/.watch-triage.log" "switched-off attended triage still wrote a triage verdict"
  pass "attended triage off by default leaves the wake queue and triage log untouched"
}

test_config_file_turns_the_pass_on() {
  local dir state
  dir=$(attended_case switch-config-file); state="$dir/state"
  mkdir -p "$dir/config"
  printf '# captain note\n\non\n' > "$dir/config/attended-triage"
  append_wake "$state" signal task-aa.status "signal: task-aa.status"

  ( set +e
    unset FM_ATTENDED_TRIAGE
    # shellcheck disable=SC2030,SC2031
    export FM_ATTENDED_TRIAGE_EXEC="$dir/fakebin/claude"
    # shellcheck disable=SC2030,SC2031
    export FM_STATE_OVERRIDE="$state" FM_HOME="$dir"
    fm_attended_triage_pass "$state"
  )

  assert_absent "$state/.wake-queue.absent" "sanity"
  [ ! -s "$state/.wake-queue" ] || fail "config/attended-triage=on did not enable the absorbing pass"
  assert_grep 'attended: absorb tier=model' "$state/.watch-triage.log" "config-enabled pass did not log a model verdict"
  pass "config/attended-triage turns the pass on, comments and blanks ignored"
}

test_unrecognised_switch_value_is_treated_as_off() {
  local dir state
  dir=$(attended_case switch-garbage); state="$dir/state"
  mkdir -p "$dir/config"
  printf 'maybe\n' > "$dir/config/attended-triage"
  append_wake "$state" signal task-aa.status "signal: task-aa.status"

  ( set +e
    unset FM_ATTENDED_TRIAGE
    # shellcheck disable=SC2030,SC2031
    export FM_ATTENDED_TRIAGE_EXEC="$dir/fakebin/claude"
    # shellcheck disable=SC2030,SC2031
    export FM_STATE_OVERRIDE="$state" FM_HOME="$dir"
    fm_attended_triage_pass "$state"
  )

  assert_grep 'task-aa.status' "$state/.wake-queue" "an unrecognised switch value enabled absorption"
  assert_grep 'unrecognised attended-triage setting' "$state/.watch-triage.log" "an unrecognised switch value was not reported"
  pass "an unrecognised attended-triage value is treated as off and reported"
}

test_attended_start_refuses_while_switched_off() {
  local dir out status
  dir=$(attended_case start-refuses)
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_ATTENDED_TRIAGE=off "$ATTENDED_START" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm-attended-start.sh started the daemon while attended triage was off"
  assert_contains "$out" "attended background triage is switched off" "fm-attended-start.sh did not name the switch"
  assert_absent "$dir/state/.afk" "fm-attended-start.sh wrote the away-mode flag"
  pass "fm-attended-start.sh refuses while the switch is off and never writes the away-mode flag"
}

test_attended_start_refuses_while_away_mode_owns_the_daemon() {
  local dir out status
  dir=$(attended_case start-refuses-afk)
  date '+%s' > "$dir/state/.afk"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_ATTENDED_TRIAGE=on "$ATTENDED_START" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm-attended-start.sh started a second daemon under away mode"
  assert_contains "$out" "away mode is active" "fm-attended-start.sh did not name away-mode ownership"
  pass "fm-attended-start.sh refuses while away mode owns the daemon"
}

# --- criterion 1: away mode is unchanged ------------------------------------

test_away_mode_never_absorbs_from_the_queue() {
  local dir state
  dir=$(attended_case away-no-absorb); state="$dir/state"
  date '+%s' > "$state/.afk"
  append_wake "$state" signal task-aa.status "signal: task-aa.status"

  run_pass "$dir" "$state"

  assert_grep 'task-aa.status' "$state/.wake-queue" "the attended pass absorbed a wake while away mode was active"
  assert_absent "$state/.watch-triage.log" "the attended pass judged a wake while away mode was active"
  pass "with state/.afk present the attended pass stands down and never touches the queue"
}

test_away_mode_injection_still_gated_on_the_flag() {
  local dir state out
  dir=$(attended_case away-inject-gate); state="$dir/state"

  # afk absent with attended triage ON: injection must still defer, exactly as
  # today. Attended mode escalates by leaving the wake queued, never by typing
  # into the captain's session.
  out=$(
    set +e
    # shellcheck disable=SC2030,SC2031
    export FM_ATTENDED_TRIAGE=on FM_STATE_OVERRIDE="$state"
    export FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane
    export FM_FAKE_TMUX_SENT="$dir/sent"
    PATH="$dir/fakebin:$PATH" inject_msg "digest body" "$state" 2>&1
    printf 'status=%s\n' "$?"
  )
  assert_contains "$out" "status=1" "inject_msg injected while away mode was inactive"
  assert_absent "$dir/sent" "inject_msg sent keys while away mode was inactive"
  pass "with attended triage on, injection is still refused unless state/.afk is present"
}

test_operational_input_discrimination_unchanged() {
  local marked kind status
  # shellcheck source=bin/fm-operational-input.sh
  . "$ROOT/bin/fm-operational-input.sh"
  fm_operational_input_construct away-supervisor "task-aa done: PR ready" marked \
    || fail "could not construct an away-supervisor operational input"

  kind=''
  FM_ATTENDED_TRIAGE=on fm_operational_input_classify "$marked" kind
  status=$?
  expect_code 0 "$status" "a marked away-supervisor message stopped classifying as internal"
  [ "$kind" = away-supervisor ] || fail "marked message classified as '$kind', not away-supervisor"

  kind=''
  FM_ATTENDED_TRIAGE=on fm_operational_input_classify "hey, I'm back" kind
  status=$?
  [ "$status" -ne 0 ] || fail "an unmarked captain message classified as internal operational input"
  pass "marked/unmarked operational-input discrimination is unchanged with attended triage on"
}

# --- criterion 2: attended absorb and escalate ------------------------------

test_attended_absorbs_routine_wake_with_logged_verdict() {
  local dir state calls
  dir=$(attended_case absorb-routine); state="$dir/state"
  calls="$dir/calls"
  append_wake "$state" signal task-aa.status "signal: task-aa.status"

  run_pass "$dir" "$state" "FM_FAKE_MODEL_ANSWER=absorb worker is plainly still working" \
    "FM_FAKE_MODEL_CALLS=$calls"

  [ ! -s "$state/.wake-queue" ] || fail "a routine wake stayed actionable after an absorb verdict"
  assert_grep 'attended: absorb tier=model' "$state/.watch-triage.log" "the absorbed wake was not logged with its verdict and tier"
  assert_grep 'worker is plainly still working' "$state/.watch-triage.log" "the absorbed wake was logged without the model's reason"
  assert_grep 'removed 1 from the wake queue' "$state/.watch-triage.log" "the pass did not record what it removed"
  assert_present "$calls" "the second tier was never consulted"
  pass "an attended routine wake is absorbed with a logged verdict and stops being actionable"
}

test_attended_escalation_leaves_the_wake_queued() {
  local dir state
  dir=$(attended_case escalate-queued); state="$dir/state"
  append_wake "$state" signal task-aa.status "signal: task-aa.status"

  run_pass "$dir" "$state" "FM_FAKE_MODEL_ANSWER=escalate this needs the captain"

  assert_grep 'task-aa.status' "$state/.wake-queue" "an escalated wake was removed from the durable queue"
  assert_grep 'attended: escalate tier=model' "$state/.watch-triage.log" "the escalated wake was not logged with its verdict and tier"
  assert_absent "$state/.subsuper-escalations" "the attended pass buffered an away-mode escalation"
  pass "an attended escalation reaches the main session by staying on the wake queue, with no injection"
}

test_attended_pass_leaves_unrelated_records_alone() {
  local dir state
  dir=$(attended_case absorb-one-of-two); state="$dir/state"
  printf 'done: PR https://example.invalid/pr/1 checks green\n' > "$state/task-bb.status"
  cat > "$state/task-bb.meta" <<META
window=fm-task-bb
META
  append_wake "$state" signal task-aa.status "signal: task-aa.status"
  append_wake "$state" signal task-bb.status "signal: task-bb.status"

  run_pass "$dir" "$state" "FM_FAKE_MODEL_ANSWER=absorb routine"

  assert_no_grep 'task-aa.status' "$state/.wake-queue" "the routine record was not absorbed"
  assert_grep 'task-bb.status' "$state/.wake-queue" "a captain-relevant record was absorbed alongside a routine one"
  pass "the pass removes exactly the records it absorbed and leaves the rest queued"
}

# --- criterion 3: every degraded model path escalates ------------------------

assert_model_failure_escalates() {  # <name> <label> <env assignment>...
  local name=$1 label=$2 dir state
  shift 2
  dir=$(attended_case "$name"); state="$dir/state"
  append_wake "$state" signal task-aa.status "signal: task-aa.status"

  run_pass "$dir" "$state" "$@"

  assert_grep 'task-aa.status' "$state/.wake-queue" "$label silenced a wake instead of falling back to escalation"
  assert_grep 'attended: escalate tier=model-failed' "$state/.watch-triage.log" "$label was not recorded as a model failure"
  pass "$label falls back to the pattern verdict and keeps the wake actionable"
}

test_model_missing_binary_escalates() {
  local dir state
  dir=$(attended_case model-missing); state="$dir/state"
  append_wake "$state" signal task-aa.status "signal: task-aa.status"

  ( set +e
    # shellcheck disable=SC2030,SC2031
    export FM_ATTENDED_TRIAGE=on FM_STATE_OVERRIDE="$state"
    # shellcheck disable=SC2030,SC2031
    export FM_ATTENDED_TRIAGE_EXEC="$dir/fakebin/no-such-model-binary"
    fm_attended_triage_pass "$state"
  )

  assert_grep 'task-aa.status' "$state/.wake-queue" "a missing model binary silenced a wake"
  assert_grep 'attended: escalate tier=model-failed' "$state/.watch-triage.log" "a missing model binary was not recorded as a model failure"
  pass "a missing model binary falls back to the pattern verdict and keeps the wake actionable"
}

test_model_nonzero_exit_escalates() {
  assert_model_failure_escalates model-nonzero "a non-zero model exit" \
    'FM_FAKE_MODEL_ANSWER=absorb routine' 'FM_FAKE_MODEL_EXIT=3'
}

test_model_timeout_escalates() {
  assert_model_failure_escalates model-timeout "a model timeout" \
    'FM_FAKE_MODEL_ANSWER=absorb routine' 'FM_FAKE_MODEL_SLEEP=5' \
    'FM_ATTENDED_TRIAGE_TIMEOUT_SECS=1'
}

test_model_garbage_output_escalates() {
  assert_model_failure_escalates model-garbage "an unparseable model answer" \
    'FM_FAKE_MODEL_ANSWER=I think we should probably look at this'
}

test_model_empty_output_escalates() {
  assert_model_failure_escalates model-empty "an empty model answer" \
    'FM_FAKE_MODEL_ANSWER='
}

test_model_call_cap_escalates_the_remainder() {
  local dir state calls i
  dir=$(attended_case model-cap); state="$dir/state"
  calls="$dir/calls"
  for i in 1 2 3; do
    printf 'working: still going\n' > "$state/task-c$i.status"
    printf 'window=fm-task-c%s\n' "$i" > "$state/task-c$i.meta"
    append_wake "$state" signal "task-c$i.status" "signal: task-c$i.status"
  done

  run_pass "$dir" "$state" 'FM_FAKE_MODEL_ANSWER=absorb routine' \
    'FM_ATTENDED_TRIAGE_MAX_CALLS=1' "FM_FAKE_MODEL_CALLS=$calls"

  [ "$(wc -l < "$calls" | tr -d '[:space:]')" = 1 ] || fail "the pass exceeded its model call cap"
  assert_grep 'attended: escalate tier=cap' "$state/.watch-triage.log" "wakes past the call cap were not recorded as capped"
  assert_grep 'task-c2.status' "$state/.wake-queue" "a wake past the model call cap was absorbed without a verdict"
  pass "past its per-pass model call cap the attended pass keeps every remaining wake actionable"
}

# --- criterion 4: never-absorb categories -----------------------------------

# Each case queues a wake the model is told to absorb; the tier-1 rules must
# override that and keep it actionable.
assert_never_absorbed() {  # <name> <label> <kind> <key> <payload> [<setup-fn>]
  local name=$1 label=$2 kind=$3 key=$4 payload=$5 setup=${6:-} dir state
  dir=$(attended_case "$name"); state="$dir/state"
  [ -z "$setup" ] || "$setup" "$state"
  append_wake "$state" "$kind" "$key" "$payload"

  run_pass "$dir" "$state" 'FM_FAKE_MODEL_ANSWER=absorb looks routine to me'

  [ -s "$state/.wake-queue" ] || fail "$label was absorbed; it must always reach the captain"
  assert_grep 'attended: escalate tier=rule' "$state/.watch-triage.log" "$label was not kept by a tier-1 rule"
  pass "$label is never absorbed"
}

setup_needs_decision() { printf 'needs-decision: [key=schema] which shape wins?\n' >> "$1/task-aa.status"; }
setup_open_decision() {
  # An open decision buried under later unrelated progress: the wake payload and
  # the last status line are both routine, so only the decision fold catches it.
  printf 'needs-decision: [key=schema] which shape wins?\nworking: exploring option a\n' > "$1/task-aa.status"
}

test_never_absorb_done_verb() {
  assert_never_absorbed never-done "a done report" signal task-aa.status \
    'signal: task-aa.status done: PR opened'
}

test_never_absorb_needs_decision_verb() {
  assert_never_absorbed never-needs-decision "a needs-decision report" signal task-aa.status \
    'signal: task-aa.status' setup_needs_decision
}

test_never_absorb_blocked_verb() {
  assert_never_absorbed never-blocked "a blocked report" signal task-aa.status \
    'signal: task-aa.status blocked: no credential'
}

test_never_absorb_failed_verb() {
  assert_never_absorbed never-failed "a failed report" signal task-aa.status \
    'signal: task-aa.status failed: build broke'
}

test_never_absorb_open_decision_record() {
  assert_never_absorbed never-open-decision "a wake for work with an open decision" \
    signal task-aa.status 'signal: task-aa.status' setup_open_decision
}

test_never_absorb_relay_mention() {
  # Use the production key format: watcher queues relay wakes as the full path
  # "$STATE/x-watch.check.sh", which does NOT match x-watch* in the key case.
  # Protection comes from the payload-based match (*x-mention*) — this test
  # proves that path is the live guard.
  local dir state key
  dir=$(attended_case never-relay); state="$dir/state"
  key="$state/x-watch.check.sh"
  append_wake "$state" check "$key" "check: $key: x-mention 12345: someone asked for a status update"

  run_pass "$dir" "$state" 'FM_FAKE_MODEL_ANSWER=absorb looks routine to me'

  [ -s "$state/.wake-queue" ] || fail "a Relay mention was absorbed; it must always reach the captain"
  assert_grep 'attended: escalate tier=rule' "$state/.watch-triage.log" "a Relay mention was not kept by a tier-1 rule"
  pass "a Relay mention (production full-path key) is never absorbed via payload match"
}

test_never_absorb_relay_configuration_error() {
  # Same production-key reasoning as test_never_absorb_relay_mention above.
  local dir state key
  dir=$(attended_case never-relay-error); state="$dir/state"
  key="$state/x-watch.check.sh"
  append_wake "$state" check "$key" "check: $key: x-mode-error: pairing token rejected"

  run_pass "$dir" "$state" 'FM_FAKE_MODEL_ANSWER=absorb looks routine to me'

  [ -s "$state/.wake-queue" ] || fail "a Relay configuration error was absorbed; it must always reach the captain"
  assert_grep 'attended: escalate tier=rule' "$state/.watch-triage.log" "a Relay configuration error was not kept by a tier-1 rule"
  pass "a Relay configuration error (production full-path key) is never absorbed via payload match"
}

test_never_absorb_pr_poll_retirement() {
  assert_never_absorbed never-pr-poll-retirement "a PR poll retirement auth failure" \
    check pr-poll-retirement \
    'check: rejected unauthenticated PR poll retirement receipts: /tmp/state/task-aa.pr-poll-retirement'
}

test_never_absorb_merged_pr() {
  assert_never_absorbed never-merged "a merged pull request" check task-aa \
    'check: PR https://example.invalid/pr/9 merged'
}

test_never_absorb_checks_green() {
  assert_never_absorbed never-green "a checks-green result" check task-aa \
    'check: PR https://example.invalid/pr/9 checks green'
}

test_never_absorb_staleness_autoclose() {
  assert_never_absorbed never-staleness "a staleness auto-close reclaim" stale fm-task-aa \
    'stale: fm-task-aa reclaimed by staleness auto-close, worktree preserved'
}

test_never_absorb_heartbeat() {
  assert_never_absorbed never-heartbeat "a fleet-wide heartbeat review" heartbeat heartbeat \
    'heartbeat: review the fleet'
}

test_never_absorb_unknown_key_shape() {
  local dir state
  dir=$(attended_case never-unknown); state="$dir/state"
  # A record whose kind the classifier does not recognise cannot be judged, so
  # it must survive. Written straight to the queue: fm_wake_append rejects the
  # kind by design, which is itself the first line of defence.
  printf '%s\t%s\t%s\t%s\t%s\n' 1700000000 1 mystery something 'check: ???' > "$state/.wake-queue"

  run_pass "$dir" "$state" 'FM_FAKE_MODEL_ANSWER=absorb looks routine to me'

  assert_grep 'mystery' "$state/.wake-queue" "an unrecognised wake kind was absorbed"
  pass "a wake whose kind the classifier does not recognise is never absorbed"
}

test_switch_off_leaves_the_queue_and_log_untouched
test_config_file_turns_the_pass_on
test_unrecognised_switch_value_is_treated_as_off
test_attended_start_refuses_while_switched_off
test_attended_start_refuses_while_away_mode_owns_the_daemon
test_away_mode_never_absorbs_from_the_queue
test_away_mode_injection_still_gated_on_the_flag
test_operational_input_discrimination_unchanged
test_attended_absorbs_routine_wake_with_logged_verdict
test_attended_escalation_leaves_the_wake_queued
test_attended_pass_leaves_unrelated_records_alone
test_model_missing_binary_escalates
test_model_nonzero_exit_escalates
test_model_timeout_escalates
test_model_garbage_output_escalates
test_model_empty_output_escalates
test_model_call_cap_escalates_the_remainder
test_never_absorb_done_verb
test_never_absorb_needs_decision_verb
test_never_absorb_blocked_verb
test_never_absorb_failed_verb
test_never_absorb_open_decision_record
test_never_absorb_relay_mention
test_never_absorb_relay_configuration_error
test_never_absorb_pr_poll_retirement
test_never_absorb_merged_pr
test_never_absorb_checks_green
test_never_absorb_staleness_autoclose
test_never_absorb_heartbeat
test_never_absorb_unknown_key_shape
