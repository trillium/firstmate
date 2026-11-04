# shellcheck shell=bash
# shellcheck disable=SC2034  # the FM_POOL_LEASE_* results are read by the sourcing scripts
# fm-pool-lease-lib.sh - optional per-quota-pool concurrency leases for worker
# spawns, so several workers never drain one small quota pool at once.
#
# A provider account or scope can be small enough that two workers launched
# together exhaust it and fail together. The captain declares a cap per
# provider, and bin/fm-spawn.sh takes a lease from a lease-axi authority
# (github.com/trillium/lease-axi) before launching a worker whose harness and
# model resolve to a capped pool. A pool at its cap launches nothing, leaves the
# backlog item queued, prints `deferred:` and exits 75, exactly like project
# capacity. Without a declaration nothing changes (AGENTS.md section 7).
#
# This file is the single owner of the declaration format, of the pool id, and
# of the grant, renew, and release calls. docs/configuration.md "Pool leases" is
# the operator reference; bin/fm-spawn.sh owns where the grant runs, the watcher
# (bin/fm-watch.sh) owns renewal, and bin/fm-teardown.sh and
# bin/fm-control.sh exit own release.
#
# Declaration: config/pool-lease in the spawning home (it is an inherited item,
# so a secondmate home receives the primary's copy). One directive per line:
#   authority <url>      the lease-axi HTTP authority every home and machine
#                        shares, so the cap counts every holder (required)
#   ttl <n>s|<n>m        lease lifetime, renewed while the worker is alive
#                        (default 5m)
#   cap <provider> <n>   at most <n> concurrent workers per pool of <provider>
#                        (codex or agy; a provider with no cap line is uncapped)
# Blank lines and lines starting with `#` are ignored. Any other shape, a
# repeated directive, a cap for a provider that is not poolable (claude has no
# usage limit and is never leased), or an unreadable file makes the whole
# declaration unreadable, and a spawn then refuses rather than guessing.
#
# Pool id: <provider>/<accountKey>/<scope>, the same provider + accountKey +
# scope join bin/fm-quota-axi-lib.sh uses to bind a candidate to its quota row.
# Each Codex account (codex-home, or a Pi lane's auth provider) is its own pool,
# and each Antigravity scope (gemini, argon, claude_gpt) is its own pool.
#
# Lease record: state/<id>.pool-lease holds lease=, pool=, cap=, server=, ttl=, and
# renewed= (epoch of the last grant or renew), since= (epoch of the grant, the
# activity floor), plus lapsed= (epoch) once the
# lease was returned for inactivity. It exists while the task holds, or is
# owed, a lease; TTL expiry at the authority covers a worker that never released.
#
# Return paths: teardown, fm-control exit, and a secondmate retirement release at
# once. The watcher tick (bin/fm-pool-lease-tick.sh) renews a lease only while
# the holder shows activity and releases it after FM_POOL_LEASE_IDLE_SECS (30
# minutes) of inactivity; a declared `paused:` wait counts as inactive. A
# holder active again after a lapse takes a new lease and waits while the pool
# is held.
#
# Requires bin/fm-quota-axi-lib.sh (sourced here), bin/fm-timeout-lib.sh
# (fm_run_timed), and bin/fm-wake-lib.sh (fm_path_mtime) to be sourced first. No side effects on source.

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"

# Exit status of a spawn deferred because its pool is at its cap: the sysexits
# "temporary failure" code, shared with project capacity.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_POOL_LEASE_DEFER_EXIT=75

# Bound for every lease-axi call, so a hung authority never stalls a spawn or
# the watcher.
FM_POOL_LEASE_CALL_TIMEOUT=${FM_POOL_LEASE_CALL_TIMEOUT:-20}

# Inactivity after which a holder's lease is returned.
FM_POOL_LEASE_IDLE_SECS=${FM_POOL_LEASE_IDLE_SECS:-1800}

fm_pool_lease_ttl_seconds() {  # <n>s|<n>m
  case "$1" in
    [1-9]*s) case "${1%s}" in *[!0-9]*) return 1 ;; esac; printf '%s\n' "${1%s}" ;;
    [1-9]*m) case "${1%m}" in *[!0-9]*) return 1 ;; esac; printf '%s\n' "$((${1%m} * 60))" ;;
    *) return 1 ;;
  esac
}

# Read config/pool-lease.
# Sets FM_POOL_LEASE_FILE, FM_POOL_LEASE_ENABLED (1 when a declaration exists),
# FM_POOL_LEASE_SERVER, FM_POOL_LEASE_TTL (as written), FM_POOL_LEASE_TTL_SECS,
# and FM_POOL_LEASE_CAPS (space-separated provider=cap pairs).
# Returns 1 with FM_POOL_LEASE_ERROR when the declaration is unreadable.
fm_pool_lease_load() {  # <config-dir>
  local line lineno=0 key value arg extra
  FM_POOL_LEASE_FILE="$1/pool-lease"
  FM_POOL_LEASE_ENABLED=
  FM_POOL_LEASE_SERVER=
  FM_POOL_LEASE_TTL=5m
  FM_POOL_LEASE_TTL_SECS=300
  FM_POOL_LEASE_CAPS=
  FM_POOL_LEASE_ERROR=
  if [ ! -e "$FM_POOL_LEASE_FILE" ] && [ ! -L "$FM_POOL_LEASE_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_POOL_LEASE_FILE" ] || [ ! -r "$FM_POOL_LEASE_FILE" ]; then
    FM_POOL_LEASE_ERROR="$FM_POOL_LEASE_FILE is not a readable regular file"
    return 1
  fi
  local seen_ttl=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in '' | '#'*) continue ;; esac
    read -r key value arg extra <<< "$line"
    case "$key" in
      authority)
        if [ -n "$FM_POOL_LEASE_SERVER" ] || [ -z "$value" ] || [ -n "$arg" ]; then
          FM_POOL_LEASE_ERROR="$FM_POOL_LEASE_FILE line $lineno is not a single 'authority <url>'"
          return 1
        fi
        case "$value" in
          http://* | https://*) FM_POOL_LEASE_SERVER=$value ;;
          *)
            FM_POOL_LEASE_ERROR="$FM_POOL_LEASE_FILE line $lineno: the authority must be an http:// or https:// URL"
            return 1
            ;;
        esac
        ;;
      ttl)
        if [ "$seen_ttl" = 1 ] || [ -n "$arg" ] || ! FM_POOL_LEASE_TTL_SECS=$(fm_pool_lease_ttl_seconds "$value"); then
          FM_POOL_LEASE_ERROR="$FM_POOL_LEASE_FILE line $lineno is not a single 'ttl <n>s' or 'ttl <n>m'"
          return 1
        fi
        seen_ttl=1
        FM_POOL_LEASE_TTL=$value
        ;;
      cap)
        case "$value" in
          codex | agy) ;;
          claude)
            FM_POOL_LEASE_ERROR="$FM_POOL_LEASE_FILE line $lineno: claude has no usage limit and is never leased"
            return 1
            ;;
          *)
            FM_POOL_LEASE_ERROR="$FM_POOL_LEASE_FILE line $lineno names a provider that is not poolable (codex or agy)"
            return 1
            ;;
        esac
        case " $FM_POOL_LEASE_CAPS " in
          *" $value="*)
            FM_POOL_LEASE_ERROR="$FM_POOL_LEASE_FILE line $lineno repeats the cap for $value"
            return 1
            ;;
        esac
        case "$arg" in
          '' | *[!0-9]* | 0*)
            FM_POOL_LEASE_ERROR="$FM_POOL_LEASE_FILE line $lineno gives $value a cap that is not a positive integer"
            return 1
            ;;
        esac
        if [ -n "$extra" ]; then
          FM_POOL_LEASE_ERROR="$FM_POOL_LEASE_FILE line $lineno is not 'cap <provider> <n>'"
          return 1
        fi
        FM_POOL_LEASE_CAPS="$FM_POOL_LEASE_CAPS $value=$arg"
        ;;
      *)
        FM_POOL_LEASE_ERROR="$FM_POOL_LEASE_FILE line $lineno is not 'authority <url>', 'ttl <n>s', or 'cap <provider> <n>'"
        return 1
        ;;
    esac
  done < "$FM_POOL_LEASE_FILE"
  if [ -z "$FM_POOL_LEASE_SERVER" ]; then
    FM_POOL_LEASE_ERROR="$FM_POOL_LEASE_FILE declares no authority"
    return 1
  fi
  FM_POOL_LEASE_CAPS=${FM_POOL_LEASE_CAPS# }
  FM_POOL_LEASE_ENABLED=1
}

# Resolve the capped pool a launch draws from.
# Sets FM_POOL_LEASE_POOL (<provider>/<accountKey>/<scope>) and FM_POOL_LEASE_CAP
# to the pool and its cap, or both to empty when the launch is not capped
# (claude and any harness with no quota pool are never leased, nor is a
# provider with no cap line). Requires fm_pool_lease_load first.
fm_pool_lease_resolve() {  # <harness> <model>
  local harness=$1 model=${2:-} provider='' lane='' scope=default pair
  FM_POOL_LEASE_POOL=
  FM_POOL_LEASE_CAP=
  [ "$FM_POOL_LEASE_ENABLED" = 1 ] || return 0
  [ "$model" != default ] || model=
  case "$harness" in
    codex) provider=codex ;;
    agy) provider=agy ;;
    pi | pi-signed) provider=pi ;;
    *) return 0 ;;
  esac
  if [ "$provider" = agy ]; then
    lane=default
    scope=$(jq -rn --arg m "$model" "$FM_QUOTA_ROW_JQ"' quota_agy_scope($m)') || return 1
    [ -n "$scope" ] || scope=default
  else
    lane=$(jq -rn --arg h "$harness" --arg m "$model" "$FM_QUOTA_ROW_JQ"' quota_lane($h; $m)') || return 1
    [ "$provider" = codex ] && lane=codex-home
    if [ "$provider" = pi ]; then
      case "$lane" in
        codex-home | openai-codex*) provider=codex ;;
        *) return 0 ;;
      esac
    fi
  fi
  for pair in $FM_POOL_LEASE_CAPS; do
    if [ "${pair%%=*}" = "$provider" ]; then
      FM_POOL_LEASE_CAP=${pair#*=}
      FM_POOL_LEASE_POOL="$provider/$lane/$scope"
      return 0
    fi
  done
  return 0
}

fm_pool_lease_path() {  # <state-dir> <task-id>
  printf '%s/%s.pool-lease\n' "$1" "$2"
}

fm_pool_lease_record_get() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

fm_pool_lease_write_record() {  # <record> <lease> <pool> <cap> <server> <ttl> <renewed> <since> [<lapsed>]
  local tmp="$1.tmp.$$"
  if { printf 'lease=%s\npool=%s\ncap=%s\nserver=%s\nttl=%s\nrenewed=%s\nsince=%s\n' "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    [ -z "${9:-}" ] || printf 'lapsed=%s\n' "$9"; } > "$tmp" &&
    mv -f "$tmp" "$1"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# Take a lease for one task and record it. Returns 0 when granted (record
# written), 75 when the pool is at its cap (FM_POOL_LEASE_HOLDERS names the
# holders), and 1 when the authority could not be reached or answered something
# unreadable (FM_POOL_LEASE_ERROR says why). Never launches unleased: the caller
# refuses on 1.
fm_pool_lease_grant() {  # <state-dir> <task-id> <holder> <pool> <cap> <server> <ttl>
  local state=$1 id=$2 holder=$3 pool=$4 cap=$5 server=$6 ttl=$7 out rc lease_id
  FM_POOL_LEASE_ERROR=
  FM_POOL_LEASE_HOLDERS=
  command -v lease-axi >/dev/null 2>&1 || {
    FM_POOL_LEASE_ERROR="lease-axi is not installed"
    return 1
  }
  rc=0
  out=$(fm_run_timed "$FM_POOL_LEASE_CALL_TIMEOUT" lease-axi grant --server "$server" --pool "$pool" --cap "$cap" --ttl "$ttl" --holder "$holder" --json 2>&1 </dev/null) || rc=$?
  case "$rc" in
    0)
      lease_id=$(printf '%s' "$out" | jq -r 'select(.granted == true) | .lease.id // empty' 2>/dev/null) || lease_id=
      if [ -z "$lease_id" ]; then
        FM_POOL_LEASE_ERROR="lease-axi granted without a readable lease id"
        return 1
      fi
      fm_pool_lease_write_record "$(fm_pool_lease_path "$state" "$id")" "$lease_id" "$pool" "$cap" "$server" "$ttl" "$(date +%s)" "$(date +%s)" || {
        fm_run_timed "$FM_POOL_LEASE_CALL_TIMEOUT" lease-axi release "$lease_id" --server "$server" >/dev/null 2>&1 </dev/null || true
        FM_POOL_LEASE_ERROR="could not record the lease for $id"
        return 1
      }
      ;;
    75)
      FM_POOL_LEASE_HOLDERS=$(printf '%s' "$out" | jq -r '[.holders[]? | .holder] | join(", ")' 2>/dev/null) || FM_POOL_LEASE_HOLDERS=
      return 75
      ;;
    *)
      FM_POOL_LEASE_ERROR="lease-axi grant against $server failed (exit $rc)"
      return 1
      ;;
  esac
}

# Release one lease at its authority. Best effort: an unreachable authority
# leaves TTL expiry to free the slot.
fm_pool_lease_release_id() {  # <server> <lease> <task-id>
  [ -n "$1" ] && [ -n "$2" ] || return 0
  if command -v lease-axi >/dev/null 2>&1 &&
    fm_run_timed "$FM_POOL_LEASE_CALL_TIMEOUT" lease-axi release "$2" --server "$1" >/dev/null 2>&1 </dev/null; then
    return 0
  fi
  echo "warning: could not release the pool lease $2 for $3; it expires on its own at the authority" >&2
}

# Release a task's lease and drop its record. The record is dropped either way
# because nothing renews it any longer.
fm_pool_lease_release() {  # <state-dir> <task-id>
  local record
  record=$(fm_pool_lease_path "$1" "$2")
  [ -f "$record" ] || return 0
  fm_pool_lease_release_id "$(fm_pool_lease_record_get "$record" server)" "$(fm_pool_lease_record_get "$record" lease)" "$2"
  rm -f "$record"
}

# The holder's last activity as an epoch: the newest of the status log, busy
# record, turn-end, and progress files the watcher already reads, or the
# declaration time of a still-open `paused:` wait, whose later churn does not
# count (a declared pause is inactive).
fm_pool_lease_activity() {  # <state-dir> <task-id> <fallback-epoch>
  local state=$1 id=$2 best=${3:-0} f m last
  for f in "$state/$id.status" "$state/$id.busy-state" "$state/$id.turn-ended" "$state/$id.progress"; do
    [ -e "$f" ] || continue
    m=$(fm_path_mtime "$f" 2>/dev/null) || continue
    [ "$m" -le "$best" ] || best=$m
  done
  if [ -f "$state/$id.status" ]; then
    last=$(tail -n 1 "$state/$id.status" 2>/dev/null) || last=
    case "$last" in
      paused*)
        m=$(fm_path_mtime "$state/$id.status" 2>/dev/null) || m=$best
        [ "$m" -ge "${3:-0}" ] || m=${3:-0}
        best=$m
        ;;
    esac
  fi
  printf '%s\n' "$best"
}

# One pass over every lease record in a state directory:
#  - a held lease whose holder has been inactive for FM_POOL_LEASE_IDLE_SECS is
#    released at the authority and marked lapsed;
#  - a held lease whose holder is active is renewed once a third of its ttl has
#    passed (an authority that no longer knows it - expired during an outage -
#    is asked for a fresh one, so a live worker keeps its place);
#  - a lapsed record whose holder is active again takes a new lease, and waits
#    (warning once per pass) while the pool is held.
# Quiet when nothing is due.
fm_pool_lease_tick() {  # <state-dir>
  local state=$1 record id lease pool cap server ttl renewed since lapsed secs now act rc
  now=${FM_POOL_LEASE_NOW:-$(date +%s)}
  for record in "$state"/*.pool-lease; do
    [ -f "$record" ] || continue
    id=$(basename "$record" .pool-lease)
    lease=$(fm_pool_lease_record_get "$record" lease)
    pool=$(fm_pool_lease_record_get "$record" pool)
    cap=$(fm_pool_lease_record_get "$record" cap)
    server=$(fm_pool_lease_record_get "$record" server)
    ttl=$(fm_pool_lease_record_get "$record" ttl)
    renewed=$(fm_pool_lease_record_get "$record" renewed)
    since=$(fm_pool_lease_record_get "$record" since)
    lapsed=$(fm_pool_lease_record_get "$record" lapsed)
    : "${ttl:=5m}" "${cap:=1}"
    secs=$(fm_pool_lease_ttl_seconds "$ttl") || secs=300
    case "$renewed" in '' | *[!0-9]*) renewed=0 ;; esac
    case "$since" in '' | *[!0-9]*) since=$renewed ;; esac
    [ -n "$server" ] || continue
    if [ -n "$lapsed" ]; then
      act=$(fm_pool_lease_activity "$state" "$id" "$lapsed")
      [ "$act" -gt "$lapsed" ] || continue
      rc=0
      fm_pool_lease_grant "$state" "$id" "fm:$id" "$pool" "$cap" "$server" "$ttl" || rc=$?
      [ "$rc" -eq 0 ] || echo "warning: $id is active again but quota pool $pool is held ($rc); its lease is retaken once the pool has room" >&2
      continue
    fi
    act=$(fm_pool_lease_activity "$state" "$id" "$since")
    if [ $((now - act)) -ge "$FM_POOL_LEASE_IDLE_SECS" ]; then
      fm_pool_lease_release_id "$server" "$lease" "$id"
      fm_pool_lease_write_record "$record" "" "$pool" "$cap" "$server" "$ttl" "$renewed" "$since" "$now" || true
      continue
    fi
    [ $((now - renewed)) -ge $((secs / 3)) ] || continue
    [ -n "$lease" ] || continue
    rc=0
    fm_run_timed "$FM_POOL_LEASE_CALL_TIMEOUT" lease-axi renew "$lease" --server "$server" --ttl "$ttl" >/dev/null 2>&1 </dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
      fm_pool_lease_write_record "$record" "$lease" "$pool" "$cap" "$server" "$ttl" "$now" "$since" || true
    elif [ "$rc" -eq 1 ]; then
      fm_pool_lease_grant "$state" "$id" "fm:$id" "$pool" "$cap" "$server" "$ttl" ||
        echo "warning: pool lease $lease for $id lapsed and could not be retaken; the worker keeps running until $pool has room" >&2
    else
      echo "warning: could not renew pool lease $lease for $id (exit $rc); it expires if the authority stays unreachable" >&2
    fi
  done
  return 0
}
