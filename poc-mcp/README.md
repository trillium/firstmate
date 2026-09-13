First Mate MCP proof of concept

This directory is exploratory scaffolding for task-gluj4 and ships local-only with no PR and no merge.

First Mate stays the implementation and this layer only exposes existing capabilities as typed tools.

## Layout

`fm_mcp_server.py` is the stdio MCP server with zero dependencies beyond Python 3.

`test_client.py` is the external-client proof that handshakes and exercises every tool.

`INVENTORY.md` holds the full capability inventory and the typed mapping with read-versus-write boundaries.

`FINDINGS.md` holds the full-coverage results, the nothing-held-back posture, and the residual risks.
`AUTH.md` holds the four authorization tiers with the explicit approval rule.

## Run

Start the server with `python3 poc-mcp/fm_mcp_server.py` speaking newline-delimited JSON-RPC on stdio.

The server resolves its checkout root from its own path and passes `FM_HOME` through, defaulting to that root.

Logs go to stderr so stdout stays pure protocol.

## Test

Run `python3 poc-mcp/test_client.py` for the 66-check end-to-end proof.
The suite covers handshake, tool listing, snapshot schema, backlog, current state, traversal refusals, steer validation, fail-closed steering, protocol errors, and every new tool's refusal paths in a sandbox home.

## Tools

Reads: `fleet_snapshot`, `backlog`, `crew_state`, and `status_tail`.

Single safe write: `send_message`, which wraps only the verified plain-text `fm-send.sh` path.
Authority writes (approval required): lifecycle verbs, `spawn_crew`, `scaffold_brief`, `promote_scout`, `teardown_crew` (never `--force`), `arm_pr_check`, `merge_pr`, `merge_local`, `decision_hold`, `decision_resolve`, and `review_decision`.
External sends (approval required): `relay_reply`, `relay_dismiss`, and `relay_followup`.
Read-only poller: `fleet_poll` over `fleet_snapshot`; see `AUTH.md` for the tier list.
