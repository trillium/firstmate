#!/usr/bin/env bash
# fm-isolated-launch.sh - launch a fully HOME-isolated `claude` CLI session.
#
# Why this exists: Claude Code resolves its "global" config directory as
# $HOME/.claude/ - that is where the real ~/.claude/CLAUDE.md @-imports,
# ~/.claude/settings.json hooks, and ~/.claude/skills|agents live. This
# repo's own project-level CLAUDE.md/AGENTS.md and .agents/skills/ are read
# relative to the current working directory, not HOME, so they are
# unaffected by the redirect. Pointing HOME at a fresh, empty directory for
# the child `claude` process gives real isolation: firstmate runs as a clean
# persona with none of the user's separate global "PAI" customization layer
# (global CLAUDE.md, global hooks, global skills/agents, global auto-memory)
# bleeding in, while this repo's own project CLAUDE.md/AGENTS.md and
# .agents/skills/ still load exactly as normal.
#
# This is real isolation, not a partial merge: no file is copied in from the
# real ~/.claude or ~/.claude.json. In particular, Claude Code auth/session
# state normally lives under the real HOME (~/.claude.json and friends), so
# the FIRST launch under a fresh isolated home will require logging in again
# - there is no credential or session file to inherit, and this script does
# not attempt to guess at or copy any undocumented internal auth format.
# Subsequent launches against the same isolated home reuse whatever auth
# state that login produced, same as any other HOME.
#
# Usage: fm-isolated-launch.sh [claude-args...]
#        fm-isolated-launch.sh -h|--help
#
# Environment overrides:
#   FM_ROOT_OVERRIDE     firstmate repo root (self-located otherwise)
#   FM_ISOLATED_HOME     isolated HOME dir (default: $FM_ROOT/.fm-isolated-home)
#
# All arguments are forwarded verbatim to the `claude` binary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ISOLATED_HOME="${FM_ISOLATED_HOME:-$FM_ROOT/.fm-isolated-home}"

fm_isolated_launch_usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help)
    fm_isolated_launch_usage
    exit 0
    ;;
esac

if ! mkdir -p "$ISOLATED_HOME/.claude"; then
  echo "fm-isolated-launch: failed to create isolated home at $ISOLATED_HOME" >&2
  exit 1
fi

if [ ! -f "$ISOLATED_HOME/.claude.json" ]; then
  echo "fm-isolated-launch: first run under this isolated home - no auth carried over from the real ~/.claude.json, you will need to log in again." >&2
fi

cd "$FM_ROOT" || exit 1
exec env HOME="$ISOLATED_HOME" claude "$@"
