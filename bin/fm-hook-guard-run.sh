#!/usr/bin/env bash
# Entry point the tracked .claude/settings.json guard hooks run through, so a
# guard script that cannot be loaded never wedges the session.
#
# A merge or rebase inside a worktree can leave conflict markers in a guard
# script under bin/. Claude runs the hook from that worktree, bash exits 2 on the
# syntax error, and a PreToolUse exit 2 blocks every tool call (a Stop guard
# loops to its block cap), so the worker cannot even repair the file.
#
# Usage: bin/fm-hook-guard-run.sh <guard-script-basename> [guard args...]
#
# The named script is resolved next to this file. When it is missing or fails
# `bash -n`, print a one-line warning to stderr and exit 0 (pass-through).
# Otherwise exec it with stdin, arguments, and exit status untouched, so a guard
# that runs and denies still denies.
set -u

name=${1-}
[ -n "$name" ] || { printf 'fm-hook-guard-run: no guard script named; passing through\n' >&2; exit 0; }
shift
script=$(dirname "${BASH_SOURCE[0]}")/$name

if [ ! -f "$script" ]; then
  printf 'fm-hook-guard-run: %s is missing; guard skipped\n' "$name" >&2
  exit 0
fi
if ! bash -n "$script" 2>/dev/null; then
  printf 'fm-hook-guard-run: %s does not parse (conflict markers or syntax error?); guard skipped\n' "$name" >&2
  exit 0
fi
exec "$script" "$@"
