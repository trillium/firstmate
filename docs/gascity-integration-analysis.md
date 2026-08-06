# Gascity Integration Feasibility Report

## Executive Summary

Gascity is a multi-agent orchestration framework with declarative config (`city.toml`), pluggable runtime providers, beads-backed work tracking, and a reconciliation loop. Evaluation follows five integration vectors:

### Integration Candidates (Priority Order)

#### 1. **Runtime Provider Abstraction** — Clean, 1-2 weeks
- **What**: Gascity's `internal/runtime/` abstracts tmux, subprocess, exec, ACP, K8s behind a unified interface
- **Firstmate fit**: Harness adapters already abstract claude/codex/opencode/pi/grok/kimi. Gascity's provider pattern offers a *pane lifecycle* abstraction (spawn, nudge, wait, kill) that could unify our backend-specific worktree logic
- **Benefit**: Extract shared `PaneHandle` type and provider callbacks (detect liveness, send input, read output, cleanup)
- **Blockers**: None structural. Gascity's providers assume pane-per-session; firstmate's tmux backend runs multiple tasks per session
- **Adoption path**: Extract gascity's `runtime.Manager` interface signature into a shared primitive, implement firstmate's tmux/herdr backends against it
- **Effort**: 1-2 weeks (prototype, test coverage, second-mate integration)

#### 2. **City.toml Declarative Config Pattern** — Medium friction, 2-4 weeks
- **What**: Gascity's `city.toml` is progressive-activation TOML (config presence = feature flag) with multi-layer overrides, pack imports, and composition
- **Firstmate fit**: `config/crew-dispatch.json` (crew-dispatch profiles) and `config/crew-harness` (static harness choice) are hand-curated routing rules. City.toml's declarative override resolution could replace ad-hoc dispatch logic
- **Benefit**: Unified configuration schema, inheritance across secondmate homes, simpler captain-facing config inspection
- **Friction**: Firstmate's dispatch also consults runtime state (quota-axi output); pure declarative config is insufficient. City.toml assumes agents are defined upfront; firstmate's agents emerge from fleet state
- **Adoption path**: Not a direct port. Adopt gascity's *composition* pattern (includes, packs, override layering) for a reworked `city.toml`-like dispatch schema, while keeping firstmate's quota-aware selection
- **Effort**: 2-4 weeks (schema design, quota-aware loader, secondmate config inheritance)

#### 3. **Beads Integration Depth** — Low disruption, 1-2 weeks (research + minimal integration)
- **What**: Gascity uses beads for universal persistence: tasks, mail, molecules, convoys, state. Gascity's `internal/beads/` wraps dolt/file stores with typed accessors
- **Firstmate fit**: Firstmate already supports beads as a backlog backend (`config/backlog-backend=beads`). Gascity's pattern is deeper: multi-table store (Convoy, Mail, Molecule) vs. firstmate's single-table Tasks model
- **Benefit**: Adopt gascity's typed store pattern (`Store` interface with methods like `CreateConvoy`, `AppendMail`) for firstmate's durable state (wakes, pending-replies, X-context). Tighter integration than hand-rolled JSON in state/
- **Friction**: Tight coupling risk—gascity's store is core to execution; firstmate's watcher is already loosely coupled to beads. Adopting gascity's pattern would centralize state in beads
- **Adoption path**: (a) lightweight: create a `PendingReplyStore` wrapper around beads following gascity's pattern, (b) ambitious: migrate all `state/` durable records into typed beads tables
- **Effort**: 1-2 weeks lightweight; 4-6 weeks for full migration
- **Recommendation**: Lightweight adoption only; full migration conflicts with firstmate's stateless-watcher design

#### 4. **Health Patrol & State Reconciliation Loop** — Architectural conflict, defer
- **What**: Gascity's Health Patrol (supervision) is a bounded reconciliation loop: desired config → detect running state → apply corrections (crash recovery, idle drain, crash tracking)
- **Firstmate fit**: Firstmate's watcher already implements bounded reconciliation (wake queue → state read → supervision action → heartbeat). Same intent, different implementation
- **Conflict**: Gascity's reconciliation is *config-driven* (desired state from `city.toml`); firstmate's is *event-driven* (wakes from status file appends, PR polls, X-mode mentions)
- **Adoption path**: Not a direct port. Both are valid patterns. Gascity's works best when agents are declared upfront; firstmate's works best when agent lifecycle is implicit in fleet state
- **Recommendation**: Document the trade-off in design notes; adopt insights (crash detection, idle-task discovery) where applicable, but keep the watcher event-driven
- **Effort**: Design doc only; no code adoption this cycle

#### 5. **CLI Command Naming & Config Schema UX** — Small wins, 1-2 weeks
- **What**: Gascity's CLI (`gc init`, `gc start`, `gc session attach mayor`) uses nouns consistently; config schema favors declarative clarity over shell shortcuts
- **Firstmate fit**: Firstmate's `bin/` scripts use verb-first naming (`fm-spawn.sh`, `fm-send.sh`); captain CLI is thin and opinionated. Gascity's broader command surface could inform secondmate CLI if secondmate gains a public interface
- **Benefit**: Cleaner CLI help output, consistent naming across `gc` and `fm` when both are in use
- **Adoption path**: (a) no code change: adopt Gascity's command-naming pattern in future firstmate CLI work, (b) light: create thin `gc` wrapper for cross-tool workflow recipes
- **Effort**: 1-2 weeks documentation; 1-2 weeks for CLI wrapper if desired

---

## Key Design Insights to Preserve

1. **Progressive Activation**: Gascity's config activation model (feature presence = activation) is clean and avoids feature-flag sprawl. Useful for firstmate's dispatch schema redesign if pursued
2. **Typed Store Abstraction**: Gascity's store interface is minimal and composable (file, dolt backends under one API). Contrast with firstmate's hand-rolled state JSON; typed stores are worth migrating to if beads integration deepens
3. **Provenance Tracking**: Every config element is traced to its source file. Firstmate's dispatch profiles lack this; would aid debugging when quota or harness selection surprises
4. **No Hardcoded Roles**: Gascity defines zero builtin agent roles; everything is config-driven. Firstmate's roles (captain, crewmate, secondmate, supervisor) are baked in. Both valid; Gascity's is more flexible but requires more explicit config

---

## Conflicts with Firstmate Core Design

1. **Config-driven vs Event-driven Reconciliation**: Gascity's Health Patrol assumes desired state is declarative (in `city.toml`). Firstmate's watcher assumes desired state is implicit in fleet records + durable wake events. No single pattern dominates; both are sound
2. **Session Scope**: Gascity's sessions are pane groups with shared context. Firstmate's sessions are per-task worktree handles. Adopting Gascity's pane-pooling would require major firstmate refactoring
3. **Harness Coupling**: Gascity's runtime providers are pluggable *within* a session. Firstmate's harnesses (claude/codex/pi) are process-level, not pane-level. Runtime abstraction is possible; harness coupling would require more surgery

---

## Recommended Phased Adoption

### Phase 1 (1-2 weeks): Runtime Provider Extraction
- Extract gascity's `PaneHandle` and provider interface into a shared primitive
- Implement firstmate's existing backends (tmux, herdr) against it
- Proof: secondmate's herdr launches work using the new interface
- Benefit: Unify pane lifecycle code across tools

### Phase 2 (2-4 weeks): Dispatch Schema + Quota Integration
- Design a gascity-inspired `city.toml`-like dispatch schema that incorporates quota-axi
- Prototype with crew-dispatch profile resolution
- Preserve event-driven reconciliation (no config-driven shift)
- Benefit: Cleaner dispatch logic, inherited config in secondmate homes

### Phase 3 (1-2 weeks, optional): Beads Typed Store
- Wrap pending-reply and X-mode state in typed beads tables (lightweight adoption)
- Defer full state migration; keep watcher loosely coupled
- Benefit: Cleaner state inspection, natural secondmate state sharing via beads

### Phase 4 (Design doc only): Health Patrol Insights
- Document trade-offs between config-driven and event-driven supervision
- Adopt crash-detection and idle-task-discovery heuristics where applicable
- Recommendation: keep watcher event-driven; do not adopt config-driven reconciliation

---

## Files Worth a Closer Read (for the implementing crew)

When Phase 1 or 2 starts, these are the entry points in gascity's codebase:

- Runtime provider abstraction: `internal/runtime/runtime.go`, provider implementations in `internal/runtime/{tmux,subprocess,exec,acp,k8s,hybrid}`
- Config system: `internal/config/config.go`, `compose.go`, `pack.go`
- Beads store: `internal/beads/store.go`, provider implementations in `internal/beads/{dolt,file}`
- Health Patrol: `cmd/gc/cmd_supervise.go`, `internal/health/` (crash tracking, idle detection)

---

## Summary Table

| Pattern | Effort | Conflict | Blockers | Adopt? |
|---------|--------|----------|----------|--------|
| Runtime provider abstraction | 1-2w | None | None | **Yes**, Phase 1 |
| City.toml config pattern | 2-4w | Config-driven assumes agents upfront | Need quota integration | **Partial**, Phase 2 (adopt composition, not config-driven reconciliation) |
| Beads typed store | 1-2w (light), 4-6w (full) | Tight coupling risk | State migration complexity | **Lightweight**, Phase 3 optional |
| Health Patrol reconciliation | design only | Event-driven vs config-driven | Fundamental design choice | **No**, document insights only |
| CLI naming & UX | 1-2w | None | None | **Optional**, not urgent |

---

## Next Steps

1. **Approve Phase 1** (runtime provider extraction): highest ROI, no conflicts
2. **Prototype Phase 2** (dispatch schema): determines if quota-aware config is feasible
3. **Defer Health Patrol analysis**: document the trade-off in design notes, revisit if event-driven reconciliation becomes a bottleneck
4. **Coordinate with gascity**: If runtime extraction or beads integration require gascity API changes, open a discussion with the gascity crew

---

*Report complete: 2026-08-01*
