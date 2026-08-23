#!/usr/bin/env python3
"""Run the preregistered canonical U.S. turn-of-the-month strategy."""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP3-US-TURN-MONTH-001"
CANDIDATE_ID = "S-US-TURN-MONTH-001"
FRAGMENT = ROOT / "tools/us_turn_month_001.swiftpart"
LOGIC = ROOT / "tools/us_turn_month_001_logic.swift"
ASSEMBLED = Path("/private/tmp/atm_us_turn_month_001.swift")
BINARY = Path("/private/tmp/atm_us_turn_month_001")


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
        str(LOGIC.relative_to(ROOT)), str(ASSEMBLED),
        "-o", str(BINARY),
    ])


def validate_document(document: dict) -> None:
    if document.get("trial_id") != TRIAL_ID or document.get("candidate_id") != CANDIDATE_ID:
        raise RuntimeError("formal identity mismatch")
    if document.get("evaluation_start") != "2000-01-04" or document.get("evaluation_end") != "2026-08-20":
        raise RuntimeError("evaluation window drifted")
    if abs(float(document.get("fee_rate_per_fill", -1)) - 0.00005) > 1e-12:
        raise RuntimeError("fee rate drifted")
    if abs(float(document.get("primary_slippage_rate_per_fill", -1))) > 1e-12:
        raise RuntimeError("primary slippage drifted")
    if abs(float(document.get("stress_slippage_rate_per_fill", -1)) - 0.0005) > 1e-12:
        raise RuntimeError("stress slippage drifted")
    if "penultimate" not in str(document.get("calendar_rule", "")):
        raise RuntimeError("calendar rule assertion missing")


def evaluate(document: dict) -> dict:
    candidate = document["candidate"]
    rest = document["rest_of_month_control"]
    cash = document["cash_control"]
    stress = document["slippage_stress"]
    folds = candidate.get("folds") or []
    positive_folds = sum(float(row.get("sharpe", 0)) > 0 for row in folds)
    fold_fraction = positive_folds / len(folds) if folds else 0.0
    validation_checks = {
        "actual_trades_gt_0": int(candidate["trades"]) > 0,
        "full_cagr_gt_0": float(candidate["cagr_percent"]) > 0,
        "full_sharpe_gt_0": float(candidate["sharpe"]) > 0,
        "full_mdd_le_25pct": float(candidate["mdd_percent"]) <= 25.0,
        "positive_sharpe_folds_ge_70pct": fold_fraction >= 0.70,
        "stress_cagr_gt_0": float(stress["cagr_percent"]) > 0,
        "stress_sharpe_gt_0": float(stress["sharpe"]) > 0,
        "stress_mdd_le_2x_base": float(stress["mdd_percent"]) <= 2.0 * float(candidate["mdd_percent"]) + 1e-9,
        "max_gross_le_1": float(candidate["max_gross"]) <= 1.000000001,
        "cash_nonnegative": float(candidate["minimum_cash"]) >= -1e-8,
        "stress_target_fingerprint_invariant": candidate["target_fingerprint"] == stress["target_fingerprint"],
    }
    objective_checks = {
        "combined_cagr_ge_8pct": float(candidate["cagr_percent"]) >= 8.0,
        "combined_sharpe_ge_1": float(candidate["sharpe"]) >= 1.0,
        "combined_mdd_le_15pct": float(candidate["mdd_percent"]) <= 15.0,
        "since2020_cagr_positive": float(candidate["since2020_cagr_percent"]) > 0,
        "since2022_cagr_positive": float(candidate["since2022_cagr_percent"]) > 0,
        "turn_month_cagr_gt_cash": float(candidate["cagr_percent"]) > float(cash["cagr_percent"]),
    }
    comparison_checks = {
        "turn_month_sharpe_gt_rest_month": float(candidate["sharpe"]) > float(rest["sharpe"]),
        "turn_month_mdd_le_rest_month": float(candidate["mdd_percent"]) <= float(rest["mdd_percent"]),
    }
    return {
        "status": "PASS" if all(validation_checks.values()) else "FAIL",
        "validation_status": "PASS" if all(validation_checks.values()) else "FAIL",
        "objective_status": "PASS" if all(objective_checks.values()) else "FAIL",
        "comparison_status": "PASS" if all(comparison_checks.values()) else "FAIL",
        "validation_checks": validation_checks,
        "objective_checks": objective_checks,
        "comparison_checks": comparison_checks,
        "diagnostics": {
            "positive_fold_count": positive_folds,
            "fold_count": len(folds),
            "positive_fold_fraction": fold_fraction,
            "rest_month_cagr_percent": float(rest["cagr_percent"]),
            "rest_month_sharpe": float(rest["sharpe"]),
            "rest_month_mdd_percent": float(rest["mdd_percent"]),
            "cash_cagr_percent": float(cash["cagr_percent"]),
        },
    }


def write_outputs(output_dir: Path, document: dict, evaluation: dict) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    payload = {**document, "three_axis_evaluation": evaluation}
    (output_dir / "candidate-metrics.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    with (output_dir / "candidate-metrics.csv").open("w", encoding="utf-8", newline="") as handle:
        fields = [
            "id", "kind", "cagr_percent", "mdd_percent", "volatility_percent", "sharpe",
            "trades", "active_target_sessions", "average_cash_ratio", "max_gross",
            "minimum_cash", "target_fingerprint",
        ]
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        rows = [
            ("CANDIDATE", document["candidate"]),
            ("REST_OF_MONTH_CONTROL", document["rest_of_month_control"]),
            ("CASH_CONTROL", document["cash_control"]),
            ("SLIPPAGE_STRESS", document["slippage_stress"]),
        ]
        for kind, row in rows:
            writer.writerow({
                "id": row["id"], "kind": kind,
                "cagr_percent": row["cagr_percent"], "mdd_percent": row["mdd_percent"],
                "volatility_percent": row["volatility_percent"], "sharpe": row["sharpe"],
                "trades": row["trades"], "active_target_sessions": row["active_target_sessions"],
                "average_cash_ratio": row["average_cash_ratio"], "max_gross": row["max_gross"],
                "minimum_cash": row["minimum_cash"], "target_fingerprint": row["target_fingerprint"],
            })


def parse_formal_stdout(stdout: str) -> dict:
    prefix = "US_TURN_MONTH_001_FORMAL_JSON="
    lines = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
    if len(lines) != 1 or "US_TURN_MONTH_001_FORMAL_OK" not in stdout:
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
    env = os.environ.copy()
    env.update({"ATM_HISTORY_FIXTURE": str(fixture), "ATM_US_TURN_MONTH_001": "1"})
    if args.formal:
        env["ATM_US_TURN_MONTH_001_FORMAL"] = "1"
        env["ATM_US_TURN_MONTH_001_OUTPUT_DIR"] = str(Path(args.output_dir))
    stdout = run([str(BINARY)], env=env)
    if not args.formal:
        if "US_TURN_MONTH_001_SMOKE_OK" not in stdout:
            print(stdout, end="")
            raise RuntimeError("Swift smoke output incomplete")
        print(stdout, end="")
        return 0
    document = parse_formal_stdout(stdout)
    evaluation = evaluate(document)
    write_outputs(Path(args.output_dir), document, evaluation)
    print(json.dumps({"trial_id": TRIAL_ID, "candidate_id": CANDIDATE_ID, **evaluation}, ensure_ascii=False, sort_keys=True))
    print("US_TURN_MONTH_001_FORMAL_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
