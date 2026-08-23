#!/usr/bin/env python3
"""Run preregisterable long-only four-factor annual minimum-variance strategy."""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.factor_minvar_001_schedule import build_schedule

TRIAL_ID = "ATM-SVP3-FACTOR-MINVAR-001"
CANDIDATE_ID = "S-FACTOR-MINVAR-001"
FRAGMENT = ROOT / "tools/factor_minvar_001.swiftpart"
ASSEMBLED = Path("/private/tmp/atm_factor_minvar_001.swift")
BINARY = Path("/private/tmp/atm_factor_minvar_001")


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 360) -> str:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        sys.stderr.write(completed.stdout[-16000:])
        raise RuntimeError(f"command failed ({completed.returncode}): {' '.join(command)}")
    return completed.stdout


def compile_binary() -> None:
    run([
        sys.executable,
        "scripts/assemble_strategy_metric_dump.py",
        "--fragment", str(FRAGMENT.relative_to(ROOT)),
        "--output", str(ASSEMBLED),
    ])
    run([
        "xcrun", "swiftc", "-parse-as-library",
        "-module-cache-path", "/private/tmp/atm-swift-module-cache",
        "AssetTimeMachine/Backtest/BacktestModels.swift",
        "AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift",
        "AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift",
        "AssetTimeMachine/Backtest/BacktestFXConverter.swift",
        "AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift",
        "AssetTimeMachine/Backtest/BacktestEngine.swift",
        str(ASSEMBLED),
        "-o", str(BINARY),
    ])


def build_and_write_schedule(fixture: Path, path: Path) -> list[dict]:
    schedule = build_schedule(ROOT, fixture)
    if len(schedule) != 12:
        raise RuntimeError(f"schedule entry drift: {len(schedule)}")
    for row in schedule:
        if row["signal_end_date"] >= row["date"]:
            raise RuntimeError("schedule causality violation")
        if int(row["lookback_returns"]) != 252:
            raise RuntimeError("lookback drift")
        if abs(float(row["sum_weights"]) - 1.0) > 1e-8:
            raise RuntimeError("weight sum drift")
        if float(row["min_weight"]) < -1e-10:
            raise RuntimeError("negative weight")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(schedule, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return schedule


def validate_document(document: dict) -> None:
    if document.get("trial_id") != TRIAL_ID or document.get("candidate_id") != CANDIDATE_ID:
        raise RuntimeError("formal identity mismatch")
    if document.get("evaluation_start") != "2015-01-02" or document.get("evaluation_end") != "2026-08-13":
        raise RuntimeError("evaluation window drifted")
    if int(document.get("lookback_returns", -1)) != 252:
        raise RuntimeError("covariance lookback drifted")
    if int(document.get("schedule_entries", -1)) != 12:
        raise RuntimeError("schedule entry count drifted")
    if abs(float(document.get("fee_percent_per_trade", -1)) - 1.0) > 1e-12:
        raise RuntimeError("fee drifted")
    if abs(float(document.get("slippage_percent_per_trade", -1)) - 0.05) > 1e-12:
        raise RuntimeError("slippage drifted")


def evaluate(document: dict) -> dict:
    candidate = document["candidate"]
    equal = document["equal_factor_control"]
    cash = document["cash_control"]
    folds = candidate.get("folds") or []
    positive_folds = sum(float(row.get("sharpe", 0)) > 0 for row in folds)
    fold_fraction = positive_folds / len(folds) if folds else 0.0
    validation_checks = {
        "actual_trades_gt_0": int(candidate["trades"]) > 0,
        "full_cagr_gt_0": float(candidate["cagr_percent"]) > 0,
        "full_sharpe_gt_0": float(candidate["sharpe"]) > 0,
        "full_mdd_le_25pct": float(candidate["mdd_percent"]) <= 25.0,
        "positive_sharpe_folds_ge_70pct": fold_fraction >= 0.70,
        "max_gross_le_1": float(candidate["max_gross"]) <= 1.000000001,
        "cash_nonnegative": float(candidate["minimum_cash"]) >= -1e-8,
    }
    objective_checks = {
        "cagr_ge_12pct": float(candidate["cagr_percent"]) >= 12.0,
        "sharpe_ge_1": float(candidate["sharpe"]) >= 1.0,
        "mdd_le_20pct": float(candidate["mdd_percent"]) <= 20.0,
        "since2020_cagr_positive": float(candidate["since2020_cagr_percent"]) > 0,
        "since2022_cagr_positive": float(candidate["since2022_cagr_percent"]) > 0,
        "cagr_gt_cash": float(candidate["cagr_percent"]) > float(cash["cagr_percent"]),
    }
    comparison_checks = {
        "sharpe_gt_equal_factor": float(candidate["sharpe"]) > float(equal["sharpe"]),
        "mdd_le_equal_factor": float(candidate["mdd_percent"]) <= float(equal["mdd_percent"]),
    }
    validation_status = "PASS" if all(validation_checks.values()) else "FAIL"
    return {
        "status": validation_status,
        "validation_status": validation_status,
        "objective_status": "PASS" if all(objective_checks.values()) else "FAIL",
        "comparison_status": "PASS" if all(comparison_checks.values()) else "FAIL",
        "validation_checks": validation_checks,
        "objective_checks": objective_checks,
        "comparison_checks": comparison_checks,
        "validation_warnings": [
            "execution_stress_not_in_this_R1_trial; base run already uses product 1.00% fee plus 0.05% slippage",
            "annual covariance weights use previous 252 common CNY daily returns and no execution-day observation",
        ],
        "diagnostics": {
            "positive_fold_count": positive_folds,
            "fold_count": len(folds),
            "positive_fold_fraction": fold_fraction,
            "equal_factor_cagr_percent": float(equal["cagr_percent"]),
            "equal_factor_sharpe": float(equal["sharpe"]),
            "equal_factor_mdd_percent": float(equal["mdd_percent"]),
            "cash_cagr_percent": float(cash["cagr_percent"]),
        },
    }


def write_outputs(output_dir: Path, document: dict, evaluation: dict) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    payload = {**document, "three_axis_evaluation": evaluation}
    (output_dir / "candidate-metrics.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    with (output_dir / "candidate-metrics.csv").open("w", encoding="utf-8", newline="") as handle:
        fields = [
            "id", "kind", "cagr_percent", "mdd_percent", "volatility_percent", "sharpe",
            "trades", "average_cash_ratio", "max_gross", "minimum_cash", "target_fingerprint",
        ]
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for kind, row in [
            ("CANDIDATE", document["candidate"]),
            ("EQUAL_FACTOR_CONTROL", document["equal_factor_control"]),
            ("CASH_CONTROL", document["cash_control"]),
        ]:
            writer.writerow({"kind": kind, **{key: row.get(key) for key in fields if key != "kind"}})


def parse_formal_stdout(stdout: str) -> dict:
    prefix = "FACTOR_MINVAR_001_FORMAL_JSON="
    lines = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
    if len(lines) != 1 or "FACTOR_MINVAR_001_FORMAL_OK" not in stdout:
        raise RuntimeError("Swift formal output incomplete")
    document = json.loads(lines[0])
    validate_document(document)
    return document


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--output-dir")
    parser.add_argument("--formal", action="store_true")
    args = parser.parse_args()
    fixture = Path(args.fixture)
    if not fixture.is_file():
        raise SystemExit(f"fixture missing: {fixture}")
    if args.formal and not args.output_dir:
        raise SystemExit("--formal requires --output-dir")

    compile_binary()
    if args.formal:
        candidate_dir = Path(args.output_dir)
        schedule_path = candidate_dir / "weights-audit.json"
    else:
        schedule_path = Path("/private/tmp/atm_factor_minvar_001_schedule.json")
    schedule = build_and_write_schedule(fixture, schedule_path)

    env = os.environ.copy()
    env.update({
        "ATM_HISTORY_FIXTURE": str(fixture),
        "ATM_FACTOR_MINVAR_001": "1",
        "ATM_FACTOR_MINVAR_001_SCHEDULE": str(schedule_path),
    })
    if args.formal:
        env["ATM_FACTOR_MINVAR_001_FORMAL"] = "1"
        env["ATM_FACTOR_MINVAR_001_OUTPUT_DIR"] = str(Path(args.output_dir))

    stdout = run([str(BINARY)], env=env)
    if not args.formal:
        if "FACTOR_MINVAR_001_SMOKE_OK" not in stdout:
            print(stdout, end="")
            raise RuntimeError("Swift smoke output incomplete")
        print(stdout, end="")
        print(f"FACTOR_MINVAR_001_SCHEDULE_CAUSAL entries={len(schedule)}")
        return 0

    document = parse_formal_stdout(stdout)
    evaluation = evaluate(document)
    write_outputs(Path(args.output_dir), document, evaluation)
    print(json.dumps({"trial_id": TRIAL_ID, "candidate_id": CANDIDATE_ID, **evaluation}, ensure_ascii=False, sort_keys=True))
    print("FACTOR_MINVAR_001_FORMAL_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
