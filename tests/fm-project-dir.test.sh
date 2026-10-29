#!/usr/bin/env bash
# Behavior tests for the project-argument contract shared by bin/fm-brief.sh and
# bin/fm-spawn.sh (bin/fm-project-dir-lib.sh owns the mapping).
#
# Regression coverage for the silent half-a-dispatch mismatch: fm-brief.sh
# accepted a bare project name while fm-spawn.sh only rewrote an argument that
# already began with "projects/", so the bare name reached `cd` and died with a
# raw "cd: <name>: No such file or directory" from an internal line number.
# Both halves now resolve a bare name under $PROJECTS, and an unresolvable name
# fails with a named error instead of a shell diagnostic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-project-dir-lib.sh
. "$ROOT/bin/fm-project-dir-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-dir)
HOME_DIR="$TMP_ROOT/home"
PROJECTS="$HOME_DIR/projects"
mkdir -p "$PROJECTS/herdr-web" "$HOME_DIR/data" "$HOME_DIR/state"

test_candidate_mapping() {
  local got
  got=$(fm_project_dir_candidate herdr-web "$PROJECTS")
  [ "$got" = "$PROJECTS/herdr-web" ] || fail "a bare name did not map under projects/ (got: $got)"
  got=$(fm_project_dir_candidate projects/herdr-web "$PROJECTS")
  [ "$got" = "$PROJECTS/herdr-web" ] || fail "a projects/<name> argument did not map under projects/ (got: $got)"
  got=$(fm_project_dir_candidate /somewhere/else "$PROJECTS")
  [ "$got" = /somewhere/else ] || fail "an absolute path was rewritten (got: $got)"
  got=$(fm_project_dir_candidate ./local-clone "$PROJECTS")
  [ "$got" = ./local-clone ] || fail "an explicit relative path was rewritten (got: $got)"
  got=$(fm_project_dir_candidate nested/clone "$PROJECTS")
  [ "$got" = nested/clone ] || fail "a multi-segment relative path was rewritten (got: $got)"
  pass "fm-project-dir-lib: bare names map under projects/ while explicit paths pass through"
}

test_resolve_accepts_the_forms_fm_brief_accepts() {
  local got
  got=$(fm_resolve_project_dir herdr-web "$PROJECTS") \
    || fail "a bare project name that exists under projects/ was refused"
  [ "$got" = "$PROJECTS/herdr-web" ] || fail "a bare project name resolved to $got"
  got=$(fm_resolve_project_dir projects/herdr-web "$PROJECTS") \
    || fail "a projects/<name> argument that exists was refused"
  [ "$got" = "$PROJECTS/herdr-web" ] || fail "projects/<name> resolved to $got"
  got=$(fm_resolve_project_dir "$PROJECTS/herdr-web" "$PROJECTS") \
    || fail "an absolute clone path was refused"
  [ "$got" = "$PROJECTS/herdr-web" ] || fail "an absolute clone path resolved to $got"
  pass "fm-project-dir-lib: bare, projects/<name>, and absolute forms all resolve to the same clone"
}

test_explicit_relative_path_wins_over_a_same_named_project() {
  local elsewhere got
  elsewhere="$TMP_ROOT/elsewhere"
  mkdir -p "$elsewhere/herdr-web"
  got=$(cd "$elsewhere" && fm_resolve_project_dir ./herdr-web "$PROJECTS") \
    || fail "an explicit relative path to an existing directory was refused"
  [ "$got" = ./herdr-web ] || fail "an explicit relative path was redirected under projects/ (got: $got)"
  pass "fm-project-dir-lib: an explicit relative path is never redirected under projects/"
}

test_bare_name_falls_back_to_a_cwd_relative_directory() {
  local elsewhere got
  elsewhere="$TMP_ROOT/cwd-fallback"
  mkdir -p "$elsewhere/not-a-registered-project"
  got=$(cd "$elsewhere" && fm_resolve_project_dir not-a-registered-project "$PROJECTS") \
    || fail "a bare name matching a cwd-relative directory was refused"
  [ "$got" = not-a-registered-project ] \
    || fail "the pre-existing cwd-relative behavior was lost (got: $got)"
  pass "fm-project-dir-lib: a bare name still falls back to a cwd-relative directory"
}

test_unresolvable_name_fails_with_a_named_error_and_suggestion() {
  local err rc
  err=$(fm_resolve_project_dir herdrweb "$PROJECTS" 2>&1); rc=$?
  expect_code 1 "$rc" "an unresolvable project name did not fail"
  assert_contains "$err" "project not found: herdrweb" \
    "the failure did not name the project argument"
  assert_contains "$err" "$PROJECTS/herdrweb" \
    "the failure did not report the projects/ path it tried"
  assert_contains "$err" "did you mean projects/herdr-web" \
    "the failure did not suggest the clone the caller meant"
  pass "fm-project-dir-lib: an unresolvable name fails with a named error and a clone suggestion"
}

test_spawn_accepts_a_bare_project_name() {
  local out rc
  # The fixture clone is not a git repository, so fm-spawn stops at its project
  # lock gate for the resolved clone. Naming the resolved path there proves the
  # bare name resolved under projects/ - without launching anything.
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-spawn.sh" bare-name-task herdr-web "sh -c true" --backend tmux --mode local-only --yolo off 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn.sh launched against a fixture that is not a git repository"
  assert_contains "$out" "project lock for $PROJECTS/herdr-web" \
    "fm-spawn.sh did not get past project resolution for a bare project name (got: $out)"
  assert_not_contains "$out" "project not found" \
    "fm-spawn.sh refused a bare project name that exists under projects/"
  assert_not_contains "$out" "No such file or directory" \
    "fm-spawn.sh still handed a bare project name to cd"
  pass "fm-spawn.sh: a bare project name resolves under projects/ (matches fm-brief.sh)"
}

test_spawn_names_an_unresolvable_project() {
  local out rc
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-spawn.sh" missing-proj-task herdrweb "sh -c true" --backend tmux --mode local-only --yolo off 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn.sh accepted a project that resolves nowhere"
  assert_contains "$out" "project not found: herdrweb" \
    "fm-spawn.sh did not report an unresolvable project by name"
  assert_contains "$out" "did you mean projects/herdr-web" \
    "fm-spawn.sh did not suggest the clone the caller meant"
  pass "fm-spawn.sh: an unresolvable project fails with a named error, not a raw cd failure"
}

test_candidate_mapping
test_resolve_accepts_the_forms_fm_brief_accepts
test_explicit_relative_path_wins_over_a_same_named_project
test_bare_name_falls_back_to_a_cwd_relative_directory
test_unresolvable_name_fails_with_a_named_error_and_suggestion
test_spawn_accepts_a_bare_project_name
test_spawn_names_an_unresolvable_project
