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
#
# Also covers the second half of the same defect: an unknown --flag was consumed
# as a positional, so `fm-brief.sh <id> --project herdr-web --mode direct-PR`
# scaffolded a brief for a project literally named "--project".
#
# Also covers flag-arm reachability: a union-merge that keeps both sides of a
# case statement reorders arms and lifts the --*) catch-all above named ones,
# silently turning every named flag into "unknown option: --flag" at dispatch.
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
  # No brief exists for this id, and fm-spawn checks the brief immediately after
  # resolving the project, so reaching the brief error proves the bare name
  # resolved - without launching anything.
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-spawn.sh" bare-name-task herdr-web "sh -c true" --mode no-mistakes --yolo off --backend tmux 2>&1); rc=$?
  expect_code 1 "$rc" "fm-spawn.sh did not stop at the missing brief"
  assert_contains "$out" "no brief at" \
    "fm-spawn.sh did not get past project resolution for a bare project name"
  assert_not_contains "$out" "No such file or directory" \
    "fm-spawn.sh still handed a bare project name to cd"
  pass "fm-spawn.sh: a bare project name resolves under projects/ (matches fm-brief.sh)"
}

test_spawn_names_an_unresolvable_project() {
  local out rc
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-spawn.sh" missing-proj-task herdrweb "sh -c true" --mode no-mistakes --yolo off --backend tmux 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn.sh accepted a project that resolves nowhere"
  assert_contains "$out" "project not found: herdrweb" \
    "fm-spawn.sh did not report an unresolvable project by name"
  assert_contains "$out" "did you mean projects/herdr-web" \
    "fm-spawn.sh did not suggest the clone the caller meant"
  pass "fm-spawn.sh: an unresolvable project fails with a named error, not a raw cd failure"
}

test_spawn_rejects_an_unknown_flag() {
  local out rc
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-spawn.sh" flag-task --project herdr-web 2>&1); rc=$?
  expect_code 2 "$rc" "fm-spawn.sh did not reject an unknown option"
  assert_contains "$out" "unknown option: --project" \
    "fm-spawn.sh did not name the unknown option"
  pass "fm-spawn.sh: an unknown --flag is rejected, never consumed as a positional"
}

test_brief_rejects_an_unknown_flag() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-brief.sh" flag-brief --project herdr-web --mode direct-PR 2>&1); rc=$?
  expect_code 2 "$rc" "fm-brief.sh did not reject an unknown option"
  assert_contains "$out" "unknown option: --project" \
    "fm-brief.sh did not name the unknown option"
  assert_absent "$HOME_DIR/data/flag-brief/brief.md" \
    "fm-brief.sh scaffolded a brief from an unknown option"
  pass "fm-brief.sh: an unknown --flag is rejected instead of being taken as the repo name"
}

test_brief_names_a_missing_repo_argument() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" lonely-id 2>&1); rc=$?
  expect_code 2 "$rc" "fm-brief.sh did not reject a missing repo name"
  assert_contains "$out" "missing <repo-name>" \
    "fm-brief.sh did not name the missing positional"
  assert_not_contains "$out" "unbound variable" \
    "fm-brief.sh died on an unbound array element instead of a named error"
  pass "fm-brief.sh: a missing repo name is a named usage error"
}

test_brief_still_scaffolds_with_known_flags() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-brief.sh" known-flag-brief herdr-web --scout --beads bead-1 2>&1); rc=$?
  expect_code 0 "$rc" "fm-brief.sh rejected its own documented flags (got: $out)"
  assert_present "$HOME_DIR/data/known-flag-brief/brief.md" \
    "fm-brief.sh did not scaffold a brief when given known flags"
  pass "fm-brief.sh: documented flags still parse after unknown-flag rejection"
}

# Guard for the recurring take-both conflict resolution that has now hit these
# parsers four times (fm-spawn.sh, then fm-brief.sh at c1154f5c, then BOTH
# again at d8313f1e / robots-l0ev / robots-sg76). Resolving a merge conflict in
# the flag case by keeping both sides reorders the arms and lifts the --*)
# unknown-option catch-all above the named ones. bash matches case arms top-down,
# so every named flag below the catch-all silently becomes unreachable and dies as
# "unknown option: --flag" at dispatch time. No .gitattributes file exists in any
# ref of this repo and no merge.* driver is configured, so CI is the whole defense
# against this shape of conflict resolution.
#
# The tests below exercise each script's flag contract directly against its
# executable interface, deriving the expected flag set from --help output (never
# from source text). A behavioral invocation fails the moment the script emits
# "unknown option: --flag" for a flag its --help documents; a source-text grep
# cannot fail against dead or commented-out code.

# flag_list_from_help <script-path>: emit one flag name per line extracted from
# the script's --help output. Reads Usage synopsis lines (Usage: and 7-space
# continuation) plus 2-space-indented option description lines; never reads
# source code.
flag_list_from_help() {
  "$1" --help 2>&1 \
    | grep -E '^(Usage:|       |  --[a-zA-Z])' \
    | grep -oE '\-\-[a-zA-Z][a-zA-Z0-9-]+' \
    | sort -u
}

test_flag_reachability_sweep_brief() {
  local flags flag flag_name out
  flags=$(FM_HOME="$HOME_DIR" flag_list_from_help "$ROOT/bin/fm-brief.sh")
  [ -n "$flags" ] \
    || fail "fm-brief.sh --help produced no flags in its synopsis; the sweep would pass vacuously"
  case "$flags" in *"--mode"*) ;; *)
    fail "fm-brief.sh --help synopsis does not contain --mode; reachability of the most-often-buried flag cannot be confirmed" ;;
  esac
  # For each documented flag, invoke the script with that flag and verify the arm
  # is reachable. Any outcome is acceptable — a usage error, a missing-value error,
  # exit 2 — except "unknown option: --<flag>", which proves the arm sat below the
  # --*) catch-all. One positional (task-id) gets the script past the task-id check;
  # the script then fails at the next validation before any brief is scaffolded.
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    flag_name=${flag#--}
    out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "sweep-$flag_name" "$flag" 2>&1) || true
    case "$out" in
      *"unknown option: $flag"*)
        fail "fm-brief.sh: $flag arm is unreachable; the --*) catch-all sits above it (dispatch produced: $out)" ;;
    esac
  done <<EOF
$flags
EOF
  pass "fm-brief.sh: every flag in the --help synopsis is reachable — catch-all is not above any named arm"
}

test_flag_reachability_sweep_spawn() {
  local flags flag flag_name out
  flags=$(FM_HOME="$HOME_DIR" flag_list_from_help "$ROOT/bin/fm-spawn.sh")
  [ -n "$flags" ] \
    || fail "fm-spawn.sh --help produced no flags in its synopsis; the sweep would pass vacuously"
  case "$flags" in *"--mode"*) ;; *)
    fail "fm-spawn.sh --help synopsis does not contain --mode; reachability of the most-often-buried flag cannot be confirmed" ;;
  esac
  # FM_SPAWN_NO_GUARD=1 bypasses only the watcher guard, not spawning itself.
  # Without required positionals or --mode/--yolo, the script exits before any
  # spawn endpoint is created:
  #   valued flags:    "requires a value" at end-of-args check
  #   --scout:         "missing <project-dir>"
  #   --secondmate:    "no firstmate home registered" from registry lookup
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    flag_name=${flag#--}
    out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" \
      "$ROOT/bin/fm-spawn.sh" "sweep-$flag_name" "$flag" 2>&1) || true
    case "$out" in
      *"unknown option: $flag"*)
        fail "fm-spawn.sh: $flag arm is unreachable; the --*) catch-all sits above it (dispatch produced: $out)" ;;
    esac
  done <<EOF
$flags
EOF
  pass "fm-spawn.sh: every flag in the --help synopsis is reachable — catch-all is not above any named arm"
}

# Behavioral coverage for the want_value dispatch block: the take-both conflict
# resolution has also duplicated that block, stranding one flag's value handler
# in a dead copy (the first block's continue always skips it). A duplicated block
# causes the trapped flag's space-separated value to be silently dropped or to
# trigger an "internal parser state" error. Test both '--flag value' and
# '--flag=value' forms for every valued flag in fm-brief.sh and confirm each
# scaffolds a brief successfully. --mode is covered by test_brief_mode_flag_is_reachable.
test_beads_flag_value_dispatch_brief() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-brief.sh" beads-val-b1 herdr-web --beads test-bead-b1 --mode direct-PR 2>&1); rc=$?
  expect_code 0 "$rc" "fm-brief.sh rejected --beads with a space-separated value (got: $out)"
  assert_present "$HOME_DIR/data/beads-val-b1/brief.md" \
    "fm-brief.sh --beads value did not scaffold a brief"
  out=$(FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-brief.sh" beads-val-b2 herdr-web --beads=test-bead-b2 --mode direct-PR 2>&1); rc=$?
  expect_code 0 "$rc" "fm-brief.sh rejected --beads=<value> (got: $out)"
  assert_present "$HOME_DIR/data/beads-val-b2/brief.md" \
    "fm-brief.sh --beads=<value> did not scaffold a brief"
  pass "fm-brief.sh: --beads and --beads=<value> both dispatch the value without silent drop"
}

# Behavioral companion to the structural guards: --mode is the flag the reorder
# has buried every time, in both its space and its "=" form.
test_brief_mode_flag_is_reachable() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-brief.sh" mode-reachable-a1 herdr-web --mode no-mistakes 2>&1); rc=$?
  expect_code 0 "$rc" "fm-brief.sh rejected --mode (got: $out)"
  assert_grep "Delivery contract: mode=no-mistakes" "$HOME_DIR/data/mode-reachable-a1/brief.md" \
    "fm-brief.sh --mode did not reach the brief"
  out=$(FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-brief.sh" mode-reachable-a2 herdr-web --mode=direct-PR 2>&1); rc=$?
  expect_code 0 "$rc" "fm-brief.sh rejected --mode=<value> (got: $out)"
  assert_grep "Delivery contract: mode=direct-PR" "$HOME_DIR/data/mode-reachable-a2/brief.md" \
    "fm-brief.sh --mode=<value> did not reach the brief"
  pass "fm-brief.sh: --mode and --mode=<value> both scaffold, never 'unknown option: --mode'"
}

test_end_of_flags_separator() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" -- --weird-repo-name 2>&1); rc=$?
  expect_code 2 "$rc" "fm-brief.sh did not treat post-'--' arguments as positionals"
  assert_contains "$out" "missing <repo-name> for --weird-repo-name" \
    "'--' did not end flag parsing (got: $out)"
  pass "fm-brief.sh: '--' ends flag parsing for a positional that must start with --"
}

test_help_is_accepted_after_a_positional() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" some-id --help 2>&1); rc=$?
  expect_code 0 "$rc" "fm-brief.sh rejected --help after a positional"
  assert_contains "$out" "Usage: fm-brief.sh" "fm-brief.sh --help did not print its usage"
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-spawn.sh" some-id --help 2>&1); rc=$?
  expect_code 0 "$rc" "fm-spawn.sh rejected --help after a positional"
  assert_contains "$out" "Usage: fm-spawn.sh" "fm-spawn.sh --help did not print its usage"
  pass "fm-brief.sh/fm-spawn.sh: --help is answered wherever it appears, not rejected as unknown"
}

test_candidate_mapping
test_resolve_accepts_the_forms_fm_brief_accepts
test_explicit_relative_path_wins_over_a_same_named_project
test_bare_name_falls_back_to_a_cwd_relative_directory
test_unresolvable_name_fails_with_a_named_error_and_suggestion
test_spawn_accepts_a_bare_project_name
test_spawn_names_an_unresolvable_project
test_spawn_rejects_an_unknown_flag
test_brief_rejects_an_unknown_flag
test_brief_names_a_missing_repo_argument
test_brief_still_scaffolds_with_known_flags
test_flag_reachability_sweep_brief
test_flag_reachability_sweep_spawn
test_beads_flag_value_dispatch_brief
test_brief_mode_flag_is_reachable
test_end_of_flags_separator
test_help_is_accepted_after_a_positional
