#!/usr/bin/env bash
# Regression test: when treehouse hands fm-spawn.sh a REUSED, pooled worktree
# (the same on-disk path a prior, now-torn-down task used), the claude
# busy-hook contract fm-spawn.sh installs into that worktree
# (.claude/settings.local.json) must reference the CURRENT task's own id and
# busy-gen only. A stale hook still naming the PRIOR tenant would let the new
# task's Claude session keep touching the old task's turn-ended marker and
# reporting busy/idle under the old task's id, confusing the watcher's
# liveness tracking. bin/fm-spawn.sh's hook-install writes are unconditional
# (`cat >`, truncate-and-rewrite) and bin/fm-teardown.sh scrubs the same
# artifacts before a worktree returns to the pool; this test exercises the
# real spawn -> teardown -> respawn-into-the-same-worktree sequence end to end
# to prove neither path leaves or reintroduces a stale hook.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-reused-worktree-hooks)

make_fakebin() {
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
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi opencode claude codex gh-axi gh
  printf '%s\n' "$fakebin"
}

# One home + project + worktree shared across two successive spawns, modeling
# treehouse returning the identical pooled worktree path for an unrelated
# second task after the first task's teardown returns it to the pool.
CASE_DIR="$TMP_ROOT/reuse"
HOME_DIR="$CASE_DIR/home"
PROJ_DIR="$CASE_DIR/project"
WT_DIR="$CASE_DIR/wt"
FAKEBIN_DIR=$(make_fakebin "$CASE_DIR/fake")
mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-reuse"
touch "$HOME_DIR/state/.last-watcher-beat"

ID_A=reuse-hooks-a1
ID_B=reuse-hooks-b2
mkdir -p "$HOME_DIR/data/$ID_A" "$HOME_DIR/data/$ID_B"
printf 'brief for %s\n' "$ID_A" > "$HOME_DIR/data/$ID_A/brief.md"
printf 'brief for %s\n' "$ID_B" > "$HOME_DIR/data/$ID_B/brief.md"

run_spawn() {  # <id>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" --mode no-mistakes --yolo off "$1" "$PROJ_DIR" 2>&1
}

run_teardown() {  # <id>
  FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$1" 2>&1
}

run_claude_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd"
}

test_reused_pool_worktree_gets_fresh_hooks_not_prior_tenants() {
  local out settings state gen_a gen_b

  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"

  out=$(run_spawn "$ID_A")
  expect_code 0 $? "spawn A should succeed: $out"
  assert_present "$settings" "spawn A did not write hook settings"
  assert_grep "$ID_A" "$settings" "A's hooks do not reference A's own id"
  gen_a=$(cat "$state/$ID_A.busy-gen")

  out=$(run_teardown "$ID_A")
  expect_code 0 $? "teardown A should succeed: $out"
  assert_absent "$settings" "teardown left a stale settings.local.json in the pooled worktree"
  assert_absent "$state/$ID_A.meta" "teardown did not remove A's meta"

  # treehouse hands the exact same worktree path back out for the unrelated
  # second task - FM_FAKE_PANE_PATH stays pointed at the same $WT_DIR to model
  # the reuse-pool scenario.
  out=$(run_spawn "$ID_B")
  expect_code 0 $? "spawn B into the reused worktree should succeed: $out"
  assert_present "$settings" "spawn B did not write hook settings into the reused worktree"
  gen_b=$(cat "$state/$ID_B.busy-gen")
  [ "$gen_b" != "$gen_a" ] || fail "B armed the same busy-gen as A; incarnations must be distinguishable"

  assert_grep "$ID_B" "$settings" "B's hooks do not reference B's own id"
  assert_no_grep "$ID_A" "$settings" \
    "B's hooks still reference A's id - stale hook inheritance from the reused worktree"
  assert_no_grep "$gen_a" "$settings" \
    "B's hooks still embed A's busy-gen - stale hook inheritance from the reused worktree"

  # Firing B's Stop hook must only ever touch B's own turn-ended marker, never
  # resurrect A's.
  rm -f "$state/$ID_A.turn-ended" "$state/$ID_B.turn-ended"
  run_claude_hook "$settings" Stop || fail "B's Stop hook command failed"
  assert_present "$state/$ID_B.turn-ended" "B's Stop hook did not touch B's own turn-ended marker"
  assert_absent "$state/$ID_A.turn-ended" \
    "B's Stop hook touched A's (dead) turn-ended marker - stale hook inheritance"

  pass "fm-spawn.sh refreshes claude hooks to the current task's id and busy-gen when reusing a pooled worktree, never inheriting the prior tenant's"
}

test_reused_pool_worktree_gets_fresh_hooks_not_prior_tenants

echo "all fm-spawn-reused-worktree-hooks tests passed"
