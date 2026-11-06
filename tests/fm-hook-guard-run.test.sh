#!/usr/bin/env bash
# Behavior tests for the tracked guard-hook launcher: a guard script that is
# missing or cannot be parsed (merge conflict markers) passes through with a
# one-line warning, while a guard that runs and denies still denies.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-hook-guard-run-tests)
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
MARKER="$TMP_ROOT/marker"
QUIET_HOME="$TMP_ROOT/quiet-home"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"true"}}'
GUARDS='fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-subagent-pretool-check.sh fm-question-tool-pretool-check.sh fm-turnend-guard.sh'
TRACKED_SETTINGS="$ROOT/.claude/settings.json"

# A worktree whose bin/ holds the real launcher, with stub guard scripts
# standing in for the real guards.
make_worktree() {  # <dir>
  local dir=$1 script
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-hook-guard-run.sh" "$dir/bin/"
  for script in $GUARDS; do
    printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$dir/bin/$script"
    chmod +x "$dir/bin/$script"
  done
}

# Runs the tracked settings command that invokes <script> from <worktree>.
run_tracked() {  # <worktree> <script> [stdin]
  local cmd
  cmd=$(jq -r --arg s "$2" '.hooks[][].hooks[].command | select(contains($s))' "$TRACKED_SETTINGS")
  [ -n "$cmd" ] || fail "no tracked settings command invokes $2"
  printf '%s' "${3-}" | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$1" bash -c "$cmd" > "$OUT" 2> "$ERR"
}

conflicted_guard() {  # <path>
  printf '#!/usr/bin/env bash\n<<<<<<< HEAD\necho ours\n=======\necho theirs\n>>>>>>> origin/main\nexit 2\n' > "$1"
}

test_conflict_markers_pass_through_for_every_tracked_guard() {
  local wt="$TMP_ROOT/conflicted" script rc
  make_worktree "$wt"
  for script in $GUARDS; do
    conflicted_guard "$wt/bin/$script"
    ! bash -n "$wt/bin/$script" 2>/dev/null || fail "fixture for $script must not parse"
    rc=0
    run_tracked "$wt" "$script" '{"tool_name":"Bash"}' || rc=$?
    [ "$rc" -eq 0 ] || fail "$script with conflict markers must pass through, got exit $rc: $(cat "$ERR")"
    [ "$(wc -l < "$ERR" | tr -d ' ')" -eq 1 ] || fail "$script must warn with exactly one stderr line: $(cat "$ERR")"
    assert_contains "$(cat "$ERR")" "$script"
  done
  pass "tracked guards with conflict markers pass through with a one-line warning"
}

test_missing_guard_passes_through() {
  local wt="$TMP_ROOT/missing" rc=0
  make_worktree "$wt"
  rm "$wt/bin/fm-subagent-pretool-check.sh"
  run_tracked "$wt" fm-subagent-pretool-check.sh '{}' || rc=$?
  [ "$rc" -eq 0 ] || fail "missing guard must pass through, got exit $rc"
  assert_contains "$(cat "$ERR")" "missing"
  pass "a missing guard passes through"
}

test_genuine_deny_still_denies() {
  local wt="$TMP_ROOT/deny" rc=0
  make_worktree "$wt"
  # shellcheck disable=SC2016 # the guard body is a literal script, expanded when it runs
  printf '#!/usr/bin/env bash\nread -r payload\nprintf "denied:%%s:%%s\\n" "$1" "$payload" >&2\nexit 2\n' \
    > "$wt/bin/fm-subagent-pretool-check.sh"
  run_tracked "$wt" fm-subagent-pretool-check.sh 'PAYLOAD' || rc=$?
  [ "$rc" -eq 2 ] || fail "a parsing guard that denies must exit 2, got $rc"
  assert_contains "$(cat "$ERR")" "denied:--claude:PAYLOAD"
  pass "a guard that runs and denies still denies, with args and stdin intact"
}

# Every tracked harness hook command, not only the Claude guards above.
# A command that never reaches fm-hook-guard-run.sh fails this test.
tracked_hook_commands() {
  jq -r '.hooks[][]?.hooks[]?.command // empty' "$ROOT/.claude/settings.json"
  jq -r '.hooks[][]?.hooks[]?.command // empty' "$ROOT/.codex/hooks.json"
  jq -r '.hooks[][]?.command // empty' "$ROOT/.cursor/hooks.json"
  jq -r '.[] | (.SessionStart // empty)[]?.command, (.Stop // empty)[]?.command, (.PreToolUse // empty)[]?.hooks[]?.command' \
    "$ROOT/.agents/hooks.json"
  local grok
  for grok in "$ROOT"/.grok/hooks/*.json; do
    jq -r '.hooks[][]?.hooks[]?.command // empty' "$grok"
  done
}

hook_target() {  # <command> -> basename the command actually execs when only that file exists
  printf '%s\n' "$1" | sed -n 's/.*fm-hook-guard-run\.sh["\\ ]*\([a-zA-Z0-9_.-]*\.sh\).*/\1/p' | tail -n 1
}

# Antigravity's registration ends in `|| cd .`, so a refusing script's exit 2
# becomes 0 at the hook command. The script still ran; that is the block signal
# those hooks already use (a decision on stdout, exit 0).
expect_refusal_status() {  # <command> <actual>
  if printf '%s\n' "$1" | grep -q '|| cd \.'; then
    [ "$2" -eq 0 ]
  else
    [ "$2" -eq 2 ]
  fi
}

run_hook_command() {  # <worktree> <command>
  local wt=$1 cmd=$2 rc=0
  if printf '%s\n' "$cmd" | grep -q 'CLAUDE_PROJECT_DIR'; then
    printf '%s' "$PAYLOAD" | env -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME \
      -u GROK_SESSION_ID -u GROK_WORKSPACE_ROOT \
      HOME="$QUIET_HOME" BASH_ENV='' ENV='' CLAUDE_PROJECT_DIR="$wt" MARKER="$MARKER" \
      bash -c "$cmd" >"$OUT" 2>"$ERR" || rc=$?
  elif printf '%s\n' "$cmd" | grep -q 'CURSOR_PROJECT_DIR'; then
    printf '%s' "$PAYLOAD" | env HOME="$QUIET_HOME" BASH_ENV='' ENV='' \
      CURSOR_PROJECT_DIR="$wt" MARKER="$MARKER" \
      bash -c "$cmd" >"$OUT" 2>"$ERR" || rc=$?
  elif printf '%s\n' "$cmd" | grep -q 'GROK_WORKSPACE_ROOT'; then
    printf '%s' "$PAYLOAD" | env HOME="$QUIET_HOME" BASH_ENV='' ENV='' \
      GROK_WORKSPACE_ROOT="$wt" MARKER="$MARKER" \
      bash -c "$cmd" >"$OUT" 2>"$ERR" || rc=$?
  else
    printf '%s' "$PAYLOAD" | (
      cd "$wt" || exit 99
      env HOME="$QUIET_HOME" BASH_ENV='' ENV='' MARKER="$MARKER" bash -c "$cmd"
    ) >"$OUT" 2>"$ERR" || rc=$?
  fi
  printf '%s\n' "$rc"
}

prepare_hook_root() {  # <worktree>
  local wt=$1
  rm -rf "${wt:?}/bin"
  mkdir -p "$wt/bin" "$wt/.codex"
  cp "$ROOT/bin/fm-hook-guard-run.sh" "$wt/bin/fm-hook-guard-run.sh"
  chmod +x "$wt/bin/fm-hook-guard-run.sh"
  cp "$ROOT/.codex/hooks.json" "$wt/.codex/hooks.json"
  printf '# fixture\n' > "$wt/AGENTS.md"
}

test_every_tracked_hook_command_steps_aside_or_preserves_refusal() {
  local wt="$TMP_ROOT/all-hooks" cmd target rc n=0
  command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
  mkdir -p "$wt" "$QUIET_HOME"
  prepare_hook_root "$wt"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    target=$(hook_target "$cmd")
    [ -n "$target" ] || fail "tracked hook command does not run through fm-hook-guard-run.sh: $cmd"
    n=$((n + 1))

    conflicted_guard "$wt/bin/$target"
    chmod +x "$wt/bin/$target"
    ! bash -n "$wt/bin/$target" 2>/dev/null || fail "fixture for $target must not parse"
    rm -f "$MARKER"
    rc=$(run_hook_command "$wt" "$cmd")
    [ "$rc" -eq 0 ] || fail "$target with conflict markers must not block, got exit $rc stderr=$(cat "$ERR") cmd=$cmd"
    [ ! -e "$MARKER" ] || fail "$target with conflict markers must not run"
    assert_contains "$(cat "$ERR")" "$target" "$target conflict warning must name the script"
    assert_contains "$(cat "$ERR")" "does not parse" "$target conflict warning must say it does not parse"

    # shellcheck disable=SC2016 # the guard body is a literal script, expanded when it runs
    cat > "$wt/bin/$target" <<'EOF'
#!/usr/bin/env bash
cat > "${MARKER:?}"
printf 'denied\n' >&2
exit 2
EOF
    chmod +x "$wt/bin/$target"
    rm -f "$MARKER"
    rc=$(run_hook_command "$wt" "$cmd")
    expect_refusal_status "$cmd" "$rc" || fail "$target refusal was swallowed: exit $rc stderr=$(cat "$ERR") cmd=$cmd"
    [ -e "$MARKER" ] || fail "$target that parses must still run: stderr=$(cat "$ERR") cmd=$cmd"
    assert_equals "$PAYLOAD" "$(cat "$MARKER")" "$target must see the hook payload on stdin"
    assert_contains "$(cat "$ERR")" "denied" "$target refusal text must reach the hook"
    rm -f "$wt/bin/$target"
  done < <(tracked_hook_commands)
  [ "$n" -ge 20 ] || fail "expected every tracked hook config, saw $n commands"
  pass "every tracked hook command steps aside on conflict markers and still runs a refusing script ($n commands)"
}

# The remaining primary harnesses invoke their guards from plugin and extension
# code rather than a JSON hook command. Exercise their public hook callbacks
# against a broken and then a refusing turn-end guard.
test_plugin_and_extension_turnend_guards_step_aside_or_preserve_refusal() {
  local harness repo home ext out status
  for harness in opencode pi omp; do
    repo="$TMP_ROOT/$harness-hook-root"
    home="$TMP_ROOT/$harness-hook-home"
    mkdir -p "$repo/bin" "$home/state"
    cp "$ROOT/bin/fm-hook-guard-run.sh" "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
    chmod +x "$repo/bin/"*.sh
    case "$harness" in
      opencode)
        mkdir -p "$repo/.opencode"
        cp -R "$ROOT/.opencode/plugins" "$repo/.opencode/"
        ext="$repo/.opencode/plugins/fm-primary-turnend-guard.js"
        ;;
      pi)
        mkdir -p "$repo/.pi/extensions/lib"
        cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/"
        cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/"
        ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
        ;;
      omp)
        mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib"
        cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$repo/.omp/extensions/"
        cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/"
        ext="$repo/.omp/extensions/fm-primary-turnend-guard.ts"
        ;;
    esac

    conflicted_guard "$repo/bin/fm-turnend-guard.sh"
    chmod +x "$repo/bin/fm-turnend-guard.sh"
    out=$(HARNESS="$harness" EXT="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
let prompts = 0;
const api = {
  on(name, handler) { handlers.set(name, handler); },
  sendUserMessage() { prompts += 1; },
};
const harness = process.env.HARNESS;
if (harness === "opencode") {
  const mod = await import(pathToFileURL(process.env.EXT).href);
  const hooks = await mod.FmPrimaryTurnendGuard({
    directory: process.env.FM_HOME,
    worktree: process.env.FM_HOME.replace(/-home$/, "-root"),
    client: { session: { promptAsync: async () => { prompts += 1; } } },
  });
  await hooks.event({ event: { type: "session.idle", properties: { sessionID: "s" } } });
} else {
  const mod = await import(pathToFileURL(process.env.EXT).href);
  mod.default(api);
  if (harness === "pi") await handlers.get("agent_settled")({}, {});
  else {
    const result = await handlers.get("session_stop")({ stop_hook_active: false }, {});
    if (result !== undefined) throw new Error("broken omp guard blocked the hook");
  }
}
if (prompts !== 0) throw new Error(`broken ${harness} guard prompted ${prompts} times`);
EOF
)
    status=$?
    expect_code 0 "$status" "$harness syntax-broken turn-end guard must step aside: $out"

    printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "denied\\n" >&2\nexit 2\n' > "$repo/bin/fm-turnend-guard.sh"
    chmod +x "$repo/bin/fm-turnend-guard.sh"
    out=$(HARNESS="$harness" EXT="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
let prompts = 0;
const api = {
  on(name, handler) { handlers.set(name, handler); },
  sendUserMessage() { prompts += 1; },
};
const harness = process.env.HARNESS;
if (harness === "opencode") {
  const mod = await import(pathToFileURL(process.env.EXT).href);
  const hooks = await mod.FmPrimaryTurnendGuard({
    directory: process.env.FM_HOME,
    worktree: process.env.FM_HOME.replace(/-home$/, "-root"),
    client: { session: { promptAsync: async () => { prompts += 1; } } },
  });
  await hooks.event({ event: { type: "session.idle", properties: { sessionID: "s" } } });
  if (prompts !== 1) throw new Error(`refusing opencode guard prompted ${prompts} times`);
} else {
  const mod = await import(pathToFileURL(process.env.EXT).href);
  mod.default(api);
  if (harness === "pi") {
    await handlers.get("agent_settled")({}, {});
    if (prompts !== 1) throw new Error(`refusing pi guard prompted ${prompts} times`);
  } else {
    const result = await handlers.get("session_stop")({ stop_hook_active: false }, {});
    if (result?.continue !== true) throw new Error(`refusing omp guard did not block: ${JSON.stringify(result)}`);
  }
}
EOF
)
    status=$?
    expect_code 0 "$status" "$harness parsing refusing turn-end guard must still block: $out"
  done
  pass "OpenCode, Pi, and omp turn-end hooks step aside only for broken guards"
}

test_conflict_markers_pass_through_for_every_tracked_guard
test_missing_guard_passes_through
test_genuine_deny_still_denies
test_every_tracked_hook_command_steps_aside_or_preserves_refusal
test_plugin_and_extension_turnend_guards_step_aside_or_preserve_refusal
