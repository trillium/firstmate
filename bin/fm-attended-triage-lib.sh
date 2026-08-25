#!/usr/bin/env bash
# Attended background triage: the sub-supervisor's second, smarter pass over the
# durable wake queue while the captain is PRESENT (state/.afk ABSENT).
#
# WHY. The always-on watcher's triage is deliberately cheap and pattern-only, so
# it enqueues anything it cannot positively call benign. Every one of those
# records then costs the main firstmate session a turn. This library lets the
# already-running sub-supervisor spend a small, bounded amount of a cheap model's
# attention on the records the pattern rules did NOT positively classify, and
# drop the ones that provably need nobody. Absorption is the entire point: it is
# what frees the main session.
#
# WHAT ATTENDED MODE IS. Attended triage differs from away mode in exactly one
# way - what it does with a wake that must reach the captain:
#   away     buffer it and inject the marked away-supervisor escalation
#            (bin/fm-operational-input.sh contract, owned by the daemon).
#   attended LEAVE it on the durable wake queue, untouched, so the main session
#            surfaces it at the top of its next turn exactly as today.
# Attended mode NEVER injects operational input. The captain is already present,
# and a marked/unmarked mixup in an attended session is precisely the away-mode
# exit hazard; nothing here touches that discrimination.
#
# TWO TIERS, ONE DIRECTION. Tier 1 is the existing shared verb/regex classifier
# (bin/fm-classify-lib.sh) plus the never-absorb rules below. Tier 1 can only
# ever FORCE AN ESCALATION; it is authoritative and the model can never override
# it. Tier 2 asks a cheap model, and absorption requires that model's affirmative
# `absorb`. So every degraded path - no binary, non-zero exit, timeout, empty or
# unparseable answer, call cap reached, feature disabled - lands on escalate,
# which is byte-for-byte today's behavior. The model call is strictly
# non-load-bearing: a missing model can never wedge or silence supervision.
#
# NEVER ABSORB. Independent of the model, these always escalate:
#   * any done:/needs-decision:/blocked:/failed: verb, in the wake payload or in
#     the task's own last status line;
#   * any Relay mention or Relay configuration error check;
#   * any merged-PR or checks-green result;
#   * any staleness auto-close reclaim;
#   * any wake for a task that still has an OPEN keyed decision record;
#   * any heartbeat (the fleet-wide catch-all backstop: a single record carries
#     no evidence about the fleet it is asking firstmate to review, so its
#     routineness is not judgeable here);
#   * any wake whose kind or key this library does not recognise.
#
# SWITCH. Off unless the captain turns it on; see docs/configuration.md
# "Attended background triage (config/attended-triage)".
#
# Env knobs (all optional, daemon FM_* style):
#   FM_ATTENDED_TRIAGE          on|off - overrides config/attended-triage
#   FM_ATTENDED_TRIAGE_MODEL    model passed to `claude -p --model` (default haiku)
#   FM_ATTENDED_TRIAGE_TIMEOUT_SECS  hard per-call watchdog (default 8)
#   FM_ATTENDED_TRIAGE_MAX_CALLS     model calls per pass (default 4)
#   FM_ATTENDED_TRIAGE_EXEC     command invoked instead of `claude` (testing)
#   FM_ATTENDED_TRIAGE_STATUS_TAIL_LINES  status lines shown to the model (default 8)

FM_ATTENDED_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FM_ATTENDED_TRIAGE_MODEL_DEFAULT=haiku
FM_ATTENDED_TRIAGE_TIMEOUT_SECS_DEFAULT=8
FM_ATTENDED_TRIAGE_MAX_CALLS_DEFAULT=4
FM_ATTENDED_TRIAGE_STATUS_TAIL_LINES_DEFAULT=8

# Shared verb classifier: status_is_captain_relevant, status_is_terminal_verb,
# last_status_line, status_open_decisions, window_to_task. Guard-sourced so a
# caller that already loaded it (the daemon does, at top level) is not reloaded.
if ! command -v status_is_captain_relevant >/dev/null 2>&1; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$FM_ATTENDED_LIB_DIR/fm-classify-lib.sh"
fi
# shellcheck source=bin/fm-triage-log-lib.sh
. "$FM_ATTENDED_LIB_DIR/fm-triage-log-lib.sh"

# The durable-queue primitives live in bin/fm-wake-lib.sh, which has source-time
# side effects (it resolves STATE and creates it). Requiring it lazily keeps THIS
# library free of them, so unit tests can source it for the pure classifiers
# without a state dir appearing anywhere.
fm_attended_require_wake_lib() {
  command -v fm_wake_absorb_seqs >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_ATTENDED_LIB_DIR/fm-wake-lib.sh"
}

# --- configuration ----------------------------------------------------------

# Print the first meaningful line of a config file, ignoring blanks and #
# comments, in the established config/ style (see docs/configuration.md).
fm_attended_config_line() {  # <path>
  local path=$1 line
  [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    printf '%s' "$line"
    return 0
  done < "$path"
  return 1
}

# 0 when attended triage is switched on. Precedence: FM_ATTENDED_TRIAGE env
# override, then config/attended-triage, then OFF. The default is deliberately
# off: a captain who does nothing keeps exactly today's supervision regime.
# Any unrecognised value is treated as off and logged, so a typo silently
# weakens nothing.
fm_attended_enabled() {  # [<home>]
  local home=${1:-${FM_HOME:-}} value=''
  if [ -n "${FM_ATTENDED_TRIAGE:-}" ]; then
    value=$FM_ATTENDED_TRIAGE
  elif [ -n "$home" ]; then
    value=$(fm_attended_config_line "$home/config/attended-triage" || true)
  fi
  case "$value" in
    on|On|ON|true|yes|1) return 0 ;;
    ''|off|Off|OFF|false|no|0) return 1 ;;
    *)
      triage_log "attended: ignoring unrecognised attended-triage setting '$value' (treated as off)"
      return 1
      ;;
  esac
}

fm_attended_bounded_int() {  # <value> <default>
  local v=$1 d=$2
  case "$v" in
    ''|*[!0-9]*) printf '%s' "$d"; return 0 ;;
  esac
  [ "$v" -gt 0 ] 2>/dev/null || { printf '%s' "$d"; return 0; }
  printf '%s' "$v"
}

# --- record -> task ---------------------------------------------------------

# Print the task id a queued wake belongs to, or nothing when the record is not
# task-scoped. Never guesses a task that has no local record: a wrong answer here
# would consult the wrong status log, and the never-absorb rules that depend on
# it must fail toward escalation, not toward a confident absorb.
fm_attended_task_for_wake() {  # <kind> <key> <state>
  local kind=$1 key=$2 state=$3 id
  case "$kind" in
    signal)
      case "$key" in
        *.status) id=${key%.status} ;;
        *.turn-ended) id=${key%.turn-ended} ;;
        *) return 1 ;;
      esac
      ;;
    stale)
      id=$(window_to_task "$key" "$state" 2>/dev/null || true)
      ;;
    check)
      case "$key" in
        review-decision:*) id=${key#review-decision:} ;;
        procevent:*|herdr-spur:*) return 1 ;;
        *) id=$key ;;
      esac
      ;;
    *) return 1 ;;
  esac
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ] || return 1
  [ -e "$state/$id.meta" ] || [ -e "$state/$id.status" ] || return 1
  printf '%s' "$id"
}

# --- tier 1: never-absorb rules --------------------------------------------

# 0 when a hard rule forces this record to reach the captain, printing the
# reason. 1 when no hard rule fires, which is the ONLY state in which tier 2 may
# be consulted. This is a pure read of durable records: no model, no network.
fm_attended_never_absorb() {  # <kind> <key> <payload> <state>
  local kind=$1 key=$2 payload=$3 state=$4 task last open

  case "$kind" in
    signal|stale|check) ;;
    heartbeat)
      printf 'heartbeat is the fleet-wide catch-all review, not a single judgeable event'
      return 0
      ;;
    *)
      printf 'unrecognised wake kind: %s' "$kind"
      return 0
      ;;
  esac

  # Relay (public mention) traffic: outward-facing and time-sensitive, and the
  # daemon is not the home that owns the reply.
  case "$key" in
    x-watch*|x-mention*|x-mode-error*|*x-mention*|*x-mode-error*)
      printf 'relay mention/configuration wake'
      return 0
      ;;
    unauthenticated-state-checks*)
      printf 'unauthenticated state-check refusal'
      return 0
      ;;
    review-decision:*)
      printf 'captain review decision'
      return 0
      ;;
  esac
  case "$payload" in
    *x-mention*|*x-mode-error*)
      printf 'relay mention/configuration wake'
      return 0
      ;;
  esac

  # Delivery results and reclaims the captain must always see.
  if printf '%s' "$payload" | grep -qiE 'merged|checks green|checks-passed|checks passed|pr ready|ready in branch'; then
    printf 'delivery result in payload'
    return 0
  fi
  if printf '%s %s' "$key" "$payload" | grep -qiE 'staleness|auto-?close'; then
    printf 'staleness auto-close reclaim'
    return 0
  fi

  # A terminal verb anywhere in the payload text.
  if status_is_captain_relevant "$payload"; then
    printf 'captain-relevant verb in payload'
    return 0
  fi

  task=$(fm_attended_task_for_wake "$kind" "$key" "$state" || true)
  if [ -n "$task" ]; then
    last=$(last_status_line "$state/$task.status" 2>/dev/null || true)
    if [ -n "$last" ] && status_is_captain_relevant "$last"; then
      printf 'captain-relevant last status line for %s' "$task"
      return 0
    fi
    open=$(status_open_decisions "$state/$task.status" 2>/dev/null || true)
    if [ -n "$open" ]; then
      printf 'open decision record for %s' "$task"
      return 0
    fi
  fi

  return 1
}

# --- tier 2: bounded model verdict -----------------------------------------

# Run a command with a hard wall-clock ceiling, portably (timeout(1) is not
# guaranteed on macOS). Output goes to <outfile>; the caller reads the file, so a
# surviving grandchild cannot hold this function open. Returns the command's exit
# status, or >=128 when the watchdog terminated it.
fm_attended_run_bounded() {  # <timeout-secs> <outfile> <cmd> [<arg>...]
  local secs=$1 out=$2 pid killer rc=0
  shift 2
  : > "$out" 2>/dev/null || return 125
  "$@" > "$out" 2>/dev/null &
  pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null || true ) >/dev/null 2>&1 &
  killer=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  return "$rc"
}

fm_attended_prompt() {  # <kind> <key> <payload> <status-tail>
  cat <<PROMPT
You are triaging one background notification for an autonomous software fleet
supervisor. The supervisor's human captain is present and busy; a notification
that reaches them costs them an interruption.

Answer with exactly one word, then a short reason on the same line:
  escalate <reason>   the captain must see this now
  absorb <reason>     nobody needs to act on this

Escalate whenever you are unsure. Absorb only routine progress noise: a worker
that is plainly still working, a repeat of something already reported, a
notification with no actionable content.

wake kind: $1
wake key: $2
wake payload: $3
recent status lines for this work (oldest first, may be empty):
$4
PROMPT
}

# Print "<verdict>\t<reason>" (verdict absorb|escalate) from a cheap model.
# Non-zero return on ANY degraded path; the caller then escalates. Distinct codes
# make the failure mode auditable in the triage log:
#   3 binary absent   4 non-zero exit   5 timeout   6 empty output
#   7 unparseable answer   125 could not stage output
fm_attended_model_verdict() {  # <kind> <key> <payload> <status-tail>
  local kind=$1 key=$2 payload=$3 tail=$4
  local exec_cmd model secs out rc line verdict reason

  exec_cmd=${FM_ATTENDED_TRIAGE_EXEC:-claude}
  command -v "$exec_cmd" >/dev/null 2>&1 || return 3
  model=${FM_ATTENDED_TRIAGE_MODEL:-$FM_ATTENDED_TRIAGE_MODEL_DEFAULT}
  secs=$(fm_attended_bounded_int "${FM_ATTENDED_TRIAGE_TIMEOUT_SECS:-}" "$FM_ATTENDED_TRIAGE_TIMEOUT_SECS_DEFAULT")

  out=$(mktemp "${TMPDIR:-/tmp}/fm-attended-verdict.XXXXXX" 2>/dev/null) || return 125
  rc=0
  fm_attended_run_bounded "$secs" "$out" \
    "$exec_cmd" -p --model "$model" "$(fm_attended_prompt "$kind" "$key" "$payload" "$tail")" || rc=$?

  line=$(grep -m1 -E '[^[:space:]]' "$out" 2>/dev/null || true)
  rm -f "$out" 2>/dev/null || true

  if [ "$rc" -ge 128 ]; then
    return 5
  elif [ "$rc" -ne 0 ]; then
    return 4
  fi
  [ -n "$line" ] || return 6

  line=${line#"${line%%[![:space:]]*}"}
  verdict=${line%%[[:space:]]*}
  reason=${line#"$verdict"}
  reason=${reason#"${reason%%[![:space:]]*}"}
  case "$verdict" in
    absorb|Absorb|ABSORB) verdict=absorb ;;
    escalate|Escalate|ESCALATE) verdict=escalate ;;
    *) return 7 ;;
  esac
  [ -n "$reason" ] || reason='(no reason given)'
  printf '%s\t%s' "$verdict" "$reason"
}

# --- the pass ---------------------------------------------------------------

fm_attended_status_tail() {  # <task> <state>
  local task=$1 state=$2 lines
  [ -n "$task" ] || return 0
  lines=$(fm_attended_bounded_int "${FM_ATTENDED_TRIAGE_STATUS_TAIL_LINES:-}" "$FM_ATTENDED_TRIAGE_STATUS_TAIL_LINES_DEFAULT")
  [ -f "$state/$task.status" ] && [ ! -L "$state/$task.status" ] || return 0
  tail -n "$lines" "$state/$task.status" 2>/dev/null | cut -c1-300 || true
}

# Judge one queued record. Prints "<verdict>\t<tier>\t<reason>". Only ever
# prints absorb when tier 1 declined to force an escalation AND the model
# affirmatively answered absorb.
fm_attended_record_verdict() {  # <kind> <key> <payload> <state> <calls-left>
  local kind=$1 key=$2 payload=$3 state=$4 calls_left=$5
  local reason task tail model_out rc=0 verdict

  if reason=$(fm_attended_never_absorb "$kind" "$key" "$payload" "$state"); then
    printf 'escalate\trule\t%s' "$reason"
    return 0
  fi

  if [ "$calls_left" -le 0 ]; then
    printf 'escalate\tcap\tmodel call cap reached for this pass'
    return 0
  fi

  task=$(fm_attended_task_for_wake "$kind" "$key" "$state" || true)
  tail=$(fm_attended_status_tail "$task" "$state")

  model_out=$(fm_attended_model_verdict "$kind" "$key" "$payload" "$tail") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'escalate\tmodel-failed\tmodel verdict unavailable (code %s), falling back to the pattern verdict' "$rc"
    return 0
  fi
  verdict=${model_out%%$'\t'*}
  reason=${model_out#*$'\t'}
  case "$verdict" in
    absorb) printf 'absorb\tmodel\t%s' "$reason" ;;
    *) printf 'escalate\tmodel\t%s' "$reason" ;;
  esac
}

# The attended pass itself: judge every queued record, remove the absorbed ones
# from the durable queue, and leave everything else exactly where the watcher put
# it so the main session surfaces it on its next turn.
#
# Refuses to run while away mode is active. Away mode owns the queue and its own
# buffer-and-inject escalation path, and nothing here may alter it.
#
# Prints nothing. Every verdict, absorbed or not, is written to the shared triage
# log with its tier so the captain can audit what was dropped and why.
fm_attended_triage_pass() {  # <state>
  local state=$1 rows row epoch seq kind key payload
  local verdict tier reason judged=0 absorbed=0 removed
  local max_calls calls_left
  local -a drop=()
  # Pin the shared triage log AND the durable queue to the state dir this pass
  # was handed, rather than to whatever a caller resolved at source time. These
  # are locals, so dynamic scoping redirects the shared helpers for the duration
  # of this pass only and no caller that owns its own paths (the watcher) is
  # ever redirected. Pinning the queue is a safety property, not a convenience:
  # this pass DELETES records, and it must be structurally incapable of deleting
  # them from a queue other than the one belonging to the state dir it is
  # supervising.
  local TRIAGE_LOG="$state/.watch-triage.log"
  local FM_WAKE_QUEUE="$state/.wake-queue"
  local FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock"

  [ -n "$state" ] || return 0
  fm_attended_enabled || return 0
  if [ -e "$state/.afk" ]; then
    return 0
  fi

  fm_attended_require_wake_lib
  rows=$(fm_wake_records 2>/dev/null || true)
  [ -n "$rows" ] || return 0

  max_calls=$(fm_attended_bounded_int "${FM_ATTENDED_TRIAGE_MAX_CALLS:-}" "$FM_ATTENDED_TRIAGE_MAX_CALLS_DEFAULT")
  calls_left=$max_calls

  # shellcheck disable=SC2034 # epoch is a queue field this pass does not use.
  while IFS=$'\t' read -r epoch seq kind key payload; do
    [ -n "$seq" ] || continue
    judged=$((judged + 1))
    IFS=$'\t' read -r verdict tier reason <<EOF
$(fm_attended_record_verdict "$kind" "$key" "$payload" "$state" "$calls_left")
EOF
    case "$tier" in
      model|model-failed) calls_left=$((calls_left - 1)) ;;
    esac
    triage_log "attended: $verdict tier=$tier kind=$kind key=$key reason=$reason"
    if [ "$verdict" = absorb ]; then
      drop+=("$seq")
      absorbed=$((absorbed + 1))
    fi
  done <<EOF
$rows
EOF

  if [ "${#drop[@]}" -gt 0 ]; then
    removed=$(fm_wake_absorb_seqs "${drop[@]}" 2>/dev/null || echo 0)
    triage_log "attended: pass judged $judged, absorbed $absorbed, removed $removed from the wake queue"
  fi
  return 0
}
