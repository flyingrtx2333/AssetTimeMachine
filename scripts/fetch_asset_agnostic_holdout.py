#!/usr/bin/env python3
"""Fetch the preregistered final cross-market holdout snapshot.

This script is intentionally separate from the App production fixture. It uses Yahoo Finance's
public chart endpoint only to build a frozen research holdout in the same JSON shape consumed by
PublicHistoryResponse. Strategy parameters must be frozen before running this script.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import tempfile
import time
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "tools/fixtures/backtest-history/asset_agnostic_final_holdout.json"

HOLDOUTS = [
    ("holdout_kospi", "^KS11", "KOSPI"),
    ("holdout_dax", "^GDAXI", "DAX"),
    ("holdout_ftse100", "^FTSE", "FTSE 100"),
    ("holdout_cac40", "^FCHI", "CAC 40"),
    ("holdout_asx200", "^AXJO", "S&P/ASX 200"),
    ("holdout_nifty50", "^NSEI", "NIFTY 50"),
    ("holdout_bovespa", "^BVSP", "Bovespa"),
    ("holdout_tsx", "^GSPTSE", "S&P/TSX Composite"),
]


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        handle.write(payload)
        temp_path = Path(handle.name)
    temp_path.replace(path)


def fetch_chart(ticker: str, start: dt.datetime, end: dt.datetime, timeout: int) -> dict:
    encoded = urllib.parse.quote(ticker, safe="")
    query = urllib.parse.urlencode(
        {
            "period1": int(start.timestamp()),
            "period2": int(end.timestamp()),
            "interval": "1d",
            "events": "history",
            "includeAdjustedClose": "true",
        }
    )
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{encoded}?{query}"
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 AssetTimeMachine-generalization-holdout/1.0",
        },
    )
    last_error: Exception | None = None
    for attempt in range(2):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read())
        except Exception as exc:  # noqa: BLE001 - retry network/provider failures as a batch fetcher
            last_error = exc
            if attempt == 1:
                break
            time.sleep(1.0)
    raise RuntimeError(f"Failed to fetch {ticker}: {last_error}")


def normalize_series(symbol: str, ticker: str, label: str, document: dict) -> dict:
    chart = document.get("chart", {})
    if chart.get("error"):
        raise RuntimeError(f"Yahoo returned an error for {ticker}: {chart['error']}")
    results = chart.get("result") or []
    if not results:
        raise RuntimeError(f"Yahoo returned no result for {ticker}")
    result = results[0]
    timestamps = result.get("timestamp") or []
    quote_rows = ((result.get("indicators") or {}).get("quote") or [])
    if not quote_rows:
        raise RuntimeError(f"Yahoo returned no quote rows for {ticker}")
    quote = quote_rows[0]
    meta = result.get("meta") or {}
    timezone_name = meta.get("exchangeTimezoneName") or "UTC"
    try:
        exchange_tz = ZoneInfo(timezone_name)
    except Exception:
        exchange_tz = dt.timezone.utc

    opens = quote.get("open") or []
    highs = quote.get("high") or []
    lows = quote.get("low") or []
    closes = quote.get("close") or []
    volumes = quote.get("volume") or []

    dates: list[str] = []
    prices: list[float] = []
    open_prices: list[float] = []
    high_prices: list[float] = []
    low_prices: list[float] = []
    close_prices: list[float] = []
    volume_values: list[float | None] = []

    count = min(len(timestamps), len(opens), len(highs), len(lows), len(closes))
    for index in range(count):
        values = (opens[index], highs[index], lows[index], closes[index])
        if any(value is None for value in values):
            continue
        open_value, high_value, low_value, close_value = map(float, values)
        if min(open_value, high_value, low_value, close_value) <= 0 or low_value > high_value:
            continue
        local_date = dt.datetime.fromtimestamp(timestamps[index], tz=dt.timezone.utc).astimezone(exchange_tz).date()
        dates.append(local_date.isoformat())
        prices.append(close_value)
        open_prices.append(open_value)
        high_prices.append(high_value)
        low_prices.append(low_value)
        close_prices.append(close_value)
        raw_volume = volumes[index] if index < len(volumes) else None
        volume_values.append(float(raw_volume) if raw_volume is not None else None)

    if len(dates) < 800:
        raise RuntimeError(f"Insufficient history for {ticker}: {len(dates)} rows")

    return {
        "symbol": symbol,
        "category": "holdout_index",
        "label": label,
        "currency": str(meta.get("currency") or "LOCAL"),
        "unit": str(meta.get("currency") or "index"),
        "source": f"Yahoo Finance chart API {ticker}",
        "dates": dates,
        "prices": prices,
        "has_ohlc": True,
        "ohlc_source": "Yahoo Finance chart API",
        "ohlc_coverage_ratio": 1.0,
        "open_prices": open_prices,
        "high_prices": high_prices,
        "low_prices": low_prices,
        "close_prices": close_prices,
        "volumes": volume_values,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--timeout", type=int, default=45)
    parser.add_argument("--start", default="1990-01-01")
    args = parser.parse_args()

    start = dt.datetime.fromisoformat(args.start).replace(tzinfo=dt.timezone.utc)
    end = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1)
    series: list[dict] = []
    failures: list[str] = []
    for symbol, ticker, label in HOLDOUTS:
        try:
            document = fetch_chart(ticker, start, end, args.timeout)
            normalized = normalize_series(symbol, ticker, label, document)
            series.append(normalized)
            print("HOLDOUT_FETCH_OK", symbol, ticker, normalized["dates"][0], normalized["dates"][-1], len(normalized["dates"]))
        except Exception as exc:  # noqa: BLE001 - preserve partial provider availability
            failures.append(f"{symbol} {ticker}: {exc}")
            print("HOLDOUT_FETCH_FAIL", symbol, ticker, exc)

    if len(series) < 6:
        raise RuntimeError(f"Only {len(series)} holdout markets fetched successfully; need at least 6. Failures: {failures}")

    payload = {
        "success": True,
        "series": series,
        "available_symbols": [item["symbol"] for item in series],
        "start_date": min(item["dates"][0] for item in series),
        "end_date": max(item["dates"][-1] for item in series),
        "holdout_preregistered_symbols": [item[0] for item in HOLDOUTS],
        "fetch_failures": failures,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    atomic_write(args.output.resolve(), (json.dumps(payload, ensure_ascii=False) + "\n").encode())
    print("HOLDOUT_FIXTURE_OK", args.output.resolve(), len(series), payload["start_date"], payload["end_date"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
