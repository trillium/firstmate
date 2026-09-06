#!/usr/bin/env python3
"""Clear one Herdr pane's lifecycle authority through the supported socket API.

The CLI exposes ``pane release-agent`` for custom integrations, but Herdr
protects official lifecycle sources from that command because their own hooks
must release them.  Firstmate uses the narrower ``pane.clear_agent_authority``
API only after its backend has independently proved that the exact pane is a
bare idle shell, so a stale official hook record cannot block a safe relaunch.

Usage: herdr-clear-agent-authority.py <socket_path> <pane_id>

Exit status:
  0  the server accepted the clear request;
  2  arguments or socket connection were invalid;
  3  the request could not be sent or its response could not be read;
  4  the response was malformed, mismatched, or reported an error.
"""

import json
import socket
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 5.0
RECV_CHUNK = 65536
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
REQUEST_ID = "fm-clear-agent-authority"


def _read_line(sock, deadline):
    buffer = b""
    while b"\n" not in buffer:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK)
        except (OSError, socket.timeout):
            return None
        if not chunk:
            return None
        buffer += chunk
        if len(buffer) > MAX_RESPONSE_BYTES:
            return None
    return buffer.split(b"\n", 1)[0]


def main(argv):
    if len(argv) != 3:
        return 2
    socket_path, pane_id = argv[1:]
    if not socket_path.startswith("/") or not pane_id:
        return 2
    if any(char in pane_id for char in "\t\r\n"):
        return 2

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(socket_path)
    except OSError:
        return 2

    request = {
        "id": REQUEST_ID,
        "method": "pane.clear_agent_authority",
        "params": {"pane_id": pane_id},
    }
    try:
        sock.sendall(
            (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
        )
    except OSError:
        return 3

    line = _read_line(sock, time.monotonic() + RESPONSE_TIMEOUT)
    if line is None:
        return 3
    try:
        response = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 4
    if (
        not isinstance(response, dict)
        or response.get("id") != REQUEST_ID
        or response.get("error") is not None
        or not isinstance(response.get("result"), dict)
    ):
        return 4
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
