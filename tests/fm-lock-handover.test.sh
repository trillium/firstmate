#!/usr/bin/env bash
# tests/fm-lock-handover.test.sh - session swap-over through fm-lock.sh handover.
#
# Two live "sessions" are real sleep processes that a fake ps reports as Claude
# harnesses; FM_FAKE_HARNESS_PID picks which one the ancestry walk of each
# command resolves to. The cases drive the public commands only: request,
# template, write, release, and show, plus the captain inbox the protocol
# rides on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-handover)
LOCK_BIN="$ROOT/bin/fm-lock.sh"
INBOX_BIN="$ROOT/bin/fm-inbox.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HARNESS_PIDS="$TMP_ROOT/harness-pids"
: > "$HARNESS_PIDS"

cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
# Like the real ps, a pid that is gone reports nothing.
[ -z "$pid" ] || kill -0 "$pid" 2>/dev/null || exit 1
case "$*" in
  *"comm="*)
    if [ -f "$FM_FAKE_HARNESS_DIR/harness-$pid" ]; then printf '%s\n' /usr/local/bin/claude; else printf '%s\n' /bin/bash; fi
    ;;
  *"args="*)
    if [ -f "$FM_FAKE_HARNESS_DIR/harness-$pid" ]; then printf '%s\n' claude; else printf '%s\n' bash; fi
    ;;
  *"ppid="*) printf '%s\n' "${FM_FAKE_HARNESS_PID:-1}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/ps"

cleanup_harnesses() {
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done < "$HARNESS_PIDS"
}
trap 'cleanup_harnesses; fm_test_cleanup' EXIT

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/harness" "$home/projects/bloom"
  printf '%s\n' "# Fleet project registry" "" \
    "- bloom [no-mistakes] - Bloom app; live copy ~/Documents/bloom (added 2026-09-09)" \
    > "$home/data/projects.md"
  printf '%s\n' "$home"
}

# Start a live fake harness for <home> and print its pid.
new_harness() {
  local home=$1 pid
  # Detached from the caller's command substitution, or $(...) would wait on it.
  sleep 600 >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >> "$HARNESS_PIDS"
  : > "$home/harness/harness-$pid"
  printf '%s\n' "$pid"
}

# Run a command as the session whose harness pid is <pid>.
as_session() {  # <home> <pid> <command> [args...]
  local home=$1 pid=$2
  shift 2
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_STATE_OVERRIDE \
    FM_HOME="$home" FM_FAKE_HARNESS_DIR="$home/harness" FM_FAKE_HARNESS_PID="$pid" \
    PATH="$FAKEBIN:$PATH" "$@"
}

run_inbox() {
  local home=$1
  shift
  FM_HOME="$home" "$INBOX_BIN" "$@"
}

# Fill a template so it validates: every placeholder line becomes real text.
fill_template() {  # <template> <out>
  sed 's/<fill in[^>]*>/handled in this test/' "$1" > "$2"
}

test_template_names_notes_registry_and_clones() {
  local home a out
  home=$(make_home template)
  a=$(new_harness "$home")
  as_session "$home" "$a" "$LOCK_BIN" >/dev/null || fail "session A could not take the lock"
  run_inbox "$home" note "please rebuild the pricing page" >/dev/null || fail "note failed"
  out=$(as_session "$home" "$a" "$LOCK_BIN" handover template) || fail "template failed"
  for section in 'Work in progress' 'Open captain asks' 'Promises to the captain' \
    'Facts not yet in durable records' 'Steers not yet reflected in status' 'Projects and local copies'; do
    assert_contains "$out" "## $section" "template is missing section $section"
  done
  assert_contains "$out" "$(run_inbox "$home" list --ids)" "template does not name the unacknowledged note id"
  assert_contains "$out" "please rebuild the pricing page" "template does not summarize the note"
  assert_contains "$out" "live copy ~/Documents/bloom" "template does not carry the registry live-copy location"
  assert_contains "$out" "firstmate clone: projects/bloom" "template does not list firstmate's clones"
  pass "handover template names every pending captain note, registry live copies, and clones"
}

test_takeover_writes_record_then_moves_lock() {
  local home a b req_out req_rc out record_file tmpl note_id
  home=$(make_home takeover)
  a=$(new_harness "$home")
  b=$(new_harness "$home")
  as_session "$home" "$a" "$LOCK_BIN" >/dev/null || fail "session A could not take the lock"
  run_inbox "$home" note "add the winter banner" >/dev/null || fail "note failed"
  note_id=$(run_inbox "$home" list --ids)

  # Release without a request is refused and moves nothing.
  fill_template <(as_session "$home" "$a" "$LOCK_BIN" handover template) "$home/early.md"
  if as_session "$home" "$a" "$LOCK_BIN" handover release "$home/early.md" >/dev/null 2>&1; then
    fail "release without an incoming request succeeded"
  fi
  assert_equals "$a" "$(cat "$home/state/.lock")" "a refused release moved the lock"

  req_out="$home/request.out"
  ( as_session "$home" "$b" "$LOCK_BIN" handover request --no-start --wait 30 > "$req_out" 2>&1; echo $? > "$home/request.rc" ) &
  local waiter=$!
  for _ in $(seq 1 100); do
    [ -f "$home/state/.handover-request" ] && grep -q '^note=' "$home/state/.handover-request" && break
    sleep 0.1
  done
  assert_present "$home/state/.handover-request" "incoming request was not recorded"
  grep -q 'firstmate handover requested' "$home"/state/inbox/*.note \
    || fail "the request did not reach the live session as a captain inbox note"
  grep -q 'check: captain inbox note .* firstmate handover requested' "$home/state/.wake-queue" \
    || fail "the request note did not wake the live session"

  # The incoming session cannot release, and an incomplete record is refused.
  if as_session "$home" "$b" "$LOCK_BIN" handover release "$home/early.md" >/dev/null 2>&1; then
    fail "the session that does not hold the lock released it"
  fi
  tmpl="$home/template.md"
  as_session "$home" "$a" "$LOCK_BIN" handover template > "$tmpl"
  out=$(as_session "$home" "$a" "$LOCK_BIN" handover release "$tmpl" 2>&1) && fail "an unfilled template was accepted"
  assert_contains "$out" "template placeholders remain" "refusal did not name the leftover placeholders"
  grep -v "$note_id" "$tmpl" | sed 's/<fill in[^>]*>/done/' > "$home/missing-note.md"
  out=$(as_session "$home" "$a" "$LOCK_BIN" handover release "$home/missing-note.md" 2>&1) \
    && fail "a record that drops an unacknowledged captain note was accepted"
  assert_contains "$out" "note $note_id is not named" "refusal did not name the dropped captain note"
  assert_equals "$a" "$(cat "$home/state/.lock")" "a refused release moved the lock"
  assert_absent "$home/state/handover.md" "a refused release published a record"

  record_file="$home/record.md"
  fill_template "$tmpl" "$record_file"
  printf '%s\n' "- working in ~/Documents/bloom on app/views/pricing.html.erb" >> "$record_file"
  out=$(as_session "$home" "$a" "$LOCK_BIN" handover release "$record_file" 2>&1) || fail "complete release failed: $out"
  assert_contains "$out" "lock handed over to harness pid $b" "release did not report the transfer"
  wait "$waiter" 2>/dev/null || true
  req_rc=$(cat "$home/request.rc")
  expect_code 0 "$req_rc" "incoming request did not succeed: $(cat "$req_out")"
  assert_contains "$(cat "$req_out")" "the previous session handed over" "incoming session did not report the handover"
  assert_equals "$b" "$(cat "$home/state/.lock")" "the lock did not move to the incoming session"
  assert_absent "$home/state/.handover-request" "the fulfilled request was left pending"
  assert_equals "to_pid=$b" "$(grep '^to_pid=' "$home/state/handover.md")" "record is not addressed to the incoming session"
  grep -q 'pricing.html.erb' "$home/state/handover.md" || fail "record lost the work-in-progress body"
  run_inbox "$home" list --ids | grep -qx "$note_id" || fail "the captain's own note was acknowledged by the handover"
  [ "$(run_inbox "$home" list --ids | wc -l | tr -d ' ')" = 1 ] || fail "the request note was not acknowledged by release"

  # The old session is now read-only; the new one sees the record in its digest.
  if as_session "$home" "$a" "$LOCK_BIN" >/dev/null 2>&1; then
    fail "the outgoing session reacquired the lock it handed over"
  fi
  out=$(as_session "$home" "$b" "$LOCK_BIN" handover show --digest) || fail "show --digest failed"
  assert_contains "$out" "release handover record" "digest did not print the addressed record"
  assert_contains "$out" "pricing.html.erb" "digest did not print the record body"
  pass "takeover: release refuses incomplete records, then publishes the record before moving the lock to the requester"
}

test_request_takes_free_or_stale_lock_directly() {
  local home b dead out
  home=$(make_home stale)
  b=$(new_harness "$home")
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null || true
  printf '%s\n' "$dead" > "$home/state/.lock"
  out=$(as_session "$home" "$b" "$LOCK_BIN" handover request --no-start --wait 5 2>&1) || fail "request on a stale lock failed: $out"
  assert_contains "$out" "no live firstmate session holds the lock" "stale-lock request did not explain itself"
  assert_equals "$b" "$(cat "$home/state/.lock")" "stale-lock request did not take the lock"
  assert_absent "$home/state/.handover-request" "stale-lock request left a pending request"
  pass "a takeover request against a dead session takes the lock directly"
}

test_request_wait_expires_and_rerun_queues_no_second_note() {
  local home a b out before after
  home=$(make_home expiry)
  a=$(new_harness "$home")
  b=$(new_harness "$home")
  as_session "$home" "$a" "$LOCK_BIN" >/dev/null || fail "session A could not take the lock"
  out=$(as_session "$home" "$b" "$LOCK_BIN" handover request --no-start --wait 1 2>&1) && fail "an unanswered request reported success"
  assert_contains "$out" "has not handed over within 1s" "expiry did not say what happened"
  assert_present "$home/state/.handover-request" "expiry dropped the pending request"
  before=$(run_inbox "$home" list --ids | wc -l | tr -d ' ')
  as_session "$home" "$b" "$LOCK_BIN" handover request --no-start --wait 1 >/dev/null 2>&1 && fail "rerun reported success"
  after=$(run_inbox "$home" list --ids | wc -l | tr -d ' ')
  assert_equals "$before" "$after" "a rerun queued a second request note"
  assert_equals "$a" "$(cat "$home/state/.lock")" "an expired request moved the lock"
  out=$(as_session "$home" "$a" "$LOCK_BIN" handover show --digest)
  assert_contains "$out" "HANDOVER REQUESTED (takeover)" "the holder's digest did not surface the pending request"
  assert_contains "$out" "fm-lock.sh handover release" "the holder's digest did not say how to answer"
  pass "an unanswered request expires without moving the lock, stays pending, and reruns idempotently"
}

test_request_fails_when_note_cannot_wake_the_holder() {
  local home a b out status snapshot_note
  home=$(make_home unwoken)
  a=$(new_harness "$home")
  b=$(new_harness "$home")
  as_session "$home" "$a" "$LOCK_BIN" >/dev/null || fail "session A could not take the lock"
  # A wake queue that cannot be appended to: the note saves, but its wake never lands.
  mkdir "$home/state/.wake-queue"
  status=0
  out=$(as_session "$home" "$b" "$LOCK_BIN" handover request --no-start --wait 30 2>&1) || status=$?
  expect_code 1 "$status" "a request whose note never woke the holder must fail"
  assert_contains "$out" "did not wake the live session" "the failed request did not say the holder was not woken"
  assert_not_contains "$out" "handover requested from harness pid" "the failed request claimed it was requested"
  assert_absent "$home/state/.handover-request" "the failed request was still recorded"
  assert_absent "$home/state/.handover-request.tmp" "the failed request left a staged record"
  assert_equals "$a" "$(cat "$home/state/.lock")" "the failed request moved the lock"
  status=0
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$home" FM_FAKE_HARNESS_DIR="$home/harness" \
    PATH="$FAKEBIN:$PATH" "$LOCK_BIN" handover request --snapshot 2>&1) || status=$?
  expect_code 1 "$status" "a snapshot request whose note never woke the holder must fail"
  assert_contains "$out" "did not wake the live session" "the failed snapshot request did not say the holder was not woken"
  assert_absent "$home/state/.handover-request" "the failed snapshot request was still recorded"
  assert_equals "" "$(run_inbox "$home" list --ids)" "a failed request left its request note pending"

  # A failed takeover leaves an already pending snapshot request untouched.
  rmdir "$home/state/.wake-queue"
  sleep 1
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$home" FM_FAKE_HARNESS_DIR="$home/harness" \
    PATH="$FAKEBIN:$PATH" "$LOCK_BIN" handover request --snapshot >/dev/null 2>&1 || fail "snapshot request failed"
  snapshot_note=$(run_inbox "$home" list --ids)
  [ -n "$snapshot_note" ] || fail "the snapshot request queued no note"
  rm -f "$home/state/.wake-queue"
  mkdir "$home/state/.wake-queue"
  as_session "$home" "$b" "$LOCK_BIN" handover request --no-start --wait 30 >/dev/null 2>&1 \
    && fail "a takeover whose note never woke the holder reported success"
  assert_equals snapshot "$(sed -n 's/^kind=//p' "$home/state/.handover-request")" "a failed takeover replaced the pending snapshot request"
  assert_equals "$snapshot_note" "$(run_inbox "$home" list --ids)" "a failed takeover changed the pending request notes"
  pass "a request whose note cannot wake the holder fails at once instead of waiting"
}

test_snapshot_is_requestable_and_readable_from_outside() {
  local home a out record
  home=$(make_home snapshot)
  a=$(new_harness "$home")
  as_session "$home" "$a" "$LOCK_BIN" >/dev/null || fail "session A could not take the lock"
  # An outside controller is not a harness session.
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$home" FM_FAKE_HARNESS_DIR="$home/harness" \
    PATH="$FAKEBIN:$PATH" "$LOCK_BIN" handover request --snapshot 2>&1) || fail "snapshot request failed: $out"
  assert_contains "$out" "handover snapshot requested from harness pid $a" "snapshot request did not name the holder"
  grep -q 'firstmate handover snapshot requested' "$home"/state/inbox/*.note || fail "snapshot request did not reach the holder"
  out=$(as_session "$home" '' "$LOCK_BIN" handover show --json)
  [ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["request"]["kind"])')" = snapshot ] \
    || fail "show --json did not report the pending snapshot request: $out"
  record="$home/snapshot.md"
  fill_template <(as_session "$home" "$a" "$LOCK_BIN" handover template) "$record"
  out=$(as_session "$home" "$a" "$LOCK_BIN" handover write "$record" 2>&1) || fail "snapshot write failed: $out"
  assert_equals "$a" "$(cat "$home/state/.lock")" "a snapshot write moved the lock"
  out=$(as_session "$home" '' "$LOCK_BIN" handover show --json)
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schema"] == "fm-handover.v1", d
assert d["request"] is None, d
assert d["record"]["kind"] == "snapshot", d
assert "## Work in progress" in d["record"]["body"], d
assert "snapshot requested" not in d["record"]["body"], d
assert d["lock"]["state"] == "held", d
' || fail "show --json did not return the written snapshot: $out"
  [ -z "$(run_inbox "$home" list --ids)" ] || fail "the snapshot request note was not acknowledged by write"
  pass "an outside controller can request a snapshot and read it back as JSON while the holder keeps the lock"
}

test_digest_names_old_unaddressed_record_without_printing_it() {
  local home a out
  home=$(make_home old-record)
  a=$(new_harness "$home")
  as_session "$home" "$a" "$LOCK_BIN" >/dev/null || fail "session A could not take the lock"
  printf '%s\n' 'fm_handover=v1' 'kind=release' 'from_pid=1' 'to_pid=999999' 'to_session=' \
    'written_at=1000000000' '--' '## Work in progress' 'SECRET-OLD-BODY' > "$home/state/handover.md"
  out=$(as_session "$home" "$a" "$LOCK_BIN" handover show --digest)
  assert_contains "$out" "older release handover record" "digest did not name the old record"
  assert_not_contains "$out" "SECRET-OLD-BODY" "digest printed an old record addressed to another session"
  out=$(as_session "$home" "$a" "$LOCK_BIN" handover show)
  assert_contains "$out" "SECRET-OLD-BODY" "plain show did not print the record"
  pass "the digest only names an old handover record addressed to another session"
}

test_inbox_list_ids_and_bounds() {
  local home out i
  home=$(make_home inbox-list)
  for i in 1 2 3; do
    run_inbox "$home" note "$(printf 'note %s line one\nline two\nline three' "$i")" >/dev/null || fail "note $i failed"
  done
  [ "$(run_inbox "$home" list --ids | wc -l | tr -d ' ')" = 3 ] || fail "list --ids did not print one id per note"
  out=$(run_inbox "$home" list --max-notes 2 --max-lines 1)
  [ "$(printf '%s\n' "$out" | grep -c 'line one')" = 2 ] || fail "bounded list did not print exactly --max-notes bodies: $out"
  assert_contains "$out" "$(run_inbox "$home" list --ids | tail -n 1)    (body omitted" "bounded list hid a note past the bound"
  assert_contains "$out" "(2 more line(s) omitted" "bounded list did not disclose cut lines"
  pass "fm-inbox.sh list prints ids alone or a bounded view that still names every note"
}

# Run the takeover dance with --finish: A hands the lock to B and stays alive.
# Leaves the home in the finishing posture; sets FIN_A / FIN_B / FIN_HOME.
start_finishing_handover() {  # <home-name> [<item>]
  local item=${2:-finish the pricing banner in ~/Documents/bloom} tmpl rec out waiter
  FIN_HOME=$(make_home "$1")
  FIN_A=$(new_harness "$FIN_HOME")
  FIN_B=$(new_harness "$FIN_HOME")
  as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" >/dev/null || fail "session A could not take the lock"
  ( as_session "$FIN_HOME" "$FIN_B" "$LOCK_BIN" handover request --no-start --wait 30 > "$FIN_HOME/request.out" 2>&1 ) &
  waiter=$!
  for _ in $(seq 1 100); do
    [ -f "$FIN_HOME/state/.handover-request" ] && grep -q '^note=' "$FIN_HOME/state/.handover-request" && break
    sleep 0.1
  done
  tmpl="$FIN_HOME/template.md"
  as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover template --finish > "$tmpl"
  assert_contains "$(cat "$tmpl")" "## Finishing" "template --finish has no Finishing section"
  out=$(as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover template)
  assert_not_contains "$out" "## Finishing" "a plain template carries the Finishing section"
  rec="$FIN_HOME/record.md"
  fill_template "$tmpl" "$rec"
  # No "- " item under Finishing yet, so --finish refuses and the lock stays put.
  out=$(as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover release --finish "$rec" 2>&1) \
    && fail "release --finish without a Finishing item was accepted"
  assert_contains "$out" 'lists no "- " item' "refusal did not name the empty Finishing list"
  assert_equals "$FIN_A" "$(cat "$FIN_HOME/state/.lock")" "a refused release --finish moved the lock"
  printf '%s\n' "- $item" >> "$rec"
  # A Finishing section is refused on a plain release so nobody believes they are finishing.
  out=$(as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover release "$rec" 2>&1) \
    && fail "a plain release accepted a record with a Finishing section"
  assert_contains "$out" "not a release --finish" "plain release refusal did not explain itself"
  out=$(as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover release --finish "$rec" 2>&1) \
    || fail "release --finish failed: $out"
  assert_contains "$out" "FINISHING" "release --finish did not announce the finishing posture"
  wait "$waiter" 2>/dev/null || true
}

test_finishing_posture_bounds_the_outgoing_session() {
  local out rc
  start_finishing_handover finishing "finish the pricing banner in ~/Documents/bloom"
  assert_equals "$FIN_B" "$(cat "$FIN_HOME/state/.lock")" "the lock did not move to the incoming session"
  assert_present "$FIN_HOME/state/.handover-finishing" "release --finish wrote no finishing marker"
  assert_equals "finishing=yes" "$(grep '^finishing=' "$FIN_HOME/state/handover.md")" "record header does not say finishing"

  # The new owner sees the posture and the items in its digest, status, and JSON.
  out=$(as_session "$FIN_HOME" "$FIN_B" "$LOCK_BIN" handover show --digest)
  assert_contains "$out" "finishing: ACTIVE" "digest does not show the finishing posture"
  assert_contains "$out" "finish the pricing banner" "digest does not list the items being finished"
  assert_contains "$out" "Leave those items to the outgoing session" "new owner is not told to leave the items alone"
  out=$(as_session "$FIN_HOME" "$FIN_B" "$LOCK_BIN" handover finishing)
  assert_contains "$out" "finishing: ACTIVE" "finishing status is not active"
  assert_equals "- finish the pricing banner in ~/Documents/bloom" \
    "$(as_session "$FIN_HOME" "$FIN_B" "$LOCK_BIN" handover finishing --items)" "--items did not print exactly the items"
  out=$(as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover finishing)
  assert_contains "$out" "This is the outgoing session" "the outgoing session is not told what to do"
  as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover finishing --check || fail "--check denies the outgoing session"
  if as_session "$FIN_HOME" "$FIN_B" "$LOCK_BIN" handover finishing --check; then
    fail "--check admitted the new owner as the finishing session"
  fi
  if command -v python3 >/dev/null 2>&1; then
    out=$(as_session "$FIN_HOME" "$FIN_B" "$LOCK_BIN" handover show --json) || fail "show --json failed"
    printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
f = d["finishing"]
assert f["active"] is True and f["items"] == ["- finish the pricing banner in ~/Documents/bloom"], f
assert d["record"]["finishing"] is True
' || fail "show --json does not report the finishing posture: $out"
  fi

  # The outgoing session may not take new work, drain, dispatch, or take the lock back.
  out=$(as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" 2>&1) && fail "the finishing session reacquired the lock"
  assert_contains "$out" "only finishing" "lock refusal did not name the finishing posture"
  as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover request --no-start --wait 1 >/dev/null 2>&1 \
    && fail "the finishing session requested a handover back"
  run_inbox "$FIN_HOME" note "a new captain ask" >/dev/null || fail "note failed"
  out=$(as_session "$FIN_HOME" "$FIN_A" "$ROOT/bin/fm-inbox.sh" drain --ack "$(run_inbox "$FIN_HOME" list --ids)" 2>&1) \
    && fail "the finishing session acknowledged a captain note"
  assert_contains "$out" "only finishing" "note acknowledgement refusal did not name the finishing posture"
  out=$(as_session "$FIN_HOME" "$FIN_A" "$ROOT/bin/fm-wake-drain.sh" 2>&1) && fail "the finishing session drained the wake queue"
  assert_contains "$out" "only finishing" "wake drain refusal did not name the finishing posture"
  out=$(as_session "$FIN_HOME" "$FIN_A" "$ROOT/bin/fm-spawn.sh" some-task "$FIN_HOME" "" 2>&1) && fail "the finishing session spawned new work"
  assert_contains "$out" "only finishing" "spawn refusal did not name the finishing posture"
  # The new owner is not bound by the posture.
  as_session "$FIN_HOME" "$FIN_B" "$ROOT/bin/fm-inbox.sh" drain --ack "$(run_inbox "$FIN_HOME" list --ids)" >/dev/null 2>&1 \
    || fail "the new owner could not acknowledge a captain note during the finishing posture"

  # Only the finishing session may end it, and only with a real summary.
  printf 'did it\n' > "$FIN_HOME/summary.md"
  as_session "$FIN_HOME" "$FIN_B" "$LOCK_BIN" handover finished "$FIN_HOME/summary.md" >/dev/null 2>&1 \
    && fail "the new owner ended the outgoing session's finishing posture"
  : > "$FIN_HOME/empty.md"
  as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover finished "$FIN_HOME/empty.md" >/dev/null 2>&1 \
    && fail "finished accepted an empty summary"
  out=$(as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover finished "$FIN_HOME/summary.md" 2>&1) || fail "finished failed: $out"
  assert_contains "$out" "Exit this session now" "finished did not tell the session to exit"
  assert_absent "$FIN_HOME/state/.handover-finishing" "finished left the marker behind"
  assert_equals "$FIN_B" "$(cat "$FIN_HOME/state/.lock")" "finishing disturbed the new owner's lock"
  grep -q '^## Finished by the outgoing session' "$FIN_HOME/state/handover.md" || fail "record gained no finished section"
  grep -q '^did it$' "$FIN_HOME/state/handover.md" || fail "record lost the finished summary"
  grep -q 'finish the pricing banner' "$FIN_HOME/state/handover.md" || fail "record lost the Finishing items"
  out=$(as_session "$FIN_HOME" "$FIN_B" "$LOCK_BIN" handover show --digest)
  assert_contains "$out" "Finished by the outgoing session" "new owner's digest does not show what was finished"
  assert_not_contains "$out" "finishing: ACTIVE" "the digest still shows an active posture after finishing"
  rc=0
  as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover finished "$FIN_HOME/summary.md" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "finished ran twice"
  pass "finishing: the outgoing session stays bounded, the new owner sees it, and finished appends to the record and lifts it"
}

test_finishing_posture_lifts_when_the_new_owner_dies() {
  local out
  start_finishing_handover finishing-dead
  kill "$FIN_B" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$FIN_B" 2>/dev/null || break; sleep 0.1; done
  out=$(as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover finishing)
  assert_contains "$out" "stale marker" "a dead new owner did not make the marker stale"
  if as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" handover finishing --check; then
    fail "--check admitted a finishing session whose new owner is gone"
  fi
  as_session "$FIN_HOME" "$FIN_A" "$LOCK_BIN" >/dev/null 2>&1 || fail "the outgoing session could not reacquire a lock its successor abandoned"
  assert_equals "$FIN_A" "$(cat "$FIN_HOME/state/.lock")" "reacquisition did not record the outgoing session"
  pass "the finishing posture lifts when the new owner is gone, so the old session can reacquire normally"
}

test_plain_release_leaves_no_finishing_posture() {
  local home a b out waiter tmpl rec
  home=$(make_home plain-release)
  a=$(new_harness "$home")
  b=$(new_harness "$home")
  as_session "$home" "$a" "$LOCK_BIN" >/dev/null || fail "session A could not take the lock"
  ( as_session "$home" "$b" "$LOCK_BIN" handover request --no-start --wait 30 >/dev/null 2>&1 ) &
  waiter=$!
  for _ in $(seq 1 100); do
    [ -f "$home/state/.handover-request" ] && grep -q '^note=' "$home/state/.handover-request" && break
    sleep 0.1
  done
  tmpl="$home/t.md"; rec="$home/r.md"
  as_session "$home" "$a" "$LOCK_BIN" handover template > "$tmpl"
  fill_template "$tmpl" "$rec"
  as_session "$home" "$a" "$LOCK_BIN" handover release "$rec" >/dev/null 2>&1 || fail "plain release failed"
  wait "$waiter" 2>/dev/null || true
  assert_absent "$home/state/.handover-finishing" "a plain release wrote a finishing marker"
  assert_contains "$(as_session "$home" "$b" "$LOCK_BIN" handover finishing)" "finishing: none" "plain release shows a finishing posture"
  if as_session "$home" "$a" "$LOCK_BIN" handover write --finish "$rec" >/dev/null 2>&1; then
    fail "write accepted --finish"
  fi
  pass "a plain release leaves no finishing posture, and --finish is release-only"
}

test_template_names_notes_registry_and_clones
test_takeover_writes_record_then_moves_lock
test_request_takes_free_or_stale_lock_directly
test_request_wait_expires_and_rerun_queues_no_second_note
test_request_fails_when_note_cannot_wake_the_holder
test_snapshot_is_requestable_and_readable_from_outside
test_digest_names_old_unaddressed_record_without_printing_it
test_inbox_list_ids_and_bounds
test_finishing_posture_bounds_the_outgoing_session
test_finishing_posture_lifts_when_the_new_owner_dies
test_plain_release_leaves_no_finishing_posture
