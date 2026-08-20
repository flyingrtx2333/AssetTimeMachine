#!/usr/bin/env python3
"""Fetch the preregistered Orthogonal Factor Family V1 raw inputs only.

This module never computes strategy returns, candidate metrics, or factor-conditioned portfolio
performance. It only writes immutable date/value source series and provenance for the formal run.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

ALLOWED_FACTOR_SOURCES = {
    "T10Y3M": ("FRED", "T10Y3M"),
    "DXY": ("YAHOO", "DX-Y.NYB"),
    "RUT": ("YAHOO", "^RUT"),
    "RUI": ("YAHOO", "^RUI"),
}
USER_AGENT = "AssetTimeMachine-OrthogonalFactorV1/1.0"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request_bytes(url: str, *, accept: str = "*/*", timeout: int = 30) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def finite_number(raw: Any) -> float | None:
    if raw is None or raw == "" or raw == ".":
        return None
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


def parse_fred_csv(text: str, series_id: str) -> list[tuple[str, float]]:
    reader = csv.DictReader(io.StringIO(text))
    rows: list[tuple[str, float]] = []
    for item in reader:
        date_value = item.get("DATE") or item.get("observation_date")
        value = finite_number(item.get(series_id))
        if date_value and value is not None:
            rows.append((str(date_value)[:10], value))
    return validate_rows(rows, label=f"FRED:{series_id}")


def parse_yahoo_chart(payload: bytes) -> tuple[list[tuple[str, float]], dict[str, Any]]:
    document = json.loads(payload)
    chart = document.get("chart") or {}
    if chart.get("error"):
        raise RuntimeError(f"Yahoo chart error: {chart['error']}")
    results = chart.get("result") or []
    if not results:
        raise RuntimeError("Yahoo chart returned no result")
    result = results[0]
    timestamps = result.get("timestamp") or []
    quote = ((result.get("indicators") or {}).get("quote") or [{}])[0]
    closes = quote.get("close") or []
    rows: list[tuple[str, float]] = []
    for index, raw_timestamp in enumerate(timestamps):
        if index >= len(closes):
            continue
        close = finite_number(closes[index])
        if close is None:
            continue
        day = datetime.fromtimestamp(int(raw_timestamp), timezone.utc).date().isoformat()
        rows.append((day, close))
    meta = result.get("meta") or {}
    return validate_rows(rows, label="Yahoo"), {
        "instrument_type": meta.get("instrumentType"),
        "exchange_name": meta.get("exchangeName"),
        "currency": meta.get("currency"),
        "timezone": meta.get("exchangeTimezoneName"),
    }


def validate_rows(rows: list[tuple[str, float]], *, label: str) -> list[tuple[str, float]]:
    if not rows:
        raise RuntimeError(f"{label} returned no valid rows")
    ordered = sorted(rows, key=lambda row: row[0])
    dates = [date_value for date_value, _ in ordered]
    if len(dates) != len(set(dates)):
        raise RuntimeError(f"{label} contains duplicate dates")
    if any(not math.isfinite(value) for _, value in ordered):
        raise RuntimeError(f"{label} contains non-finite values")
    return ordered


def fetch_fred(series_id: str, start: str, end: str) -> tuple[list[tuple[str, float]], dict[str, Any]]:
    query = urllib.parse.urlencode({"id": series_id, "cosd": start, "coed": end})
    url = f"https://fred.stlouisfed.org/graph/fredgraph.csv?{query}"
    text = request_bytes(url, accept="text/csv").decode("utf-8-sig")
    return parse_fred_csv(text, series_id), {
        "source": "FRED",
        "series_id": series_id,
        "url_template": "https://fred.stlouisfed.org/graph/fredgraph.csv?id=<series>&cosd=<start>&coed=<end>",
    }


def fetch_yahoo(series_id: str, start: str, end: str) -> tuple[list[tuple[str, float]], dict[str, Any]]:
    start_dt = datetime.fromisoformat(start).replace(tzinfo=timezone.utc)
    end_dt = datetime.fromisoformat(end).replace(tzinfo=timezone.utc) + timedelta(days=1)
    query = urllib.parse.urlencode({
        "period1": int(start_dt.timestamp()),
        "period2": int(end_dt.timestamp()),
        "interval": "1d",
        "events": "history",
        "includeAdjustedClose": "true",
    })
    encoded = urllib.parse.quote(series_id, safe="")
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{encoded}?{query}"
    rows, meta = parse_yahoo_chart(request_bytes(url, accept="application/json"))
    return rows, {
        "source": "YAHOO",
        "series_id": series_id,
        "url_template": "https://query1.finance.yahoo.com/v8/finance/chart/<series>?period1=<start>&period2=<end>&interval=1d",
        **meta,
    }


def write_csv(path: Path, rows: list[tuple[str, float]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["date", "value"])
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--start", required=True)
    parser.add_argument("--end", required=True)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    summary: dict[str, Any] = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": "ATM-SVP2-ORTHO-FACTOR-001",
        "start": args.start,
        "end": args.end,
        "series": {},
    }
    for output_id, (source, series_id) in ALLOWED_FACTOR_SOURCES.items():
        if source == "FRED":
            rows, provenance = fetch_fred(series_id, args.start, args.end)
        elif source == "YAHOO":
            rows, provenance = fetch_yahoo(series_id, args.start, args.end)
        else:
            raise AssertionError(source)
        path = output_dir / f"{output_id}.csv"
        write_csv(path, rows)
        summary["series"][output_id] = {
            "source": source,
            "series_id": series_id,
            "path": path.as_posix(),
            "rows": len(rows),
            "first_date": rows[0][0],
            "last_date": rows[-1][0],
            "sha256": sha256(path),
            "provenance": provenance,
        }
        print(
            f"FACTOR_FETCHED id={output_id} source={source} series={series_id} "
            f"rows={len(rows)} first={rows[0][0]} last={rows[-1][0]} sha256={sha256(path)}"
        )
    summary_path = output_dir / "fetch-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"FACTOR_FETCH_COMPLETE summary={summary_path} sha256={sha256(summary_path)}")


if __name__ == "__main__":
    main()
