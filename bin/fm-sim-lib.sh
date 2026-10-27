#!/usr/bin/env bash
# fm-sim-lib.sh - iOS simulators booted by worker tasks, and what becomes of them.
#
# Workers boot simulators for tests and nothing else shuts them down, so a
# forgotten simulator holds gigabytes of memory for days. This file is the single
# owner of three facts, and docs/configuration.md "Host health" is the operator
# reference:
#   - the baseline: bin/fm-spawn.sh records the simulators already booted when a
#     fresh task starts as sim_baseline= in state/<id>.meta (comma-separated
#     UDIDs, or "none" when Xcode is present and nothing was booted). The key is
#     absent on a host without a usable xcrun, and a task with no baseline is
#     never cleaned up after, because what pre-existed it cannot be told.
#   - in use: whether a simulator is still needed (fm_sim_in_use and
#     fm_sim_claimed_by_peer below).
#   - cleanup: bin/fm-teardown.sh calls fm_sim_teardown_cleanup, which shuts down
#     every simulator booted after the task started that nothing still uses.
# bin/fm-host-health.sh reuses the in-use and age readers to flag simulators that
# outlive their task. Nothing here kills a process; the only mutation is
# `xcrun simctl shutdown <udid>`.
#
# Every function is a no-op on a host without xcrun, so Linux and Xcode-less Macs
# are untouched.

FM_SIM_UUID_RE='[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}'

# Commands that drive a simulator. A running one that names a UDID uses that
# simulator; one that names none may be using any of them (an xcodebuild
# -destination "name=iPhone 15" run), so it protects every candidate.
FM_SIM_TOOLS='xcodebuild|xctest|xcrun|simctl|xcbeautify|swift-build|swift-test|idb|idb_companion|maestro|detox|applesimutils|appium'

fm_sim_available() {
  command -v xcrun >/dev/null 2>&1
}

# Sets FM_SIM_BOOTED to the booted UDIDs, one per line, sorted. Returns 1 when
# simctl cannot be read, which callers treat as "unknown", never as "none".
fm_sim_booted() {
  local out
  FM_SIM_BOOTED=
  fm_sim_available || return 1
  out=$(xcrun simctl list devices booted 2>/dev/null) || return 1
  FM_SIM_BOOTED=$(printf '%s\n' "$out" | grep -F '(Booted)' | grep -Eo "$FM_SIM_UUID_RE" | sort -u) || true
  return 0
}

# The sim_baseline= value for a fresh task, empty when it cannot be read.
fm_sim_baseline_value() {
  fm_sim_booted || return 0
  if [ -z "$FM_SIM_BOOTED" ]; then
    printf 'none\n'
  else
    printf '%s\n' "$FM_SIM_BOOTED" | paste -sd, -
  fi
}

fm_sim_meta_get() {  # <meta> <key>
  local line value=
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1"
  printf '%s' "$value"
}

# Seconds for a ps etime value ([[dd-]hh:]mm:ss).
fm_sim_etime_secs() {
  local t=$1 d=0 h=0 m s
  case "$t" in *-*) d=${t%%-*}; t=${t#*-} ;; esac
  case "$t" in
    *:*:*) h=${t%%:*}; t=${t#*:}; m=${t%%:*}; s=${t#*:} ;;
    *:*) m=${t%%:*}; s=${t#*:} ;;
    *) return 1 ;;
  esac
  case "$d$h$m$s" in *[!0-9]*|'') return 1 ;; esac
  printf '%s\n' $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# Seconds the simulator has been booted, read from its launchd_sim process.
# Empty (return 1) when that process cannot be found.
fm_sim_boot_age() {  # <udid>
  local etime
  etime=$(ps -axo etime=,command= 2>/dev/null | awk -v u="$1" 'index($0, u) && index($0, "launchd_sim") {print $1; exit}')
  [ -n "$etime" ] || return 1
  fm_sim_etime_secs "$etime"
}

# Whether a running tool still needs the simulator. Sets FM_SIM_USE_REASON.
fm_sim_in_use() {  # <udid>
  local udid=$1 cmd base lc_udid
  lc_udid=$(printf '%s' "$udid" | tr 'A-F' 'a-f')
  FM_SIM_USE_REASON=
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    base=${cmd%% *}
    base=${base##*/}
    [[ $base =~ ^($FM_SIM_TOOLS)$ ]] || continue
    case "$cmd" in *' simctl list'*|*' simctl shutdown'*) continue ;; esac
    if printf '%s' "$cmd" | tr 'A-F' 'a-f' | grep -Fq "$lc_udid"; then
      FM_SIM_USE_REASON="a running $base targets it"
      return 0
    fi
    if ! printf '%s' "$cmd" | grep -Eq "$FM_SIM_UUID_RE"; then
      FM_SIM_USE_REASON="a running $base names no simulator and may be using it"
      return 0
    fi
  done <<EOF
$(ps -axo command= 2>/dev/null)
EOF
  return 1
}

# Sets FM_SIM_PEER_STATES to the state directories whose live tasks count as
# other users: every local Firstmate home when the registry can be walked,
# otherwise only <state>. Returns 1 when the walk fails, so a caller keeps the
# simulator rather than guessing.
fm_sim_peer_states() {  # <state>
  FM_SIM_PEER_STATES=("$1")
  if declare -F fm_local_firstmate_state_dirs >/dev/null 2>&1; then
    fm_local_firstmate_state_dirs "$1" || return 1
    FM_SIM_PEER_STATES=("${FM_LOCAL_FIRSTMATE_STATES[@]}")
  fi
}

# Whether another live task (any local home, never a secondmate) recorded the
# simulator in its baseline: it was already booted when that task started, so the
# task may rely on it. Sets FM_SIM_CLAIM_TASK to that task's id.
# Both <state-dir>/<self>.meta and a missing state dir are skipped.
fm_sim_claimed_by_peer() {  # <udid> <self-id> <state>...
  local udid=$1 self=$2 state meta id baseline
  shift 2
  FM_SIM_CLAIM_TASK=
  for state in "$@"; do
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      [ "$id" != "$self" ] || continue
      [ "$(fm_sim_meta_get "$meta" kind)" != secondmate ] || continue
      baseline=$(fm_sim_meta_get "$meta" sim_baseline)
      case ",$baseline," in
        *",$udid,"*) FM_SIM_CLAIM_TASK=$id; return 0 ;;
      esac
    done
  done
  return 1
}

# Teardown step: shut down the simulators this task booted that nothing still
# uses, and report each outcome on stdout. Never fails the teardown.
fm_sim_teardown_cleanup() {  # <meta> <id> <state>
  local meta=$1 id=$2 state=$3 baseline udid
  baseline=$(fm_sim_meta_get "$meta" sim_baseline)
  [ -n "$baseline" ] || return 0
  fm_sim_booted || return 0
  [ -n "$FM_SIM_BOOTED" ] || return 0
  if ! fm_sim_peer_states "$state"; then
    echo "teardown $id: left its simulators booted because the other local homes could not be read"
    return 0
  fi
  while IFS= read -r udid; do
    [ -n "$udid" ] || continue
    case ",$baseline," in *",$udid,"*) continue ;; esac
    if fm_sim_in_use "$udid"; then
      echo "teardown $id: left simulator $udid booted ($FM_SIM_USE_REASON)"
    elif fm_sim_claimed_by_peer "$udid" "$id" "${FM_SIM_PEER_STATES[@]}"; then
      echo "teardown $id: left simulator $udid booted (task $FM_SIM_CLAIM_TASK found it already booted)"
    elif xcrun simctl shutdown "$udid" >/dev/null 2>&1; then
      echo "teardown $id: shut down simulator $udid, booted after the task started"
    else
      echo "teardown $id: could not shut down simulator $udid; run 'xcrun simctl shutdown $udid'"
    fi
  done <<EOF
$FM_SIM_BOOTED
EOF
  return 0
}
