#!/usr/bin/env bash
# Behavior tests for bin/fm-review-decision.sh - the firstmate-side half of the
# interactive review decision loop. Given a captain's decision on a review item,
# it must (a) enqueue a durable `check` wake keyed review-decision:<id>, (b)
# annotate the item via `review note`, and (c) append a JSONL audit record - and
# FAIL LOUDLY (non-zero) when the load-bearing wake or annotation cannot land.
#
# Hermetic and network-free. The `review` CLI is stubbed with a bash fake on a
# fakebin whose `note` verb either logs the argv (success) or exits non-zero
# (forced failure), so the fail-loud path is asserted without the real store.
# FM_HOME points at a throwaway temp home so the wake queue is isolated.
#
# Cases:
#   (a) approve      -> exit 0, wake enqueued, note appended, audit line written
#   (b) decline+cmt  -> comment threads into wake payload, note, and audit
#   (c) comment      -> requires text; body reaches all three sinks
#   (d) empty comment-> comment verdict with no text is rejected (exit 1)
#   (e) bad verdict  -> rejected (exit 2), nothing enqueued
#   (f) note failure -> store annotation failure fails loudly (exit 1)
#   (g) --stdin      -> comment read from stdin lands in all three sinks
#   (h) missing args -> usage error (exit 2)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-review-decision.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-decision)

# install_fake_review <fakebin-dir> <note-log> [fail]
#   note verb appends its argv to <note-log>; when [fail] is "fail", note exits 1.
install_fake_review() {
  local dir=$1 log=$2 mode=${3:-ok}
  mkdir -p "$dir"
  if [ "$mode" = fail ]; then
    cat > "$dir/review" <<SH
#!/usr/bin/env bash
case "\$1" in
  note) echo "store unreachable" >&2; exit 1 ;;
  *) exit 0 ;;
esac
SH
  else
    cat > "$dir/review" <<SH
#!/usr/bin/env bash
case "\$1" in
  note) shift; printf 'note %s\n' "\$*" >> "$log" ;;
  *) exit 0 ;;
esac
SH
  fi
  chmod +x "$dir/review"
}

# run_decision <home> <fakebin> <log> <args...> [<stdin>]  -> $OUTPUT/$RC
# A trailing arg that begins with $'\x01' is fed on stdin (used for --stdin case).
run_decision() {
  local home=$1 fakebin=$2 log=$3
  shift 3
  local stdin_data=""
  # Detect an optional stdin sentinel as the LAST arg.
  local last="${!#}"
  local -a args=("$@")
  if [ "${last:0:1}" = $'\x01' ]; then
    stdin_data="${last:1}"
    unset 'args[${#args[@]}-1]'
  fi
  if [ -n "$stdin_data" ]; then
    OUTPUT=$(
      FM_HOME="$home" \
      FM_REVIEW_BIN="$fakebin/review" \
      FM_REVIEW_DECISIONS_LOG="$home/decisions.jsonl" \
        printf '%s' "$stdin_data" | \
      FM_HOME="$home" \
      FM_REVIEW_BIN="$fakebin/review" \
      FM_REVIEW_DECISIONS_LOG="$home/decisions.jsonl" \
        bash "$TOOL" "${args[@]}" 2>&1
    )
    RC=$?
  else
    OUTPUT=$(
      FM_HOME="$home" \
      FM_REVIEW_BIN="$fakebin/review" \
      FM_REVIEW_DECISIONS_LOG="$home/decisions.jsonl" \
        bash "$TOOL" "${args[@]}" 2>&1
    )
    RC=$?
  fi
}

# The wake queue lives at $home/state/.wake-queue (fm-wake-lib derives STATE from
# FM_HOME). Helper to grep it.
wake_queue() { printf '%s/state/.wake-queue' "$1"; }

# ===========================================================================
# (a) approve: exit 0, wake enqueued, note appended, audit line written.
# ===========================================================================
t_approve() {
  local case_dir="$TMP_ROOT/approve"; local home="$case_dir/home" fakebin="$case_dir/bin"
  local log="$case_dir/notes.log"
  mkdir -p "$home"
  install_fake_review "$fakebin" "$log"

  run_decision "$home" "$fakebin" "$log" review-znt approve
  expect_code 0 "$RC" "approve: exit 0"

  assert_grep "check	" "$(wake_queue "$home")" "approve: a check-kind wake landed"
  assert_grep "review-decision:review-znt" "$(wake_queue "$home")" "approve: wake keyed to the item"
  assert_grep "captain decided approve on review-znt" "$(wake_queue "$home")" "approve: wake payload carries verdict"
  assert_grep "note review-znt Captain decision: approve" "$log" "approve: item annotated with the decision"
  assert_grep '"verdict":"approve"' "$home/decisions.jsonl" "approve: audit record written"
  assert_grep '"id":"review-znt"' "$home/decisions.jsonl" "approve: audit record carries id"

  pass "fm-review-decision: approve enqueues wake, annotates item, writes audit"
}

# ===========================================================================
# (b) decline with a comment: comment threads into wake payload, note, audit.
# ===========================================================================
t_decline_comment() {
  local case_dir="$TMP_ROOT/decline"; local home="$case_dir/home" fakebin="$case_dir/bin"
  local log="$case_dir/notes.log"
  mkdir -p "$home"
  install_fake_review "$fakebin" "$log"

  run_decision "$home" "$fakebin" "$log" review-dmv decline "too risky right now"
  expect_code 0 "$RC" "decline: exit 0"
  assert_grep "captain decided decline on review-dmv - too risky right now" "$(wake_queue "$home")" "decline: comment in wake payload"
  assert_grep "note review-dmv Captain decision: decline - too risky right now" "$log" "decline: comment in note"
  assert_grep '"comment":"too risky right now"' "$home/decisions.jsonl" "decline: comment in audit"

  pass "fm-review-decision: decline+comment threads the comment into every sink"
}

# ===========================================================================
# (c) comment verdict with text: body reaches all three sinks.
# ===========================================================================
t_comment() {
  local case_dir="$TMP_ROOT/comment"; local home="$case_dir/home" fakebin="$case_dir/bin"
  local log="$case_dir/notes.log"
  mkdir -p "$home"
  install_fake_review "$fakebin" "$log"

  run_decision "$home" "$fakebin" "$log" review-2az comment "what about the QBO edge case?"
  expect_code 0 "$RC" "comment: exit 0"
  assert_grep "review-decision:review-2az" "$(wake_queue "$home")" "comment: wake enqueued"
  assert_grep "note review-2az Captain decision: comment - what about the QBO edge case?" "$log" "comment: note carries the comment"

  pass "fm-review-decision: comment verdict routes the comment body to all sinks"
}

# ===========================================================================
# (d) comment verdict with empty text is rejected (exit 1), nothing enqueued.
# ===========================================================================
t_empty_comment() {
  local case_dir="$TMP_ROOT/empty"; local home="$case_dir/home" fakebin="$case_dir/bin"
  local log="$case_dir/notes.log"
  mkdir -p "$home"
  install_fake_review "$fakebin" "$log"

  run_decision "$home" "$fakebin" "$log" review-znt comment "   "
  [ "$RC" -ne 0 ] || fail "empty-comment: expected non-zero exit, got 0"
  assert_contains "$OUTPUT" "requires non-empty comment" "empty-comment: loud rejection"
  assert_absent "$(wake_queue "$home")" "empty-comment: no wake enqueued"

  pass "fm-review-decision: empty comment verdict is rejected, nothing enqueued"
}

# ===========================================================================
# (e) invalid verdict is rejected (exit 2), nothing enqueued.
# ===========================================================================
t_bad_verdict() {
  local case_dir="$TMP_ROOT/bad"; local home="$case_dir/home" fakebin="$case_dir/bin"
  local log="$case_dir/notes.log"
  mkdir -p "$home"
  install_fake_review "$fakebin" "$log"

  run_decision "$home" "$fakebin" "$log" review-znt yolo
  expect_code 2 "$RC" "bad-verdict: exit 2"
  assert_contains "$OUTPUT" "invalid verdict" "bad-verdict: loud rejection"
  assert_absent "$(wake_queue "$home")" "bad-verdict: no wake enqueued"

  pass "fm-review-decision: invalid verdict is rejected (exit 2), nothing enqueued"
}

# ===========================================================================
# (f) FAIL LOUD: when `review note` fails, the whole command fails (exit 1).
# This is the robots-5l8 guarantee - never a silent ok when a load-bearing step
# cannot deliver.
# ===========================================================================
t_note_failure() {
  local case_dir="$TMP_ROOT/notefail"; local home="$case_dir/home" fakebin="$case_dir/bin"
  local log="$case_dir/notes.log"
  mkdir -p "$home"
  install_fake_review "$fakebin" "$log" fail

  run_decision "$home" "$fakebin" "$log" review-znt approve
  [ "$RC" -ne 0 ] || fail "note-failure: expected non-zero exit on store failure, got 0"
  assert_contains "$OUTPUT" "failed to annotate review item review-znt" "note-failure: loud diagnostic"

  pass "fm-review-decision: store annotation failure fails loudly (no silent ok)"
}

# ===========================================================================
# (g) --stdin: comment read from stdin lands in all three sinks.
# ===========================================================================
t_stdin_comment() {
  local case_dir="$TMP_ROOT/stdin"; local home="$case_dir/home" fakebin="$case_dir/bin"
  local log="$case_dir/notes.log"
  mkdir -p "$home"
  install_fake_review "$fakebin" "$log"

  # Trailing $'\x01'-prefixed arg is fed on stdin by run_decision.
  run_decision "$home" "$fakebin" "$log" review-bk6 comment --stdin $'\x01multi word stdin comment'
  expect_code 0 "$RC" "stdin: exit 0"
  assert_grep "multi word stdin comment" "$(wake_queue "$home")" "stdin: comment reached the wake"
  assert_grep "note review-bk6 Captain decision: comment - multi word stdin comment" "$log" "stdin: comment reached the note"

  pass "fm-review-decision: --stdin comment lands in every sink"
}

# ===========================================================================
# (h) missing args -> usage error (exit 2).
# ===========================================================================
t_missing_args() {
  local case_dir="$TMP_ROOT/missing"; local home="$case_dir/home" fakebin="$case_dir/bin"
  local log="$case_dir/notes.log"
  mkdir -p "$home"
  install_fake_review "$fakebin" "$log"

  run_decision "$home" "$fakebin" "$log" review-znt
  expect_code 2 "$RC" "missing-args: exit 2"

  pass "fm-review-decision: missing verdict is a usage error (exit 2)"
}

t_approve
t_decline_comment
t_comment
t_empty_comment
t_bad_verdict
t_note_failure
t_stdin_comment
t_missing_args
