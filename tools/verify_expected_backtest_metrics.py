#!/usr/bin/env python3
"""Verify App BacktestEngine golden metrics against the expected JSON baseline.

Default mode verifies the current working tree. Use --ref HEAD (or another git ref)
to verify a committed snapshot without being affected by local dirty files.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
BASELINE_PATH = ROOT / "tools" / "expected_backtest_metrics" / "app" / "app_engine_strategy_baseline.json"
SWIFT_SOURCES = [
    "AssetTimeMachine/Backtest/BacktestModels.swift",
    "AssetTimeMachine/Backtest/BacktestEngine.swift",
    "tools/strategy_metric_dump.swift",
]
REQUIRED_SLICES = {"full", "since2020", "last10y", "since2022"}
METRIC_KEYS = ["annualized", "max_drawdown", "volatility", "sharpe"]


@dataclass(frozen=True)
class ActualRow:
    title: str
    strategy_id: str
    slice_name: str
    metrics: dict[str, float]
    start: str
    end: str
    point_count: int


def run(command: list[str], *, cwd: Path = ROOT, env: dict[str, str] | None = None, capture: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=False,
    )


def git_show(ref: str, path: str) -> str:
    result = run(["git", "show", f"{ref}:{path}"])
    if result.returncode != 0:
        raise RuntimeError(f"git show {ref}:{path} failed:\n{result.stderr}")
    return result.stdout


def source_paths(ref: str | None, temp_dir: Path) -> list[Path]:
    if ref is None:
        return [ROOT / path for path in SWIFT_SOURCES]

    materialized: list[Path] = []
    for path in SWIFT_SOURCES:
        target = temp_dir / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(git_show(ref, path), encoding="utf-8")
        materialized.append(target)
    return materialized


def compile_dump_tool(sources: list[Path], output: Path) -> None:
    cmd = [
        "xcrun",
        "swiftc",
        "-parse-as-library",
        "-module-cache-path",
        str(output.parent / "swift-module-cache"),
        *[str(path) for path in sources],
        "-o",
        str(output),
    ]
    result = run(cmd, capture=True)
    if result.returncode != 0:
        raise RuntimeError("swiftc failed:\n" + result.stdout + result.stderr)


def dump_slice_metrics(binary: Path) -> str:
    env = os.environ.copy()
    env["ATM_DUMP_SLICES"] = "1"
    result = run([str(binary)], env=env, capture=True)
    if result.returncode != 0:
        raise RuntimeError("strategy metric dump failed:\n" + result.stdout + result.stderr)
    return result.stdout


def parse_dump_csv(text: str) -> dict[tuple[str, str], ActualRow]:
    lines = [line for line in text.splitlines() if line.strip()]
    try:
        header_index = lines.index("title,id,slice,annualized,max_drawdown,volatility,sharpe,start,end,points")
    except ValueError as exc:
        raise RuntimeError("slice metric CSV header not found in dump output") from exc

    rows: dict[tuple[str, str], ActualRow] = {}
    reader = csv.DictReader(lines[header_index:])
    for row in reader:
        strategy_id = row["id"]
        slice_name = row["slice"]
        key = (strategy_id, slice_name)
        if key in rows:
            raise RuntimeError(f"duplicate dump row for {strategy_id} / {slice_name}")
        rows[key] = ActualRow(
            title=row["title"],
            strategy_id=strategy_id,
            slice_name=slice_name,
            metrics={metric: float(row[metric]) for metric in METRIC_KEYS},
            start=row["start"],
            end=row["end"],
            point_count=int(row["points"]),
        )
    return rows


def expected_rows(path: Path) -> dict[tuple[str, str], dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 2:
        raise RuntimeError(f"unsupported baseline schema_version: {data.get('schema_version')}")
    if data.get("baseline_type") != "app_backtest_engine_baseline_not_full_app_equivalent_replay":
        raise RuntimeError(f"unexpected baseline_type: {data.get('baseline_type')}")

    rows: dict[tuple[str, str], dict] = {}
    for strategy in data["strategies"]:
        slices = strategy.get("metrics_by_slice", {})
        if set(slices) != REQUIRED_SLICES:
            raise RuntimeError(
                f"{strategy['id']} slices mismatch: expected {sorted(REQUIRED_SLICES)}, got {sorted(slices)}"
            )
        for slice_name, payload in slices.items():
            rows[(strategy["id"], slice_name)] = {
                "title": strategy["title"],
                "metrics": payload["metrics_percent"],
                "start": payload["start"],
                "end": payload["end"],
                "point_count": payload["point_count"],
            }
    return rows


def compare(expected: dict[tuple[str, str], dict], actual: dict[tuple[str, str], ActualRow], metric_tolerance: float) -> list[str]:
    failures: list[str] = []
    expected_keys = set(expected)
    actual_keys = set(actual)
    for missing in sorted(expected_keys - actual_keys):
        failures.append(f"missing actual row: {missing[0]} / {missing[1]}")
    for extra in sorted(actual_keys - expected_keys):
        failures.append(f"extra actual row: {extra[0]} / {extra[1]}")

    for key in sorted(expected_keys & actual_keys):
        exp = expected[key]
        act = actual[key]
        label = f"{key[0]} / {key[1]}"
        if exp["start"] != act.start:
            failures.append(f"{label}: start expected {exp['start']} got {act.start}")
        if exp["end"] != act.end:
            failures.append(f"{label}: end expected {exp['end']} got {act.end}")
        if exp["point_count"] != act.point_count:
            failures.append(f"{label}: points expected {exp['point_count']} got {act.point_count}")
        for metric in METRIC_KEYS:
            expected_value = float(exp["metrics"][metric])
            actual_value = float(act.metrics[metric])
            delta = abs(expected_value - actual_value)
            if delta > metric_tolerance:
                failures.append(
                    f"{label}: {metric} expected {expected_value:.6f} got {actual_value:.6f} delta {delta:.6f}"
                )
    return failures


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify App BacktestEngine expected metrics.")
    parser.add_argument("--ref", help="Verify Swift sources from a git ref, e.g. HEAD. Defaults to current working tree.")
    parser.add_argument("--baseline", type=Path, default=BASELINE_PATH, help="Expected baseline JSON path.")
    parser.add_argument(
        "--metric-tolerance",
        type=float,
        default=0.1,
        help="Allowed absolute drift for percent metrics and Sharpe. The history endpoint can be served by slightly different cached backends, so keep this strict enough to catch architecture drift but loose enough to ignore sub-0.1pp data-cache jitter.",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    with tempfile.TemporaryDirectory(prefix="atm-backtest-verify-") as tmp:
        temp_dir = Path(tmp)
        sources = source_paths(args.ref, temp_dir)
        binary = temp_dir / "strategy_metric_dump"
        compile_dump_tool(sources, binary)
        output = dump_slice_metrics(binary)

    actual = parse_dump_csv(output)
    expected = expected_rows(args.baseline)
    failures = compare(expected, actual, args.metric_tolerance)
    if failures:
        print("Backtest metric verification FAILED")
        print(f"baseline: {args.baseline}")
        print(f"source ref: {args.ref or 'working-tree'}")
        print(f"expected rows: {len(expected)}, actual rows: {len(actual)}")
        for failure in failures[:80]:
            print("- " + failure)
        if len(failures) > 80:
            print(f"... {len(failures) - 80} more failures")
        return 1

    print("Backtest metric verification OK")
    print(f"source ref: {args.ref or 'working-tree'}")
    print(f"strategies: {len({strategy_id for strategy_id, _ in expected})}")
    print(f"rows: {len(expected)}")
    print(f"slices: {', '.join(sorted(REQUIRED_SLICES))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
