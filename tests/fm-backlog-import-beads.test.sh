#!/usr/bin/env bash
# End-to-end tests for bin/fm-backlog-import-beads.sh, the one-time forward
# importer from data/backlog.md into the beads federated task store
# (beads-authority migration Stage 6). Every case drives the real importer
# through its executable interface against a real, isolated beads store (never
# the shared federated store) and reads the result back through beads, so the
# mapping is verified against actual bead/gate semantics rather than asserted
# against the importer's own source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMPORT="$ROOT/bin/fm-backlog-import-beads.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-import-beads)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v beads >/dev/null 2>&1 || { echo "skip: beads not found"; exit 0; }

FLEET="fleet:test-import"

# One isolated store for the whole suite; cases use distinct backlog ids so they
# never collide within it.
STORE="$TMP_ROOT/store"
mkdir -p "$STORE"
(cd "$STORE" && beads init --prefix bmt >/dev/null 2>&1) \
  || { echo "skip: could not init an isolated beads store"; exit 0; }

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/task" <<SH
#!/usr/bin/env bash
exec beads -C "$STORE" "\$@"
SH
chmod +x "$FAKEBIN/task"

# A fakebin whose `task` cannot reach any store, to drive the fail-closed path.
BADBIN="$TMP_ROOT/badbin"
mkdir -p "$BADBIN"
cat > "$BADBIN/task" <<'SH'
#!/usr/bin/env bash
# Simulate an unreachable/broken store: every task invocation fails.
exit 1
SH
chmod +x "$BADBIN/task"

make_home() {  # <name> -> home dir
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' "$home"
}

write_backlog() {  # <home> <line...> - write data/backlog.md with the given raw lines
  local home=$1; shift
  local f="$home/data/backlog.md"
  : > "$f"
  local l
  for l in "$@"; do
    printf '%s\n' "$l" >> "$f"
  done
}

add_origin() {  # <home> <origin-id>
  local home=$1 origin=$2
  fm_write_meta "$home/state/$origin.meta" \
    "window=firstmate:fm-$origin" \
    "kind=scout"
}

run_import() {  # <home> <args...>
  local home=$1; shift
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_BEADS_FLEET_LABEL="$FLEET" \
    "$IMPORT" "$@"
}

run_import_badstore() {  # <home> <args...>
  local home=$1; shift
  PATH="$BADBIN:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_BEADS_FLEET_LABEL="$FLEET" \
    "$IMPORT" "$@"
}

bead_for() {  # <task-id> -> bead id carrying task:<id>, or empty
  beads -C "$STORE" list --label "task:$1" --all --json 2>/dev/null \
    | jq -r 'if type=="array" and length>0 then .[0].id else empty end'
}

bead_count_for() {  # <task-id> -> how many beads carry task:<id>
  beads -C "$STORE" list --label "task:$1" --all --json 2>/dev/null \
    | jq 'if type=="array" then length else 0 end'
}

bead_field() {  # <bead-id> <jq-path>
  beads -C "$STORE" show "$1" --json 2>/dev/null | jq -r ".[0]$2"
}

open_human_gates() {  # <bead-id> -> count of open blocking gates
  beads -C "$STORE" show "$1" --json 2>/dev/null \
    | jq '[.[0].dependencies[]? | select(.issue_type=="gate" and .dependency_type=="blocks" and .status=="open")] | length'
}

anchor_for_hold() {  # <hold-id> -> anchor bead carrying hold:<id>, or empty
  beads -C "$STORE" list --label "hold:$1" --all --json 2>/dev/null \
    | jq -r 'if type=="array" and length>0 then .[0].id else empty end'
}

test_inflight_and_queued_status_and_priority() {
  local home bead
  home=$(make_home statuses)
  write_backlog "$home" \
    '## In flight' \
    '- [ ] alpha-run - Active alpha work (repo: alpha) (kind: ship) (priority: 1)' \
    '' \
    '## Queued' \
    '- [ ] beta-wait - Queued beta work (repo: beta) (kind: ship) (priority: 3)' \
    '' \
    '## Done' \
    '- [x] gamma-old - Finished long ago (repo: gamma)'
  run_import "$home" --apply >/dev/null

  bead=$(bead_for alpha-run)
  [ -n "$bead" ] || fail "statuses: no bead created for in-flight item"
  [ "$(bead_field "$bead" .status)" = in_progress ] \
    || fail "statuses: in-flight item should map to in_progress"
  [ "$(bead_field "$bead" .priority)" = 1 ] \
    || fail "statuses: in-flight priority 1 was not carried over"
  [ "$(bead_field "$bead" .title)" = "Active alpha work" ] \
    || fail "statuses: in-flight title was not extracted cleanly"
  printf '%s' "$(bead_field "$bead" .description)" | grep -Fq '(repo: alpha)' \
    || fail "statuses: full body was not preserved in the description"

  bead=$(bead_for beta-wait)
  [ -n "$bead" ] || fail "statuses: no bead created for queued item"
  [ "$(bead_field "$bead" .status)" = open ] \
    || fail "statuses: queued item should map to open"
  [ "$(bead_field "$bead" .priority)" = 3 ] \
    || fail "statuses: queued priority 3 was not carried over"

  [ "$(bead_count_for gamma-old)" = 0 ] \
    || fail "statuses: a Done item was migrated but must not be"
  pass "in-flight->in_progress, queued->open, priority carried, Done not migrated"
}

test_dry_run_writes_nothing() {
  local home out
  home=$(make_home dryrun)
  write_backlog "$home" \
    '## In flight' \
    '- [ ] dry-item - Would be created (repo: alpha) (kind: ship)'
  out=$(run_import "$home")
  assert_contains "$out" "DRY RUN" "dryrun: default run should announce a dry run"
  assert_contains "$out" "dry-item" "dryrun: dry run should list the item it would import"
  [ "$(bead_count_for dry-item)" = 0 ] \
    || fail "dryrun: a dry run must not create any bead"
  pass "dry run previews items and writes nothing to the store"
}

test_idempotent_no_duplicates() {
  local home first second
  home=$(make_home idem)
  write_backlog "$home" \
    '## In flight' \
    '- [ ] idem-item - Repeatable work (repo: alpha) (kind: ship) (priority: 2)' \
    '## Queued' \
    '- [ ] idem-queued - Repeatable queued (repo: alpha) (kind: ship)'
  run_import "$home" --apply >/dev/null
  first=$(bead_for idem-item)
  run_import "$home" --apply >/dev/null
  second=$(bead_for idem-item)

  [ "$first" = "$second" ] \
    || fail "idem: re-run resolved a different bead ($first vs $second)"
  [ "$(bead_count_for idem-item)" = 1 ] \
    || fail "idem: re-running the import duplicated the in-flight bead"
  [ "$(bead_count_for idem-queued)" = 1 ] \
    || fail "idem: re-running the import duplicated the queued bead"
  pass "re-running the import is idempotent and creates no duplicate beads"
}

test_captain_decision_hold_becomes_anchor_and_gate() {
  local home anchor
  home=$(make_home cap-decision)
  add_origin "$home" invest
  write_backlog "$home" \
    '## Queued' \
    '- [ ] invest-decision-route - Choose a route (repo: alpha) (kind: ship) (hold: north or south) (hold-kind: captain)'
  run_import "$home" --apply >/dev/null

  anchor=$(anchor_for_hold invest-decision-route)
  [ -n "$anchor" ] || fail "cap-decision: no decision-hold anchor bead was created"
  [ "$(open_human_gates "$anchor")" = 1 ] \
    || fail "cap-decision: the decision-hold anchor is not blocked by an open human gate"
  beads -C "$STORE" show "$anchor" --json 2>/dev/null \
    | jq -e '.[0].labels | index("captain-hold") and index("human")' >/dev/null \
    || fail "cap-decision: anchor is missing the captain-hold/human labels"
  pass "a captain decision-hold identity migrates to a labeled anchor plus a human gate"
}

test_captain_gated_work_item_gets_human_gate() {
  local home bead
  home=$(make_home cap-thread)
  write_backlog "$home" \
    '## Queued' \
    '- [ ] held-thread - Captain-gated thread (repo: alpha) (kind: ship) (hold: awaiting captain) (hold-kind: captain)'
  run_import "$home" --apply >/dev/null

  bead=$(bead_for held-thread)
  [ -n "$bead" ] || fail "cap-thread: no bead created for the gated work item"
  [ "$(open_human_gates "$bead")" = 1 ] \
    || fail "cap-thread: the gated work item is not blocked by an open human gate"

  # Idempotent: a re-run must not stack a second gate on the same item.
  run_import "$home" --apply >/dev/null
  [ "$(open_human_gates "$bead")" = 1 ] \
    || fail "cap-thread: re-running the import added a duplicate human gate"
  pass "a bare captain-gated thread migrates to its own bead plus one human gate, idempotently"
}

test_unreachable_store_fails_closed() {
  local home rc err
  home=$(make_home unreachable)
  write_backlog "$home" \
    '## In flight' \
    '- [ ] never-run - Should never be created (repo: alpha) (kind: ship)'
  set +e
  err=$(run_import_badstore "$home" --apply 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unreachable: importer should fail when the store is unreachable"
  assert_contains "$err" "unreachable" "unreachable: missing the expected fail-closed message"
  # And nothing partial should have been written to the real (reachable) store.
  [ "$(bead_count_for never-run)" = 0 ] \
    || fail "unreachable: a bead was created despite the store being reported unreachable"
  pass "the importer fails closed and writes nothing when the store is unreachable"
}

test_inflight_and_queued_status_and_priority
test_dry_run_writes_nothing
test_idempotent_no_duplicates
test_captain_decision_hold_becomes_anchor_and_gate
test_captain_gated_work_item_gets_human_gate
test_unreachable_store_fails_closed

echo "# all fm-backlog-import-beads tests passed"
