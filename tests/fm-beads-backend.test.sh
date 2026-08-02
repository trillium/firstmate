#!/usr/bin/env bash
# tests/fm-beads-backend.test.sh - beads as third backlog backend option.
# Tests backend selection and availability checks.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-tasks-axi-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-beads-backend)

# Test: fm_backlog_backend_value() returns beads when configured
test_beads_backend_value() {
  local config="$TMP_ROOT/config"
  mkdir -p "$config"

  # Test default (tasks-axi)
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "tasks-axi" ] || fail "default backend should be tasks-axi, got: $value"

  # Test explicit beads
  printf '%s' 'beads' > "$config/backlog-backend"
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "beads" ] || fail "beads backend when configured should return beads, got: $value"

  # Test manual
  printf '%s' 'manual' > "$config/backlog-backend"
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "manual" ] || fail "manual backend when configured should return manual, got: $value"
}

# Test: fm_beads_backend_available() checks config and task CLI
test_beads_backend_available() {
  local config="$TMP_ROOT/config-beads"
  mkdir -p "$config"

  # Test: beads not configured - should return false
  printf '%s' 'tasks-axi' > "$config/backlog-backend"
  if fm_beads_backend_available "$config"; then
    fail "fm_beads_backend_available should return false when beads not configured"
  fi

  # Test: beads configured but task CLI not found - should return false
  printf '%s' 'beads' > "$config/backlog-backend"
  if ! command -v task >/dev/null 2>&1; then
    if fm_beads_backend_available "$config"; then
      fail "fm_beads_backend_available should return false when task CLI not found"
    fi
    return 0
  fi

  # Test: beads configured and task CLI found - should return true if store is reachable
  if ! task list --limit 1 >/dev/null 2>&1; then
    # Store not reachable in test environment - that's OK
    return 0
  fi
  if ! fm_beads_backend_available "$config"; then
    fail "fm_beads_backend_available should return true when beads configured and task CLI works"
  fi
}

# Test: fm_tasks_axi_backend_available() returns false when beads is configured
test_tasks_axi_backend_false_for_beads() {
  local config="$TMP_ROOT/config-axi"
  mkdir -p "$config"

  printf '%s' 'beads' > "$config/backlog-backend"

  if fm_tasks_axi_backend_available "$config"; then
    fail "fm_tasks_axi_backend_available should return false when beads is configured"
  fi
}

# Test: backend value handles whitespace
test_backend_value_whitespace() {
  local config="$TMP_ROOT/config-ws"
  mkdir -p "$config"

  printf '%s' '  beads  ' > "$config/backlog-backend"
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "beads" ] || fail "backend value should strip whitespace, got: $value"
}

# Test: fm_beads_fleet_label() defaults to fleet:firstmate and honors the
# test-only FM_BEADS_FLEET_LABEL override (beads-authority migration Stage 0).
test_beads_fleet_label() {
  local value
  value=$(unset FM_BEADS_FLEET_LABEL; fm_beads_fleet_label)
  [ "$value" = "fleet:firstmate" ] || fail "default fleet label should be fleet:firstmate, got: $value"

  value=$(FM_BEADS_FLEET_LABEL="fleet:example" fm_beads_fleet_label)
  [ "$value" = "fleet:example" ] || fail "fleet label override should win, got: $value"
}

# add_beads_task_mock_resolve <fakebin_dir> <calls_log> <existing_id> <minted_id>:
# a fake `task` CLI for fm_beads_resolve_or_create - `list --label ...` reports
# <existing_id> (or none, when empty) and `create ...` reports <minted_id>.
add_beads_task_mock_resolve() {
  local fakebin_dir=$1 calls_log=$2 existing_id=$3 minted_id=$4
  cat > "$fakebin_dir/task" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls_log"
case "\$1" in
  list)
    if [ -n "$existing_id" ]; then
      printf '[{"id":"%s"}]\n' "$existing_id"
    else
      printf '[]\n'
    fi
    ;;
  create)
    printf '%s\n' "$minted_id"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin_dir/task"
}

# Test: fm_beads_resolve_or_create() mints a new bead labeled task:<id> when no
# bead already carries that label (beads-authority migration Stage 3).
test_beads_resolve_or_create_mints_when_absent() {
  local dir fakebin calls_log id
  dir="$TMP_ROOT/resolve-mint"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_resolve "$fakebin" "$calls_log" "" "bead-99"

  id=$(PATH="$fakebin:$PATH" fm_beads_resolve_or_create "task-abc")
  [ "$id" = "bead-99" ] || fail "expected minted bead id bead-99, got: $id"
  assert_grep "list --label task:task-abc --all --limit 1 --json" "$calls_log" \
    "resolve did not look up an existing bead by its task: label"
  assert_grep "create --title" "$calls_log" \
    "resolve did not mint a new bead when none existed"
  assert_grep "task:task-abc" "$calls_log" \
    "minted bead did not carry the task:<id> idempotency label"
  pass "fm_beads_resolve_or_create mints a new bead labeled task:<id> when none exists"
}

# Test: fm_beads_resolve_or_create() reuses an existing task:<id>-labeled bead
# instead of minting a duplicate, so fm-spawn.sh and fm-brief.sh converge on the
# same bead regardless of which one runs first.
test_beads_resolve_or_create_reuses_existing() {
  local dir fakebin calls_log id
  dir="$TMP_ROOT/resolve-reuse"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_resolve "$fakebin" "$calls_log" "bead-7" "bead-should-not-be-created"

  id=$(PATH="$fakebin:$PATH" fm_beads_resolve_or_create "task-xyz")
  [ "$id" = "bead-7" ] || fail "expected existing bead id bead-7, got: $id"
  assert_no_grep "create --title" "$calls_log" \
    "resolve minted a duplicate bead despite an existing task:<id> label match"
  pass "fm_beads_resolve_or_create reuses an existing task:<id>-labeled bead instead of minting a duplicate"
}

# Run all tests
test_beads_backend_value
test_beads_backend_available
test_tasks_axi_backend_false_for_beads
test_backend_value_whitespace
test_beads_fleet_label
test_beads_resolve_or_create_mints_when_absent
test_beads_resolve_or_create_reuses_existing

echo "ok - all beads backend tests passed"
