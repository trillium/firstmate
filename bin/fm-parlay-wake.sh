#!/usr/bin/env bash
# fm-parlay-wake.sh - bridge parlay channel arrivals into firstmate's durable
# wake queue, so stream lines on the primary's agent channel become wakes even
# when no session is watching the listener.
#
# WHY THIS EXISTS.
# The primary enrolls with the parlay relay as firstmate-primary and holds a
# live listener, but stream lines delivered into a backgrounded session never
# become wakes: they sit silent until somebody manually reads the channel.
# This bridge tails the same channel and publishes every arrival to the durable
# wake queue (state/.wake-queue) via fm-wake-lib.sh's fm_wake_append, so
# fm-wake-drain surfaces it and firstmate reacts on its ordinary supervision
# cycle. It closes the reactive gap without touching any existing supervision
# path: the watcher, the drain, and every poll keep their exact current shape.
#
# READ-ONLY AGAINST PARLAY.
# The relay fans each agent channel out to an append-only spool file,
# <runtime>/<agent>.chan, with one `CHAT_MSG|<id>|<role>|<text>` line per
# message (tools/RELAY_MONITOR.md in the parlay repo owns that wire contract).
# This bridge tails that spool file directly and NEVER registers with the relay,
# never enrolls, and never touches the relay socket. Registering would evict the
# primary's live reader - the relay keeps exactly one reader per channel - so a
# second enrolled reader is not a second view, it is a theft. A file tail is a
# genuinely additive second view: the primary's listener keeps working exactly
# as before whether this bridge runs or not.
#
# NO BUSY-POLL.
# Delivery rides a blocking `tail -F` read: the process sleeps in the kernel
# until the spool grows. There is no timer, no interval, and no periodic `parlay
# history` comparison. The only sleep loop in the script waits for the spool
# file itself to exist (armed before the channel is ever registered); once the
# spool is present, message flow is purely event-driven.
#
# EXACTLY ONCE.
# A cursor file, state/.parlay-wake.<agent>.cursor, holds the last-seen message
# id. On start the bridge replays the spool only forward from that id; a cursor
# that never appears in the spool (replaced spool) resumes from the current end
# rather than replaying history as a wake storm. A first-ever run with no cursor
# also starts from the current end, so arming the bridge never floods the queue
# with old channel history. Cursor writes are atomic (tmp file plus rename), so
# a kill between enqueue and cursor commit replays at most one wake on restart.
#
# WHAT IT ENQUEUES.
# The durable wake queue accepts only signal|stale|check|heartbeat
# (fm-wake-lib.sh owns that contract). A channel arrival is not a task status
# signal or a stale-pane read, so like the herdr-spur bridge it rides the
# `check` kind - the "always actionable" lane the watcher surfaces
# unconditionally. The record is:
#     <epoch>\t<seq>\tcheck\tparlay:<agent>\t<id> <role>: <text...>
# with the text capped at a notification-safe budget. fm-wake-drain prints it
# verbatim as a `check:` wake and firstmate handles it like any other wake.
#
# Usage: fm-parlay-wake.sh [--agent <id>] [--spool <path>] [--once] [--wait]
#        [--self-detach] [--cursor <path>]
#   --agent <id>   channel to tail (default: $FM_PARLAY_WAKE_AGENT or
#                  firstmate-primary, the sanctioned primary channel)
#   --spool <path> tail this spool file directly (default: resolve <agent>.chan
#                  under the relay runtime dir; override for tests)
#   --once         single pass over the current spool content, then exit
#                  (smoke tests; never tails)
#   --wait         when the spool file does not exist yet, wait for it instead
#                  of exiting non-zero (daemon arming before registration)
#   --self-detach  re-exec detached so the daemon survives its parent shell
#   --cursor <path> cursor file override (default:
#                  state/.parlay-wake.<agent>.cursor)
# Spool resolution without --spool: ${PARLAY_RELAY_RUNTIME:-$TMPDIR/parlay},
# then /tmp/parlay, then any srv-* subdirectory of those (one relay per
# upstream server, each with its own runtime dir). The first <agent>.chan found
# wins. Nothing here contacts the relay, so resolution is a pure file scan.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

AGENT="${FM_PARLAY_WAKE_AGENT:-firstmate-primary}"
SPOOL=""
MODE=loop
WAIT_FOR_SPOOL=false
DO_DETACH=false
CURSOR=""
PAYLOAD_BUDGET=400

usage() {
  cat >&2 <<'EOF'
Usage: fm-parlay-wake.sh [options]
  --agent <id>    parlay channel to tail (default: firstmate-primary)
  --spool <path>  tail this spool file directly (default: resolve <agent>.chan)
  --once          single pass over current spool content, then exit
  --wait          wait for the spool file to appear instead of exiting non-zero
  --self-detach   re-exec detached so the daemon survives its parent
  --cursor <path> cursor file override
  -h, --help      show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --spool) SPOOL="$2"; shift 2 ;;
    --once) MODE=once; shift ;;
    --wait) WAIT_FOR_SPOOL=true; shift ;;
    --self-detach) DO_DETACH=true; shift ;;
    --cursor) CURSOR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-parlay-wake: unknown arg: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

case "$AGENT" in
  ''|*[^a-z0-9-]*)
    printf 'fm-parlay-wake: invalid agent id: %s (relay requires kebab-slugs)\n' "$AGENT" >&2
    exit 2 ;;
esac

if [ "$DO_DETACH" = true ]; then
  # Same survival contract as fm-herdr-spur.sh: processes survive, context
  # does not. Re-exec detached and let the child own the tail.
  detach_args=(--agent "$AGENT")
  [ -n "$SPOOL" ] && detach_args+=(--spool "$SPOOL")
  [ -n "$CURSOR" ] && detach_args+=(--cursor "$CURSOR")
  [ "$WAIT_FOR_SPOOL" = true ] && detach_args+=(--wait)
  setsid nohup "$0" "${detach_args[@]}" </dev/null >/dev/null 2>&1 &
  printf 'fm-parlay-wake: detached pid %s tailing %s\n' "$!" "$AGENT"
  exit 0
fi

[ -n "$CURSOR" ] || CURSOR="$STATE/.parlay-wake.$AGENT.cursor"

resolve_spool() {
  local base
  if [ -n "${PARLAY_RELAY_RUNTIME:-}" ]; then
    [ -f "$PARLAY_RELAY_RUNTIME/$AGENT.chan" ] && { printf '%s' "$PARLAY_RELAY_RUNTIME/$AGENT.chan"; return 0; }
  else
    for base in "${TMPDIR:-/tmp}/parlay" /tmp/parlay; do
      [ -f "$base/$AGENT.chan" ] && { printf '%s' "$base/$AGENT.chan"; return 0; }
      for srv in "$base"/srv-*; do
        [ -f "$srv/$AGENT.chan" ] && { printf '%s' "$srv/$AGENT.chan"; return 0; }
      done
    done
  fi
  return 1
}

if [ -z "$SPOOL" ]; then
  SPOOL=$(resolve_spool) || SPOOL=""
fi

if [ ! -f "$SPOOL" ]; then
  if [ "$WAIT_FOR_SPOOL" = true ] && [ "$MODE" != once ]; then
    while [ ! -f "$SPOOL" ]; do
      sleep 5
      if [ -z "$SPOOL" ]; then
        SPOOL=$(resolve_spool) || SPOOL=""
      fi
    done
  else
    printf 'fm-parlay-wake: no spool for agent %s (relay not serving it yet)\n' "$AGENT" >&2
    exit 1
  fi
fi

# process_line <line>: enqueue one spool line when it is a new arrival.
# Globals: SEEN_CURSOR (0 until the stored cursor id is observed), CURSOR,
# AGENT. Prints the enqueued wake key on success for --once callers that
# count wakes; silent otherwise.
SEEN_CURSOR=0
LAST_ID=""
HAVE_CURSOR=false
if [ -f "$CURSOR" ]; then
  HAVE_CURSOR=true
  LAST_ID=$(tr -d '\r\n' < "$CURSOR" 2>/dev/null)
else
  # No cursor means first-ever run: nothing before the current end is an
  # arrival. Loop mode starts the tail at the end of the file; --once starts
  # already-seen so a first pass enqueues nothing. Either way arming the
  # bridge never floods the queue with old channel history. (Fixture-driven
  # tests seed a cursor holding a real spool id when they want arrivals after
  # that id to enqueue.)
  SEEN_CURSOR=1
fi

store_cursor() {
  local id=$1 tmp
  tmp="$CURSOR.tmp.$$"
  printf '%s\n' "$id" > "$tmp" && mv "$tmp" "$CURSOR"
}

process_line() {
  local line=$1 id role text payload
  case "$line" in
    CHAT_MSG\|*\|*\|*) ;;
    *) return 0 ;;
  esac
  line=${line#CHAT_MSG|}
  id=${line%%|*}
  line=${line#*|}
  role=${line%%|*}
  text=${line#*|}
  [ -n "$id" ] || return 0
  if [ "$SEEN_CURSOR" -eq 0 ]; then
    if [ "$id" = "$LAST_ID" ]; then
      SEEN_CURSOR=1
    fi
    return 0
  fi
  # Cap the payload so one long voice-dictated message cannot bloat the queue.
  text=$(printf '%s' "$text" | cut -c "1-$PAYLOAD_BUDGET")
  payload="$id $role: $text"
  fm_wake_append check "parlay:$AGENT" "$payload" || return 1
  store_cursor "$id" || return 1
}

# fast_forward_cursor: point the cursor at the last arrival in the spool without
# enqueuing anything. Used when the stored cursor id is absent from the spool:
# the spool was replaced under us, and replaying its whole content as new
# arrivals would be a wake storm. Fast-forwarding resumes cleanly: history is
# skipped once, and every arrival appended after this point enqueues normally.
fast_forward_cursor() {
  local last
  last=$(awk -F'|' '$1 == "CHAT_MSG" && $2 != "" { id=$2 } END { print id }' "$SPOOL" 2>/dev/null)
  [ -n "$last" ] && store_cursor "$last"
  return 0
}

# cursor_missing: true when a cursor id is stored but names no line in the
# spool. An empty cursor file counts as no cursor, not a missing one.
cursor_missing() {
  [ "$SEEN_CURSOR" -eq 0 ] && [ -n "$LAST_ID" ] && \
    ! grep -q -F "|$LAST_ID|" "$SPOOL" 2>/dev/null
}

if [ "$MODE" = once ]; then
  # No cursor is a first-ever run and a missing cursor id is a replaced spool:
  # both fast-forward to the spool's end without enqueueing, so arming the
  # bridge (or swapping its spool) never floods the queue with history.
  if [ "$HAVE_CURSOR" = false ] || cursor_missing; then
    fast_forward_cursor
    exit 0
  fi
  while IFS= read -r spool_line || [ -n "$spool_line" ]; do
    process_line "$spool_line" || exit 1
  done < "$SPOOL"
  exit 0
fi

# Loop mode: a replaced spool fast-forwards first, then the blocking tail
# carries every new line. tail -F sleeps in the kernel until the spool grows,
# so idle channels cost no wakeups. Without a cursor the tail starts at the
# end of the file, so only genuine new arrivals enqueue; with a cursor it
# replays from the start and skips forward to the stored id.
if cursor_missing; then
  fast_forward_cursor
  HAVE_CURSOR=false
fi
if [ "$HAVE_CURSOR" = true ]; then
  tail -n +1 -F "$SPOOL" 2>/dev/null | while IFS= read -r spool_line; do
    process_line "$spool_line" || exit 1
  done
else
  tail -n 0 -F "$SPOOL" 2>/dev/null | while IFS= read -r spool_line; do
    process_line "$spool_line" || exit 1
  done
fi
