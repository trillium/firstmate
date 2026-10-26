#!/usr/bin/env bash
# Live drive: real fm-send.sh marked request -> pending record -> real recovery send (no hook)
set -u
ROOT=$1; SUMMARY=$2
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
trap 'TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_PENDING_REPLY_SEND_HOOK
export FM_HOME="$LAB" FM_SEND_SETTLE=0 FM_PENDING_REPLY_GRACE_SECS=0 TMUX_TMPDIR="$LAB/tmux"
. "$ROOT/bin/fm-marker-lib.sh"; . "$ROOT/bin/fm-pending-reply-lib.sh"
state="$LAB/state"
# Seed a local secondmate task "hibit" with a real pane on the lab tmux socket.
tmux -L fm-lab new-session -d -s fm-hibit 'cat'
mate="$LAB/sm-hibit"; mkdir -p "$mate/state"
printf 'hibit\n' > "$mate/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB" > "$mate/.fm-secondmate-parent"
printf "window=fm-hibit:0\nendpoint_task_id=hibit\nworktree=%s\nproject=%s\nharness=claude\nkind=secondmate\nmode=secondmate\nyolo=off\nhome=%s\nprojects=alpha\n" "$mate" "$mate" "$mate" > "$state/hibit.meta"
echo "== 1. real fm-send.sh: marked request =="
FM_PENDING_REPLY_NOW=1000 "$ROOT/bin/fm-send.sh" hibit "${FM_FROMFIRST_MARK}${SUMMARY}"; echo "fm-send exit=$?"
corr=$(ls "$state/pending-replies" | head -1); rec=$(fm_pending_reply_path "$state" "$corr")
echo "corr=$corr"; echo "stored request_summary=[$(fm_pending_reply_get "$rec" request_summary)]"
echo "phase=$(fm_pending_reply_get "$rec" phase)"
fm_pending_reply_mark_delivered "$state" "$corr" 2>/dev/null
export FM_PENDING_REPLY_NOW=2000
fm_pending_reply_observe_busy "$state" "$corr" busy; fm_pending_reply_observe_busy "$state" "$corr" idle
echo "== 2. real recovery send (no hook, via fm-send.sh) =="
fm_pending_reply_send_recovery "$state" "$corr"; echo "send_recovery exit=$?"
echo "phase=$(fm_pending_reply_get "$rec" phase)"
echo "stored request_summary after recovery=[$(fm_pending_reply_get "$rec" request_summary)]"
echo "== 3. delivered recovery body (last steering-inbox record) =="
r=$(find "$state/hibit.inbox" -name '*.msg' 2>/dev/null | sort | tail -1)
body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$r")
printf '%s\n' "$body"
printf '%s' "$body" > "${OUT_BODY:-/dev/null}"
echo "== 4. fence-marker counts in delivered body =="
echo ">>> count: $(grep -o '>>>' <<< "$body" | wc -l | tr -d ' ')"
echo "<<< count: $(grep -o '<<<' <<< "$body" | wc -l | tr -d ' ')"
echo "contains 'Original request:': $(grep -c 'Original request:' <<< "$body")"
echo "pending records: $(ls "$state/pending-replies" | wc -l | tr -d ' ')"
