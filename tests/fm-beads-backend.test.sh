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

# add_beads_task_mock_store <fakebin_dir> <calls_log> <store_json> <minted_id>:
# a fake `task` CLI backed by a small in-memory store. `list` applies the same
# --label (AND), --status, --all, and --limit semantics the real CLI documents -
# including truncating to --limit AFTER filtering - so a lookup that forgets a
# filter sees exactly the rows it meant to exclude instead of a fixture that
# answers correctly no matter what was asked. Rows are {id,status,labels};
# `create` reports <minted_id>.
add_beads_task_mock_store() {
  local fakebin_dir=$1 calls_log=$2 store_json=$3 minted_id=$4
  cat > "$fakebin_dir/task" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$calls_log"
case "\$1" in
  list)
    labels=; statuses=; limit=50
    shift
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --label|-l) labels=\${2:-}; shift 2 ;;
        --status|-s) statuses=\${2:-}; shift 2 ;;
        --limit|-n) limit=\${2:-0}; shift 2 ;;
        --all) statuses=all; shift ;;
        *) shift ;;
      esac
    done
    printf '%s' '$store_json' | jq -c \
      --arg labels "\$labels" --arg statuses "\$statuses" --argjson limit "\$limit" '
      [ .[]
        | select(\$labels == "" or ((\$labels | split(",")) - (.labels // [])) == [])
        | select(
            if \$statuses == "all" then true
            elif \$statuses == "" then .status != "closed"
            else (.status as \$s | \$statuses | split(",") | index(\$s)) != null
            end)
      ]
      | if \$limit > 0 then .[0:\$limit] else . end'
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
  command -v jq >/dev/null 2>&1 || { pass "resolve mint skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-mint"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" '[]' "bead-99"

  id=$(PATH="$fakebin:$PATH" fm_beads_resolve_or_create "task-abc")
  [ "$id" = "bead-99" ] || fail "expected minted bead id bead-99, got: $id"
  assert_grep "list --label task:task-abc --limit 1 --json" "$calls_log" \
    "resolve did not look up an existing bead by its task:<id> label"
  assert_no_grep "list --label task:task-abc --all" "$calls_log" \
    "resolve asked for closed beads instead of letting the store exclude them"
  assert_grep "create --title" "$calls_log" \
    "resolve did not mint a new bead when none existed"
  assert_grep "task:task-abc" "$calls_log" \
    "minted bead did not carry the task:<id> idempotency label"
  pass "fm_beads_resolve_or_create mints a new bead labeled task:<id> when none exists"
}

# Test: fm_beads_resolve_or_create() reuses an existing task:<id>-labeled bead
# instead of minting a duplicate, so a resolution against an id that was already
# linked (e.g. an explicit --beads spawn, or a prior successful spawn attempt)
# never mints a second bead for the same task.
test_beads_resolve_or_create_reuses_existing() {
  local dir fakebin calls_log id
  command -v jq >/dev/null 2>&1 || { pass "resolve reuse skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-reuse"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-7","status":"open","labels":["task:task-xyz"]}]' \
    "bead-should-not-be-created"

  id=$(PATH="$fakebin:$PATH" fm_beads_resolve_or_create "task-xyz")
  [ "$id" = "bead-7" ] || fail "expected existing bead id bead-7, got: $id"
  assert_no_grep "create --title" "$calls_log" \
    "resolve minted a duplicate bead despite an existing task:<id> label match"
  pass "fm_beads_resolve_or_create reuses an existing task:<id>-labeled bead instead of minting a duplicate"
}

# Test: a CLOSED bead carrying the task:<id> label is never adopted. Task ids are
# reusable slugs and fm-teardown.sh closes a bead without stripping that label, so
# the record of a long-finished task survives in the store. Adopting it would link
# a brand-new task to an already-closed bead - and under the beads backend a closed
# bead is the authoritative task-complete signal bin/fm-crew-state.sh reads, so the
# fresh crew would reconcile as done before its worker committed anything.
test_beads_resolve_or_create_skips_closed_bead() {
  local dir fakebin calls_log id
  command -v jq >/dev/null 2>&1 || { pass "resolve closed-bead skip skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-closed"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-old","status":"closed","labels":["task:fix-ci"]}]' \
    "bead-fresh"

  id=$(PATH="$fakebin:$PATH" fm_beads_resolve_or_create "fix-ci")
  [ "$id" != "bead-old" ] \
    || fail "resolve adopted the closed bead of a previous task that reused this id"
  [ "$id" = "bead-fresh" ] || fail "expected a freshly minted bead, got: $id"
  assert_grep "create --title" "$calls_log" \
    "resolve did not mint a fresh bead when the only labeled bead was closed"
  pass "fm_beads_resolve_or_create mints a fresh bead instead of adopting a closed one"
}

# Test: the closed-bead exclusion must not cost idempotency. When a task id has a
# closed predecessor AND the live bead for the current task, resolve still returns
# the live one rather than minting a duplicate - the label matches both records and
# their order in the store is not specified.
test_beads_resolve_or_create_prefers_live_bead_over_closed() {
  local dir fakebin calls_log id
  command -v jq >/dev/null 2>&1 || { pass "resolve live-over-closed skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-mixed"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-old","status":"closed","labels":["task:fix-ci"]},{"id":"bead-live","status":"in_progress","labels":["task:fix-ci"]}]' \
    "bead-should-not-be-created"

  id=$(PATH="$fakebin:$PATH" fm_beads_resolve_or_create "fix-ci")
  [ "$id" = "bead-live" ] || fail "expected the still-live bead bead-live, got: $id"
  assert_no_grep "create --title" "$calls_log" \
    "resolve minted a duplicate despite a live task:<id>-labeled bead existing"
  pass "fm_beads_resolve_or_create returns the live bead when a closed predecessor shares the label"
}

# Test: the store, not the caller, decides which rows come back. A reusable task id
# accumulates one closed predecessor per completed task, and the store applies
# --limit AFTER filtering, so a lookup that fetches a page and drops the closed rows
# itself sees only predecessors once they outnumber the page - and mints a duplicate
# bead for a task that is already linked, every time it is asked. Asking the store
# for the non-closed rows makes the page size irrelevant.
test_beads_resolve_or_create_ignores_predecessor_backlog_depth() {
  local dir fakebin calls_log id store i
  command -v jq >/dev/null 2>&1 || { pass "resolve predecessor-depth skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-deep"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  store='['
  for i in $(seq 1 40); do
    store="$store{\"id\":\"bead-old-$i\",\"status\":\"closed\",\"labels\":[\"task:fix-ci\"]},"
  done
  store="$store{\"id\":\"bead-live\",\"status\":\"open\",\"labels\":[\"task:fix-ci\"]}]"
  add_beads_task_mock_store "$fakebin" "$calls_log" "$store" "bead-should-not-be-created"

  id=$(PATH="$fakebin:$PATH" fm_beads_resolve_or_create "fix-ci")
  [ "$id" = "bead-live" ] \
    || fail "expected the live bead behind 40 closed predecessors, got: $id"
  assert_no_grep "create --title" "$calls_log" \
    "resolve minted a duplicate because the closed predecessors filled its page"
  pass "fm_beads_resolve_or_create finds the live bead however many closed predecessors share the label"
}

# Test: the library stays sourceable on its own. It is copied WITHOUT its
# siblings into partially-synced remote code roots (tests/fm-on.test.sh,
# tests/fm-remote-backlog-handoff.test.sh build exactly that fixture), where the
# scripts that source it run under `set -eu` and must still reach the report that
# names what the host is missing. An unguarded source of fm-timeout-lib.sh aborts
# them at load time instead.
test_lib_sources_without_its_siblings() {
  local dir="$TMP_ROOT/lonely-lib" out rc
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-tasks-axi-lib.sh" "$dir/bin/"
  cat > "$dir/consumer.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/bin/fm-tasks-axi-lib.sh"
printf 'reached-the-end\n'
SH
  chmod +x "$dir/consumer.sh"
  out=$("$dir/consumer.sh" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "sourcing fm-tasks-axi-lib.sh alone under set -eu exited $rc: $out"
  [ "$out" = "reached-the-end" ] \
    || fail "sourcing fm-tasks-axi-lib.sh alone did not reach the next statement: $out"
  pass "fm-tasks-axi-lib.sh stays sourceable under set -eu when no sibling libs are co-located"
}

# Test: fm_beads_status distinguishes a completed read, an absent bead, and a read
# that never answered. Conflating the last two loses a queued write: an unanswered
# read is not evidence the bead is gone.
test_beads_status_read_outcomes() {
  local dir fakebin out rc
  command -v jq >/dev/null 2>&1 || { pass "fm_beads_status outcomes skipped without jq"; return; }
  dir="$TMP_ROOT/beads-status"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'list --limit 1') exit 0 ;;
  'show bd-open --json') printf '%s\n' '[{"id":"bd-open","status":"open"}]'; exit 0 ;;
  'show bd-closed --json') printf '%s\n' '[{"id":"bd-closed","status":"closed"}]'; exit 0 ;;
  'show bd-slow --json') sleep 5; printf '%s\n' '[{"id":"bd-slow","status":"open"}]'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/task"

  out=$(PATH="$fakebin:$PATH" fm_beads_status bd-open) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a completed read of an existing bead must return 0, got $rc"
  [ "$out" = open ] || fail "expected status 'open' for bd-open, got: $out"

  out=$(PATH="$fakebin:$PATH" fm_beads_status bd-gone) && rc=0 || rc=$?
  [ "$rc" -eq "$FM_BEADS_STATUS_RC_ABSENT" ] \
    || fail "an absent bead must return FM_BEADS_STATUS_RC_ABSENT, got $rc"
  [ -z "$out" ] || fail "an absent bead must print nothing, got: $out"

  out=$(PATH="$fakebin:$PATH" FM_BEADS_STATUS_TIMEOUT=1 fm_beads_status bd-slow) && rc=0 || rc=$?
  [ "$rc" -eq "$FM_BEADS_STATUS_RC_UNREADABLE" ] \
    || fail "a read that hit its bound must return FM_BEADS_STATUS_RC_UNREADABLE, got $rc"
  [ -z "$out" ] || fail "a read that hit its bound must print nothing, got: $out"

  PATH="$fakebin:$PATH" fm_beads_is_closed bd-closed \
    || fail "fm_beads_is_closed must be true for a bead the store reports closed"
  PATH="$fakebin:$PATH" fm_beads_is_closed bd-open \
    && fail "fm_beads_is_closed must be false for an open bead"
  PATH="$fakebin:$PATH" fm_beads_is_closed bd-gone \
    && fail "fm_beads_is_closed must be false for an absent bead"
  PATH="$fakebin:$PATH" FM_BEADS_STATUS_TIMEOUT=1 fm_beads_is_closed bd-slow \
    && fail "fm_beads_is_closed must fail open (not closed) when the read never answered"
  pass "fm_beads_status separates a completed read, an absent bead, and an unanswered read"
}

# Test: a failed read against a store that is DOWN is not evidence the bead is
# gone. `task show` exits non-zero for a missing bead and for an unreachable,
# locked, or unauthenticated store alike, so the classification must rest on
# whether the store itself answered - a down store is unreadable, not absent.
test_beads_status_down_store_is_not_absent() {
  local dir fakebin out rc
  command -v jq >/dev/null 2>&1 || { pass "fm_beads_status down-store skipped without jq"; return; }
  dir="$TMP_ROOT/beads-status-down"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
set -u
exit 1
SH
  chmod +x "$fakebin/task"

  out=$(PATH="$fakebin:$PATH" fm_beads_status bd-any) && rc=0 || rc=$?
  [ "$rc" -eq "$FM_BEADS_STATUS_RC_UNREADABLE" ] \
    || fail "a failed read against an unreachable store must be UNREADABLE, not absent (got $rc)"
  [ -z "$out" ] || fail "a failed read against an unreachable store must print nothing, got: $out"
  PATH="$fakebin:$PATH" fm_beads_is_closed bd-any \
    && fail "fm_beads_is_closed must fail open (not closed) when the store is unreachable"
  pass "fm_beads_status reports an unreachable store as unreadable rather than an absent bead"
}

# Test: a non-positive bound is not a bound. bin/fm-timeout-lib.sh documents that
# `timeout 0` and the perl fallback's `alarm 0` both DISABLE the deadline, so an
# operator-supplied zero must be rejected before it reaches fm_run_timed - it is
# all-digits and would otherwise pass a digits-only validator and let a wedged
# store stall the read forever. Runs in a child process because the bound is
# sanitized from the environment when the library is sourced.
test_beads_status_rejects_non_positive_bound() {
  local dir fakebin consumer rc value
  command -v jq >/dev/null 2>&1 || { pass "fm_beads_status bound skipped without jq"; return; }
  dir="$TMP_ROOT/beads-status-bound"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'list --limit 1') exit 0 ;;
  'show bd-hang --json') sleep 30 ;;
esac
exit 1
SH
  chmod +x "$fakebin/task"

  consumer="$dir/consumer.sh"
  cat > "$consumer" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-tasks-axi-lib.sh"
fm_beads_status bd-hang
exit \$?
SH
  chmod +x "$consumer"

  for value in 0 00; do
    PATH="$fakebin:$PATH" FM_BEADS_STATUS_TIMEOUT="$value" \
      fm_run_timed 15 "$consumer" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -ne 124 ] \
      || fail "FM_BEADS_STATUS_TIMEOUT=$value left the store read unbounded"
    [ "$rc" -eq "$FM_BEADS_STATUS_RC_UNREADABLE" ] \
      || fail "FM_BEADS_STATUS_TIMEOUT=$value must fall back to a real bound and report unreadable, got $rc"
  done
  pass "fm_beads_status rejects a non-positive bound instead of running the read unbounded"
}

# Run all tests
test_beads_backend_value
test_beads_backend_available
test_tasks_axi_backend_false_for_beads
test_backend_value_whitespace
test_beads_fleet_label
test_beads_resolve_or_create_mints_when_absent
test_beads_resolve_or_create_reuses_existing
test_beads_resolve_or_create_skips_closed_bead
test_beads_resolve_or_create_prefers_live_bead_over_closed
test_beads_resolve_or_create_ignores_predecessor_backlog_depth
test_lib_sources_without_its_siblings
test_beads_status_read_outcomes
test_beads_status_down_store_is_not_absent
test_beads_status_rejects_non_positive_bound

echo "ok - all beads backend tests passed"
