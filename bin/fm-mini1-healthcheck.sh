#!/usr/bin/env bash
# fm-mini1-healthcheck.sh — dev-space readiness check for mini1
#
# WHAT IT IS
# ----------
# A point-in-time health check that confirms mini1 has everything needed to
# take over as the captain's primary dev space. It checks the four gaps found
# during the September 2026 mini1 inventory (gh auth, Claude credential,
# juggle/ccjuggler, disk), plus the services fm-remote-doctor.sh already
# covers (beads stores, herdr, key harnesses).
#
# HOW TO USE IT
# -------------
# Run locally on mini1:
#   ~/code/firstmate/bin/fm-mini1-healthcheck.sh
#
# Run from the MacBook over SSH:
#   ssh mini1 '~/code/firstmate/bin/fm-mini1-healthcheck.sh'
#
# HOW TO FIX GAPS (in priority order)
# ------------------------------------
# 1. gh auth MISSING
#    Run on mini1:  gh auth login
#    (blocks all PR pushes and crewmate GitHub operations from mini1)
#
# 2. Claude credential MISSING
#    Run on MacBook:  scp ~/.claude/.credentials.json mini1:~/.claude/.credentials.json
#    (Claude Code sessions won't authenticate without this file)
#
# 3. juggle MISSING
#    Run on MacBook:
#      ssh mini1 'mkdir -p ~/code/juggle ~/.local/bin'
#      scp ~/code/juggle/accounts.json mini1:~/code/juggle/accounts.json
#      scp ~/.local/bin/juggle mini1:~/.local/bin/juggle
#    (parlay token resolution for primary account fails without juggle)
#
# 4. Disk full
#    Run on mini1:  brew cleanup && brew autoremove
#    (mini1 was at 100% / 1.6G free in September 2026 inventory)
#
# 5. fm-remote-doctor gaps (beads unreachable, herdr down, etc.)
#    Run:  ~/code/firstmate/bin/fm-remote-doctor.sh
#    Each reported gap includes its own fix command.

set -euo pipefail

PASS="ok"
FAIL="MISSING"
WARN="warn"

pass() { printf "  %-30s %s\n" "$1" "$PASS"; }
fail() { printf "  %-30s %s\n" "$1" "$FAIL"; FAILED=1; }
warn() { printf "  %-30s %s  (%s)\n" "$1" "$WARN" "$2"; }

FAILED=0

echo ""
echo "=== mini1 dev-space health check ==="
echo ""

# --- 1. GitHub auth ---
echo "-- GitHub auth"
if gh auth status 2>&1 | grep -q "✓ Logged"; then
  pass "gh auth"
elif gh auth status 2>&1 | grep -q "X Failed"; then
  fail "gh auth (token invalid — run: gh auth login)"
else
  fail "gh auth (not configured — run: gh auth login)"
fi
echo ""

# --- 2. Claude Code credential ---
echo "-- Claude Code credential"
CRED="$HOME/.claude/.credentials.json"
if [[ -f "$CRED" ]]; then
  if python3 -c "import json,sys; d=json.load(open('$CRED')); assert d.get('claudeAiOauth')" 2>/dev/null; then
    pass ".credentials.json (claudeAiOauth present)"
  else
    warn ".credentials.json" "present but claudeAiOauth key missing"
  fi
else
  fail ".credentials.json (run from MacBook: scp ~/.claude/.credentials.json mini1:~/.claude/.credentials.json)"
fi
echo ""

# --- 3. juggle / ccjuggler ---
echo "-- juggle (ccjuggler account switcher)"
JUGGLE_ACCOUNTS="$HOME/code/juggle/accounts.json"
if [[ -f "$JUGGLE_ACCOUNTS" ]]; then
  ACCTS=$(python3 -c "import json,sys; [print('  account:', a['name']) for a in json.load(open('$JUGGLE_ACCOUNTS')).get('accounts',[])]" 2>/dev/null || echo "  (parse error)")
  pass "accounts.json"
  echo "$ACCTS"
else
  fail "accounts.json (copy from MacBook: scp ~/code/juggle/accounts.json mini1:~/code/juggle/accounts.json)"
fi
if [[ -f "$HOME/.local/bin/juggle" ]]; then
  pass "juggle binary"
else
  fail "juggle binary (copy from MacBook: scp ~/.local/bin/juggle mini1:~/.local/bin/juggle)"
fi
echo ""

# --- 4. Disk space ---
echo "-- Disk space"
FREE_BYTES=$(df -k "$HOME" | awk 'NR==2 {print $4}')
FREE_GB=$(echo "scale=1; $FREE_BYTES / 1048576" | bc 2>/dev/null || echo "?")
FREE_DISPLAY=$(df -h "$HOME" | awk 'NR==2 {print $4, "free (" $5, "used)"}')
if (( FREE_BYTES < 5242880 )); then  # < 5 GB
  fail "disk: $FREE_DISPLAY  (run: brew cleanup && brew autoremove)"
elif (( FREE_BYTES < 20971520 )); then  # < 20 GB
  warn "disk" "$FREE_DISPLAY — getting low"
else
  pass "disk ($FREE_DISPLAY)"
fi
echo ""

# --- 5. Key harnesses / CLI tools ---
echo "-- Harnesses and CLI tools"
for tool in claude opencode herdr parlay bun node go; do
  if command -v "$tool" &>/dev/null; then
    pass "$tool"
  else
    fail "$tool"
  fi
done
echo ""

# --- 6. Beads federated stores ---
echo "-- Federated stores (beads)"
for store in task brain friction ideas; do
  if $store list 2>/dev/null | head -1 &>/dev/null; then
    pass "$store store"
  else
    fail "$store store (is Dolt running? check: ps aux | grep dolt)"
  fi
done
echo ""

# --- 7. fm-remote-doctor (covers herdr, GUI session, launch agent, entrypoint) ---
echo "-- fm-remote-doctor"
DOCTOR="$HOME/code/firstmate/bin/fm-remote-doctor.sh"
if [[ -x "$DOCTOR" ]]; then
  "$DOCTOR" 2>&1 | grep -E "ok:|fixable:|gap:|MISSING|ERROR" | sed 's/^/  /' || true
else
  warn "fm-remote-doctor.sh" "not found at $DOCTOR"
fi
echo ""

# --- Summary ---
echo "=== Summary ==="
if [[ $FAILED -eq 0 ]]; then
  echo "  All checks passed. mini1 is ready for dev handoff."
else
  echo "  One or more checks FAILED. Fix the MISSING items above before handing off dev work."
fi
echo ""
