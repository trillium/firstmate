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
# non-default branch checked out in a root that is itself the PRIMARY checkout.
# It is deliberately silent for every legitimate state - the primary on its
# default branch, and any linked worktree whatever its HEAD. Linked worktrees are
# where feature branches BELONG: the sanctioned crew flow is
# `git worktree add <dir> -b <branch>`, which leaves the worktree on a named
# branch, so a named branch alone can never be the signal. Being the primary
# checkout is what makes it the alarm.

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

# Echo the absolute, symlink-resolved path git reports for <what> ("--git-dir" or
# "--git-common-dir") at <dir>, or return 1. git prints these RELATIVE to the
# working directory whenever it can (a plain `.git` in a primary checkout), so
# they must be resolved from <dir> before two of them can be compared.
fm_git_dir_path() {
  local dir=$1 what=$2 path
  path=$(git -C "$dir" rev-parse "$what" 2>/dev/null) || return 1
  [ -n "$path" ] || return 1
  (cd "$dir" 2>/dev/null && cd "$path" 2>/dev/null && pwd -P) || return 1
}

# True when <root> is the PRIMARY checkout of its repo rather than a linked
# `git worktree`. Every linked worktree gets its own per-worktree git dir
# (<common>/worktrees/<name>) distinct from the shared common dir; in the primary
# checkout the two resolve to the same directory. This is the check that scopes
# the tangle alarm - without it, `git worktree add <dir> -b <branch>` (the
# sanctioned crew flow) trips the alarm on every fleet action from inside the
# worktree.
fm_is_primary_checkout() {
  local root=$1 gitdir commondir
  gitdir=$(fm_git_dir_path "$root" --git-dir) || return 1
  commondir=$(fm_git_dir_path "$root" --git-common-dir) || return 1
  [ "$gitdir" = "$commondir" ]
}

# If the git checkout at <root> is tangled - a PRIMARY checkout sitting on a
# NAMED branch that is not its default branch - echo the offending branch name and
# return 0. For every healthy state (not a git work tree, a linked worktree,
# detached HEAD, or already on the default branch) echo nothing and return 1. A
# linked worktree on a feature branch is the sanctioned crew flow, not a tangle,
# so only the primary checkout can trip this.
fm_primary_tangle_branch() {
  local root=$1 cur default
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  fm_is_primary_checkout "$root" || return 1
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  default=$(fm_default_branch "$root") || return 1
  [ "$cur" = "$default" ] && return 1
  printf '%s\n' "$cur"
  return 0
}
