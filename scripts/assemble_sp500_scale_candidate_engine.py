#!/usr/bin/env python3
"""Assemble a temporary production-engine variant with a scaled S&P 500 target."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="AssetTimeMachine/Backtest/BacktestEngine.swift")
    parser.add_argument("--output", default="/private/tmp/BacktestEngineSP500ScaleCandidate.swift")
    parser.add_argument("--scale", type=float, default=0.60)
    args = parser.parse_args()

    text = Path(args.base).read_text(encoding="utf-8")
    old = """                let gross = pendingWeights.values.reduce(0, +)
                if gross > grossCap, gross > 0 {
"""
    new = f"""                pendingWeights[\"sp500\"] = max(
                    (pendingWeights[\"sp500\"] ?? 0) * {args.scale:.12f},
                    0
                )
                let gross = pendingWeights.values.reduce(0, +)
                if gross > grossCap, gross > 0 {{
"""
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one production anchor, found {count}")
    text = text.replace(old, new, 1)
    output = Path(args.output)
    output.write_text(text, encoding="utf-8")
    print(f"assembled={output} scale={args.scale:.6f} bytes={output.stat().st_size}")


if __name__ == "__main__":
    main()
