#!/usr/bin/env python3
"""Refresh the pinned App backtest fixture and rebuild its golden metrics.

The request intentionally mirrors tools/strategy_metric_dump.swift:
- the same public-history endpoint
- the same 12 symbols
- period=all
- include_ohlc=true
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = ROOT / "tools/fixtures/backtest-history/public_history.json"
DEFAULT_BASELINE = ROOT / "tools/expected_backtest_metrics/app/app_engine_strategy_baseline.json"
DEFAULT_BINARY = Path("/private/tmp/strategy_metric_dump")
ENDPOINT = "https://api.flyingrtx.com/api/v1/money/public/history"
SYMBOLS = [
    "gold_cny",
    "nasdaq_composite",
    "sp500",
    "dow_jones",
    "hang_seng",
    "nikkei225",
    "oil_wti_cny",
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
    "AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift",
    "AssetTimeMachine/Backtest/BacktestEngine.swift",
    "tools/strategy_metric_dump.swift",
]


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        handle.write(data)
        temp_path = Path(handle.name)
    temp_path.replace(path)


def fetch_fixture(path: Path, timeout: int) -> dict:
    query = urllib.parse.urlencode(
        {
            "symbols": ",".join(SYMBOLS),
            "period": "all",
            "include_ohlc": "true",
        }
    )
    request = urllib.request.Request(
        f"{ENDPOINT}?{query}",
        headers={"Accept": "application/json", "User-Agent": "AssetTimeMachine-baseline-refresh/1"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = response.read()
    document = json.loads(payload)
    if document.get("success") is not True:
        raise RuntimeError("History endpoint returned success=false")
    returned = {item.get("symbol") for item in document.get("series", [])}
    missing = set(SYMBOLS) - returned
    if missing:
        raise RuntimeError(f"History response is missing symbols: {sorted(missing)}")
    atomic_write(path, payload)
    return document


def compile_metric_dump(binary: Path, timeout: int) -> None:
    command = [
        "xcrun",
        "swiftc",
        "-parse-as-library",
        "-module-cache-path",
        "/private/tmp/atm-swift-module-cache",
        *SWIFT_SOURCES,
        "-o",
        str(binary),
    ]
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout)
    if result.returncode != 0:
        sys.stderr.write(result.stdout[-8000:] + result.stderr[-8000:])
        raise RuntimeError("Failed to compile strategy_metric_dump")


def collect_slice_rows(binary: Path, fixture: Path, timeout: int) -> list[dict[str, str]]:
    environment = os.environ.copy()
    environment["ATM_HISTORY_FIXTURE"] = str(fixture)
    environment["ATM_DUMP_SLICES"] = "1"
    result = subprocess.run(
        [str(binary)],
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout[-8000:] + result.stderr[-8000:])
        raise RuntimeError("Metric dump failed")
    lines = result.stdout.splitlines()
    if not lines or lines[0] != "APP_STRATEGY_SLICE_METRICS":
        raise RuntimeError("Unexpected metric dump output")
    return list(csv.DictReader(lines[1:]))


def update_baseline(path: Path, fixture_document: dict, rows: list[dict[str, str]]) -> dict:
    document = json.loads(path.read_text())
    actual = {(row["id"], row["slice"]): row for row in rows}
    expected = {
        (strategy["id"], slice_name)
        for strategy in document["strategies"]
        for slice_name in strategy["metrics_by_slice"]
    }
    missing = expected - set(actual)
    if missing:
        raise RuntimeError(f"Metric dump is missing baseline rows: {sorted(missing)}")

    for strategy in document["strategies"]:
        for slice_name, target in strategy["metrics_by_slice"].items():
            row = actual[(strategy["id"], slice_name)]
            annualized = float(row["annualized"])
            drawdown = float(row["max_drawdown"])
            volatility = float(row["volatility"])
            sharpe = float(row["sharpe"])
            target["metrics_percent"] = {
                "annualized": annualized,
                "max_drawdown": drawdown,
                "volatility": volatility,
                "sharpe": sharpe,
            }
            target["metrics"] = {
                "annualized_return": annualized / 100,
                "max_drawdown": -abs(drawdown) / 100,
                "annualized_volatility": volatility / 100,
                "sharpe": sharpe,
            }
            target["start"] = row["start"]
            target["end"] = row["end"]
            target["point_count"] = int(row["points"])

    document["generated_at"] = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    document["source"] = (
        "scripts/refresh_app_backtest_baseline.py using the same period=all "
        "public-history request as tools/strategy_metric_dump.swift"
    )
    document["assumptions"]["verified_source_ref"] = "latest-app-history-snapshot"
    document["assumptions"]["note"] = (
        "Pinned snapshot refreshed from the same symbols, period=all, and include_ohlc=true "
        "public-history request used by the App metric dump. Refresh before formal strategy research."
    )
    document["history_fixture_series_count"] = len(fixture_document["series"])
    document["history_fixture_symbols"] = [item["symbol"] for item in fixture_document["series"]]
    document["history_fixture_max_end"] = fixture_document["end_date"]
    atomic_write(path, (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode())
    return document


def verify(binary: Path, fixture: Path, baseline: Path, timeout: int) -> None:
    environment = os.environ.copy()
    environment["ATM_HISTORY_FIXTURE"] = str(fixture)
    environment["ATM_BASELINE_PATH"] = str(baseline)
    result = subprocess.run(
        [str(binary), "--verify-app-baseline"],
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise RuntimeError("Golden baseline verification failed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--skip-download", action="store_true")
    parser.add_argument("--skip-compile", action="store_true")
    parser.add_argument("--skip-verify", action="store_true")
    args = parser.parse_args()

    fixture = args.fixture.resolve()
    baseline = args.baseline.resolve()
    binary = args.binary.resolve()

    if args.skip_download:
        fixture_document = json.loads(fixture.read_text())
    else:
        fixture_document = fetch_fixture(fixture, args.timeout)
    if not args.skip_compile:
        compile_metric_dump(binary, args.timeout)

    rows = collect_slice_rows(binary, fixture, args.timeout)
    document = update_baseline(baseline, fixture_document, rows)
    if not args.skip_verify:
        verify(binary, fixture, baseline, args.timeout)

    target_rows = [
        row for row in rows if row["id"] == "risk-contribution-cash-confidence-router"
    ]
    print(
        "REFRESH_OK",
        f"fixture_end={fixture_document['end_date']}",
        f"series={len(fixture_document['series'])}",
        f"strategies={len(document['strategies'])}",
    )
    for row in target_rows:
        print(
            "TARGET",
            row["slice"],
            f"annualized={row['annualized']}",
            f"drawdown={row['max_drawdown']}",
            f"volatility={row['volatility']}",
            f"sharpe={row['sharpe']}",
            f"end={row['end']}",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
