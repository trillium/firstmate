#!/usr/bin/env bash
# fm-pr-jobs.sh - list the failing CI jobs of one GitHub pull request.
#
# Read-only. For each check that is not passing it prints one line:
#   <job name>: <conclusion> - <real failure | never scheduled (no runner, no steps)>
# A job that was cancelled with no runner and no steps never got a runner, so
# a runner outage is not confused with a failure caused by the diff.
# Prints nothing when no check is failing.
#
# Usage: fm-pr-jobs.sh <pr-url>
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

[ "$#" -eq 1 ] && [ "$1" != --help ] || { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" | sed '$d'; [ "${1:-}" = --help ] && exit 0; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "fm-pr-jobs: gh is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-pr-jobs: jq is required" >&2; exit 2; }
URL=$1
fm_pr_url_parse "$URL" && [ "$FM_PR_PROVIDER" = github ] || { echo "fm-pr-jobs: expected a GitHub pull-request URL" >&2; exit 2; }

CHECKS=$(gh pr checks "$URL" --json name,bucket,link 2>/dev/null) || CHECKS='[]'
printf '%s' "$CHECKS" | jq -r '.[] | select(.bucket=="fail" or .bucket=="cancel") | [.name, .link] | @tsv' |
while IFS=$'\t' read -r name link; do
  job_id=$(printf '%s' "$link" | sed -n 's#.*/job/\([0-9][0-9]*\).*#\1#p')
  detail='{}'
  if [ -n "$job_id" ]; then
    detail=$(gh api "/repos/$FM_PR_PATH/actions/jobs/$job_id" 2>/dev/null) || detail='{}'
  fi
  printf '%s' "$detail" | jq -r --arg name "$name" '
    (.conclusion // "unknown") as $c
    | $name + ": " + $c + " - "
    + (if $c == "cancelled" and (.runner_name == null or .runner_name == "")
          and ((.steps // []) | length) == 0
       then "never scheduled (no runner, no steps)" else "real failure" end)'
done
