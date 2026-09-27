#!/usr/bin/env bash
# Regression test for the fm-spawn.sh stale-base drift warning (beads
# task-zr9gd): a recycled treehouse pool slot can sit at a commit behind the
# project's current default branch, and a worker branching from that HEAD
# silently builds on an obsolete base. That cost two wrong PRs in one day: a
# worker many commits stale reopened an already-landed mirror (duplicate PR
# #60), and a worker exactly one commit stale produced a PR conflicting
# against main with 802 deletions (PR #65). Neither worker made a mistake.
# fm-spawn.sh now freshens the remote refs after acquiring the worktree and
# prints one loud warning line when HEAD differs from the remote default
# branch, naming both commits, without touching the worktree. These tests
# drive that path end to end through a hermetic spawn: the "remote" is a
# local-path bare repo, so git fetch works fully offline with a fake tmux and
# a no-op treehouse standing in for the pool handoff.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-stale-base)

# A fake tmux that always reports FM_FAKE_PANE_PATH as the post-`treehouse
# get` pane cwd, names the session on '#S', and swallows window ops.
make_stale_base_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_origin_case <dir> builds a local-path bare origin, a project clone of
# it, and a detached worktree of the project parked at the older commit A
# while origin's main has since advanced to B. Echoes "origin|proj|wt|sha_a|sha_b".
make_origin_case() {
  local dir=$1 origin seed proj wt sha_a sha_b
  origin="$dir/origin.git"
  seed="$dir/seed"
  proj="$dir/proj"
  wt="$dir/wt"
  git init -q -b main --bare "$origin"
  git clone -q "$origin" "$seed" 2>/dev/null
  git -C "$seed" config user.name 'fmtest'
  git -C "$seed" config user.email 'fmtest@example.invalid'
  printf 'v1\n' > "$seed/file.txt"
  git -C "$seed" add file.txt
  git -C "$seed" commit -qm "commit A"
  git -C "$seed" push -q origin main
  sha_a=$(git -C "$seed" rev-parse HEAD)
  git clone -q "$origin" "$proj" 2>/dev/null
  git -C "$proj" worktree add -q --detach "$wt" "$sha_a"
  printf 'v2\n' > "$seed/file.txt"
  git -C "$seed" commit -qam "commit B"
  git -C "$seed" push -q origin main
  sha_b=$(git -C "$seed" rev-parse HEAD)
  printf '%s\n' "$origin|$proj|$wt|$sha_a|$sha_b"
}

run_stale_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" codex --mode no-mistakes --yolo off --model sonnet 2>&1
}

# A worktree parked at A while the freshly fetched origin/main is B must warn
# loudly, name both commits, and leave the worktree exactly as found: same
# HEAD, still detached, no new branch.
test_stale_head_warns_and_touches_nothing() {
  local rec proj_dir wt_dir sha_a sha_b home fakebin out status head_now
  rec=$(make_origin_case "$TMP_ROOT/stale")
  IFS='|' read -r _ proj_dir wt_dir sha_a sha_b <<EOF
$rec
EOF
  home="$TMP_ROOT/stale-home"
  mkdir -p "$home/data"
  fakebin=$(make_stale_base_fakebin "$TMP_ROOT/stale-fake")

  out=$(run_stale_spawn "$home" stale-warns-g1 "$proj_dir" "$wt_dir" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn onto a stale worktree should still succeed (the warning never blocks launch)"
  assert_contains "$out" "spawned stale-warns-g1" "stale spawn did not report success"
  assert_contains "$out" "warning: spawned worktree HEAD $sha_a differs from fresh origin/main $sha_b" \
    "stale spawn did not warn with both commits named"
  head_now=$(git -C "$wt_dir" rev-parse HEAD)
  [ "$head_now" = "$sha_a" ] || fail "warning path moved the worktree HEAD ($head_now != $sha_a)"
  git -C "$wt_dir" symbolic-ref -q HEAD >/dev/null 2>&1 \
    && fail "warning path checked out a branch in the worktree (expected to stay detached)"
  pass "fm-spawn: a stale worktree HEAD warns loudly with both commits and is left untouched"
}

# A worktree already sitting at the fresh remote default must stay silent: no
# warning line, just the ordinary successful spawn.
test_current_head_is_silent() {
  local rec proj_dir wt_dir sha_a sha_b home fakebin wt2 out status
  rec=$(make_origin_case "$TMP_ROOT/current")
  IFS='|' read -r _ proj_dir wt_dir sha_a sha_b <<EOF
$rec
EOF
  git -C "$proj_dir" fetch -q origin
  wt2="$TMP_ROOT/current/wt2"
  git -C "$proj_dir" worktree add -q --detach "$wt2" "$sha_b"
  home="$TMP_ROOT/current-home"
  mkdir -p "$home/data"
  fakebin=$(make_stale_base_fakebin "$TMP_ROOT/current-fake")

  out=$(run_stale_spawn "$home" current-silent-g2 "$proj_dir" "$wt2" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn onto a current worktree should succeed"
  assert_contains "$out" "spawned current-silent-g2" "current spawn did not report success"
  assert_not_contains "$out" "differs from fresh origin/" "current spawn wrongly warned on a matching HEAD"
  pass "fm-spawn: a current worktree HEAD stays silent"
}

test_stale_head_warns_and_touches_nothing
test_current_head_is_silent

echo "# all fm-spawn-stale-base tests passed"
