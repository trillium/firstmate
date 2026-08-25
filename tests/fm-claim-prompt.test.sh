#!/usr/bin/env bash
# Behavior tests for the optional Parlay claim prompt: the default-OFF launch
# shape that hands a bead-linked agent `parlay claim <bead>` instead of its
# whole encoded brief (bin/fm-claim-prompt-lib.sh, wired in bin/fm-spawn.sh).
#
# Two levels are covered here because the subject spans both. The decision
# matrix is a pure function and is pinned directly - every degrade condition,
# because "degrades cleanly" is the entire safety argument for an optional
# Parlay path. The wiring is then pinned end to end through the real
# fm-spawn.sh, because the claim prompt is only worth anything if the launch it
# produces is the one the agent actually receives, and because "off restores
# exactly the previous behaviour" can only be proven against a real launch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-claim-prompt-lib.sh
. "$ROOT/bin/fm-claim-prompt-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claim-prompt)

# assert_eq <expected> <actual> <msg>
assert_eq() {
  [ "$1" = "$2" ] || fail "$3"$'\n'"--- expected ---"$'\n'"$1"$'\n'"--- actual ---"$'\n'"$2"
}

# make_config <name> [<flag-contents>]: a config dir, with the flag file written
# only when contents are given (absent file is the default-off shape).
make_config() {
  local dir="$TMP_ROOT/config-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  [ "$#" -lt 2 ] || printf '%s\n' "$2" > "$dir/spawn-claim-prompt"
  printf '%s\n' "$dir"
}

# with_parlay <exit-code> -- <cmd...>: run with a fake `parlay` on PATH that
# exits <exit-code>, and nothing else from the real PATH's parlay.
with_parlay() {
  local rc=$1 dir; shift; [ "${1:-}" != -- ] || shift
  dir="$TMP_ROOT/parlaybin-$rc"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nexit %s\n' "$rc" > "$dir/parlay"
  chmod +x "$dir/parlay"
  PATH="$dir:$(fm_path_without parlay)" "$@"
}

# --- the gate ----------------------------------------------------------------

test_the_flag_is_off_unless_it_says_exactly_on() {
  local cfg
  # Absent is the shipped state and the one that matters most: a home that has
  # never heard of this feature must not acquire it.
  cfg=$(make_config absent)
  fm_claim_prompt_enabled "$cfg" \
    && fail "the claim prompt was enabled with no flag file at all"

  local bad
  for bad in '' 'off' 'ON' 'true' '1' 'yes' 'on-ish' 'garbage'; do
    cfg=$(make_config "val" "$bad")
    fm_claim_prompt_enabled "$cfg" \
      && fail "the claim prompt was enabled by a flag file reading '$bad'"
  done

  cfg=$(make_config on 'on')
  fm_claim_prompt_enabled "$cfg" \
    || fail "the claim prompt stayed off with the flag explicitly on"

  # Surrounding whitespace is a hand-edited file, not a different intent.
  cfg=$(make_config spaced '  on  ')
  fm_claim_prompt_enabled "$cfg" \
    || fail "a hand-edited flag file with surrounding whitespace did not read as on"

  pass "the claim prompt is off unless its flag says exactly on, and an absent flag is off"
}

test_every_degrade_condition_falls_back_to_the_brief() {
  local cfg on
  cfg=$(make_config degrade-off)
  on=$(make_config degrade-on 'on')

  # Off wins before anything else is even consulted - no bead lookup, no probe.
  assert_eq 'off disabled' "$(with_parlay 0 -- fm_claim_prompt_decide "$cfg" ship bead-1 2)" \
    "a disabled home did not degrade"
  # A secondmate carries a charter, not a bead-backed work item.
  assert_eq 'off secondmate' \
    "$(with_parlay 0 -- fm_claim_prompt_decide "$on" secondmate bead-1 2)" \
    "a secondmate did not degrade even with a bead forced onto it"
  # A task with no linked bead has nothing to claim.
  assert_eq 'off no-bead' "$(with_parlay 0 -- fm_claim_prompt_decide "$on" ship '' 2)" \
    "a task with no bead did not degrade"
  # Parlay is optional captain tooling: not having it installed is normal.
  assert_eq 'off no-parlay' \
    "$(PATH="$(fm_path_without parlay)" fm_claim_prompt_decide "$on" ship bead-1 2)" \
    "an absent parlay binary did not degrade"
  # Installed but the server is down: the claim would fail in the agent's pane.
  assert_eq 'off unreachable' \
    "$(with_parlay 1 -- fm_claim_prompt_decide "$on" ship bead-1 2)" \
    "an unreachable parlay server did not degrade"

  # Only all of them together open the gate.
  assert_eq 'use' "$(with_parlay 0 -- fm_claim_prompt_decide "$on" ship bead-1 2)" \
    "the gate stayed shut with the flag on, a bead present, and parlay answering"
  # A scout is ordinary bead-backed work, so it is eligible exactly like a ship.
  assert_eq 'use' "$(with_parlay 0 -- fm_claim_prompt_decide "$on" scout bead-1 2)" \
    "a scout was excluded from a path it qualifies for"
  pass "disabled, secondmate, no-bead, absent-parlay, and unreachable-server each degrade to the brief"
}

test_an_unreachable_probe_cannot_hang_a_spawn() {
  local on dir started elapsed out
  on=$(make_config hang 'on')
  dir="$TMP_ROOT/parlaybin-hang"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nsleep 600\n' > "$dir/parlay"
  chmod +x "$dir/parlay"

  # An optional convenience must never be able to wedge a launch. The bound is
  # the whole reason the probe is allowed to exist.
  started=$(date +%s)
  out=$(PATH="$dir:$(fm_path_without parlay)" fm_claim_prompt_decide "$on" ship bead-1 2)
  elapsed=$(( $(date +%s) - started ))
  assert_eq 'off unreachable' "$out" "a hanging parlay did not degrade"
  [ "$elapsed" -lt 20 ] \
    || fail "a hanging parlay probe took ${elapsed}s - the bound did not hold"
  pass "a hanging parlay server is bounded and degrades instead of wedging the launch"
}

test_the_probe_is_skipped_without_a_bounded_runner() {
  local on out
  on=$(make_config nobound 'on')
  # fm_run_timed is what makes the probe safe. Running one unbounded is worse
  # than not running one, so its absence must degrade rather than improvise.
  # A fresh shell with ONLY this library sourced: fm_run_timed is not defined.
  # shellcheck disable=SC2016  # single quotes are deliberate: $1/$2 are the child shell's own args
  out=$(with_parlay 0 -- bash -c '
    . "$1/bin/fm-claim-prompt-lib.sh"
    fm_claim_prompt_decide "$2" ship bead-1 2
  ' _ "$ROOT" "$on")
  assert_eq 'off unreachable' "$out" \
    "the gate opened without any bounded runner to hold the probe"
  pass "no bounded runner means no probe: the gate degrades instead of running one unbounded"
}

# --- the prompt itself -------------------------------------------------------

test_the_claim_prompt_never_loses_the_brief() {
  local out path
  path="$TMP_ROOT/prompt.md"
  fm_claim_prompt_write "$path" task-wgos /abs/data/task-spwn/brief.md task-spwn \
    || fail "writing the claim prompt failed"
  out=$(cat "$path")

  assert_contains "$out" 'parlay claim task-wgos' "the prompt does not carry the claim command"
  # fm-spawn already enrolled this agent in Parlay under its FIRSTMATE task id
  # and recorded that pid for teardown. Without --agent the claim would derive a
  # second identity from the ticket, and without --silent it would print a
  # `parlay listen` command for the agent to arm - a second poll loop teardown
  # does not know about.
  assert_contains "$out" '--agent task-spwn' \
    "the claim does not pin the agent to firstmate's own task id"
  assert_contains "$out" '--silent' \
    "the claim does not suppress the arm-command for a listener firstmate already runs"
  # The whole safety argument for a SHORT prompt is that it still reaches the
  # full contract - the worktree isolation assertion, the definition of done,
  # the status protocol all live in the brief and nowhere else.
  assert_contains "$out" '/abs/data/task-spwn/brief.md' "the prompt does not name the brief"
  assert_contains "$out" 'The brief is authoritative' "the prompt does not say the brief wins"
  assert_contains "$out" 'skip it and follow the brief' \
    "the prompt does not tell the agent what to do when the claim fails"

  # Short is the point; a prompt that grew back into a charter would be a
  # regression rather than a feature.
  [ "$(wc -c < "$path")" -lt 512 ] \
    || fail "the claim prompt is no longer short ($(wc -c < "$path") bytes)"
  pass "the claim prompt carries the claim, names the brief, and keeps the brief authoritative"
}

test_a_prompt_that_cannot_be_written_is_a_failure_not_a_half_file() {
  local dir
  dir="$TMP_ROOT/unwritable"
  mkdir -p "$dir"
  chmod 500 "$dir"
  fm_claim_prompt_write "$dir/prompt.md" task-wgos /abs/brief.md task-spwn \
    && { chmod 700 "$dir"; fail "writing into an unwritable dir reported success"; }
  [ -e "$dir/prompt.md" ] && { chmod 700 "$dir"; fail "a failed write left a file behind"; }
  chmod 700 "$dir"

  # A missing argument must never yield a prompt missing its brief pointer, its
  # bead, or the agent id that keeps the claim on firstmate's own identity.
  fm_claim_prompt_write "$TMP_ROOT/p2.md" task-wgos '' task-spwn \
    && fail "a prompt with no brief pointer was written"
  fm_claim_prompt_write "$TMP_ROOT/p3.md" '' /abs/brief.md task-spwn \
    && fail "a prompt with no bead was written"
  fm_claim_prompt_write "$TMP_ROOT/p4.md" task-wgos /abs/brief.md '' \
    && fail "a prompt with no agent id was written"
  pass "an unwritable or under-specified prompt fails instead of launching against a half file"
}

# --- end to end through the real spawn ---------------------------------------

# make_spawn_case <name> <id>: a home + project + worktree + brief, with a fake
# tmux that logs the launch line, ready for a real spawn.
make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin sendlog
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  sendlog="$case_dir/send-keys.log"
  mkdir -p "$case_dir"
  : > "$sendlog"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  list-windows) exit 0 ;;
  new-window) printf '@9\n'; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys) printf '%s\n' "\$*" >> '$sendlog'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$sendlog"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SEND_LOG <<EOF
$1
EOF
}

# run_case_spawn <id> [extra args...]: the real spawn against the fake backend.
# PARLAY_RC selects the fake parlay's exit status; unset means no parlay at all.
run_case_spawn() {
  local id=$1 pdir; shift
  pdir="$CASE_DIR/parlaybin"
  mkdir -p "$pdir"
  if [ -n "${PARLAY_RC:-}" ]; then
    printf '#!/usr/bin/env bash\nexit %s\n' "$PARLAY_RC" > "$pdir/parlay"
    chmod +x "$pdir/parlay"
  fi
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_SPAWN_CLAIM_PROBE_TIMEOUT=2 \
    PATH="$pdir:$FAKEBIN_DIR:$(fm_path_without parlay)" \
    "$SPAWN" --mode no-mistakes --yolo off --harness claude "$id" "$PROJ_DIR" "$@" 2>&1
}

# launch_line <sendlog>: the send-keys payload that carries the launch command.
launch_line() { grep -F -- '-l ' "$1" | grep -F 'claude' | head -1; }

test_the_launch_reads_the_claim_prompt_when_the_gate_opens() {
  local rec id out prompt
  id=claim-on-z1
  rec=$(make_spawn_case on "$id"); read_spawn_record "$rec"
  printf 'on\n' > "$HOME_DIR/config/spawn-claim-prompt"

  out=$(PARLAY_RC=0 run_case_spawn "$id" --beads task-wgos)
  expect_code 0 "$?" "spawn failed with the claim prompt on: $out"

  prompt="$HOME_DIR/data/$id/claim-prompt.md"
  [ -f "$prompt" ] || fail "the gate opened but no claim prompt was written"
  assert_grep 'parlay claim task-wgos' "$prompt" "the claim prompt lost its bead"
  assert_grep "data/$id/brief.md" "$prompt" "the claim prompt lost its brief pointer"

  # The launch must READ the claim prompt, not the brief - that substitution is
  # the only thing this feature changes.
  assert_contains "$(launch_line "$SEND_LOG")" "$prompt" \
    "the launch command did not read the claim prompt"
  assert_not_contains "$(launch_line "$SEND_LOG")" "data/$id/brief.md" \
    "the launch command still read the brief instead of the claim prompt"
  assert_grep 'claim_prompt=on' "$HOME_DIR/state/$id.meta" \
    "the launch shape was not durably recorded"

  # The encoding contract is untouched: still one `encode launch-brief` read.
  assert_contains "$(launch_line "$SEND_LOG")" 'encode launch-brief' \
    "the operational-input encoding contract changed"
  pass "with the gate open the launch reads the claim prompt, and the encoding contract is unchanged"
}

test_off_restores_exactly_the_previous_launch() {
  local id_off=claim-cmp-off-z2 id_on=claim-cmp-on-z2 rec off_line on_line off_n on_n
  # Both spawns run in the SAME home, one flag apart, so the launch lines differ
  # only where this feature is allowed to change them. Anything else that moved
  # would show up in the normalized comparison below.
  rec=$(make_spawn_case cmp "$id_off"); read_spawn_record "$rec"

  PARLAY_RC=0 run_case_spawn "$id_off" --beads task-wgos >/dev/null
  off_line=$(launch_line "$SEND_LOG")
  assert_absent "$HOME_DIR/data/$id_off/claim-prompt.md" \
    "a default-off spawn wrote a claim prompt"
  assert_no_grep 'claim_prompt=' "$HOME_DIR/state/$id_off.meta" \
    "a default-off spawn recorded a claim_prompt line - meta is not byte-identical"
  assert_contains "$off_line" "data/$id_off/brief.md" \
    "the default-off launch did not read the brief"

  mkdir -p "$HOME_DIR/data/$id_on"
  printf 'brief for %s\n' "$id_on" > "$HOME_DIR/data/$id_on/brief.md"
  printf 'on\n' > "$HOME_DIR/config/spawn-claim-prompt"
  : > "$SEND_LOG"
  PARLAY_RC=0 run_case_spawn "$id_on" --beads task-wgos >/dev/null
  on_line=$(launch_line "$SEND_LOG")

  # Normalize the two axes that MUST differ - the task id and which file in the
  # task's own data dir the prompt is read from - and require the rest to match
  # byte for byte: same binary, same flags, same env prefixes, same quoting,
  # same `encode launch-brief` read.
  off_n=${off_line//$id_off/TASKID}; off_n=${off_n//brief.md/PROMPT}
  on_n=${on_line//$id_on/TASKID};    on_n=${on_n//claim-prompt.md/PROMPT}
  assert_eq "$off_n" "$on_n" \
    "turning the claim prompt on changed more of the launch than which file it reads"
  pass "the flag off launches exactly as before, and on changes nothing but the file the prompt is read from"
}

test_a_degraded_gate_launches_the_brief() {
  local rec id
  # Flag ON for all three, so the ONLY thing keeping each on the brief is the
  # degrade condition itself - the property the optional path rests on.
  local case_name
  for case_name in nobead unreachable noparlay; do
    id="claim-deg-$case_name-z3"
    rec=$(make_spawn_case "deg-$case_name" "$id"); read_spawn_record "$rec"
    printf 'on\n' > "$HOME_DIR/config/spawn-claim-prompt"
    case "$case_name" in
      nobead)      PARLAY_RC=0 run_case_spawn "$id" >/dev/null ;;
      unreachable) PARLAY_RC=1 run_case_spawn "$id" --beads task-wgos >/dev/null ;;
      noparlay)    PARLAY_RC='' run_case_spawn "$id" --beads task-wgos >/dev/null ;;
    esac
    assert_absent "$HOME_DIR/data/$id/claim-prompt.md" \
      "$case_name did not degrade: a claim prompt was written"
    assert_contains "$(launch_line "$SEND_LOG")" "data/$id/brief.md" \
      "$case_name did not degrade: the launch did not read the brief"
    assert_no_grep 'claim_prompt=' "$HOME_DIR/state/$id.meta" \
      "$case_name recorded a claim_prompt line despite degrading"
  done
  pass "no bead, an unreachable server, and an absent parlay each launch the brief with the flag still on"
}

test_the_flag_is_off_unless_it_says_exactly_on
test_every_degrade_condition_falls_back_to_the_brief
test_an_unreachable_probe_cannot_hang_a_spawn
test_the_probe_is_skipped_without_a_bounded_runner
test_the_claim_prompt_never_loses_the_brief
test_a_prompt_that_cannot_be_written_is_a_failure_not_a_half_file
test_the_launch_reads_the_claim_prompt_when_the_gate_opens
test_off_restores_exactly_the_previous_launch
test_a_degraded_gate_launches_the_brief
echo "# all fm-claim-prompt tests passed"
