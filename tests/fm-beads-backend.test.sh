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

# add_beads_task_mock_sync <fakebin_dir> <control_dir>: a fake `task` CLI for the
# store-provisioning and Dolt-sync helpers, driven entirely by files the test
# writes under <control_dir>, so one fake covers every success and failure shape:
#   calls.log     every argv the fake saw, one line per call (written by the fake)
#   list.rc       exit status for `task list`      (default 0, store answers)
#   remotes.json  what `task dolt remote list --json` prints  (default "[]")
#   remote.rc     exit status for `task dolt remote list`  (default 0; non-zero
#                 makes the listing itself fail, as an older bd without the
#                 subcommand or an unreachable store would)
#   commit.out    what `task dolt commit` prints  (default nothing)
#   commit.rc / push.rc / pull.rc   exit status per dolt subcommand (default 0)
#   commit.sleep / push.sleep / remote.sleep / list.sleep   seconds that
#                 subcommand hangs before answering (default 0)
#   bootstrap.rc  exit status for `task bootstrap` (default 0)
#   bootstrap.leaves_broken   when present, bootstrap "succeeds" without making
#                             the store answer a read
add_beads_task_mock_sync() {
  local fakebin_dir=$1 control=$2
  mkdir -p "$control"
  cat > "$fakebin_dir/task" <<SH
#!/usr/bin/env bash
control="$control"
printf '%s\n' "\$*" >> "\$control/calls.log"
read_control() { # <file> <default>
  if [ -f "\$control/\$1" ]; then cat "\$control/\$1"; else printf '%s' "\$2"; fi
}
case "\${1:-} \${2:-}" in
  'dolt remote')
    hang=\$(read_control remote.sleep 0)
    [ "\$hang" = 0 ] || sleep "\$hang"
    remote_rc=\$(read_control remote.rc 0)
    if [ "\$remote_rc" != 0 ]; then
      printf 'unknown command "remote" for "bd dolt"\n' >&2
      exit "\$remote_rc"
    fi
    read_control remotes.json '[]'
    printf '\n'
    exit 0
    ;;
  'dolt commit')
    hang=\$(read_control commit.sleep 0)
    [ "\$hang" = 0 ] || sleep "\$hang"
    read_control commit.out ''
    exit "\$(read_control commit.rc 0)"
    ;;
  'dolt push')
    hang=\$(read_control push.sleep 0)
    [ "\$hang" = 0 ] || sleep "\$hang"
    exit "\$(read_control push.rc 0)"
    ;;
  'dolt pull') exit "\$(read_control pull.rc 0)" ;;
esac
case "\${1:-}" in
  list)
    hang=\$(read_control list.sleep 0)
    [ "\$hang" = 0 ] || sleep "\$hang"
    exit "\$(read_control list.rc 0)"
    ;;
  bootstrap)
    [ -f "\$control/bootstrap.leaves_broken" ] || printf '0' > "\$control/list.rc"
    exit "\$(read_control bootstrap.rc 0)"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin_dir/task"
}

# beads_sync_fixture <name>: make a fixture dir, drop the fake `task` in it, and
# print "<fakebin> <control>" for the caller to read.
beads_sync_fixture() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  add_beads_task_mock_sync "$fakebin" "$dir/control"
  printf '%s %s\n' "$fakebin" "$dir/control"
}

# Test: fm_beads_store_reachable() decides purely on whether the CLI answers a
# read. It must never infer a store from the filesystem: the `task` wrapper pins
# BEADS_DIR for the whole federation, so a home with no local .beads/ directory
# can be perfectly healthy and a host with one can still be broken.
test_beads_store_reachable_tracks_the_cli_answer() {
  local fakebin control
  read -r fakebin control <<< "$(beads_sync_fixture store-reachable)"

  PATH="$fakebin:$PATH" fm_beads_store_reachable ||
    fail "store should be reachable when the task CLI answers a read"

  printf '1' > "$control/list.rc"
  if PATH="$fakebin:$PATH" fm_beads_store_reachable; then
    fail "store should be unreachable when the task CLI fails a read"
  fi

  if PATH="$(fm_path_without task)" fm_beads_store_reachable; then
    fail "store should be unreachable when no task CLI exists at all"
  fi
  pass "fm_beads_store_reachable decides on the CLI's answer, not on a local .beads directory"
}

# Test: fm_beads_store_reachable honours the bound its CALLER passed, and stays
# unbounded when the caller passed none. Both halves are load-bearing and pull in
# opposite directions, which is why the bound is a per-call argument rather than
# one library-wide default:
#   - bin/fm-bootstrap.sh's sync sweep passes a bound carved out of the session
#     start budget. Substituting a shorter library default silently shrinks that
#     budget; substituting a longer one lets the probe overrun the whole stage.
#   - fm_beads_bootstrap_store's refuse-over-a-live-store guard passes NO bound
#     on purpose. A live-but-slow store answering late still means "live", and
#     reading it as unreachable is the one mistake provisioning must never make,
#     because the next step creates a second empty database beside the real one.
# A merge that leaves two definitions of this function in the file compiles and
# passes every other test in this suite while breaking exactly these guarantees,
# so they are asserted directly on observable return codes.
test_beads_store_reachable_honours_the_callers_bound() {
  local fakebin control
  read -r fakebin control <<< "$(beads_sync_fixture store-reachable-bound)"
  # The store answers, but only after 2s - longer than the status-read default.
  printf '2' > "$control/list.sleep"

  # A bound WIDER than the store is slow must let the read succeed, and the
  # library default is deliberately set narrower than the store's 2s so a
  # definition that substitutes it fails here instead of passing by luck.
  FM_BEADS_STATUS_TIMEOUT=1 PATH="$fakebin:$PATH" fm_beads_store_reachable 10 \
    || fail "an explicit 10s bound must let a store that answers in 2s read as reachable"

  # ...and a bound NARROWER than the store is slow must cut the read off, with
  # the default set wide this time so the bound cannot be credited to it.
  if FM_BEADS_STATUS_TIMEOUT=30 PATH="$fakebin:$PATH" fm_beads_store_reachable 1; then
    fail "an explicit 1s bound must not be widened by a library default"
  fi

  FM_BEADS_STATUS_TIMEOUT=1 PATH="$fakebin:$PATH" fm_beads_store_reachable \
    || fail "the unbounded form must not inherit a library default and read a live store as gone"

  pass "fm_beads_store_reachable applies the caller's bound, and none when the caller passed none"
}

# Test: the safety consequence of the above, asserted end to end. A store that is
# alive but slow to answer must still make provisioning REFUSE. This is the case
# that turns a silently-ignored bound into data loss rather than a slow session:
# bootstrap cannot see a Dolt sql-server store, so a false "unreachable" here is
# what puts a fresh empty database next to the live one.
test_beads_bootstrap_refuses_over_a_slow_live_store() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture bootstrap-refuse-slow)"
  printf '2' > "$control/list.sleep"

  if out=$(FM_BEADS_STATUS_TIMEOUT=1 PATH="$fakebin:$PATH" fm_beads_bootstrap_store 2>&1); then
    fail "bootstrap should refuse a live-but-slow store, got success: $out"
  fi
  assert_no_grep "bootstrap" "$control/calls.log" \
    "bootstrap ran over a live store that merely answered slowly"
  pass "fm_beads_bootstrap_store refuses a live store that answers slower than the status-read default"
}

# Test: fm_beads_bootstrap_store() refuses whenever the store already answers.
# This guard is the whole safety margin for provisioning: `bd bootstrap` inspects
# the .beads/ directory and cannot see a store served by a Dolt sql-server, so
# against a healthy server-mode store it would happily create a fresh empty
# database beside the live one.
test_beads_bootstrap_refuses_over_a_live_store() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture bootstrap-refuse)"

  if out=$(PATH="$fakebin:$PATH" fm_beads_bootstrap_store 2>&1); then
    fail "bootstrap should refuse a store that already answers, got success"
  fi
  case "$out" in
    *'bootstrap refused'*) ;;
    *) fail "bootstrap refusal did not explain itself, got: $out" ;;
  esac
  assert_no_grep "bootstrap" "$control/calls.log" \
    "bootstrap ran against a live store instead of refusing"
  pass "fm_beads_bootstrap_store refuses to bootstrap over a store that already answers"
}

# Test: fm_beads_bootstrap_store() provisions a home whose store genuinely does
# not answer, using the non-destructive `bootstrap` verb rather than an init.
test_beads_bootstrap_provisions_an_unreachable_store() {
  local fakebin control
  read -r fakebin control <<< "$(beads_sync_fixture bootstrap-provision)"
  printf '1' > "$control/list.rc"

  PATH="$fakebin:$PATH" fm_beads_bootstrap_store >/dev/null 2>&1 ||
    fail "bootstrap should provision a store that does not answer"
  assert_grep "bootstrap --yes" "$control/calls.log" \
    "provisioning did not run the non-destructive bootstrap verb"
  assert_no_grep "init" "$control/calls.log" \
    "provisioning reached for a destructive init instead of bootstrap"
  pass "fm_beads_bootstrap_store provisions an unreachable store with the non-destructive bootstrap verb"
}

# Test: a bootstrap that exits 0 without leaving a store that answers is still a
# failure. Provisioning is judged by the store's own read, never by the CLI's
# exit status, so a half-provisioned home is reported rather than assumed good.
test_beads_bootstrap_verifies_rather_than_trusting_exit_status() {
  local fakebin control
  read -r fakebin control <<< "$(beads_sync_fixture bootstrap-unverified)"
  printf '1' > "$control/list.rc"
  : > "$control/bootstrap.leaves_broken"

  if PATH="$fakebin:$PATH" fm_beads_bootstrap_store >/dev/null 2>&1; then
    fail "bootstrap reported success even though the store still does not answer"
  fi
  pass "fm_beads_bootstrap_store judges provisioning by the store's own read, not the CLI's exit status"
}

# Test: with no Dolt remote configured, sync is inert and succeeds. A
# single-machine store is a legitimate posture - firstmate never configures a
# remote on its own, because that would publish task data to a destination the
# captain has not approved - so sync must say so plainly and touch nothing.
test_beads_sync_is_inert_without_a_configured_remote() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture sync-no-remote)"

  out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1) ||
    fail "sync with no remote configured must succeed, got failure: $out"
  case "$out" in
    *'no Dolt remote configured'*) ;;
    *) fail "sync did not report the missing remote, got: $out" ;;
  esac
  assert_no_grep "dolt push" "$control/calls.log" \
    "sync pushed despite no configured remote"
  assert_no_grep "dolt commit" "$control/calls.log" \
    "sync committed despite no configured remote"
  pass "fm_beads_sync_once stays inert and succeeds when no Dolt remote is configured"
}

# Test: an unreadable remote listing is never reported as "no remote
# configured". The empty-listing line is documented as the expected steady state
# and explicitly not a failure, so folding a failing listing into it would leave
# a home that IS configured silently not syncing, behind the one line that tells
# the reader not to investigate.
test_beads_sync_separates_an_unreadable_remote_list_from_an_empty_one() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture sync-remote-unreadable)"
  printf '1' > "$control/remote.rc"

  if out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1); then
    fail "an unreadable remote listing was reported as a clean no-op, got: $out"
  fi
  case "$out" in
    *'could not read the Dolt remote list'*) ;;
    *) fail "sync did not report that it could not read the remote list, got: $out" ;;
  esac
  case "$out" in
    *'no Dolt remote configured'*)
      fail "an unreadable remote listing was reported as the benign single-machine posture, got: $out"
      ;;
  esac
  assert_no_grep "dolt push" "$control/calls.log" \
    "sync pushed without knowing whether a remote is configured"
  pass "fm_beads_sync_once separates an unreadable remote listing from a genuinely empty one"
}

# Test: the same separation when jq itself is absent. jq is not an unconditional
# requirement of bootstrap, so this path is reachable on a real host, and it
# must not masquerade as a store that has no remote.
test_beads_sync_reports_a_missing_jq_rather_than_assuming_no_remote() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture sync-no-jq)"

  if out=$(PATH="$fakebin:$(fm_path_without jq)" fm_beads_sync_once 2>&1); then
    fail "sync with no jq was reported as a clean no-op, got: $out"
  fi
  case "$out" in
    *'could not read the Dolt remote list'*) ;;
    *) fail "sync did not report that it could not read the remote list, got: $out" ;;
  esac
  case "$out" in
    *'jq'*) ;;
    *) fail "sync did not name the missing tool, got: $out" ;;
  esac
  case "$out" in
    *'no Dolt remote configured'*)
      fail "a missing jq was reported as the benign single-machine posture, got: $out"
      ;;
  esac
  pass "fm_beads_sync_once names a missing jq instead of assuming no remote is configured"
}

# Test: a genuine commit failure is reported. The default auto-commit policy is
# off, so a failed commit leaves this home's writes in the Dolt working set;
# swallowing it would let the push line announce success over exactly the
# durability gap routine sync exists to close.
test_beads_sync_reports_a_genuine_commit_failure() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture sync-commit-fails)"
  printf '%s' '[{"name":"origin"}]' > "$control/remotes.json"
  printf '1' > "$control/commit.rc"
  printf 'error: cannot commit: schema skew detected\n' > "$control/commit.out"

  if out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1); then
    fail "a genuine commit failure was reported as a successful sync, got: $out"
  fi
  case "$out" in
    *'commit failed'*) ;;
    *) fail "sync did not report the failing commit, got: $out" ;;
  esac
  case "$out" in
    *'schema skew detected'*) ;;
    *) fail "the commit failure did not carry the CLI's own reason, got: $out" ;;
  esac
  assert_grep "dolt push" "$control/calls.log" \
    "a failed commit abandoned the push instead of degrading best-effort"
  pass "fm_beads_sync_once reports a genuine commit failure instead of calling the sweep a success"
}

# Test: the other side of that separation. A clean working set is a success:
# `task dolt commit` prints that it found nothing and exits 0, so the routine
# sweep must stay silent rather than crying wolf on every session that wrote
# nothing. The fixture, not this test's prose, is what fixes that contract.
test_beads_sync_treats_a_clean_working_set_as_nothing_to_do() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture sync-commit-clean)"
  printf '%s' '[{"name":"origin"}]' > "$control/remotes.json"
  printf '0' > "$control/commit.rc"
  printf 'Nothing to commit.\n' > "$control/commit.out"

  out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1) ||
    fail "a clean working set was reported as a sync failure, got: $out"
  case "$out" in
    *'BEADS_SYNC: commit'*) fail "a clean working set was reported at all, got: $out" ;;
  esac
  case "$out" in
    *'pushed local commits'*) ;;
    *) fail "sync stopped short of the push after a clean working set, got: $out" ;;
  esac
  pass "fm_beads_sync_once treats a clean working set as nothing to do, not as a failure"
}

# Test: the exit status alone decides, and the CLI's wording never does. A
# commit that fails while printing the clean-working-set sentence is still a
# failure, because the writes it did not commit are still stranded in the Dolt
# working set. Matching on that wording is how a real durability gap would be
# swallowed as routine quiet, and it is the exact bug this asserts against.
test_beads_sync_classifies_the_commit_on_exit_status_not_wording() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture sync-commit-liar)"
  printf '%s' '[{"name":"origin"}]' > "$control/remotes.json"
  printf '1' > "$control/commit.rc"
  printf 'Nothing to commit.\n' > "$control/commit.out"

  if out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1); then
    fail "a non-zero commit was excused by its wording, got success: $out"
  fi
  case "$out" in
    *'commit failed'*) ;;
    *) fail "sync excused a failing commit because of what it printed, got: $out" ;;
  esac
  pass "fm_beads_sync_once classifies the commit on its exit status, never on its wording"
}

# Test: the happy path commits, pushes, then pulls, in that order. Commit comes
# first because the auto-commit policy leaves writes in the working set, and
# push comes before pull because durability is the gap being closed.
test_beads_sync_commits_pushes_then_pulls() {
  local fakebin control out sequence
  read -r fakebin control <<< "$(beads_sync_fixture sync-success)"
  printf '%s' '[{"name":"origin"}]' > "$control/remotes.json"

  out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1) ||
    fail "a fully healthy sync must succeed, got: $out"
  case "$out" in
    *'pushed local commits'*) ;;
    *) fail "sync did not report the push, got: $out" ;;
  esac
  case "$out" in
    *'pulled remote commits'*) ;;
    *) fail "sync did not report the pull, got: $out" ;;
  esac
  sequence=$(grep -o 'dolt [a-z]*' "$control/calls.log" | tr '\n' ' ')
  [ "$sequence" = 'dolt remote dolt commit dolt push dolt pull ' ] ||
    fail "sync ran the wrong order of Dolt steps, got: $sequence"
  pass "fm_beads_sync_once commits, then pushes, then pulls against a configured remote"
}

# Test: a failing push degrades best-effort - it is reported, the pull still
# runs, and the caller gets a non-zero status to report as a diagnostic. Sync is
# a background convenience, so one broken step must neither abandon the rest of
# the sweep nor be silently swallowed.
test_beads_sync_failure_degrades_best_effort() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture sync-push-fails)"
  printf '%s' '[{"name":"origin"}]' > "$control/remotes.json"
  printf '1' > "$control/push.rc"

  if out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1); then
    fail "a failed push must be reported as a failure, got success: $out"
  fi
  case "$out" in
    *'push failed'*) ;;
    *) fail "sync did not name the failing step, got: $out" ;;
  esac
  assert_grep "dolt pull" "$control/calls.log" \
    "a failed push abandoned the pull instead of degrading best-effort"
  pass "fm_beads_sync_once reports a failed push, keeps going, and never swallows the failure"
}

# Test: a hanging remote is bounded, so sync can never wedge the session start
# sweep that calls it. The bound is the reason sync is safe to run routinely.
test_beads_sync_bounds_a_hanging_remote() {
  local fakebin control out started elapsed
  read -r fakebin control <<< "$(beads_sync_fixture sync-hangs)"
  printf '%s' '[{"name":"origin"}]' > "$control/remotes.json"
  printf '30' > "$control/push.sleep"

  started=$(date +%s)
  if out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_TIMEOUT=1 fm_beads_sync_once 2>&1); then
    fail "a timed-out push must be reported as a failure, got success: $out"
  fi
  elapsed=$(( $(date +%s) - started ))
  case "$out" in
    *'timed out after 1s'*) ;;
    *) fail "sync did not report the bound being hit, got: $out" ;;
  esac
  [ "$elapsed" -lt 15 ] ||
    fail "sync waited ${elapsed}s on a hanging remote instead of honouring its bound"
  pass "fm_beads_sync_once bounds a hanging remote so it cannot wedge the sweep that calls it"
}

# Test: the bound that matters to the caller is the one on the WHOLE sweep. Three
# per-step bounds can sum to three times the caller's own budget, so a blackholed
# remote could starve every other sweep sharing it. Here the per-step bound is
# generous and the sweep budget is small: the first slow step consumes it, and
# the remaining steps must be reported skipped rather than started.
test_beads_sync_bounds_the_whole_sweep_not_each_step() {
  local fakebin control out started elapsed
  read -r fakebin control <<< "$(beads_sync_fixture sync-budget)"
  printf '%s' '[{"name":"origin"}]' > "$control/remotes.json"
  printf '30' > "$control/commit.sleep"

  started=$(date +%s)
  if out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_TIMEOUT=45 FM_BEADS_SYNC_BUDGET=2 \
    fm_beads_sync_once 2>&1); then
    fail "a sweep that spent its whole budget must be reported as a failure, got: $out"
  fi
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] ||
    fail "the sweep ran ${elapsed}s against a 2s budget, so only the per-step bound applied"
  case "$out" in
    *'push skipped: the 2s sync budget was spent'*) ;;
    *) fail "sync did not report the push skipped for a spent sweep budget, got: $out" ;;
  esac
  case "$out" in
    *'pull skipped: the 2s sync budget was spent'*) ;;
    *) fail "sync did not report the pull skipped for a spent sweep budget, got: $out" ;;
  esac
  if grep -q 'dolt push' "$control/calls.log"; then
    fail "sync started a push it had no budget left to run"
  fi
  pass "fm_beads_sync_once bounds the whole sweep, not merely each step within it"
}

# Test: the budget covers the sweep's FIRST command, not merely the three steps
# it names. A Dolt server that accepts the connection and then never answers
# hangs the remote listing, which runs before any step does, so leaving that
# probe outside the budget lets the sweep spend unbounded wall clock without a
# single bounded step running and without any diagnostic at all - the budget
# would be a claim rather than a bound.
test_beads_sync_bounds_the_probe_that_precedes_its_steps() {
  local fakebin control out started elapsed
  read -r fakebin control <<< "$(beads_sync_fixture sync-probe-hangs)"
  printf '%s' '[{"name":"origin"}]' > "$control/remotes.json"
  printf '30' > "$control/remote.sleep"

  started=$(date +%s)
  if out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_TIMEOUT=45 FM_BEADS_SYNC_BUDGET=2 \
    fm_beads_sync_once 2>&1); then
    fail "a sweep whose remote listing never answered must be reported as a failure, got: $out"
  fi
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] ||
    fail "the sweep hung ${elapsed}s on its remote listing against a 2s budget"
  case "$out" in
    *'could not read the Dolt remote list'*) ;;
    *) fail "a listing that never answered was not reported as unreadable, got: $out" ;;
  esac
  case "$out" in
    *'no Dolt remote configured'*)
      fail "a listing that never answered was reported as a home that has no remote: $out" ;;
  esac
  if grep -q 'dolt commit' "$control/calls.log"; then
    fail "sync started its steps after a remote listing it never got an answer from"
  fi
  pass "fm_beads_sync_once bounds the probe that precedes its steps, not only the steps"
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

test_beads_store_reachable_tracks_the_cli_answer
test_beads_store_reachable_honours_the_callers_bound
test_beads_bootstrap_refuses_over_a_live_store
test_beads_bootstrap_refuses_over_a_slow_live_store
test_beads_bootstrap_provisions_an_unreachable_store
test_beads_bootstrap_verifies_rather_than_trusting_exit_status
test_beads_sync_is_inert_without_a_configured_remote
test_beads_sync_separates_an_unreadable_remote_list_from_an_empty_one
test_beads_sync_reports_a_missing_jq_rather_than_assuming_no_remote
test_beads_sync_reports_a_genuine_commit_failure
test_beads_sync_treats_a_clean_working_set_as_nothing_to_do
test_beads_sync_classifies_the_commit_on_exit_status_not_wording
test_beads_sync_commits_pushes_then_pulls
test_beads_sync_failure_degrades_best_effort
test_beads_sync_bounds_a_hanging_remote
test_beads_sync_bounds_the_whole_sweep_not_each_step
test_beads_sync_bounds_the_probe_that_precedes_its_steps

echo "ok - all beads backend tests passed"
