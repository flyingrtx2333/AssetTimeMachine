#!/usr/bin/env python3
"""Build a point-in-time first-release SLOOS DRTSCILM series from ALFRED vintages.

This script is data construction only. It never loads portfolio returns or computes strategy performance.
ALFRED's public release calendar for SLOOS begins in 2010, so observations before 2010Q2 are
intentionally excluded rather than falsely labeling a 2010 vintage as their original release.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
SERIES_ID = "DRTSCILM"
RELEASE_ID = 191
FIRST_TRUSTED_OBSERVATION = dt.date(2010, 4, 1)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def curl_bytes(url: str) -> bytes:
    result = subprocess.run(
        [
            "curl", "-L", "--http1.1", "--retry", "4", "--retry-delay", "1",
            "--connect-timeout", "15", "--max-time", "60", url,
        ],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=75,
        check=False,
    )
    if result.returncode != 0 or len(result.stdout) < 20:
        raise RuntimeError(f"download failed: {url}")
    return result.stdout


def release_dates() -> list[dt.date]:
    url = f"https://alfred.stlouisfed.org/release/downloaddates?ff=txt&rid={RELEASE_ID}"
    text = curl_bytes(url).decode("utf-8", errors="replace")
    return sorted({
        dt.date.fromisoformat(token)
        for token in re.findall(r"(?m)^\d{4}-\d{2}-\d{2}$", text)
        if token >= "2010-04-20"
    })


def parse_latest_snapshot(path: Path) -> tuple[dt.date, float] | None:
    rows: list[tuple[dt.date, float]] = []
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            raw = next((value for key, value in row.items() if key != "observation_date"), "")
            if not raw or raw == ".":
                continue
            try:
                observation_date = dt.date.fromisoformat(row["observation_date"])
                value = float(raw)
            except (KeyError, TypeError, ValueError):
                continue
            if observation_date >= FIRST_TRUSTED_OBSERVATION:
                rows.append((observation_date, value))
    return max(rows, key=lambda item: item[0]) if rows else None


def fetch_snapshot(release_date: dt.date, cache_dir: Path) -> tuple[dt.date, dt.date, float] | None:
    cache = cache_dir / f"{release_date.isoformat()}.csv"
    if not cache.exists() or cache.stat().st_size < 20:
        params = urlencode({
            "id": SERIES_ID,
            "cosd": (release_date - dt.timedelta(days=220)).isoformat(),
            "coed": release_date.isoformat(),
            "vintage_date": release_date.isoformat(),
        })
        cache.write_bytes(curl_bytes("https://alfred.stlouisfed.org/graph/alfredgraph.csv?" + params))
    latest = parse_latest_snapshot(cache)
    if latest is None:
        return None
    observation_date, value = latest
    return release_date, observation_date, value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = ROOT / output_dir
    cache_dir = output_dir / "raw-alfred-vintages"
    cache_dir.mkdir(parents=True, exist_ok=True)

    releases = release_dates()
    snapshots: dict[dt.date, tuple[dt.date, dt.date, float] | None] = {}
    with ThreadPoolExecutor(max_workers=12) as pool:
        futures = {pool.submit(fetch_snapshot, release, cache_dir): release for release in releases}
        for future in as_completed(futures):
            release = futures[future]
            try:
                snapshots[release] = future.result()
            except Exception:
                snapshots[release] = None

    first_by_observation: dict[dt.date, tuple[dt.date, float]] = {}
    for release in releases:
        snapshot = snapshots.get(release)
        if snapshot is None:
            continue
        release_date, observation_date, value = snapshot
        if observation_date not in first_by_observation:
            first_by_observation[observation_date] = (release_date, value)

    rows = sorted(first_by_observation.items())
    if len(rows) < 20:
        raise RuntimeError(f"too few trusted first-release SLOOS observations: {len(rows)}")

    out = output_dir / "DRTSCILM_FIRST_RELEASE.csv"
    with out.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["release_date", "available_date", "observation_date", "initial_value"])
        for observation_date, (release_date, value) in rows:
            writer.writerow([
                release_date.isoformat(),
                (release_date + dt.timedelta(days=1)).isoformat(),
                observation_date.isoformat(),
                f"{value:.8f}",
            ])

    missing_releases = [release.isoformat() for release in releases if snapshots.get(release) is None]
    summary = {
        "series_id": SERIES_ID,
        "release_id": RELEASE_ID,
        "purpose": "first-release SLOOS standards construction only; no strategy performance",
        "performance_computed": False,
        "trusted_observation_start": FIRST_TRUSTED_OBSERVATION.isoformat(),
        "trusted_start_reason": "ALFRED SLOOS release calendar begins 2010-04-20; older observations are not treated as point-in-time initial releases",
        "availability_rule": "release_date + 1 calendar day",
        "risk_direction_only": "higher net tightening is adverse for future U.S. stock returns; no strategy threshold is selected in this fetcher",
        "release_dates": len(releases),
        "usable_initial_observations": len(rows),
        "first_observation_date": rows[0][0].isoformat(),
        "last_observation_date": rows[-1][0].isoformat(),
        "first_release_date": rows[0][1][0].isoformat(),
        "last_release_date": rows[-1][1][0].isoformat(),
        "missing_release_snapshots": missing_releases,
        "output_sha256": sha256(out),
        "raw_snapshot_count": sum(1 for path in cache_dir.glob("*.csv") if path.is_file()),
    }
    summary_path = output_dir / "fetch-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    print("SLOOS_FIRST_RELEASE_FETCH_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
