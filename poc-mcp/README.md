First Mate MCP proof of concept

This directory is exploratory scaffolding for task-gluj4 and ships local-only with no PR and no merge.

First Mate stays the implementation and this layer only exposes existing capabilities as typed tools.

## Layout

`fm_mcp_server.py` is the stdio MCP server with zero dependencies beyond Python 3.

`test_client.py` is the external-client proof that handshakes and exercises every tool.

`INVENTORY.md` holds the full capability inventory and the typed mapping with read-versus-write boundaries.

`FINDINGS.md` holds the schemas reference, exclusions, full-coverage requirements, and the recommendation.

## Run

Start the server with `python3 poc-mcp/fm_mcp_server.py` speaking newline-delimited JSON-RPC on stdio.

The server resolves its checkout root from its own path and passes `FM_HOME` through, defaulting to that root.

Logs go to stderr so stdout stays pure protocol.

## Test

Run `python3 poc-mcp/test_client.py` for the 17-check end-to-end proof.

The suite covers handshake, tool listing, snapshot schema, backlog, current state, traversal refusals, steer validation, fail-closed steering, and protocol errors.

## Tools

Reads: `fleet_snapshot`, `backlog`, `crew_state`, and `status_tail`.

Single safe write: `send_message`, which wraps only the verified plain-text `fm-send.sh` path.

Everything authority-bearing (lifecycle, merges, decisions, Relay sends) is intentionally absent.
