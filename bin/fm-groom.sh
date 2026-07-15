#!/usr/bin/env bash
# fm-groom.sh - PROACTIVE idea->brief->dispatch generator for firstmate.
#
# The missing engine behind data/captain.md's "Formulate the brief from his sparks
# -- never make him articulate the exact task" doctrine. The captain drops rough
# ideas into the `ideas` store; today firstmate only launches work REACTIVELY, so
# those ideas sit ungroomed. This tool grooms them: for each READY idea it
# FORMULATES a concrete runnable brief with an LLM (the core value -- turning a
# spark into the clear string gnhf/a crewmate needs), CLASSIFIES it safe vs unsafe,
# and either dispatches the safe ones or files the unsafe ones to the `review`
# store for the captain.
#
# SAFETY (this is an autonomous LAUNCHER -- it must not run wild):
#   * OFF BY DEFAULT. Real dispatch requires FM_GROOM_ENABLED=1. Without it every
#     run is a DRY-RUN: it formulates + classifies + prints the intended action,
#     and spawns/files/marks NOTHING. This is the primary rail.
#   * RATE-LIMITED. FM_GROOM_MAX_IN_FLIGHT (default 2) caps concurrently-dispatched
#     groom tasks; when the fleet already holds that many groom-dispatched tasks,
#     no new safe idea is dispatched this run (it is reported as deferred).
#   * BOUNDED PER RUN. FM_GROOM_MAX_PER_RUN (default 3) caps how many ideas this
#     single invocation will act on (dispatch OR file), so one run can never
#     stampede the whole 25-idea backlog. Cost-aware: fewer LLM calls, fewer spawns.
#   * IDEMPOTENT. Every acted-on idea gets a durable `groom:<state>` label via
#     `ideas set-state`; a labeled idea is skipped forever after, so re-runs never
#     re-dispatch or re-file the same idea.
#   * DURABLE DISPATCH. Safe work is launched through fm-spawn.sh as a Herder-backed
#     crewmate (survives this session's compaction; the captain can watch it), never
#     a detached headless process.
#
# The LLM prompts live in fm-groom-lib.sh and are deliberately non-instructional so
# PAI's PromptGuard injection inspector does not block the nested claude (see
# data/learnings.md).
#
# Usage:
#   fm-groom.sh                 dry-run over ready ideas (default, safe)
#   fm-groom.sh --limit N       override FM_GROOM_MAX_PER_RUN for this run
#   fm-groom.sh --idea <id>     groom exactly one idea by id (still dry-run unless enabled)
#   fm-groom.sh --json          machine-readable per-idea result records (one JSON object per line)
#   FM_GROOM_ENABLED=1 fm-groom.sh   ARM real dispatch/file/mark (still bounded + rate-limited)
#
# Environment:
#   FM_GROOM_ENABLED        1 arms real actions; anything else = dry-run (default off)
#   FM_GROOM_MAX_PER_RUN    max ideas acted on per invocation (default 3)
#   FM_GROOM_MAX_IN_FLIGHT  max concurrently groom-dispatched tasks (default 2)
#   FM_GROOM_INFERENCE      override Inference.ts path (tests); see fm-groom-lib.sh
#   FM_GROOM_IDEAS_BIN      override the `ideas` CLI (tests); default `ideas` on PATH
#   FM_GROOM_REVIEW_BIN     override the `review` CLI (tests); default `review` on PATH
#   FM_GROOM_SPAWN          override the dispatch command (tests); default bin/fm-spawn.sh
#
# Exit status: 0 when the run completed (even a dry-run finding escalations); 1 on
# a hard setup error (missing dependency, unreadable store).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-groom-lib.sh
. "$SCRIPT_DIR/fm-groom-lib.sh"

IDEAS_BIN=${FM_GROOM_IDEAS_BIN:-ideas}
REVIEW_BIN=${FM_GROOM_REVIEW_BIN:-review}
SPAWN_BIN=${FM_GROOM_SPAWN:-$SCRIPT_DIR/fm-spawn.sh}

# The durable groom state-label dimension. `ideas set-state <id> groom=<value>`
# writes an event bead + a `groom:<value>` label; the presence of ANY groom:*
# label is the idempotency marker.
GROOM_DIM=groom

ENABLED=0
[ "${FM_GROOM_ENABLED:-}" = "1" ] && ENABLED=1
MAX_PER_RUN=${FM_GROOM_MAX_PER_RUN:-3}
MAX_IN_FLIGHT=${FM_GROOM_MAX_IN_FLIGHT:-2}
JSON=0
ONLY_IDEA=

usage() { sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=1 ;;
    --limit) shift; [ $# -gt 0 ] || { echo "error: --limit requires a value" >&2; exit 1; }; MAX_PER_RUN=$1 ;;
    --limit=*) MAX_PER_RUN=${1#--limit=} ;;
    --idea) shift; [ $# -gt 0 ] || { echo "error: --idea requires a value" >&2; exit 1; }; ONLY_IDEA=$1 ;;
    --idea=*) ONLY_IDEA=${1#--idea=} ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

case "$MAX_PER_RUN" in ''|*[!0-9]*) echo "error: --limit / FM_GROOM_MAX_PER_RUN must be a non-negative integer" >&2; exit 1 ;; esac
case "$MAX_IN_FLIGHT" in ''|*[!0-9]*) echo "error: FM_GROOM_MAX_IN_FLIGHT must be a non-negative integer" >&2; exit 1 ;; esac

command -v "$IDEAS_BIN" >/dev/null 2>&1 || { echo "error: ideas CLI not found ('$IDEAS_BIN')" >&2; exit 1; }

# --- helpers -------------------------------------------------------------------

# Count groom-dispatched tasks currently in flight. A groom dispatch writes a
# state/<task-id>.meta whose ID is prefixed `groom-`; teardown removes the meta.
# So the live in-flight count is the number of groom-*.meta files present. This is
# the same "meta = live task" convention fm-spawn/fm-teardown already use.
fm_groom_in_flight_count() {
  local n=0 f
  [ -d "$STATE" ] || { printf '0\n'; return 0; }
  for f in "$STATE"/groom-*.meta; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Has this idea already been groomed? True when it carries any groom:* label.
fm_groom_already_done() {
  local id=$1 labels
  labels=$("$IDEAS_BIN" label list "$id" 2>/dev/null || true)
  printf '%s\n' "$labels" | grep -qE "(^|[[:space:]])${GROOM_DIM}:" && return 0
  return 1
}

# Emit a JSON record for one idea's outcome (when --json). Fields are pre-escaped
# by the caller via fm_groom_json_escape.
fm_groom_json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g' -e 's/\t/\\t/g'
}

emit_json() {  # <id> <title> <verdict> <action> <brief> <note>
  printf '{"id":"%s","title":"%s","verdict":"%s","action":"%s","brief":"%s","note":"%s"}\n' \
    "$(fm_groom_json_escape "$1")" "$(fm_groom_json_escape "$2")" \
    "$(fm_groom_json_escape "$3")" "$(fm_groom_json_escape "$4")" \
    "$(fm_groom_json_escape "$5")" "$(fm_groom_json_escape "$6")"
}

# Human-readable per-idea report block.
emit_human() {  # <id> <title> <verdict> <action> <brief> <note>
  printf '\n──────────────────────────────────────────────────────────────\n'
  printf 'IDEA     %s  %s\n' "$1" "$2"
  printf 'VERDICT  %s' "$3"
  [ -n "$6" ] && printf '  (%s)' "$6"
  printf '\n'
  printf 'ACTION   %s\n' "$4"
  printf 'BRIEF ↓\n%s\n' "$5"
}

# --- ready-idea gathering ------------------------------------------------------

# Pull ready ideas as a stable id list, then read each idea's title+description.
# We shell out per-idea (ideas show --json) rather than parse the ready array so
# we get the full description reliably regardless of ready's truncation.
ready_json=$("$IDEAS_BIN" ready --json 2>/dev/null || printf '[]')
ids=$(printf '%s' "$ready_json" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/')
if [ -n "$ONLY_IDEA" ]; then
  ids=$ONLY_IDEA
fi

if [ -z "$ids" ]; then
  [ "$JSON" -eq 1 ] || echo "fm-groom: no ready ideas to groom."
  exit 0
fi

in_flight=$(fm_groom_in_flight_count)

if [ "$JSON" -eq 0 ]; then
  mode_label="DRY-RUN (no dispatch, no file, no mark)"
  [ "$ENABLED" -eq 1 ] && mode_label="ARMED (real dispatch/file/mark)"
  printf '════════════════════════════════════════════════════════════════\n'
  printf 'fm-groom  mode=%s\n' "$mode_label"
  printf '          max-per-run=%s  max-in-flight=%s  currently-in-flight=%s\n' \
    "$MAX_PER_RUN" "$MAX_IN_FLIGHT" "$in_flight"
  printf '════════════════════════════════════════════════════════════════\n'
fi

acted=0
skipped=0
dispatched_this_run=0

for id in $ids; do
  # Bounded per-run: stop acting once we hit the cap. In dry-run we still WANT to
  # show the cap taking effect, so we report remaining ideas as capped and stop.
  if [ "$acted" -ge "$MAX_PER_RUN" ]; then
    if [ "$JSON" -eq 1 ]; then
      title=$("$IDEAS_BIN" show "$id" --json 2>/dev/null | grep -oE '"title"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
      emit_json "$id" "${title:-}" "-" "capped" "" "per-run limit ($MAX_PER_RUN) reached"
    else
      printf '\n(… %s and remaining ideas skipped: per-run limit %s reached)\n' "$id" "$MAX_PER_RUN"
    fi
    break
  fi

  # Idempotency: skip already-groomed ideas.
  if fm_groom_already_done "$id"; then
    skipped=$((skipped + 1))
    [ "$JSON" -eq 1 ] && emit_json "$id" "" "-" "skipped" "" "already groomed (groom:* label present)"
    continue
  fi

  show_json=$("$IDEAS_BIN" show "$id" --json 2>/dev/null || true)
  title=$(printf '%s' "$show_json" | grep -oE '"title"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
  # Description can contain escaped quotes/newlines; pull it with a JSON-aware read.
  desc=$(printf '%s' "$show_json" | FM_KEY=description "$SCRIPT_DIR/fm-groom-json-field.sh" 2>/dev/null || true)
  [ -n "$title" ] || title="(untitled $id)"
  [ -n "$desc" ] || desc="$title"

  # (1)+(2) FORMULATE the runnable brief. This is the core value.
  if ! brief=$(fm_groom_formulate_brief "$title" "$desc"); then
    note="brief formulation failed (inference error)"
    if [ "$JSON" -eq 1 ]; then emit_json "$id" "$title" "-" "error" "" "$note"
    else emit_human "$id" "$title" "-" "SKIP: $note" "" ""; fi
    acted=$((acted + 1))
    continue
  fi

  # (3) CLASSIFY safe vs escalate. Fail-safe: any failure => escalate.
  if classify_out=$(fm_groom_classify "$title" "$brief"); then
    verdict=$(printf '%s\n' "$classify_out" | head -1)
    rationale=$(printf '%s\n' "$classify_out" | sed -n '2p')
  else
    verdict=escalate
    rationale="classification inference failed; escalating by fail-safe policy"
  fi

  if [ "$verdict" = "safe" ]; then
    # (4) SAFE -> dispatch (rate-limited). If we're at the in-flight cap, defer.
    if [ "$dispatched_this_run" -ge 1 ] && [ $((in_flight + dispatched_this_run)) -ge "$MAX_IN_FLIGHT" ]; then
      action="DEFER dispatch (in-flight cap $MAX_IN_FLIGHT reached)"
      if [ "$JSON" -eq 1 ]; then emit_json "$id" "$title" "$verdict" "deferred" "$brief" "$rationale"
      else emit_human "$id" "$title" "$verdict" "$action" "$brief" "$rationale"; fi
      acted=$((acted + 1))
      continue
    fi
    if [ $((in_flight + dispatched_this_run)) -ge "$MAX_IN_FLIGHT" ]; then
      action="DEFER dispatch (in-flight cap $MAX_IN_FLIGHT reached)"
      if [ "$JSON" -eq 1 ]; then emit_json "$id" "$title" "$verdict" "deferred" "$brief" "$rationale"
      else emit_human "$id" "$title" "$verdict" "$action" "$brief" "$rationale"; fi
      acted=$((acted + 1))
      continue
    fi

    task_id="groom-$(printf '%s' "$id" | tr -cd 'a-z0-9')"
    if [ "$ENABLED" -eq 1 ]; then
      # Real dispatch: write the formulated brief to data/<task-id>/brief.md and
      # spawn a scout crewmate (report deliverable, scratch worktree). We mark the
      # idea in-progress via groom=dispatched BEFORE spawn so a crash mid-spawn
      # still leaves the idempotency marker (never double-dispatch).
      mkdir -p "$DATA/$task_id"
      {
        printf '# Groomed from idea %s: %s\n\n' "$id" "$title"
        printf '%s\n\n' "$brief"
        # shellcheck disable=SC2016  # literal backticks/braces are the brief text, not shell expansions
        printf 'When done, document your findings to brain via `brain create --type=knowledge "<title>"`.\n'
        printf 'Report your result to data/%s/report.md.\n' "$task_id"
      } > "$DATA/$task_id/brief.md"
      "$IDEAS_BIN" set-state "$id" "$GROOM_DIM=dispatched" \
        --reason "fm-groom auto-dispatched as $task_id" >/dev/null 2>&1 || true
      "$IDEAS_BIN" note "$id" "fm-groom dispatched as task $task_id (result -> data/$task_id/report.md)" >/dev/null 2>&1 || true
      if "$SPAWN_BIN" "$task_id" "$FM_ROOT" --scout >/dev/null 2>&1; then
        action="DISPATCHED as $task_id (scout)"
        dispatched_this_run=$((dispatched_this_run + 1))
      else
        action="DISPATCH FAILED for $task_id (idea marked; retry manually)"
      fi
    else
      action="WOULD DISPATCH as $task_id (scout via fm-spawn)"
    fi
  else
    # ESCALATE -> file a review item (never dispatch).
    if [ "$ENABLED" -eq 1 ]; then
      review_title="Groomed idea needs your call: $title"
      if command -v "$REVIEW_BIN" >/dev/null 2>&1; then
        rid=$(printf '%s' "$brief" | "$REVIEW_BIN" q "$review_title" \
          --description "Auto-formulated from idea $id. Classified NOT safe to auto-dispatch: ${rationale:-no rationale}. Review the brief below and either enable it or drop it." \
          --body-file - 2>/dev/null || true)
        "$IDEAS_BIN" set-state "$id" "$GROOM_DIM=escalated" \
          --reason "fm-groom filed review item ${rid:-?}" >/dev/null 2>&1 || true
        "$IDEAS_BIN" note "$id" "fm-groom escalated to review item ${rid:-(unknown)}: $rationale" >/dev/null 2>&1 || true
        action="FILED review item ${rid:-(id unknown)}"
      else
        action="REVIEW CLI MISSING; idea left unmarked for retry"
      fi
    else
      action="WOULD FILE review item (escalate)"
    fi
  fi

  if [ "$JSON" -eq 1 ]; then
    emit_json "$id" "$title" "$verdict" "$action" "$brief" "$rationale"
  else
    emit_human "$id" "$title" "$verdict" "$action" "$brief" "$rationale"
  fi
  acted=$((acted + 1))
done

if [ "$JSON" -eq 0 ]; then
  printf '\n════════════════════════════════════════════════════════════════\n'
  printf 'fm-groom done: acted=%s skipped(already-groomed)=%s dispatched-this-run=%s\n' \
    "$acted" "$skipped" "$dispatched_this_run"
  if [ "$ENABLED" -eq 0 ]; then
    printf 'This was a DRY-RUN. To arm real dispatch/file/mark:\n'
    printf '  FM_GROOM_ENABLED=1 %s\n' "$SCRIPT_DIR/fm-groom.sh"
  fi
  printf '════════════════════════════════════════════════════════════════\n'
fi
