#!/usr/bin/env python3
"""Run the preregistered 日K高速005 trial through the shared Swift research engine."""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP2-DAYK-HS-005"
CANDIDATE_ID = "S-DAYK-HIGH-SPEED-005"
FRAGMENT = ROOT / "tools/dayk_high_speed_005.swiftpart"
LOGIC = ROOT / "tools/dayk_high_speed_005_logic.swift"
ASSEMBLED = Path("/private/tmp/atm_dayk_high_speed_005.swift")
BINARY = Path("/private/tmp/atm_dayk_high_speed_005")


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
    expected_candidates = {"DKHS005-GOLD", "DKHS005-NASDAQ", "DKHS005-SP500", "DKHS005-COMBINED"}
    expected_controls = {"C-BASE-PULLBACK-GOLD", "C-BASE-PULLBACK-NASDAQ", "C-BASE-PULLBACK-SP500", "C-BASE-PULLBACK-COMBINED"}
    candidate_ids = {row.get("id") for row in document.get("candidate_paths", [])}
    control_ids = {row.get("id") for row in document.get("matched_control_paths", [])}
    if candidate_ids != expected_candidates:
        raise RuntimeError(f"candidate path mismatch: {sorted(candidate_ids)}")
    if control_ids != expected_controls:
        raise RuntimeError(f"control path mismatch: {sorted(control_ids)}")
    if document.get("evaluation_start") != "2017-04-11" or document.get("evaluation_end") != "2026-08-20":
        raise RuntimeError("evaluation window drifted")
    if abs(float(document.get("fee_rate_per_fill", -1)) - 0.00005) > 1e-12:
        raise RuntimeError("fee rate drifted")
    if abs(float(document.get("primary_slippage_rate_per_fill", -1))) > 1e-12:
        raise RuntimeError("primary slippage rate drifted")
    if abs(float(document.get("stress_slippage_rate_per_fill", -1)) - 0.0005) > 1e-12:
        raise RuntimeError("stress slippage rate drifted")
    vote_counts = document.get("factor_vote_counts")
    if not isinstance(vote_counts, dict) or set(vote_counts) != {"gold_cny", "nasdaq", "sp500"}:
        raise RuntimeError("factor vote audit missing")


def evaluate(document: dict) -> dict:
    combined = path_by_id(document, "candidate_paths", "DKHS005-COMBINED")
    matched = path_by_id(document, "matched_control_paths", "C-BASE-PULLBACK-COMBINED")
    cash = document["cash_control"]
    stress = document["slippage_stress"]
    standalone = [
        path_by_id(document, "candidate_paths", "DKHS005-GOLD"),
        path_by_id(document, "candidate_paths", "DKHS005-NASDAQ"),
        path_by_id(document, "candidate_paths", "DKHS005-SP500"),
    ]
    fold_sharpes = [float(row["sharpe"]) for row in combined["folds"]]
    if len(fold_sharpes) != 5:
        raise RuntimeError("combined path must contain five fixed folds")
    cash_cagr = float(cash["cagr_percent"])
    profitable_assets = sum(float(row["cagr_percent"]) > cash_cagr for row in standalone)
    positive_sharpe_assets = sum(float(row["sharpe"]) > 0 for row in standalone)
    minimum_asset_trades = min(int(row["trade_stats"]["round_trips"]) for row in standalone)
    positive_folds = sum(value > 0 for value in fold_sharpes)
    trade_stats = combined["trade_stats"]
    invariant_checks = {
        "max_gross_le_100pct": float(combined["max_gross"]) <= 1.000000001,
        "minimum_end_of_day_cash_nonnegative": float(combined["minimum_end_of_day_cash"]) >= -1e-8,
        "minimum_holding_sessions_ge_2": int(combined["minimum_holding_sessions"]) >= 2,
        "maximum_holding_sessions_le_5": int(combined["maximum_holding_sessions"]) <= 5,
        "zero_final_open_positions": int(combined["final_open_positions"]) == 0,
    }
    checks = {
        "at_least_two_assets_outperform_cash": profitable_assets >= 2,
        "at_least_two_assets_positive_sharpe": positive_sharpe_assets >= 2,
        "each_asset_at_least_75_round_trips": minimum_asset_trades >= 75,
        "combined_cagr_ge_cash_plus_2pp": float(combined["cagr_percent"]) >= cash_cagr + 2.0,
        "combined_sharpe_ge_1": float(combined["sharpe"]) >= 1.0,
        "combined_mdd_le_12pct": float(combined["mdd_percent"]) <= 12.0,
        "combined_sharpe_gt_matched_base_pullback_control": float(combined["sharpe"]) > float(matched["sharpe"]),
        "combined_average_trade_return_positive": float(trade_stats["average_return_percent"]) > 0,
        "combined_profit_factor_ge_1_10": float(trade_stats["profit_factor"]) >= 1.10,
        "at_least_four_of_five_positive_sharpe_folds": positive_folds >= 4,
        "since2020_cagr_gt_cash_full_cagr": float(combined["since2020_cagr_percent"]) > cash_cagr,
        "since2022_cagr_gt_cash_full_cagr": float(combined["since2022_cagr_percent"]) > cash_cagr,
        "slippage_stress_cagr_gt_cash": float(stress["cagr_percent"]) > cash_cagr,
        "slippage_stress_sharpe_gt_0_5": float(stress["sharpe"]) > 0.5,
        **invariant_checks,
    }
    return {
        "pass": all(checks.values()),
        "checks": checks,
        "diagnostics": {
            "cash_cagr_percent": cash_cagr,
            "profitable_asset_count": profitable_assets,
            "positive_sharpe_asset_count": positive_sharpe_assets,
            "minimum_asset_round_trips": minimum_asset_trades,
            "positive_sharpe_fold_count": positive_folds,
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
            "round_trips", "win_rate_percent", "average_return_percent", "profit_factor",
            "max_gross", "average_holding_sessions", "maximum_holding_sessions",
            "position_nights", "final_open_positions", "target_fingerprint",
        ]
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        rows: list[tuple[str, dict]] = []
        rows.extend(("CANDIDATE", row) for row in document["candidate_paths"])
        rows.extend(("MATCHED_CONTROL", row) for row in document["matched_control_paths"])
        rows.append(("CASH_CONTROL", document["cash_control"]))
        rows.append(("SLIPPAGE_STRESS", document["slippage_stress"]))
        for kind, row in rows:
            stats = row["trade_stats"]
            writer.writerow({
                "id": row["id"], "kind": kind,
                "cagr_percent": row["cagr_percent"], "mdd_percent": row["mdd_percent"],
                "volatility_percent": row["volatility_percent"], "sharpe": row["sharpe"],
                "round_trips": stats["round_trips"], "win_rate_percent": stats["win_rate_percent"],
                "average_return_percent": stats["average_return_percent"], "profit_factor": stats["profit_factor"],
                "max_gross": row["max_gross"],
                "average_holding_sessions": row["average_holding_sessions"],
                "maximum_holding_sessions": row["maximum_holding_sessions"],
                "position_nights": row["position_nights"],
                "final_open_positions": row["final_open_positions"],
                "target_fingerprint": row["target_fingerprint"],
            })


def parse_formal_stdout(stdout: str) -> dict:
    prefix = "DAYK_HIGH_SPEED_005_FORMAL_JSON="
    lines = [line[len(prefix):] for line in stdout.splitlines() if line.startswith(prefix)]
    if len(lines) != 1 or "DAYK_HIGH_SPEED_005_FORMAL_OK" not in stdout:
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
        "ATM_DAYK_HIGH_SPEED_005": "1",
    })
    if args.formal:
        env["ATM_DAYK_HIGH_SPEED_005_FORMAL"] = "1"
        env["ATM_DAYK_HIGH_SPEED_005_OUTPUT_DIR"] = str(Path(args.output_dir))
    stdout = run([str(BINARY)], env=env)
    if not args.formal:
        if "DAYK_HIGH_SPEED_005_SMOKE_OK" not in stdout:
            raise RuntimeError("Swift smoke output incomplete")
        print(stdout, end="")
        return 0

    document = parse_formal_stdout(stdout)
    evaluation = evaluate(document)
    write_outputs(Path(args.output_dir), document, evaluation)
    print(json.dumps({"trial_id": TRIAL_ID, "candidate_id": CANDIDATE_ID, **evaluation}, ensure_ascii=False, sort_keys=True))
    print("DAYK_HIGH_SPEED_005_FORMAL_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
