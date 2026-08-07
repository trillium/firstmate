#!/usr/bin/env bash
# fm-herdr-spur.sh - bridge that SPURS firstmate when an EXTERNAL herdr agent
# finishes (working -> idle | working -> done), by enqueuing a durable wake into
# firstmate's own state/.wake-queue so fm-wake-drain surfaces it and firstmate
# reacts. This closes the reactive gap where a herdr agent NOT spawned by
# firstmate (e.g. a parlay-spawned agent) has no state/<id>.status file and no
# turn-end hook, so firstmate never learns it finished.
#
# WHY A SEPARATE BRIDGE (not the built-in herdr backend push).
# firstmate ALREADY has a native herdr push path
# (bin/backends/herdr.sh fm_backend_herdr_wait_transition, wire reader
# bin/backends/herdr-eventwait.py). That path only watches panes that firstmate
# itself spawned (recorded in state/<id>.meta window=), and its policy
# (bin/fm-transition-lib.sh) deliberately DEFERS idle/done because a
# firstmate-spawned crew's completion is already caught by its status file and
# turn-end hook. An EXTERNAL agent has neither, so for it idle/done IS the only
# completion signal. This bridge reuses the SAME wire reader and the SAME
# normalized-record shape, but applies a spur-specific edge policy: a
# working->idle or working->done transition on a TRACKED external agent is the
# actionable edge.
#
# WHAT IT ENQUEUES.
# The durable wake queue (state/.wake-queue) is written only through
# fm-wake-lib.sh's fm_wake_append, whose kind is validated against
# signal|stale|check|heartbeat. An external-agent completion is not a
# firstmate-task status signal or a stale-pane read, so it rides the `check`
# kind - the "per-task slow poll fired, always actionable" lane the watcher
# already treats as unconditionally surfaced. The record written is:
#     <epoch>\t<seq>\tcheck\therdr-spur:<agent>\t<reason>
# where <reason> is a human-readable "herdr agent <name> went <status> (was
# working)" line. fm-wake-drain prints it verbatim as a `check:` wake and
# firstmate acts on it exactly like any other actionable wake.
#
# NATIVE PUSH vs POLL.
# When the herdr server is events-capable (protocol >= 16, events.subscribe +
# pane.agent_status_changed in `herdr api schema`), the bridge BLOCKS on the
# native pane.agent_status_changed stream via herdr-eventwait.py and reacts
# sub-second - no polling. When it is not capable (or the socket/reader is
# unusable), it falls back to a lightweight periodic `herdr agent list` poll.
# Both paths share one normalize + edge-detect + enqueue core.
#
# OWNED-AGENT FILTER.
# EXTERNAL is enforced, not assumed. `herdr agent list` reports every agent in
# the session, including the panes firstmate itself spawned, so before enqueuing
# a finish edge the bridge resolves the pane back to a firstmate task through
# window_owner_task (bin/fm-classify-lib.sh) and drops the edge when one owns it.
# Without that, every firstmate-owned agent wakes firstmate twice per turn-end -
# once legitimately via its status append, once spuriously here - and the channel
# stops meaning "an agent firstmate cannot otherwise see".
#
# DEBOUNCE.
# Edges are computed against a remembered last-status per agent (in-memory for
# the process). Only working->{idle,done} fires. A subsequent working edge
# re-arms the agent, so a real finish after a resumed turn spurs again, but
# idle/done flapping without an intervening working edge fires at most once.
#
# CONFIGURABLE.
# Which agents to watch is resolved, in order:
#   1. --agent <name> flags (repeatable) on the command line;
#   2. config/herdr-spur.agents (one agent name per line, # comments allowed);
#   3. otherwise ALL agents herdr currently reports (auto-track every agent).
# --session <name> selects the herdr session (default: "default").
# --once runs a single poll pass and exits (used by the smoke test).
# --self-detach re-execs the process detached (setsid + nohup) so it survives
#   the launching shell / firstmate compaction; the captain's rule: processes
#   survive, context does not.
#
# SAFETY. This bridge is READ-ONLY against herdr: it only ever runs
# `herdr agent list`, `herdr api schema`, `herdr session list`, and the
# read-only event subscription. It never sends, focuses, renames, or tears down
# anything. It only WRITES to firstmate's own state/.wake-queue via the
# sanctioned fm_wake_append helper.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-transition-lib.sh
. "$SCRIPT_DIR/fm-transition-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

FM_HERDR_SPUR_SESSION="${FM_HERDR_SPUR_SESSION:-default}"
FM_HERDR_SPUR_POLL_INTERVAL="${FM_HERDR_SPUR_POLL_INTERVAL:-5}"   # seconds between poll passes (poll fallback)
FM_HERDR_SPUR_EVENT_BUDGET="${FM_HERDR_SPUR_EVENT_BUDGET:-3600}"  # seconds per event-wait block before reconcile
FM_HERDR_SPUR_AGENTS_FILE="${FM_HERDR_SPUR_AGENTS_FILE:-$FM_HOME/config/herdr-spur.agents}"
FM_HERDR_SPUR_LOG="${FM_HERDR_SPUR_LOG:-$STATE/.herdr-spur.log}"

# --- CLI ---------------------------------------------------------------------
MODE=loop            # loop | once
DO_DETACH=false
declare -a WATCH_AGENTS=()

usage() {
  cat >&2 <<'EOF'
Usage: fm-herdr-spur.sh [options]
  --agent <name>     watch this agent (repeatable; overrides config file)
  --session <name>   herdr session (default: "default")
  --once             run one poll pass and exit (no event-wait, no loop)
  --self-detach      re-exec detached so the daemon survives its parent
  --interval <secs>  poll-fallback interval (default: 5)
  -h, --help         show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agent) WATCH_AGENTS+=("$2"); shift 2 ;;
    --session) FM_HERDR_SPUR_SESSION="$2"; shift 2 ;;
    --once) MODE=once; shift ;;
    --self-detach) DO_DETACH=true; shift ;;
    --interval) FM_HERDR_SPUR_POLL_INTERVAL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-herdr-spur: unknown arg: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

log() { printf '%s %s\n' "$(date +%FT%T%z)" "$*" >> "$FM_HERDR_SPUR_LOG" 2>/dev/null || true; }

# --- self-detach: robust survival across shell/context death -----------------
# Re-exec via setsid (Linux) or nohup+disown fallback, dropping --self-detach so
# the child runs the real loop. All state truth lives in files, so a restart is
# a non-event.
if [ "$DO_DETACH" = true ]; then
  args=()
  [ "$MODE" = once ] && args+=(--once)
  args+=(--session "$FM_HERDR_SPUR_SESSION" --interval "$FM_HERDR_SPUR_POLL_INTERVAL")
  for a in "${WATCH_AGENTS[@]:-}"; do [ -n "$a" ] && args+=(--agent "$a"); done
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$SCRIPT_DIR/fm-herdr-spur.sh" "${args[@]}" >/dev/null 2>&1 &
  else
    nohup "$SCRIPT_DIR/fm-herdr-spur.sh" "${args[@]}" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
  printf 'fm-herdr-spur: detached daemon started (session=%s, pid=%s)\n' \
    "$FM_HERDR_SPUR_SESSION" "$!"
  log "detached daemon started session=$FM_HERDR_SPUR_SESSION pid=$!"
  exit 0
fi

# --- herdr reads (read-only) -------------------------------------------------
# fm_herdr_spur_snapshot: emit one TAB line per agent for the session:
#   <agent-name>\t<pane_id>\t<workspace_id>\t<agent_status>
# agent-name falls back to the pane_id when herdr reports no explicit name.
fm_herdr_spur_snapshot() {
  herdr agent list --session "$FM_HERDR_SPUR_SESSION" 2>/dev/null \
    | jq -r '.result.agents[]?
        | [ (.name // .pane_id), .pane_id, .workspace_id, .agent_status ]
        | @tsv' 2>/dev/null
}

# Non-session-scoped fallback (default session may reject --session on some
# builds); try the plain form when the scoped form yields nothing.
fm_herdr_spur_snapshot_any() {
  local out
  out=$(fm_herdr_spur_snapshot)
  if [ -z "$out" ]; then
    out=$(herdr agent list 2>/dev/null \
      | jq -r '.result.agents[]?
          | [ (.name // .pane_id), .pane_id, .workspace_id, .agent_status ]
          | @tsv' 2>/dev/null)
  fi
  # Emit with a trailing newline so `read` in the consuming while-loop does not
  # drop the final agent (command substitution strips trailing newlines).
  [ -n "$out" ] && printf '%s\n' "$out"
}

# --- watch-set resolution ----------------------------------------------------
# Prints the newline-separated set of agent names to watch. Empty output means
# "watch every agent herdr currently reports".
fm_herdr_spur_watch_set() {
  if [ "${#WATCH_AGENTS[@]}" -gt 0 ]; then
    printf '%s\n' "${WATCH_AGENTS[@]}"
    return 0
  fi
  if [ -f "$FM_HERDR_SPUR_AGENTS_FILE" ]; then
    grep -vE '^[[:space:]]*(#|$)' "$FM_HERDR_SPUR_AGENTS_FILE" 2>/dev/null \
      | sed 's/[[:space:]]*$//'
    return 0
  fi
  return 0  # empty = all
}

fm_herdr_spur_in_watch_set() {  # <agent> <watch-set-newline-list>
  local agent=$1 set=$2
  [ -z "$set" ] && return 0  # empty set = all
  printf '%s\n' "$set" | grep -Fxq -- "$agent"
}

# --- edge detection + enqueue ------------------------------------------------
# LAST_STATUS_<safekey> holds the previously-seen status per agent for debounce.
# A working->{idle,done} edge on a watched agent enqueues one `check` wake.
fm_herdr_spur_safekey() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'; }

# fm_herdr_spur_edge_policy: the spur-specific edge policy for EXTERNAL agents.
# Returns 0 (spur) only for a fresh working->{idle,done} finish edge; 1
# otherwise. Deliberately different from fm_transition_policy, whose `defer` on
# idle/done is correct for firstmate-OWNED tasks (caught by status/turn-end) but
# would swallow an external agent's only completion signal.
fm_herdr_spur_edge_policy() {  # <from> <to>
  local from=$1 to=$2
  [ "$from" = "working" ] || return 1
  case "$to" in
    idle|done) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_herdr_spur_pane_owner: print the firstmate task id that owns <pane_id>, or
# return 1 (printing nothing) when no task in this home does. Ownership decides
# the bridge's whole scope: a firstmate-SPAWNED agent already reports completion
# through its state/<id>.status append and turn-end hook, so spurring on its
# idle/done edge would wake firstmate TWICE per turn-end and bury the genuinely
# invisible external agents this channel exists to surface.
#
# The lookup is window_owner_task's strict state/*.meta scan
# (bin/fm-classify-lib.sh) - strict because "nobody owns this pane" must be a
# real answer, not window_to_task's always-something fallback. herdr records
# window= as "<session>:<pane-id>" (bin/backends/herdr.sh's target shape) while
# both `herdr agent list` and the event stream report the BARE pane id, so the
# bare form alone never matches a herdr-backed task's meta; try both shapes.
# Checked at each finish EDGE rather than once at subscribe time, so a task
# spawned or torn down mid-stream is classified against current metadata.
fm_herdr_spur_pane_owner() {  # <pane_id>
  local pane=$1
  [ -n "$pane" ] || return 1
  window_owner_task "$pane" "$STATE" && return 0
  window_owner_task "${FM_HERDR_SPUR_SESSION}:${pane}" "$STATE" && return 0
  return 1
}

# Enqueue one spur wake for <agent> reaching <status>, unless the pane belongs to
# a firstmate task (which reports its own completion; see fm_herdr_spur_pane_owner).
fm_herdr_spur_spur_or_skip() {  # <agent> <status> <pane_id>
  local agent=$1 status=$2 pane=$3 owner
  if owner=$(fm_herdr_spur_pane_owner "$pane"); then
    log "SKIP-OWNED agent=$agent status=$status pane=$pane task=$owner"
    return 0
  fi
  fm_herdr_spur_enqueue "$agent" "$status" "$pane"
}

# Enqueue one spur wake for <agent> reaching <status>.
fm_herdr_spur_enqueue() {  # <agent> <status> <pane_id>
  local agent=$1 status=$2 pane=$3 reason
  reason="herdr agent ${agent} went ${status} (was working; external agent, no firstmate status file) pane=${pane}"
  if fm_wake_append check "herdr-spur:${agent}" "$reason"; then
    log "SPUR agent=$agent status=$status pane=$pane"
    printf 'fm-herdr-spur: spurred firstmate: %s\n' "$reason" >&2
    return 0
  fi
  log "SPUR-FAILED agent=$agent status=$status pane=$pane"
  return 1
}

# fm_herdr_spur_reconcile: read the current snapshot, and for every watched
# agent whose status transitioned working->{idle,done} since last seen, enqueue
# a spur. Updates the in-memory last-status. This is the shared core used by
# BOTH the poll fallback and the post-event level-reconcile.
fm_herdr_spur_reconcile() {  # <watch-set>
  local watch_set=$1 line agent pane ws status key prev prev_var
  while IFS=$'\t' read -r agent pane ws status; do
    [ -n "$agent" ] || continue
    fm_herdr_spur_in_watch_set "$agent" "$watch_set" || continue
    key=$(fm_herdr_spur_safekey "$agent")
    prev_var="LAST_STATUS_${key}"
    prev="${!prev_var:-}"
    if [ -n "$prev" ] && fm_herdr_spur_edge_policy "$prev" "$status"; then
      fm_herdr_spur_spur_or_skip "$agent" "$status" "$pane"
    fi
    printf -v "$prev_var" '%s' "$status"
  done < <(fm_herdr_spur_snapshot_any)
}

# --- capability probe (mirror fm_backend_herdr_events_capable, lightweight) ---
fm_herdr_spur_events_capable() {
  command -v jq >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local protocol schema
  protocol=$(herdr status --json 2>/dev/null | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in ''|*[!0-9]*) return 1 ;; esac
  [ "$protocol" -ge 16 ] || return 1
  schema=$(herdr api schema --json 2>/dev/null) || return 1
  printf '%s' "$schema" | grep -Fq 'events.subscribe' || return 1
  printf '%s' "$schema" | grep -Fq 'pane.agent_status_changed' || return 1
  return 0
}

fm_herdr_spur_socket_path() {
  herdr session list --json 2>/dev/null \
    | jq -r --arg name "$FM_HERDR_SPUR_SESSION" \
        '.sessions[]? | select(.name == $name) | .socket_path // empty' 2>/dev/null \
    | head -1
}

# --- the event-wait block: reuse herdr-eventwait.py ---------------------------
# Subscribe to pane.agent_status_changed for every currently-watched pane, and
# for each streamed edge run the shared edge policy + enqueue. Returns when the
# reader exits (budget elapsed or stream closed); the loop then reconciles
# levels and re-subscribes (panes may have appeared/disappeared).
# Note: this machine's bash is 3.2 (no associative arrays), matching the house
# rule in bin/backends/herdr.sh. pane->agent mapping is stored in per-pane
# dynamic variables PANE_AGENT_<safekey(pane_id)>, read via indirection.
fm_herdr_spur_event_block() {  # <watch-set>
  local watch_set=$1 sock reader_py agent pane ws status key
  local pane_ids=""
  sock=$(fm_herdr_spur_socket_path)
  [ -n "$sock" ] || return 2
  reader_py="$SCRIPT_DIR/backends/herdr-eventwait.py"
  [ -f "$reader_py" ] || return 2

  # Build pane list for watched agents, seed last-status so the first streamed
  # edge has a `from`, and record each pane's agent name for the reverse lookup.
  while IFS=$'\t' read -r agent pane ws status; do
    [ -n "$agent" ] || continue
    fm_herdr_spur_in_watch_set "$agent" "$watch_set" || continue
    pane_ids="$pane_ids $pane"
    key=$(fm_herdr_spur_safekey "$agent")
    printf -v "LAST_STATUS_${key}" '%s' "$status"
    printf -v "PANE_AGENT_$(fm_herdr_spur_safekey "$pane")" '%s' "$agent"
  done < <(fm_herdr_spur_snapshot_any)
  # shellcheck disable=SC2086
  set -- $pane_ids
  [ "$#" -gt 0 ] || return 2

  # Stream. herdr-eventwait.py prints "@subscribed" then TAB lines:
  #   <pane_id>\t<workspace_id>\t<agent_status>\t<agent>
  local pane_id ev_ws ev_status ev_agent name prev prev_var pa_var
  local saw_subscribed=false
  # shellcheck disable=SC2034 # ev_ws is a positional field in the stream, deliberately unused here.
  while IFS=$'\t' read -r pane_id ev_ws ev_status ev_agent; do
    if [ "$pane_id" = "@subscribed" ]; then
      saw_subscribed=true
      log "subscribed panes=$#"
      continue
    fi
    [ -n "$pane_id" ] || continue
    pa_var="PANE_AGENT_$(fm_herdr_spur_safekey "$pane_id")"
    name="${!pa_var:-$ev_agent}"
    [ -n "$name" ] || name="$pane_id"
    fm_herdr_spur_in_watch_set "$name" "$watch_set" || continue
    key=$(fm_herdr_spur_safekey "$name")
    prev_var="LAST_STATUS_${key}"
    prev="${!prev_var:-}"
    if [ -n "$prev" ] && fm_herdr_spur_edge_policy "$prev" "$ev_status"; then
      fm_herdr_spur_spur_or_skip "$name" "$ev_status" "$pane_id"
    fi
    printf -v "$prev_var" '%s' "$ev_status"
  done < <(python3 "$reader_py" "$sock" "$FM_HERDR_SPUR_EVENT_BUDGET" "$@" 2>/dev/null)
  if [ "$saw_subscribed" = true ]; then
    return 0
  fi
  log "event stream never subscribed; treating as reader failure"
  return 2
}

# --- main --------------------------------------------------------------------
main() {
  local watch_set
  watch_set=$(fm_herdr_spur_watch_set)
  log "start mode=$MODE session=$FM_HERDR_SPUR_SESSION watch=[$(printf '%s' "$watch_set" | tr '\n' ' ')]"

  if [ "$MODE" = once ]; then
    # One reconcile pass. With no prior in-memory status this seeds levels and
    # cannot detect an edge by itself; --once exists for the smoke test, which
    # seeds a working level then flips it. To let a single invocation observe an
    # edge, honor FM_HERDR_SPUR_SEED (agent=status,agent=status) as the assumed
    # prior status.
    if [ -n "${FM_HERDR_SPUR_SEED:-}" ]; then
      local pair a s key
      IFS=',' read -ra pairs <<<"$FM_HERDR_SPUR_SEED"
      for pair in "${pairs[@]}"; do
        a="${pair%%=*}"; s="${pair#*=}"
        [ -n "$a" ] || continue
        key=$(fm_herdr_spur_safekey "$a")
        printf -v "LAST_STATUS_${key}" '%s' "$s"
      done
    fi
    fm_herdr_spur_reconcile "$watch_set"
    return 0
  fi

  local capable=false
  if fm_herdr_spur_events_capable; then
    capable=true
    log "events-capable: using native pane.agent_status_changed push"
  else
    log "events-incapable: using herdr agent list poll fallback"
  fi

  while :; do
    watch_set=$(fm_herdr_spur_watch_set)
    if [ "$capable" = true ]; then
      # Native push: block on the stream. On return (budget/close), reconcile
      # levels to catch any edge missed across the re-subscribe seam, then loop.
      fm_herdr_spur_event_block "$watch_set" || {
        log "event block unusable this cycle; poll reconcile"
        fm_herdr_spur_reconcile "$watch_set"
        sleep "$FM_HERDR_SPUR_POLL_INTERVAL"
      }
    else
      fm_herdr_spur_reconcile "$watch_set"
      sleep "$FM_HERDR_SPUR_POLL_INTERVAL"
    fi
  done
}

main
