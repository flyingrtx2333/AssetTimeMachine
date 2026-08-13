#!/usr/bin/env python3
"""Download the preregistered third/final asset-OOS holdout for frozen V4."""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import json
from pathlib import Path
import tempfile

from curl_cffi import requests

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "tools/fixtures/backtest-history/asset_agnostic_final_holdout_v4.json"
SERIES = [
    ("holdout_norway", "NASDAQNQNO", "NASDAQ Norway Index"),
    ("holdout_denmark", "NASDAQNQDK", "NASDAQ Denmark Index"),
    ("holdout_finland", "NASDAQNQFI", "NASDAQ Finland Index"),
    ("holdout_belgium", "NASDAQNQBE", "NASDAQ Belgium Index"),
    ("holdout_austria", "NASDAQNQAT", "NASDAQ Austria Index"),
    ("holdout_portugal", "NASDAQNQPT", "NASDAQ Portugal Index"),
    ("holdout_new_zealand", "NASDAQNQNZ", "NASDAQ New Zealand Index"),
    ("holdout_south_africa", "NASDAQNQZA", "NASDAQ South Africa Index"),
]


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        handle.write(payload)
        temporary = Path(handle.name)
    temporary.replace(path)


def fetch(symbol: str, fred_id: str, label: str, timeout: int) -> dict:
    url = f"https://fred.stlouisfed.org/graph/fredgraph.csv?id={fred_id}"
    response = requests.get(url, impersonate="chrome", timeout=timeout)
    response.raise_for_status()
    dates: list[str] = []
    prices: list[float] = []
    for row in csv.DictReader(io.StringIO(response.text)):
        date_text = (row.get("observation_date") or row.get("DATE") or "").strip()
        value_text = (row.get(fred_id) or "").strip()
        if not date_text or value_text in {"", "."}:
            continue
        try:
            value = float(value_text)
        except ValueError:
            continue
        if value <= 0:
            continue
        dates.append(date_text)
        prices.append(value)
    if len(dates) < 800:
        raise RuntimeError(f"{fred_id} returned only {len(dates)} valid observations")
    return {
        "symbol": symbol,
        "category": "holdout_country_equity",
        "label": label,
        "currency": "INDEX",
        "unit": "Index",
        "source": f"FRED / Nasdaq Daily Index Data ({fred_id})",
        "dates": dates,
        "prices": prices,
        "has_ohlc": False,
        "ohlc_source": None,
        "ohlc_coverage_ratio": None,
        "open_prices": None,
        "high_prices": None,
        "low_prices": None,
        "close_prices": None,
        "volumes": None,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--timeout", type=int, default=45)
    args = parser.parse_args()

    series: list[dict] = []
    failures: list[str] = []
    for symbol, fred_id, label in SERIES:
        try:
            item = fetch(symbol, fred_id, label, args.timeout)
            series.append(item)
            print("FRED_V4_HOLDOUT_OK", symbol, fred_id, item["dates"][0], item["dates"][-1], len(item["dates"]))
        except Exception as exc:
            failures.append(f"{symbol}/{fred_id}: {exc}")
            print("FRED_V4_HOLDOUT_FAIL", symbol, fred_id, exc)

    if len(series) < 6:
        raise RuntimeError(f"Only {len(series)} V4 holdout markets available; need at least 6. Failures: {failures}")
    document = {
        "success": True,
        "series": series,
        "available_symbols": [item["symbol"] for item in series],
        "catalog": None,
        "research_metadata": {
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "provider": "FRED / Nasdaq Daily Index Data",
            "preregistered_series": [fred_id for _, fred_id, _ in SERIES],
            "fetch_failures": failures,
            "protocol": "docs/strategies/asset-agnostic-generalization-v4.md",
            "note": "Third final asset-OOS snapshot; frozenV4 and validator were fixed/compiled before download.",
        },
    }
    output = args.output.resolve()
    atomic_write(output, (json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n").encode())
    print("FRED_V4_HOLDOUT_FIXTURE_OK", output, len(series))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
