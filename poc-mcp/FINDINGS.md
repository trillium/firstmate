First Mate MCP full-coverage findings (poc-full)

## What changed

`poc-mcp/fm_mcp_server.py` grew from 5 PoC tools to 24 tools with no dependency beyond Python 3.

The 5 original tools (`fleet_snapshot`, `backlog`, `crew_state`, `status_tail`, `send_message`) are behavior-identical and their original checks still pass.

19 new tools shell to the owning `bin/` scripts: 5 lifecycle verbs, `spawn_crew`, `scaffold_brief`, `promote_scout`, `teardown_crew`, `arm_pr_check`, `merge_pr`, `merge_local`, `decision_hold`, `decision_resolve`, `review_decision`, `relay_reply`, `relay_dismiss`, `relay_followup`, and the read-only `fleet_poll` convenience poller.

`poc-mcp/AUTH.md` documents the four tiers: open reads, reversible steers, authority writes, and external sends.

`poc-mcp/test_client.py` now runs 66 checks: the original 17 (with the tool-count assertion widened to subset) plus refusal-path coverage for every new tool.

All 66 client checks pass, with sandbox-home isolation (`FM_HOME` pointed at a temp dir) for every side-effecting test.

## What full coverage now requires

Nothing is held back per the explicit owner order of 2026-09-13: Trillium authorizes each use or not.

Every authority-bearing or externally visible tool takes an explicit `approval` argument starting with `I authorize` and refuses without it.

Reads stay open and `send_message` keeps its PoC validation (500-char single line, no slash commands).

Teardown through MCP never passes `--force`, so discarding unlanded work still needs the captain directly.

Merges, decisions, and Relay sends inherit the owning scripts' guards: merge authority, CodeRabbit gate, yolo posture, decision-hold lifecycle, and relay consent.

The server inherits `FM_HOME` from its environment, so the launcher must pin it rather than passing it per call.

## Residual risks

Authority laundering remains the largest risk: a convenient tool can feel routine while the underlying action is destructive.

The mitigation is unchanged layering: the MCP schema narrows the flags, the server revalidates ids and approval, and the owning script still fails closed.

Relay tokens and merge authority live outside this layer, so a compromised MCP caller with approval strings could still send or land code.

Recommendation: keep this local-only on a pinned `FM_HOME`, treat approval strings as per-action captain consent, and rescope before any networked or multi-user wiring.
