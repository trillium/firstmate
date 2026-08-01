#!/usr/bin/env bash
# File a triage bead into the `staleness` federated store for a task whose
# expensive live process was just reclaimed by bin/fm-watch.sh's idle>2h
# backstop because its worktree still holds unlanded work. Called only from
# bin/fm-teardown.sh's staleness_chat_only_teardown, after work_is_landed has
# already returned false for the task's branch.
# Fail-open by design, matching bin/fm-bead-stamp.sh: a missing `staleness` CLI
# or a create call it rejects warns on stderr and exits 0 so a triage-filing
# problem never blocks or fails the reclaim that is already under way.
# Usage: fm-staleness-file.sh <task-id> <purpose> <worktree> <branch> <project> <harness> <idle-since-epoch> <change-summary>
set -u

ID=${1-}
PURPOSE=${2-}
WORKTREE=${3-}
BRANCH=${4-}
PROJECT=${5-}
HARNESS=${6-unknown}
IDLE_SINCE=${7-}
SUMMARY=${8-}

if [ -z "$ID" ] || [ -z "$WORKTREE" ]; then
  echo "warning: fm-staleness-file.sh needs at least a task id and worktree, skipping" >&2
  exit 0
fi

if ! command -v staleness >/dev/null 2>&1; then
  echo "warning: staleness CLI not found on PATH, could not file $ID for triage" >&2
  exit 0
fi

idle_human=$IDLE_SINCE
case "$IDLE_SINCE" in
  '') idle_human=unknown ;;
  *[!0-9]*) ;;
  *) idle_human=$(date -r "$IDLE_SINCE" 2>/dev/null || date -d "@$IDLE_SINCE" 2>/dev/null || echo "$IDLE_SINCE") ;;
esac

body=$(printf 'task: %s\npurpose: %s\nworktree: %s\nbranch: %s\nproject: %s\nharness: %s\nidle since: %s\n\n%s\n' \
  "$ID" "${PURPOSE:-unknown}" "$WORKTREE" "${BRANCH:-unknown}" "${PROJECT:-unknown}" "$HARNESS" \
  "$idle_human" "${SUMMARY:-<no change summary>}")

bead_id=$(staleness create "Stale task $ID: ${BRANCH:-unknown branch}" \
  --description "$body" --labels staleness-autoclose --silent 2>&1) || {
  echo "warning: could not file staleness bead for $ID: $bead_id" >&2
  exit 0
}
echo "filed staleness bead $bead_id for $ID"
