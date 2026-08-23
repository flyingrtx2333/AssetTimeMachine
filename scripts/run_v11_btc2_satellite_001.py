#!/usr/bin/env python3
"""Run the preregistered frozen-V11 + fixed 2% Bitcoin satellite strategy."""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP3-V11-BTC2-SATELLITE-001"
CANDIDATE_ID = "S-V11-BTC2-SATELLITE-001"
FRAGMENT = ROOT / "tools/v11_btc2_satellite_001.swiftpart"
LOGIC = ROOT / "tools/v11_btc2_satellite_001_logic.swift"
ASSEMBLED = Path("/private/tmp/atm_v11_btc2_satellite_001.swift")
BINARY = Path("/private/tmp/atm_v11_btc2_satellite_001")


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
    ])


def validate_document(document: dict) -> None:
    if document.get("trial_id") != TRIAL_ID or document.get("candidate_id") != CANDIDATE_ID:
        raise RuntimeError("formal identity mismatch")
    if document.get("evaluation_start") != "2017-08-17" or document.get("evaluation_end") != "2026-08-20":
        raise RuntimeError("evaluation window drifted")
    if abs(float(document.get("btc_weight", -1)) - 0.02) > 1e-12:
        raise RuntimeError("BTC weight drifted")
    if abs(float(document.get("core_scale", -1)) - 0.98) > 1e-12:
        raise RuntimeError("V11 core scale drifted")
    if document.get("source_v11_mode") != "nfciDualCoreSimplifiedV11":
        raise RuntimeError("V11 source mode drifted")
    if int(document.get("source_event_count", 0)) <= 0:
        raise RuntimeError("V11 source event count missing")
    if abs(float(document.get("fee_percent_per_trade", -1)) - 1.0) > 1e-12:
        raise RuntimeError("fee drifted")
    if abs(float(document.get("slippage_percent_per_trade", -1)) - 0.05) > 1e-12:
        raise RuntimeError("slippage drifted")


def evaluate(document: dict) -> dict:
    candidate = document["candidate"]
    control = document["v11_matched_control"]
    folds = candidate.get("folds") or []
    positive_folds = sum(float(row.get("sharpe", 0)) > 0 for row in folds)
    fold_fraction = positive_folds / len(folds) if folds else 0.0

    validation_checks = {
        "actual_trades_gt_0": int(candidate["trades"]) > 0,
        "full_cagr_gt_0": float(candidate["cagr_percent"]) > 0,
        "full_sharpe_gt_0": float(candidate["sharpe"]) > 0,
        "full_mdd_le_25pct": float(candidate["mdd_percent"]) <= 25.0,
        "positive_sharpe_folds_ge_70pct": fold_fraction >= 0.70,
        "max_target_gross_le_1": float(candidate["max_target_gross"]) <= 1.000000001,
        "max_realized_gross_le_1": float(candidate["max_gross"]) <= 1.000000001,
        "cash_nonnegative": float(candidate["minimum_cash"]) >= -1e-8,
    }
    objective_checks = {
        "cagr_ge_16pct": float(candidate["cagr_percent"]) >= 16.0,
        "sharpe_ge_1_45": float(candidate["sharpe"]) >= 1.45,
        "mdd_le_10pct": float(candidate["mdd_percent"]) <= 10.0,
        "since2020_cagr_positive": float(candidate["since2020_cagr_percent"]) > 0,
        "since2022_cagr_positive": float(candidate["since2022_cagr_percent"]) > 0,
    }
    comparison_checks = {
        "cagr_gt_matched_v11": float(candidate["cagr_percent"]) > float(control["cagr_percent"]),
        "sharpe_ge_matched_v11": float(candidate["sharpe"]) >= float(control["sharpe"]),
        "mdd_le_matched_v11": float(candidate["mdd_percent"]) <= float(control["mdd_percent"]),
    }
    validation_status = "PASS" if all(validation_checks.values()) else "FAIL"
    objective_status = "PASS" if all(objective_checks.values()) else "FAIL"
    comparison_status = "PASS" if all(comparison_checks.values()) else "FAIL"
    return {
        "status": validation_status,
        "validation_status": validation_status,
        "objective_status": objective_status,
        "comparison_status": comparison_status,
        "validation_checks": validation_checks,
        "objective_checks": objective_checks,
        "comparison_checks": comparison_checks,
        "validation_warnings": [
            "BTCUSDT quote is treated as USD-equivalent before historical USD/CNY conversion",
            "BTC is re-targeted only on frozen V11 source events; no BTC-driven rebalance dates",
            "base run already uses 1.00% fee plus 0.05% slippage",
        ],
        "diagnostics": {
            "positive_fold_count": positive_folds,
            "fold_count": len(folds),
            "positive_fold_fraction": fold_fraction,
            "matched_v11_cagr_percent": float(control["cagr_percent"]),
            "matched_v11_sharpe": float(control["sharpe"]),
            "matched_v11_mdd_percent": float(control["mdd_percent"]),
            "candidate_minus_v11_cagr_pp": float(candidate["cagr_percent"]) - float(control["cagr_percent"]),
            "candidate_minus_v11_sharpe": float(candidate["sharpe"]) - float(control["sharpe"]),
            "candidate_minus_v11_mdd_pp": float(candidate["mdd_percent"]) - float(control["mdd_percent"]),
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
            "trades", "average_cash_ratio", "max_gross", "minimum_cash", "max_target_gross",
            "target_fingerprint", "v11_role_fingerprint",
        ]
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for kind, row in [
            ("CANDIDATE", document["candidate"]),
            ("MATCHED_V11_CONTROL", document["v11_matched_control"]),
        ]:
            writer.writerow({"kind": kind, **{key: row.get(key) for key in fields if key != "kind"}})


def parse_formal_stdout(stdout: str) -> dict:
    prefix = "V11_BTC2_SATELLITE_001_FORMAL_JSON="
    lines = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
    if len(lines) != 1 or "V11_BTC2_SATELLITE_001_FORMAL_OK" not in stdout:
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
    if args.formal and not args.output_dir:
        raise SystemExit("--formal requires --output-dir")

    compile_binary()
    env = os.environ.copy()
    env.update({"ATM_HISTORY_FIXTURE": args.fixture, "ATM_V11_BTC2_SATELLITE_001": "1"})
    if args.formal:
        env["ATM_V11_BTC2_SATELLITE_001_FORMAL"] = "1"
        env["ATM_V11_BTC2_SATELLITE_001_OUTPUT_DIR"] = args.output_dir
    stdout = run([str(BINARY)], env=env)
    if not args.formal:
        if "V11_BTC2_SATELLITE_001_SMOKE_OK" not in stdout:
            print(stdout, end="")
            raise RuntimeError("Swift smoke output incomplete")
        print(stdout, end="")
        return 0

    document = parse_formal_stdout(stdout)
    evaluation = evaluate(document)
    write_outputs(Path(args.output_dir), document, evaluation)
    print(json.dumps({"trial_id": TRIAL_ID, "candidate_id": CANDIDATE_ID, **evaluation}, ensure_ascii=False, sort_keys=True))
    print("V11_BTC2_SATELLITE_001_FORMAL_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
