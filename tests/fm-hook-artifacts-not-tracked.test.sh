#!/usr/bin/env bash
# Per-task worktree-resident hook artifacts (bin/fm-spawn.sh's busy-hook
# install; bin/fm-teardown.sh's matching scrub) must never be committed to the
# firstmate repo. Each one binds one task incarnation's id and busy-gen; if one
# is ever accidentally tracked (a plain `git add -A` sweeps it in, same as
# happened once with .claude/settings.local.json), every future worktree - a
# fresh clone or a treehouse pool worktree handed back for reuse - checks out
# that stale content as its baseline. fm-spawn.sh's own unconditional
# hook-rewrite then papers over it in the live working tree, but the
# underlying tracked blob keeps re-seeding every new checkout with a dead
# task's id/gen, and any step that resets the worktree to HEAD before that
# rewrite runs re-exposes the stale hook directly.
#
# This is a repo-hygiene guard, not a fm-spawn.sh logic test - it protects the
# same invariant that tests/fm-spawn-reused-worktree-hooks.test.sh proves for
# fm-spawn.sh's own write path, but against the file becoming tracked in the
# first place, which a synthetic fixture repo can never reproduce.
set -u

# fm-spawn.sh enrolls the spawned agent with the live parlay relay unless this
# is set, and that listener outlives the test (robots-4nkn). Tests that source
# tests/lib.sh inherit the guard; this file rolls its own boilerplate, so it
# sets it directly.
export FM_SPAWN_SKIP_PARLAY=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# Keep in sync with the exclude_path() call sites in bin/fm-spawn.sh and the
# rm -f scrub list in bin/fm-teardown.sh.
HOOK_ARTIFACTS="
.claude/settings.local.json
.opencode/plugins/fm-busy-state.js
.opencode/plugins/fm-turn-end.js
.fm-grok-turnend
.fm-kimi-turnend
"

test_hook_artifacts_gitignored() {
  local path
  for path in $HOOK_ARTIFACTS; do
    git -C "$ROOT" check-ignore -q "$path" \
      || fail "git does not ignore $path (a per-task hook artifact must be gitignored so it can never be committed)"
  done
  pass "every per-task hook artifact path is gitignored"
}

test_hook_artifacts_never_tracked() {
  local path tracked
  for path in $HOOK_ARTIFACTS; do
    tracked=$(git -C "$ROOT" ls-files -- "$path")
    [ -z "$tracked" ] \
      || fail "$path is tracked in git - a committed per-task hook artifact freezes one task's stale hooks into every future worktree checkout"
  done
  pass "no per-task hook artifact is tracked in the repo"
}

test_unrelated_claude_settings_stays_tracked() {
  # Control: the shared, non-per-task .claude/settings.json must remain
  # tracked and visible, so the coverage above is proven by contrast rather
  # than an overreaching ignore rule swallowing all of .claude/.
  local tracked
  tracked=$(git -C "$ROOT" ls-files -- .claude/settings.json)
  [ -n "$tracked" ] \
    || fail ".claude/settings.json is not tracked (the ignore rule must not overreach into all of .claude/)"
  git -C "$ROOT" check-ignore -q .claude/settings.json \
    && fail "git unexpectedly ignores .claude/settings.json (the shared, non-per-task settings file)"
  pass "the shared .claude/settings.json stays tracked and visible"
}

test_hook_artifacts_gitignored
test_hook_artifacts_never_tracked
test_unrelated_claude_settings_stays_tracked

echo "all fm-hook-artifacts-not-tracked tests passed"
