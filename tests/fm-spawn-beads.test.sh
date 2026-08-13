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
    "$SPAWN" --mode no-mistakes --yolo off "$id" "$PROJ_DIR" "$@" 2>&1
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

# add_beads_task_mock_full <fakebin_dir> <calls_log> <minted_id>: a fake `task`
# CLI covering both fm_beads_resolve_or_create's lookup/mint calls (list/create)
# and fm-bead-stamp.sh's claim-lifecycle calls (show/set-state/assign). `list`
# always reports no existing bead, so `create` mints <minted_id>.
add_beads_task_mock_full() {
  local fakebin_dir=$1 calls_log=$2 minted_id=$3
  cat > "$fakebin_dir/task" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls_log"
case "\$1" in
  list) printf '[]\n' ;;
  create) printf '%s\n' "$minted_id" ;;
esac
exit 0
SH
  chmod +x "$fakebin_dir/task"
}

# Test: under config/backlog-backend=beads (beads-authority migration Stage 3),
# a spawn with NO --beads flag still resolves/mints a bead and records it as
# beads_id= in the task's meta, and the dispatch=sent/lifecycle=sent stamp still
# fires - bead-linking is automatic, not opt-in, under this backend.
test_spawn_under_beads_backend_auto_links_without_flag() {
  local rec id out calls_log
  id=spawn-beads-auto-z3
  rec=$(make_spawn_case spawn-beads-auto "$id")
  read_spawn_record "$rec"
  printf 'beads\n' > "$HOME_DIR/config/backlog-backend"
  calls_log="$CASE_DIR/task-calls.log"
  add_beads_task_mock_full "$FAKEBIN_DIR" "$calls_log" "bead-auto-9"

  out=$(run_case_spawn "$id")
  expect_code 0 "$?" "spawn should succeed under the beads backend without --beads"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  assert_grep 'beads_id=bead-auto-9' "$HOME_DIR/state/$id.meta" \
    "spawn under the beads backend did not auto-record beads_id= without --beads"

  for _ in $(seq 1 30); do grep -q 'set-state bead-auto-9 lifecycle=sent' "$calls_log" 2>/dev/null && break; sleep 0.1; done
  assert_grep "list --label task:$id --all --limit 20 --json" "$calls_log" \
    "spawn did not resolve the bead via its task:<id> label under the beads backend"
  assert_grep "set-state bead-auto-9 dispatch=sent" "$calls_log" \
    "fm-bead-stamp.sh did not stamp dispatch=sent on the auto-linked bead"
  assert_grep "set-state bead-auto-9 lifecycle=sent" "$calls_log" \
    "fm-bead-stamp.sh did not stamp lifecycle=sent on the auto-linked bead"
  pass "a spawn under config/backlog-backend=beads auto-links a bead (no --beads needed) and stamps dispatch=sent/lifecycle=sent"
}

# Test: an explicit --beads flag still wins over auto-resolution under the beads
# backend, and no second bead is minted for the task.
test_spawn_under_beads_backend_explicit_beads_wins() {
  local rec id out calls_log
  id=spawn-beads-explicit-z4
  rec=$(make_spawn_case spawn-beads-explicit "$id")
  read_spawn_record "$rec"
  printf 'beads\n' > "$HOME_DIR/config/backlog-backend"
  calls_log="$CASE_DIR/task-calls.log"
  add_beads_task_mock_full "$FAKEBIN_DIR" "$calls_log" "bead-should-not-be-used"

  out=$(run_case_spawn "$id" --beads bead-explicit-1)
  expect_code 0 "$?" "spawn should succeed with --beads set under the beads backend"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  assert_grep 'beads_id=bead-explicit-1' "$HOME_DIR/state/$id.meta" \
    "an explicit --beads id was not preserved under the beads backend"
  grep -q '^beads_id=bead-should-not-be-used$' "$HOME_DIR/state/$id.meta" 2>/dev/null \
    && fail "spawn ignored the explicit --beads id and used an auto-resolved bead instead"
  assert_no_grep "list --label task:$id" "$calls_log" \
    "spawn resolved/minted a bead via auto-lookup despite an explicit --beads flag"
  pass "an explicit --beads id wins over auto-resolution under the beads backend"
}

# Test: an auto-linked spawn (beads backend, no --beads flag) must inject the
# Bead Receipt/Closure hook sections into the already-scaffolded brief, since
# fm-brief.sh ran before a bead existed and its own hook loop never fired.
test_spawn_under_beads_backend_auto_links_injects_bead_hook_sections() {
  local rec id out setup_line receipt_line
  id=spawn-beads-hooksect-z5
  rec=$(make_spawn_case spawn-beads-hooksect "$id")
  read_spawn_record "$rec"
  printf 'beads\n' > "$HOME_DIR/config/backlog-backend"
  add_beads_task_mock_full "$FAKEBIN_DIR" "$CASE_DIR/task-calls.log" "bead-hooksect-1"
  cat > "$HOME_DIR/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
{TASK}

# Setup
You are in a disposable git worktree.
EOF

  out=$(run_case_spawn "$id")
  expect_code 0 "$?" "spawn should succeed under the beads backend without --beads"

  assert_grep '# Bead Receipt' "$HOME_DIR/data/$id/brief.md" \
    "auto-linked spawn did not inject the Bead Receipt section into the brief"
  assert_grep '# Bead Closure' "$HOME_DIR/data/$id/brief.md" \
    "auto-linked spawn did not inject the Bead Closure section into the brief"
  assert_grep 'bead-hooksect-1' "$HOME_DIR/data/$id/brief.md" \
    "injected bead hook sections did not reference the auto-resolved bead id"

  setup_line=$(grep -n '^# Setup$' "$HOME_DIR/data/$id/brief.md" | head -1 | cut -d: -f1)
  receipt_line=$(grep -n '^# Bead Receipt$' "$HOME_DIR/data/$id/brief.md" | head -1 | cut -d: -f1)
  [ -n "$setup_line" ] && [ -n "$receipt_line" ] && [ "$receipt_line" -lt "$setup_line" ] \
    || fail "Bead Receipt section was not inserted before # Setup"

  pass "an auto-linked spawn injects the Bead Receipt/Closure sections into the brief before # Setup"
}

# Test: an explicit --beads spawn must not duplicate the hook sections that
# fm-brief.sh already rendered at scaffold time (its caller pre-set
# FM_HOOK_BEADS_ID before scaffolding).
test_spawn_explicit_beads_does_not_duplicate_hook_sections() {
  local rec id out receipt_count
  id=spawn-beads-nodupe-z6
  rec=$(make_spawn_case spawn-beads-nodupe "$id")
  read_spawn_record "$rec"
  printf 'beads\n' > "$HOME_DIR/config/backlog-backend"
  add_beads_task_mock_full "$FAKEBIN_DIR" "$CASE_DIR/task-calls.log" "bead-should-not-be-used"
  cat > "$HOME_DIR/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
{TASK}

# Bead Receipt
This task is linked to bead `bead-explicit-2`.

# Bead Closure
Close bead `bead-explicit-2` when done.

# Setup
You are in a disposable git worktree.
EOF

  out=$(run_case_spawn "$id" --beads bead-explicit-2)
  expect_code 0 "$?" "spawn should succeed with --beads set under the beads backend"

  receipt_count=$(grep -c '^# Bead Receipt$' "$HOME_DIR/data/$id/brief.md")
  [ "$receipt_count" -eq 1 ] \
    || fail "explicit --beads spawn duplicated the Bead Receipt section (count=$receipt_count)"
  pass "an explicit --beads spawn does not duplicate the brief's already-scaffolded hook sections"
}

test_spawn_beads_records_meta_and_stamps_bead
test_spawn_without_beads_flag_omits_meta_and_skips_stamp
test_spawn_under_beads_backend_auto_links_without_flag
test_spawn_under_beads_backend_explicit_beads_wins
test_spawn_under_beads_backend_auto_links_injects_bead_hook_sections
test_spawn_explicit_beads_does_not_duplicate_hook_sections

echo "# all fm-spawn-beads tests passed"
