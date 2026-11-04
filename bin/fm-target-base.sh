#!/usr/bin/env bash
# fm-target-base.sh - anchor and check a ship branch against the repository its
# pull request targets, when that repository is not the clone's own origin.
#
# Usage: fm-target-base.sh anchor <host>/<owner>/<repo> [--url <git-url>]
#        fm-target-base.sh check  <host>/<owner>/<repo> [--url <git-url>] [--allow <glob>]...
#
# A task recorded with --upstream-consent (bin/fm-brief.sh) publishes to that
# repository's default branch. The clone's origin is often a fork whose main
# carries commits the target never saw, and the no-mistakes pipeline rebases
# onto origin's default branch, so a branch built or validated against the fork
# lands in the target PR with the fork's extra history. This script is the
# worker's guard for the direct-PR path: it measures against the target itself.
#
# anchor fetches the target's default branch and moves the current branch onto
# it. It drops only history already published on a remote (the fork's own
# commits) and refuses on unpublished commits or uncommitted changes, so it
# never discards work; run it on the fresh task branch before editing.
# check fetches the same branch and refuses unless the target's tip is an
# ancestor of HEAD, then prints the commits and files HEAD adds beyond the
# target. With --allow, a changed file matching none of the shell globs is also
# refused, so an intended-files list turns the manual diff review into a gate.
# Run check before every push.
#
# The target is fetched from https://<scope> unless --url names another git
# location (a mirror or a local path). Nothing here pushes, and nothing touches a
# remote or git config: the fetch uses FETCH_HEAD only.
set -u

die() {
  echo "error: fm-target-base.sh: $*" >&2
  exit 1
}

[ "$#" -ge 2 ] || die "usage: fm-target-base.sh anchor|check <host>/<owner>/<repo> [--url <git-url>] [--allow <glob>]..."
CMD=$1
SCOPE=$2
shift 2
case $CMD in
anchor | check) ;;
*) die "unknown subcommand '$CMD' (expected anchor or check)" ;;
esac
case $SCOPE in
*/*/*) ;;
*) die "target must be <host>/<owner>/<repo> (got '$SCOPE')" ;;
esac

URL=https://$SCOPE
ALLOW=()
while [ "$#" -gt 0 ]; do
  case $1 in
  --url)
    [ "$#" -ge 2 ] || die "--url requires a git location"
    URL=$2
    shift 2
    ;;
  --allow)
    [ "$CMD" = check ] || die "--allow applies only to check"
    [ "$#" -ge 2 ] || die "--allow requires a glob"
    ALLOW+=("$2")
    shift 2
    ;;
  *) die "unknown argument '$1'" ;;
  esac
done

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git worktree"

# The target's own default branch, never origin's.
head_ref=$(git ls-remote --symref "$URL" HEAD 2>/dev/null | awk '$1 == "ref:" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
[ -n "$head_ref" ] || die "cannot read the default branch of $URL"
git fetch --quiet "$URL" "$head_ref" || die "cannot fetch $head_ref from $URL"
TIP=$(git rev-parse --verify "FETCH_HEAD^{commit}") || die "fetch of $head_ref from $URL left no commit"

if [ "$CMD" = anchor ]; then
  git rev-parse --verify HEAD >/dev/null 2>&1 || die "no commit to anchor"
  if git merge-base --is-ancestor "$TIP" HEAD 2>/dev/null; then
    echo "anchored: HEAD already contains $SCOPE $head_ref ($TIP)"
    exit 0
  fi
  # Only history that already exists on a remote may be dropped: the fork's own
  # published commits are the thing being left behind, never task work.
  if [ -n "$(git rev-list -n 1 HEAD --not --remotes 2>/dev/null)" ]; then
    die "this branch carries unpublished commits; anchor only a fresh branch, and rebase real work onto $TIP yourself"
  fi
  [ -z "$(git status --porcelain 2>/dev/null)" ] || die "the worktree has uncommitted changes; anchor before editing"
  git reset --hard --quiet "$TIP" || die "cannot move the branch onto $TIP"
  echo "anchored: branch now at $SCOPE $head_ref ($TIP)"
  exit 0
fi

git merge-base --is-ancestor "$TIP" HEAD 2>/dev/null ||
  die "HEAD does not contain $SCOPE $head_ref ($TIP); the branch is built on another base - rebase it onto $TIP before any push"
commits=$(git rev-list --count "$TIP..HEAD")
files=$(git diff --name-only "$TIP" HEAD)
nfiles=$(printf '%s' "$files" | grep -c . || true)
echo "target: $SCOPE $head_ref ($TIP)"
echo "commits beyond target: $commits"
echo "files changed beyond target: $nfiles"
[ -z "$files" ] || printf '%s\n' "$files" | sed 's/^/  /'
if [ "${#ALLOW[@]}" -gt 0 ] && [ -n "$files" ]; then
  bad=
  while IFS= read -r f; do
    ok=0
    for g in "${ALLOW[@]}"; do
      # shellcheck disable=SC2254 # the allow list is deliberately a set of shell globs
      case $f in $g) ok=1 ;; esac
    done
    [ "$ok" -eq 1 ] || bad="$bad  $f"$'\n'
  done <<<"$files"
  [ -z "$bad" ] || die "files outside the intended set:"$'\n'"$bad"
fi
exit 0
