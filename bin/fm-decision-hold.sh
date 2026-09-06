#!/usr/bin/env bash
# fm-decision-hold.sh - transitional compatibility shim over bin/fm-captain-hold.sh.
#
# The separate "decision" concept collapsed into the one primitive the captain
# cares about: a task held for the captain. bin/fm-captain-hold.sh owns every
# surviving behavior; this shim only maps the retired command surface onto it so
# in-flight work briefed before the collapse keeps working for one release, and
# it will be removed in the release after the collapse lands.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# When config/backlog-backend=beads, every subcommand instead uses beads-native
# primitives rather than tasks-axi's HoldKind: a labeled anchor bead carries the
# hold identity, a `task gate create --type=human` blocking that anchor is the
# active-hold state, and `task dep` edges wire routed dependent work onto that
# same gate. Resolving records the decision in the anchor's structured metadata,
# clears those dependency edges, and closes the gate and the anchor. See
# docs/decision-hold-lifecycle.md and
# .agents/skills/decision-hold-lifecycle/SKILL.md for the semantic policy.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CAPTAIN_HOLD="$SCRIPT_DIR/fm-captain-hold.sh"

beads_backend_active() {
  [ "$(fm_backlog_backend_value "$FM_HOME/config")" = beads ]
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  case "$2" in
    ''|*[!A-Za-z0-9._-]*) fail "$1 must be a non-empty privacy-safe slug: $2" ;;
  esac
}

compose() {  # <origin> <key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s' "$1" "$2"
}

task_show() {
  (cd "$FM_HOME" && tasks-axi show "$1" --full) 2>/dev/null
}

show_field() {
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

normalized_blocked_by() {
  local blocked
  blocked=$(show_field "$1" blocked_by | tr -d '[:space:]')
  blocked=${blocked#\"}
  blocked=${blocked%\"}
  [ "$blocked" != - ] || blocked=''
  printf '%s' "$blocked"
}

list_has_key() {
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

hold_label() {  # <origin-id> <decision-key>
  printf 'hold:%s\n' "$(hold_id "$1" "$2")"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ]; then
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
    esac
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'Routed identities: '*'\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

# --- Beads-native captain hold primitives -----------------------------------
# Used only when beads_backend_active. A hold's identity is the anchor bead
# carrying the unique `hold:<origin>-decision-<key>` label; the active-hold
# state is an open `task gate --type=human` blocking that anchor; resolution
# is recorded as structured metadata on the anchor, never scraped prose. The
# anchor also carries the hold reason as metadata.hold_reason at creation time
# so a structured reader (bin/fm-fleet-snapshot.sh) can surface it from the
# same `task list --json` read that finds the anchor, with no extra calls.

require_beads_cli() {
  command -v task >/dev/null 2>&1 || fail "task CLI not found"
  command -v jq >/dev/null 2>&1 || fail "jq not found"
}

beads_task() {
  task "$@"
}

beads_anchor_json() {  # <label> -> the anchor bead's JSON object, if found
  local label=$1 out
  out=$(beads_task list --label "$label" --all --json 2>/dev/null) || return 1
  out=$(printf '%s' "$out" | jq -c '.[0] // empty')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

beads_show_json() {  # <id> -> that issue's full `task show --json` array
  beads_task show "$1" --json 2>/dev/null
}

beads_open_gate_id() {  # <id> -> the id of an open human gate blocking it, if any
  local id=$1 show
  show=$(beads_show_json "$id") || return 1
  printf '%s' "$show" |
    jq -r '.[0].dependencies[]? | select(.issue_type=="gate" and .dependency_type=="blocks" and .status=="open") | .id' |
    head -1
}

beads_resolved_gate_id() {  # <id> -> the id of a resolved/closed human gate blocking it, if any
  local id=$1 show
  show=$(beads_show_json "$id") || return 1
  printf '%s' "$show" |
    jq -r '.[0].dependencies[]? | select(.issue_type=="gate" and .dependency_type=="blocks" and .status!="open") | .id' |
    head -1
}

beads_hold_durable() {  # <origin-id> <decision-key>
  local origin=$1 key=$2 id label anchor status gate
  id=$(hold_id "$origin" "$key")
  label=$(hold_label "$origin" "$key")
  if anchor=$(beads_anchor_json "$label"); then
    status=$(printf '%s' "$anchor" | jq -r '.status')
    if [ "$status" = open ]; then
      gate=$(beads_open_gate_id "$(printf '%s' "$anchor" | jq -r '.id')")
      [ -n "$gate" ] && return 0
    elif [ "$status" = closed ]; then
      printf '%s' "$anchor" |
        jq -e '(.metadata.decision_digest // "") != "" and (.metadata.routed_identities // "") != ""' \
        >/dev/null 2>&1 && return 0
    fi
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_hold_durable_dispatch() {  # <origin-id> <decision-key>
  if beads_backend_active; then
    beads_hold_durable "$1" "$2"
  else
    verify_hold_durable "$(hold_id "$1" "$2")"
  fi
}

command_hold_beads() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id label anchor status existing_title anchor_id gate notes
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  require_beads_cli
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  label=$(hold_label "$origin" "$key")
  if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
    repo=$(meta_value "$STATE/$origin.meta" project)
    repo=${repo%/}
    repo=${repo##*/}
  fi
  [ -n "$repo" ] || repo=firstmate
  validate_one_line repo "$repo"
  if anchor=$(beads_anchor_json "$label"); then
    printf '%s' "$anchor" | jq -e '.labels | index("captain-hold")' >/dev/null \
      || fail "existing backlog identity $id is not a captain hold"
    status=$(printf '%s' "$anchor" | jq -r '.status')
    [ "$status" != closed ] \
      || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    existing_title=$(printf '%s' "$anchor" | jq -r '.title')
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
    anchor_id=$(printf '%s' "$anchor" | jq -r '.id')
  else
    notes=$(printf 'Origin: %s\nDecision key: %s\nRepo: %s\nState: awaiting captain decision.' "$origin" "$key" "$repo")
    anchor_id=$(beads_task create "$title" \
      --labels "$(fm_beads_fleet_label),captain-hold,human,$label" \
      --notes "$notes" --metadata "$(jq -cn --arg r "$reason" '{hold_reason:$r}')" --json \
      | jq -r '.id') || fail "could not create captain decision item $id"
    [ -n "$anchor_id" ] && [ "$anchor_id" != null ] \
      || fail "could not create captain decision item $id"
  fi
  gate=$(beads_open_gate_id "$anchor_id")
  if [ -z "$gate" ]; then
    beads_task gate create --type=human --blocks "$anchor_id" --reason "$reason" >/dev/null \
      || fail "could not activate captain hold $id"
    gate=$(beads_open_gate_id "$anchor_id")
  fi
  [ -n "$gate" ] || fail "could not activate captain hold $id"
  printf '%s\n' "$id"
}

command_resolve_beads() {
  local origin=${1:-} key=${2:-} decision_file='' decision='' decision_digest='' routed='' routed_csv=''
  local id label anchor anchor_id status gate dep dep_show dep_status blocked
  local recorded_digest recorded_routes resolution_recorded=0 notes
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_beads_cli
  id=$(hold_id "$origin" "$key")
  label=$(hold_label "$origin" "$key")
  anchor=$(beads_anchor_json "$label") || fail "captain hold $id is absent from the beads store"
  anchor_id=$(printf '%s' "$anchor" | jq -r '.id')
  status=$(printf '%s' "$anchor" | jq -r '.status')
  recorded_digest=$(printf '%s' "$anchor" | jq -r '.metadata.decision_digest // empty')
  recorded_routes=$(printf '%s' "$anchor" | jq -r '.metadata.routed_identities // empty')

  if [ "$status" = closed ]; then
    [ -n "$recorded_digest" ] || fail "captain hold $id has no retry identity record"
    [ "$recorded_digest" = "$decision_digest" ] \
      || fail "captain hold $id records a different captain decision"
    [ "$recorded_routes" = "$routed_csv" ] \
      || fail "captain hold $id records different routed work"
    printf 'resolved: %s -> %s\n' "$id" "$routed"
    return 0
  fi

  [ "$status" = open ] || fail "captain hold $id is not actively held"
  gate=$(beads_open_gate_id "$anchor_id")
  if [ -z "$gate" ]; then
    gate=$(beads_resolved_gate_id "$anchor_id")
    [ -n "$gate" ] || fail "captain hold $id is not actively held"
    [ -n "$recorded_digest" ] || fail "captain hold $id is not actively held"
    [ "$recorded_digest" = "$decision_digest" ] \
      || fail "captain hold $id records a different captain decision"
    [ "$recorded_routes" = "$routed_csv" ] \
      || fail "captain hold $id records different routed work"
    beads_task close "$anchor_id" --reason "captain decision recorded" >/dev/null \
      || fail "could not close resolved captain hold $id"
    beads_task dep remove "$anchor_id" "$gate" >/dev/null \
      || fail "could not clear the captain hold's own dependency edge"
    anchor=$(beads_anchor_json "$label") || fail "captain hold $id did not retain its durable resolution record"
    status=$(printf '%s' "$anchor" | jq -r '.status')
    [ "$status" = closed ] || fail "captain hold $id did not retain its durable resolution record"
    printf 'resolved: %s -> %s\n' "$id" "$routed"
    return 0
  fi

  if [ -n "$recorded_digest" ]; then
    [ "$recorded_digest" = "$decision_digest" ] \
      || fail "captain hold $id records a different captain decision"
    [ "$recorded_routes" = "$routed_csv" ] \
      || fail "captain hold $id records different routed work"
    resolution_recorded=1
  fi

  for dep in $routed; do
    dep_show=$(beads_show_json "$dep") || fail "routed task $dep does not exist in the active home"
    dep_status=$(printf '%s' "$dep_show" | jq -r '.[0].status')
    [ "$dep_status" != closed ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    blocked=$(printf '%s' "$dep_show" |
      jq -r --arg gate "$gate" '[.[0].dependencies[]? | select(.id==$gate and .dependency_type=="blocks")] | length')
    if [ "$blocked" = 0 ]; then
      [ "$resolution_recorded" = 1 ] \
        || fail "routed task $dep is not durably blocked by $id"
    fi
  done

  notes=$(printf 'Captain decision:\n%s\n\nRouted work:\n' "$decision")
  for dep in $routed; do
    notes="${notes}- ${dep}"$'\n'
  done
  beads_task update "$anchor_id" \
    --set-metadata "decision_digest=$decision_digest" \
    --set-metadata "routed_identities=$routed_csv" \
    --append-notes "$notes" >/dev/null \
    || fail "could not record the captain decision on $id"

  for dep in $routed; do
    beads_task dep remove "$dep" "$gate" >/dev/null \
      || fail "could not route the recorded decision to $dep"
  done

  beads_task gate resolve "$gate" --reason "captain decision recorded" >/dev/null \
    || fail "could not close resolved captain hold $id"
  beads_task close "$anchor_id" --reason "captain decision recorded" >/dev/null \
    || fail "could not close resolved captain hold $id"
  beads_task dep remove "$anchor_id" "$gate" >/dev/null \
    || fail "could not clear the captain hold's own dependency edge"

  anchor=$(beads_anchor_json "$label") || fail "captain hold $id did not retain its durable resolution record"
  status=$(printf '%s' "$anchor" | jq -r '.status')
  [ "$status" = closed ] || fail "captain hold $id did not retain its durable resolution record"

  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  if beads_backend_active; then
    command_hold_beads "$@"
    return
  fi
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  if beads_backend_active; then
    require_beads_cli
  else
    require_tasks_axi
  fi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable_dispatch "$origin" "$key"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi
    fm_lock_release "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=0

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  if beads_backend_active; then
    require_beads_cli
  else
    require_tasks_axi
  fi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable_dispatch "$origin" "$key"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable_dispatch "$origin" "$key"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  if beads_backend_active; then
    command_resolve_beads "$@"
    return
  fi
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  id=$(compose "$origin" "$key")
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  [ -n "$routed" ] || fail "at least one --routed-to task is required; use answer when the captain's answer routes no work"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s' "$routed" | tr ' ' ',')
  decision_text=$(cat "$decision_file")
  [ -n "$decision_text" ] || fail "decision file must not be empty"
  decision_digest=$(sha256_text "$decision_text")
  hold_show=$(task_show "$id") || fail "captain decision $id does not exist in the active home"
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*"Routed identities: "*)
      recorded_digest=$(recorded_field "$hold_body" "Decision digest" || true)
      recorded_routes=$(recorded_field "$hold_body" "Routed identities" || true)
      [ "$recorded_digest" = "$decision_digest" ] \
        || fail "captain decision $id records a different captain decision"
      [ "$recorded_routes" = "$routed_csv" ] \
        || fail "captain decision $id records different routed work"
      resolution_recorded=1
      legacy_replay=1
      ;;
    *"Resolution recorded by fm-captain-hold."*)
      resolution_recorded=1
      ;;
  esac
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]' | sed 's/^"//;s/"$//')
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-decision-hold-resolve.XXXXXX") \
    || fail "cannot stage the captain decision"
  if ! { cat "$decision_file" && printf '\n\nRouted work:\n' \
    && printf '%s\n' "$routed" | tr ' ' '\n' | sed 's/^/- /'; } > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the captain decision for $id"
  fi
  answer_file=$tmp
  [ "$legacy_replay" = 0 ] || answer_file=$decision_file
  if ! "$CAPTAIN_HOLD" answer "$id" --decision-file "$answer_file"; then
    rm -f -- "$tmp"
    exit 1
  fi
  rm -f -- "$tmp"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]' | sed 's/^"//;s/"$//')
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

command_complete() {
  local origin=${1:-} mapped=''
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    exec "$CAPTAIN_HOLD" complete "$origin" --none
  fi
  for key in "$@"; do
    [ "$key" != --none ] || fail "--none cannot be combined with decision keys"
    mapped="${mapped}${mapped:+ }$(compose "$origin" "$key")"
  done
  # shellcheck disable=SC2086  # mapped is a validated space-separated slug list.
  exec "$CAPTAIN_HOLD" complete "$origin" $mapped
}

command_close() {  # <origin> <key> <flag-args...>
  local origin=${1:-} key=${2:-} id
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  id=$(compose "$origin" "$key")
  shift 2
  local decision_file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  exec "$CAPTAIN_HOLD" answer "$id" --decision-file "$decision_file"
}

command_hold() {
  local origin=${1:-} key=${2:-} id
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  id=$(compose "$origin" "$key")
  shift 2
  exec "$CAPTAIN_HOLD" hold "$id" --origin "$origin" "$@"
}

case "${1:-}" in
  id) shift; [ "$#" -eq 2 ] || { usage >&2; exit 2; }; compose "$1" "$2"; printf '\n' ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; exec "$CAPTAIN_HOLD" verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  answer|decline|repair) shift; command_close "$@" ;;
  answers) shift; exec "$CAPTAIN_HOLD" answers "$@" ;;
  bind) shift; exec "$CAPTAIN_HOLD" bind "$@" ;;
  unbind) shift; exec "$CAPTAIN_HOLD" unbind "$@" ;;
  binding) shift; exec "$CAPTAIN_HOLD" binding "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
