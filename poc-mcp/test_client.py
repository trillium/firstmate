#!/usr/bin/env python3
"""External MCP client proof for the First Mate PoC server (stdlib only)."""
import json
import subprocess
import sys
from pathlib import Path

SERVER = Path(__file__).resolve().parent / "fm_mcp_server.py"
CHECKS = []


def check(name, cond, detail=""):
    CHECKS.append((name, bool(cond), detail))
    print(("PASS " if cond else "FAIL ") + name + (f" :: {detail}" if detail and not cond else ""))


class Client:
    def __init__(self):
        self.proc = subprocess.Popen(
            [sys.executable, str(SERVER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
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
        check("tools list has 5 PoC tools", names == {
            "fleet_snapshot", "backlog", "crew_state", "status_tail", "send_message",
        }, sorted(names))
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
    failed = [n for n, ok, _ in CHECKS if not ok]
    print(f"{len(CHECKS) - len(failed)}/{len(CHECKS)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
