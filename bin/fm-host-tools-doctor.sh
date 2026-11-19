#!/usr/bin/env bash
# Report whether this host has every required tool present AND authenticated.
#
# Usage:
#   bin/fm-host-tools-doctor.sh [--record] [--host <name>]
#   <check-lines> | bin/fm-host-tools-doctor.sh --ingest <host>
#
# The checks live in bin/fm-host-tools-lib.sh (the single owner of the check
# list and its knobs). The output is the line protocol bin/fm-remote-doctor.sh
# prints, stable for script consumers:
#   check <check>=ok: <evidence>
#   check <check>=skip: <why this host is exempt>
#   check <check>=human: <the missing or unauthenticated tool>
#   action: <check>: <the exact command that closes the gap>
# A missing or unauthenticated tool is a `human:` check with its exact fix
# command in the `action:` line, and any `human:` check exits 1.
#
# --record writes the result to $FM_HOME/state/host-readiness/<host>.json, the
# file bin/fm-fleet-snapshot.sh reads, so bin/fm-fleet-view.sh shows each
# host's readiness beside its agents; --host names the record (default: the
# short hostname). --ingest records another host's already-collected check
# lines read from stdin, which is how a remote host's result reaches the same
# view:
#   bin/fm-on.sh <secondmate-id> fm-remote-doctor.sh --host-tools \
#     | bin/fm-host-tools-doctor.sh --ingest <host>
# Ingest keeps only `check host-*` and `action:` lines and exits 0 once the
# record is written, since it reports a result rather than judging it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-host-tools-lib.sh
. "$SCRIPT_DIR/fm-host-tools-lib.sh"
# shellcheck source=bin/fm-home-lib.sh
. "$SCRIPT_DIR/fm-home-lib.sh"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

RECORD=0
INGEST=
HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo local)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --record) RECORD=1 ;;
    --host) shift; [ -n "${1:-}" ] || usage; HOST=$1 ;;
    --ingest) shift; [ -n "${1:-}" ] || usage; INGEST=$1; HOST=$1; RECORD=1 ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
  shift
done
case "$HOST" in */* | "" | .*) echo "error: invalid host name for a record: $HOST" >&2; exit 2 ;; esac

NAMES=()
VALUES=()
ACTIONS=()
emit() { NAMES+=("$1"); VALUES+=("$2"); ACTIONS+=("${3:-}"); }

if [ -n "$INGEST" ]; then
  while IFS= read -r line; do
    case "$line" in
      "check host-"*=*)
        rest=${line#check }
        emit "${rest%%=*}" "${rest#*=}"
        ;;
      "action: host-"*": "*)
        rest=${line#action: }
        name=${rest%%: *}
        i=0
        while [ "$i" -lt "${#NAMES[@]}" ]; do
          [ "${NAMES[$i]}" != "$name" ] || ACTIONS[i]=${rest#*: }
          i=$((i + 1))
        done
        ;;
    esac
  done
else
  FM_HOME=$(fm_resolve_home 2>/dev/null) || FM_HOME=
  export FM_HOME
  fm_host_tools_collect emit
fi

GAPS=0
i=0
while [ "$i" -lt "${#NAMES[@]}" ]; do
  printf 'check %s=%s\n' "${NAMES[$i]}" "${VALUES[$i]}"
  case "${VALUES[$i]}" in human:*) GAPS=$((GAPS + 1)) ;; esac
  i=$((i + 1))
done
i=0
while [ "$i" -lt "${#NAMES[@]}" ]; do
  case "${VALUES[$i]}" in
    human:*) [ -z "${ACTIONS[$i]}" ] || printf 'action: %s: %s\n' "${NAMES[$i]}" "${ACTIONS[$i]}" ;;
  esac
  i=$((i + 1))
done

if [ "$RECORD" -eq 1 ]; then
  command -v jq >/dev/null 2>&1 || { echo "error: --record needs jq" >&2; exit 1; }
  [ -n "${FM_HOME:-}" ] || FM_HOME=$(fm_resolve_home) || exit 1
  dest="$FM_HOME/state/host-readiness"
  mkdir -p "$dest" || exit 1
  rows=''
  i=0
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    v=${VALUES[$i]}
    rows+=$(jq -cn --arg name "${NAMES[$i]}" --arg status "${v%%:*}" --arg detail "${v#*: }" --arg action "${ACTIONS[$i]}" \
      '{name:$name,status:$status,detail:$detail,action:(if $action == "" then null else $action end)}')$'\n'
    i=$((i + 1))
  done
  printf '%s' "$rows" | jq -s --arg host "$HOST" --argjson at "$(date +%s)" \
    '{schema:"fm-host-readiness.v1",host:$host,checked_at:$at,ready:(all(.[]; .status != "human")),checks:.}' \
    >"$dest/$HOST.json" || { echo "error: cannot write $dest/$HOST.json" >&2; exit 1; }
fi

[ -z "$INGEST" ] || exit 0
if [ "$GAPS" -gt 0 ]; then
  printf 'error: this host is not ready: %s check(s) failing\n' "$GAPS" >&2
  exit 1
fi
printf 'ok: every required tool is present and authenticated on this host\n'
