#!/usr/bin/env bash
# tests/fm-wake-decision-log.test.sh - the stale-wake decision log
# (bin/fm-wake-decision-lib.sh): every verdict row is one valid JSON line
# carrying the features the shadow scorer is calibrated against, a surfaced
# wake is labelled noop, acted, or gone when the real drain acknowledges it,
# the knob that disables the log silences every write, and the size cap keeps
# the newest rows. The watcher's own verdict wiring is covered by
# fm-watch-triage.test.sh; this suite drives the library's public functions and
# the real drain.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-decision-log-tests)

# Run one library call against <state> in a fresh shell, so each case sees
# exactly the environment the watcher and drain give the library.
decision_call() {  # <state> <function> [args...]
  local state=$1; shift
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1/fm-wake-lib.sh"
    # shellcheck disable=SC1090,SC1091
    . "$1/fm-classify-lib.sh"
    # shellcheck disable=SC1090,SC1091
    . "$1/fm-wake-decision-lib.sh"
    fn=$2; shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin" "$@"
}

# Every line of <file> parses as JSON. Skips silently when no JSON parser is
# installed, so the structural assertions around it still run.
assert_json_lines() {  # <file> <label>
  local file=$1 label=$2 check
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$file" >/dev/null 2>&1 || fail "$label: a row is not valid JSON"
  elif command -v python3 >/dev/null 2>&1; then
    check="$TMP_ROOT/json-lines.py"
    [ -e "$check" ] || printf 'import json, sys\nfor line in open(sys.argv[1]):\n    json.loads(line)\n' > "$check"
    python3 -I "$check" "$file" >/dev/null 2>&1 || fail "$label: a row is not valid JSON"
  fi
}

ack_main_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1
}

test_decision_row_is_valid_json_with_features() {
  local dir state log row
  dir=$(make_case row); state="$dir/state"; log="$state/.wake-decisions.jsonl"
  printf 'window=test:fm-row\nkind=ship\n' > "$state/row-task.meta"
  printf 'working: first pass\nneeds-decision [key=shape]: "REST" or RPC \\ pick one\n' > "$state/row-task.status"
  mkdir -p "$state/row-task.inbox/handled"
  : > "$state/row-task.inbox/001.msg"
  : > "$state/row-task.inbox/handled/000.msg"
  decision_call "$state" fm_wake_decision_log_stale "$state" test:fm-row row-task surface terminal-surface 7 none 1 2 '' \
    || fail "logging a surface verdict failed"
  [ -s "$log" ] || fail "no decision row was written"
  assert_json_lines "$log" "surface row"
  row=$(cat "$log")
  case "$row" in
    *'"event":"decision"'*'"kind":"stale"'*'"window":"test:fm-row"'*'"task":"row-task"'*'"verdict":"surface"'*'"rule":"terminal-surface"'*'"seq":7,'*) ;;
    *) fail "the row lacks its identity fields: $row" ;;
  esac
  case "$row" in
    *'"last_verb":"needs-decision"'*'"last_line":"needs-decision [key=shape]: \"REST\" or RPC \\ pick one"'*) ;;
    *) fail "the last line was not escaped into the row: $row" ;;
  esac
  case "$row" in
    *'"open_decision":true'*'"captain_call":"none"'*'"afk":false'*'"busy":false'*'"escalations":2,'*'"throttle_age_secs":null'*) ;;
    *) fail "the feature fields are wrong: $row" ;;
  esac
  case "$row" in
    *'"surfaced_unchanged":false,"times_surfaced":0,'*) ;;
    *) fail "an unpresented status logged as surfaced: $row" ;;
  esac
  case "$row" in
    *';inbox=1/1;'*';hold=none"'*) ;;
    *) fail "the fingerprint does not carry the inbox counts and hold: $row" ;;
  esac
  grep -q '^7	row-task	test:fm-row	[0-9]*	status=' "$state/.wake-decisions.pending" \
    || fail "the surfaced wake was not queued for its label"
  [ "$(cut -f2 "$state/.wake-decision-surfaced-test_fm-row")" = 1 ] \
    || fail "the surface did not count itself against this status state"
  decision_call "$state" fm_wake_decision_log_stale "$state" test:fm-row row-task absorb terminal-repeat '' none 1 '' 30 \
    || fail "logging an absorb verdict failed"
  assert_json_lines "$log" "absorb row"
  tail -n 1 "$log" | grep -q '"verdict":"absorb","rule":"terminal-repeat","seq":null,.*"times_surfaced":1,.*"throttle_age_secs":30,' \
    || fail "the absorb row does not record the prior surface and throttle age: $(tail -n 1 "$log")"
  [ "$(wc -l < "$state/.wake-decisions.pending" | tr -d '[:space:]')" = 1 ] \
    || fail "an absorb verdict queued a label it can never receive"
  pass "a verdict row is valid JSON carrying the verdict, rule, escaped last line, and features"
}

test_acknowledgement_labels_noop_acted_and_gone() {
  local dir state log t
  dir=$(make_case labels); state="$dir/state"; log="$state/.wake-decisions.jsonl"
  for t in quiet touched vanished; do
    printf 'window=test:fm-%s\nkind=ship\n' "$t" > "$state/$t.meta"
    printf 'done: ready in branch fm/%s\n' "$t" > "$state/$t.status"
    append_wake "$state" stale "test:fm-$t" "stale: test:fm-$t" || fail "could not queue a stale wake for $t"
  done
  decision_call "$state" fm_wake_decision_log_stale "$state" test:fm-quiet quiet surface terminal-surface 1 none 1 '' '' \
    || fail "could not log the quiet surface"
  decision_call "$state" fm_wake_decision_log_stale "$state" test:fm-touched touched surface terminal-surface 2 none 1 '' '' \
    || fail "could not log the touched surface"
  decision_call "$state" fm_wake_decision_log_stale "$state" test:fm-vanished vanished surface terminal-surface 3 none 1 '' '' \
    || fail "could not log the vanished surface"
  [ "$(wc -l < "$state/.wake-decisions.pending" | tr -d '[:space:]')" = 3 ] \
    || fail "three surfaced wakes did not queue three labels"
  # Between presentation and acknowledgement: one task is steered, one is torn
  # down, one is left alone.
  sleep 1
  printf 'working: resuming after the steer\n' >> "$state/touched.status"
  rm -f "$state/vanished.status" "$state/vanished.meta"
  ack_main_cycle "$state" || fail "the drain could not present and acknowledge the three wakes"
  assert_json_lines "$log" "label rows"
  grep -q '"event":"label".*"seq":1,"window":"test:fm-quiet","task":"quiet","label":"noop",' "$log" \
    || fail "an untouched task was not labelled noop"
  grep -q '"event":"label".*"seq":2,"window":"test:fm-touched","task":"touched","label":"acted",' "$log" \
    || fail "a task whose status changed was not labelled acted"
  grep -q '"event":"label".*"seq":3,"window":"test:fm-vanished","task":"vanished","label":"gone",.*"fingerprint_after":"gone"' "$log" \
    || fail "a task whose records vanished was not labelled gone"
  grep '"event":"label"' "$log" | grep -q '"ack_delay_secs":[0-9]' \
    || fail "label rows do not record the acknowledgement delay"
  [ ! -s "$state/.wake-decisions.pending" ] \
    || fail "labelled wakes were left pending: $(cat "$state/.wake-decisions.pending")"
  pass "acknowledging surfaced wakes labels them noop, acted, or gone and clears them from pending"
}

test_acknowledgement_leaves_unconsumed_rows_pending() {
  local dir state log
  dir=$(make_case partial); state="$dir/state"; log="$state/.wake-decisions.jsonl"
  printf 'window=test:fm-later\nkind=ship\n' > "$state/later.meta"
  printf 'done: ready in branch fm/later\n' > "$state/later.status"
  append_wake "$state" stale test:fm-later 'stale: test:fm-later' || fail "could not queue the first wake"
  decision_call "$state" fm_wake_decision_log_stale "$state" test:fm-later later surface terminal-surface 1 none 1 '' '' \
    || fail "could not log the first surface"
  # A pending row above the acknowledged cutoff is not this acknowledgement's
  # to label, so it stays for the next one.
  decision_call "$state" fm_wake_decision_label_through "$state" 0 \
    || fail "labelling through an empty cutoff failed"
  grep -q '"event":"label"' "$log" && fail "a wake above the cutoff was labelled"
  [ "$(wc -l < "$state/.wake-decisions.pending" | tr -d '[:space:]')" = 1 ] \
    || fail "the unacknowledged wake left pending"
  ack_main_cycle "$state" || fail "the drain could not acknowledge the wake"
  grep -q '"event":"label".*"seq":1,.*"label":"noop",' "$log" \
    || fail "the wake was not labelled once acknowledged"
  pass "a surfaced wake stays pending until an acknowledgement consumes it"
}

test_disabled_log_writes_nothing() {
  local dir state
  dir=$(make_case off); state="$dir/state"
  printf 'window=test:fm-off\nkind=ship\n' > "$state/off.meta"
  printf 'done: ready in branch fm/off\n' > "$state/off.status"
  FM_WAKE_DECISION_LOG=off decision_call "$state" fm_wake_decision_log_stale "$state" test:fm-off off surface terminal-surface 1 none 1 '' '' \
    || fail "a disabled log call failed instead of returning quietly"
  [ ! -e "$state/.wake-decisions.jsonl" ] || fail "a disabled log still wrote a decision row"
  [ ! -e "$state/.wake-decisions.pending" ] || fail "a disabled log still queued a label"
  [ ! -e "$state/.wake-decision-surfaced-test_fm-off" ] || fail "a disabled log still counted a surface"
  pass "FM_WAKE_DECISION_LOG=off silences every write"
}

test_size_cap_keeps_newest_rows() {
  local dir state log i lines
  dir=$(make_case cap); state="$dir/state"; log="$state/.wake-decisions.jsonl"
  printf 'window=test:fm-cap\nkind=ship\n' > "$state/cap.meta"
  printf 'done: ready in branch fm/cap\n' > "$state/cap.status"
  i=1
  while [ "$i" -le 12 ]; do
    FM_WAKE_DECISION_LOG_MAX_BYTES=1200 FM_WAKE_DECISION_LOG_KEEP_LINES=3 \
      decision_call "$state" fm_wake_decision_log_stale "$state" test:fm-cap cap absorb terminal-repeat '' none 1 "$i" '' \
      || fail "row $i failed"
    i=$((i + 1))
  done
  lines=$(wc -l < "$log" | tr -d '[:space:]')
  [ "$lines" -le 3 ] || fail "the capped log kept $lines rows instead of at most 3"
  tail -n 1 "$log" | grep -q '"escalations":12,' || fail "the capped log lost its newest row"
  assert_json_lines "$log" "capped rows"
  pass "a log past its size cap keeps only its newest rows"
}

test_decision_row_is_valid_json_with_features
test_acknowledgement_labels_noop_acted_and_gone
test_acknowledgement_leaves_unconsumed_rows_pending
test_disabled_log_writes_nothing
test_size_cap_keeps_newest_rows
