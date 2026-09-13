#!/usr/bin/env bash
# fm-inbox-triage.sh - route every inbox bead to exactly one project, with
# evidence-only detectors and an immutable decision trace for later evaluation.
#
# The agent runs all registered detectors, reads their evidence, then chooses
# (or creates) exactly one project and records its reasoning. Detectors never
# decide: they emit scored evidence and the agent owns the decision. Each
# decide appends one JSON object to a JSONL trace log holding the raw input,
# the detector evidence, the decision and reasoning, the structured detector
# feedback, and the bead's original assignment. The log is append-only: this
# command never truncates or rewrites it, so later evaluation (forward replay,
# detector scoring, reassignment analysis) always sees the original history.
#
# A create-project decision only edits the local registry file given by
# --registry. It never publishes, migrates, or touches any other store; the
# inbox and task stores are read (show/list) but never written by this tool.
#
# Detector registry: every executable file directly under the detectors
# directory is one detector, run in sorted filename order. A detector's I/O
# contract (see "Detector contract" below) is stdin JSON in, one JSON object
# out. To reuse a detector with new parameters, copy it under a new filename
# with different arguments wired into its registry lookup; to register a new
# detector type, drop in an executable implementing the contract plus positive
# and negative tests in tests/fm-inbox-triage.test.sh. A failing detector is
# fail-open: it becomes score-0 evidence naming its exit code, never an abort.
#
# Detector contract:
#   stdin:  {"id","title","description","labels":[],"assignee","status"}
#   stdout: {"detector":"<name>","score":<0-100 int>,
#            "project":"<slug>"|null,"evidence":"<one line>"}
#   exit 0 on valid input. The runner overwrites .detector with the detector's
#   filename (minus extension) and coerces an out-of-range score to 0, so the
#   registry filename is the single source of detector identity.
#
# Usage:
#   fm-inbox-triage.sh detectors
#   fm-inbox-triage.sh list [--json]
#   fm-inbox-triage.sh evidence <inbox-id> [--input <json-file>]
#     [--registry <file>] [--json]
#   fm-inbox-triage.sh decide <inbox-id> --project <slug> --reason <text>
#     [--create-project] [--input <json-file>] [--registry <file>]
#     [--trace-log <file>] [--actor <name>] [--feedback <detector>:<value>]...
#
# Feedback values: useful, irrelevant, misleading, false-positive, decisive.
# --project may be given exactly once; a second one is an error, never a tie.
#
# Env:
#   FM_INBOX_BIN               inbox CLI to read from (default: inbox)
#   FM_INBOX_TRIAGE_DETECTORS  detector directory
#     (default: <this-script-dir>/fm-inbox-triage-detectors)
#   FM_INBOX_TRIAGE_REGISTRY   default --registry path (default: unset)
#   FM_INBOX_TRIAGE_LOG        default --trace-log path
#     (default: ./fm-inbox-triage-trace.jsonl)
set -u

BIN="${FM_INBOX_BIN:-inbox}"
SELF_DIR="$(dirname "$0")"
DETECTORS_DIR="${FM_INBOX_TRIAGE_DETECTORS:-$SELF_DIR/fm-inbox-triage-detectors}"
DEFAULT_REGISTRY="${FM_INBOX_TRIAGE_REGISTRY:-}"
DEFAULT_LOG="${FM_INBOX_TRIAGE_LOG:-./fm-inbox-triage-trace.jsonl}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

need_jq() {
  command -v jq >/dev/null 2>&1 || { echo "fm-inbox-triage: jq not found" >&2; exit 1; }
}

detector_name() {
  local base="${1##*/}"
  printf '%s' "${base%.*}"
}

cmd_detectors() {
  [ -d "$DETECTORS_DIR" ] || { echo "fm-inbox-triage: no detectors directory: $DETECTORS_DIR" >&2; exit 1; }
  local found=0
  local f
  while IFS= read -r f; do
    [ -x "$f" ] && [ -f "$f" ] || continue
    printf '%s\t%s\n' "$(detector_name "$f")" "$f"
    found=1
  done < <(find "$DETECTORS_DIR" -maxdepth 1 -type f | sort)
  [ "$found" -eq 1 ] || { echo "fm-inbox-triage: no executable detectors in $DETECTORS_DIR" >&2; exit 1; }
}

fetch_bead_json() {
  local id=$1 input=$2
  if [ -n "$input" ]; then
    cat "$input"
  else
    command -v "$BIN" >/dev/null 2>&1 || { echo "fm-inbox-triage: $BIN CLI not found" >&2; exit 1; }
    "$BIN" show "$id" --json || { echo "fm-inbox-triage: could not read $id via $BIN" >&2; exit 1; }
  fi
}

normalize_input() {
  jq -c '. | if type == "array" then .[0] else . end
    | {id: (.id // ""), title: (.title // ""), description: (.description // ""),
         labels: (.labels // []), assignee: (.assignee // ""), status: (.status // "")}'
}

run_evidence() {
  local canonical=$1 registry=$2
  local outs=()
  local f name out rc
  while IFS= read -r f; do
    [ -x "$f" ] && [ -f "$f" ] || continue
    name="$(detector_name "$f")"
    if [ -n "$registry" ]; then
      out=$(printf '%s' "$canonical" | "$f" --registry "$registry" 2>/dev/null)
      rc=$?
    else
      out=$(printf '%s' "$canonical" | "$f" 2>/dev/null)
      rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      out=$(printf '%s' "$out" | jq -c --arg d "$name" \
        '. * {detector: $d} | .score = (if (.score | type) == "number" and .score >= 0 and .score <= 100 then (.score | floor) else 0 end)' 2>/dev/null) \
        || out=$(jq -c -n --arg d "$name" '{detector: $d, score: 0, project: null, evidence: "detector printed invalid JSON"}')
    else
      out=$(jq -c -n --arg d "$name" --argjson rc "$rc" '{detector: $d, score: 0, project: null, evidence: ("detector failed with exit " + ($rc | tostring))}')
    fi
    outs+=("$out")
  done < <(find "$DETECTORS_DIR" -maxdepth 1 -type f | sort)
  [ "${#outs[@]}" -gt 0 ] || { echo "fm-inbox-triage: no executable detectors in $DETECTORS_DIR" >&2; exit 1; }
  printf '%s\n' "${outs[@]}" | jq -s -c '.'
}

cmd_evidence() {
  need_jq
  local id=${1:-}
  [ -n "$id" ] || { echo "fm-inbox-triage: evidence requires an inbox id" >&2; exit 2; }
  shift
  local input="" registry="$DEFAULT_REGISTRY" json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --input) [ $# -ge 2 ] || { echo "fm-inbox-triage: --input requires a value" >&2; exit 2; }; input=$2; shift 2 ;;
      --registry) [ $# -ge 2 ] || { echo "fm-inbox-triage: --registry requires a value" >&2; exit 2; }; registry=$2; shift 2 ;;
      --json) json=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "fm-inbox-triage: unknown evidence argument: $1" >&2; exit 2 ;;
    esac
  done
  local canonical
  canonical=$(fetch_bead_json "$id" "$input" | normalize_input) || exit 1
  local evidence
  evidence=$(run_evidence "$canonical" "$registry") || exit 1
  if [ "$json" -eq 1 ]; then
    jq -c -n --arg id "$id" --argjson ev "$evidence" '{inbox_id: $id, evidence: $ev}'
  else
    printf 'evidence for %s:\n' "$id"
    printf '%s' "$evidence" | jq -r '.[] | "- [\(.score)] \(.detector): \(.evidence) (project: \(.project // "none"))"'
  fi
}

valid_feedback() {
  case "$1" in
    useful|irrelevant|misleading|false-positive|decisive) return 0 ;;
    *) return 1 ;;
  esac
}

registry_add_project() {
  local registry=$1 slug=$2
  if [ -f "$registry" ]; then
    jq --arg s "$slug" 'if (.projects // [] | map(.slug) | index($s)) then . else .projects += [{slug: $s, name: $s}] end' "$registry" > "$registry.tmp" \
      || { echo "fm-inbox-triage: could not update registry $registry" >&2; rm -f "$registry.tmp"; exit 1; }
    mv "$registry.tmp" "$registry"
  else
    jq -n --arg s "$slug" '{projects: [{slug: $s, name: $s}]}' > "$registry" \
      || { echo "fm-inbox-triage: could not create registry $registry" >&2; exit 1; }
  fi
}

cmd_decide() {
  need_jq
  local id=${1:-}
  [ -n "$id" ] || { echo "fm-inbox-triage: decide requires an inbox id" >&2; exit 2; }
  shift
  local project="" project_count=0 reason="" create=0
  local input="" registry="$DEFAULT_REGISTRY" log="$DEFAULT_LOG" actor="${USER:-agent}"
  local feedback_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) [ $# -ge 2 ] || { echo "fm-inbox-triage: --project requires a value" >&2; exit 2; }; project=$2; project_count=$((project_count + 1)); shift 2 ;;
      --reason) [ $# -ge 2 ] || { echo "fm-inbox-triage: --reason requires a value" >&2; exit 2; }; reason=$2; shift 2 ;;
      --create-project) create=1; shift ;;
      --input) [ $# -ge 2 ] || { echo "fm-inbox-triage: --input requires a value" >&2; exit 2; }; input=$2; shift 2 ;;
      --registry) [ $# -ge 2 ] || { echo "fm-inbox-triage: --registry requires a value" >&2; exit 2; }; registry=$2; shift 2 ;;
      --trace-log) [ $# -ge 2 ] || { echo "fm-inbox-triage: --trace-log requires a value" >&2; exit 2; }; log=$2; shift 2 ;;
      --actor) [ $# -ge 2 ] || { echo "fm-inbox-triage: --actor requires a value" >&2; exit 2; }; actor=$2; shift 2 ;;
      --feedback) [ $# -ge 2 ] || { echo "fm-inbox-triage: --feedback requires a value" >&2; exit 2; }; feedback_args+=("$2"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "fm-inbox-triage: unknown decide argument: $1" >&2; exit 2 ;;
    esac
  done
  [ "$project_count" -eq 1 ] || { echo "fm-inbox-triage: decide requires exactly one --project (got $project_count)" >&2; exit 2; }
  [ -n "$reason" ] || { echo "fm-inbox-triage: decide requires a non-empty --reason" >&2; exit 2; }
  local feedback_json="{}"
  local fb name value
  for fb in ${feedback_args[@]+"${feedback_args[@]}"}; do
    name=${fb%%:*}; value=${fb#*:}
    [ -n "$name" ] && [ "$name" != "$fb" ] || { echo "fm-inbox-triage: --feedback must be <detector>:<value>, got: $fb" >&2; exit 2; }
    valid_feedback "$value" || { echo "fm-inbox-triage: invalid feedback value: $value" >&2; exit 2; }
    feedback_json=$(printf '%s' "$feedback_json" | jq -c --arg k "$name" --arg v "$value" '. + {($k): $v}') || exit 1
  done
  if [ "$create" -eq 1 ]; then
    [ -n "$registry" ] || { echo "fm-inbox-triage: --create-project requires --registry" >&2; exit 2; }
    registry_add_project "$registry" "$project"
  fi
  local raw canonical evidence ts record
  raw=$(fetch_bead_json "$id" "$input") || exit 1
  canonical=$(printf '%s' "$raw" | normalize_input) || exit 1
  evidence=$(run_evidence "$canonical" "$registry") || exit 1
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  record=$(jq -c -n --arg ts "$ts" --arg actor "$actor" --arg id "$id" \
    --argjson input "$canonical" --argjson ev "$evidence" \
    --arg proj "$project" --argjson created "$([ "$create" -eq 1 ] && echo true || echo false)" \
    --arg reason "$reason" --argjson fb "$feedback_json" \
    '{v: 1, ts: $ts, actor: $actor, inbox_id: $id, input: $input, evidence: $ev,
      decision: {project: $proj, created: $created, reason: $reason}, feedback: $fb}') || exit 1
  printf '%s\n' "$record" >> "$log" || { echo "fm-inbox-triage: could not append to $log" >&2; exit 1; }
  echo "triaged $id -> $project (trace: $log)"
}

cmd_list() {
  local json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "fm-inbox-triage: unknown list argument: $1" >&2; exit 2 ;;
    esac
  done
  command -v "$BIN" >/dev/null 2>&1 || { echo "fm-inbox-triage: $BIN CLI not found" >&2; exit 1; }
  if [ "$json" -eq 1 ]; then
    exec "$BIN" list --json
  else
    exec "$BIN" list
  fi
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
cmd=$1; shift
case "$cmd" in
  detectors) cmd_detectors "$@" ;;
  evidence) cmd_evidence "$@" ;;
  decide) cmd_decide "$@" ;;
  list) cmd_list "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *) echo "fm-inbox-triage: unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
