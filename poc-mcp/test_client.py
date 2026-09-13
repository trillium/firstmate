#!/usr/bin/env python3
"""External MCP client proof for the First Mate full-coverage server (stdlib only)."""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SERVER = Path(__file__).resolve().parent / "fm_mcp_server.py"
CHECKS = []
APPROVAL = "I authorize full-coverage PoC use"


def check(name, cond, detail=""):
    CHECKS.append((name, bool(cond), detail))
    print(("PASS " if cond else "FAIL ") + name + (f" :: {detail}" if detail and not cond else ""))


class Client:
    def __init__(self, env=None):
        merged = dict(os.environ)
        if env:
            merged.update(env)
        self.proc = subprocess.Popen(
            [sys.executable, str(SERVER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            env=merged,
        )
        self.seq = 0

    def request(self, method, params=None):
        self.seq += 1
        msg = {"jsonrpc": "2.0", "id": self.seq, "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())

    def notify(self, method):
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.proc.stdin.flush()

    def call(self, name, args):
        return self.request("tools/call", {"name": name, "arguments": args})

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def payload(resp):
    return json.loads(resp["result"]["content"][0]["text"])


def is_error(resp):
    return resp["result"].get("isError") is True


def main():
    client = Client()
    try:
        resp = client.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "poc-test-client", "version": "0.1.0"},
        })
        check("handshake negotiates version", resp["result"]["protocolVersion"] == "2024-11-05")
        check("server identifies itself", resp["result"]["serverInfo"]["name"] == "firstmate-mcp-poc")
        client.notify("notifications/initialized")

        resp = client.request("tools/list")
        names = {t["name"] for t in resp["result"]["tools"]}
        check("tools list keeps the 5 PoC tools", {
            "fleet_snapshot", "backlog", "crew_state", "status_tail", "send_message",
        } <= names, sorted(names))
        check("tools carry input schemas", all("inputSchema" in t for t in resp["result"]["tools"]))

        resp = client.call("fleet_snapshot", {})
        snap = payload(resp)
        check("fleet_snapshot returns canonical schema", snap.get("schema") == "fm-fleet-snapshot.v1", str(snap)[:200])
        check("fleet_snapshot has backlog plus tasks", "backlog" in snap and "tasks" in snap)

        resp = client.call("backlog", {})
        back = payload(resp)
        check("backlog returns records plus counts", "backlog" in back and "task_counts" in back)

        resp = client.call("crew_state", {"id": "no-such-id"})
        state = payload(resp)
        check("crew_state answers unknown for missing id", state["current"]["state"] == "unknown", str(state)[:200])

        resp = client.call("crew_state", {"id": "../escape"})
        check("crew_state rejects traversal", resp["result"].get("isError") is True)

        resp = client.call("status_tail", {"id": "no-such-id", "lines": 5})
        check("status_tail missing id is structured error", resp["result"].get("isError") is True)
        resp = client.call("status_tail", {"id": "x/../../y"})
        check("status_tail rejects traversal", resp["result"].get("isError") is True)

        resp = client.call("send_message", {"target": "no-such-id", "text": "hello"})
        check("send_message fail-closed stays structured", resp["result"].get("isError") is True)
        resp = client.call("send_message", {"target": "x", "text": "/merge now"})
        check("send_message refuses slash", "slash" in payload(resp).get("error", ""))
        resp = client.call("send_message", {"target": "x", "text": "one\ntwo"})
        check("send_message refuses multiline", resp["result"].get("isError") is True)
        resp = client.call("send_message", {"target": "x", "text": "z" * 501})
        check("send_message enforces length cap", resp["result"].get("isError") is True)

        resp = client.call("nope", {})
        check("unknown tool is JSON-RPC error", "error" in resp and resp["error"]["code"] == -32602)

        resp = client.request("ping")
        check("ping answers", resp["result"] == {})
    finally:
        client.close()

    sandbox = tempfile.mkdtemp(prefix="fm-mcp-full-")
    boxed = Client(env={"FM_HOME": sandbox})
    try:
        boxed.notify("notifications/initialized")
        resp = boxed.request("tools/list")
        names = {t["name"] for t in resp["result"]["tools"]}
        check("full server lists 24 tools", len(names) == 24, sorted(names))
        for required in ("lifecycle_interrupt", "spawn_crew", "scaffold_brief",
                         "promote_scout", "teardown_crew", "arm_pr_check",
                         "merge_pr", "merge_local", "decision_hold",
                         "decision_resolve", "review_decision", "relay_reply",
                         "relay_dismiss", "relay_followup", "fleet_poll"):
            check(f"tool present: {required}", required in names)
        check("every authority tool schema requires approval", all(
            "approval" in (t.get("inputSchema", {}).get("required", []) or [])
            for t in resp["result"]["tools"]
            if t["name"] not in ("fleet_snapshot", "backlog", "crew_state", "status_tail", "send_message", "fleet_poll")
        ))

        resp = boxed.call("lifecycle_interrupt", {"id": "no-such-id"})
        check("interrupt refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))
        resp = boxed.call("lifecycle_interrupt", {"id": "../escape", "approval": APPROVAL})
        check("interrupt rejects traversal", is_error(resp))
        resp = boxed.call("lifecycle_interrupt", {"id": "no-such-id", "approval": APPROVAL})
        check("interrupt unknown id stays structured", is_error(resp))

        resp = boxed.call("lifecycle_exit", {"id": "no-such-id"})
        check("exit refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))
        resp = boxed.call("lifecycle_exit", {"id": "no-such-id", "approval": APPROVAL})
        check("exit unknown id stays structured", is_error(resp))

        resp = boxed.call("lifecycle_relaunch", {"id": "no-such-id", "note": "retry", "approval": APPROVAL})
        check("relaunch unknown id stays structured", is_error(resp))
        resp = boxed.call("lifecycle_relaunch", {"id": "no-such-id", "approval": APPROVAL})
        check("relaunch requires note", is_error(resp))

        resp = boxed.call("lifecycle_suspend", {"id": "no-such-id", "note": "park", "approval": APPROVAL})
        check("suspend unknown id stays structured", is_error(resp))
        resp = boxed.call("lifecycle_resume", {"id": "no-such-id", "note": "back", "approval": APPROVAL})
        check("resume unknown id stays structured", is_error(resp))

        resp = boxed.call("spawn_crew", {"task_id": "no-such-id", "project": "no-such-project",
                                         "mode": "local-only", "yolo": "off"})
        check("spawn refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))
        resp = boxed.call("spawn_crew", {"task_id": "../x", "project": "p",
                                         "mode": "local-only", "yolo": "off", "approval": APPROVAL})
        check("spawn rejects traversal id", is_error(resp))
        resp = boxed.call("spawn_crew", {"task_id": "no-such-id", "project": "/abs/path",
                                         "mode": "local-only", "yolo": "off", "approval": APPROVAL})
        check("spawn rejects absolute project", is_error(resp))
        resp = boxed.call("spawn_crew", {"task_id": "no-such-id", "project": "no-such-project",
                                         "mode": "local-only", "yolo": "off", "approval": APPROVAL})
        check("spawn unknown target stays structured", is_error(resp))

        resp = boxed.call("scaffold_brief", {"task_id": "no-such-id", "project": "no-such-project", "mode": "scout"})
        check("brief refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))
        resp = boxed.call("scaffold_brief", {"task_id": "no-such-id", "project": "no-such-project",
                                             "mode": "bogus", "approval": APPROVAL})
        check("brief rejects bad mode", is_error(resp))

        resp = boxed.call("promote_scout", {"task_id": "no-such-id", "mode": "local-only", "yolo": "off"})
        check("promote refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))
        resp = boxed.call("promote_scout", {"task_id": "no-such-id", "mode": "local-only",
                                            "yolo": "off", "approval": APPROVAL})
        check("promote unknown id stays structured", is_error(resp))

        resp = boxed.call("teardown_crew", {"task_id": "../escape", "approval": APPROVAL})
        check("teardown rejects traversal", is_error(resp))
        resp = boxed.call("teardown_crew", {"task_id": "no-such-id", "approval": APPROVAL})
        check("teardown unknown id stays structured", is_error(resp))

        resp = boxed.call("arm_pr_check", {"task_id": "no-such-id",
                                           "pr_url": "https://github.com/trillium/firstmate/pull/1",
                                           "approval": APPROVAL})
        check("pr check unknown id stays structured", is_error(resp))
        resp = boxed.call("arm_pr_check", {"task_id": "no-such-id", "pr_url": "not-a-url", "approval": APPROVAL})
        check("pr check rejects bad url", is_error(resp))

        resp = boxed.call("merge_pr", {"task_id": "no-such-id",
                                       "pr_url": "https://github.com/trillium/firstmate/pull/1"})
        check("merge refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))
        resp = boxed.call("merge_local", {"task_id": "no-such-id", "approval": APPROVAL})
        check("local merge unknown id stays structured", is_error(resp))

        resp = boxed.call("decision_hold", {"origin_id": "no-such-id", "decision_key": "k1",
                                            "title": "t", "reason": "r"})
        check("decision hold refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))
        resp = boxed.call("decision_resolve", {"origin_id": "x", "decision_key": "k",
                                               "routed_to": "y", "decision_text": "d"})
        check("decision resolve refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))

        resp = boxed.call("review_decision", {"id": "no-such-id", "verdict": "approve"})
        check("review refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))
        resp = boxed.call("review_decision", {"id": "no-such-id", "verdict": "bogus", "approval": APPROVAL})
        check("review rejects bad verdict", is_error(resp))

        resp = boxed.call("relay_reply", {"request_id": "no-such-id", "text": "hello"})
        check("relay reply refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))
        resp = boxed.call("relay_reply", {"request_id": "../x", "text": "hello", "approval": APPROVAL})
        check("relay reply rejects traversal", is_error(resp))
        resp = boxed.call("relay_dismiss", {"request_id": "no-such-id"})
        check("relay dismiss refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))
        resp = boxed.call("relay_followup", {"task_id": "no-such-id", "text": "done"})
        check("relay followup refuses without approval", is_error(resp) and "approval" in payload(resp).get("error", ""))

        resp = boxed.call("fleet_poll", {"count": 2, "interval_s": 0})
        polled = payload(resp)
        check("fleet_poll returns poll summaries", not is_error(resp) and len(polled.get("polls", [])) == 2)
    finally:
        boxed.close()
    failed = [n for n, ok, _ in CHECKS if not ok]
    print(f"{len(CHECKS) - len(failed)}/{len(CHECKS)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
