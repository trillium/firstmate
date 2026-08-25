#!/usr/bin/env bash
# fm-claim-prompt-lib.sh - the ONE owner of firstmate's optional Parlay claim
# prompt: a default-OFF launch-prompt shape that hands a bead-linked agent a
# short `parlay claim <bead>` command instead of its whole encoded brief.
#
# Why this exists: `parlay claim <task-id>` is a one-call agent bootstrap that
# resolves the ticket, enrols the agent in Parlay's chat panel, and prints the
# ticket's own title and description as the work. Parlay's own design note for
# it says the point is that "the spawn prompt shrinks to 'run parlay claim
# <task-id> and follow its output'". Where firstmate has already linked a task
# to a bead (beads_id= in state/<id>.meta) that shape is available to us too.
#
# What it is NOT: a second spawner. fm-spawn.sh keeps every one of its own
# guarantees - the isolated-worktree assertion, the secondmate registry-binding
# authorization, FM_HOME inheritance, state/<id>.meta publication, --relaunch
# metadata inheritance, remote-secondmate readiness gating. The ONLY thing this
# library changes is which file fm-spawn.sh feeds to the launch prompt's
# `fm-operational-input.sh encode launch-brief < <file>` substitution. The
# operational-input encoding contract is untouched, every harness template is
# untouched, and no launch flag moves.
#
# The brief always stays authoritative. The claim prompt this library writes
# NAMES the task's real brief and tells the agent the brief wins, so a claim
# that fails at the agent's end still lands on the full contract - the worktree
# isolation assertion, the delivery mode's definition of done, the status
# protocol. A short prompt must never be a way to lose a safety contract.
#
# Default OFF, and off is not a second code path: when any degrade condition
# holds, fm-spawn.sh feeds the real brief exactly as it always has, so the
# launch is byte-identical to the behaviour with this library absent.
#
# Sourcing: set -u and set -e safe. fm_claim_prompt_decide's reachability probe
# needs fm-timeout-lib.sh's fm_run_timed to already be sourced; without it the
# probe is skipped and the decision degrades rather than running unbounded.

# shellcheck disable=SC2034 # Public source-library variable used by callers.
FM_CLAIM_PROMPT_LIB_VERSION=v1

# The probe. `parlay subscribers` is one plain GET against the relay: it is the
# cheapest call that actually proves the server answered (measured ~0.6s live,
# against ~3.5s for `parlay health`, which also probes a separate pulse service
# firstmate does not care about here).
FM_CLAIM_PROMPT_PROBE_ARGS='subscribers'

# fm_claim_prompt_enabled: 0 only when <config-dir>/spawn-claim-prompt reads
# exactly "on". Absent, empty, or anything else is off - the flag has to be
# turned on deliberately, and an unreadable or garbled file can never enable it.
fm_claim_prompt_enabled() {  # <config-dir>
  local config_dir=${1:-} value
  [ -n "$config_dir" ] || return 1
  [ -f "$config_dir/spawn-claim-prompt" ] || return 1
  value=$(tr -d '[:space:]' < "$config_dir/spawn-claim-prompt" 2>/dev/null || true)
  [ "$value" = on ]
}

# fm_claim_prompt_decide: the whole gate in one place. Prints "use" or
# "off <reason>" and always exits 0 - the decision is the result, not the exit
# status. Reasons: disabled, secondmate, no-bead, no-parlay, unreachable.
#
# Every reason degrades to exactly the same thing (fm-spawn feeds the real
# brief), so the reasons exist to make a degraded launch explainable, not to
# branch behaviour. The order is deliberate: the cheapest and most certain
# reasons are settled before anything reaches out to the network.
fm_claim_prompt_decide() {  # <config-dir> <kind> <beads-id> [<probe-seconds>]
  local config_dir=${1:-} kind=${2:-} beads=${3:-} secs=${4:-10}

  fm_claim_prompt_enabled "$config_dir" || { printf 'off disabled'; return 0; }
  # A secondmate is an operational entity with a charter, not a backlog work
  # item - the same reason fm-spawn.sh's beads auto-link skips it. Its charter
  # is the thing being delivered, so it is never replaced by a claim command
  # even if a bead were forced onto it.
  [ "$kind" != secondmate ] || { printf 'off secondmate'; return 0; }
  [ -n "$beads" ] || { printf 'off no-bead'; return 0; }
  command -v parlay >/dev/null 2>&1 || { printf 'off no-parlay'; return 0; }

  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ "$secs" -ge 1 ] || secs=1

  # An unbounded probe would make an optional convenience able to hang a spawn,
  # which is the one thing Parlay must never do here. No bounded runner means no
  # probe: degrade instead of risking it.
  command -v fm_run_timed >/dev/null 2>&1 || { printf 'off unreachable'; return 0; }
  # shellcheck disable=SC2086 # FM_CLAIM_PROMPT_PROBE_ARGS is a deliberate word-split argument list.
  fm_run_timed "$secs" parlay $FM_CLAIM_PROMPT_PROBE_ARGS >/dev/null 2>&1 \
    || { printf 'off unreachable'; return 0; }

  printf 'use'
}

# fm_claim_prompt_write: write the claim prompt to <path>. Returns non-zero if
# it cannot be written, so the caller degrades to the real brief rather than
# launching an agent against a prompt file that is missing or half-written.
#
# The text is deliberately three short parts: the claim command, the brief
# pointer, and the precedence rule that keeps the brief authoritative when the
# claim fails.
#
# The claim carries two flags, and both exist to keep it from colliding with
# what fm-spawn.sh already does:
#
#   --agent <task-id>  fm-spawn already enrols the new agent in Parlay's chat
#                      panel as its FIRSTMATE task id, and records that pid for
#                      teardown to stop. Left to itself, claim would derive a
#                      profile from the ticket instead and the one agent would
#                      hold two Parlay identities. Pinning the id keeps one.
#   --silent           claim otherwise prints a `parlay listen` Monitor command
#                      for the agent to arm - Parlay's own note calls a printed
#                      Monitor call "an instruction something may act on". The
#                      listen loop is already running and already owned by
#                      teardown, so arming a second one would leak a poll loop
#                      teardown cannot kill. Registration and the announce still
#                      happen; only the arm-command is dropped.
fm_claim_prompt_write() {  # <path> <beads-id> <brief-abs-path> <task-id>
  local path=${1:-} beads=${2:-} brief=${3:-} task=${4:-} tmp
  [ -n "$path" ] && [ -n "$beads" ] && [ -n "$brief" ] && [ -n "$task" ] || return 1
  tmp="$path.tmp.$$"
  {
    printf 'Run this first: parlay claim %s --agent %s --silent\n' "$beads" "$task"
    printf '\n'
    printf 'Then read your brief at %s and follow it exactly.\n' "$brief"
    printf '\n'
    printf 'The brief is authoritative. If the claim command is unavailable or fails, skip it and follow the brief.\n'
    # 2>/dev/null must precede the write: redirections are set up left to
    # right, so a trailing one cannot silence the shell's own report of failing
    # to OPEN the file. A spawn that degrades has nothing to say about it.
  } 2>/dev/null > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}
