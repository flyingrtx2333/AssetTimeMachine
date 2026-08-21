#!/usr/bin/env python3
"""Frozen bootstrap/PBO/DSR audit for ATM-SVP2-LIT-STRESS-001."""
from __future__ import annotations

import argparse
import csv
import itertools
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
PBO_BLOCKS = 8
CANDIDATES = ["F-BAA", "F-EPU", "F-MOVE"]
MATCHED = {
    "F-BAA": "C-BAA-ALWAYS",
    "F-EPU": "C-EPU-ALWAYS",
    "F-MOVE": "C-MOVE-ALWAYS",
}
PRIOR_RESULT_PATHS = [
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-HR-ARCH-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-001.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-002.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-003.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-004.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-005.json",
    ROOT / "tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-006.json",
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
    if returns.ndim != 1 or not np.all(np.isfinite(returns)) or np.any(returns <= -1):
        raise RuntimeError("invalid portfolio returns")
    return returns


def aligned_returns(paths: dict[str, Path]) -> tuple[list[str], dict[str, np.ndarray]]:
    value_maps = {key: read_portfolio(path) for key, path in paths.items()}
    common = set.intersection(*(set(values) for values in value_maps.values()))
    dates = sorted(common)
    if len(dates) < 3:
        raise RuntimeError("insufficient aligned portfolio dates")
    returns: dict[str, np.ndarray] = {}
    for key, values in value_maps.items():
        array = np.asarray([values[day] for day in dates], dtype=np.float64)
        returns[key] = to_returns(array)
    return dates, returns


def performance_metrics(returns: np.ndarray) -> dict[str, float]:
    returns = np.asarray(returns, dtype=np.float64)
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


def bootstrap_candidate(candidate_id: str, candidate_dir: Path) -> dict:
    paths = {
        "candidate": candidate_dir / f"{candidate_id}-portfolio.csv",
        "matched": candidate_dir / f"{MATCHED[candidate_id]}-portfolio.csv",
        "v11": candidate_dir / "V11-CONTROL-portfolio.csv",
    }
    dates, series = aligned_returns(paths)
    candidate = series["candidate"]
    matched = series["matched"]
    v11 = series["v11"]
    n = candidate.size
    blocks_per_path = math.ceil(n / BLOCK_SESSIONS)
    rng = np.random.default_rng(RNG_SEED)

    c_cagrs: list[np.ndarray] = []
    c_sharpes: list[np.ndarray] = []
    c_mdds: list[np.ndarray] = []
    m_sharpes: list[np.ndarray] = []
    v_cagrs: list[np.ndarray] = []
    remaining = REPLICATES
    offsets = np.arange(BLOCK_SESSIONS, dtype=np.int64)
    while remaining > 0:
        batch = min(BATCH_SIZE, remaining)
        starts = rng.integers(0, n, size=(batch, blocks_per_path), endpoint=False)
        indices = ((starts[:, :, None] + offsets[None, None, :]) % n).reshape(batch, -1)[:, :n]
        c = candidate[indices]
        m = matched[indices]
        v = v11[indices]
        c_cagr, c_sharpe, c_mdd = batch_metrics(c)
        _, m_sharpe, _ = batch_metrics(m)
        v_cagr, _, _ = batch_metrics(v)
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
        "bootstrap_robust_pass": all(checks.values()),
        "checks": checks,
    }


def sharpe_from_returns(returns: np.ndarray) -> float:
    if returns.size < 2:
        return -1e9
    std = float(returns.std(ddof=1))
    if std <= 0:
        return -1e9
    return float(returns.mean()) / std * math.sqrt(SESSIONS_PER_YEAR)


def percentile_rank(values: list[float], selected_index: int) -> float:
    value = values[selected_index]
    eps = 1e-10
    less = sum(item < value - eps for item in values)
    equal = sum(abs(item - value) <= eps for item in values)
    midpoint = less + 0.5 * max(equal, 1)
    return (midpoint + 0.5) / (len(values) + 1.0)


def family_pbo(candidate_dir: Path) -> dict:
    paths = {candidate_id: candidate_dir / f"{candidate_id}-portfolio.csv" for candidate_id in CANDIDATES}
    paths["V11-CONTROL"] = candidate_dir / "V11-CONTROL-portfolio.csv"
    dates, series = aligned_returns(paths)
    matrix = [series[candidate_id] for candidate_id in CANDIDATES]
    n = len(matrix[0])
    starts = [round(index * n / PBO_BLOCKS) for index in range(PBO_BLOCKS + 1)]
    block_slices = [(starts[index], starts[index + 1]) for index in range(PBO_BLOCKS)]
    splits = list(itertools.combinations(range(PBO_BLOCKS), PBO_BLOCKS // 2))
    lambdas: list[float] = []
    selected_oos_ranks: list[float] = []
    selected_under_v11 = 0
    for split in splits:
        ins = set(split)
        outs = set(range(PBO_BLOCKS)) - ins
        is_sharpes: list[float] = []
        oos_sharpes: list[float] = []
        for returns in matrix:
            is_returns = np.concatenate([returns[slice(*block_slices[block])] for block in sorted(ins)])
            oos_returns = np.concatenate([returns[slice(*block_slices[block])] for block in sorted(outs)])
            is_sharpes.append(sharpe_from_returns(is_returns))
            oos_sharpes.append(sharpe_from_returns(oos_returns))
        selected = max(range(len(CANDIDATES)), key=lambda index: (is_sharpes[index], CANDIDATES[index]))
        rank = percentile_rank(oos_sharpes, selected)
        rank = min(max(rank, 1e-9), 1 - 1e-9)
        selected_oos_ranks.append(rank)
        lambdas.append(math.log(rank / (1 - rank)))
        v11_oos = np.concatenate([series["V11-CONTROL"][slice(*block_slices[block])] for block in sorted(outs)])
        if oos_sharpes[selected] < sharpe_from_returns(v11_oos):
            selected_under_v11 += 1
    pbo = sum(value <= 0 for value in lambdas) / len(lambdas)
    return {
        "blocks": PBO_BLOCKS,
        "splits": len(splits),
        "pbo": pbo,
        "pass": pbo <= 0.20,
        "strong": pbo <= 0.10,
        "selected_oos_rank_median": float(np.median(selected_oos_ranks)),
        "selected_under_v11_fraction": selected_under_v11 / len(splits),
        "aligned_portfolio_dates": len(dates),
    }


def prior_post_protocol_sharpes() -> list[float]:
    sharpes: list[float] = []
    for path in PRIOR_RESULT_PATHS:
        document = json.loads(path.read_text(encoding="utf-8"))
        for result in document.get("candidate_results") or []:
            metrics = result.get("metrics") or {}
            value = float(metrics["sharpe"])
            if not math.isfinite(value):
                raise RuntimeError(f"non-finite prior Sharpe in {path}")
            sharpes.append(value)
    if len(sharpes) != 21:
        raise RuntimeError(f"global DSR prior trial inventory must contain 21 candidates, got {len(sharpes)}")
    return sharpes


def dsr_audit(candidate_dir: Path, candidate_metrics: dict) -> dict[str, dict]:
    family_sharpes = [
        float(next(item for item in candidate_metrics["candidate_results"] if item["candidate_id"] == candidate_id)["metrics"]["sharpe"])
        for candidate_id in CANDIDATES
    ]
    global_sharpes = prior_post_protocol_sharpes() + family_sharpes
    if len(global_sharpes) != 24:
        raise RuntimeError("global DSR inventory must contain 24 candidates after this trial")
    output: dict[str, dict] = {}
    for candidate_id in CANDIDATES:
        values = read_portfolio(candidate_dir / f"{candidate_id}-portfolio.csv")
        dates = sorted(values)
        returns = [values[dates[index]] / values[dates[index - 1]] - 1.0 for index in range(1, len(dates))]
        family = deflated_sharpe_ratio(returns, family_sharpes, SESSIONS_PER_YEAR)
        global_result = deflated_sharpe_ratio(returns, global_sharpes, SESSIONS_PER_YEAR)
        output[candidate_id] = {
            "family": family,
            "global_post_protocol": global_result,
            "family_pass": float(family["dsr_probability"]) >= 0.95,
            "global_pass": float(global_result["dsr_probability"]) >= 0.95,
        }
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate-dir", required=True)
    parser.add_argument("--candidate-metrics", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    candidate_dir = Path(args.candidate_dir)
    output_dir = Path(args.output_dir)
    candidate_metrics = json.loads(Path(args.candidate_metrics).read_text(encoding="utf-8"))
    deterministic = {
        item["candidate_id"]: bool(item["admit_for_robustness"])
        for item in candidate_metrics["candidate_results"]
    }
    if set(deterministic) != set(CANDIDATES):
        raise RuntimeError("candidate-metrics does not contain the frozen three-candidate family")

    bootstraps = {candidate_id: bootstrap_candidate(candidate_id, candidate_dir) for candidate_id in CANDIDATES}
    pbo = family_pbo(candidate_dir)
    dsr = dsr_audit(candidate_dir, candidate_metrics)
    results = []
    for candidate_id in CANDIDATES:
        robust = (
            deterministic[candidate_id]
            and bootstraps[candidate_id]["bootstrap_robust_pass"]
            and pbo["pass"]
            and dsr[candidate_id]["family_pass"]
            and dsr[candidate_id]["global_pass"]
        )
        results.append({
            "candidate_id": candidate_id,
            "deterministic_admit": deterministic[candidate_id],
            "bootstrap": bootstraps[candidate_id],
            "family_dsr": dsr[candidate_id]["family"],
            "global_post_protocol_dsr": dsr[candidate_id]["global_post_protocol"],
            "family_dsr_pass": dsr[candidate_id]["family_pass"],
            "global_dsr_pass": dsr[candidate_id]["global_pass"],
            "robust_factor_pass": robust,
        })
    document = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": "ATM-SVP2-LIT-STRESS-001",
        "method": {
            "bootstrap_sampling": "paired circular moving blocks",
            "bootstrap_block_sessions": BLOCK_SESSIONS,
            "bootstrap_replicates": REPLICATES,
            "bootstrap_rng_seed": RNG_SEED,
            "pbo_blocks": PBO_BLOCKS,
            "family_dsr_trial_count": 3,
            "global_post_protocol_dsr_trial_count": 24,
        },
        "family_pbo": pbo,
        "candidate_results": results,
        "robust_pass_candidates": [item["candidate_id"] for item in results if item["robust_factor_pass"]],
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "statistical-audit.json"
    json_path.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    csv_path = output_dir / "statistical-audit.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "candidate_id", "deterministic_admit", "bootstrap_pass", "pbo_pass",
            "family_dsr_probability", "global_dsr_probability", "robust_factor_pass",
            "probability_cagr_gt_v11", "probability_sharpe_gt_matched", "candidate_mdd_p975",
        ])
        writer.writeheader()
        for item in results:
            bootstrap = item["bootstrap"]
            writer.writerow({
                "candidate_id": item["candidate_id"],
                "deterministic_admit": item["deterministic_admit"],
                "bootstrap_pass": bootstrap["bootstrap_robust_pass"],
                "pbo_pass": pbo["pass"],
                "family_dsr_probability": item["family_dsr"]["dsr_probability"],
                "global_dsr_probability": item["global_post_protocol_dsr"]["dsr_probability"],
                "robust_factor_pass": item["robust_factor_pass"],
                "probability_cagr_gt_v11": bootstrap["bootstrap"]["probability_cagr_gt_v11"],
                "probability_sharpe_gt_matched": bootstrap["bootstrap"]["probability_sharpe_gt_matched_control"],
                "candidate_mdd_p975": bootstrap["bootstrap"]["candidate_mdd_p975"],
            })
    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print("LITERATURE_STRESS_FACTOR_V1_STATS_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
