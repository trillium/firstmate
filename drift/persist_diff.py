#!/usr/bin/env python3
"""Diff engine for Firstmate persistence snapshots.

Categorizes persistence differences across Five Persistence Drift Classes:
1. new_surface: Novel persistence surface detected (Critical Feature Drift)
2. removed_surface: Registered surface deleted or unreferenced (Feature Drift)
3. schema_drift: Keys, columns, or format definitions modified (Breaking Drift)
4. chokepoint_drift: Bypass leaks introduced or helper chokepoints altered (Architectural Drift)
5. access_drift: New readers or writers for existing surfaces (Behavior Drift)
"""

from typing import Dict, Any, List, Optional


def diff_persist_snapshots(baseline: Dict[str, Any], observed: Dict[str, Any]) -> Dict[str, Any]:
    """Compare two persistence snapshot dicts and return structured drift report."""
    base_surfaces = baseline.get("surfaces", {})
    obs_surfaces = observed.get("surfaces", {})

    base_names = set(base_surfaces.keys())
    obs_names = set(obs_surfaces.keys())

    added_names = sorted(obs_names - base_names)
    removed_names = sorted(base_names - obs_names)
    common_names = sorted(base_names & obs_names)

    drift_entries: List[Dict[str, Any]] = []

    # 1. New Surfaces (Critical Feature Drift)
    for name in added_names:
        s_data = obs_surfaces[name]
        drift_entries.append({
            "surface": name,
            "class": "new_surface",
            "severity": "CRITICAL",
            "boundary": s_data.get("boundary", "boundary_unknown"),
            "category": s_data.get("category", "Unclassified"),
            "beads_role_recommendation": s_data.get("beads_role", "UNKNOWN"),
            "writers": s_data.get("verified_writers", []),
            "readers": s_data.get("verified_readers", []),
            "detail": f"Novel persistence surface observed: {name}"
        })

    # 2. Removed Surfaces (Feature Drift)
    for name in removed_names:
        s_data = base_surfaces[name]
        drift_entries.append({
            "surface": name,
            "class": "removed_surface",
            "severity": "HIGH",
            "boundary": s_data.get("boundary", "boundary_unknown"),
            "category": s_data.get("category", "Unclassified"),
            "detail": f"Registered baseline surface removed or unreferenced: {name}"
        })

    # 3. Changed Surfaces (Schema, Chokepoints, Access)
    schema_drift_count = 0
    chokepoint_drift_count = 0
    access_drift_count = 0

    for name in common_names:
        b_data = base_surfaces[name]
        o_data = obs_surfaces[name]

        # Schema Drift (keys, columns, format)
        schema_changes = []
        b_keys = set(b_data.get("keys", []))
        o_keys = set(o_data.get("keys", []))
        if b_keys != o_keys:
            schema_changes.append({
                "field": "keys",
                "gained": sorted(o_keys - b_keys),
                "lost": sorted(b_keys - o_keys)
            })

        b_cols = b_data.get("columns", [])
        o_cols = o_data.get("columns", [])
        if b_cols != o_cols:
            schema_changes.append({
                "field": "columns",
                "baseline": b_cols,
                "observed": o_cols
            })

        if schema_changes:
            schema_drift_count += 1
            drift_entries.append({
                "surface": name,
                "class": "schema_drift",
                "severity": "HIGH",
                "boundary": o_data.get("boundary", b_data.get("boundary")),
                "changes": schema_changes,
                "detail": f"Schema definition altered for surface: {name}"
            })

        # Chokepoint & Bypass Drift
        b_bypass = set(b_data.get("bypass_leaks", []))
        o_bypass = set(o_data.get("bypass_leaks", []))
        new_bypasses = sorted(o_bypass - b_bypass)
        resolved_bypasses = sorted(b_bypass - o_bypass)

        b_chokes = set(b_data.get("chokepoints", []))
        o_chokes = set(o_data.get("chokepoints", []))
        choke_diff = b_chokes != o_chokes

        if new_bypasses or resolved_bypasses or choke_diff:
            chokepoint_drift_count += 1
            drift_entries.append({
                "surface": name,
                "class": "chokepoint_drift",
                "severity": "HIGH" if new_bypasses else "MEDIUM",
                "boundary": o_data.get("boundary", b_data.get("boundary")),
                "new_bypass_leaks": new_bypasses,
                "resolved_bypass_leaks": resolved_bypasses,
                "detail": f"Bypass leaks or chokepoints modified for surface: {name}"
            })

        # Access Drift (New readers / writers)
        b_readers = set(b_data.get("verified_readers", []))
        o_readers = set(o_data.get("verified_readers", []))
        new_readers = sorted(o_readers - b_readers)

        b_writers = set(b_data.get("verified_writers", []))
        o_writers = set(o_data.get("verified_writers", []))
        new_writers = sorted(o_writers - b_writers)

        if new_readers or new_writers:
            access_drift_count += 1
            drift_entries.append({
                "surface": name,
                "class": "access_drift",
                "severity": "LOW",
                "boundary": o_data.get("boundary", b_data.get("boundary")),
                "new_readers": new_readers,
                "new_writers": new_writers,
                "detail": f"Access graph modified (new readers/writers) for surface: {name}"
            })

    feature_drift_count = len(added_names) + len(removed_names) + schema_drift_count
    behavior_drift_count = chokepoint_drift_count + access_drift_count
    is_clean = len(drift_entries) == 0

    return {
        "version": 1,
        "baseline": {
            "revision": baseline.get("firstmate_revision", "unknown"),
            "generated": baseline.get("generated", "")
        },
        "observed": {
            "revision": observed.get("firstmate_revision", "unknown"),
            "generated": observed.get("generated", "")
        },
        "summary": {
            "clean": is_clean,
            "new_surfaces": len(added_names),
            "removed_surfaces": len(removed_names),
            "schema_drift": schema_drift_count,
            "chokepoint_drift": chokepoint_drift_count,
            "access_drift": access_drift_count,
            "feature_drift_count": feature_drift_count,
            "behavior_drift_count": behavior_drift_count
        },
        "drift_entries": drift_entries
    }
