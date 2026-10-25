#!/usr/bin/env bash
# tests/fm-urgent.test.sh - bin/fm-urgent.sh through its public CLI on the
# file-backed fake pane (FM_URGENT_BACKEND=fake, armed by FM_TEST_SEAM=1):
# argument parsing, record creation, the fallback exit paths, the idle-timeout
# computation, and the done/cleanup path. The real-harness run is the live QR
# regression recorded in docs/urgency-protocol.md.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

URGENT="$ROOT/bin/fm-urgent.sh"
TMP=$(fm_test_tmproot fm-urgent)
export FM_HOME="$TMP/home"
export FM_URGENT_BACKEND=fake
export FM_URGENT_FAKE_DIR="$TMP/fake"
export FM_URGENT_POLL_SECS=1
export FM_URGENT_BASE="$TMP/base"
export FM_URGENT_NOW=1000000
mkdir -p "$FM_HOME" "$TMP/bin"

# A stand-in harness on PATH so the launch passes the harness-ready check.
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH"

contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
run() { OUT=$("$URGENT" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }

# --- duration parsing -----------------------------------------------------
for pair in "90s:90" "30m:1800" "10h:36000" "2d:172800" "45:45"; do
  run duration "${pair%%:*}"
  [ "$RC" = 0 ] && [ "$OUT" = "${pair##*:}" ] || fail "duration ${pair%%:*} -> '$OUT' (rc $RC), want ${pair##*:}"
done
for bad in "" 0 -5 1x 1.5h h; do
  run duration "$bad"
  [ "$RC" = 2 ] || fail "duration '$bad' should be refused with 2, got $RC"
done
pass "idle-timeout durations parse to seconds and garbage is refused"

# --- argument parsing -----------------------------------------------------
run
[ "$RC" = 2 ] || fail "bare invocation should print usage and exit 2 (got $RC)"
run Bad_Slug -- ask
{ [ "$RC" = 2 ] && contains "$ERR" "lowercase letters"; } || fail "bad slug not refused: rc=$RC err=$ERR"
run ok1 --harness gemini -- ask
[ "$RC" = 2 ] || fail "unknown harness should exit 2 (got $RC)"
run ok1 --idle-timeout soon -- ask
[ "$RC" = 2 ] || fail "bad idle timeout should exit 2 (got $RC)"
run ok1 --bogus -- ask
[ "$RC" = 2 ] || fail "unknown flag should exit 2 (got $RC)"
run ok1 --harness claude
[ "$RC" = 2 ] || fail "missing ask should exit 2 (got $RC)"
[ ! -e "$FM_HOME/state/urgent/ok1" ] || fail "a refused launch must leave no record"
pass "argument parsing refuses bad slugs, harnesses, durations, flags, and a missing ask"

# --- launch: record, prompt, launch script, pane ----------------------------
printf 'context from firstmate\n' >"$TMP/ctx.txt"
run qr1 --harness claude --idle-timeout 30m --out "$TMP/out1" --grant "Only touch the out dir." \
  --context "$TMP/ctx.txt" -- "make six QR PDFs"
[ "$RC" = 0 ] || fail "launch failed rc=$RC err=$ERR"
case "$OUT" in *"urgent:qr1 is open"*) ;; *) fail "launch line missing pane name: $OUT" ;; esac
REC="$FM_HOME/state/urgent/qr1/record"
[ -f "$REC" ] || fail "no record written"
for want in "slug=qr1" "pane=fake:p1" "harness=claude" "status=live" "idle_secs=1800" "started=1000000" "out=$(cd "$TMP/out1" && pwd -P)" "grant=Only touch the out dir."; do
  grep -qxF "$want" "$REC" || fail "record lacks '$want': $(cat "$REC")"
done
D="$FM_HOME/state/urgent/qr1"
grep -qF "make six QR PDFs" "$D/prompt.md" || fail "prompt lacks the ask"
grep -qF "context from firstmate" "$D/prompt.md" || fail "prompt lacks the passed context"
grep -qF "Only touch the out dir." "$D/prompt.md" || fail "prompt lacks the grant"
grep -qF "Native sub-agents are explicitly preauthorized" "$D/role.md" || fail "role lacks the sub-agent preauthorization"
grep -qF "Do NOT write firstmate briefs" "$D/role.md" || fail "role lacks the no-briefs rule"
grep -q -- '--permission-mode acceptEdits' "$D/launch.sh" || fail "claude launch lacks the scoped permission mode"
grep -q -- "--settings .*claude-settings.json" "$D/launch.sh" || fail "claude launch lacks the per-session settings"
jq -e '.permissions.allow | index("Agent") and index("Task")' "$D/claude-settings.json" >/dev/null || fail "settings do not preapprove native sub-agents"
jq -e '.permissions.deny | index("Bash(git push:*)")' "$D/claude-settings.json" >/dev/null || fail "settings do not deny pushes"
[ "$(cat "$FM_URGENT_FAKE_DIR/panes/p1/label")" = "urgent:qr1" ] || fail "pane label wrong"
grep -q "launch.sh" "$FM_URGENT_FAKE_DIR/panes/p1/sent" || fail "launch command was not typed into the pane"
[ ! -e "$FM_HOME/state/qr1.meta" ] && [ ! -e "$FM_HOME/state/qr1.status" ] || fail "launch must not create firstmate task records"
pass "launch writes the record, prompt, role, scoped claude settings, and types the launch into one labelled pane"

# --- list / status / duplicate ---------------------------------------------
run list
case "$OUT" in qr1$'\t'live*) ;; *) fail "list lacks the live session: $OUT" ;; esac
run status qr1
case "$OUT" in *"idle_closes_in_secs=1800"*) ;; *) fail "status lacks the idle deadline: $OUT" ;; esac
FM_URGENT_NOW=$((1000000 + 600))
run status qr1
contains "$OUT" "idle_closes_in_secs=1200" || fail "idle countdown should shrink as the clock advances: $OUT"
FM_URGENT_NOW=1000000
run qr1 -- again
{ [ "$RC" = 1 ] && contains "$ERR" "already exists"; } || fail "duplicate slug not refused: rc=$RC err=$ERR"
pass "list and status show the session; a duplicate slug is refused"

# --- fallback exits ---------------------------------------------------------
# Pi without a sub-agent package: fake `pi list` showing none.
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "$1" = list ] && echo "User packages:" && echo "  npm:pi-web-access"\nexit 0\n' >"$TMP/bin/pi"
chmod +x "$TMP/bin/pi"
run pi1 --harness pi -- ask
{ [ "$RC" = 1 ] && contains "$ERR" "no installed sub-agent package"; } || fail "pi without sub-agents must stop with that reason: rc=$RC err=$ERR"
[ "$(printf '%s' "$ERR" | wc -l)" -le 1 ] || fail "fallback must be one plain line: $ERR"
[ ! -e "$FM_HOME/state/urgent/pi1" ] || fail "a refused launch must leave no record"
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "$1" = list ] && echo "  npm:pi-subagents"\nexit 0\n' >"$TMP/bin/pi"
run pi1 --harness pi --out "$TMP/outpi" -- ask
[ "$RC" = 0 ] || fail "pi with a sub-agent package should launch: rc=$RC err=$ERR"
grep -q '^exec pi ' "$FM_HOME/state/urgent/pi1/launch.sh" || fail "pi launch line missing"
# Missing harness binary.
SAVED_PATH=$PATH
mkdir -p "$TMP/empty"
PATH="$TMP/empty:/usr/bin:/bin"
run nohar --harness claude -- ask
PATH=$SAVED_PATH
if command -v claude >/dev/null 2>&1 && [ "$(PATH="$TMP/empty:/usr/bin:/bin" command -v claude)" = "" ]; then
  { [ "$RC" = 1 ] && contains "$ERR" "Claude Code is not installed"; } || fail "missing claude not reported: rc=$RC err=$ERR"
fi
# No window backend: the fake is the only seam, so assert the real-path message through a missing tmux/herdr.
(
  unset FM_URGENT_BACKEND
  PATH="$TMP/bin:$TMP/empty:/usr/bin:/bin"
  FM_BACKEND=tmux
  export FM_BACKEND
  if ! command -v tmux >/dev/null 2>&1; then
    OUT2=$("$URGENT" nowin --harness claude -- ask 2>&1); RC2=$?
    [ "$RC2" = 1 ] && case "$OUT2" in *"no interactive window available"*) true ;; *) false ;; esac || exit 9
  fi
) || fail "missing window backend should exit 1 with the plain reason"
pass "fallback exits non-zero with one plain line and never leaves a record or a brief"

# --- done: refuse mid-turn, then preserve + close --------------------------
echo "pdf-bytes" >"$TMP/out1/card-1.pdf"
echo busy >"$FM_URGENT_FAKE_DIR/panes/p1/busy"
echo "screen text for the tail" >"$FM_URGENT_FAKE_DIR/panes/p1/screen"
run "done" qr1
[ "$RC" = 3 ] || fail "done mid-turn must refuse with 3 (got $RC, $ERR)"
[ ! -f "$FM_URGENT_FAKE_DIR/panes/p1/closed" ] || fail "a mid-turn pane must not be closed"
grep -qx 'status=live' "$REC" || fail "refused done must leave the session live"
echo idle >"$FM_URGENT_FAKE_DIR/panes/p1/busy"
run "done" qr1
[ "$RC" = 0 ] || fail "done failed rc=$RC err=$ERR"
[ -f "$FM_URGENT_FAKE_DIR/panes/p1/closed" ] || fail "done must close the recorded pane"
[ ! -f "$FM_URGENT_FAKE_DIR/panes/p2/closed" ] || fail "done must never touch another pane"
grep -qx 'status=done' "$REC" || fail "record not marked done"
[ -f "$TMP/out1/card-1.pdf" ] || fail "the original output dir must survive cleanup"
[ -f "$FM_HOME/data/urgent/qr1/out/card-1.pdf" ] || fail "outputs were not copied under data/urgent/<slug>/out"
{ [ -f "$FM_HOME/data/urgent/qr1/pane-tail.txt" ] && grep -q "screen text" "$FM_HOME/data/urgent/qr1/pane-tail.txt"; } || fail "pane tail not preserved"
grep -q '^transcript:' "$FM_HOME/data/urgent/qr1/transcript-pointer.txt" || fail "transcript pointer missing"
run "done" qr1
{ [ "$RC" = 0 ] && contains "$ERR" "already done"; } || fail "second done should be a quiet no-op: rc=$RC err=$ERR"
pass "done refuses mid-turn, then preserves outputs and context, closes only its own pane, and is idempotent"

# --- done --force closes a busy pane ---------------------------------------
echo busy >"$FM_URGENT_FAKE_DIR/panes/p2/busy"
run "done" pi1 --force
[ "$RC" = 0 ] && [ -f "$FM_URGENT_FAKE_DIR/panes/p2/closed" ] || fail "--force should close a busy pane (rc=$RC err=$ERR)"
pass "done --force closes a busy pane after preserving"

# --- idle watcher: expiry, activity reset, busy guard -----------------------
run idle1 --harness claude --idle-timeout 60s --out "$TMP/outi" -- ask
[ "$RC" = 0 ] || fail "idle1 launch failed: $ERR"
IREC="$FM_HOME/state/urgent/idle1/record"
PANE=$(sed -n 's/^pane=fake://p' "$IREC")
echo "work in $TMP" >"$TMP/outi/result.txt"
watch_once() { # run the loop for ~3 poll periods then stop it
  "$URGENT" watch-loop idle1 >"$TMP/watch.log" 2>&1 &
  WPID=$!
  sleep 3
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
}
# Stop the launch's own detached watcher so this test drives the loop itself.
kill "$(cat "$FM_HOME/state/urgent/idle1/watcher.pid")" 2>/dev/null
FM_URGENT_NOW=$((1000000 + 59))
echo "tick" >"$FM_URGENT_FAKE_DIR/panes/$PANE/screen"
watch_once
grep -qx 'status=live' "$IREC" || fail "must stay live before the idle timeout"
FM_URGENT_NOW=$((1000000 + 61))
echo busy >"$FM_URGENT_FAKE_DIR/panes/$PANE/busy"
watch_once
grep -qx 'status=live' "$IREC" && [ ! -f "$FM_URGENT_FAKE_DIR/panes/$PANE/closed" ] || fail "must never close a busy pane at expiry"
echo idle >"$FM_URGENT_FAKE_DIR/panes/$PANE/busy"
FM_URGENT_NOW=$((1000000 + 200))
watch_once
grep -qx 'status=expired' "$IREC" || fail "idle pane past the timeout should expire: $(cat "$IREC") $(cat "$TMP/watch.log")"
[ -f "$FM_URGENT_FAKE_DIR/panes/$PANE/closed" ] || fail "expiry must close the pane"
[ -f "$FM_HOME/data/urgent/idle1/out/result.txt" ] || fail "expiry must preserve outputs before closing"
[ -f "$TMP/outi/result.txt" ] || fail "expiry must not delete the original output dir"
pass "idle watcher waits for the timeout, never closes a busy pane, then preserves and closes"

# --- external close: preserved, not lost -----------------------------------
FM_URGENT_NOW=1000000
run ext1 --out "$TMP/oute" -- ask
kill "$(cat "$FM_HOME/state/urgent/ext1/watcher.pid")" 2>/dev/null
echo x >"$TMP/oute/a.txt"
EPANE=$(sed -n 's/^pane=fake://p' "$FM_HOME/state/urgent/ext1/record")
: >"$FM_URGENT_FAKE_DIR/panes/$EPANE/closed"
"$URGENT" watch-loop ext1 >/dev/null 2>&1 &
EP=$!; sleep 2; kill "$EP" 2>/dev/null; wait "$EP" 2>/dev/null
grep -qx 'status=closed-externally' "$FM_HOME/state/urgent/ext1/record" || fail "captain-closed pane should be recorded as closed-externally"
[ -f "$FM_HOME/data/urgent/ext1/out/a.txt" ] || fail "outputs of an externally closed pane must still be preserved"
pass "a pane the captain closed by hand is recorded and its outputs are still preserved"

echo "fm-urgent: all tests passed"
