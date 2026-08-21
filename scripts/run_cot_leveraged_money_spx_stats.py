#!/usr/bin/env python3
"""Frozen bootstrap and cumulative DSR audit for ATM-SVP2-COT-001."""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np

from strategy_validation_stats import deflated_sharpe_ratio

ROOT = Path(__file__).resolve().parents[1]
BLOCK_SESSIONS = 63
REPLICATES = 20_000
RNG_SEED = 20_260_821
SESSIONS_PER_YEAR = 252
BATCH_SIZE = 128
CANDIDATE_ID = "F-COT-LEV-SPX"
MATCHED_CONTROL_ID = "C-COT-LEV-ALWAYS"
PRIOR_RESULT_PATHS = [
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-HR-ARCH-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-002.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-003.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-004.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-005.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-006.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-LIT-STRESS-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-VRP-001.json",
]


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


def to_returns(values: np.ndarray) -> np.ndarray:
    returns = values[1:] / values[:-1] - 1.0
    if returns.ndim != 1 or not np.all(np.isfinite(returns)) or np.any(returns <= -1.0):
        raise RuntimeError("invalid portfolio returns")
    return returns


def aligned_returns(paths: dict[str, Path]) -> tuple[list[str], dict[str, np.ndarray]]:
    value_maps = {key: read_portfolio(path) for key, path in paths.items()}
    dates = sorted(set.intersection(*(set(values) for values in value_maps.values())))
    if len(dates) < 3:
        raise RuntimeError("insufficient aligned portfolio dates")
    result: dict[str, np.ndarray] = {}
    for key, values in value_maps.items():
        result[key] = to_returns(np.asarray([values[day] for day in dates], dtype=np.float64))
    return dates, result


def performance_metrics(returns: np.ndarray) -> dict[str, float]:
    log_growth = float(np.log1p(returns).sum())
    cagr = math.expm1(log_growth * SESSIONS_PER_YEAR / returns.size)
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


def bootstrap(candidate_dir: Path) -> dict:
    dates, series = aligned_returns({
        "candidate": candidate_dir / f"{CANDIDATE_ID}-portfolio.csv",
        "matched": candidate_dir / f"{MATCHED_CONTROL_ID}-portfolio.csv",
        "v11": candidate_dir / "V11-CONTROL-portfolio.csv",
    })
    candidate = series["candidate"]
    matched = series["matched"]
    v11 = series["v11"]
    n = candidate.size
    blocks_per_path = math.ceil(n / BLOCK_SESSIONS)
    rng = np.random.default_rng(RNG_SEED)
    offsets = np.arange(BLOCK_SESSIONS, dtype=np.int64)
    c_cagrs: list[np.ndarray] = []
    c_sharpes: list[np.ndarray] = []
    c_mdds: list[np.ndarray] = []
    m_sharpes: list[np.ndarray] = []
    v_cagrs: list[np.ndarray] = []
    remaining = REPLICATES
    while remaining > 0:
        batch = min(BATCH_SIZE, remaining)
        starts = rng.integers(0, n, size=(batch, blocks_per_path), endpoint=False)
        indices = ((starts[:, :, None] + offsets[None, None, :]) % n).reshape(batch, -1)[:, :n]
        c_cagr, c_sharpe, c_mdd = batch_metrics(candidate[indices])
        _, m_sharpe, _ = batch_metrics(matched[indices])
        v_cagr, _, _ = batch_metrics(v11[indices])
        c_cagrs.append(c_cagr)
        c_sharpes.append(c_sharpe)
        c_mdds.append(c_mdd)
        m_sharpes.append(m_sharpe)
        v_cagrs.append(v_cagr)
        remaining -= batch

    cagr_c = np.concatenate(c_cagrs)
    sharpe_c = np.concatenate(c_sharpes)
    mdd_c = np.concatenate(c_mdds)
    sharpe_m = np.concatenate(m_sharpes)
    cagr_v = np.concatenate(v_cagrs)
    probability_cagr_gt_v11 = float(np.mean(cagr_c > cagr_v))
    probability_sharpe_gt_matched = float(np.mean(sharpe_c > sharpe_m))
    median_cagr_delta = float(np.median(cagr_c - cagr_v))
    median_sharpe_delta = float(np.median(sharpe_c - sharpe_m))
    candidate_mdd_p975 = float(np.quantile(mdd_c, 0.975))
    checks = {
        "probability_cagr_gt_v11_ge_0_90": probability_cagr_gt_v11 >= 0.90,
        "probability_sharpe_gt_matched_ge_0_90": probability_sharpe_gt_matched >= 0.90,
        "median_cagr_delta_gt_0": median_cagr_delta > 0,
        "median_sharpe_delta_gt_0": median_sharpe_delta > 0,
        "candidate_mdd_p975_le_0_15": candidate_mdd_p975 <= 0.15,
    }
    return {
        "candidate_id": CANDIDATE_ID,
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
        "bootstrap_robust_pass": all(checks.values()),
        "checks": checks,
    }


def prior_post_protocol_sharpes() -> list[float]:
    sharpes: list[float] = []
    for path in PRIOR_RESULT_PATHS:
        document = json.loads(path.read_text(encoding="utf-8"))
        for result in document.get("candidate_results") or []:
            value = float((result.get("metrics") or {})["sharpe"])
            if not math.isfinite(value):
                raise RuntimeError(f"non-finite prior Sharpe in {path}")
            sharpes.append(value)
    if len(sharpes) != 25:
        raise RuntimeError(f"global DSR prior inventory must contain 25 candidates, got {len(sharpes)}")
    return sharpes


def global_dsr(candidate_dir: Path, candidate_sharpe: float) -> dict:
    trial_sharpes = prior_post_protocol_sharpes() + [candidate_sharpe]
    if len(trial_sharpes) != 26:
        raise RuntimeError("global DSR inventory must contain 26 candidates")
    values = read_portfolio(candidate_dir / f"{CANDIDATE_ID}-portfolio.csv")
    dates = sorted(values)
    returns = [values[dates[index]] / values[dates[index - 1]] - 1.0 for index in range(1, len(dates))]
    return deflated_sharpe_ratio(returns, trial_sharpes, SESSIONS_PER_YEAR)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate-dir", required=True)
    parser.add_argument("--candidate-metrics", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    candidate_dir = Path(args.candidate_dir)
    output_dir = Path(args.output_dir)
    metrics_document = json.loads(Path(args.candidate_metrics).read_text(encoding="utf-8"))
    result = metrics_document["candidate_results"][0]
    if result["candidate_id"] != CANDIDATE_ID:
        raise RuntimeError("candidate metrics does not contain frozen COT candidate")
    deterministic = bool(result["admit_for_robustness"])
    bootstrap_result = bootstrap(candidate_dir)
    dsr = global_dsr(candidate_dir, float(result["metrics"]["sharpe"]))
    dsr_pass = float(dsr["dsr_probability"]) >= 0.95
    robust = deterministic and bootstrap_result["bootstrap_robust_pass"] and dsr_pass

    document = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": "ATM-SVP2-COT-001",
        "method": {
            "bootstrap_sampling": "paired circular moving blocks",
            "bootstrap_block_sessions": BLOCK_SESSIONS,
            "bootstrap_replicates": REPLICATES,
            "bootstrap_rng_seed": RNG_SEED,
            "family_pbo": "not_applicable_single_candidate",
            "global_post_protocol_dsr_trial_count": 26,
        },
        "candidate_results": [{
            "candidate_id": CANDIDATE_ID,
            "deterministic_admit": deterministic,
            "bootstrap": bootstrap_result,
            "global_post_protocol_dsr": dsr,
            "global_dsr_pass": dsr_pass,
            "robust_factor_pass": robust,
        }],
        "robust_pass_candidates": [CANDIDATE_ID] if robust else [],
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "statistical-audit.json").write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    with (output_dir / "statistical-audit.csv").open("w", encoding="utf-8", newline="") as handle:
        boot = bootstrap_result["bootstrap"]
        writer = csv.DictWriter(handle, fieldnames=[
            "candidate_id", "deterministic_admit", "bootstrap_pass", "global_dsr_probability",
            "global_dsr_pass", "robust_factor_pass", "probability_cagr_gt_v11",
            "probability_sharpe_gt_matched", "candidate_mdd_p975",
        ])
        writer.writeheader()
        writer.writerow({
            "candidate_id": CANDIDATE_ID,
            "deterministic_admit": deterministic,
            "bootstrap_pass": bootstrap_result["bootstrap_robust_pass"],
            "global_dsr_probability": dsr["dsr_probability"],
            "global_dsr_pass": dsr_pass,
            "robust_factor_pass": robust,
            "probability_cagr_gt_v11": boot["probability_cagr_gt_v11"],
            "probability_sharpe_gt_matched": boot["probability_sharpe_gt_matched_control"],
            "candidate_mdd_p975": boot["candidate_mdd_p975"],
        })
    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print("COT_LEVERAGED_MONEY_SPX_V1_STATS_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
