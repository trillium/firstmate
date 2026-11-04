#!/usr/bin/env bash
# Read-only: report whether a GitHub pull request is verifiably ready at its
# live head, using the same judgment bin/fm-pr-merge.sh enforces before a merge
# (bin/fm-pr-github-ready-lib.sh owns it): open, not a draft, mergeable, every
# check green, and every check the base branch requires has reported. It never
# records, merges, or changes anything.
#
# Usage: fm-pr-ready-check.sh <pr-url>
# Exit 0 and a "verified:" line on stdout/stderr when ready. Exit 1 with every
# failing condition (for example a required check that has not reported) when
# not ready or unreadable, including mergeability GitHub has not computed yet.
# Exit 2 for a usage problem or a pull request this check cannot judge (only
# GitHub pull requests are judged), which a caller must treat as unverified.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-github-ready-lib.sh
. "$SCRIPT_DIR/fm-pr-github-ready-lib.sh"

if [ "$#" -ne 1 ] || ! fm_pr_url_parse "$1"; then
  echo "usage: fm-pr-ready-check.sh <pr-url>" >&2
  exit 2
fi
if [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: readiness can be verified only for a GitHub pull request, not $FM_PR_PROVIDER" >&2
  exit 2
fi
for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: verifying readiness requires $tool on PATH" >&2; exit 2; }
done
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
ALLOW_RED=()
ALLOW_MISSING=()
fm_pr_github_host_export "$FM_PR_HOST"
github_verify_mergeable || exit 1
