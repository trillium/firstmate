# Cloud runs

`bin/fm-cloud.sh` is the default command for Claude Code cloud sessions: it launches one from the command line, records it, and polls for its result.
Run `bin/fm-cloud.sh doctor` first; it checks that the installed `claude` CLI supports `--cloud` and lists what still needs the web UI.

## Commands

- `launch` runs `claude --cloud` with a prompt argument or `--file`, optionally targeting `--environment <id>` and a `--repo`, and writes one record per run under `state/cloud-runs/`.
- `status` and `list` show the recorded runs; `status` also polls the run's remote for `claude/*` branches that are new since launch, which is where cloud work lands.
- `cleanup <run-id>` retires the record and prints the remaining web-only steps without performing them; a run still bound to a task is retired with `teardown` instead.
- `launch --task <id>` makes the run an ordinary dispatch, described below.
- `check <id>`, `land <id>`, and `teardown <id>` finish a task-bound run.
- `credit` reports the cloud credit's days remaining and the runs launched, and `doctor` prints the same line.

## Cloud runs as a dispatch route

A cloud run suits self-contained work in a GitHub repository whose commits are pushed, and it is preferred for that work while `config/cloud-credit` is unexpired ([configuration](configuration.md#cloud-runs-configcloud-credit--configcloud-timeout)).

1. Add the backlog item and write the instructions with `bin/fm-brief.sh`, which leaves `data/<id>/brief.md`.
2. Run `bin/fm-cloud.sh launch --task <id> --repo <dir>`.
3. Wait for the wake; the finish check runs every watcher poll and prints one line only when firstmate should act.
4. On a PR wake, run `bin/fm-cloud.sh land <id>` to hand the PR to the ordinary merge poll and landing path.
5. After the merge, `bin/fm-teardown.sh <id>` retires the run.

`launch --task` sends the brief plus a short trailer (work on `claude/<id>`, push it, open a pull request against the default branch, put no secrets in either).
It refuses before launching when the task has no brief or no backlog item, then records the task with `backend=cloud`, moves the item to In flight, notes the session url on the status log, and registers the finish check.
The fleet view and `fm-crew-state.sh` show the run as working with its session url, and a recorded PR is added to that line.

The finish check wakes firstmate when a `claude/*` branch is new or moved, when its pull request appears, and once when the run has been silent past the time limit.
Each distinct result is reported once, and the check goes quiet when a PR is recorded because the merge poll owns the task from there.
Delivery is always a direct PR to the fork or repository named by the run's remote; a cloud run never runs the no-mistakes pipeline.

`teardown` refuses unless the recorded PR is merged, and `--force` discards a run whose work was not landed.
It retires the finish check, the merge poll, the run record, and the task record, and closes the backlog item.

## What stays manual

The cloud environment's network allowlist and environment variables, and Tailscale key minting, have no CLI.
Drive them in the browser per runbook `runbooks-e8k`, then run `cleanup` and remove the key, revoke it, and restore network access when the run is over.

## Secrets

The tool never prints, logs, or stores a key, token, or environment value, and it stores only the prompt's length and hash.
`bin/fm-cloud.sh`'s header owns the record fields and exact flags.
