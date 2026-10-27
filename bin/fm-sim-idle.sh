#!/usr/bin/env bash
# fm-sim-idle.sh - flag iOS simulators that stayed booted with nothing using them.
# Usage: fm-sim-idle.sh scan | ack
#
# A booted simulator holds gigabytes of memory, and a worker that forgot to shut
# one down is invisible to every other check (teardown only cleans up what a
# task booted while it was alive, bin/fm-sim-lib.sh). `scan` prints one line per
# simulator that has been booted longer than the threshold with no running tool
# using it, naming it and the live tasks that started before it booted (its
# possible owners), and prints nothing otherwise. It reads, never shuts anything
# down: the captain decides, and `xcrun simctl shutdown <udid>` is the remedy.
# `scan` records the lines it printed as pending; bin/fm-watch.sh calls `ack`
# only after the wake is queued, which starts that simulator's re-alert quiet
# period (enqueue before suppress), so a failed enqueue is reported again.
#
# Threshold: config/sim-idle-hours in the local root home (FM_SIM_IDLE_HOURS
# overrides it), a positive integer, default 12; "off" disables the check. A
# simulator is re-reported at most once per FM_SIM_IDLE_REALERT_HOURS (default
# 24). Secondmate homes, hosts without xcrun, and non-macOS hosts print nothing,
# so only the root home's watcher raises the wake. docs/configuration.md "Host
# health" is the operator reference; bin/fm-watch.sh owns when it runs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-sim-lib.sh
. "$SCRIPT_DIR/fm-sim-lib.sh"

DIR="$STATE/.sim-idle"
PENDING="$DIR/.pending"
NOW=${FM_SIM_IDLE_NOW:-$(date +%s)}

positive_int() { case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac; }

# Hours threshold, empty when the check is off.
threshold_hours() {
  local v=${FM_SIM_IDLE_HOURS:-} root config_dir
  if [ -z "$v" ]; then
    root=$(fm_firstmate_root_home "$FM_HOME") || return 0
    config_dir=$root/config
    [ "$root" != "$(cd "$FM_HOME" 2>/dev/null && pwd -P)" ] || config_dir=$CONFIG
    [ ! -f "$config_dir/sim-idle-hours" ] || v=$(head -n 1 "$config_dir/sim-idle-hours" | tr -d '[:space:]')
  fi
  case "$v" in
    off) return 0 ;;
    '') printf '12\n' ;;
    *) if positive_int "$v"; then printf '%s\n' "$v"; else
         echo "fm-sim-idle: ignoring invalid simulator idle hours '$v'; using 12" >&2
         printf '12\n'
       fi ;;
  esac
}

sim_name() {  # <udid>
  xcrun simctl list devices booted 2>/dev/null | grep -F "($1)" | head -n 1 \
    | sed -e "s/ *($1).*//" -e 's/^ *//'
}

# Live tasks (any local home, never a secondmate) that started before the
# simulator booted, i.e. whose baseline does not list it.
possible_owners() {  # <udid> <state>...
  local udid=$1 state meta id out=
  shift
  for state in "$@"; do
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      [ "$(fm_sim_meta_get "$meta" kind)" != secondmate ] || continue
      case ",$(fm_sim_meta_get "$meta" sim_baseline)," in
        *",$udid,"*) continue ;;
        ,,) continue ;;
      esac
      out="${out:+$out, }$id"
    done
  done
  printf '%s\n' "$out"
}

scan() {
  local hours threshold realert home_real root udid age last owners name line
  [ "$(uname -s)" = Darwin ] || return 0
  fm_sim_available || return 0
  home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || return 0
  root=$(fm_firstmate_root_home "$FM_HOME") || return 0
  [ "$root" = "$home_real" ] || return 0
  hours=$(threshold_hours)
  [ -n "$hours" ] || return 0
  threshold=$((hours * 3600))
  realert=${FM_SIM_IDLE_REALERT_HOURS:-24}
  positive_int "$realert" || realert=24
  realert=$((realert * 3600))
  fm_sim_booted || return 0
  fm_sim_peer_states "$STATE" || return 0
  mkdir -p "$DIR" || return 0
  : > "$PENDING"
  for f in "$DIR"/*; do
    [ -f "$f" ] || continue
    case ",$(printf '%s' "$FM_SIM_BOOTED" | paste -sd, -)," in *",$(basename "$f"),"*) ;; *) rm -f "$f" ;; esac
  done
  while IFS= read -r udid; do
    [ -n "$udid" ] || continue
    age=$(fm_sim_boot_age "$udid") || continue
    [ "$age" -ge "$threshold" ] || continue
    ! fm_sim_in_use "$udid" || continue
    last=$(cat "$DIR/$udid" 2>/dev/null || true)
    positive_int "$last" || last=
    [ -z "$last" ] || [ $((NOW - last)) -ge "$realert" ] || continue
    owners=$(possible_owners "$udid" "${FM_SIM_PEER_STATES[@]}")
    name=$(sim_name "$udid")
    line="simulator ${name:+$name }$udid has been booted $((age / 3600))h with nothing using it ("
    if [ -n "$owners" ]; then line="${line}tasks started before it booted: $owners"; else line="${line}no live task started before it booted"; fi
    printf '%s); shut it down with: xcrun simctl shutdown %s\n' "$line" "$udid"
    printf '%s\n' "$udid" >> "$PENDING"
  done <<EOF2
$FM_SIM_BOOTED
EOF2
}

ack() {
  local udid
  [ -f "$PENDING" ] || return 0
  while IFS= read -r udid; do
    [ -n "$udid" ] || continue
    printf '%s\n' "$NOW" > "$DIR/$udid"
  done < "$PENDING"
  : > "$PENDING"
}

case "${1:-}" in
  scan) scan ;;
  ack) ack ;;
  *) echo "usage: fm-sim-idle.sh scan|ack" >&2; exit 2 ;;
esac
