#!/usr/bin/env bash
# fm-isolated-launch.sh - launch a fully isolated `claude` CLI session that
# does not inherit the real user's global PAI config.
#
# Why this exists, part 1 (HOME): Claude Code resolves its "global" config
# directory as $HOME/.claude/ - that is where the real ~/.claude/CLAUDE.md
# @-imports, ~/.claude/settings.json hooks, and ~/.claude/skills|agents live.
# Pointing HOME at a fresh, isolated directory for the child `claude` process
# strips all of that: firstmate runs as a clean persona with none of the
# user's separate global "PAI" customization layer (global CLAUDE.md, global
# hooks, global skills/agents, global auto-memory) bleeding in.
#
# Why this exists, part 2 (cwd - root-caused 2026-07-27): HOME alone is NOT
# enough. Claude Code's memory-file discovery also does an ancestor-directory
# walk from cwd up to filesystem root, checking each ancestor for a
# .claude/CLAUDE.md, entirely independent of $HOME. Firstmate's repo lives at
# /Users/trilliumsmith/code/firstmate - nested inside the real user's home
# directory, which itself has ~/.claude/CLAUDE.md - so that real global
# CLAUDE.md gets swept up as an ordinary ancestor "Project" memory file even
# with HOME fully isolated (confirmed via /context: it showed up labeled
# `Project`, not `User`, proving this is the ancestor walk and not a HOME
# leak). The earlier "isolation confirmed clean" read of this script's
# behavior was wrong for exactly this reason - a HOME override alone doesn't
# touch the ancestor walk at all. `--bare` suppresses the walk but also hard-
# disables OAuth/keychain auth, so it's not usable here.
#
# The fix is to also move cwd physically outside the real home tree: this
# script mirrors the repo's tracked files into a detached git worktree under
# /private/tmp (ancestor chain: /private, / - neither has a .claude/CLAUDE.md)
# and launches `claude` from there instead of from $FM_ROOT. The mirror is
# refreshed to the repo's current HEAD on every launch. Because that mirror
# has no data/, state/, config/, or projects/ (those are untracked, worktree-
# local), FM_ROOT_OVERRIDE is exported pointing back at the real $FM_ROOT so
# every bin/ script invoked from inside the isolated session still resolves
# firstmate's real operational state exactly as if run from $FM_ROOT itself.
# Verified via /context inside the resulting session: memory files list only
# the mirror's own CLAUDE.md (34.4k tokens) - no
# /Users/trilliumsmith/.claude/CLAUDE.md entry anywhere.
#
# This is real isolation, not a partial merge: none of the real ~/.claude or
# ~/.claude.json config, hooks, skills, or memory is copied in. The one
# deliberate exception is auth: Claude Code's OAuth flow tries to persist its
# token to the macOS Keychain, and a freshly isolated $HOME has no
# Library/Keychains structure, so that persist step fails with a "Keychain
# Not Found" dialog that blocks login entirely (root-caused 2026-07-27 against
# brain-ow1w0, the same $HOME-isolation approach used for danny-coach). The
# fix is Claude Code's own documented fallback: a file-based credential at
# .claude/.credentials.json. On first run, if that file is absent, this
# script copies the existing OAuth token straight out of the real, already-
# unlocked macOS Keychain (read-only against the real keychain; nothing is
# reset or modified there) so the isolated session reuses the same logged-in
# account without ever hitting the broken Keychain-write path. If extraction
# fails (non-macOS, no `security` binary, or no stored credential yet), this
# script falls back to the plain "you'll need to log in again" first-run
# message below. Subsequent launches against the same isolated home reuse
# whatever credential file is already there, same as any other HOME.
#
# Usage: fm-isolated-launch.sh [claude-args...]
#        fm-isolated-launch.sh -h|--help
#
# Environment overrides:
#   FM_ROOT_OVERRIDE     firstmate repo root (self-located otherwise)
#   FM_ISOLATED_HOME     isolated HOME dir (default: $FM_ROOT/.fm-isolated-home)
#   FM_ISOLATED_CWD       isolated cwd worktree mirror (default:
#                        /private/tmp/fm-isolated-worktree)
#
# All arguments are forwarded verbatim to the `claude` binary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ISOLATED_HOME="${FM_ISOLATED_HOME:-$FM_ROOT/.fm-isolated-home}"
ISOLATED_CWD="${FM_ISOLATED_CWD:-/private/tmp/fm-isolated-worktree}"

fm_isolated_launch_usage() {
  sed -n '2,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# Seed the OAuth credential from the real, already-unlocked macOS Keychain the
# first time this isolated home is used, so login doesn't hit the broken
# Keychain-write path under an isolated $HOME (see header comment). Read-only
# against the real keychain; never resets or modifies it. Skipped silently if
# a credential is already present, or if extraction isn't possible.
if [ ! -f "$ISOLATED_HOME/.claude/.credentials.json" ] && command -v security >/dev/null 2>&1; then
  if security find-generic-password -a "$USER" -s "Claude Code-credentials" -w \
       > "$ISOLATED_HOME/.claude/.credentials.json.tmp" 2>/dev/null; then
    chmod 600 "$ISOLATED_HOME/.claude/.credentials.json.tmp"
    mv "$ISOLATED_HOME/.claude/.credentials.json.tmp" "$ISOLATED_HOME/.claude/.credentials.json"
  else
    rm -f "$ISOLATED_HOME/.claude/.credentials.json.tmp"
  fi
fi

if [ ! -f "$ISOLATED_HOME/.claude.json" ] && [ ! -f "$ISOLATED_HOME/.claude/.credentials.json" ]; then
  echo "fm-isolated-launch: first run under this isolated home - no credential could be extracted from the real macOS Keychain, you will need to log in again." >&2
fi

# Mirror $FM_ROOT's tracked files into a detached worktree physically outside
# the real home directory tree, refreshed to current HEAD every launch, so
# Claude Code's ancestor-directory CLAUDE.md walk never reaches
# ~/.claude/CLAUDE.md (see header comment, part 2).
sync_isolated_worktree() {
  git -C "$FM_ROOT" worktree prune >/dev/null 2>&1
  if git -C "$FM_ROOT" worktree list --porcelain 2>/dev/null | grep -qx "worktree $ISOLATED_CWD"; then
    git -C "$ISOLATED_CWD" fetch --quiet "$FM_ROOT" HEAD >/dev/null 2>&1 &&
      git -C "$ISOLATED_CWD" checkout --quiet --detach FETCH_HEAD >/dev/null 2>&1
    return $?
  fi
  mkdir -p "$(dirname "$ISOLATED_CWD")" || return 1
  git -C "$FM_ROOT" worktree add --quiet --detach "$ISOLATED_CWD" HEAD >/dev/null 2>&1
}

if ! sync_isolated_worktree; then
  echo "fm-isolated-launch: failed to create/refresh the isolated cwd worktree at $ISOLATED_CWD" >&2
  echo "fm-isolated-launch: refusing to fall back to launching from $FM_ROOT - that path is nested under the real \$HOME and would re-leak /Users/trilliumsmith/.claude/CLAUDE.md via Claude Code's ancestor-directory walk." >&2
  exit 1
fi

cd "$ISOLATED_CWD" || exit 1
exec env HOME="$ISOLATED_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" claude "$@"
