#!/usr/bin/env python3
"""Fetch initial-release monthly macro values from immutable ALFRED vintages.

This script never reads or computes strategy performance. It downloads the official
ALFRED release-date list, fetches the series snapshot for each release date, and
records a reference month only when it first appears in a release vintage.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "tools/research-results/macro-vintages/alfred-initial-release"
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


@dataclass(frozen=True)
class SeriesSpec:
    series_id: str
    release_id: int


SPECS = (
    SeriesSpec("UNRATE", 50),
    SeriesSpec("CPIAUCSL", 10),
)


def fetch(url: str, attempts: int = 5) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "AssetTimeMachineResearch/1.0"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                body = response.read()
                if not body:
                    raise RuntimeError("empty response")
                return body
        except (urllib.error.URLError, TimeoutError, RuntimeError) as error:
            if attempt + 1 == attempts:
                raise RuntimeError(f"fetch failed after {attempts} attempts: {url}: {error}") from error
            time.sleep(1.5 * (2**attempt))
    raise AssertionError("unreachable")


def release_dates(spec: SeriesSpec, output_dir: Path, min_release_date: str) -> list[str]:
    url = f"https://alfred.stlouisfed.org/release/downloaddates?rid={spec.release_id}&ff=txt"
    body = fetch(url)
    source_path = output_dir / "sources" / f"release_dates_{spec.release_id}.txt"
    source_path.parent.mkdir(parents=True, exist_ok=True)
    source_path.write_bytes(body)
    dates = sorted({line.strip() for line in body.decode("utf-8").splitlines() if DATE_RE.fullmatch(line.strip())})
    selected = [value for value in dates if value >= min_release_date]
    if not selected:
        raise RuntimeError(f"no release dates for {spec.series_id} at or after {min_release_date}")
    return selected


def snapshot_url(series_id: str, vintage_date: str, observation_start: str) -> str:
    query = urllib.parse.urlencode({
        "id": series_id,
        "cosd": observation_start,
        "vintage_date": vintage_date,
    })
    return f"https://alfred.stlouisfed.org/graph/alfredgraph.csv?{query}"


def parse_snapshot(series_id: str, vintage_date: str, body: bytes) -> tuple[str, str]:
    text = body.decode("utf-8-sig")
    rows = list(csv.DictReader(io.StringIO(text)))
    value_columns = [name for name in (rows[0].keys() if rows else []) if name != "observation_date"]
    if len(value_columns) != 1:
        raise RuntimeError(f"unexpected columns for {series_id} vintage {vintage_date}: {value_columns}")
    value_column = value_columns[0]
    valid: list[tuple[str, str]] = []
    for row in rows:
        observation = (row.get("observation_date") or "").strip()
        raw = (row.get(value_column) or "").strip()
        if not DATE_RE.fullmatch(observation) or raw in {"", "."}:
            continue
        value = float(raw)
        if not value == value or value in {float("inf"), float("-inf")}:
            continue
        valid.append((observation, raw))
    if not valid:
        raise RuntimeError(f"no valid observations for {series_id} vintage {vintage_date}")
    valid.sort()
    return valid[-1]


def month_next(month: str) -> str:
    year, value = map(int, month.split("-"))
    value += 1
    if value == 13:
        year += 1
        value = 1
    return f"{year:04d}-{value:02d}"


def months_between(left: str, right: str) -> list[str]:
    values: list[str] = []
    current = month_next(left)
    while current < right:
        values.append(current)
        current = month_next(current)
    return values


def collect(spec: SeriesSpec, output_dir: Path, min_release_date: str, observation_start: str, workers: int) -> Path:
    dates = release_dates(spec, output_dir, min_release_date)
    responses: dict[str, tuple[bytes, str]] = {}

    def one(vintage: str) -> tuple[str, bytes, str]:
        url = snapshot_url(spec.series_id, vintage, observation_start)
        cache_root = Path(os.environ.get("ATM_ALFRED_CACHE", "/private/tmp/atm-alfred-initial-release-cache"))
        cache_path = cache_root / spec.series_id / f"{vintage}.csv"
        if cache_path.is_file() and cache_path.stat().st_size > 0:
            body = cache_path.read_bytes()
        else:
            body = fetch(url)
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_bytes(body)
        return vintage, body, url

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(one, vintage): vintage for vintage in dates}
        for number, future in enumerate(as_completed(futures), start=1):
            vintage, body, url = future.result()
            responses[vintage] = (body, url)
            if number % 50 == 0 or number == len(futures):
                print(f"{spec.series_id}: fetched {number}/{len(futures)} release vintages", flush=True)

    initial_by_month: dict[str, dict[str, str]] = {}
    for vintage in dates:
        body, url = responses[vintage]
        observation_date, raw_value = parse_snapshot(spec.series_id, vintage, body)
        reference_month = observation_date[:7]
        if reference_month in initial_by_month:
            continue
        initial_by_month[reference_month] = {
            "series_id": spec.series_id,
            "reference_month": reference_month,
            "release_date": vintage,
            "initial_value": raw_value,
            "source": url,
            "vintage_id": vintage,
            "snapshot_sha256": hashlib.sha256(body).hexdigest(),
        }

    months = sorted(month for month in initial_by_month if month >= observation_start[:7])
    if not months:
        raise RuntimeError(f"no initial-release rows for {spec.series_id}")
    if months[0] != observation_start[:7]:
        raise RuntimeError(
            f"initial coverage for {spec.series_id} starts at {months[0]}, expected {observation_start[:7]}"
        )
    gaps: list[dict[str, str]] = []
    for left, right in zip(months, months[1:]):
        for missing in months_between(left, right):
            gaps.append({
                "series_id": spec.series_id,
                "missing_reference_month": missing,
                "previous_available_month": left,
                "next_available_month": right,
                "handling": "remain_or_move_to_cash; never interpolate or backfill",
            })
    for month in months:
        row = initial_by_month[month]
        release = date.fromisoformat(row["release_date"])
        reference = date.fromisoformat(month + "-01")
        if release <= reference:
            raise RuntimeError(f"impossible release order for {spec.series_id} {month}: {release}")

    output_path = output_dir / f"{spec.series_id}_initial_release.csv"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["series_id", "reference_month", "release_date", "initial_value", "source", "vintage_id", "snapshot_sha256"]
    with output_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(initial_by_month[month] for month in months)
    gaps_path = output_dir / f"{spec.series_id}_missing_reference_months.csv"
    gap_fields = [
        "series_id", "missing_reference_month", "previous_available_month",
        "next_available_month", "handling",
    ]
    with gaps_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=gap_fields)
        writer.writeheader()
        writer.writerows(gaps)
    print(
        f"{spec.series_id}: rows={len(months)} reference={months[0]}..{months[-1]} "
        f"release={initial_by_month[months[0]]['release_date']}..{initial_by_month[months[-1]]['release_date']} "
        f"gaps={len(gaps)} sha256={hashlib.sha256(output_path.read_bytes()).hexdigest()}"
    )
    return output_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--min-release-date", default="2000-01-01")
    parser.add_argument("--observation-start", default="1999-12-01")
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.workers <= 8:
        raise SystemExit("--workers must be between 1 and 8")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    outputs = [collect(spec, args.output_dir, args.min_release_date, args.observation_start, args.workers) for spec in SPECS]
    manifest_path = args.output_dir / "source-manifest.txt"
    lines = [
        f"generated_at_utc={datetime.now(timezone.utc).isoformat()}",
        "provider=Federal Reserve Bank of St. Louis ALFRED",
        "method=earliest official release vintage in which each reference month appears",
    ]
    auxiliary = list(args.output_dir.glob("*_missing_reference_months.csv"))
    for path in sorted(outputs + auxiliary + list((args.output_dir / "sources").glob("*.txt"))):
        lines.append(f"sha256={hashlib.sha256(path.read_bytes()).hexdigest()} bytes={path.stat().st_size} path={path.relative_to(ROOT)}")
    manifest_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"ALFRED_INITIAL_RELEASE_COMPLETE manifest={manifest_path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
