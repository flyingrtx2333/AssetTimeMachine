#!/usr/bin/env python3
"""Fetch frozen VIXCLS input for ATM-SVP2-VRP-001 without computing performance."""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import subprocess
import urllib.parse
import urllib.request
from pathlib import Path

USER_AGENT = "AssetTimeMachine-VRPProxyV1/1.0"
SERIES_ID = "VIXCLS"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request_bytes(url: str, timeout: int = 30) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "text/csv"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except Exception as first_error:
        completed = subprocess.run(
            [
                "curl", "--http1.1", "-fsSL", "--retry", "3", "--retry-all-errors",
                "--connect-timeout", "10", "--max-time", str(max(timeout, 30)),
                "-A", USER_AGENT, "-H", "Accept: text/csv", url,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode == 0 and completed.stdout:
            return completed.stdout
        raise RuntimeError(
            f"VIXCLS request failed; urllib={first_error}; curl={completed.stderr.decode('utf-8', 'ignore').strip()}"
        )


def parse_fred(text: str) -> list[tuple[str, float]]:
    rows: list[tuple[str, float]] = []
    for row in csv.DictReader(io.StringIO(text)):
        day = row.get("DATE") or row.get("observation_date")
        raw = row.get(SERIES_ID)
        if not day or raw in (None, "", "."):
            continue
        try:
            value = float(raw)
        except ValueError:
            continue
        if math.isfinite(value) and value > 0:
            rows.append((str(day)[:10], value))
    rows.sort(key=lambda item: item[0])
    if not rows or len({day for day, _ in rows}) != len(rows):
        raise RuntimeError("invalid VIXCLS rows")
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--start", required=True)
    parser.add_argument("--end", required=True)
    args = parser.parse_args()
    query = urllib.parse.urlencode({"id": SERIES_ID, "cosd": args.start, "coed": args.end})
    url = f"https://fred.stlouisfed.org/graph/fredgraph.csv?{query}"
    rows = parse_fred(request_bytes(url).decode("utf-8-sig"))
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / "VIXCLS.csv"
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["date", "value"])
        writer.writerows(rows)
    summary = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": "ATM-SVP2-VRP-001",
        "series_id": SERIES_ID,
        "source": "FRED",
        "start": args.start,
        "end": args.end,
        "rows": len(rows),
        "first_date": rows[0][0],
        "last_date": rows[-1][0],
        "availability_rule": "VIX close observation_date <= frozen V11 signal_date; max 7 calendar days stale",
        "performance_computed": False,
        "sha256": sha256(path),
    }
    summary_path = output_dir / "fetch-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"VRP_VIX_FETCHED rows={len(rows)} first={rows[0][0]} last={rows[-1][0]} "
        f"sha256={summary['sha256']} summary_sha256={sha256(summary_path)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
