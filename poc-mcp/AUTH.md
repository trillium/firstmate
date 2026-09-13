First Mate MCP authorization tiers (full coverage)

Trillium is the sole authorizer and nothing stays excluded for safety by default.

Every authority-bearing or externally visible tool takes an explicit `approval` string starting with `I authorize` and refuses without it.

Reads stay open because they change nothing.

Tier 1 - open reads (no approval): `fleet_snapshot`, `backlog`, `crew_state`, `status_tail`, `fleet_poll`.

Tier 2 - reversible steers (no approval, validated text): `send_message` wraps only the plain-text `fm-send.sh` path with a 500-char single-line cap and a slash-command refusal.

Tier 3 - authority writes (approval required): `lifecycle_interrupt`, `lifecycle_exit`, `lifecycle_relaunch`, `lifecycle_suspend`, `lifecycle_resume`, `spawn_crew`, `scaffold_brief`, `promote_scout`, `teardown_crew`, `arm_pr_check`, `merge_pr`, `merge_local`, `decision_hold`, `decision_resolve`, `review_decision`.

Tier 4 - external sends (approval required, relay-gated): `relay_reply`, `relay_dismiss`, `relay_followup` shell to the owning `fm-x-*.sh` scripts and stay inert without relay consent.

Safety notes that survive full coverage.

The MCP layer never reimplements policy: every tool shells to the owning `bin/` script and the script still fails closed.

Teardown through MCP never passes `--force`, so discard of unlanded work still needs the captain on the trusted channel.

Merges still enforce the configured merge authority, the CodeRabbit gate, and yolo posture inside the owning scripts.

Relay sends still require relay consent (`FMX_PAIRING_TOKEN`) and follow-up budgets inside the owning scripts.

`FM_HOME` is inherited from the server environment, so pin it at launch and do not expose it as a tool argument.
