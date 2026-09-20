#!/usr/bin/env python3
"""Static AST and I/O persistence analyzer for Firstmate.

Scans shell scripts, libraries, configurations, and skills across Firstmate
to extract all persistent file surface accesses, I/O modes, readers, writers,
chokepoint invocations, and schema definitions.

Outputs a structured persistence snapshot JSON according to the schema in
data/mcp-persist-5/report.md.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Path normalization replacements (Section 4.1.2 of mcp-persist-5)
PATH_REPLACEMENTS = [
    # Variable roots
    (re.compile(r'(\$STATE|\$\{STATE\}|\$FM_STATE_OVERRIDE|\$\{FM_STATE_OVERRIDE\})'), 'state'),
    (re.compile(r'(\$DATA|\$\{DATA\}|\$FM_DATA_OVERRIDE|\$\{FM_DATA_OVERRIDE\})'), 'data'),
    (re.compile(r'(\$CONFIG|\$\{CONFIG\}|\$FM_CONFIG_OVERRIDE|\$\{FM_CONFIG_OVERRIDE\})'), 'config'),
    (re.compile(r'(\$PROJECTS|\$\{PROJECTS\}|\$FM_PROJECTS_OVERRIDE|\$\{FM_PROJECTS_OVERRIDE\})'), 'projects'),
    (re.compile(r'(\$FM_HOME|\$\{FM_HOME\}|\$FM_ROOT|\$\{FM_ROOT\})'), '.'),
    (re.compile(r'(\$XDG_STATE_HOME|\$\{XDG_STATE_HOME\})/firstmate'), 'xdg_state'),
    # Dynamic identifiers
    (re.compile(r'/(\$ID|\$\{ID\}|\$task_id|\$\{task_id\}|\$TASK_ID|\$\{TASK_ID\})\b'), '/<id>'),
    (re.compile(r'/(\$corr_id|\$\{corr_id\}|\$CORR_ID|\$\{CORR_ID\})\b'), '/<corr_id>'),
    (re.compile(r'/(\$source_id|\$\{source_id\}|\$SOURCE_ID|\$\{SOURCE_ID\})\b'), '/<source_id>'),
    (re.compile(r'/(\$request_id|\$\{request_id\}|\$rid|\$\{rid\})\b'), '/<request_id>'),
    (re.compile(r'/(\$view|\$\{view\})\b'), '/<view>'),
    (re.compile(r'/(\$project|\$\{project\}|\$PROJECT|\$\{PROJECT\}|\$PROJECT_SLUG|\$\{PROJECT_SLUG\})\b'), '/<project>'),
]

# The 15 Architectural Persistence Boundaries (from mcp-persist-2, .4, .7)
BOUNDARIES_CONFIG = {
    "boundary_1": {
        "name": "Backlog & Task Queue Management",
        "classification": "Canonical State",
        "beads_role": "CANONICAL_BEADS_STATE",
        "beads_mapping": {
            "primitive": "issue",
            "type": "task",
            "state_dimension": "lifecycle",
            "labels": ["fleet:firstmate", "home:<home_scope>", "task:<home_scope>:<id>"]
        },
        "surfaces": [
            "data/backlog.md",
            "data/done-archive.md",
            ".tasks.toml"
        ],
        "chokepoints": [
            "tasks-axi",
            "bin/fm-tasks-axi-lib.sh:fm_tasks_axi_cmd",
            "bin/fm-tasks-axi-lib.sh:fm_task_create"
        ]
    },
    "boundary_2": {
        "name": "Beads Store Resilience & Mirroring Layer",
        "classification": "Independent Local Files / Outage Resilience",
        "beads_role": "INDEPENDENT_LOCAL_FILE",
        "surfaces": [
            "state/.beads-mirror-<view>.json",
            "state/.beads-write-queue",
            "state/.beads-write-queue.lock",
            "state/.beads-label-migration-v1",
            "state/.beads-sync-last"
        ],
        "chokepoints": [
            "fm_beads_mirror_write",
            "fm_beads_mirror_read",
            "fm_beads_write_enqueue",
            "fm_beads_write_queue_reconcile"
        ]
    },
    "boundary_3": {
        "name": "Task Specifications & Written Deliverables",
        "classification": "Hybrid Canonical / Worktree Projection",
        "beads_role": "HYBRID_PROJECTION",
        "beads_mapping": {
            "canonical": "issue.description + acceptance_criteria",
            "projection": "<worktree>/brief.md"
        },
        "surfaces": [
            "data/<id>/brief.md",
            "data/<id>/report.md",
            "data/<id>/claim-prompt.md",
            "data/charter.md"
        ],
        "chokepoints": [
            "bin/fm-brief.sh",
            "bin/fm-claim-prompt-lib.sh",
            "bin/fm-promote.sh"
        ]
    },
    "boundary_4": {
        "name": "Task Runtime Metadata",
        "classification": "Canonical State / Runtime Interchange",
        "beads_role": "HYBRID_SPLIT_MODEL",
        "beads_mapping": {
            "logical_attributes": "issue.metadata (JSON)",
            "volatile_coordinates": "INDEPENDENT_LOCAL_FILE (state/<id>.runtime)"
        },
        "surfaces": [
            "state/<id>.meta",
            "state/<id>.runtime",
            "state/<id>.control-relaunch"
        ],
        "chokepoints": [
            "fm_meta_set",
            "fm_meta_get",
            "fm_meta_get_exact",
            "fm_backend_meta_set",
            "fm_backend_meta_get"
        ]
    },
    "boundary_5": {
        "name": "Task Status Logs & Open Decisions",
        "classification": "Hybrid Event Log / Decision Gates",
        "beads_role": "HYBRID_EVENT_GATES",
        "beads_mapping": {
            "status_stream": "state/<id>.status (local file append)",
            "decisions": "task gate create --type=human"
        },
        "surfaces": [
            "state/<id>.status",
            "state/.<id>.open-decisions-cursor"
        ],
        "chokepoints": [
            "fm_classify_status",
            "fm_send_resolve_key",
            "fm_decision_hold"
        ]
    },
    "boundary_6": {
        "name": "Semantic Busy-State IPC & Turn Handshakes",
        "classification": "OS Process Interchange / Mutual Exclusion",
        "beads_role": "INDEPENDENT_LOCAL_FILE",
        "surfaces": [
            "state/<id>.busy-state",
            "state/<id>.busy-gen",
            "state/<id>.turn-ended",
            "state/<id>.grok-turnend-token",
            "state/<id>.kimi-turnend-token",
            "state/<id>.muse-session"
        ],
        "chokepoints": [
            "fm_busy_event",
            "fm_busy_record_read",
            "fm_busy_classify"
        ]
    },
    "boundary_7": {
        "name": "Session Locks & Supervision Liveness",
        "classification": "OS Process Interchange / Mutual Exclusion",
        "beads_role": "INDEPENDENT_LOCAL_FILE",
        "surfaces": [
            "state/.lock",
            "state/.watch.lock",
            "state/.last-watcher-beat",
            "state/.claude-autoarm.lock"
        ],
        "chokepoints": [
            "fm_lock_try_acquire",
            "fm_lock_release",
            "fm_lock_acquire_wait"
        ]
    },
    "boundary_8": {
        "name": "Durable Wake Queue",
        "classification": "Canonical State / Interchange Queue",
        "beads_role": "INDEPENDENT_LOCAL_FILE",
        "surfaces": [
            "state/.wake-queue",
            "state/.wake-queue.lock"
        ],
        "chokepoints": [
            "fm_wake_append",
            "fm_wake_records",
            "fm_wake_absorb_seqs",
            "fm_wake_enqueue"
        ]
    },
    "boundary_9": {
        "name": "Away Mode (AFK) & Daemon Coordination",
        "classification": "Ephemeral Runtime Flag / Daemon IPC",
        "beads_role": "HYBRID_PRESENCE",
        "surfaces": [
            "state/.afk",
            "state/.subsuper-escalations",
            "state/.subsuper-pid"
        ],
        "chokepoints": [
            "bin/fm-afk-start.sh",
            "bin/fm-afk-return.sh",
            "bin/fm-supervise-daemon.sh"
        ]
    },
    "boundary_10": {
        "name": "PR Checks, Forge Polling & Retirement Barrier",
        "classification": "Canonical Forge Gates / PR Polls",
        "beads_role": "CANONICAL_BEADS_GATES",
        "beads_mapping": {
            "primitive": "gate",
            "type": "gh:pr",
            "resolution": "automated on forge merge"
        },
        "surfaces": [
            "state/<id>.check.sh",
            "state/<id>.check-trust",
            "state/<id>.pr-poll",
            "state/<id>.pr-poll-registration",
            "state/<id>.pr-poll-retirement",
            "state/<id>.pr-review-seen"
        ],
        "chokepoints": [
            "fm_pr_gate_create",
            "fm_pr_gate_check",
            "fm_pr_poll_prepare",
            "fm_pr_poll_publish_prepared"
        ]
    },
    "boundary_11": {
        "name": "Public Relay (X-Mode) & Public Follow-up Transport",
        "classification": "Canonical Relay Task & Event Beads",
        "beads_role": "CANONICAL_BEADS_STATE",
        "surfaces": [
            "state/x-inbox/<request_id>.json",
            "state/x-context/<request_id>.json",
            "state/x-outbox/<request_id>.json",
            "state/public-followup/<request_id>.json"
        ],
        "chokepoints": [
            "fmx_context_registry_set",
            "fmx_context_registry_get",
            "fmx_offer_registry_claim",
            "fm_pf_registry_ids",
            "fm_pf_event_id"
        ]
    },
    "boundary_12": {
        "name": "Process-to-Event Sources",
        "classification": "Beads KV Registrations & Event Streams",
        "beads_role": "CANONICAL_BEADS_STATE",
        "surfaces": [
            "state/procevent/<source_id>.json",
            "state/procevent-inbox/<source_id>.output"
        ],
        "chokepoints": [
            "fm_procevent_capture",
            "fm_procevent_mark_handled",
            "fm_procevent_register"
        ]
    },
    "boundary_13": {
        "name": "Secondmate Routing & Inter-Home RPC",
        "classification": "Canonical Dolt Replication / Distributed State",
        "beads_role": "CANONICAL_DOLT_REPLICATION",
        "surfaces": [
            "data/secondmates.md",
            "state/pending-replies/<corr_id>.json",
            "data/handoff/<id>.outbox.md"
        ],
        "chokepoints": [
            "secondmate_registry_get",
            "secondmate_registry_sync",
            "fm_pending_reply_record"
        ]
    },
    "boundary_14": {
        "name": "Project Posture Registry",
        "classification": "Canonical Project Entity Beads",
        "beads_role": "CANONICAL_BEADS_ENTITY",
        "beads_mapping": {
            "primitive": "issue",
            "type": "entity",
            "labels": ["type:project", "project:<slug>"]
        },
        "surfaces": [
            "data/projects.md"
        ],
        "chokepoints": [
            "fm_project_mode",
            "fm_project_entity_get",
            "fm_project_entity_set"
        ]
    },
    "boundary_15": {
        "name": "Domain Knowledge, Preferences & Startup Memory",
        "classification": "Canonical Persistent Memories",
        "beads_role": "CANONICAL_BEADS_MEMORIES",
        "beads_mapping": {
            "primitive": "memory",
            "storage": "task remember / recall"
        },
        "surfaces": [
            "data/captain.md",
            "data/captain-shared.md",
            "data/learnings.md",
            "config/startup-memory-budget"
        ],
        "chokepoints": [
            "fm_memory_get",
            "fm_memory_set",
            "fm_memory_render",
            "fm_startup_memory_budget_read"
        ]
    }
}

# Known metadata keys for state/<id>.meta
KNOWN_META_KEYS = [
    "window", "endpoint_task_id", "worktree", "project", "harness",
    "model", "effort", "kind", "mode", "yolo", "tasktmp", "traceparent",
    "home", "projects", "remote_host", "remote_root", "remote_backend",
    "remote_herdr_session", "remote_target", "account", "claim_prompt",
    "label", "beads_id", "pr", "pr_head", "x_request", "x_request_ts",
    "x_followups", "x_platform", "x_reply_max_chars", "runtime"
]

# Known columns for state/.wake-queue
KNOWN_WAKE_COLUMNS = ["epoch", "seq", "kind", "key", "payload"]


def normalize_path(raw_path: str) -> str:
    """Normalize variable-interpolated file paths to canonical surface templates."""
    path = raw_path.strip().strip('"\'')
    for pattern, replacement in PATH_REPLACEMENTS:
        path = pattern.sub(replacement, path)
    
    # Strip leading ./ if present
    if path.startswith("./"):
        path = path[2:]
        
    # Match known patterns
    if "state/" in path:
        sub = path[path.index("state/"):]
        sub = re.sub(r'state/(\$ID|\$\{ID\}|[A-Za-z0-9._-]+)\.meta\b', 'state/<id>.meta', sub)
        sub = re.sub(r'state/(\$ID|\$\{ID\}|[A-Za-z0-9._-]+)\.runtime\b', 'state/<id>.runtime', sub)
        sub = re.sub(r'state/(\$ID|\$\{ID\}|[A-Za-z0-9._-]+)\.status\b', 'state/<id>.status', sub)
        sub = re.sub(r'state/(\$ID|\$\{ID\}|[A-Za-z0-9._-]+)\.check\.sh\b', 'state/<id>.check.sh', sub)
        sub = re.sub(r'state/(\$ID|\$\{ID\}|[A-Za-z0-9._-]+)\.pr-poll\b', 'state/<id>.pr-poll', sub)
        sub = re.sub(r'state/(\$ID|\$\{ID\}|[A-Za-z0-9._-]+)\.busy-state\b', 'state/<id>.busy-state', sub)
        sub = re.sub(r'state/\.beads-mirror-[A-Za-z0-9._-]+\.json', 'state/.beads-mirror-<view>.json', sub)
        sub = re.sub(r'state/pending-replies/[A-Za-z0-9._-]+\.json', 'state/pending-replies/<corr_id>.json', sub)
        sub = re.sub(r'state/x-inbox/[A-Za-z0-9._-]+\.json', 'state/x-inbox/<request_id>.json', sub)
        sub = re.sub(r'state/x-context/[A-Za-z0-9._-]+\.json', 'state/x-context/<request_id>.json', sub)
        sub = re.sub(r'state/x-outbox/[A-Za-z0-9._-]+\.json', 'state/x-outbox/<request_id>.json', sub)
        sub = re.sub(r'state/public-followup/[A-Za-z0-9._-]+\.json', 'state/public-followup/<request_id>.json', sub)
        sub = re.sub(r'state/procevent/[A-Za-z0-9._-]+\.json', 'state/procevent/<source_id>.json', sub)
        return sub
    elif "data/" in path:
        sub = path[path.index("data/"):]
        sub = re.sub(r'data/(\$ID|\$\{ID\}|[A-Za-z0-9._-]+)/brief\.md\b', 'data/<id>/brief.md', sub)
        sub = re.sub(r'data/(\$ID|\$\{ID\}|[A-Za-z0-9._-]+)/report\.md\b', 'data/<id>/report.md', sub)
        sub = re.sub(r'data/(\$ID|\$\{ID\}|[A-Za-z0-9._-]+)/claim-prompt\.md\b', 'data/<id>/claim-prompt.md', sub)
        return sub
    elif "config/" in path:
        return path[path.index("config/"):]
        
    return path


def surface_to_boundary(surface: str) -> str:
    """Map a surface template to its governing boundary identifier."""
    for boundary_id, data in BOUNDARIES_CONFIG.items():
        for s in data["surfaces"]:
            if surface == s or surface.startswith(s.rstrip('*')):
                return boundary_id
            # Prefix/glob matching
            if '<id>' in s and '<id>' in surface:
                if s.split('<id>')[1] == surface.split('<id>')[1]:
                    return boundary_id
    if surface.startswith("state/"):
        return "boundary_4"
    if surface.startswith("data/"):
        return "boundary_1"
    if surface.startswith("config/"):
        return "boundary_15"
    return "boundary_unknown"


def scan_file_for_persistence(filepath: Path, rel_path: str):
    """Scan a single script file for persistence reads, writes, and chokepoints."""
    try:
        content = filepath.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return [], [], []

    reads = []
    writes = []
    chokepoints = []
    lines = content.splitlines()

    # Chokepoint helper function definitions or calls
    helper_patterns = [
        "fm_meta_set", "fm_meta_get", "fm_meta_get_exact",
        "fm_wake_append", "fm_wake_records", "fm_wake_absorb_seqs", "fm_wake_enqueue",
        "fm_busy_event", "fm_busy_record_read", "fm_busy_classify",
        "fm_memory_get", "fm_memory_set", "fm_memory_render",
        "fm_project_mode", "fm_project_entity_get", "fm_project_entity_set",
        "fmx_context_registry_set", "fmx_context_registry_get", "fmx_offer_registry_claim",
        "fm_pf_registry_ids", "fm_pf_event_id",
        "fm_procevent_capture", "fm_procevent_mark_handled",
        "fm_beads_mirror_write", "fm_beads_mirror_read", "fm_beads_write_enqueue",
        "fm_lock_try_acquire", "fm_lock_release", "fm_lock_acquire_wait"
    ]

    # Regex patterns for file I/O
    write_re = re.compile(r'(?:>|>>|tee\s+-a|tee\s+|cp\s+.*?|mv\s+.*?|mv\s+-f\s+.*?)\s+([\'"]?(?:\$STATE|\$DATA|\$CONFIG|\$PROJECTS|\$\{STATE\}|\$\{DATA\}|\$\{CONFIG\}|state/|data/|config/)[^\s;|\'\"]+[\'"]?)')
    read_re = re.compile(r'(?:<|cat\s+|head\s+|tail\s+|grep\s+.*?|source\s+|\.\s+|jq\s+.*?)\s+([\'"]?(?:\$STATE|\$DATA|\$CONFIG|\$PROJECTS|\$\{STATE\}|\$\{DATA\}|\$\{CONFIG\}|state/|data/|config/)[^\s;|\'\"]+[\'"]?)')

    for idx, line in enumerate(lines, 1):
        line_str = line.strip()
        if line_str.startswith("#") and not line_str.startswith("#!"):
            continue

        # Check for chokepoint calls
        for helper in helper_patterns:
            if re.search(r'\b' + re.escape(helper) + r'\b', line_str):
                chokepoints.append((helper, f"{rel_path}:{idx}"))

        # Check for writes
        for match in write_re.finditer(line_str):
            target = match.group(1)
            norm = normalize_path(target)
            if norm.startswith(("state/", "data/", "config/", ".tasks.toml")):
                writes.append((norm, f"{rel_path}:{idx}", line_str))

        # Check for reads
        for match in read_re.finditer(line_str):
            target = match.group(1)
            norm = normalize_path(target)
            if norm.startswith(("state/", "data/", "config/", ".tasks.toml")):
                reads.append((norm, f"{rel_path}:{idx}", line_str))

    return reads, writes, chokepoints


def generate_snapshot(fm_home: Path) -> dict:
    """Generate complete persistence snapshot for a Firstmate directory."""
    try:
        rev = subprocess.check_output(
            ["git", "-C", str(fm_home), "rev-parse", "--short", "HEAD"],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        rev = "unknown"

    snapshot = {
        "version": 1,
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "firstmate_revision": rev,
        "boundaries": BOUNDARIES_CONFIG,
        "surfaces": {}
    }

    # Initialize known baseline surfaces
    all_registered_surfaces = set()
    for b_data in BOUNDARIES_CONFIG.values():
        for s in b_data.get("surfaces", []):
            all_registered_surfaces.add(s)

    for s in sorted(all_registered_surfaces):
        b_id = surface_to_boundary(s)
        b_info = BOUNDARIES_CONFIG.get(b_id, {})
        snapshot["surfaces"][s] = {
            "boundary": b_id,
            "category": b_info.get("classification", "Unclassified"),
            "beads_role": b_info.get("beads_role", "UNKNOWN"),
            "format": "json" if s.endswith(".json") else "key_value_lines" if s.endswith(".meta") else "markdown" if s.endswith(".md") else "tsv_stream" if "wake-queue" in s or "status" in s else "file",
            "chokepoints": b_info.get("chokepoints", []),
            "verified_readers": [],
            "verified_writers": [],
            "bypass_leaks": []
        }
        if s == "state/<id>.meta":
            snapshot["surfaces"][s]["keys"] = KNOWN_META_KEYS
        elif s == "state/.wake-queue":
            snapshot["surfaces"][s]["columns"] = KNOWN_WAKE_COLUMNS

    # Scan bin/ directory and libraries
    scan_dirs = [fm_home / "bin"]
    if (fm_home / ".agents" / "skills").is_dir():
        scan_dirs.append(fm_home / ".agents" / "skills")

    for scan_dir in scan_dirs:
        for root, _, files in os.walk(scan_dir):
            for file in files:
                if file.endswith((".sh", ".md", ".py")):
                    f_path = Path(root) / file
                    rel = str(f_path.relative_to(fm_home))
                    reads, writes, _ = scan_file_for_persistence(f_path, rel)

                    for target, cit, line_str in reads:
                        if target in snapshot["surfaces"]:
                            if cit not in snapshot["surfaces"][target]["verified_readers"]:
                                snapshot["surfaces"][target]["verified_readers"].append(cit)

                    for target, cit, line_str in writes:
                        if target not in snapshot["surfaces"]:
                            b_id = surface_to_boundary(target)
                            b_info = BOUNDARIES_CONFIG.get(b_id, {})
                            snapshot["surfaces"][target] = {
                                "boundary": b_id,
                                "category": b_info.get("classification", "Discovered Surface"),
                                "beads_role": b_info.get("beads_role", "UNKNOWN"),
                                "format": "file",
                                "chokepoints": b_info.get("chokepoints", []),
                                "verified_readers": [],
                                "verified_writers": [],
                                "bypass_leaks": []
                            }

                        if cit not in snapshot["surfaces"][target]["verified_writers"]:
                            snapshot["surfaces"][target]["verified_writers"].append(cit)

                        # Check for bypass leak on strict chokepoint surfaces
                        if target == "state/<id>.meta":
                            # If direct append without fm_meta_set or outside fm-spawn.sh/fm-pr-check/test
                            if ">>" in line_str and "fm_meta_set" not in line_str and "fm-spawn.sh" not in rel:
                                if cit not in snapshot["surfaces"][target]["bypass_leaks"]:
                                    snapshot["surfaces"][target]["bypass_leaks"].append(cit)

    # Sort all citation lists
    for s_data in snapshot["surfaces"].values():
        s_data["verified_readers"].sort()
        s_data["verified_writers"].sort()
        s_data["bypass_leaks"].sort()

    return snapshot


def main(argv=None):
    parser = argparse.ArgumentParser(description="Generate Firstmate persistence snapshot.")
    parser.add_argument("--fm-home", default=".", help="Path to Firstmate root directory")
    parser.add_argument("-o", "--output", help="Output path for snapshot JSON (default: stdout)")
    parser.add_argument("--update", action="store_true", help="Update drift/persist_baseline.json directly")
    args = parser.parse_args(argv)

    fm_home = Path(args.fm_home).resolve()
    snapshot = generate_snapshot(fm_home)

    out_json = json.dumps(snapshot, indent=2) + "\n"

    if args.update:
        baseline_path = fm_home / "drift" / "persist_baseline.json"
        baseline_path.parent.mkdir(parents=True, exist_ok=True)
        baseline_path.write_text(out_json, encoding="utf-8")
        print(f"Updated persistence baseline at {baseline_path}", file=sys.stderr)
    elif args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(out_json, encoding="utf-8")
    else:
        sys.stdout.write(out_json)

    return 0


if __name__ == "__main__":
    sys.exit(main())
