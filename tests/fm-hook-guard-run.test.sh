#!/usr/bin/env bash
# Behavior tests for the tracked guard-hook launcher: a guard script that is
# missing or cannot be parsed (merge conflict markers) passes through with a
# one-line warning, while a guard that runs and denies still denies.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-hook-guard-run-tests)
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
GUARDS='fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-subagent-pretool-check.sh fm-question-tool-pretool-check.sh fm-turnend-guard.sh'
TRACKED_SETTINGS="$ROOT/.claude/settings.json"

# A worktree whose bin/ holds the real launcher, with stub guard scripts
# standing in for the real guards.
make_worktree() {  # <dir>
  local dir=$1 script
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-hook-guard-run.sh" "$dir/bin/"
  for script in $GUARDS; do
    printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$dir/bin/$script"
    chmod +x "$dir/bin/$script"
  done
}

# Runs the tracked settings command that invokes <script> from <worktree>.
run_tracked() {  # <worktree> <script> [stdin]
  local cmd
  cmd=$(jq -r --arg s "$2" '.hooks[][].hooks[].command | select(contains($s))' "$TRACKED_SETTINGS")
  [ -n "$cmd" ] || fail "no tracked settings command invokes $2"
  printf '%s' "${3-}" | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$1" bash -c "$cmd" > "$OUT" 2> "$ERR"
}

conflicted_guard() {  # <path>
  printf '#!/usr/bin/env bash\n<<<<<<< HEAD\necho ours\n=======\necho theirs\n>>>>>>> origin/main\nexit 2\n' > "$1"
}

test_conflict_markers_pass_through_for_every_tracked_guard() {
  local wt="$TMP_ROOT/conflicted" script rc
  make_worktree "$wt"
  for script in $GUARDS; do
    conflicted_guard "$wt/bin/$script"
    ! bash -n "$wt/bin/$script" 2>/dev/null || fail "fixture for $script must not parse"
    rc=0
    run_tracked "$wt" "$script" '{"tool_name":"Bash"}' || rc=$?
    [ "$rc" -eq 0 ] || fail "$script with conflict markers must pass through, got exit $rc: $(cat "$ERR")"
    [ "$(wc -l < "$ERR" | tr -d ' ')" -eq 1 ] || fail "$script must warn with exactly one stderr line: $(cat "$ERR")"
    assert_contains "$(cat "$ERR")" "$script"
  done
  pass "tracked guards with conflict markers pass through with a one-line warning"
}

test_missing_guard_passes_through() {
  local wt="$TMP_ROOT/missing" rc=0
  make_worktree "$wt"
  rm "$wt/bin/fm-subagent-pretool-check.sh"
  run_tracked "$wt" fm-subagent-pretool-check.sh '{}' || rc=$?
  [ "$rc" -eq 0 ] || fail "missing guard must pass through, got exit $rc"
  assert_contains "$(cat "$ERR")" "missing"
  pass "a missing guard passes through"
}

test_genuine_deny_still_denies() {
  local wt="$TMP_ROOT/deny" rc=0
  make_worktree "$wt"
  printf '#!/usr/bin/env bash\nread -r payload\nprintf "denied:%%s:%%s\\n" "$1" "$payload" >&2\nexit 2\n' \
    > "$wt/bin/fm-subagent-pretool-check.sh"
  run_tracked "$wt" fm-subagent-pretool-check.sh 'PAYLOAD' || rc=$?
  [ "$rc" -eq 2 ] || fail "a parsing guard that denies must exit 2, got $rc"
  assert_contains "$(cat "$ERR")" "denied:--claude:PAYLOAD"
  pass "a guard that runs and denies still denies, with args and stdin intact"
}

test_conflict_markers_pass_through_for_every_tracked_guard
test_missing_guard_passes_through
test_genuine_deny_still_denies
