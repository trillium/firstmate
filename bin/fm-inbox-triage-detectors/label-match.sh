#!/usr/bin/env bash
# label-match.sh - score an inbox bead against its own labels. Reads the
# canonical triage input on stdin (see bin/fm-inbox-triage.sh "Detector
# contract") and prints one evidence object. A `project:<slug>` label is an
# explicit routing hint and scores 95. A `cat-<name>` label is a topic hint,
# not a project, so it scores 40 with a null project and names the label as
# evidence. Any other labels, or none, score 0. This detector needs no
# registry and ignores --registry when given.
set -u

while [ $# -gt 0 ]; do shift; done

INPUT=$(cat)
LABELS=$(printf '%s' "$INPUT" | jq -r '(.labels // []) | .[]' 2>/dev/null) || {
  jq -c -n '{detector: "label-match", score: 0, project: null, evidence: "input unreadable"}'
  exit 0
}

emit() {
  jq -c -n --argjson score "$1" --argjson proj "$2" --arg ev "$3" \
    '{detector: "label-match", score: $score, project: $proj, evidence: $ev}'
}

BEST_SCORE=0
BEST_PROJ=null
BEST_EV="no project or topic labels"
while IFS= read -r label; do
  [ -n "$label" ] || continue
  case "$label" in
    project:*)
      slug=${label#project:}
      if [ -n "$slug" ] && [ "$BEST_SCORE" -lt 95 ]; then
        BEST_SCORE=95
        BEST_PROJ=$(printf '%s' "$slug" | jq -R .)
        BEST_EV="label '$label' explicitly routes to $slug"
      fi
      ;;
    cat-*)
      if [ "$BEST_SCORE" -lt 40 ]; then
        BEST_SCORE=40
        BEST_EV="label '$label' suggests a topic, not a project"
      fi
      ;;
  esac
done <<<"$LABELS"

emit "$BEST_SCORE" "$BEST_PROJ" "$BEST_EV"
