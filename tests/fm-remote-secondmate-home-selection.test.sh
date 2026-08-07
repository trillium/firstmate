#!/usr/bin/env bash
# tests/fm-remote-secondmate-home-selection.test.sh - regression coverage for
# bin/fm-remote-secondmate-control.sh's handling of an unset FM_HOME.
#
# The command used to resolve its target home with a bare `${FM_HOME:?...}` at
# the top of the file, so an operator running it by hand outside a routed call
# got a shell-internal "line N: FM_HOME: FM_HOME is required" abort instead of
# the command's own diagnostic, and even `--help` could not run.
#
# An unset FM_HOME selects no secondmate at all, so the command now reports that
# and help works without one. The resolution must also stay ahead of
# bin/fm-backend.sh, which defaults FM_HOME to the code root when sourced: an
# unset selection must never silently become "this Firstmate checkout".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-remote-secondmate-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-home-selection)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# --- help runs with no home selected ---------------------------------------

out=$(env -u FM_HOME "$CONTROL" --help 2>"$TMP_ROOT/help.err") && rc=0 || rc=$?
expect_code 2 "$rc" "--help with no FM_HOME"
assert_contains "$out" "fm-remote-secondmate-control.sh state <id>" \
  "--help must print the usage block with no FM_HOME"
assert_contains "$out" "FM_HOME must name the remote secondmate home" \
  "--help must document the FM_HOME requirement"
err=$(cat "$TMP_ROOT/help.err")
assert_not_contains "$err" "FM_HOME is required" \
  "--help must not abort on a bare parameter expansion"
pass "help runs with no secondmate selected"

# --- every verb reports no secondmate instead of aborting -------------------

for verb in "state s1" "route s1" "send s1 hello" "key s1 enter" \
  "capture s1" "observe s1" "sync s1" "update s1" "retire s1" \
  "launch s1 claude - - herdr"; do
  # shellcheck disable=SC2086 # each entry is a deliberate argv split
  err=$(env -u FM_HOME "$CONTROL" $verb 2>&1 >/dev/null) && rc=0 || rc=$?
  expect_code 1 "$rc" "'$verb' with no FM_HOME"
  assert_contains "$err" "error: no secondmate selected" \
    "'$verb' must report that no secondmate is selected"
  assert_not_contains "$err" "FM_HOME is required" \
    "'$verb' must not surface the shell-internal abort"
  assert_not_contains "$err" "not a seeded secondmate home" \
    "'$verb' must not fall back to this Firstmate checkout as the home"
done
pass "every verb reports no secondmate when none is selected"

# An exported-but-empty FM_HOME selects nothing either.
err=$(FM_HOME='' "$CONTROL" state s1 2>&1 >/dev/null) && rc=0 || rc=$?
expect_code 1 "$rc" "empty FM_HOME"
assert_contains "$err" "error: no secondmate selected" \
  "an empty FM_HOME must report that no secondmate is selected"
pass "empty FM_HOME selects no secondmate"

# --- a selected home still resolves normally --------------------------------

HOME_DIR="$TMP_ROOT/remote-home"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state"
: > "$HOME_DIR/AGENTS.md"
printf 's1\n' > "$HOME_DIR/.fm-secondmate-home"

out=$(FM_HOME="$HOME_DIR" "$CONTROL" state s1 2>"$TMP_ROOT/state.err") && rc=0 || rc=$?
expect_code 0 "$rc" "state against a seeded home"
assert_contains "$out" "missing" \
  "state must report the endpoint as missing for a seeded home with no route"
pass "a selected secondmate home still resolves"

err=$(FM_HOME="$HOME_DIR" "$CONTROL" bogus 2>&1 >/dev/null) && rc=0 || rc=$?
expect_code 1 "$rc" "unknown verb with a selected home"
assert_contains "$err" "error: unknown command: bogus" \
  "an unknown verb must still be reported as an unknown command"
pass "unknown verb is still reported once a home is selected"
