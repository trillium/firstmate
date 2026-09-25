#!/usr/bin/env python3
"""CLI entry point for checking Firstmate persistence drift.

Usage:
    python3 drift/persist_check.py BASELINE OBSERVED [--format json|markdown|text]
    python3 drift/persist_check.py --fm-home /path/to/firstmate [--baseline BASELINE] [--format json|markdown|text]

Exit 0: No persistence drift.
Exit 1: Persistence drift detected.
Exit 2: Read, snapshot, or usage error.
"""

import argparse
import json
import sys
from pathlib import Path

# Add parent directory for module imports
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from drift.persist_diff import diff_persist_snapshots
from drift.persist_report import to_json, to_markdown, to_text
from drift.persist_snapshot import generate_snapshot


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ValueError(f"cannot read {path}: {exc}")
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path} is not valid JSON: {exc}")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check Firstmate persistence drift.")
    parser.add_argument("baseline", nargs="?", help="Path to baseline snapshot JSON")
    parser.add_argument("observed", nargs="?", help="Path to observed snapshot JSON")
    parser.add_argument("--fm-home", help="Path to Firstmate checkout root (generates live observed snapshot)")
    parser.add_argument(
        "--format",
        choices=("json", "markdown", "text"),
        default="markdown",
        help="Report format (default: markdown)"
    )
    args = parser.parse_args(argv)

    drift_dir = Path(__file__).resolve().parent
    default_baseline = drift_dir / "persist_baseline.json"

    baseline_path = Path(args.baseline) if args.baseline else default_baseline

    if not baseline_path.exists():
        print(f"persist-check error: baseline file not found at {baseline_path}", file=sys.stderr)
        return 2

    try:
        baseline_snap = load_json(baseline_path)
    except ValueError as exc:
        print(f"persist-check error: {exc}", file=sys.stderr)
        return 2

    if args.observed:
        obs_path = Path(args.observed)
        try:
            observed_snap = load_json(obs_path)
        except ValueError as exc:
            print(f"persist-check error: {exc}", file=sys.stderr)
            return 2
    elif args.fm_home:
        fm_home = Path(args.fm_home).resolve()
        observed_snap = generate_snapshot(fm_home)
    else:
        # Default to checking current repo root
        repo_root = drift_dir.parent
        observed_snap = generate_snapshot(repo_root)

    report = diff_persist_snapshots(baseline_snap, observed_snap)

    if args.format == "json":
        sys.stdout.write(to_json(report))
    elif args.format == "markdown":
        sys.stdout.write(to_markdown(report))
    else:
        sys.stdout.write(to_text(report))

    clean = report.get("summary", {}).get("clean", True)
    return 0 if clean else 1


if __name__ == "__main__":
    sys.exit(main())
