#!/usr/bin/env bash
# Tests for robots-73la: state/<id>.meta must never hold duplicate keys.
# bin/fm-decision-hold.sh blindly appended decisions_reviewed=/decision_keys=,
# and readers disagreed on duplicates (tail -1 vs first match), which let a
# second decision-hold review make a task endpoint permanently unresolvable.
# bin/fm-backend.sh now owns the single writer (fm_meta_set, replace-in-place)
# and the single exact-value reader (fm_meta_get_exact, fail-closed on
# duplicates); this suite proves duplicates are impossible and readers agree.
#
# Matrix:
#   (a) writer creates exactly one line for a fresh key
#   (b) writer collapses the bead's exact repro (doubled decisions_reviewed= /
#       decision_keys=) to one line each, preserving every other line
#   (c) repeated writer runs stay at exactly one line (idempotent)
#   (d) empty value removes the key instead of writing an empty line
#   (e) line-unsafe key is refused and the file is untouched
#   (f) exact reader: single value wins, absent/duplicate/empty all fail
#   (g) end to end: duplicated worktree= makes fm-review-diff.sh refuse with
#       the missing-worktree error, and fm_meta_set repair makes it run
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-meta-duplicate-keys-tests)

count_key() {  # <file> <key> -> number of key= lines
  grep -c "^$2=" "$1" 2>/dev/null || true
}

test_writer_creates_single_line() {
  local meta="$TMP_ROOT/a.meta"
  : > "$meta"
  fm_meta_set "$meta" worktree /wt || fail "fresh-key write failed"
  [ "$(count_key "$meta" worktree)" = 1 ] || fail "fresh-key write is not single"
  [ "$(fm_meta_get_exact "$meta" worktree)" = /wt ] || fail "fresh-key readback wrong"
  pass "writer creates a single line for a fresh key"
}

test_writer_collapses_bead_repro() {
  local meta="$TMP_ROOT/b.meta"
  fm_write_meta "$meta" \
    "window=fm-repro" \
    "worktree=/wt" \
    "project=/proj" \
    "decisions_reviewed=1" \
    "decision_keys=k1" \
    "decisions_reviewed=1" \
    "decision_keys=k1"
  fm_meta_set "$meta" decisions_reviewed 1 || fail "reviewed rewrite failed"
  fm_meta_set "$meta" decision_keys "k1,k2" || fail "keys rewrite failed"
  [ "$(count_key "$meta" decisions_reviewed)" = 1 ] || fail "decisions_reviewed still duplicated"
  [ "$(count_key "$meta" decision_keys)" = 1 ] || fail "decision_keys still duplicated"
  [ "$(fm_meta_get_exact "$meta" decision_keys)" = "k1,k2" ] || fail "new keys value lost"
  [ "$(fm_meta_get_exact "$meta" window)" = fm-repro ] || fail "unrelated window line disturbed"
  [ "$(fm_meta_get_exact "$meta" worktree)" = /wt ] || fail "unrelated worktree line disturbed"
  [ "$(fm_meta_get_exact "$meta" project)" = /proj ] || fail "unrelated project line disturbed"
  pass "writer collapses the doubled decision inventory to one line each"
}

test_writer_is_idempotent() {
  local meta="$TMP_ROOT/c.meta"
  fm_write_meta "$meta" "pr=https://example.invalid/x"
  fm_meta_set "$meta" pr "https://example.invalid/x" || fail "first rewrite failed"
  fm_meta_set "$meta" pr "https://example.invalid/x" || fail "second rewrite failed"
  fm_meta_set "$meta" pr "https://example.invalid/y" || fail "value-change rewrite failed"
  [ "$(count_key "$meta" pr)" = 1 ] || fail "repeated writes duplicated the key"
  [ "$(fm_meta_get_exact "$meta" pr)" = "https://example.invalid/y" ] || fail "latest value did not win"
  pass "repeated writer runs keep exactly one line"
}

test_empty_value_removes_key() {
  local meta="$TMP_ROOT/d.meta"
  fm_write_meta "$meta" "decision_keys=k1" "window=fm-d"
  fm_meta_set "$meta" decision_keys "" || fail "empty-value removal failed"
  [ "$(count_key "$meta" decision_keys)" = 0 ] || fail "empty value left a line behind"
  fm_meta_get_exact "$meta" decision_keys 2>/dev/null && fail "removed key still reads"
  [ "$(fm_meta_get_exact "$meta" window)" = fm-d ] || fail "unrelated line disturbed by removal"
  pass "empty value removes the key"
}

test_unsafe_key_refused() {
  local meta="$TMP_ROOT/e.meta"
  fm_write_meta "$meta" "window=fm-e"
  fm_meta_set "$meta" 'bad=key' x 2>/dev/null && fail "line-unsafe key was accepted"
  [ "$(count_key "$meta" window)" = 1 ] || fail "refused write disturbed the file"
  fm_meta_set "$meta" '' x 2>/dev/null && fail "empty key was accepted"
  pass "line-unsafe key is refused without touching the file"
}

test_exact_reader_verdicts() {
  local meta="$TMP_ROOT/f.meta"
  fm_write_meta "$meta" "window=fm-f" "empty=" "dup=1" "dup=2"
  [ "$(fm_meta_get_exact "$meta" window)" = fm-f ] || fail "single value misread"
  fm_meta_get_exact "$meta" absent 2>/dev/null && fail "absent key read as set"
  fm_meta_get_exact "$meta" dup 2>/dev/null && fail "duplicated key read as set"
  fm_meta_get_exact "$meta" empty 2>/dev/null && fail "empty value read as set"
  fm_backend_meta_exact_value "$meta" window >/dev/null || fail "backend exact wrapper diverged"
  fm_backend_meta_exact_value "$meta" dup 2>/dev/null && fail "backend exact wrapper diverged on duplicates"
  pass "exact reader accepts one value and refuses absent, duplicated, and empty"
}

test_review_diff_refuses_duplicates_then_runs_after_repair() {
  local case_dir="$TMP_ROOT/g" meta out
  mkdir -p "$case_dir/state"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  meta="$case_dir/state/task-x1.meta"
  fm_write_meta "$meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project"
  if out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-review-diff.sh" task-x1 --stat 2>&1); then
    fail "review-diff accepted a duplicated worktree key: $out"
  fi
  case "$out" in
    *"missing worktree="*) ;;
    *) fail "review-diff refused duplicates with the wrong error: $out" ;;
  esac
  fm_meta_set "$meta" worktree "$case_dir/wt" || fail "repair write failed"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-review-diff.sh" task-x1 --stat 2>&1) || fail "review-diff failed after repair: $out"
  pass "review-diff refuses duplicated keys and runs after writer repair"
}

test_writer_creates_single_line
test_writer_collapses_bead_repro
test_writer_is_idempotent
test_empty_value_removes_key
test_unsafe_key_refused
test_exact_reader_verdicts
test_review_diff_refuses_duplicates_then_runs_after_repair
