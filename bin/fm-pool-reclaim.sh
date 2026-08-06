#!/usr/bin/env bash
# fm-pool-reclaim.sh - reclaim treehouse pool slots that no live task owns.
#
# Why this exists: a treehouse pool only shrinks. `treehouse prune` skips any
# worktree with uncommitted changes, and a `--lease` is durable by contract -
# never handed out again and never pruned, even with nothing running inside it,
# until an explicit `treehouse return`. So every crew endpoint that dies without
# reaching bin/fm-teardown.sh (killed window, lost machine, context blowout)
# leaks its slot permanently. Slots accumulate until `treehouse get` has nothing
# to hand out and bin/fm-spawn.sh fails with "treehouse get did not enter a
# worktree within 60s".
#
# Two leak shapes are reclaimable without judgment, and this script reclaims
# only those two:
#
#   stale lease   status=leased, zero processes, leased longer ago than the
#                 staleness threshold. Returned with `--if-lease-id`, so a lease
#                 re-acquired between the status read and the return is refused
#                 by treehouse rather than stolen.
#   spent slot    status=dirty, unleased, zero processes, and every dirty path
#                 is one firstmate itself wrote (the per-spawn hook droppings in
#                 DROPPINGS below, which fm-teardown.sh removes). Such a slot
#                 holds no work: the dirt IS the removal of our own hook file,
#                 which reads as an uncommitted deletion whenever the path is
#                 tracked at the worktree's HEAD.
#
# Everything else is left alone and reported: a worktree with any dirty path
# outside DROPPINGS may hold unlanded work, and reclaiming it would run
# `treehouse return --force`, which resets. Triage those by hand.
#
# Fail-open by design, matching bin/fm-staleness-file.sh: this runs as a
# best-effort pre-flight from bin/fm-spawn.sh, so a missing treehouse, an
# unparseable status, or a refused return warns on stderr and still exits 0. A
# reclaim problem must never be the reason a spawn fails.
#
# Usage: fm-pool-reclaim.sh [--project <dir>] [--yes] [--only-if-exhausted]
#                           [--stale-lease-secs <n>]
#   --project <dir>          Directory whose pool to sweep (default: cwd).
#                            treehouse resolves the pool from this directory.
#   --yes                    Perform the returns. Without it this is a dry run
#                            that prints exactly what it would reclaim.
#   --only-if-exhausted      Do nothing unless the pool has no available slot.
#                            The spawn pre-flight in bin/fm-spawn.sh uses this so
#                            an ordinary spawn with a slot free pays no sweep.
#   --stale-lease-secs <n>   Age past which a process-free lease counts as
#                            abandoned (default: $FM_POOL_STALE_LEASE_SECS, else
#                            7200). Guards the window between `treehouse get
#                            --lease` and the leaseholder's first process.
set -u

PROJECT=$PWD
APPLY=0
ONLY_IF_EXHAUSTED=0
STALE_LEASE_SECS=${FM_POOL_STALE_LEASE_SECS:-7200}

# Per-spawn hook droppings firstmate writes into a pool worktree and
# fm-teardown.sh removes. Kept in step with the `exclude_path` calls in
# bin/fm-spawn.sh and the `rm -f "$WT/..."` lines in bin/fm-teardown.sh.
DROPPINGS='
.claude/settings.local.json
.opencode/plugins/fm-turn-end.js
.opencode/plugins/fm-busy-state.js
.fm-grok-turnend
.fm-kimi-turnend
'

warn() { printf 'fm-pool-reclaim: %s\n' "$1" >&2; }
say() { printf 'fm-pool-reclaim: %s\n' "$1"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] || { warn 'usage: --project needs a directory'; exit 2; }
      PROJECT=$2
      shift 2
      ;;
    --yes)
      APPLY=1
      shift
      ;;
    --only-if-exhausted)
      ONLY_IF_EXHAUSTED=1
      shift
      ;;
    --stale-lease-secs)
      [ "$#" -ge 2 ] || { warn 'usage: --stale-lease-secs needs a number'; exit 2; }
      STALE_LEASE_SECS=$2
      shift 2
      ;;
    -h|--help)
      # The header comment above is the help text; print it up to `set -u` so
      # the two can never drift.
      awk 'NR==1 {next} /^set -u$/ {exit} {sub(/^# ?/, ""); print}' "$0"
      exit 0
      ;;
    *)
      warn "unknown argument: $1"
      exit 2
      ;;
  esac
done

case "$STALE_LEASE_SECS" in
  ''|*[!0-9]*)
    warn "invalid --stale-lease-secs '$STALE_LEASE_SECS', using 7200"
    STALE_LEASE_SECS=7200
    ;;
esac

if ! command -v treehouse >/dev/null 2>&1; then
  warn 'treehouse not found on PATH, nothing to reclaim'
  exit 0
fi
if [ ! -d "$PROJECT" ]; then
  warn "project directory not found: $PROJECT"
  exit 0
fi

STATUS_JSON=$( (cd "$PROJECT" && treehouse status --json) 2>/dev/null ) || {
  warn "treehouse status failed for $PROJECT, nothing to reclaim"
  exit 0
}
[ -n "$STATUS_JSON" ] || {
  warn "treehouse status returned nothing for $PROJECT"
  exit 0
}

# Flatten the pool into one record per worktree, fields separated by US (0x1f):
#   <status> <US> <path> <US> <lease_id> <US> <lease_holder> <US> <procs> <US> <lease_age_secs>
# Not tab-separated: bash's `read` treats tab as IFS whitespace and collapses
# runs of it, so an unleased worktree's two empty lease fields would silently
# shift every later field left. US is not IFS whitespace, so empty fields hold
# their place. lease_age_secs is -1 when no lease timestamp parsed, which makes
# the age check below decline rather than guess.
flatten() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$STATUS_JSON" <<'PY'
import json, sys, datetime

try:
    pool = json.loads(sys.argv[1])
except Exception:
    sys.exit(3)
if not isinstance(pool, list):
    sys.exit(3)

now = datetime.datetime.now(datetime.timezone.utc)
for wt in pool:
    if not isinstance(wt, dict):
        continue
    leased_at = wt.get("leased_at") or ""
    age = -1
    if leased_at:
        text = leased_at.replace("Z", "+00:00")
        try:
            stamp = datetime.datetime.fromisoformat(text)
        except ValueError:
            stamp = None
        if stamp is not None:
            if stamp.tzinfo is None:
                stamp = stamp.replace(tzinfo=datetime.timezone.utc)
            age = int((now - stamp).total_seconds())
    procs = wt.get("processes") or []
    fields = [
        str(wt.get("status") or ""),
        str(wt.get("path") or ""),
        str(wt.get("lease_id") or ""),
        str(wt.get("lease_holder") or ""),
        str(len(procs)),
        str(age),
    ]
    if any("\x1f" in f or "\n" in f for f in fields):
        continue
    print("\x1f".join(fields))
PY
    return
  fi
  # Without python3 there is no portable RFC3339 parse, so report every lease as
  # age -1: dirty-slot reclaim still works, stale-lease reclaim declines.
  command -v jq >/dev/null 2>&1 || return 3
  printf '%s' "$STATUS_JSON" | jq -r '
    .[] | [ (.status // ""), (.path // ""), (.lease_id // ""),
            (.lease_holder // ""), ((.processes // []) | length | tostring),
            "-1" ] | join("\u001f")'
}

RECORDS=$(flatten) || {
  warn 'could not parse treehouse status (needs python3, or jq as a fallback)'
  exit 0
}

if [ "$ONLY_IF_EXHAUSTED" -eq 1 ]; then
  # An available slot means the next `treehouse get` succeeds on its own, so
  # there is nothing worth the sweep's cost. Read this off the same flattened
  # records the sweep uses, not a second `treehouse status` call, so the
  # decision and the sweep can never disagree about the pool.
  while IFS=$'\x1f' read -r status _rest; do
    if [ "$status" = available ]; then
      say 'pool has an available worktree, skipping the sweep'
      exit 0
    fi
  done <<EOF
$RECORDS
EOF
fi

# True when every path git reports as dirty is a firstmate hook dropping.
# Fails closed: an unreadable worktree, an unparseable porcelain line, a rename,
# or any path we did not write all answer "not reclaimable".
only_firstmate_droppings() {  # <worktree>
  local wt=$1 porcelain line path known
  porcelain=$(git -C "$wt" status --porcelain 2>/dev/null) || return 1
  [ -n "$porcelain" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Porcelain v1 is "XY<space><path>"; anything shorter is not a status line.
    [ "${#line}" -gt 3 ] || return 1
    path=${line:3}
    # A quoted path means git escaped something unusual in it, and a rename
    # arrow means two paths on one line. Neither can be a plain dropping.
    case "$path" in
      '"'*|*' -> '*) return 1 ;;
    esac
    known=0
    while IFS= read -r dropping; do
      [ -n "$dropping" ] || continue
      [ "$path" = "$dropping" ] && { known=1; break; }
    done <<EOF
$DROPPINGS
EOF
    [ "$known" -eq 1 ] || return 1
  done <<EOF
$porcelain
EOF
  return 0
}

do_return() {  # <path> [extra treehouse args...]
  local wt=$1 out
  shift
  if [ "$APPLY" -ne 1 ]; then
    return 0
  fi
  if out=$( (cd "$PROJECT" && treehouse return --force "$@" "$wt") 2>&1 ); then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2
  return 1
}

reclaimed=0
skipped=0
live=0
failed=0

# "reclaimed" in a dry run would read as a completed action, so name the mode.
if [ "$APPLY" -eq 1 ]; then
  VERB=reclaimed
else
  VERB='would reclaim'
fi

while IFS=$'\x1f' read -r status path lease_id holder procs age; do
  [ -n "$path" ] || continue
  if [ "${procs:-0}" != 0 ]; then
    live=$((live + 1))
    continue
  fi
  case "$status" in
    leased)
      if [ -z "$lease_id" ]; then
        say "skipped $path (leased with no lease id to match on)"
        skipped=$((skipped + 1))
        continue
      fi
      # A non-numeric or negative age means the lease timestamp did not parse.
      # Decline rather than guess: an unaged lease is indistinguishable from one
      # taken a second ago by a leaseholder that has not spawned its process yet.
      case "$age" in
        ''|*[!0-9-]*|-*)
          say "skipped $path (lease held by '${holder:-unnamed}' has no usable timestamp)"
          skipped=$((skipped + 1))
          continue
          ;;
      esac
      if [ "$age" -lt "$STALE_LEASE_SECS" ]; then
        say "skipped $path (lease held by '${holder:-unnamed}' is not old enough: ${age}s < ${STALE_LEASE_SECS}s)"
        skipped=$((skipped + 1))
        continue
      fi
      if do_return "$path" --if-lease-id "$lease_id"; then
        say "$VERB $path (stale lease held by '${holder:-unnamed}', idle ${age}s, no processes)"
        reclaimed=$((reclaimed + 1))
      else
        say "could not reclaim $path (stale lease return refused; it may have been re-leased)"
        failed=$((failed + 1))
      fi
      ;;
    dirty)
      if [ -n "$lease_id" ]; then
        say "skipped $path (dirty but still leased by '${holder:-unnamed}')"
        skipped=$((skipped + 1))
        continue
      fi
      if only_firstmate_droppings "$path"; then
        if do_return "$path"; then
          say "$VERB $path (spent slot: only firstmate hook droppings were dirty)"
          reclaimed=$((reclaimed + 1))
        else
          say "could not reclaim $path (return failed; see stderr)"
          failed=$((failed + 1))
        fi
      else
        say "skipped $path (dirty with changes firstmate did not write; triage by hand)"
        skipped=$((skipped + 1))
      fi
      ;;
    *)
      ;;
  esac
done <<EOF
$RECORDS
EOF

if [ "$APPLY" -eq 1 ]; then
  say "done: $reclaimed reclaimed, $skipped skipped, $failed failed, $live in use"
else
  say "dry run: $reclaimed would be reclaimed, $skipped skipped, $live in use (pass --yes to act)"
fi
exit 0
