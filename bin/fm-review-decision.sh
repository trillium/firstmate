#!/usr/bin/env bash
# fm-review-decision.sh - record a captain's decision on a review-store item and
# route it to firstmate's attention. This is the firstmate-side half of the
# interactive review decision loop; the captain-facing half is the Pulse endpoint
# POST /api/review/decision (PAI/PULSE/pulse.ts), which validates the id and then
# shells here.
#
# THE LOOP (contract, end to end):
#   1. Captain clicks Approve/Decline/Comment on /review/<id>/ (an interactive
#      decision page rendered by bin/fm-review-page.ts).
#   2. The page POSTs {id, verdict, comment?} same-origin to /api/review/decision.
#   3. The Pulse endpoint validates the id exists (via `review show`) and, on a
#      valid id, invokes THIS script (resolving firstmate's home via FM_HOME).
#   4. THIS script does three durable things, in order, and FAILS LOUDLY if any
#      of the first two cannot be delivered - never a silent ok (robots-5l8):
#        a. appends a `check`-kind wake to firstmate's durable wake queue
#           (state/.wake-queue) via the sanctioned fm_wake_append helper, keyed
#           `review-decision:<id>`, so fm-wake-drain.sh surfaces it on the next
#           supervision cycle as an actionable `check:` wake;
#        b. annotates the review item itself (`review note <id> "Captain
#           decision: <verdict> - <comment> @ <ts>"`) so the decision is visible
#           in `review show <id>` / `review ready`;
#        c. appends a JSONL audit record to the durable decisions log
#           (~/pulse-pages/review/.decisions.jsonl by default) as the trail.
#   5. firstmate drains the wake, reads the decision, and acts on it.
#
# FAIL-LOUD POLICY. The wake enqueue and the store annotation are load-bearing:
# if either fails, this script exits non-zero with a diagnostic on stderr so the
# endpoint returns a non-2xx and the captain sees a real error rather than a
# false success. The audit-log append is best-effort last (the decision is
# already durably enqueued and annotated by then); a log failure is reported on
# stderr but does not fail the command, because losing the human-readable trail
# is strictly less bad than double-reporting a decision that already landed.
#
# VERDICTS. approve | decline | comment. `comment` requires non-empty text; the
# other two accept an optional comment. Any other verdict is rejected (exit 2).
#
# ENV OVERRIDES (all optional):
#   FM_HOME                    firstmate home (selects state/.wake-queue root)
#   FM_REVIEW_BIN              review CLI path        (default `review` on PATH)
#   FM_REVIEW_DECISIONS_LOG    audit JSONL path       (default ~/pulse-pages/review/.decisions.jsonl)
#   FM_REVIEW_DECISION_ACTOR   audit actor for the note (default "captain")
#
# USAGE:
#   fm-review-decision.sh <id> <approve|decline|comment> [comment text...]
#   echo "<comment>" | fm-review-decision.sh <id> comment --stdin
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

REVIEW_BIN="${FM_REVIEW_BIN:-review}"
DECISION_ACTOR="${FM_REVIEW_DECISION_ACTOR:-captain}"
# fm-wake-lib.sh pins HOME-independent STATE via FM_HOME; the audit log defaults
# under the real HOME's pulse-pages so it sits beside the served review pages.
DECISIONS_LOG="${FM_REVIEW_DECISIONS_LOG:-$HOME/pulse-pages/review/.decisions.jsonl}"

die() { printf 'fm-review-decision: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: fm-review-decision.sh <id> <approve|decline|comment> [comment...]
       echo "<comment>" | fm-review-decision.sh <id> comment --stdin
EOF
}

# --- parse args --------------------------------------------------------------
ID="${1:-}"
VERDICT="${2:-}"
if [ -z "$ID" ] || [ -z "$VERDICT" ]; then
  usage
  exit 2
fi
shift 2 || true

# Remaining args are the comment; support --stdin for piped comment bodies.
COMMENT=""
if [ "${1:-}" = "--stdin" ]; then
  COMMENT="$(cat)"
else
  COMMENT="$*"
fi

case "$VERDICT" in
  approve|decline|comment) ;;
  *) printf 'fm-review-decision: invalid verdict: %s (want approve|decline|comment)\n' "$VERDICT" >&2; exit 2 ;;
esac

# A bare `comment` verdict with no text is meaningless - reject it loudly rather
# than enqueue an empty comment.
if [ "$VERDICT" = comment ] && [ -z "${COMMENT//[[:space:]]/}" ]; then
  die "comment verdict requires non-empty comment text"
fi

# --- JSON string escaper for the audit record --------------------------------
# Escape a string for embedding as a JSON value (quotes, backslashes, control
# chars). Kept dependency-free; correctness over cleverness.
json_escape() {
  local s=$1 out=""
  local i ch
  for (( i = 0; i < ${#s}; i++ )); do
    ch="${s:i:1}"
    case "$ch" in
      '"')  out+='\"' ;;
      '\')  out+='\\' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *) out+="$ch" ;;
    esac
  done
  printf '%s' "$out"
}

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# (a) DURABLE WAKE - load-bearing, fail loud on any failure.
# The payload is a compact, human-readable line firstmate reads directly off the
# drained wake: verdict first, then the comment if present.
# ---------------------------------------------------------------------------
WAKE_PAYLOAD="captain decided ${VERDICT} on ${ID}"
if [ -n "${COMMENT//[[:space:]]/}" ]; then
  WAKE_PAYLOAD="${WAKE_PAYLOAD} - ${COMMENT}"
fi
if ! fm_wake_append check "review-decision:${ID}" "$WAKE_PAYLOAD"; then
  die "failed to enqueue wake for ${ID} (queue: ${FM_WAKE_QUEUE})"
fi

# ---------------------------------------------------------------------------
# (b) STORE ANNOTATION - load-bearing, fail loud. Makes the decision visible in
# `review show <id>` so the item carries its own decision trail.
# ---------------------------------------------------------------------------
NOTE="Captain decision: ${VERDICT}"
if [ -n "${COMMENT//[[:space:]]/}" ]; then
  NOTE="${NOTE} - ${COMMENT}"
fi
NOTE="${NOTE} @ ${TS}"
NOTE_ERR="$(mktemp "${TMPDIR:-/tmp}/fm-review-decision-note.XXXXXX")"
if ! BEADS_ACTOR="$DECISION_ACTOR" "$REVIEW_BIN" note "$ID" "$NOTE" >/dev/null 2>"$NOTE_ERR"; then
  err="$(cat "$NOTE_ERR" 2>/dev/null || true)"; rm -f "$NOTE_ERR"
  die "failed to annotate review item ${ID}: ${err}"
fi
rm -f "$NOTE_ERR"

# ---------------------------------------------------------------------------
# (c) AUDIT LOG - best-effort last. The decision is already durably enqueued and
# annotated; a log write failure is reported but does not fail the command.
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$DECISIONS_LOG")" 2>/dev/null || true
AUDIT_LINE="$(printf '{"ts":"%s","id":"%s","verdict":"%s","comment":"%s","actor":"%s"}' \
  "$TS" \
  "$(json_escape "$ID")" \
  "$(json_escape "$VERDICT")" \
  "$(json_escape "$COMMENT")" \
  "$(json_escape "$DECISION_ACTOR")")"
if ! printf '%s\n' "$AUDIT_LINE" >> "$DECISIONS_LOG" 2>/dev/null; then
  printf 'fm-review-decision: WARNING: audit-log append failed (%s); decision already enqueued + annotated\n' "$DECISIONS_LOG" >&2
fi

# Success line for the endpoint to relay.
printf 'recorded: %s decided on %s @ %s\n' "$VERDICT" "$ID" "$TS"
