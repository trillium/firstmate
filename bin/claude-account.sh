#!/usr/bin/env bash
# claude-account.sh: launch claude with per-account credential isolation.
# Usage: claude-account.sh <N> [args...]
#
# Standalone - works with no firstmate checkout on $PATH. Each account gets its
# own CLAUDE_CONFIG_DIR under ~/.claude-homes/accountN/.claude; shared config
# (commands, hooks, skills, mcp-configs, settings.json, settings.local.json,
# rules, agents) is symlinked in from ~/.claude/, one source of truth.
# .credentials.json and .claude.json are never in that symlink list - they must
# stay per-account real files or OAuth tokens leak across accounts.
#
# Auth model: this launcher authenticates each account with a long-lived
# `claude setup-token` (a CLAUDE_CODE_OAUTH_TOKEN, sk-ant-oat01-...) resolved
# from the macOS keychain, exported into the session env, and honored by current
# Claude Code interactive sessions. Setup tokens are chosen over the interactive
# .credentials.json / `claude /login` blob on purpose: they are ~1yr-lived and
# never silently log out mid-fleet-run (an expired/cleared .credentials.json
# does), and they are the same tokens the ccjuggler/juggle switcher already
# stores, so all multi-account auth shares one source of truth.
#
# Token store: keychain service "ccjuggler-acc<N>", account "ccjuggler" (the
# exact lookup `juggle`/ccjuggler.py use). Seed or rotate a token with
# `claude setup-token` under the target account, then store it with
#   security add-generic-password -U -s "ccjuggler-acc<N>" -a "ccjuggler" -w "<token>"
# (or `juggle add`). The launcher validates the sk-ant-oat01- prefix and refuses
# a missing or malformed token rather than launching into a login prompt.
#
# Onboarding pre-seed location (current Claude Code): when CLAUDE_CONFIG_DIR is
# set, Claude Code reads its global config JSON from $CLAUDE_CONFIG_DIR/.claude.json
# (path = join(CLAUDE_CONFIG_DIR ?? homedir, ".claude.json")), NOT from a
# .claude.json in the PARENT of that dir. The onboarding gate it checks is a
# single key, hasCompletedOnboarding===true; the first-run welcome/theme/login
# flow (and everything under it) is skipped once that is set. We therefore write
# the pre-seed into $CLAUDE_CONFIG_DIR/.claude.json (see below).
#
# flock on a per-account lock file serializes the bootstrap section below so
# two concurrent first launches on the same account cannot race on the JSON
# writes and corrupt .claude.json; the lock fd is closed before exec claude so
# the agent process never inherits it.
#
# See docs/configuration.md "Multi-account Claude Code" and the reference
# pattern this implements:
# https://gist.github.com/sjarmak/61e22d3625ecaac2279e8564d1b1b68f
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: claude-account.sh <N> [args...]" >&2
  exit 1
fi
ACCOUNT=$1
shift
case "$ACCOUNT" in
  ''|*[!0-9]*|0) echo "error: <N> must be a positive integer account index" >&2; exit 1 ;;
esac

ACCOUNT_HOME="$HOME/.claude-homes/account${ACCOUNT}"
export CLAUDE_CONFIG_DIR="$ACCOUNT_HOME/.claude"

# Authenticate with the account's long-lived setup token from the keychain.
# Refuse rather than launch into a login prompt when the token is absent or
# malformed (a corrupt/non-oat value stored here is what silently broke acc2).
KEYCHAIN_SERVICE="ccjuggler-acc${ACCOUNT}"
OAUTH_TOKEN="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "ccjuggler" -w 2>/dev/null || true)"
case "$OAUTH_TOKEN" in
  sk-ant-oat01-*) ;;
  "")
    echo "error: no setup token in keychain service '$KEYCHAIN_SERVICE' (account 'ccjuggler')" >&2
    echo "seed it once: run 'claude setup-token' under the target account, then:" >&2
    echo "  security add-generic-password -U -s \"$KEYCHAIN_SERVICE\" -a \"ccjuggler\" -w \"<token>\"" >&2
    exit 1 ;;
  *)
    echo "error: keychain service '$KEYCHAIN_SERVICE' holds a value that is not a setup token" >&2
    echo "(expected an sk-ant-oat01-... token). Re-store the correct token with:" >&2
    echo "  security add-generic-password -U -s \"$KEYCHAIN_SERVICE\" -a \"ccjuggler\" -w \"<token>\"" >&2
    exit 1 ;;
esac
export CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN"

# Create the per-account config dir (not just the home) so a brand-new account -
# one never seeded by an interactive login - has $CLAUDE_CONFIG_DIR present for
# the symlink and .claude.json pre-seed steps below.
mkdir -p "$CLAUDE_CONFIG_DIR"
exec 9>"$ACCOUNT_HOME/.claude-account.lock"
flock 9

# Symlink shared config idempotently. Existing files or links at dest are left
# alone, so a captain-customized per-account override survives.
for item in commands hooks skills mcp-configs settings.json settings.local.json rules agents; do
  src="$HOME/.claude/$item"
  dest="$CLAUDE_CONFIG_DIR/$item"
  if [ -e "$src" ] && [ ! -e "$dest" ]; then
    ln -s "$src" "$dest"
  fi
done

# Pre-accept onboarding and the trust dialog so a session doesn't land in the
# first-run onboarding flow or hang on the trust prompt. When CLAUDE_CONFIG_DIR
# is set, current Claude Code reads its global config from
# $CLAUDE_CONFIG_DIR/.claude.json (NOT a .claude.json in the parent dir, which
# older layouts used and which CC now ignores) - so the pre-seed MUST live
# there or onboarding is not skipped. The onboarding gate is the single key
# hasCompletedOnboarding===true. CLAUDE_TRUST_DIR overrides which directory
# gets pre-trusted when it differs from the launcher's own cwd.
CLAUDE_JSON="$CLAUDE_CONFIG_DIR/.claude.json"
CLAUDE_TRUST_DIR="${CLAUDE_TRUST_DIR:-$PWD}" python3 - "$CLAUDE_JSON" <<'PYEOF'
import json
import os
import sys
import tempfile

path = sys.argv[1]
trust_dir = os.environ["CLAUDE_TRUST_DIR"]

if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
else:
    data = {}

changed = False
if not data.get("hasCompletedOnboarding"):
    data["hasCompletedOnboarding"] = True
    data.setdefault("numStartups", 1)
    changed = True

projects = data.setdefault("projects", {})
if not projects.get(trust_dir, {}).get("hasTrustDialogAccepted"):
    projects.setdefault(trust_dir, {})["hasTrustDialogAccepted"] = True
    changed = True

# Auto-approve project-scoped (.mcp.json) MCP servers so a fresh account home
# is not dropped into the per-server "New MCP server found" prompt on first
# encounter. .claude.json is per-account (never symlinked, to avoid OAuth/
# project-state leak), so an account never inherits the primary's MCP approvals
# - this global flag is the durable equivalent of choosing "use this and all
# future MCP servers in this project".
if not data.get("enableAllProjectMcpServers"):
    data["enableAllProjectMcpServers"] = True
    changed = True

if changed:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".claude-account.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
PYEOF

# If you plan to use --dangerously-skip-permissions, pre-accept its matching
# settings.json confirmation so the agent doesn't prompt at startup. Only a
# real per-account settings.json is patched in place - a symlinked shared
# settings.json is left alone so accounts never silently diverge from the
# single source of truth; set the flag once in ~/.claude/settings.json instead
# if every account should skip the prompt.
SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
if [ -f "$SETTINGS" ] && [ ! -L "$SETTINGS" ]; then
  python3 - "$SETTINGS" <<'PYEOF'
import json
import os
import sys
import tempfile

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

if not data.get("skipDangerousModePermissionPrompt"):
    data["skipDangerousModePermissionPrompt"] = True
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".claude-account.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
PYEOF
fi

# Release the bootstrap lock before handing control to claude.
exec 9>&-

exec claude "$@"
