#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock.
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so exactly one
#     GENERATION owner arms per event epoch: the epoch ledger's monotonic
#     sequence is the claim generation, every firing defers (exit 0) to a live
#     open claim, and a stuck, dead, identity-mismatched, or finished claim is
#     superseded by taking the next generation instead of being unlocked or
#     revoked. No mutex is ever held across arming or output - the owner lock
#     survives only as the micro-mutex serializing individual ledger writes -
#     and a superseded owner goes completely silent: ownership is re-verified
#     before every arm invocation, episode-state mutation, ledger write, and
#     continuation (fm_autoarm_claim_open/fm_autoarm_claim_next in
#     bin/fm-wake-lib.sh own the contract, including the legacy shim for a
#     pre-generation lock).
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh in the FOREGROUND of
#     this hook-owned process tree (never shell &); Claude owns the process
#     group, so its timeout/session teardown kills arm and watcher together.
#   - Continuity: a quiet arm close is NOT proof that supervision survived. The
#     arm's benign "idle" line asserts that "adapter re-arm owns continuity",
#     and for a Claude primary this hook IS that adapter - so exiting 0 on it
#     would hand continuity to itself and then quit, leaving zero watchers with
#     nothing scheduled to notice. This owner therefore VERIFIES continuity
#     after every quiet close (fm_watcher_healthy, the live lock + identity +
#     beacon gate) and re-arms in this same foreground tree when no live watcher
#     survived, bounded by FM_AUTOARM_MAX_REARMS. Never a detached successor:
#     that would leave a watcher alive with no owner to notify.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat), a typed
#     watcher: FAILED, or an exhausted re-arm budget prints one rewake banner to
#     stderr and exits 2, which wakes Claude even while idle ("Stop hook
#     feedback"). The irrevocable commit point is the EXIT STATUS: the harness
#     delivers the collected stderr only on exit 2, so an owned terminal commit
#     decides the exit. Markerless outcomes commit with the ledger write; the
#     failure notice additionally requires its marker write. A refused
#     generation exits 0 silently even after printing. Exit 0 is otherwise
#     reserved for the cases where supervision is provably fine: no remaining
#     need, AFK took over, or a live watcher genuinely holds the singleton.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim
# generation and outcome so the synchronous Stop guard
# (bin/fm-turnend-guard.sh --claude) can allow a stop whose recovery this hook
# already owns, instead of forcing a duplicate continuation for the same event
# epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later automatic continuation in that unresolved episode.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
WATCH="$SCRIPT_DIR/fm-watch.sh"
# How many times one firing may re-arm behind a quiet close that left no live
# watcher. A real cycle blocks until its watcher ends, so this budget is only
# ever consumed by a watcher that cannot stay up; exhausting it is a genuine
# failure and becomes a loud exit-2 rewake rather than a silent exit.
MAX_REARMS=${FM_AUTOARM_MAX_REARMS:-20}
case "$MAX_REARMS" in ''|*[!0-9]*) MAX_REARMS=20 ;; esac
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-watch-cycle-lib.sh
. "$SCRIPT_DIR/fm-watch-cycle-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe, and its host
# is inspected before anything else runs.
PAYLOAD=$(cat 2>/dev/null || true)

# Cursor loads the tracked Claude settings too. Cursor has no asyncRewake, so if
# a future Cursor build starts firing the Claude-shaped Stop entry, this arm
# would run SYNCHRONOUSLY inside Cursor's stop step and hold that turn open for
# the declared multi-hour timeout - the exact wedge grok 1.0.0 produced
# (docs/turnend-guard.md "Harness integrations"). Cursor's own park adapter owns
# its turn boundary, so stand down on a Cursor-delivered payload.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work or an X-mode relay poll ----------------------------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- single-flight generation claim --------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# generation owner arms and translates per event epoch: every firing defers to
# a live open claim, and a stuck, dead, identity-mismatched, or finished claim
# is superseded by taking the next generation (fm_autoarm_claim_open and
# fm_autoarm_claim_next in bin/fm-wake-lib.sh own the contract). No mutex is
# held past this point. A micro-mutex contention with a bare hold is another
# participant's short ledger section and the next Stop firing simply retries,
# while a role-carrying hold is a legacy lock-holding claim from a
# pre-generation build (or the guard's own terminal-check), which the legacy
# shim defers to while genuinely deciding and reclaims once when proven
# abandoned.
fm_autoarm_claim_open "$STATE" "$GRACE" && exit 0
fm_autoarm_claim_next "$STATE" "$GRACE"
CLAIM_RC=$?
if [ "$CLAIM_RC" -ne 0 ]; then
  [ "$CLAIM_RC" -eq 2 ] && exit 0
  ROLE=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  [ -n "$ROLE" ] || exit 0
  fm_autoarm_release_abandoned "$STATE" "$GRACE" || exit 0
  fm_autoarm_claim_next "$STATE" "$GRACE" || exit 0
fi
MY_GEN=$FM_AUTOARM_MY_GEN
[ -n "$MY_GEN" ] || exit 0

# Commit <outcome> (optionally with the once-per-episode notice marker) for
# this generation. Success means this generation's translation WINS and the
# caller exits 2 unconditionally. Markerless outcomes commit with the owned
# ledger write; a notice wins only when its following marker write succeeds in
# the same hold. Failure means refused or unverifiable: the caller goes silent
# (cleanup, exit 0) - the harness discards the collected stderr on exit 0, so
# even an already-printed banner is never delivered by a losing generation.
autoarm_commit() {  # <outcome> [marker-file]
  if [ -n "${2:-}" ]; then
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" "$2"
  else
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1"
  fi
}

# Best-effort ownership-checked record for exit-0 paths, where supersession
# changes nothing about the action taken.
autoarm_record() {  # <outcome>
  fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" >/dev/null 2>&1 || true
}

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the arm wrapper, reconciling every close ----------------------
# NO shell &: this hook process tree is the harness-owned lifecycle. The arm
# forks the watcher as its own tracked child exactly as it does for the
# model-driven background-task path, and propagates the wake reason on close.
#
# Every non-actionable close is first checked against the same identity-matched
# live-watcher-plus-fresh-beacon predicate the turn-end guard uses: a live
# successor makes the close benign no matter its exit code. Only when no live
# watcher survived does the close translate into recovery, and two kinds are
# distinguished:
#   - A typed failure (nonzero rc or a "watcher: FAILED" line) is the automatic
#     mechanism itself failing. It is verified a bounded number of attempts
#     (FM_CLAUDE_AUTOARM_ATTEMPTS) and then raises the once-only mechanism alarm.
#   - A quiet close (rc 0, no actionable reason, no typed failure) means the arm
#     handed continuity to "some adapter" that, on a Claude primary, is this
#     hook. Exiting 0 there would end supervision with nothing scheduled to
#     restart it, so it re-arms in this same foreground tree (bounded by
#     FM_AUTOARM_MAX_REARMS) and, if that cannot re-establish a live watcher or a
#     durable wake is already queued, reports lost continuity.
OUT=
drop_output() {
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
}

ACTIONABLE=0
CONTINUITY_LOST=0
HEALTHY=0
REARMS=0
attempt=0

while :; do
  # A superseded owner must not start or attach another watcher or mutate any
  # watcher/wake state: re-verify generation ownership before every arm
  # invocation, first attempt and retries alike.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    drop_output
    exit 0
  fi
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
  if [ -n "$OUT" ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1
    RC=$?
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1
    RC=$?
  fi

  # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress the
  # rewake even for an actionable close and never re-arm against the daemon.
  if [ -e "$STATE/.afk" ]; then
    autoarm_record afk
    drop_output
    exit 0
  fi

  ACTIONABLE=0
  FAILEDLINE=0
  if [ -n "$OUT" ]; then
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null && ACTIONABLE=1
    grep -q '^watcher: FAILED' "$OUT" 2>/dev/null && FAILEDLINE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break

  # The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
  # left to supervise, so close quietly. This also populates FM_SUP_QUEUE_PENDING
  # for the durable-wake check below.
  if ! need_supervision; then
    autoarm_record clean
    drop_output
    exit 0
  fi

  # A non-actionable close is benign - whatever its exit code or typed failure
  # line - when another verified watcher already owns this home, matches its
  # identity, and is still beating. Only this proves the arm's "adapter re-arm
  # owns continuity" claim, so check it before any recovery.
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi

  # No live successor. A typed failure is the mechanism itself failing: verify it
  # up to the bounded attempt budget, then translate it into the once-only alarm.
  if [ "$RC" -ne 0 ] || [ "$FAILEDLINE" -eq 1 ]; then
    [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
    drop_output
    continue
  fi

  # A quiet close (rc 0, no actionable reason, no typed failure) that left no live
  # watcher ended supervision with nothing scheduled to restart it. A wake already
  # sitting in the durable queue needs a handling turn now, not another silent
  # cycle stacked behind it.
  if [ "$FM_SUP_QUEUE_PENDING" = true ]; then
    CONTINUITY_LOST=1
    break
  fi
  REARMS=$((REARMS + 1))
  if [ "$REARMS" -gt "$MAX_REARMS" ]; then
    CONTINUITY_LOST=1
    break
  fi
  autoarm_record rearming
  drop_output
  # A healthy cycle blocks; only a watcher that cannot stay up returns straight
  # away, so pace the retry rather than spinning through the whole budget.
  sleep 1
done

# --- classify and translate ---------------------------------------------------
# The need may have vanished while the final cycle ran: nothing left to
# supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  autoarm_record clean
  drop_output
  exit 0
fi

# A live successor genuinely survived the close: benign. Reset the failure
# episode so a later genuine failure starts a fresh bounded progression.
if [ "$HEALTHY" -eq 1 ]; then
  fm_autoarm_reset_owned "$STATE" "$MY_GEN"
  RESET_RC=$?
  if [ "$RESET_RC" -eq 0 ]; then
    autoarm_record clean
    drop_output
    exit 0
  fi
  if [ "$RESET_RC" -eq 2 ]; then
    drop_output
    exit 0
  fi
  if autoarm_commit failed-suppressed; then
    drop_output
    [ -e "$FAILURE_ALARM" ] && exit 0
    exit 2
  fi
  drop_output
  exit 0
fi

# After the synchronous guard has consumed the episode's attended fail-open, do
# not create another exit-2 continuation that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  autoarm_record failed-suppressed
  drop_output
  exit 0
fi

# An actionable close: one supervision event needs a handling turn now.
if [ "$ACTIONABLE" -eq 1 ]; then
  # Cheap early-out before composing the banner; the real commit decision is
  # the owned terminal write below.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    drop_output
    exit 0
  fi
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
  if autoarm_commit rewake; then
    drop_output
    exit 2
  fi
  drop_output
  exit 0
fi

# A quiet close left supervision down with no live successor: re-arming could not
# re-establish it, or a durable wake is already queued. Report lost continuity.
if [ "$CONTINUITY_LOST" -eq 1 ]; then
  # Cheap early-out before composing the banner; the real commit decision is
  # the owned terminal write below.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    drop_output
    exit 0
  fi
  {
    printf 'firstmate watcher continuity LOST - supervision ended and could not be re-established while this home still needs it.\n'
    fm_cycle_describe "$STATE" 2>/dev/null || true
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first. Then repair supervision with bin/fm-watch-arm.sh as its own Claude Code background task (never shell &). If it will not stay up, treat it as a blocker and report it instead of ending blind.\n'
  } >&2
  if autoarm_commit rewake; then
    drop_output
    exit 2
  fi
  drop_output
  exit 0
fi

# A typed failure exhausted its bounded attempts: the automatic mechanism itself
# is broken. Notify only once for this continuous failure episode; every later
# invocation still exits 2 so Claude continues into another Stop-owned retry
# without creating a repeated operator notice or manual-arm loop. The notice
# marker commits in the same owned critical section as the winning failed write,
# so a losing generation can neither consume nor deliver it.
if [ ! -e "$FAILURE_NOTICE" ]; then
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    drop_output
    exit 0
  fi
  {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } >&2
  if autoarm_commit failed "$FAILURE_NOTICE"; then
    drop_output
    exit 2
  fi
  drop_output
  exit 0
fi
if autoarm_commit failed-suppressed; then
  drop_output
  exit 2
fi
drop_output
exit 0
