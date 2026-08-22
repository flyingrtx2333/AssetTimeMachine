#!/usr/bin/env python3
"""Frozen bootstrap + DSR audit for QUAL versus matched SPY total-return role trial."""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np

from strategy_validation_stats import deflated_sharpe_ratio

ROOT = Path(__file__).resolve().parents[1]
CANDIDATE_ID = "S-QUAL-VS-SPY-TR-ROLE"
MATCHED_CONTROL_ID = "C-SPY-TR-PROD-SP500-ROLE"
EVALUATION_START = "2013-07-19"
BLOCK_SESSIONS = 63
REPLICATES = 20_000
RNG_SEED = 20_260_822
SESSIONS_PER_YEAR = 252
BATCH_SIZE = 128
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
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-COT-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-MARGIN-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-BDLEV-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-INSIDER-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-NPY-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-TIC-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-HESHARE-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-SLOOS-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-CBOE-PC-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-US-VALUE-ROLE-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-US-MQ-ROLE-002.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-US-VALUE-PROD-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-IWD-SPY-TR-001.json",
]


def read_portfolio(path: Path) -> dict[str, float]:
    rows: dict[str, float] = {}
    with path.open("r", encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            day = row["date"]
            value = float(row["portfolio_value"])
            if not day or not math.isfinite(value) or value <= 0 or day in rows:
                raise RuntimeError(f"invalid portfolio row: {path}")
            rows[day] = value
    if len(rows) < 3:
        raise RuntimeError(f"portfolio too short: {path}")
    return rows


def aligned_returns(candidate_dir: Path) -> tuple[list[str], np.ndarray, np.ndarray]:
    candidate = read_portfolio(candidate_dir / f"{CANDIDATE_ID}-portfolio.csv")
    matched = read_portfolio(candidate_dir / f"{MATCHED_CONTROL_ID}-portfolio.csv")
    dates = [day for day in sorted(set(candidate).intersection(matched)) if day >= EVALUATION_START]
    if len(dates) < 3:
        raise RuntimeError("insufficient matched evaluation dates")
    c = np.asarray([candidate[day] for day in dates], dtype=np.float64)
    m = np.asarray([matched[day] for day in dates], dtype=np.float64)
    cr = c[1:] / c[:-1] - 1.0
    mr = m[1:] / m[:-1] - 1.0
    if not np.all(np.isfinite(cr)) or not np.all(np.isfinite(mr)) or np.any(cr <= -1.0) or np.any(mr <= -1.0):
        raise RuntimeError("invalid aligned returns")
    return dates, cr, mr


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


def bootstrap(candidate_dir: Path) -> dict:
    dates, candidate, matched = aligned_returns(candidate_dir)
    n = candidate.size
    blocks = math.ceil(n / BLOCK_SESSIONS)
    offsets = np.arange(BLOCK_SESSIONS, dtype=np.int64)
    rng = np.random.default_rng(RNG_SEED)
    cc: list[np.ndarray] = []
    cs: list[np.ndarray] = []
    cm: list[np.ndarray] = []
    mc: list[np.ndarray] = []
    ms: list[np.ndarray] = []
    remaining = REPLICATES
    while remaining:
        batch = min(BATCH_SIZE, remaining)
        starts = rng.integers(0, n, size=(batch, blocks), endpoint=False)
        idx = ((starts[:, :, None] + offsets[None, None, :]) % n).reshape(batch, -1)[:, :n]
        c_cagr, c_sharpe, c_mdd = batch_metrics(candidate[idx])
        m_cagr, m_sharpe, _ = batch_metrics(matched[idx])
        cc.append(c_cagr)
        cs.append(c_sharpe)
        cm.append(c_mdd)
        mc.append(m_cagr)
        ms.append(m_sharpe)
        remaining -= batch
    cc_a = np.concatenate(cc)
    cs_a = np.concatenate(cs)
    cm_a = np.concatenate(cm)
    mc_a = np.concatenate(mc)
    ms_a = np.concatenate(ms)
    p_cagr = float(np.mean(cc_a > mc_a))
    p_sharpe = float(np.mean(cs_a > ms_a))
    med_cagr = float(np.median(cc_a - mc_a))
    med_sharpe = float(np.median(cs_a - ms_a))
    mdd975 = float(np.quantile(cm_a, 0.975))
    checks = {
        "probability_cagr_gt_spy_ge_0_90": p_cagr >= 0.90,
        "probability_sharpe_gt_spy_ge_0_90": p_sharpe >= 0.90,
        "median_cagr_delta_gt_0": med_cagr > 0,
        "median_sharpe_delta_gt_0": med_sharpe > 0,
        "candidate_mdd_p975_le_0_15": mdd975 <= 0.15,
    }
    return {
        "candidate_id": CANDIDATE_ID,
        "matched_control_id": MATCHED_CONTROL_ID,
        "sample": {
            "evaluation_start": EVALUATION_START,
            "first_date": dates[0],
            "last_date": dates[-1],
            "aligned_portfolio_dates": len(dates),
            "daily_returns": n,
        },
        "observed": {"candidate": perf(candidate), "matched_control": perf(matched)},
        "bootstrap": {
            "replicates": REPLICATES,
            "block_sessions": BLOCK_SESSIONS,
            "rng_seed": RNG_SEED,
            "probability_cagr_gt_matched_control": p_cagr,
            "probability_sharpe_gt_matched_control": p_sharpe,
            "median_candidate_minus_matched_cagr": med_cagr,
            "median_candidate_minus_matched_sharpe": med_sharpe,
            "candidate_mdd_p975": mdd975,
            "candidate_cagr_p025": float(np.quantile(cc_a, 0.025)),
            "candidate_cagr_p50": float(np.quantile(cc_a, 0.50)),
            "candidate_cagr_p975": float(np.quantile(cc_a, 0.975)),
            "candidate_sharpe_p025": float(np.quantile(cs_a, 0.025)),
            "candidate_sharpe_p50": float(np.quantile(cs_a, 0.50)),
            "candidate_sharpe_p975": float(np.quantile(cs_a, 0.975)),
        },
        "checks": checks,
        "bootstrap_robust_pass": all(checks.values()),
    }


def prior_sharpes() -> list[float]:
    values: list[float] = []
    for path in PRIOR_RESULT_PATHS:
        document = json.loads(path.read_text(encoding="utf-8"))
        for result in document.get("candidate_results") or []:
            metrics = result.get("metrics") or {}
            raw = metrics.get("sharpe", metrics.get("full_sharpe"))
            if raw is None:
                raise RuntimeError(f"prior result missing Sharpe: {path}")
            value = float(raw)
            if not math.isfinite(value):
                raise RuntimeError(f"non-finite prior Sharpe: {path}")
            values.append(value)
    if len(values) != 41:
        raise RuntimeError(f"expected 41 prior performance-bearing candidates, got {len(values)}")
    return values


def evaluation_returns(path: Path) -> list[float]:
    values = read_portfolio(path)
    dates = [day for day in sorted(values) if day >= EVALUATION_START]
    return [values[dates[index]] / values[dates[index - 1]] - 1.0 for index in range(1, len(dates))]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate-dir", required=True)
    parser.add_argument("--candidate-metrics", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    candidate_dir = Path(args.candidate_dir)
    output_dir = Path(args.output_dir)
    metrics_doc = json.loads(Path(args.candidate_metrics).read_text(encoding="utf-8"))
    result = metrics_doc["candidate_results"][0]
    if result["candidate_id"] != CANDIDATE_ID or result["matched_control_id"] != MATCHED_CONTROL_ID:
        raise RuntimeError("frozen QUAL/SPY matched pair missing")
    deterministic = bool(result["admit_for_robustness"])
    boot = bootstrap(candidate_dir)
    candidate_sharpe = float(result["metrics"]["evaluation_sharpe"])
    all_sharpes = prior_sharpes() + [candidate_sharpe]
    if len(all_sharpes) != 42:
        raise RuntimeError("global DSR inventory must contain 42 candidates")
    dsr = deflated_sharpe_ratio(
        evaluation_returns(candidate_dir / f"{CANDIDATE_ID}-portfolio.csv"),
        all_sharpes,
        SESSIONS_PER_YEAR,
    )
    dsr_pass = float(dsr["dsr_probability"]) >= 0.95
    robust = deterministic and boot["bootstrap_robust_pass"] and dsr_pass
    document = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": "ATM-SVP2-QUAL-SPY-TR-001",
        "method": {
            "evaluation_start": EVALUATION_START,
            "matched_control": MATCHED_CONTROL_ID,
            "price_field": "Yahoo adjusted_close_total_return_proxy for both QUAL and SPY",
            "bootstrap_sampling": "paired circular moving blocks QUAL versus SPY matched control",
            "bootstrap_block_sessions": BLOCK_SESSIONS,
            "bootstrap_replicates": REPLICATES,
            "bootstrap_rng_seed": RNG_SEED,
            "family_pbo": "not_applicable_single_candidate_fixed_matched_control",
            "global_post_protocol_dsr_prior_trial_count": 41,
            "global_post_protocol_dsr_total_trial_count": 42,
            "global_dsr_return_window": "2013-07-19+ candidate behavior only",
        },
        "candidate_results": [
            {
                "candidate_id": CANDIDATE_ID,
                "matched_control_id": MATCHED_CONTROL_ID,
                "deterministic_admit": deterministic,
                "bootstrap": boot,
                "global_post_protocol_dsr": dsr,
                "global_dsr_pass": dsr_pass,
                "robust_strategy_pass": robust,
            }
        ],
        "robust_pass_candidates": [CANDIDATE_ID] if robust else [],
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "statistical-audit.json").write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    with (output_dir / "statistical-audit.csv").open("w", encoding="utf-8", newline="") as handle:
        b = boot["bootstrap"]
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "candidate_id",
                "matched_control_id",
                "deterministic_admit",
                "bootstrap_pass",
                "global_dsr_probability",
                "global_dsr_pass",
                "robust_strategy_pass",
                "probability_cagr_gt_matched",
                "probability_sharpe_gt_matched",
                "candidate_mdd_p975",
            ],
        )
        writer.writeheader()
        writer.writerow(
            {
                "candidate_id": CANDIDATE_ID,
                "matched_control_id": MATCHED_CONTROL_ID,
                "deterministic_admit": deterministic,
                "bootstrap_pass": boot["bootstrap_robust_pass"],
                "global_dsr_probability": dsr["dsr_probability"],
                "global_dsr_pass": dsr_pass,
                "robust_strategy_pass": robust,
                "probability_cagr_gt_matched": b["probability_cagr_gt_matched_control"],
                "probability_sharpe_gt_matched": b["probability_sharpe_gt_matched_control"],
                "candidate_mdd_p975": b["candidate_mdd_p975"],
            }
        )
    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print("QUAL_SPY_TR_MATCHED_V1_STATS_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
