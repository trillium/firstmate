#!/usr/bin/env python3
"""First Mate MCP proof-of-concept server (stdlib only, no dependencies)."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SERVER_NAME = "firstmate-mcp-poc"
SERVER_VERSION = "0.1.0"
SUPPORTED_PROTOCOL_VERSIONS = ("2024-11-05", "2025-03-26", "2025-06-18")
SNAPSHOT_SCHEMA = "fm-fleet-snapshot.v1"
CHECKOUT_ROOT = Path(__file__).resolve().parent.parent
BIN = CHECKOUT_ROOT / "bin"
MAX_OUTPUT_BYTES = 131072
TAIL_CAP_BYTES = 8192
SUBPROCESS_TIMEOUT_S = 30
SEND_TEXT_MAX_CHARS = 500
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}")


def home_dir():
    return Path(os.environ.get("FM_HOME", str(CHECKOUT_ROOT)))


def state_dir():
    override = os.environ.get("FM_STATE_OVERRIDE")
    return Path(override) if override else home_dir() / "state"


def valid_id(value):
    return isinstance(value, str) and ID_RE.fullmatch(value) is not None


def truncate(text, cap=TAIL_CAP_BYTES):
    if len(text.encode("utf-8", "replace")) <= cap:
        return text, False
    buf = text.encode("utf-8", "replace")[:cap].decode("utf-8", "replace")
    return buf + "\n…[truncated]", True


def run_script(argv):
    try:
        proc = subprocess.run(
            [str(a) for a in argv],
            cwd=str(CHECKOUT_ROOT),
            capture_output=True,
            text=True,
            timeout=SUBPROCESS_TIMEOUT_S,
        )
    except FileNotFoundError as exc:
        return None, {"error": "executable not found", "detail": str(exc)}
    except subprocess.TimeoutExpired:
        return None, {"error": "timed out", "timeout_s": SUBPROCESS_TIMEOUT_S}
    return proc, None


def tool_fleet_snapshot(_args):
    proc, err = run_script([BIN / "fm-fleet-snapshot.sh", "--json"])
    if err:
        return err, True
    if proc.returncode != 0:
        out, _ = truncate(proc.stderr or proc.stdout)
        return {"error": "snapshot failed", "exit": proc.returncode, "output": out}, True
    if len(proc.stdout.encode("utf-8", "replace")) > MAX_OUTPUT_BYTES:
        return {"error": "snapshot too large for PoC envelope"}, True
    try:
        snapshot = json.loads(proc.stdout)
    except json.JSONDecodeError:
        out, _ = truncate(proc.stdout)
        return {"error": "snapshot was not JSON", "output": out}, True
    if snapshot.get("schema") != SNAPSHOT_SCHEMA:
        return {"error": "unexpected snapshot schema", "schema": snapshot.get("schema")}, True
    return snapshot, False


def tool_backlog(_args):
    snapshot, is_error = tool_fleet_snapshot({})
    if is_error:
        return snapshot, True
    by_state = {}
    for task in snapshot.get("tasks", []):
        state = ((task.get("current_state") or {}).get("state")) or "unknown"
        by_state[state] = by_state.get(state, 0) + 1
    return {
        "generated": snapshot.get("generated"),
        "backlog": snapshot.get("backlog", {}),
        "task_counts": {"total": len(snapshot.get("tasks", [])), "by_state": by_state},
    }, False


def tool_crew_state(args):
    task_id = args.get("id")
    if not valid_id(task_id):
        return {"error": "invalid id", "expect": "short task id, no slashes or traversal"}, True
    proc, err = run_script([BIN / "fm-crew-state.sh", task_id])
    if err:
        return err, True
    raw = (proc.stdout or "").strip().splitlines()
    line = raw[0] if raw else ""
    parsed = {"state": "unknown", "source": "none", "detail": line}
    match = re.match(r"state:\s*(\S+)\s+·\s*source:\s*(\S+)\s+·\s*(.*)", line)
    if match:
        parsed = {"state": match.group(1), "source": match.group(2), "detail": match.group(3)}
    return {"id": task_id, "current": parsed, "raw": line}, False


def tool_status_tail(args):
    task_id = args.get("id")
    if not valid_id(task_id):
        return {"error": "invalid id", "expect": "short task id, no slashes or traversal"}, True
    try:
        lines = int(args.get("lines", 10))
    except (TypeError, ValueError):
        return {"error": "invalid lines", "expect": "integer 1..50"}, True
    lines = max(1, min(50, lines))
    path = (state_dir() / f"{task_id}.status").resolve()
    try:
        state_resolved = state_dir().resolve()
    except FileNotFoundError:
        return {"error": "no status log for id", "id": task_id}, True
    if path.parent != state_resolved:
        return {"error": "invalid id", "expect": "short task id, no slashes or traversal"}, True
    try:
        content = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        return {"error": "no status log for id", "id": task_id}, True
    except OSError as exc:
        return {"error": "cannot read status log", "detail": str(exc)}, True
    return {
        "id": task_id,
        "events": content[-lines:],
        "warning": "wake-event history only, never current state; use crew_state for current state",
    }, False


def tool_send_message(args):
    target = args.get("target")
    text = args.get("text")
    if not valid_id(target):
        return {"error": "invalid target", "expect": "exact task id, no slashes or traversal"}, True
    if not isinstance(text, str) or not 1 <= len(text) <= SEND_TEXT_MAX_CHARS:
        return {
            "error": "invalid text",
            "expect": f"single line, 1..{SEND_TEXT_MAX_CHARS} chars",
        }, True
    if "\n" in text or "\r" in text:
        return {"error": "invalid text", "expect": "single line, no newlines"}, True
    if text.lstrip().startswith("/"):
        return {"error": "slash commands refused", "expect": "plain prose steer only"}, True
    proc, err = run_script([BIN / "fm-send.sh", target, text])
    if err:
        return err, True
    out, out_trunc = truncate(proc.stdout or "")
    err_out, err_trunc = truncate(proc.stderr or "")
    if proc.returncode != 0:
        return {
            "error": "steer refused or failed",
            "target": target,
            "exit": proc.returncode,
            "stdout": out,
            "stderr": err_out,
        }, True
    return {
        "delivered": True,
        "target": target,
        "note": "verified submit per fm-send contract; delivery is not reply",
        "stdout": out,
        "stdout_truncated": out_trunc,
        "stderr_truncated": err_trunc,
    }, False


TOOLS = {
    "fleet_snapshot": (
        "Read-only canonical fleet snapshot (backlog plus per-task state).",
        {"type": "object", "properties": {}, "additionalProperties": False},
        tool_fleet_snapshot,
    ),
    "backlog": (
        "Read-only backlog records plus per-state task counts, derived from the fleet snapshot.",
        {"type": "object", "properties": {}, "additionalProperties": False},
        tool_backlog,
    ),
    "crew_state": (
        "Read-only deterministic current state of one crew; never infer state from the status log tail.",
        {
            "type": "object",
            "properties": {"id": {"type": "string", "description": "Task id"}},
            "required": ["id"],
            "additionalProperties": False,
        },
        tool_crew_state,
    ),
    "status_tail": (
        "Read-only tail of one task wake-event log; history only, not current state.",
        {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Task id"},
                "lines": {"type": "integer", "minimum": 1, "maximum": 50, "default": 10},
            },
            "required": ["id"],
            "additionalProperties": False,
        },
        tool_status_tail,
    ),
    "send_message": (
        "Steer one crew with a single verified prose line; slash commands, keys, raw panes, and lifecycle verbs are refused.",
        {
            "type": "object",
            "properties": {
                "target": {"type": "string", "description": "Exact task id"},
                "text": {"type": "string", "minLength": 1, "maxLength": 500},
            },
            "required": ["target", "text"],
            "additionalProperties": False,
        },
        tool_send_message,
    ),
}


def reply(msg_id, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}) + "\n")
    sys.stdout.flush()


def reply_error(msg_id, code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "error": err}) + "\n")
    sys.stdout.flush()


def handle_initialize(msg_id, params):
    params = params or {}
    requested = params.get("protocolVersion")
    version = requested if requested in SUPPORTED_PROTOCOL_VERSIONS else SUPPORTED_PROTOCOL_VERSIONS[-1]
    reply(msg_id, {
        "protocolVersion": version,
        "capabilities": {"tools": {}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
    })


def handle_tools_list(msg_id):
    reply(msg_id, {
        "tools": [
            {"name": name, "description": desc, "inputSchema": schema}
            for name, (desc, schema, _) in TOOLS.items()
        ]
    })


def handle_tools_call(msg_id, params):
    params = params or {}
    name = params.get("name")
    args = params.get("arguments") or {}
    if name not in TOOLS:
        reply_error(msg_id, -32602, f"unknown tool: {name}")
        return
    if not isinstance(args, dict):
        reply_error(msg_id, -32602, "arguments must be an object")
        return
    _, _, func = TOOLS[name]
    try:
        payload, is_error = func(args)
    except Exception as exc:  # never crash the session on a tool failure
        payload, is_error = {"error": "tool crashed", "detail": str(exc)}, True
    result = {"content": [{"type": "text", "text": json.dumps(payload)}]}
    if is_error:
        result["isError"] = True
    reply(msg_id, result)


def main():
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            reply_error(None, -32700, "parse error")
            continue
        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}
        if method == "initialize":
            handle_initialize(msg_id, params)
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            handle_tools_list(msg_id)
        elif method == "tools/call":
            handle_tools_call(msg_id, params)
        elif method == "ping":
            reply(msg_id, {})
        elif isinstance(method, str) and method.startswith("notifications/"):
            continue
        elif msg_id is not None:
            reply_error(msg_id, -32601, f"method not found: {method}")


if __name__ == "__main__":
    main()
