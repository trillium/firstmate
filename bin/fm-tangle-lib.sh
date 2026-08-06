# shellcheck shell=bash
# Shared worktree-tangle guard for the firstmate-on-itself case.
# Usage: . bin/fm-tangle-lib.sh
#
# Firstmate is a treehouse-pooled git repo of itself: crewmate worktrees and
# secondmate homes are all linked `git worktree`s of the same repo, while the
# PRIMARY checkout (the repo root firstmate operates from) is a normal checkout
# on a real branch - normally the default branch, main. The "worktree tangle"
# failure mode is a crewmate spawned to work on firstmate ITSELF branching and
# committing in the primary checkout instead of its own disposable worktree,
# stranding the primary on a feature branch (e.g. fm/readme-restructure-d3).
#
# fm_primary_tangle_branch detects exactly that and nothing else: a NAMED,
# non-default branch checked out in the given root. It is deliberately silent for
# every legitimate state - the primary on its default branch, and detached HEAD,
# which is how every linked worktree and secondmate home legitimately sits on the
# default branch. Detached HEAD on the default is fine; a feature branch in a
# primary checkout is the alarm.
#
# One case looks identical to that alarm but is not it: a linked worktree of the
# SAME repo - typically a secondmate home - can hold the default branch on a real
# branch rather than detached. Git permits one worktree per branch, so while that
# holder exists the primary CANNOT be on the default branch and no `git checkout
# <default>` remedy can ever succeed. fm_branch_holder_worktree identifies that
# holder so callers downgrade or suppress the alarm instead of prescribing an
# impossible fix forever.

# Resolve the default branch name of the git repo at <dir>: prefer origin/HEAD,
# then fall back to a local main/master. Echoes the name, or returns 1.
fm_default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
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

# If the git checkout at <root> is tangled - on a NAMED branch that is not its
# default branch - echo the offending branch name and return 0. For every healthy
# state (not a git work tree, detached HEAD, or already on the default branch)
# echo nothing and return 1. Detached HEAD is how linked worktrees and secondmate
# homes legitimately sit, so they never trip this; only a feature branch checked
# out in a primary checkout does.
fm_primary_tangle_branch() {
  local root=$1 cur default
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  default=$(fm_default_branch "$root") || return 1
  [ "$cur" = "$default" ] && return 1
  printf '%s\n' "$cur"
  return 0
}

# Echo the path of a worktree of the repo at <root> that currently has <branch>
# checked out and return 0; echo nothing and return 1 when none does. Callers
# only ask about a branch the given root is NOT on, so the root can never be
# reported as its own holder. A bare or detached worktree carries no branch line
# and is skipped.
fm_branch_holder_worktree() {
  local root=$1 branch=$2 line path=""
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) path=${line#worktree } ;;
      'branch refs/heads/'*)
        if [ "${line#branch refs/heads/}" = "$branch" ] && [ -n "$path" ]; then
          printf '%s\n' "$path"
          return 0
        fi
        ;;
    esac
  done <<EOF
$(git -C "$root" worktree list --porcelain 2>/dev/null)
EOF
  return 1
}
