#!/usr/bin/env python3
"""Run preregistered Cboe Equity Put/Call execution-timing V1 through the shared Swift App engine."""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FRAGMENT = ROOT / "tools/cboe_equity_put_call_execution_v1.swiftpart"
LOGIC = ROOT / "tools/cboe_equity_put_call_execution_v1_logic.swift"
ASSEMBLED = Path("/private/tmp/atm_cboe_pc_execution_v1.swift")
BINARY = Path("/private/tmp/atm_cboe_pc_execution_v1")
CANDIDATE_ID = "F-CBOE-PC-EXECUTION"
MATCHED_CONTROL_ID = "C-CBOE-PC-DELAY-ALWAYS"
FROZEN_V11_FINGERPRINT = "ba67c8aa24bc7168"
FOLD_COUNT = 7


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 300) -> str:
    completed = subprocess.run(command, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, check=False)
    if completed.returncode != 0:
        sys.stderr.write(completed.stdout[-16000:])
        raise RuntimeError(f"command failed ({completed.returncode}): {' '.join(command)}")
    return completed.stdout


def compile_binary() -> None:
    run([sys.executable, "scripts/assemble_strategy_metric_dump.py", "--fragment", str(FRAGMENT.relative_to(ROOT)), "--output", str(ASSEMBLED)])
    run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", "/private/tmp/atm-swift-module-cache",
        "AssetTimeMachine/Backtest/BacktestModels.swift", "AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift",
        "AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift", "AssetTimeMachine/Backtest/BacktestFXConverter.swift",
        "AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift", "AssetTimeMachine/Backtest/BacktestEngine.swift",
        str(LOGIC.relative_to(ROOT)), str(ASSEMBLED), "-o", str(BINARY),
    ], timeout=300)


def parse_list(raw: str, candidate_id: str, field: str) -> list[float]:
    values = [float(value) for value in raw.split(";") if value]
    if len(values) != FOLD_COUNT:
        raise RuntimeError(f"candidate={candidate_id} {field} must have {FOLD_COUNT} values")
    return values


def parse_candidate(block: str) -> dict:
    lines = [line.strip() for line in block.splitlines() if line.strip()]
    candidate_id = lines[0]
    values = dict(line.split("=", 1) for line in lines[1:] if "=" in line)
    required = {
        "cagr", "mdd", "vol", "sharpe", "evaluation_cagr", "evaluation_mdd", "evaluation_sharpe", "trades",
        "average_cash", "max_gross", "min_weight", "fingerprint", "source_events", "us_risk_increase_events",
        "available_us_risk_increase_events", "delayed_events", "completed_delayed_events", "cancelled_by_new_source_event",
        "since2020_cagr", "since2020_sharpe", "since2022_cagr", "since2022_sharpe", "fold_names", "fold_sharpes",
        "fold_cagrs", "fold_mdds",
    }
    missing = required - set(values)
    if missing:
        raise RuntimeError(f"candidate={candidate_id} missing {sorted(missing)}")
    fold_names = [value for value in values["fold_names"].split(";") if value]
    if len(fold_names) != FOLD_COUNT:
        raise RuntimeError(f"candidate={candidate_id} fold_names must have {FOLD_COUNT} values")
    return {
        "candidate_id": candidate_id,
        "cagr_percent": float(values["cagr"]), "mdd_percent": float(values["mdd"]), "vol_percent": float(values["vol"]),
        "sharpe": float(values["sharpe"]), "evaluation_cagr_percent": float(values["evaluation_cagr"]),
        "evaluation_mdd_percent": float(values["evaluation_mdd"]), "evaluation_sharpe": float(values["evaluation_sharpe"]),
        "trades": int(values["trades"]), "average_cash_ratio": float(values["average_cash"]), "max_gross": float(values["max_gross"]),
        "min_weight": float(values["min_weight"]), "fingerprint": values["fingerprint"], "source_events": int(values["source_events"]),
        "us_risk_increase_events": int(values["us_risk_increase_events"]),
        "available_us_risk_increase_events": int(values["available_us_risk_increase_events"]),
        "delayed_events": int(values["delayed_events"]), "completed_delayed_events": int(values["completed_delayed_events"]),
        "cancelled_by_new_source_event": int(values["cancelled_by_new_source_event"]),
        "since2020_cagr_percent": float(values["since2020_cagr"]), "since2020_sharpe": float(values["since2020_sharpe"]),
        "since2022_cagr_percent": float(values["since2022_cagr"]), "since2022_sharpe": float(values["since2022_sharpe"]),
        "fold_names": fold_names, "fold_sharpes": parse_list(values["fold_sharpes"], candidate_id, "fold_sharpes"),
        "fold_cagrs_percent": parse_list(values["fold_cagrs"], candidate_id, "fold_cagrs"),
        "fold_mdds_percent": parse_list(values["fold_mdds"], candidate_id, "fold_mdds"),
    }


def parse_formal_output(stdout: str) -> dict[str, dict]:
    rows = {}
    for chunk in stdout.split("candidate_id=")[1:]:
        block, separator, _ = chunk.partition("END_CANDIDATE")
        if not separator:
            raise RuntimeError("unterminated candidate block")
        row = parse_candidate(block)
        rows[row["candidate_id"]] = row
    expected = {"V11-CONTROL", MATCHED_CONTROL_ID, CANDIDATE_ID}
    if set(rows) != expected:
        raise RuntimeError(f"formal path ids mismatch expected={sorted(expected)} got={sorted(rows)}")
    return rows


def evaluate_candidate(metrics: dict, *, v11: dict, matched: dict) -> dict:
    fold_wins = sum(a >= b for a, b in zip(metrics["fold_sharpes"], matched["fold_sharpes"]))
    worst = min(metrics["fold_sharpes"])
    constraints = metrics["max_gross"] <= 1.000000001 and metrics["min_weight"] >= -1e-10
    checks = {
        "evaluation_cagr_gt_v11": metrics["evaluation_cagr_percent"] > v11["evaluation_cagr_percent"],
        "evaluation_sharpe_ge_v11": metrics["evaluation_sharpe"] >= v11["evaluation_sharpe"],
        "evaluation_sharpe_gt_matched_control": metrics["evaluation_sharpe"] > matched["evaluation_sharpe"],
        "evaluation_mdd_le_10pct": metrics["evaluation_mdd_percent"] <= 10.0,
        "folds_sharpe_ge_matched_ge_5_of_7": fold_wins >= 5,
        "worst_fold_sharpe_gt_0": worst > 0,
        "constraints_pass": constraints,
    }
    return {"admit_for_robustness": all(checks.values()), "constraints_pass": constraints, "folds_sharpe_ge_matched": fold_wins, "worst_fold_sharpe": worst, "admission_checks": checks}


def validate_smoke(stdout: str) -> dict:
    fingerprint = re.search(r"^source_target_fingerprint=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    identity = re.search(r"^SMOKE_IDENTITY_MATCH=(true|false)$", stdout, flags=re.MULTILINE)
    factor_count = re.search(r"^factor_point_count=(\d+)$", stdout, flags=re.MULTILINE)
    ids = re.findall(r"^SMOKE_CBOE_PC_PATH=(.+)$", stdout, flags=re.MULTILINE)
    source = [int(v) for v in re.findall(r"^SMOKE_SOURCE_COUNT=(\d+)$", stdout, flags=re.MULTILINE)]
    increases = [int(v) for v in re.findall(r"^SMOKE_US_RISK_INCREASE_COUNT=(\d+)$", stdout, flags=re.MULTILINE)]
    available = [int(v) for v in re.findall(r"^SMOKE_AVAILABLE_US_RISK_INCREASE_COUNT=(\d+)$", stdout, flags=re.MULTILINE)]
    gross = [float(v) for v in re.findall(r"^SMOKE_MAX_GROSS=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    minimums = [float(v) for v in re.findall(r"^SMOKE_MIN_WEIGHT=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    if not fingerprint or not identity or identity.group(1) != "true" or not factor_count:
        raise RuntimeError("smoke identity/fingerprint/factor-count check failed")
    if ids != [MATCHED_CONTROL_ID, CANDIDATE_ID]:
        raise RuntimeError(f"smoke path ids mismatch: {ids}")
    for name, values in (("source", source), ("us increases", increases), ("available", available)):
        if len(values) != 2 or len(set(values)) != 1 or values[0] <= 0:
            raise RuntimeError(f"{name} count mismatch: {values}")
    if any(v > 1.000000001 for v in gross) or any(v < -1e-10 for v in minimums):
        raise RuntimeError("portfolio constraint failed")
    return {"source_fingerprint": fingerprint.group(1), "identity_match": True, "source_events": source[0], "us_risk_increase_events": increases[0], "available_us_risk_increase_events": available[0], "factor_points": int(factor_count.group(1))}


def write_outputs(output_dir: Path, rows: dict[str, dict]) -> dict:
    v11, matched, metrics = rows["V11-CONTROL"], rows[MATCHED_CONTROL_ID], rows[CANDIDATE_ID]
    flags = evaluate_candidate(metrics, v11=v11, matched=matched)
    result = {"candidate_id": CANDIDATE_ID, "matched_control_id": MATCHED_CONTROL_ID, "metrics": metrics, **flags}
    document = {
        "protocol_id": "ATM-SVP-2", "trial_id": "ATM-SVP2-CBOE-PC-001", "strategy_lineage": "cboe-equity-put-call-execution-v1",
        "evaluation_window_start": "2013-01-01", "v11_control": v11, "matched_control": matched, "candidate_results": [result],
        "admitted_candidates": [CANDIDATE_ID] if result["admit_for_robustness"] else [],
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "candidate-metrics.json").write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    fields = [
        "candidate_id", "kind", "matched_control_id", "cagr_percent", "mdd_percent", "sharpe", "evaluation_cagr_percent",
        "evaluation_mdd_percent", "evaluation_sharpe", "trades", "average_cash_ratio", "max_gross", "min_weight", "source_events",
        "us_risk_increase_events", "available_us_risk_increase_events", "delayed_events", "completed_delayed_events",
        "cancelled_by_new_source_event", "folds_sharpe_ge_matched", "worst_fold_sharpe", "admit_for_robustness",
    ]
    with (output_dir / "candidate-metrics.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields); writer.writeheader()
        for path_id, kind in [("V11-CONTROL", "CONTROL"), (MATCHED_CONTROL_ID, "MATCHED_CONTROL")]:
            path = rows[path_id]
            writer.writerow({"candidate_id": path_id, "kind": kind, "matched_control_id": "", **{k: path[k] for k in fields if k in path}, "folds_sharpe_ge_matched": "CONTROL", "worst_fold_sharpe": min(path["fold_sharpes"]), "admit_for_robustness": "CONTROL"})
        writer.writerow({"candidate_id": CANDIDATE_ID, "kind": "FACTOR_STRATEGY", "matched_control_id": MATCHED_CONTROL_ID, **{k: metrics[k] for k in fields if k in metrics}, "folds_sharpe_ge_matched": flags["folds_sharpe_ge_matched"], "worst_fold_sharpe": flags["worst_fold_sharpe"], "admit_for_robustness": flags["admit_for_robustness"]})
    return document


def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--fixture", required=True); parser.add_argument("--factor-input", required=True); parser.add_argument("--output-dir", required=True); parser.add_argument("--formal", action="store_true"); args = parser.parse_args()
    fixture, factor_input = Path(args.fixture), Path(args.factor_input)
    if not fixture.is_file() or not factor_input.is_file():
        raise SystemExit("fixture or factor input missing")
    compile_binary()
    env = os.environ.copy(); env.update({"ATM_HISTORY_FIXTURE": str(fixture), "ATM_CBOE_PC_EXECUTION_V1": "1", "ATM_CBOE_PC_EXECUTION_V1_FACTOR_PATH": str(factor_input)})
    output_dir = Path(args.output_dir)
    if args.formal:
        env["ATM_CBOE_PC_EXECUTION_V1_FORMAL"] = "1"; env["ATM_CBOE_PC_EXECUTION_V1_OUTPUT_DIR"] = str(output_dir)
    stdout = run([str(BINARY)], env=env, timeout=300)
    if "CBOE_PC_EXECUTION_V1_COMPLETE" not in stdout:
        raise RuntimeError("Swift Cboe P/C trial did not complete")
    if not args.formal:
        smoke = validate_smoke(stdout)
        if smoke["source_fingerprint"] != FROZEN_V11_FINGERPRINT:
            raise RuntimeError("V11 source fingerprint drifted")
        print(json.dumps({"mode": "SMOKE_NO_PERFORMANCE", **smoke}, ensure_ascii=False, sort_keys=True)); print("CBOE_PC_EXECUTION_V1_SMOKE_OK"); return 0
    rows = parse_formal_output(stdout)
    if rows["V11-CONTROL"]["fingerprint"] != FROZEN_V11_FINGERPRINT:
        raise RuntimeError("formal V11 fingerprint drifted")
    document = write_outputs(output_dir, rows); print(json.dumps(document, ensure_ascii=False, sort_keys=True)); print("CBOE_PC_EXECUTION_V1_FORMAL_COMPLETE"); return 0


if __name__ == "__main__":
    raise SystemExit(main())
