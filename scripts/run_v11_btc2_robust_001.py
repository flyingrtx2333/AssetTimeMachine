#!/usr/bin/env python3
"""Frozen paired block-bootstrap audit for the immutable V11 + 2% BTC candidate."""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP3-V11-BTC2-ROBUST-001"
AUDIT_ID = "A-V11-BTC2-ROBUST-001"
SOURCE_TRIAL = "ATM-SVP3-V11-BTC2-SATELLITE-001"
CANDIDATE_ID = "S-V11-BTC2-SATELLITE-001"
CONTROL_ID = "C-V11-MATCHED"
BLOCK_SESSIONS = 63
REPLICATES = 20_000
RNG_SEED = 20_260_822
SESSIONS_PER_YEAR = 252
BATCH_SIZE = 128


def read_portfolio(path: Path) -> dict[str, float]:
    values: dict[str, float] = {}
    with path.open("r", encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            day = row["date"]
            value = float(row["portfolio_value"])
            if not day or not math.isfinite(value) or value <= 0 or day in values:
                raise RuntimeError(f"invalid portfolio row: {path}")
            values[day] = value
    if len(values) < 3:
        raise RuntimeError(f"portfolio too short: {path}")
    return values


def aligned_returns(candidate_path: Path, control_path: Path) -> tuple[list[str], np.ndarray, np.ndarray]:
    candidate = read_portfolio(candidate_path)
    control = read_portfolio(control_path)
    dates = sorted(set(candidate).intersection(control))
    if len(dates) < 3:
        raise RuntimeError("insufficient aligned dates")
    c = np.asarray([candidate[d] for d in dates], dtype=np.float64)
    v = np.asarray([control[d] for d in dates], dtype=np.float64)
    cr = c[1:] / c[:-1] - 1.0
    vr = v[1:] / v[:-1] - 1.0
    if not np.all(np.isfinite(cr)) or not np.all(np.isfinite(vr)):
        raise RuntimeError("non-finite aligned returns")
    if np.any(cr <= -1.0) or np.any(vr <= -1.0):
        raise RuntimeError("invalid <= -100% return")
    return dates, cr, vr


def perf(returns: np.ndarray) -> dict[str, float]:
    cagr = math.expm1(float(np.log1p(returns).sum()) * SESSIONS_PER_YEAR / returns.size)
    std = float(returns.std(ddof=1))
    sharpe = float(returns.mean()) / std * math.sqrt(SESSIONS_PER_YEAR) if std > 0 else 0.0
    wealth = np.cumprod(1.0 + returns)
    peaks = np.maximum.accumulate(wealth)
    mdd = float(np.max(1.0 - wealth / peaks))
    return {"cagr": cagr, "sharpe": sharpe, "mdd": mdd}


def batch_metrics(returns: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    n = returns.shape[1]
    cagr = np.expm1(np.log1p(returns).sum(axis=1) * SESSIONS_PER_YEAR / n)
    means = returns.mean(axis=1)
    stds = returns.std(axis=1, ddof=1)
    sharpe = np.divide(means * math.sqrt(SESSIONS_PER_YEAR), stds, out=np.zeros_like(means), where=stds > 0)
    wealth = np.cumprod(1.0 + returns, axis=1)
    peaks = np.maximum.accumulate(wealth, axis=1)
    mdd = np.max(1.0 - wealth / peaks, axis=1)
    return cagr, sharpe, mdd


def audit(candidate_path: Path, control_path: Path) -> dict:
    dates, candidate, control = aligned_returns(candidate_path, control_path)
    n = candidate.size
    blocks = math.ceil(n / BLOCK_SESSIONS)
    offsets = np.arange(BLOCK_SESSIONS, dtype=np.int64)
    rng = np.random.default_rng(RNG_SEED)
    cc: list[np.ndarray] = []
    cs: list[np.ndarray] = []
    cm: list[np.ndarray] = []
    vc: list[np.ndarray] = []
    vs: list[np.ndarray] = []
    remaining = REPLICATES
    while remaining:
        batch = min(BATCH_SIZE, remaining)
        starts = rng.integers(0, n, size=(batch, blocks), endpoint=False)
        idx = ((starts[:, :, None] + offsets[None, None, :]) % n).reshape(batch, -1)[:, :n]
        c_cagr, c_sharpe, c_mdd = batch_metrics(candidate[idx])
        v_cagr, v_sharpe, _ = batch_metrics(control[idx])
        cc.append(c_cagr); cs.append(c_sharpe); cm.append(c_mdd); vc.append(v_cagr); vs.append(v_sharpe)
        remaining -= batch
    cc_a = np.concatenate(cc); cs_a = np.concatenate(cs); cm_a = np.concatenate(cm)
    vc_a = np.concatenate(vc); vs_a = np.concatenate(vs)
    p_cagr = float(np.mean(cc_a > vc_a))
    p_sharpe = float(np.mean(cs_a > vs_a))
    median_cagr_delta = float(np.median(cc_a - vc_a))
    median_sharpe_delta = float(np.median(cs_a - vs_a))
    candidate_mdd_p975 = float(np.quantile(cm_a, 0.975))
    checks = {
        "probability_cagr_gt_v11_ge_0_90": p_cagr >= 0.90,
        "probability_sharpe_gt_v11_ge_0_90": p_sharpe >= 0.90,
        "median_cagr_delta_gt_0": median_cagr_delta > 0,
        "median_sharpe_delta_gt_0": median_sharpe_delta > 0,
        "candidate_mdd_p975_le_0_15": candidate_mdd_p975 <= 0.15,
    }
    return {
        "trial_id": TRIAL_ID,
        "audit_id": AUDIT_ID,
        "source_trial_id": SOURCE_TRIAL,
        "candidate_id": CANDIDATE_ID,
        "control_id": CONTROL_ID,
        "sample": {"first_date": dates[0], "last_date": dates[-1], "aligned_portfolio_dates": len(dates), "daily_returns": n},
        "method": {"sampling": "paired circular moving blocks", "block_sessions": BLOCK_SESSIONS, "replicates": REPLICATES, "rng_seed": RNG_SEED, "sessions_per_year": SESSIONS_PER_YEAR},
        "observed": {"candidate": perf(candidate), "matched_v11": perf(control)},
        "bootstrap": {
            "probability_cagr_gt_v11": p_cagr,
            "probability_sharpe_gt_v11": p_sharpe,
            "median_candidate_minus_v11_cagr": median_cagr_delta,
            "median_candidate_minus_v11_sharpe": median_sharpe_delta,
            "candidate_mdd_p975": candidate_mdd_p975,
            "candidate_cagr_p025": float(np.quantile(cc_a, 0.025)),
            "candidate_cagr_p50": float(np.quantile(cc_a, 0.50)),
            "candidate_cagr_p975": float(np.quantile(cc_a, 0.975)),
            "candidate_sharpe_p025": float(np.quantile(cs_a, 0.025)),
            "candidate_sharpe_p50": float(np.quantile(cs_a, 0.50)),
            "candidate_sharpe_p975": float(np.quantile(cs_a, 0.975)),
        },
        "checks": checks,
        "bootstrap_incremental_pass": all(checks.values()),
        "known_source_global_dsr_probability": 0.38570194449673956,
        "strong_validation_upgrade_allowed": False,
        "strong_validation_upgrade_blocker": "source-trial global DSR remains below the project threshold; this audit cannot rewrite the immutable R1 validation status",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--control", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    result = audit(Path(args.candidate), Path(args.control))
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "bootstrap-audit.json").write_text(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    with (out / "bootstrap-audit.csv").open("w", encoding="utf-8", newline="") as handle:
        fields = ["audit_id", "bootstrap_incremental_pass", "probability_cagr_gt_v11", "probability_sharpe_gt_v11", "median_candidate_minus_v11_cagr", "median_candidate_minus_v11_sharpe", "candidate_mdd_p975", "known_source_global_dsr_probability"]
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        b = result["bootstrap"]
        writer.writerow({
            "audit_id": AUDIT_ID,
            "bootstrap_incremental_pass": result["bootstrap_incremental_pass"],
            "probability_cagr_gt_v11": b["probability_cagr_gt_v11"],
            "probability_sharpe_gt_v11": b["probability_sharpe_gt_v11"],
            "median_candidate_minus_v11_cagr": b["median_candidate_minus_v11_cagr"],
            "median_candidate_minus_v11_sharpe": b["median_candidate_minus_v11_sharpe"],
            "candidate_mdd_p975": b["candidate_mdd_p975"],
            "known_source_global_dsr_probability": result["known_source_global_dsr_probability"],
        })
    print("V11_BTC2_ROBUST_001_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
