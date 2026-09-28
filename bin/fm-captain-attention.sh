#!/usr/bin/env bash
# fm-captain-attention.sh - side observer that puts captain-needing signals
# on the jumbotron (displayd) without changing firstmate's flow.
#
# OBSERVE, never change the flow: this reads records firstmate ALREADY writes
# and reacts to them. No dispatch, supervision, or escalation path calls this;
# if a design requires an agent to remember to call something, it is wrong.
#
# Signal sources (read-only, never written):
#   state/<id>.status - append-only wake-event lines. needs-decision/blocked
#     lines OPEN a keyed decision; only an explicit resolved/captain-held line
#     for the same [key=...] closes it. The fold lives in
#     bin/fm-classify-lib.sh (status_open_decisions) and this script consumes
#     its output verbatim, so "needs the captain" cannot drift from
#     firstmate's own notion.
#   The review federated store - new open review items are a first-class
#     "needs the captain" signal. Read via the review CLI, never written.
#   state/.afk - present means the captain is away, which makes the panel
#     MORE important, not less (no behaviour change needed - same takeover).
#
# Display: displayd already runs (tailnet, POST /notify shows the transient
# notice view, then returns automatically). No new renderer: the notice view
# carries title/body/severity, which is everything a glanceable takeover
# needs.
#
# Idempotence: every shown signal is recorded in
# state/.captain-attention.seen (one sig per line) and a signal fires at most
# once. A decision sig binds task + key + verb + note-hash + open-count, so
# unrelated appends never re-fire, while a genuinely re-opened key (open
# count bumped) or a re-worded ask (note hash changed) fires again. A review
# sig binds the review id; ids that leave the open set are forgotten, so a
# close-then-reopen fires again. Seen entries with no live signal are pruned,
# keeping the file bounded.
#
# Failure isolation: displayd unreachable (or any store read failing) never
# breaks firstmate - this is a separate process. A failed POST leaves the sig
# unrecorded, so it retries quietly on the next poll and lands exactly once
# when displayd returns, with no replay flood. Failure logging is throttled.
#
# Usage:
#   fm-captain-attention.sh once [--bootstrap] [--dry-run]
#     Single scan. --bootstrap records current signals as seen without
#     notifying (first-run flood guard). --dry-run prints what would fire
#     without POSTing or recording.
#   fm-captain-attention.sh watch
#     Loop forever (POLL_SECS). Bootstraps silently when no seen file exists.
#   fm-captain-attention.sh --install | --uninstall | --status
#     macOS launchd supervision (survives logout/reboot).
#
# Config (CLI flags win, then env, then $FM_HOME/config/captain-attention.env):
#   FM_HOME / --state-dir   firstmate home (state dir holds *.status)
#   DISPLAYD_URL            displayd base (default http://100.81.88.113:8980)
#   CAPTAIN_ATTENTION_ENABLED=0 turns the observer off without editing code
#   POLL_SECS               watch interval (default 5)
#   NOTICE_DURATION         notify seconds on screen, 1-300 (default 120)
#   REVIEW_BIN              review CLI (default review)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

DISPLAYD_DEFAULT="http://100.81.88.113:8980"
POLL_DEFAULT=5
DURATION_DEFAULT=120

MODE=""
BOOTSTRAP=0
DRY_RUN=0
STATE_DIR_OVERRIDE=""
DISPLAYD_OVERRIDE=""

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    once|watch) MODE=$1; shift ;;
    --bootstrap) BOOTSTRAP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --install) MODE=install; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --status) MODE=status; shift ;;
    --state-dir)
      [ $# -ge 2 ] || { echo "fm-captain-attention: --state-dir needs a value" >&2; exit 2; }
      STATE_DIR_OVERRIDE=$2; shift 2 ;;
    --state-dir=*) STATE_DIR_OVERRIDE=${1#--state-dir=}; shift ;;
    --displayd-url)
      [ $# -ge 2 ] || { echo "fm-captain-attention: --displayd-url needs a value" >&2; exit 2; }
      DISPLAYD_OVERRIDE=$2; shift 2 ;;
    --displayd-url=*) DISPLAYD_OVERRIDE=${1#--displayd-url=}; shift ;;
    *) echo "fm-captain-attention: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$MODE" ] || { echo "fm-captain-attention: need once|watch|--install|--uninstall|--status" >&2; exit 2; }

# --- home + config ---------------------------------------------------------
# Env values are captured BEFORE defaults apply, so the optional config file
# only fills keys the environment left unset; CLI flags win over both.
ENV_ENABLED="${CAPTAIN_ATTENTION_ENABLED:-__unset}"
ENV_DISPLAYD="${DISPLAYD_URL:-__unset}"
ENV_POLL="${POLL_SECS:-__unset}"
ENV_DURATION="${NOTICE_DURATION:-__unset}"
FM_HOME_RESOLVED="${FM_HOME:-}"
if [ -z "$FM_HOME_RESOLVED" ] && [ -d "$HOME/fm_home/firstmate" ]; then
  FM_HOME_RESOLVED="$HOME/fm_home/firstmate"
fi
STATE_DIR="${STATE_DIR_OVERRIDE:-${FM_HOME_RESOLVED:+$FM_HOME_RESOLVED/state}}"
DISPLAYD_URL="${DISPLAYD_OVERRIDE:-${DISPLAYD_URL:-$DISPLAYD_DEFAULT}}"
POLL_SECS="${POLL_SECS:-$POLL_DEFAULT}"
NOTICE_DURATION="${NOTICE_DURATION:-$DURATION_DEFAULT}"
REVIEW_BIN="${REVIEW_BIN:-review}"
ENABLED="${CAPTAIN_ATTENTION_ENABLED:-1}"

# Optional flat KEY=value config file (lets the captain turn the observer off
# and set the endpoint without editing code). Only known keys are honoured,
# and only when neither a CLI flag nor the environment set them.
CONFIG_FILE="${FM_HOME_RESOLVED:+$FM_HOME_RESOLVED/config/captain-attention.env}"
if [ -z "$STATE_DIR_OVERRIDE" ] && [ -n "${CONFIG_FILE:-}" ] && [ -f "$CONFIG_FILE" ]; then
  _cfg_val() {
    grep -E "^$1=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
  }
  _v=$(_cfg_val CAPTAIN_ATTENTION_ENABLED); [ "$ENV_ENABLED" = "__unset" ] && [ -n "$_v" ] && ENABLED="$_v"
  _v=$(_cfg_val DISPLAYD_URL); [ "$ENV_DISPLAYD" = "__unset" ] && [ -z "$DISPLAYD_OVERRIDE" ] && [ -n "$_v" ] && DISPLAYD_URL="$_v"
  _v=$(_cfg_val POLL_SECS); [ "$ENV_POLL" = "__unset" ] && [ -n "$_v" ] && POLL_SECS="$_v"
  _v=$(_cfg_val NOTICE_DURATION); [ "$ENV_DURATION" = "__unset" ] && [ -n "$_v" ] && NOTICE_DURATION="$_v"
fi

SEEN_FILE="$STATE_DIR/.captain-attention.seen"
LOG_FILE="$STATE_DIR/.captain-attention.log"
PID_FILE="$STATE_DIR/.captain-attention.pid"
LAST_FAIL_FILE="$STATE_DIR/.captain-attention.last-fail"

log_line() {
  # log_line <event> <detail> - quiet append, keeps the last ~200 lines.
  [ -d "$STATE_DIR" ] || return 0
  printf '%s %s %s\n' "$(date +%s)" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || return 0
  _n=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d '[:space:]') || return 0
  case "$_n" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$_n" -gt 500 ]; then
    tail -200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

log_fail_throttled() {
  # Failure logging at most every 10 minutes so a down displayd stays quiet.
  _now=$(date +%s)
  _last=0
  if [ -f "$LAST_FAIL_FILE" ]; then
    _last=$(cat "$LAST_FAIL_FILE" 2>/dev/null | tr -d '[:space:]') || _last=0
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
  fi
  if [ $((_now - _last)) -ge 600 ]; then
    printf '%s' "$_now" > "$LAST_FAIL_FILE" 2>/dev/null || true
    log_line "displayd-unreachable" "$1"
  fi
}

seen_has() {
  [ -f "$SEEN_FILE" ] && grep -qxF "$1" "$SEEN_FILE" 2>/dev/null
}

seen_add() {
  [ -d "$STATE_DIR" ] || return 1
  touch "$SEEN_FILE" 2>/dev/null || return 1
  printf '%s\n' "$1" >> "$SEEN_FILE"
}

note_crc() {
  # Short stable hash of a note (cksum is on both macOS and Linux).
  printf '%s' "$1" | cksum 2>/dev/null | awk '{print $1}' || printf '0'
}

truncate_text() {
  # truncate_text <max-chars> - reads stdin, one line, no newlines.
  _max=$1
  tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c "1-${_max}"
}

post_notify() {
  # post_notify <title> <body> <severity> - 0 on 2xx, 1 otherwise. Quiet.
  _title=$1 _body=$2 _sev=$3 _code=""
  if command -v python3 >/dev/null 2>&1; then
    _payload=$(TITLE="$_title" BODY="$_body" SEV="$_sev" DUR="$NOTICE_DURATION" python3 -c \
      'import json,os; print(json.dumps({"title":os.environ["TITLE"],"body":os.environ["BODY"],"severity":os.environ["SEV"],"duration":float(os.environ["DUR"])}))' 2>/dev/null) \
      || return 1
  else
    _esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '; }
    _payload=$(printf '{"title":"%s","body":"%s","severity":"%s","duration":%s}' \
      "$(_esc "$_title")" "$(_esc "$_body")" "$_sev" "$NOTICE_DURATION")
  fi
  _code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d "$_payload" \
    "$DISPLAYD_URL/notify" 2>/dev/null) || return 1
  case "$_code" in 2*) return 0 ;; *) return 1 ;; esac
}

# --- signal collection (read-only) -----------------------------------------
# Prints current live sigs, one per line, fields TAB-separated:
#   D <sig> <title> <body> <severity>   (status open decision)
#   R <sig> <title> <body> <severity>   (open review item)
collect_sigs() {
  for _f in "$STATE_DIR"/*.status; do
    [ -e "$_f" ] || continue
    _task=$(basename "$_f"); _task=${_task%.status}
    _open=$(status_open_decisions "$_f") || continue
    [ -n "$_open" ] || continue
    while IFS= read -r _line; do
      [ -n "$_line" ] || continue
      _key=$(printf '%s' "$_line" | cut -f1)
      _verb=$(printf '%s' "$_line" | cut -f2)
      _note=$(printf '%s' "$_line" | cut -f3-)
      # Open-count for this key in this file: a reopen bumps it, so a
      # resolved-then-reopened key with identical text still re-fires,
      # while unrelated appends leave every sig untouched.
      _count=$(grep -cE "(needs-decision|blocked)[^:]*\[key=${_key}\]" "$_f" 2>/dev/null) || _count=0
      if [ "$_key" = "default" ]; then
        _count=$(grep -cE '^(needs-decision|blocked)[ :]' "$_f" 2>/dev/null) || _count=0
      fi
      _crc=$(note_crc "$_note")
      _sig="d:${_task}:${_key}:${_verb}:${_crc}:${_count}"
      _title=$(printf 'Captain %s: %s' "$_verb" "$_task" | truncate_text 80)
      if [ "$_key" != "default" ]; then
        _body=$(printf '[%s] %s' "$_key" "$_note" | truncate_text 180)
      else
        _body=$(printf '%s' "$_note" | truncate_text 180)
      fi
      case "$_verb" in
        blocked) _sev="critical" ;;
        *) _sev="warn" ;;
      esac
      printf 'D\t%s\t%s\t%s\t%s\n' "$_sig" "$_title" "$_body" "$_sev"
    done <<EOF
$_open
EOF
  done
  if command -v "$REVIEW_BIN" >/dev/null 2>&1; then
    "$REVIEW_BIN" list --status open -n 0 --flat --no-pager 2>/dev/null \
      | grep -oE 'review-[A-Za-z0-9._-]+' | sort -u | while IFS= read -r _rid; do
      [ -n "$_rid" ] || continue
      _rtitle=$(printf '%s' "$_rid" | truncate_text 60)
      printf 'R\tr:%s\tCaptain review: %s\t%s needs human eyes\twarn\n' "$_rid" "$_rtitle" "$_rid"
    done
  fi
  return 0
}

reconcile_seen() {
  # Drop seen entries with no live signal (keeps the file bounded; lets a
  # close-then-reopen review id fire again). Reads live sigs from $1.
  _live=$1 _kept=""
  [ -f "$SEEN_FILE" ] || return 0
  while IFS= read -r _s; do
    [ -n "$_s" ] || continue
    if grep -qxF "$_s" "$_live" 2>/dev/null; then
      _kept="${_kept}${_s}
"
    fi
  done < "$SEEN_FILE"
  printf '%s' "$_kept" > "$SEEN_FILE.tmp" 2>/dev/null && mv -f "$SEEN_FILE.tmp" "$SEEN_FILE"
}

scan_once() {
  # One scan: notify (or print/bootstrap) every unseen live signal.
  _live=$(mktemp "${TMPDIR:-/tmp}/captain-attn.live.XXXXXX") || return 1
  _sigs=$(mktemp "${TMPDIR:-/tmp}/captain-attn.sigs.XXXXXX") || { rm -f "$_live"; return 1; }
  collect_sigs > "$_live"
  cut -f2 "$_live" > "$_sigs" 2>/dev/null || true
  _fired=0
  while IFS= read -r _entry; do
    [ -n "$_entry" ] || continue
    _kind=$(printf '%s' "$_entry" | cut -f1)
    _sig=$(printf '%s' "$_entry" | cut -f2)
    _title=$(printf '%s' "$_entry" | cut -f3)
    _body=$(printf '%s' "$_entry" | cut -f4)
    _sev=$(printf '%s' "$_entry" | cut -f5)
    seen_has "$_sig" && continue
    if [ "$BOOTSTRAP" -eq 1 ]; then
      seen_add "$_sig"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would-notify [%s] %s | %s | %s\n' "$_kind" "$_title" "$_body" "$_sev"
      continue
    fi
    if post_notify "$_title" "$_body" "$_sev"; then
      seen_add "$_sig"
      log_line "notified" "$_sig :: $_title"
      printf 'notified %s :: %s\n' "$_sig" "$_title"
      _fired=$((_fired + 1))
    else
      log_fail_throttled "$_sig :: $DISPLAYD_URL"
    fi
  done < "$_live"
  if [ "$BOOTSTRAP" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    reconcile_seen "$_sigs"
  fi
  rm -f "$_live" "$_sigs"
  printf '%s' "$_fired"
}

do_install() {
  _plist="$HOME/Library/LaunchAgents/com.trillium.fm-captain-attention.plist"
  _self="$SCRIPT_DIR/fm-captain-attention.sh"
  mkdir -p "$HOME/Library/LaunchAgents" || return 1
  cat > "$_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.trillium.fm-captain-attention</string>
  <key>ProgramArguments</key>
  <array><string>$_self</string><string>watch</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key><string>$FM_HOME_RESOLVED</string>
    <key>DISPLAYD_URL</key><string>$DISPLAYD_URL</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$STATE_DIR/.captain-attention.stdout.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/.captain-attention.stderr.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/com.trillium.fm-captain-attention" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$_plist" || return 1
  printf 'installed %s\n' "$_plist"
}

do_uninstall() {
  _plist="$HOME/Library/LaunchAgents/com.trillium.fm-captain-attention.plist"
  launchctl bootout "gui/$(id -u)/com.trillium.fm-captain-attention" 2>/dev/null || true
  rm -f "$_plist"
  printf 'uninstalled (seen/log state kept in %s)\n' "$STATE_DIR"
}

case "$MODE" in
  install) do_install; exit $? ;;
  uninstall) do_uninstall; exit $? ;;
  status)
    if launchctl print "gui/$(id -u)/com.trillium.fm-captain-attention" >/dev/null 2>&1; then
      printf 'loaded\n'
    else
      printf 'not loaded\n'
    fi
    exit 0
    ;;
esac

if [ -z "$STATE_DIR" ] || [ ! -d "$STATE_DIR" ]; then
  echo "fm-captain-attention: no state dir (set FM_HOME or --state-dir)" >&2
  exit 2
fi
if [ "$ENABLED" = "0" ]; then
  exit 0
fi

case "$MODE" in
  once)
    scan_once
    printf '\n'
    exit 0
    ;;
  watch)
    if [ -f "$PID_FILE" ]; then
      _old=$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]') || _old=""
      case "$_old" in ''|*[!0-9]*) ;; *) kill -0 "$_old" 2>/dev/null && { echo "fm-captain-attention: already running (pid $_old)" >&2; exit 1; } ;; esac
    fi
    printf '%s' "$$" > "$PID_FILE" 2>/dev/null || true
    trap 'rm -f "$PID_FILE"; exit 0' INT TERM
    if [ ! -f "$SEEN_FILE" ]; then
      BOOTSTRAP=1
      scan_once >/dev/null
      BOOTSTRAP=0
      log_line "bootstrap" "recorded baseline without notifying"
    fi
    while true; do
      scan_once >/dev/null
      sleep "$POLL_SECS"
    done
    ;;
esac
