#!/usr/bin/env bash
# Wake-drain memo: a growing durable log mapping each drained wake to the action
# taken on it, so repeated wakes become lookups instead of fresh investigations.
#
# Record format (state/.wake-memo, one TAB-separated line per entry):
#   ts \t kind \t key \t payload-hash \t outcome \t note
# A wake's stable identity is kind + key + payload-hash. The hash (never the raw
# payload text, which can carry sensitive content) is a tiered content digest
# (sha1sum, shasum, md5sum, cksum, then an od fallback), so no payload bytes ever
# land in the memo. The note field is handler prose only and must never carry
# payload text either. Outcomes: pending, absorbed-benign, reconciled-idle,
# steered, interrupted, relaunched, escalated, failed.
#
# Two-phase writes. The drain path (bin/fm-wake-drain.sh) emits the identity with
# outcome pending once per drained wake; the handler appends the outcome once it
# is known (via `record`, or the watcher triage directly for its own absorbs).
# A wake with no outcome yet is pending, never assumed absorbed: consult misses
# on pending, on unknown identities, and on identities whose latest outcome is a
# handler-side result (steered, interrupted, relaunched, escalated, failed). Only
# a latest outcome of absorbed-benign or reconciled-idle consults as a hit, so a
# wake that previously needed steering or escalation always flows as new.
#
# Consult step. The stale/heartbeat triage in bin/fm-watch.sh consults the memo
# before absorbing: a hit absorbs with a memo citation (outcome plus timestamp,
# never payload text) instead of a fresh investigation, while a miss - genuinely
# new, pending, or previously actioned - behaves exactly as before. The watcher
# records its own absorbs (absorbed-benign for provably-working and no-change
# absorbs, reconciled-idle for declared-pause absorbs); every other outcome is
# recorded by the handling turn through this script's CLI.
#
# Growth bound and pruning. FM_WAKE_MEMO_MAX_LINES (default 1000) caps the file
# and FM_WAKE_MEMO_KEEP_SECS (default 7 days) defines recent. Pruning runs after
# every record that crosses the cap and only ever deletes old superseded outcome
# entries: every recent entry, every identity's latest entry (so consult stays
# correct), and every still-unabsorbed pending entry is always kept. The cap is
# therefore spent on old superseded entries first, newest kept; when the
# protected set alone already exceeds the cap the file transiently stays above it
# and converges as entries age out of the recent window.
#
# Concurrency. All reads and writes hold state/.wake-memo.lock through the shared
# lock helpers, so a drain, a watcher triage, and a handler turn can never
# interleave a prune rewrite with an append. Every caller treats the memo as
# best-effort: a memo failure must never change a drain, triage, or handling
# verdict, so call sites append `|| true` and keep flowing as if the memo missed.
#
# Usage:
#   fm-wake-memo.sh record <kind> <key> <payload> <outcome> [note]
#   fm-wake-memo.sh consult <kind> <key> <payload>
#   fm-wake-memo.sh prune
#   fm-wake-memo.sh --help
# consult prints `memo: <outcome> <ts> (<kind> <key>)` and exits 0 on a hit,
# exits 1 on a miss (genuinely new, pending, or previously actioned), and exits
# 2 on invalid arguments. record exits 2 on an invalid kind or outcome.
set -u

FM_WAKE_MEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_WAKE_MEMO_DIR/fm-wake-lib.sh"

FM_WAKE_MEMO_FILE="${FM_WAKE_MEMO_FILE:-$STATE/.wake-memo}"
FM_WAKE_MEMO_LOCK="${FM_WAKE_MEMO_LOCK:-$STATE/.wake-memo.lock}"
FM_WAKE_MEMO_MAX_LINES="${FM_WAKE_MEMO_MAX_LINES:-1000}"
FM_WAKE_MEMO_KEEP_SECS="${FM_WAKE_MEMO_KEEP_SECS:-604800}"

# fm_memo_valid_kind <kind>: the wake kinds the durable queue itself accepts.
fm_memo_valid_kind() {
  case "$1" in
    signal|stale|check|heartbeat) return 0 ;;
  esac
  return 1
}

# fm_memo_valid_outcome <outcome>: pending plus every handling result in the
# brief's outcome vocabulary.
fm_memo_valid_outcome() {
  case "$1" in
    pending|absorbed-benign|reconciled-idle|steered|interrupted|relaunched|escalated|failed) return 0 ;;
  esac
  return 1
}

# fm_memo_consultable <outcome>: only these past results shortcut a new wake.
fm_memo_consultable() {
  case "$1" in
    absorbed-benign|reconciled-idle) return 0 ;;
  esac
  return 1
}

# fm_memo_hash: tiered content digest of stdin, printed as "<algo>:<digest>".
# Mirrors the degrade-don't-fail philosophy of the watcher's pane hash: any tool
# that stably digests bytes is interchangeable for identity purposes, and the
# algo prefix keeps the identity stable even if the available tool changes.
fm_memo_hash() {
  local digest
  if command -v sha1sum >/dev/null 2>&1; then
    digest=$(sha1sum | cut -d' ' -f1) && [ -n "$digest" ] && { printf 'sha1:%s\n' "$digest"; return 0; }
  fi
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 1 | cut -d' ' -f1) && [ -n "$digest" ] && { printf 'sha1:%s\n' "$digest"; return 0; }
  fi
  if command -v md5sum >/dev/null 2>&1; then
    digest=$(md5sum | cut -d' ' -f1) && [ -n "$digest" ] && { printf 'md5:%s\n' "$digest"; return 0; }
  fi
  if command -v cksum >/dev/null 2>&1; then
    digest=$(cksum | awk '{ print $1 "-" $2 }') && [ -n "$digest" ] && { printf 'cksum:%s\n' "$digest"; return 0; }
  fi
  digest=$(od -An -tx1 -v | tr -d '[:space:]') && [ -n "$digest" ] && { printf 'od:%s\n' "$digest"; return 0; }
  return 1
}

# fm_memo_clean <text> <max-chars>: strip tabs/newlines (never raw multiline
# content in a TSV field) and cap the length.
fm_memo_clean() {
  local text=$1 max=$2
  text=$(printf '%s' "$text" | fm_wake_clean_field)
  printf '%s\n' "${text:0:$max}"
}

# fm_memo_prune_locked: enforce the growth bound; caller holds the memo lock.
fm_memo_prune_locked() {
  local lines now keep_from tmp
  [ -f "$FM_WAKE_MEMO_FILE" ] || return 0
  lines=$(awk 'END { print NR + 0 }' "$FM_WAKE_MEMO_FILE" 2>/dev/null || echo 0)
  case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
  [ "$lines" -gt "$FM_WAKE_MEMO_MAX_LINES" ] || return 0
  now=$(date +%s)
  keep_from=$((now - FM_WAKE_MEMO_KEEP_SECS))
  tmp="$FM_WAKE_MEMO_FILE.prune.$(fm_current_pid)"
  awk -F '\t' -v keep_from="$keep_from" -v max="$FM_WAKE_MEMO_MAX_LINES" '
    NF >= 5 {
      id = $2 SUBSEP $3 SUBSEP $4
      latest_nr[id] = NR
      line[NR] = $0
      idof[NR] = id
      ts[NR] = ($1 ~ /^[0-9]+$/ ? $1 : 0)
    }
    END {
      prot = 0
      u = 0
      for (n = 1; n <= NR; n++) {
        if (!(n in line)) continue
        if (ts[n] >= keep_from || latest_nr[idof[n]] == n) {
          keep[n] = 1
          prot++
        } else {
          unprot[++u] = n
        }
      }
      drop = u - (max - prot)
      if (drop < 0) drop = 0
      for (i = drop + 1; i <= u; i++) keep[unprot[i]] = 1
      for (n = 1; n <= NR; n++) {
        if (n in keep) print line[n]
      }
    }
  ' "$FM_WAKE_MEMO_FILE" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$FM_WAKE_MEMO_FILE" || { rm -f "$tmp"; return 1; }
  return 0
}

# fm_memo_record <kind> <key> <payload> <outcome> [note]: append one memo entry.
# A pending record is skipped when the identity's latest entry is already
# pending, so repeated drains of an unhandled wake cannot grow the file.
fm_memo_record() {
  local kind=$1 key=$2 payload=$3 outcome=$4 note=${5:-}
  local clean_key phash clean_note ts latest
  fm_memo_valid_kind "$kind" || { printf 'fm_memo_record: invalid kind: %s\n' "$kind" >&2; return 2; }
  fm_memo_valid_outcome "$outcome" || { printf 'fm_memo_record: invalid outcome: %s\n' "$outcome" >&2; return 2; }
  clean_key=$(fm_memo_clean "$key" 256)
  phash=$(printf '%s' "$payload" | fm_memo_hash) || { printf 'fm_memo_record: could not hash payload\n' >&2; return 1; }
  clean_note=$(fm_memo_clean "$note" 200)
  ts=$(date +%s)
  fm_lock_acquire_wait "$FM_WAKE_MEMO_LOCK"
  # Idempotent outcomes: repeating the same verdict for an identical wake (a
  # paused window absorbed every poll, a no-change heartbeat every interval)
  # refreshes nothing, so skip the append. A new outcome for the same identity
  # still appends, preserving the full handling history newest-last.
  latest=$(awk -F '\t' -v k="$kind" -v key="$clean_key" -v h="$phash" '
    NF >= 5 && $2 == k && $3 == key && $4 == h { out = $5 }
    END { print out }
  ' "$FM_WAKE_MEMO_FILE" 2>/dev/null || true)
  if [ "$latest" = "$outcome" ]; then
    fm_lock_release "$FM_WAKE_MEMO_LOCK"
    return 0
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$kind" "$clean_key" "$phash" "$outcome" "$clean_note" >> "$FM_WAKE_MEMO_FILE" || {
    fm_lock_release "$FM_WAKE_MEMO_LOCK"
    return 1
  }
  fm_memo_prune_locked || true
  fm_lock_release "$FM_WAKE_MEMO_LOCK"
  return 0
}

# memo_emit_drained_identities <deduped-raw-rows>: the drain path's first phase of
# the two-phase write - one pending identity per drained queue row (epoch, seq,
# kind, key, payload). Malformed rows are skipped. Best-effort by contract: the
# caller guards with `|| true` so a memo failure never touches the committed rows.
memo_emit_drained_identities() {
  local rows=$1 epoch seq kind key payload
  [ -n "$rows" ] || return 0
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ -n "${kind:-}" ] && [ -n "${key:-}" ] || continue
    fm_memo_record "$kind" "$key" "${payload:-}" pending || true
  done <<EOF
$rows
EOF
  return 0
}

# fm_memo_consult <kind> <key> <payload>: print a citation and exit 0 when the
# identity's latest outcome is a past absorb; exit 1 for genuinely new, pending,
# or previously actioned wakes. The citation carries kind, key, outcome, and
# timestamp only - never payload-derived text.
fm_memo_consult() {
  local kind=$1 key=$2 payload=$3
  local clean_key phash latest
  fm_memo_valid_kind "$kind" || { printf 'fm_memo_consult: invalid kind: %s\n' "$kind" >&2; return 2; }
  clean_key=$(fm_memo_clean "$key" 256)
  phash=$(printf '%s' "$payload" | fm_memo_hash) || { printf 'fm_memo_consult: could not hash payload\n' >&2; return 1; }
  fm_lock_acquire_wait "$FM_WAKE_MEMO_LOCK"
  latest=$(awk -F '\t' -v k="$kind" -v key="$clean_key" -v h="$phash" '
    NF >= 5 && $2 == k && $3 == key && $4 == h { ts = $1; out = $5 }
    END { if (out != "") print ts "\t" out }
  ' "$FM_WAKE_MEMO_FILE" 2>/dev/null || true)
  fm_lock_release "$FM_WAKE_MEMO_LOCK"
  [ -n "$latest" ] || return 1
  local hit_ts=${latest%%$'\t'*}
  local hit_out=${latest#*$'\t'}
  fm_memo_consultable "$hit_out" || return 1
  printf 'memo: %s %s (%s %s)\n' "$hit_out" "$hit_ts" "$kind" "$clean_key"
  return 0
}

fm_memo_usage() {
  cat <<'EOF'
Usage:
  fm-wake-memo.sh record <kind> <key> <payload> <outcome> [note]
  fm-wake-memo.sh consult <kind> <key> <payload>
  fm-wake-memo.sh prune
  fm-wake-memo.sh --help
kinds: signal, stale, check, heartbeat.
outcomes: pending, absorbed-benign, reconciled-idle, steered, interrupted,
relaunched, escalated, failed. The note must never carry raw payload text.
consult exits 0 with a citation on a past absorb, 1 on a miss, 2 on bad input.
EOF
}

fm_memo_main() {
  local cmd=${1:-}
  case "$cmd" in
    record)
      [ "$#" -ge 5 ] && [ "$#" -le 6 ] || { fm_memo_usage >&2; return 2; }
      fm_memo_record "$2" "$3" "$4" "$5" "${6:-}"
      return "$?"
      ;;
    consult)
      [ "$#" -eq 4 ] || { fm_memo_usage >&2; return 2; }
      fm_memo_consult "$2" "$3" "$4"
      return "$?"
      ;;
    prune)
      [ "$#" -eq 1 ] || { fm_memo_usage >&2; return 2; }
      fm_lock_acquire_wait "$FM_WAKE_MEMO_LOCK"
      fm_memo_prune_locked
      local status=$?
      fm_lock_release "$FM_WAKE_MEMO_LOCK"
      return "$status"
      ;;
    -h|--help|help)
      fm_memo_usage
      return 0
      ;;
    *)
      fm_memo_usage >&2
      return 2
      ;;
  esac
}

# --- Main entry: the CLI below runs only when this file is executed as a
# script. When sourced (the drain script and the watcher load the functions
# above), return here before parsing arguments.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

fm_memo_main "$@"
