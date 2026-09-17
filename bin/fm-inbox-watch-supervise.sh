#!/usr/bin/env bash
# Independent supervision for the inbox store-event tail (task-z8sn4).
#
# Usage:
#   fm-inbox-watch-supervise.sh [--once] [--interval N]
#
# This is the monitor that stays alive when the firstmate watcher does not.
# Every pass it guarantees BOTH halves the task requires: the registration
# row exists (re-arm when missing) AND a live runner owns it (reconcile
# starts one when none does, republishes unhandled captures). Both halves
# are idempotent: a live owner is never displaced, re-arm never resets the
# cursor, and re-publication never duplicates a handled acknowledgement.
#
# It never touches the watcher, chat, or the poke path. Run it under a
# KeepAlive supervisor (launchd com.firstmate.inbox-watch.plist) so a crash
# restarts supervision itself; --once performs a single pass for tests and
# one-shot recovery.
#
# Environment:
#   FM_HOME (default: this repo root) - the home whose tail is supervised.
#   INBOX_EVENTS_FILE (default: ~/data/inbox/events.jsonl) - the watch file.
#   FM_INBOX_SUPERVISE_INTERVAL (default: 15) - seconds between passes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# NOTE: no local STATE: arm/reconcile resolve their own state from FM_HOME.
WATCH="${INBOX_EVENTS_FILE:-$HOME/data/inbox/events.jsonl}"
INTERVAL="${FM_INBOX_SUPERVISE_INTERVAL:-15}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() {
  printf 'usage: %s [--once] [--interval N]\n' "$(basename "$0")" >&2
  exit 2
}

ONCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --interval)
      [ "$#" -ge 2 ] || usage
      INTERVAL=$2; shift 2 ;;
    -h|--help|help) usage ;;
    *) usage ;;
  esac
done
case "$INTERVAL" in ''|*[!0-9]*|0) die "interval must be a positive integer" ;; esac

# Secondmate homes stay passive: machine-wide source ownership must converge
# on the primary, never on a transient home.
if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
  printf 'inbox-supervise: passive secondmate home, nothing to do\n' >&2
  exit 0
fi

pass() {
  local arm_out rc=0
  # Half 1: the registration row exists. Silent re-arm when present already.
  arm_out=$("$SCRIPT_DIR/fm-procevent-inbox.sh" arm "$WATCH" 2>&1) || {
    printf 'inbox-supervise: arm failed for %s\n' "$WATCH" >&2
    return 1
  }
  # Half 2: a live runner owns every ownerless source; unhandled captures
  # are republished. Never displaces a live owner.
  "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'inbox-supervise: reconcile failed\n' >&2
    return 1
  fi
  printf 'inbox-supervise: pass ok (%s)\n' "$(printf '%s' "$arm_out" | head -1)" >&2
  return 0
}

if [ "$ONCE" -eq 1 ]; then
  pass
  exit "$?"
fi

printf 'inbox-supervise: watching %s for %s every %ss\n' "$WATCH" "$FM_HOME" "$INTERVAL" >&2
while :; do
  pass || true
  /bin/sleep "$INTERVAL"
done
