#!/usr/bin/env bash
# fm-firstturn-lib.sh - the ONE owner of firstmate's first-turn verification
# contract: did a freshly launched agent actually START its first turn, or did
# the launch prompt silently fail to land?
#
# Why this exists: fm-spawn.sh delivers a launch prompt by typing it into a
# fresh shell pane and then reported success unconditionally. Under high machine
# load that typed line can race with the shell's own echo and be lost, leaving
# an agent parked at an empty composer having consumed nothing while the spawn
# reported success. This library supplies the missing proof, and fm-spawn.sh
# owns what it does with the verdict (see its header's first-turn watchdog
# section).
#
# Detection basis - no new vendor signal is invented here. bin/fm-busy-lib.sh
# already owns a semantic busy-state record, and bin/fm-busy-event.sh's `arm`
# seeds exactly one launch-time record:
#
#   v1 gen=<token> seq=1 state=busy source=fm-spawn event=launch-brief ts=<epoch>
#
# That seed is an ASSUMPTION about a prompt that has not been observed yet. Each
# converted adapter's own turn-lifecycle writer replaces it the moment the agent
# genuinely submits or completes a turn, advancing seq and changing source to
# that adapter's token. So the record's source answers the question exactly:
#
#   source is the harness's OWN adapter token  -> the agent was observed in a
#                                                 turn:            FIRED
#   source is still fm-spawn at seq=1          -> nothing has ever been
#                                                 observed:        NOT-FIRED
#   anything else                              -> proves nothing:  UNPROVEN
#
# The seed-then-adapter transition is live-verified for every adapter this
# library can prove, against firstmate-launched workers wired exactly as
# fm-spawn writes them (docs/verification/supervision.md "semantic sources"):
# Claude's UserPromptSubmit fired for the argv launch prompt, Pi went seed ->
# pi-ext agent-start, and OpenCode went seed -> opencode-plugin session-busy.
# That evidence is what makes NOT-FIRED trustworthy enough to act on.
#
# The firstmate-owned sources (fm-spawn, fm-interrupt, fm-recovery) are
# deliberately NOT proof: they record firstmate's own actions, not an observed
# agent turn. A record carrying one of those is unproven, never fired.
#
# Coverage is a property of the HARNESS, not the runtime backend, because the
# evidence is a semantic record rather than anything read off a rendered pane.
# Every backend is therefore covered identically for a provable harness. The
# harnesses with no semantic turn source - codex, grok, kimi, muse, and any
# unverified adapter - and secondmate spawns, which fm-spawn deliberately leaves
# unarmed, all report UNPROVEN with a named reason. They are never given a
# fabricated verdict and never resubmitted into.
#
# Sourcing: set -u and set -e safe. Requires bin/fm-busy-lib.sh to be sourced
# first, or sourced from the same directory.

if [ -z "${FM_BUSY_LIB_VERSION:-}" ]; then
  # shellcheck source=bin/fm-busy-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-busy-lib.sh"
fi

# shellcheck disable=SC2034 # Public source-library variable used by callers.
FM_FIRSTTURN_LIB_VERSION=v1

# The firstmate-owned busy sources. fm_busy_sources_for_harness appends exactly
# these to every converted adapter's own token; none of them is evidence that an
# agent turn was observed, so first-turn proof subtracts them.
FM_FIRSTTURN_NON_EVIDENCE_SOURCES='fm-spawn fm-interrupt fm-recovery'

# fm_firstturn_adapter_sources: the sources that DO prove <harness> was observed
# in a turn - its trusted busy sources minus the firstmate-owned ones. One line,
# space-separated, empty when the harness has no semantic turn source at all.
# Derived from fm-busy-lib.sh's table rather than restated, so opening a gated
# adapter there (codex, kimi) extends first-turn proof in the same change.
fm_firstturn_adapter_sources() {  # <harness>
  local src out='' s
  src=$(fm_busy_sources_for_harness "${1:-}")
  for s in $src; do
    case " $FM_FIRSTTURN_NON_EVIDENCE_SOURCES " in
      *" $s "*) continue ;;
    esac
    if [ -z "$out" ]; then out=$s; else out="$out $s"; fi
  done
  printf '%s' "$out"
}

# fm_firstturn_provable: 0 when <harness> has at least one semantic source that
# could ever prove a first turn. Callers use this to skip the wait entirely
# rather than burning the poll budget on a verdict that can never arrive.
fm_firstturn_provable() {  # <harness>
  [ -n "$(fm_firstturn_adapter_sources "${1:-}")" ]
}

# fm_firstturn_observe: one non-blocking read of the task's current first-turn
# evidence. Prints "<verdict> <detail>" and always exits 0 - the verdict is the
# result, not the exit status.
#
#   fired <source>          an adapter observed the agent in a turn
#   not-fired seed          the launch-time seed is still untouched at seq=1
#   unproven <reason>       nothing can be concluded; reason is one of
#                           no-semantic-source, missing, malformed,
#                           gen-mismatch, firstmate-source, foreign-source,
#                           unexpected-seq
fm_firstturn_observe() {  # <state-dir> <id> <harness>
  local state=${1:-} id=${2:-} harness=${3:-} adapter_sources record
  local r_state r_source r_event r_seq

  adapter_sources=$(fm_firstturn_adapter_sources "$harness")
  if [ -z "$adapter_sources" ]; then
    printf 'unproven no-semantic-source'
    return 0
  fi

  # fm_busy_record_read prints "<state> <source> <event> <seq>" on success and
  # one of missing/malformed/gen-mismatch on failure. Reuse it rather than
  # re-parsing the record: bin/fm-busy-lib.sh owns that format.
  if ! record=$(fm_busy_record_read "$state" "$id"); then
    case "$record" in
      missing|malformed|gen-mismatch) printf 'unproven %s' "$record" ;;
      *) printf 'unproven malformed' ;;
    esac
    return 0
  fi
  # shellcheck disable=SC2034 # r_state and r_event are read for completeness of the record shape.
  read -r r_state r_source r_event r_seq <<EOF
$record
EOF

  case " $adapter_sources " in
    *" $r_source "*) printf 'fired %s' "$r_source"; return 0 ;;
  esac

  # Still firstmate-owned. Only the untouched launch seed proves that nothing
  # has been observed; a later firstmate-written record (an interrupt or a
  # recovery reset) has overwritten whatever the adapter may have reported and
  # can no longer rule a first turn in or out.
  if [ "$r_source" = fm-spawn ]; then
    if [ "$r_seq" = 1 ]; then
      printf 'not-fired seed'
    else
      printf 'unproven unexpected-seq'
    fi
    return 0
  fi
  case " $FM_FIRSTTURN_NON_EVIDENCE_SOURCES " in
    *" $r_source "*) printf 'unproven firstmate-source' ;;
    *)               printf 'unproven foreign-source' ;;
  esac
}

# fm_firstturn_wait: poll fm_firstturn_observe until it proves a turn fired or
# the budget runs out. Prints the same "<verdict> <detail>" and always exits 0.
# Returns the instant a turn is proven, so a healthy launch costs one read. A
# harness that can never be proven returns immediately rather than sleeping out
# the whole budget.
fm_firstturn_wait() {  # <state-dir> <id> <harness> <polls> <interval>
  local state=${1:-} id=${2:-} harness=${3:-} max=${4:-120} interval=${5:-0.5}
  local i=0 verdict last

  case "$max" in ''|*[!0-9]*) max=120 ;; esac
  [ "$max" -ge 1 ] || max=1

  last=$(fm_firstturn_observe "$state" "$id" "$harness")
  case "$last" in
    fired*|'unproven no-semantic-source') printf '%s' "$last"; return 0 ;;
  esac

  while [ "$i" -lt "$max" ]; do
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
    verdict=$(fm_firstturn_observe "$state" "$id" "$harness")
    last=$verdict
    case "$verdict" in
      fired*) break ;;
    esac
  done
  printf '%s' "$last"
}

# fm_firstturn_log: append one durable outcome record to the home-wide
# first-turn log. Append-only, never read back as authority - it exists so a
# launch that quietly failed to land leaves an actionable record instead of a
# clean success report. Best-effort by design: an unwritable state dir must
# never fail a spawn that otherwise succeeded.
fm_firstturn_log() {  # <state-dir> <id> <harness> <backend> <outcome> <detail>
  local state=${1:-} id=${2:-} harness=${3:-} backend=${4:-}
  local outcome=${5:-} detail=${6:-} ts
  [ -n "$state" ] || return 0
  ts=$(date +%s 2>/dev/null) || ts=0
  # 2>/dev/null must precede the append: redirections are set up left to right,
  # so a trailing one cannot silence the shell's own report of the append
  # failing. An unwritable state dir must stay completely quiet.
  printf '%s id=%s harness=%s backend=%s outcome=%s detail=%s\n' \
    "$ts" "$id" "$harness" "$backend" "$outcome" "$detail" \
    2>/dev/null >> "$state/.firstturn.log" || true
  return 0
}
