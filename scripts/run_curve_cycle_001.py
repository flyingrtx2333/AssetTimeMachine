#!/usr/bin/env python3
"""Run the preregistered slow yield-curve regime strategy."""
from __future__ import annotations

import argparse, csv, json, os, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP3-CURVE-CYCLE-001"
CANDIDATE_ID = "S-CURVE-CYCLE-001"
FRAGMENT = ROOT / "tools/curve_cycle_001.swiftpart"
LOGIC = ROOT / "tools/orthogonal_factor_family_v1_logic.swift"
ASSEMBLED = Path("/private/tmp/atm_curve_cycle_001.swift")
BINARY = Path("/private/tmp/atm_curve_cycle_001")
CURVE = ROOT / "tools/research-results/strategy-validation/factor-data/ATM-SVP2-ORTHO-FACTOR-001/T10Y3M.csv"


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 360) -> str:
    p = subprocess.run(command, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, check=False)
    if p.returncode != 0:
        sys.stderr.write(p.stdout[-16000:])
        raise RuntimeError(f"command failed ({p.returncode}): {' '.join(command)}")
    return p.stdout


def compile_binary() -> None:
    run([sys.executable, "scripts/assemble_strategy_metric_dump.py", "--fragment", str(FRAGMENT.relative_to(ROOT)), "--output", str(ASSEMBLED)])
    run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", "/private/tmp/atm-swift-module-cache",
        "AssetTimeMachine/Backtest/BacktestModels.swift", "AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift",
        "AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift", "AssetTimeMachine/Backtest/BacktestFXConverter.swift",
        "AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift", "AssetTimeMachine/Backtest/BacktestEngine.swift",
        str(LOGIC.relative_to(ROOT)), str(ASSEMBLED), "-o", str(BINARY),
    ])


def validate_document(d: dict) -> None:
    if d.get("trial_id") != TRIAL_ID or d.get("candidate_id") != CANDIDATE_ID: raise RuntimeError("identity drift")
    if d.get("evaluation_start") != "2002-01-04" or d.get("evaluation_end") != "2026-08-20": raise RuntimeError("window drift")
    if abs(float(d.get("fee_percent_per_trade", -1)) - 1.0) > 1e-12: raise RuntimeError("fee drift")
    if abs(float(d.get("slippage_percent_per_trade", -1)) - 0.05) > 1e-12: raise RuntimeError("slippage drift")


def evaluate(d: dict) -> dict:
    c, control, cash = d["candidate"], d["always_risk_control"], d["cash_control"]
    folds = c.get("folds") or []
    positive = sum(float(x.get("sharpe", 0)) > 0 for x in folds)
    validation = {
        "actual_trades_gt_0": int(c["trades"]) > 0,
        "full_cagr_gt_0": float(c["cagr_percent"]) > 0,
        "full_sharpe_gt_0": float(c["sharpe"]) > 0,
        "full_mdd_le_25pct": float(c["mdd_percent"]) <= 25,
        "positive_sharpe_folds_ge_70pct": bool(folds) and positive / len(folds) >= .70,
        "max_gross_le_1": float(c["max_gross"]) <= 1.000000001,
        "cash_nonnegative": float(c["minimum_cash"]) >= -1e-8,
    }
    objective = {
        "cagr_ge_12pct": float(c["cagr_percent"]) >= 12,
        "sharpe_ge_1": float(c["sharpe"]) >= 1,
        "mdd_le_20pct": float(c["mdd_percent"]) <= 20,
        "since2020_cagr_positive": float(c["since2020_cagr_percent"]) > 0,
        "since2022_cagr_positive": float(c["since2022_cagr_percent"]) > 0,
        "cagr_gt_cash": float(c["cagr_percent"]) > float(cash["cagr_percent"]),
    }
    comparison = {
        "sharpe_gt_always_risk": float(c["sharpe"]) > float(control["sharpe"]),
        "mdd_lt_always_risk": float(c["mdd_percent"]) < float(control["mdd_percent"]),
    }
    return {
        "status": "PASS" if all(validation.values()) else "FAIL",
        "validation_status": "PASS" if all(validation.values()) else "FAIL",
        "objective_status": "PASS" if all(objective.values()) else "FAIL",
        "comparison_status": "PASS" if all(comparison.values()) else "FAIL",
        "validation_checks": validation, "objective_checks": objective, "comparison_checks": comparison,
        "validation_warnings": ["execution_stress_not_in_this_R1_trial"],
        "diagnostics": {"positive_fold_count": positive, "fold_count": len(folds), "always_risk_cagr_percent": control["cagr_percent"], "always_risk_sharpe": control["sharpe"], "always_risk_mdd_percent": control["mdd_percent"], "cash_cagr_percent": cash["cagr_percent"]},
    }


def write_outputs(outdir: Path, d: dict, e: dict) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "candidate-metrics.json").write_text(json.dumps({**d, "three_axis_evaluation": e}, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    with (outdir / "candidate-metrics.csv").open("w", newline="", encoding="utf-8") as f:
        fields=["id","kind","cagr_percent","mdd_percent","volatility_percent","sharpe","trades","average_cash_ratio","max_gross","minimum_cash","risk_on_sessions","target_fingerprint"]
        w=csv.DictWriter(f,fieldnames=fields,lineterminator="\n"); w.writeheader()
        for kind,row in [("CANDIDATE",d["candidate"]),("ALWAYS_RISK_CONTROL",d["always_risk_control"]),("CASH_CONTROL",d["cash_control"])]:
            w.writerow({"kind":kind,**{k:row.get(k) for k in fields if k!="kind"}})


def parse(stdout: str) -> dict:
    prefix="CURVE_CYCLE_001_FORMAL_JSON="
    rows=[x[len(prefix):] for x in stdout.splitlines() if x.startswith(prefix)]
    if len(rows)!=1 or "CURVE_CYCLE_001_FORMAL_OK" not in stdout: raise RuntimeError("formal output incomplete")
    d=json.loads(rows[0]); validate_document(d); return d


def main() -> int:
    ap=argparse.ArgumentParser(); ap.add_argument("--fixture",required=True); ap.add_argument("--output-dir"); ap.add_argument("--formal",action="store_true"); a=ap.parse_args()
    if not Path(a.fixture).is_file() or not CURVE.is_file(): raise SystemExit("required input missing")
    if a.formal and not a.output_dir: raise SystemExit("--formal requires --output-dir")
    compile_binary(); env=os.environ.copy(); env.update({"ATM_HISTORY_FIXTURE":a.fixture,"ATM_CURVE_CYCLE_001":"1","ATM_CURVE_CYCLE_001_CURVE":str(CURVE)})
    if a.formal: env.update({"ATM_CURVE_CYCLE_001_FORMAL":"1","ATM_CURVE_CYCLE_001_OUTPUT_DIR":str(Path(a.output_dir))})
    stdout=run([str(BINARY)],env=env)
    if not a.formal:
        if "CURVE_CYCLE_001_SMOKE_OK" not in stdout: print(stdout,end=""); raise RuntimeError("smoke incomplete")
        print(stdout,end=""); return 0
    d=parse(stdout); e=evaluate(d); write_outputs(Path(a.output_dir),d,e)
    print(json.dumps({"trial_id":TRIAL_ID,"candidate_id":CANDIDATE_ID,**e},ensure_ascii=False,sort_keys=True)); print("CURVE_CYCLE_001_FORMAL_COMPLETE"); return 0


if __name__ == "__main__": raise SystemExit(main())
