#!/usr/bin/env bash
# fm-stalled-work.sh - list captain-authorized work that is blocked, never
# started, or stalled, in a form that reaches the captain.
#
# Usage: fm-stalled-work.sh [--json | --plain] [--quiet] [--resume] [--notify] [--help]
#
# Why: work the captain authorized can sit blocked for weeks with its only
# record a note on a bead. This is the read-only sweep behind the NOT DONE
# delivery surfaces (bin/fm-session-start.sh, bin/fm-wake-drain.sh on a
# heartbeat wake, and the not_done[] list in bin/fm-bearings-snapshot.sh).
# It never writes to any bead store or the summary cache and never spawns; its
# only remote contact is the read of a remote home's published summary.
#
# Classes (one row per item, oldest first):
#   blocked    a blocked bead in the task store, a backlog row with a recorded
#              blocked reason, or an in-flight item whose latest status event
#              is blocked or failed for at least FM_STALLED_BLOCKED_MIN_SECONDS.
#   unstarted  a queued ship or scout with no dependency, hold, or date gate
#              that was filed more than FM_STALLED_GRACE_HOURS ago.
#   stalled    an in-flight item with no status event for FM_STALLED_STALL_HOURS.
# Skipped: captain-held decisions (hold kind captain, or a captain or decision
# kind), rows gated on unfinished work, a future hold date, external holds,
# and in-flight items that declared paused, needs-decision, or done.
#
# Sources, all read-only:
#   - The main backlog, through bin/fm-fleet-snapshot.sh --contribution-input.
#   - state/<id>.status for last-event age (the latest [at=<epoch>] tag, else
#     the file's modification time, else the backlog row's filed date).
#   - Every registered secondmate home through its published home summary: a
#     remote home's state/home-summary.json is read live through fm-on.sh
#     (concurrent, bounded at 8 seconds); a local home's own
#     state/home-summary.json is read directly. Only when the live read fails
#     does the newest matching copy in the parent-side cache
#     state/secondmate-summary-cache answer. A remote home republishes its
#     summary only at session start, spawn, and teardown, so a summary can lag
#     work the home has since closed: whatever its source, a summary over a day
#     old (or with no generated_epoch) is listed in the unavailable list with
#     its age instead of judged. Summaries carry no per-item event age, so only
#     queued and blocked rows are judged there. A row with no recorded date
#     shows its age as "unknown". FM_STALLED_REMOTE_FETCH=0 skips the live read
#     for a caller that has just refreshed the cache itself
#     (bin/fm-bearings-snapshot.sh, after its fleet snapshot).
#   - `task list --status blocked --json` when the task CLI is on PATH. A
#     failure or an absent CLI is reported under unavailable, never as
#     "nothing blocked". A bead that a backlog item names is annotated with
#     that item instead of being treated as unowned.
#
# Output: TOON by default, --json for the same model, --plain for the captain
# list ("Not done: <title> (<id>) - <state> <age>: <why> - <needs>").
#   not_done[N]{home,id,title,state,since,why,needs}
#   needs is `captain: <what>`, `resumes: <when or condition>`, or
#   `firstmate: <action>`. why is one scrubbed line with no raw paths.
#   unavailable[M]{source,reason} lists every source that could not be read.
# --quiet prints nothing and exits 0 when nothing is waiting and every source
# was read; if a source was unreadable it prints just that one line, so a
# silent run never means "unchecked". The delivery surfaces call --quiet --plain.
#
# Quota self-heal: a blocker whose text matches quota, exhausted_now,
# 0% remaining, or "no quota on the configured route" gets
# `needs: resumes: when a configured route has runway`. --resume reads the
# current quota-axi TOON and, only when at least one candidate row has a runway
# other than exhausted_now, EMITS (never runs) the exact
# bin/fm-dispatch-resolve.sh and bin/fm-spawn.sh lines for each such queued
# backlog row, using the project's registered posture as the starting point
# firstmate confirms at intake. An in-flight row gets the bin/fm-control.sh
# relaunch line instead. Firstmate runs the emitted lines itself.
#
# --notify compares the current rows (home, id, state) against
# state/stalled-work.last. Only when they differ does it print a plain list,
# ready to paste into ONE `status comment status-kvo` call, and then record the
# new rows in that file. Unchanged prints nothing. It never calls a store CLI
# to write. Firstmate runs `bin/fm-stalled-work.sh --notify` on each heartbeat
# and posts any output to status-kvo.
#
# Environment: FM_HOME selects the home. FM_STALLED_GRACE_HOURS (default 24),
# FM_STALLED_STALL_HOURS (default 48), FM_STALLED_BLOCKED_MIN_SECONDS (default
# 3600), and FM_STALLED_NOW (epoch seconds, tests) tune the sweep.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

FORMAT=toon QUIET=0 RESUME=0 NOTIFY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --json) FORMAT=json ;;
    --plain) FORMAT=plain ;;
    --toon) FORMAT=toon ;;
    --quiet) QUIET=1 ;;
    --resume) RESUME=1 ;;
    --notify) NOTIFY=1 ;;
    *) printf 'fm-stalled-work: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo 'fm-stalled-work: jq is required' >&2; exit 1; }

GRACE_H=${FM_STALLED_GRACE_HOURS:-24}
STALL_H=${FM_STALLED_STALL_HOURS:-48}
BLOCKED_MIN=${FM_STALLED_BLOCKED_MIN_SECONDS:-3600}
for v in "$GRACE_H" "$STALL_H" "$BLOCKED_MIN"; do
  case "$v" in '' | *[!0-9]*) echo 'fm-stalled-work: tuning values must be whole numbers' >&2; exit 2 ;; esac
done
NOW=${FM_STALLED_NOW:-$(date -u +%s)}

UNAVAIL='[]'
unavailable() {  # <source> <reason>
  UNAVAIL=$(printf '%s' "$UNAVAIL" | jq -c --arg s "$1" --arg r "$2" '. + [{source:$s,reason:$r}]')
}

# --- main backlog -----------------------------------------------------------
BACKLOG='[]'
if raw=$(FM_HOME="$FM_HOME" fm_run_timed 90 "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input 2>/dev/null) \
  && printf '%s' "$raw" | jq -e '.backlog.records | type == "array"' >/dev/null 2>&1; then
  BACKLOG=$(printf '%s' "$raw" | jq -c '.backlog.records')
else
  unavailable backlog 'the backlog snapshot could not be read'
fi

# --- last status event per in-flight id -------------------------------------
STATUSES='{}'
while IFS= read -r id; do
  [ -n "$id" ] || continue
  case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac
  f="$STATE/$id.status"
  [ -f "$f" ] || continue
  last=$(tail -n 40 "$f" 2>/dev/null | grep . | tail -n 1)
  [ -n "$last" ] || continue
  at=$(tail -n 40 "$f" 2>/dev/null | grep -o '\[at=[0-9]\{1,12\}\]' | tail -n 1 | tr -dc '0-9')
  if [ -z "$at" ]; then
    at=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || printf '')
  fi
  [ -n "$at" ] || continue
  STATUSES=$(printf '%s' "$STATUSES" | jq -c --arg id "$id" --arg line "$last" --argjson at "$at" '
    ($line | split(" ")[0]) as $verb
    | . + {($id): {at:$at, verb:$verb, text:($line | sub("^[^:]*: *";""))}}')
done < <(printf '%s' "$BACKLOG" | jq -r '.[] | select(.state == "in_flight") | .id')

# --- blocked beads ----------------------------------------------------------
BEADS='[]'
if ! command -v task >/dev/null 2>&1; then
  unavailable 'task store' 'the task CLI is not on PATH, so blocked beads were not checked'
elif raw=$(fm_run_timed 30 task list --status blocked --json 2>/dev/null) \
  && printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
  BEADS=$raw
else
  unavailable 'task store' 'the task store could not be read, so blocked beads were not checked'
fi

# --- registered secondmate homes (published summaries only) -----------------
# A remote home's summary is read live first (the same fm-on.sh read the fleet
# snapshot uses, concurrent and bounded). Only when that read fails does the
# parent-side cache answer, and then the newest cached copy for the home wins.
# Any summary older than a day is disclosed instead of judged: it can no longer
# say what is unstarted now.
SMS='[]'
REG="$DATA/secondmates.md"
CACHE="$STATE/secondmate-summary-cache"
SUMMARY_MAX_BYTES=${FM_SNAPSHOT_SECONDMATE_MAX_BYTES:-262144}
# shellcheck disable=SC2016  # a jq filter fragment; $h is a jq variable
SUMMARY_OK='.schema == "fm-secondmate-home-summary.v1" and .home == $h and (.queued | type == "array")'
FETCH_DIR=''
if [ -f "$REG" ]; then
  FETCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-stalled-fetch.XXXXXX" 2>/dev/null) || FETCH_DIR=''
  trap '[ -z "$FETCH_DIR" ] || rm -rf "$FETCH_DIR"' EXIT
  if [ -n "$FETCH_DIR" ] && [ "${FM_STALLED_REMOTE_FETCH:-1}" != 0 ]; then
    while IFS= read -r line; do
      case "$line" in '- '*) ;; *) continue ;; esac
      secondmate_registry_parse_line "$line" || continue
      [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] || continue
      case "$SECONDMATE_REGISTRY_ID" in *[!A-Za-z0-9._-]*) continue ;; esac
      (
        FM_HOME="$FM_HOME" fm_run_timed 8 "$SCRIPT_DIR/fm-on.sh" "$SECONDMATE_REGISTRY_ID" \
          fm-remote-file.sh get state/home-summary.json "$SUMMARY_MAX_BYTES" 2>/dev/null \
          | LC_ALL=C head -c "$((SUMMARY_MAX_BYTES + 1))" > "$FETCH_DIR/$SECONDMATE_REGISTRY_ID.json"
      ) &
    done < "$REG"
    wait
  fi
  while IFS= read -r line; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    sid=$SECONDMATE_REGISTRY_ID shome=$SECONDMATE_REGISTRY_HOME summary=''
    if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
      if [ -n "$FETCH_DIR" ] && [ -s "$FETCH_DIR/$sid.json" ] \
        && [ "$(LC_ALL=C wc -c < "$FETCH_DIR/$sid.json" | tr -d ' ')" -le "$SUMMARY_MAX_BYTES" ]; then
        summary=$(jq -c -s --arg h "$shome" '.[0] | select(('"$SUMMARY_OK"'))' "$FETCH_DIR/$sid.json" 2>/dev/null | head -n 1)
      fi
    elif [ -f "$shome/state/home-summary.json" ]; then
      summary=$(cat "$shome/state/home-summary.json" 2>/dev/null)
    fi
    if [ -z "$summary" ] && [ -d "$CACHE" ]; then
      summary=$(cat "$CACHE"/*.json 2>/dev/null | jq -c -s --arg h "$shome" \
        '[.[] | select(('"$SUMMARY_OK"'))] | sort_by(.generated_epoch // 0) | last // empty' 2>/dev/null | head -n 1)
    fi
    if [ -z "$summary" ] || ! printf '%s' "$summary" | jq -e '.queued | type == "array"' >/dev/null 2>&1; then
      unavailable "secondmate $sid" 'no published home summary, so its queued work was not checked'
      continue
    fi
    gen=$(printf '%s' "$summary" | jq -r '.generated_epoch // 0')
    case "$gen" in '' | *[!0-9]*) gen=0 ;; esac
    if [ "$gen" -le 0 ]; then
      unavailable "secondmate $sid" 'its home summary has no generation time, so its queued work was not checked'
      continue
    fi
    if [ $((NOW - gen)) -gt 86400 ]; then
      unavailable "secondmate $sid" "its home summary is $(((NOW - gen) / 86400)) day(s) old, so its queued work was not checked"
      continue
    fi
    SMS=$(printf '%s' "$SMS" | jq -c --arg id "$sid" --argjson s "$summary" '
      . + [{id:$id, generated_epoch:($s.generated_epoch // 0), queued:$s.queued, holds:($s.holds // [])}]')
  done < "$REG"
fi

# --- classify ---------------------------------------------------------------
MODEL=$(jq -n -c \
  --argjson now "$NOW" --argjson grace "$((GRACE_H * 3600))" --argjson stall "$((STALL_H * 3600))" \
  --argjson blocked_min "$BLOCKED_MIN" \
  --argjson backlog "$BACKLOG" --argjson statuses "$STATUSES" --argjson beads "$BEADS" \
  --argjson sms "$SMS" --argjson unavail "$UNAVAIL" '
  def epoch_of($d):
    if $d == null or ($d | tostring) == "" then null
    else try (($d | tostring) | sub("\\.[0-9]+";"") | if test("T") then . else . + "T00:00:00Z" end | fromdateiso8601) catch null end;
  def human($s): if $s < 3600 then "\(($s / 60) | floor)m" elif $s < 172800 then "\(($s / 3600) | floor)h" else "\(($s / 86400) | floor)d" end;
  def scrub: ((. // "") | tostring) | gsub("(?<p>^|[ (])(~?/[A-Za-z0-9._~-]+){2,}"; "\(.p)<path>") | gsub("\\s+"; " ") | sub("^ +";"");
  def clip($n): if length > $n then .[0:($n - 3)] + "..." else . end;
  def quota_hit: ((. // "") | tostring) | test("quota|exhausted_now|0% remaining|no quota on the configured route"; "i");
  def captain_hit: ((. // "") | tostring) | test("needs the captain|needs your|captain (must|to |needs|decision|approval|login|call)|awaiting (the )?captain|waiting (on|for) (the )?captain|login required|credential"; "i");
  def resolved_hit: ((. // "") | tostring) | test("^ *RESOLVED"; "i");
  def needs_for($why; $default):
    if ($why | resolved_hit) then "firstmate: the note says the blocker is resolved, so unblock or close it"
    elif ($why | quota_hit) then "resumes: when a configured route has runway"
    elif ($why | captain_hit) then "captain: \($why | clip(100))"
    else $default end;
  def row($home; $id; $title; $state; $at; $why; $needs; $src; $extra):
    {home:$home, id:$id, title:($title | scrub | clip(80)), state:$state,
     since:(if $at == null then "unknown" else human($now - $at) end), why:($why | scrub | clip(140)), needs:$needs,
     age_seconds:(if $at == null then -1 else $now - $at end), source:$src, quota:(($why | quota_hit) or ($needs | startswith("resumes: when a configured")))} + $extra;
  def gated($r):
    ($r.hold_kind == "captain") or (($r.kind // "") | IN("captain", "decision", "secondmate"))
    or ((($r.unresolved_blocker_ids // []) | length) > 0)
    or ($r.hold_kind != null and ($r.hold_until == null or (epoch_of($r.hold_until) > $now)))
    or ($r.hold_until != null and (epoch_of($r.hold_until) > $now));
  def queued_row($home; $r):
    if gated($r) then empty
    elif $r.blocked_reason != null then
      row($home; $r.id; $r.title; "blocked"; epoch_of($r.since); $r.blocked_reason;
          needs_for($r.blocked_reason; "firstmate: clear the blocker or ask the captain to drop it"); "backlog"; {backlog_state:"queued", repo:($r.repo // null)})
    elif (epoch_of($r.since) | . == null or ($now - .) > $grace) then
      row($home; $r.id; $r.title; "unstarted"; epoch_of($r.since);
          "queued with no dependency or date gate and never dispatched"; "firstmate: dispatch it, or ask the captain whether to drop it"; "backlog"; {backlog_state:"queued", repo:($r.repo // null)})
    else empty end;
  def in_flight_row($r):
    if gated($r) or ($r.hold_kind != null) then empty
    else ($statuses[$r.id] // null) as $s
      | if $s != null and ($s.verb | IN("done", "paused", "needs-decision")) then empty
        elif $s != null and ($s.verb | IN("blocked", "failed")) then
          if ($now - $s.at) < $blocked_min then empty
          else row("main"; $r.id; $r.title; "blocked"; $s.at; $s.text;
                   needs_for($s.text; "firstmate: clear the blocker named in why"); "status"; {backlog_state:"in_flight", repo:($r.repo // null)}) end
        else ((if $s != null then $s.at else epoch_of($r.since) end)) as $at
          | if $at == null or ($now - $at) > $stall then
              row("main"; $r.id; $r.title; "stalled"; $at;
                  (if $s != null then "no status event since the last report" else "in flight with no status event on record" end);
                  "firstmate: check the worker and relaunch or close it"; "status"; {backlog_state:"in_flight", repo:($r.repo // null)})
            else empty end
        end
    end;
  def covered_by($id):
    [$backlog[] | select(.id != $id and (((.raw // "") + " " + ((.body_lines // []) | join(" "))) | contains($id)))
     | {id, state, title_hit: ((.raw // "") | contains($id))}]
    | sort_by([(if .title_hit then 0 else 1 end), (if .state == "done" then 0 elif .state == "in_flight" then 1 else 2 end)])
    | .[0] // null;
  def bead_row($b):
    (($b.notes // "") + " " + ($b.description // "")) as $all
    | ((($b.notes // "") | split("\n") | map(select(test("^\\s*(#|$)") | not)) | join(" "))
       | if . == "" then ($b.description // "") else . end | gsub("\\s+"; " ")) as $text
    | ($text | split(". ")) as $sentences
    | ((($sentences | map(select(quota_hit or test("block|waiting|not launched|needs|requires"; "i"))) | .[0]) // $sentences[0]) // "") as $why0
    | covered_by($b.id) as $by
    | (if $text == "" then "blocked with no reason recorded on the bead" else $why0 end) as $why
    | row("main"; $b.id; $b.title; "blocked"; epoch_of($b.created_at); $why;
          (if $by != null and $by.state == "done" then "firstmate: close the bead, its work landed as \($by.id)"
           elif $by != null then "firstmate: update or close the bead, its work is tracked as \($by.id)"
           elif $text == "" then "firstmate: record why it is blocked, or close the bead"
           elif ($all | quota_hit) then "resumes: when a configured route has runway"
           else needs_for($why; "firstmate: triage the bead, no unblock condition is recorded") end);
          "bead"; {covered_by:($by.id // null)});
  ( [ $backlog[] | select(.state == "queued") | queued_row("main"; .) ]
  + [ $backlog[] | select(.state == "in_flight") | in_flight_row(.) ]
  + [ $beads[] | bead_row(.) ]
  + [ $sms[] as $m | $m.queued[] | queued_row($m.id; .) ]
  + [ $sms[] as $m | $m.holds[] | select(.source == "child-state")
      | row($m.id; .id; .title; "blocked"; ($m.generated_epoch // $now); .reason;
            needs_for(.reason; "firstmate: ask the secondmate to clear the blocker"); "secondmate-ledger"; {}) ]
  ) as $rows
  | ($rows | group_by(.home + "\u0000" + .id) | map(sort_by(-.age_seconds)[0]) | sort_by(-.age_seconds)) as $dedup
  | {schema:"fm-stalled-work.v1", generated:($now | todate), count:($dedup | length),
     not_done:$dedup, unavailable:$unavail}
')
[ -n "$MODEL" ] || { echo 'fm-stalled-work: classification failed' >&2; exit 1; }
COUNT=$(printf '%s' "$MODEL" | jq -r '.count')
UNAVAIL_N=$(printf '%s' "$MODEL" | jq -r '.unavailable | length')

# --- --resume: emit, never run ----------------------------------------------
RESUME_LINES=''
if [ "$RESUME" -eq 1 ]; then
  QUOTA_ROWS=$(printf '%s' "$MODEL" | jq -r '[.not_done[] | select(.quota)] | length')
  if [ "$QUOTA_ROWS" -gt 0 ]; then
    qout=''
    command -v quota-axi >/dev/null 2>&1 && qout=$(fm_run_timed 45 quota-axi 2>/dev/null)
    runway=$(printf '%s\n' "$qout" | awk '
      /^quota\[[0-9]+\]\{/ { n = split(substr($0, index($0, "{") + 1), h, /[,}]/); for (i = 1; i <= n; i++) if (h[i] == "runway") col = i; inq = 1; next }
      /^[^ ]/ { inq = 0 }
      inq && col {
        s = $0; sub(/^ +/, "", s); f = 0; field = ""; q = 0; out = ""
        for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
          if (c == "\"") q = !q
          else if (c == "," && !q) { f++; if (f == col) out = field; field = "" }
          else field = field c }
        f++; if (f == col) out = field
        if (out != "" && out != "exhausted_now") { found = 1 }
      }
      END { print found ? "yes" : "no" }')
    if [ -z "$qout" ]; then
      RESUME_LINES='resume: quota-axi is unavailable, so no route could be confirmed; nothing emitted'
    elif [ "$runway" != yes ]; then
      RESUME_LINES='resume: no configured route has runway yet; nothing emitted'
    else
      while IFS=$'\t' read -r id bstate repo src; do
        [ -n "$id" ] || continue
        if [ "$src" != backlog ] && [ "$src" != status ]; then
          RESUME_LINES+="resume $id: a route has runway but no backlog item owns this work; file one, then dispatch it"$'\n'
        elif [ "$bstate" = in_flight ]; then
          RESUME_LINES+="resume $id: a route has runway; relaunch the stopped worker: bin/fm-control.sh $id relaunch"$'\n'
        else
          posture=$("$SCRIPT_DIR/fm-project-mode.sh" "$repo" 2>/dev/null) || posture='no-mistakes off'
          mode=${posture%% *} yolo=${posture##* }
          RESUME_LINES+="resume $id: a route has runway; dispatch with the registered posture (confirm at intake):"$'\n'
          RESUME_LINES+="  bin/fm-dispatch-resolve.sh data/$id/brief.md --project $repo"$'\n'
          RESUME_LINES+="  bin/fm-spawn.sh $id projects/$repo --mode $mode --yolo $yolo"$'\n'
        fi
      done < <(printf '%s' "$MODEL" | jq -r '.not_done[] | select(.quota and .home == "main") | [.id, (.backlog_state // ""), (.repo // ""), .source] | @tsv')
    fi
  fi
fi

# --- rendering --------------------------------------------------------------
plain_list() {  # <model-json>
  printf '%s' "$1" | jq -r '.not_done[]
    | "Not done: \(.title) (\(.id)\(if .home == "main" then "" else " on " + .home end)) - \(.state) \(.since): \(.why) - \(.needs)"'
}
unavailable_list() {
  printf '%s' "$MODEL" | jq -r '.unavailable[] | "Not checked: \(.source) - \(.reason)"'
}

render() {
  case "$FORMAT" in
    json)
      if [ -n "$RESUME_LINES" ]; then
        printf '%s' "$MODEL" | jq --arg r "$RESUME_LINES" '. + {resume:($r | split("\n") | map(select(. != "")))}'
      else
        printf '%s' "$MODEL" | jq .
      fi ;;
    plain)
      plain_list "$MODEL"
      unavailable_list
      [ -z "$RESUME_LINES" ] || printf '%s\n' "$RESUME_LINES" | grep . ;;
    *)
      printf '%s' "$MODEL" | jq -r '
        def q:
          tostring
          | if (. == "") or test("^\\s|\\s$") or (. == "true" or . == "false" or . == "null")
               or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
               or test("[:\"\\\\\\[\\]{},]") or test("[[:cntrl:]]") or test("^-")
            then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
            else . end;
        def table($k; $ks; $rows):
          if ($rows | length) == 0 then "\($k): []"
          else "\($k)[\($rows | length)]{\($ks | join(","))}:",
               ($rows[] as $r | "  " + ([ $ks[] as $f | ($r[$f] | q) ] | join(",")))
          end;
        "schema: \(.schema)", "generated: \(.generated)", "count: \(.count)",
        table("not_done"; ["home","id","title","state","since","why","needs"]; .not_done),
        (if (.unavailable | length) > 0 then table("unavailable"; ["source","reason"]; .unavailable) else empty end)'
      [ -z "$RESUME_LINES" ] || printf '%s\n' "$RESUME_LINES" | grep . ;;
  esac
}

# --- --notify: change detection ---------------------------------------------
if [ "$NOTIFY" -eq 1 ]; then
  LAST="$STATE/stalled-work.last"
  CUR=$(printf '%s' "$MODEL" | jq -r '.not_done[] | "\(.home)|\(.id)|\(.state)"' | sort)
  PREV=''
  [ -f "$LAST" ] && PREV=$(sort "$LAST" 2>/dev/null)
  if [ "$CUR" = "$PREV" ]; then
    exit 0
  fi
  # A source that could not be read must not read as "everything cleared".
  if [ "$UNAVAIL_N" -gt 0 ] && [ "$COUNT" -eq 0 ] && [ -n "$PREV" ]; then
    unavailable_list
    exit 0
  fi
  if [ "$COUNT" -gt 0 ]; then
    printf 'Not done (%s item(s) waiting on the captain or the fleet; list changed since the last notice):\n' "$COUNT"
    plain_list "$MODEL"
  else
    printf 'Not done: nothing is waiting now.\n'
  fi
  [ "$UNAVAIL_N" -eq 0 ] || unavailable_list
  cleared=$(comm -13 <(printf '%s\n' "$CUR" | cut -d'|' -f1,2 | sort -u) <(printf '%s\n' "$PREV" | cut -d'|' -f1,2 | sort -u) | grep . | tr '\n' ' ')
  [ -z "$cleared" ] || printf 'Cleared since the last notice: %s\n' "$cleared"
  mkdir -p "$STATE" 2>/dev/null || :
  { [ -z "$CUR" ] || printf '%s\n' "$CUR"; } > "$LAST.tmp.$$" 2>/dev/null && mv -f "$LAST.tmp.$$" "$LAST" 2>/dev/null || :
  exit 0
fi

if [ "$QUIET" -eq 1 ] && [ "$COUNT" -eq 0 ]; then
  [ "$UNAVAIL_N" -eq 0 ] || unavailable_list
  exit 0
fi

render
