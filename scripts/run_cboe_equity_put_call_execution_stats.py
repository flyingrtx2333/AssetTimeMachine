#!/usr/bin/env python3
"""Frozen bootstrap and cumulative DSR audit for ATM-SVP2-CBOE-PC-001."""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np

from strategy_validation_stats import deflated_sharpe_ratio

ROOT = Path(__file__).resolve().parents[1]
CANDIDATE_ID = "F-CBOE-PC-EXECUTION"
MATCHED_CONTROL_ID = "C-CBOE-PC-DELAY-ALWAYS"
EVALUATION_START = "2013-01-01"
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
]


def read_portfolio(path: Path) -> dict[str, float]:
    rows = {}
    with path.open("r", encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            day, value = row["date"], float(row["portfolio_value"])
            if not day or not math.isfinite(value) or value <= 0 or day in rows:
                raise RuntimeError(f"invalid portfolio row: {path}")
            rows[day] = value
    return rows


def aligned_returns(paths: dict[str, Path], start: str | None = None) -> tuple[list[str], dict[str, np.ndarray]]:
    maps = {key: read_portfolio(path) for key, path in paths.items()}
    dates = sorted(set.intersection(*(set(value) for value in maps.values())))
    if start:
        dates = [day for day in dates if day >= start]
    if len(dates) < 3:
        raise RuntimeError("insufficient aligned dates")
    series = {}
    for key, values in maps.items():
        array = np.asarray([values[day] for day in dates], dtype=np.float64)
        returns = array[1:] / array[:-1] - 1
        if np.any(returns <= -1) or not np.all(np.isfinite(returns)):
            raise RuntimeError("invalid returns")
        series[key] = returns
    return dates, series


def perf(returns: np.ndarray) -> dict[str, float]:
    cagr = math.expm1(float(np.log1p(returns).sum()) * SESSIONS_PER_YEAR / returns.size)
    std = float(returns.std(ddof=1))
    sharpe = float(returns.mean()) / std * math.sqrt(SESSIONS_PER_YEAR) if std > 0 else 0.0
    wealth = np.cumprod(1 + returns); peaks = np.maximum.accumulate(wealth); mdd = float(np.max(1 - wealth / peaks))
    return {"cagr": cagr, "sharpe": sharpe, "mdd": mdd}


def batch_metrics(returns: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    n = returns.shape[1]
    cagr = np.expm1(np.log1p(returns).sum(axis=1) * SESSIONS_PER_YEAR / n)
    mean = returns.mean(axis=1); std = returns.std(axis=1, ddof=1)
    sharpe = np.divide(mean * math.sqrt(SESSIONS_PER_YEAR), std, out=np.zeros_like(mean), where=std > 0)
    wealth = np.cumprod(1 + returns, axis=1); peaks = np.maximum.accumulate(wealth, axis=1); mdd = np.max(1 - wealth / peaks, axis=1)
    return cagr, sharpe, mdd


def bootstrap(candidate_dir: Path) -> dict:
    dates, series = aligned_returns({
        "candidate": candidate_dir / f"{CANDIDATE_ID}-portfolio.csv",
        "matched": candidate_dir / f"{MATCHED_CONTROL_ID}-portfolio.csv",
        "v11": candidate_dir / "V11-CONTROL-portfolio.csv",
    }, EVALUATION_START)
    candidate, matched, v11 = series["candidate"], series["matched"], series["v11"]
    n = candidate.size; blocks = math.ceil(n / BLOCK_SESSIONS); rng = np.random.default_rng(RNG_SEED); offsets = np.arange(BLOCK_SESSIONS, dtype=np.int64)
    c_cagr=[]; c_sharpe=[]; c_mdd=[]; m_sharpe=[]; v_cagr=[]; remaining=REPLICATES
    while remaining:
        batch=min(BATCH_SIZE,remaining); starts=rng.integers(0,n,size=(batch,blocks),endpoint=False); idx=((starts[:,:,None]+offsets[None,None,:])%n).reshape(batch,-1)[:,:n]
        a,b,c=batch_metrics(candidate[idx]); _,d,_=batch_metrics(matched[idx]); e,_,_=batch_metrics(v11[idx])
        c_cagr.append(a); c_sharpe.append(b); c_mdd.append(c); m_sharpe.append(d); v_cagr.append(e); remaining-=batch
    cc=np.concatenate(c_cagr); cs=np.concatenate(c_sharpe); cm=np.concatenate(c_mdd); ms=np.concatenate(m_sharpe); vc=np.concatenate(v_cagr)
    p_cagr=float(np.mean(cc>vc)); p_sharpe=float(np.mean(cs>ms)); med_cagr=float(np.median(cc-vc)); med_sharpe=float(np.median(cs-ms)); mdd975=float(np.quantile(cm,.975))
    checks={"probability_cagr_gt_v11_ge_0_90":p_cagr>=.90,"probability_sharpe_gt_matched_ge_0_90":p_sharpe>=.90,"median_cagr_delta_gt_0":med_cagr>0,"median_sharpe_delta_gt_0":med_sharpe>0,"candidate_mdd_p975_le_0_15":mdd975<=.15}
    return {
        "candidate_id": CANDIDATE_ID,
        "sample": {"evaluation_start":EVALUATION_START,"first_date":dates[0],"last_date":dates[-1],"aligned_portfolio_dates":len(dates),"daily_returns":n},
        "observed": {"candidate":perf(candidate),"matched_control":perf(matched),"v11":perf(v11)},
        "bootstrap": {"replicates":REPLICATES,"block_sessions":BLOCK_SESSIONS,"rng_seed":RNG_SEED,"probability_cagr_gt_v11":p_cagr,"probability_sharpe_gt_matched_control":p_sharpe,"median_candidate_minus_v11_cagr":med_cagr,"median_candidate_minus_matched_sharpe":med_sharpe,"candidate_mdd_p975":mdd975,"candidate_cagr_p025":float(np.quantile(cc,.025)),"candidate_cagr_p50":float(np.quantile(cc,.5)),"candidate_cagr_p975":float(np.quantile(cc,.975)),"candidate_sharpe_p025":float(np.quantile(cs,.025)),"candidate_sharpe_p50":float(np.quantile(cs,.5)),"candidate_sharpe_p975":float(np.quantile(cs,.975))},
        "checks": checks, "bootstrap_robust_pass": all(checks.values()),
    }


def prior_sharpes() -> list[float]:
    values=[]
    for path in PRIOR_RESULT_PATHS:
        document=json.loads(path.read_text(encoding="utf-8"))
        for result in document.get("candidate_results") or []:
            value=float((result.get("metrics") or {})["sharpe"])
            if not math.isfinite(value): raise RuntimeError(f"non-finite prior Sharpe: {path}")
            values.append(value)
    if len(values)!=33: raise RuntimeError(f"expected 33 prior candidates, got {len(values)}")
    return values


def global_dsr(candidate_dir: Path, candidate_sharpe: float) -> dict:
    trial_sharpes=prior_sharpes()+[candidate_sharpe]
    values=read_portfolio(candidate_dir/f"{CANDIDATE_ID}-portfolio.csv"); dates=sorted(values); returns=[values[dates[i]]/values[dates[i-1]]-1 for i in range(1,len(dates))]
    return deflated_sharpe_ratio(returns, trial_sharpes, SESSIONS_PER_YEAR)


def main() -> int:
    parser=argparse.ArgumentParser(); parser.add_argument("--candidate-dir",required=True); parser.add_argument("--candidate-metrics",required=True); parser.add_argument("--output-dir",required=True); args=parser.parse_args()
    candidate_dir=Path(args.candidate_dir); output_dir=Path(args.output_dir); metrics_doc=json.loads(Path(args.candidate_metrics).read_text(encoding="utf-8")); result=metrics_doc["candidate_results"][0]
    if result["candidate_id"]!=CANDIDATE_ID: raise RuntimeError("wrong frozen candidate")
    deterministic=bool(result["admit_for_robustness"]); boot=bootstrap(candidate_dir); dsr=global_dsr(candidate_dir,float(result["metrics"]["sharpe"])); dsr_pass=float(dsr["dsr_probability"])>=.95; robust=deterministic and boot["bootstrap_robust_pass"] and dsr_pass
    document={"protocol_id":"ATM-SVP-2","trial_id":"ATM-SVP2-CBOE-PC-001","method":{"bootstrap_sample_start":EVALUATION_START,"bootstrap_sampling":"paired circular moving blocks","bootstrap_block_sessions":BLOCK_SESSIONS,"bootstrap_replicates":REPLICATES,"bootstrap_rng_seed":RNG_SEED,"family_pbo":"not_applicable_single_candidate","global_post_protocol_dsr_trial_count":34},"candidate_results":[{"candidate_id":CANDIDATE_ID,"deterministic_admit":deterministic,"bootstrap":boot,"global_post_protocol_dsr":dsr,"global_dsr_pass":dsr_pass,"robust_factor_pass":robust}],"robust_pass_candidates":[CANDIDATE_ID] if robust else []}
    output_dir.mkdir(parents=True,exist_ok=True); (output_dir/"statistical-audit.json").write_text(json.dumps(document,ensure_ascii=False,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    with (output_dir/"statistical-audit.csv").open("w",encoding="utf-8",newline="") as handle:
        b=boot["bootstrap"]; writer=csv.DictWriter(handle,fieldnames=["candidate_id","deterministic_admit","bootstrap_pass","global_dsr_probability","global_dsr_pass","robust_factor_pass","probability_cagr_gt_v11","probability_sharpe_gt_matched","candidate_mdd_p975"]); writer.writeheader(); writer.writerow({"candidate_id":CANDIDATE_ID,"deterministic_admit":deterministic,"bootstrap_pass":boot["bootstrap_robust_pass"],"global_dsr_probability":dsr["dsr_probability"],"global_dsr_pass":dsr_pass,"robust_factor_pass":robust,"probability_cagr_gt_v11":b["probability_cagr_gt_v11"],"probability_sharpe_gt_matched":b["probability_sharpe_gt_matched_control"],"candidate_mdd_p975":b["candidate_mdd_p975"]})
    print(json.dumps(document,ensure_ascii=False,sort_keys=True)); print("CBOE_PC_EXECUTION_V1_STATS_COMPLETE"); return 0


if __name__ == "__main__":
    raise SystemExit(main())
