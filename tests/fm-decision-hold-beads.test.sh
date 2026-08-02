#!/usr/bin/env bash
# End-to-end tests for bin/fm-decision-hold.sh's beads-native captain hold path
# (config/backlog-backend=beads): a `task gate create --type=human` blocking a
# labeled anchor bead is the active-hold state, and `task dep` edges wire routed
# dependent work onto that gate. See docs/decision-hold-lifecycle.md.
#
# Uses a real, isolated beads store (never the shared federated store) so the
# lifecycle is exercised against actual gate/dep semantics, not a hand-rolled
# mock of them.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECISION_HOLD="$ROOT/bin/fm-decision-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold-beads)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v beads >/dev/null 2>&1 || { echo "skip: beads not found"; exit 0; }

# One isolated beads store for the whole suite; test cases use distinct
# origin ids and decision keys so they never collide within it.
STORE="$TMP_ROOT/store"
mkdir -p "$STORE"
(cd "$STORE" && beads init --prefix bht >/dev/null 2>&1) \
  || { echo "skip: could not init an isolated beads store"; exit 0; }

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/task" <<SH
#!/usr/bin/env bash
exec beads -C "$STORE" "\$@"
SH
chmod +x "$FAKEBIN/task"

make_home() {  # <name> -> home dir, with config/backlog-backend=beads
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf 'beads\n' > "$home/config/backlog-backend"
  printf '%s\n' "$home"
}

add_origin() {  # <home> <origin-id> [kind]
  local home=$1 origin=$2 kind=${3:-ship}
  fm_write_meta "$home/state/$origin.meta" \
    "window=firstmate:fm-$origin" \
    "kind=$kind"
}

run_hold() {  # <home> <args...>
  local home=$1; shift
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$DECISION_HOLD" "$@"
}

anchor_json() {  # <label>
  beads -C "$STORE" list --label "$1" --all --json 2>/dev/null | jq -c '.[0] // empty'
}

open_gate_for() {  # <anchor-id>
  beads -C "$STORE" show "$1" --json 2>/dev/null \
    | jq -r '.[0].dependencies[]? | select(.issue_type=="gate" and .dependency_type=="blocks" and .status=="open") | .id' \
    | head -1
}

test_hold_creates_anchor_and_open_gate() {
  local home id out anchor gate
  home=$(make_home hold-basic)
  add_origin "$home" bh-alpha
  out=$(run_hold "$home" hold bh-alpha route-choice \
    --title "Pick a route" --reason "north or south" --repo sample)
  id=$(printf '%s' "$out" | tail -1)
  [ "$id" = "bh-alpha-decision-route-choice" ] \
    || fail "hold-basic: unexpected id output: $out"

  anchor=$(anchor_json "hold:bh-alpha-decision-route-choice")
  [ -n "$anchor" ] || fail "hold-basic: no anchor bead was created"
  [ "$(printf '%s' "$anchor" | jq -r '.status')" = open ] \
    || fail "hold-basic: anchor should be open"
  [ "$(printf '%s' "$anchor" | jq -r '.title')" = "Pick a route" ] \
    || fail "hold-basic: anchor title mismatch"
  [ "$(printf '%s' "$anchor" | jq -r '.metadata.hold_reason')" = "north or south" ] \
    || fail "hold-basic: anchor did not record hold_reason metadata"
  printf '%s' "$anchor" | jq -e '.labels | index("captain-hold") and index("human")' >/dev/null \
    || fail "hold-basic: anchor is missing captain-hold/human labels"

  gate=$(open_gate_for "$(printf '%s' "$anchor" | jq -r '.id')")
  [ -n "$gate" ] || fail "hold-basic: no open human gate blocks the anchor"
  pass "hold creates a labeled anchor bead with an open human gate and recorded hold_reason"
}

test_hold_is_idempotent_on_retry() {
  local home anchor_id gate_count
  home=$(make_home hold-retry)
  add_origin "$home" bh-beta
  run_hold "$home" hold bh-beta pick-again \
    --title "Pick again" --reason "reason one" --repo sample >/dev/null
  run_hold "$home" hold bh-beta pick-again \
    --title "Pick again" --reason "reason one" --repo sample >/dev/null

  anchor_id=$(anchor_json "hold:bh-beta-decision-pick-again" | jq -r '.id')
  gate_count=$(beads -C "$STORE" show "$anchor_id" --json 2>/dev/null \
    | jq '[.[0].dependencies[]? | select(.issue_type=="gate" and .dependency_type=="blocks")] | length')
  [ "$gate_count" = 1 ] \
    || fail "hold-retry: expected exactly one gate after two identical hold calls, got $gate_count"
  pass "hold is idempotent on an identical retry: no duplicate gate is created"
}

test_hold_rejects_changed_title() {
  local home err rc
  home=$(make_home hold-title-change)
  add_origin "$home" bh-gamma
  run_hold "$home" hold bh-gamma retitle \
    --title "Original title" --reason "r" --repo sample >/dev/null

  set +e
  err=$(run_hold "$home" hold bh-gamma retitle \
    --title "Different title" --reason "r" --repo sample 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "hold-title-change: a changed title should be rejected"
  assert_contains "$err" "different title" "hold-title-change: missing the expected error text"
  pass "hold rejects a retry that changes the recorded title"
}

test_verify_and_complete_recognize_beads_hold() {
  local home out
  home=$(make_home complete-verify)
  add_origin "$home" bh-delta
  run_hold "$home" hold bh-delta open-question \
    --title "Open question" --reason "r" --repo sample >/dev/null

  out=$(run_hold "$home" complete bh-delta open-question)
  assert_contains "$out" "complete: bh-delta decision inventory reviewed" \
    "complete-verify: complete did not accept the beads-durable hold"

  out=$(run_hold "$home" verify bh-delta)
  assert_contains "$out" "verified: bh-delta" \
    "complete-verify: verify did not accept the beads-durable hold"
  pass "complete and verify recognize an actively-held beads decision as durable"
}

test_resolve_clears_dep_edges_and_closes_gate_and_anchor() {
  local home anchor anchor_id gate dep_id decision_file out status
  home=$(make_home resolve-basic)
  add_origin "$home" bh-epsilon
  run_hold "$home" hold bh-epsilon go-decision \
    --title "Go decision" --reason "r" --repo sample >/dev/null
  anchor=$(anchor_json "hold:bh-epsilon-decision-go-decision")
  anchor_id=$(printf '%s' "$anchor" | jq -r '.id')
  gate=$(open_gate_for "$anchor_id")

  dep_id=$(beads -C "$STORE" create "Routed work for go-decision" --json 2>/dev/null | jq -r '.id')
  beads -C "$STORE" dep add "$dep_id" "$gate" >/dev/null

  decision_file="$TMP_ROOT/resolve-basic-decision.txt"
  printf 'Go with the plan.\n' > "$decision_file"
  out=$(run_hold "$home" resolve bh-epsilon go-decision \
    --decision-file "$decision_file" --routed-to "$dep_id")
  assert_contains "$out" "resolved: bh-epsilon-decision-go-decision -> $dep_id" \
    "resolve-basic: unexpected resolve output: $out"

  status=$(beads -C "$STORE" show "$anchor_id" --json 2>/dev/null | jq -r '.[0].status')
  [ "$status" = closed ] || fail "resolve-basic: anchor should be closed after resolve"
  status=$(beads -C "$STORE" show "$gate" --json 2>/dev/null | jq -r '.[0].status')
  [ "$status" = closed ] || fail "resolve-basic: gate should be closed after resolve"

  local remaining_gate_deps
  remaining_gate_deps=$(beads -C "$STORE" show "$dep_id" --json 2>/dev/null \
    | jq --arg gate "$gate" '[.[0].dependencies[]? | select(.id==$gate and .status=="open")] | length')
  [ "$remaining_gate_deps" = 0 ] \
    || fail "resolve-basic: routed task should no longer be blocked by the resolved gate"
  pass "resolve records the decision, clears dependency edges, and closes the gate and anchor"
}

test_resolve_is_idempotent_on_exact_retry() {
  local home anchor anchor_id gate dep_id decision_file out1 out2
  home=$(make_home resolve-retry)
  add_origin "$home" bh-zeta
  run_hold "$home" hold bh-zeta repeat-resolve \
    --title "Repeat resolve" --reason "r" --repo sample >/dev/null
  anchor=$(anchor_json "hold:bh-zeta-decision-repeat-resolve")
  anchor_id=$(printf '%s' "$anchor" | jq -r '.id')
  gate=$(open_gate_for "$anchor_id")
  dep_id=$(beads -C "$STORE" create "Routed work for repeat-resolve" --json 2>/dev/null | jq -r '.id')
  beads -C "$STORE" dep add "$dep_id" "$gate" >/dev/null

  decision_file="$TMP_ROOT/resolve-retry-decision.txt"
  printf 'Proceed.\n' > "$decision_file"
  out1=$(run_hold "$home" resolve bh-zeta repeat-resolve \
    --decision-file "$decision_file" --routed-to "$dep_id")
  out2=$(run_hold "$home" resolve bh-zeta repeat-resolve \
    --decision-file "$decision_file" --routed-to "$dep_id")
  [ "$out1" = "$out2" ] \
    || fail "resolve-retry: an exact retry should produce the same output ($out1 vs $out2)"
  pass "resolve is idempotent on an exact retry of the same decision and routed set"
}

test_resolve_rejects_changed_decision_on_retry() {
  local home anchor anchor_id gate dep_id decision_file err rc
  home=$(make_home resolve-changed)
  add_origin "$home" bh-eta
  run_hold "$home" hold bh-eta changed-decision \
    --title "Changed decision" --reason "r" --repo sample >/dev/null
  anchor=$(anchor_json "hold:bh-eta-decision-changed-decision")
  anchor_id=$(printf '%s' "$anchor" | jq -r '.id')
  gate=$(open_gate_for "$anchor_id")
  dep_id=$(beads -C "$STORE" create "Routed work for changed-decision" --json 2>/dev/null | jq -r '.id')
  beads -C "$STORE" dep add "$dep_id" "$gate" >/dev/null

  decision_file="$TMP_ROOT/resolve-changed-decision-1.txt"
  printf 'First decision.\n' > "$decision_file"
  run_hold "$home" resolve bh-eta changed-decision \
    --decision-file "$decision_file" --routed-to "$dep_id" >/dev/null

  decision_file="$TMP_ROOT/resolve-changed-decision-2.txt"
  printf 'A different decision.\n' > "$decision_file"
  set +e
  err=$(run_hold "$home" resolve bh-eta changed-decision \
    --decision-file "$decision_file" --routed-to "$dep_id" 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "resolve-changed: a changed decision on retry should be rejected"
  assert_contains "$err" "records a different captain decision" \
    "resolve-changed: missing the expected error text"
  pass "resolve rejects a retry that changes the recorded captain decision"
}

test_resolve_rejects_task_not_durably_blocked() {
  local home dep_id decision_file err rc
  home=$(make_home resolve-unblocked)
  add_origin "$home" bh-theta
  run_hold "$home" hold bh-theta unblocked-dep \
    --title "Unblocked dep" --reason "r" --repo sample >/dev/null
  dep_id=$(beads -C "$STORE" create "Unrelated free task" --json 2>/dev/null | jq -r '.id')

  decision_file="$TMP_ROOT/resolve-unblocked-decision.txt"
  printf 'Proceed anyway.\n' > "$decision_file"
  set +e
  err=$(run_hold "$home" resolve bh-theta unblocked-dep \
    --decision-file "$decision_file" --routed-to "$dep_id" 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "resolve-unblocked: an unblocked routed task should be rejected"
  assert_contains "$err" "is not durably blocked by" \
    "resolve-unblocked: missing the expected error text"
  pass "resolve rejects a routed task that is not durably blocked by the hold's gate"
}

test_hold_rejects_reopening_a_resolved_decision() {
  local home anchor anchor_id gate dep_id decision_file err rc
  home=$(make_home hold-reopen)
  add_origin "$home" bh-iota
  run_hold "$home" hold bh-iota one-shot \
    --title "One shot decision" --reason "r" --repo sample >/dev/null
  anchor=$(anchor_json "hold:bh-iota-decision-one-shot")
  anchor_id=$(printf '%s' "$anchor" | jq -r '.id')
  gate=$(open_gate_for "$anchor_id")
  dep_id=$(beads -C "$STORE" create "Routed work for one-shot" --json 2>/dev/null | jq -r '.id')
  beads -C "$STORE" dep add "$dep_id" "$gate" >/dev/null
  decision_file="$TMP_ROOT/hold-reopen-decision.txt"
  printf 'Decided.\n' > "$decision_file"
  run_hold "$home" resolve bh-iota one-shot \
    --decision-file "$decision_file" --routed-to "$dep_id" >/dev/null

  set +e
  err=$(run_hold "$home" hold bh-iota one-shot \
    --title "One shot decision" --reason "r" --repo sample 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "hold-reopen: reopening a resolved decision should be rejected"
  assert_contains "$err" "already durably resolved" \
    "hold-reopen: missing the expected error text"
  pass "hold rejects reopening an already-resolved decision identity"
}

test_hold_creates_anchor_and_open_gate
test_hold_is_idempotent_on_retry
test_hold_rejects_changed_title
test_verify_and_complete_recognize_beads_hold
test_resolve_clears_dep_edges_and_closes_gate_and_anchor
test_resolve_is_idempotent_on_exact_retry
test_resolve_rejects_changed_decision_on_retry
test_resolve_rejects_task_not_durably_blocked
test_hold_rejects_reopening_a_resolved_decision

echo "# all fm-decision-hold-beads tests passed"
