#!/usr/bin/env python3
"""Export and reconcile all formal strategy results with the FlyingrtxFast strategy library."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_DIR = ROOT / "tools/research-results/strategy-library"


def run(command: list[str]) -> None:
    completed = subprocess.run(command, cwd=ROOT, text=True, check=False)
    if completed.returncode != 0:
        raise SystemExit(completed.returncode)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="https://api.flyingrtx.com")
    parser.add_argument("--agents-file", default="AGENTS.md")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    run([sys.executable, "scripts/export_strategy_library_manifest.py", "--all"])
    manifests = sorted(MANIFEST_DIR.glob("*-strategy-library-v1.json"))
    if not manifests:
        raise SystemExit("no strategy-library manifests were exported")

    for manifest in manifests:
        command = [
            sys.executable,
            "scripts/publish_strategy_library_manifest.py",
            "--manifest", str(manifest.relative_to(ROOT)),
            "--base-url", args.base_url,
            "--agents-file", args.agents_file,
            "--timeout", str(args.timeout),
        ]
        if args.validate_only:
            command.append("--validate-only")
        run(command)
        if not args.validate_only:
            run([
                sys.executable,
                "scripts/publish_strategy_library_manifest.py",
                "--manifest", str(manifest.relative_to(ROOT)),
                "--base-url", args.base_url,
                "--agents-file", args.agents_file,
                "--timeout", str(args.timeout),
                "--status-only",
            ])

    mode = "validated" if args.validate_only else "published"
    print(f"STRATEGY_LIBRARY_SYNC_COMPLETE mode={mode} batches={len(manifests)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
