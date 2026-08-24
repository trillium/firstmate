#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) a merge poll that cannot be armed still merges and reports separately
#   (j) a check that fails before recording pr= refuses and says no merge ran
#   (k) a rate-limited CodeRabbit (green check, zero reviews) refuses the merge
#   (l) a real CodeRabbit review lets the merge through
#   (m) an unreadable CodeRabbit review state refuses rather than merging
#   (n) FM_CODERABBIT_GATE=skip waives the gate deliberately
#   (o) the CodeRabbit verdict script classifies reviewed/rate-limited/pending
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock whose `api` subcommand answers the three CodeRabbit sub-resources from
# fixture files in the case dir, and applies the caller's --jq filter with real
# jq so the verdict script's own filter is exercised rather than stubbed out.
# A missing fixture answers an empty JSON array; a fixture named `fail` makes
# that call exit non-zero, which is how the unreadable-state case is built.
# Args: case_dir head_sha
add_gh_coderabbit_mock() {
  local case_dir=$1 head=$2
  mkdir -p "$case_dir/fakebin" "$case_dir/ghfixtures"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
FIX='$case_dir/ghfixtures'
HEAD='$head'
SH
  cat >> "$case_dir/fakebin/gh" <<'SH'
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  case " $* " in *headRefOid*) printf '%s\n' "$HEAD"; exit 0 ;; esac
  exit 0
fi
if [ "${1:-}" = api ]; then
  path= filter=
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --jq) filter=$2; shift 2 ;;
      --paginate) shift ;;
      *) path=$1; shift ;;
    esac
  done
  case "$path" in
    */reviews) name=reviews ;;
    */pulls/*/comments) name=review-comments ;;
    */issues/*/comments) name=issue-comments ;;
    *) name=unknown ;;
  esac
  [ ! -e "$FIX/$name.fail" ] || exit 1
  [ -f "$FIX/$name.json" ] || { printf '[]' > "$FIX/$name.json"; }
  jq -r "$filter" < "$FIX/$name.json"
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# Arming the watcher's merge poll is supervision convenience; the merge is the
# operation. bin/fm-pr-check.sh reports status 3 when it recorded pr= but could
# not arm the poll, and that must never cancel the merge silently.
test_unarmable_poll_still_merges_and_reports() {
  local case_dir rc warnings
  case_dir=$(make_case arming-blocked)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"
  # A private quarantine that is not a directory blocks the non-executing PR
  # check migration even in the --checks-safe mode fm-pr-check.sh uses, so the
  # poll cannot be armed while recording stays possible.
  printf 'not a quarantine directory\n' > "$case_dir/state/.pr-check-quarantine"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "arming-blocked: fm-pr-merge should merge when only arming failed"
  grep -qxF 'pr merge 31 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "arming-blocked: gh-axi pr merge was not invoked"
  assert_grep 'pr=https://github.com/example/repo/pull/31' "$case_dir/state/task-x1.meta" \
    "arming-blocked: pr= was not recorded before the merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "arming-blocked: a merge poll was armed despite the blocked migration"
  assert_grep 'merge poll NOT armed for task-x1' "$case_dir/stderr" \
    "arming-blocked: the arming failure was not reported"
  assert_grep 'bin/fm-watch-arm.sh' "$case_dir/stderr" \
    "arming-blocked: the arming failure did not name the re-arm path"
  warnings=$(grep -c 'merging anyway' "$case_dir/stderr" || true)
  [ "$warnings" -eq 2 ] \
    || fail "arming-blocked: arming failure should be reported before and after the merge, saw $warnings"
  pass "fm-pr-merge merges and reports separately when the merge poll cannot be armed"
}

test_check_failure_before_recording_refuses_merge() {
  local case_dir rc
  case_dir=$(make_case check-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"
  # A pending retirement receipt that cannot be validated or discarded fails
  # fm-pr-check.sh before it records pr=, the hard merge prerequisite.
  mkdir "$case_dir/state/task-x1.pr-poll-retirement"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "check-fails: fm-pr-merge should refuse when recording failed"
  assert_grep 'no merge was performed' "$case_dir/stderr" \
    "check-fails: refusal did not say that no merge was performed"
  assert_no_grep 'pr=https://github.com/example/repo/pull/33' "$case_dir/state/task-x1.meta" \
    "check-fails: pr= was recorded by a failed check"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "check-fails: gh-axi pr merge was invoked without a recorded pr="
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "check-fails: a merge poll was armed by a failed check"
  pass "fm-pr-merge refuses and reports that no merge was performed when recording fails"
}

# --- CodeRabbit review gate (robots-6bsj) -----------------------------------
#
# The defect these cover: a rate-limited CodeRabbit reports its status check as
# SUCCESS ("Review rate limited") while submitting no review at all, so a merge
# policy reading "all checks green" merges unreviewed code on a public repo. The
# gate must read the reviews API, not the check, and must refuse rather than
# assume a review happened - including when the API cannot be read at all.

CR_STATE="$ROOT/bin/fm-coderabbit-review-state.sh"

# Build a case whose gh mock reports CodeRabbit as rate limited: zero reviews,
# zero review comments, and the review-limit issue comment observed on
# trillium/firstmate#67.
make_rate_limited_case() {
  local name=$1 case_dir
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_coderabbit_mock "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  cat > "$case_dir/ghfixtures/issue-comments.json" <<'JSON'
[{"user":{"login":"coderabbitai[bot]"},
  "body":"> [!WARNING]\n> ## Review limit reached\n> @trillium, you've reached your PR review limit."}]
JSON
  : > "$case_dir/gh-axi.log"
  printf '%s\n' "$case_dir"
}

test_rate_limited_coderabbit_refuses_merge() {
  local case_dir rc
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (CodeRabbit gate)"; return 0; }
  case_dir=$(make_rate_limited_case coderabbit-rate-limited)

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "coderabbit-rate-limited: fm-pr-merge should refuse an unreviewed PR"
  assert_grep 'CodeRabbit is rate limited' "$case_dir/stderr" \
    "coderabbit-rate-limited: refusal did not name the rate limit"
  assert_grep 'FM_CODERABBIT_GATE=skip' "$case_dir/stderr" \
    "coderabbit-rate-limited: refusal did not name the deliberate waiver"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "coderabbit-rate-limited: gh-axi pr merge was invoked on an unreviewed PR"
  assert_no_grep 'pr=https://github.com/example/repo/pull/67' "$case_dir/state/task-x1.meta" \
    "coderabbit-rate-limited: PR was recorded before the gate refused"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "coderabbit-rate-limited: a refused merge armed a poll"
  pass "fm-pr-merge refuses to merge when CodeRabbit is rate limited and reviewed nothing"
}

test_real_coderabbit_review_allows_merge() {
  local case_dir
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (CodeRabbit gate)"; return 0; }
  case_dir=$(make_case coderabbit-reviewed)
  mkdir -p "$case_dir/wt"
  add_gh_coderabbit_mock "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  cat > "$case_dir/ghfixtures/reviews.json" <<'JSON'
[{"id":4711,"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED"}]
JSON
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/68 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "coderabbit-reviewed: fm-pr-merge should merge a genuinely reviewed PR"

  grep -qxF 'pr merge 68 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "coderabbit-reviewed: a reviewed PR was not merged"
  pass "fm-pr-merge merges normally once CodeRabbit has actually submitted a review"
}

test_unreadable_review_state_refuses_merge() {
  local case_dir rc
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (CodeRabbit gate)"; return 0; }
  case_dir=$(make_case coderabbit-unreadable)
  mkdir -p "$case_dir/wt"
  add_gh_coderabbit_mock "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/ghfixtures/reviews.fail"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/69 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "coderabbit-unreadable: an unreadable review state must not merge"
  assert_grep 'could not be determined' "$case_dir/stderr" \
    "coderabbit-unreadable: refusal did not report the unknown state"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "coderabbit-unreadable: gh-axi pr merge was invoked on an unknown review state"
  pass "fm-pr-merge refuses when CodeRabbit review state cannot be read, instead of assuming a review"
}

test_gate_skip_waives_deliberately() {
  local case_dir
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (CodeRabbit gate)"; return 0; }
  case_dir=$(make_rate_limited_case coderabbit-waived)

  FM_CODERABBIT_GATE=skip run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "coderabbit-waived: an explicit waiver should let the merge through"

  grep -qxF 'pr merge 70 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "coderabbit-waived: FM_CODERABBIT_GATE=skip did not waive the gate"
  pass "FM_CODERABBIT_GATE=skip waives the CodeRabbit gate deliberately rather than silently"
}

# Run the verdict script directly against one fixture set. Args: case_dir
run_cr_state() {
  local case_dir=$1
  PATH="$case_dir/fakebin:$PATH" "$CR_STATE" example repo 67
}

test_review_state_verdicts() {
  local case_dir rc out
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (CodeRabbit gate)"; return 0; }

  # rate-limited: the exact shape observed on trillium/firstmate#67
  case_dir=$(make_rate_limited_case cr-state-rate-limited)
  out=$(run_cr_state "$case_dir")
  [ "$out" = rate-limited ] || fail "cr-state: rate-limited PR reported '$out'"

  # absent: no CodeRabbit artifact anywhere, so the bot is simply not on the repo
  case_dir=$(make_case cr-state-absent)
  add_gh_coderabbit_mock "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  out=$(run_cr_state "$case_dir")
  [ "$out" = absent ] || fail "cr-state: repo without CodeRabbit reported '$out'"

  # pending: CodeRabbit has spoken but has not reviewed
  case_dir=$(make_case cr-state-pending)
  add_gh_coderabbit_mock "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  printf '%s\n' '[{"user":{"login":"coderabbitai[bot]"},"body":"Currently reviewing this pull request."}]' \
    > "$case_dir/ghfixtures/issue-comments.json"
  out=$(run_cr_state "$case_dir")
  [ "$out" = pending ] || fail "cr-state: unreviewed-but-present CodeRabbit reported '$out'"

  # a non-CodeRabbit review is not a CodeRabbit review
  case_dir=$(make_case cr-state-other-reviewer)
  add_gh_coderabbit_mock "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  printf '%s\n' '[{"id":9,"user":{"login":"some-human"},"state":"APPROVED"}]' \
    > "$case_dir/ghfixtures/reviews.json"
  out=$(run_cr_state "$case_dir")
  [ "$out" = absent ] || fail "cr-state: a human review was counted as CodeRabbit's ('$out')"

  # inline review comments count as a review
  case_dir=$(make_case cr-state-inline)
  add_gh_coderabbit_mock "$case_dir" 1010101010101010101010101010101010101010
  printf '%s\n' '[{"id":31,"user":{"login":"coderabbitai[bot]"},"body":"nit"}]' \
    > "$case_dir/ghfixtures/review-comments.json"
  out=$(run_cr_state "$case_dir")
  [ "$out" = reviewed ] || fail "cr-state: inline CodeRabbit comments reported '$out'"

  # an unreadable forge is exit 3, never a verdict
  case_dir=$(make_case cr-state-unreadable)
  add_gh_coderabbit_mock "$case_dir" 2020202020202020202020202020202020202020
  : > "$case_dir/ghfixtures/reviews.fail"
  set +e
  out=$(run_cr_state "$case_dir" 2>/dev/null)
  rc=$?
  set -e
  expect_code 3 "$rc" "cr-state: an unreadable forge must exit 3"
  [ -z "$out" ] || fail "cr-state: an unreadable forge printed the verdict '$out'"

  pass "fm-coderabbit-review-state classifies reviewed, rate-limited, pending, absent, and unknown"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_unarmable_poll_still_merges_and_reports
test_check_failure_before_recording_refuses_merge
test_rate_limited_coderabbit_refuses_merge
test_real_coderabbit_review_allows_merge
test_unreadable_review_state_refuses_merge
test_gate_skip_waives_deliberately
test_review_state_verdicts
