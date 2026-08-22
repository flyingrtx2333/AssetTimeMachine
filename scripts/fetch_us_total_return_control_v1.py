#!/usr/bin/env python3
"""Fetch the fixed SPY adjusted-close matched control without computing strategy performance."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import subprocess
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SERIES_ID = "SPY"
OFFICIAL_INCEPTION = "1993-01-22"
USER_AGENT = "AssetTimeMachine-USTotalReturnControlV1/1.0"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request_bytes(url: str, timeout: int = 30) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except Exception as first_error:
        completed = subprocess.run(
            [
                "curl", "--http1.1", "-fsSL", "--retry", "3", "--retry-all-errors",
                "--connect-timeout", "10", "--max-time", "45", "-A", USER_AGENT, url,
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode == 0 and completed.stdout:
            return completed.stdout
        raise RuntimeError(
            f"request failed: {url}; urllib={first_error}; "
            f"curl={completed.stderr.decode('utf-8', 'ignore')[:500]}"
        )


def finite(raw: Any) -> float | None:
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


def fetch_adjusted_close(start: str, end: str) -> tuple[list[tuple[str, float]], dict[str, Any]]:
    start_dt = datetime.fromisoformat(start).replace(tzinfo=timezone.utc)
    end_dt = datetime.fromisoformat(end).replace(tzinfo=timezone.utc) + timedelta(days=1)
    query = urllib.parse.urlencode(
        {
            "period1": int(start_dt.timestamp()),
            "period2": int(end_dt.timestamp()),
            "interval": "1d",
            "events": "history",
            "includeAdjustedClose": "true",
        }
    )
    url = (
        "https://query1.finance.yahoo.com/v8/finance/chart/"
        f"{urllib.parse.quote(SERIES_ID, safe='')}?{query}"
    )
    document = json.loads(request_bytes(url))
    chart = document.get("chart") or {}
    if chart.get("error"):
        raise RuntimeError(f"Yahoo chart error for {SERIES_ID}: {chart['error']}")
    results = chart.get("result") or []
    if not results:
        raise RuntimeError("Yahoo chart returned no SPY result")
    result = results[0]
    timestamps = result.get("timestamp") or []
    adjusted_entries = ((result.get("indicators") or {}).get("adjclose") or [])
    adjusted = adjusted_entries[0].get("adjclose") if adjusted_entries else None
    if adjusted is None:
        raise RuntimeError("Yahoo chart missing SPY adjusted close")
    rows: list[tuple[str, float]] = []
    for index, raw_timestamp in enumerate(timestamps):
        if index >= len(adjusted):
            continue
        value = finite(adjusted[index])
        if value is None or value <= 0:
            continue
        rows.append((datetime.fromtimestamp(int(raw_timestamp), timezone.utc).date().isoformat(), value))
    rows.sort(key=lambda item: item[0])
    if not rows or len({day for day, _ in rows}) != len(rows):
        raise RuntimeError("invalid SPY adjusted-close rows")
    meta = result.get("meta") or {}
    return rows, {
        "source": "YAHOO",
        "series_id": SERIES_ID,
        "price_field": "adjusted_close_total_return_proxy",
        "instrument_type": meta.get("instrumentType"),
        "exchange_name": meta.get("exchangeName"),
        "currency": meta.get("currency"),
        "timezone": meta.get("exchangeTimezoneName"),
        "url_template": "https://query1.finance.yahoo.com/v8/finance/chart/<series>?period1=<start>&period2=<end>&interval=1d&includeAdjustedClose=true",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--end", required=True)
    args = parser.parse_args()
    output_dir = Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = ROOT / output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    rows, provenance = fetch_adjusted_close(OFFICIAL_INCEPTION, args.end)
    path = output_dir / "SPY.csv"
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["date", "adjusted_close"])
        writer.writerows(rows)
    gaps = [
        (datetime.fromisoformat(right).date() - datetime.fromisoformat(left).date()).days
        for (left, _), (right, _) in zip(rows, rows[1:])
    ]
    summary = {
        "purpose": "matched investable broad-U.S. total-return control construction only; no strategy performance",
        "performance_computed": False,
        "selection_policy": "SPY is fixed ex ante as the investable broad-S&P total-return comparator for IWD because the frozen V11 sp500 fixture is a price index while IWD uses adjusted close",
        "series": {
            "SPY": {
                "role": "broad U.S. S&P 500 investable matched control",
                "official_inception": OFFICIAL_INCEPTION,
                "rows": len(rows),
                "first_date": rows[0][0],
                "last_date": rows[-1][0],
                "max_calendar_gap": max(gaps, default=0),
                "path": path.relative_to(ROOT).as_posix(),
                "sha256": sha256(path),
                "provenance": provenance,
            }
        },
    }
    summary_path = output_dir / "fetch-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    print("US_TOTAL_RETURN_CONTROL_V1_FETCH_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
