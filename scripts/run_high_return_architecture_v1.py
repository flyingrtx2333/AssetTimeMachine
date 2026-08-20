#!/usr/bin/env python3
"""Run the preregistered high-return architecture round-1 family through the shared Swift engine.

Python orchestrates compilation, parsing and preregistered gate evaluation only. It does not
calculate portfolio returns or strategy targets.
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
FRAGMENT = ROOT / "tools/high_return_architecture_v1.swiftpart"
LOGIC = ROOT / "tools/high_return_architecture_v1_logic.swift"
ASSEMBLED = Path("/private/tmp/atm_high_return_architecture_v1.swift")
BINARY = Path("/private/tmp/atm_high_return_architecture_v1")
FORMAL_CANDIDATES = ["HR-A", "HR-B", "HR-C"]
CONTROL_ID = "V11-CONTROL"
FROZEN_V11_CAGR_PERCENT = 14.345615
FROZEN_V11_FINGERPRINT = "ba67c8aa24bc7168"


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


def evaluate_candidate(metrics: dict, *, frozen_v11_cagr_percent: float) -> dict:
    folds = [float(value) for value in metrics["fold_sharpes"]]
    if len(folds) != 7:
        raise ValueError(f"expected 7 fold Sharpes, got {len(folds)}")
    folds_gt1 = sum(value > 1.0 for value in folds)
    worst = min(folds)
    constraints_pass = (
        float(metrics["max_gross"]) <= 1.000000001
        and float(metrics["min_weight"]) >= -1e-10
    )
    admission_checks = {
        "cagr_ge_16pct": float(metrics["cagr_percent"]) >= 16.0,
        "sharpe_ge_1_40": float(metrics["sharpe"]) >= 1.40,
        "mdd_le_12pct": float(metrics["mdd_percent"]) <= 12.0,
        "cagr_improvement_ge_1_5pp": float(metrics["cagr_percent"]) >= frozen_v11_cagr_percent + 1.5,
        "folds_sharpe_gt1_ge_5": folds_gt1 >= 5,
        "worst_fold_sharpe_gt_0": worst > 0,
        "constraints_pass": constraints_pass,
    }
    admitted = all(admission_checks.values())
    target_region = (
        admitted
        and float(metrics["cagr_percent"]) >= 18.0
        and float(metrics["sharpe"]) >= 1.45
    )
    return {
        "admit_for_robustness": admitted,
        "target_region": target_region,
        "constraints_pass": constraints_pass,
        "folds_sharpe_gt1": folds_gt1,
        "worst_fold_sharpe": worst,
        "admission_checks": admission_checks,
    }


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
        str(LOGIC.relative_to(ROOT)),
        str(ASSEMBLED),
        "-o",
        str(BINARY),
    ], timeout=300)


def parse_semicolon_floats(raw: str, *, field: str, candidate_id: str) -> list[float]:
    try:
        values = [float(value) for value in raw.split(";") if value != ""]
    except ValueError as error:
        raise RuntimeError(f"candidate={candidate_id} invalid {field}: {raw}") from error
    if not values:
        raise RuntimeError(f"candidate={candidate_id} empty {field}")
    return values


def parse_formal_candidate(block: str) -> dict:
    lines = [line.strip() for line in block.splitlines() if line.strip()]
    candidate_id = lines[0]
    values: dict[str, str] = {}
    for line in lines[1:]:
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    required = {
        "cagr", "mdd", "vol", "sharpe", "trades", "average_cash", "max_gross",
        "min_weight", "fingerprint", "since2020_cagr", "since2020_sharpe",
        "since2022_cagr", "since2022_sharpe", "fold_names", "fold_sharpes",
        "fold_cagrs", "fold_mdds",
    }
    missing = required - set(values)
    if missing:
        raise RuntimeError(f"candidate={candidate_id} missing {sorted(missing)}")
    fold_names = [name for name in values["fold_names"].split(";") if name]
    fold_sharpes = parse_semicolon_floats(values["fold_sharpes"], field="fold_sharpes", candidate_id=candidate_id)
    fold_cagrs = parse_semicolon_floats(values["fold_cagrs"], field="fold_cagrs", candidate_id=candidate_id)
    fold_mdds = parse_semicolon_floats(values["fold_mdds"], field="fold_mdds", candidate_id=candidate_id)
    if not (len(fold_names) == len(fold_sharpes) == len(fold_cagrs) == len(fold_mdds) == 7):
        raise RuntimeError(f"candidate={candidate_id} fold field lengths are not all 7")
    return {
        "candidate_id": candidate_id,
        "cagr_percent": float(values["cagr"]),
        "mdd_percent": float(values["mdd"]),
        "vol_percent": float(values["vol"]),
        "sharpe": float(values["sharpe"]),
        "trades": int(values["trades"]),
        "average_cash_ratio": float(values["average_cash"]),
        "max_gross": float(values["max_gross"]),
        "min_weight": float(values["min_weight"]),
        "fingerprint": values["fingerprint"],
        "since2020_cagr_percent": float(values["since2020_cagr"]),
        "since2020_sharpe": float(values["since2020_sharpe"]),
        "since2022_cagr_percent": float(values["since2022_cagr"]),
        "since2022_sharpe": float(values["since2022_sharpe"]),
        "fold_names": fold_names,
        "fold_sharpes": fold_sharpes,
        "fold_cagrs_percent": fold_cagrs,
        "fold_mdds_percent": fold_mdds,
    }


def parse_formal_output(stdout: str) -> dict[str, dict]:
    results: dict[str, dict] = {}
    for chunk in stdout.split("candidate_id=")[1:]:
        block, separator, _ = chunk.partition("END_CANDIDATE")
        if not separator:
            raise RuntimeError("unterminated candidate block")
        row = parse_formal_candidate(block)
        candidate_id = row["candidate_id"]
        if candidate_id in results:
            raise RuntimeError(f"duplicate candidate block: {candidate_id}")
        results[candidate_id] = row
    expected = {CONTROL_ID, *FORMAL_CANDIDATES}
    if set(results) != expected:
        raise RuntimeError(f"formal result ids mismatch: expected={sorted(expected)} got={sorted(results)}")
    return results


def validate_smoke(stdout: str) -> dict:
    match = re.search(r"^SMOKE_CONTROL_FINGERPRINT=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    if not match:
        raise RuntimeError("smoke output missing control fingerprint")
    ids = re.findall(r"^SMOKE_CANDIDATE=(.+)$", stdout, flags=re.MULTILINE)
    gross = [float(value) for value in re.findall(r"^SMOKE_MAX_GROSS=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    minimums = [float(value) for value in re.findall(r"^SMOKE_MIN_WEIGHT=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    if ids != FORMAL_CANDIDATES:
        raise RuntimeError(f"smoke candidate ids mismatch: {ids}")
    if len(gross) != 3 or len(minimums) != 3:
        raise RuntimeError("smoke constraint count mismatch")
    if any(value > 1.000000001 for value in gross):
        raise RuntimeError(f"smoke gross constraint failed: {gross}")
    if any(value < -1e-10 for value in minimums):
        raise RuntimeError(f"smoke negative weight constraint failed: {minimums}")
    return {
        "control_fingerprint": match.group(1),
        "candidate_ids": ids,
        "max_gross": gross,
        "min_weight": minimums,
    }


def write_formal_outputs(output_dir: Path, results: dict[str, dict]) -> dict:
    control = results[CONTROL_ID]
    candidate_results: list[dict] = []
    for candidate_id in FORMAL_CANDIDATES:
        metrics = dict(results[candidate_id])
        flags = evaluate_candidate(metrics, frozen_v11_cagr_percent=FROZEN_V11_CAGR_PERCENT)
        candidate_results.append({
            "candidate_id": candidate_id,
            "metrics": metrics,
            **flags,
        })
    document = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": "ATM-SVP2-HR-ARCH-001",
        "strategy_lineage": "high-return-architecture-v1",
        "formal_candidates": FORMAL_CANDIDATES,
        "control": control,
        "candidate_results": candidate_results,
        "admitted_candidates": [row["candidate_id"] for row in candidate_results if row["admit_for_robustness"]],
        "target_region_candidates": [row["candidate_id"] for row in candidate_results if row["target_region"]],
        "frozen_v11_cagr_percent": FROZEN_V11_CAGR_PERCENT,
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "candidate-metrics.json"
    json_path.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    csv_path = output_dir / "candidate-metrics.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "candidate_id", "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades",
            "average_cash_ratio", "max_gross", "min_weight", "fingerprint", "folds_sharpe_gt1",
            "worst_fold_sharpe", "admit_for_robustness", "target_region",
        ])
        writer.writeheader()
        control_row = {
            "candidate_id": CONTROL_ID,
            **{key: control[key] for key in [
                "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades",
                "average_cash_ratio", "max_gross", "min_weight", "fingerprint",
            ]},
            "folds_sharpe_gt1": sum(value > 1 for value in control["fold_sharpes"]),
            "worst_fold_sharpe": min(control["fold_sharpes"]),
            "admit_for_robustness": "CONTROL",
            "target_region": "CONTROL",
        }
        writer.writerow(control_row)
        for row in candidate_results:
            metrics = row["metrics"]
            writer.writerow({
                "candidate_id": row["candidate_id"],
                **{key: metrics[key] for key in [
                    "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades",
                    "average_cash_ratio", "max_gross", "min_weight", "fingerprint",
                ]},
                "folds_sharpe_gt1": row["folds_sharpe_gt1"],
                "worst_fold_sharpe": row["worst_fold_sharpe"],
                "admit_for_robustness": row["admit_for_robustness"],
                "target_region": row["target_region"],
            })
    return document


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--formal", action="store_true")
    args = parser.parse_args()

    fixture = Path(args.fixture)
    if not fixture.is_file():
        raise SystemExit(f"fixture missing: {fixture}")
    output_dir = Path(args.output_dir)
    compile_binary()
    env = os.environ.copy()
    env.update({
        "ATM_HISTORY_FIXTURE": str(fixture),
        "ATM_HIGH_RETURN_ARCH_V1": "1",
    })
    if args.formal:
        env["ATM_HIGH_RETURN_FORMAL"] = "1"
        env["ATM_HIGH_RETURN_OUTPUT_DIR"] = str(output_dir)
    stdout = run([str(BINARY)], env=env, timeout=300)
    if "HIGH_RETURN_ARCHITECTURE_V1_COMPLETE" not in stdout:
        raise RuntimeError("Swift family did not complete")

    if not args.formal:
        smoke = validate_smoke(stdout)
        if smoke["control_fingerprint"] != FROZEN_V11_FINGERPRINT:
            raise RuntimeError(
                f"V11 control fingerprint drifted: {smoke['control_fingerprint']} != {FROZEN_V11_FINGERPRINT}"
            )
        print(json.dumps({"mode": "SMOKE_NO_PERFORMANCE", **smoke}, ensure_ascii=False, sort_keys=True))
        print("HIGH_RETURN_SMOKE_OK")
        return 0

    results = parse_formal_output(stdout)
    if results[CONTROL_ID]["fingerprint"] != FROZEN_V11_FINGERPRINT:
        raise RuntimeError("formal V11 control fingerprint drifted")
    document = write_formal_outputs(output_dir, results)
    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print("HIGH_RETURN_FORMAL_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
