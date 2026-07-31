#!/usr/bin/env bash
# fm-no-mistakes-liveness.sh - check liveness of no-mistakes runs and match them to tasks.
#
# Purpose: answer two related questions about shared no-mistakes daemon runs:
#   1. Which entries in `no-mistakes runs` showing `running` are genuinely live and
#      in-progress, and which task/home (if any) owns each one?
#   2. During ordinary supervision of an in-flight no-mistakes run, detect when the
#      run itself has silently hung (not just waiting on CI).
#
# This is a check/tool that reports liveness status, not an auto-remediator.
# It does not restart the daemon, kill a run, or interrupt a crewmate.
#
# Usage:
#   fm-no-mistakes-liveness.sh [<id>]        Check a specific task's run liveness
#   fm-no-mistakes-liveness.sh --all          List liveness of all "running" runs
#   fm-no-mistakes-liveness.sh --help         Show this help
#
# Exit codes:
#   0 - success (run is live, or all runs checked)
#   1 - run is not live/hung
#   2 - usage error or precondition failed
#
# Output format (one line per run when checking multiple):
#   run: <run-id> · branch: <branch> · status: <running|hung|done|failed> · owned-by: <task-id|unknown> · last-activity: <seconds-ago>s
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# Timeouts for CLI calls
NM_TIMEOUT=${FM_NM_LIVENESS_TIMEOUT:-15}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=15 ;; esac

# Freshness threshold: a run is considered hung if its last activity is older than this
STALE_THRESHOLD=${FM_NM_LIVENESS_STALE:-300}
case "$STALE_THRESHOLD" in ''|*[!0-9]*) STALE_THRESHOLD=300 ;; esac

# --- utilities ---------------------------------------------------------------

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

strip_quotes() {
  local s
  s=$(trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  trim "$s"
}

die() {
  printf 'error: %s\n' "$@" >&2
  exit 2
}

usage() {
  sed -n '2,11p' "$0" | sed 's/^# //'
  exit 2
}

# Bounded no-mistakes call; stdout only, never fails the script.
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
nm_run() {  # <args...>
  case "$HAVE_TIMEOUT" in
    timeout)  timeout "$NM_TIMEOUT" no-mistakes "$@" 2>/dev/null || true ;;
    gtimeout) gtimeout "$NM_TIMEOUT" no-mistakes "$@" 2>/dev/null || true ;;
    perl)     perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$NM_TIMEOUT" no-mistakes "$@" 2>/dev/null || true ;;
    *)        true ;;
  esac
}

# Extract TOON field value
nm_field() {  # <output> <key>
  local output=$1 key=$2
  printf '%s\n' "$output" | sed -n "s/^[[:space:]]*$key:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Check if a run is owned by a task by matching branch names
# Also checks secondmate homes and project homes
find_task_for_branch() {  # <branch>
  local branch=$1 task_meta task_id
  local homes_to_check=("$STATE")

  # Also check the current directory's git root state (for project tasks)
  local git_root
  if git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    [ -d "$git_root/state" ] && [ "$git_root/state" != "$STATE" ] && homes_to_check+=("$git_root/state")
  fi

  # Also check secondmate homes if secondmates.md exists
  if [ -f "$FM_HOME/data/secondmates.md" ] 2>/dev/null; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in '#'*|'- '*) continue ;; esac
      # Parse secondmate entry: "- [id](path) — description"
      # Simple extraction: look for [...] and (...) patterns
      if [[ "$line" =~ \[([^\]]+)\]\(([^\)]+)\) ]]; then
        local sm_path="${BASH_REMATCH[2]}"
        [ -d "$sm_path/state" ] && homes_to_check+=("$sm_path/state")
      fi
    done < "$FM_HOME/data/secondmates.md"
  fi

  # Check all meta files in all homes
  for home_state in "${homes_to_check[@]}"; do
    [ -d "$home_state" ] || continue
    for task_meta in "$home_state"/*.meta; do
      [ -f "$task_meta" ] || continue
      local worktree
      worktree=$(grep "^worktree=" "$task_meta" | tail -1 | cut -d= -f2-)
      [ -n "$worktree" ] || continue
      [ -d "$worktree" ] || continue

      local task_branch
      task_branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
      if [ "$task_branch" = "$branch" ]; then
        # Found a match - return the task id (basename of meta file without .meta)
        # Qualify with home label if from a secondmate
        task_id=$(basename "$task_meta" .meta)
        if [ "$home_state" != "$STATE" ]; then
          task_id="$(basename "$(dirname "$home_state")")/$task_id"
        fi
        printf '%s' "$task_id"
        return 0
      fi
    done
  done

  printf 'unknown'
}

# --- run liveness check ------------------------------------------------------

# Extract step information: name,status,findings,duration_ms from the steps table
# Returns: name|status|duration (e.g., "review|fix_review|430107")
get_step_info() {  # <run_output> <step_name>
  local output=$1 step_name=$2 line
  line=$(printf '%s\n' "$output" | grep -E "^[[:space:]]*$step_name," | head -1 | sed 's/^ *//')
  if [ -n "$line" ]; then
    local step status rest duration
    step="${line%%,*}"
    rest="${line#*,}"
    status="$(strip_quotes "$(trim "${rest%%,*}")")"
    rest="${rest#*,}"
    # Skip findings count (third field)
    rest="${rest#*,}"
    duration="$(trim "${rest#*,}")"
    printf '%s|%s|%s' "$step" "$status" "$duration"
  fi
}

# Extract the currently-active step (running, fixing, or if awaiting_agent, the gate step)
# Returns step name
get_active_step() {  # <run_output>
  local output=$1 line step

  # First check if there's a running or fixing step
  line=$(printf '%s\n' "$output" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1 | sed 's/^ *//')
  if [ -n "$line" ]; then
    step="${line%%,*}"
    printf '%s' "$step"
    return 0
  fi

  # If parked at gate, find the gate step
  if printf '%s\n' "$output" | grep -q '^[[:space:]]*gate:[[:space:]]*$'; then
    step=$(printf '%s\n' "$output" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
    step=$(strip_quotes "$(trim "$step")")
    [ -n "$step" ] && printf '%s' "$step" && return 0
  fi

  # Fallback to step from status field
  step=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*status:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$(trim "$step")")
  [ -n "$step" ] && printf '%s' "$step" && return 0

  return 1
}

# Extract last_activity time from active_steps table (e.g., "2s ago: log: message")
# Returns seconds elapsed, or 0 if cannot parse
parse_active_steps_time() {  # <active_steps_line>
  local line=$1
  # Look for patterns like "2s ago:" or "30m ago:"
  if [[ "$line" =~ ([0-9]+)(s|m|h)\ ago: ]]; then
    local value="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    case "$unit" in
      s) printf '%d' "$value" ;;
      m) printf '%d' "$((value * 60))" ;;
      h) printf '%d' "$((value * 3600))" ;;
      *) printf '0' ;;
    esac
  else
    printf '0'
  fi
}

# Check a single run's liveness by reading step activity
# Returns elapsed seconds (> 0) and exit code 0 for live, 1 for hung
check_run_liveness() {  # <run-id>
  local run_id=$1
  local run_out outcome awaiting_msg elapsed

  run_out=$(nm_run axi status --run "$run_id")
  if [ -z "$run_out" ]; then
    printf '0'
    return 1
  fi

  # Parse run info
  outcome=$(strip_quotes "$(nm_field "$run_out" outcome)")

  # Terminal outcomes are not hung
  if [ -n "$outcome" ]; then
    printf '0'
    return 0
  fi

  # Check if awaiting_agent (parked at gate waiting for input)
  awaiting_msg=$(printf '%s\n' "$run_out" | grep -E '^[[:space:]]*awaiting_agent:' | head -1)
  if [ -n "$awaiting_msg" ]; then
    # Deliberately parked at gate - not hung, not stale. Report 0 elapsed.
    printf '0'
    return 0
  fi

  # Check active_steps table for real-time last_activity
  # This section appears after the header 'active_steps[N]{...}:'
  local active_steps_section active_step_line last_activity_field
  active_steps_section=$(printf '%s\n' "$run_out" | sed -n '/^[[:space:]]*active_steps\[/,/^[^[:space:]]/p')

  if [ -n "$active_steps_section" ]; then
    # Get the data rows (skip the header line that ends with ':')
    active_step_line=$(printf '%s\n' "$active_steps_section" | grep -E '^[[:space:]]*[^,]+,(running|fixing),' | head -1 | sed 's/^[[:space:]]*//')

    if [ -n "$active_step_line" ]; then
      # Found an active running/fixing step in active_steps. Extract last_activity.
      # Format: step,status,active_for,"time ago: message","pid",round
      # Extract the quoted field after active_for
      if [[ "$active_step_line" =~ ^[^,]*,[^,]*,[^,]*,\"([^\"]*) ]]; then
        last_activity_field="${BASH_REMATCH[1]}"
        if [ -n "$last_activity_field" ]; then
          elapsed=$(parse_active_steps_time "$last_activity_field")
          if [ "$elapsed" -gt "$STALE_THRESHOLD" ]; then
            printf '%d' "$elapsed"
            return 1  # Hung
          fi
          printf '%d' "$elapsed"
          return 0  # Live
        fi
      fi
    fi
  fi

  # Fallback to steps table if no active_steps
  local active_step step_info step_status duration
  active_step=$(get_active_step "$run_out") || {
    printf '0'
    return 0
  }

  # Get step info (name|status|duration_ms)
  step_info=$(get_step_info "$run_out" "$active_step")
  if [ -z "$step_info" ]; then
    # Could not get step info - assume live
    printf '0'
    return 0
  fi

  step_status="${step_info#*|}"
  step_status="${step_status%|*}"
  duration="${step_info##*|}"

  # Use step duration only as fallback; it's less accurate than active_steps
  case "$duration" in ''|*[!0-9]*)
    printf '0'
    return 0
    ;;
  *)
    # Convert milliseconds to seconds
    elapsed=$((duration / 1000))
    # Step duration alone isn't reliable (includes all time at gate)
    # Only report hung if duration is extremely large (> 30 min) and still running
    if [ "$step_status" = "fixing" ] && [ "$elapsed" -gt 1800 ]; then
      printf '%d' "$elapsed"
      return 1  # Suspicious
    fi
    ;;
  esac

  printf '%d' "$elapsed"
  return 0  # Live
}

# List and check all running runs
check_all_runs() {
  local runs_out run_row status branch run_id task elapsed liveness
  runs_out=$(nm_run runs --limit 50) || die "Failed to list runs"
  [ -n "$runs_out" ] || { printf 'no runs found\n'; return 0; }

  local total=0 live=0 hung=0
  while IFS= read -r run_row; do
    run_row=$(trim "$run_row")
    [ -n "$run_row" ] || continue

    status=${run_row%% *}
    [ "$status" = "running" ] || continue

    total=$((total + 1))

    # Parse: status branch sha date [pr-url]
    # We only need branch for task lookup
    local rest
    rest=${run_row#* }
    rest=$(trim "$rest")
    branch=${rest%% *}

    # Get the run id by looking for axi status on a worktree with this branch
    run_id="unknown"
    # Try to find a task with this branch and get its run ID
    task=$(find_task_for_branch "$branch")
    if [ "$task" != "unknown" ]; then
      # Found a task - get its run ID from axi status
      local task_id="${task##*/}"
      local meta_file="$STATE/$task_id.meta"
      if [ ! -f "$meta_file" ] && [ -d "$FM_HOME/state" ]; then
        meta_file="$FM_HOME/state/$task_id.meta"
      fi
      if [ -f "$meta_file" ]; then
        local worktree
        worktree=$(grep "^worktree=" "$meta_file" | tail -1 | cut -d= -f2-)
        if [ -n "$worktree" ] && [ -d "$worktree" ]; then
          local axi_out
          axi_out=$(cd "$worktree" && nm_run axi status 2>/dev/null || true)
          if [ -n "$axi_out" ]; then
            run_id=$(strip_quotes "$(nm_field "$axi_out" id)")
          fi
        fi
      fi
    fi

    # Check liveness only if we got a valid run ID
    if [ "$run_id" != "unknown" ]; then
      if elapsed=$(check_run_liveness "$run_id" 2>/dev/null); then
        liveness="live"
        live=$((live + 1))
      else
        liveness="hung"
        hung=$((hung + 1))
      fi
    else
      # Could not get run ID - report as unknown liveness
      elapsed="unknown"
      liveness="unknown"
    fi

    printf 'run: %s · branch: %s · status: %s · owned-by: %s · last-activity: %ss\n' \
      "$run_id" "$branch" "$liveness" "$task" "$elapsed"
  done <<< "$runs_out"

  printf '\nsummary: %d total, %d live, %d hung\n' "$total" "$live" "$hung"
  [ "$hung" -eq 0 ] && return 0 || return 1
}

# Check a specific task's run liveness
check_task_run() {  # <task-id>
  local task_id=$1 meta_file worktree branch task_branch git_root

  meta_file="$STATE/$task_id.meta"
  if [ ! -f "$meta_file" ]; then
    # Try the current git root's state directory
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    [ -n "$git_root" ] && meta_file="$git_root/state/$task_id.meta"
  fi
  [ -f "$meta_file" ] || die "no metadata for $task_id"

  worktree=$(grep "^worktree=" "$meta_file" | tail -1 | cut -d= -f2-)
  [ -n "$worktree" ] || die "no worktree in metadata for $task_id"
  [ -d "$worktree" ] || die "worktree gone for $task_id"

  task_branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$task_branch" ] || die "detached HEAD in $task_id (no run to check)"

  # Find the run for this branch
  local runs_out run_row status branch
  runs_out=$(nm_run runs --limit 200) || die "Failed to list runs"
  [ -n "$runs_out" ] || die "no runs found"

  while IFS= read -r run_row; do
    run_row=$(trim "$run_row")
    [ -n "$run_row" ] || continue

    status=${run_row%% *}
    [ "$status" = "running" ] || continue

    local rest
    rest=${run_row#* }
    rest=$(trim "$rest")
    branch=${rest%% *}

    if [ "$branch" = "$task_branch" ]; then
      # Found a run for this task's branch
      # Get full run details via axi status
      local axi_out run_id
      axi_out=$(cd "$worktree" && nm_run axi status 2>/dev/null || true)
      run_id=$(strip_quotes "$(nm_field "$axi_out" id)")

      [ -n "$run_id" ] || die "Could not get run ID"

      # Check liveness
      local elapsed
      if elapsed=$(check_run_liveness "$run_id" 2>/dev/null); then
        printf 'task: %s · branch: %s · status: live · last-activity: %ss\n' \
          "$task_id" "$branch" "$elapsed"
        return 0
      else
        printf 'task: %s · branch: %s · status: hung · last-activity: %ss\n' \
          "$task_id" "$branch" "$elapsed"
        return 1
      fi
    fi
  done <<< "$runs_out"

  die "no running no-mistakes run for $task_id's branch ($task_branch)"
}

# --- main --------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --help|-h) usage ;;
    --all) check_all_runs ;;
    --*) die "unknown option: $1" ;;
    '')
      # Default: check all running runs
      check_all_runs
      ;;
    *)
      # Check specific task
      check_task_run "$1"
      ;;
  esac
fi
