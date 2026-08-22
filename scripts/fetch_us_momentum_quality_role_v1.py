#!/usr/bin/env python3
"""Fetch fixed MTUM/QUAL total-return inputs before strategy performance is opened."""
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
SOURCES = {
    "MTUM": {"series_id": "MTUM", "official_inception": "2013-04-16", "role": "U.S. momentum"},
    "QUAL": {"series_id": "QUAL", "official_inception": "2013-07-16", "role": "U.S. sector-neutral quality"},
}
USER_AGENT = "AssetTimeMachine-USMomentumQualityRoleV1/1.0"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request_bytes(url: str, timeout: int = 30) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except Exception as first_error:
        completed = subprocess.run(
            ["curl", "--http1.1", "-fsSL", "--retry", "3", "--retry-all-errors", "--connect-timeout", "10", "--max-time", "45", "-A", USER_AGENT, url],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode == 0 and completed.stdout:
            return completed.stdout
        raise RuntimeError(f"request failed: {url}; urllib={first_error}; curl={completed.stderr.decode('utf-8', 'ignore')[:500]}")


def finite(raw: Any) -> float | None:
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


def fetch_adjusted_close(series_id: str, start: str, end: str) -> tuple[list[tuple[str, float]], dict[str, Any]]:
    start_dt = datetime.fromisoformat(start).replace(tzinfo=timezone.utc) - timedelta(days=10)
    end_dt = datetime.fromisoformat(end).replace(tzinfo=timezone.utc) + timedelta(days=1)
    query = urllib.parse.urlencode({
        "period1": int(start_dt.timestamp()),
        "period2": int(end_dt.timestamp()),
        "interval": "1d",
        "events": "history",
        "includeAdjustedClose": "true",
    })
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{urllib.parse.quote(series_id, safe='')}?{query}"
    document = json.loads(request_bytes(url))
    chart = document.get("chart") or {}
    if chart.get("error"):
        raise RuntimeError(f"Yahoo chart error for {series_id}: {chart['error']}")
    results = chart.get("result") or []
    if not results:
        raise RuntimeError(f"Yahoo chart returned no result for {series_id}")
    result = results[0]
    timestamps = result.get("timestamp") or []
    adjusted_entries = ((result.get("indicators") or {}).get("adjclose") or [])
    adjusted = adjusted_entries[0].get("adjclose") if adjusted_entries else None
    if adjusted is None:
        raise RuntimeError(f"Yahoo chart missing adjusted close for {series_id}")
    rows: list[tuple[str, float]] = []
    for index, raw_timestamp in enumerate(timestamps):
        if index >= len(adjusted):
            continue
        value = finite(adjusted[index])
        if value is None or value <= 0:
            continue
        rows.append((datetime.fromtimestamp(int(raw_timestamp), timezone.utc).date().isoformat(), value))
    rows.sort(key=lambda item: item[0])
    if len(rows) < 1000 or len({day for day, _ in rows}) != len(rows):
        raise RuntimeError(f"invalid adjusted-close history for {series_id}")
    meta = result.get("meta") or {}
    return rows, {
        "source": "YAHOO",
        "series_id": series_id,
        "price_field": "adjusted_close_total_return_proxy",
        "instrument_type": meta.get("instrumentType"),
        "exchange_name": meta.get("exchangeName"),
        "currency": meta.get("currency"),
        "timezone": meta.get("exchangeTimezoneName"),
    }


def write_csv(path: Path, rows: list[tuple[str, float]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["date", "adjusted_close"])
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--end", required=True)
    args = parser.parse_args()
    output_dir = Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = ROOT / output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    summary: dict[str, Any] = {
        "purpose": "fixed MTUM/QUAL asset-role data construction only; no AssetTimeMachine strategy performance",
        "performance_computed": False,
        "selection_policy": "MTUM and QUAL are both frozen before either role-substitution result is viewed",
        "series": {},
    }
    for name, spec in SOURCES.items():
        rows, provenance = fetch_adjusted_close(spec["series_id"], spec["official_inception"], args.end)
        path = output_dir / f"{name}.csv"
        write_csv(path, rows)
        gaps = [
            (datetime.fromisoformat(right).date() - datetime.fromisoformat(left).date()).days
            for (left, _), (right, _) in zip(rows, rows[1:])
        ]
        summary["series"][name] = {
            "role": spec["role"],
            "official_inception": spec["official_inception"],
            "rows": len(rows),
            "first_date": rows[0][0],
            "first_return_date": rows[1][0],
            "last_date": rows[-1][0],
            "max_calendar_gap": max(gaps, default=0),
            "path": path.relative_to(ROOT).as_posix(),
            "sha256": sha256(path),
            "provenance": provenance,
        }
    summary["common_substitution_start"] = max(
        item["first_return_date"] for item in summary["series"].values()
    )
    summary["common_evaluation_start"] = summary["common_substitution_start"]
    summary_path = output_dir / "fetch-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    print("US_MOMENTUM_QUALITY_ROLE_V1_FETCH_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
