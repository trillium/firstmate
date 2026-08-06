#!/usr/bin/env bash
# fork-features.sh: Regression guard suite for fork-specific capabilities
# Uses a baseline manifest to detect silent feature drops, not absolute pass/fail
# Restores (gap assertions now passing) are printed as progress, not failures

set -u

# Resolve repo root from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Self-check: guard against running in wrong directory
if ! [[ -f "$REPO_ROOT/AGENTS.md" ]] || ! [[ -f "$REPO_ROOT/bin/fm-spawn.sh" ]] || ! [[ -d "$REPO_ROOT/docs" ]]; then
  echo "ERROR: fork-features.sh resolved repo root to $REPO_ROOT, but it does not look like the firstmate repo"
  echo "(expected AGENTS.md, bin/fm-spawn.sh, docs/ all present)"
  exit 1
fi

# Load baseline
if ! [[ -f "$SCRIPT_DIR/fork-features.baseline" ]]; then
  echo "ERROR: fork-features.baseline not found at $SCRIPT_DIR/fork-features.baseline"
  exit 1
fi

cd "$REPO_ROOT"

PASS=0
FAIL=0
REGRESSION_FAILURES=()
RESTORES=()
ASSERTIONS_EXECUTED=0

test_pass() {
  PASS=$((PASS+1))
  ASSERTIONS_EXECUTED=$((ASSERTIONS_EXECUTED+1))
  [[ "${1:-}" == "-v" ]] && echo "  ✓ $2"
  return 0
}

test_fail() {
  FAIL=$((FAIL+1))
  ASSERTIONS_EXECUTED=$((ASSERTIONS_EXECUTED+1))
  echo "  ✗ $1"
  return 0
}

# Self-test: verify accounting before running main suite
echo "=== Fork Features Guard Suite (Regression Mode) ==="
echo "Running self-test of accounting..."
SELF_TEST_PASS=$PASS
SELF_TEST_FAIL=$FAIL

# Known-true: this script itself exists
[[ -f tests/fork-features.sh ]] && test_pass || test_fail "SELF-TEST: script exists"
if [[ $PASS -ne $((SELF_TEST_PASS+1)) ]]; then
  echo "ERROR: test_pass did not increment PASS correctly"
  exit 1
fi

# Known-false: definitely nonexistent file
[[ -f /this/file/does/not/exist/anywhere/ever.txt ]] && test_pass || test_fail "SELF-TEST: nonexistent file"
if [[ $FAIL -ne $((SELF_TEST_FAIL+1)) ]]; then
  echo "ERROR: test_fail did not increment FAIL correctly"
  exit 1
fi

if [[ $((PASS+FAIL)) -ne 2 ]]; then
  echo "ERROR: accounting does not sum to 2 (got $((PASS+FAIL)))"
  exit 1
fi

echo "Self-test passed: accounting is correct ✓"
echo ""
PASS=0
FAIL=0
ASSERTIONS_EXECUTED=0
FAILURES_LIST=()
echo ""

echo "Testing: Multi-account Claude Code"
  grep -q '\-\-account' bin/fm-spawn.sh && test_pass || test_fail "fm-spawn.sh --account flag"
  [[ -f bin/claude-account.sh ]] && test_pass || test_fail "bin/claude-account.sh exists"
  grep -q "Multi-account\|claude-account" docs/configuration.md 2>/dev/null && test_pass || test_fail "Multi-account documented"
  grep -q 'ACCOUNT.*=' bin/fm-spawn.sh && test_pass || test_fail "fm-spawn.sh parses ACCOUNT"
  [[ -x bin/claude-account.sh ]] 2>/dev/null && test_pass || test_fail "bin/claude-account.sh executable"

echo ""
echo "Testing: Remote Dispatch (SSH-based)"
  grep -q '\-\-remote' bin/fm-spawn.sh && test_pass || test_fail "fm-spawn.sh --remote flag"
  { [[ -f bin/fm-remote-ssh.sh ]] || grep -q 'fm-remote\|remote.*ssh' bin/fm-spawn.sh; } && test_pass || test_fail "Remote SSH transport"

echo ""
echo "Testing: Beads Integration"
  [[ -f bin/fm-brief-hooks.d/beads.sh ]] && test_pass || test_fail "bin/fm-brief-hooks.d/beads.sh"
  [[ -f bin/fm-beads-resilience-lib.sh ]] && test_pass || test_fail "bin/fm-beads-resilience-lib.sh"
  [[ -f bin/fm-bead-stamp.sh ]] && test_pass || test_fail "bin/fm-bead-stamp.sh"
  { [[ -d bin/fm-spawn-hooks ]] && [[ -f bin/fm-spawn-hooks/beads ]]; } && test_pass || test_fail "bin/fm-spawn-hooks/beads"
  { [[ -f bin/fm-classify-lib.sh ]] && grep -q 'open_decisions\|status_open' bin/fm-classify-lib.sh; } && test_pass || test_fail "Decision hold support"
  { [[ -f .tasks.toml ]] && grep -q 'beads\|backend' .tasks.toml; } && test_pass || test_fail ".tasks.toml beads backend"
  grep -q 'fm-brief-hooks.d' bin/fm-brief.sh && test_pass || test_fail "fm-brief.sh loads beads"

echo ""
echo "Testing: Fork-local Skills"
  [[ -d .agents/skills ]] && test_pass || test_fail ".agents/skills directory"
  [[ -f .agents/skills/firstmate-orca/SKILL.md ]] && test_pass || test_fail "firstmate-orca skill"
  [[ -f .agents/skills/herdr-navigation/SKILL.md ]] && test_pass || test_fail "herdr-navigation skill"
  { [[ -L .claude/skills ]] && [[ -d .claude/skills ]]; } && test_pass || test_fail ".claude/skills symlink"
  grep -r 'agents/skills\|\.agents/skills' bin/ >/dev/null 2>&1 && test_pass || test_fail "Skill loader integration"

echo ""
echo "Testing: Fork-origin Validation"
  grep -q 'fork-origin\|upstream\|trillium' bin/fm-spawn.sh && test_pass || test_fail "Fork-origin check"

echo ""
echo "Testing: Decision Hold Lifecycle"
  [[ -f .agents/skills/decision-hold-lifecycle/SKILL.md ]] && test_pass || test_fail "decision-hold-lifecycle skill"
  { [[ -f bin/fm-session-start.sh ]] && grep -q 'OPEN DECISIONS\|open_decisions' bin/fm-session-start.sh; } && test_pass || test_fail "OPEN DECISIONS display"

echo ""
echo "Testing: Beads Task-Store Backend"
  [[ -f bin/fm-backlog-handoff.sh ]] && test_pass || test_fail "bin/fm-backlog-handoff.sh"
  [[ -f bin/fm-backlog-receive.sh ]] && test_pass || test_fail "bin/fm-backlog-receive.sh"
  grep -q 'backend.*beads\|beads.*backend' .tasks.toml 2>/dev/null && test_pass || test_fail "Beads backend configured"

echo ""
echo "Testing: X-mode Integration"
  [[ -f .agents/skills/fmx-respond/SKILL.md ]] && test_pass || test_fail "fmx-respond skill"
  [[ -f bin/fm-x-lib.sh ]] && test_pass || test_fail "bin/fm-x-lib.sh"
  grep -q 'FMX_PAIRING_TOKEN\|x-mode\|X mode' docs/configuration.md 2>/dev/null && test_pass || test_fail "X-mode documented"

echo ""
echo "Testing: Herdr Backend Support"
  [[ -f bin/backends/herdr.sh ]] && test_pass || test_fail "bin/backends/herdr.sh"
  { grep -q '\-\-backend' bin/fm-spawn.sh && grep -q 'herdr' bin/fm-spawn.sh; } && test_pass || test_fail "Herdr backend support"
  [[ -f .agents/skills/herdr-navigation/SKILL.md ]] && test_pass || test_fail "herdr-navigation skill (Herdr backend integration)"
  [[ -f docs/herdr-backend.md ]] && test_pass || test_fail "docs/herdr-backend.md"

echo ""
echo "=== Regression Analysis ==="

# Build a map of assertion results: assertion_name -> pass/fail
declare -A assertion_results
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"  # Strip leading whitespace
  if [[ "$line" =~ ^✓\ (.+)$ ]]; then
    assertion_results["${BASH_REMATCH[1]}"]="pass"
  elif [[ "$line" =~ ^✗\ (.+)$ ]]; then
    assertion_results["${BASH_REMATCH[1]}"]="fail"
  fi
done < <(
  cd "$REPO_ROOT"
  {
    echo "Testing: Multi-account Claude Code"
      grep -q '\-\-account' bin/fm-spawn.sh && echo "  ✓ fm-spawn.sh --account flag" || echo "  ✗ fm-spawn.sh --account flag"
      [[ -f bin/claude-account.sh ]] && echo "  ✓ bin/claude-account.sh exists" || echo "  ✗ bin/claude-account.sh exists"
      grep -q "Multi-account\|claude-account" docs/configuration.md 2>/dev/null && echo "  ✓ Multi-account documented" || echo "  ✗ Multi-account documented"
      grep -q 'ACCOUNT.*=' bin/fm-spawn.sh && echo "  ✓ fm-spawn.sh parses ACCOUNT" || echo "  ✗ fm-spawn.sh parses ACCOUNT"
      [[ -x bin/claude-account.sh ]] 2>/dev/null && echo "  ✓ bin/claude-account.sh executable" || echo "  ✗ bin/claude-account.sh executable"

    echo "Testing: Remote Dispatch (SSH-based)"
      grep -q '\-\-remote' bin/fm-spawn.sh && echo "  ✓ fm-spawn.sh --remote flag" || echo "  ✗ fm-spawn.sh --remote flag"
      { [[ -f bin/fm-remote-ssh.sh ]] || grep -q 'fm-remote\|remote.*ssh' bin/fm-spawn.sh; } && echo "  ✓ Remote SSH transport" || echo "  ✗ Remote SSH transport"

    echo "Testing: Beads Integration"
      [[ -f bin/fm-brief-hooks.d/beads.sh ]] && echo "  ✓ bin/fm-brief-hooks.d/beads.sh" || echo "  ✗ bin/fm-brief-hooks.d/beads.sh"
      [[ -f bin/fm-beads-resilience-lib.sh ]] && echo "  ✓ bin/fm-beads-resilience-lib.sh" || echo "  ✗ bin/fm-beads-resilience-lib.sh"
      [[ -f bin/fm-bead-stamp.sh ]] && echo "  ✓ bin/fm-bead-stamp.sh" || echo "  ✗ bin/fm-bead-stamp.sh"
      { [[ -d bin/fm-spawn-hooks ]] && [[ -f bin/fm-spawn-hooks/beads ]]; } && echo "  ✓ bin/fm-spawn-hooks/beads" || echo "  ✗ bin/fm-spawn-hooks/beads"
      { [[ -f bin/fm-classify-lib.sh ]] && grep -q 'open_decisions\|status_open' bin/fm-classify-lib.sh; } && echo "  ✓ Decision hold support" || echo "  ✗ Decision hold support"
      { [[ -f .tasks.toml ]] && grep -q 'beads\|backend' .tasks.toml; } && echo "  ✓ .tasks.toml beads backend" || echo "  ✗ .tasks.toml beads backend"
      grep -q 'fm-brief-hooks.d' bin/fm-brief.sh && echo "  ✓ fm-brief.sh loads beads" || echo "  ✗ fm-brief.sh loads beads"

    echo "Testing: Fork-local Skills"
      [[ -d .agents/skills ]] && echo "  ✓ .agents/skills directory" || echo "  ✗ .agents/skills directory"
      [[ -f .agents/skills/firstmate-orca/SKILL.md ]] && echo "  ✓ firstmate-orca skill" || echo "  ✗ firstmate-orca skill"
      [[ -f .agents/skills/herdr-navigation/SKILL.md ]] && echo "  ✓ herdr-navigation skill" || echo "  ✗ herdr-navigation skill"
      { [[ -L .claude/skills ]] && [[ -d .claude/skills ]]; } && echo "  ✓ .claude/skills symlink" || echo "  ✗ .claude/skills symlink"
      grep -r 'agents/skills\|\.agents/skills' bin/ >/dev/null 2>&1 && echo "  ✓ Skill loader integration" || echo "  ✗ Skill loader integration"

    echo "Testing: Fork-origin Validation"
      grep -q 'fork-origin\|upstream\|trillium' bin/fm-spawn.sh && echo "  ✓ Fork-origin check" || echo "  ✗ Fork-origin check"

    echo "Testing: Decision Hold Lifecycle"
      [[ -f .agents/skills/decision-hold-lifecycle/SKILL.md ]] && echo "  ✓ decision-hold-lifecycle skill" || echo "  ✗ decision-hold-lifecycle skill"
      { [[ -f bin/fm-session-start.sh ]] && grep -q 'OPEN DECISIONS\|open_decisions' bin/fm-session-start.sh; } && echo "  ✓ OPEN DECISIONS display" || echo "  ✗ OPEN DECISIONS display"

    echo "Testing: Beads Task-Store Backend"
      [[ -f bin/fm-backlog-handoff.sh ]] && echo "  ✓ bin/fm-backlog-handoff.sh" || echo "  ✗ bin/fm-backlog-handoff.sh"
      [[ -f bin/fm-backlog-receive.sh ]] && echo "  ✓ bin/fm-backlog-receive.sh" || echo "  ✗ bin/fm-backlog-receive.sh"
      grep -q 'backend.*beads\|beads.*backend' .tasks.toml 2>/dev/null && echo "  ✓ Beads backend configured" || echo "  ✗ Beads backend configured"

    echo "Testing: X-mode Integration"
      [[ -f .agents/skills/fmx-respond/SKILL.md ]] && echo "  ✓ fmx-respond skill" || echo "  ✗ fmx-respond skill"
      [[ -f bin/fm-x-lib.sh ]] && echo "  ✓ bin/fm-x-lib.sh" || echo "  ✗ bin/fm-x-lib.sh"
      grep -q 'FMX_PAIRING_TOKEN\|x-mode\|X mode' docs/configuration.md 2>/dev/null && echo "  ✓ X-mode documented" || echo "  ✗ X-mode documented"

    echo "Testing: Herdr Backend Support"
      [[ -f bin/backends/herdr.sh ]] && echo "  ✓ bin/backends/herdr.sh" || echo "  ✗ bin/backends/herdr.sh"
      { grep -q '\-\-backend' bin/fm-spawn.sh && grep -q 'herdr' bin/fm-spawn.sh; } && echo "  ✓ Herdr backend support" || echo "  ✗ Herdr backend support"
      [[ -f .agents/skills/herdr-navigation/SKILL.md ]] && echo "  ✓ herdr-navigation skill (Herdr backend integration)" || echo "  ✗ herdr-navigation skill (Herdr backend integration)"
      [[ -f docs/herdr-backend.md ]] && echo "  ✓ docs/herdr-backend.md" || echo "  ✗ docs/herdr-backend.md"
  }
)

# Check assertion count in baseline
baseline_count=$(grep -c "^pass\|^gap" tests/fork-features.baseline 2>/dev/null || echo "0")

if [[ $ASSERTIONS_EXECUTED -ne $baseline_count ]]; then
  echo "ERROR: Assertion count mismatch"
  echo "  Executed: $ASSERTIONS_EXECUTED"
  echo "  Baseline: $baseline_count"
  echo "This is a critical accounting error that prevents regression detection."
  exit 1
fi

# Regression detection: compare each baseline entry against actual results
CRITICAL_REGRESSION=0

while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"  # Strip leading whitespace
  [[ "$line" =~ ^#.*$ ]] && continue
  [[ -z "$line" ]] && continue

  expected_status=$(echo "$line" | awk '{print $1}')
  assertion_name=$(echo "$line" | cut -d' ' -f2-)

  actual_status="${assertion_results[$assertion_name]:-}"

  if [[ "$expected_status" == "pass" && "$actual_status" == "fail" ]]; then
    # CRITICAL: expected-pass assertion failed = silent feature drop
    echo "REGRESSION: expected-pass assertion failed: $assertion_name"
    CRITICAL_REGRESSION=1
  elif [[ "$expected_status" == "gap" && "$actual_status" == "pass" ]]; then
    # OK: expected-gap assertion now passes = restoration
    RESTORES+=("$assertion_name")
  fi
done < tests/fork-features.baseline

if [[ $CRITICAL_REGRESSION -eq 1 ]]; then
  echo ""
  echo "CRITICAL: Regression detected. A feature that was expected to work is now failing."
  echo "This indicates a silent feature drop during upstream reconcile or rebase."
  exit 1
fi

# Check for gaps deleted from baseline without being fixed
baseline_gaps=$(grep "^gap " tests/fork-features.baseline | cut -d' ' -f2- | sort)
actual_gaps=$(for name in "${!assertion_results[@]}"; do
  [[ "${assertion_results[$name]}" == "fail" ]] && echo "$name"
done | sort)

while IFS= read -r gap_name; do
  [[ -z "$gap_name" ]] && continue
  if ! grep -q "^gap $gap_name$" tests/fork-features.baseline; then
    echo "CRITICAL: Expected gap was deleted from baseline without being fixed: $gap_name"
    echo "This is evidence removal and indicates someone tried to hide a missing feature."
    CRITICAL_REGRESSION=1
  fi
done < <(echo "$actual_gaps")

if [[ $CRITICAL_REGRESSION -eq 1 ]]; then
  exit 1
fi

echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed (expected gaps): $FAIL"

if [[ ${#RESTORES[@]} -gt 0 ]]; then
  echo ""
  echo "Restorations (gaps now passing):"
  for restore in "${RESTORES[@]}"; do
    echo "  ✓ RESTORED: $restore"
  done
  echo ""
  echo "To promote restored gaps to expected-pass, edit tests/fork-features.baseline"
fi

echo ""
echo "No regressions detected. CI is green. ✓"
exit 0
