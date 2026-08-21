#!/usr/bin/env python3
"""Paired circular moving-block bootstrap for locked screening factor winners."""
from __future__ import annotations

import csv
import json
import math
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
BLOCK_SESSIONS = 63
REPLICATES = 20_000
RNG_SEED = 20_260_821
SESSIONS_PER_YEAR = 252
BATCH_SIZE = 128
LOCKED_CANDIDATES = {
    "F-BREADTH": {
        "candidate": ROOT / "tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-003/candidates/F-BREADTH-portfolio.csv",
        "matched_control": ROOT / "tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-003/candidates/C-BREADTH-ALWAYS-portfolio.csv",
        "v11": ROOT / "tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-003/candidates/V11-CONTROL-portfolio.csv",
    },
    "F-HIGHBETA": {
        "candidate": ROOT / "tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-004/candidates/F-HIGHBETA-portfolio.csv",
        "matched_control": ROOT / "tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-004/candidates/C-HIGHBETA-ALWAYS-portfolio.csv",
        "v11": ROOT / "tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-004/candidates/V11-CONTROL-portfolio.csv",
    },
}


def expand_circular_blocks(
    starts: np.ndarray,
    *,
    n: int,
    block_sessions: int,
    target_length: int,
) -> np.ndarray:
    if n <= 0 or block_sessions <= 0 or target_length <= 0:
        raise ValueError("n, block_sessions and target_length must be positive")
    starts = np.asarray(starts, dtype=np.int64).reshape(-1)
    if starts.size == 0:
        raise ValueError("starts must be non-empty")
    offsets = np.arange(block_sessions, dtype=np.int64)
    indices = ((starts[:, None] + offsets[None, :]) % n).reshape(-1)
    if indices.size < target_length:
        raise ValueError("not enough blocks to reach target_length")
    return indices[:target_length]


def sample_paired_returns(
    candidate: np.ndarray,
    matched: np.ndarray,
    v11: np.ndarray,
    indices: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    if not (candidate.shape == matched.shape == v11.shape):
        raise ValueError("paired return arrays must have the same shape")
    return candidate[indices], matched[indices], v11[indices]


def evaluate_bootstrap_gate(
    *,
    probability_cagr_gt_v11: float,
    probability_sharpe_gt_matched: float,
    median_cagr_delta: float,
    median_sharpe_delta: float,
    candidate_mdd_p975: float,
) -> dict:
    checks = {
        "probability_cagr_gt_v11_ge_0_90": probability_cagr_gt_v11 >= 0.90,
        "probability_sharpe_gt_matched_ge_0_90": probability_sharpe_gt_matched >= 0.90,
        "median_cagr_delta_gt_0": median_cagr_delta > 0,
        "median_sharpe_delta_gt_0": median_sharpe_delta > 0,
        "candidate_mdd_p975_le_0_15": candidate_mdd_p975 <= 0.15,
    }
    return {"bootstrap_robust_pass": all(checks.values()), "checks": checks}


def read_portfolio(path: Path) -> dict[str, float]:
    rows: dict[str, float] = {}
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None or "date" not in reader.fieldnames or "portfolio_value" not in reader.fieldnames:
            raise RuntimeError(f"invalid portfolio CSV columns: {path}")
        for row in reader:
            day = row["date"]
            value = float(row["portfolio_value"])
            if not day or not math.isfinite(value) or value <= 0:
                raise RuntimeError(f"invalid portfolio row in {path}")
            if day in rows:
                raise RuntimeError(f"duplicate date {day} in {path}")
            rows[day] = value
    if len(rows) < 3:
        raise RuntimeError(f"portfolio too short: {path}")
    return rows


def aligned_daily_returns(paths: dict[str, Path]) -> tuple[list[str], np.ndarray, np.ndarray, np.ndarray]:
    candidate_values = read_portfolio(paths["candidate"])
    matched_values = read_portfolio(paths["matched_control"])
    v11_values = read_portfolio(paths["v11"])
    dates = sorted(set(candidate_values).intersection(matched_values).intersection(v11_values))
    if len(dates) < 3:
        raise RuntimeError("insufficient common portfolio dates")

    def values(source: dict[str, float]) -> np.ndarray:
        return np.asarray([source[day] for day in dates], dtype=np.float64)

    candidate = values(candidate_values)
    matched = values(matched_values)
    v11 = values(v11_values)

    def returns(series: np.ndarray) -> np.ndarray:
        result = series[1:] / series[:-1] - 1.0
        if not np.all(np.isfinite(result)) or np.any(result <= -1.0):
            raise RuntimeError("invalid daily return")
        return result

    return dates, returns(candidate), returns(matched), returns(v11)


def performance_metrics(returns: np.ndarray) -> dict[str, float]:
    returns = np.asarray(returns, dtype=np.float64)
    if returns.ndim != 1 or returns.size < 2:
        raise ValueError("returns must be a one-dimensional sample with at least two observations")
    log_growth = float(np.log1p(returns).sum())
    cagr = math.expm1(log_growth * SESSIONS_PER_YEAR / returns.size)
    std = float(returns.std(ddof=1))
    sharpe = (float(returns.mean()) / std * math.sqrt(SESSIONS_PER_YEAR)) if std > 0 else 0.0
    wealth = np.cumprod(1.0 + returns)
    peaks = np.maximum.accumulate(wealth)
    mdd = float(np.max(1.0 - wealth / peaks))
    return {"cagr": cagr, "sharpe": sharpe, "mdd": mdd}


def batch_metrics(returns: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    if returns.ndim != 2 or returns.shape[1] < 2:
        raise ValueError("returns batch must be 2-D")
    n = returns.shape[1]
    log_growth = np.log1p(returns).sum(axis=1)
    cagr = np.expm1(log_growth * SESSIONS_PER_YEAR / n)
    means = returns.mean(axis=1)
    stds = returns.std(axis=1, ddof=1)
    sharpe = np.divide(
        means * math.sqrt(SESSIONS_PER_YEAR),
        stds,
        out=np.zeros_like(means),
        where=stds > 0,
    )
    wealth = np.cumprod(1.0 + returns, axis=1)
    peaks = np.maximum.accumulate(wealth, axis=1)
    mdd = np.max(1.0 - wealth / peaks, axis=1)
    return cagr, sharpe, mdd


def bootstrap_locked_candidate(candidate_id: str, paths: dict[str, Path]) -> dict:
    dates, candidate, matched, v11 = aligned_daily_returns(paths)
    n = candidate.size
    blocks_per_path = math.ceil(n / BLOCK_SESSIONS)
    rng = np.random.default_rng(RNG_SEED)

    candidate_cagrs: list[np.ndarray] = []
    candidate_sharpes: list[np.ndarray] = []
    candidate_mdds: list[np.ndarray] = []
    matched_sharpes: list[np.ndarray] = []
    v11_cagrs: list[np.ndarray] = []

    remaining = REPLICATES
    while remaining > 0:
        batch = min(BATCH_SIZE, remaining)
        starts = rng.integers(0, n, size=(batch, blocks_per_path), endpoint=False)
        offsets = np.arange(BLOCK_SESSIONS, dtype=np.int64)
        indices = ((starts[:, :, None] + offsets[None, None, :]) % n).reshape(batch, -1)[:, :n]
        c = candidate[indices]
        m = matched[indices]
        v = v11[indices]
        c_cagr, c_sharpe, c_mdd = batch_metrics(c)
        _, m_sharpe, _ = batch_metrics(m)
        v_cagr, _, _ = batch_metrics(v)
        candidate_cagrs.append(c_cagr)
        candidate_sharpes.append(c_sharpe)
        candidate_mdds.append(c_mdd)
        matched_sharpes.append(m_sharpe)
        v11_cagrs.append(v_cagr)
        remaining -= batch

    cagr_c = np.concatenate(candidate_cagrs)
    sharpe_c = np.concatenate(candidate_sharpes)
    mdd_c = np.concatenate(candidate_mdds)
    sharpe_m = np.concatenate(matched_sharpes)
    cagr_v = np.concatenate(v11_cagrs)
    probability_cagr_gt_v11 = float(np.mean(cagr_c > cagr_v))
    probability_sharpe_gt_matched = float(np.mean(sharpe_c > sharpe_m))
    cagr_delta = cagr_c - cagr_v
    sharpe_delta = sharpe_c - sharpe_m
    median_cagr_delta = float(np.median(cagr_delta))
    median_sharpe_delta = float(np.median(sharpe_delta))
    candidate_mdd_p975 = float(np.quantile(mdd_c, 0.975))
    gate = evaluate_bootstrap_gate(
        probability_cagr_gt_v11=probability_cagr_gt_v11,
        probability_sharpe_gt_matched=probability_sharpe_gt_matched,
        median_cagr_delta=median_cagr_delta,
        median_sharpe_delta=median_sharpe_delta,
        candidate_mdd_p975=candidate_mdd_p975,
    )
    return {
        "candidate_id": candidate_id,
        "sample": {
            "first_date": dates[0],
            "last_date": dates[-1],
            "aligned_portfolio_dates": len(dates),
            "daily_returns": n,
        },
        "observed": {
            "candidate": performance_metrics(candidate),
            "matched_control": performance_metrics(matched),
            "v11": performance_metrics(v11),
        },
        "bootstrap": {
            "replicates": REPLICATES,
            "block_sessions": BLOCK_SESSIONS,
            "rng_seed": RNG_SEED,
            "probability_cagr_gt_v11": probability_cagr_gt_v11,
            "probability_sharpe_gt_matched_control": probability_sharpe_gt_matched,
            "median_candidate_minus_v11_cagr": median_cagr_delta,
            "median_candidate_minus_matched_sharpe": median_sharpe_delta,
            "candidate_mdd_p975": candidate_mdd_p975,
            "candidate_cagr_p025": float(np.quantile(cagr_c, 0.025)),
            "candidate_cagr_p50": float(np.quantile(cagr_c, 0.50)),
            "candidate_cagr_p975": float(np.quantile(cagr_c, 0.975)),
            "candidate_sharpe_p025": float(np.quantile(sharpe_c, 0.025)),
            "candidate_sharpe_p50": float(np.quantile(sharpe_c, 0.50)),
            "candidate_sharpe_p975": float(np.quantile(sharpe_c, 0.975)),
        },
        **gate,
    }


def main() -> int:
    output_dir = ROOT / "tools/research-results/strategy-validation/runs/ATM-SVP2-FACTOR-ROBUST-001/candidates"
    output_dir.mkdir(parents=True, exist_ok=True)
    results = [bootstrap_locked_candidate(candidate_id, paths) for candidate_id, paths in LOCKED_CANDIDATES.items()]
    document = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": "ATM-SVP2-FACTOR-ROBUST-001",
        "method": {
            "sampling": "paired circular moving blocks",
            "block_sessions": BLOCK_SESSIONS,
            "replicates": REPLICATES,
            "rng_seed": RNG_SEED,
            "sessions_per_year": SESSIONS_PER_YEAR,
        },
        "candidate_results": results,
        "robust_pass_candidates": [row["candidate_id"] for row in results if row["bootstrap_robust_pass"]],
    }
    json_path = output_dir / "bootstrap-results.json"
    json_path.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    csv_path = output_dir / "bootstrap-results.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "candidate_id",
            "probability_cagr_gt_v11",
            "probability_sharpe_gt_matched_control",
            "median_candidate_minus_v11_cagr",
            "median_candidate_minus_matched_sharpe",
            "candidate_mdd_p975",
            "bootstrap_robust_pass",
        ])
        writer.writeheader()
        for row in results:
            boot = row["bootstrap"]
            writer.writerow({
                "candidate_id": row["candidate_id"],
                "probability_cagr_gt_v11": boot["probability_cagr_gt_v11"],
                "probability_sharpe_gt_matched_control": boot["probability_sharpe_gt_matched_control"],
                "median_candidate_minus_v11_cagr": boot["median_candidate_minus_v11_cagr"],
                "median_candidate_minus_matched_sharpe": boot["median_candidate_minus_matched_sharpe"],
                "candidate_mdd_p975": boot["candidate_mdd_p975"],
                "bootstrap_robust_pass": row["bootstrap_robust_pass"],
            })
    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print("SCREENING_FACTOR_BOOTSTRAP_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
