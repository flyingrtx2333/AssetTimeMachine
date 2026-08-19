#!/usr/bin/env python3
"""ATM-SVP-1 G5 final component: fixed +1 common-session execution delay.

The Swift fragment first computes the frozen V11 source path with the exact App engine. It then
replays the source rebalance events through BacktestEngine.runResearchTargetProviderStrategyWithTrace,
which uses the same BacktestDailySimulator. Development mode runs only delay=0 to validate replay
equivalence. Formal mode additionally runs the already-frozen 1.50% fee + 0.10% slippage +1 session
delay case. Python only orchestrates compilation, parses Swift outputs and applies preregistered
checks; it never simulates the strategy or portfolio.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FRAGMENT = ROOT / "tools/v11_execution_delay_stress.swiftpart"
FIXTURE = ROOT / "tools/fixtures/backtest-history/generalization_public_history.json"
PRIOR_RESULT = ROOT / "tools/research-results/strategy-validation/results/ATM-SVP1-G5-EXEC-COST-001.json"
ASSEMBLED = Path("/private/tmp/atm_v11_execution_delay_stress.swift")
BINARY = Path("/private/tmp/atm_v11_execution_delay_stress")
CONTROL_ID = "adverse_cost_replay_delay0"
DELAY_ID = "adverse_cost_plus_delay1"
SOURCE_TARGET_FINGERPRINT = "ba67c8aa24bc7168"


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 300) -> str:
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
        "--fragment",
        str(FRAGMENT.relative_to(ROOT)),
        "--output",
        str(ASSEMBLED),
    ])
    run([
        "xcrun",
        "swiftc",
        "-parse-as-library",
        "-module-cache-path",
        "/private/tmp/atm-swift-module-cache",
        "AssetTimeMachine/Backtest/BacktestModels.swift",
        "AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift",
        "AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift",
        "AssetTimeMachine/Backtest/BacktestFXConverter.swift",
        "AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift",
        "AssetTimeMachine/Backtest/BacktestEngine.swift",
        str(ASSEMBLED),
        "-o",
        str(BINARY),
    ], timeout=300)


def parse_candidate_blocks(stdout: str) -> tuple[str, dict[str, dict]]:
    source_match = re.search(r"^source_target_fingerprint=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    if not source_match:
        raise RuntimeError("missing source_target_fingerprint")
    candidates: dict[str, dict] = {}
    for block in stdout.split("candidate_id=")[1:]:
        text, _, _ = block.partition("END_CANDIDATE")
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        candidate_id = lines[0]
        values: dict[str, str] = {}
        for line in lines[1:]:
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key] = value
        required = {
            "cagr", "mdd", "vol", "sharpe", "trades", "daily_state_fingerprint",
            "source_trade_count", "scheduled_shift_count",
        }
        missing = required - set(values)
        if missing:
            raise RuntimeError(f"candidate={candidate_id} missing {sorted(missing)}")
        candidates[candidate_id] = {
            "candidate_id": candidate_id,
            "metrics": {
                "cagr_percent": float(values["cagr"]),
                "mdd_percent": float(values["mdd"]),
                "vol_percent": float(values["vol"]),
                "sharpe": float(values["sharpe"]),
                "trades": int(values["trades"]),
            },
            "daily_state_fingerprint": values["daily_state_fingerprint"],
            "source_trade_count": int(values["source_trade_count"]),
            "scheduled_shift_count": int(values["scheduled_shift_count"]),
            "first_shift": values.get("first_shift"),
            "last_shift": values.get("last_shift"),
        }
    return source_match.group(1), candidates


def read_schedule(path: Path) -> list[tuple[str, str, int]]:
    rows: list[tuple[str, str, int]] = []
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            rows.append((
                row["source_execution_date"],
                row["stressed_execution_date"],
                int(row["configured_delay_sessions"]),
            ))
    if not rows:
        raise RuntimeError(f"empty shift schedule: {path}")
    return rows


def prior_adverse_metrics() -> dict:
    doc = json.loads(PRIOR_RESULT.read_text(encoding="utf-8"))
    for row in doc["candidate_results"]:
        if row["candidate_id"] == "adverse_cost":
            return row["metrics"]
    raise RuntimeError("prior G5 adverse_cost metrics missing")


def close(a: float, b: float, tolerance: float) -> bool:
    return math.isclose(a, b, rel_tol=0.0, abs_tol=tolerance)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--formal", action="store_true")
    args = parser.parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    control_portfolio = output_dir / f"{CONTROL_ID}-portfolio.csv"
    control_schedule = output_dir / f"{CONTROL_ID}-schedule.csv"
    delayed_portfolio = output_dir / f"{DELAY_ID}-portfolio.csv"
    delayed_schedule = output_dir / f"{DELAY_ID}-schedule.csv"

    compile_binary()
    env = os.environ.copy()
    env.update({
        "ATM_HISTORY_FIXTURE": str(FIXTURE.relative_to(ROOT)),
        "ATM_V11_EXECUTION_DELAY_STRESS": "1",
        "ATM_V11_DELAY_CONTROL_OUTPUT": str(control_portfolio),
        "ATM_V11_DELAY_CONTROL_SCHEDULE": str(control_schedule),
    })
    if args.formal:
        env.update({
            "ATM_V11_DELAY_FORMAL": "1",
            "ATM_V11_DELAY_FORMAL_OUTPUT": str(delayed_portfolio),
            "ATM_V11_DELAY_FORMAL_SCHEDULE": str(delayed_schedule),
        })
    stdout = run([str(BINARY)], env=env, timeout=300)
    source_fingerprint, candidates = parse_candidate_blocks(stdout)
    if CONTROL_ID not in candidates:
        raise RuntimeError("control candidate missing")
    if args.formal and DELAY_ID not in candidates:
        raise RuntimeError("formal delay candidate missing")
    if not args.formal and DELAY_ID in candidates:
        raise RuntimeError("development run unexpectedly exposed formal delay result")

    prior = prior_adverse_metrics()
    control = candidates[CONTROL_ID]
    control_metrics = control["metrics"]
    control_checks = {
        "source_target_fingerprint_matches_frozen_v11": source_fingerprint == SOURCE_TARGET_FINGERPRINT,
        "control_cagr_matches_g5_001_within_0_01pp": close(control_metrics["cagr_percent"], prior["cagr_percent"], 0.01),
        "control_mdd_matches_g5_001_within_0_01pp": close(control_metrics["mdd_percent"], prior["mdd_percent"], 0.01),
        "control_sharpe_matches_g5_001_within_0_001": close(control_metrics["sharpe"], prior["sharpe"], 0.001),
        "control_trade_records_match_g5_001": control_metrics["trades"] == int(prior["trades"]),
    }
    control_mapping = read_schedule(control_schedule)
    control_checks["delay0_schedule_is_identity"] = all(source == execution for source, execution, _ in control_mapping)
    control_checks["delay0_schedule_declares_zero_sessions"] = all(delay == 0 for _, _, delay in control_mapping)
    control_checks["scheduled_event_count_matches_control"] = len(control_mapping) == control["scheduled_shift_count"]
    control_pass = all(control_checks.values())

    document: dict = {
        "protocol_id": "ATM-SVP-1",
        "component": "G5_EXECUTION_DELAY",
        "formal": args.formal,
        "source_target_fingerprint": source_fingerprint,
        "control_reference_trial": "ATM-SVP1-G5-EXEC-COST-001",
        "control_checks": control_checks,
        "candidate_results": [control],
        "control_status": "PASS" if control_pass else "FAIL",
        "full_g5_status": "PENDING_FORMAL_DELAY" if not args.formal else "UNDECIDED",
    }

    exit_code = 0 if control_pass else 2
    if args.formal:
        delayed = candidates[DELAY_ID]
        delayed_metrics = delayed["metrics"]
        delayed_mapping = read_schedule(delayed_schedule)
        base_mdd_percent = 7.689054
        delay_checks = {
            "control_equivalence_pass": control_pass,
            "source_target_fingerprint_matches_frozen_v11": source_fingerprint == SOURCE_TARGET_FINGERPRINT,
            "delayed_cagr_gt_0": delayed_metrics["cagr_percent"] > 0,
            "delayed_sharpe_gt_0": delayed_metrics["sharpe"] > 0,
            "delayed_mdd_le_2x_frozen_base": delayed_metrics["mdd_percent"] <= 2.0 * base_mdd_percent,
            "delay1_schedule_count_matches_control": len(delayed_mapping) == len(control_mapping),
            "all_delay1_execution_dates_differ_from_source": all(source != execution for source, execution, _ in delayed_mapping),
            "delay1_schedule_declares_one_session": all(delay == 1 for _, _, delay in delayed_mapping),
            "same_source_rebalance_dates": [source for source, _, _ in delayed_mapping] == [source for source, _, _ in control_mapping],
            "scheduled_event_count_matches_candidate": len(delayed_mapping) == delayed["scheduled_shift_count"],
        }
        full_pass = all(delay_checks.values())
        document["candidate_results"].append(delayed)
        document["delay_checks"] = delay_checks
        document["full_g5_status"] = "PASS" if full_pass else "FAIL"
        exit_code = 0 if full_pass else 2

    json_path = output_dir / "candidate-metrics.json"
    json_path.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    csv_path = output_dir / "candidate-metrics.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["candidate_id", "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades", "daily_state_fingerprint", "source_trade_count", "scheduled_shift_count"],
        )
        writer.writeheader()
        for row in document["candidate_results"]:
            metrics = row["metrics"]
            writer.writerow({
                "candidate_id": row["candidate_id"],
                "cagr_percent": metrics["cagr_percent"],
                "mdd_percent": metrics["mdd_percent"],
                "vol_percent": metrics["vol_percent"],
                "sharpe": metrics["sharpe"],
                "trades": metrics["trades"],
                "daily_state_fingerprint": row["daily_state_fingerprint"],
                "source_trade_count": row["source_trade_count"],
                "scheduled_shift_count": row["scheduled_shift_count"],
            })

    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print(f"G5_DELAY_{document['full_g5_status']}")
    print(f"OUTPUT_JSON={json_path}")
    print(f"OUTPUT_CSV={csv_path}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
