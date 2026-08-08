#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A declared external-wait pause is
# the separate idle absorb case and re-surfaces only on its long bounded cadence,
# although its initial no-verb status signal still surfaces in normal mode.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge. Only when neither
#                          absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active. A genuinely busy pane
#                          (window_is_busy true) is exempt from the above, but
#                          only up to BUSY_TURN_MAX_SECS with no completed turn
#                          (state/<id>.turn-ended, or the spawn record before any
#                          turn completes); past that bound busy_turn_over_age
#                          routes it through the same wedge timer, so it surfaces
#                          with the identical "stale: ..." reason, escalation
#                          count, and demand-deep-inspection marker, for human
#                          inspection only - never an automatic interrupt,
#                          signal, or restart of the worker or its tool process.
#   check: <script>: <out> authenticated check output, always actionable
#   check: process-event result captured: <keys>
#                          a durably captured process-to-event result is queued
#                          and has not been surfaced yet; reported once per
#                          captured generation, never again while that record
#                          stays queued and never once it is acknowledged
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: rejected unauthenticated PR poll retirement receipts: <paths>
#                          invalid pending retirements were preserved without
#                          running a check or removing poll artifacts
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# The native event fast-path and only its true dependencies have one narrow
# production owner. The Herdr event-wait smoke test consumes this same owner
# without sourcing the entire watcher graph.
# shellcheck source=bin/fm-push-transition-lib.sh
. "$SCRIPT_DIR/fm-push-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat, via the single owner in bin/fm-stat-lib.sh (sourced above through
# fm-pr-lib.sh, and again explicitly here because this file calls it directly).
# Two traps that lib exists to close, both of which used to live here:
#   - `stat -f <fmt> ... || stat -c <fmt> ...` is unsafe, because GNU's `-f` is
#     --file-system: it writes a filesystem dump to stdout and only THEN exits 1.
#     The `||` does fire; that is the trap, not the escape. A single
#     `$(... || ...)` captures both commands, so the fallback's correct integer
#     lands appended to the dump at overall rc=0, and arithmetic under `set -u`
#     aborts on a stray token and silently kills the watcher mid-cycle.
#   - `uname` is the wrong discriminator. A Darwin kernel routinely resolves
#     `stat` to GNU coreutils (nix-darwin, or Homebrew coreutils ahead of
#     /usr/bin on PATH), so the kernel's name does not predict the binary's
#     dialect. fm-stat-lib.sh feature-detects the binary once and caches it.
# shellcheck source=bin/fm-stat-lib.sh
. "$SCRIPT_DIR/fm-stat-lib.sh"
stat_mtime() { fm_stat_mtime "$1"; }      # epoch seconds of mtime
stat_sig()   { fm_stat_signature "$1"; }  # size:mtime signature

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
IDLE_DISCOVERY_INTERVAL=${FM_IDLE_DISCOVERY_INTERVAL:-60}  # seconds between idle-task-discovery attempts
DEAD_WINDOW_SWEEP_INTERVAL=${FM_DEAD_WINDOW_SWEEP_INTERVAL:-300}  # seconds between dead-window triage sweeps
# Busy state is decided by the semantic contract in bin/fm-busy-lib.sh, which
# is the single owner of per-harness sources, source attribution, and the one
# remaining rendered-text fallback (Grok only).
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# Idle>2h staleness auto-close backstop (captain design, 2026-07-31): once an
# ordinary ship task's pane content (.hash-<key>, see staleness_autoclose_reclaim)
# has sat unchanged this long AND the crew is not provably working (see
# crew_is_provably_working - a validating crew legitimately sits on a static
# pane for its whole run), the prompt-cache advantage of keeping its live
# process around is already gone (Anthropic cache TTL is 5m/1h), so the watcher
# reclaims it via bin/fm-teardown.sh --staleness-autoclose rather than leaving
# costly compute idle indefinitely. Also runs while away (state/.afk exists) -
# reclaiming wasted idle compute matters most while nobody is watching it - and
# bin/fm-teardown.sh's own landed-check still guarantees unlanded work is only
# ever chat-reclaimed (worktree, branch, and uncommitted changes preserved),
# never force-discarded, regardless of afk state. A reap-candidate pane the
# captain is actively reading/scrolling in herdr (a non-captain-relevant idle
# pane such as a quiet working:/resolved: pane whose crew looks finished but the
# captain is still reviewing it) is the one idle pane that must NOT be reclaimed
# out from under them: it too shows zero content churn, so
# staleness_focus_guard_blocks_reap gates the reclaim on the pane's live
# human-focus signal - see STALENESS_FOCUS_GRACE_SECS below.
STALENESS_AUTOCLOSE_SECS=${FM_STALENESS_AUTOCLOSE_SECS:-7200}
# A reclaim call that keeps failing (a broken FM_TEARDOWN_BIN, a wedged
# git/teardown dependency) must not retry silently forever: bounded attempts
# with doubling backoff, then give up until the pane's hash next changes and
# let the window fall through to ordinary stale surfacing/escalation below so
# a stuck reclaim notifies instead of looping invisibly.
STALENESS_AUTOCLOSE_MAX_RETRIES=${FM_STALENESS_AUTOCLOSE_MAX_RETRIES:-5}
STALENESS_AUTOCLOSE_RETRY_BASE_SECS=${FM_STALENESS_AUTOCLOSE_RETRY_BASE_SECS:-300}
STALENESS_AUTOCLOSE_RETRY_MAX_SECS=${FM_STALENESS_AUTOCLOSE_RETRY_MAX_SECS:-3600}
# Human-conversation guard for the reclaim above. A currently-focused pane blocks
# the reclaim outright; a pane focused within this many seconds also blocks it, so
# a captain who glances away from a quiet working:/resolved: pane mid-review does
# not lose it in the gap. Focus history is not queryable in herdr (only the current boolean is), so
# staleness_focus_stamp touches state/.focus-<key> on every poll an idle ship
# candidate is seen focused - not only past the 2h threshold - so the window is
# already accurate the instant the pane crosses it; staleness_focus_guard_blocks_reap
# then ages that marker against this window. Tunable for a captain who wants a
# longer/shorter courtesy grace; default 5 min. A malformed override (non-numeric
# or empty) would break the guard's integer age comparison below and silently drop
# the reclaim protection, so reject anything that is not all-digits and fall back to
# the shipped default - the same ''|*[!0-9]* sanitize the retry counters use.
STALENESS_FOCUS_GRACE_SECS=${FM_STALENESS_FOCUS_GRACE_SECS:-300}
case "$STALENESS_FOCUS_GRACE_SECS" in ''|*[!0-9]*) STALENESS_FOCUS_GRACE_SECS=300 ;; esac
# FM_TEARDOWN_BIN lets tests stub the reclaim call, matching the
# FM_CREW_STATE_BIN seam in bin/fm-classify-lib.sh.
FM_TEARDOWN_BIN="${FM_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"
# A busy pane is unconditional proof of liveness with no built-in duration bound,
# so a hung foreground call can remain hidden even while its rendered busy
# footer changes every poll. BUSY_TURN_MAX_SECS bounds how long any busy pane
# may go with no completed turn: once its task's
# state/<id>.turn-ended marker (or, before any turn has completed, the task's
# spawn record) is this old, busy_turn_over_age routes the pane through the
# same STALE_ESCALATE_SECS-paced wedge_timer_check used for a provably-working
# non-busy stale, so it escalates via the existing stale reason, escalation
# counter, and demand-deep-inspection marker for human inspection only - never
# an automatic interrupt, signal, or restart. A completed turn touches
# turn-ended and resets the age. Set generously above any legitimate interval
# between completed turns, including long tool calls, builds, or test runs.
BUSY_TURN_MAX_SECS=${FM_BUSY_TURN_MAX_SECS:-3600}
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew whose agent has confidently exited uses the same
# bounded cadence, while a live or ambiguously read agent still surfaces once.
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten hold cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

hash_pane() {
  local sbin_md5="${FM_MD5_SBIN_OVERRIDE:-/sbin/md5}"
  # Only used for change-detection between polls, so any tool that reliably
  # returns the checksum in its first whitespace-delimited field is
  # interchangeable here. The chain degrades through progressively more
  # universal tools rather than hard-erroring when a watcher's PATH is
  # missing md5/md5sum (observed on a secondmate whose runtime PATH omitted
  # both): openssl and cksum are near-universal fallbacks, and the final tier
  # is a pure-shell content digest (od + awk, both POSIX baseline) rather
  # than a raw byte count, so two same-size panes with different content
  # cannot collide and mask a real change.
  if command -v md5 >/dev/null 2>&1; then
    # A PATH `md5` is not always BSD md5: Homebrew's coreutils/md5sha1sum `md5`
    # shadows /sbin/md5 and rejects -q (printing "invalid option" and an empty
    # hash), which silently breaks pane change-detection. Parse the first
    # whitespace field instead of trusting -q, so BSD ("<hash>"), GNU/Homebrew
    # ("<hash>  -") md5 all yield the same real digest.
    md5 | awk '{ print $1 }'
  elif [ -x "$sbin_md5" ]; then
    "$sbin_md5" -q
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -md5 -r | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum | cut -d' ' -f1
  elif command -v cksum >/dev/null 2>&1; then
    printf '%x\n' "$(cksum | cut -d' ' -f1)"
  else
    od -An -tu1 -v | awk '
      { for (i = 1; i <= NF; i++) h = (h * 31 + $i) % 4294967291 }
      END { printf "%x\n", h }
    '
  fi
}

# window_is_busy: 0 (busy) iff the task's harness is PROVABLY working, through
# the semantic busy-state contract (bin/fm-busy-lib.sh). Only an exact busy
# verdict returns 0: idle, unknown, and dead all return 1, so a converted
# adapter whose semantic state is missing, malformed, stale, or unverified is
# treated as not-provably-working and surfaces rather than being absorbed.
# <tail40> is the same bounded capture already read for hashing and is
# consumed only by the Grok-scoped fallback inside the contract.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 task meta verdict
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  if [ -n "$task" ] && [ -f "$meta" ]; then
    verdict=$(fm_busy_classify_meta "$meta" "$task" "$STATE" "$tail40")
  else
    verdict=$(fm_busy_classify "$(window_backend "$w")" "$w" "$(window_harness "$w")" \
      "${task:-unknown}" "$STATE" "$tail40")
  fi
  [ "${verdict%% *}" = busy ]
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_harness() {
  local w=$1 meta
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  grep '^harness=' "$meta" | cut -d= -f2- || true
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 since age n reason
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# Idle>2h staleness auto-close (see STALENESS_AUTOCLOSE_SECS above): reclaim an
# ordinary ship task's expensive live process once its pane has shown zero
# change for that long, regardless of wedge/pause classification. Delegates the
# landed-vs-unlanded decision entirely to bin/fm-teardown.sh's
# --staleness-autoclose mode, which never deletes a worktree that has not
# landed (git-verified) and instead files it to the staleness triage store.
# Silent by design (like idle-task-discovery below): this is a deterministic,
# reversible-for-unlanded-work reclaim, not a captain-actionable wake - except
# while away (afk_present), when a successful reclaim also appends one line to
# STALE_AUTOCLOSE_AFK_LOG so bin/fm-afk-return.sh can surface it as durable
# catch-up evidence the next time the captain returns; nothing reads that log
# while away, so it never wakes anything. Returns 1 on a failed reclaim so the
# caller can drive the bounded retry/backoff below.
STALE_AUTOCLOSE_AFK_LOG="$STATE/.staleness-autoclose-afk.log"
staleness_autoclose_reclaim() {  # <window> <task> <hash-file>
  local win=$1 task=$2 hf=$3 idle_since idle_age
  idle_since=$(stat_mtime "$hf")
  idle_age=$(age_of "$hf")
  if "$FM_TEARDOWN_BIN" "$task" --staleness-autoclose "${idle_since:-}" \
    >>"$STATE/.staleness-autoclose.log" 2>&1; then
    triage_log "staleness auto-close reclaimed $win (task $task, idle ${idle_age}s)"
    if afk_present; then
      printf 'reclaimed %s (task %s, idle %ss)\n' "$win" "$task" "$idle_age" >> "$STALE_AUTOCLOSE_AFK_LOG"
    fi
    return 0
  fi
  triage_log "staleness auto-close FAILED for $win (task $task); leaving window as-is for the next poll"
  return 1
}

# staleness_focus_stamp: read <window>'s live human-focus once and, when it is
# focused, (re)touch state/.focus-<key> so the recency window in
# staleness_focus_guard_blocks_reap ages from the last time a human actually had
# the pane. Called every poll for an idling ship candidate - at any idle age, not
# only past the 2h threshold - because herdr exposes no queryable focus history:
# the marker IS that history, and it must already be accurate the instant the
# pane crosses the threshold. Echoes the read focus state (focused|unfocused|
# unsupported|unknown) for the guard to reuse, or "na" on a focus-unaware backend
# (tmux et al.) so a single read serves both stamp and guard. Strictly read-only
# against the backend; the only write is the local marker touch.
staleness_focus_stamp() {  # <window> <key> -> focused|unfocused|unsupported|unknown|na
  local w=$1 key=$2 fstate uf n
  [ "$(window_backend "$w")" = herdr ] || { printf 'na'; return 0; }
  uf="$STATE/.focus-unknown-$key"
  fstate=$(fm_backend_pane_focus_state herdr "$w" 2>/dev/null) || fstate=unknown
  case "$fstate" in
    focused)
      touch "$STATE/.focus-$key" 2>/dev/null || true
      rm -f "$uf" 2>/dev/null || true
      ;;
    unknown)
      n=$(cat "$uf" 2>/dev/null || echo 0)
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      echo "$(( n + 1 ))" > "$uf" 2>/dev/null || true
      ;;
    *)
      rm -f "$uf" 2>/dev/null || true
      ;;
  esac
  printf '%s' "$fstate"
}

# staleness_focus_guard_blocks_reap: 0 (BLOCK the idle>2h auto-close reclaim this
# cycle) when a human is - or was very recently - actively viewing this task's
# pane; 1 (allow the reclaim) otherwise. The current focus state is read once per
# poll by staleness_focus_stamp and passed in here, so this is a pure decision
# with no second backend read. All three focus branches converge on ONE reap
# rule: reap iff the pane is NOT focused now AND has no fresh state/.focus-<key>
# recency marker within STALENESS_FOCUS_GRACE_SECS. "na" (a focus-unaware backend
# such as tmux) and "unsupported" (a herdr build that structurally cannot report
# pane focus) skip the guard entirely and allow the reclaim, so a focus-less
# backend can never permanently wedge the idle>2h auto-close. A currently-focused
# pane always blocks. An unreadable ("unknown") pane stays protective while its
# consecutive-unknown count is below the bound (a transient focus-read blip is
# forgiven, err toward NOT reaping); once STALENESS_AUTOCLOSE_MAX_RETRIES
# consecutive unknown polls accumulate (staleness_focus_stamp advances
# state/.focus-unknown-<key> and resets it on any readable poll) the unknown pane
# is subjected to the SAME within-grace recency check as an unfocused pane, so a
# persistently-unreadable dead/destroyed herdr runtime (no fresh marker) falls
# through to reap while a live pane focused within the grace window stays blocked
# even through a sustained unreadable stretch. Every blocked reclaim is logged - a
# silent skip reads as "nothing happened". Never a failure: a focus-blocked skip
# does not consume the reclaim retry budget.
staleness_focus_guard_blocks_reap() {  # <window> <task> <key> <focus-state>
  local w=$1 task=$2 key=$3 fstate=$4 mf ucount
  mf="$STATE/.focus-$key"
  case "$fstate" in
    na|unsupported)
      return 1
      ;;
    focused)
      triage_log "staleness auto-close skipped for $w (task $task): pane is focused by a human"
      return 0
      ;;
    unfocused)
      ;;
    *)
      ucount=$(cat "$STATE/.focus-unknown-$key" 2>/dev/null || echo 0)
      case "$ucount" in ''|*[!0-9]*) ucount=0 ;; esac
      if [ "$ucount" -lt "$STALENESS_AUTOCLOSE_MAX_RETRIES" ]; then
        triage_log "staleness auto-close skipped for $w (task $task): pane focus unreadable ($fstate); erring toward not reaping"
        return 0
      fi
      ;;
  esac
  if [ -e "$mf" ] && [ "$(age_of "$mf")" -lt "$STALENESS_FOCUS_GRACE_SECS" ]; then
    triage_log "staleness auto-close skipped for $w (task $task): pane focused within ${STALENESS_FOCUS_GRACE_SECS}s"
    return 0
  fi
  [ "$fstate" = unfocused ] || triage_log "staleness auto-close focus unreadable ($fstate) for $w (task $task) persisted $ucount polls (bound $STALENESS_AUTOCLOSE_MAX_RETRIES) with no focus within ${STALENESS_FOCUS_GRACE_SECS}s; falling through to reap"
  return 1
}

# staleness_autoclose_should_retry: 0 (attempt now) unless this key's reclaim
# has either exhausted STALENESS_AUTOCLOSE_MAX_RETRIES consecutive failures
# (permanently, until the pane's hash next changes and resets the counters via
# staleness_autoclose_clear_retries) or is still inside the doubling backoff
# window set by the last failure.
staleness_autoclose_should_retry() {  # <key>
  local key=$1 fails next now
  fails=$(cat "$STATE/.staleness-fails-$key" 2>/dev/null || echo 0)
  case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
  [ "$fails" -lt "$STALENESS_AUTOCLOSE_MAX_RETRIES" ] || return 1
  next=$(cat "$STATE/.staleness-next-$key" 2>/dev/null || echo 0)
  case "$next" in ''|*[!0-9]*) next=0 ;; esac
  now=$(date +%s)
  [ "$now" -ge "$next" ]
}

# staleness_autoclose_record_failure: bumps this key's failure count and sets
# its next-retry time base*2^(fails-1) seconds out (capped), then echoes the
# new failure count so the caller can tell whether the retry budget is spent.
staleness_autoclose_record_failure() {  # <key>
  local key=$1 fails backoff shift_by
  fails=$(( $(cat "$STATE/.staleness-fails-$key" 2>/dev/null || echo 0) + 1 ))
  case "$fails" in ''|*[!0-9]*) fails=1 ;; esac
  echo "$fails" > "$STATE/.staleness-fails-$key"
  shift_by=$(( fails - 1 ))
  [ "$shift_by" -lt 16 ] || shift_by=16
  backoff=$(( STALENESS_AUTOCLOSE_RETRY_BASE_SECS * (1 << shift_by) ))
  [ "$backoff" -le "$STALENESS_AUTOCLOSE_RETRY_MAX_SECS" ] || backoff=$STALENESS_AUTOCLOSE_RETRY_MAX_SECS
  echo "$(( $(date +%s) + backoff ))" > "$STATE/.staleness-next-$key"
  printf '%s' "$fails"
}

staleness_autoclose_clear_retries() {  # <key>
  rm -f "$STATE/.staleness-fails-$1" "$STATE/.staleness-next-$1" \
    "$STATE/.staleness-working-$1" "$STATE/.focus-$1" "$STATE/.focus-unknown-$1"
}

# busy_turn_over_age: 0 iff <task>'s latest completed-turn marker is at least
# BUSY_TURN_MAX_SECS old. Ages the per-task turn-ended marker, the harness-neutral
# signal every verified harness's turn-end hook touches; before any turn has
# completed, ages the task's spawn record instead so a fresh task still gets a
# bound. The caller checks that the pane is busy and routes a crossed bound
# through the existing wedge_timer_check, never anything that touches the
# worker itself.
busy_turn_over_age() {  # <task>
  local task=$1 f
  f="$STATE/$task.turn-ended"
  [ -e "$f" ] || f="$STATE/$task.meta"
  [ "$(age_of "$f")" -ge "$BUSY_TURN_MAX_SECS" ]
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent captain-held transfer, and re-surface it once every
# PAUSE_RESURFACE_SECS for a recheck so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. A .paused-resurfaced-<key> throttle marker records the last
# re-surface epoch so, once past the window, it fires once per window rather than
# every poll. Advances the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age rf rf_age reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}

clear_pause_state() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  clear_pause_state "$win"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# Only a confidently dead ordinary crew may recover paused classification after
# fm-crew-state has fallen back to stopped or unknown.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$(window_kind "$win")" != secondmate ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$(window_kind "$win")" != secondmate ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  [ "$class" = none ] && [ "${agent_alive:-unknown}" = dead ] && class=paused
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(printf '%s' "$win" | tr ':/.' '___')
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if status_is_paused_or_captain_held "$last"; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

# Deliver a durably queued process-event result to firstmate. Publication is
# owned by bin/fm-procevent.sh - by the runner at capture time and by reconcile's
# re-announcement - so this decides only whether a queued check record has been
# surfaced yet, then reports it through the same actionable exit every other wake
# uses. Without it a captured result sits on the queue until something else
# happens to wake firstmate, which is exactly the missed delivery this repairs.
# Dedup uses the same .seen-* discipline as scan_signals: the durable record is
# always written before its marker, so nothing is suppressed before it is queued,
# and re-announcement, drain-time deduplication, and the handled acknowledgement
# keep their existing owners untouched.
procevent_surfaced_marker() {  # <queue-key>
  printf '%s/.seen-procevent-%s' "$STATE" "$(printf '%s' "$1" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
}

procevent_surface_after_output() {
  local output_status=$1 key marker tmp status=0
  if [ "$output_status" -eq 0 ]; then
    for key in $PROCEVENT_SURFACED; do
      marker=$(procevent_surfaced_marker "$key")
      tmp=$(umask 077; mktemp "$STATE/.seen-procevent.XXXXXX") || { status=1; continue; }
      if ! mv -f -- "$tmp" "$marker"; then
        rm -f -- "$tmp"
        status=1
      fi
    done
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

procevent_surface_queued() {
  local key reason
  PROCEVENT_SURFACED=
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  while IFS= read -r key; do
    case "$key" in procevent:*) ;; *) continue ;; esac
    [ -e "$(procevent_surfaced_marker "$key")" ] && continue
    PROCEVENT_SURFACED="$PROCEVENT_SURFACED $key"
  done < <(fm_wake_queued_keys_locked check)
  if [ -z "$PROCEVENT_SURFACED" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  reason="check: process-event result captured:$PROCEVENT_SURFACED"
  FM_WAKE_POST_OUTPUT_ACTION=procevent_surface_after_output
  wake "$reason"
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop is owned by
# fm-push-transition-lib.sh because push and poll paths must write one format.
# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# parlay_heartbeat_payload: build the heartbeat wake-queue payload including a
# compact parlay sweep summary. When parlay is absent, returns plain "heartbeat".
# Surfaces only needs-decision, blocked, and failed HOLD lines; truncates each
# to 80 chars. Read-only and safe to call at any time.
parlay_heartbeat_payload() {
  local sweep held count line summary
  command -v parlay >/dev/null 2>&1 || { printf 'heartbeat'; return 0; }
  sweep=$(parlay sweep 2>/dev/null) || sweep=
  held=$(printf '%s\n' "$sweep" | grep -E '^HOLD[[:space:]].*state=(needs-decision|blocked|failed)' || true)
  count=0
  [ -n "$held" ] && count=$(printf '%s\n' "$held" | grep -c .)
  if [ "$count" -eq 0 ]; then
    printf 'heartbeat | parlay: none held'
    return
  fi
  summary="heartbeat | parlay: ${count} agent(s) held"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "${#line}" -gt 80 ]; then
      summary="${summary} | ${line:0:80}"
    else
      summary="${summary} | ${line}"
    fi
  done <<EOF
$held
EOF
  printf '%s' "$summary"
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# Idle-task-discovery: when fleet is idle (no active windows), try to dispatch
# the next ready task from the backlog autonomously. This reduces captain context
# switches by letting the watcher pick up ready work automatically.
# Returns 0 if a task was dispatched, 1 if no ready task or fleet not idle.
discover_and_dispatch_idle_task() {
  local windows_count ready_tasks_file ready_task_id task_kind

  # Check if fleet is idle: recorded_windows output should be empty
  windows_count=$(recorded_windows | wc -l)
  if [ "$windows_count" -ne 0 ]; then
    # Fleet is not idle, skip auto-discovery
    return 1
  fi

  # Fleet is idle; check for ready tasks. Use tasks-axi ready to find unblocked tasks
  if ! command -v tasks-axi >/dev/null 2>&1; then
    # tasks-axi not available
    return 1
  fi

  # Get the first ready task ID using a temp file to parse output
  ready_tasks_file=$(mktemp "$STATE/.fm-ready-tasks.XXXXXX") || return 1
  trap 'rm -f "$ready_tasks_file"' RETURN

  tasks-axi ready > "$ready_tasks_file" 2>/dev/null || {
    return 1
  }

  # Parse task ID from first ready task. The output looks like:
  # count: 2
  # ready[2]{id,state,kind,repo,title}:
  #   test-p1-a1,queued,ship,"-",Test P1 task
  #   test-p2-a2,queued,ship,"-",Test P2 task
  # We extract the first id from the task lines (indented lines with commas)
  ready_task_id=$(awk -F',' '
    /^  [a-z0-9]/ { if (!found) { print $1; gsub(/^[[:space:]]+/, ""); print; found=1 } }
  ' "$ready_tasks_file" | head -1)

  if [ -z "$ready_task_id" ]; then
    return 1
  fi

  # Get task metadata: kind to determine how to dispatch it
  task_kind=$(awk -F',' -v task="$ready_task_id" '
    /^  [a-z0-9]/ && $1 ~ task { print $3; gsub(/^[[:space:]]+/, ""); exit }
  ' "$ready_tasks_file")

  # For secondmate tasks, use FM_HOME directly
  if [ "$task_kind" = secondmate ]; then
    if "$SCRIPT_DIR/fm-spawn.sh" "$ready_task_id" "$FM_HOME" --secondmate 2>/dev/null >/dev/null; then
      triage_log "idle-discovery: dispatched secondmate $ready_task_id (first ready when fleet idle)"
      return 0
    else
      triage_log "idle-discovery: failed to dispatch secondmate $ready_task_id"
      return 1
    fi
  fi

  # For ship/scout tasks, we need a project directory.
  # Infer from data/projects.md or check if task note contains project info.
  # For now, skip auto-dispatch of ship/scout without explicit project routing.
  # TODO: implement project-routing from task metadata or dispatch profiles
  triage_log "idle-discovery: skipping task $ready_task_id (kind=$task_kind, needs project routing)"
  return 1
}

# Dead-window triage sweep. The idle>2h staleness auto-close above reclaims a
# LIVE idle window; the stale loop below skips any window whose pane capture
# fails. Neither surfaces a kind=ship task whose window DIED on its own
# (herdr/zellij pane crashed or closed) while its worktree still holds
# committed-but-unlanded or ask-user-parked work: that orphan meta just sits with
# its work preserved but nothing durable filed for triage. This sweep gives that
# dead-window case the SAME triage filing the live-idle path has. For each
# kind=ship meta whose recorded endpoint is CONFIDENTLY dead
# (fm_backend_agent_alive == dead - an ambiguous or transiently unreadable
# endpoint stays untouched, matching the secondmate liveness sweep's discipline),
# it delegates to fm-teardown.sh --staleness-file-dead. That mode reuses
# work_is_landed and the fail-open fm-staleness-file.sh, files a staleness bead
# (or the state/<id>.staleness-unfiled fallback) ONLY for unlanded work, and
# NEVER kills anything, removes the meta, or touches the worktree, branch, or any
# uncommitted change - the never-discard-unlanded-work invariant is preserved.
# Idempotent: teardown skips a task already filed, so a repeated sweep never
# re-files. Fail-open like every other sweep here: a delegation failure is logged
# and never breaks the loop. Runs during afk too - tracking a wasted orphan
# matters most while nobody is watching - since the filing is non-destructive.
dead_window_triage_sweep() {
  local meta id kind window backend
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = ship ] || continue
    window=$(fm_backend_target_of_meta "$meta")
    [ -n "$window" ] || continue
    id=$(basename "$meta" .meta)
    backend=$(fm_backend_of_meta "$meta")
    [ "$(fm_backend_agent_alive "$backend" "$window" 2>/dev/null)" = dead ] || continue
    if ! "$FM_TEARDOWN_BIN" "$id" --staleness-file-dead >>"$STATE/.dead-window-triage.log" 2>&1; then
      triage_log "dead-window triage FAILED for task $id (see .dead-window-triage.log)"
    fi
  done
  return 0
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Before acquiring the watcher lock or enumerating any runnable check, replace
# or quarantine checks created by older versions. The migration compares bytes
# and reads data only; it never invokes legacy check files through Bash.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
watcher_cleanup() {
  fm_active_check_stop || return 1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  fm_lock_release "$WATCH_LOCK"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
FM_WATCH_DELIVERY_PID=$WATCHER_PID
FM_WATCH_DELIVERY_IDENTITY=$(fm_pid_identity "$WATCHER_PID" 2>/dev/null || true)
printf '%s\n' "$FM_WATCH_DELIVERY_IDENTITY" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"
# Anchor the dead-window triage cadence at startup so the first sweep runs one
# DEAD_WINDOW_SWEEP_INTERVAL after this watcher starts, not on the very first
# poll: a dead-window orphan is never urgent (its work is preserved regardless),
# and this keeps a freshly-armed watcher from spending its first poll enumerating
# every meta's endpoint liveness. A restart that finds a stale marker
# (>= interval old) still sweeps promptly on the next poll.
[ -e "$STATE/.last-dead-window-sweep" ] || touch "$STATE/.last-dead-window-sweep"

# A merged poll may have queued its terminal wake and then lost the process
# between receipt publication and fixed-path removal.
# Finish only identity-bound retirement receipts before any check can run.
if ! fm_pr_poll_retirement_recover_all "$STATE" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  reason="check: rejected unauthenticated PR poll retirement receipts:$FM_PR_POLL_RETIREMENT_REJECTED"
  fm_wake_append check pr-poll-retirement "$reason" || exit 1
  touch "$STATE/.last-check"
  wake "$reason"
fi

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true

  # Process-to-event liveness repair. This never discovers a result by polling:
  # each registered source has its own child blocking on that source, and this
  # only republishes results already captured durably and restarts a source
  # whose owner is gone. It is a no-op with nothing registered.
  if [ -d "$STATE/procevent" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
  fi
  # Then deliver any queued-but-unsurfaced result, including one a runner
  # published while this watcher was between cycles.
  procevent_surface_queued

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      is_pr_poll=0
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          is_pr_poll=1
          provider=$FM_PR_POLL_SNAPSHOT_PROVIDER
          url=$FM_PR_POLL_SNAPSHOT_URL
          host=$FM_PR_POLL_SNAPSHOT_HOST
          path=$FM_PR_POLL_SNAPSHOT_PATH
          number=$FM_PR_POLL_SNAPSHOT_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" "$STATE/$id.pr-review-seen" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        if [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
          if fm_pr_poll_retirement_publish "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" "$out"; then
            fm_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
              || triage_log "merged PR poll retirement remains recoverable for $id"
          else
            triage_log "merged PR poll retirement deferred because its canonical snapshot changed for $id"
          fi
        fi
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=${w//:/_}
    key=${key//\//_}
    key=${key//./_}
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$w"
    fi
    if [ "$kind" = secondmate ] && ! status_is_paused "$last"; then
      continue
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    pwf="$STATE/.staleness-working-$key"   # cache: hash last found provably-working by auto-close
    prev=$(cat "$hf" 2>/dev/null || true)
    # Busy match: a backend's native semantic state when available (herdr), else
    # the last 6 non-blank lines only (the TUI footer area, where every verified
    # harness renders its busy indicator) so busy-looking strings in displayed
    # content cannot suppress stale detection. Read once per window per poll and
    # reused below so a busy verdict is consistent within one cycle.
    if window_is_busy "$w" "$tail40"; then busy_now=0; else busy_now=1; fi
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && [ "$busy_now" -ne 0 ]; then
        # Idle>2h staleness auto-close backstop, ahead of ordinary
        # classification below: an ordinary ship task, not declared paused or
        # captain-held (that wait is deliberate and may legitimately run much
        # longer than two hours), not parked at a captain-relevant gate (a
        # needs-decision/blocked/done/failed status means the crew is waiting
        # on the captain, not idling wastefully - the stale_is_terminal path
        # below exists to surface that, not have it silently reclaimed out
        # from under a pending decision), not provably working (a no-mistakes
        # validation legitimately sits on a static pane for its whole run per
        # AGENTS.md's sparse status-reporting contract - the same predicate
        # the terminal-stale path below trusts to avoid the 2026-07 herdr
        # false-surface incident), and not already out of retry budget for
        # this stale hash. Runs during afk too - reclaiming wasted idle
        # compute matters most while away - with a successful reclaim logged
        # for the returning captain by staleness_autoclose_reclaim itself. See
        # staleness_autoclose_reclaim above. crew_is_provably_working is only
        # invoked on the first poll of a given stale hash (cached in $pwf),
        # matching the first-sighting-only contract every other caller in this
        # file follows - not re-run on every ~15s poll for the whole time a
        # provably-working task sits past the threshold.
        if [ "$kind" = ship ] \
          && ! status_is_paused_or_captain_held "$last" \
          && ! status_is_captain_relevant "$last"; then
          # This is an ordinary idling ship pane: the reap-candidate set. Stamp
          # its live human-focus on every poll while it idles (herdr only; a
          # no-op that reports "na" on focus-unaware backends) so the recency
          # window in staleness_focus_guard_blocks_reap has a faithful
          # time-since-last-focus the instant the pane crosses the threshold.
          # herdr exposes no queryable focus history, only the current boolean,
          # so we reconstruct recency from the poll we already run here rather
          # than adding a second loop. The guard below consumes this same read.
          focus_state=$(staleness_focus_stamp "$w" "$key")
          if [ "$(age_of "$hf")" -ge "$STALENESS_AUTOCLOSE_SECS" ] \
            && staleness_autoclose_should_retry "$key"; then
            if [ "$(cat "$pwf" 2>/dev/null || true)" != "$h" ]; then
              if crew_is_provably_working "$task"; then
                printf '%s' "$h" > "$pwf"
              else
                rm -f "$pwf"
              fi
            fi
            if [ "$(cat "$pwf" 2>/dev/null || true)" != "$h" ]; then
              # Human-conversation guard: never reclaim a pane the captain is (or
              # just was) actively viewing - an idle pane in live human review
              # shows the same zero churn as a finished crew. No-op on
              # focus-unaware backends; errs toward NOT reaping on an unreadable
              # focus, but only until STALENESS_AUTOCLOSE_MAX_RETRIES consecutive
              # unknown polls, after which the unreadable pane honors the same
              # within-grace recency check as an unfocused one so a dead/unreadable
              # pane with no fresh focus marker falls through to reap while a pane
              # focused within the grace window stays blocked even at the bound.
              # Not a failure, so it never touches the retry budget - the
              # pane is simply reconsidered next cadence.
              if staleness_focus_guard_blocks_reap "$w" "$task" "$key" "$focus_state"; then
                continue
              fi
              if staleness_autoclose_reclaim "$w" "$task" "$hf"; then
                staleness_autoclose_clear_retries "$key"
                continue
              fi
              if [ "$(staleness_autoclose_record_failure "$key")" -lt "$STALENESS_AUTOCLOSE_MAX_RETRIES" ]; then
                continue
              fi
              triage_log "staleness auto-close exhausted retries for $w (task $task); falling through to ordinary stale surfacing"
            fi
          fi
        fi
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$w" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crew declared an external wait, or a declared pause or
          #     captain hold is paired with a confidently dead agent, so absorb on
          #     the long PAUSE_RESURFACE_SECS cadence instead of wedge-escalating;
          #   - none: no running pipeline, no exact busy verdict, no declared pause.
          #     Surface immediately so firstmate inspects the inconclusive state
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping,
        # unless a genuinely busy pane has gone too long with no completed turn -
        # then route it through the same wedge timer instead of erasing it.
        if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
          wedge_timer_check "$w" "$ssf" "busy (no completed turn)" "$ewf"
        else
          rm -f "$ssf" "$ewf"
        fi
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      staleness_autoclose_clear_retries "$key"
      if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
        wedge_timer_check "$w" "$ssf" "busy (no completed turn)" "$ewf"
      else
        rm -f "$ssf" "$ewf"
      fi
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" && [ "$busy_now" -ne 0 ]; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$w" ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat "$(parlay_heartbeat_payload)" || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat "$(parlay_heartbeat_payload)" || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Idle-task-discovery: when fleet is idle, try to autonomously dispatch ready tasks.
  # Throttle to every IDLE_DISCOVERY_INTERVAL seconds to avoid constant polling.
  if [ "$(age_of "$STATE/.last-idle-discovery")" -ge "$IDLE_DISCOVERY_INTERVAL" ]; then
    touch "$STATE/.last-idle-discovery"
    discover_and_dispatch_idle_task || true
  fi

  # Dead-window triage sweep: file a durable triage record for a kind=ship task
  # whose window died on its own while holding unlanded work (see
  # dead_window_triage_sweep). Throttled like idle-discovery so a large fleet's
  # metas are not re-scanned every poll; non-destructive and idempotent.
  if [ "$(age_of "$STATE/.last-dead-window-sweep")" -ge "$DEAD_WINDOW_SWEEP_INTERVAL" ]; then
    touch "$STATE/.last-dead-window-sweep"
    dead_window_triage_sweep || true
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
