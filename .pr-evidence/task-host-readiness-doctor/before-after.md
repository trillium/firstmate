# Host readiness doctor: before -> after

```mermaid
flowchart LR
  subgraph Before
    A[fm-remote-doctor.sh] --> B[backend, launch agent, job worker, entrypoint]
    B --> C[tool present on PATH only]
  end
  subgraph After
    D[fm-host-tools-lib.sh] --> E[gh, git access, claude, pi, store, no-mistakes, treehouse, bun, ssh peers]
    E -->|human: + action: exact fix| F[fm-host-tools-doctor.sh]
    A2[fm-remote-doctor.sh --host-tools] --> D
    F -->|--record / --ingest| G[state/host-readiness/HOST.json]
    G --> H[fm-fleet-snapshot.sh host_readiness]
    H --> I[fm-fleet-view.sh Host readiness table]
  end
```

Real output of `fm-fleet-view.sh` after recording a host that lacks gh auth (the m1studio1 case):

```
## Host readiness
| Host | Ready | Failing checks | Fix | Checked |
| --- | --- | --- | --- | --- |
| m1studio1 | NO | host-gh | gh auth login | 2026-11-16T19:37:53Z |
```
