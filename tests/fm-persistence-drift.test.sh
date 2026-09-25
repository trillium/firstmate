#!/usr/bin/env bash
# Behavioral test for persistence drift gate (drift.persist).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-persistence-drift)

test_snapshot_generation() {
  local snap="$TMP_ROOT/snap.json"
  python3 "$ROOT/drift/persist_snapshot.py" --fm-home "$ROOT" -o "$snap" || fail "persist_snapshot failed"
  [ -f "$snap" ] || fail "snapshot file not created"

  # Check JSON structure
  python3 -c "
import json
with open('$snap') as f:
    d = json.load(f)
assert d['version'] == 1
assert 'boundaries' in d
assert 'surfaces' in d
assert len(d['boundaries']) == 15
assert 'state/<id>.meta' in d['surfaces']
assert 'data/projects.md' in d['surfaces']
" || fail "snapshot JSON schema validation failed"

  pass "persist_snapshot generates valid schema"
}

test_drift_check_clean() {
  local baseline="$ROOT/drift/persist_baseline.json"
  [ -f "$baseline" ] || fail "baseline missing"

  local out
  out=$(python3 "$ROOT/drift/persist_check.py" --fm-home "$ROOT" --format text)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "persist_check returned non-zero on clean repo: $rc ($out)"
  assert_grep "persistence-drift: CLEAN" <(printf '%s\n' "$out") "persist_check did not report CLEAN"

  pass "persist_check reports clean against current baseline"
}

test_drift_detection_on_mutation() {
  local snap_clean="$TMP_ROOT/clean.json"
  local snap_dirty="$TMP_ROOT/dirty.json"

  python3 "$ROOT/drift/persist_snapshot.py" --fm-home "$ROOT" -o "$snap_clean"

  # Simulate drift in dirty snapshot (add a new unmapped surface)
  python3 -c "
import json
with open('$snap_clean') as f:
    d = json.load(f)
d['surfaces']['state/unmapped_shadow_file.meta'] = {
    'boundary': 'boundary_4',
    'category': 'Unclassified',
    'beads_role': 'UNKNOWN',
    'verified_writers': ['bin/fm-evil.sh:10'],
    'verified_readers': [],
    'bypass_leaks': []
}
with open('$snap_dirty', 'w') as f:
    json.dump(d, f)
"

  local out
  out=$(python3 "$ROOT/drift/persist_check.py" "$snap_clean" "$snap_dirty" --format text 2>&1)
  local rc=$?
  [ "$rc" -eq 1 ] || fail "persist_check should exit 1 on persistence drift (got $rc)"
  assert_grep "new_surfaces: 1" <(printf '%s\n' "$out") "did not detect new surface"

  pass "persist_check detects unmapped persistence drift and exits 1"
}

test_snapshot_generation
test_drift_check_clean
test_drift_detection_on_mutation
