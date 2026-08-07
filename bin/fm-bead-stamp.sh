#!/usr/bin/env bash
# Stamp a linked bead as dispatched: sets its dispatch=sent state dimension and
# assigns it to the launched agent. Called by fm-spawn.sh after a successful
# spawn when the task was launched with --beads <id> or auto-linked under
# config/backlog-backend=beads.
# Fail-open by design: a missing `task` CLI, an empty beads id, or a bead the
# CLI cannot find warns on stderr and exits 0 so a bead-tracking problem never
# blocks or fails a spawn. A failed write against a reachable store, or every
# write when the store is unreachable, is queued via fm-beads-resilience-lib.sh
# for replay once the store recovers (beads-authority-migration Stage 5
# resilience layer, report.md section 5), rather than only warning and losing
# the update.
# Usage: fm-bead-stamp.sh <beads_id> <agent_name>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-beads-resilience-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-beads-resilience-lib.sh"

BEADS_ID=${1-}
AGENT=${2-}

if [ -z "$BEADS_ID" ]; then
  echo "warning: no bead id given, skipping stamp" >&2
  exit 0
fi

if ! command -v task >/dev/null 2>&1; then
  echo "warning: task CLI not found on PATH, skipping stamp for $BEADS_ID" >&2
  exit 0
fi

if [ -z "$AGENT" ]; then
  echo "warning: no agent name given, skipping stamp for $BEADS_ID" >&2
  exit 0
fi

if ! task list --limit 1 >/dev/null 2>&1; then
  echo "warning: beads store unreachable, queuing dispatch stamp for $BEADS_ID" >&2
  fm_beads_write_enqueue "$BEADS_ID" "dispatch=sent" set-state "$BEADS_ID" dispatch=sent --reason "dispatched: agent=$AGENT" || true
  fm_beads_write_enqueue "$BEADS_ID" "lifecycle=sent" set-state "$BEADS_ID" lifecycle=sent --reason "dispatched: agent=$AGENT" || true
  fm_beads_write_enqueue "$BEADS_ID" "assign $AGENT" assign "$BEADS_ID" "$AGENT" || true
  exit 0
fi

if ! task show "$BEADS_ID" >/dev/null 2>&1; then
  echo "warning: bead $BEADS_ID not found, skipping stamp" >&2
  exit 0
fi

if ! task set-state "$BEADS_ID" dispatch=sent --reason "dispatched: agent=$AGENT" >/dev/null 2>&1; then
  echo "warning: could not set dispatch=sent on bead $BEADS_ID, queuing for retry" >&2
  fm_beads_write_enqueue "$BEADS_ID" "dispatch=sent" set-state "$BEADS_ID" dispatch=sent --reason "dispatched: agent=$AGENT" || true
fi

if ! task set-state "$BEADS_ID" lifecycle=sent --reason "dispatched: agent=$AGENT" >/dev/null 2>&1; then
  echo "warning: could not set lifecycle=sent on bead $BEADS_ID, queuing for retry" >&2
  fm_beads_write_enqueue "$BEADS_ID" "lifecycle=sent" set-state "$BEADS_ID" lifecycle=sent --reason "dispatched: agent=$AGENT" || true
fi

if ! task assign "$BEADS_ID" "$AGENT" >/dev/null 2>&1; then
  echo "warning: could not assign bead $BEADS_ID to $AGENT, queuing for retry" >&2
  fm_beads_write_enqueue "$BEADS_ID" "assign $AGENT" assign "$BEADS_ID" "$AGENT" || true
fi

exit 0
