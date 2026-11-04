#!/usr/bin/env bash
# Behavior tests for quota pool leases: a capped provider pool (one Codex
# account, one Antigravity scope) never gets a second worker launched while a
# lease is held, a lease returns on teardown, `fm-control exit`, or after 30
# minutes of inactivity, and claude is never leased (bin/fm-pool-lease-lib.sh
# owns the contract; bin/fm-spawn.sh gates, bin/fm-pool-lease-tick.sh renews).
#
# Every case drives the real scripts against a fake lease-axi that keeps its
# pools in files, exits 75 when a pool is full, and logs every call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TICK="$ROOT/bin/fm-pool-lease-tick.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-lease)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the project's heavy suite for $2.

## Firstmate spec
Exercise project capacity admission.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

# A Firstmate home with its own backlog (when tasks-axi is installed) and a
# brief for every named task.
make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

# A case: one home, a project clone with an origin, and fake tmux/treehouse
# that record every call so a deferral can be proved to have created nothing.
make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "$*" in
  *"#{pane_current_path}"*)
    # A spawn that is told to hold waits here, after its capacity check and
    # while it still holds the project lock, until the test releases it.
    if [ -n "${FM_FAKE_HOLD:-}" ]; then
      : > "$FM_FAKE_HOLD.reached"
      i=0
      while [ ! -f "$FM_FAKE_HOLD.release" ]; do
        i=$((i + 1))
        [ "$i" -lt 400 ] || exit 1
        sleep 0.05
      done
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
  kill-window)
    target=
    previous=
    for arg in "$@"; do
      [ "$previous" = -t ] && target=$arg
      previous=$arg
    done
    target=${target##*:}
    target=${target#=}
    grep -Fvx -- "$target" "$window_file" 2>/dev/null > "$window_file.tmp" || true
    mv "$window_file.tmp" "$window_file"
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  write_fake_lease_axi "$fakebin"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != models ] || printf '%s\t%s\n' gemini-3-pro "Gemini Pro" gemini-3-flash "Gemini Flash" claude-sonnet-4-5 "Claude Sonnet"
exit 0
SH
  chmod +x "$fakebin/agy"
  mkdir -p "$case_dir/leases"
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  fm_git_init_commit "$case_dir/other-project"
  fm_git_add_origin "$case_dir/other-project" "$case_dir/other-project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

declare_capacity() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/project-capacity"
}

# A live worker already on a project: the record shape bin/fm-spawn.sh
# publishes, with its backlog item In flight so cleanup can close it.
write_live() {  # <home> <id> <project-dir> [extra-line...]
  local home=$1 id=$2 project=$3
  shift 3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/absent-worktree-$id" \
    "project=$project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s-$id" \
    "$@"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    add_item "$home" "$id"
    tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  fi
}

# One isolated worktree per spawn, so every admitted launch has its own copy.
new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() {  # <case-dir> <home> <pane-path> <args...>
  local case_dir=$1 home=$2 pane=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" FAKE_LEASE_DIR="$case_dir/leases" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" --repo-unrecorded-ok 2>&1
}

spawn_ship() {  # <case-dir> <id> [pane-path]
  local case_dir=$1 id=$2 pane=${3:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

# Everything a deferred spawn must not have created for <id>; <worktrees-before>
# is worktree_list taken before the spawn.
assert_nothing_created() {  # <case-dir> <home> <id> <calls-before> <worktrees-before>
  local case_dir=$1 home=$2 id=$3 before=$4 worktrees=$5 after
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a deferred spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] ||
    fail "a deferred spawn touched the terminal or worktree pool for $id: $(tail -n +"$((before + 1))" "$case_dir/calls.log")"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a deferred spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] ||
      fail "a deferred spawn moved $id's backlog item: $(row_state "$home" "$id")"
  fi
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

worktree_list() { git -C "$1/project" worktree list --porcelain; }


# A file-backed lease authority: <dir>/<pool>/<lease-id> holds the holder name.
write_fake_lease_axi() {  # <fakebin>
  cat > "$1/lease-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LEASE_DIR/calls.log"
[ -z "${FAKE_LEASE_DOWN:-}" ] || exit 2
verb=$1
shift
pool= cap=1 holder= lease=
if [ "$verb" = grant ]; then :; else lease=$1; shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --pool) pool=$2; shift ;;
    --cap) cap=$2; shift ;;
    --holder) holder=$2; shift ;;
  esac
  shift
done
case "$verb" in
  grant)
    dir="$FAKE_LEASE_DIR/$(printf '%s' "$pool" | tr '/' '_')"
    mkdir -p "$dir"
    n=$(find "$dir" -type f | wc -l | tr -d ' ')
    if [ "$n" -ge "$cap" ]; then
      holders=$(for f in "$dir"/*; do printf '{"holder":"%s"},' "$(cat "$f")"; done)
      printf '{"granted":false,"holders":[%s]}\n' "${holders%,}"
      exit 75
    fi
    id="L$(date +%s)$RANDOM"
    printf '%s' "$holder" > "$dir/$id"
    printf '{"granted":true,"lease":{"id":"%s"}}\n' "$id"
    ;;
  renew)
    f=$(find "$FAKE_LEASE_DIR" -type f -name "$lease" | head -1)
    [ -n "$f" ] || exit 1
    touch "$f"
    ;;
  release)
    find "$FAKE_LEASE_DIR" -type f -name "$lease" -delete
    ;;
esac
exit 0
SH
  chmod +x "$1/lease-axi"
}

held_count() {  # <case-dir> [pool-dir-name]
  find "$1/leases" -type f ! -name calls.log -path "*${2:-}*" | wc -l | tr -d ' '
}

declare_pool_lease() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "authority http://lease.test:9" "$@" > "$home/config/pool-lease"
}

spawn_with() {  # <case-dir> <id> <harness> [model]
  local case_dir=$1 id=$2 harness=$3 model=${4:-} pane args
  pane="$case_dir/wt-$id"
  [ -d "$pane" ] || new_worktree "$case_dir" "$id" >/dev/null
  args=(--mode no-mistakes --yolo off --harness "$harness")
  [ -z "$model" ] || args+=(--model "$model")
  run_spawn "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" "${args[@]}"
}

run_tool() {  # <case-dir> <script> <args...>
  local case_dir=$1 script=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_CALL_LOG="$case_dir/calls.log" FAKE_LEASE_DIR="$case_dir/leases" PATH="$case_dir/fakebin:$PATH" \
    "$script" "$@" 2>&1
}

touch_epoch() {  # <file> <epoch>
  touch -t "$(date -r "$2" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$2" +%Y%m%d%H%M.%S)" "$1"
}

# --- cases ------------------------------------------------------------------

test_absent_config_changes_nothing() {
  local case_dir out rc=0
  case_dir=$(make_case absent task-a task-b)
  out=$(spawn_with "$case_dir" task-a codex) || rc=$?
  expect_code 0 "$rc" "no pool-lease config refused a spawn: $out"
  out=$(spawn_with "$case_dir" task-b codex) || rc=$?
  expect_code 0 "$rc" "no pool-lease config capped a second codex spawn: $out"
  [ ! -s "$case_dir/leases/calls.log" ] || fail "lease-axi was called with no config"
  assert_absent "$case_dir/home/state/task-a.pool-lease" "a lease record exists with no config"
  pass "an absent config/pool-lease leaves spawn behaviour unchanged"
}

test_second_capped_spawn_defers_and_release_frees() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case codex task-a task-b task-c)
  home="$case_dir/home"
  declare_pool_lease "$home" "cap codex 1"
  out=$(spawn_with "$case_dir" task-a codex) || rc=$?
  expect_code 0 "$rc" "the first codex spawn was refused: $out"
  assert_present "$home/state/task-a.pool-lease" "the first spawn recorded no lease"
  [ "$(held_count "$case_dir")" = 1 ] || fail "the authority does not hold one lease"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  # new_worktree adds a worktree; list after it so only the spawn's own effect counts.
  local pane
  pane=$(new_worktree "$case_dir" task-b)
  worktrees=$(worktree_list "$case_dir")
  before=$(call_count "$case_dir")
  rc=0
  out=$(run_spawn "$case_dir" "$home" "$pane" task-b "$case_dir/project" --mode no-mistakes --yolo off --harness codex) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a second codex spawn was not deferred: $out"
  assert_contains "$out" "deferred: quota pool codex/codex-home/default" "the deferral did not name the pool"
  assert_contains "$out" "task-b was not launched and its backlog item stays queued" "the deferral did not say the task stays queued"
  assert_nothing_created "$case_dir" "$home" task-b "$before" "$worktrees"

  # Standard-tooling release frees the pool.
  out=$(run_tool "$case_dir" "$TEARDOWN" task-a) || fail "teardown failed: $out"
  assert_absent "$home/state/task-a.pool-lease" "teardown left the lease record"
  [ "$(held_count "$case_dir")" = 0 ] || fail "teardown did not release the lease at the authority"
  rc=0
  out=$(run_spawn "$case_dir" "$home" "$pane" task-b "$case_dir/project" --mode no-mistakes --yolo off --harness codex) || rc=$?
  expect_code 0 "$rc" "the freed pool did not admit the deferred task: $out"
  pass "a second capped spawn defers 75 and creates nothing; teardown frees the pool"
}

test_claude_is_never_leased() {
  local case_dir home out rc=0 id
  case_dir=$(make_case claude task-a task-b task-c)
  home="$case_dir/home"
  declare_pool_lease "$home" "cap codex 1" "cap agy 1"
  for id in task-a task-b task-c; do
    rc=0
    out=$(spawn_with "$case_dir" "$id" claude) || rc=$?
    expect_code 0 "$rc" "a claude spawn was capped: $out"
    assert_absent "$home/state/$id.pool-lease" "claude took a lease"
  done
  [ ! -s "$case_dir/leases/calls.log" ] || fail "lease-axi was called for claude"
  pass "claude is uncapped and never leased"
}

test_pools_are_per_scope_and_account() {
  local case_dir home out rc=0 pool
  case_dir=$(make_case scopes task-a task-b task-c)
  home="$case_dir/home"
  declare_pool_lease "$home" "cap codex 1" "cap agy 1"
  # The pool id each harness/model resolves to (the quota-axi provider +
  # accountKey + scope join).
  (
    # shellcheck source=bin/fm-pool-lease-lib.sh
    . "$ROOT/bin/fm-timeout-lib.sh"
    . "$ROOT/bin/fm-wake-lib.sh"
    . "$ROOT/bin/fm-pool-lease-lib.sh"
    fm_pool_lease_load "$home/config"
    check() {  # <harness> <model> <expected-pool-or-empty>
      fm_pool_lease_resolve "$1" "$2"
      [ "$FM_POOL_LEASE_POOL" = "$3" ] || fail "$1 $2 resolved to '$FM_POOL_LEASE_POOL', wanted '$3'"
    }
    check agy gemini-3-pro agy/default/gemini
    check agy gemini-3-flash agy/default/gemini
    check agy claude-sonnet-4-5 agy/default/claude_gpt
    check agy gemini-3-pro-argon agy/default/argon
    check codex gpt-5 codex/codex-home/default
    check claude opus ""
  ) || exit 1
  # The gemini pool is full: a gemini spawn defers, another scope and another
  # provider pass the gate.
  mkdir -p "$case_dir/leases/agy_default_gemini"
  printf 'someone-else' > "$case_dir/leases/agy_default_gemini/other"
  out=$(spawn_with "$case_dir" task-a agy gemini-3-flash) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a gemini spawn was admitted to a full gemini pool: $out"
  assert_contains "$out" "deferred: quota pool agy/default/gemini" "the deferral did not name the gemini pool"
  rc=0
  out=$(spawn_with "$case_dir" task-b agy claude-sonnet-4-5) || rc=$?
  assert_not_contains "$out" "deferred:" "a claude_gpt spawn shared the gemini pool: $out"
  rc=0
  out=$(spawn_with "$case_dir" task-c codex) || rc=$?
  expect_code 0 "$rc" "codex shared an agy pool: $out"
  pass "each Antigravity scope and each Codex account is its own pool"
}

test_unreachable_authority_refuses_capped_spawn() {
  local case_dir home out rc=0
  case_dir=$(make_case down task-a task-b)
  home="$case_dir/home"
  declare_pool_lease "$home" "cap codex 1"
  out=$(FAKE_LEASE_DOWN=1 spawn_with "$case_dir" task-a codex) || rc=$?
  expect_code 1 "$rc" "an unreachable authority did not refuse: $out"
  assert_contains "$out" "lease authority could not grant a lease" "the refusal did not name the authority"
  assert_absent "$home/state/task-a.meta" "a refused spawn left a record"
  rc=0
  out=$(FAKE_LEASE_DOWN=1 spawn_with "$case_dir" task-b claude) || rc=$?
  expect_code 0 "$rc" "an unreachable authority blocked an uncapped claude spawn: $out"
  pass "an unreachable authority refuses a capped spawn and never an uncapped one"
}

test_unreadable_config_refuses() {
  local case_dir home out rc=0 body
  case_dir=$(make_case unreadable task-a)
  home="$case_dir/home"
  for body in 'cap codex 1\n' 'authority http://x\ncap claude 1\n' 'authority http://x\ncap codex zero\n'; do
    printf '%b' "$body" > "$home/config/pool-lease"
    rc=0
    out=$(spawn_with "$case_dir" task-a codex) || rc=$?
    expect_code 1 "$rc" "an unreadable declaration did not refuse ($body): $out"
    assert_contains "$out" "the pool lease declaration is unreadable" "the refusal did not name the declaration"
  done
  pass "an unreadable pool-lease declaration refuses the spawn"
}

test_failed_spawn_releases_its_lease() {
  local case_dir home out rc=0
  case_dir=$(make_case failed task-a task-b)
  home="$case_dir/home"
  declare_pool_lease "$home" "cap codex 1"
  printf '%s\n' '# Task' "## Captain's intent" '{TASK}' '' '## Firstmate spec' 'x' > "$home/data/task-a/brief.md"
  out=$(spawn_with "$case_dir" task-a codex) || rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne "$DEFER_EXIT" ] || fail "an invalid brief did not fail (exit $rc): $out"
  assert_absent "$home/state/task-a.pool-lease" "a failed spawn kept its lease record"
  [ "$(held_count "$case_dir")" = 0 ] || fail "a failed spawn kept its lease at the authority"
  rc=0
  out=$(spawn_with "$case_dir" task-b codex) || rc=$?
  expect_code 0 "$rc" "a failed spawn kept holding the pool: $out"
  pass "a spawn that fails after the grant gives its lease back"
}

# fm-control exit needs a live agent endpoint that proves the exit, which the
# fake terminal here cannot stage, so this pins the wiring: the exit verb
# releases the task's lease only after do_exit has returned, and the release
# itself is the one the teardown case above proves against the authority.
test_control_exit_releases() {
  local body
  body=$(awk '/^  exit\)/{f=1} f&&/^  relaunch\)/{exit} f' "$ROOT/bin/fm-control.sh")
  # shellcheck disable=SC2016  # literal source text to find, not an expansion
  assert_contains "$body" 'result=$(do_exit)' "the exit verb no longer runs do_exit"
  # shellcheck disable=SC2016  # literal source text to find, not an expansion
  assert_contains "$body" 'fm_pool_lease_release "$STATE" "$ID"' "fm-control exit does not release the pool lease"
  [ "${body%%do_exit*}" != "$body" ] && [ "${body%%fm_pool_lease_release*}" != "$body" ] || fail "missing calls"
  case "$body" in
    *do_exit*fm_pool_lease_release*) ;;
    *) fail "the lease is released before the worker has exited" ;;
  esac
  grep -q 'fm-pool-lease-lib.sh' "$ROOT/bin/fm-control.sh" || fail "fm-control does not source the pool lease lib"
  pass "fm-control exit releases the lease after the worker has exited"
}

# Renewal rides the activity the watcher already sees; inactivity of 30 minutes
# releases, and a declared pause counts as inactive.
test_tick_renews_only_while_active_and_releases_after_30_minutes() {
  local case_dir home out rc=0 now lease
  case_dir=$(make_case tick task-a)
  home="$case_dir/home"
  declare_pool_lease "$home" "cap codex 1" "ttl 3m"
  out=$(spawn_with "$case_dir" task-a codex) || rc=$?
  expect_code 0 "$rc" "spawn refused: $out"
  lease=$(sed -n 's/^lease=//p' "$home/state/task-a.pool-lease")
  now=$(date +%s)

  # Active: a fresh status line, renewal due -> renewed, still held.
  printf 'working\n' > "$home/state/task-a.status"
  : > "$case_dir/leases/calls.log"
  FM_POOL_LEASE_NOW=$((now + 120)) run_tool "$case_dir" "$TICK" >/dev/null
  assert_contains "$(cat "$case_dir/leases/calls.log")" "renew $lease" "an active holder was not renewed"
  [ "$(held_count "$case_dir")" = 1 ] || fail "renewal dropped the lease"

  # Inactive for 31 minutes: released, record marked lapsed, pool free.
  : > "$case_dir/leases/calls.log"
  FM_POOL_LEASE_NOW=$((now + 31 * 60)) run_tool "$case_dir" "$TICK" >/dev/null
  assert_not_contains "$(cat "$case_dir/leases/calls.log")" "renew" "an idle holder was renewed"
  assert_contains "$(cat "$case_dir/leases/calls.log")" "release $lease" "an idle holder was not released"
  [ "$(held_count "$case_dir")" = 0 ] || fail "30 idle minutes did not free the pool"
  assert_contains "$(cat "$home/state/task-a.pool-lease")" "lapsed=" "the lapse was not recorded"
  pass "a lease is renewed only while the holder is active and released after 30 idle minutes"
}

test_tick_does_not_release_before_30_minutes() {
  local case_dir home out rc=0 now
  case_dir=$(make_case young task-a)
  home="$case_dir/home"
  declare_pool_lease "$home" "cap codex 1"
  out=$(spawn_with "$case_dir" task-a codex) || rc=$?
  expect_code 0 "$rc" "spawn refused: $out"
  now=$(date +%s)
  FM_POOL_LEASE_NOW=$((now + 29 * 60)) run_tool "$case_dir" "$TICK" >/dev/null
  [ "$(held_count "$case_dir")" = 1 ] || fail "a holder idle for 29 minutes lost its lease"
  pass "a holder idle for under 30 minutes keeps its lease"
}

test_declared_pause_counts_as_inactive() {
  local case_dir home out rc=0 now
  case_dir=$(make_case paused task-a)
  home="$case_dir/home"
  declare_pool_lease "$home" "cap codex 1"
  out=$(spawn_with "$case_dir" task-a codex) || rc=$?
  expect_code 0 "$rc" "spawn refused: $out"
  now=$(date +%s)
  printf 'paused: waiting on the captain\n' > "$home/state/task-a.status"
  # The pause was declared 31 minutes ago; the status file is its newest signal.
  FM_POOL_LEASE_NOW=$((now + 31 * 60)) run_tool "$case_dir" "$TICK" >/dev/null
  [ "$(held_count "$case_dir")" = 0 ] || fail "a declared pause kept its lease past 30 minutes"
  pass "a declared paused: wait counts as inactive"
}

test_lapsed_lease_is_retaken_when_active_again() {
  local case_dir home out rc=0 now
  case_dir=$(make_case retake task-a)
  home="$case_dir/home"
  declare_pool_lease "$home" "cap codex 1"
  out=$(spawn_with "$case_dir" task-a codex) || rc=$?
  expect_code 0 "$rc" "spawn refused: $out"
  now=$(date +%s)
  FM_POOL_LEASE_NOW=$((now + 31 * 60)) run_tool "$case_dir" "$TICK" >/dev/null
  [ "$(held_count "$case_dir")" = 0 ] || fail "lapse did not free the pool"

  # Another worker takes the freed pool; the lapsed holder waking up must wait.
  mkdir -p "$case_dir/leases/codex_codex-home_default"
  printf 'someone-else' > "$case_dir/leases/codex_codex-home_default/other"
  printf 'working\n' > "$home/state/task-a.status"
  touch_epoch "$home/state/task-a.status" $((now + 32 * 60))
  out=$(FM_POOL_LEASE_NOW=$((now + 32 * 60)) run_tool "$case_dir" "$TICK")
  assert_contains "$out" "is held" "an active lapsed holder did not warn while the pool was held"
  [ "$(held_count "$case_dir")" = 1 ] || fail "the lapsed holder took a place that was not free"

  rm -f "$case_dir/leases/codex_codex-home_default/other"
  FM_POOL_LEASE_NOW=$((now + 33 * 60)) run_tool "$case_dir" "$TICK" >/dev/null
  [ "$(held_count "$case_dir")" = 1 ] || fail "the lapsed holder did not retake the freed pool"
  assert_not_contains "$(cat "$home/state/task-a.pool-lease")" "lapsed=" "the retaken lease is still marked lapsed"
  pass "a lapsed holder that is active again retakes its lease, waiting while the pool is held"
}

test_pool_lease_is_inherited_by_secondmates() {
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  case " $(fm_config_inherit_items | tr '\n' ' ') " in
    *" config/pool-lease "*) ;;
    *) fail "pool-lease is not in the inheritable config set" ;;
  esac
  pass "config/pool-lease is inherited by secondmates"
}


fm_test_run \
  test_absent_config_changes_nothing \
  test_second_capped_spawn_defers_and_release_frees \
  test_claude_is_never_leased \
  test_pools_are_per_scope_and_account \
  test_unreachable_authority_refuses_capped_spawn \
  test_unreadable_config_refuses \
  test_failed_spawn_releases_its_lease \
  test_control_exit_releases \
  test_tick_renews_only_while_active_and_releases_after_30_minutes \
  test_tick_does_not_release_before_30_minutes \
  test_declared_pause_counts_as_inactive \
  test_lapsed_lease_is_retaken_when_active_again \
  test_pool_lease_is_inherited_by_secondmates
