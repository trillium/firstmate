#!/usr/bin/env python3
"""End-to-end persistence shift and drift detection tool.

Integrates upstream git revision monitoring with the persistence AST analyzer
to detect if upstream commits introduce unmapped persistence drift.

Usage:
    python3 drift/persist_shift.py [--fm-home /path/to/firstmate] [--format json|markdown|text]
"""

import argparse
import subprocess
import sys
from pathlib import Path

# Add parent directory for module imports
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from drift.persist_check import main as check_main


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check upstream persistence shift and drift.")
    parser.add_argument("--fm-home", default=".", help="Path to Firstmate checkout root")
    parser.add_argument(
        "--format",
        choices=("json", "markdown", "text"),
        default="markdown",
        help="Report format (default: markdown)"
    )
    args, remaining = parser.parse_known_args(argv)

    fm_home = Path(args.fm_home).resolve()
    baseline = fm_home / "drift" / "persist_baseline.json"

    # Forward to persist_check
    check_args = ["--fm-home", str(fm_home), "--format", args.format]
    if baseline.exists():
        check_args.extend([str(baseline)])

    return check_main(check_args)


if __name__ == "__main__":
    sys.exit(main())
