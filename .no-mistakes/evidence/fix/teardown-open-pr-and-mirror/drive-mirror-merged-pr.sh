#!/usr/bin/env bash
# S6: work pushed to the no-mistakes mirror whose replayed patch landed in a
# squash-merged PR head must still count as landed (allow), driving the real
# bin/fm-teardown.sh with forge lookups stubbed to report PR 7 merged.
set -u
SRC_ROOT=$1; LABEL=$2
WT_ROOT=/Users/mini0/.no-mistakes/worktrees/1467055f0b60/01M65KHRK7HT918W8V5E2RJM5W
. "$WT_ROOT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
for fn in make_case write_meta wt_commit_file run_teardown add_gh_pr_merged_for_head append_pr_meta_url land_equivalent_patch_on_origin_branch commit_tree_from_wt_head; do
  eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$WT_ROOT/tests/fm-teardown.test.sh")"
done
ROOT=$SRC_ROOT; TEARDOWN="$SRC_ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-mirror-pr.XXXXXX"); trap 'rm -rf "$TMP_ROOT"' EXIT
for variant in merged-pr-contains-patch merged-pr-different-content; do
  c=$(make_case "$variant"); write_meta "$c" no-mistakes ship
  wt_commit_file "$c" local-parent.txt parent "local parent" >/dev/null
  git -C "$c/wt" push -q origin HEAD:refs/heads/fm/task-x1; git -C "$c/project" fetch -q origin fm/task-x1
  wt_commit_file "$c" feature.txt hello "add feature" >/dev/null
  git init -q --bare "$c/mirror.git"; git -C "$c/project" remote add no-mistakes "$c/mirror.git"
  git -C "$c/wt" push -q no-mistakes fm/task-x1 2>/dev/null; git -C "$c/project" fetch -q no-mistakes
  append_pr_meta_url "$c"
  content=hello; [ "$variant" = merged-pr-different-content ] && content=goodbye
  pr_head=$(land_equivalent_patch_on_origin_branch "$c" pr-head feature.txt "$content" "add feature")
  add_gh_pr_merged_for_head "$c" "$pr_head"
  run_teardown "$c" >"$c/stdout" 2>"$c/stderr"; rc=$?
  echo "--- [$LABEL] S6 $variant (unpushed-to-forge commit sits on no-mistakes mirror) -> exit $rc"
  echo "remote-tracking refs: $(git -C "$c/wt" for-each-ref --format='%(refname:short)' refs/remotes | tr '\n' ' ')"
  sed -n '1,4p' "$c/stderr" | sed 's/^/  | /'
  echo "task meta present: $([ -e "$c/state/task-x1.meta" ] && echo yes || echo no)"; echo
done
