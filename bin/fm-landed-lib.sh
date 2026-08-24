# shellcheck shell=bash
# fm-landed-lib.sh - single owner of the "has this work LANDED" predicate.
#
# Why this is its own library: the predicate used to live inside
# bin/fm-teardown.sh, a mutating script a side-effect-free reader (like
# bin/fm-crew-state.sh) must not source. The extraction to this pure,
# function-only library is the earliest shared boundary: sourcing it defines
# functions and performs no other work, so any reader can load it safely.
# bin/fm-teardown.sh sources it and binds its own globals through thin wrappers;
# bin/fm-crew-state.sh sources it to answer the same question its closed-bead
# gate asks (is a closed bead completion evidence, or did the work never land).
#
# "Landed" means the worktree's committed work is reachable from a remote, OR -
# for a normal ship task whose commits are not so reachable - its PR is merged and
# GitHub reports a PR head that contains the current local work, or its content is
# already present in the up-to-date default branch. This recognizes the common
# squash-merge-then-delete-branch flow, where the branch's own commits live nowhere
# on a remote yet the change is fully in main.
#
# Every function here is read-only except fm_landed_content_in_default, which
# fetches the default branch into the worktree's remote-tracking ref (the same
# read-modify of the remote that teardown performs) so the content comparison is
# against an up-to-date default branch. Each probe fails closed: any lookup,
# fetch, or git operation that cannot answer returns non-zero, which the caller
# treats as unlanded rather than guessing.
#
# Functions take the worktree dir and (where needed) the project dir explicitly;
# no function depends on ambient globals, so the same code serves teardown,
# crew-state, and any future reader with a different variable naming scheme.
#
#   fm_work_is_landed <wt> <proj> <branch> [pr_url]   -> 0 landed, 1 not landed
#   fm_landed_pr_is_merged <wt> <branch> [pr_url]
#   fm_landed_content_in_default <wt> <proj>
#   fm_landed_default_branch <proj>
#   fm_landed_pr_number_from_branch <wt> <branch>
#   fm_landed_pr_number_from_target <target>
#   fm_landed_ensure_commit_object <wt> <target> <commit>
#   fm_landed_patch_id_for_commit <wt> <commit>
#   fm_landed_unpushed_patches_are_in_pr_head <wt> <pr_head>
#   fm_landed_squash_merged_pr_contains_work <wt> <pr_head>

# Resolve the default branch name for a project checkout: the remote HEAD symbolic
# ref when present, else a local main/master branch. Non-zero when neither exists.
fm_landed_default_branch() {  # <proj>
  local proj=$1 ref branch
  ref=$(git -C "$proj" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
fm_landed_pr_number_from_branch() {  # <wt> <branch>
  local wt=$1 branch=$2 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$wt" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Extract a PR number from a PR URL or bare number. Pure string parse, no git.
fm_landed_pr_number_from_target() {  # <target>
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Make sure a commit object exists locally, fetching the PR head ref when it does
# not (e.g. the head branch was deleted after a squash merge).
fm_landed_ensure_commit_object() {  # <wt> <target> <commit>
  local wt=$1 target=$2 commit=$3 n
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_landed_pr_number_from_target "$target") || return 1
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$wt" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null
}

fm_landed_patch_id_for_commit() {  # <wt> <commit>
  local wt=$1 commit=$2
  git -C "$wt" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

# True when every unpushed local commit's patch-id appears in the merged PR head,
# i.e. the local work was replayed (rather than the original commits reachable).
fm_landed_unpushed_patches_are_in_pr_head() {  # <wt> <pr_head>
  local wt=$1 pr_head=$2 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$wt" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$wt" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          fm_landed_patch_id_for_commit "$wt" "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$wt" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(fm_landed_patch_id_for_commit "$wt" "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# True when 3-way merging the PR head with HEAD yields the PR head's tree, i.e. the
# squash-merged PR already contains the worktree's content.
fm_landed_squash_merged_pr_contains_work() {  # <wt> <pr_head>
  local wt=$1 pr_head=$2 pr_tree merged_tree
  pr_tree=$(git -C "$wt" rev-parse --quiet --verify "$pr_head^{tree}" 2>/dev/null) || return 1
  [ -n "$pr_tree" ] || return 1
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$pr_head" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$pr_tree" ]
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks GitHub
# for both the PR state and head. Returns non-zero when the PR is not merged, the
# current work is not contained in the PR head, no PR is found, or any gh error
# occurs - the caller then falls back to the content check.
fm_landed_pr_is_merged() {  # <wt> <branch> [pr_url]
  local wt=$1 branch=$2 pr_url=${3:-} target view state head current
  if [ -n "$pr_url" ]; then
    target=$pr_url
  else
    target=$(fm_landed_pr_number_from_branch "$wt" "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$wt" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  fm_landed_ensure_commit_object "$wt" "$target" "$head" || return 1
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$wt" merge-base --is-ancestor "$current" "$head" 2>/dev/null && return 0
  fm_landed_unpushed_patches_are_in_pr_head "$wt" "$head" && return 0
  fm_landed_squash_merged_pr_contains_work "$wt" "$head"
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns non-zero when inconclusive (no default ref, or a merge conflict),
# so the caller refuses rather than guesses.
fm_landed_content_in_default() {  # <wt> <proj>
  local wt=$1 proj=$2 name ref default_tree merged_tree
  name=$(fm_landed_default_branch "$proj") || return 1
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    git -C "$wt" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$wt" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths). False
# only for genuinely unlanded work.
fm_work_is_landed() {  # <wt> <proj> <branch> [pr_url]
  local wt=$1 proj=$2 branch=$3 pr_url=${4:-}
  fm_landed_pr_is_merged "$wt" "$branch" "$pr_url" && return 0
  fm_landed_content_in_default "$wt" "$proj"
}
