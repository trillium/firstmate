#!/usr/bin/env bash
# Live driver: real Claude Code worker in a disposable lab home on a private
# tmux socket; a user draft sits in its composer; the REAL bin/fm-send.sh steers
# the task. Records the fm-send stderr note, pane captures, and inbox ack state.
# Usage: drive-composer-rescue.sh <worktree> <evidence-dir> <scenario> <draft-mode>
set -u
ROOT=$1 EV=$2 SC=$3 MODE=$4
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
  FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/shim" "$LAB/work"
REAL_TMUX=$(command -v tmux)
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
TMUX_TMPDIR="$LAB/tmux" exec "$REAL_TMUX" -L fm-lab "\$@"
SH
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
OUT="$EV/$SC"; mkdir -p "$OUT"
cleanup() { tmux kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
. "$ROOT/bin/fm-tmux-lib.sh"
. "$ROOT/bin/fm-task-inbox-lib.sh"

task=live-$SC
win=w
acted="$LAB/acted"
tmux new-session -d -s lab -x 160 -y 45 -n "$win" -c "$LAB/work" \
  -- bash -lc "export FM_TASK_INBOX=$(printf '%q' "$LAB/state/$task.inbox"); CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'"
T="lab:$win"
i=0; v=
while [ $i -lt 60 ]; do
  v=$(fm_tmux_composer_state "$T"); [ "$v" = empty ] && break
  if tmux capture-pane -p -t "$T" | grep -q 'Yes, I trust this folder'; then
    tmux capture-pane -p -t "$T" > "$OUT/0-trust-dialog-throwaway-dir.txt"
    tmux send-keys -t "$T" Down; sleep 0.3; tmux send-keys -t "$T" Enter
  fi
  sleep 1; i=$((i+1))
done
echo "ready verdict: $v after ${i}s" > "$OUT/log.txt"
printf 'window=%s\nkind=ship\nharness=claude\n' "$T" > "$LAB/state/$task.meta"

case "$MODE" in
  stray) tmux send-keys -t "$T" -l 'x' ;;
  midcursor) tmux send-keys -t "$T" -l 'fix the bug in the parser'; sleep 0.3
             for _ in 1 2 3 4 5 6 7 8 9 10; do tmux send-keys -t "$T" Left; done ;;
  wrapped) tmux send-keys -t "$T" -l "$(printf 'this draft is deliberately long so that it wraps past one composer row %.0s' 1 2 3)" ;;
esac
sleep 1.5
tmux capture-pane -p -t "$T" > "$OUT/1-before-send.txt"
echo "composer state before send: $(fm_tmux_composer_state "$T")" >> "$OUT/log.txt"
echo "composer text before send: [$(fm_task_inbox_composer_text tmux "$T")]" >> "$OUT/log.txt"

rc=0
FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$task" \
  "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
  > "$OUT/fm-send.stdout" 2> "$OUT/fm-send.stderr" || rc=$?
echo "fm-send rc=$rc" >> "$OUT/log.txt"
tmux capture-pane -p -t "$T" > "$OUT/2-right-after-send.txt"

rec="$LAB/state/$task.inbox/001.msg"; handled="$LAB/state/$task.inbox/handled/001.msg"
echo "record written: $([ -f "$rec" ] || [ -f "$handled" ] && echo yes || echo no)" >> "$OUT/log.txt"
wait=${WAIT:-150}; i=0
while [ $i -lt "$wait" ]; do
  [ -f "$handled" ] && [ -e "$acted" ] && break
  sleep 1; i=$((i+1))
done
# let the turn finish so the composer is visible again
j=0; while [ $j -lt 60 ]; do
  [ "$(fm_tmux_busy_state "$T" 2>/dev/null)" = busy ] || break; sleep 1; j=$((j+1)); done
sleep 2
echo "worker acted=$([ -e "$acted" ] && echo yes || echo no) acked=$([ -f "$handled" ] && echo yes || echo no) after ${i}s" >> "$OUT/log.txt"
tmux capture-pane -p -t "$T" > "$OUT/3-final.txt"
echo "composer state final: $(fm_tmux_composer_state "$T")" >> "$OUT/log.txt"
echo "composer text final: [$(fm_task_inbox_composer_text tmux "$T")]" >> "$OUT/log.txt"
cat "$OUT/log.txt"; echo "--- fm-send stderr"; cat "$OUT/fm-send.stderr"
