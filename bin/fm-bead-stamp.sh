#!/usr/bin/env bash
# Stamp a linked bead as dispatched: sets its dispatch=sent state dimension and
# assigns it to the launched agent. Called by fm-spawn.sh after a successful
# spawn when the task was launched with --beads <id>.
# Fail-open by design: a missing `task` CLI, an empty beads id, or a bead the
# CLI cannot find warns on stderr and exits 0 so a bead-tracking problem never
# blocks or fails a spawn.
# Usage: fm-bead-stamp.sh <beads_id> <agent_name>
set -u

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

if ! task show "$BEADS_ID" >/dev/null 2>&1; then
  echo "warning: bead $BEADS_ID not found, skipping stamp" >&2
  exit 0
fi

if ! task set-state "$BEADS_ID" dispatch=sent --reason "dispatched: agent=$AGENT" >/dev/null 2>&1; then
  echo "warning: could not set dispatch=sent on bead $BEADS_ID" >&2
fi

if ! task assign "$BEADS_ID" "$AGENT" >/dev/null 2>&1; then
  echo "warning: could not assign bead $BEADS_ID to $AGENT" >&2
fi

exit 0
