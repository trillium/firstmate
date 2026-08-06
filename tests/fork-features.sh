#!/usr/bin/env bash
# fork-features.sh: Guard suite for fork-specific capabilities
# Prevents silent feature drops during upstream reconciles

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

cd "$REPO_ROOT"

PASS=0
FAIL=0
FAILURES_LIST=()

test_pass() {
  PASS=$((PASS+1))
  [[ "${1:-}" == "-v" ]] && echo "  ✓ $2"
  return 0
}

test_fail() {
  FAIL=$((FAIL+1))
  FAILURES_LIST+=("$1")
  echo "  ✗ $1"
  return 0
}

# Self-test: verify accounting before running main suite
echo "=== Fork Features Guard Suite ==="
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
  grep -q "remote\|ssh" docs/configuration.md 2>/dev/null && test_pass || test_fail "Remote dispatch documented"
  grep -q 'remote_host\|FM_HERDR_REMOTE_HOST' bin/fm-spawn.sh && test_pass || test_fail "Remote metadata recorded"

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
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failed tests:"
  for item in "${FAILURES_LIST[@]}"; do
    echo "  - $item"
  done
  echo ""
  echo "To restore missing features, see docs/fork-features.md"
  exit 1
else
  echo ""
  echo "All fork features present and working! ✓"
  exit 0
fi
