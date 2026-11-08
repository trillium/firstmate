#!/usr/bin/env bash
# tests/fm-herdr-tab-pin.test.sh - pinning a labeled secondmate tab first.
#
# Drives bin/backends/herdr-tab-move.py against a fake unix-socket server and
# fm_backend_herdr_tab_pin_first against a fake herdr adapter surface; no real
# herdr is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-tab-pin)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
SERVER_PID=
trap '[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null; fm_test_cleanup || true' EXIT

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
MOVER="$ROOT/bin/backends/herdr-tab-move.py"

# --- the socket helper ------------------------------------------------------
SOCK=$TMP_ROOT/s.sock
REQ=$TMP_ROOT/request.json
cat > "$TMP_ROOT/server.py" <<'PY'
import os, socket, sys
sock_path, req_path, reply_path = sys.argv[1:4]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(1)
while True:
    conn, _ = srv.accept()
    data = b""
    while b"\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    open(req_path, "wb").write(data)
    conn.sendall(open(reply_path, "rb").read())
    conn.close()
PY
REPLY=$TMP_ROOT/reply
printf '%s\n' '{"id":"fm-tab-move","result":{"type":"tab_list","tabs":[{"tab_id":"w1:t2","workspace_id":"w1"},{"tab_id":"w1:t1","workspace_id":"w1"}]}}' > "$REPLY"
python3 "$TMP_ROOT/server.py" "$SOCK" "$REQ" "$REPLY" &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done

out=$("$MOVER" "$SOCK" w1:t2 0); status=$?
assert_equals "$status" "0" "mover accepts a tab_list reply"
assert_equals "$(jq -c '.method, .params' < "$REQ" | tr '\n' ' ')" '"tab.move" {"tab_id":"w1:t2","insert_index":0} ' "mover sends only tab.move with exact params"
assert_contains "$out" '"tab_list"' "mover prints the verified reply"

"$MOVER" "$SOCK" w1:t2 -1 >/dev/null 2>&1; assert_equals "$?" "2" "negative index is rejected"
"$MOVER" "$SOCK" w1:t2 01 >/dev/null 2>&1; assert_equals "$?" "2" "non-canonical index is rejected"
"$MOVER" relative.sock w1:t2 0 >/dev/null 2>&1; assert_equals "$?" "2" "relative socket path is rejected"
"$MOVER" "$SOCK" "$(printf 'a\nb')" 0 >/dev/null 2>&1; assert_equals "$?" "2" "newline in tab id is rejected"

printf '%s\n' '{"id":"fm-tab-move","result":{"type":"workspace_list","workspaces":[]}}' > "$REPLY"
"$MOVER" "$SOCK" w1:t2 0 >/dev/null 2>&1; assert_equals "$?" "4" "wrong reply type is a strict failure"
printf '%s\n' '{"id":"fm-tab-move","error":{"code":"tab_not_found"}}' > "$REPLY"
"$MOVER" "$SOCK" w1:t2 0 >/dev/null 2>&1; assert_equals "$?" "4" "error reply is a strict failure"

# --- the pin function ---------------------------------------------------------
FAKE_BIN=$TMP_ROOT/fake-mover
LOG=$TMP_ROOT/calls.log
cat > "$FAKE_BIN" <<EOS
#!/usr/bin/env bash
printf 'mover %s\n' "\$*" >> "$LOG"
[ -s "$TMP_ROOT/mover-reply" ] || exit 3
cat "$TMP_ROOT/mover-reply"
EOS
chmod +x "$FAKE_BIN"

run_pin() {  # <capable-rc> <mover-reply-or-empty> -> prints stderr, log in $LOG
  : > "$LOG"
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$TMP_ROOT/mover-reply"; else : > "$TMP_ROOT/mover-reply"; fi
  FAKE_CAPABLE=$1 FM_BACKEND_HERDR_TAB_MOVER=$FAKE_BIN bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_tab_move_capable() { return "$FAKE_CAPABLE"; }
    fm_backend_herdr_presentation_session_socket_path() { printf "/tmp/fake.sock"; }
    fm_backend_herdr_projection_focus_snapshot() { printf "w1\tw1:t1"; }
    fm_backend_herdr_projection_focus_restore() { printf "restore %s\n" "$2" >> "'"$LOG"'"; }
    fm_backend_herdr_tab_pin_first sess w1:t2
    echo "rc=$?"
  ' "$ROOT" 2>&1
}

GOOD='{"id":"fm-tab-move","result":{"type":"tab_list","tabs":[{"tab_id":"w1:t2","workspace_id":"w1"},{"tab_id":"w1:t1","workspace_id":"w1"}]}}'
out=$(run_pin 0 "$GOOD")
assert_contains "$out" "rc=0" "pin succeeds"
assert_not_contains "$out" "warning" "a verified pin is quiet"
assert_contains "$(cat "$LOG")" "mover /tmp/fake.sock w1:t2 0" "pin moves the exact tab to index 0"
assert_contains "$(cat "$LOG")" "restore w1"$'\t'"w1:t1" "pin restores the prior focus snapshot"

out=$(run_pin 5 "$GOOD")
assert_equals "$out" "rc=0" "a herdr without tab.move skips quietly"
assert_equals "$(cat "$LOG")" "" "no move is attempted without tab.move"

out=$(run_pin 2 "$GOOD")
assert_contains "$out" "warning: herdr tab pinning could not verify" "unverifiable support warns"
assert_contains "$out" "rc=0" "unverifiable support never fails the caller"

out=$(run_pin 0 "")
assert_contains "$out" "warning: herdr tab pinning failed" "a failed move warns"
assert_contains "$out" "rc=0" "a failed move never fails the caller"

out=$(run_pin 0 '{"id":"fm-tab-move","result":{"type":"tab_list","tabs":[{"tab_id":"w1:t1","workspace_id":"w1"},{"tab_id":"w1:t2","workspace_id":"w1"}]}}')
assert_contains "$out" "unverifiable order" "a reply with the tab not first warns"
assert_contains "$out" "rc=0" "an unverifiable reply never fails the caller"

pass "herdr tab pin"
