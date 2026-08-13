#!/usr/bin/env python3
"""Assemble a temporary strategy_metric_dump Swift source with one research fragment.

This keeps experimental blocks out of the production research CLI until they are accepted.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="tools/strategy_metric_dump.swift")
    parser.add_argument("--fragment", required=True)
    parser.add_argument(
        "--marker",
        default='        if ProcessInfo.processInfo.environment["ATM_ACTUAL_DRAWDOWN_GOVERNOR_GRID"] == "1" {',
    )
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    base_path = Path(args.base)
    fragment_path = Path(args.fragment)
    output_path = Path(args.output)

    base = base_path.read_text(encoding="utf-8")
    fragment = fragment_path.read_text(encoding="utf-8").rstrip() + "\n\n"
    count = base.count(args.marker)
    if count != 1:
        raise SystemExit(f"expected marker exactly once, found {count}: {args.marker!r}")

    assembled = base.replace(args.marker, fragment + args.marker, 1)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(assembled, encoding="utf-8")
    print(f"assembled={output_path} bytes={len(assembled.encode('utf-8'))}")


if __name__ == "__main__":
    main()
