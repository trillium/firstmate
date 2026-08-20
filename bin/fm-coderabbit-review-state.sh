#!/usr/bin/env bash
# Report whether CodeRabbit has actually reviewed a GitHub pull request, by
# asking the reviews API instead of reading its status check.
#
# Why this exists (robots-6bsj, observed on trillium/firstmate#67 on 2026-08-05):
# when CodeRabbit is rate limited it still reports its own commit-status context
# as SUCCESS, with the description "Review rate limited", while posting no review
# and no review comments at all - only an issue comment saying "Review limit
# reached". A green CodeRabbit check is therefore indistinguishable from a
# genuine clean review, and every merge policy that treats "all checks green" as
# sufficient will merge, on a public repo, code the reviewer never opened. The
# check conclusion is not evidence; the reviews list is.
#
# Usage: fm-coderabbit-review-state.sh <owner> <repo> <pr-number>
#
# Prints exactly one verdict word on stdout:
#   reviewed      CodeRabbit submitted a review or left inline review comments
#   rate-limited  CodeRabbit reviewed nothing and posted its review-limit notice
#   pending       CodeRabbit is present on the PR but has produced no review yet
#   absent        no CodeRabbit artifact at all (the bot is not on this repo)
#
# Exit status:
#   0  a verdict was determined and printed
#   2  usage error
#   3  the forge could not be queried, so the state is UNKNOWN
#
# Exit 3 is deliberately distinct from a verdict: a caller gating a merge must
# never read a failed query as "reviewed". This script's whole reason to exist is
# that a signal which is green when it should be silent is worse than no signal,
# so it reports what it could not learn rather than guessing.

set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: fm-coderabbit-review-state.sh <owner> <repo> <pr-number>" >&2
  exit 2
fi

OWNER=$1
REPO=$2
NUMBER=$3

# Validate before interpolating anything into an API path. Same character set the
# PR URL parser in bin/fm-pr-lib.sh accepts, so a caller cannot widen it here.
case "$OWNER" in *[!A-Za-z0-9._-]*|'') echo "error: invalid owner" >&2; exit 2 ;; esac
case "$REPO" in *[!A-Za-z0-9._-]*|'') echo "error: invalid repository" >&2; exit 2 ;; esac
case "$NUMBER" in *[!0-9]*|'') echo "error: invalid PR number" >&2; exit 2 ;; esac

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh is required to read CodeRabbit review state" >&2
  exit 3
fi

# CodeRabbit's GitHub App posts as the bot account "coderabbitai[bot]"; the
# human-facing account is "coderabbitai". Matching the lowercased prefix covers
# both without matching an unrelated login that merely contains the substring.
CODERABBIT_SELECT='select((.user.login // "") | ascii_downcase | startswith("coderabbitai"))'

# One paginated read of a PR sub-resource, with gh's own jq engine so this script
# adds no external jq dependency (matching bin/fm-pr-poll.sh). A failure of the
# call is propagated as unknown rather than as an empty - i.e. "not reviewed" -
# result, because the two must not be confused in either direction.
gh_read() {
  local path=$1 filter=$2 out
  out=$(gh api --paginate "$path" --jq "$filter" 2>/dev/null) || return 1
  printf '%s' "$out"
}

# A submitted review is the strongest evidence CodeRabbit actually looked.
REVIEWS=$(gh_read "repos/$OWNER/$REPO/pulls/$NUMBER/reviews" \
  ".[] | $CODERABBIT_SELECT | .id") || {
  echo "error: could not read reviews for $OWNER/$REPO#$NUMBER" >&2
  exit 3
}
if [ -n "$REVIEWS" ]; then
  printf '%s\n' reviewed
  exit 0
fi

# Inline review comments count too: CodeRabbit occasionally leaves file comments
# whose parent review is not surfaced by the reviews list.
INLINE=$(gh_read "repos/$OWNER/$REPO/pulls/$NUMBER/comments" \
  ".[] | $CODERABBIT_SELECT | .id") || {
  echo "error: could not read review comments for $OWNER/$REPO#$NUMBER" >&2
  exit 3
}
if [ -n "$INLINE" ]; then
  printf '%s\n' reviewed
  exit 0
fi

# No review of any kind. Issue comments distinguish "rate limited, will not
# review" from "has not got to it yet" from "is not on this repo at all".
# Newlines are collapsed so one comment stays one line for the match below.
NOTICES=$(gh_read "repos/$OWNER/$REPO/issues/$NUMBER/comments" \
  ".[] | $CODERABBIT_SELECT | (.body // \"\") | gsub(\"[[:space:]]+\"; \" \")") || {
  echo "error: could not read issue comments for $OWNER/$REPO#$NUMBER" >&2
  exit 3
}

if [ -z "$NOTICES" ]; then
  printf '%s\n' absent
  exit 0
fi

# Match CodeRabbit's own limit banners, including the machine marker it wraps the
# comment in. Deliberately NOT a bare "rate limit" match: the tips boilerplate
# CodeRabbit appends to every summary links to its rate-limits docs page, which
# would make an ordinary pending summary look like a limit notice. Both verdicts
# refuse the merge, so the distinction is about reporting the truth, not safety.
if printf '%s\n' "$NOTICES" \
  | grep -qiE 'rate limited by coderabbit|review limit reached|review rate limited|reached your pr review limit'; then
  printf '%s\n' rate-limited
  exit 0
fi

printf '%s\n' pending
exit 0
