#!/usr/bin/env bash
# Behavior tests for bin/fm-target-base.sh: a branch destined for another
# repository's pull request is anchored on, and checked against, that
# repository's default branch rather than the clone's fork default branch.
#
# The fixture is a local "upstream" repository and a "fork" that has diverged
# from it with extra history, which is the shape that put fork-only commits into
# an upstream pull request. Only the script's executable interface is used.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TARGET_BASE="$ROOT/bin/fm-target-base.sh"
TMP_ROOT=$(fm_test_tmproot fm-target-base)
SCOPE=example.invalid/owner/repo

git_in() {
  local dir=$1
  shift
  git -C "$dir" -c user.name=fixture -c user.email=fixture@example.invalid "$@"
}

commit_file() {  # <dir> <file> <message>
  printf '%s\n' "$3" > "$1/$2"
  git_in "$1" add "$2" || fail "could not add $2 in $1"
  git_in "$1" commit -q -m "$3" || fail "could not commit in $1"
}

# make_case <name> - upstream (main), a bare fork of it, and a clone of the fork
# (origin) whose published main carries two fork-only commits. Echoes the case
# directory; the clone is <dir>/clone.
make_case() {
  local d="$TMP_ROOT/$1"
  git init -q -b main "$d/upstream" || fail "could not init upstream"
  commit_file "$d/upstream" README.md upstream-1
  git clone -q --bare "$d/upstream" "$d/fork.git" || fail "could not create the fork"
  git clone -q "$d/fork.git" "$d/clone" || fail "could not clone the fork"
  commit_file "$d/clone" fork-only-1.txt fork-1
  commit_file "$d/clone" fork-only-2.txt fork-2
  git_in "$d/clone" push -q origin main || fail "could not publish fork-only commits"
  # The upstream moves on after the fork diverged.
  commit_file "$d/upstream" CHANGELOG.md upstream-2
  printf '%s\n' "$d"
}

run_tb() {  # <clone> <args...>
  local clone=$1
  shift
  (cd "$clone" && "$TARGET_BASE" "$@" 2>&1)
}

test_anchor_moves_a_fresh_branch_onto_the_target() {
  local d clone out rc
  d=$(make_case anchor-fresh)
  clone=$d/clone
  git_in "$clone" checkout -q -b fm/task || fail "could not branch"
  rc=0
  out=$(run_tb "$clone" anchor "$SCOPE" --url "$d/upstream") || rc=$?
  expect_code 0 "$rc" "anchor on a fresh branch"
  assert_equals "$(git -C "$d/upstream" rev-parse main)" "$(git -C "$clone" rev-parse HEAD)" \
    "anchor must leave the branch at the target's tip, not the fork's"
  assert_absent "$clone/fork-only-1.txt" "fork-only history must be gone from the anchored branch"
  pass "fm-target-base.sh: anchor starts a fresh branch from the target, not the fork"
}

test_anchor_refuses_to_discard_branch_work() {
  local d clone out rc before
  d=$(make_case anchor-work)
  clone=$d/clone
  git_in "$clone" checkout -q -b fm/task || fail "could not branch"
  commit_file "$clone" mine.txt mine
  before=$(git -C "$clone" rev-parse HEAD)
  rc=0
  out=$(run_tb "$clone" anchor "$SCOPE" --url "$d/upstream") || rc=$?
  expect_code 1 "$rc" "anchor over unlanded work"
  assert_contains "$out" "unpublished commits" "refusal must say the branch carries unpublished work"
  assert_equals "$before" "$(git -C "$clone" rev-parse HEAD)" "a refused anchor must not move the branch"
  pass "fm-target-base.sh: anchor refuses to discard commits"
}

test_check_passes_a_clean_branch_and_lists_files() {
  local d clone out rc
  d=$(make_case check-clean)
  clone=$d/clone
  git_in "$clone" checkout -q -b fm/task || fail "could not branch"
  run_tb "$clone" anchor "$SCOPE" --url "$d/upstream" >/dev/null || fail "anchor failed"
  commit_file "$clone" bin-fix.sh fix
  rc=0
  out=$(run_tb "$clone" check "$SCOPE" --url "$d/upstream" --allow 'bin-*.sh') || rc=$?
  expect_code 0 "$rc" "check on an anchored branch"
  assert_contains "$out" "files changed beyond target: 1" "check must count only the task's file"
  assert_contains "$out" "bin-fix.sh" "check must list the changed file"
  pass "fm-target-base.sh: check accepts an anchored branch touching only intended files"
}

test_check_refuses_a_branch_built_on_the_fork() {
  local d clone out rc
  d=$(make_case check-fork)
  clone=$d/clone
  git_in "$clone" checkout -q -b fm/task || fail "could not branch"
  commit_file "$clone" bin-fix.sh fix
  rc=0
  out=$(run_tb "$clone" check "$SCOPE" --url "$d/upstream") || rc=$?
  expect_code 1 "$rc" "check on a fork-based branch"
  assert_contains "$out" "does not contain" "refusal must say the target tip is missing from the branch"
  pass "fm-target-base.sh: check refuses a branch built on the fork's history"
}

test_check_refuses_a_fork_history_that_swallowed_the_target() {
  local d clone out rc
  d=$(make_case check-merged)
  clone=$d/clone
  git_in "$clone" checkout -q -b fm/task || fail "could not branch"
  git_in "$clone" fetch -q "$d/upstream" main || fail "could not fetch upstream"
  git_in "$clone" merge -q --no-edit FETCH_HEAD || fail "could not merge upstream into the fork branch"
  commit_file "$clone" bin-fix.sh fix
  rc=0
  out=$(run_tb "$clone" check "$SCOPE" --url "$d/upstream" --allow 'bin-*.sh') || rc=$?
  expect_code 1 "$rc" "check when the fork's extra files ride along"
  assert_contains "$out" "fork-only-1.txt" "the allow list must name the fork-only file that rode along"
  assert_contains "$out" "outside the intended set" "refusal must say which files are unintended"
  pass "fm-target-base.sh: check names fork-only files even when the target tip is an ancestor"
}

test_unreachable_target_is_refused() {
  local d clone out rc
  d=$(make_case unreachable)
  clone=$d/clone
  rc=0
  out=$(run_tb "$clone" check "$SCOPE" --url "$d/no-such-repo") || rc=$?
  expect_code 1 "$rc" "check against an unreachable target"
  assert_contains "$out" "cannot read the default branch" "refusal must name the unreadable target"
  pass "fm-target-base.sh: an unreachable target is refused rather than skipped"
}

test_anchor_moves_a_fresh_branch_onto_the_target
test_anchor_refuses_to_discard_branch_work
test_check_passes_a_clean_branch_and_lists_files
test_check_refuses_a_branch_built_on_the_fork
test_check_refuses_a_fork_history_that_swallowed_the_target
test_unreachable_target_is_refused

echo "# all fm-target-base tests passed"
