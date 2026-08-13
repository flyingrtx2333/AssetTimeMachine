#!/usr/bin/env python3
"""Fetch the frozen final asset-OOS holdout from FRED/Nasdaq country index series.

The strategy and validation thresholds are defined before this script is run. This script only
materializes the preregistered country-equity proxy data in PublicHistoryResponse JSON shape.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import json
from pathlib import Path
import tempfile

try:
    from curl_cffi import requests
except ImportError as exc:  # pragma: no cover - explicit setup guidance for research machines
    raise SystemExit("curl_cffi is required: python3 -m pip install --user curl_cffi") from exc

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "tools/fixtures/backtest-history/asset_agnostic_final_holdout.json"

SERIES = [
    ("holdout_korea", "NASDAQNQKR", "NASDAQ Korea Index"),
    ("holdout_germany", "NASDAQNQDE", "NASDAQ Germany Index"),
    ("holdout_uk", "NASDAQNQGB", "NASDAQ UK Index"),
    ("holdout_france", "NASDAQNQFR", "NASDAQ France Index"),
    ("holdout_australia", "NASDAQNQAU", "NASDAQ Australia Index"),
    ("holdout_india", "NASDAQNQIN", "NASDAQ India Index"),
    ("holdout_brazil", "NASDAQNQBR", "NASDAQ Brazil Index"),
    ("holdout_canada", "NASDAQNQCA", "NASDAQ Canada Index"),
]


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        handle.write(payload)
        temp_path = Path(handle.name)
    temp_path.replace(path)


def fetch_series(symbol: str, fred_id: str, label: str, timeout: int) -> dict:
    url = f"https://fred.stlouisfed.org/graph/fredgraph.csv?id={fred_id}"
    response = requests.get(url, impersonate="chrome", timeout=timeout)
    response.raise_for_status()
    rows = csv.DictReader(io.StringIO(response.text))
    dates: list[str] = []
    prices: list[float] = []
    for row in rows:
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
        raise RuntimeError(f"{fred_id} only returned {len(dates)} valid daily observations")
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
            item = fetch_series(symbol, fred_id, label, args.timeout)
            series.append(item)
            print("FRED_HOLDOUT_OK", symbol, fred_id, item["dates"][0], item["dates"][-1], len(item["dates"]))
        except Exception as exc:  # noqa: BLE001 - keep partial provider availability explicit
            failures.append(f"{symbol}/{fred_id}: {exc}")
            print("FRED_HOLDOUT_FAIL", symbol, fred_id, exc)

    if len(series) < 6:
        raise RuntimeError(f"Only {len(series)} holdout markets available; need at least 6. Failures: {failures}")

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
            "note": "Final asset-OOS proxy snapshot; strategy parameters and PASS thresholds were frozen before validation.",
        },
    }
    output = args.output.resolve()
    atomic_write(output, (json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n").encode())
    print("FRED_HOLDOUT_FIXTURE_OK", output, len(series))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
