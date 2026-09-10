#!/usr/bin/env bash
# Opt-in real Pi/Herdr launch proof for the captain-approved Luna model.
# It routes every Herdr call through one named non-default lab and proves that
# the Pi pane stays present after its launch brief is processed.
set -u

if [ "${FM_PI_HERDR_LUNA_LIVE_E2E:-0}" != 1 ]; then
  echo 'skip: set FM_PI_HERDR_LUNA_LIVE_E2E=1 to run the credentialed Pi/Herdr proof'
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

for command_name in herdr jq pi treehouse; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "skip: $command_name not found"; exit 0; }
done
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

# The server passes its login shell to each new pane. Avoid operator startup
# helpers so the process proof below observes the worker pane itself.
SHELL=/bin/bash
export SHELL FM_SPAWN_SKIP_PARLAY=1
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-pi-herdr-luna.XXXXXX")
HERDR_LAB_SESSION=$($HERDR_LAB_HELPER name fm-pi-herdr-luna)
REAL_HERDR=$(command -v herdr)
ORIGINAL_PATH=$PATH
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR ORIGINAL_PATH
PROJECT="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
WT=

cleanup() {
  local status=$?
  [ -z "$WT" ] || treehouse return --force "$WT" >/dev/null 2>&1 || status=1
  env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision the named Herdr lab'

# Keep the lab helper as the only Herdr transport, including Herdr calls made
# by the production spawn and backend code.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset 'args[$last]' 'args[$flag]'
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

mkdir -p "$PROJECT" "$HOME_DIR/state" "$HOME_DIR/data/pi-luna" "$HOME_DIR/config"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
git -C "$PROJECT" init -q
printf '# Pi Luna lab project\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
cat > "$HOME_DIR/data/pi-luna/brief.md" <<'EOF'
# Pi Luna launch proof

Read these instructions and follow them before waiting for more work.
Create a file named `PI_LUNA_BRIEF_PROCESSED` in the current project containing exactly `brief-processed`.
After creating the file, remain available in the interactive session.
EOF

OUT="$TMP_ROOT/spawn.out"
ERR="$TMP_ROOT/spawn.err"
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_LAB_SESSION="$HERDR_LAB_SESSION" \
  HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
  FM_SPAWN_FIRSTTURN=on \
  "$ROOT/bin/fm-spawn.sh" pi-luna "$PROJECT" --mode direct-PR --yolo off \
    --backend herdr --harness pi --model openai-codex/gpt-5.6-luna --effort low \
    >"$OUT" 2>"$ERR" || fail "Pi/Luna spawn failed: $(cat "$OUT") $(cat "$ERR")"

META="$HOME_DIR/state/pi-luna.meta"
[ -f "$META" ] || fail 'Pi/Luna spawn did not publish task metadata'
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
[ -n "$WT" ] && [ -n "$PANE" ] || fail 'Pi/Luna metadata did not include its Herdr pane and local copy'
[ -d "$WT" ] || fail 'Pi/Luna metadata points at a missing local copy'
pass "real named lab: Pi/Luna launch returned with a recorded Herdr pane"

PROCESSED=0
VISIBLE=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  INFO=$(lab pane process-info --pane "$PANE" 2>/dev/null || true)
  if printf '%s' "$INFO" | jq -e '
    [.result.process_info.foreground_processes[]?
      | ([.name // "", .argv0 // "", .cmdline // ""] | join(" "))
      | test("(^|[^A-Za-z])pi([^A-Za-z]|$)"; "i")]
    | any
  ' >/dev/null 2>&1; then
    VISIBLE=1
  fi
  [ -f "$WT/PI_LUNA_BRIEF_PROCESSED" ] && { PROCESSED=1; break; }
  /bin/sleep 1
done
[ "$VISIBLE" -eq 1 ] || fail "Pi/Luna never appeared as a foreground process in the named lab: $INFO"
[ "$PROCESSED" -eq 1 ] || fail 'Pi/Luna did not process the launch brief within the bounded proof window'
pass 'real named lab: Pi/Luna appeared visibly and processed the launch brief'

INFO=$(lab pane process-info --pane "$PANE") || fail 'the Pi/Luna pane disappeared before the availability check'
printf '%s' "$INFO" | jq -e '.result.process_info.pane_id == $pane' --arg pane "$PANE" >/dev/null \
  || fail 'the final process-info response did not identify the recorded Pi/Luna pane'
pass 'real named lab: Pi/Luna remained available after processing its brief'
printf 'evidence: model=openai-codex/gpt-5.6-luna herdr=%s pane=%s default-session=not-used\n' \
  "$(lab status --json | jq -r '.client.version')" "$PANE"
