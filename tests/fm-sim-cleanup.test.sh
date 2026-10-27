#!/usr/bin/env bash
# Behavior tests for iOS simulator hygiene: bin/fm-spawn.sh records the
# simulators already booted when a task starts, bin/fm-teardown.sh shuts down the
# ones the task booted that nothing else uses, and bin/fm-sim-idle.sh flags a
# simulator that outlived its threshold with nothing using it (bin/fm-sim-lib.sh
# owns the rules).
#
# Every case runs against fake xcrun, ps, and uname binaries on PATH, so no real
# simulator is ever read or shut down. The fake xcrun keeps the booted set in a
# file and logs every shutdown; the fake ps serves one "<etime>\t<command>" line
# per process from a file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
IDLE="$ROOT/bin/fm-sim-idle.sh"
TMP_ROOT=$(fm_test_tmproot fm-sim-cleanup)
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

SIM_A=AAAAAAAA-1111-4111-8111-AAAAAAAAAAAA
SIM_B=BBBBBBBB-2222-4222-8222-BBBBBBBBBBBB
SIM_C=CCCCCCCC-3333-4333-8333-CCCCCCCCCCCC

# --- fixture ----------------------------------------------------------------

# A case: one home, a project clone with an origin, and fake tmux, treehouse,
# xcrun, ps, and uname. <case>/booted lists the booted simulators, <case>/ps the
# process table, and <case>/shutdown.log every simulator shut down.
make_case() {  # <name>
  local case_dir fakebin
  case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/home/state" "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/projects"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/booted"
  : > "$case_dir/ps"
  : > "$case_dir/shutdown.log"
  touch "$case_dir/home/state/.last-watcher-beat"
  printf '%s\n' codex > "$case_dir/home/config/crew-harness"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/xcrun" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = simctl ] || exit 0
case "${2:-}" in
  list)
    printf '== Devices ==\n-- iOS 26.3 --\n'
    while IFS= read -r udid; do
      [ -n "$udid" ] || continue
      printf '    iPhone Fake (%s) (Booted) \n' "$udid"
    done < "$FM_FAKE_SIM_BOOTED"
    ;;
  shutdown)
    [ -z "${FM_FAKE_SIM_SHUTDOWN_FAILS:-}" ] || exit 1
    printf '%s\n' "$3" >> "$FM_FAKE_SIM_LOG"
    grep -Fxv "$3" "$FM_FAKE_SIM_BOOTED" > "$FM_FAKE_SIM_BOOTED.new" || true
    mv "$FM_FAKE_SIM_BOOTED.new" "$FM_FAKE_SIM_BOOTED"
    ;;
esac
exit 0
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *etime=*) awk -F'\t' '{print $1 " " $2}' "$FM_FAKE_PS" ;;
  *) awk -F'\t' '{print $2}' "$FM_FAKE_PS" ;;
esac
SH
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_UNAME:-Darwin}"
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/xcrun" "$fakebin/ps" "$fakebin/uname"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$case_dir/home/data/backlog.md"
    cat > "$case_dir/home/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
TOML
  fi
  printf '%s\n' "$case_dir"
}

boot() {  # <case-dir> <udid>...
  local case_dir=$1
  shift
  printf '%s\n' "$@" > "$case_dir/booted"
}

# A process-table line: <etime> <command>.
proc() {  # <case-dir> <etime> <command>
  printf '%s\t%s\n' "$2" "$3" >> "$1/ps"
}

# The caller's PATH with every directory that holds an xcrun replaced by a
# symlink mirror of it that lacks xcrun: a host without Xcode.
path_without_xcrun() {  # <case-dir>
  local case_dir=$1 dir mirror n=0 entry out
  out=$case_dir/fakebin
  local IFS=:
  for dir in $PATH; do
    [ "$dir" != "$case_dir/fakebin" ] || continue
    if [ -e "$dir/xcrun" ]; then
      n=$((n + 1))
      mirror="$case_dir/no-xcrun-$n"
      mkdir -p "$mirror"
      for entry in "$dir"/*; do
        [ "$(basename "$entry")" = xcrun ] || ln -sf "$entry" "$mirror/$(basename "$entry")"
      done
      out="$out:$mirror"
    else
      out="$out:$dir"
    fi
  done
  printf '%s\n' "$out"
}

shut_down() { sort "$1/shutdown.log" | paste -sd, -; }

# Sets SIM_ENV to the env assignments that point a command at the case's fakes.
env_for() {  # <case-dir>
  SIM_ENV=("FM_FAKE_SIM_BOOTED=$1/booted" "FM_FAKE_SIM_LOG=$1/shutdown.log" "FM_FAKE_PS=$1/ps" "PATH=$1/fakebin:$PATH")
}

# A live worker record, with its backlog item In flight so cleanup can close it.
write_live() {  # <case-dir> <id> [extra-line...]
  local case_dir=$1 id=$2
  shift 2
  fm_write_meta "$case_dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/absent-worktree-$id" \
    "project=$case_dir/project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s$(date +%s)-$id" \
    "$@"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    tasks-axi add "$id" "item for $id" --kind ship --file "$case_dir/home/data/backlog.md" >/dev/null
    tasks-axi start "$id" --file "$case_dir/home/data/backlog.md" >/dev/null
  fi
}

run_teardown() {  # <case-dir> <id>
  local case_dir=$1
  env FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_SIM_BOOTED="$case_dir/booted" FM_FAKE_SIM_LOG="$case_dir/shutdown.log" FM_FAKE_PS="$case_dir/ps" \
    PATH="$case_dir/fakebin:$PATH" "$TEARDOWN" "$2" 2>&1
}

run_idle() {  # <case-dir> <mode> [VAR=value...]
  local case_dir=$1 mode=$2
  shift 2
  env FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_SIM_BOOTED="$case_dir/booted" FM_FAKE_SIM_LOG="$case_dir/shutdown.log" FM_FAKE_PS="$case_dir/ps" \
    PATH="$case_dir/fakebin:$PATH" "$@" "$IDLE" "$mode" 2>&1
}

# A queued task with a brief, ready for bin/fm-spawn.sh.
queue_task() {  # <case-dir> <id>
  mkdir -p "$1/home/data/$2"
  cat > "$1/home/data/$2/brief.md" <<EOF2
# Task
## Captain's intent
Exercise simulator tracking for $2.

## Firstmate spec
Nothing to build.

# Definition of done
Delivery contract: mode=no-mistakes
EOF2
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/home/data/backlog.md" >/dev/null
}

# --- cases: spawn ------------------------------------------------------------

test_spawn_records_the_simulators_already_booted() {
  local case_dir out rc=0
  case_dir=$(make_case spawn-baseline)
  boot "$case_dir" "$SIM_B" "$SIM_A"
  git -C "$case_dir/project" worktree add --quiet -b wt-t1 "$case_dir/wt-t1"
  queue_task "$case_dir" task-1
  env_for "$case_dir"
  out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$case_dir/wt-t1" "${SIM_ENV[@]}" \
    "$SPAWN" task-1 "$case_dir/project" --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "spawn failed: $out"
  assert_grep "sim_baseline=$SIM_A,$SIM_B" "$case_dir/home/state/task-1.meta" \
    "spawn did not record the booted simulators"

  : > "$case_dir/booted"
  git -C "$case_dir/project" worktree add --quiet -b wt-t2 "$case_dir/wt-t2"
  queue_task "$case_dir" task-2
  rc=0
  out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$case_dir/wt-t2" "${SIM_ENV[@]}" \
    "$SPAWN" task-2 "$case_dir/project" --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "spawn with nothing booted failed: $out"
  assert_grep 'sim_baseline=none' "$case_dir/home/state/task-2.meta" \
    "spawn with nothing booted did not record an empty baseline"
  pass "spawn records the simulators booted when a task starts, and an empty set as none"
}

test_spawn_without_xcode_records_nothing() {
  local case_dir out rc=0
  case_dir=$(make_case spawn-no-xcode)
  rm -f "$case_dir/fakebin/xcrun"
  git -C "$case_dir/project" worktree add --quiet -b wt-t1 "$case_dir/wt-t1"
  queue_task "$case_dir" task-1
  out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$case_dir/wt-t1" PATH="$(path_without_xcrun "$case_dir")" \
    "$SPAWN" task-1 "$case_dir/project" --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "spawn on a host without Xcode failed: $out"
  assert_no_grep 'sim_baseline=' "$case_dir/home/state/task-1.meta" \
    "spawn recorded a simulator baseline on a host without Xcode"
  pass "spawn on a host without Xcode records no simulator baseline"
}

# --- cases: teardown ---------------------------------------------------------

test_teardown_shuts_down_only_what_the_task_booted() {
  local case_dir out rc=0
  case_dir=$(make_case teardown-owned)
  boot "$case_dir" "$SIM_A" "$SIM_B"
  write_live "$case_dir" task-1 "sim_baseline=$SIM_A"
  fm_write_meta "$case_dir/home/state/mate-1.meta" "window=firstmate:fm-mate-1" "kind=secondmate"
  out=$(run_teardown "$case_dir" task-1) || rc=$?
  expect_code 0 "$rc" "teardown failed: $out"
  assert_equals "$SIM_B" "$(shut_down "$case_dir")" "teardown did not shut down exactly the simulator booted after the task started, or counted a secondmate as its owner"
  assert_contains "$out" "shut down simulator $SIM_B" "teardown did not report the simulator it shut down"
  assert_absent "$case_dir/home/state/task-1.meta" "teardown left the task record"
  pass "teardown shuts down the simulator the task booted, leaves the pre-existing one, and ignores secondmates"
}

test_teardown_keeps_a_simulator_a_running_tool_targets() {
  local case_dir out rc=0
  case_dir=$(make_case teardown-targeted)
  boot "$case_dir" "$SIM_B" "$SIM_C"
  proc "$case_dir" 05:00 "/usr/bin/xcodebuild test -destination id=$SIM_B -scheme App"
  write_live "$case_dir" task-1 "sim_baseline=none"
  out=$(run_teardown "$case_dir" task-1) || rc=$?
  expect_code 0 "$rc" "teardown failed: $out"
  assert_equals "$SIM_C" "$(shut_down "$case_dir")" "teardown shut down a simulator a running xcodebuild targets, or kept an unused one"
  assert_contains "$out" "left simulator $SIM_B booted" "teardown did not report keeping the targeted simulator"
  pass "teardown keeps a simulator a running tool targets by UDID"
}

test_teardown_keeps_every_candidate_while_unpinned_tooling_runs() {
  local case_dir out rc=0
  case_dir=$(make_case teardown-unpinned)
  boot "$case_dir" "$SIM_B" "$SIM_C"
  proc "$case_dir" 01:00 "xcodebuild test -destination platform=iOS Simulator,name=iPhone 15 -scheme App"
  write_live "$case_dir" task-1 "sim_baseline=none"
  out=$(run_teardown "$case_dir" task-1) || rc=$?
  expect_code 0 "$rc" "teardown failed: $out"
  assert_equals "" "$(shut_down "$case_dir")" "teardown shut down a simulator while a name-targeted xcodebuild ran"
  assert_contains "$out" "names no simulator and may be testing on it" "teardown did not report why it kept the simulators"
  pass "teardown keeps every candidate while a test run that names no simulator is running"
}

test_teardown_unpinned_test_drivers_each_protect() {
  local case_dir out cmd n=0
  for cmd in \
    "xcodebuild test-without-building -xctestrun App.xctestrun" \
    "xcodebuild build-for-testing -scheme App" \
    "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest App.xctest" \
    "xcrun simctl spawn booted log stream" \
    "xcrun simctl launch booted com.example.app" \
    "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl install booted App.app" \
    "xcrun simctl io booted screenshot shot.png"; do
    n=$((n + 1))
    case_dir=$(make_case "teardown-driver-$n")
    boot "$case_dir" "$SIM_B"
    proc "$case_dir" 01:00 "$cmd"
    write_live "$case_dir" task-1 "sim_baseline=none"
    out=$(run_teardown "$case_dir" task-1) || true
    assert_equals "" "$(shut_down "$case_dir")" "teardown shut down a simulator while '$cmd' ran"
  done
  pass "every test-driving command that names no simulator keeps the candidates booted"
}

test_teardown_ignores_servers_builds_and_listing() {
  local case_dir out rc=0
  case_dir=$(make_case teardown-non-drivers)
  boot "$case_dir" "$SIM_B"
  proc "$case_dir" 3-00:00:00 "/opt/homebrew/bin/appium --port 4723"
  proc "$case_dir" 3-00:00:00 "/usr/local/bin/maestro studio"
  proc "$case_dir" 02:00 "/usr/bin/swift-build --package-path Other"
  proc "$case_dir" 02:00 "xcodebuild build -scheme App"
  proc "$case_dir" 00:01 "xcrun simctl list devices booted"
  proc "$case_dir" 00:01 "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl list devices booted"
  write_live "$case_dir" task-1 "sim_baseline=none"
  out=$(run_teardown "$case_dir" task-1) || rc=$?
  expect_code 0 "$rc" "teardown failed: $out"
  assert_equals "$SIM_B" "$(shut_down "$case_dir")" "a server, a plain build, or a simctl listing kept an unused simulator booted: $out"
  pass "servers, plain builds, and simctl listings never protect a simulator they do not name"
}

test_teardown_ignores_the_simulators_own_processes() {
  local case_dir out rc=0
  case_dir=$(make_case teardown-own-procs)
  boot "$case_dir" "$SIM_B"
  proc "$case_dir" 09:00 "/Library/Developer/CoreSimulator/Volumes/x/launchd_sim /Users/u/Library/Developer/CoreSimulator/Devices/$SIM_B/data/var/run/launchd_bootstrap.plist"
  proc "$case_dir" 09:00 "/Users/u/Library/Developer/CoreSimulator/Devices/$SIM_B/data/Containers/Bundle/Application/App"
  write_live "$case_dir" task-1 "sim_baseline=none"
  out=$(run_teardown "$case_dir" task-1) || rc=$?
  expect_code 0 "$rc" "teardown failed: $out"
  assert_equals "$SIM_B" "$(shut_down "$case_dir")" "the simulator's own processes kept it booted"
  pass "a simulator's own processes do not count as something using it"
}

test_teardown_keeps_a_simulator_another_live_task_found_booted() {
  local case_dir out rc=0
  case_dir=$(make_case teardown-peer)
  boot "$case_dir" "$SIM_B"
  write_live "$case_dir" task-1 "sim_baseline=none"
  write_live "$case_dir" task-2 "sim_baseline=$SIM_B"
  out=$(run_teardown "$case_dir" task-1) || rc=$?
  expect_code 0 "$rc" "teardown failed: $out"
  assert_equals "" "$(shut_down "$case_dir")" "teardown ignored another live task's recorded boot"
  assert_contains "$out" "task task-2 found it already booted" "teardown did not name the task that relies on the simulator"
  pass "teardown keeps a simulator another live task found booted"
}

test_teardown_keeps_a_simulator_a_live_peer_may_have_booted() {
  local case_dir out rc=0
  case_dir=$(make_case teardown-peer-booted)
  # X and Y both start with nothing booted, then X boots SIM_B and sits between
  # test runs: tearing down Y must not shut X's simulator down.
  write_live "$case_dir" task-x "sim_baseline=none"
  write_live "$case_dir" task-y "sim_baseline=none"
  boot "$case_dir" "$SIM_B"
  out=$(run_teardown "$case_dir" task-y) || rc=$?
  expect_code 0 "$rc" "teardown failed: $out"
  assert_equals "" "$(shut_down "$case_dir")" "teardown shut down a simulator a live peer task booted"
  assert_contains "$out" "left simulator $SIM_B booted (live tasks that may have booted it: task-x)" "teardown did not name the peer that may own the simulator"

  case_dir=$(make_case teardown-peer-no-baseline)
  write_live "$case_dir" task-old
  write_live "$case_dir" task-y "sim_baseline=none"
  boot "$case_dir" "$SIM_C"
  rc=0
  out=$(run_teardown "$case_dir" task-y) || rc=$?
  expect_code 0 "$rc" "teardown failed: $out"
  assert_equals "" "$(shut_down "$case_dir")" "teardown shut down a simulator a live peer with no baseline may have booted"
  assert_contains "$out" "live tasks that may have booted it: task-old" "teardown did not name the peer with no baseline"
  pass "teardown keeps a simulator a live peer, with or without a baseline, may have booted"
}

test_teardown_without_a_baseline_or_xcode_is_a_no_op() {
  local case_dir out rc=0
  case_dir=$(make_case teardown-noop)
  boot "$case_dir" "$SIM_B"
  write_live "$case_dir" task-1
  out=$(run_teardown "$case_dir" task-1) || rc=$?
  expect_code 0 "$rc" "teardown of a task with no baseline failed: $out"
  assert_equals "" "$(shut_down "$case_dir")" "teardown shut down a simulator for a task that recorded no baseline"
  assert_not_contains "$out" "simulator" "teardown mentioned simulators for a task that recorded no baseline"

  rm -f "$case_dir/fakebin/xcrun"
  write_live "$case_dir" task-2 "sim_baseline=none"
  rc=0
  out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_PS="$case_dir/ps" PATH="$(path_without_xcrun "$case_dir")" "$TEARDOWN" task-2 2>&1) || rc=$?
  assert_not_contains "$out" "simulator" "teardown mentioned simulators on a host with no xcrun"
  pass "teardown is a no-op without a recorded baseline"
}

test_teardown_reports_a_shutdown_that_failed() {
  local case_dir out rc=0
  case_dir=$(make_case teardown-fails)
  boot "$case_dir" "$SIM_B"
  write_live "$case_dir" task-1 "sim_baseline=none"
  out=$(FM_FAKE_SIM_SHUTDOWN_FAILS=1 run_teardown "$case_dir" task-1) || rc=$?
  expect_code 0 "$rc" "a failed simulator shutdown failed the teardown: $out"
  assert_contains "$out" "could not shut down simulator $SIM_B" "teardown did not report the failed shutdown"
  assert_absent "$case_dir/home/state/task-1.meta" "a failed simulator shutdown blocked the cleanup"
  pass "a simulator that will not shut down is reported and never blocks the cleanup"
}

# --- cases: idle simulator check ----------------------------------------------

proc_booted() {  # <case-dir> <udid> <etime>
  proc "$1" "$3" "/Library/Developer/CoreSimulator/Volumes/x/launchd_sim /Users/u/Library/Developer/CoreSimulator/Devices/$2/data/var/run/launchd_bootstrap.plist"
}

test_idle_scan_names_an_old_unused_simulator_and_its_possible_owners() {
  local case_dir out
  case_dir=$(make_case idle-old)
  boot "$case_dir" "$SIM_A" "$SIM_B"
  proc_booted "$case_dir" "$SIM_A" "5-02:10:00"
  proc_booted "$case_dir" "$SIM_B" "01:00:00"
  write_live "$case_dir" task-1 "sim_baseline=none"
  write_live "$case_dir" task-2 "sim_baseline=$SIM_A"
  out=$(run_idle "$case_dir" scan)
  assert_contains "$out" "$SIM_A" "the scan did not name the simulator booted for days"
  assert_contains "$out" "booted 122h" "the scan did not report how long the simulator has been booted"
  assert_contains "$out" "possible owners: task-1" "the scan did not name the task that started before the simulator booted"
  assert_not_contains "$out" "$SIM_B" "the scan named a simulator booted for one hour"
  assert_not_contains "$out" "task-2" "the scan named a task that found the simulator already booted as its owner"
  assert_equals "" "$(shut_down "$case_dir")" "the scan shut a simulator down"
  pass "the idle scan names an old unused simulator and the tasks that could own it, and shuts nothing down"
}

test_idle_scan_orphan_and_threshold_config() {
  local case_dir out
  case_dir=$(make_case idle-config)
  boot "$case_dir" "$SIM_A"
  proc_booted "$case_dir" "$SIM_A" "03:00:00"
  out=$(run_idle "$case_dir" scan)
  assert_equals "" "$out" "a 3h-old simulator was flagged under the 12h default"
  printf '2\n' > "$case_dir/home/config/sim-idle-hours"
  out=$(run_idle "$case_dir" scan)
  assert_contains "$out" "no live task may own it" "an orphaned simulator was not reported as having no live task"
  printf 'off\n' > "$case_dir/home/config/sim-idle-hours"
  assert_equals "" "$(run_idle "$case_dir" scan)" "config/sim-idle-hours=off did not disable the check"
  printf '2\n' > "$case_dir/home/config/sim-idle-hours"
  assert_equals "" "$(run_idle "$case_dir" scan FM_SIM_IDLE_HOURS=4)" "FM_SIM_IDLE_HOURS did not override the config file"
  out=$(run_idle "$case_dir" scan FM_SIM_IDLE_HOURS=bogus)
  assert_contains "$out" "using 12" "an invalid threshold was not reported and defaulted"
  assert_not_contains "$out" "$SIM_A" "an invalid threshold flagged a 3h-old simulator under the 12h default"
  pass "the idle threshold comes from config, the environment overrides it, off disables it"
}

test_idle_scan_reports_why_it_kept_a_simulator() {
  local case_dir out
  case_dir=$(make_case idle-in-use)
  boot "$case_dir" "$SIM_A"
  proc_booted "$case_dir" "$SIM_A" "1-00:00:00"
  proc "$case_dir" 10:00 "xcrun simctl launch $SIM_A com.example.app"
  write_live "$case_dir" task-1 "sim_baseline=none"
  out=$(run_idle "$case_dir" scan)
  assert_contains "$out" "$SIM_A has been booted 24h and was kept because a running simctl targets it (possible owners: task-1)" "the scan did not report why it kept a simulator a tool uses"
  assert_not_contains "$out" "shut it down" "the scan offered to shut down a simulator a tool uses"

  case_dir=$(make_case idle-unpinned)
  boot "$case_dir" "$SIM_A"
  proc_booted "$case_dir" "$SIM_A" "1-00:00:00"
  proc "$case_dir" 10:00 "xcodebuild test -destination platform=iOS Simulator,name=iPhone 15 -scheme App"
  out=$(run_idle "$case_dir" scan)
  assert_contains "$out" "was kept because a running xcodebuild names no simulator and may be testing on it (no live task may own it)" "the scan stayed silent about a simulator an unpinned test run kept"
  pass "the idle scan reports a simulator past the threshold that a running tool keeps, with the reason"
}

test_idle_scan_is_not_silenced_by_a_server() {
  local case_dir out
  case_dir=$(make_case idle-server)
  boot "$case_dir" "$SIM_A"
  proc_booted "$case_dir" "$SIM_A" "5-00:00:00"
  proc "$case_dir" 5-00:00:00 "/opt/homebrew/bin/appium --port 4723"
  proc "$case_dir" 5-00:00:00 "/usr/local/bin/maestro studio"
  out=$(run_idle "$case_dir" scan)
  assert_contains "$out" "$SIM_A has been booted 120h with nothing using it" "a long-lived server silenced the idle simulator wake"
  pass "a long-lived appium or maestro server never silences the idle simulator wake"
}

test_idle_scan_alerts_once_until_the_quiet_period_passes() {
  local case_dir out now=1000000
  case_dir=$(make_case idle-realert)
  boot "$case_dir" "$SIM_A"
  proc_booted "$case_dir" "$SIM_A" "2-00:00:00"
  out=$(run_idle "$case_dir" scan FM_SIM_IDLE_NOW=$now)
  assert_contains "$out" "$SIM_A" "the first scan did not flag the simulator"
  out=$(run_idle "$case_dir" scan FM_SIM_IDLE_NOW=$now)
  assert_contains "$out" "$SIM_A" "a scan without an ack suppressed the alert (enqueue must come before suppression)"
  run_idle "$case_dir" ack FM_SIM_IDLE_NOW=$now >/dev/null
  assert_equals "" "$(run_idle "$case_dir" scan FM_SIM_IDLE_NOW=$((now + 3600)))" "an acknowledged simulator was reported again within the quiet period"
  out=$(run_idle "$case_dir" scan FM_SIM_IDLE_NOW=$((now + 25 * 3600)))
  assert_contains "$out" "$SIM_A" "an acknowledged simulator was never reported again"
  : > "$case_dir/booted"
  run_idle "$case_dir" scan FM_SIM_IDLE_NOW=$((now + 26 * 3600)) >/dev/null
  assert_absent "$case_dir/home/state/.sim-idle/$SIM_A" "the quiet-period record outlived the simulator"
  pass "an idle simulator is reported until acknowledged, then once per quiet period"
}

test_idle_scan_is_quiet_where_it_should_be() {
  local case_dir mate out
  case_dir=$(make_case idle-quiet)
  boot "$case_dir" "$SIM_A"
  proc_booted "$case_dir" "$SIM_A" "2-00:00:00"
  assert_equals "" "$(run_idle "$case_dir" scan FM_FAKE_UNAME=Linux)" "the scan reported on a non-macOS host"
  # A secondmate home never raises the host-level wake.
  env_for "$case_dir"
  mate="$case_dir/mate"
  mkdir -p "$mate/state" "$mate/config"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$case_dir/home" > "$mate/.fm-secondmate-parent"
  out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$mate" FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    "${SIM_ENV[@]}" "$IDLE" scan 2>&1)
  assert_not_contains "$out" "$SIM_A" "a secondmate home raised the host-level idle simulator wake"
  assert_contains "$(run_idle "$case_dir" scan)" "$SIM_A" "the root home did not flag the simulator the secondmate home stayed quiet about"
  rm -f "$case_dir/fakebin/xcrun"
  out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_PS="$case_dir/ps" PATH="$(path_without_xcrun "$case_dir")" "$IDLE" scan 2>&1)
  assert_equals "" "$out" "the scan reported on a host without Xcode"
  pass "the idle scan is silent off macOS, in a secondmate home, and without Xcode"
}

test_watcher_wakes_on_an_idle_simulator() {
  local case_dir out rc=0
  case_dir=$(make_case idle-watch)
  boot "$case_dir" "$SIM_A"
  proc_booted "$case_dir" "$SIM_A" "2-00:00:00"
  env_for "$case_dir"
  out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_CHECK_INTERVAL=0 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_NO_EVENT_WAIT=1 "${SIM_ENV[@]}" \
    timeout 60 "$ROOT/bin/fm-watch.sh" 2>&1) || rc=$?
  assert_contains "$out" "check: idle simulator: simulator" "the watcher did not wake on an idle simulator: $out"
  assert_contains "$out" "$SIM_A" "the watcher wake did not name the simulator"
  assert_present "$case_dir/home/state/.sim-idle/$SIM_A" "the watcher did not acknowledge the alert after queueing it"
  pass "the watcher's check cadence wakes firstmate naming an idle simulator"
}

test_spawn_records_the_simulators_already_booted
test_spawn_without_xcode_records_nothing
test_teardown_shuts_down_only_what_the_task_booted
test_teardown_keeps_a_simulator_a_running_tool_targets
test_teardown_keeps_every_candidate_while_unpinned_tooling_runs
test_teardown_unpinned_test_drivers_each_protect
test_teardown_ignores_servers_builds_and_listing
test_teardown_ignores_the_simulators_own_processes
test_teardown_keeps_a_simulator_another_live_task_found_booted
test_teardown_keeps_a_simulator_a_live_peer_may_have_booted
test_teardown_without_a_baseline_or_xcode_is_a_no_op
test_teardown_reports_a_shutdown_that_failed
test_idle_scan_names_an_old_unused_simulator_and_its_possible_owners
test_idle_scan_orphan_and_threshold_config
test_idle_scan_reports_why_it_kept_a_simulator
test_idle_scan_is_not_silenced_by_a_server
test_idle_scan_alerts_once_until_the_quiet_period_passes
test_idle_scan_is_quiet_where_it_should_be
test_watcher_wakes_on_an_idle_simulator
