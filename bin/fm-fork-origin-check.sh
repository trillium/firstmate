#!/usr/bin/env bash
# Advisory scan for registered project clones that cannot cut a correct
# fork-contribution branch. Two independent things can be wrong: the remotes
# (`origin` still points at the upstream repo the captain does not own, rather
# than the captain's own trillium/<repo> fork) and the base (the clone's
# default branch sits on upstream's line instead of the fork's). See the
# project-management skill's "Fork-contribution projects" section for the
# required origin/upstream convention, and bin/fm-brief.sh for how a generated
# brief reacts to each clone shape at dispatch time.
#
# This is a read-only report, never a gate: it never blocks a spawn, edits a
# remote, moves a local branch, or fails the build. Run it by hand when
# triaging suspected misconfigured clones (e.g. after an incident like the
# rango PR opened against upstream instead of the captain's fork).
#
# Remote shape - for each project in data/projects.md with a local clone under
# projects/:
#   - origin owned by trillium, no upstream remote  -> ordinary project, silent.
#   - origin owned by trillium, upstream remote set  -> correctly swapped
#     fork-contribution clone; remotes are right, so the base check below runs.
#   - origin NOT owned by trillium, upstream remote set -> MISCONFIGURED:
#     the swap was started (upstream added) but never finished (origin still
#     points upstream). Always reported; no network call needed.
#   - origin NOT owned by trillium, no upstream remote -> possibly an
#     unswapped fork-contribution clone, or a genuinely non-Trillium project
#     with no fork relationship at all. Best-effort: report it only when
#     `trillium/<repo>` exists on GitHub and is itself a fork (via `gh`), so
#     an ordinary non-Trillium project with no fork counterpart stays silent.
#     A missing `gh` or a failed lookup is not an error - that project is
#     skipped rather than misreported.
#
# Base - for a correctly swapped clone only, its local default branch is then
# compared against origin/<default>, because correct remotes alone do not mean
# the clone can cut a correct branch:
#   - local default is ahead of origin/<default> -> DIVERGED-BASE: the clone is
#     sitting on upstream's line, so every worktree cut from it starts on the
#     wrong base. This is the defect that turned a 3-file change into a
#     46-commit conflicting PR (robots-tnwd, trillium/herdr-web#10). Fleet sync
#     deliberately refuses to touch a diverged default, so it needs a decision.
#   - local default is only behind origin/<default> -> BEHIND: ordinary drift
#     that fleet sync fast-forwards. Reported for context, never counted as a
#     misconfiguration.
#   - in sync, or no resolvable default branch -> silent.
# The comparison refreshes just origin/<default> with one targeted fetch per
# swapped clone. That fetch is best-effort: a failure (offline, no auth) falls
# back to the remote-tracking ref already on disk rather than erroring, and
# --no-fetch skips it entirely.
#
# Usage: fm-fork-origin-check.sh [--no-fetch]
# A scan always exits 0; findings go to stdout, one per line. Only an unknown
# argument is an error (exit 2), so the scan itself is never a gate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/projects.md"

do_fetch=1
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    --no-fetch) do_fetch=0; shift ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

if [ ! -f "$REG" ]; then
  echo "no registry at $REG; nothing to check"
  exit 0
fi

owner_of() {
  local url=$1 rest owner
  url=${url%.git}
  url=${url%/}
  rest=${url%/*}
  owner=${rest##*/}
  owner=${owner##*:}
  printf '%s\n' "$owner" | tr '[:upper:]' '[:lower:]'
}

# The clone's default branch name: origin/HEAD when the clone recorded one,
# else the first of main/master that exists locally. A clone with neither (no
# commits yet, or an unusual branch name) has no default to judge.
default_branch_of() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=""
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# Report whether a correctly swapped clone's local default branch can actually
# serve as a branch base. Sets `found` only for the diverged case; plain
# "behind" is ordinary drift, not a misconfiguration. Never moves a branch: the
# only write is the targeted refresh of origin/<default>'s remote-tracking ref.
base_check() {
  local name=$1 dir=$2 default ahead behind
  default=$(default_branch_of "$dir") || return 0
  git -C "$dir" show-ref --verify --quiet "refs/heads/$default" || return 0
  if [ "$do_fetch" -eq 1 ]; then
    git -C "$dir" fetch --quiet origin \
      "+refs/heads/$default:refs/remotes/origin/$default" </dev/null 2>/dev/null || true
  fi
  git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$default" || return 0
  ahead=$(git -C "$dir" rev-list --count "refs/remotes/origin/$default..refs/heads/$default" 2>/dev/null) || return 0
  behind=$(git -C "$dir" rev-list --count "refs/heads/$default..refs/remotes/origin/$default" 2>/dev/null) || return 0
  if [ "$ahead" -gt 0 ]; then
    echo "DIVERGED-BASE: $name - local $default is $ahead commits ahead of origin/$default (and $behind behind); the remotes are right but the branch is sitting on upstream's line, so every worktree cut from this clone starts on the wrong base and its PR will carry upstream's commits. Fleet sync will not touch a diverged default; decide how to reset it (project-management skill)"
    found=1
  elif [ "$behind" -gt 0 ]; then
    echo "BEHIND: $name - local $default is $behind commits behind origin/$default; ordinary drift that fleet sync fast-forwards, not a misconfiguration"
  fi
}

have_gh=0
command -v gh >/dev/null 2>&1 && have_gh=1

found=0
while read -r name; do
  [ -n "$name" ] || continue
  dir="$PROJECTS/$name"
  [ -d "$dir" ] || continue
  origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
  [ -n "$origin" ] || continue
  upstream=$(git -C "$dir" remote get-url upstream 2>/dev/null) || upstream=""
  owner=$(owner_of "$origin")
  if [ "$owner" = trillium ]; then
    # Remotes are right. An ordinary Trillium project with no upstream remote
    # has no fork base to get wrong; a swapped fork-contribution clone does.
    [ -n "$upstream" ] && base_check "$name" "$dir"
    continue
  fi
  if [ -n "$upstream" ]; then
    echo "MISCONFIGURED: $name - origin ($origin) is not trillium but an upstream remote is set; finish the swap (project-management skill)"
    found=1
    continue
  fi
  [ "$have_gh" -eq 1 ] || continue
  is_fork=$(gh repo view "trillium/$name" --json isFork -q .isFork 2>/dev/null) || continue
  if [ "$is_fork" = "true" ]; then
    echo "CANDIDATE: $name - origin ($origin) is not trillium, and trillium/$name exists as a fork; likely needs the origin/upstream swap (project-management skill)"
    found=1
  fi
done <<EOF
$(awk '$1=="-"{print $2}' "$REG")
EOF

[ "$found" -eq 1 ] || echo "no misconfigured fork-contribution clones found"
exit 0
