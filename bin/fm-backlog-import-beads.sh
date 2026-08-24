#!/usr/bin/env bash
# fm-backlog-import-beads.sh - one-time forward importer from data/backlog.md to
# the beads federated task store (beads-authority migration Stage 6; see
# data/beads-authority-migration-scout/report.md section 4 "Stage 6").
#
# It walks the active home's data/backlog.md `## In flight` and `## Queued`
# sections and creates one bead per item in the active beads store, so a home
# can flip config/backlog-backend to beads without losing its live queue. The
# `## Done` section is historical record and is never migrated.
#
# Mapping:
#   - `## In flight` item  -> bead status in_progress
#   - `## Queued` item     -> bead status open (bd's default)
#   - `(priority: N)`      -> bead priority N (beads' 0-4 scale, passed through)
#   - a captain-held decision thread (`(hold-kind: captain)` or `(kind: captain)`)
#     -> the Stage 4 beads-native mechanism via `bin/fm-decision-hold.sh hold`
#        (a labeled anchor bead plus a `task gate create --type=human`), NOT a
#        status hack. The backlog id must follow the `<origin>-decision-<key>`
#        convention that fm-decision-hold.sh owns, and the origin must be present
#        in the active home (its state/<origin>.meta or data/<origin>/report.md);
#        otherwise the item fails closed rather than migrating incorrectly.
#   - `blocked-by: <id>` (one or more) -> a real beads dependency edge, wired in
#     a second pass after every bead exists so a blocker defined later in the
#     file still resolves (`task dep <blocker-bead> --blocks <item-bead>`). The
#     reference is kept in the description too, so nothing is dropped.
#   - a clearly-dated queued time gate `(since <YYYY-MM-DD>)` -> the bead's defer
#     date (`task update --defer`), so the bead stays hidden from `task ready`
#     until then. beads' own semantics handle either meaning: a past date leaves
#     the bead ready now (age marker), a future date withholds it (time gate).
#   - the item's FIRST line, cut at its first trailing metadata marker, inline
#     note, or URL -> the bead's single-line title; an indented continuation line
#     never reaches the title field (extract_title below owns the exact cut).
#   - the full item text (title-line metadata plus indented continuation lines)
#     -> the bead's description, so nothing is dropped.
#
# Every created bead carries the firstmate-fleet label (fm_beads_fleet_label)
# so `task list --label <fleet>` scopes to firstmate's fleet, and the
# home-scoped task:<scope>:<id> idempotency label that fm_beads_resolve_or_create
# already uses, so re-running the importer resolves the existing bead instead of
# duplicating it. Captain holds are idempotent through fm-decision-hold.sh's own
# `hold:<id>` anchor lookup.
#
# Modes:
#   (default)   Dry run. Prints what it WOULD create and whether each item
#               already exists in the store, and makes no writes.
#   --apply     Perform the writes. Idempotent: safe to re-run after a partial
#               failure; already-imported items are resolved, not duplicated.
#
# The importer fails closed if the beads CLI or store is unreachable, and aborts
# loudly on any write failure rather than migrating part of the backlog
# silently. A partial run leaves already-created beads in place; fix the cause
# and re-run --apply to converge.
#
# This importer deliberately does NOT flip config/backlog-backend; that file is
# local and per-home. The intended operator sequence is:
#   1. fm-backlog-import-beads.sh                 # dry run, review the plan
#   2. fm-backlog-import-beads.sh --apply         # perform the import
#   3. printf 'beads\n' > "$FM_HOME/config/backlog-backend"   # flip the backend
# See docs/configuration.md "Backlog backend" for the surrounding contract.
#
# Usage:
#   fm-backlog-import-beads.sh [--backlog <path>] [--apply]
#   fm-backlog-import-beads.sh --help
#
#   --backlog <path>  Read this backlog file instead of $FM_HOME/data/backlog.md
#                     (used by tests against a fixture; never touch a live store).
#   --apply           Perform the import. Without it the importer only previews.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-backlog-import-beads: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'fm-backlog-import-beads: %s\n' "$*" >&2
}

APPLY=0
BACKLOG=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --backlog) shift; BACKLOG=${1:-} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$BACKLOG" ] || BACKLOG="$DATA/backlog.md"
[ -f "$BACKLOG" ] || fail "backlog file not found: $BACKLOG"

command -v task >/dev/null 2>&1 || fail "the beads task CLI is required but was not found on PATH"
command -v jq >/dev/null 2>&1 || fail "jq is required but was not found on PATH"
# Fail closed on an unreachable or broken store: never partially migrate against
# a store we cannot read, and never silently create in the wrong place.
task list --limit 1 >/dev/null 2>&1 || fail "beads task store is unreachable or broken (cannot run 'task list')"

FLEET_LABEL=$(fm_beads_fleet_label)

IMPORT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-backlog-import.XXXXXX") || fail "could not create a temp dir"
cleanup() { rm -rf "$IMPORT_TMP"; }
trap cleanup EXIT

# extract_title <remainder> - the human-readable title is the FIRST line's text
# up to the first trailing metadata marker, inline note, or URL. The full
# remainder is kept verbatim as the bead description, so this only shapes the
# short title field.
#
# First line only, and exactly one output line: an item body is multi-line (the
# title line plus its indented continuation lines) while a bead title is not.
# Without the trailing `exit` the awk block runs once per body line and prints
# one cut line PER line, so the caller's command substitution captures a
# multi-line string as the "title" - which `task create` then rejects, aborting
# the whole import on the first item that actually needs creating.
extract_title() {
  printf '%s' "$1" | awk '
    {
      line = $0
      # Cut at the earliest trailing metadata marker, inline note, or URL, using
      # fixed-string search so no marker is interpreted as a regex.
      n = split(" (repo:\n (kind:\n (priority:\n (since \n (hold:\n (hold-kind:\n blocked-by:\n http", markers, "\n")
      res = length(line) + 1
      for (i = 1; i <= n; i++) {
        where = index(line, markers[i])
        if (where > 0 && where < res) res = where
      }
      title = substr(line, 1, res - 1)
      sub(/[[:space:]]+$/, "", title)
      print title
      exit
    }'
}

# resolve_existing_bead <task-id> - echo the bead id already carrying the
# home-scoped idempotency label, or nothing. Read-only. Matches
# fm_beads_resolve_or_create's own lookup (fm_beads_lookup: scoped label first,
# then an owned legacy task:<id> fallback) so this report's "(exists)"
# annotation and the blocked-by dependency edges name the bead the apply path
# resolves to.
resolve_existing_bead() {
  fm_beads_lookup "$1" || true
}

# beads_create_failure_reason <task-id> <title> - a one-line, actionable reason a
# bead create was refused, for the abort message below.
#
# fm_beads_resolve_or_create fails open by design (see its contract in
# bin/fm-tasks-axi-lib.sh): it discards the CLI's stderr and returns 1 with no
# diagnostic, which is right for dispatch but leaves this importer's fail-closed
# abort unexplained - a rejected create used to read only as "could not resolve
# or create a bead for <id>", which took a shell trace to attribute. This
# reconstructs the distinguishing evidence AFTER the fact with read-only probes
# plus the exact rejected input, so it explains the write without re-attempting
# it. The three causes it separates need opposite responses: an unreachable
# store is retried, a create that landed without returning its id converges on
# re-run, and a refused create is a bad field on this item.
beads_create_failure_reason() {
  local id=$1 title=$2 lines chars shown existing
  if ! task list --limit 1 >/dev/null 2>&1; then
    printf 'the beads store went unreachable mid-import'
    return 0
  fi
  existing=$(resolve_existing_bead "$id")
  if [ -n "$existing" ]; then
    printf 'the store is reachable and bead %s now carries the idempotency label for task %s, so the create landed without returning its id; re-run --apply to converge' \
      "$existing" "$id"
    return 0
  fi
  lines=$(printf '%s\n' "$title" | wc -l | tr -d ' ')
  chars=${#title}
  # Render the rejected title on one line so the abort stays greppable: an
  # embedded newline is the failure this guard was written for, and printing it
  # raw would hide it in the very message meant to expose it.
  shown=${title//$'\n'/\\n}
  [ "${#shown}" -le 200 ] || shown="${shown:0:200}..."
  printf "the store is reachable and no bead carries the idempotency label for task %s, so 'task create' itself refused this title (%s line(s), %s chars): '%s'" \
    "$id" "$lines" "$chars" "$shown"
}

# resolve_existing_hold_anchor <hold-id> - echo the anchor bead id already
# carrying the hold:<hold-id> label, or nothing. Read-only.
resolve_existing_hold_anchor() {
  local existing
  existing=$(task list --label "hold:$1" --all --limit 1 --json 2>/dev/null) || existing=
  printf '%s' "$existing" | jq -r 'if type=="array" and length>0 then .[0].id else empty end' 2>/dev/null || true
}

# run_decision_hold_beads <args...> - invoke fm-decision-hold.sh forced onto its
# beads-native path (config/backlog-backend=beads) while keeping the active home's
# real state/ and data/ so its origin-existence check reads the true home. This
# lets the importer reuse the Stage 4 mechanism even before the home's own
# backend file has been flipped.
run_decision_hold_beads() {
  local force_home="$IMPORT_TMP/dh-home"
  mkdir -p "$force_home/config"
  printf 'beads\n' > "$force_home/config/backlog-backend"
  FM_HOME="$force_home" \
    FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_BEADS_FLEET_LABEL="$FLEET_LABEL" \
    "$SCRIPT_DIR/fm-decision-hold.sh" "$@"
}

# open_human_gate_count <bead-id> - echo how many open human gates already block
# this bead. Lets the direct-gate captain-hold path stay idempotent on re-run.
open_human_gate_count() {
  task show "$1" --json 2>/dev/null | jq '
    if type=="array" and length>0
    then [.[0].dependencies[]? | select(.issue_type=="gate" and .dependency_type=="blocks" and .status=="open")] | length
    else 0 end' 2>/dev/null || printf '0'
}

# resolved_human_gate_count <bead-id> - echo how many human gates that once
# blocked this bead have since been RESOLVED (closed). A resolved gate stays
# listed in the bead's dependencies with status other than "open", so a re-run
# can tell "the captain already answered this" apart from "no gate was ever
# added" and avoid resurrecting a decision the captain has already made.
resolved_human_gate_count() {
  task show "$1" --json 2>/dev/null | jq '
    if type=="array" and length>0
    then [.[0].dependencies[]? | select(.issue_type=="gate" and .dependency_type=="blocks" and .status!="open")] | length
    else 0 end' 2>/dev/null || printf '0'
}

# ensure_human_gate <bead-id> <reason> - attach a beads-native human gate that
# blocks this bead, unless one already does. A captain-held backlog item that is
# not a decision-hold identity has no separate origin/anchor, so the item's own
# bead carries the gate directly (the same `task gate --type=human` primitive
# fm-decision-hold.sh uses for anchored decision holds). Idempotent, and it never
# re-adds a gate the captain has already resolved: it adds one only when NEITHER
# an open gate is still withholding the bead NOR a resolved one records that the
# captain already answered.
ensure_human_gate() {
  local bead=$1 reason=$2 open resolved
  open=$(open_human_gate_count "$bead")
  resolved=$(resolved_human_gate_count "$bead")
  if [ "$open" -ge 1 ] || [ "$resolved" -ge 1 ]; then
    return 1
  fi
  task gate create --type=human --blocks "$bead" --reason "$reason" >/dev/null \
    || fail "could not attach a human gate to captain-held bead $bead"
  return 0
}

# dependency_exists <blocked-bead> <blocker-bead> - true if a blocks-dependency
# edge from blocker to blocked already exists (the blocker appears among the
# blocked bead's dependencies). Read-only; keeps the pass-2 edge wiring
# idempotent across re-runs.
dependency_exists() {
  local blocked=$1 blocker=$2 hit
  hit=$(task show "$blocked" --json 2>/dev/null | jq -r --arg b "$blocker" '
    if type=="array" and length>0
    then ([.[0].dependencies[]? | select(.dependency_type=="blocks" and .id==$b)] | length)
    else 0 end' 2>/dev/null) || hit=0
  [ "${hit:-0}" -ge 1 ]
}

# apply_common_fields <bead-id> <status> <priority> <defer> <desc-file> - set the
# bead's status, priority, defer date, and verbatim description. Idempotent (all
# replacements). An empty field is left untouched; in particular an empty defer
# never touches the bead's defer date, so an item with no time gate stays
# ready-now while a dated gate keeps the bead hidden from `task ready` until then.
apply_common_fields() {
  local id=$1 status=$2 priority=$3 defer=$4 desc_file=$5
  if [ -n "$status" ]; then
    task update "$id" --status "$status" >/dev/null \
      || fail "could not set status $status on bead $id"
  fi
  if [ -n "$priority" ]; then
    task update "$id" --priority "$priority" >/dev/null \
      || fail "could not set priority $priority on bead $id"
  fi
  if [ -n "$defer" ]; then
    task update "$id" --defer "$defer" >/dev/null \
      || fail "could not set defer date $defer on bead $id"
  fi
  task update "$id" --body-file "$desc_file" >/dev/null \
    || fail "could not set description on bead $id"
}

# Parse the backlog into per-item work files under $IMPORT_TMP. Bash tracks the
# current section and accumulates each item's title line plus indented
# continuation lines, so the multi-line body survives intact.
section=
count=0
flush_item() {
  [ -n "${cur_id:-}" ] || return 0
  count=$((count + 1))
  printf '%s\n' "$cur_status" > "$IMPORT_TMP/item.$count.status"
  printf '%s\n' "$cur_id" > "$IMPORT_TMP/item.$count.id"
  printf '%s' "$cur_body" > "$IMPORT_TMP/item.$count.body"
  cur_id=
  cur_body=
  cur_status=
}

cur_id=
cur_body=
cur_status=
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '## In flight') flush_item; section=in_progress; continue ;;
    '## Queued') flush_item; section=open; continue ;;
    '## Done') flush_item; section=skip; continue ;;
    '## '*) flush_item; section=other; continue ;;
  esac
  case "$section" in
    in_progress|open) ;;
    *) continue ;;
  esac
  case "$line" in
    '- ['*']'*)
      flush_item
      cur_status=$section
      # Strip the "- [ ] " / "- [x] " checkbox prefix, then split id from the rest.
      rest=${line#- \[}
      rest=${rest#*\] }
      cur_id=${rest%%[[:space:]]*}
      # The body is everything after "<id> - " (the verbatim remainder).
      cur_body=${rest#"$cur_id"}
      cur_body=${cur_body# - }
      ;;
    '  '*|$'\t'*)
      # Indented continuation line: part of the current item body.
      [ -n "$cur_id" ] && cur_body="$cur_body"$'\n'"$line"
      ;;
    *) : ;;
  esac
done < "$BACKLOG"
flush_item

if [ "$count" -eq 0 ]; then
  printf 'No In-flight or Queued items found in %s; nothing to import.\n' "$BACKLOG"
  exit 0
fi

imported=0
skipped=0
inflight=0
queued=0
captain=0

printf '%s beads import of %s (fleet label: %s)\n' \
  "$( [ "$APPLY" -eq 1 ] && echo APPLYING || echo 'DRY RUN -' )" "$BACKLOG" "$FLEET_LABEL"

i=0
while [ "$i" -lt "$count" ]; do
  i=$((i + 1))
  status=$(cat "$IMPORT_TMP/item.$i.status")
  id=$(cat "$IMPORT_TMP/item.$i.id")
  body=$(cat "$IMPORT_TMP/item.$i.body")
  title=$(extract_title "$body")
  [ -n "$title" ] || title="$id"
  priority=$(printf '%s' "$body" | sed -n 's/.*(priority:[[:space:]]*\([0-9][0-9]*\)).*/\1/p' | head -1)
  is_captain=0
  case "$body" in
    *'(hold-kind: captain)'*|*'(kind: captain)'*) is_captain=1 ;;
  esac
  if [ -n "$priority" ]; then
    case "$priority" in
      0|1|2|3|4) ;;
      *) warn "item $id: priority '$priority' is outside beads' 0-4 range; leaving default"; priority= ;;
    esac
  fi

  # A queued time gate is the item's `(since <date>)` marker: it becomes the
  # bead's defer date so the bead stays hidden from `task ready` until then. Only
  # a clearly-dated gate (YYYY-MM-DD) is parsed; anything else is left ungated so
  # an item without a real date is never guessed at. beads' own defer semantics
  # then do the right thing for either meaning: a past date leaves the bead ready
  # now (age marker), a future date withholds it (time gate).
  defer=$(printf '%s' "$body" | sed -n 's/.*(since[[:space:]]\{1,\}\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)).*/\1/p' | head -1)

  # blocked-by references are wired into real bead dependency edges in a second
  # pass (below), after every bead exists, so a blocker defined later in the file
  # still resolves. Record this item's blocked-by targets now; the verbatim body
  # keeps the text too, so nothing is dropped from the description.
  printf '%s' "$body" | grep -oE 'blocked-by:[[:space:]]+[^[:space:])]+' \
    | sed 's/blocked-by:[[:space:]]*//' > "$IMPORT_TMP/item.$i.blockedby" || true

  if [ "$status" = in_progress ]; then inflight=$((inflight + 1)); else queued=$((queued + 1)); fi

  # A captain-held thread parsed from the backlog becomes a beads-native human
  # gate, never a status hack. Two shapes exist. A decision-hold identity
  # (<origin>-decision-<key>) is owned by fm-decision-hold.sh, so it is
  # reconstructed through that Stage 4 owner: a labeled anchor plus a
  # `task gate create --type=human`, recognizable to the rest of the decision
  # machinery. Any other captain-gated work thread has no separate origin, so its
  # own item bead carries the human gate directly.
  if [ "$is_captain" -eq 1 ]; then
    captain=$((captain + 1))
    reason=$(printf '%s' "$body" | sed -n 's/.*(hold:[[:space:]]*\(.*\))[[:space:]]*(hold-kind:.*/\1/p' | head -1)
    [ -n "$reason" ] || reason=$(printf '%s' "$body" | sed -n 's/.*(hold:[[:space:]]*\(.*\))[[:space:]]*$/\1/p' | head -1)
    [ -n "$reason" ] || reason="$title"
    case "$id" in
      *-decision-*)
        # Split on the FIRST "-decision-", the exact inverse of the identity
        # fm-decision-hold.sh's hold_id() composes as <origin>-decision-<key>.
        # A decision KEY may itself contain "decision-" (a hold about decision
        # holds), so anchoring on the last occurrence instead silently shifts the
        # boundary: the id still round-trips, but the origin it checks for
        # existence does not exist, and the item fails closed against a home that
        # is in fact holding the real origin.
        origin=${id%%-decision-*}
        key=${id#*-decision-}
        anchor=$(resolve_existing_hold_anchor "$id")
        if [ "$APPLY" -eq 0 ]; then
          printf '  captain-hold  %-40s (decision-hold origin=%s key=%s)%s\n' \
            "$id" "$origin" "$key" "$( [ -n "$anchor" ] && echo ' (exists)' )"
          continue
        fi
        if [ -z "$anchor" ]; then
          run_decision_hold_beads hold "$origin" "$key" \
            --title "$title" --reason "$reason" >/dev/null \
            || fail "could not create captain hold for $id (is origin '$origin' present in this home?)"
          anchor=$(resolve_existing_hold_anchor "$id")
          [ -n "$anchor" ] || fail "captain hold $id was not created in the store"
          imported=$((imported + 1))
        else
          skipped=$((skipped + 1))
        fi
        # Carry priority and the verbatim body onto the anchor; the hold's own
        # state is the open anchor plus its human gate, so status is left as
        # fm-decision-hold.sh set it rather than forced.
        printf '%s' "$body" > "$IMPORT_TMP/desc.$i"
        apply_common_fields "$anchor" "" "$priority" "$defer" "$IMPORT_TMP/desc.$i"
        ;;
      *)
        existing=$(resolve_existing_bead "$id")
        if [ "$APPLY" -eq 0 ]; then
          printf '  captain-hold  %-40s (gated work item)%s%s\n' \
            "$id" "$( [ -n "$defer" ] && echo " defer=$defer" )" \
            "$( [ -n "$existing" ] && echo ' (exists)' )"
          continue
        fi
        bead=$(fm_beads_resolve_or_create "$id" "$title") \
          || fail "the beads CLI rejected the bead create for $id: $(beads_create_failure_reason "$id" "$title")"
        if [ -n "$existing" ]; then skipped=$((skipped + 1)); else imported=$((imported + 1)); fi
        printf '%s' "$body" > "$IMPORT_TMP/desc.$i"
        # A gated work item keeps its section status so it is visible; the human
        # gate is what withholds it from `task ready` until the captain resolves.
        apply_common_fields "$bead" "$status" "$priority" "$defer" "$IMPORT_TMP/desc.$i"
        ensure_human_gate "$bead" "$reason" || true
        ;;
    esac
    continue
  fi

  existing=$(resolve_existing_bead "$id")
  if [ "$APPLY" -eq 0 ]; then
    printf '  %-13s %-40s priority=%s%s%s\n' \
      "$status" "$id" "${priority:-default}" \
      "$( [ -n "$defer" ] && echo " defer=$defer" )" \
      "$( [ -n "$existing" ] && echo ' (exists)' )"
    continue
  fi

  bead=$(fm_beads_resolve_or_create "$id" "$title") \
    || fail "the beads CLI rejected the bead create for $id: $(beads_create_failure_reason "$id" "$title")"
  if [ -n "$existing" ]; then skipped=$((skipped + 1)); else imported=$((imported + 1)); fi
  printf '%s' "$body" > "$IMPORT_TMP/desc.$i"
  apply_common_fields "$bead" "$status" "$priority" "$defer" "$IMPORT_TMP/desc.$i"
done

# target_imported <task-id> - true if some parsed item carries that backlog id,
# i.e. a blocked-by target is (or will be) imported by this run. Used only to
# annotate the dry-run report; the apply path resolves the real bead instead.
target_imported() {
  local want=$1 k=0
  while [ "$k" -lt "$count" ]; do
    k=$((k + 1))
    [ "$(cat "$IMPORT_TMP/item.$k.id")" = "$want" ] && return 0
  done
  return 1
}

# Pass 2: wire each item's blocked-by references into real bead dependency edges.
# Every bead exists now (pass 1 created/resolved them all), so a blocker defined
# later in the file resolves here. `blocked-by: X` means X blocks this item, so
# the edge is `task dep <X-bead> --blocks <item-bead>`. Idempotent: an edge that
# already exists is not re-added, and the dry run only reports what it would add.
edges_added=0
edges_planned=0
i=0
while [ "$i" -lt "$count" ]; do
  i=$((i + 1))
  [ -s "$IMPORT_TMP/item.$i.blockedby" ] || continue
  dep_id=$(cat "$IMPORT_TMP/item.$i.id")
  while IFS= read -r target || [ -n "$target" ]; do
    [ -n "$target" ] || continue
    if [ "$APPLY" -eq 0 ]; then
      edges_planned=$((edges_planned + 1))
      if [ -n "$(resolve_existing_bead "$target")" ]; then
        note=' (blocker exists)'
      elif target_imported "$target"; then
        note=
      else
        note=' (blocker not found in this import)'
      fi
      printf '  dep           %-40s blocked-by %s%s\n' "$dep_id" "$target" "$note"
      continue
    fi
    item_bead=$(resolve_existing_bead "$dep_id")
    if [ -z "$item_bead" ]; then
      warn "item $dep_id: cannot wire blocked-by (its bead was not found)"
      continue
    fi
    blocker_bead=$(resolve_existing_bead "$target")
    if [ -z "$blocker_bead" ]; then
      warn "item $dep_id: blocked-by target '$target' has no imported bead; skipping that edge"
      continue
    fi
    if dependency_exists "$item_bead" "$blocker_bead"; then
      continue
    fi
    task dep "$blocker_bead" --blocks "$item_bead" >/dev/null \
      || fail "could not add dependency edge: $blocker_bead blocks $item_bead"
    edges_added=$((edges_added + 1))
  done < "$IMPORT_TMP/item.$i.blockedby"
done

if [ "$APPLY" -eq 0 ]; then
  printf 'DRY RUN complete: %d item(s) (%d in-flight, %d queued, %d captain-hold, %d dependency edge(s)). Re-run with --apply to import.\n' \
    "$count" "$inflight" "$queued" "$captain" "$edges_planned"
else
  printf 'Import complete: %d created, %d already present (%d in-flight, %d queued, %d captain-hold, %d dependency edge(s) added).\n' \
    "$imported" "$skipped" "$inflight" "$queued" "$captain" "$edges_added"
  printf 'Next: review with "task list --label %s", then set config/backlog-backend to beads.\n' "$FLEET_LABEL"
fi
