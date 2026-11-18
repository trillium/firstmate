#!/usr/bin/env bash
# fm-workhorse-file.sh - file a workhorse bead whose body is a full brief, then
# ring the workhorse mate.
#
# Usage: fm-workhorse-file.sh --title <title> --intent <text> --spec <text>
#          --out-of-scope <text> --dod <text> --evidence <kind>:<what>...
#          --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
#          --project <name> --answer-to <filing-mate-id> [--dry-run]
#
# The bead goes into the TASK store only, always through `task` with BEADS_DIR
# pinned to the task store and the cwd moved off the caller's tree
# (bin/fm-workhorse-lib.sh owns the pinning and the body layout), so a mate
# whose cwd or wrapper resolves a different .beads still files into the right
# place. It is filed with the `workhorse` label (plus the fleet label fm-note.sh
# uses, FM_BEADS_FLEET_LABEL, default fleet:firstmate) and records the filing
# mate in the bead's metadata and in its Answer-to section.
#
# Every section text accepts `@<path>` to read it from a file. The brief
# sections are Captain's intent, Firstmate spec, Out of scope, Definition of
# done, Evidence required, Delivery mode + yolo posture, and Answer-to. Each
# one is REFUSED, with nothing filed, when it is empty, a vague stand-in (none,
# n/a, tbd, see title, ...), shorter than four words, a copy of the title,
# or carries a leftover placeholder ({TASK}, <fill in>, TBD, FIXME, ...). The
# intent must not open with a Captain label, and no section may contain a line
# that starts with `## ` (it would split the brief when read back).
# --evidence is repeatable and needs at least one `pr:`, `report:`, or
# `command:` entry naming the proof the closer must supply (a PR link, a report
# path, or command output); bin/fm-workhorse-close.sh enforces exactly the
# kinds named here. --mode and --yolo are explicit per-bead decisions that the
# claiming mate passes on, and --project names the registered project the
# claimed work builds in.
# --dry-run prints the body that would be filed and files nothing.
#
# On success the bead id is the only stdout line. The doorbell then rings
# through bin/fm-workhorse-ring.sh; a filed bead whose doorbell is unconfirmed
# exits 4 after printing its id, and the same ring is re-run by hand. Exit 2 is
# a refused request (nothing filed) and 1 is a store failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-workhorse-lib.sh
. "$SCRIPT_DIR/fm-workhorse-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

refuse() {
  printf 'fm-workhorse-file: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

TITLE='' INTENT='' SPEC='' OUT='' DOD='' MODE='' YOLO='' PROJECT='' ANSWER_TO=''
DRY_RUN=0
EVIDENCE=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift; continue ;;
    --title|--intent|--spec|--out-of-scope|--dod|--evidence|--mode|--yolo|--project|--answer-to) ;;
    *) refuse "unknown argument: $1" ;;
  esac
  [ "$#" -ge 2 ] || refuse "$1 needs a value"
  value=$2
  case "$value" in
    @?*)
      [ -f "${value#@}" ] || refuse "$1: file ${value#@} does not exist"
      value=$(cat "${value#@}")
      ;;
  esac
  case "$1" in
    --title) TITLE=$value ;;
    --intent) INTENT=$value ;;
    --spec) SPEC=$value ;;
    --out-of-scope) OUT=$value ;;
    --dod) DOD=$value ;;
    --evidence) EVIDENCE+=("$value") ;;
    --mode) MODE=$value ;;
    --yolo) YOLO=$value ;;
    --project) PROJECT=$value ;;
    --answer-to) ANSWER_TO=$value ;;
  esac
  shift 2
done

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# Refuse empty, vague, one-liner, title-copy, or placeholder-bearing text.
check_text() {  # <label> <text>
  local label=$1 text=$2 flat lower
  flat=$(trim "$text")
  [ -n "$flat" ] || refuse "$label is empty; every brief section must say something concrete"
  lower=$(printf '%s' "$flat" | tr '[:upper:]' '[:lower:]' | sed 's/[[:punct:][:space:]]*$//')
  case "$lower" in
    tbd|todo|n/a|na|none|nothing|nil|same|ok|obvious|"see title"|"see above"|"as discussed"|"as usual"|"same as above"|"see description"|"to be decided"|"to be determined")
      refuse "$label is a vague stand-in ('$flat'); state the concrete content" ;;
  esac
  [ "$(printf '%s' "$flat" | wc -w | tr -d ' ')" -ge 4 ] \
    || refuse "$label is too short ('$flat'); write at least four words of concrete content"
  if printf '%s\n' "$text" | grep -Eq '(^|[^$])\{[A-Z][A-Z_]{2,}\}' \
    || printf '%s\n' "$text" | grep -Eiq '<(fill|todo|tbd|placeholder|insert|describe|your)[^>]*>|\[(fill|todo|tbd|placeholder|insert|describe)[^]]*\]|\btbd\b|lorem ipsum' \
    || printf '%s\n' "$text" | grep -Eq '\b(TODO|FIXME|XXX)\b|^\.\.\.$'; then
    refuse "$label still carries a placeholder; replace it with real content"
  fi
  if printf '%s\n' "$text" | grep -Eq '^## '; then
    refuse "$label has a line starting with '## ', which would split the brief; reword it"
  fi
}

[ -n "$(trim "$TITLE")" ] || refuse "--title is required"
check_text "title" "$TITLE"
[ "$(printf '%s' "$TITLE" | wc -l | tr -d ' ')" -eq 0 ] || refuse "--title must be a single line"
check_text "Captain's intent" "$INTENT"
if printf '%s\n' "$INTENT" | head -n1 | grep -Eiq '^[[:space:]]*(the )?captain[[:space:]]*[:,-]'; then
  refuse "Captain's intent opens with a Captain label; write the ask itself without speaker labels"
fi
check_text "Firstmate spec" "$SPEC"
check_text "Out of scope" "$OUT"
check_text "Definition of done" "$DOD"

for section in "$INTENT" "$SPEC" "$OUT" "$DOD"; do
  [ "$(trim "$section" | tr '[:upper:]' '[:lower:]')" != "$(trim "$TITLE" | tr '[:upper:]' '[:lower:]')" ] \
    || refuse "a section only repeats the title; add the real content"
done

[ "${#EVIDENCE[@]}" -gt 0 ] || refuse "--evidence is required: name at least one of pr:<what>, report:<what>, command:<what>"
EVIDENCE_BODY=
for entry in "${EVIDENCE[@]}"; do
  kind=${entry%%:*}
  [ "$kind" != "$entry" ] || refuse "--evidence '$entry' must look like <pr|report|command>:<what the proof shows>"
  what=$(trim "${entry#*:}")
  case "$kind" in
    pr) label='PR link' ;;
    report) label='Report path' ;;
    command) label='Command output' ;;
    *) refuse "--evidence kind '$kind' must be pr, report, or command" ;;
  esac
  check_text "Evidence required ($kind)" "$what"
  [ "$(printf '%s' "$what" | wc -l | tr -d ' ')" -eq 0 ] || refuse "--evidence $kind text must be a single line"
  EVIDENCE_BODY+="- $label: $what"$'\n'
done
EVIDENCE_BODY=${EVIDENCE_BODY%$'\n'}

case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  '') refuse "--mode is required (no-mistakes, direct-PR, or local-only); decide it explicitly for this bead" ;;
  *) refuse "--mode must be no-mistakes, direct-PR, or local-only (got '$MODE')" ;;
esac
case "$YOLO" in
  on|off) ;;
  '') refuse "--yolo is required (on or off); decide the merge posture explicitly for this bead" ;;
  *) refuse "--yolo must be on or off (got '$YOLO')" ;;
esac
[ -n "$PROJECT" ] || refuse "--project is required: the registered project the claimed work builds in"
printf '%s' "$PROJECT" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || refuse "--project '$PROJECT' is not a valid project name"
[ -n "$ANSWER_TO" ] || refuse "--answer-to is required: the id of the filing mate the result returns to"
printf '%s' "$ANSWER_TO" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || refuse "--answer-to '$ANSWER_TO' is not a valid mate id"

BODY=
add_section() {  # <heading> <text>
  BODY+="## $1"$'\n\n'"$2"$'\n\n'
}
add_section "Captain's intent" "$(trim "$INTENT")"
add_section "Firstmate spec" "$(trim "$SPEC")"
add_section "Out of scope" "$(trim "$OUT")"
add_section "Definition of done" "$(trim "$DOD")"
add_section "Evidence required" "$EVIDENCE_BODY"
add_section "Delivery mode + yolo posture" "mode: $MODE"$'\n'"yolo: $YOLO"$'\n'"project: $PROJECT"
BODY+="## Answer-to"$'\n\n'"$ANSWER_TO"$'\n'

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s' "$BODY"
  exit 0
fi

fm_workhorse_store_check || exit 1
LABELS="$FM_WORKHORSE_LABEL,${FM_BEADS_FLEET_LABEL:-fleet:firstmate}"
METADATA=$(jq -nc --arg by "$ANSWER_TO" '{filed_by: $by}')
ID=$(fm_workhorse_task create "$TITLE" --description "$BODY" --labels "$LABELS" \
  --metadata "$METADATA" --silent) || {
  echo "fm-workhorse-file: filing into $(fm_workhorse_beads_dir) failed" >&2
  exit 1
}
ID=$(trim "$ID")
fm_workhorse_valid_bead_id "$ID" || {
  echo "fm-workhorse-file: the store returned an unusable bead id '$ID'; nothing was rung" >&2
  exit 1
}
# Read the bead back from the pinned store: proof it landed where it must.
fm_workhorse_bead_json "$ID" >/dev/null || {
  echo "fm-workhorse-file: bead $ID could not be read back from the pinned task store with the $FM_WORKHORSE_LABEL label" >&2
  exit 1
}
printf '%s\n' "$ID"

"$SCRIPT_DIR/fm-workhorse-ring.sh" "$ID" >&2 || {
  echo "fm-workhorse-file: bead $ID is filed but the workhorse doorbell is unconfirmed; run bin/fm-workhorse-ring.sh $ID" >&2
  exit 4
}
