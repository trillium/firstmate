#!/usr/bin/env bash
# fm-control.sh suspend/resume: parking and restoring a persistent secondmate.
#
# suspend and resume are the only control verbs that create and remove the
# durable state/<id>.suspended record, so these tests pin that lifecycle,
# hermetically (stubbed tmux, real fm-spawn for the restore, no real agent):
#   1. A live secondmate is parked: the agent is stopped, the v1 record lands
#      with the home snapshot, and a note becomes reason= on the record.
#   2. An already-missing endpoint still parks: the record is written with
#      agent=no-agent and nothing is sent into the stale target.
#   3. Refusals before anything runs: a non-secondmate kind, an existing
#      record, a home that is not a worktree root, an unmarked home, an
#      unreadable head, and an unattributed endpoint all refuse with no record
#      and no stopped agent.
#   4. resume without a record refuses with the determinism explanation, and
#      resume onto a live agent refuses as a contradiction with the record
#      intact.
#   5. A failed relaunch keeps the record so a later resume can retry.
#   6. A full suspend -> resume round trip restores the parked home byte for
#      byte: same worktree, same HEAD, uncommitted work preserved, the record
#      removed, and the relaunched agent alive again.
#   7. The session-start liveness sweep exempts a parked home: a suspended
#      secondmate is neither probed nor attributed.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-suspend)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()
REAL_GIT=$(command -v git)
REAL_MV=$(command -v mv)

suspend_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap suspend_cleanup EXIT

# The same lifecycle-modelling tmux stub as tests/fm-control-relaunch.test.sh:
# the harness's /exit literal stops the agent, a launch-brief literal starts
# the harness named in `becomes`, and list-windows/display-message drive the
# backend's liveness classifier.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          ;;
        *'encode launch-brief'*)
          cat "$D/becomes" > "$D/command"
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\n'; exit 0 ;;
  new-window)
    prev=
    for a in "$@"; do
      if [ "$prev" = -n ]; then
        [ -f "$D/windows" ] || : > "$D/windows"
        grep -qxF "$a" "$D/windows" || printf '%s\n' "$a" >> "$D/windows"
      fi
      prev=$a
    done
    exit 0 ;;
  kill-window) : > "$D/windows"; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf 'bare sleep is forbidden in control/suspend paths\n' >&2
exit 97
SH
  chmod +x "$fb/sleep"
}

new_case() {  # <name> [id] -> echoes a case dir with a live claude ship task.
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf 'fakepath' > "$dir/fake/cwd"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id>: a ship task so suspend's secondmate-only guard
# has something non-secondmate to refuse.
add_ship_task() {
  local dir=$1 id=$2
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n\nDo the thing.\n' "$id" > "$home/data/$id/brief.md"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "model=default" \
    "effort=default"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

# sm_case <name> <id>: a live claude secondmate whose home is a real isolated
# git worktree marked and registered exactly like a seeded persistent home.
# Echoes the case dir.
sm_case() {
  local name=$1 id=$2
  local dir="$TMP_ROOT/$name-$RANDOM"
  local home="$dir/home" smhome="$dir/smhome"
  mkdir -p "$home/state" "$home/data" "$home/config" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/windows"
  fm_git_worktree "$dir/proj" "$smhome" sm-branch
  mkdir -p "$smhome/bin" "$smhome/state" "$smhome/data" "$smhome/config" "$smhome/projects"
  printf '# Firstmate\n' > "$smhome/AGENTS.md"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# charter\n\nCustomer onboarding charter.\n' > "$smhome/data/charter.md"
  printf 'claude sonnet\n' > "$home/config/secondmate-harness"
  printf 'tmux\n' > "$home/config/backend"
  fm_register_secondmate "$home/data/secondmates.md" "$id" "$smhome" \
    'customer onboarding from brief' 'alpha, beta'
  git -C "$smhome" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' add -A
  git -C "$smhome" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture-home || true
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$smhome" \
    "project=$smhome" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "model=default" \
    "effort=default" \
    "home=$smhome" \
    "projects=alpha, beta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s' "$smhome" > "$dir/fake/cwd"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT="$ROOT" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_REAL_GIT="${FM_REAL_GIT:-$REAL_GIT}" FM_FAKE_GIT_FAILURE="${FM_FAKE_GIT_FAILURE:-}" \
    FM_REAL_MV="${FM_REAL_MV:-$REAL_MV}" \
    "$CONTROL" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

record_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.suspended" | tail -1 | cut -d= -f2-
}

sm_home() {  # <case-dir> <id>
  meta_field "$1" "$2" worktree
}

make_git_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_GIT_FAILURE:-}:$*" in
  head:*' rev-parse --verify HEAD'|head:*' symbolic-ref -q HEAD') exit 128 ;;
  status:*' status --porcelain') exit 128 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$1/fakebin/git"
}

# --- 1. suspend: parking, snapshots, and notes ------------------------------

test_suspend_parks_a_live_secondmate_and_snapshots_the_home() {
  local dir home id=sm1 out rc head
  dir=$(sm_case park "$id")
  home=$(sm_home "$dir" "$id")
  head=$(git -C "$home" rev-parse HEAD)
  out=$(run_control "$dir" "$id" suspend --note "wintering this secondmate"); rc=$?
  expect_code 0 "$rc" "suspending a live secondmate should succeed"$'\n'"$out"
  assert_contains "$out" "suspended $id backend=tmux endpoint=firstmate:fm-$id" \
    "the outcome should name the parked endpoint"
  assert_contains "$out" "recorded=$dir/home/state/$id.suspended" \
    "the outcome should name the durable record"
  assert_present "$dir/home/state/$id.suspended" "suspend wrote no durable record"
  [ "$(record_field "$dir" "$id" task)" = "$id" ] || fail "record task id is wrong"
  [ "$(record_field "$dir" "$id" kind)" = secondmate ] || fail "record kind is wrong"
  [ "$(record_field "$dir" "$id" backend)" = tmux ] || fail "record backend is wrong"
  [ "$(record_field "$dir" "$id" endpoint)" = "firstmate:fm-$id" ] || fail "record endpoint is wrong"
  [ "$(record_field "$dir" "$id" worktree)" = "$home" ] || fail "record worktree is wrong"
  [ "$(record_field "$dir" "$id" worktree_head)" = "$head" ] || fail "record head is wrong"
  [ "$(record_field "$dir" "$id" worktree_dirty)" = no ] || fail "record should report a clean home"
  [ "$(record_field "$dir" "$id" reason)" = "wintering this secondmate" ] \
    || fail "record reason did not carry the note"
  [ "$(grep -c '^v1$' "$dir/home/state/$id.suspended")" -eq 1 ] || fail "record version line is missing or ambiguous"
  [ "$(cat "$dir/fake/command")" = zsh ] || fail "a live agent must be stopped by suspend"
  assert_grep "suspended: secondmate $id parked on tmux endpoint firstmate:fm-$id until resumption (agent=stopped)" \
    "$dir/home/state/$id.status" "suspend did not append its status event"
  pass "suspend: a live secondmate is stopped and its home snapshot lands in the record"
}

test_suspend_records_a_dirty_home() {
  local dir home id=sm2 out rc
  dir=$(sm_case dirty "$id")
  home=$(sm_home "$dir" "$id")
  printf 'uncommitted work\n' > "$home/notes.txt"
  out=$(run_control "$dir" "$id" suspend); rc=$?
  expect_code 0 "$rc" "suspending a secondmate with local changes should succeed"$'\n'"$out"
  [ "$(record_field "$dir" "$id" worktree_dirty)" = yes ] \
    || fail "record should report an uncommitted home, got '$(record_field "$dir" "$id" worktree_dirty)'"
  pass "suspend: an uncommitted home is recorded as dirty"
}

test_suspend_parks_an_already_missing_endpoint_without_sending_anything() {
  local dir home id=sm3 out rc
  dir=$(sm_case gone "$id")
  home=$(sm_home "$dir" "$id")
  : > "$dir/fake/windows"
  out=$(run_control "$dir" "$id" suspend); rc=$?
  expect_code 0 "$rc" "suspending a secondmate whose endpoint is gone should park it"$'\n'"$out"
  assert_contains "$out" "agent=no-agent" "the outcome should report nothing was stopped"
  assert_present "$dir/home/state/$id.suspended" "a missing endpoint must still write the record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "suspend must not send anything to a stale target"
  pass "suspend: an already-missing endpoint parks the home and sends no lifecycle key"
}

# --- 2. suspend refusals ----------------------------------------------------

test_suspend_refuses_a_ship_task() {
  local dir out rc id=sh1
  dir=$(new_case ship-refusal "$id")
  add_ship_task "$dir" "$id"
  out=$(run_control "$dir" "$id" suspend); rc=$?
  expect_code 1 "$rc" "a ship task must not be suspendable"$'\n'"$out"
  assert_contains "$out" "only a persistent secondmate can be suspended" \
    "the refusal should name the secondmate-only kind"
  assert_absent "$dir/home/state/$id.suspended" "a refused suspend must write no record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused suspend must not stop the agent"
  pass "suspend: a non-secondmate task is refused before anything runs"
}

test_suspend_refuses_an_existing_record() {
  local dir id=sm4 out rc before
  dir=$(sm_case twice "$id")
  printf 'v1\ntask=%s\n' "$id" > "$dir/home/state/$id.suspended"
  before=$(cat "$dir/home/state/$id.suspended")
  out=$(run_control "$dir" "$id" suspend); rc=$?
  expect_code 1 "$rc" "suspending an already-suspended secondmate must refuse"$'\n'"$out"
  assert_contains "$out" "already suspended" "the refusal should name the existing record"
  [ "$(cat "$dir/home/state/$id.suspended")" = "$before" ] \
    || fail "a refused suspend must leave the existing record untouched"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused suspend must not stop the agent"
  pass "suspend: an existing record refuses and the agent is untouched"
}

test_suspend_refuses_a_home_that_is_not_a_worktree_root() {
  local dir home id=sm5 out rc
  dir=$(sm_case subdir "$id")
  home=$(sm_home "$dir" "$id")
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$home/data" "project=$home" \
    "harness=claude" "kind=secondmate" "mode=secondmate" \
    "yolo=off" "model=default" "effort=default" "home=$home" "projects=alpha"
  out=$(run_control "$dir" "$id" suspend); rc=$?
  expect_code 1 "$rc" "a home that is not a worktree root must refuse"$'\n'"$out"
  assert_contains "$out" "not a worktree root" "the refusal should name the ambiguous checkout"
  assert_absent "$dir/home/state/$id.suspended" "a refused suspend must write no record"
  pass "suspend: a subdirectory home is refused as an ambiguous checkout"
}

test_suspend_refuses_an_unmarked_home() {
  local dir home id=sm6 out rc
  dir=$(sm_case unmarked "$id")
  home=$(sm_home "$dir" "$id")
  printf 'other\n' > "$home/.fm-secondmate-home"
  out=$(run_control "$dir" "$id" suspend); rc=$?
  expect_code 1 "$rc" "a home marked for another secondmate must refuse"$'\n'"$out"
  assert_contains "$out" "not marked as its own seeded secondmate home" \
    "the refusal should name the marker mismatch"
  assert_absent "$dir/home/state/$id.suspended" "a refused suspend must write no record"
  pass "suspend: a wrong identity marker is refused"
}

test_suspend_refuses_an_uninspectable_head() {
  local dir id=sm7 out rc
  dir=$(sm_case badhead "$id")
  make_git_failure_stub "$dir"
  # shellcheck disable=SC2209 # the prefix sets the stub's injected failure, not a command
  out=$(FM_FAKE_GIT_FAILURE=head run_control "$dir" "$id" suspend); rc=$?
  expect_code 1 "$rc" "an unreadable home HEAD must refuse"$'\n'"$out"
  assert_contains "$out" "HEAD cannot be inspected" "the refusal should name the unreadable head"
  assert_absent "$dir/home/state/$id.suspended" "a refused suspend must write no record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused suspend must not stop the agent"
  pass "suspend: an unreadable home head refuses before the agent is touched"
}

test_suspend_refuses_an_unattributed_endpoint() {
  local dir id=sm8 out rc
  dir=$(sm_case unattributed "$id")
  : > "$dir/fake/command"
  out=$(run_control "$dir" "$id" suspend); rc=$?
  expect_code 1 "$rc" "an unattributed endpoint must refuse"$'\n'"$out"
  assert_contains "$out" "unattributed endpoint" "the refusal should name the ambiguous verdict"
  assert_absent "$dir/home/state/$id.suspended" "a refused suspend must write no record"
  pass "suspend: an endpoint that cannot be classified is refused"
}

test_suspend_parks_with_a_note_file() {
  local dir id=sm9 out rc
  dir=$(sm_case notefile "$id")
  printf 'paused for upstream review\n' > "$dir/note.txt"
  out=$(run_control "$dir" "$id" suspend --note-file "$dir/note.txt"); rc=$?
  expect_code 0 "$rc" "a note file should be accepted on suspend"$'\n'"$out"
  [ "$(record_field "$dir" "$id" reason)" = "paused for upstream review" ] \
    || fail "the note file's content did not land on the record"
  pass "suspend: --note-file content lands on the record"
}

test_suspend_resume_refuse_relaunch_only_flags() {
  local dir id=sm10 out rc
  dir=$(sm_case flags "$id")
  out=$(run_control "$dir" "$id" suspend --harness codex); rc=$?
  expect_code 1 "$rc" "--harness must refuse on suspend"$'\n'"$out"
  assert_contains "$out" "apply to 'relaunch' only" "the refusal should name the relaunch-only flags"
  assert_absent "$dir/home/state/$id.suspended" "a refused suspend must write no record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused suspend must not stop the agent"
  pass "suspend/resume: --harness, --model, and --effort refuse before anything runs"
}

# --- 3. resume refusals and retention ---------------------------------------

test_resume_without_a_record_refuses_with_the_determinism_explanation() {
  local dir id=sm11 out rc
  dir=$(sm_case nopark "$id")
  out=$(run_control "$dir" "$id" resume); rc=$?
  expect_code 1 "$rc" "resume without a record must refuse"$'\n'"$out"
  assert_contains "$out" "no suspension record" "the refusal should name the missing record"
  assert_contains "$out" "relaunch' is the deterministic way to replace a running agent" \
    "the refusal should point pane-session resume away"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused resume must not disturb the agent"
  pass "resume: without a record it refuses and points at relaunch, not a pane-session guess"
}

test_resume_refuses_a_live_agent_despite_a_record() {
  local dir id=sm12 out rc record_before
  dir=$(sm_case contradiction "$id")
  printf 'v1\ntask=%s\n' "$id" > "$dir/home/state/$id.suspended"
  record_before=$(cat "$dir/home/state/$id.suspended")
  out=$(run_control "$dir" "$id" resume); rc=$?
  expect_code 1 "$rc" "resume onto a live agent must refuse"$'\n'"$out"
  assert_contains "$out" "despite its suspension record" \
    "the refusal should name the contradiction"
  [ "$(cat "$dir/home/state/$id.suspended")" = "$record_before" ] \
    || fail "a refused resume must not touch the record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused resume must not disturb the agent"
  pass "resume: a live agent under a record is a refusal, and the record survives"
}

test_resume_failed_launch_keeps_the_record() {
  local dir id=sm13 out rc
  dir=$(sm_case launchfail "$id")
  : > "$dir/home/state/$id.suspended"
  rm -f "$dir/home/state/$id.meta"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/smhome" "project=$dir/smhome" \
    "harness=claude" "kind=secondmate" "mode=secondmate" \
    "yolo=off" "model=default" "effort=default"
  rm -f "$dir/home/data/secondmates.md"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_control "$dir" "$id" resume); rc=$?
  expect_code 1 "$rc" "a resume whose relaunch fails must refuse"$'\n'"$out"
  assert_contains "$out" "could not relaunch" "the refusal should name the failed relaunch"
  assert_contains "$out" "record is retained" "the refusal should promise a later retry"
  assert_present "$dir/home/state/$id.suspended" "a failed resume must keep the record"
  pass "resume: a failed relaunch retains the record"
}

# --- 4. the round trip ------------------------------------------------------

test_suspend_resume_round_trip_restores_the_parked_home() {
  local dir id=sm14 home out rc head
  dir=$(sm_case roundtrip "$id")
  home=$(sm_home "$dir" "$id")
  head=$(git -C "$home" rev-parse HEAD)
  printf 'winter note\n' > "$home/data/local-note.txt"

  out=$(run_control "$dir" "$id" suspend); rc=$?
  expect_code 0 "$rc" "the round-trip suspend should succeed"$'\n'"$out"
  assert_present "$dir/home/state/$id.suspended" "the round trip never parked"
  [ "$(cat "$dir/fake/command")" = zsh ] || fail "the round trip never stopped the agent"

  out=$(run_control "$dir" "$id" resume --note "back after the break"); rc=$?
  expect_code 0 "$rc" "the round-trip resume should succeed"$'\n'"$out"
  assert_contains "$out" "resumed $id backend=tmux endpoint=firstmate:fm-$id" \
    "the outcome should name the restored endpoint"
  assert_absent "$dir/home/state/$id.suspended" "resume must remove the durable record"
  assert_grep "resumed: secondmate $id relaunched on tmux endpoint firstmate:fm-$id (agent=alive)" \
    "$dir/home/state/$id.status" "resume did not append its status event"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "resume must bring the agent back alive"
  [ "$(git -C "$home" rev-parse HEAD)" = "$head" ] \
    || fail "resume must not move the home's HEAD"
  [ "$(cat "$home/data/local-note.txt")" = "winter note" ] \
    || fail "resume lost uncommitted work in the parked home"
  [ "$(cat "$home/.fm-secondmate-home")" = "$id" ] \
    || fail "resume must leave the home's identity marker intact"
  pass "resume: a parked secondmate round-trips byte-identical and comes back alive"
}

# --- 5. the liveness sweep exemption ----------------------------------------

# The same fake toolchain stubbing as tests/fm-bootstrap.test.sh, minimal for
# the deferred-network half: the sweep must attribute a normal secondmate but
# never touch a suspended one.
make_fake_toolchain() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_GH_AXI_VERSION:-0.1.29}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_NO_MISTAKES_VERSION:-no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  add_tasks_axi "$fakebin" "0.2.4"
  add_quota_axi "$fakebin"
  printf '%s\n' "$fakebin"
}

add_quota_axi() {
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_QUOTA_AXI_VERSION:-0.1.17}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
}

add_tasks_axi() {
  local fakebin=$1 version=$2
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

# assert_timing_record <log> <scope> <name>: one bin/fm-timing-lib.sh record
# with exactly this scope/name must exist.
assert_timing_record() {
  local log=$1 scope=$2 name=$3
  awk -F'\t' -v s="$scope" -v n="$name" '$1 == "v1" && $2 == s && $3 == n { found = 1 }
    END { exit found ? 0 : 1 }' "$log" || fail "no '$scope $name' timing record in: $(cat "$log")"
}

assert_no_timing_record() {
  local log=$1 scope=$2 name=$3
  ! awk -F'\t' -v s="$scope" -v n="$name" '$1 == "v1" && $2 == s && $3 == n { found = 1 }
    END { exit found ? 0 : 1 }' "$log" \
    || fail "a suspended secondmate must not be attributed a '$scope $name' timing record in: $(cat "$log")"
}

test_bootstrap_skips_a_suspended_secondmate_in_the_liveness_sweep() {
  local case_dir fakebin log out base_path
  base_path=${BASE_PATH:-$PATH}
  # shellcheck disable=SC2329 # Exported and invoked by the bootstrap subprocess.
    sleep() { /bin/sleep 0.01; }
  export -f sleep
  case_dir="$TMP_ROOT/liveness"
  mkdir -p "$case_dir/home/config" "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/projects"
  mkdir -p "$case_dir/mate-a-home"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' $$ > "$case_dir/home/state/.lock"
  fakebin=$(make_fake_toolchain "$case_dir")
  fm_write_secondmate_meta "$case_dir/home/state/mate-a.meta" "$case_dir/mate-a-home" 'firstmate:fm-mate-a'

  log="$case_dir/timings.tsv"
  PATH="$fakebin:$base_path" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=$$ FM_TIMING_LOG="$log" FM_TIMING_EPOCH_MS=0 \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_timing_record "$log" secondmate liveness mate-a \
    "an ordinary secondmate must be attributed by the sweep"

  rm -f "$log"
  : > "$case_dir/home/state/mate-a.suspended"
  out=$(PATH="$fakebin:$base_path" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=$$ FM_TIMING_LOG="$log" FM_TIMING_EPOCH_MS=0 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_no_timing_record "$log" secondmate liveness mate-a \
    "a suspended secondmate must not be liveness-attributed"
  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate mate-a" \
    "a suspended secondmate must not be probed or attributed by the liveness sweep"
  unset -f sleep
  pass "bootstrap: the liveness sweep exempts a parked secondmate from probing and attribution"
}

# --- runner --------------------------------------------------------------

test_suspend_parks_a_live_secondmate_and_snapshots_the_home
test_suspend_records_a_dirty_home
test_suspend_parks_an_already_missing_endpoint_without_sending_anything
test_suspend_refuses_a_ship_task
test_suspend_refuses_an_existing_record
test_suspend_refuses_a_home_that_is_not_a_worktree_root
test_suspend_refuses_an_unmarked_home
test_suspend_refuses_an_uninspectable_head
test_suspend_refuses_an_unattributed_endpoint
test_suspend_parks_with_a_note_file
test_suspend_resume_refuse_relaunch_only_flags
test_resume_without_a_record_refuses_with_the_determinism_explanation
test_resume_refuses_a_live_agent_despite_a_record
test_resume_failed_launch_keeps_the_record
test_suspend_resume_round_trip_restores_the_parked_home
test_bootstrap_skips_a_suspended_secondmate_in_the_liveness_sweep