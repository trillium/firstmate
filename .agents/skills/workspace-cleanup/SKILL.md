---
name: workspace-cleanup
description: >-
  Clean up discarded herdr terminal spaces when the captain invokes /workspace-cleanup or asks to clean discarded herdr spaces.
  Lists herdr workspaces, classifies each as live, done, or stale, closes only verified-empty panes via herdr pane-close, and reports what was closed and what was kept with reasons.
  Never touches secondmate homes, personal spaces, or the focused main session, and never closes a live worker.
user-invocable: true
metadata:
  internal: true
---

# workspace-cleanup

Reclaim discarded herdr terminal spaces on captain request.
This skill is the one owner of the classify-verify-close-report procedure for herdr space cleanup.
It closes panes only after verification, and it never closes a live worker.

## Trigger

The captain invokes `/workspace-cleanup` or asks in plain language to clean up discarded herdr spaces.
Do not run this procedure unprompted, on a wake, or as part of any other task.

## Procedure

1. **List herdr workspaces.**
   Run `herdr workspace list` for the home-scoped session inventory.
   For each workspace, run `herdr pane list --workspace <workspace-id>` to enumerate its panes.
   These two reads are the only fleet-wide inspection this skill performs.
2. **Classify each workspace into exactly one bucket.**
   - Live or working agent: any pane reports a working agent status, has recent output, or owns a running process tied to a live task.
   - Done plus its task torn down: every pane is idle and empty, and the owning task is already torn down with its report landed.
   - Unknown or stale shell: panes show no agent activity and no owning live task, but ownership is unclear.
   - Never touch: secondmate homes, personal spaces, and the focused main session, identified via `herdr pane current` and the secondmate registry.
3. **Verify before closing.**
   For a done candidate, confirm every pane is empty with `herdr pane read <pane-id>` and confirm no running work with `herdr pane process-info <pane-id>`.
   For an unknown or stale shell, apply the same two reads, and close only when both prove the pane empty and idle.
   A pane that fails either check returns to the keep bucket, never to the close list.
4. **Close only via `herdr pane close`.**
   Close each verified pane with `herdr pane close <pane-id>`.
   When a workspace is left with no panes, close the workspace itself with `herdr workspace close` only after re-listing confirms it is empty.
   Close panes one at a time and re-list between workspaces so a concurrent new pane is never swept up.
5. **Close a discarded empty space with the proven live procedure.**
   List herdr workspaces and pick candidates.
   For each candidate confirm task metadata is absent, or the task is done plus its branch is preserved in refs.
   Prove a single idle shell via `herdr pane process-info`: foreground processes must be exactly one zsh with no children.
   Close with `herdr workspace close <workspace-id>`.
   Verify the worktree directory plus the branch ref survive with `git worktree list` and `git rev-parse`.
6. **Report what was closed and what was kept with reasons.**
   Captain chat carries one scannable line per workspace: closed or kept, plus the one-line reason (live worker, done and torn down, verified empty, secondmate home, personal space, or focused session).
   Follow `AGENTS.md` section 9 and translate internal terms into plain outcomes.

## Safety rules

- Never close a live worker.
- Never close a paused worker holding unlanded branches unless their branches verify intact in refs first.
- A pane with any sign of running work is kept, no exceptions.
- Never broad pkill and never stop the herdr server.
- Home-scoped only: operate solely on this home's own session inventory.
- Secondmate homes, personal spaces, and the focused main session are never touched.
- When any classification is uncertain, keep the workspace and say why.

## Worked example of restraint

Two live agents named access-url and deploy were skipped during a real cleanup because their panes showed working activity.
Both stayed open while verified-empty spaces around them were closed.
Skipping a live worker is always correct, even when its task looks nearly done.
