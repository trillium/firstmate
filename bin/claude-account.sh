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

if [ ! -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
  echo "error: credentials not found at $CLAUDE_CONFIG_DIR/.credentials.json" >&2
  echo "seed them with:" >&2
  echo "  CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR claude /login" >&2
  exit 1
fi

mkdir -p "$ACCOUNT_HOME"
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

# .claude.json lives in the PARENT of CLAUDE_CONFIG_DIR - a Claude Code
# convention, not something this pattern invented. Pre-accept onboarding and
# the trust dialog for the working directory so a headless session doesn't
# hang on either prompt; CLAUDE_TRUST_DIR overrides which directory gets
# pre-trusted when it differs from the launcher's own cwd.
CLAUDE_JSON="$ACCOUNT_HOME/.claude.json"
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
