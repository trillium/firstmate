#!/usr/bin/env bash
# tests/fm-herdr-spur.test.sh - behavior tests for the external-agent completion
# bridge (bin/fm-herdr-spur.sh) and the strict ownership lookup it relies on
# (window_owner_task in bin/fm-classify-lib.sh).
#
# The bridge exists to surface agents firstmate structurally CANNOT see. A
# firstmate-SPAWNED agent already reports completion through its status append
# and turn-end hook, so a spur on its finish edge is a duplicate wake and it
# pollutes the one channel that is supposed to mean "external". These cases pin
# that filter, including the backend-qualified "<session>:<pane-id>" meta shape
# that a bare pane id never matches on its own.
#
# No real herdr: `herdr agent list` is a PATH stub and the bridge runs --once
# with FM_HERDR_SPUR_SEED supplying the prior "working" level.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || {
  echo "# fm-herdr-spur.test.sh: SKIP - jq absent (the bridge parses herdr JSON with it)"
  exit 0
}

# --- window_owner_task: strict, never guesses --------------------------------

# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

OWNER_ROOT=$(fm_test_tmproot fm-spur-owner)
OWNER_STATE="$OWNER_ROOT/state"
mkdir -p "$OWNER_STATE"
fm_write_meta "$OWNER_STATE/shipwright.meta" "window=default:w1J:p2" "harness=claude"

[ "$(window_owner_task 'default:w1J:p2' "$OWNER_STATE")" = "shipwright" ] \
  || fail "window_owner_task must resolve an exact recorded window= to its task"
pass "window_owner_task resolves a recorded window target to its owning task"

if out=$(window_owner_task 'w9Z:p7' "$OWNER_STATE"); then
  fail "window_owner_task must return non-zero for an unowned target, got: $out"
fi
[ -z "${out:-}" ] || fail "window_owner_task must print nothing for an unowned target, got: $out"
pass "window_owner_task returns non-zero and prints nothing when no task owns the target"

# The guessing fallback is window_to_task's job alone; keeping it there is what
# lets an ownership decision trust a non-zero return.
[ "$(window_to_task 'w9Z:p7' "$OWNER_STATE")" = "p7" ] \
  || fail "window_to_task must keep its always-something fallback for unowned targets"
[ "$(window_to_task 'default:w1J:p2' "$OWNER_STATE")" = "shipwright" ] \
  || fail "window_to_task must still resolve an owned target through the metadata scan"
pass "window_to_task keeps its fallback while window_owner_task stays strict"

# --- the bridge: owned panes are filtered out of the spur channel ------------

# spur_run <home> <seed> <agents-json> : run one --once pass of the bridge in a
# fixture home whose herdr is a stub emitting <agents-json>, then echo the wake
# queue it produced (empty when nothing was enqueued).
spur_run() {
  local home=$1 seed=$2 agents=$3 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
# Only \`agent list\` is reachable from the --once path; anything else is a bug.
case "\$1 \${2:-}" in
  "agent list") printf '%s\n' '$agents' ;;
  *) printf 'unexpected herdr call: %s\n' "\$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HERDR_SPUR_SEED="$seed" \
    "$ROOT/bin/fm-herdr-spur.sh" --once >/dev/null 2>&1 \
    || fail "fm-herdr-spur.sh --once exited non-zero"
  cat "$home/state/.wake-queue" 2>/dev/null || true
}

# An UNOWNED pane still spurs: this case is the canary that the stub, the JSON
# parse, and the enqueue path all work, so a silent "no wakes" below is a real
# filter and not a broken fixture.
EXT_HOME=$(fm_test_tmproot fm-spur-ext)
mkdir -p "$EXT_HOME/state"
EXT_Q=$(spur_run "$EXT_HOME" 'w9Z:p7=working' \
  '{"result":{"agents":[{"name":null,"pane_id":"w9Z:p7","workspace_id":"w9Z","agent_status":"idle"}]}}')
printf '%s\n' "$EXT_Q" | grep -q 'herdr-spur:w9Z:p7' \
  || fail "an external agent's working->idle edge must still spur, got: $EXT_Q"
pass "a pane no firstmate task records still spurs on working->idle"

# The reported defect: a firstmate-owned secondmate pane classified as external.
# herdr records window= as "<session>:<pane-id>" while `herdr agent list` reports
# the BARE pane id, so this is exactly the shape that failed to match.
OWNED_HOME=$(fm_test_tmproot fm-spur-owned)
mkdir -p "$OWNED_HOME/state"
fm_write_meta "$OWNED_HOME/state/shipwright.meta" "window=default:w1J:p2" "harness=claude"
OWNED_Q=$(spur_run "$OWNED_HOME" 'w1J:p2=working' \
  '{"result":{"agents":[{"name":null,"pane_id":"w1J:p2","workspace_id":"w1J","agent_status":"idle"}]}}')
[ -z "$OWNED_Q" ] \
  || fail "a firstmate-owned pane must not spur (it already wakes via its status file), got: $OWNED_Q"
pass "a bare pane id matching a backend-qualified window= is recognized as owned and never spurs"

# The same filter holds when meta recorded the window unqualified.
BARE_HOME=$(fm_test_tmproot fm-spur-bare)
mkdir -p "$BARE_HOME/state"
fm_write_meta "$BARE_HOME/state/shipwright.meta" "window=w1J:p2" "harness=claude"
BARE_Q=$(spur_run "$BARE_HOME" 'w1J:p2=working' \
  '{"result":{"agents":[{"name":null,"pane_id":"w1J:p2","workspace_id":"w1J","agent_status":"idle"}]}}')
[ -z "$BARE_Q" ] || fail "an unqualified window= must also be recognized as owned, got: $BARE_Q"
pass "an unqualified recorded window= is recognized as owned too"

# Mixed fleet: the owned pane is dropped and the external one survives in the
# same pass, which is the property that keeps the channel readable.
MIX_HOME=$(fm_test_tmproot fm-spur-mix)
mkdir -p "$MIX_HOME/state"
fm_write_meta "$MIX_HOME/state/shipwright.meta" "window=default:w1J:p2" "harness=claude"
MIX_Q=$(spur_run "$MIX_HOME" 'w1J:p2=working,w9Z:p7=working' \
  '{"result":{"agents":[{"name":null,"pane_id":"w1J:p2","workspace_id":"w1J","agent_status":"done"},{"name":null,"pane_id":"w9Z:p7","workspace_id":"w9Z","agent_status":"done"}]}}')
printf '%s\n' "$MIX_Q" | grep -q 'herdr-spur:w9Z:p7' \
  || fail "the external agent must still spur alongside an owned one, got: $MIX_Q"
printf '%s\n' "$MIX_Q" | grep -q 'w1J:p2' \
  && fail "the owned agent must be absent from the spur channel, got: $MIX_Q"
[ "$(printf '%s\n' "$MIX_Q" | grep -c 'herdr-spur:')" = "1" ] \
  || fail "exactly one spur expected from a one-owned/one-external pass, got: $MIX_Q"
pass "a mixed pass spurs only the external agent"

echo "# fm-herdr-spur.test.sh: all assertions passed"
