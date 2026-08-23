#!/usr/bin/env python3
"""Run the preregistered unconditional U.S. overnight close-to-open strategy."""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP3-US-OVERNIGHT-001"
CANDIDATE_ID = "S-US-OVERNIGHT-001"
FRAGMENT = ROOT / "tools/us_overnight_001.swiftpart"
LOGIC = ROOT / "tools/us_overnight_001_logic.swift"
ASSEMBLED = Path("/private/tmp/atm_us_overnight_001.swift")
BINARY = Path("/private/tmp/atm_us_overnight_001")


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 360) -> str:
    completed = subprocess.run(
        command, cwd=ROOT, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=timeout, check=False,
    )
    if completed.returncode != 0:
        sys.stderr.write(completed.stdout[-16000:])
        raise RuntimeError(f"command failed ({completed.returncode}): {' '.join(command)}")
    return completed.stdout


def compile_binary() -> None:
    run([sys.executable, "scripts/assemble_strategy_metric_dump.py", "--fragment", str(FRAGMENT.relative_to(ROOT)), "--output", str(ASSEMBLED)])
    run([
        "xcrun", "swiftc", "-parse-as-library",
        "-module-cache-path", "/private/tmp/atm-swift-module-cache",
        "AssetTimeMachine/Backtest/BacktestModels.swift",
        "AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift",
        "AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift",
        "AssetTimeMachine/Backtest/BacktestFXConverter.swift",
        "AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift",
        "AssetTimeMachine/Backtest/BacktestEngine.swift",
        str(LOGIC.relative_to(ROOT)), str(ASSEMBLED), "-o", str(BINARY),
    ])


def path_by_id(document: dict, section: str, path_id: str) -> dict:
    rows = document.get(section)
    if not isinstance(rows, list):
        raise RuntimeError(f"missing path section: {section}")
    matches = [row for row in rows if row.get("id") == path_id]
    if len(matches) != 1:
        raise RuntimeError(f"expected one {path_id} in {section}, got {len(matches)}")
    return matches[0]


def validate_document(document: dict) -> None:
    if document.get("trial_id") != TRIAL_ID or document.get("candidate_id") != CANDIDATE_ID:
        raise RuntimeError("formal identity mismatch")
    if document.get("evaluation_start") != "2000-01-04" or document.get("evaluation_end") != "2026-08-20":
        raise RuntimeError("evaluation window drifted")
    if abs(float(document.get("fee_rate_per_fill", -1)) - 0.00005) > 1e-12:
        raise RuntimeError("fee rate drifted")
    if abs(float(document.get("stress_slippage_rate_per_fill", -1)) - 0.0005) > 1e-12:
        raise RuntimeError("stress slippage drifted")
    if "prior-close CNY value" not in str(document.get("fx_alignment")):
        raise RuntimeError("FX alignment assertion missing")
    if {row.get("id") for row in document.get("candidate_paths", [])} != {"USOVN001-NASDAQ", "USOVN001-SP500", "USOVN001-COMBINED"}:
        raise RuntimeError("candidate path mismatch")
    if {row.get("id") for row in document.get("daytime_control_paths", [])} != {"C-DAYTIME-NASDAQ", "C-DAYTIME-SP500", "C-DAYTIME-COMBINED"}:
        raise RuntimeError("daytime control path mismatch")


def evaluate(document: dict) -> dict:
    combined = path_by_id(document, "candidate_paths", "USOVN001-COMBINED")
    nasdaq = path_by_id(document, "candidate_paths", "USOVN001-NASDAQ")
    sp500 = path_by_id(document, "candidate_paths", "USOVN001-SP500")
    daytime = path_by_id(document, "daytime_control_paths", "C-DAYTIME-COMBINED")
    stress = document["slippage_stress"]
    folds = combined.get("folds") or []
    positive_folds = sum(float(row.get("sharpe", 0)) > 0 for row in folds)
    fold_fraction = positive_folds / len(folds) if folds else 0.0
    stats = combined["trade_stats"]
    sentinel_hits = sum(int(v) for v in (combined.get("take_profit_hits_by_symbol") or {}).values())
    validation_checks = {
        "actual_round_trips_gt_0": int(stats["round_trips"]) > 0,
        "sentinel_take_profit_hits_eq_0": sentinel_hits == 0,
        "full_cagr_gt_0": float(combined["cagr_percent"]) > 0,
        "full_sharpe_gt_0": float(combined["sharpe"]) > 0,
        "full_mdd_le_25pct": float(combined["mdd_percent"]) <= 25.0,
        "positive_sharpe_folds_ge_70pct": fold_fraction >= 0.70,
        "stress_cagr_gt_0": float(stress["cagr_percent"]) > 0,
        "stress_sharpe_gt_0": float(stress["sharpe"]) > 0,
        "stress_mdd_le_2x_base": float(stress["mdd_percent"]) <= 2.0 * float(combined["mdd_percent"]) + 1e-9,
        "max_gross_le_1": float(combined["max_session_gross"]) <= 1.000000001,
        "cash_nonnegative": float(combined["minimum_end_of_session_cash"]) >= -1e-8,
    }
    objective_checks = {
        "combined_cagr_ge_8pct": float(combined["cagr_percent"]) >= 8.0,
        "combined_sharpe_ge_1": float(combined["sharpe"]) >= 1.0,
        "combined_mdd_le_15pct": float(combined["mdd_percent"]) <= 15.0,
        "both_us_paths_positive_sharpe": float(nasdaq["sharpe"]) > 0 and float(sp500["sharpe"]) > 0,
        "profit_factor_ge_1_05": float(stats["profit_factor"]) >= 1.05,
        "average_trade_return_positive": float(stats["average_return_percent"]) > 0,
        "since2020_cagr_positive": float(combined["since2020_cagr_percent"]) > 0,
        "since2022_cagr_positive": float(combined["since2022_cagr_percent"]) > 0,
    }
    comparison_checks = {
        "overnight_cagr_gt_daytime": float(combined["cagr_percent"]) > float(daytime["cagr_percent"]),
        "overnight_sharpe_gt_daytime": float(combined["sharpe"]) > float(daytime["sharpe"]),
        "overnight_mdd_le_daytime": float(combined["mdd_percent"]) <= float(daytime["mdd_percent"]),
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
            "daytime_cagr_percent": float(daytime["cagr_percent"]),
            "daytime_sharpe": float(daytime["sharpe"]),
            "daytime_mdd_percent": float(daytime["mdd_percent"]),
        },
    }


def write_outputs(output_dir: Path, document: dict, evaluation: dict) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    payload = {**document, "three_axis_evaluation": evaluation}
    (output_dir / "candidate-metrics.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    with (output_dir / "candidate-metrics.csv").open("w", encoding="utf-8", newline="") as handle:
        fields = ["id", "kind", "cagr_percent", "mdd_percent", "volatility_percent", "sharpe", "round_trips", "win_rate_percent", "average_return_percent", "profit_factor", "active_sessions", "max_session_gross", "target_fingerprint"]
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        rows: list[tuple[str, dict]] = []
        rows.extend(("CANDIDATE_OVERNIGHT", row) for row in document["candidate_paths"])
        rows.extend(("DAYTIME_CONTROL", row) for row in document["daytime_control_paths"])
        rows.append(("CASH_CONTROL", document["cash_control"]))
        rows.append(("SLIPPAGE_STRESS", document["slippage_stress"]))
        for kind, row in rows:
            stats = row["trade_stats"]
            writer.writerow({
                "id": row["id"], "kind": kind, "cagr_percent": row["cagr_percent"], "mdd_percent": row["mdd_percent"],
                "volatility_percent": row["volatility_percent"], "sharpe": row["sharpe"], "round_trips": stats["round_trips"],
                "win_rate_percent": stats["win_rate_percent"], "average_return_percent": stats["average_return_percent"],
                "profit_factor": stats["profit_factor"], "active_sessions": row.get("active_sessions", 0),
                "max_session_gross": row["max_session_gross"], "target_fingerprint": row["target_fingerprint"],
            })


def parse_formal_stdout(stdout: str) -> dict:
    prefix = "US_OVERNIGHT_001_FORMAL_JSON="
    lines = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
    if len(lines) != 1 or "US_OVERNIGHT_001_FORMAL_OK" not in stdout:
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
    env.update({"ATM_HISTORY_FIXTURE": str(fixture), "ATM_US_OVERNIGHT_001": "1"})
    if args.formal:
        env["ATM_US_OVERNIGHT_001_FORMAL"] = "1"
        env["ATM_US_OVERNIGHT_001_OUTPUT_DIR"] = str(Path(args.output_dir))
    stdout = run([str(BINARY)], env=env)
    if not args.formal:
        if "US_OVERNIGHT_001_SMOKE_OK" not in stdout:
            print(stdout, end="")
            raise RuntimeError("Swift smoke output incomplete")
        print(stdout, end="")
        return 0
    document = parse_formal_stdout(stdout)
    evaluation = evaluate(document)
    write_outputs(Path(args.output_dir), document, evaluation)
    print(json.dumps({"trial_id": TRIAL_ID, "candidate_id": CANDIDATE_ID, **evaluation}, ensure_ascii=False, sort_keys=True))
    print("US_OVERNIGHT_001_FORMAL_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
