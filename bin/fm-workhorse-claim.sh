#!/usr/bin/env bash
# fm-workhorse-claim.sh - list and claim unclaimed `workhorse` beads, and turn a
# claimed bead into a worker brief.
#
# Usage: fm-workhorse-claim.sh list
#        fm-workhorse-claim.sh claim [<bead-id>] [--as <mate-id>]
#
# list prints every unclaimed (open, no assignee) bead carrying the `workhorse`
# label in the pinned task store (bin/fm-workhorse-lib.sh), oldest first, one
# `unclaimed <id> brief=<ok|incomplete> <title>` line each, or one
# "no unclaimed workhorse beads" line. `brief=incomplete` marks a bead that is
# not a full brief (for example a legacy one-line title): it can be listed but
# never claimed. The workhorse mate runs this at session start, after every
# relaunch, and on every heartbeat; it is the wake path that finds beads whose
# doorbell was missed.
#
# claim takes <bead-id>, or the oldest unclaimed bead when none is named. It
# first checks the bead is a complete brief and refuses before touching it
# otherwise, then claims it atomically with one guarded update (assignee set
# and status in_progress only while it is still open and unassigned), so two
# claimers cannot both win and the loser is told so. The assignee is --as, else
# FM_WORKHORSE_MATE, else workhorse-mate. It then scaffolds the worker brief
# with bin/fm-brief.sh for the bead's project and delivery mode and fills the
# brief's `## Captain's intent` from the bead's intent and its `## Firstmate
# spec` from the bead's spec, out of scope, definition of done, evidence
# required, and answer-to. A scaffold failure releases the claim again. FM_HOME
# must name the workhorse mate's own home (the brief lands under its data/).
# The claim output names the brief path, the proposed task id, project, mode,
# yolo posture, and answer-to for the spawn that follows; the bead id is in the
# brief so the closing step (bin/fm-workhorse-close.sh) can name it.
# Exit 2 is a refused request, 1 a store or scaffold failure, 5 a lost race.
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
  printf 'fm-workhorse-claim: %s\n' "$*" >&2
  exit 2
}

# 0 when the description holds every section and a valid delivery posture.
brief_complete() {  # <description-text>
  local desc=$1 section mode yolo project
  for section in "Captain's intent" "Firstmate spec" "Out of scope" "Definition of done" \
    "Evidence required" "Delivery mode + yolo posture" "Answer-to"; do
    [ -n "$(fm_workhorse_section "$desc" "$section")" ] || return 1
  done
  [ -n "$(fm_workhorse_evidence_kinds "$desc")" ] || return 1
  mode=$(fm_workhorse_delivery_field "$desc" mode)
  yolo=$(fm_workhorse_delivery_field "$desc" yolo)
  project=$(fm_workhorse_delivery_field "$desc" project)
  case "$mode" in no-mistakes|direct-PR|local-only) ;; *) return 1 ;; esac
  case "$yolo" in on|off) ;; *) return 1 ;; esac
  [ -n "$project" ]
}

unclaimed_json() {
  local out
  out=$(fm_workhorse_task list --label "$FM_WORKHORSE_LABEL" --status open --no-assignee --json -n 0) || {
    echo "fm-workhorse-claim: listing the pinned task store $(fm_workhorse_beads_dir) failed" >&2
    return 1
  }
  printf '%s' "$out" | jq -c --arg l "$FM_WORKHORSE_LABEL" '
    [ .[] | select(.status == "open" and ((.assignee // "") == "") and ((.labels // []) | index($l)) != null) ]
    | sort_by(.created_at)' 2>/dev/null || {
    echo "fm-workhorse-claim: the store returned an unreadable list" >&2
    return 1
  }
}

cmd_list() {
  local json count line id desc
  fm_workhorse_store_check || exit 1
  json=$(unclaimed_json) || exit 1
  count=$(printf '%s' "$json" | jq 'length')
  if [ "$count" -eq 0 ]; then
    echo "no unclaimed workhorse beads"
    return 0
  fi
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | jq -r '.id')
    desc=$(printf '%s' "$line" | jq -r '.description // ""')
    if brief_complete "$desc"; then
      printf 'unclaimed %s brief=ok %s\n' "$id" "$(printf '%s' "$line" | jq -r '.title')"
    else
      printf 'unclaimed %s brief=incomplete %s\n' "$id" "$(printf '%s' "$line" | jq -r '.title')"
    fi
  done < <(printf '%s' "$json" | jq -c '.[]')
}

release_claim() {  # <bead-id> <mate>
  fm_workhorse_task update "$1" --if-assignee "$2" --assignee '' --status open >/dev/null 2>&1
}

cmd_claim() {
  local bead='' mate=${FM_WORKHORSE_MATE:-workhorse-mate} json rec desc rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --as) [ "$#" -ge 2 ] || refuse "--as needs a mate id"; mate=$2; shift 2 ;;
      -*) refuse "unknown argument: $1" ;;
      *) [ -z "$bead" ] || refuse "only one bead id may be claimed at a time"; bead=$1; shift ;;
    esac
  done
  printf '%s' "$mate" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || refuse "--as '$mate' is not a valid mate id"
  [ -n "${FM_HOME:-}" ] || refuse "set FM_HOME to the workhorse mate's home; the brief is written under its data/"
  fm_workhorse_store_check || exit 1

  if [ -z "$bead" ]; then
    json=$(unclaimed_json) || exit 1
    bead=$(printf '%s' "$json" | jq -r '.[0].id // empty')
    [ -n "$bead" ] || { echo "no unclaimed workhorse beads"; exit 0; }
  fi
  rec=$(fm_workhorse_bead_json "$bead") || exit 2
  printf '%s' "$rec" | jq -e '.status == "open" and ((.assignee // "") == "")' >/dev/null \
    || refuse "bead $bead is not unclaimed (status $(printf '%s' "$rec" | jq -r '.status'), assignee '$(printf '%s' "$rec" | jq -r '.assignee // ""')')"
  desc=$(printf '%s' "$rec" | jq -r '.description // ""')
  brief_complete "$desc" || refuse "bead $bead is not a complete brief (a section, evidence kind, mode, yolo, or project is missing); ask the filer to re-file it through bin/fm-workhorse-file.sh"

  rc=0
  fm_workhorse_task update "$bead" --if-assignee '' --if-status open --assignee "$mate" --status in_progress >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 13 ]; then
    echo "fm-workhorse-claim: bead $bead was claimed by someone else first; nothing changed" >&2
    exit 5
  fi
  [ "$rc" -eq 0 ] || { echo "fm-workhorse-claim: claiming $bead in the pinned task store failed (exit $rc)" >&2; exit 1; }

  local mode yolo project answer_to task_id out brief tmpdir
  mode=$(fm_workhorse_delivery_field "$desc" mode)
  yolo=$(fm_workhorse_delivery_field "$desc" yolo)
  project=$(fm_workhorse_delivery_field "$desc" project)
  answer_to=$(fm_workhorse_section "$desc" "Answer-to")
  task_id="wh-$(printf '%s' "$bead" | tr '[:upper:]._' '[:lower:]--')"

  if ! out=$("$SCRIPT_DIR/fm-brief.sh" "$task_id" "$project" --mode "$mode" 2>&1); then
    release_claim "$bead" "$mate" || echo "fm-workhorse-claim: could not release the claim on $bead; release it by hand" >&2
    echo "fm-workhorse-claim: scaffolding the brief failed, claim released: $out" >&2
    exit 1
  fi
  brief=$(printf '%s\n' "$out" | sed -n 's/^scaffolded: \(.*\) (ship.*/\1/p' | head -n1)
  [ -f "$brief" ] || {
    release_claim "$bead" "$mate" || echo "fm-workhorse-claim: could not release the claim on $bead; release it by hand" >&2
    echo "fm-workhorse-claim: fm-brief did not report a brief path: $out" >&2
    exit 1
  }

  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-workhorse-claim.XXXXXX") || exit 1
  fm_workhorse_section "$desc" "Captain's intent" >"$tmpdir/intent"
  {
    fm_workhorse_section "$desc" "Firstmate spec"
    printf '\nOut of scope:\n'
    fm_workhorse_section "$desc" "Out of scope"
    printf '\nDefinition of done for this bead:\n'
    fm_workhorse_section "$desc" "Definition of done"
    printf '\nEvidence this bead requires before it can close (supply it to bin/fm-workhorse-close.sh %s):\n' "$bead"
    fm_workhorse_section "$desc" "Evidence required"
    printf '\nBead %s, delivery mode %s, merge posture yolo %s. Answer to: %s.\n' "$bead" "$mode" "$yolo" "$answer_to"
  } >"$tmpdir/spec"
  awk -v intent="$tmpdir/intent" -v spec="$tmpdir/spec" '
    function dump(path,   line) { while ((getline line < path) > 0) print line; close(path) }
    $0 == "{TASK}" { dump(intent); next }
    $0 == "{FIRSTMATE_SPEC}" { dump(spec); next }
    { print }
  ' "$brief" >"$tmpdir/brief"
  if ! cat "$tmpdir/brief" >"$brief"; then
    rm -rf "$tmpdir"
    echo "fm-workhorse-claim: filling the brief at $brief failed; the bead stays claimed by $mate" >&2
    exit 1
  fi
  rm -rf "$tmpdir"

  printf 'claimed %s as %s\n' "$bead" "$mate"
  printf 'brief: %s\n' "$brief"
  printf 'task-id: %s\n' "$task_id"
  printf 'project: %s\n' "$project"
  printf 'mode: %s\n' "$mode"
  printf 'yolo: %s\n' "$yolo"
  printf 'answer-to: %s\n' "$answer_to"
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  list) shift; [ "$#" -eq 0 ] || refuse "list takes no arguments"; cmd_list ;;
  claim) shift; cmd_claim "$@" ;;
  *) usage >&2; exit 2 ;;
esac
