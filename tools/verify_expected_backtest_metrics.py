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
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
BASELINE_PATH = ROOT / "tools" / "expected_backtest_metrics" / "app" / "app_engine_strategy_baseline.json"
FIXTURE_PATH = ROOT / "tools" / "fixtures" / "backtest-history" / "public_history.json"
HISTORY_SYMBOLS = [
    "gold_cny",
    "nasdaq_composite",
    "sp500",
    "dow_jones",
    "hang_seng",
    "nikkei225",
    "csi300",
    "shanghai_composite",
    "shenzhen_component",
    "chinext",
    "usd_per_cny",
]
SWIFT_SOURCES = [
    "AssetTimeMachine/Backtest/BacktestModels.swift",
    "AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift",
    "AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift",
    "AssetTimeMachine/Backtest/BacktestFXConverter.swift",
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


def dump_tool_supports_history_fixture(sources: list[Path]) -> bool:
    return any("ATM_HISTORY_FIXTURE" in path.read_text(encoding="utf-8") for path in sources)


def validate_history_payload(payload: dict) -> None:
    if not payload.get("success") or not payload.get("series"):
        raise RuntimeError("history fixture refresh returned an invalid payload")
    series = payload.get("series") or []
    symbols = [row.get("symbol") for row in series]
    missing = sorted(set(HISTORY_SYMBOLS) - set(symbols))
    if missing:
        raise RuntimeError(f"history fixture refresh missing symbols: {', '.join(missing)}")
    for row in series:
        symbol = row.get("symbol", "<unknown>")
        dates = row.get("dates") or []
        prices = row.get("prices") or []
        if not dates or not prices:
            raise RuntimeError(f"history fixture series is empty: {symbol}")
        if len(dates) != len(prices):
            raise RuntimeError(f"history fixture date/price length mismatch: {symbol}")


def refresh_fixture(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    query = urllib.parse.urlencode(
        {
            "symbols": ",".join(HISTORY_SYMBOLS),
            "period": "all",
            "include_ohlc": "false",
        }
    )
    url = f"https://api.flyingrtx.com/api/v1/money/public/history?{query}"
    with urllib.request.urlopen(url, timeout=60) as response:
        payload = json.loads(response.read().decode("utf-8"))
    validate_history_payload(payload)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def dump_slice_metrics(binary: Path, *, fixture: Path | None) -> str:
    env = os.environ.copy()
    env["ATM_DUMP_SLICES"] = "1"
    env.pop("ATM_HISTORY_FIXTURE", None)
    if fixture is not None:
        env["ATM_HISTORY_FIXTURE"] = str(fixture)
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
    parser.add_argument("--fixture", type=Path, default=FIXTURE_PATH, help="Pinned public-history fixture used by default.")
    parser.add_argument("--live-history", action="store_true", help="Use the live market-history endpoint instead of the pinned fixture.")
    parser.add_argument("--refresh-fixture", action="store_true", help="Refresh the pinned fixture from the live market-history endpoint before verifying.")
    parser.add_argument(
        "--metric-tolerance",
        type=float,
        default=0.1,
        help="Allowed absolute drift for percent metrics and Sharpe. The history endpoint can be served by slightly different cached backends, so keep this strict enough to catch architecture drift but loose enough to ignore sub-0.1pp data-cache jitter.",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    if args.live_history and args.refresh_fixture:
        parser.error("--live-history and --refresh-fixture are mutually exclusive")

    fixture: Path | None = None
    if not args.live_history:
        fixture_path: Path = args.fixture
        if args.refresh_fixture:
            refresh_fixture(fixture_path)
        if not fixture_path.exists():
            raise RuntimeError(f"history fixture not found: {fixture_path}. Run with --refresh-fixture once.")
        fixture = fixture_path

    with tempfile.TemporaryDirectory(prefix="atm-backtest-verify-") as tmp:
        temp_dir = Path(tmp)
        sources = source_paths(args.ref, temp_dir)
        if fixture is not None and not dump_tool_supports_history_fixture(sources):
            raise RuntimeError(
                "selected Swift sources do not support ATM_HISTORY_FIXTURE; "
                "use a ref that includes the pinned-fixture verifier change or pass --live-history"
            )
        binary = temp_dir / "strategy_metric_dump"
        compile_dump_tool(sources, binary)
        output = dump_slice_metrics(binary, fixture=fixture)

    actual = parse_dump_csv(output)
    expected = expected_rows(args.baseline)
    failures = compare(expected, actual, args.metric_tolerance)
    if failures:
        print("Backtest metric verification FAILED")
        print(f"baseline: {args.baseline}")
        print(f"source ref: {args.ref or 'working-tree'}")
        print(f"history: {'live' if fixture is None else fixture}")
        print(f"expected rows: {len(expected)}, actual rows: {len(actual)}")
        for failure in failures[:80]:
            print("- " + failure)
        if len(failures) > 80:
            print(f"... {len(failures) - 80} more failures")
        return 1

    print("Backtest metric verification OK")
    print(f"source ref: {args.ref or 'working-tree'}")
    print(f"history: {'live' if fixture is None else fixture}")
    print(f"strategies: {len({strategy_id for strategy_id, _ in expected})}")
    print(f"rows: {len(expected)}")
    print(f"slices: {', '.join(sorted(REQUIRED_SLICES))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
