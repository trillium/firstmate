#!/usr/bin/env bash
# Run the sub-supervisor daemon ATTENDED - while the captain is present - so it
# triages the durable wake queue in the background instead of spending the main
# session's turns on routine events.
#
# Usage: fm-attended-start.sh
#   Refuses unless attended triage is switched on (config/attended-triage; see
#   docs/configuration.md) and refuses while away mode owns the daemon. Then:
#     - prints "attended: daemon already running pid=<pid>" and exits 0 when the
#       daemon lock is held by a live daemon;
#     - otherwise execs bin/fm-supervise-daemon.sh in the foreground.
#
# This deliberately does NOT write state/.afk and does NOT touch the away-mode
# escalation buffer. It is the same daemon and the same lock as away mode, so a
# later /afk simply refreshes into away behavior on the process already running,
# and the attended pass stands down the moment that flag appears.
#
# Keep this as a tracked background session exactly as bin/fm-afk-start.sh
# documents; do not wrap it in `nohup ... &`.
set -eu

FM_ATTENDED_START_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_ATTENDED_START_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_ATTENDED_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# The daemon-lock helpers (daemon_lock_pid, daemon_lock_held_by_live_daemon) have
# one owner, the away launcher; its BASH_SOURCE guard keeps its main from running
# here. Sourcing it also loads fm-wake-lib.sh.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_ATTENDED_START_DIR/fm-afk-start.sh"
# shellcheck source=bin/fm-attended-triage-lib.sh
. "$FM_ATTENDED_START_DIR/fm-attended-triage-lib.sh"

fm_attended_start_usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_attended_start_main() {
  case "${1:-}" in
    '' ) ;;
    -h|--help) fm_attended_start_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[1]:-fm-attended-start.sh}")" >&2; return 2 ;;
  esac

  if ! fm_attended_enabled "$FM_HOME"; then
    echo "attended: attended background triage is switched off; turn it on with 'on' in $FM_HOME/config/attended-triage (docs/configuration.md)" >&2
    return 1
  fi

  if [ -e "$FM_ATTENDED_STATE/.afk" ]; then
    echo "attended: away mode is active and already owns the daemon; nothing to start" >&2
    return 1
  fi

  mkdir -p "$FM_ATTENDED_STATE"

  local pid
  pid=$(daemon_lock_pid 2>/dev/null || true)
  if daemon_lock_held_by_live_daemon; then
    echo "attended: daemon already running pid=$pid"
    return 0
  fi

  if fm_pid_alive "$pid" && [ -n "$pid" ]; then
    fm_lock_remove_path "$FM_AFK_LOCK" 2>/dev/null || true
  fi

  echo "attended: starting supervise daemon in foreground; keep this command as a tracked background session"
  exec "$FM_ATTENDED_START_DIR/fm-supervise-daemon.sh"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_attended_start_main "$@"
fi
