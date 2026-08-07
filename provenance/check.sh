#!/usr/bin/env bash
# provenance/check.sh - the fork-feature provenance guard.
#
# Green when every registered fork feature is present and still behaves as
# approved; red (nonzero exit) the moment one is deleted or its behavior is
# clobbered - the whole point of the POC.
#
# Usage:
#   provenance/check.sh            verify every feature in the register.
#   provenance/check.sh --regen    re-bless: (re)write approved snapshots AND
#                                   recompute anchor signatures in the register.
#                                   Run this ONLY after a human has reviewed the
#                                   diff and confirmed each story still holds.
#   provenance/check.sh --help     this help.
#
# Per feature, in check mode:
#   1. Anchors: a vanished path or symbol is a FAIL (deletion tripwire). A sig
#      that no longer matches is a WARN, not a FAIL - upstream edits shift code
#      without deleting features, and drift just prompts a human re-bless.
#   2. Behavioral proof: run the feature's `test` command, scrub volatile tokens,
#      and diff against tests/provenance/<id>/approved.txt. A mismatch (or a
#      missing snapshot) is a FAIL - the feature's behavior changed or is gone.
#
# Exit 0 iff no FAIL. See provenance/README.md for the format and the guarantee.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=provenance/lib.sh
. "$SELF_DIR/lib.sh"

# ROOT / REGISTER / SNAP_DIR default to this repo's real locations. The three
# FM_PROV_* env overrides exist so the portable regression test can point the
# whole guard at an isolated fixture tree without touching tracked files.
ROOT=${FM_PROV_ROOT:-$(cd "$SELF_DIR/.." && pwd)}
REGISTER=${FM_PROV_REGISTER:-$SELF_DIR/register.toml}
SNAP_DIR=${FM_PROV_SNAP_DIR:-$ROOT/tests/provenance}

MODE=check
case "${1:-}" in
  --regen) MODE=regen ;;
  --help|-h)
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) echo "provenance/check.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
esac

if [ ! -f "$REGISTER" ]; then
  echo "provenance: register not found at $REGISTER" >&2
  exit 2
fi

# Isolated throwaway home so behavioral `test` commands never touch real state.
TESTHOME=$(mktemp -d)
trap 'rm -rf "$TESTHOME"' EXIT
export FM_PROV_ROOT="$ROOT"

# Run a feature's behavioral `test` command from the repo root under the
# throwaway home, capturing combined output plus a normalized exit-code line,
# then scrubbing volatile tokens. Its stdout is the received snapshot.
run_behavioral() {
  local cmd=$1 out ec
  out=$(cd "$ROOT" && FM_HOME="$TESTHOME" bash -c "$cmd" 2>&1)
  ec=$?
  { printf '%s\n' "$out"; printf -- '---exit---\n%s\n' "$ec"; } | scrub_volatile
}

# Compute the current signature of an anchor: a named-function region when
# `symbol` is set, otherwise the whole file. Prints the fingerprint, or nothing
# and returns nonzero when the path/symbol is gone (the caller treats that as a
# FAIL deletion tripwire).
anchor_signature() {
  local symbol=$2 abs="$ROOT/$1"
  [ -f "$abs" ] || return 1
  if [ -n "$symbol" ]; then
    local region
    region=$(provenance_locate_symbol "$abs" "$symbol") || return 2
    printf '%s\n' "$region" | provenance_fingerprint
  else
    provenance_fingerprint < "$abs"
  fi
}

# --- Load the register into parallel arrays (bash 3.2 compatible). -----------
feat_ids=(); feat_stories=(); feat_tests=()
anc_fidx=(); anc_path=(); anc_symbol=(); anc_sig=()
cur=-1
# US (U+001F), not tab: tab is IFS-whitespace and `read` collapses runs of it, so
# an empty field would swallow the one after it. provenance_parse_register's
# header owns the record format.
while IFS=$'\x1f' read -r kind a b c d; do
  case "$kind" in
    FEATURE) cur=$((cur + 1)); feat_ids[cur]="$a"; feat_stories[cur]=""; feat_tests[cur]="" ;;
    STORY)   feat_stories[cur]="$a" ;;
    TEST)    feat_tests[cur]="$a" ;;
    ANCHOR)  anc_fidx+=("$cur"); anc_path+=("$b"); anc_sig+=("$c"); anc_symbol+=("$d") ;;
  esac
done < <(provenance_parse_register "$REGISTER")
nfeat=$((cur + 1))

# ---------------------------------------------------------------------------
if [ "$MODE" = regen ]; then
  echo "provenance --regen: re-blessing snapshots and signatures"
  sigmap=$(mktemp)
  for ((f = 0; f < nfeat; f++)); do
    id=${feat_ids[f]}
    mkdir -p "$SNAP_DIR/$id"
    run_behavioral "${feat_tests[f]}" > "$SNAP_DIR/$id/approved.txt"
    echo "  snapshot: tests/provenance/$id/approved.txt"
    aidx=0
    for ((i = 0; i < ${#anc_fidx[@]}; i++)); do
      [ "${anc_fidx[i]}" = "$f" ] || continue
      newsig=$(anchor_signature "${anc_path[i]}" "${anc_symbol[i]}") || {
        echo "  ERROR: anchor ${anc_path[i]}#${anc_symbol[i]:-<file>} for '$id' cannot be located; not re-blessed" >&2
        aidx=$((aidx + 1)); continue
      }
      printf '%s\t%s\t%s\n' "$id" "$aidx" "$newsig" >> "$sigmap"
      echo "  sig: $id anchor#$aidx (${anc_path[i]}#${anc_symbol[i]:-<file>}) -> $newsig"
      aidx=$((aidx + 1))
    done
  done
  # Rewrite each anchor's sig line in the register from the freshly computed map,
  # and INSERT one for an anchor authored without a `sig` line at all - otherwise
  # a first-draft anchor would warn "unblessed" forever, since --regen would have
  # nothing to replace.
  tmpreg=$(mktemp)
  awk '
    # Called when an anchor block ends: supply its sig line if it had none, then
    # release any blank lines parked while we waited to see one.
    function close_anchor() {
      if (in_anchor && !sig_seen && (curid SUBSEP aidx) in sig) {
        printf "sig    = \"%s\"\n", sig[curid SUBSEP aidx]
      }
      printf "%s", hold; hold = ""
    }
    FNR == NR { sig[$1 SUBSEP $2] = $3; next }
    /^[ \t]*\[\[feature\]\]/        { close_anchor(); in_anchor = 0; aidx = -1; print; next }
    /^[ \t]*\[\[feature\.anchor\]\]/ { close_anchor(); in_anchor = 1; sig_seen = 0; aidx++; print; next }
    {
      if (!in_anchor) {
        eq = index($0, "=")
        if (eq > 0) {
          k = substr($0, 1, eq - 1); gsub(/[ \t]/, "", k)
          if (k == "id") { v = substr($0, eq + 1); gsub(/[ \t"]/, "", v); curid = v }
        }
        print; next
      }
      # Park blank lines so a synthesized sig line lands with the anchor keys
      # rather than after the gap that separates feature blocks.
      if ($0 ~ /^[ \t]*$/) { hold = hold $0 "\n"; next }
      printf "%s", hold; hold = ""
      t = $0; gsub(/[ \t]/, "", t)
      if (t ~ /^sig=/) {
        sig_seen = 1
        if ((curid SUBSEP aidx) in sig) { printf "sig    = \"%s\"\n", sig[curid SUBSEP aidx]; next }
      }
      print
    }
    END { close_anchor() }
  ' "$sigmap" "$REGISTER" > "$tmpreg"
  mv "$tmpreg" "$REGISTER"
  rm -f "$sigmap"
  echo "provenance --regen: register signatures updated."
  exit 0
fi

# --- Check mode --------------------------------------------------------------
fails=0
warns=0
echo "provenance check: $nfeat feature(s)"
echo
for ((f = 0; f < nfeat; f++)); do
  id=${feat_ids[f]}
  story=${feat_stories[f]}
  feat_fail=0
  feat_warn=0
  detail=""

  # 1) anchors
  aidx=0
  for ((i = 0; i < ${#anc_fidx[@]}; i++)); do
    [ "${anc_fidx[i]}" = "$f" ] || continue
    apath=${anc_path[i]}; asym=${anc_symbol[i]}; want=${anc_sig[i]}
    label="${apath}#${asym:-<file>}"
    if [ ! -f "$ROOT/$apath" ]; then
      detail="${detail}    FAIL  anchor gone: $apath (file deleted - feature clobbered?)\n"
      feat_fail=1
    else
      got=$(anchor_signature "$apath" "$asym")
      rc=$?
      if [ "$rc" -eq 2 ]; then
        detail="${detail}    FAIL  anchor symbol vanished: $label (feature deleted?)\n"
        feat_fail=1
      elif [ "$want" = "PENDING" ]; then
        detail="${detail}    WARN  anchor unblessed: $label (run --regen)\n"
        feat_warn=1
      elif [ "$got" != "$want" ]; then
        detail="${detail}    WARN  anchor drift: $label ($want -> $got); re-verify then --regen\n"
        feat_warn=1
      fi
    fi
    aidx=$((aidx + 1))
  done

  # 2) behavioral proof
  approved="$SNAP_DIR/$id/approved.txt"
  if [ ! -f "$approved" ]; then
    detail="${detail}    FAIL  no approved snapshot: tests/provenance/$id/approved.txt (run --regen)\n"
    feat_fail=1
  else
    received=$(run_behavioral "${feat_tests[f]}")
    if ! diff -u "$approved" <(printf '%s\n' "$received") > "$TESTHOME/diff.$id" 2>&1; then
      detail="${detail}    FAIL  behavior changed vs approved snapshot:\n"
      detail="${detail}$(sed 's/^/        /' "$TESTHOME/diff.$id")\n"
      feat_fail=1
    fi
  fi

  if [ "$feat_fail" -eq 1 ]; then
    echo "  FAIL  $id"
    fails=$((fails + 1))
  elif [ "$feat_warn" -eq 1 ]; then
    echo "  WARN  $id"
    warns=$((warns + 1))
  else
    echo "  PASS  $id"
  fi
  echo "        story: $story"
  [ -n "$detail" ] && printf "%b" "$detail"
done

echo
echo "provenance check: $((nfeat - fails)) ok, $fails failed, $warns warned."
if [ "$fails" -gt 0 ]; then
  echo "provenance: FAIL - a fork feature was lost or its behavior changed. Re-verify the named feature(s) above."
  exit 1
fi
echo "provenance: all fork features present and behaving as approved."
exit 0
