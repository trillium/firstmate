#!/usr/bin/env bash
# fm-urgent.sh - launch, track, and close ONE captain-facing interactive
# "Urgency Agent" pane for an ask that cannot wait for the normal brief ->
# spawn -> report cycle (docs/urgency-protocol.md owns the design and the
# measured latencies; .agents/skills/urgent/SKILL.md owns when firstmate runs it).
#
# Usage:
#   fm-urgent.sh <slug> [--harness claude|pi] [--idle-timeout <duration>]
#                [--cwd <dir>] [--out <dir>] [--grant "<one-line authority>"]
#                [--context <text-or-file>] -- <captain's ask text or file>
#   fm-urgent.sh done <slug> [--force]   the captain's explicit completion
#   fm-urgent.sh list                    every recorded session, live or closed
#   fm-urgent.sh status <slug>           one session: state, idle deadline, watcher
#   fm-urgent.sh rearm <slug>            restart a dead idle watcher for a live session
#   fm-urgent.sh duration <spec>         print <spec> (90s|30m|10h|2d|bare seconds) in seconds
#
# Launch opens exactly one new pane (a Herdr tab labelled urgent:<slug> in the
# launcher's own workspace of the default session, or a tmux window when Herdr
# is not the resolved backend) running the harness interactively. The first
# prompt carries the ask, the context firstmate passed, and the authority grant;
# the standing role (hands-on worker, native sub-agents preauthorized, no
# firstmate briefs, out-of-grant asks the captain) rides the system prompt. The
# launch never writes a brief, never spawns a firstmate-managed worker, and never
# falls back to one: any failure exits non-zero with ONE plain-English line on
# stderr that firstmate relays. Exit codes: 0 ok, 1 cannot launch/close, 2 usage,
# 3 `done` refused because the agent is mid-turn (re-run with --force).
#
# Pane operations are limited to: open one tab/window, type into it, read it, and
# close the pane this script itself recorded. No session, server, or workspace
# lifecycle command is ever issued here.
#
# Claude Code is launched with --permission-mode acceptEdits plus a per-session
# --settings file (state/urgent/<slug>/claude-settings.json) preapproving the
# in-scope tools, native sub-agents (Agent/Task), and common local tooling, and
# denying pushes, recursive deletes, sudo, and merges. Nothing in the captain's
# own settings is edited. Pi is launched only when `pi list` shows an installed
# sub-agent package; otherwise the launch stops with that exact reason.
#
# Record: state/urgent/<slug>/{record,prompt.md,role.md,launch.sh,activity,
# watcher.pid,watcher.log,claude-settings.json}. The idle watcher is a small
# detached loop started by this script (no launchd): it closes the pane only
# after <idle-timeout> of unchanged screen, never while the agent is busy, and
# only after preserving the output dir and a transcript pointer under
# data/urgent/<slug>/.
#
# Environment: FM_HOME (state/ and data/ root; default this checkout),
# FM_URGENT_POLL_SECS (watcher period, default 30). Under FM_TEST_SEAM=1 only:
# FM_URGENT_BACKEND=fake with FM_URGENT_FAKE_DIR drives a file-backed pane, and
# FM_URGENT_NOW overrides the epoch clock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE_ROOT="${FM_STATE_OVERRIDE:-$FM_HOME/state}/urgent"
DATA_ROOT="${FM_DATA_OVERRIDE:-$FM_HOME/data}/urgent"
POLL_SECS="${FM_URGENT_POLL_SECS:-30}"
DEFAULT_IDLE="10h"
# Default working and output area: outside any repository, so the pane never inherits
# firstmate's supervisor AGENTS.md. Trusting this one folder once covers every session.
BASE_DIR="${FM_URGENT_BASE:-$HOME/.fm-urgent}"
DEFAULT_GRANT="Work freely inside the working directory and the output dir; run local tooling, install packages into a throwaway environment, research on the web, and use native sub-agents. Do not push, publish, send messages, spend money, or delete or change anything outside the output dir without the captain's word in this pane."

die() { echo "fm-urgent: $*" >&2; exit "${2:-1}"; }
usage() { sed -n '2,13p' "$SCRIPT_DIR/fm-urgent.sh" | sed 's/^# \{0,1\}//' >&2; exit 2; }

now() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_URGENT_NOW:-}" ]; then printf '%s' "$FM_URGENT_NOW"; else date +%s; fi
}

# duration_secs: 90s|30m|10h|2d|bare seconds -> seconds; non-zero on garbage or zero.
duration_secs() {
  local spec=$1 n unit
  case "$spec" in
    *[!0-9smhd]* | '' ) return 1 ;;
  esac
  n=${spec%[smhd]}
  unit=${spec#"$n"}
  case "$n" in '' | *[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ] || return 1
  case "$unit" in
    '' | s) printf '%s' "$n" ;;
    m) printf '%s' $((n * 60)) ;;
    h) printf '%s' $((n * 3600)) ;;
    d) printf '%s' $((n * 86400)) ;;
    *) return 1 ;;
  esac
}

valid_slug() { case "$1" in '' | -* | *[!a-z0-9-]*) return 1 ;; esac; [ "${#1}" -le 40 ]; }

rec_get() { # <record> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1
}
rec_set() { # <record> <key> <value>
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  { grep -v "^$2=" "$1" 2>/dev/null || true; printf '%s=%s\n' "$2" "$3"; } >"$tmp"
  mv "$tmp" "$1"
}

# --- pane backend ------------------------------------------------------------
# Every function takes/returns the same opaque target string the record stores.
BACKEND=""

pick_backend() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ "${FM_URGENT_BACKEND:-}" = fake ]; then
    BACKEND=fake
    return 0
  fi
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  case "$(fm_backend_name 2>/dev/null)" in
    herdr)
      if ! command -v herdr >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        die "no interactive window available: the herdr backend is configured but herdr or jq is not installed."
      fi
      BACKEND=herdr
      ;;
    *)
      command -v tmux >/dev/null 2>&1 || die "no interactive window available: neither herdr nor tmux is installed."
      BACKEND=tmux
      ;;
  esac
}

pane_open() { # <label> <cwd> -> prints target
  case "$BACKEND" in
    fake)
      local n d
      d=${FM_URGENT_FAKE_DIR:?}
      mkdir -p "$d/panes"
      n=$(($(find "$d/panes" -mindepth 1 -maxdepth 1 | wc -l) + 1))
      mkdir -p "$d/panes/p$n"
      printf '%s\n' "$1" >"$d/panes/p$n/label"
      printf '%s\n' "$2" >"$d/panes/p$n/cwd"
      : >"$d/panes/p$n/screen"
      printf 'fake:p%s' "$n"
      ;;
    herdr)
      fm_backend_source herdr || return 1
      local session ws status out tab pane
      session=$(fm_backend_herdr_session)
      fm_backend_herdr_launcher_identity "$session" && status=0 || status=$?
      case "$status" in
        0) ws=$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID ;;
        2) ws=$(fm_backend_herdr_workspace_find "$session") ;;
        *) return 1 ;;
      esac
      [ -n "$ws" ] || return 1
      out=$(fm_backend_herdr_cli "$session" tab create --workspace "$ws" --cwd "$2" --label "$1" 2>/dev/null) || return 1
      tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
      pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
      [ -n "$tab" ] && [ -n "$pane" ] || return 1
      printf '%s:%s' "$session" "$pane"
      ;;
    tmux)
      fm_backend_source tmux || return 1
      local ses wid
      ses=$(fm_backend_tmux_container_ensure) || return 1
      wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$1" -c "$2") || return 1
      tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
      tmux select-window -t "$wid" 2>/dev/null || true
      printf '%s' "$wid"
      ;;
  esac
}

pane_type_line() { # <target> <text>
  case "$BACKEND" in
    fake) printf '%s\n' "$2" >>"${FM_URGENT_FAKE_DIR:?}/panes/${1#fake:}/sent" ;;
    herdr) fm_backend_source herdr && fm_backend_herdr_send_text_line "$1" "$2" ;;
    tmux) fm_backend_tmux_send_text_line "$1" "$2" ;;
  esac
}

pane_read() { # <target> <lines>
  case "$BACKEND" in
    fake) tail -n "$2" "${FM_URGENT_FAKE_DIR:?}/panes/${1#fake:}/screen" 2>/dev/null ;;
    *) fm_backend_capture "$BACKEND" "$1" "$2" ;;
  esac
}

pane_exists() { # <target>
  case "$BACKEND" in
    fake) [ -d "${FM_URGENT_FAKE_DIR:?}/panes/${1#fake:}" ] && [ ! -f "${FM_URGENT_FAKE_DIR}/panes/${1#fake:}/closed" ] ;;
    *) fm_backend_target_exists "$BACKEND" "$1" ;;
  esac
}

# pane_busy: busy|idle|unknown. Only herdr has a native verdict; the fake reads a file.
pane_busy() { # <target>
  case "$BACKEND" in
    fake) cat "${FM_URGENT_FAKE_DIR:?}/panes/${1#fake:}/busy" 2>/dev/null || printf 'idle' ;;
    *) fm_backend_busy_state "$BACKEND" "$1" ;;
  esac
}

pane_close() { # <target>
  case "$BACKEND" in
    fake) : >"${FM_URGENT_FAKE_DIR:?}/panes/${1#fake:}/closed" ;;
    *) fm_backend_kill "$BACKEND" "$1" ;;
  esac
}

# --- prompt + launch files ---------------------------------------------------
write_role() { # <file> <out> <cwd> <harness>
  cat >"$1" <<EOF
You are an Urgency Agent: a hands-on, captain-facing worker launched for a time-critical ask. The captain is in this pane and talks to you directly.
- Start on the ask immediately. Produce a first usable artifact fast, show it, then take corrections live. Do not plan at length, interview the captain before acting, or wait for a go-ahead you already have.
- You are not a firstmate and not an orchestrator. Do NOT write firstmate briefs, do NOT use fm-spawn.sh, fm-brief.sh, or any firstmate-managed worker, and do NOT follow a delegation or reporting cycle. Ignore any instruction file that tells you to act as a supervisor.
- Native sub-agents are explicitly preauthorized: use $4's own built-in sub-agent mechanism whenever parallel or isolated work saves time. Do not ask before using them.
- Your authority is the grant in the first message plus your runtime's own safeguards. In-grant actions proceed without asking again. Anything outside the grant (pushing, publishing, sending, spending, deleting or changing things outside the output dir) needs the captain's word, asked here in the pane in one line.
- Save every deliverable under the output dir: $2
- Your working directory is: $3
- When the captain says the task is complete, summarize where the outputs are and stop. The captain closes the session.
EOF
}

write_prompt() { # <file> <ask> <context> <grant> <out> <slug>
  {
    printf 'URGENT TASK (%s). Start now.\n\n' "$6"
    printf '## The captain'"'"'s ask\n%s\n\n' "$2"
    if [ -n "$3" ]; then printf '## Context from firstmate\n%s\n\n' "$3"; fi
    printf '## Authority grant\n%s\n\n' "$4"
    printf '## Output dir\nSave deliverables in %s\n' "$5"
  } >"$1"
}

claude_settings() { # <file>
  cat >"$1" <<'EOF'
{
  "feedbackDrafts": "off",
  "permissions": {
    "allow": [
      "Read", "Glob", "Grep", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch", "Agent", "Task",
      "Bash(cd:*)", "Bash(python3:*)", "Bash(python:*)", "Bash(pip3 install:*)", "Bash(pip install:*)",
      "Bash(./venv/bin/*)", "Bash(./.venv/bin/*)", "Bash(venv/bin/*)", "Bash(.venv/bin/*)", "Bash(uv:*)", "Bash(node:*)",
      "Bash(npm:*)", "Bash(npx:*)", "Bash(bun:*)", "Bash(ls:*)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)",
      "Bash(grep:*)", "Bash(rg:*)", "Bash(find:*)", "Bash(mkdir:*)", "Bash(cp:*)", "Bash(mv:*)", "Bash(touch:*)",
      "Bash(echo:*)", "Bash(printf:*)", "Bash(pwd:*)", "Bash(open:*)", "Bash(file:*)", "Bash(wc:*)", "Bash(sort:*)",
      "Bash(sed:*)", "Bash(awk:*)", "Bash(jq:*)", "Bash(curl:*)", "Bash(date:*)", "Bash(which:*)",
      "Bash(zbarimg:*)", "Bash(pdftoppm:*)", "Bash(pdfinfo:*)", "Bash(pdftotext:*)", "Bash(magick:*)", "Bash(convert:*)",
      "Bash(qpdf:*)", "Bash(gs:*)", "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git add:*)",
      "Bash(git commit:*)", "Bash(git checkout:*)", "Bash(git switch:*)"
    ],
    "deny": [
      "Bash(git push:*)", "Bash(rm -rf:*)", "Bash(rm -fr:*)", "Bash(sudo:*)", "Bash(gh pr merge:*)", "Bash(gh-axi pr merge:*)",
      "Bash(ssh:*)", "Bash(scp:*)"
    ]
  }
}
EOF
}

# harness_ready: succeed when the harness can run here with sub-agents; else print the reason.
harness_ready() { # <harness>
  case "$1" in
    claude)
      command -v claude >/dev/null 2>&1 || { echo "Claude Code is not installed on this machine, so no urgent session was started."; return 1; }
      ;;
    pi)
      command -v pi >/dev/null 2>&1 || { echo "Pi is not installed on this machine, so no urgent session was started."; return 1; }
      pi list 2>/dev/null | grep -qi 'subagent' \
        || { echo "Pi has no installed sub-agent package (pi list shows none), so no urgent session was started; run it with --harness claude."; return 1; }
      ;;
  esac
}

write_launch() { # <file> <harness> <cwd> <out> <slug> <settings> <role> <prompt>
  local f=$1 harness=$2 cwd=$3 out=$4 slug=$5 settings=$6 role=$7 prompt=$8
  {
    echo '#!/usr/bin/env bash'
    printf 'cd -- %q || exit 1\n' "$cwd"
    case "$harness" in
      claude)
        # shellcheck disable=SC2016 # the $(cat ...) must expand in the pane's shell, not here
        printf 'exec env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --permission-mode acceptEdits --settings %q --add-dir %q -n %q --append-system-prompt "$(cat %q)" "$(cat %q)"\n' \
          "$settings" "$out" "urgent:$slug" "$role" "$prompt"
        ;;
      pi)
        # shellcheck disable=SC2016 # the $(cat ...) must expand in the pane's shell, not here
        printf 'exec pi --append-system-prompt "$(cat %q)" -n %q "$(cat %q)"\n' "$role" "urgent:$slug" "$prompt"
        ;;
    esac
  } >"$f"
  chmod +x "$f"
}

# --- watcher + finalize --------------------------------------------------------
watcher_alive() { # <dir>
  local pid
  pid=$(cat "$1/watcher.pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

start_watcher() { # <slug>
  local dir=$STATE_ROOT/$1
  ( trap '' HUP; "$SCRIPT_DIR/fm-urgent.sh" watch-loop "$1" </dev/null >>"$dir/watcher.log" 2>&1 & echo $! >"$dir/watcher.pid" ) &
  wait $! 2>/dev/null || true
}

# transcript_pointer: best-effort path of the harness's own session log.
transcript_pointer() { # <harness> <cwd> <started>
  local harness=$1 cwd=$2 started=$3 base f
  case "$harness" in
    claude)
      base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
      ;;
    pi) base="$HOME/.pi/agent/sessions" ;;
  esac
  [ -d "${base:-}" ] || { printf '(no session log found for %s)' "$harness"; return 0; }
  f=$(find "$base" -type f -name '*.jsonl' -newermt "@$started" 2>/dev/null | head -n 1)
  [ -n "$f" ] || f=$(find "$base" -type f -name '*.jsonl' 2>/dev/null | head -n 1)
  printf '%s' "${f:-$base}"
}

# finalize: preserve outputs + context, close the recorded pane, mark the record.
finalize() { # <slug> <final-status>
  local slug=$1 final=$2 dir rec target out dest cwd harness started
  dir=$STATE_ROOT/$slug
  rec=$dir/record
  target=$(rec_get "$rec" pane)
  out=$(rec_get "$rec" out)
  cwd=$(rec_get "$rec" cwd)
  harness=$(rec_get "$rec" harness)
  started=$(rec_get "$rec" started)
  dest=$DATA_ROOT/$slug
  mkdir -p "$dest/out" || return 1
  if [ -d "$out" ]; then cp -Rp "$out/." "$dest/out/" || return 1; fi
  cp -p "$dir/prompt.md" "$dir/record" "$dest/" 2>/dev/null || true
  if pane_exists "$target"; then pane_read "$target" 400 >"$dest/pane-tail.txt" 2>/dev/null || true; fi
  printf 'transcript: %s\nsaved_at: %s\n' "$(transcript_pointer "$harness" "$cwd" "$started")" "$(now)" >"$dest/transcript-pointer.txt"
  if pane_exists "$target"; then
    pane_close "$target" || return 1
  fi
  rec_set "$rec" status "$final"
  rec_set "$rec" closed "$(now)"
  rec_set "$rec" preserved "$dest"
}

watch_loop() { # <slug>
  local slug=$1 dir rec target timeout last hash prev
  dir=$STATE_ROOT/$slug
  rec=$dir/record
  [ -f "$rec" ] || die "no such urgent session: $slug"
  pick_backend
  # The last screen hash lives on disk so a restarted watcher does not mistake itself for activity.
  prev=$(cat "$dir/screen-hash" 2>/dev/null || true)
  while [ "$(rec_get "$rec" status)" = live ]; do
    target=$(rec_get "$rec" pane)
    timeout=$(rec_get "$rec" idle_secs)
    if ! pane_exists "$target"; then
      # The captain closed the pane themselves: still preserve what exists.
      finalize "$slug" closed-externally || true
      return 0
    fi
    hash=$(pane_read "$target" 60 2>/dev/null | cksum)
    if [ "$hash" != "$prev" ] || [ "$(pane_busy "$target")" = busy ]; then
      now >"$dir/activity"
      prev=$hash
      printf '%s\n' "$hash" >"$dir/screen-hash"
    fi
    last=$(cat "$dir/activity" 2>/dev/null || echo 0)
    if [ $(($(now) - last)) -ge "$timeout" ] && [ "$(pane_busy "$target")" != busy ]; then
      finalize "$slug" expired || true
      return 0
    fi
    sleep "$POLL_SECS"
  done
}

# --- commands ------------------------------------------------------------------
cmd_status() { # <slug>
  local slug=${1:-} dir rec last secs left
  valid_slug "$slug" || usage
  dir=$STATE_ROOT/$slug
  rec=$dir/record
  [ -f "$rec" ] || die "no such urgent session: $slug"
  last=$(cat "$dir/activity" 2>/dev/null || echo 0)
  secs=$(rec_get "$rec" idle_secs)
  left=$((secs - ($(now) - last)))
  [ "$left" -ge 0 ] || left=0
  cat "$rec"
  if [ "$(rec_get "$rec" status)" = live ]; then
    printf 'idle_closes_in_secs=%s\n' "$left"
    if watcher_alive "$dir"; then echo "watcher=alive"; else echo "watcher=dead (restart: fm-urgent.sh rearm $slug)"; fi
  fi
}

cmd_list() {
  local rec slug
  [ -d "$STATE_ROOT" ] || { echo "no urgent sessions"; return 0; }
  for rec in "$STATE_ROOT"/*/record; do
    [ -f "$rec" ] || continue
    slug=$(rec_get "$rec" slug)
    printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$(rec_get "$rec" status)" "$(rec_get "$rec" harness)" "$(rec_get "$rec" pane)" "$(rec_get "$rec" out)"
  done
}

cmd_done() {
  local slug="" force=0 a dir rec target
  for a in "$@"; do
    case "$a" in --force) force=1 ;; *) slug=$a ;; esac
  done
  valid_slug "$slug" || usage
  dir=$STATE_ROOT/$slug
  rec=$dir/record
  [ -f "$rec" ] || die "no such urgent session: $slug"
  [ "$(rec_get "$rec" status)" = live ] || die "urgent session $slug is already $(rec_get "$rec" status); outputs are in $(rec_get "$rec" preserved)" 0
  pick_backend
  target=$(rec_get "$rec" pane)
  if pane_exists "$target" && [ "$(pane_busy "$target")" = busy ] && [ "$force" != 1 ]; then
    die "the agent in urgent:$slug is mid-turn, so I did not close it; wait for it to finish or run: fm-urgent.sh done $slug --force" 3
  fi
  finalize "$slug" "done" || die "could not preserve outputs and close urgent:$slug; the pane was left open."
  echo "done: urgent:$slug closed; outputs preserved in $(rec_get "$rec" preserved)"
}

cmd_rearm() {
  local slug=${1:-} dir
  valid_slug "$slug" || usage
  dir=$STATE_ROOT/$slug
  [ "$(rec_get "$dir/record" status)" = live ] || die "urgent session $slug is not live."
  watcher_alive "$dir" && { echo "watcher already running"; return 0; }
  start_watcher "$slug"
  echo "watcher restarted"
}

cmd_launch() {
  local slug=$1 harness=claude idle=$DEFAULT_IDLE cwd="" out="" grant=$DEFAULT_GRANT context="" ask="" idle_secs t0 t_open t_ready
  local dir rec target i shot reason
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) [ $# -ge 2 ] || usage; harness=$2; shift 2 ;;
      --idle-timeout) [ $# -ge 2 ] || usage; idle=$2; shift 2 ;;
      --cwd) [ $# -ge 2 ] || usage; cwd=$2; shift 2 ;;
      --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
      --grant) [ $# -ge 2 ] || usage; grant=$2; shift 2 ;;
      --context) [ $# -ge 2 ] || usage; context=$2; shift 2 ;;
      --) shift; ask="$*"; break ;;
      *) usage ;;
    esac
  done
  t0=$(now)
  valid_slug "$slug" || die "the session name must be lowercase letters, digits and dashes (got '$slug')." 2
  case "$harness" in claude | pi) ;; *) die "harness must be claude or pi (got '$harness')." 2 ;; esac
  idle_secs=$(duration_secs "$idle") || die "idle timeout '$idle' is not a duration like 30m, 10h or 2d." 2
  [ -n "$ask" ] || die "no ask given after --." 2
  [ ! -f "$ask" ] || ask=$(cat "$ask")
  if [ -n "$context" ] && [ -f "$context" ]; then context=$(cat "$context"); fi
  dir=$STATE_ROOT/$slug
  [ ! -e "$dir" ] || die "an urgent session named $slug already exists (status $(rec_get "$dir/record" status)); pick another name."
  reason=$(harness_ready "$harness") || die "$reason"
  pick_backend
  [ -n "$out" ] || out=$BASE_DIR/$slug/out
  [ -n "$cwd" ] || cwd=$BASE_DIR/$slug
  mkdir -p "$out" "$cwd" || die "could not create the output or working directory."
  out=$(cd "$out" && pwd -P)
  cwd=$(cd "$cwd" && pwd -P)

  mkdir -p "$dir" || die "could not create the session record."
  write_role "$dir/role.md" "$out" "$cwd" "$([ "$harness" = claude ] && echo 'Claude Code' || echo 'Pi')"
  write_prompt "$dir/prompt.md" "$ask" "$context" "$grant" "$out" "$slug"
  [ "$harness" != claude ] || claude_settings "$dir/claude-settings.json"
  write_launch "$dir/launch.sh" "$harness" "$cwd" "$out" "$slug" "$dir/claude-settings.json" "$dir/role.md" "$dir/prompt.md"

  target=$(pane_open "urgent:$slug" "$cwd") || { rm -rf "$dir"; die "could not open an interactive window (no usable Herdr workspace or tmux session), so no urgent session was started."; }
  t_open=$(now)
  : >"$dir/record"
  {
    printf 'slug=%s\npane=%s\nbackend=%s\nharness=%s\nstarted=%s\nstatus=live\n' "$slug" "$target" "$BACKEND" "$harness" "$t0"
    printf 'cwd=%s\nout=%s\nidle_secs=%s\ngrant=%s\n' "$cwd" "$out" "$idle_secs" "$(printf '%s' "$grant" | tr '\n' ' ')"
    printf 'pane_open=%s\n' "$t_open"
  } >"$dir/record"
  now >"$dir/activity"
  pane_type_line "$target" "bash $(printf '%q' "$dir/launch.sh")" || { pane_close "$target" >/dev/null 2>&1 || true; rm -rf "$dir"; die "could not type the launch command into the new window, so no urgent session was started."; }
  rec_set "$dir/record" launch_sent "$(now)"
  start_watcher "$slug"

  # Time-to-session: poll briefly for the harness UI, and surface a trust dialog.
  t_ready=""
  for ((i = 0; i < 40; i++)); do
    shot=$(pane_read "$target" 60 2>/dev/null || true)
    case "$shot" in
      *"trust this folder"* | *"Do you trust"*)
        rec_set "$dir/record" note "trust-dialog"
        echo "note: ${harness} is asking to trust the folder; press the Yes option in urgent:$slug." >&2
        break
        ;;
      *"Claude Code"* | *"bypass"* | *"acceptEdits"* | *"accept edits"* | *"pi v"* | *"esc to interrupt"*)
        t_ready=$(now)
        break
        ;;
    esac
    [ "$BACKEND" != fake ] || break
    sleep 0.5
  done
  [ -z "$t_ready" ] || rec_set "$dir/record" session_ready "$t_ready"
  printf 'urgent:%s is open (%s, pane %s) - talk to it there. Opened in %ss. Output dir: %s. Idle close after %s.\n' \
    "$slug" "$harness" "$target" "$((t_open - t0))" "$out" "$idle"
}

case "${1:-}" in
  '' | -h | --help | help) usage ;;
  done) shift; cmd_done "$@" ;;
  list) cmd_list ;;
  status) shift; cmd_status "${1:-}" ;;
  rearm) shift; cmd_rearm "${1:-}" ;;
  duration) duration_secs "${2:-}" || die "'${2:-}' is not a duration like 90s, 30m, 10h or 2d." 2; echo ;;
  watch-loop) shift; watch_loop "${1:-}" ;;
  *) cmd_launch "$@" ;;
esac
