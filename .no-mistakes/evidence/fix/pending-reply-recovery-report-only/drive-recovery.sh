#!/usr/bin/env bash
# Live driver: runs inside the lab tmux session so fm-send.sh talks to the lab socket.
set -u
ROOT=$1 LAB=$2 SUMMARY=$3 OUT=$4
. "$ROOT/tests/lib.sh" >/dev/null 2>&1 || true
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_HOME="$LAB" FM_PENDING_REPLY_GRACE_SECS=0 FM_SEND_SETTLE=0
state="$LAB/state"; mkdir -p "$state" "$LAB/sm-hibit"
fm_write_secondmate_meta "$state/hibit.meta" "$LAB/sm-hibit" "primary:fm-hibit" alpha claude
corr=$(fm_pending_reply_create "$LAB" "$state" hibit "$SUMMARY")
fm_pending_reply_mark_delivered "$state" "$corr"
fm_pending_reply_observe_busy "$state" "$corr" busy
fm_pending_reply_observe_busy "$state" "$corr" idle
if fm_pending_reply_send_recovery "$state" "$corr"; then rc=0; else rc=$?; fi
{
  echo "corr=$corr send_recovery_rc=$rc"
  echo "phase=$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" phase)"
  echo "stored request_summary=$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" request_summary)"
  echo "--- inbox records ---"
  for f in $(find "$state" -path '*hibit.inbox*' -type f | sort); do echo "## $f"; cat "$f"; echo; done
} > "$OUT" 2>&1
echo DONE >> "$OUT"
