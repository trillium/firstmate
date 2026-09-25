#!/usr/bin/env bash
# tests/fm-parlay-wake.test.sh - behavior tests for the parlay channel to
# wake-queue bridge (bin/fm-parlay-wake.sh).
#
# The bridge exists because the primary's live parlay listener delivers stream
# lines into a session nobody is watching: arrivals sit silent until somebody
# reads the channel. These cases pin the three guarantees that make the bridge
# safe to arm: arrivals become durable wakes, each arrival enqueues exactly
# once across restarts, and arming never floods the queue with old history.
#
# No relay, no parlay binary: the spool is a fixture file passed with --spool
# and the home is a fixture root via FM_ROOT_OVERRIDE, so the enqueue path is
# exercised exactly as the daemon uses it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# wake_run <home> <spool> [cursor-content]: run one --once pass in a fixture
# home against a fixture spool, then echo the wake queue it produced (empty
# when nothing was enqueued). A cursor-content of "-" means no cursor file.
wake_run() {
  local home=$1 spool=$2 cursor=${3-"-"}
  mkdir -p "$home/state"
  if [ "$cursor" = "-" ]; then
    rm -f "$home/state/.parlay-wake.test-agent.cursor"
  else
    printf '%s\n' "$cursor" > "$home/state/.parlay-wake.test-agent.cursor"
  fi
  FM_ROOT_OVERRIDE="$home" \
    "$ROOT/bin/fm-parlay-wake.sh" --agent test-agent --spool "$spool" --once \
    >/dev/null 2>&1 \
    || fail "fm-parlay-wake.sh --once exited non-zero"
  cat "$home/state/.wake-queue" 2>/dev/null || true
}

SPOOL_HOME=$(fm_test_tmproot fm-parlay-wake-spool)
SPOOL="$SPOOL_HOME/test-agent.chan"
cat > "$SPOOL" <<'EOF'
CHAT_MSG|aaa111|user|first message
CHAT_MSG|bbb222|user|second message
not-a-chat-line
CHAT_MSG|ccc333|user|third message
EOF

# A cursor holding a real spool id replays forward from it: with the cursor
# on the first arrival, the two later arrivals enqueue, one wake each, and the
# malformed line is dropped without a wake.
HOME1=$(fm_test_tmproot fm-parlay-wake-new)
Q1=$(wake_run "$HOME1" "$SPOOL" "aaa111")
[ "$(printf '%s' "$Q1" | grep -c .)" -eq 2 ] \
  || fail "expected 2 wakes for 2 arrivals after the cursor, got: $Q1"
case "$Q1" in
  *check*parlay:test-agent*bbb222*user:*second*) ;;
  *) fail "first wake must carry kind, key, id, and text, got: $Q1" ;;
esac
pass "new arrivals enqueue as check wakes with id and text"

# Exactly once: a second pass over the same spool enqueues nothing, because the
# cursor now points at the last arrival. The cursor must survive as a file.
HOME2=$(fm_test_tmproot fm-parlay-wake-dedup)
Q2a=$(wake_run "$HOME2" "$SPOOL" "aaa111")
[ "$(printf '%s' "$Q2a" | grep -c .)" -eq 2 ] || fail "first pass must enqueue 2, got: $Q2a"
[ "$(cat "$HOME2/state/.parlay-wake.test-agent.cursor")" = "ccc333" ] \
  || fail "cursor must advance to the last arrival id"
# Second pass reuses HOME2's state (cursor now ccc333): simulate by pointing a
# fresh run at the same state dir.
mkdir -p "$HOME2/state"
printf 'ccc333\n' > "$HOME2/state/.parlay-wake.test-agent.cursor"
FM_ROOT_OVERRIDE="$HOME2" \
  "$ROOT/bin/fm-parlay-wake.sh" --agent test-agent --spool "$SPOOL" --once \
  >/dev/null 2>&1 || fail "second --once pass exited non-zero"
Q2b=$(cat "$HOME2/state/.wake-queue" 2>/dev/null || true)
[ "$(printf '%s' "$Q2b" | grep -c .)" -eq 2 ] \
  || fail "second pass must enqueue nothing new, queue held: $Q2b"
pass "a restart enqueues nothing when the cursor already covers the spool"

# Forward motion: one line appended after the cursor enqueues exactly one wake.
printf 'CHAT_MSG|ddd444|user|fourth message\n' >> "$SPOOL"
FM_ROOT_OVERRIDE="$HOME2" \
  "$ROOT/bin/fm-parlay-wake.sh" --agent test-agent --spool "$SPOOL" --once \
  >/dev/null 2>&1 || fail "third --once pass exited non-zero"
Q2c=$(cat "$HOME2/state/.wake-queue" 2>/dev/null || true)
[ "$(printf '%s' "$Q2c" | grep -c .)" -eq 3 ] \
  || fail "appended arrival must add exactly one wake, queue held: $Q2c"
case "$Q2c" in
  *ddd444*fourth*) ;;
  *) fail "new wake must carry the appended arrival, got: $Q2c" ;;
esac
pass "an arrival appended after the cursor enqueues exactly one wake"

# Safe arming: no cursor file means first-ever run, and a first pass over
# existing spool history must enqueue nothing, never a flood of old wakes.
HOME3=$(fm_test_tmproot fm-parlay-wake-arm)
Q3=$(wake_run "$HOME3" "$SPOOL" "-")
[ -z "$Q3" ] || fail "first-ever run must enqueue no history, got: $Q3"
pass "arming with no cursor enqueues no history"

# Replaced spool: a cursor that names an id absent from the spool fast-forwards
# to the spool's end without replaying, and arrivals appended after that point
# enqueue normally. The bridge resumes instead of storming.
HOME4=$(fm_test_tmproot fm-parlay-wake-replaced)
SPOOL4="$HOME4/other.chan"
printf 'CHAT_MSG|zzz999|user|replacement spool\n' > "$SPOOL4"
Q4=$(wake_run "$HOME4" "$SPOOL4" "ccc333")
[ -z "$Q4" ] || fail "replaced spool must not replay as new arrivals, got: $Q4"
[ "$(cat "$HOME4/state/.parlay-wake.test-agent.cursor")" = "zzz999" ] \
  || fail "cursor must fast-forward to the replacement spool end"
printf 'CHAT_MSG|www000|user|after replacement\n' >> "$SPOOL4"
FM_ROOT_OVERRIDE="$HOME4" \
  "$ROOT/bin/fm-parlay-wake.sh" --agent test-agent --spool "$SPOOL4" --once \
  >/dev/null 2>&1 || fail "post-replacement pass exited non-zero"
Q4b=$(cat "$HOME4/state/.wake-queue" 2>/dev/null || true)
[ "$(printf '%s' "$Q4b" | grep -c .)" -eq 1 ] \
  || fail "post-replacement arrival must enqueue exactly one wake, got: $Q4b"
pass "a replaced spool fast-forwards, then resumes enqueueing new arrivals"

# Missing spool is a clean usage error, not a silent empty pass.
HOME5=$(fm_test_tmproot fm-parlay-wake-missing)
mkdir -p "$HOME5/state"
if FM_ROOT_OVERRIDE="$HOME5" \
  "$ROOT/bin/fm-parlay-wake.sh" --agent test-agent --spool "$HOME5/no.chan" --once \
  >/dev/null 2>&1; then
  fail "missing spool must exit non-zero"
fi
pass "a missing spool exits non-zero instead of passing silently"
