#!/usr/bin/env python3
from __future__ import annotations

import csv
import datetime as dt
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "tools/research-results/nfci_credit_realtime_us_derisk_events.csv"
SERIES = ["NFCIRISK", "NFCILEVERAGE"]


def fetch_vintage(series_id: str, release_date: dt.date) -> tuple[dt.date, float] | None:
    cache_dir = ROOT / f"tools/research-results/{series_id.lower()}-vintages"
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache = cache_dir / f"{release_date.isoformat()}.csv"
    if not cache.exists() or cache.stat().st_size < 20:
        params = urlencode({
            "id": series_id,
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
                pass
    return max(rows, key=lambda x: x[0]) if rows else None


def main() -> None:
    rows = list(csv.DictReader(SOURCE.open()))
    needed: set[dt.date] = set()
    for row in rows:
        for field in ("release_date", "release_4w", "release_8w"):
            if row.get(field):
                needed.add(dt.date.fromisoformat(row[field]))
    print(f"events={len(rows)} vintages={len(needed)}", flush=True)

    for series_id in SERIES:
        snapshots: dict[dt.date, tuple[dt.date, float] | None] = {}
        with ThreadPoolExecutor(max_workers=12) as pool:
            futures = {pool.submit(fetch_vintage, series_id, d): d for d in sorted(needed)}
            for future in as_completed(futures):
                d = futures[future]
                try:
                    snapshots[d] = future.result()
                except Exception:
                    snapshots[d] = None
        out = ROOT / f"tools/research-results/{series_id}_realtime_us_derisk_events.csv"
        fields = [
            "trade_date", "release_date", "observation_date", "initial_value",
            "release_4w", "initial_4w", "change_4w",
            "release_8w", "initial_8w", "change_8w",
            "edge20", "edge60", "prior_leader", "new_leader", "us_delta", "gross_delta",
        ]
        output = []
        for row in rows:
            current_date = dt.date.fromisoformat(row["release_date"])
            current = snapshots.get(current_date)
            four_date = dt.date.fromisoformat(row["release_4w"]) if row.get("release_4w") else None
            eight_date = dt.date.fromisoformat(row["release_8w"]) if row.get("release_8w") else None
            four = snapshots.get(four_date) if four_date else None
            eight = snapshots.get(eight_date) if eight_date else None
            if current is None:
                continue
            output.append({
                "trade_date": row["trade_date"],
                "release_date": row["release_date"],
                "observation_date": current[0].isoformat(),
                "initial_value": current[1],
                "release_4w": row.get("release_4w", ""),
                "initial_4w": four[1] if four else "",
                "change_4w": current[1] - four[1] if four else "",
                "release_8w": row.get("release_8w", ""),
                "initial_8w": eight[1] if eight else "",
                "change_8w": current[1] - eight[1] if eight else "",
                "edge20": row["edge20"],
                "edge60": row["edge60"],
                "prior_leader": row["prior_leader"],
                "new_leader": row["new_leader"],
                "us_delta": row["us_delta"],
                "gross_delta": row["gross_delta"],
            })
        with out.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fields)
            writer.writeheader(); writer.writerows(output)
        usable = sum(1 for x in snapshots.values() if x is not None)
        print(f"{series_id}: snapshots={usable}/{len(needed)} events={len(output)} output={out.name}", flush=True)
        print("rule,count,mean20,mean60,win20,win60")
        for field in ("change_4w", "change_8w"):
            for threshold in (0.0, -0.03, -0.05, -0.10):
                group = [r for r in output if r[field] not in ("", None) and float(r[field]) <= threshold and r["edge20"] not in ("", "n/a")]
                e20 = [float(r["edge20"]) for r in group]
                e60 = [float(r["edge60"]) for r in group if r["edge60"] not in ("", "n/a")]
                mean20 = sum(e20) / len(e20) if e20 else float("nan")
                mean60 = sum(e60) / len(e60) if e60 else float("nan")
                win20 = sum(x > 0 for x in e20) / len(e20) if e20 else 0
                win60 = sum(x > 0 for x in e60) / len(e60) if e60 else 0
                print(f"{field}<={threshold:+.2f},{len(group)},{mean20:.4f},{mean60:.4f},{win20:.3f},{win60:.3f}")


if __name__ == "__main__":
    main()
