#!/usr/bin/env bash
# fm-send from-firstmate marker for secondmate targets.
#
# A secondmate is itself a firstmate, so a request relayed to it lands in its own
# chat - which the main firstmate never reads (the only channel back is the terse
# status file). fm-send therefore prepends a from-firstmate marker
# (bin/fm-marker-lib.sh) when, and only when, the resolved target is a task
# selector whose meta records kind=secondmate, so the secondmate can recognize
# the request and route its reply via the status path. These tests pin that
# behavior hermetically (stubbed tmux, no real agent):
#   1. Exact-id and stable-label kind=secondmate selectors prepend the marker.
#   2. Exact-id and stable-label ordinary crewmate selectors stay unmarked.
#   3. Explicit endpoints stay unmarked, with or without matching local meta.
#   4. The --key path never carries the marker.
#   5. Direct captain text stays unmarked, and already-marked text is idempotent.
#   6. The marker is the label plus terminal-safe U+2063 INVISIBLE SEPARATOR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-marker)

# A fake tmux that (a) records the literal text of every `send-keys -l` to
# FM_SEND_LOG and (b) lets fm-send's submit path reach a clean "empty" verdict.
# display-message yields a numeric cursor_y; capture-pane returns an empty
# bordered composer so fm_tmux_composer_state reads "empty" (submit landed) on the
# first Enter. Only the literal (-l) text is logged; Enter retries and --key sends
# are not, so the log holds exactly what was typed into the composer.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> -- <fm-send args...>
# Runs fm-send.sh with the stubs on PATH against the given home (which holds
# state/<id>.meta). FM_ROOT_OVERRIDE points at the same non-repo home so
# fm-guard's tangle check stays silent; guard noise goes to stderr (discarded).
# FM_SEND_SETTLE=0 keeps the run fast. Truncates the log first; returns fm-send's
# exit code.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

# setup_home <name> -> echoes a fresh home dir with an empty state/.
setup_home() {
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# Same as run_send but prints fm-send's stderr (the refusal diagnostic) and
# preserves its exit code, so a refusal can be asserted on both.
run_send_err() {
  local fb=$1 home=$2 log=$3; shift 3
  local errfile="$log.err" rc=0
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" >/dev/null 2>"$errfile" || rc=$?
  cat "$errfile"
  return "$rc"
}

test_marked_slash_command_is_refused() {
  local dir fb log home rc err marked
  dir="$TMP_ROOT/slash"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home slash)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"

  # The carrier sits at column 0, so the harness would read '/exit' as prose and
  # never run it. A verified submit plus a pending-reply expectation for a command
  # that did not execute is the exact silent failure this refusal exists to stop.
  err=$(run_send_err "$fb" "$home" "$log" "fm-domain" "/exit"); rc=$?
  expect_code 1 "$rc" "a slash command to a secondmate should be refused"
  [ ! -s "$log" ] || fail "refused slash command still typed text into the composer"$'\n'"$(od -An -c "$log")"
  assert_contains "$err" "/exit" "refusal should name the slash command"
  assert_contains "$err" "$FM_FROMFIRST_LABEL" "refusal should name the carrier as the cause"
  assert_contains "$err" "fm-teardown.sh" "refusal should name the close path"
  [ -z "$(ls -A "$home/state/pending-replies" 2>/dev/null)" ] \
    || fail "refused slash command left a pending-reply expectation behind"

  # A command with arguments is refused on the verb alone.
  err=$(run_send_err "$fb" "$home" "$log" "domain" "/compact keep the build notes"); rc=$?
  expect_code 1 "$rc" "an argument-bearing slash command should be refused"
  assert_contains "$err" "/compact" "refusal should name the verb"
  assert_not_contains "$err" "keep the build notes" "refusal should not echo the whole body"

  # An already marked+correlated recovery resend is judged on its BODY, not its
  # carrier, so the same command cannot slip through the resend path.
  marked="${FM_FROMFIRST_MARK}corr=0123456789abcdef /exit"
  err=$(run_send_err "$fb" "$home" "$log" "domain" "$marked"); rc=$?
  expect_code 1 "$rc" "an already-marked slash command resend should be refused"
  assert_contains "$err" "/exit" "resend refusal should name the slash command"
  [ ! -s "$log" ] || fail "refused marked resend still typed text into the composer"
  pass "fm-send: a slash command to a marked secondmate is refused, not silently sent as prose"
}

test_marked_slash_lookalikes_still_send() {
  local dir fb log home rc got
  dir="$TMP_ROOT/slash-lookalike"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home slash-lookalike)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"

  # Only a body whose FIRST character is the slash can be a command. Prose that
  # merely contains or is indented before one is ordinary text and must still go.
  run_send "$fb" "$home" "$log" "fm-domain" "see /Users/x/log for the failure"; rc=$?
  expect_code 0 "$rc" "prose containing a path should still send"
  got=$(cat "$log")
  case "$got" in
    *"see /Users/x/log for the failure") : ;;
    *) fail "prose containing a path was altered"$'\n'"$got" ;;
  esac

  run_send "$fb" "$home" "$log" "fm-domain" " /exit is what I typed"; rc=$?
  expect_code 0 "$rc" "leading-blank prose should still send"
  pass "fm-send: only a leading-slash body is refused; slash-bearing prose is unaffected"
}

test_marked_codex_skill_command_is_refused() {
  local dir fb log home rc err marked
  dir="$TMP_ROOT/codex-skill"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home codex-skill)
  # codex invokes a skill with '$<skill>' (SKILL.md), so a marked '$no-mistakes'
  # hits the same column-0 carrier demotion as '/exit': read as prose, never run.
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain" alpha codex

  err=$(run_send_err "$fb" "$home" "$log" "fm-domain" "\$no-mistakes"); rc=$?
  expect_code 1 "$rc" "a codex skill command to a secondmate should be refused"
  [ ! -s "$log" ] || fail "refused codex skill command still typed text into the composer"$'\n'"$(od -An -c "$log")"
  assert_contains "$err" "\$no-mistakes" "refusal should name the codex skill command"
  assert_contains "$err" "$FM_FROMFIRST_LABEL" "refusal should name the carrier as the cause"
  assert_contains "$err" "fm-teardown.sh" "refusal should name the close path"
  [ -z "$(ls -A "$home/state/pending-replies" 2>/dev/null)" ] \
    || fail "refused codex skill command left a pending-reply expectation behind"

  # A skill command with arguments is refused on the verb alone.
  err=$(run_send_err "$fb" "$home" "$log" "domain" "\$no-mistakes fix the build"); rc=$?
  expect_code 1 "$rc" "an argument-bearing codex skill command should be refused"
  assert_contains "$err" "\$no-mistakes" "refusal should name the verb"
  assert_not_contains "$err" "fix the build" "refusal should not echo the whole body"

  # An already marked+correlated recovery resend is judged on its BODY, not its
  # carrier, so the same command cannot slip through the resend path.
  marked="${FM_FROMFIRST_MARK}corr=0123456789abcdef \$no-mistakes"
  err=$(run_send_err "$fb" "$home" "$log" "domain" "$marked"); rc=$?
  expect_code 1 "$rc" "an already-marked codex skill command resend should be refused"
  assert_contains "$err" "\$no-mistakes" "resend refusal should name the codex skill command"
  [ ! -s "$log" ] || fail "refused marked codex resend still typed text into the composer"
  pass "fm-send: a codex '\$<skill>' to a marked secondmate is refused, not silently sent as prose"
}

test_marked_dollar_prose_and_noncodex_still_send() {
  local dir fb log home rc got
  dir="$TMP_ROOT/dollar-prose"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"

  # A leading '$' before a non-skill token (a price, an env var) is ordinary
  # codex prose, not a skill invocation, so the codex refusal must not fire.
  home=$(setup_home dollar-codex-prose)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain" alpha codex
  run_send "$fb" "$home" "$log" "fm-domain" "\$5/month is cheap"; rc=$?
  expect_code 0 "$rc" "a codex '\$5' price to a secondmate should still send"
  got=$(cat "$log")
  case "$got" in
    *"\$5/month is cheap") : ;;
    *) fail "codex '\$5' price was altered or dropped"$'\n'"$got" ;;
  esac
  run_send "$fb" "$home" "$log" "fm-domain" "\$HOME is unset"; rc=$?
  expect_code 0 "$rc" "a codex '\$HOME' env-var mention to a secondmate should still send"

  # The refusal is codex-scoped: on claude a leading '$' only ever starts prose,
  # so even a skill-shaped '$no-mistakes' body must be delivered, not refused.
  home=$(setup_home dollar-claude)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain" alpha claude
  run_send "$fb" "$home" "$log" "fm-domain" "\$no-mistakes"; rc=$?
  expect_code 0 "$rc" "a '\$no-mistakes' body to a non-codex secondmate should still send"
  got=$(cat "$log")
  case "$got" in
    *"\$no-mistakes") : ;;
    *) fail "non-codex '\$no-mistakes' body was altered or dropped"$'\n'"$got" ;;
  esac
  pass "fm-send: only a codex '\$<skill>' body is refused; '\$' prose and non-codex '\$' bodies send"
}

test_unmarked_targets_still_accept_slash_commands() {
  local dir fb log home rc got
  dir="$TMP_ROOT/slash-unmarked"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home slash-unmarked)
  fm_write_meta "$home/state/build.meta" \
    "window=sess:fm-build" "worktree=$home/wt" "project=$home/p" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"

  # The refusal is scoped to the marked path. A crewmate never carries the
  # carrier, so '/no-mistakes' still reaches its composer at column 0.
  run_send "$fb" "$home" "$log" "fm-build" "/no-mistakes"; rc=$?
  expect_code 0 "$rc" "a slash command to a crewmate should still send"
  got=$(cat "$log")
  [ "$got" = "/no-mistakes" ] || fail "crewmate slash command was altered"$'\n'"$got"

  # The explicit-endpoint escape hatch is likewise never marked, so it remains
  # the way to drive a secondmate's own harness directly.
  fm_write_secondmate_meta "$home/state/win.meta" "$home" "other:win"
  run_send "$fb" "$home" "$log" "other:win" "/exit"; rc=$?
  expect_code 0 "$rc" "a slash command to an explicit endpoint should still send"
  got=$(cat "$log")
  [ "$got" = "/exit" ] || fail "explicit-endpoint slash command was altered"$'\n'"$got"
  pass "fm-send: crewmate and explicit-endpoint slash commands are unaffected by the refusal"
}

test_secondmate_target_is_marked() {
  local dir fb log home rc got corr
  dir="$TMP_ROOT/sm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "fm-domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to a secondmate target should succeed"
  got=$(cat "$log")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=[a-f0-9][a-f0-9]*) : ;;
    *) fail "secondmate send: literal text should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  case "$got" in
    *audit\ the\ build) : ;;
    *) fail "secondmate send lost the request body"$'\n'"$got" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$got")
  [ -f "$(fm_pending_reply_path "$home/state" "$corr")" ] \
    || fail "marked secondmate send should create a parent pending-reply record"
  pass "fm-send: a kind=secondmate target gets the from-firstmate marker and corr prepended"
}

test_exact_secondmate_task_id_is_marked() {
  local dir fb log home rc got already_marked corr
  dir="$TMP_ROOT/sm-exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-exact)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to an exact secondmate task id should succeed"
  got=$(cat "$log")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=[a-f0-9]*) : ;;
    *) fail "exact secondmate send: literal text should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$got")
  # Resend with the same corr already present: embed is idempotent for that corr.
  already_marked="${FM_FROMFIRST_MARK}corr=${corr} already routed"
  run_send "$fb" "$home" "$log" "domain" "$already_marked"; rc=$?
  expect_code 0 "$rc" "send of already-marked exact-id content should succeed"
  got=$(cat "$log")
  case "$got" in
    "${FM_FROMFIRST_MARK}corr=${corr} already routed") : ;;
    *) fail "exact secondmate send altered already-correlated content"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -tx1)" ;;
  esac
  pass "fm-send: an exact kind=secondmate task id is marked with corr exactly once"
}

test_crewmate_target_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/crew"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home crew)
  fm_write_meta "$home/state/build.meta" \
    "window=sess:fm-build" "worktree=$home/wt" "project=$home/p" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  run_send "$fb" "$home" "$log" "fm-build" "fix the test"; rc=$?
  expect_code 0 "$rc" "send to a stable-label crewmate target should succeed"
  got=$(cat "$log")
  [ "$got" = "fix the test" ] \
    || fail "stable-label crewmate send: expected bare text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  run_send "$fb" "$home" "$log" "build" "fix the exact test"; rc=$?
  expect_code 0 "$rc" "send to an exact-id crewmate target should succeed"
  got=$(cat "$log")
  [ "$got" = "fix the exact test" ] \
    || fail "exact-id crewmate send: expected bare text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "fm-send: exact-id and stable-label kind=ship selectors are sent unmarked"
}

test_explicit_window_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home explicit)
  # An explicit endpoint is not a task selector, so even matching secondmate
  # metadata must not make fm-send guess the caller's intent and mark it.
  fm_write_secondmate_meta "$home/state/win.meta" "$home" "other:win"
  run_send "$fb" "$home" "$log" "other:win" "ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with matching meta should succeed"
  got=$(cat "$log")
  [ "$got" = "ping" ] \
    || fail "explicit session:window send with meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"

  home=$(setup_home explicit-no-meta)
  run_send "$fb" "$home" "$log" "outside:window" "outside ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with no local meta should succeed"
  got=$(cat "$log")
  [ "$got" = "outside ping" ] \
    || fail "explicit session:window send without meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "fm-send: explicit endpoints stay unmarked with or without local metadata"
}

test_key_path_is_not_marked() {
  local dir fb log home rc
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home key)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "fm-domain" --key Escape; rc=$?
  expect_code 0 "$rc" "--key send to a secondmate should succeed"
  [ ! -s "$log" ] \
    || fail "--key path logged a literal send (marker leaked into a keypress)"$'\n'"--- bytes ---"$'\n'"$(od -An -c "$log")"
  pass "fm-send: the --key path carries no marker (no literal text is typed)"
}

test_marker_is_label_plus_invisible_separator() {
  local separator hex
  separator=$(printf '\342\201\243')
  [ "$FM_FROMFIRST_MARK" = "[fm-from-firstmate]$separator" ] \
    || fail "marker is not the expected label + U+2063 sequence"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$FM_FROMFIRST_MARK" | od -An -tx1)"
  hex=$(printf '%s' "$FM_FROMFIRST_MARK" | od -An -tx1 | tr -d ' \n')
  case "$hex" in
    *e281a3) : ;;
    *) fail "marker does not end in UTF-8 U+2063 bytes e2 81 a3; bytes were: $hex" ;;
  esac
  fm_message_from_firstmate "${FM_FROMFIRST_MARK}do the work" \
    || fail "detector should recognize a marked message"
  fm_message_from_firstmate "do the work" \
    && fail "direct captain input must remain unmarked"
  fm_message_from_firstmate "[fm-from-firstmate]do the work" \
    && fail "detector must reject the label without U+2063"
  pass "fm-send: the marker is '[fm-from-firstmate]' + terminal-safe U+2063, while direct captain text stays unmarked"
}

test_marker_transformation_is_idempotent() {
  local once twice
  fm_message_mark_from_firstmate "do the work" once
  fm_message_mark_from_firstmate "$once" twice
  [ "$once" = "$twice" ] \
    || fail "already-marked content was double-prefixed"$'\n'"--- once ---"$'\n'"$(printf '%s' "$once" | od -An -tx1)"$'\n'"--- twice ---"$'\n'"$(printf '%s' "$twice" | od -An -tx1)"
  [ "$once" = "${FM_FROMFIRST_MARK}do the work" ] \
    || fail "marker transformation did not prefix bare content exactly once"
  pass "fm-marker: from-firstmate transformation is idempotent"
}

test_marked_send_preserves_trailing_newlines() {
  local dir fb log home rc payload got_hex body_hex corr
  dir="$TMP_ROOT/sm-trailing-newlines"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-trailing-newlines)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  payload=$'audit the build\n\n'
  run_send "$fb" "$home" "$log" "domain" "$payload"; rc=$?
  expect_code 0 "$rc" "marked send with trailing newlines should succeed"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$(cat "$log")")
  [ -n "$corr" ] || fail "marked send should embed a corr id"
  # Body after marker+corr+space must preserve the original trailing newlines.
  body_hex=$(printf '%s' "$payload" | od -An -tx1 | tr -d ' \n')
  got_hex=$(od -An -tx1 "$log" | tr -d ' \n')
  case "$got_hex" in
    *"$body_hex") : ;;
    *) fail "marked send lost trailing newline body bytes: got $got_hex expected to end with $body_hex" ;;
  esac
  pass "fm-send: marked secondmate payload preserves trailing newline bytes"
}

test_secondmate_target_is_marked
test_exact_secondmate_task_id_is_marked
test_marked_slash_command_is_refused
test_marked_slash_lookalikes_still_send
test_marked_codex_skill_command_is_refused
test_marked_dollar_prose_and_noncodex_still_send
test_unmarked_targets_still_accept_slash_commands
test_crewmate_target_is_not_marked
test_explicit_window_is_not_marked
test_key_path_is_not_marked
test_marker_is_label_plus_invisible_separator
test_marker_transformation_is_idempotent
test_marked_send_preserves_trailing_newlines
