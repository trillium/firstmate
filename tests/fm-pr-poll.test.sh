#!/usr/bin/env bash
# Behavioral tests for Boundary 10 PR Checks to Native Beads Gates (bin/fm-pr-check.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-poll)
export FM_SPAWN_NO_GUARD=1

test_pr_check_beads_gate() {
  local home="$TMP_ROOT/home_beads"
  mkdir -p "$home/config" "$home/state" "$home/data"
  echo "beads-gates" > "$home/config/pr-gate-backend"
  fm_test_beads_setup "$home"

  # Create task metadata
  cat > "$home/state/task-1.meta" <<'EOF'
window=1
endpoint_task_id=task-1
project=testproj
harness=pi
kind=crewmate
mode=direct-PR
yolo=off
beads_id=task-100
EOF
  chmod 0600 "$home/state/task-1.meta"

  local out
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-pr-check.sh" task-1 "https://github.com/trillium/firstmate/pull/42")
  assert_contains "$out" "armed: beads-gate gh:pr" "expected beads-gate armed message"

  # Verify pr= recorded in metadata
  assert_grep "pr=https://github.com/trillium/firstmate/pull/42" "$home/state/task-1.meta" "pr= was not recorded in metadata"

  # Verify .check.sh was NOT created under beads-gates
  assert_absent "$home/state/task-1.check.sh" "legacy .check.sh should not be created under beads-gates"

  pass "fm-pr-check.sh arms native beads-gate and records pr in metadata"
}

test_pr_check_rollback_files() {
  local home="$TMP_ROOT/home_files"
  mkdir -p "$home/config" "$home/state" "$home/data"
  echo "files" > "$home/config/pr-gate-backend"

  cat > "$home/state/task-2.meta" <<'EOF'
window=1
endpoint_task_id=task-2
project=testproj
harness=pi
kind=crewmate
mode=direct-PR
yolo=off
EOF
  chmod 0600 "$home/state/task-2.meta"

  local out
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-pr-check.sh" task-2 "https://github.com/trillium/firstmate/pull/43")
  assert_contains "$out" "armed: state/task-2.check.sh" "expected state/task-2.check.sh armed message"

  # Verify .check.sh was created under files
  assert_present "$home/state/task-2.check.sh" "legacy .check.sh should be created under files"
  assert_present "$home/state/task-2.pr-poll" "legacy .pr-poll sidecar should be created under files"

  pass "config/pr-gate-backend=files restores legacy .check.sh polling"
}

test_pr_check_beads_gate
test_pr_check_rollback_files
