#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's --beads <id> wiring: the id is recorded as
# beads_id= in the task's meta, and fm-bead-stamp.sh is invoked with it after
# a confirmed spawn (see bin/fm-spawn.sh's header and its --beads section).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-beads)

# make_spawn_fakebin <dir>: a fake tmux that always reports FM_FAKE_PANE_PATH
# for pane_current_path (an already-settled pane, no staleness), plus exit-0
# treehouse. Mirrors fm-spawn-parlay.test.sh's already-settled case.
make_spawn_fakebin() {
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
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <id>: a home + primary project with a real worktree
# (the pane's reported cwd) and a brief, ready for a successful spawn.
make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_case_spawn() {
  local id=$1; shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$@" 2>&1
}

# Mock `task` (the beads CLI) as fm-bead-stamp.sh calls it: logs every
# invocation and always succeeds.
add_beads_task_mock() {
  local fakebin_dir=$1 calls_log=$2
  cat > "$fakebin_dir/task" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls_log"
exit 0
SH
  chmod +x "$fakebin_dir/task"
}

test_spawn_beads_records_meta_and_stamps_bead() {
  local rec id out calls_log
  id=spawn-beads-present-z1
  rec=$(make_spawn_case spawn-beads-present "$id")
  read_spawn_record "$rec"
  calls_log="$CASE_DIR/task-calls.log"
  add_beads_task_mock "$FAKEBIN_DIR" "$calls_log"

  out=$(run_case_spawn "$id" --beads bead-42)
  expect_code 0 "$?" "spawn should succeed with --beads set"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  assert_grep 'beads_id=bead-42' "$HOME_DIR/state/$id.meta" \
    "spawn did not record beads_id=bead-42 in the task's meta"

  for _ in $(seq 1 30); do [ -s "$calls_log" ] && break; sleep 0.1; done
  assert_grep "show bead-42" "$calls_log" \
    "fm-bead-stamp.sh did not invoke 'task show bead-42'"
  assert_grep "set-state bead-42 dispatch=sent" "$calls_log" \
    "fm-bead-stamp.sh did not stamp dispatch=sent on bead-42"
  assert_grep "set-state bead-42 lifecycle=sent" "$calls_log" \
    "fm-bead-stamp.sh did not stamp lifecycle=sent on bead-42"
  pass "a spawn with --beads <id> records beads_id= in meta and stamps the bead dispatch=sent/lifecycle=sent"
}

test_spawn_without_beads_flag_omits_meta_and_skips_stamp() {
  local rec id out calls_log
  id=spawn-beads-absent-z2
  rec=$(make_spawn_case spawn-beads-absent "$id")
  read_spawn_record "$rec"
  calls_log="$CASE_DIR/task-calls.log"
  add_beads_task_mock "$FAKEBIN_DIR" "$calls_log"

  out=$(run_case_spawn "$id")
  expect_code 0 "$?" "spawn should succeed without --beads"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  grep -q '^beads_id=' "$HOME_DIR/state/$id.meta" 2>/dev/null \
    && fail "spawn recorded a beads_id= despite no --beads flag"
  [ -e "$calls_log" ] \
    && fail "fm-bead-stamp.sh was invoked despite no --beads flag: $(cat "$calls_log")"
  pass "a spawn without --beads records no beads_id= and never invokes the bead stamp"
}

test_spawn_beads_records_meta_and_stamps_bead
test_spawn_without_beads_flag_omits_meta_and_skips_stamp

echo "# all fm-spawn-beads tests passed"
