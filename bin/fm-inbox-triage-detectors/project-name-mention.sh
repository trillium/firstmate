#!/usr/bin/env bash
# project-name-mention.sh - score an inbox bead against project names in a
# local registry. Reads the canonical triage input on stdin (see
# bin/fm-inbox-triage.sh "Detector contract"), takes --registry <file> with
# {"projects": [{"slug", "name", "aliases"?}]}, and prints one evidence object.
# A slug mention scores 90, a name or alias mention scores 70, no mention
# scores 0 with a null project. A missing or unreadable registry is score 0,
# never an error: evidence-only detectors stay fail-open.
set -u

REGISTRY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) shift; REGISTRY=${1:-}; [ $# -gt 0 ] && shift ;;
    *) shift ;;
  esac
done

INPUT=$(cat)
TEXT=$(printf '%s' "$INPUT" | jq -r '"\(.title // "")\n\(.description // "")"' 2>/dev/null | tr '[:upper:]' '[:lower:]')
[ -n "$TEXT" ] || { jq -c -n '{detector: "project-name-mention", score: 0, project: null, evidence: "input unreadable"}'; exit 0; }

emit() {
  jq -c -n --argjson score "$1" --argjson proj "$2" --arg ev "$3" \
    '{detector: "project-name-mention", score: $score, project: $proj, evidence: $ev}'
}

if [ -z "$REGISTRY" ] || [ ! -f "$REGISTRY" ]; then
  emit 0 null "no registry, no name to match against"
  exit 0
fi

BEST_SCORE=0
BEST_PROJ=null
BEST_EV="no project name mentioned"
BEST_JSON=$(jq -c '.projects // [] | .[] | {slug: .slug, names: ([.slug, .name] + (.aliases // []) | map(select(. != null and . != "")) | unique)}' "$REGISTRY" 2>/dev/null) \
  || { emit 0 null "registry unreadable"; exit 0; }

while IFS= read -r row; do
  slug=$(printf '%s' "$row" | jq -r '.slug')
  [ -n "$slug" ] && [ "$slug" != null ] || continue
  names=$(printf '%s' "$row" | jq -r '.names[]')
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    lower_n=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')
    case "$TEXT" in
      *"$lower_n"*)
        if [ "$lower_n" = "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" ]; then
          score=90
        else
          score=70
        fi
        if [ "$score" -gt "$BEST_SCORE" ]; then
          BEST_SCORE=$score
          BEST_PROJ=$(printf '%s' "$slug" | jq -R .)
          BEST_EV="mentions '$n' (project $slug)"
        fi
        ;;
    esac
  done <<<"$names"
done <<<"$BEST_JSON"

emit "$BEST_SCORE" "$BEST_PROJ" "$BEST_EV"
