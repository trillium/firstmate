#!/usr/bin/env bash
# fm-done-gate-warn.sh - warn on a done line the append itself does not refuse.
# Usage: fm-done-gate-warn.sh <state>/<task>.status
#
# Called by the worker status command right after the append. Reads the last
# status line. Never refuses and always exits 0: the append has already happened.
#
# A kind=scout task whose meta lacks decisions_reviewed=1 (the record
# bin/fm-captain-hold.sh complete writes) gets a completion-gate warning.
#
# A ship whose worktree is a git repository with a Makefile `check` target must
# back the done line with a recorded verification: .pr-evidence/<task>/check.json
# (written by bin/fm-check-record.sh) naming the same head, with exit 0 and
# source live. The head is the commit hash the done line names, else the
# worktree's HEAD. A missing, mismatched, failing, or sample-sourced record gets
# a warning; a worktree without a Makefile check target, or without jq, is quiet.
#
# When meta names a worktree and a branch, and that branch has an open pull
# request, a further warning names the pending and failing checks. No open
# pull request, a forge failure, or a read that exceeds FM_DONE_GATE_CHECK_SECS
# (default 5) prints nothing about checks. Passing and skipped checks are quiet.
# The open-PR lookup is fm_pr_number_from_branch (bin/fm-pr-lib.sh). The check
# read is `gh pr checks --json name,bucket`, the same read bin/fm-pr-state.sh
# uses. "no checks reported" is gh's own sentence, matched the same way
# bin/fm-pr-state.sh matches it. An empty check list is the same unverified
# state.
status=${1:-}
[ -n "$status" ] && [ -f "$status" ] || exit 0
case "$(tail -n 1 "$status")" in
  done*) ;;
  *) exit 0 ;;
esac
meta=${status%.status}.meta
[ -f "$meta" ] || exit 0
get() { sed -n "s/^$1=//p" "$meta" | tail -n 1; }
id=$(basename "${status%.status}")

if [ "$(get kind)" = scout ] && [ "$(get decisions_reviewed)" != 1 ]; then
  echo "warning: $id reported done but no captain-hold completion record exists; run bin/fm-captain-hold.sh complete $id (--none | <task-id>...) before treating it as finished" >&2
fi

# Quiet unless the done head lacks a passing recorded check. Reads only local
# files, so it cannot change the exit status.
warn_unrecorded_check() {
  local wt line named head file rec_head rec_exit rec_source
  [ "$(get kind)" = scout ] && return 0
  wt=$(get worktree)
  [ -n "$wt" ] && [ -f "$wt/Makefile" ] && grep -q '^check:' "$wt/Makefile" || return 0
  command -v jq >/dev/null 2>&1 || return 0
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 0
  line=$(tail -n 1 "$status")
  named=$(printf '%s\n' "$line" | grep -oE '(^|[^0-9a-fA-F])[0-9a-f]{7,40}([^0-9a-fA-F]|$)' | grep -oE '[0-9a-f]{7,40}' | head -n 1)
  if [ -n "$named" ]; then
    head=$(git -C "$wt" rev-parse --verify --quiet "$named^{commit}" 2>/dev/null) || head=$named
  fi
  file="$wt/.pr-evidence/$id/check.json"
  if [ ! -f "$file" ]; then
    echo "warning: $id reported done at ${head:0:12} but no recorded check exists (.pr-evidence/$id/check.json); run make check through bin/fm-check-record.sh on this head" >&2
    return 0
  fi
  rec_head=$(jq -r '.head // empty' "$file" 2>/dev/null) || rec_head=
  rec_exit=$(jq -r '.exit // empty' "$file" 2>/dev/null) || rec_exit=
  rec_source=$(jq -r '.source // empty' "$file" 2>/dev/null) || rec_source=
  if [ "$rec_head" != "$head" ]; then
    echo "warning: $id reported done at ${head:0:12} but the recorded check is for ${rec_head:0:12}; rerun make check on this head" >&2
  elif [ "$rec_exit" != 0 ]; then
    echo "warning: $id reported done at ${head:0:12} but its recorded check exited ${rec_exit:-unknown}" >&2
  elif [ "$rec_source" != live ]; then
    echo "warning: $id reported done at ${head:0:12} but its recorded check used ${rec_source:-unknown} data, not live" >&2
  fi
}
warn_unrecorded_check || true

# Quiet unless an open PR's checks are still unsettled. A forge failure or the
# time bound leaves no warning and cannot change the exit status.
warn_open_pr_checks() {
  local wt branch script_dir secs
  wt=$(get worktree)
  branch=$(get branch)
  [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$branch" ] || return 0
  case "$branch" in
    HEAD | *[$'\n']*) return 0 ;;
  esac
  command -v gh >/dev/null 2>&1 || return 0
  command -v gh-axi >/dev/null 2>&1 || return 0
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  secs=${FM_DONE_GATE_CHECK_SECS:-5}
  case "$secs" in
    '' | *[!0-9]* | 0) secs=5 ;;
  esac
  (
    set +e
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$script_dir/fm-timeout-lib.sh"
    local deadline left number rc json err summary count pending failing parts now
    deadline=$(($(date +%s) + secs))
    left=$secs
    rc=0
    number=$(
      # shellcheck disable=SC2016 # The child shell expands this after bash -c receives its arguments.
      fm_run_timed "$left" bash -c \
        'unset CDPATH; . "$1"; fm_pr_number_from_branch "$2" "$3" open' \
        _ "$script_dir/fm-pr-lib.sh" "$wt" "$branch" 2>/dev/null
    ) || rc=$?
    if fm_timed_out "$rc" || [ "$rc" -ge 128 ] || [ "$rc" -ne 0 ]; then
      exit 0
    fi
    case "$number" in
      '' | *[!0-9]*) exit 0 ;;
    esac
    now=$(date +%s)
    left=$((deadline - now))
    [ "$left" -ge 1 ] || exit 0
    err=$(mktemp "${TMPDIR:-/tmp}/fm-done-gate-warn.XXXXXX") || exit 0
    trap 'rm -f "$err"' EXIT
    rc=0
    json=$(
      # shellcheck disable=SC2016 # The child shell expands this after bash -c receives its arguments.
      fm_run_timed "$left" bash -c \
        'unset CDPATH
         cd "$1" >/dev/null || exit 1
         export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
         exec gh pr checks "$2" --json name,bucket' \
        _ "$wt" "$number" 2>"$err"
    ) || rc=$?
    if fm_timed_out "$rc" || [ "$rc" -ge 128 ]; then
      exit 0
    fi
    if [ -z "$(printf '%s' "$json" | tr -d '[:space:]')" ]; then
      if [ "$rc" -ne 0 ] && grep -q "^no checks reported on the '" "$err"; then
        printf 'warning: %s reported done but no checks have reported yet on branch %s\n' \
          "$id" "$branch" >&2
      fi
      exit 0
    fi
    command -v jq >/dev/null 2>&1 || exit 0
    count=$(printf '%s\n' "$json" | jq -er 'if type == "array" then length else error("not an array") end' 2>/dev/null) || exit 0
    case "$count" in
      '' | *[!0-9]*) exit 0 ;;
    esac
    if [ "$count" -eq 0 ]; then
      printf 'warning: %s reported done but no checks have reported yet on branch %s\n' \
        "$id" "$branch" >&2
      exit 0
    fi
    summary=$(printf '%s\n' "$json" | jq -r '
      if type != "array" then error("not an array") else
        ([.[] | select(.bucket == "pending" and (.name | type) == "string" and .name != "") | .name] | unique | join(", ")) as $p
        | ([.[] | select(.bucket == "fail" and (.name | type) == "string" and .name != "") | .name] | unique | join(", ")) as $f
        | (if $p != "" then "P\t" + $p else empty end),
          (if $f != "" then "F\t" + $f else empty end)
      end
    ' 2>/dev/null) || exit 0
    pending=
    failing=
    while IFS=$'\t' read -r kind names; do
      case "$kind" in
        P) pending=$names ;;
        F) failing=$names ;;
      esac
    done <<EOF
$summary
EOF
    parts=
    [ -z "$pending" ] || parts="pending: $pending"
    if [ -n "$failing" ]; then
      if [ -n "$parts" ]; then
        parts="$parts; failing: $failing"
      else
        parts="failing: $failing"
      fi
    fi
    [ -n "$parts" ] || exit 0
    printf 'warning: %s reported done with unsettled checks on branch %s: %s\n' \
      "$id" "$branch" "$parts" >&2
  )
}

warn_open_pr_checks || true
exit 0
