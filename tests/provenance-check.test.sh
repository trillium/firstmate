#!/usr/bin/env bash
# Behavior tests for provenance/check.sh - the fork-feature provenance guard.
#
# Drives the guard through its CLI against an ISOLATED fixture tree (its own
# root, register, snapshot dir, and a fake target script) via the FM_PROV_ROOT /
# FM_PROV_REGISTER / FM_PROV_SNAP_DIR overrides, so nothing here touches the real
# bin/ scripts or the real register. Asserts the guard's contract through exit
# codes and messages, never by reading implementation source bytes:
#   - green (exit 0) on an intact tree,
#   - red (exit 1) when an anchored symbol is deleted (deletion tripwire),
#   - red (exit 1) when a feature's behavior changes vs its approved snapshot,
#   - that a mere signature drift is a WARN, not a FAIL,
#   - and that an anchor authored WITHOUT a sig line keeps its symbol (so the
#     deletion tripwire stays armed) and gets a sig line written by --regen.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/provenance/check.sh"
TMP_ROOT=$(fm_test_tmproot provenance-check)

# make_fixture: build a self-contained repo-shaped tree with one fake target
# script carrying an anchorable greet() function and a --help behavior, plus a
# register pointing at it. Echoes the fixture root.
make_fixture() {
  local fx="$TMP_ROOT/fx"
  rm -rf "$fx"
  mkdir -p "$fx/bin" "$fx/provenance" "$fx/tests/provenance"
  cat > "$fx/bin/feat.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
greet() {
  echo "hello from feat"
}
case "${1:-}" in
  --help) echo "feat.sh - a fixture feature"; exit 0 ;;
  *) greet ;;
esac
EOF
  chmod +x "$fx/bin/feat.sh"
  cat > "$fx/provenance/register.toml" <<'EOF'
version = 1

[[feature]]
id    = "fixture-feat"
story = "As a tester, I want the fixture feature present and behaving."
test  = "bin/feat.sh --help"
[[feature.anchor]]
path   = "bin/feat.sh"
symbol = "greet"
sig    = "PENDING"
EOF
  printf '%s\n' "$fx"
}

# make_fixture_nosig: the same fixture with the anchor's `sig` line removed - the
# natural first draft of a new anchor, authored before the first --regen. Echoes
# the fixture root.
make_fixture_nosig() {
  local fx; fx=$(make_fixture)
  grep -v '^sig ' "$fx/provenance/register.toml" > "$fx/provenance/register.toml.new"
  mv "$fx/provenance/register.toml.new" "$fx/provenance/register.toml"
  printf '%s\n' "$fx"
}

# run_check <fixture> [args...]: run the real check.sh against the fixture tree.
run_check() {
  local fx=$1; shift
  FM_PROV_ROOT="$fx" \
  FM_PROV_REGISTER="$fx/provenance/register.toml" \
  FM_PROV_SNAP_DIR="$fx/tests/provenance" \
    bash "$CHECK" "$@"
}

test_regen_then_green_on_intact() {
  local fx; fx=$(make_fixture)
  run_check "$fx" --regen >/dev/null 2>&1 || fail "regen should succeed on intact fixture"
  assert_grep 'sig    = "' "$fx/provenance/register.toml" "regen should replace PENDING with a real sig"
  assert_present "$fx/tests/provenance/fixture-feat/approved.txt" "regen should write the approved snapshot"
  local out ec
  out=$(run_check "$fx" 2>&1); ec=$?
  expect_code 0 "$ec" "intact fixture should pass"
  assert_contains "$out" "PASS  fixture-feat" "intact check should report PASS"
  pass "green (exit 0) on an intact tree after --regen"
}

test_deletion_tripwire() {
  local fx; fx=$(make_fixture)
  run_check "$fx" --regen >/dev/null 2>&1
  # Delete the anchored greet() function - simulates an upstream merge clobber.
  cat > "$fx/bin/feat.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  --help) echo "feat.sh - a fixture feature"; exit 0 ;;
  *) echo "hello from feat" ;;
esac
EOF
  local out ec
  out=$(run_check "$fx" 2>&1); ec=$?
  expect_code 1 "$ec" "deleted anchor symbol should fail the guard"
  assert_contains "$out" "FAIL  fixture-feat" "deletion should name the lost feature"
  assert_contains "$out" "anchor symbol vanished" "deletion should report the vanished symbol"
  pass "red (exit 1) with a named feature when an anchored symbol is deleted"
}

test_behavior_clobber() {
  local fx; fx=$(make_fixture)
  run_check "$fx" --regen >/dev/null 2>&1
  # Anchor stays put; only the --help behavior changes -> snapshot mismatch.
  cat > "$fx/bin/feat.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
greet() {
  echo "hello from feat"
}
case "${1:-}" in
  --help) echo "feat.sh - CHANGED help text"; exit 0 ;;
  *) greet ;;
esac
EOF
  local out ec
  out=$(run_check "$fx" 2>&1); ec=$?
  expect_code 1 "$ec" "changed behavior should fail the guard"
  assert_contains "$out" "behavior changed vs approved snapshot" "clobber should report the behavior change"
  pass "red (exit 1) when a feature's behavior changes vs its approved snapshot"
}

test_drift_is_warn_not_fail() {
  local fx; fx=$(make_fixture)
  run_check "$fx" --regen >/dev/null 2>&1
  # Edit the anchored function body but keep --help behavior identical: the sig
  # drifts (WARN) while the behavioral proof still passes -> overall exit 0.
  cat > "$fx/bin/feat.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
greet() {
  echo "hello from feat"
  # an added comment / extra line: drifts the signature, same behavior
  return 0
}
case "${1:-}" in
  --help) echo "feat.sh - a fixture feature"; exit 0 ;;
  *) greet ;;
esac
EOF
  local out ec
  out=$(run_check "$fx" 2>&1); ec=$?
  expect_code 0 "$ec" "a mere signature drift must not fail the guard"
  assert_contains "$out" "anchor drift" "drift should be reported"
  assert_contains "$out" "WARN  fixture-feat" "drift should downgrade to WARN, not FAIL"
  pass "signature drift is a WARN (exit 0), not a FAIL"
}

test_anchor_without_sig_keeps_its_symbol() {
  local fx; fx=$(make_fixture_nosig)
  # Before any --regen, the anchor is unblessed and must SAY so rather than pass
  # quietly. A missing sig must never be read as "no symbol either".
  local out ec
  out=$(run_check "$fx" 2>&1); ec=$?
  assert_contains "$out" "anchor unblessed" "a sig-less anchor should report itself unblessed"
  assert_contains "$out" "bin/feat.sh#greet" "a sig-less anchor must keep its symbol, not fall back to the whole file"
  run_check "$fx" --regen >/dev/null 2>&1 || fail "regen should succeed on a sig-less anchor"
  # The tripwire is the point: delete greet() while leaving --help identical, so
  # only the anchor can catch it. A whole-file anchor would merely WARN on drift.
  cat > "$fx/bin/feat.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  --help) echo "feat.sh - a fixture feature"; exit 0 ;;
  *) echo "hello from feat" ;;
esac
EOF
  out=$(run_check "$fx" 2>&1); ec=$?
  expect_code 1 "$ec" "a sig-less anchor's deletion tripwire must still fire"
  assert_contains "$out" "anchor symbol vanished" "deleting the symbol should be reported, not downgraded to drift"
  pass "an anchor authored without a sig line keeps its symbol and its deletion tripwire"
}

test_regen_writes_a_missing_sig_line() {
  local fx; fx=$(make_fixture_nosig)
  run_check "$fx" --regen >/dev/null 2>&1 || fail "regen should succeed on a sig-less anchor"
  assert_grep 'sig    = "' "$fx/provenance/register.toml" "regen should write a sig line the author never typed"
  local out ec
  out=$(run_check "$fx" 2>&1); ec=$?
  expect_code 0 "$ec" "a regenerated sig-less anchor should pass"
  assert_contains "$out" "PASS  fixture-feat" "regen should leave no lingering unblessed warning"
  pass "--regen supplies a sig line for an anchor that was authored without one"
}

test_regen_then_green_on_intact
test_deletion_tripwire
test_behavior_clobber
test_drift_is_warn_not_fail
test_anchor_without_sig_keeps_its_symbol
test_regen_writes_a_missing_sig_line

echo "# all provenance-check tests passed"
