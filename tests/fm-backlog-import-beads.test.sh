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

# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-tasks-axi-lib.sh"

IMPORT="$ROOT/bin/fm-backlog-import-beads.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-import-beads)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v beads >/dev/null 2>&1 || { echo "skip: beads not found"; exit 0; }

FLEET="fleet:test-import"

# The importer mints the HOME-SCOPED idempotency label (bin/fm-tasks-axi-lib.sh's
# fm_beads_task_label owns its shape), so these helpers must name that same label
# rather than the pre-migration unscoped task:<id>. One scope is pinned for the
# whole suite - it shares the store exactly the way the old unscoped label did, and
# cases already use distinct backlog ids so they never collide. Cross-home
# separation is a property of the label itself, covered by
# tests/fm-beads-backend.test.sh rather than here.
HOME_SCOPE="import-beads-suite"

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

# A fakebin whose `task create` is refused by the store while every other
# subcommand still works, to drive the abort path for a rejected bead create.
NOCREATEBIN="$TMP_ROOT/nocreatebin"
mkdir -p "$NOCREATEBIN"
cat > "$NOCREATEBIN/task" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = create ]; then
  echo "beads: create refused by store validation" >&2
  exit 1
fi
exec beads -C "$STORE" "\$@"
SH
chmod +x "$NOCREATEBIN/task"

# A fakebin whose `task create` really creates but returns no id on stdout, the
# other way fm_beads_resolve_or_create's fail-open contract yields a bare
# failure: the write landed, so the importer must say so rather than blame the
# item's fields.
SILENTBIN="$TMP_ROOT/silentbin"
mkdir -p "$SILENTBIN"
cat > "$SILENTBIN/task" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = create ]; then
  beads -C "$STORE" "\$@" >/dev/null 2>&1
  exit 0
fi
exec beads -C "$STORE" "\$@"
SH
chmod +x "$SILENTBIN/task"

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
    FM_BEADS_FLEET_LABEL="$FLEET" FM_BEADS_HOME_SCOPE="$HOME_SCOPE" \
    "$IMPORT" "$@"
}

run_import_badstore() {  # <home> <args...>
  local home=$1; shift
  PATH="$BADBIN:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_BEADS_FLEET_LABEL="$FLEET" FM_BEADS_HOME_SCOPE="$HOME_SCOPE" \
    "$IMPORT" "$@"
}

run_import_with_bin() {  # <fakebin-dir> <home> <args...>
  local bin=$1 home=$2; shift 2
  PATH="$bin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_BEADS_FLEET_LABEL="$FLEET" FM_BEADS_HOME_SCOPE="$HOME_SCOPE" \
    "$IMPORT" "$@"
}

task_label_for() {  # <task-id> -> the home-scoped idempotency label the importer mints
  FM_BEADS_HOME_SCOPE="$HOME_SCOPE" fm_beads_task_label "$1"
}

bead_for() {  # <task-id> -> bead id carrying the task's idempotency label, or empty
  beads -C "$STORE" list --label "$(task_label_for "$1")" --all --json 2>/dev/null \
    | jq -r 'if type=="array" and length>0 then .[0].id else empty end'
}

bead_count_for() {  # <task-id> -> how many beads carry the task's idempotency label
  beads -C "$STORE" list --label "$(task_label_for "$1")" --all --json 2>/dev/null \
    | jq 'if type=="array" then length else 0 end'
}

bead_field() {  # <bead-id> <jq-path>
  beads -C "$STORE" show "$1" --json 2>/dev/null | jq -r ".[0]$2"
}

open_human_gates() {  # <bead-id> -> count of open blocking gates
  beads -C "$STORE" show "$1" --json 2>/dev/null \
    | jq '[.[0].dependencies[]? | select(.issue_type=="gate" and .dependency_type=="blocks" and .status=="open")] | length'
}

total_human_gates() {  # <bead-id> -> count of blocking gates in any state (open or closed)
  beads -C "$STORE" show "$1" --json 2>/dev/null \
    | jq '[.[0].dependencies[]? | select(.issue_type=="gate" and .dependency_type=="blocks")] | length'
}

gate_on() {  # <bead-id> -> id of a blocking gate on the bead, or empty
  beads -C "$STORE" show "$1" --json 2>/dev/null \
    | jq -r '[.[0].dependencies[]? | select(.issue_type=="gate" and .dependency_type=="blocks")][0].id // empty'
}

is_ready() {  # <bead-id> -> 0 if the bead appears in bd ready
  beads -C "$STORE" ready --json 2>/dev/null \
    | jq -e --arg b "$1" 'any(.[]?; .id == $b)' >/dev/null
}

has_blocks_edge() {  # <blocked-bead> <blocker-bead> -> count of blocks edges from blocker
  beads -C "$STORE" show "$1" --json 2>/dev/null \
    | jq --arg b "$2" '[.[0].dependencies[]? | select(.dependency_type=="blocks" and .id==$b)] | length'
}

anchor_for_hold() {  # <hold-id> -> anchor bead carrying hold:<id>, or empty
  beads -C "$STORE" list --label "hold:$1" --all --json 2>/dev/null \
    | jq -r 'if type=="array" and length>0 then .[0].id else empty end'
}

title_lines() {  # <bead-id> -> how many lines the stored title occupies
  bead_field "$1" .title | wc -l | tr -d ' '
}

assert_title() {  # <case> <task-id> <expected title>
  local case=$1 id=$2 want=$3 bead got
  bead=$(bead_for "$id")
  [ -n "$bead" ] || fail "$case: no bead created for $id"
  [ "$(title_lines "$bead")" = 1 ] \
    || fail "$case: $id got a multi-line title: $(bead_field "$bead" .title)"
  got=$(bead_field "$bead" .title)
  [ "$got" = "$want" ] \
    || fail "$case: $id title is '$got', expected '$want'"
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

test_captain_decision_hold_key_containing_decision() {
  local home anchor
  home=$(make_home cap-decision-key)
  # The origin is `spike`; the decision KEY itself contains "decision-" (a hold
  # about decision-hold design). fm-decision-hold.sh composes the identity as
  # <origin>-decision-<key>, so the importer must split on the FIRST
  # "-decision-". Splitting on the last one yields origin `spike-decision`,
  # which this home does not own, and the item fails closed instead of migrating.
  add_origin "$home" spike
  write_backlog "$home" \
    '## Queued' \
    '- [ ] spike-decision-decision-hold-representation - Validate the decision-hold shape (repo: alpha) (kind: ship) (hold: needs captain sign-off) (hold-kind: captain)'
  run_import "$home" --apply >/dev/null

  anchor=$(anchor_for_hold spike-decision-decision-hold-representation)
  [ -n "$anchor" ] \
    || fail "cap-decision-key: no anchor for a decision key that itself contains 'decision-'"
  [ "$(open_human_gates "$anchor")" = 1 ] \
    || fail "cap-decision-key: the anchor is not blocked by an open human gate"
  pass "a decision key containing 'decision-' still resolves to its real origin and migrates"
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

test_blocked_by_becomes_real_dependency_edge() {
  local home waiter blocker out
  home=$(make_home blocked-by)
  # The blocker is declared AFTER the waiter, so a correct import must resolve it
  # in a second pass rather than at the moment the waiter's bead is created.
  write_backlog "$home" \
    '## Queued' \
    '- [ ] dep-waiter - Waits on the blocker (repo: alpha) (kind: ship) blocked-by: dep-blocker - needs it first' \
    '- [ ] dep-blocker - The blocker (repo: alpha) (kind: ship)'

  # Dry run must report the edge it would add, and write nothing.
  out=$(run_import "$home")
  assert_contains "$out" "blocked-by dep-blocker" "blocked-by: dry run should report the dependency edge"
  [ "$(bead_count_for dep-waiter)" = 0 ] \
    || fail "blocked-by: dry run created a bead"

  run_import "$home" --apply >/dev/null
  waiter=$(bead_for dep-waiter)
  blocker=$(bead_for dep-blocker)
  [ -n "$waiter" ] && [ -n "$blocker" ] \
    || fail "blocked-by: beads were not created for the pair"
  [ "$(has_blocks_edge "$waiter" "$blocker")" = 1 ] \
    || fail "blocked-by: no real dependency edge from blocker to waiter"
  # The edge must actually withhold the waiter from ready while the blocker is open.
  is_ready "$waiter" \
    && fail "blocked-by: waiter appears ready despite an open blocker"
  is_ready "$blocker" \
    || fail "blocked-by: the blocker itself should be ready"

  # Idempotent: a re-run must not duplicate the edge.
  run_import "$home" --apply >/dev/null
  [ "$(has_blocks_edge "$waiter" "$blocker")" = 1 ] \
    || fail "blocked-by: re-running the import duplicated the dependency edge"
  pass "blocked-by becomes a real bead dependency edge that hides the waiter until its blocker closes, idempotently"
}

test_dated_gate_defers_bead() {
  local home gated ungated out
  home=$(make_home dated-gate)
  # A far-future dated gate must hide the bead; an item with no gate is untouched.
  write_backlog "$home" \
    '## Queued' \
    '- [ ] gate-future - Held until a future date (repo: alpha) (kind: ship) (since 2099-01-01)' \
    '- [ ] gate-none - No time gate here (repo: alpha) (kind: ship)'

  # Dry run must report the defer it would set, and write nothing.
  out=$(run_import "$home")
  assert_contains "$out" "defer=2099-01-01" "dated-gate: dry run should report the defer date"
  [ "$(bead_count_for gate-future)" = 0 ] \
    || fail "dated-gate: dry run created a bead"

  run_import "$home" --apply >/dev/null
  gated=$(bead_for gate-future)
  ungated=$(bead_for gate-none)
  [ -n "$gated" ] && [ -n "$ungated" ] \
    || fail "dated-gate: beads were not created"
  is_ready "$gated" \
    && fail "dated-gate: the dated-gate item appears ready despite a future defer date"
  is_ready "$ungated" \
    || fail "dated-gate: an item with no gate was wrongly withheld from ready"
  pass "a dated (since) time gate defers the bead so it is hidden from ready; an ungated item is unaffected"
}

test_resolved_gate_not_resurrected() {
  local home bead gate
  home=$(make_home resolved-gate)
  write_backlog "$home" \
    '## Queued' \
    '- [ ] resolve-me - Captain-gated thread (repo: alpha) (kind: ship) (hold: awaiting captain) (hold-kind: captain)'
  run_import "$home" --apply >/dev/null
  bead=$(bead_for resolve-me)
  [ -n "$bead" ] || fail "resolved-gate: no bead created for the gated item"
  [ "$(open_human_gates "$bead")" = 1 ] \
    || fail "resolved-gate: expected exactly one open human gate initially"

  # The captain resolves (closes) the gate: the decision is now made.
  gate=$(gate_on "$bead")
  [ -n "$gate" ] || fail "resolved-gate: could not find the gate to resolve"
  beads -C "$STORE" gate resolve "$gate" >/dev/null 2>&1 \
    || fail "resolved-gate: could not resolve the human gate"
  [ "$(open_human_gates "$bead")" = 0 ] \
    || fail "resolved-gate: the gate was not actually resolved"

  # A re-run must NOT re-add a gate the captain has already resolved.
  run_import "$home" --apply >/dev/null
  [ "$(open_human_gates "$bead")" = 0 ] \
    || fail "resolved-gate: re-running the import resurrected a captain-resolved gate"
  [ "$(total_human_gates "$bead")" = 1 ] \
    || fail "resolved-gate: re-run added a second gate alongside the resolved one"
  pass "a re-run does not resurrect a human gate the captain has already resolved"
}

test_multiline_body_yields_single_line_title() {
  local home bead
  home=$(make_home multiline-title)
  # Backlog item bodies are multi-line: a title line plus indented continuation
  # lines. A bead title is single-line, so the whole body must collapse to the
  # first line's cut text - no continuation line may leak into the title field,
  # whether or not it carries markers of its own.
  write_backlog "$home" \
    '## In flight' \
    '- [ ] multi-body - Make remote panes typeable (repo: alpha) (kind: ship) (priority: 1)' \
    '  Federation input relay. PR #7 open on trillium/herdr.' \
    '  Next: confirm the relay handshake survives reconnect.' \
    '' \
    '## Queued' \
    '- [ ] multi-plainfirst - Plain first line with no markers' \
    '  Follow-up detail (repo: beta) (priority: 3)'
  run_import "$home" --apply >/dev/null

  assert_title multiline-title multi-body 'Make remote panes typeable'
  # A continuation line's own markers must not cut the title either: the title
  # comes from line 1 only, so a marker-free first line survives whole.
  assert_title multiline-title multi-plainfirst 'Plain first line with no markers'

  # The full multi-line body still has to survive as the bead description.
  bead=$(bead_for multi-body)
  printf '%s' "$(bead_field "$bead" .description)" | grep -Fq 'survives reconnect' \
    || fail "multiline-title: continuation lines were dropped from the description"
  printf '%s' "$(bead_field "$bead" .description)" | grep -Fq '(repo: alpha)' \
    || fail "multiline-title: the title line's markers were dropped from the description"
  pass "a multi-line item body yields a single-line title while the full body stays the description"
}

test_single_line_marker_cuts_unchanged() {
  local home
  home=$(make_home marker-cuts)
  # One item per trailing marker, each as the first marker on a single-line body,
  # plus the no-marker, earliest-wins, and trailing-space cases.
  write_backlog "$home" \
    '## Queued' \
    '- [ ] mark-repo - Repo scoped work (repo: alpha)' \
    '- [ ] mark-kind - Ship this thing (kind: ship)' \
    '- [ ] mark-priority - Priority scoped work (priority: 2)' \
    '- [ ] mark-since - Held until later (since 2099-01-01)' \
    '- [ ] mark-hold - Waiting on something (hold: pending review)' \
    '- [ ] mark-holdkind - Agent held item (hold-kind: agent)' \
    '- [ ] mark-blockedby - Waits on another item blocked-by: mark-blocker' \
    '- [ ] mark-blocker - The blocker for marker cuts (repo: alpha)' \
    '- [ ] mark-http - See the upstream issue https://example.com/issues/1' \
    '- [ ] mark-none - A plain title with no markers at all' \
    '- [ ] mark-earliest - Earliest marker wins (priority: 1) (repo: alpha)' \
    '- [ ] mark-space - Trimmed title   (repo: alpha)'
  run_import "$home" --apply >/dev/null

  assert_title marker-cuts mark-repo 'Repo scoped work'
  assert_title marker-cuts mark-kind 'Ship this thing'
  assert_title marker-cuts mark-priority 'Priority scoped work'
  assert_title marker-cuts mark-since 'Held until later'
  assert_title marker-cuts mark-hold 'Waiting on something'
  assert_title marker-cuts mark-holdkind 'Agent held item'
  assert_title marker-cuts mark-blockedby 'Waits on another item'
  assert_title marker-cuts mark-http 'See the upstream issue'
  assert_title marker-cuts mark-none 'A plain title with no markers at all'
  assert_title marker-cuts mark-earliest 'Earliest marker wins'
  assert_title marker-cuts mark-space 'Trimmed title'
  pass "every trailing-marker cut, the no-marker case, earliest-wins, and trailing-space trimming are unchanged"
}

test_rejected_create_reports_why() {
  local home rc err
  home=$(make_home reject-create)
  write_backlog "$home" \
    '## In flight' \
    '- [ ] diag-item - Diagnosable work (repo: alpha) (kind: ship)'
  set +e
  err=$(run_import_with_bin "$NOCREATEBIN" "$home" --apply 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reject-create: importer should abort when a bead create is refused"
  assert_contains "$err" "rejected the bead create for diag-item" \
    "reject-create: abort message does not name the rejected create or the item"
  assert_contains "$err" "'task create' itself refused this title" \
    "reject-create: abort message does not distinguish a refused create from an unreachable store"
  assert_contains "$err" "(1 line(s)" \
    "reject-create: abort message does not report the rejected title's shape"
  assert_contains "$err" "Diagnosable work" \
    "reject-create: abort message does not include the rejected title itself"
  [ "$(bead_count_for diag-item)" = 0 ] \
    || fail "reject-create: a bead was created despite the refused create"

  # The other fail-open shape: the create really lands but returns no id. That is
  # the opposite response (re-run converges), so the message must say so instead
  # of blaming the item's fields.
  write_backlog "$home" \
    '## In flight' \
    '- [ ] diag-landed - Landed but silent (repo: alpha) (kind: ship)'
  set +e
  err=$(run_import_with_bin "$SILENTBIN" "$home" --apply 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reject-create: importer should abort when no bead id came back"
  assert_contains "$err" "the create landed without returning its id" \
    "reject-create: abort message does not recognise a create that actually landed"
  assert_contains "$err" "re-run --apply to converge" \
    "reject-create: abort message does not name the recovery for a landed create"
  pass "a refused bead create aborts with an actionable reason, distinguished from a create that landed silently"
}

test_inflight_and_queued_status_and_priority
test_dry_run_writes_nothing
test_idempotent_no_duplicates
test_captain_decision_hold_becomes_anchor_and_gate
test_captain_decision_hold_key_containing_decision
test_captain_gated_work_item_gets_human_gate
test_unreachable_store_fails_closed
test_blocked_by_becomes_real_dependency_edge
test_dated_gate_defers_bead
test_resolved_gate_not_resurrected
test_multiline_body_yields_single_line_title
test_single_line_marker_cuts_unchanged
test_rejected_create_reports_why

echo "# all fm-backlog-import-beads tests passed"
