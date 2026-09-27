#!/usr/bin/env bash
# tests/fm-wake-consolidation.test.sh - pending-queue wake consolidation
# (robots-o94e): one wake per turn, never one per queued entry or per poll
# while a record sits unconsumed, and a drain chain that survives a Pi tool
# guard aborting bare sleep. Behavioral throughout: every assertion drives a
# production executable or the production wake library and counts real queue
# rows, never source bytes.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
GUARD="$ROOT/bin/fm-guard.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-consolidation)

queue_rows() {
  awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$1/.wake-queue" 2>/dev/null
}

append_once() {
  local state=$1 kind=$2 key=$3 payload=$4
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_append_once "$2" "$3" "$4"
  ' _ "$LIB" "$kind" "$key" "$payload"
}

test_append_once_collapses_repeats_while_pending() {
  local dir state drain_out status
  dir=$(make_case append-once)
  state="$dir/state"
  drain_out="$dir/drain.out"
  # Three identical appends (the pre-grace scan, the post-grace re-scan, and a
  # re-poll while the record sits unconsumed) must leave exactly one row.
  append_once "$state" signal task.status "signal: one" || fail "first append-once failed"
  append_once "$state" signal task.status "signal: two" || fail "repeat append-once failed"
  append_once "$state" signal task.status "signal: three" || fail "third append-once failed"
  [ "$(queue_rows "$state")" -eq 1 ] || fail "repeat append-once left $(queue_rows "$state") rows, want 1"
  # A distinct key is a distinct wake, not a duplicate: it must still append.
  append_once "$state" signal other.status "signal: other" || fail "distinct-key append-once failed"
  [ "$(queue_rows "$state")" -eq 2 ] || fail "distinct key did not append, rows=$(queue_rows "$state")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain failed"
  [ "$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$drain_out")" -eq 2 ] \
    || fail "drain did not print both consolidated rows"
  # Suppression ends at consumption: after the drain the same key appends again.
  append_once "$state" signal task.status "signal: after drain" || fail "post-drain append-once failed"
  [ "$(queue_rows "$state")" -eq 1 ] || fail "post-drain append-once left $(queue_rows "$state") rows, want 1"
  # Kind validation matches fm_wake_append: garbage is still rejected.
  status=0
  append_once "$state" bogus task.status "nope" 2>/dev/null || status=$?
  [ "$status" -eq 2 ] || fail "append-once rejected invalid kind with status $status, want 2"
  pass "append-once collapses repeats while pending and releases after drain"
}

test_watcher_signal_path_emits_one_record_per_file() {
  local dir state fakebin out rows
  dir=$(make_case signal-consolidation)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'blocked: needs a decision\n' > "$state/task.status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  wait_for_exit "$!" 60 || fail "watcher did not exit for first signal"
  grep -F "signal:" "$out" >/dev/null || fail "watcher did not print a signal wake"
  rows=$(queue_rows "$state")
  [ "$rows" -eq 1 ] || fail "one signal turn queued $rows rows, want 1 (pre/post-grace double scan)"
  # A second change while the first record sits unconsumed must not pad the
  # queue: the pending record already guarantees the handling turn.
  printf 'blocked: still needs a decision\n' >> "$state/task.status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  wait_for_exit "$!" 60 || fail "watcher did not exit for second signal"
  rows=$(queue_rows "$state")
  [ "$rows" -eq 1 ] || fail "re-poll while pending queued $rows rows, want 1"
  pass "watcher signal path emits one queued record per file per turn"
}

test_drain_chain_survives_pi_sleep_guard() {
  local dir state fakebin marker drain_out guard_out holder drain_pid i
  dir=$(make_case pi-sleep-guard)
  state="$dir/state"
  fakebin="$dir/fakebin"
  marker="$dir/sleep-calls"
  drain_out="$dir/drain.out"
  guard_out="$dir/guard.out"
  # A Pi tool guard that aborts bare sleep: fail it loudly and record any call,
  # so any remaining bare-sleep dependency in the chain is both fatal and
  # visible. /bin/sleep stays real, which is exactly the production fix.
  cat > "$fakebin/sleep" <<SH
#!/usr/bin/env bash
printf 'bare-sleep\n' >> "$marker"
exit 1
SH
  chmod +x "$fakebin/sleep"
  append_wake "$state" check "pi-check" "check: pi sleep-guard probe" || fail "setup append failed"
  # Hold the queue lock from the background so the drain's lock wait actually
  # sleeps; a bare sleep there would hit the failing stub above.
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    /bin/sleep 3
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  ' _ "$LIB" &
  holder=$!
  # Let the holder claim the lock first so the drain's wait really sleeps.
  /bin/sleep 0.5
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT=1 "$DRAIN" > "$drain_out" 2>&1 &
  drain_pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$drain_pid" 2>/dev/null; do /bin/sleep 0.1; i=$((i + 1)); done
  if kill -0 "$drain_pid" 2>/dev/null; then
    kill "$drain_pid" "$holder" 2>/dev/null || true
    fail "drain did not finish under a failing bare sleep"
  fi
  wait "$drain_pid" || fail "drain failed under a failing bare sleep"
  wait "$holder" 2>/dev/null || true
  grep -F "pi-check" "$drain_out" >/dev/null || fail "drain lost its record under a failing bare sleep"
  # The guard warns on the re-queued wake without touching bare sleep either.
  # It only reaches the queue warning with work in flight, so stage a meta.
  printf 'window=test:fm-pi-guard\nkind=ship\n' > "$state/guard.meta"
  append_wake "$state" check "pi-check-two" "check: guard probe" || fail "guard setup append failed"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$GUARD" > "$guard_out" 2>&1 \
    || fail "guard failed under a failing bare sleep"
  grep -F "queued wakes pending" "$guard_out" >/dev/null || fail "guard did not warn on the pending queue"
  [ -e "$marker" ] && fail "drain/guard chain called bare sleep (Pi guard would abort it)"
  pass "drain and guard complete without bare sleep"
}

test_append_once_collapses_repeats_while_pending
test_watcher_signal_path_emits_one_record_per_file
test_drain_chain_survives_pi_sleep_guard
