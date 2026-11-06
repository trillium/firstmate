#!/usr/bin/env bash
# Report the authenticated operator's pull requests on this checkout's origin
# and registered publication upstream.
#
# Usage: fm-pr-status.sh [--json]
#
# Structured reads use the plain GitHub CLI (gh) with --json/--jq; gh-axi emits
# its own text format and is not parseable here. Non-JSON output is reported as
# a per-repository error rather than parsed.
#
# The command is read-only. It discovers only the existing origin remote and
# the publication upstream selected by fm-role-lib.sh; it never guesses a
# repository. Each reachable repository is queried independently, so an API
# failure is reported without hiding the other repository. Plain text is the
# default. --json emits fm-pr-status.v1 with rows, flags, and errors.
#
# Rows contain an open PR's number, title, repository, merge state, age and
# last update, plus the newest comment not written by the authenticated
# operator. A state/*.meta `pr=` link supplies the owning task when present.
# Flags identify open task metadata whose linked PR is closed or merged, and
# drafts that have been open for more than seven days.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) JSON=1 ;;
  '') JSON=0 ;;
  *) printf 'fm-pr-status: unknown option: %s\n' "$1" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { printf 'fm-pr-status: jq is required\n' >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { printf 'fm-pr-status: gh is required\n' >&2; exit 1; }

# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-status.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

repo_for_remote() { # <remote> -> owner/repo when it is github.com
  local url identity
  url=$(git -C "$FM_ROOT" remote get-url "$1" 2>/dev/null) || return 0
  identity=$(fm_role_remote_identity "$url" "$FM_ROOT")
  case "$identity" in github.com/*/*) printf '%s\n' "${identity#github.com/}" ;; esac
}

origin=$(repo_for_remote origin)
upstream=$(fm_role_publication_target "$FM_ROOT")
case "$upstream" in github.com/*/*) upstream=${upstream#github.com/} ;; *) upstream= ;; esac
printf '%s\n%s\n' "$origin" "$upstream" | awk 'NF && !seen[$0]++' > "$TMP/repos"

operator=$(gh api user --jq .login 2>"$TMP/operator.err") || {
  printf 'fm-pr-status: could not identify authenticated operator: %s\n' "$(sed -n '/[^[:space:]]/{s/[[:cntrl:]]//g;p;q;}' "$TMP/operator.err")" >&2
  exit 1
}

# Task metadata is authoritative for the URL-to-task relation. A metadata
# record is current work; terminal records are removed by the lifecycle.
: > "$TMP/links.jsonl"
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  task=${meta##*/}; task=${task%.meta}
  while IFS= read -r url; do
    case "$url" in https://github.com/*/*/pull/[1-9]* ) jq -cn --arg url "$url" --arg task "$task" '{url:$url,task:$task}' >> "$TMP/links.jsonl" ;; esac
  done < <(sed -n 's/^pr=//p' "$meta")
done
jq -s '.' "$TMP/links.jsonl" > "$TMP/links.json"

: > "$TMP/rows.jsonl"; : > "$TMP/errors.jsonl"; : > "$TMP/flags.jsonl"
while IFS= read -r repo; do
  repo_key=$(printf '%s' "$repo" | tr '/' '_')
  out="$TMP/$repo_key.json"; err="$TMP/$repo_key.err"
  if ! gh pr list --repo "$repo" --author "$operator" --state open --limit 100 \
      --json number,title,url,updatedAt,createdAt,mergeStateStatus,isDraft,author > "$out" 2>"$err"; then
    message=$(sed -n '/[^[:space:]]/{s/[[:cntrl:]]//g;p;q;}' "$err")
    jq -cn --arg repo "$repo" --arg message "${message:-GitHub query failed}" '{repo:$repo,message:$message}' >> "$TMP/errors.jsonl"
    continue
  fi
  if ! jq -e 'type == "array"' "$out" >/dev/null 2>&1; then
    jq -cn --arg repo "$repo" '{repo:$repo,message:"GitHub returned invalid PR list JSON"}' >> "$TMP/errors.jsonl"
    continue
  fi
  while IFS= read -r pr; do
    number=$(jq -r '.number' <<<"$pr")
    url=$(jq -r '.url' <<<"$pr")
    comments="$TMP/comments-$repo_key-$number.json"
    if ! gh api "repos/$repo/issues/$number/comments?per_page=100" > "$comments" 2>/dev/null || ! jq -e 'type == "array"' "$comments" >/dev/null 2>&1; then
      printf '[]\n' > "$comments"
    fi
    jq -c --arg repo "$repo" --arg url "$url" --arg operator "$operator" --arg now "$NOW" --argjson links "$(cat "$TMP/links.json")" --slurpfile comments "$comments" '
      . + {repo:$repo, task: ($links | map(select(.url == $url) | .task) | first),
      age_seconds:(($now | fromdateiso8601) - (.createdAt | fromdateiso8601)),
      update_age_seconds:(($now | fromdateiso8601) - (.updatedAt | fromdateiso8601)),
      last_non_operator_comment: ([ $comments[]?[] | select(.user.login != $operator) ] | sort_by(.created_at) | last
        | if . then {author:.user.login,date:.created_at} else null end)}' <<<"$pr" >> "$TMP/rows.jsonl"
  done < <(jq -c '.[]' "$out")
done < "$TMP/repos"

# A linked current task can point at a PR no longer in the open listings.
while IFS= read -r link; do
  url=$(jq -r '.url' <<<"$link"); task=$(jq -r '.task' <<<"$link")
  record=$(gh pr view "$url" --json state,mergedAt,isDraft,createdAt 2>/dev/null) || continue
  jq -e 'type == "object"' <<<"$record" >/dev/null 2>&1 || continue
  state=$(jq -r '.state' <<<"$record")
  if [ "$state" = CLOSED ] || [ "$state" = MERGED ]; then
    jq -cn --arg type closed_task --arg task "$task" --arg url "$url" --arg state "$state" '{type:$type,task:$task,url:$url,state:$state}' >> "$TMP/flags.jsonl"
  fi
done < <(jq -c '.[]' "$TMP/links.json")

jq -s '.' "$TMP/rows.jsonl" > "$TMP/rows.json"
while IFS= read -r row; do
  if jq -e --arg now "$NOW" '(.isDraft == true) and (($now | fromdateiso8601) - (.createdAt | fromdateiso8601) > 604800)' <<<"$row" >/dev/null; then
    jq -cn --argjson row "$row" --arg now "$NOW" '{type:"stale_draft",url:$row.url,age_days:((($now|fromdateiso8601)-($row.createdAt|fromdateiso8601))/86400|floor)}' >> "$TMP/flags.jsonl"
  fi
done < <(jq -c '.[]' "$TMP/rows.json")
jq -s '.' "$TMP/errors.jsonl" > "$TMP/errors.json"
jq -s '.' "$TMP/flags.jsonl" > "$TMP/flags.json"

if [ "$JSON" = 1 ]; then
  jq -n --arg generated "$NOW" --arg operator "$operator" --slurpfile rows "$TMP/rows.json" --slurpfile flags "$TMP/flags.json" --slurpfile errors "$TMP/errors.json" \
    '{schema:"fm-pr-status.v1",generated:$generated,operator:$operator,prs:$rows[0],flags:$flags[0],errors:$errors[0]}'
  exit 0
fi

printf 'Open pull requests for %s\n' "$operator"
jq -r '.[] | "#\(.number) [\(.repo)] \(.title)\n  \(.url)\n  merge: \(.mergeStateStatus // "UNKNOWN") · age: \((.age_seconds / 86400 | floor))d · updated: \((.update_age_seconds / 86400 | floor))d ago (\(.updatedAt))\n  last non-operator comment: \(if .last_non_operator_comment then .last_non_operator_comment.author + " at " + .last_non_operator_comment.date else "none" end)\n  task: \(.task // "unlinked")"' "$TMP/rows.json"
jq -r '.[] | "GitHub unavailable for \(.repo): \(.message)"' "$TMP/errors.json" >&2
jq -r '.[] | if .type == "closed_task" then "FLAG closed task \(.task): \(.state) \(.url)" else "FLAG draft older than 7 days (\(.age_days)d): \(.url)" end' "$TMP/flags.json"
