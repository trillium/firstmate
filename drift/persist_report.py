#!/usr/bin/env python3
"""Report formatter for Firstmate persistence drift."""

import json
from typing import Dict, Any


def to_dict(report: Dict[str, Any]) -> Dict[str, Any]:
    """Return the raw report dictionary."""
    return report


def to_json(report: Dict[str, Any], indent: int = 2) -> str:
    """Format the report as machine-readable JSON."""
    return json.dumps(report, indent=indent) + "\n"


def to_markdown(report: Dict[str, Any]) -> str:
    """Format the report as human-readable Markdown."""
    summary = report.get("summary", {})
    base = report.get("baseline", {})
    obs = report.get("observed", {})
    clean = summary.get("clean", True)

    lines = [
        "# Persistence Drift Report",
        "",
        f"Baseline rev `{base.get('revision', 'unknown')}` ({base.get('generated', '')}) "
        f"vs observed rev `{obs.get('revision', 'unknown')}` ({obs.get('generated', '')}).",
        "",
        f"**Summary:** {summary.get('new_surfaces', 0)} new surface(s), "
        f"{summary.get('removed_surfaces', 0)} removed, "
        f"{summary.get('schema_drift', 0)} schema drift, "
        f"{summary.get('chokepoint_drift', 0)} chokepoint drift, "
        f"{summary.get('access_drift', 0)} access drift.",
        f"**Verdict:** {'✅ **CLEAN (No Persistence Drift Detected)**' if clean else '⚠️ **PERSISTENCE DRIFT DETECTED**'}",
        ""
    ]

    if clean:
        lines.append("All observed file persistence operations conform to the registered baseline.")
        return "\n".join(lines) + "\n"

    entries = report.get("drift_entries", [])

    # Critical / New Surfaces
    new_surfaces = [e for e in entries if e.get("class") == "new_surface"]
    if new_surfaces:
        lines.extend([
            "---",
            f"### 🚨 Critical Drift: New Persistence Surfaces ({len(new_surfaces)})",
            ""
        ])
        for entry in new_surfaces:
            lines.extend([
                f"- **`{entry['surface']}`** [`new_surface`]",
                f"  - **Boundary:** `{entry.get('boundary', 'unknown')}`",
                f"  - **Category:** {entry.get('category', 'Unclassified')}",
                f"  - **Beads Role Recommendation:** **{entry.get('beads_role_recommendation', 'UNKNOWN')}**",
                f"  - **Writers:** {', '.join(entry.get('writers', [])) or 'none'}",
                f"  - **Readers:** {', '.join(entry.get('readers', [])) or 'none'}",
                ""
            ])

    # Schema Drift
    schema_entries = [e for e in entries if e.get("class") == "schema_drift"]
    if schema_entries:
        lines.extend([
            "---",
            f"### ⚠️ Schema & Format Drift ({len(schema_entries)})",
            ""
        ])
        for entry in schema_entries:
            lines.extend([
                f"- **`{entry['surface']}`** [`schema_drift`]",
                f"  - **Boundary:** `{entry.get('boundary', 'unknown')}`",
                f"  - **Changes:** {json.dumps(entry.get('changes', []))}",
                ""
            ])

    # Chokepoint Drift
    choke_entries = [e for e in entries if e.get("class") == "chokepoint_drift"]
    if choke_entries:
        lines.extend([
            "---",
            f"### 🛡️ Chokepoint & Bypass Drift ({len(choke_entries)})",
            ""
        ])
        for entry in choke_entries:
            lines.extend([
                f"- **`{entry['surface']}`** [`chokepoint_drift`]",
                f"  - **Boundary:** `{entry.get('boundary', 'unknown')}`",
                f"  - **New Bypass Leaks:** {', '.join(entry.get('new_bypass_leaks', [])) or 'none'}",
                f"  - **Resolved Bypass Leaks:** {', '.join(entry.get('resolved_bypass_leaks', [])) or 'none'}",
                ""
            ])

    # Access Drift
    access_entries = [e for e in entries if e.get("class") == "access_drift"]
    if access_entries:
        lines.extend([
            "---",
            f"### 📊 Access Graph Drift ({len(access_entries)})",
            ""
        ])
        for entry in access_entries:
            lines.extend([
                f"- **`{entry['surface']}`** [`access_drift`]",
                f"  - **Boundary:** `{entry.get('boundary', 'unknown')}`",
                f"  - **New Readers:** {', '.join(entry.get('new_readers', [])) or 'none'}",
                f"  - **New Writers:** {', '.join(entry.get('new_writers', [])) or 'none'}",
                ""
            ])

    return "\n".join(lines) + "\n"


def to_text(report: Dict[str, Any]) -> str:
    """Format the report as concise CLI text."""
    summary = report.get("summary", {})
    clean = summary.get("clean", True)
    status = "CLEAN" if clean else "DRIFT DETECTED"
    lines = [
        f"persistence-drift: {status}",
        f"  new_surfaces: {summary.get('new_surfaces', 0)}",
        f"  removed_surfaces: {summary.get('removed_surfaces', 0)}",
        f"  schema_drift: {summary.get('schema_drift', 0)}",
        f"  chokepoint_drift: {summary.get('chokepoint_drift', 0)}",
        f"  access_drift: {summary.get('access_drift', 0)}",
    ]
    if not clean:
        for entry in report.get("drift_entries", []):
            lines.append(f"  * [{entry.get('class')}] {entry.get('surface')}: {entry.get('detail', '')}")
    return "\n".join(lines) + "\n"
