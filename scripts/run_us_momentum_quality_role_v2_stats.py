#!/usr/bin/env python3
"""Frozen bootstrap + cumulative DSR audit for the calendar-alignment repair for ATM-SVP2-US-MQ-ROLE-002."""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np

from strategy_validation_stats import deflated_sharpe_ratio

ROOT = Path(__file__).resolve().parents[1]
CANDIDATES = ("F-MTUM-SP500-ROLE", "F-QUAL-SP500-ROLE")
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
    return rows


def aligned_returns(candidate_path: Path, control_path: Path) -> tuple[list[str], np.ndarray, np.ndarray]:
    candidate = read_portfolio(candidate_path); control = read_portfolio(control_path)
    dates = [day for day in sorted(set(candidate).intersection(control)) if day >= EVALUATION_START]
    if len(dates) < 3: raise RuntimeError("insufficient evaluation dates")
    c = np.asarray([candidate[day] for day in dates], dtype=np.float64); v = np.asarray([control[day] for day in dates], dtype=np.float64)
    cr = c[1:] / c[:-1] - 1.0; vr = v[1:] / v[:-1] - 1.0
    if not np.all(np.isfinite(cr)) or not np.all(np.isfinite(vr)) or np.any(cr <= -1.0) or np.any(vr <= -1.0): raise RuntimeError("invalid returns")
    return dates, cr, vr


def perf(returns: np.ndarray) -> dict[str, float]:
    cagr = math.expm1(float(np.log1p(returns).sum()) * SESSIONS_PER_YEAR / returns.size)
    std = float(returns.std(ddof=1)); sharpe = float(returns.mean()) / std * math.sqrt(SESSIONS_PER_YEAR) if std > 0 else 0.0
    wealth = np.cumprod(1.0 + returns); peaks = np.maximum.accumulate(wealth); mdd = float(np.max(1.0 - wealth / peaks))
    return {"cagr": cagr, "sharpe": sharpe, "mdd": mdd}


def batch_metrics(returns: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    n = returns.shape[1]; cagr = np.expm1(np.log1p(returns).sum(axis=1) * SESSIONS_PER_YEAR / n); means = returns.mean(axis=1); stds = returns.std(axis=1, ddof=1)
    sharpe = np.divide(means * math.sqrt(SESSIONS_PER_YEAR), stds, out=np.zeros_like(means), where=stds > 0)
    wealth = np.cumprod(1.0 + returns, axis=1); peaks = np.maximum.accumulate(wealth, axis=1); mdd = np.max(1.0 - wealth / peaks, axis=1)
    return cagr, sharpe, mdd


def bootstrap(candidate_id: str, candidate_dir: Path) -> dict:
    dates, candidate, v11 = aligned_returns(candidate_dir / f"{candidate_id}-portfolio.csv", candidate_dir / "V11-CONTROL-portfolio.csv")
    n = candidate.size; blocks = math.ceil(n / BLOCK_SESSIONS); offsets = np.arange(BLOCK_SESSIONS, dtype=np.int64); rng = np.random.default_rng(RNG_SEED)
    cc=[]; cs=[]; cm=[]; vc=[]; vs=[]; remaining=REPLICATES
    while remaining:
        batch=min(BATCH_SIZE,remaining); starts=rng.integers(0,n,size=(batch,blocks),endpoint=False); idx=((starts[:,:,None]+offsets[None,None,:])%n).reshape(batch,-1)[:,:n]
        a,b,c=batch_metrics(candidate[idx]); d,e,_=batch_metrics(v11[idx]); cc.append(a); cs.append(b); cm.append(c); vc.append(d); vs.append(e); remaining-=batch
    cc=np.concatenate(cc); cs=np.concatenate(cs); cm=np.concatenate(cm); vc=np.concatenate(vc); vs=np.concatenate(vs)
    p_cagr=float(np.mean(cc>vc)); p_sharpe=float(np.mean(cs>vs)); med_cagr=float(np.median(cc-vc)); med_sharpe=float(np.median(cs-vs)); mdd975=float(np.quantile(cm,.975))
    checks={"probability_cagr_gt_v11_ge_0_90":p_cagr>=.90,"probability_sharpe_gt_v11_ge_0_90":p_sharpe>=.90,"median_cagr_delta_gt_0":med_cagr>0,"median_sharpe_delta_gt_0":med_sharpe>0,"candidate_mdd_p975_le_0_15":mdd975<=.15}
    return {"candidate_id":candidate_id,"sample":{"evaluation_start":EVALUATION_START,"first_date":dates[0],"last_date":dates[-1],"aligned_portfolio_dates":len(dates),"daily_returns":n},"observed":{"candidate":perf(candidate),"v11":perf(v11)},"bootstrap":{"replicates":REPLICATES,"block_sessions":BLOCK_SESSIONS,"rng_seed":RNG_SEED,"probability_cagr_gt_v11":p_cagr,"probability_sharpe_gt_v11":p_sharpe,"median_candidate_minus_v11_cagr":med_cagr,"median_candidate_minus_v11_sharpe":med_sharpe,"candidate_mdd_p975":mdd975,"candidate_cagr_p025":float(np.quantile(cc,.025)),"candidate_cagr_p50":float(np.quantile(cc,.5)),"candidate_cagr_p975":float(np.quantile(cc,.975)),"candidate_sharpe_p025":float(np.quantile(cs,.025)),"candidate_sharpe_p50":float(np.quantile(cs,.5)),"candidate_sharpe_p975":float(np.quantile(cs,.975))},"checks":checks,"bootstrap_robust_pass":all(checks.values())}


def prior_sharpes() -> list[float]:
    values=[]
    for path in PRIOR_RESULT_PATHS:
        document=json.loads(path.read_text(encoding="utf-8"))
        for result in document.get("candidate_results") or []:
            metrics=result.get("metrics") or {}
            raw=metrics.get("sharpe", metrics.get("full_sharpe"))
            if raw is None: raise RuntimeError(f"prior result missing Sharpe: {path}")
            value=float(raw)
            if not math.isfinite(value): raise RuntimeError(f"non-finite prior Sharpe: {path}")
            values.append(value)
    if len(values)!=36: raise RuntimeError(f"expected 36 prior candidates, got {len(values)}")
    return values


def evaluation_returns(path: Path) -> list[float]:
    values=read_portfolio(path); dates=[day for day in sorted(values) if day>=EVALUATION_START]
    return [values[dates[i]]/values[dates[i-1]]-1.0 for i in range(1,len(dates))]


def main() -> int:
    parser=argparse.ArgumentParser(); parser.add_argument("--candidate-dir",required=True); parser.add_argument("--candidate-metrics",required=True); parser.add_argument("--output-dir",required=True); args=parser.parse_args()
    candidate_dir=Path(args.candidate_dir); output_dir=Path(args.output_dir); metrics_doc=json.loads(Path(args.candidate_metrics).read_text(encoding="utf-8")); by_id={row["candidate_id"]:row for row in metrics_doc["candidate_results"]}
    if set(by_id)!=set(CANDIDATES): raise RuntimeError("frozen MTUM/QUAL pair missing")
    current_sharpes=[float(by_id[candidate_id]["metrics"]["evaluation_sharpe"]) for candidate_id in CANDIDATES]
    all_sharpes=prior_sharpes()+current_sharpes
    if len(all_sharpes)!=38: raise RuntimeError("global DSR inventory must contain 38 candidates")
    results=[]
    for candidate_id in CANDIDATES:
        deterministic=bool(by_id[candidate_id]["admit_for_robustness"]); boot=bootstrap(candidate_id,candidate_dir); dsr=deflated_sharpe_ratio(evaluation_returns(candidate_dir/f"{candidate_id}-portfolio.csv"),all_sharpes,SESSIONS_PER_YEAR); dsr_pass=float(dsr["dsr_probability"])>=.95; robust=deterministic and boot["bootstrap_robust_pass"] and dsr_pass
        results.append({"candidate_id":candidate_id,"deterministic_admit":deterministic,"bootstrap":boot,"global_post_protocol_dsr":dsr,"global_dsr_pass":dsr_pass,"robust_strategy_pass":robust})
    document={"protocol_id":"ATM-SVP-2","trial_id":"ATM-SVP2-US-MQ-ROLE-002","method":{"evaluation_start":EVALUATION_START,"bootstrap_sampling":"paired circular moving blocks versus production-path V11","bootstrap_block_sessions":BLOCK_SESSIONS,"bootstrap_replicates":REPLICATES,"bootstrap_rng_seed":RNG_SEED,"family_pbo":"not_applicable_no_winner_selection_two_independent_preregistered_roles","global_post_protocol_dsr_prior_trial_count":36,"global_post_protocol_dsr_total_trial_count":38,"global_dsr_return_window":"2013-07-19+ evaluation behavior only; pre-substitution identical history excluded"},"candidate_results":results,"robust_pass_candidates":[row["candidate_id"] for row in results if row["robust_strategy_pass"]]}
    output_dir.mkdir(parents=True,exist_ok=True); (output_dir/"statistical-audit.json").write_text(json.dumps(document,ensure_ascii=False,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    with (output_dir/"statistical-audit.csv").open("w",encoding="utf-8",newline="") as handle:
        writer=csv.DictWriter(handle,fieldnames=["candidate_id","deterministic_admit","bootstrap_pass","global_dsr_probability","global_dsr_pass","robust_strategy_pass","probability_cagr_gt_v11","probability_sharpe_gt_v11","candidate_mdd_p975"]); writer.writeheader()
        for row in results:
            boot=row["bootstrap"]["bootstrap"]; writer.writerow({"candidate_id":row["candidate_id"],"deterministic_admit":row["deterministic_admit"],"bootstrap_pass":row["bootstrap"]["bootstrap_robust_pass"],"global_dsr_probability":row["global_post_protocol_dsr"]["dsr_probability"],"global_dsr_pass":row["global_dsr_pass"],"robust_strategy_pass":row["robust_strategy_pass"],"probability_cagr_gt_v11":boot["probability_cagr_gt_v11"],"probability_sharpe_gt_v11":boot["probability_sharpe_gt_v11"],"candidate_mdd_p975":boot["candidate_mdd_p975"]})
    print(json.dumps(document,ensure_ascii=False,sort_keys=True)); print("US_MQ_ROLE_V2_STATS_COMPLETE"); return 0


if __name__ == "__main__":
    raise SystemExit(main())
