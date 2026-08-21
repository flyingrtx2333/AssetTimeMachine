#!/usr/bin/env python3
"""Fetch preregistered Final Crisis Filter V6 adjusted-close inputs only."""
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

ALLOWED_SOURCES = {
    "VIX9D": "^VIX9D",
    "VIX": "^VIX",
    "VVIX": "^VVIX",
    "HYG": "HYG",
    "SHY": "SHY",
}
USER_AGENT = "AssetTimeMachine-FinalCrisisFilterV6/1.0"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request_bytes(url: str, *, accept: str = "application/json", timeout: int = 30) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except Exception as first_error:
        completed = subprocess.run(
            [
                "curl", "--http1.1", "-fsSL", "--retry", "3", "--retry-all-errors",
                "--connect-timeout", "10", "--max-time", str(max(timeout, 30)),
                "-A", USER_AGENT, "-H", f"Accept: {accept}", url,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode == 0 and completed.stdout:
            return completed.stdout
        message = completed.stderr.decode("utf-8", "ignore").strip()
        raise RuntimeError(f"request failed: {url}; urllib={first_error}; curl={message or completed.returncode}")


def finite_number(raw: Any) -> float | None:
    if raw is None or raw == "":
        return None
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


def validate_rows(rows: list[tuple[str, float]], *, label: str) -> list[tuple[str, float]]:
    if not rows:
        raise RuntimeError(f"{label} returned no valid rows")
    ordered = sorted(rows, key=lambda row: row[0])
    dates = [day for day, _ in ordered]
    if len(dates) != len(set(dates)):
        raise RuntimeError(f"{label} contains duplicate dates")
    if any(value <= 0 or not math.isfinite(value) for _, value in ordered):
        raise RuntimeError(f"{label} contains invalid adjusted-close values")
    return ordered


def parse_yahoo_adjusted_chart(payload: bytes) -> tuple[list[tuple[str, float]], dict[str, Any]]:
    document = json.loads(payload)
    chart = document.get("chart") or {}
    if chart.get("error"):
        raise RuntimeError(f"Yahoo chart error: {chart['error']}")
    results = chart.get("result") or []
    if not results:
        raise RuntimeError("Yahoo chart returned no result")
    result = results[0]
    timestamps = result.get("timestamp") or []
    indicators = result.get("indicators") or {}
    adjusted_entries = indicators.get("adjclose") or []
    if not adjusted_entries or "adjclose" not in adjusted_entries[0]:
        raise RuntimeError("Yahoo chart missing adjusted-close series")
    adjusted = adjusted_entries[0].get("adjclose") or []
    rows: list[tuple[str, float]] = []
    for index, raw_timestamp in enumerate(timestamps):
        if index >= len(adjusted):
            continue
        value = finite_number(adjusted[index])
        if value is None or value <= 0:
            continue
        day = datetime.fromtimestamp(int(raw_timestamp), timezone.utc).date().isoformat()
        rows.append((day, value))
    meta = result.get("meta") or {}
    return validate_rows(rows, label="Yahoo adjusted close"), {
        "instrument_type": meta.get("instrumentType"),
        "exchange_name": meta.get("exchangeName"),
        "currency": meta.get("currency"),
        "timezone": meta.get("exchangeTimezoneName"),
    }


def fetch_yahoo_adjusted(series_id: str, start: str, end: str) -> tuple[list[tuple[str, float]], dict[str, Any]]:
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
    rows, meta = parse_yahoo_adjusted_chart(request_bytes(url))
    return rows, {
        "source": "YAHOO",
        "series_id": series_id,
        "price_field": "adjusted_close",
        "url_template": "https://query1.finance.yahoo.com/v8/finance/chart/<series>?period1=<start>&period2=<end>&interval=1d&includeAdjustedClose=true",
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
        "trial_id": "ATM-SVP2-ORTHO-FACTOR-006",
        "start": args.start,
        "end": args.end,
        "series": {},
    }
    for output_id, series_id in ALLOWED_SOURCES.items():
        rows, provenance = fetch_yahoo_adjusted(series_id, args.start, args.end)
        path = output_dir / f"{output_id}.csv"
        write_csv(path, rows)
        summary["series"][output_id] = {
            "series_id": series_id,
            "path": path.as_posix(),
            "rows": len(rows),
            "first_date": rows[0][0],
            "last_date": rows[-1][0],
            "sha256": sha256(path),
            "provenance": provenance,
        }
        print(
            f"EVENT_FACTOR_FETCHED id={output_id} series={series_id} rows={len(rows)} "
            f"first={rows[0][0]} last={rows[-1][0]} sha256={sha256(path)}"
        )
    summary_path = output_dir / "fetch-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"EVENT_FACTOR_FETCH_COMPLETE summary={summary_path} sha256={sha256(summary_path)}")


if __name__ == "__main__":
    main()
