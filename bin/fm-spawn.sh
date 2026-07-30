#!/usr/bin/env bash
# Thin policy shim over parlay-spawn: apply firstmate crew-dispatch and policy,
# then delegate spawn mechanics to parlay-spawn.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>] [--model <name>] [--effort <level>] [--scout] [--beads <id>]
#        fm-spawn.sh <task-id> [<firstmate-home>] --secondmate
#
# This script applies firstmate policy (crew-dispatch harness selection,
# escalation judgment, delivery mode) and then delegates agent spawning to
# parlay-spawn. It registers the task in firstmate's fleet for supervision.
# On success, writes state/<id>.meta and prints: spawned <id> ...

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# Load policy-layer libs
# shellcheck source=bin/fm-dispatch-select.sh
. "$SCRIPT_DIR/fm-dispatch-select.sh" 2>/dev/null || true

usage() {
  cat >&2 <<'EOF'
Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>] [--model <name>] [--effort <level>] [--scout] [--beads <id>]
       fm-spawn.sh <task-id> [<firstmate-home>] --secondmate

Spawns a crewmate (disposable task agent) via parlay-spawn, applying firstmate's
policy for crew-dispatch (harness/model selection) and escalation judgment.

For crewmate/scout spawns:
  --harness <name>  Explicit harness (claude, codex, pi, grok, etc.). Without it,
                    crew-dispatch resolves the harness per config/crew-dispatch.json.
  --model <name>    Claude model (e.g., sonnet, opus). Passed through to parlay.
  --effort <level>  Reasoning effort (low, medium, high, xhigh, max). Recorded in meta.
  --scout           Kind=scout (report deliverable, scratch worktree).
  --beads <id>      Link the spawn to a beads issue (recorded as beads_id= in meta).

For secondmate (persistent domain home):
  --secondmate      Launch a persistent secondmate home instead of a crewmate.
EOF
  exit 1
}

parse_args() {
  local i=0
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage ;;
    esac
    ((i++))
  done

  # Positional: task-id [project-dir or home] [--scout|--secondmate]
  # Flags: --harness, --model, --effort, --beads
  ID="${1:-}"
  [ -n "$ID" ] || { echo "error: task-id required" >&2; usage; }

  HARNESS_ARG=
  MODEL=
  EFFORT=
  BEADS_ID=
  KIND=ship
  SECONDMATE_HOME=

  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --scout) KIND=scout; shift ;;
      --secondmate) KIND=secondmate; shift ;;
      --harness) [ $# -gt 1 ] || usage; HARNESS_ARG="$2"; shift 2 ;;
      --model) [ $# -gt 1 ] || usage; MODEL="$2"; shift 2 ;;
      --effort) [ $# -gt 1 ] || usage; EFFORT="$2"; shift 2 ;;
      --beads) [ $# -gt 1 ] || usage; BEADS_ID="$2"; shift 2 ;;
      --*) echo "error: unknown flag $1" >&2; usage ;;
      *)
        if [ "$KIND" = secondmate ] && [ -z "$SECONDMATE_HOME" ]; then
          SECONDMATE_HOME="$1"
        elif [ "$KIND" != secondmate ] && [ -z "$PROJ" ]; then
          PROJ="$1"
        else
          echo "error: unexpected positional $1" >&2; usage
        fi
        shift
        ;;
    esac
  done

  # Validation
  case "$EFFORT" in
    ''|low|medium|high|xhigh|max) ;;
    *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
  esac
  [ -z "$BEADS_ID" ] || [ "$KIND" != secondmate ] || {
    echo "error: --beads applies only to crewmate spawn" >&2; exit 1
  }
}

# Apply crew-dispatch to resolve harness/model if not explicitly set
apply_crew_dispatch() {
  # Crew-dispatch is firstmate policy: if config/crew-dispatch.json exists,
  # consult it for harness/model/effort selection. This stays in the shim.
  # For now, minimal impl: if no harness given and crew-dispatch exists, warn.
  # Full impl would run fm-dispatch-select.sh logic.

  if [ -z "$HARNESS_ARG" ] && [ -f "$FM_HOME/config/crew-dispatch.json" ]; then
    # TODO: resolve via crew-dispatch
    # For this first pass, default to claude.
    HARNESS_ARG=claude
  fi
  HARNESS_ARG=${HARNESS_ARG:-claude}
}

# Register task with firstmate fleet for supervision
register_with_firstmate() {
  mkdir -p "$STATE" "$DATA"

  # Write state/<id>.meta for fleet tracking
  {
    echo "window="
    echo "worktree="
    echo "project=$PROJ"
    echo "harness=$HARNESS_ARG"
    echo "model=${MODEL:-default}"
    echo "effort=${EFFORT:-default}"
    echo "kind=$KIND"
    echo "mode=report"
    echo "yolo=on"
    [ -z "$BEADS_ID" ] || echo "beads_id=$BEADS_ID"
  } > "$STATE/$ID.meta"

  # Set PARLAY_STATUS_FILE env var so agent's parlay status appends to
  # firstmate's state/<id>.status for supervision.
  export PARLAY_STATUS_FILE="$STATE/$ID.status"
}

# Delegate spawn to parlay-spawn
spawn_via_parlay() {
  local parlay_spawn="$FM_ROOT/../parlay/bin/parlay-spawn"
  [ -x "$parlay_spawn" ] || {
    echo "error: parlay-spawn not found at $parlay_spawn" >&2
    exit 1
  }

  local prompt="Spawn a $KIND crewmate for task $ID in $PROJ"
  [ "$KIND" = secondmate ] && prompt="Spawn a secondmate home at $SECONDMATE_HOME"

  # Call parlay-spawn with appropriate args
  # Format: parlay-spawn <id> <name> <color> <prompt> [--cwd PATH] [--model MODEL]
  local color="#2563EB"  # Default blue; could be per-project
  "$parlay_spawn" "$ID" "fm-$ID" "$color" "$prompt" \
    --cwd "${PROJ:-.}" \
    ${MODEL:+--model "$MODEL"} || return 1

  echo "spawned $ID harness=$HARNESS_ARG kind=$KIND"
}

# ---- MAIN ----
parse_args "$@"
apply_crew_dispatch
register_with_firstmate
spawn_via_parlay
