#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
from pathlib import Path
from typing import Mapping

import numpy as np

ASSETS = ("vbr_tr", "mtum_tr", "qual_tr", "splv_tr")
SOURCE_PATHS = {
    "vbr_tr": "tools/research-results/strategy-validation/factor-data/US-VALUE-ROLE-V1-2026-08-22/VBR.csv",
    "mtum_tr": "tools/research-results/strategy-validation/factor-data/US-MOMENTUM-QUALITY-ROLE-V1-2026-08-22/MTUM.csv",
    "qual_tr": "tools/research-results/strategy-validation/factor-data/US-MOMENTUM-QUALITY-ROLE-V1-2026-08-22/QUAL.csv",
    "splv_tr": "tools/research-results/strategy-validation/factor-data/ATM-SVP2-ORTHO-FACTOR-004/SPLV.csv",
}
LOOKBACK_RETURNS = 252
EVALUATION_START = "2015-01-02"
EVALUATION_END = "2026-08-13"


def load_price_csv(path: Path) -> dict[str, float]:
    out: dict[str, float] = {}
    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            try:
                value = float(next(value for key, value in row.items() if key != "date"))
            except (StopIteration, TypeError, ValueError):
                continue
            if value > 0 and np.isfinite(value):
                out[row["date"]] = value
    return out


def load_fx_cny_per_usd(fixture: Path) -> dict[str, float]:
    root = json.loads(fixture.read_text(encoding="utf-8"))
    series = next(row for row in root["series"] if row.get("symbol") == "usd_per_cny")
    return {
        date: 1.0 / float(value)
        for date, value in zip(series["dates"], series["prices"])
        if float(value) > 0 and np.isfinite(float(value))
    }


def aligned_cny_prices(root: Path, fixture: Path) -> tuple[list[str], np.ndarray]:
    raw = {asset: load_price_csv(root / SOURCE_PATHS[asset]) for asset in ASSETS}
    common = set.intersection(*(set(values) for values in raw.values()))
    dates = sorted(date for date in common if date <= EVALUATION_END)
    fx = load_fx_cny_per_usd(fixture)
    fx_dates = sorted(fx)
    fx_index = 0
    latest_fx: float | None = None
    rows: list[list[float]] = []
    kept: list[str] = []
    for date in dates:
        while fx_index < len(fx_dates) and fx_dates[fx_index] <= date:
            latest_fx = fx[fx_dates[fx_index]]
            fx_index += 1
        if latest_fx is None:
            continue
        kept.append(date)
        rows.append([raw[asset][date] * latest_fx for asset in ASSETS])
    return kept, np.asarray(rows, dtype=float)


def long_only_min_variance(covariance: np.ndarray) -> np.ndarray:
    n = covariance.shape[0]
    best_weights: np.ndarray | None = None
    best_variance = float("inf")
    for mask in range(1, 1 << n):
        idx = [i for i in range(n) if mask & (1 << i)]
        sub = covariance[np.ix_(idx, idx)]
        try:
            inv_one = np.linalg.solve(sub, np.ones(len(idx)))
        except np.linalg.LinAlgError:
            continue
        denom = float(inv_one.sum())
        if not np.isfinite(denom) or denom <= 0:
            continue
        sub_weights = inv_one / denom
        if np.min(sub_weights) < -1e-10:
            continue
        weights = np.zeros(n)
        weights[idx] = np.maximum(sub_weights, 0.0)
        weights /= weights.sum()
        variance = float(weights @ covariance @ weights)
        if variance < best_variance:
            best_variance = variance
            best_weights = weights
    if best_weights is None:
        raise RuntimeError("no feasible long-only minimum-variance solution")
    return best_weights


def schedule_from_prices(dates: list[str], cny_prices: np.ndarray) -> list[dict]:
    entries: list[dict] = []
    years = range(int(EVALUATION_START[:4]), int(EVALUATION_END[:4]) + 1)
    for year in years:
        indices = [i for i, date in enumerate(dates) if date.startswith(f"{year:04d}-") and date >= EVALUATION_START]
        if not indices:
            continue
        execution_index = indices[0]
        if execution_index < LOOKBACK_RETURNS + 1:
            continue
        history = cny_prices[execution_index - (LOOKBACK_RETURNS + 1):execution_index]
        returns = history[1:] / history[:-1] - 1.0
        if returns.shape != (LOOKBACK_RETURNS, len(ASSETS)):
            raise RuntimeError("lookback shape drift")
        covariance = np.cov(returns, rowvar=False, ddof=1)
        weights = long_only_min_variance(covariance)
        entries.append({
            "date": dates[execution_index],
            "signal_end_date": dates[execution_index - 1],
            "lookback_returns": LOOKBACK_RETURNS,
            "weights": {asset: float(weight) for asset, weight in zip(ASSETS, weights)},
            "sum_weights": float(weights.sum()),
            "min_weight": float(weights.min()),
        })
    return entries


def build_schedule(root: Path, fixture: Path) -> list[dict]:
    dates, prices = aligned_cny_prices(root, fixture)
    return schedule_from_prices(dates, prices)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    schedule = build_schedule(root, Path(args.fixture))
    Path(args.output).write_text(json.dumps(schedule, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"FACTOR_MINVAR_001_SCHEDULE_WRITTEN entries={len(schedule)}")
