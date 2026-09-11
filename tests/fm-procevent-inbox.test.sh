#!/usr/bin/env bash
# Behavior tests for the inbox-store event adapter (task-z8sn4).
#
# The adapter tails a JSONL watch file the way the inbox create-wrapper
# appends to it: each new line is only a signal to re-check the store, never
# the payload. Tests use isolated temp watch files and temp homes, never the
# live ~/data/inbox/events.jsonl, and never touch prod inbox items.
#
# Timing is structural, not clock-based: the source under test blocks until
# new bytes arrive (or its short WAIT window closes with exit 75), and the
# round-trip drives completion by appending to the watch file, then waiting
# on the runner's own durable artifacts (claim, result, wake-queue).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-inbox-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

INBOX_ADAPTER="$ROOT/bin/fm-procevent-inbox.sh"

new_home() { mkdir -p "$1/state"; }

new_watch() { # <path>; seed with one history line the arm must NOT replay
  printf '{"id":"inbox-history","created_at":"2026-09-11T00:00:00Z"}\n' > "$1"
}

inbox() { FM_HOME="$1" "$INBOX_ADAPTER" "${@:2}"; }

wait_for() { # <file> [tries]
  local f=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -s "$f" ] && return 0; sleep 0.1; done
  return 1
}

# --- arm starts at EOF: history is never replayed, id is stable ---------------
H1="$TMP_ROOT/h1"; new_home "$H1"
W1="$TMP_ROOT/w1.jsonl"; new_watch "$W1"
out=$(INBOX_EVENTS_FILE="$W1" inbox "$H1" arm "$W1")
assert_contains "$out" "registered: inbox-" "arm registers an inbox source"
SID1=$(INBOX_EVENTS_FILE="$W1" inbox "$H1" source-id "$W1")
case "$SID1" in inbox-????????????????) ;; *) fail "source id has the wrong shape: $SID1" ;; esac
assert_contains "$out" "armed: $SID1" "arm reports the canonical source id"
[ "$(cat "$H1/state/inbox-cursor/$SID1.offset")" = "$(wc -c < "$W1" | tr -d ' ')" ] \
  || fail "first arm does not start at EOF"
out2=$(INBOX_EVENTS_FILE="$W1" inbox "$H1" arm "$W1")
assert_contains "$out2" "armed: $SID1" "re-arm keeps the canonical source id"
[ "$(cat "$H1/state/inbox-cursor/$SID1.offset")" = "$(wc -c < "$W1" | tr -d ' ')" ] \
  || fail "re-arm reset the cursor"
pass "arm starts at EOF with a stable id and never resets the cursor"

# --- idle source times out with exit 75 and no output --------------------------
FM_INBOX_WAIT_SECONDS=2 inbox "$H1" source "$SID1" > "$TMP_ROOT/idle.out" 2>/dev/null
rc=$?
[ "$rc" -eq 75 ] || fail "idle source exited $rc, want 75"
[ ! -s "$TMP_ROOT/idle.out" ] || fail "idle source emitted output on timeout"
pass "an idle source exits 75 with no output"

# --- torn writes wait: a partial line is never emitted -------------------------
printf '{"id":"inbox-half"' >> "$W1"
FM_INBOX_WAIT_SECONDS=2 inbox "$H1" source "$SID1" > "$TMP_ROOT/torn.out" 2>/dev/null
rc=$?
[ "$rc" -eq 75 ] || fail "torn source exited $rc, want 75"
[ ! -s "$TMP_ROOT/torn.out" ] || fail "torn source emitted a partial line"
printf ',"created_at":"2026-09-11T00:00:01Z"}\n' >> "$W1"
FM_INBOX_WAIT_SECONDS=5 inbox "$H1" source "$SID1" > "$TMP_ROOT/whole.out" 2>/dev/null \
  || fail "completed source did not exit 0"
assert_grep '"id":"inbox-half"' "$TMP_ROOT/whole.out" "the completed line is emitted whole"
assert_grep 'schema=fm-inbox-delta.v1' "$TMP_ROOT/whole.out" "the result carries the delta schema"
assert_grep 'payload_lines=1' "$TMP_ROOT/whole.out" "the result counts its batch"
out=$(inbox "$H1" classify "$TMP_ROOT/whole.out")
assert_contains "$out" "inbox-event" "a batch classifies as inbox-event"
if inbox "$H1" terminal "$TMP_ROOT/whole.out" 2>/dev/null; then
  fail "an inbox batch must never be terminal"
fi
pass "torn writes wait for line completion and classify without retiring"

# --- rotation never replays: a smaller file resets forward ---------------------
printf '{"id":"inbox-newgen"}\n' > "$W1"
FM_INBOX_WAIT_SECONDS=2 inbox "$H1" source "$SID1" > "$TMP_ROOT/rot.out" 2>/dev/null
rc=$?
[ "$rc" -eq 75 ] || fail "rotated source exited $rc, want 75"
[ ! -s "$TMP_ROOT/rot.out" ] || fail "rotated source replayed the truncated prefix"
pass "rotation resets forward instead of replaying"

# --- runner round-trip: capture, wake, autohandle, no duplicates ---------------
H2="$TMP_ROOT/h2"; new_home "$H2"
W2="$TMP_ROOT/w2.jsonl"; new_watch "$W2"
INBOX_EVENTS_FILE="$W2" inbox "$H2" arm "$W2" >/dev/null
SID2=$(INBOX_EVENTS_FILE="$W2" inbox "$H2" source-id "$W2")
printf '{"id":"inbox-rt1"}\n{"id":"inbox-rt2"}\n' >> "$W2"
FM_INBOX_WAIT_SECONDS=25 FM_HOME="$H2" "$ROOT/bin/fm-procevent.sh" start "$SID2" \
  > "$TMP_ROOT/start.out" 2>&1 &
runner=$!
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$SID2.claim" || fail "inbox start never claimed its source"
wait "$runner" || fail "inbox start failed after the batch completed"
assert_contains "$(cat "$TMP_ROOT/start.out")" "captured:" "start captures the inbox batch"
assert_contains "$(cat "$TMP_ROOT/start.out")" "autohandled:" "the cursor advance is applied by the runner"
payload=$(awk -F '\t' '{print $5}' "$H2/state/.wake-queue" 2>/dev/null)
assert_contains "$payload" "procevent inbox $SID2 1" "completion publishes the committed sequence"
assert_not_contains "$payload" "inbox-rt1" "watch-file bytes never reach the event line"
[ -f "$H2/state/procevent-inbox/$SID2.1.handled" ] \
  || fail "autohandle did not record the acknowledgement"
assert_grep '"id":"inbox-rt1"' "$H2/state/procevent-inbox/$SID2.1.result" "the capture holds the batch verbatim"
cursor_after_one=$(cat "$H2/state/inbox-cursor/$SID2.offset")
printf '{"id":"inbox-rt3"}\n' >> "$W2"
FM_INBOX_WAIT_SECONDS=5 inbox "$H2" source "$SID2" > "$TMP_ROOT/next.out" 2>/dev/null \
  || fail "follow-up source did not exit 0"
assert_not_contains "$(cat "$TMP_ROOT/next.out")" "inbox-rt1" "handled batches are never re-emitted"
assert_grep '"id":"inbox-rt3"' "$TMP_ROOT/next.out" "only unhandled lines follow the cursor"
[ "$(cat "$H2/state/inbox-cursor/$SID2.offset")" = "$cursor_after_one" ] \
  || fail "source alone moved the cursor; only handling may advance it"
pass "one batch yields one normalized wake, acknowledges, and never re-emits"

# --- reconcile arms an inbox source with no live owner -------------------------
H3="$TMP_ROOT/h3"; new_home "$H3"
W3="$TMP_ROOT/w3.jsonl"; new_watch "$W3"
INBOX_EVENTS_FILE="$W3" inbox "$H3" arm "$W3" >/dev/null
out=$(FM_HOME="$H3" "$ROOT/bin/fm-procevent.sh" reconcile)
assert_contains "$out" "started=1" "reconcile starts the orphaned inbox runner"
FM_HOME="$H3" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
pass "reconcile repairs inbox liveness like any other source"

fm_test_cleanup
