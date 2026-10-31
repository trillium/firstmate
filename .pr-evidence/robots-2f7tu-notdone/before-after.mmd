# NOT DONE shows remote-secondmate work the remote already closed

Fixture: a registered remote secondmate whose parent-side cached summary still lists two queued items, while the remote's live summary has already closed one of them; the other has no recorded date.

```mermaid
flowchart LR
  subgraph Before
    C1[stale cached summary] --> N1[NOT DONE: unstarted 2494d, unstarted 20756d]
  end
  subgraph After
    L[live read of the remote summary] --> N2[NOT DONE: only what the remote still has queued, undated shows unknown]
    L -. read fails .-> C2[newest cached copy]
    L --> S[any summary over a day old: disclosed with its age, not judged]
    C2 --> S
  end
```

## Before (main)
```
Not done: Sidecar heartbeat persist (sidecar-heartbeat-persist-q1 on mini1-ops) - unstarted 20756d: queued with no dependency or date gate and never dispatched - firstmate: dispatch it, or ask the captain whether to drop it
Not done: Pre-push git env leak (fm-hooks-prepush-git-env-leak on mini1-ops) - unstarted 2494d: queued with no dependency or date gate and never dispatched - firstmate: dispatch it, or ask the captain whether to drop it
```

## After (this branch)
```
Not done: Sidecar heartbeat persist (sidecar-heartbeat-persist-q1 on mini1-ops) - unstarted unknown: queued with no dependency or date gate and never dispatched - firstmate: dispatch it, or ask the captain whether to drop it
```
