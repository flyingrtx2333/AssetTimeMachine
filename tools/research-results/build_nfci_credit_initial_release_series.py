#!/usr/bin/env python3
from __future__ import annotations

import csv
import datetime as dt
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "tools/research-results/nfci-credit-vintages"
CACHE.mkdir(parents=True, exist_ok=True)
OUT = ROOT / "tools/research-results/NFCICREDIT_initial_release.csv"


def release_dates() -> list[dt.date]:
    url = "https://alfred.stlouisfed.org/release/downloaddates?ff=txt&rid=221"
    result = subprocess.run(
        ["curl", "-L", "--http1.1", "--retry", "3", "--connect-timeout", "15", "--max-time", "60", url],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=75, check=True,
    )
    return sorted({
        dt.date.fromisoformat(token)
        for token in re.findall(r"(?m)^\d{4}-\d{2}-\d{2}$", result.stdout)
        if token >= "2012-07-05"
    })


def fetch_vintage(release_date: dt.date) -> tuple[dt.date, dt.date, float] | None:
    cache = CACHE / f"{release_date.isoformat()}.csv"
    if not cache.exists() or cache.stat().st_size < 20:
        params = urlencode({
            "id": "NFCICREDIT",
            "cosd": (release_date - dt.timedelta(days=14)).isoformat(),
            "coed": release_date.isoformat(),
            "vintage_date": release_date.isoformat(),
        })
        url = "https://alfred.stlouisfed.org/graph/alfredgraph.csv?" + params
        result = subprocess.run(
            ["curl", "-L", "--http1.1", "--retry", "4", "--retry-delay", "1", "--connect-timeout", "15", "--max-time", "60", url],
            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=75,
        )
        if result.returncode != 0 or len(result.stdout) < 20:
            return None
        cache.write_bytes(result.stdout)
    rows: list[tuple[dt.date, float]] = []
    with cache.open(newline="") as f:
        for row in csv.DictReader(f):
            raw = next((v for k, v in row.items() if k != "observation_date"), "")
            if not raw or raw == ".":
                continue
            try:
                rows.append((dt.date.fromisoformat(row["observation_date"]), float(raw)))
            except (ValueError, TypeError):
                continue
    if not rows:
        return None
    observation_date, value = max(rows, key=lambda x: x[0])
    return release_date, observation_date, value


def main() -> None:
    releases = release_dates()
    existing = sum((CACHE / f"{d.isoformat()}.csv").exists() for d in releases)
    print(f"releases={len(releases)} cached_before={existing}", flush=True)
    snapshots: dict[dt.date, tuple[dt.date, dt.date, float] | None] = {}
    with ThreadPoolExecutor(max_workers=14) as pool:
        futures = {pool.submit(fetch_vintage, d): d for d in releases}
        done = 0
        for future in as_completed(futures):
            d = futures[future]
            try:
                snapshots[d] = future.result()
            except Exception:
                snapshots[d] = None
            done += 1
            if done % 100 == 0:
                print(f"processed={done}/{len(releases)}", flush=True)

    usable = [x for x in snapshots.values() if x is not None]
    usable.sort(key=lambda x: x[0])
    with OUT.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["release_date", "observation_date", "initial_value"])
        for release_date, observation_date, value in usable:
            writer.writerow([release_date.isoformat(), observation_date.isoformat(), f"{value:.8f}"])
    missing = [d.isoformat() for d in releases if snapshots.get(d) is None]
    print(f"usable={len(usable)} missing={len(missing)} output={OUT}", flush=True)
    if missing:
        print("missing_dates=" + "|".join(missing), flush=True)
    if usable:
        print(f"first={usable[0]} last={usable[-1]}", flush=True)


if __name__ == "__main__":
    main()
