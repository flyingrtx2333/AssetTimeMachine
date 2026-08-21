#!/usr/bin/env python3
"""Fetch only the six frozen Yahoo factor inputs for prospective shadow tracking.

The request end and the durable CSVs are both clipped to the frozen V11 signal_date. Future observations
must never be persisted into a prospective factor snapshot input bundle.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from datetime import date, timedelta
from pathlib import Path
from typing import Any

from fetch_orthogonal_event_factor_v4 import fetch_yahoo_adjusted, write_csv

TRIAL_ID = "ATM-SVP2-PROSPECTIVE-FACTOR-001"
ALLOWED_SOURCES = {
    "HYG": "HYG",
    "SHY": "SHY",
    "RSP": "RSP",
    "SPY": "SPY",
    "SPHB": "SPHB",
    "SPLV": "SPLV",
}
PAIR_IDS = {
    "F-CREDITCASH-PROSPECTIVE": ("HYG", "SHY"),
    "F-BREADTH-PROSPECTIVE": ("RSP", "SPY"),
    "F-HIGHBETA-PROSPECTIVE": ("SPHB", "SPLV"),
}
FETCH_LOOKBACK_CALENDAR_DAYS = 120
MIN_SOURCE_OBSERVATIONS = 21


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clip_rows_to_signal_date(rows: list[tuple[str, float]], signal_date: str) -> list[tuple[str, float]]:
    clipped = [(day, value) for day, value in rows if day <= signal_date]
    if len(clipped) < MIN_SOURCE_OBSERVATIONS:
        raise RuntimeError(
            f"prospective source has only {len(clipped)} usable observations through signal_date={signal_date}; "
            f"need at least {MIN_SOURCE_OBSERVATIONS}"
        )
    if any(day > signal_date for day, _ in clipped):
        raise AssertionError("future factor observation survived signal-date clipping")
    return clipped


def common_observation_count(
    left: list[tuple[str, float]],
    right: list[tuple[str, float]],
) -> int:
    return len({day for day, _ in left}.intersection(day for day, _ in right))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--signal-date", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    signal = date.fromisoformat(args.signal_date)
    start = (signal - timedelta(days=FETCH_LOOKBACK_CALENDAR_DAYS)).isoformat()
    end = signal.isoformat()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    series_rows: dict[str, list[tuple[str, float]]] = {}
    summary: dict[str, Any] = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": TRIAL_ID,
        "signal_date": end,
        "requested_start": start,
        "requested_end": end,
        "future_observations_allowed": False,
        "series": {},
        "pairs": {},
    }
    for output_id, series_id in ALLOWED_SOURCES.items():
        rows, provenance = fetch_yahoo_adjusted(series_id, start, end)
        clipped = clip_rows_to_signal_date(rows, end)
        path = output_dir / f"{output_id}.csv"
        write_csv(path, clipped)
        series_rows[output_id] = clipped
        summary["series"][output_id] = {
            "series_id": series_id,
            "path": path.as_posix(),
            "rows": len(clipped),
            "first_date": clipped[0][0],
            "last_date": clipped[-1][0],
            "sha256": sha256(path),
            "provenance": provenance,
        }
        print(
            f"PROSPECTIVE_FACTOR_INPUT id={output_id} rows={len(clipped)} "
            f"first={clipped[0][0]} last={clipped[-1][0]} sha256={sha256(path)}"
        )

    for candidate_id, (left, right) in PAIR_IDS.items():
        common = common_observation_count(series_rows[left], series_rows[right])
        if common < MIN_SOURCE_OBSERVATIONS:
            raise RuntimeError(
                f"candidate={candidate_id} has only {common} common observations through {end}; "
                f"need at least {MIN_SOURCE_OBSERVATIONS}"
            )
        summary["pairs"][candidate_id] = {
            "numerator": left,
            "denominator": right,
            "common_observations": common,
        }

    summary_path = output_dir / "input-manifest.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"PROSPECTIVE_FACTOR_INPUTS_COMPLETE manifest={summary_path} sha256={sha256(summary_path)}")


if __name__ == "__main__":
    main()
