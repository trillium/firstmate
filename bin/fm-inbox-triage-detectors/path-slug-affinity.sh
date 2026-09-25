#!/usr/bin/env bash
# path-slug-affinity.sh - score an inbox bead on path-like mentions of a
# project slug (`projects/<slug>`, `code/<slug>`, `trillium/<slug>`,
# `.treehouse/<slug>`). Reads the canonical triage input on stdin (see
# bin/fm-inbox-triage.sh "Detector contract"), takes an optional
# --registry <file> with {"projects": [{"slug"}]}, and prints one evidence
# object. With a registry, a path mention of a known slug scores 80. Without
# one, a `projects/<slug>` mention still yields a candidate slug at 60, since
# the path itself names the project. Anything else scores 0 with a null
# project. An unreadable registry behaves like no registry, never an error.
set -u

REGISTRY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) shift; REGISTRY=${1:-}; [ $# -gt 0 ] && shift ;;
    *) shift ;;
  esac
done

INPUT=$(cat)
TEXT=$(printf '%s' "$INPUT" | jq -r '"\(.title // "")\n\(.description // "")"' 2>/dev/null)
[ -n "$TEXT" ] || { jq -c -n '{detector: "path-slug-affinity", score: 0, project: null, evidence: "input unreadable"}'; exit 0; }
LOWER=$(printf '%s' "$TEXT" | tr '[:upper:]' '[:lower:]')

emit() {
  jq -c -n --argjson score "$1" --argjson proj "$2" --arg ev "$3" \
    '{detector: "path-slug-affinity", score: $score, project: $proj, evidence: $ev}'
}

SLUGS=""
if [ -n "$REGISTRY" ] && [ -f "$REGISTRY" ]; then
  SLUGS=$(jq -r '(.projects // []) | .[].slug | select(. != null and . != "")' "$REGISTRY" 2>/dev/null) || SLUGS=""
fi

if [ -n "$SLUGS" ]; then
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    lower_slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
    for prefix in "projects/$lower_slug" "code/$lower_slug" "trillium/$lower_slug" ".treehouse/$lower_slug" "/$lower_slug/" "/$lower_slug"; do
      case "$LOWER" in
        *"$prefix"*)
          emit 80 "$(printf '%s' "$slug" | jq -R .)" "path mention '$prefix' points at $slug"
          exit 0
          ;;
      esac
    done
  done <<<"$SLUGS"
  emit 0 null "no path mention of a known project slug"
  exit 0
fi

CANDIDATE=$(printf '%s' "$LOWER" | grep -o -E 'projects/[a-z0-9][a-z0-9_-]*' | head -1 | cut -d/ -f2)
if [ -n "$CANDIDATE" ]; then
  emit 60 "$(printf '%s' "$CANDIDATE" | jq -R .)" "path mention 'projects/$CANDIDATE' names a candidate project"
else
  emit 0 null "no path-like project mention"
fi
