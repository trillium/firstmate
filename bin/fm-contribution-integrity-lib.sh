#!/usr/bin/env bash
# Deterministic push-integrity check over owned open contribution PRs.
#
# Sourced by fm-contributions.sh; its poll calls contribution_integrity_check
# right after each successful PR observation, with that observation's core
# pull read in $TMP/core.json. Needs the caller's STATE, TMP, NOW, DEADLINE,
# fm-timeout-lib and fm-wake-lib.
#
# Per PR (state: $STATE/contribution-integrity/<sha256 of url>.json) it records
# the last known-good head and its commit count, and on every new head checks:
#   conflicting    the forge reports the head unmergeable (needs a prior good head)
#   commit-growth  the commit count grew by more than
#                  FM_CONTRIBUTIONS_INTEGRITY_COMMIT_GROWTH (default 10) in one push
#                  (needs a prior good head)
#   wrong-base     a fork PR whose commits include commits already on the
#                  fork's default branch, i.e. it was rebased onto fork main
#   workflows      .github/workflows files appear in the diff
# A flagged head never becomes the known-good head. One incident per PR and
# head wakes firstmate ("check: contributions integrity <url> rules=<r,..>
# bad=<head> last-good=<head|none>") and files one robots item; the head is
# recorded as an incident only after both succeed, so a failed filing retries.
# A PR whose core read lacks a commit count is skipped, and a failed extra read
# leaves the head unrecorded so the next poll retries. Detection only: it never
# touches the forge or the PR, and the pre-push half is a follow-up.

integrity_read() { # outfile gh-args... : bounded best-effort forge read
  local out=$1 left
  shift
  left=$((DEADLINE - $(date +%s)))
  [ "$left" -ge 2 ] || return 1
  [ "$left" -le 5 ] || left=5
  fm_run_timed "$left" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@" > "$out" 2> /dev/null
}

contribution_integrity_check() { # canonical-pr-url
  local url=$1 key dir file prior number base_repo head_repo default_branch head_ref head
  local part ahead=null workflows=false rules incident key_incident reason title body status=0
  jq -e '.state == "open" and (.commits | type == "number") and (.head.sha | type == "string")' "$TMP/core.json" >/dev/null 2>&1 || return 0
  key=$(printf '%s' "$url" | shasum -a 256 | awk '{print $1}')
  dir="$STATE/contribution-integrity"
  file="$dir/$key.json"
  prior='{}'
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    prior=$(jq -c . "$file" 2>/dev/null) || prior='{}'
  fi
  head=$(jq -r '.head.sha' "$TMP/core.json")
  jq -e --arg head "$head" '.last_head == $head and .mergeable_known == true' <<< "$prior" >/dev/null 2>&1 && return 0
  number=${url##*/}
  base_repo=$(jq -r '.base.repo.full_name // empty' "$TMP/core.json")
  [ -n "$base_repo" ] || { part=${url#https://github.com/}; base_repo=${part%/pull/*}; }
  head_repo=$(jq -r '.head.repo.full_name // empty' "$TMP/core.json")
  default_branch=$(jq -r '.head.repo.default_branch // empty' "$TMP/core.json")
  head_ref=$(jq -r '.head.ref // empty' "$TMP/core.json")

  integrity_read "$TMP/integrity-files.json" api "repos/$base_repo/pulls/$number/files?per_page=100" --paginate --slurp || return 0
  jq -e 'type == "array"' "$TMP/integrity-files.json" >/dev/null 2>&1 || return 0
  workflows=$(jq 'any(.[][]; .filename | startswith(".github/workflows/"))' "$TMP/integrity-files.json") || return 0
  if [ -n "$head_repo" ] && [ "$head_repo" != "$base_repo" ] && [ -n "$default_branch" ] && [ "$head_ref" != "$default_branch" ]; then
    integrity_read "$TMP/integrity-compare.json" api "repos/$head_repo/compare/$default_branch...$head" || return 0
    ahead=$(jq '.ahead_by | if type == "number" then . else null end' "$TMP/integrity-compare.json" 2>/dev/null) || return 0
  fi

  jq -n --argjson prior "$prior" --slurpfile core "$TMP/core.json" --argjson workflows "$workflows" \
    --argjson ahead "$ahead" --argjson bound "${FM_CONTRIBUTIONS_INTEGRITY_COMMIT_GROWTH:-10}" '
    $core[0] as $c | $prior.good as $good
    | [ (if $good != null and $c.mergeable == false then "conflicting" else empty end),
        (if $good != null and ($c.commits - $good.commits) > $bound then "commit-growth" else empty end),
        (if $ahead != null and ($c.commits - $ahead) > 0 then "wrong-base" else empty end),
        (if $workflows and ($good == null or ($good.workflows | not)) then "workflows" else empty end) ]' > "$TMP/integrity-rules.json" || return 0
  rules=$(jq -r 'join(",")' "$TMP/integrity-rules.json")

  incident=false
  if [ -n "$rules" ]; then
    if ! jq -e --arg head "$head" '(.incidents // []) | index($head) != null' <<< "$prior" >/dev/null; then
      incident=true
    fi
  fi
  if [ "$incident" = true ]; then
    local good_head
    good_head=$(jq -r '.good.head // "none"' <<< "$prior")
    reason="check: contributions integrity $url rules=$rules bad=$head last-good=$good_head"
    key_incident=$(printf '%s\n%s\n' "$url" "$head" | shasum -a 256 | awk '{print $1}')
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 0
    if ! fm_wake_queued_keys_locked check | grep -Fx "contribution-integrity-$key_incident" >/dev/null; then
      fm_wake_append_locked check "contribution-integrity-$key_incident" "$reason" || status=1
      [ "$status" -ne 0 ] || printf 'contribution-wake: %s\n' "$reason"
    fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
    [ "$status" -eq 0 ] || return 0
    title="Contribution push integrity: $url head ${head:0:12} ($rules)"
    body="Rule(s) fired: $rules. Bad head: $head. Last known-good head: $good_head. PR: $url. Found by fm-contributions integrity check; fix or revert the push, then re-observe."
    "$SCRIPT_DIR/fm-note.sh" robots "$title" --body "$body" >/dev/null 2>&1 || return 0
  fi

  mkdir -p "$dir"
  local mergeable_known=true staged
  jq -e '.mergeable == null' "$TMP/core.json" >/dev/null && mergeable_known=false
  staged=$(umask 077; mktemp "$dir/.integrity.XXXXXX")
  jq -n --argjson prior "$prior" --slurpfile core "$TMP/core.json" --argjson workflows "$workflows" \
    --arg rules "$rules" --arg url "$url" --argjson known "$mergeable_known" '
    $core[0] as $c
    | $prior + {url:$url, last_head:$c.head.sha, mergeable_known:$known}
    | if $rules == "" and $known then .good = {head:$c.head.sha, commits:$c.commits, workflows:$workflows} else . end
    | if $rules != "" then .incidents = (((.incidents // []) + [$c.head.sha]) | unique) else . end' > "$staged" \
    && mv -f -- "$staged" "$file"
}
