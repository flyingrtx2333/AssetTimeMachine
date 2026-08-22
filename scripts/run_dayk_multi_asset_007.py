#!/usr/bin/env python3
"""Run the preregistered 日K多资产007 trial through the shared Swift engine."""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP2-DAYK-MA-007"
CANDIDATE_ID = "S-DAYK-MULTI-ASSET-007"
FRAGMENT = ROOT / "tools/dayk_multi_asset_007.swiftpart"
LOGIC = ROOT / "tools/dayk_multi_asset_007_logic.swift"
ASSEMBLED = Path("/private/tmp/atm_dayk_multi_asset_007.swift")
BINARY = Path("/private/tmp/atm_dayk_multi_asset_007")


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
        str(LOGIC.relative_to(ROOT)),
        str(ASSEMBLED),
        "-o", str(BINARY),
    ], timeout=360)


def validate_document(document: dict) -> None:
    if document.get("trial_id") != TRIAL_ID or document.get("candidate_id") != CANDIDATE_ID:
        raise RuntimeError("formal identity mismatch")
    expected = {
        "candidate": "DKMA007-RISK-BALANCED",
        "matched_control": "C-DKMA007-EQUAL-ELIGIBLE",
        "v11_control": "V11-CONTROL",
        "cash_control": "C-CASH-COMBINED",
        "slippage_stress": "DKMA007-RISK-BALANCED-SLIP005",
    }
    for section, path_id in expected.items():
        if document.get(section, {}).get("id") != path_id:
            raise RuntimeError(f"{section} identity mismatch")
    if document.get("evaluation_start") != "2012-07-05" or document.get("evaluation_end") != "2026-08-20":
        raise RuntimeError("evaluation window drifted")
    if abs(float(document.get("fee_rate_per_fill", -1)) - 0.00005) > 1e-12:
        raise RuntimeError("fee rate drifted")
    if abs(float(document.get("primary_slippage_rate_per_fill", -1))) > 1e-12:
        raise RuntimeError("primary slippage drifted")
    if abs(float(document.get("stress_slippage_rate_per_fill", -1)) - 0.0005) > 1e-12:
        raise RuntimeError("stress slippage drifted")


def evaluate(document: dict) -> dict:
    candidate = document["candidate"]
    matched = document["matched_control"]
    v11 = document["v11_control"]
    cash = document["cash_control"]
    stress = document["slippage_stress"]
    folds = candidate["folds"]
    if len(folds) != 7:
        raise RuntimeError("candidate must contain seven fixed folds")
    positive_folds = sum(float(row["sharpe"]) > 0 for row in folds)
    folds_above_one = sum(float(row["sharpe"]) > 1 for row in folds)
    cash_cagr = float(cash["cagr_percent"])
    checks = {
        "candidate_cagr_ge_v11_same_cost": float(candidate["cagr_percent"]) >= float(v11["cagr_percent"]),
        "candidate_sharpe_ge_v11_same_cost": float(candidate["sharpe"]) >= float(v11["sharpe"]),
        "candidate_mdd_le_v11_same_cost": float(candidate["mdd_percent"]) <= float(v11["mdd_percent"]),
        "candidate_sharpe_gt_matched_equal_weight": float(candidate["sharpe"]) > float(matched["sharpe"]),
        "candidate_cagr_ge_cash_plus_5pp": float(candidate["cagr_percent"]) >= cash_cagr + 5.0,
        "candidate_sharpe_ge_1": float(candidate["sharpe"]) >= 1.0,
        "candidate_mdd_le_15pct": float(candidate["mdd_percent"]) <= 15.0,
        "at_least_six_of_seven_positive_sharpe_folds": positive_folds >= 6,
        "at_least_four_of_seven_folds_sharpe_gt_1": folds_above_one >= 4,
        "since2020_cagr_gt_cash": float(candidate["since2020_cagr_percent"]) > cash_cagr,
        "since2022_cagr_gt_cash": float(candidate["since2022_cagr_percent"]) > cash_cagr,
        "stress_cagr_ge_cash_plus_3pp": float(stress["cagr_percent"]) >= cash_cagr + 3.0,
        "stress_sharpe_gt_0_75": float(stress["sharpe"]) > 0.75,
        "target_change_count_between_20_and_200": 20 <= int(candidate["target_change_count"]) <= 200,
        "executed_trade_count_le_500": int(candidate["trades"]) <= 500,
        "max_gross_le_100pct": float(candidate["max_gross"]) <= 1.000000001,
        "minimum_target_weight_nonnegative": float(candidate["minimum_target_weight"]) >= -1e-10,
        "maximum_asset_weight_le_50pct": float(candidate["maximum_asset_weight"]) <= 0.500000001,
        "minimum_cash_nonnegative": float(candidate["minimum_cash"]) >= -1e-8,
        "zero_us_role_violations": int(candidate["us_role_violation_sessions"]) == 0,
        "zero_china_role_violations": int(candidate["china_role_violation_sessions"]) == 0,
    }
    return {
        "pass": all(checks.values()),
        "checks": checks,
        "diagnostics": {
            "cash_cagr_percent": cash_cagr,
            "positive_sharpe_fold_count": positive_folds,
            "folds_sharpe_gt_1_count": folds_above_one,
            "candidate_minus_v11_cagr_pp": float(candidate["cagr_percent"]) - float(v11["cagr_percent"]),
            "candidate_minus_v11_sharpe": float(candidate["sharpe"]) - float(v11["sharpe"]),
        },
    }


def write_outputs(output_dir: Path, document: dict, evaluation: dict) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    payload = {**document, "preregistered_gate_evaluation": evaluation}
    (output_dir / "candidate-metrics.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    with (output_dir / "candidate-metrics.csv").open("w", encoding="utf-8", newline="") as handle:
        fields = [
            "id", "kind", "cagr_percent", "mdd_percent", "volatility_percent", "sharpe",
            "trades", "average_cash_ratio", "max_gross", "maximum_asset_weight",
            "target_change_count", "target_fingerprint",
        ]
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for kind, key in [
            ("CANDIDATE", "candidate"),
            ("MATCHED_CONTROL", "matched_control"),
            ("V11_CONTROL", "v11_control"),
            ("CASH_CONTROL", "cash_control"),
            ("SLIPPAGE_STRESS", "slippage_stress"),
        ]:
            row = document[key]
            writer.writerow({field: row.get(field, "") for field in fields} | {"kind": kind})


def parse_formal_stdout(stdout: str) -> dict:
    prefix = "DAYK_MULTI_ASSET_007_FORMAL_JSON="
    lines = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
    if len(lines) != 1 or "DAYK_MULTI_ASSET_007_FORMAL_OK" not in stdout:
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
    env.update({
        "ATM_HISTORY_FIXTURE": str(fixture),
        "ATM_DAYK_MULTI_ASSET_007": "1",
    })
    if args.formal:
        env["ATM_DAYK_MULTI_ASSET_007_FORMAL"] = "1"
        env["ATM_DAYK_MULTI_ASSET_007_OUTPUT_DIR"] = str(Path(args.output_dir))
    stdout = run([str(BINARY)], env=env)
    if not args.formal:
        if "DAYK_MULTI_ASSET_007_SMOKE_OK" not in stdout:
            raise RuntimeError("Swift smoke output incomplete")
        print(stdout, end="")
        return 0

    document = parse_formal_stdout(stdout)
    evaluation = evaluate(document)
    write_outputs(Path(args.output_dir), document, evaluation)
    print(json.dumps({"trial_id": TRIAL_ID, "candidate_id": CANDIDATE_ID, **evaluation}, ensure_ascii=False, sort_keys=True))
    print("DAYK_MULTI_ASSET_007_FORMAL_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
