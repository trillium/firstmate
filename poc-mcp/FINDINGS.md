First Mate MCP proof-of-concept findings (task-gluj4)

## What was built

`poc-mcp/fm_mcp_server.py` is a dependency-free stdio MCP server that exposes five typed tools over JSON-RPC.

`poc-mcp/test_client.py` is an external MCP client that handshakes, lists tools, and exercises every tool including all refusal paths.

All 17 client checks pass, and a scratch-home probe proved the positive read path plus the fail-closed steer path.

## What the PoC proves

An external client can inspect First Mate semantically without screen-scraping panes or misreading the append-only status log.

The typed boundary is enforceable in one place: ids are validated, paths are confined, text is capped and single-line, and slash commands never reach the composer.

First Mate stays the implementation because every tool shells to the owning script instead of reimplementing its logic.

Fail-closed behavior survives the mapping: steering an unknown target returns a structured error with no side effects.

## Intentionally excluded from the PoC

Lifecycle verbs (interrupt, exit, relaunch, suspend, resume), spawn, brief, promote, and teardown are excluded as irreversible or worker-replacing.

Merges, PR arming, decision-hold writes, review decisions, and all Relay sends are excluded as authority-bearing or externally visible.

Proactive server-initiated wake streaming (roots, sampling, or subscriptions) is excluded because the PoC is request-response only.

Batch JSON-RPC, progress tokens, and cancellation are excluded as unneeded for five tools.

## What full coverage would require

A permission-tier model distinguishing home-visible reads, reversible steers, authority-bearing writes, and externally visible sends.

Server-side pinning of `FM_HOME` plus per-client grants, so a client cannot repoint the server at another home through the environment.

Lifecycle and merge tools gated on the same authorities firstmate enforces today: yolo posture, merge authority, CodeRabbit gate, and relay consent.

A wake-subscription transport if clients need push instead of polling `fleet_snapshot` on an interval.

Conformance tests against a real MCP SDK client and a live crewmate steer in a lab home.

## Risks and recommendation

The largest risk is authority laundering, where a convenient tool lets a client do what firstmate policy would refuse.

The mitigation is layering: the MCP schema narrows the flags, the server validates again, and the owning script still fails closed.

Recommendation: keep this PoC local-only, rescope before any production wiring, and expand reads first with `bearings_snapshot` and `review_diff` next.
