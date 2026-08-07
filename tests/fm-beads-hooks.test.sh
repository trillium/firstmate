#!/usr/bin/env bash
# Behavior tests for the beads lifecycle hook feature: bin/fm-bead-stamp.sh,
# the --beads flag on fm-brief.sh and fm-spawn.sh, and the fm-brief-hooks.d/
# and fm-spawn-hooks.d/ extension points that carry the bead-specific logic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STAMP="$ROOT/bin/fm-bead-stamp.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-beads-hooks)

make_fake_task() {
  local dir=$1 fakebin log
  fakebin=$(fm_fakebin "$dir")
  log="$dir/task-calls.log"
  cat > "$fakebin/task" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$log"
case "\${1:-}" in
  show)
    case "\${2:-}" in
      task-missing) exit 1 ;;
      task-closed) printf '{"id":"%s","status":"closed"}\n' "\$2" ;;
      *) printf '{"id":"%s","status":"open"}\n' "\${2:-}" ;;
    esac
    exit 0
    ;;
  set-state|assign) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/task"
  printf '%s|%s\n' "$fakebin" "$log"
}

# --- fm-bead-stamp.sh: fail-open behavior -----------------------------------

test_stamp_fails_open_on_empty_id() {
  local out status
  out=$("$STAMP" "" agent-1 2>&1); status=$?
  expect_code 0 "$status" "empty beads id should exit 0"
  assert_contains "$out" "no bead id given" "empty-id stamp did not warn"
  pass "fm-bead-stamp.sh: empty beads id warns and exits 0"
}

test_stamp_fails_open_without_task_cli() {
  local out status
  out=$(PATH=/usr/bin:/bin "$STAMP" task-123 agent-1 2>&1); status=$?
  expect_code 0 "$status" "missing task CLI should exit 0"
  assert_contains "$out" "task CLI not found" "missing-CLI stamp did not warn"
  pass "fm-bead-stamp.sh: missing task CLI warns and exits 0"
}

test_stamp_fails_open_on_missing_bead() {
  local case_dir fakebin_log fakebin out status
  case_dir="$TMP_ROOT/stamp-missing"
  fakebin_log=$(make_fake_task "$case_dir")
  fakebin=${fakebin_log%%|*}
  out=$(PATH="$fakebin:$PATH" "$STAMP" task-missing agent-1 2>&1); status=$?
  expect_code 0 "$status" "bead not found should exit 0"
  assert_contains "$out" "bead task-missing not found" "not-found stamp did not warn"
  pass "fm-bead-stamp.sh: bead the task CLI cannot find warns and exits 0"
}

test_stamp_sets_dispatch_and_assigns() {
  local case_dir fakebin_log fakebin log status
  case_dir="$TMP_ROOT/stamp-ok"
  fakebin_log=$(make_fake_task "$case_dir")
  fakebin=${fakebin_log%%|*}
  log=${fakebin_log##*|}
  PATH="$fakebin:$PATH" "$STAMP" task-open agent-1 >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "successful stamp should exit 0"
  assert_grep "set-state task-open dispatch=sent" "$log" "stamp did not set dispatch=sent"
  assert_grep "assign task-open agent-1" "$log" "stamp did not assign the bead"
  pass "fm-bead-stamp.sh: stamps dispatch=sent and assigns the bead"
}

# --- fm-brief.sh --beads: fm-brief-hooks.d/beads.sh -------------------------

test_brief_beads_renders_receipt_and_closure_once() {
  local home id brief
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  id="brief-beads-a1"
  FM_HOME="$home" "$BRIEF" "$id" some-proj --mode no-mistakes --beads task-hzqq >/dev/null 2>&1 \
    || fail "fm-brief.sh --beads should exit 0"
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "# Bead Receipt" "$brief" "brief missing Bead Receipt section"
  # shellcheck disable=SC2016
  assert_grep 'task set-state task-hzqq dispatch=claimed' "$brief" \
    "brief missing the dispatch=claimed receipt command"
  assert_grep "# Bead Closure" "$brief" "brief missing Bead Closure section"
  # shellcheck disable=SC2016
  assert_grep 'task close task-hzqq' "$brief" "brief missing the bead-close instruction"
  [ "$(grep -c '# Bead Receipt' "$brief")" -eq 1 ] || fail "Bead Receipt section must appear exactly once"
  [ "$(grep -c '# Bead Closure' "$brief")" -eq 1 ] || fail "Bead Closure section must appear exactly once"
  pass "fm-brief.sh: --beads renders one Bead Receipt and one Bead Closure section via the hook"
}

test_brief_without_beads_has_no_bead_content() {
  local home id brief
  home="$TMP_ROOT/brief-nobeads-home"
  mkdir -p "$home/data"
  id="brief-nobeads-a2"
  FM_HOME="$home" "$BRIEF" "$id" some-proj --mode no-mistakes >/dev/null 2>&1 || fail "fm-brief.sh should exit 0"
  brief="$home/data/$id/brief.md"
  assert_no_grep "Bead" "$brief" "brief without --beads must carry no bead content"
  pass "fm-brief.sh: omitting --beads leaves no bead content behind"
}

test_brief_beads_rejected_for_secondmate() {
  local home out status
  home="$TMP_ROOT/brief-secondmate-home"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" "$BRIEF" brief-beads-sm-a3 --secondmate --no-projects --beads task-xyz 2>&1); status=$?
  expect_code 1 "$status" "--beads with --secondmate should be refused"
  assert_contains "$out" "applies only to crewmate ship or scout briefs" "secondmate refusal message missing"
  pass "fm-brief.sh: --beads is refused for secondmate charters"
}

test_brief_beads_rejects_invalid_id() {
  local home out status
  home="$TMP_ROOT/brief-invalid-home"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" "$BRIEF" brief-beads-bad-a4 some-proj --mode no-mistakes --beads 'bad id!' 2>&1); status=$?
  expect_code 1 "$status" "an invalid --beads id should be refused"
  assert_contains "$out" "invalid --beads id" "invalid-id refusal message missing"
  pass "fm-brief.sh: --beads rejects an id with disallowed characters"
}

# --- fm-spawn.sh --beads: flag parsing and meta ------------------------------

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
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi-signed
  printf '%s\n' "$fakebin"
}

test_spawn_records_beads_id_in_meta_and_runs_hook() {
  local case_dir home proj wt fakebin id task_fakebin_log task_fakebin task_log out status
  case_dir="$TMP_ROOT/spawn-beads"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=spawn-beads-a5
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  task_fakebin_log=$(make_fake_task "$case_dir/fake-task")
  task_fakebin=${task_fakebin_log%%|*}
  task_log=${task_fakebin_log##*|}
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$task_fakebin:$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off --beads task-open 2>&1); status=$?

  expect_code 0 "$status" "ship spawn with --beads should exit 0 (got: $out)"
  assert_grep "beads_id=task-open" "$home/state/$id.meta" "meta missing beads_id="
  assert_grep "set-state task-open dispatch=sent" "$task_log" \
    "post-spawn hook did not stamp the bead through the real fm-spawn-hooks.d/beads.sh"
  pass "fm-spawn.sh: --beads records beads_id= in meta and runs the post-spawn stamp hook"
}

test_spawn_beads_rejected_for_secondmate() {
  local case_dir home out status
  case_dir="$TMP_ROOT/spawn-sm-beads"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/state"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" spawn-sm-beads-a6 --secondmate --beads task-xyz 2>&1); status=$?
  expect_code 1 "$status" "--beads with --secondmate should be refused"
  assert_contains "$out" "applies only to crewmate ship or scout tasks" "spawn secondmate refusal message missing"
  pass "fm-spawn.sh: --beads is refused for --secondmate"
}

test_spawn_beads_rejects_invalid_id() {
  local case_dir home out status
  case_dir="$TMP_ROOT/spawn-invalid-beads"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/state"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" spawn-invalid-beads-a7 some-proj --beads 'bad id!' 2>&1); status=$?
  expect_code 1 "$status" "an invalid --beads id should be refused"
  assert_contains "$out" "invalid --beads id" "spawn invalid-id refusal message missing"
  pass "fm-spawn.sh: --beads rejects an id with disallowed characters"
}

# --- bin/fm-spawn-hooks.d/beads.sh: hook behavior in isolation --------------

test_spawn_hook_stamps_and_registers_check() {
  local case_dir state fakebin_log fakebin log out status check
  case_dir="$TMP_ROOT/spawn-hook-ok"
  state="$case_dir/state"
  mkdir -p "$state"
  fakebin_log=$(make_fake_task "$case_dir/fake-task")
  fakebin=${fakebin_log%%|*}
  log=${fakebin_log##*|}

  out=$(FM_HOOK_ID=hook-task-a8 FM_HOOK_HARNESS=claude FM_HOOK_BEADS_ID=task-open \
    FM_HOOK_WINDOW=win1 FM_HOOK_STATE="$state" FM_HOOK_ROOT="$ROOT" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-spawn-hooks.d/beads.sh" 2>&1); status=$?
  expect_code 0 "$status" "spawn hook should exit 0 on success (got: $out)"
  assert_grep "set-state task-open dispatch=sent" "$log" "spawn hook did not stamp the bead"
  check="$state/hook-task-a8.check.sh"
  assert_present "$check" "spawn hook did not write the watcher check"
  assert_present "$state/hook-task-a8.check-trust" "spawn hook did not register the watcher check"
  if [ "$(uname)" = Darwin ]; then
    perm=$(stat -f '%Lp' "$check" 2>/dev/null)
  else
    perm=$(stat -c '%a' "$check" 2>/dev/null)
  fi
  [ "$perm" = "700" ] || fail "watcher check must be mode 0700, got $perm"
  pass "fm-spawn-hooks.d/beads.sh: stamps the bead and registers a mode-0700 watcher check"
}

test_spawn_hook_check_detects_closed_bead_only() {
  local case_dir state fakebin_log fakebin out status check
  case_dir="$TMP_ROOT/spawn-hook-check"
  state="$case_dir/state"
  mkdir -p "$state"
  fakebin_log=$(make_fake_task "$case_dir/fake-task")
  fakebin=${fakebin_log%%|*}

  FM_HOOK_ID=hook-task-a9 FM_HOOK_HARNESS=claude FM_HOOK_BEADS_ID=task-open \
    FM_HOOK_WINDOW=win1 FM_HOOK_STATE="$state" FM_HOOK_ROOT="$ROOT" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-spawn-hooks.d/beads.sh" >/dev/null 2>&1
  check="$state/hook-task-a9.check.sh"
  out=$(PATH="$fakebin:$PATH" "$check" 2>&1)
  [ -z "$out" ] || fail "check must print nothing while the bead is open (got: $out)"

  FM_HOOK_ID=hook-task-a10 FM_HOOK_HARNESS=claude FM_HOOK_BEADS_ID=task-closed \
    FM_HOOK_WINDOW=win1 FM_HOOK_STATE="$state" FM_HOOK_ROOT="$ROOT" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-spawn-hooks.d/beads.sh" >/dev/null 2>&1
  check="$state/hook-task-a10.check.sh"
  out=$(PATH="$fakebin:$PATH" "$check" 2>&1)
  assert_contains "$out" "bead closed: task-closed" "check did not report the closed bead"
  pass "fm-spawn-hooks.d/beads.sh: registered check reports a closed bead exactly once and stays silent otherwise"
}

test_spawn_hook_is_fail_open_without_task_cli() {
  local case_dir state out status
  case_dir="$TMP_ROOT/spawn-hook-no-task"
  state="$case_dir/state"
  mkdir -p "$state"
  out=$(FM_HOOK_ID=hook-task-a11 FM_HOOK_HARNESS=claude FM_HOOK_BEADS_ID=task-open \
    FM_HOOK_WINDOW=win1 FM_HOOK_STATE="$state" FM_HOOK_ROOT="$ROOT" \
    PATH=/usr/bin:/bin "$ROOT/bin/fm-spawn-hooks.d/beads.sh" 2>&1); status=$?
  expect_code 0 "$status" "spawn hook without task CLI must still exit 0"
  assert_contains "$out" "task CLI not found" "spawn hook did not warn about the missing task CLI"
  assert_absent "$state/hook-task-a11.check.sh" "spawn hook must not write a check without the task CLI"
  pass "fm-spawn-hooks.d/beads.sh: fails open (warns, exits 0, writes no check) without the task CLI"
}

test_spawn_hook_noop_without_beads_id() {
  local case_dir state out status
  case_dir="$TMP_ROOT/spawn-hook-noop"
  state="$case_dir/state"
  mkdir -p "$state"
  out=$(FM_HOOK_ID=hook-task-a12 FM_HOOK_HARNESS=claude FM_HOOK_BEADS_ID='' \
    FM_HOOK_WINDOW=win1 FM_HOOK_STATE="$state" FM_HOOK_ROOT="$ROOT" \
    "$ROOT/bin/fm-spawn-hooks.d/beads.sh" 2>&1); status=$?
  expect_code 0 "$status" "spawn hook with no beads id must exit 0"
  [ -z "$out" ] || fail "spawn hook with no beads id must print nothing (got: $out)"
  assert_absent "$state/hook-task-a12.check.sh" "spawn hook must not act when FM_HOOK_BEADS_ID is empty"
  pass "fm-spawn-hooks.d/beads.sh: no-ops silently when FM_HOOK_BEADS_ID is empty"
}

test_script_parses() {
  local f
  for f in "$STAMP" "$ROOT/bin/fm-brief-hooks.d/beads.sh" "$ROOT/bin/fm-spawn-hooks.d/beads.sh"; do
    bash -n "$f" || fail "bash -n $f must parse cleanly"
  done
  pass "beads hook scripts: bash -n succeeds"
}

test_script_parses
test_stamp_fails_open_on_empty_id
test_stamp_fails_open_without_task_cli
test_stamp_fails_open_on_missing_bead
test_stamp_sets_dispatch_and_assigns
test_brief_beads_renders_receipt_and_closure_once
test_brief_without_beads_has_no_bead_content
test_brief_beads_rejected_for_secondmate
test_brief_beads_rejects_invalid_id
test_spawn_records_beads_id_in_meta_and_runs_hook
test_spawn_beads_rejected_for_secondmate
test_spawn_beads_rejects_invalid_id
test_spawn_hook_stamps_and_registers_check
test_spawn_hook_check_detects_closed_bead_only
test_spawn_hook_is_fail_open_without_task_cli
test_spawn_hook_noop_without_beads_id
