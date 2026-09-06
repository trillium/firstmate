#!/usr/bin/env bash
# fm-beads-remote-backup.sh - verify and repair the fleet task store's off-box
# Dolt copy on mini1.
#
# WHAT IT IS
# ----------
# The routine durability check for the one private Dolt remote the captain
# approved: the `mini1` SQL remote served by mini1's dolt sql-server
# remotesapi on port 3310 over Tailscale. `--verify` is read-only and answers
# whether the backup is currently reachable and correctly wired. `--repair`
# additionally converges the wiring (re-add a missing remote entry, commit the
# working set, push this machine's commits, confirm both ends share one head).
# Every outcome is one `BEADS_BACKUP:` line, mirroring the `BEADS_SYNC:` style
# the bootstrap sweep already reports, so a sweep can call this and relay the
# lines unchanged.
#
# WHAT IT IS NOT
# -------------
# This script never invents a destination: the remote name and URL below are
# the approved off-box copy, and a present entry pointing anywhere else is
# reported, never overwritten. It never runs `bd init`, never passes `--force`
# to any push, never removes a remote, and never drops a database, because any
# of those could discard history the local store is the single authority for.
# Rebuilding a corrupt remote copy from the authority (quarantine with a file
# backup, reseed, re-verify) stays a documented manual procedure exactly
# because it needs that judgment; see docs/beads-sync-topology.md.
# [`docs/beads-sync-topology.md`](../docs/beads-sync-topology.md) owns the why
# (single write authority, best-effort durability) and points here for the how.
#
# CALLERS
# -------
# `bin/fm-bootstrap.sh`'s beads sync sweep may call `--repair` for the routine
# pass. That sweep already bounds every step with fm_run_timed, so this script
# takes no step timeout of its own except the HTTP reachability probe
# (`FM_BEADS_BACKUP_PROBE_TIMEOUT`, default 10 seconds): every other step runs
# to completion and the caller owns the bound. Standalone runs inherit the
# same contract and should themselves run under `timeout` when a bound matters.
#
# EXIT STATUS
# -----------
# 0 means healthy (`--verify`) or repaired and verified (`--repair`). 1 means
# something still needs an operator, named by the last `BEADS_BACKUP:` line.
#
# ENVIRONMENT OVERRIDES (used by tests/fm-beads-remote-backup.test.sh)
# --------------------------------------------------------------------
# FM_BEADS_BACKUP_TASK_BIN  task CLI to drive (default: task).
# FM_BEADS_BACKUP_CURL_BIN  curl binary for the reachability probe (default: curl).
# FM_BEADS_BACKUP_REMOTE_NAME / FM_BEADS_BACKUP_REMOTE_URL: the approved copy.
# FM_BEADS_BACKUP_USER      Dolt user the mesh authenticates as (default: brainsync).
#                           The password is never a script input: it comes from
#                           the dolt server's own environment, as it does for
#                           every other mesh operation.
set -uo pipefail

TASK_BIN=${FM_BEADS_BACKUP_TASK_BIN:-task}
CURL_BIN=${FM_BEADS_BACKUP_CURL_BIN:-curl}
REMOTE_NAME=${FM_BEADS_BACKUP_REMOTE_NAME:-mini1}
REMOTE_URL=${FM_BEADS_BACKUP_REMOTE_URL:-http://100.102.238.78:3310/tasks}
MESH_USER=${FM_BEADS_BACKUP_USER:-brainsync}
PROBE_TIMEOUT=${FM_BEADS_BACKUP_PROBE_TIMEOUT:-10}

say() { printf 'BEADS_BACKUP: %s\n' "$1"; }

usage() {
  cat <<'EOF'
Usage: fm-beads-remote-backup.sh [--verify|--repair|--help]

Verify or repair the fleet task store's off-box Dolt copy on mini1.
--verify is read-only; --repair additionally re-adds a missing remote entry,
commits the working set, pushes, and confirms one shared head. Never runs
bd init, never force-pushes, never removes a remote, never drops a database.
EOF
}

MODE=verify
for arg in "$@"; do
  case "$arg" in
    --verify) MODE=verify ;;
    --repair) MODE=repair ;;
    --help | -h) usage; exit 0 ;;
    *) say "unknown argument: $arg"; usage >&2; exit 1 ;;
  esac
done

command -v "$TASK_BIN" >/dev/null 2>&1 || { say "missing: task CLI not found ($TASK_BIN)"; exit 1; }

if ! "$TASK_BIN" sql "select 1" >/dev/null 2>&1; then
  say "unreachable: the local task store does not answer a read; repair the store before its backup"
  exit 1
fi

REMOTE_LIST=$("$TASK_BIN" dolt remote list 2>&1) || {
  say "unreadable: 'task dolt remote list' failed, so a configured remote is indistinguishable from none"
  exit 1
}
HAVE_URL=$(printf '%s\n' "$REMOTE_LIST" | awk -v name="$REMOTE_NAME" '$1 == name { print $2; exit }')
if [ -z "$HAVE_URL" ]; then
  if [ "$MODE" = verify ]; then
    say "no-remote: no '$REMOTE_NAME' Dolt remote configured, so this store is single-machine only"
    exit 1
  fi
  if ! "$TASK_BIN" dolt remote add "$REMOTE_NAME" "$REMOTE_URL" >/dev/null 2>&1; then
    say "repair-failed: could not add the '$REMOTE_NAME' Dolt remote"
    exit 1
  fi
  say "repaired: re-added the '$REMOTE_NAME' Dolt remote ($REMOTE_URL)"
  HAVE_URL=$REMOTE_URL
elif [ "$HAVE_URL" != "$REMOTE_URL" ]; then
  say "remote-url-mismatch: '$REMOTE_NAME' points at $HAVE_URL, not the approved $REMOTE_URL; leaving it alone"
  exit 1
fi

HTTP_CODE=$("$CURL_BIN" -s -m "$PROBE_TIMEOUT" -o /dev/null -w "%{http_code}" "$REMOTE_URL" 2>/dev/null) || HTTP_CODE=000
if [ "$HTTP_CODE" = "000" ]; then
  say "unreachable-remote: '$REMOTE_NAME' ($REMOTE_URL) did not answer; sync stays best-effort until the transport recovers"
  exit 1
fi

if [ "$MODE" = verify ]; then
  LOCAL_HEAD=$("$TASK_BIN" sql "select hash from dolt_branches where name='main'" 2>&1 | grep -E '^[a-z0-9]{32}$' | head -1)
  say "ok: '$REMOTE_NAME' is configured at $REMOTE_URL and answers (local main ${LOCAL_HEAD:-unknown})"
  exit 0
fi

"$TASK_BIN" dolt commit >/dev/null 2>&1 || say "commit-failed: 'task dolt commit' exited non-zero; continuing to push previously committed work"

if ! PUSH_OUT=$("$TASK_BIN" sql "call dolt_push('$REMOTE_NAME','main','--user','$MESH_USER')" 2>&1); then
  say "push-failed: 'task dolt push' to '$REMOTE_NAME' failed: $(printf '%s' "$PUSH_OUT" | head -1)"
  exit 1
fi

if ! "$TASK_BIN" sql "call dolt_fetch('$REMOTE_NAME','main','--user','$MESH_USER')" >/dev/null 2>&1; then
  say "pushed-unverified: push to '$REMOTE_NAME' returned ok but the post-push fetch failed, so head equality is unconfirmed"
  exit 1
fi
LOCAL_HEAD=$("$TASK_BIN" sql "select hash from dolt_branches where name='main'" 2>&1 | grep -E '^[a-z0-9]{32}$' | head -1)
REMOTE_HEAD=$("$TASK_BIN" sql "select hash from dolt_branches where name='remotes/$REMOTE_NAME/main'" 2>&1 | grep -E '^[a-z0-9]{32}$' | head -1)
if [ -n "$LOCAL_HEAD" ] && [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
  say "repaired-verified: '$REMOTE_NAME' now shares local main ($LOCAL_HEAD)"
  exit 0
fi
say "diverged: '$REMOTE_NAME' main (${REMOTE_HEAD:-unknown}) differs from local main (${LOCAL_HEAD:-unknown}); needs an operator, never a force-push"
exit 1
