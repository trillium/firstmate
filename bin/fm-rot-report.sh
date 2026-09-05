#!/usr/bin/env bash
# fm-rot-report.sh - read-only report of what is quietly wrong right now.
#
# Firstmate instruments things that HAPPEN. The watcher wakes on status events,
# PR results and staleness; bin/fm-fleet-snapshot.sh answers "what is live";
# bin/fm-bearings-snapshot.sh answers "where did I leave off". Nothing surfaces
# what has quietly STOPPED happening, because rot is the ABSENCE of an event and
# no wake ever fires for an absence. A default branch red for four days, a
# preserved worktree whose triage record was never filed, an open PR no task
# records, a second mate whose automatic relaunch has been failing: each is
# invisible to every existing surface until someone goes looking. This is the
# deliberate sweep that goes looking.
#
# Strictly read-only. It takes no lock, drains no wake queue, arms no watcher,
# repairs nothing, and writes nothing outside the temp directory it creates and
# removes, so it is safe to run in a session that could not acquire the session
# lock and is therefore forbidden from mutating anything. It is not machinery:
# nothing invokes it automatically, and it must never be wired into the watcher,
# session start, bootstrap, or a registered state/<id>.check.sh.
#
# It never cries wolf. Quiet because healthy and quiet because dead look
# identical from the outside, so every check either proves the difference or
# declines to guess: an idle second mate, an empty backlog, a task parked at a
# captain-owned gate and a clean unleased worktree are healthy and never appear.
# A check that cannot establish rot reports an unknown instead of a finding.
# Missing a real finding is always preferred to emitting a false one.
#
# Silence is the healthy output. A check that ran and found nothing prints
# nothing at all; anything the run could NOT establish is listed under "not
# checked", so an absent section always means "checked, clean" and never
# "skipped". Exit status is 0 whenever the report itself ran, findings or not;
# a non-zero status means this command failed, never that the fleet is rotten.
#
# Usage: fm-rot-report.sh [options]
#   --include-network      Also run the network-gated checks (default: off).
#                          Without it this command itself makes zero network and
#                          zero authenticated calls, mirroring --include-prs in
#                          bin/fm-bearings-snapshot.sh. Its wall time is then
#                          almost entirely bin/fm-fleet-snapshot.sh's own, which
#                          on a home with registered remote second mates reaches
#                          across to read their endpoints; FM_SNAPSHOT_SECONDMATE_TIMEOUT
#                          bounds that, and an endpoint left unread is reported
#                          as not checked rather than assumed dead.
#   --all-pools            Sweep every registered project's worktree pool for
#                          abandoned uncommitted work, not just this home's own.
#   --json                 Emit the structured model instead of text.
#   --toon                 Emit the model as TOON (the repo's agent-facing shape).
#   --check-timeout <n>    Hard per-check bound in seconds (default: 20). A check
#                          that hits it degrades to an unknown and never stalls
#                          the report.
#   --network-timeout <n>  Hard bound on each individual remote call made by the
#                          network sweep (default: 30).
#   --red-hours <n>        A default branch must have been failing this long
#                          before it counts as rot (default: 24). Age is the
#                          signal, not redness: one flaky run is not rot.
#   --pr-green-days <n>    An open, green, unblocked PR waiting this long counts
#                          as rot (default: 2).
#   --dead-endpoint-hours <n>
#                          A task record whose worker endpoint is gone counts as
#                          rot once its status log has been quiet this long
#                          (default: 2), so an ordinary teardown in progress is
#                          not mistaken for a dangling record.
#   --decision-quiet-days <n>
#                          Open decisions on a task whose status log has been
#                          quiet this long count as rot (default: 3).
#   --bead-stale-days <n>  Passed straight to bin/fm-ledger.sh (default: 2).
#   --stranded-commits <n> How far ahead of the default branch an undelivered
#                          branch must be before it counts as rot (default: 10),
#                          counted by patch id so rebased and cherry-picked work
#                          already upstream does not inflate it.
#   -h, --help             Print this header.
#
# Internal:
#   --internal-run-check <id>   Run one registered check in this process and
#                          print its raw records. The parent uses it to give
#                          every check a hard bound of its own; it is not a
#                          supported entry point and its record format is
#                          private to this script.
#
# Env:
#   FM_ROT_NOW             Epoch seconds to treat as "now" (tests).
#   FM_HOME, FM_ROOT_OVERRIDE, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE,
#   FM_CONFIG_OVERRIDE, FM_PROJECTS_OVERRIDE
#                          Resolved exactly as bin/fm-fleet-snapshot.sh resolves
#                          them, so both commands always describe the same home.
#
# Adding a check: write one check_<slug> function that emits findings through
# `finding` and non-findings through `unknown`, then add one row to CHECK_TABLE.
# Nothing else in this file needs to change. Consume bin/fm-fleet-snapshot.sh
# for live task facts rather than re-deriving them, delegate to the script that
# already owns a judgment (bin/fm-pool-reclaim.sh owns "does this worktree hold
# real work", bin/fm-ledger.sh owns bead staleness, bin/fm-crew-state.sh owns
# current crew state), and never print credential material: some inputs sit
# beside token stores, and no finding may carry a token, a key, or the contents
# of a credential file.

# shellcheck disable=SC2329 # Every check_* below is dispatched indirectly through CHECK_TABLE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-stat-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-stat-lib.sh"

US=$'\037'

# The check inventory. One row per check, in the order it is run and reported:
#   <slug>|<band>|<needs-network>|<one-line description>
# Bands are ordered by what a finding costs: losing work beats blocked delivery
# beats untidy records.
CHECK_TABLE='
home-uncommitted|S1|0|uncommitted work sitting in the fleet home checkout
orphan-worktree|S1|0|isolated copy holding uncommitted work with no live worker
duplicate-worktree|S1|0|one isolated copy claimed by more than one task record
staleness-unfiled|S1|0|preserved worktree whose triage record was never filed
default-branch-red|S2|1|a project default branch has been failing CI
pr-untracked|S2|1|open fleet PR no task records, invisible to every automated path
pr-waiting|S2|1|open fleet PR green and mergeable, waiting on a person
pr-head-drift|S2|1|recorded PR head no longer matches the open PR
stranded-branch|S2|1|fleet branch carrying unmerged work with no open PR
dead-endpoint|S3|0|task record whose worker endpoint is gone
secondmate-home-missing|S3|0|registered second mate whose home is not there
project-registry-drift|S3|0|project registry and local clones disagree
unarmed-check|S3|0|registered poll the watcher will never run
quarantined-check|S3|0|poll neutralized by the migration and never rebuilt
stale-open-decisions|S4|0|open decisions on a task that has gone quiet
dropped-beads|S4|0|claimed beads still open past their staleness window
'

band_title() {
  case "$1" in
    S1) printf 'work may be silently lost' ;;
    S2) printf 'delivery is stalled' ;;
    S3) printf 'records point at nothing' ;;
    S4) printf 'gone quiet' ;;
    *) printf '%s' "$1" ;;
  esac
}

INCLUDE_NETWORK=0
ALL_POOLS=0
FORMAT=text
CHECK_TIMEOUT=20
NETWORK_TIMEOUT=30
RED_HOURS=24
PR_GREEN_DAYS=2
DEAD_ENDPOINT_HOURS=2
DECISION_QUIET_DAYS=3
BEAD_STALE_DAYS=2
STRANDED_COMMITS=10
RUN_ONE=

die() { printf 'fm-rot-report: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }

validate_bound() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0) die "$1 must be a positive integer" 2 ;;
  esac
}

need_value() {  # <flag> <count>
  [ "$2" -ge 2 ] || die "$1 requires a value" 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --include-network) INCLUDE_NETWORK=1; shift ;;
    --all-pools) ALL_POOLS=1; shift ;;
    --json) FORMAT=json; shift ;;
    --toon) FORMAT=toon; shift ;;
    --check-timeout) need_value "$1" "$#"; validate_bound --check-timeout "$2"; CHECK_TIMEOUT=$2; shift 2 ;;
    --network-timeout) need_value "$1" "$#"; validate_bound --network-timeout "$2"; NETWORK_TIMEOUT=$2; shift 2 ;;
    --red-hours) need_value "$1" "$#"; validate_bound --red-hours "$2"; RED_HOURS=$2; shift 2 ;;
    --pr-green-days) need_value "$1" "$#"; validate_bound --pr-green-days "$2"; PR_GREEN_DAYS=$2; shift 2 ;;
    --dead-endpoint-hours) need_value "$1" "$#"; validate_bound --dead-endpoint-hours "$2"; DEAD_ENDPOINT_HOURS=$2; shift 2 ;;
    --decision-quiet-days) need_value "$1" "$#"; validate_bound --decision-quiet-days "$2"; DECISION_QUIET_DAYS=$2; shift 2 ;;
    --bead-stale-days) need_value "$1" "$#"; validate_bound --bead-stale-days "$2"; BEAD_STALE_DAYS=$2; shift 2 ;;
    --stranded-commits) need_value "$1" "$#"; validate_bound --stranded-commits "$2"; STRANDED_COMMITS=$2; shift 2 ;;
    --internal-run-check) need_value "$1" "$#"; RUN_ONE=$2; shift 2 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 'jq not found'

NOW=${FM_ROT_NOW:-$(date -u +%s)}
case "$NOW" in ''|*[!0-9]*) die 'FM_ROT_NOW must be epoch seconds' 2 ;; esac

# ---------------------------------------------------------------- record I/O

# Fields are separated by US and may never contain US, a newline, or a carriage
# return, so one record is always exactly one line with a fixed field count.
scrub() { printf '%s' "$1" | tr -d '\n\r\037'; }

emit() {  # <type> <fields...>
  local out=$1 field
  shift
  for field in "$@"; do out="$out$US$(scrub "$field")"; done
  printf '%s\n' "$out"
}

# finding <subject> <age-seconds|-> <detail> <next-command>
# Every finding says what is rotting, how long it has been that way, and the
# concrete next command. A finding without an actionable next step is half a
# finding, so `next` is required.
finding() { emit F "$FM_ROT_CHECK" "$1" "$2" "$3" "$4"; }

# unknown <reason>
# What this run could not establish. Never a guess in either direction.
unknown() { emit U "$FM_ROT_CHECK" "$1"; }

age_of() {  # <path> -> seconds since mtime, or "-"
  local mtime
  mtime=$(fm_stat_mtime "$1" 2>/dev/null) || { printf -- '-\n'; return 0; }
  case "$mtime" in ''|*[!0-9]*) printf -- '-\n'; return 0 ;; esac
  if [ "$mtime" -gt "$NOW" ]; then printf '0\n'; else printf '%s\n' "$((NOW - mtime))"; fi
}

snapshot() { cat "$FM_ROT_SNAPSHOT"; }

# The clock is pinned once when the report starts, so anything that came into
# existence after that - a pull request opened while this very report was still
# running - subtracts to a negative age and renders as "age unknown". Clamp it
# exactly as age_of does for a file mtime, so a brand-new thing reads as new
# rather than as unreadable.
# shellcheck disable=SC2016  # $now and $iso are jq parameters, not shell expansions.
JQ_AGE='def age($now; $iso): ($now - ($iso | fromdateiso8601)) | if . < 0 then 0 else . end;'

# Every local checkout this report may reason about: each project clone, plus
# the fleet home itself. The home is deliberately included because firstmate's
# own repo is where the fleet ships its tooling and it is not a clone under
# projects/ - without it, fleet PRs and branches against firstmate would be the
# one class this report could never see.
repo_dirs() {
  local d
  if [ -d "$PROJECTS" ]; then
    for d in "$PROJECTS"/*; do
      [ -d "$d" ] && printf '%s\n' "$d"
    done
  fi
  [ -d "$FM_HOME/.git" ] && printf '%s\n' "$FM_HOME"
  return 0
}

# ---------------------------------------------------------------- S1 checks

check_home_uncommitted() {
  local gitdir porcelain count oldest path mtime age
  if ! gitdir=$(git -C "$FM_HOME" rev-parse --absolute-git-dir 2>/dev/null); then
    unknown 'the fleet home is not a git checkout'
    return 0
  fi
  # Running from inside a task's isolated copy is the normal way a crewmate
  # invokes this. That copy is SUPPOSED to be dirty - it is the work in
  # progress - so reporting it would be the loudest false positive available.
  case "$gitdir" in
    */worktrees/*)
      unknown 'running inside an isolated task copy, not the fleet home checkout'
      return 0
      ;;
  esac
  porcelain=$(git -C "$FM_HOME" status --porcelain 2>/dev/null) || {
    unknown 'the fleet home checkout would not report its status'
    return 0
  }
  [ -n "$porcelain" ] || return 0
  count=$(printf '%s\n' "$porcelain" | grep -c . || true)
  oldest=
  while IFS= read -r line; do
    [ "${#line}" -gt 3 ] || continue
    path=${line:3}
    case "$path" in *' -> '*) path=${path##* -> } ;; esac
    path=${path%\"}; path=${path#\"}
    [ -e "$FM_HOME/$path" ] || continue
    mtime=$(fm_stat_mtime "$FM_HOME/$path" 2>/dev/null) || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$oldest" ] || [ "$mtime" -lt "$oldest" ]; then oldest=$mtime; fi
  done <<EOF
$porcelain
EOF
  if [ -n "$oldest" ] && [ "$oldest" -le "$NOW" ]; then age=$((NOW - oldest)); else age='-'; fi
  finding "$FM_HOME" "$age" \
    "$count uncommitted path(s) in the fleet home checkout; it exists only as a working tree" \
    "git -C $FM_HOME status"
}

check_orphan_worktree() {
  # bin/fm-pool-reclaim.sh already owns the judgment "does this pool slot hold
  # real work, or only firstmate's own per-spawn droppings". Its dry run is
  # read-only and reports exactly the slots it refuses to reclaim; asking it is
  # how this check avoids keeping a second copy of that rule. Absence from its
  # output means "not established as holding real work", which biases this
  # check toward silence rather than toward a guess.
  local reclaim dirs dir out line path owner alive porcelain count age scanned=0
  reclaim="$SCRIPT_DIR/fm-pool-reclaim.sh"
  [ -x "$reclaim" ] || { unknown 'the pool sweeper is not available here'; return 0; }
  command -v treehouse >/dev/null 2>&1 || { unknown 'treehouse is not installed, so no worktree pool can be read'; return 0; }
  dirs=$FM_ROOT
  if [ "${FM_ROT_ALL_POOLS:-0}" = 1 ] && [ -d "$PROJECTS" ]; then
    for dir in "$PROJECTS"/*; do
      [ -d "$dir" ] || continue
      [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue
      dirs="$dirs$US$dir"
    done
  else
    unknown 'only this home pool was swept; pass --all-pools to sweep every project pool'
  fi
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    out=$(TREEHOUSE_NO_UPDATE_CHECK=1 "$reclaim" --project "$dir" 2>/dev/null) || continue
    scanned=$((scanned + 1))
    while IFS= read -r line; do
      case "$line" in
        *': skipped '*'(dirty with changes firstmate did not write'*) ;;
        *) continue ;;
      esac
      path=${line#*': skipped '}
      path=${path%% (dirty with changes*}
      [ -d "$path" ] || continue
      # A slot a live worker is sitting in is healthy: the dirt is work in
      # progress, and the worker will commit it.
      owner=$(snapshot | jq -r --arg p "$path" '
        [.tasks[] | select(.paths.worktree.path == $p)][0].id // ""')
      if [ -n "$owner" ]; then
        alive=$(snapshot | jq -r --arg p "$path" '
          [.tasks[] | select(.paths.worktree.path == $p)][0].endpoint.exists // "unknown"')
        [ "$alive" = true ] && continue
      fi
      porcelain=$(git -C "$path" status --porcelain 2>/dev/null) || continue
      count=$(printf '%s\n' "$porcelain" | grep -c . || true)
      age=$(age_of "$path")
      if [ -n "$owner" ]; then
        finding "$path" "$age" \
          "$count uncommitted path(s); its task $owner has no worker left to commit them" \
          "bin/fm-crew-state.sh $owner"
      else
        finding "$path" "$age" \
          "$count uncommitted path(s) and no task record points at this copy" \
          "git -C $path status"
      fi
    done <<EOF
$out
EOF
  done <<EOF
$(printf '%s\n' "$dirs" | tr "$US" '\n')
EOF
  [ "$scanned" -gt 0 ] || unknown 'no worktree pool could be read'
}

check_duplicate_worktree() {
  # Two task records naming the same isolated copy is a data-loss hazard, not
  # untidiness: cleanup or relaunch of the stale record operates on a live
  # sibling's tree, and the watcher's own idle reclaim is an automated caller of
  # that path. So this reads the records themselves rather than the snapshot -
  # the claim is what is dangerous, whether or not either worker is still alive.
  local f id wt seen='' path claimants n live
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .meta)
    wt=$(sed -n 's/^worktree=//p' "$f" | head -1)
    [ -n "$wt" ] || continue
    seen="$seen$wt$US$id"$'\n'
  done
  [ -n "$seen" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    claimants=$(printf '%s' "$seen" | awk -F"$US" -v p="$path" '$1 == p { printf "%s ", $2 }')
    claimants=${claimants% }
    n=$(printf '%s\n' "$claimants" | tr ' ' '\n' | grep -c . || true)
    [ "$n" -gt 1 ] || continue
    # Name which claimants still have a worker, because a dead record sharing a
    # copy with a LIVE one is the shape that actually destroys work.
    live=$(snapshot | jq -r --arg p "$path" '
      [.tasks[] | select(.paths.worktree.path == $p and .endpoint.exists == true) | .id] | join(", ")')
    finding "$path" "$(age_of "$path")" \
      "claimed by $n task records ($claimants)${live:+; still worked in by $live}; cleanup or relaunch of either would operate on the other work" \
      "grep -l \"worktree=$path\" $STATE/*.meta"
  done <<EOF
$(printf '%s' "$seen" | cut -d"$US" -f1 | sort -u)
EOF
}

check_staleness_unfiled() {
  # bin/fm-teardown.sh writes this marker only when a reclaimed task's triage
  # bead could not be filed, which makes the marker the SOLE remaining record
  # of a preserved worktree. Nothing else will ever mention it again.
  local f id wt branch project age
  for f in "$STATE"/*.staleness-unfiled; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .staleness-unfiled)
    wt=$(sed -n 's/^worktree: //p' "$f" | head -1)
    branch=$(sed -n 's/^branch: //p' "$f" | head -1)
    project=$(sed -n 's/^project: //p' "$f" | head -1)
    age=$(age_of "$f")
    finding "$id" "$age" \
      "reclaimed with work preserved but its triage record was never filed; worktree ${wt:-unknown} on branch ${branch:-unknown} in ${project:-unknown}" \
      "cat $f"
  done
}

# ---------------------------------------------------------------- S2 checks

netinv() {
  [ -n "${FM_ROT_NETINV:-}" ] && [ -s "$FM_ROT_NETINV" ] || return 1
  cat "$FM_ROT_NETINV"
}

check_default_branch_red() {
  local inv
  inv=$(netinv) || { unknown 'the network sweep produced nothing to read'; return 0; }
  printf '%s' "$inv" | jq -r --argjson now "$NOW" --argjson red "$((RED_HOURS * 3600))" "$JQ_AGE"'
    .repos[]
    | select(.runs_ok == true)
    | . as $r
    | ($r.runs | map(select(.status == "completed"))) as $done
    | select(($done | length) > 0)
    | select($done[0].conclusion == "failure")
    | ([$done[] | if .conclusion == "failure" then . else empty end] | length) as $_
    | ([ $done | to_entries[] | select(.value.conclusion != "failure") | .key ] | first // ($done | length)) as $streak
    | age($now; $done[$streak - 1].createdAt) as $age
    | select($age >= $red)
    | [$r.slug, ($age | tostring), "default branch \($r.default_branch) failing CI for \($streak) consecutive push run(s); every PR opened since is unmergeable", "gh-axi run list --repo \($r.slug) --branch \($r.default_branch) --limit 5"]
    | @tsv
  ' 2>/dev/null | while IFS=$'\t' read -r slug age detail next; do
    [ -n "$slug" ] || continue
    finding "$slug" "$age" "$detail" "$next"
  done
}

check_pr_untracked() {
  local inv recorded
  inv=$(netinv) || { unknown 'the network sweep produced nothing to read'; return 0; }
  recorded=$(snapshot | jq -c '[.tasks[].pr.url // empty]')
  printf '%s' "$inv" | jq -r --argjson now "$NOW" --argjson recorded "$recorded" "$JQ_AGE"'
    ($recorded | map(sub("/+$"; ""))) as $known
    | .repos[]
    | select(.prs_ok == true)
    | .prs[]
    | select(.isDraft == false)
    | select(.headRefName | startswith("fm/"))
    | select(((.url | sub("/+$"; "")) | IN($known[])) | not)
    | [.url, (age($now; .createdAt) | tostring),
       "open PR from fleet branch \(.headRefName) that no task records, so it cannot go through the guarded merge path at all",
       "bin/fm-pr-check.sh <task-id> \(.url)"]
    | @tsv
  ' 2>/dev/null | while IFS=$'\t' read -r url age detail next; do
    [ -n "$url" ] || continue
    finding "$url" "$age" "$detail" "$next"
  done
}

check_pr_waiting() {
  local inv
  inv=$(netinv) || { unknown 'the network sweep produced nothing to read'; return 0; }
  printf '%s' "$inv" | jq -r --argjson now "$NOW" --argjson wait "$((PR_GREEN_DAYS * 86400))" "$JQ_AGE"'
    .repos[]
    | select(.prs_ok == true)
    | .prs[]
    | select(.isDraft == false)
    | select(.headRefName | startswith("fm/"))
    | select(.mergeable == "MERGEABLE")
    | select(.reviewDecision != "CHANGES_REQUESTED")
    | select((.statusCheckRollup // []) | length > 0)
    | select(((.statusCheckRollup // []) | map(.conclusion // .state // "") | any(. == "FAILURE" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "PENDING" or . == "")) | not)
    | age($now; .updatedAt) as $age
    | select($age >= $wait)
    | [.url, ($age | tostring), "green and mergeable, waiting on a person with nothing left to run", "bin/fm-pr-merge.sh <task-id>"]
    | @tsv
  ' 2>/dev/null | while IFS=$'\t' read -r url age detail next; do
    [ -n "$url" ] || continue
    finding "$url" "$age" "$detail" "$next"
  done
}

check_pr_head_drift() {
  local inv recorded
  inv=$(netinv) || { unknown 'the network sweep produced nothing to read'; return 0; }
  # The recorded head lives only in state/<id>.meta; the snapshot does not carry
  # it, so read the one field this check needs rather than re-parsing the file.
  recorded=$(
    for f in "$STATE"/*.meta; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .meta)
      url=$(sed -n 's/^pr=//p' "$f" | head -1)
      head=$(sed -n 's/^pr_head=//p' "$f" | head -1)
      [ -n "$url" ] && [ -n "$head" ] || continue
      printf '%s\t%s\t%s\n' "$id" "$url" "$head"
    done | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {id: .[0], url: (.[1] | sub("/+$"; "")), head: .[2]})'
  )
  [ -n "$recorded" ] || recorded='[]'
  printf '%s' "$inv" | jq -r --argjson now "$NOW" --argjson recorded "$recorded" "$JQ_AGE"'
    [.repos[] | select(.prs_ok == true) | .prs[]] as $open
    | $recorded[]
    | . as $rec
    | ([$open[] | select((.url | sub("/+$"; "")) == $rec.url)][0]) as $pr
    | select($pr != null)
    | select($pr.headRefOid != null and $pr.headRefOid != "")
    | select(($pr.headRefOid | startswith($rec.head)) | not)
    | select(($rec.head | startswith($pr.headRefOid)) | not)
    | [$rec.url, (age($now; $pr.updatedAt) | tostring),
       "the head recorded for task \($rec.id) is \($rec.head), but the open PR is at \($pr.headRefOid | .[0:12]); the local record is stale",
       "bin/fm-pr-check.sh \($rec.id) \($rec.url)"]
    | @tsv
  ' 2>/dev/null | while IFS=$'\t' read -r url age detail next; do
    [ -n "$url" ] || continue
    finding "$url" "$age" "$detail" "$next"
  done
}

check_stranded_branch() {
  # Work that was written, committed, and then simply never delivered. The
  # never-cry-wolf problem here is that most fleet branches are LANDED - so a
  # branch is only reported once three independent suppressions have failed to
  # explain it: it is not an ancestor of the default branch, its commits are not
  # already upstream by patch id (which catches rebase and cherry-pick), and it
  # was never the head of a merged PR (which catches squash merges, the case
  # neither git test can see).
  #
  # Branch state is read from the local clone exactly as it stands. This never
  # fetches, because fetching would write to a checkout this report is not
  # allowed to touch, so a clone that has not fetched in a while can only make
  # this check quieter, never louder.
  local inv rows dir default slug heads branch base ahead files tip age checked
  inv=$(netinv) || { unknown 'the network sweep produced nothing to read'; return 0; }
  rows=$(printf '%s' "$inv" | jq -r '
    .repos[] | select(.dir != "") | [.dir, .default_branch, .slug, (.merged_ok and .prs_ok)] | @tsv')
  printf '%s' "$inv" | jq -r '.repos[] | select(.dir == "") | .slug' 2>/dev/null \
    | while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        unknown "no local copy of $slug here, so its branches were not read"
      done
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r dir default slug ok; do
    [ -n "$dir" ] || continue
    if [ "$ok" != true ]; then
      unknown "the pull request history for $slug was unreadable, so its branches were not judged"
      continue
    fi
    base="origin/$default"
    # Every branch currently checked out in one of this clone's worktrees. That
    # is somebody's working copy right now - a worker mid-task has committed
    # work and no pull request yet, which is the healthy shape this check must
    # never mistake for abandonment. The snapshot carries no branch of its own,
    # so the checkouts are the authority.
    checked=$(git -C "$dir" worktree list --porcelain 2>/dev/null \
      | sed -n 's#^branch refs/heads/##p')
    git -C "$dir" rev-parse --verify -q "$base" >/dev/null 2>&1 || {
      unknown "$slug has no $base to compare against here"
      continue
    }
    # Every branch name the forge has ever shipped for this repo, open or merged.
    heads=$(printf '%s' "$inv" | jq -r --arg s "$slug" '
      .repos[] | select(.slug == $s) | (.merged_heads + [.prs[].headRefName]) | .[]' | sort -u)
    while IFS= read -r branch; do
      [ -n "$branch" ] || continue
      git -C "$dir" merge-base --is-ancestor "$branch" "$base" 2>/dev/null && continue
      printf '%s\n' "$heads" | grep -qxF "$branch" && continue
      # git cherry compares by patch id, so a rebased or cherry-picked commit
      # already on the default branch does not count toward being ahead.
      ahead=$(git -C "$dir" cherry "$base" "$branch" 2>/dev/null | grep -c '^+' || true)
      [ "${ahead:-0}" -ge "$STRANDED_COMMITS" ] || continue
      printf '%s\n' "$checked" | grep -qxF "$branch" && continue
      files=$(git -C "$dir" diff --name-only "$base...$branch" 2>/dev/null | grep -c . || true)
      tip=$(git -C "$dir" log -1 --format=%ct "$branch" 2>/dev/null)
      case "$tip" in
        ''|*[!0-9]*) age='-' ;;
        *) if [ "$tip" -gt "$NOW" ]; then age=0; else age=$((NOW - tip)); fi ;;
      esac
      finding "$branch" "$age" \
        "$ahead commit(s) across $files file(s) not on $default, never merged and with no open pull request in $slug" \
        "git -C $dir log --oneline $base..$branch"
    done <<EOF
$(git -C "$dir" for-each-ref --format='%(refname:short)' 'refs/heads/fm/*' 2>/dev/null)
EOF
  done <<EOF
$rows
EOF
}

# ---------------------------------------------------------------- S3 checks

check_dead_endpoint() {
  # endpoint.exists is the snapshot's own cheap presence read; this check never
  # probes a backend itself. An idle second mate reads exists:true and so never
  # appears here - only a genuinely absent endpoint does. A remote route the
  # snapshot could not read reads neither true nor false and is reported as
  # unreadable rather than dead.
  local rows unread
  rows=$(snapshot | jq -r '.tasks[] | select(.endpoint.exists == false) | [.id, .kind, (.paths.status_log.path // ""), (.paths.worktree.path // "")] | @tsv')
  unread=$(snapshot | jq -r '[.tasks[] | select(.endpoint.exists != true and .endpoint.exists != false) | .id] | join(", ")')
  [ -z "$unread" ] || unknown "endpoint presence was unreadable for: $unread"
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r id kind log wt; do
    [ -n "$id" ] || continue
    local age quiet held porcelain count
    if [ -n "$log" ] && [ -f "$log" ]; then
      age=$(age_of "$log"); quiet='whose status log has been silent since'
    else
      age=$(age_of "$STATE/$id.meta"); quiet='which never wrote a status log at all'
    fi
    case "$age" in
      '-') continue ;;
      *) [ "$age" -ge $((DEAD_ENDPOINT_HOURS * 3600)) ] || continue ;;
    esac
    # The record still leases its isolated copy, and the pool counts a leased
    # slot as unavailable however dead the worker is - three of these at once is
    # what exhausted the fleet's pool and refused every new spawn. Say which
    # copy is held and whether it holds work, because that is the difference
    # between a slot to reclaim and a slot to triage by hand.
    held=
    if [ -n "$wt" ]; then
      if [ ! -d "$wt" ]; then
        held="; its recorded copy $wt is no longer there"
      elif porcelain=$(git -C "$wt" status --porcelain 2>/dev/null); then
        if [ -n "$porcelain" ]; then
          count=$(printf '%s\n' "$porcelain" | grep -c . || true)
          held="; still holds $wt with $count uncommitted path(s)"
        else
          held="; still holds $wt, clean"
        fi
      else
        held="; still holds $wt, which would not report its status"
      fi
    fi
    finding "$id" "$age" \
      "$kind record whose worker endpoint is gone and $quiet$held" \
      "bin/fm-crew-state.sh $id"
  done <<EOF
$rows
EOF
}

check_secondmate_home_missing() {
  # A remote second mate's home lives on another machine and cannot be inspected
  # from here without a network call, so it is reported as unchecked rather than
  # guessed at. bin/fm-remote-doctor.sh, run through bin/fm-on.sh, owns that.
  local reg line id home remote=''
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || { unknown 'no second mate registry in this home'; return 0; }
  while IFS= read -r line; do
    case "$line" in '- '*) ;; *) continue ;; esac
    id=${line#- }
    id=${id%% *}
    case "$line" in
      *'host:'*) remote="$remote${remote:+, }$id"; continue ;;
    esac
    case "$line" in *'home:'*) ;; *) continue ;; esac
    home=${line#*home: }
    home=${home%%;*}
    home=${home%%)*}
    home=${home%"${home##*[![:space:]]}"}
    [ -n "$home" ] || continue
    if [ ! -d "$home" ]; then
      finding "$id" '-' "registered second mate whose home $home is not on this machine" \
        "grep -n '^- $id' $reg"
    elif [ ! -e "$home/.fm-secondmate-home" ]; then
      finding "$id" '-' "registered second mate whose home $home carries no second mate marker" \
        "ls -a $home"
    fi
  done < "$reg"
  [ -z "$remote" ] || unknown "second mates on another machine were not checked from here: $remote"
}

check_project_registry_drift() {
  local reg line name registered='' present='' entry
  reg="$DATA/projects.md"
  [ -f "$reg" ] || { unknown 'no project registry in this home'; return 0; }
  [ -d "$PROJECTS" ] || { unknown 'no project clone directory in this home'; return 0; }
  while IFS= read -r line; do
    case "$line" in '- '*) ;; *) continue ;; esac
    name=${line#- }
    name=${name%% *}
    [ -n "$name" ] || continue
    registered="$registered$name"$'\n'
  done < "$reg"
  for entry in "$PROJECTS"/*; do
    [ -e "$entry" ] || continue
    present="$present$(basename "$entry")"$'\n'
  done
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s' "$present" | grep -qxF "$name" && continue
    finding "$name" '-' 'registered in the project list with no local clone, so no task can be dispatched against it' \
      "grep -n '^- $name' $reg"
  done <<EOF
$registered
EOF
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s' "$registered" | grep -qxF "$name" && continue
    finding "$name" '-' 'cloned locally with no entry in the project list, so it has no recorded delivery posture' \
      "ls -ld $PROJECTS/$name"
  done <<EOF
$present
EOF
}

check_unarmed_check() {
  # The watcher accepts a state/<id>.check.sh only as a valid PR merge poll or
  # as a registered custom check, and silently declines to run anything else.
  # A poll that stopped being either is a check that will never fire again, and
  # nothing announces that. Both predicates below are the read-only ones their
  # owners expose; the mutating snapshot-preparing variants are never used here.
  local template f id
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-pr-lib.sh" 2>/dev/null || { unknown 'the poll validators are not available here'; return 0; }
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-check-lib.sh" 2>/dev/null || { unknown 'the poll validators are not available here'; return 0; }
  template="$SCRIPT_DIR/fm-pr-poll.sh"
  for f in "$STATE"/*.check.sh; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .check.sh)
    [ "$id" = x-watch ] && continue
    fm_custom_check_registered "$STATE" "$id" 2>/dev/null && continue
    if [ -f "$template" ] && fm_pr_poll_artifacts_valid "$STATE" "$id" "$template" 2>/dev/null; then
      continue
    fi
    finding "$id" "$(age_of "$f")" \
      'a registered poll the watcher declines to run, so this task will never wake on its own again' \
      "bin/fm-check-register.sh $id"
  done
}

check_quarantined_check() {
  # The migration parks a neutralized poll and its sidecars as
  # <id>.<kind>.<suffix>, so many files belong to one task. Report the task
  # once rather than once per file.
  local dir f id age polls total seen=''
  dir="$STATE/.pr-check-quarantine"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    id=$(basename "$f" | sed -E 's/\.(check|data|registration|retirement|diagnostic)\..*$//')
    [ -n "$id" ] || continue
    case "$US$seen$US" in *"$US$id$US"*) continue ;; esac
    seen="$seen$id$US"
    polls=$(find "$dir" -maxdepth 1 -type f -name "$id.check.*" 2>/dev/null | grep -c . || true)
    total=$(find "$dir" -maxdepth 1 -type f -name "$id.*" 2>/dev/null | grep -c . || true)
    age=$(age_of "$f")
    finding "$id" "$age" \
      "$polls neutralized poll(s) and $total quarantined file(s) never rebuilt or cleared" \
      "ls -l $dir"
  done
}

# ---------------------------------------------------------------- S4 checks

check_stale_open_decisions() {
  # hints.open_decisions is the snapshot's authoritative keyed open set. Status
  # logs carry no timestamps, so there is no honest per-decision age to report;
  # what IS knowable is how long the task's log has been silent while those
  # decisions stayed open, and that is exactly the "going nowhere" signal.
  local rows
  rows=$(snapshot | jq -r '
    .tasks[]
    | select((.hints.open_decisions // []) | length > 0)
    | [.id, ((.hints.open_decisions | length) | tostring),
       (.hints.open_decisions | map(.key) | .[0:3] | join(", ")),
       (.paths.status_log.path // "")]
    | @tsv')
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r id count keys log; do
    [ -n "$id" ] || continue
    local age
    [ -n "$log" ] && [ -f "$log" ] || continue
    age=$(age_of "$log")
    case "$age" in '-') continue ;; esac
    [ "$age" -ge $((DECISION_QUIET_DAYS * 86400)) ] || continue
    finding "$id" "$age" \
      "$count open decision(s) still unresolved while the task has said nothing: $keys" \
      "bin/fm-crew-state.sh $id"
  done <<EOF
$rows
EOF
}

check_dropped_beads() {
  # bin/fm-ledger.sh owns bead staleness. This never re-derives its query.
  local ledger out
  ledger="$SCRIPT_DIR/fm-ledger.sh"
  [ -x "$ledger" ] || { unknown 'the bead ledger is not available here'; return 0; }
  out=$("$ledger" --json --stale-days "$BEAD_STALE_DAYS" 2>/dev/null) || {
    unknown 'the bead store would not answer'
    return 0
  }
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    unknown 'the bead ledger returned an unreadable result'
    return 0
  }
  printf '%s' "$out" | jq -r --argjson now "$NOW" "$JQ_AGE"'
    .[]
    | [.id,
       (if (.updated_at // "") == "" then "-"
        else (age($now; (.updated_at | sub("\\.[0-9]+"; "") | sub("Z$"; "Z"))) | tostring)
        end),
       "claimed and still open with no worker reporting: \(.title // "untitled")",
       "bin/fm-ledger.sh --close \(.id)"]
    | @tsv
  ' 2>/dev/null | while IFS=$'\t' read -r id age detail next; do
    [ -n "$id" ] || continue
    finding "$id" "$age" "$detail" "$next"
  done
}

# ---------------------------------------------------------------- single-check mode

if [ -n "$RUN_ONE" ]; then
  [ -n "${FM_ROT_SNAPSHOT:-}" ] && [ -s "${FM_ROT_SNAPSHOT:-}" ] || die 'internal: no snapshot handed to the check' 2
  printf '%s' "$CHECK_TABLE" | grep -q "^$RUN_ONE|" || die "internal: unknown check: $RUN_ONE" 2
  FM_ROT_CHECK=$RUN_ONE
  fn="check_$(printf '%s' "$RUN_ONE" | tr '-' '_')"
  command -v "$fn" >/dev/null 2>&1 || die "internal: check $RUN_ONE has no implementation" 2
  "$fn"
  exit 0
fi

# ---------------------------------------------------------------- collection

TMPDIR_ROT=$(mktemp -d "${TMPDIR:-/tmp}/fm-rot-report.XXXXXX") || die 'could not create a working directory'
trap 'rm -rf -- "$TMPDIR_ROT"' EXIT HUP INT TERM

SNAP="$TMPDIR_ROT/snapshot.json"
if ! FM_SNAPSHOT_NOW=$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true) \
     "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$SNAP" 2>"$TMPDIR_ROT/snapshot.err"; then
  die "the fleet snapshot failed: $(head -1 "$TMPDIR_ROT/snapshot.err" 2>/dev/null)"
fi
[ -s "$SNAP" ] || die 'the fleet snapshot returned nothing'

RECORDS="$TMPDIR_ROT/records"
: > "$RECORDS"

NETINV="$TMPDIR_ROT/network.json"
NETINV_STATUS=skipped
if [ "$INCLUDE_NETWORK" -eq 1 ]; then
  # The one and only network path. Every authenticated call this command can
  # make happens inside this block; without --include-network nothing here runs
  # and the report touches no remote at all.
  build_network_inventory() {
    local slugs='' dir url slug prs runs merged default repos='' ok_prs ok_runs ok_merged rdir
    slugs=$(
      {
        repo_dirs | while IFS= read -r dir; do
          url=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
          printf '%s\n' "$url"
        done
        jq -r '.tasks[].pr.url // empty' "$SNAP"
      } | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\).*#\1#p' | sed 's#\.git$##' | sort -u
    )
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      default=$(
        repo_dirs | while IFS= read -r dir; do
          url=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
          case "$url" in *"$slug"*) ;; *) continue ;; esac
          git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##'
          break
        done
      )
      [ -n "$default" ] || default=main
      ok_prs=true
      prs=$(fm_run_timed "$NETWORK_TIMEOUT" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh pr list \
        --repo "$slug" --state open --limit 50 \
        --json number,url,title,isDraft,createdAt,updatedAt,headRefName,headRefOid,reviewDecision,statusCheckRollup,mergeable 2>/dev/null) || ok_prs=false
      printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1 || { ok_prs=false; prs='[]'; }
      ok_runs=true
      runs=$(fm_run_timed "$NETWORK_TIMEOUT" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh run list \
        --repo "$slug" --branch "$default" --event push --limit 15 \
        --json databaseId,conclusion,status,createdAt,workflowName,headSha 2>/dev/null) || ok_runs=false
      printf '%s' "$runs" | jq -e 'type == "array"' >/dev/null 2>&1 || { ok_runs=false; runs='[]'; }
      # Merged PR heads. A squash merge leaves its branch neither an ancestor of
      # the default branch nor patch-identical to it, so without this list a
      # perfectly landed branch reads as stranded. Two of five candidates on the
      # live fleet were exactly that, which is why this is fetched rather than
      # inferred.
      ok_merged=true
      merged=$(fm_run_timed "$NETWORK_TIMEOUT" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh pr list \
        --repo "$slug" --state merged --limit 300 --json headRefName 2>/dev/null) || ok_merged=false
      printf '%s' "$merged" | jq -e 'type == "array"' >/dev/null 2>&1 || { ok_merged=false; merged='[]'; }
      rdir=$(
        repo_dirs | while IFS= read -r dir; do
          url=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
          case "$url" in *"$slug"*) printf '%s\n' "$dir"; break ;; esac
        done
      )
      repos="$repos$(jq -c -n \
        --arg slug "$slug" --arg default "$default" --arg dir "$rdir" \
        --argjson prs "$prs" --argjson runs "$runs" --argjson merged "$merged" \
        --argjson prs_ok "$ok_prs" --argjson runs_ok "$ok_runs" --argjson merged_ok "$ok_merged" \
        '{slug: $slug, default_branch: $default, dir: $dir, prs: $prs, runs: $runs,
          merged_heads: [$merged[].headRefName],
          prs_ok: $prs_ok, runs_ok: $runs_ok, merged_ok: $merged_ok}')"$'\n'
    done <<EOF
$slugs
EOF
    printf '%s' "$repos" | jq -s -c '{repos: .}'
  }
  if ! command -v gh >/dev/null 2>&1; then
    NETINV_STATUS='gh is not installed, so no remote could be read'
  elif build_network_inventory > "$NETINV" 2>/dev/null && [ -s "$NETINV" ]; then
    NETINV_STATUS=ok
  else
    NETINV_STATUS='the remote sweep did not finish'
  fi
fi

run_check() {  # <slug> <band> <needs-network>
  local slug=$1 needs_net=$3 rc out
  if [ "$needs_net" = 1 ] && [ "$INCLUDE_NETWORK" -ne 1 ]; then
    emit U "$slug" 'network check, rerun with --include-network' >> "$RECORDS"
    return 0
  fi
  if [ "$needs_net" = 1 ] && [ "$NETINV_STATUS" != ok ]; then
    emit U "$slug" "$NETINV_STATUS" >> "$RECORDS"
    return 0
  fi
  out=$(FM_ROT_SNAPSHOT="$SNAP" FM_ROT_NETINV="$NETINV" FM_ROT_ALL_POOLS="$ALL_POOLS" FM_ROT_NOW="$NOW" \
    fm_run_timed "$CHECK_TIMEOUT" "$0" \
      --check-timeout "$CHECK_TIMEOUT" \
      --red-hours "$RED_HOURS" \
      --pr-green-days "$PR_GREEN_DAYS" \
      --dead-endpoint-hours "$DEAD_ENDPOINT_HOURS" \
      --decision-quiet-days "$DECISION_QUIET_DAYS" \
      --bead-stale-days "$BEAD_STALE_DAYS" \
      --stranded-commits "$STRANDED_COMMITS" \
      --internal-run-check "$slug" 2>/dev/null)
  rc=$?
  case "$rc" in
    0) [ -z "$out" ] || printf '%s\n' "$out" >> "$RECORDS" ;;
    124) emit U "$slug" "gave no answer within ${CHECK_TIMEOUT}s" >> "$RECORDS" ;;
    *) emit U "$slug" 'the check itself failed' >> "$RECORDS" ;;
  esac
  return 0
}

while IFS='|' read -r slug band needs_net _desc; do
  [ -n "$slug" ] || continue
  run_check "$slug" "$band" "$needs_net"
done <<EOF
$(printf '%s' "$CHECK_TABLE" | grep .)
EOF

# ---------------------------------------------------------------- model

TABLE_JSON=$(printf '%s' "$CHECK_TABLE" | grep . | jq -R -s -c '
  split("\n") | map(select(length > 0) | split("|")
  | {slug: .[0], band: .[1], network: (.[2] == "1"), description: .[3]})')

MODEL=$(jq -n -c \
  --arg us "$US" \
  --arg generated "$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg fm_home "$FM_HOME" \
  --argjson network "$([ "$INCLUDE_NETWORK" -eq 1 ] && echo true || echo false)" \
  --argjson checks "$TABLE_JSON" \
  --rawfile records "$RECORDS" '
  ($records | split("\n") | map(select(length > 0) | split($us))) as $rows
  | ($rows | map(select(.[0] == "F"))) as $fr
  | ($rows | map(select(.[0] == "U") | {check: .[1], reason: .[2]})) as $unknowns
  | [ $checks[] as $c
      | $fr[]
      | select(.[1] == $c.slug)
      | {check: .[1], band: $c.band, description: $c.description,
         subject: .[2],
         age_seconds: (if .[3] == "-" then null else (.[3] | tonumber? // null) end),
         detail: .[4], next: .[5]} ] as $findings
  | {
      schema: "fm-rot-report.v1",
      generated: $generated,
      fm_home: $fm_home,
      network_included: $network,
      finding_count: ($findings | length),
      findings: $findings,
      not_checked: $unknowns,
      checks: [ $checks[] as $c | $c + {
        findings: ([$findings[] | select(.check == $c.slug)] | length),
        unknowns: ([$unknowns[] | select(.check == $c.slug)] | length) } ]
    }
') || die 'building the report failed'

case "$FORMAT" in
  json) printf '%s\n' "$MODEL" | jq .; exit 0 ;;
  toon) : ;;
  text) : ;;
esac

if [ "$FORMAT" = toon ]; then
  printf '%s\n' "$MODEL" | jq -r '
    def q:
      tostring
      | if (. == "")
          or test("^\\s|\\s$")
          or (. == "true" or . == "false" or . == "null")
          or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
          or test("[:\"\\\\\\[\\]{},]")
          or test("[[:cntrl:]]")
          or test("^-")
        then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
        else . end;
    def scal:
      if . == null then "null"
      elif type == "boolean" then (if . then "true" else "false" end)
      elif type == "number" then tostring
      else q end;
    def emit($k; $v):
      if ($v | type) == "array" then
        if ($v | length) == 0 then "\($k): []"
        else
          ($v[0] | keys_unsorted) as $ks
          | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
              ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
        end
      else "\($k): " + ($v | scal)
      end;
    [ to_entries[] | emit(.key; .value) ] | join("\n")
  ' || die 'rendering failed'
  exit 0
fi

# ---------------------------------------------------------------- text

fmt_age() {  # <seconds|null>
  local s=$1
  case "$s" in
    ''|null|-) printf 'age unknown'; return 0 ;;
    *[!0-9]*) printf 'age unknown'; return 0 ;;
  esac
  if [ "$s" -lt 3600 ]; then printf '%dmin' $((s / 60))
  elif [ "$s" -lt 172800 ]; then printf '%dh' $((s / 3600))
  else printf '%dd' $((s / 86400))
  fi
}

COUNT=$(printf '%s' "$MODEL" | jq -r '.finding_count')
if [ "$COUNT" -eq 0 ]; then
  printf 'fm-rot-report: nothing rotting\n'
else
  printf 'fm-rot-report: %s finding(s)\n' "$COUNT"
fi

for band in S1 S2 S3 S4; do
  rows=$(printf '%s' "$MODEL" | jq -r --arg b "$band" '
    .findings[] | select(.band == $b) | [.check, .subject, (.age_seconds // "-" | tostring), .detail, .next] | @tsv')
  [ -n "$rows" ] || continue
  printf '\n%s  %s\n' "$band" "$(band_title "$band")"
  while IFS=$'\t' read -r check subject age detail next; do
    [ -n "$check" ] || continue
    printf '  [%s] %s - %s\n' "$check" "$subject" "$(fmt_age "$age")"
    printf '      %s\n' "$detail"
    printf '      next: %s\n' "$next"
  done <<EOF
$rows
EOF
done

NOTCHECKED=$(printf '%s' "$MODEL" | jq -r '.not_checked[] | [.check, .reason] | @tsv')
if [ -n "$NOTCHECKED" ]; then
  printf '\nnot checked\n'
  while IFS=$'\t' read -r check reason; do
    [ -n "$check" ] || continue
    printf '  %-24s %s\n' "$check" "$reason"
  done <<EOF
$NOTCHECKED
EOF
fi
printf '\nEvery check not listed above ran and found nothing.\n'
exit 0
