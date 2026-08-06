#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# Before recording anything, the merge is gated on CodeRabbit having actually
# reviewed the PR, via bin/fm-coderabbit-review-state.sh - a rate-limited
# CodeRabbit reports a green check while reviewing nothing, so its check
# conclusion cannot be the gate. FM_CODERABBIT_GATE=skip waives it explicitly.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# CodeRabbit review gate (robots-6bsj). A green CodeRabbit status check is not
# evidence of a review: when CodeRabbit is rate limited it reports its context as
# SUCCESS with the description "Review rate limited" and posts no review at all,
# so "all checks green" merges code the reviewer never opened. Ask the reviews
# API instead, and refuse rather than merge past a review that never happened.
# The refusal lands before any state is recorded, like the repo-override refusal
# above, so a blocked merge leaves the task exactly as it found it.
#
# FM_CODERABBIT_GATE=skip disables the gate. It is the explicit, deliberate
# waiver for the cases the policy allows - a stalled review the captain has
# decided to merge past, or a host with no gh - and it has to be typed, which is
# the entire difference between this and the silent green check it replaces.
coderabbit_gate() {
  local state rc=0
  [ "${FM_CODERABBIT_GATE:-}" != skip ] || return 0
  state=$("$SCRIPT_DIR/fm-coderabbit-review-state.sh" "$PR_OWNER" "$PR_REPO" "$PR_NUMBER") || rc=$?
  case "$rc:$state" in
    0:reviewed|0:absent) return 0 ;;
    0:rate-limited)
      echo "error: CodeRabbit is rate limited on $PR_OWNER/$PR_REPO#$PR_NUMBER and reviewed nothing; its green check is not a review" >&2
      ;;
    0:pending)
      echo "error: CodeRabbit has not reviewed $PR_OWNER/$PR_REPO#$PR_NUMBER yet" >&2
      ;;
    *)
      echo "error: CodeRabbit review state for $PR_OWNER/$PR_REPO#$PR_NUMBER could not be determined" >&2
      ;;
  esac
  echo "refusing to merge; fix the review or re-run with FM_CODERABBIT_GATE=skip to waive it deliberately" >&2
  return 1
}

coderabbit_gate || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
