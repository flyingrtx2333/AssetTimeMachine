#!/usr/bin/env python3
from __future__ import annotations

import csv
import datetime as dt
import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "tools/research-results/nfci-credit-vintages"
CACHE.mkdir(parents=True, exist_ok=True)
BINARY = Path("/private/tmp/atm_cc_external_event_attribution_safe")


def champion_us_derisk_rows() -> list[dict[str, str]]:
    env = os.environ.copy()
    env["ATM_HISTORY_FIXTURE"] = "tools/fixtures/backtest-history/public_history.json"
    env["ATM_CC_EXTERNAL_EVENT_ATTRIBUTION"] = "1"
    result = subprocess.run(
        [str(BINARY)], cwd=ROOT, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90, check=True,
    )
    lines = result.stdout.splitlines()
    header = "date,type,prior_leader,new_leader,gross_delta,us_delta,permission,credit_change_z,vix,term_ratio,vix_release,edge20,edge60"
    start = lines.index(header)
    reader = csv.DictReader([header] + [line for line in lines[start + 1:] if ",us-derisk," in line])
    return list(reader)


def release_dates() -> list[dt.date]:
    url = "https://alfred.stlouisfed.org/release/downloaddates?ff=txt&rid=221"
    result = subprocess.run(
        ["curl", "-L", "--http1.1", "--retry", "3", "--connect-timeout", "15", "--max-time", "60", url],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=75, check=True,
    )
    dates = []
    for token in re.findall(r"(?m)^\d{4}-\d{2}-\d{2}$", result.stdout):
        value = dt.date.fromisoformat(token)
        if value >= dt.date(2012, 7, 5):
            dates.append(value)
    return sorted(set(dates))


def fetch_vintage(release_date: dt.date) -> tuple[dt.date, float] | None:
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
            ["curl", "-L", "--http1.1", "--retry", "3", "--connect-timeout", "15", "--max-time", "60", url],
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
    return max(rows, key=lambda x: x[0]) if rows else None


def main() -> None:
    events = champion_us_derisk_rows()
    releases = release_dates()
    event_contexts = []
    needed: set[dt.date] = set()
    for event in events:
        trade = dt.date.fromisoformat(event["date"])
        cutoff = trade - dt.timedelta(days=1)  # strict T-1, conservative for weekends/holidays
        eligible = [d for d in releases if d <= cutoff]
        if not eligible:
            continue
        latest = eligible[-1]
        latest_index = releases.index(latest)
        r4 = releases[latest_index - 4] if latest_index >= 4 else None
        r8 = releases[latest_index - 8] if latest_index >= 8 else None
        event_contexts.append((event, latest, r4, r8))
        needed.add(latest)
        if r4: needed.add(r4)
        if r8: needed.add(r8)

    snapshots: dict[dt.date, tuple[dt.date, float] | None] = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(fetch_vintage, vintage): vintage for vintage in sorted(needed)}
        for future in as_completed(futures):
            vintage = futures[future]
            try:
                snapshots[vintage] = future.result()
            except Exception:
                snapshots[vintage] = None

    out_path = ROOT / "tools/research-results/nfci_credit_realtime_us_derisk_events.csv"
    fields = [
        "trade_date", "release_date", "observation_date", "credit_initial",
        "release_4w", "credit_initial_4w", "change_4w",
        "release_8w", "credit_initial_8w", "change_8w",
        "edge20", "edge60", "prior_leader", "new_leader", "us_delta", "gross_delta",
    ]
    output = []
    for event, latest, r4, r8 in event_contexts:
        current = snapshots.get(latest)
        four = snapshots.get(r4) if r4 else None
        eight = snapshots.get(r8) if r8 else None
        if current is None:
            continue
        output.append({
            "trade_date": event["date"],
            "release_date": latest.isoformat(),
            "observation_date": current[0].isoformat(),
            "credit_initial": current[1],
            "release_4w": r4.isoformat() if r4 else "",
            "credit_initial_4w": four[1] if four else "",
            "change_4w": current[1] - four[1] if four else "",
            "release_8w": r8.isoformat() if r8 else "",
            "credit_initial_8w": eight[1] if eight else "",
            "change_8w": current[1] - eight[1] if eight else "",
            "edge20": event["edge20"],
            "edge60": event["edge60"],
            "prior_leader": event["prior_leader"],
            "new_leader": event["new_leader"],
            "us_delta": event["us_delta"],
            "gross_delta": event["gross_delta"],
        })
    with out_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(output)

    print(f"events={len(events)} post_alfred={len(event_contexts)} usable={len(output)} snapshots={len(needed)}")
    print("trade_date,release_date,obs_date,credit,chg4,chg8,edge20,edge60")
    for row in output:
        print(
            f"{row['trade_date']},{row['release_date']},{row['observation_date']},"
            f"{float(row['credit_initial']):.5f},"
            f"{float(row['change_4w']):+.5f},{float(row['change_8w']):+.5f},"
            f"{row['edge20']},{row['edge60']}"
        )


if __name__ == "__main__":
    main()
