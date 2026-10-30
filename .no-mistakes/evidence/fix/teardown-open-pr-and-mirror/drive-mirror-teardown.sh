#!/usr/bin/env bash
# Drives the real bin/fm-teardown.sh against disposable git fixtures (bare origin,
# project clone, task worktree, bare no-mistakes mirror) to show how work that
# only reached the local no-mistakes mirror is judged.
# Usage: drive-mirror-teardown.sh <repo-root-under-test> <label>
set -u
SRC_ROOT=$1; LABEL=$2
WT_ROOT=/Users/mini0/.no-mistakes/worktrees/1467055f0b60/01M65KHRK7HT918W8V5E2RJM5W
. "$WT_ROOT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
# Reuse the suite's own fixture builders verbatim.
for fn in make_case write_meta wt_commit_file run_teardown; do
  eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$WT_ROOT/tests/fm-teardown.test.sh")"
done
ROOT=$SRC_ROOT
TEARDOWN="$SRC_ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-mirror-drive.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

setup() {  # <name> -> case dir with commit pushed ONLY to the no-mistakes mirror
  local c; c=$(make_case "$1")
  write_meta "$c" no-mistakes ship
  wt_commit_file "$c" feature.txt hello "mirror-only work" >/dev/null
  git init -q --bare "$c/mirror.git"
  git -C "$c/project" remote add no-mistakes "$c/mirror.git"
  git -C "$c/wt" push -q no-mistakes fm/task-x1 2>/dev/null
  git -C "$c/project" fetch -q no-mistakes
  printf '%s\n' "$c"
}
show() {  # <case> <title> <rc>
  local c=$1
  echo "--- [$LABEL] $2 -> exit $3"
  echo "remote-tracking refs: $(git -C "$c/wt" for-each-ref --format='%(refname:short)' refs/remotes | tr '\n' ' ')"
  echo "stderr (first lines):"; sed -n '1,4p' "$c/stderr" | sed 's/^/  | /'
  echo "worktree present: $([ -d "$c/wt" ] && echo yes || echo no); task meta present: $([ -e "$c/state/task-x1.meta" ] && echo yes || echo no)"
  echo
}

c=$(setup mirror-only); run_teardown "$c" >"$c/stdout" 2>"$c/stderr"; show "$c" "S1 work only on no-mistakes mirror, no --force" $?
c=$(setup mirror-and-origin); git -C "$c/wt" push -q origin fm/task-x1 2>/dev/null; git -C "$c/project" fetch -q origin
  run_teardown "$c" >"$c/stdout" 2>"$c/stderr"; show "$c" "S2 same work also pushed to origin (forge)" $?
c=$(setup mirror-force); run_teardown "$c" --force >"$c/stdout" 2>"$c/stderr"; show "$c" "S3 work only on mirror, --force" $?
c=$(setup mirror-plus-fork); git init -q --bare "$c/fork.git"; git -C "$c/project" remote add fork "$c/fork.git"
  git -C "$c/wt" push -q fork fm/task-x1 2>/dev/null; git -C "$c/project" fetch -q fork
  run_teardown "$c" >"$c/stdout" 2>"$c/stderr"; show "$c" "S4 work on mirror and a fork remote" $?
c=$(setup mirror-extra-local); wt_commit_file "$c" more.txt x "local after mirror push" >/dev/null; git -C "$c/wt" push -q origin fm/task-x1~1:refs/heads/fm/task-x1 2>/dev/null; git -C "$c/project" fetch -q origin
  run_teardown "$c" >"$c/stdout" 2>"$c/stderr"; show "$c" "S5 origin has first commit, extra local commit unpushed" $?
