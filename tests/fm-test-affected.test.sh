#!/usr/bin/env bash
# Contract tests for bin/fm-test-affected.sh - the static test-impact selector
# that narrows a pull request's CI run to the tests its changed paths could
# affect.
#
# The load-bearing property is asymmetric: over-selection costs minutes,
# under-selection ships a regression. So these tests prove both directions of
# selection, and prove every route back to the complete suite - the non-pull-request
# events, the suite-composition files, shared test infrastructure, and an
# unmapped path - because that fallback is what makes an occasionally wrong
# selector survivable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECTOR="$ROOT/bin/fm-test-affected.sh"
RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$SELECTOR" "bin/fm-test-affected.sh is missing"
[ -x "$SELECTOR" ] || fail "bin/fm-test-affected.sh must be executable"

FULL_SUITE=$("$RUNNER" --list --all | LC_ALL=C sort)
FULL_COUNT=$(printf '%s\n' "$FULL_SUITE" | wc -l | tr -d ' ')
[ "$FULL_COUNT" -gt 1 ] || fail "suite inventory looks empty; the rest of this file cannot mean anything"

# select <args...>: run the selector with a scrubbed event and return its list.
select_paths() {
  env -u GITHUB_EVENT_NAME "$SELECTOR" "$@" 2>/dev/null | LC_ALL=C sort
}

test_non_pull_request_events_run_the_complete_suite() {
  local ev out
  # A change that narrows hard under pull_request must still run everything
  # under every other event, including no event at all.
  out=$(select_paths --event pull_request --path bin/fm-brief.sh)
  [ "$out" != "$FULL_SUITE" ] || fail "fixture path did not narrow, so this test cannot detect a leak"

  for ev in push workflow_dispatch schedule merge_group ''; do
    if [ -n "$ev" ]; then
      out=$(select_paths --event "$ev" --path bin/fm-brief.sh)
    else
      out=$(select_paths --path bin/fm-brief.sh)
    fi
    [ "$out" = "$FULL_SUITE" ] \
      || fail "event '${ev:-none}' must run the complete suite, got $(printf '%s\n' "$out" | wc -l | tr -d ' ') of $FULL_COUNT"
  done

  # The ambient GitHub event is the default when --event is absent, and a push
  # to main is the case the hard safety rule exists for.
  out=$(GITHUB_EVENT_NAME=push "$SELECTOR" --path bin/fm-brief.sh 2>/dev/null | LC_ALL=C sort)
  [ "$out" = "$FULL_SUITE" ] || fail "GITHUB_EVENT_NAME=push must run the complete suite"

  # An explicit --event must beat the ambient one in the unsafe direction too:
  # a pull_request environment cannot be narrowed by claiming a push.
  out=$(GITHUB_EVENT_NAME=pull_request "$SELECTOR" --event push --path bin/fm-brief.sh 2>/dev/null | LC_ALL=C sort)
  [ "$out" = "$FULL_SUITE" ] || fail "--event push must run the complete suite"

  pass "only a pull request narrows; every other event runs the complete suite"
}

test_affected_test_is_selected_and_unaffected_is_not() {
  local out
  # tests/fm-brief.test.sh exercises bin/fm-brief.sh by name; the beads import
  # suite is a separate subsystem that does not.
  out=$(select_paths --event pull_request --path bin/fm-brief.sh)
  [ -n "$out" ] || fail "changing bin/fm-brief.sh selected nothing"
  printf '%s\n' "$out" | grep -Fqx 'tests/fm-brief.test.sh' \
    || fail "changing bin/fm-brief.sh must select tests/fm-brief.test.sh"
  printf '%s\n' "$out" | grep -Fqx 'tests/fm-backlog-import-beads.test.sh' \
    && fail "changing bin/fm-brief.sh must not select the unrelated beads import suite"

  # Every selected path is a real inventory test, and the result is a proper
  # subset: a selector that quietly returns everything would pass the
  # positive assertion above on its own.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$FULL_SUITE" | grep -Fqx "$line" \
      || fail "selected path is not in the suite inventory: $line"
  done <<<"$out"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -lt "$FULL_COUNT" ] \
    || fail "a single script change must be a proper subset of the suite"

  pass "an affected test is selected and an unaffected one is not"
}

test_single_changed_test_selects_only_itself() {
  local out
  out=$(select_paths --event pull_request --path tests/fm-brief.test.sh)
  [ "$out" = "tests/fm-brief.test.sh" ] \
    || fail "a changed test must select exactly itself, got: $out"
  pass "a changed test file selects only itself"
}

test_suite_composition_changes_run_everything() {
  local p out
  # Constraint: anything that owns or gates what the suite is invalidates the
  # selection itself, so it can only fall back to running everything.
  for p in bin/fm-test-run.sh bin/fm-test-affected.sh bin/fm-test-isolation-proof.sh \
           .github/workflows/ci.yml .github/workflows/some-new-workflow.yml; do
    out=$(select_paths --event pull_request --path "$p")
    [ "$out" = "$FULL_SUITE" ] \
      || fail "changing $p must run the complete suite, got $(printf '%s\n' "$out" | wc -l | tr -d ' ') of $FULL_COUNT"
  done
  pass "suite-composition and workflow changes fall back to the complete suite"
}

test_shared_test_infrastructure_runs_everything() {
  local p out
  for p in tests/lib.sh tests/secondmate-helpers.sh tests/cmux-test-safety.sh \
           tests/fixtures/anything/file.txt tests/fm-backend-herdr-eventwait.test.py; do
    out=$(select_paths --event pull_request --path "$p")
    [ "$out" = "$FULL_SUITE" ] \
      || fail "changing $p must run the complete suite, got $(printf '%s\n' "$out" | wc -l | tr -d ' ') of $FULL_COUNT"
  done
  pass "shared test infrastructure falls back to the complete suite"
}

test_one_fallback_path_widens_the_whole_run() {
  local out
  # A narrow change batched with a fallback change must not stay narrow: the
  # fallback is a decision about the run, not about one path.
  out=$(select_paths --event pull_request --path bin/fm-brief.sh --path bin/fm-test-run.sh)
  [ "$out" = "$FULL_SUITE" ] \
    || fail "a fallback path alongside a narrow one must still run the complete suite"
  pass "one fallback path widens the whole run"
}

test_missing_base_ref_runs_everything() {
  local out
  out=$(select_paths --event pull_request --base refs/heads/definitely-not-a-real-ref)
  [ "$out" = "$FULL_SUITE" ] \
    || fail "an unresolvable base ref must run the complete suite"
  pass "an unresolvable base ref falls back to the complete suite"
}

test_paths_from_stdin_and_out_file() {
  local tmp out
  tmp=$(fm_test_tmproot fm-test-affected-io)
  # Blank lines are ignored, so a trailing newline in a generated file is not
  # read as an empty changed path.
  printf 'bin/fm-brief.sh\n\n' >"$tmp/paths"
  "$SELECTOR" --event pull_request --paths-from "$tmp/paths" --out "$tmp/out.txt" 2>/dev/null \
    || fail "--paths-from with --out failed"
  assert_present "$tmp/out.txt" "--out did not write a file"
  assert_grep 'tests/fm-brief.test.sh' "$tmp/out.txt" "--out file must list the affected test"

  out=$(printf 'bin/fm-brief.sh\n' | "$SELECTOR" --event pull_request --paths-from - 2>/dev/null)
  printf '%s\n' "$out" | grep -Fqx 'tests/fm-brief.test.sh' \
    || fail "--paths-from - must read changed paths from stdin"

  # --out writes the file instead of stdout, so a caller cannot accidentally
  # consume a half-written list from the pipe.
  out=$("$SELECTOR" --event pull_request --path bin/fm-brief.sh --out "$tmp/out2.txt" 2>/dev/null)
  [ -z "$out" ] || fail "--out must not also print the list to stdout"

  pass "--paths-from and --out move the list without changing it"
}

test_usage_errors_never_narrow() {
  local code
  set +e
  "$SELECTOR" --event pull_request --bogus-flag >/dev/null 2>&1
  code=$?
  set -e
  expect_code 2 "$code" "an unknown flag must be a usage error"

  set +e
  "$SELECTOR" --event pull_request --paths-from /definitely/not/here.txt >/dev/null 2>&1
  code=$?
  set -e
  expect_code 2 "$code" "a missing --paths-from file must be a usage error"
  pass "a usage error refuses instead of returning a narrowed list"
}

# --- end-to-end over a real git repository ----------------------------------
#
# The rules above are exercised through explicit paths so they stay readable.
# This fixture proves the rest: that the selector derives the changed set from
# a git range at all, and that the transitive reverse source-chain closure
# selects a test naming only the consumer of a changed library.
#
# The inert-path and unmapped-path rules can ONLY be proven here. Selection is
# a fixed-string scan of the test corpus, so naming a path in a test file
# against the real repo makes that test reference it, and the case under test
# stops being the case that runs. A repo whose whole corpus is written here has
# no such coupling.
build_fixture_repo() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/tests" "$dir/docs"
  printf 'a license\n' >"$dir/LICENSE"
  printf '# notes\n' >"$dir/docs/notes.md"
  cp "$ROOT/bin/fm-test-affected.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-test-run.sh" "$dir/bin/"

  printf '#!/usr/bin/env bash\necho deep\n' >"$dir/bin/fm-deep-lib.sh"
  printf '#!/usr/bin/env bash\n. "$(dirname "$0")/fm-deep-lib.sh"\necho mid\n' \
    >"$dir/bin/fm-mid-lib.sh"
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/fm-mid-lib.sh"\necho top\n' \
    >"$dir/bin/fm-top.sh"
  printf '#!/usr/bin/env bash\necho other\n' >"$dir/bin/fm-other.sh"
  chmod +x "$dir"/bin/*.sh

  # The top test names only fm-top.sh: reaching it from a change to
  # fm-deep-lib.sh requires walking two source edges.
  printf '#!/usr/bin/env bash\n# exercises bin/fm-top.sh\necho "ok - top"\n' \
    >"$dir/tests/fm-top.test.sh"
  printf '#!/usr/bin/env bash\n# exercises bin/fm-other.sh\necho "ok - other"\n' \
    >"$dir/tests/fm-other.test.sh"
  chmod +x "$dir"/tests/*.test.sh

  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm base
}

test_git_range_derivation_and_indirect_source_chain() {
  local tmp repo base out
  tmp=$(fm_test_tmproot fm-test-affected-git)
  repo="$tmp/repo"
  build_fixture_repo "$repo"
  base=$(git -C "$repo" rev-parse HEAD)

  # A change two source-hops below the only script the test names.
  printf '#!/usr/bin/env bash\necho deeper\n' >"$repo/bin/fm-deep-lib.sh"
  git -C "$repo" add -A
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm change

  out=$(env -u GITHUB_EVENT_NAME "$repo/bin/fm-test-affected.sh" \
    --event pull_request --base "$base" 2>/dev/null | LC_ALL=C sort)
  [ "$out" = "tests/fm-top.test.sh" ] \
    || fail "a git-range change to a two-hop-deep library must select only the consumer's test, got: $out"

  # Uncommitted and untracked work is part of the changed set too, so a local
  # run answers for the tree as it actually stands.
  printf '#!/usr/bin/env bash\necho other2\n' >"$repo/bin/fm-other.sh"
  out=$(env -u GITHUB_EVENT_NAME "$repo/bin/fm-test-affected.sh" \
    --event pull_request --base "$base" 2>/dev/null | LC_ALL=C sort)
  [ "$out" = "$(printf 'tests/fm-other.test.sh\ntests/fm-top.test.sh')" ] \
    || fail "an uncommitted change must join the changed set, got: $out"

  pass "the changed set comes from the git range and the source chain is transitive"
}

test_inert_and_unmapped_paths_in_a_controlled_corpus() {
  local tmp repo sel fixture_all out p
  tmp=$(fm_test_tmproot fm-test-affected-corpus)
  repo="$tmp/repo"
  build_fixture_repo "$repo"
  sel="$repo/bin/fm-test-affected.sh"
  fixture_all=$(printf 'tests/fm-other.test.sh\ntests/fm-top.test.sh')

  # Declared inert: nothing in the corpus can depend on them, so they select
  # nothing rather than widening the run.
  for p in LICENSE docs/notes.md; do
    out=$(env -u GITHUB_EVENT_NAME "$sel" --event pull_request --path "$p" 2>/dev/null)
    [ -z "$out" ] || fail "inert path $p must select nothing, got: $out"
  done

  # Not inert and not mapped to any test: the only safe answer is everything.
  out=$(env -u GITHUB_EVENT_NAME "$sel" --event pull_request \
    --path config/unmapped.conf 2>/dev/null | LC_ALL=C sort)
  [ "$out" = "$fixture_all" ] \
    || fail "an unmapped path must run the complete suite, got: $out"

  # And that stays true under a push, where nothing narrows at all.
  out=$(env -u GITHUB_EVENT_NAME "$sel" --event push --path LICENSE 2>/dev/null | LC_ALL=C sort)
  [ "$out" = "$fixture_all" ] \
    || fail "a push must run the complete suite even for an inert path, got: $out"

  pass "inert paths select nothing and unmapped paths run everything"
}

test_non_pull_request_events_run_the_complete_suite
test_affected_test_is_selected_and_unaffected_is_not
test_single_changed_test_selects_only_itself
test_suite_composition_changes_run_everything
test_shared_test_infrastructure_runs_everything
test_one_fallback_path_widens_the_whole_run
test_missing_base_ref_runs_everything
test_paths_from_stdin_and_out_file
test_usage_errors_never_narrow
test_git_range_derivation_and_indirect_source_chain
test_inert_and_unmapped_paths_in_a_controlled_corpus
