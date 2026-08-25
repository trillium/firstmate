#!/usr/bin/env bash
# Behavior tests for bin/fm-spawn.sh's first-turn watchdog: a launch prompt is
# TYPED into a pane, so nothing about the launch itself proves the agent read
# it. Under load that typed line can be lost, leaving an agent parked at an
# empty composer while the spawn reports success.
#
# These drive the real fm-spawn.sh against a fake tmux that decides, per case,
# whether the harness's turn-lifecycle hook fires - the exact variable the
# incident turned on. bin/fm-firstturn-lib.sh's verdict logic is covered
# separately by tests/fm-firstturn.test.sh; what is pinned here is what a spawn
# DOES with each verdict: detect, resubmit exactly once, log distinguishably,
# and never resubmit into an agent that already started.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-firstturn)

POINTER_MARKER='Read the brief at'

# make_spawn_fakebin <dir> <sendlog>: a fake tmux that logs every send-keys
# payload and, when a payload contains FM_FAKE_HOOK_MATCH, fires the harness's
# turn-lifecycle event exactly as a real adapter hook would - through the real
# bin/fm-busy-event.sh writer, under the incarnation fm-spawn just armed.
# FM_FAKE_HOOK_MATCH unset means the hook never fires: a dropped prompt.
#
# It also answers the liveness probe the watchdog runs before resubmitting: the
# window is listed and its foreground process is an agent, i.e. a pane that is
# genuinely up and merely never consumed its prompt. That is the situation the
# incident produced, and the only one in which resubmitting is the right move.
# tests/fm-backend.test.sh owns the liveness classifier itself.
make_spawn_fakebin() {
  local dir=$1 sendlog=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'PSSH'
#!/usr/bin/env bash
# The fake pane's foreground process, one process group. Defaults to a live
# agent; FM_FAKE_FG_COMM=zsh makes it a bare shell instead.
comm=${FM_FAKE_FG_COMM:-claude}
case "$*" in
  *-o\ args=*) printf '%s\n' "$comm" ;;
  *) printf '4242 4242 4242 %s\n' "$comm" ;;
esac
exit 0
PSSH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_tty}"*) printf '/dev/ttys999\n'; exit 0 ;;
esac
case "\${1:-}" in
  list-windows)
    # The window exists only once new-window has actually created it, so
    # fm-spawn's own duplicate-window refusal still sees a clean session.
    [ -e '$sendlog.window' ] && printf 'fm-%s\n' "\${FM_FAKE_BUSY_ID:-}"
    exit 0 ;;
  new-window) : > '$sendlog.window'; printf '@9\n'; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    printf '%s\n' "\$*" >> '$sendlog'
    if [ -n "\${FM_FAKE_HOOK_MATCH:-}" ]; then
      case "\$*" in
        *"\$FM_FAKE_HOOK_MATCH"*)
          "\$FM_FAKE_ROOT/bin/fm-busy-event.sh" apply \\
            "\$FM_FAKE_BUSY_STATE" "\$FM_FAKE_BUSY_ID" busy --current-gen \\
            --source "\$FM_FAKE_HOOK_SOURCE" --event first-turn >/dev/null 2>&1 || true
          ;;
      esac
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <id> <harness>: a home + primary project with a real
# worktree (the pane's reported cwd) and a brief, ready for a spawn.
make_spawn_case() {
  local name=$1 id=$2 harness=$3 case_dir home proj wt fakebin sendlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  sendlog="$case_dir/send-keys.log"
  mkdir -p "$case_dir"
  : > "$sendlog"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" "$sendlog")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$sendlog"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SEND_LOG <<EOF
$1
EOF
}

# run_case_spawn <id> <harness> <hook-match> <hook-source> [extra spawn args...]
# An empty <hook-match> means the harness hook never fires - the dropped-prompt
# case. The watchdog is re-enabled per invocation because tests/lib.sh turns it
# off suite-wide for every spawn test that is not this one; CASE_FIRSTTURN lets
# one case switch it back off to pin the off-switch behaviour.
run_case_spawn() {
  local id=$1 harness=$2 match=$3 source=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_ROOT="$ROOT" \
    FM_FAKE_BUSY_STATE="$HOME_DIR/state" \
    FM_FAKE_BUSY_ID="$id" \
    FM_FAKE_HOOK_MATCH="$match" \
    FM_FAKE_HOOK_SOURCE="$source" \
    FM_SPAWN_FIRSTTURN="${CASE_FIRSTTURN:-on}" \
    FM_SPAWN_FIRSTTURN_POLLS=3 \
    FM_SPAWN_FIRSTTURN_INTERVAL=0.1 \
    FM_SPAWN_FIRSTTURN_SUBMIT_RETRIES=1 \
    FM_SPAWN_FIRSTTURN_SUBMIT_SLEEP=0.1 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" --mode no-mistakes --yolo off --harness "$harness" "$id" "$PROJ_DIR" "$@" 2>&1
}

# outcome_line <home> <id>: the task's single first-turn outcome record.
outcome_line() {
  grep -F " id=$2 " "$1/state/.firstturn.log" 2>/dev/null || true
}

# pointer_sends <sendlog>: how many brief-pointer resubmissions were typed.
pointer_sends() {
  grep -cF -- "$POINTER_MARKER" "$1" 2>/dev/null || true
}

# --- a launch whose prompt DID land -----------------------------------------

test_a_landed_prompt_is_never_resubmitted_into() {
  local rec id out
  id=firstturn-fired-z1
  rec=$(make_spawn_case firstturn-fired "$id" claude)
  read_spawn_record "$rec"

  # The harness hook fires off the launch line itself - the healthy case the
  # spawn already assumed. Resubmitting here would hand the agent a SECOND
  # charter mid-turn, so this is the safety property that matters most.
  out=$(run_case_spawn "$id" claude 'export GIT_EDITOR' claude-hook)
  expect_code 0 "$?" "spawn should succeed when the launch prompt lands: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  assert_contains "$(outcome_line "$HOME_DIR" "$id")" 'outcome=fired-normally' \
    "a landed launch prompt was not recorded as fired-normally"
  [ "$(pointer_sends "$SEND_LOG")" -eq 0 ] \
    || fail "a launch whose prompt landed was resubmitted into - the agent would receive a duplicate charter"
  assert_not_contains "$out" "FIRSTTURN:" \
    "a healthy launch reported a first-turn problem"
  if [ -e "$HOME_DIR/state/$id.status" ]; then
    assert_no_grep 'blocked:' "$HOME_DIR/state/$id.status" \
      "a healthy launch appended a blocked status line"
  fi
  pass "a launch whose prompt started a turn is confirmed and never resubmitted into - no duplicated charter"
}

# --- a launch whose prompt was DROPPED ---------------------------------------

test_dropped_prompt_is_detected_and_resubmitted_once() {
  local rec id out
  id=firstturn-resubmit-z2
  rec=$(make_spawn_case firstturn-resubmit "$id" claude)
  read_spawn_record "$rec"

  # The launch line is swallowed (the hook ignores it), so the agent sits at an
  # empty composer. The watchdog must notice and hand it the brief pointer; the
  # hook then fires off THAT, confirming the recovery.
  out=$(run_case_spawn "$id" claude "$POINTER_MARKER" claude-hook)
  expect_code 0 "$?" "spawn should still succeed after a confirmed resubmission: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  assert_contains "$(outcome_line "$HOME_DIR" "$id")" 'outcome=resubmitted-confirmed' \
    "a recovered launch was not recorded as resubmitted-confirmed"
  [ "$(pointer_sends "$SEND_LOG")" -eq 1 ] \
    || fail "the watchdog resubmitted $(pointer_sends "$SEND_LOG") times; it must resubmit exactly once"
  assert_contains "$out" "FIRSTTURN: $id" \
    "the resubmission was not surfaced to the operator"
  assert_grep "$POINTER_MARKER" "$SEND_LOG" \
    "the resubmission did not deliver a brief pointer"
  assert_grep "$HOME_DIR/data/$id/brief.md" "$SEND_LOG" \
    "the resubmitted pointer did not name the task's own brief"
  pass "a dropped launch prompt is detected, resubmitted exactly once, and the recovered turn is confirmed"
}

test_unrecovered_launch_is_reported_not_called_success() {
  local rec id out
  id=firstturn-unconfirmed-z3
  rec=$(make_spawn_case firstturn-unconfirmed "$id" claude)
  read_spawn_record "$rec"

  # Nothing ever fires the hook: neither the launch nor the resubmission lands.
  # This is the case the old code reported as a clean success.
  out=$(run_case_spawn "$id" claude '' claude-hook)
  assert_contains "$(outcome_line "$HOME_DIR" "$id")" 'outcome=resubmitted-unconfirmed' \
    "an unrecovered launch was not recorded as resubmitted-unconfirmed"
  [ "$(pointer_sends "$SEND_LOG")" -eq 1 ] \
    || fail "the watchdog resubmitted $(pointer_sends "$SEND_LOG") times; it must resubmit exactly once even when unconfirmed"
  assert_contains "$out" "FIRSTTURN: $id" \
    "an unrecovered launch was not surfaced to the operator"
  assert_grep 'blocked:' "$HOME_DIR/state/$id.status" \
    "an unrecovered launch left no supervisor-actionable status event"
  pass "a launch that never starts a turn is reported and left actionable instead of passing as success"
}

test_the_three_outcomes_are_distinguishable_in_one_log() {
  # The log is the durable record a captain reads after the fact, so the three
  # outcomes must be told apart from the log alone, not inferred from context.
  local home line
  home=$TMP_ROOT/firstturn-fired/home
  line=$(cat "$home/state/.firstturn.log" \
    "$TMP_ROOT/firstturn-resubmit/home/state/.firstturn.log" \
    "$TMP_ROOT/firstturn-unconfirmed/home/state/.firstturn.log" 2>/dev/null \
    | grep -c 'outcome=')
  [ "$line" -eq 3 ] || fail "expected one outcome record per launch, found $line"
  for outcome in fired-normally resubmitted-confirmed resubmitted-unconfirmed; do
    cat "$TMP_ROOT"/firstturn-*/home/state/.firstturn.log 2>/dev/null \
      | grep -qF "outcome=$outcome" \
      || fail "outcome '$outcome' is not distinguishable in the first-turn log"
  done
  pass "fired-normally, resubmitted-confirmed, and resubmitted-unconfirmed are each distinguishable in the durable log"
}

# --- harnesses whose first turn cannot be observed ---------------------------

test_unprovable_harness_is_never_resubmitted_into() {
  local rec id out
  id=firstturn-unprovable-z4
  rec=$(make_spawn_case firstturn-unprovable "$id" codex)
  read_spawn_record "$rec"

  # codex has no semantic turn source, so nothing about its launch can be
  # proven either way. A guess in either direction is wrong: claiming success
  # hides the incident, and resubmitting risks a duplicate charter on every
  # single codex launch. The watchdog must record the gap and do nothing.
  out=$(run_case_spawn "$id" codex "$POINTER_MARKER" claude-hook)
  expect_code 0 "$?" "spawn should succeed for a harness with no turn source: $out"
  assert_contains "$(outcome_line "$HOME_DIR" "$id")" 'outcome=unproven' \
    "an unprovable harness was not recorded as unproven"
  assert_contains "$(outcome_line "$HOME_DIR" "$id")" 'detail=no-semantic-source' \
    "the unproven record did not name why the launch could not be proven"
  [ "$(pointer_sends "$SEND_LOG")" -eq 0 ] \
    || fail "a harness whose first turn cannot be observed was resubmitted into on no evidence"
  pass "a harness with no observable first turn is recorded as unproven and never resubmitted into"
}

test_a_pointer_is_never_typed_into_a_bare_shell() {
  local rec id out
  id=firstturn-notrunning-z6
  rec=$(make_spawn_case firstturn-notrunning "$id" claude)
  read_spawn_record "$rec"

  # The pane is up but its foreground is a plain shell: the launch COMMAND
  # itself failed, so no agent ever started. Typing a brief pointer here would
  # not recover anything and would be RUN as a shell command in the task's own
  # worktree. The watchdog must report instead of resubmitting.
  out=$(FM_FAKE_FG_COMM=zsh run_case_spawn "$id" claude '' claude-hook)
  assert_contains "$(outcome_line "$HOME_DIR" "$id")" 'outcome=not-running' \
    "a launch with no agent running was not recorded as not-running"
  [ "$(pointer_sends "$SEND_LOG")" -eq 0 ] \
    || fail "the watchdog typed a brief pointer into a pane with no agent running - it would run as a shell command"
  assert_grep 'blocked:' "$HOME_DIR/state/$id.status" \
    "a launch with no agent running left no supervisor-actionable status event"
  pass "a launch that never started an agent is reported, and no pointer is ever typed into a bare shell"
}

# --- the off switch ----------------------------------------------------------

test_watchdog_off_restores_the_prior_launch_behaviour() {
  local rec id out
  id=firstturn-off-z5
  rec=$(make_spawn_case firstturn-off "$id" claude)
  read_spawn_record "$rec"

  out=$(CASE_FIRSTTURN=off run_case_spawn "$id" claude '' claude-hook)
  expect_code 0 "$?" "spawn should succeed with the watchdog off: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success with the watchdog off"
  [ "$(pointer_sends "$SEND_LOG")" -eq 0 ] \
    || fail "the watchdog resubmitted while switched off"
  assert_not_contains "$out" "FIRSTTURN:" \
    "the watchdog reported while switched off"
  assert_contains "$(outcome_line "$HOME_DIR" "$id")" 'detail=disabled' \
    "the watchdog left no record that it was switched off for this launch"
  pass "switching the watchdog off restores the prior launch behaviour and says so in the record"
}

# --- the watchdog never weakens what the spawn already guaranteed ------------

test_watchdog_does_not_disturb_the_spawn_contract() {
  local home id
  # Same launches as above: the spawn's own guarantees must survive the added
  # verification step. An isolated worktree is asserted before any of this runs,
  # so a spawn that reached a first-turn verdict at all also cleared that gate.
  for id in firstturn-fired-z1 firstturn-resubmit-z2 firstturn-unconfirmed-z3; do
    case "$id" in
      firstturn-fired-z1) home=$TMP_ROOT/firstturn-fired/home ;;
      firstturn-resubmit-z2) home=$TMP_ROOT/firstturn-resubmit/home ;;
      *) home=$TMP_ROOT/firstturn-unconfirmed/home ;;
    esac
    assert_present "$home/state/$id.meta" "$id: the watchdog cost the task its durable record"
    assert_grep 'worktree=' "$home/state/$id.meta" "$id: meta lost its worktree binding"
    assert_grep 'harness=claude' "$home/state/$id.meta" "$id: meta lost its harness binding"
    grep -q "^worktree=$TMP_ROOT" "$home/state/$id.meta" \
      || fail "$id: the recorded worktree is not the isolated one the spawn resolved"
  done
  pass "the first-turn watchdog leaves the spawn's own worktree and metadata guarantees intact"
}

test_a_landed_prompt_is_never_resubmitted_into
test_dropped_prompt_is_detected_and_resubmitted_once
test_unrecovered_launch_is_reported_not_called_success
test_the_three_outcomes_are_distinguishable_in_one_log
test_unprovable_harness_is_never_resubmitted_into
test_a_pointer_is_never_typed_into_a_bare_shell
test_watchdog_off_restores_the_prior_launch_behaviour
test_watchdog_does_not_disturb_the_spawn_contract

echo "# all fm-spawn-firstturn tests passed"
