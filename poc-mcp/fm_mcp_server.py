#!/usr/bin/env python3
"""First Mate MCP full-coverage server (stdlib only, no dependencies)."""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SERVER_NAME = "firstmate-mcp-poc"
SERVER_VERSION = "0.2.0"
SUPPORTED_PROTOCOL_VERSIONS = ("2024-11-05", "2025-03-26", "2025-06-18")
SNAPSHOT_SCHEMA = "fm-fleet-snapshot.v1"
CHECKOUT_ROOT = Path(__file__).resolve().parent.parent
BIN = CHECKOUT_ROOT / "bin"
MAX_OUTPUT_BYTES = 131072
TAIL_CAP_BYTES = 8192
SUBPROCESS_TIMEOUT_S = 30
SEND_TEXT_MAX_CHARS = 500
APPROVAL_PREFIX = "I authorize"
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}")
PROJECT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_./-]{0,199}")
PR_URL_RE = re.compile(r"https://\S{1,500}")
MODES = ("no-mistakes", "direct-PR", "local-only")
BRIEF_MODES = ("no-mistakes", "direct-PR", "local-only", "scout")
VERDICTS = ("approve", "decline", "comment")


def home_dir():
    return Path(os.environ.get("FM_HOME", str(CHECKOUT_ROOT)))


def state_dir():
    override = os.environ.get("FM_STATE_OVERRIDE")
    return Path(override) if override else home_dir() / "state"


def valid_id(value):
    return isinstance(value, str) and ID_RE.fullmatch(value) is not None


def valid_project(value):
    if not isinstance(value, str) or PROJECT_RE.fullmatch(value) is None:
        return False
    if ".." in value or value.startswith("/"):
        return False
    return True


def valid_pr_url(value):
    return isinstance(value, str) and PR_URL_RE.fullmatch(value) is not None


def valid_note(value, cap=500):
    return (
        isinstance(value, str)
        and 1 <= len(value) <= cap
        and "\n" not in value
        and "\r" not in value
    )


def valid_approval(value):
    return isinstance(value, str) and value.startswith(APPROVAL_PREFIX) and len(value) <= 500


def approval_error():
    return {
        "error": "approval required",
        "expect": "explicit approval string starting with 'I authorize'",
    }


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


def owned_call(argv, label):
    proc, err = run_script(argv)
    if err:
        return err, True
    out, out_trunc = truncate(proc.stdout or "")
    err_out, err_trunc = truncate(proc.stderr or "")
    if proc.returncode != 0:
        return {
            "error": label,
            "exit": proc.returncode,
            "stdout": out,
            "stderr": err_out,
        }, True
    return {
        "ok": True,
        "stdout": out,
        "stdout_truncated": out_trunc,
        "stderr": err_out,
        "stderr_truncated": err_trunc,
    }, False


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


def lifecycle_tool(args, verb, needs_note):
    task_id = args.get("id")
    if not valid_id(task_id):
        return {"error": "invalid id", "expect": "short task id, no slashes or traversal"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    argv = [BIN / "fm-control.sh", task_id, verb]
    if needs_note:
        note = args.get("note")
        if not valid_note(note):
            return {"error": "invalid note", "expect": "single line, 1..500 chars"}, True
        argv += ["--note", note]
    payload, is_error = owned_call(argv, f"{verb} refused or failed")
    if not is_error:
        payload = dict(payload)
        payload.update({"verb": verb, "id": task_id})
    return payload, is_error


def tool_lifecycle_interrupt(args):
    return lifecycle_tool(args, "interrupt", False)


def tool_lifecycle_exit(args):
    return lifecycle_tool(args, "exit", False)


def tool_lifecycle_relaunch(args):
    return lifecycle_tool(args, "relaunch", True)


def tool_lifecycle_suspend(args):
    return lifecycle_tool(args, "suspend", True)


def tool_lifecycle_resume(args):
    return lifecycle_tool(args, "resume", True)


def tool_spawn_crew(args):
    task_id = args.get("task_id")
    project = args.get("project")
    mode = args.get("mode")
    yolo = args.get("yolo")
    if not valid_id(task_id):
        return {"error": "invalid task_id", "expect": "short task id, no slashes or traversal"}, True
    if not valid_project(project):
        return {"error": "invalid project", "expect": "bare name or projects/<name>, no absolute paths or traversal"}, True
    if mode not in MODES:
        return {"error": "invalid mode", "expect": "one of no-mistakes, direct-PR, local-only"}, True
    if yolo not in ("on", "off"):
        return {"error": "invalid yolo", "expect": "one of on, off"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    payload, is_error = owned_call(
        [BIN / "fm-spawn.sh", task_id, project, "--mode", mode, "--yolo", yolo],
        "spawn refused or failed",
    )
    if not is_error:
        payload = dict(payload)
        payload.update({"task_id": task_id, "project": project, "mode": mode})
    return payload, is_error


def tool_scaffold_brief(args):
    task_id = args.get("task_id")
    project = args.get("project")
    mode = args.get("mode")
    if not valid_id(task_id):
        return {"error": "invalid task_id", "expect": "short task id, no slashes or traversal"}, True
    if not valid_project(project):
        return {"error": "invalid project", "expect": "bare name or projects/<name>, no absolute paths or traversal"}, True
    if mode not in BRIEF_MODES:
        return {"error": "invalid mode", "expect": "one of no-mistakes, direct-PR, local-only, scout"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    argv = [BIN / "fm-brief.sh", task_id, project]
    argv += ["--scout"] if mode == "scout" else ["--mode", mode]
    payload, is_error = owned_call(argv, "brief refused or failed")
    if not is_error:
        payload = dict(payload)
        payload.update({"task_id": task_id, "project": project, "mode": mode})
    return payload, is_error


def tool_promote_scout(args):
    task_id = args.get("task_id")
    mode = args.get("mode")
    yolo = args.get("yolo")
    if not valid_id(task_id):
        return {"error": "invalid task_id", "expect": "short task id, no slashes or traversal"}, True
    if mode not in MODES:
        return {"error": "invalid mode", "expect": "one of no-mistakes, direct-PR, local-only"}, True
    if yolo not in ("on", "off"):
        return {"error": "invalid yolo", "expect": "one of on, off"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    payload, is_error = owned_call(
        [BIN / "fm-promote.sh", task_id, "--mode", mode, "--yolo", yolo],
        "promote refused or failed",
    )
    if not is_error:
        payload = dict(payload)
        payload.update({"task_id": task_id, "mode": mode})
    return payload, is_error


def tool_teardown_crew(args):
    task_id = args.get("task_id")
    if not valid_id(task_id):
        return {"error": "invalid task_id", "expect": "short task id, no slashes or traversal"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    payload, is_error = owned_call(
        [BIN / "fm-teardown.sh", task_id],
        "teardown refused or failed",
    )
    if not is_error:
        payload = dict(payload)
        payload.update({"task_id": task_id})
    return payload, is_error


def tool_arm_pr_check(args):
    task_id = args.get("task_id")
    pr_url = args.get("pr_url")
    if not valid_id(task_id):
        return {"error": "invalid task_id", "expect": "short task id, no slashes or traversal"}, True
    if not valid_pr_url(pr_url):
        return {"error": "invalid pr_url", "expect": "https:// PR or MR url, no spaces"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    payload, is_error = owned_call(
        [BIN / "fm-pr-check.sh", task_id, pr_url],
        "pr check arming refused or failed",
    )
    if not is_error:
        payload = dict(payload)
        payload.update({"task_id": task_id})
    return payload, is_error


def tool_merge_pr(args):
    task_id = args.get("task_id")
    pr_url = args.get("pr_url")
    if not valid_id(task_id):
        return {"error": "invalid task_id", "expect": "short task id, no slashes or traversal"}, True
    if not valid_pr_url(pr_url):
        return {"error": "invalid pr_url", "expect": "https:// PR url, no spaces"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    payload, is_error = owned_call(
        [BIN / "fm-pr-merge.sh", task_id, pr_url],
        "pr merge refused or failed",
    )
    if not is_error:
        payload = dict(payload)
        payload.update({"task_id": task_id})
    return payload, is_error


def tool_merge_local(args):
    task_id = args.get("task_id")
    if not valid_id(task_id):
        return {"error": "invalid task_id", "expect": "short task id, no slashes or traversal"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    payload, is_error = owned_call(
        [BIN / "fm-merge-local.sh", task_id],
        "local merge refused or failed",
    )
    if not is_error:
        payload = dict(payload)
        payload.update({"task_id": task_id})
    return payload, is_error


def tool_decision_hold(args):
    origin_id = args.get("origin_id")
    decision_key = args.get("decision_key")
    title = args.get("title")
    reason = args.get("reason")
    if not valid_id(origin_id):
        return {"error": "invalid origin_id", "expect": "short task id, no slashes or traversal"}, True
    if not valid_id(decision_key):
        return {"error": "invalid decision_key", "expect": "short slug, no slashes or traversal"}, True
    if not valid_note(title, 200):
        return {"error": "invalid title", "expect": "single line, 1..200 chars"}, True
    if not valid_note(reason, 1000):
        return {"error": "invalid reason", "expect": "single line, 1..1000 chars"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    payload, is_error = owned_call(
        [BIN / "fm-decision-hold.sh", "hold", origin_id, decision_key,
         "--title", title, "--reason", reason],
        "decision hold refused or failed",
    )
    if not is_error:
        payload = dict(payload)
        payload.update({"origin_id": origin_id, "decision_key": decision_key})
    return payload, is_error


def tool_decision_resolve(args):
    origin_id = args.get("origin_id")
    decision_key = args.get("decision_key")
    routed_to = args.get("routed_to")
    decision_text = args.get("decision_text")
    if not valid_id(origin_id):
        return {"error": "invalid origin_id", "expect": "short task id, no slashes or traversal"}, True
    if not valid_id(decision_key):
        return {"error": "invalid decision_key", "expect": "short slug, no slashes or traversal"}, True
    if not valid_id(routed_to):
        return {"error": "invalid routed_to", "expect": "short task id, no slashes or traversal"}, True
    if not isinstance(decision_text, str) or not 1 <= len(decision_text) <= 2000:
        return {"error": "invalid decision_text", "expect": "1..2000 chars"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    tmp = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as handle:
            handle.write(decision_text)
            tmp = handle.name
        payload, is_error = owned_call(
            [BIN / "fm-decision-hold.sh", "resolve", origin_id, decision_key,
             "--decision-file", tmp, "--routed-to", routed_to],
            "decision resolve refused or failed",
        )
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    if not is_error:
        payload = dict(payload)
        payload.update({"origin_id": origin_id, "decision_key": decision_key})
    return payload, is_error


def tool_review_decision(args):
    task_id = args.get("id")
    verdict = args.get("verdict")
    comment = args.get("comment", "")
    if not valid_id(task_id):
        return {"error": "invalid id", "expect": "short task id, no slashes or traversal"}, True
    if verdict not in VERDICTS:
        return {"error": "invalid verdict", "expect": "one of approve, decline, comment"}, True
    if comment and not valid_note(comment):
        return {"error": "invalid comment", "expect": "single line, 1..500 chars"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    argv = [BIN / "fm-review-decision.sh", task_id, verdict]
    if comment:
        argv.append(comment)
    payload, is_error = owned_call(argv, "review decision refused or failed")
    if not is_error:
        payload = dict(payload)
        payload.update({"id": task_id, "verdict": verdict})
    return payload, is_error


def tool_relay_reply(args):
    request_id = args.get("request_id")
    text = args.get("text")
    if not valid_id(request_id):
        return {"error": "invalid request_id", "expect": "short slug, no slashes or traversal"}, True
    if not isinstance(text, str) or not 1 <= len(text) <= 2000:
        return {"error": "invalid text", "expect": "1..2000 chars"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    payload, is_error = owned_call(
        [BIN / "fm-x-reply.sh", request_id, text],
        "relay reply refused or failed",
    )
    if not is_error:
        payload = dict(payload)
        payload.update({"request_id": request_id})
    return payload, is_error


def tool_relay_dismiss(args):
    request_id = args.get("request_id")
    if not valid_id(request_id):
        return {"error": "invalid request_id", "expect": "short slug, no slashes or traversal"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    payload, is_error = owned_call(
        [BIN / "fm-x-dismiss.sh", request_id],
        "relay dismiss refused or failed",
    )
    if not is_error:
        payload = dict(payload)
        payload.update({"request_id": request_id})
    return payload, is_error


def tool_relay_followup(args):
    task_id = args.get("task_id")
    text = args.get("text")
    final = args.get("final", False)
    if not valid_id(task_id):
        return {"error": "invalid task_id", "expect": "short task id, no slashes or traversal"}, True
    if not isinstance(text, str) or not 1 <= len(text) <= 2000:
        return {"error": "invalid text", "expect": "1..2000 chars"}, True
    if not isinstance(final, bool):
        return {"error": "invalid final", "expect": "boolean"}, True
    if not valid_approval(args.get("approval")):
        return approval_error(), True
    tmp = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as handle:
            handle.write(text)
            tmp = handle.name
        argv = [BIN / "fm-x-followup.sh", task_id, "--text-file", tmp]
        if final:
            argv.append("--final")
        payload, is_error = owned_call(argv, "relay followup refused or failed")
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    if not is_error:
        payload = dict(payload)
        payload.update({"task_id": task_id})
    return payload, is_error


def tool_fleet_poll(args):
    try:
        count = int(args.get("count", 2))
    except (TypeError, ValueError):
        return {"error": "invalid count", "expect": "integer 1..3"}, True
    try:
        interval_s = float(args.get("interval_s", 0))
    except (TypeError, ValueError):
        return {"error": "invalid interval_s", "expect": "number 0..2"}, True
    count = max(1, min(3, count))
    interval_s = max(0.0, min(2.0, interval_s))
    polls = []
    for _ in range(count):
        snapshot, is_error = tool_fleet_snapshot({})
        if is_error:
            return snapshot, True
        polls.append({
            "generated": snapshot.get("generated"),
            "tasks": len(snapshot.get("tasks", [])),
        })
        if interval_s > 0:
            time.sleep(interval_s)
    return {
        "polls": polls,
        "warning": "polling convenience only; fleet_snapshot stays canonical",
    }, False


def approval_schema(extra):
    props = dict(extra)
    props["approval"] = {
        "type": "string",
        "description": "Explicit authorization starting with 'I authorize'",
    }
    return {"type": "object", "properties": props, "required": [*extra.keys(), "approval"], "additionalProperties": False}


def id_approval_schema(id_field="id"):
    return approval_schema({id_field: {"type": "string", "description": "Task id"}})


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
    "lifecycle_interrupt": (
        "Authority write: deliver the harness interrupt sequence to one crew; agent keeps running.",
        id_approval_schema(),
        tool_lifecycle_interrupt,
    ),
    "lifecycle_exit": (
        "Authority write: stop one agent, preserving its endpoint, worktree, and uncommitted changes.",
        id_approval_schema(),
        tool_lifecycle_exit,
    ),
    "lifecycle_relaunch": (
        "Authority write: transactionally replace one running agent in the same endpoint and worktree.",
        approval_schema({
            "id": {"type": "string", "description": "Task id"},
            "note": {"type": "string", "description": "Progress note, single line 1..500 chars"},
        }),
        tool_lifecycle_relaunch,
    ),
    "lifecycle_suspend": (
        "Authority write: park one persistent secondmate with a durable note.",
        approval_schema({
            "id": {"type": "string", "description": "Task id"},
            "note": {"type": "string", "description": "Park note, single line 1..500 chars"},
        }),
        tool_lifecycle_suspend,
    ),
    "lifecycle_resume": (
        "Authority write: restore one parked secondmate with a durable note.",
        approval_schema({
            "id": {"type": "string", "description": "Task id"},
            "note": {"type": "string", "description": "Resume note, single line 1..500 chars"},
        }),
        tool_lifecycle_resume,
    ),
    "spawn_crew": (
        "Authority write: spawn one direct report via fm-spawn.sh with an explicit delivery contract.",
        approval_schema({
            "task_id": {"type": "string"},
            "project": {"type": "string", "description": "Bare name or projects/<name>"},
            "mode": {"type": "string", "enum": list(MODES)},
            "yolo": {"type": "string", "enum": ["on", "off"]},
        }),
        tool_spawn_crew,
    ),
    "scaffold_brief": (
        "Authority write: scaffold one crewmate brief via fm-brief.sh; does not launch anything.",
        approval_schema({
            "task_id": {"type": "string"},
            "project": {"type": "string", "description": "Bare name or projects/<name>"},
            "mode": {"type": "string", "enum": list(BRIEF_MODES)},
        }),
        tool_scaffold_brief,
    ),
    "promote_scout": (
        "Authority write: promote one scout to a ship in place with its delivery contract.",
        approval_schema({
            "task_id": {"type": "string"},
            "mode": {"type": "string", "enum": list(MODES)},
            "yolo": {"type": "string", "enum": ["on", "off"]},
        }),
        tool_promote_scout,
    ),
    "teardown_crew": (
        "Authority write: clean up one task via fm-teardown.sh; never force-discards through MCP.",
        id_approval_schema("task_id"),
        tool_teardown_crew,
    ),
    "arm_pr_check": (
        "Authority write: arm the watcher merge poll for one task PR via fm-pr-check.sh.",
        approval_schema({
            "task_id": {"type": "string"},
            "pr_url": {"type": "string", "description": "https:// PR or MR url"},
        }),
        tool_arm_pr_check,
    ),
    "merge_pr": (
        "Authority write: merge one task PR through merge guards via fm-pr-merge.sh.",
        approval_schema({
            "task_id": {"type": "string"},
            "pr_url": {"type": "string", "description": "https:// PR url"},
        }),
        tool_merge_pr,
    ),
    "merge_local": (
        "Authority write: fast-forward the default branch for one local-only task via fm-merge-local.sh.",
        id_approval_schema("task_id"),
        tool_merge_local,
    ),
    "decision_hold": (
        "Authority write: record one durable captain-held decision via fm-decision-hold.sh hold.",
        approval_schema({
            "origin_id": {"type": "string"},
            "decision_key": {"type": "string", "description": "Short slug"},
            "title": {"type": "string"},
            "reason": {"type": "string"},
        }),
        tool_decision_hold,
    ),
    "decision_resolve": (
        "Authority write: resolve one held decision via fm-decision-hold.sh resolve with a decision file.",
        approval_schema({
            "origin_id": {"type": "string"},
            "decision_key": {"type": "string"},
            "routed_to": {"type": "string", "description": "Task id receiving the decision"},
            "decision_text": {"type": "string", "description": "Decision record, 1..2000 chars"},
        }),
        tool_decision_resolve,
    ),
    "review_decision": (
        "Authority write: record one captain approve, decline, or comment via fm-review-decision.sh.",
        approval_schema({
            "id": {"type": "string"},
            "verdict": {"type": "string", "enum": list(VERDICTS)},
            "comment": {"type": "string", "description": "Optional single-line comment"},
        }),
        tool_review_decision,
    ),
    "relay_reply": (
        "External send: post one public-safe reply to the relay via fm-x-reply.sh.",
        approval_schema({
            "request_id": {"type": "string"},
            "text": {"type": "string", "description": "Reply text, 1..2000 chars"},
        }),
        tool_relay_reply,
    ),
    "relay_dismiss": (
        "External send: dismiss one pending relay mention without replying via fm-x-dismiss.sh.",
        id_approval_schema("request_id"),
        tool_relay_dismiss,
    ),
    "relay_followup": (
        "External send: post one completion follow-up for a relay-linked task via fm-x-followup.sh.",
        approval_schema({
            "task_id": {"type": "string"},
            "text": {"type": "string", "description": "Follow-up text, 1..2000 chars"},
            "final": {"type": "boolean", "description": "Clear the link after this post"},
        }),
        tool_relay_followup,
    ),
    "fleet_poll": (
        "Read-only convenience poller over fleet_snapshot for clients that need push-like updates.",
        {
            "type": "object",
            "properties": {
                "count": {"type": "integer", "minimum": 1, "maximum": 3, "default": 2},
                "interval_s": {"type": "number", "minimum": 0, "maximum": 2, "default": 0},
            },
            "additionalProperties": False,
        },
        tool_fleet_poll,
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
