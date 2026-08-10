#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one line when firstmate should wake and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a signal. Two terminal-safe wakes are emitted, each a distinct single token:
#   merged      the PR or MR merged (terminal; the watcher then retires the poll)
#   bot-review  an automated reviewer (e.g. CodeRabbit, any Bot-type account)
#               submitted a new GitHub review since the last poll (non-terminal;
#               the poll stays armed and keeps watching for merge and further
#               reviews). GitHub only: it needs the reviews API, which glab has
#               no equivalent for, so a GitLab MR emits merge wakes alone.
# "merged" takes priority: a merged PR emits merged and never also bot-review.
# The provider-tagged identity is data in the sidecar and is never interpolated
# into this source: these bytes are identical for every task. Each provider is
# read through its own standard CLI, gh for GitHub and glab for GitLab, so an
# upstream checkout needs no extra tooling to follow either.
#
# bot-review is deduped through a private per-task sidecar that stores the
# highest bot review id already surfaced (state/<id>.pr-review-seen). Each new
# bot review wakes at most once: the poll wakes only when the current maximum
# bot review id exceeds the stored one, and it records the new maximum before
# printing so a persisted write is a precondition of the wake. The seen sidecar
# is not identity-bound like the merge poll: at worst a lost or doctored value
# re-wakes or misses a review, never a false merge, and every failure path here
# stays silent. Its path is derived from the check basename when the poll runs
# standalone and passed as the seventh validated argument by the watcher.
set -u
LC_ALL=C
export LC_ALL

# Print bot-review when an automated GitHub reviewer has submitted a review
# newer than the last one surfaced for this task. Silent on any error, on a
# missing seen path, and when nothing is new. The new maximum is persisted
# before printing, so a wake never fires without recording that it fired.
emit_new_bot_review() {
  local owner=$1 repo=$2 number=$3 seen_file=$4
  local ids new_max cur dir tmp
  [ -n "$seen_file" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  # gh's own --jq engine filters to Bot-authored reviews and streams their ids,
  # one per line across every page, so no external JSON processor is needed.
  ids=$(gh api --paginate "repos/$owner/$repo/pulls/$number/reviews" \
    --jq '.[] | select(.user.type == "Bot") | .id' 2>/dev/null) || return 0
  new_max=$(printf '%s\n' "$ids" | sort -n | tail -1)
  case "$new_max" in
    ''|*[!0-9]*) return 0 ;;
  esac
  cur=0
  if [ -f "$seen_file" ] && [ ! -L "$seen_file" ]; then
    IFS= read -r cur < "$seen_file" 2>/dev/null || cur=0
    case "$cur" in
      ''|*[!0-9]*) cur=0 ;;
    esac
  fi
  [ "$new_max" -gt "$cur" ] 2>/dev/null || return 0
  dir=${seen_file%/*}
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  umask 077
  tmp=$(mktemp "$dir/.fm-pr-review-seen.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$new_max" > "$tmp" 2>/dev/null \
    && chmod 0600 "$tmp" 2>/dev/null \
    && mv -f -- "$tmp" "$seen_file" 2>/dev/null; then
    printf '%s\n' bot-review
  else
    rm -f -- "$tmp" 2>/dev/null
  fi
}

seen=
if { [ "$#" -eq 6 ] || [ "$#" -eq 7 ]; } && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  seen=${7:-}
  case "$seen" in
    *.pr-review-seen) ;;
    *) seen= ;;
  esac
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll; seen=${0%.check.sh}.pr-review-seen ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    if [ "$state" = MERGED ]; then
      printf '%s\n' merged
      exit 0
    fi
    emit_new_bot_review "$owner" "$repo" "$number" "$seen"
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
