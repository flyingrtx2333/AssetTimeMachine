#!/usr/bin/env python3
"""Run the preregistered Orthogonal Factor Family V1 through the shared Swift engine."""
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
FRAGMENT = ROOT / "tools/orthogonal_factor_family_v1.swiftpart"
LOGIC = ROOT / "tools/orthogonal_factor_family_v1_logic.swift"
ASSEMBLED = Path("/private/tmp/atm_orthogonal_factor_family_v1.swift")
BINARY = Path("/private/tmp/atm_orthogonal_factor_family_v1")
FORMAL_CANDIDATES = ["F-CURVE", "F-USD", "F-SIZE"]
CONTROL_IDS = ["V11-CONTROL", "ALWAYS-FILL"]
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


def evaluate_factor(metrics: dict, *, v11: dict, always_fill: dict) -> dict:
    candidate_folds = [float(value) for value in metrics["fold_sharpes"]]
    always_folds = [float(value) for value in always_fill["fold_sharpes"]]
    if len(candidate_folds) != 7 or len(always_folds) != 7:
        raise ValueError("candidate and ALWAYS-FILL must both have exactly seven fold Sharpes")
    fold_wins = sum(candidate >= control for candidate, control in zip(candidate_folds, always_folds))
    worst = min(candidate_folds)
    constraints_pass = (
        float(metrics["max_gross"]) <= 1.000000001
        and float(metrics["min_weight"]) >= -1e-10
    )
    checks = {
        "cagr_gt_v11": float(metrics["cagr_percent"]) > float(v11["cagr_percent"]),
        "sharpe_gt_always_fill": float(metrics["sharpe"]) > float(always_fill["sharpe"]),
        "mdd_le_12pct": float(metrics["mdd_percent"]) <= 12.0,
        "folds_sharpe_ge_always_fill_ge_4": fold_wins >= 4,
        "worst_fold_sharpe_gt_0": worst > 0,
        "constraints_pass": constraints_pass,
    }
    admitted = all(checks.values())
    strong = (
        admitted
        and float(metrics["cagr_percent"]) >= float(v11["cagr_percent"]) + 1.0
        and float(metrics["sharpe"]) >= float(v11["sharpe"])
    )
    return {
        "admit_for_robustness": admitted,
        "strong_incremental": strong,
        "constraints_pass": constraints_pass,
        "folds_sharpe_ge_always_fill": fold_wins,
        "worst_fold_sharpe": worst,
        "admission_checks": checks,
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


def parse_float_list(raw: str, *, candidate_id: str, field: str) -> list[float]:
    try:
        values = [float(value) for value in raw.split(";") if value]
    except ValueError as error:
        raise RuntimeError(f"candidate={candidate_id} invalid {field}: {raw}") from error
    if len(values) != 7:
        raise RuntimeError(f"candidate={candidate_id} {field} must have seven values")
    return values


def parse_candidate(block: str) -> dict:
    lines = [line.strip() for line in block.splitlines() if line.strip()]
    candidate_id = lines[0]
    values: dict[str, str] = {}
    for line in lines[1:]:
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    required = {
        "cagr", "mdd", "vol", "sharpe", "trades", "average_cash", "max_gross", "min_weight",
        "fingerprint", "since2020_cagr", "since2020_sharpe", "since2022_cagr", "since2022_sharpe",
        "fold_names", "fold_sharpes", "fold_cagrs", "fold_mdds",
    }
    missing = required - set(values)
    if missing:
        raise RuntimeError(f"candidate={candidate_id} missing {sorted(missing)}")
    fold_names = [value for value in values["fold_names"].split(";") if value]
    if len(fold_names) != 7:
        raise RuntimeError(f"candidate={candidate_id} fold_names must have seven values")
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
        "fold_sharpes": parse_float_list(values["fold_sharpes"], candidate_id=candidate_id, field="fold_sharpes"),
        "fold_cagrs_percent": parse_float_list(values["fold_cagrs"], candidate_id=candidate_id, field="fold_cagrs"),
        "fold_mdds_percent": parse_float_list(values["fold_mdds"], candidate_id=candidate_id, field="fold_mdds"),
    }


def parse_formal_output(stdout: str) -> dict[str, dict]:
    rows: dict[str, dict] = {}
    for chunk in stdout.split("candidate_id=")[1:]:
        block, separator, _ = chunk.partition("END_CANDIDATE")
        if not separator:
            raise RuntimeError("unterminated candidate block")
        row = parse_candidate(block)
        candidate_id = row["candidate_id"]
        if candidate_id in rows:
            raise RuntimeError(f"duplicate candidate block: {candidate_id}")
        rows[candidate_id] = row
    expected = set(CONTROL_IDS + FORMAL_CANDIDATES)
    if set(rows) != expected:
        raise RuntimeError(f"formal result ids mismatch expected={sorted(expected)} got={sorted(rows)}")
    return rows


def validate_smoke(stdout: str) -> dict:
    fingerprint = re.search(r"^SMOKE_CONTROL_FINGERPRINT=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    counts = re.search(r"^SMOKE_FACTOR_COUNTS=([0-9;]+)$", stdout, flags=re.MULTILINE)
    ids = re.findall(r"^SMOKE_FACTOR_ID=(.+)$", stdout, flags=re.MULTILINE)
    gross = [float(value) for value in re.findall(r"^SMOKE_MAX_GROSS=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    minimums = [float(value) for value in re.findall(r"^SMOKE_MIN_WEIGHT=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    if not fingerprint or not counts:
        raise RuntimeError("smoke output missing control/factor metadata")
    expected_ids = ["ALWAYS-FILL", *FORMAL_CANDIDATES]
    if ids != expected_ids:
        raise RuntimeError(f"smoke ids mismatch: {ids}")
    factor_counts = [int(value) for value in counts.group(1).split(";")]
    if len(factor_counts) != 4 or any(value <= 0 for value in factor_counts):
        raise RuntimeError(f"invalid smoke factor counts: {factor_counts}")
    if len(gross) != 4 or any(value > 1.000000001 for value in gross):
        raise RuntimeError(f"smoke gross constraint failed: {gross}")
    if len(minimums) != 4 or any(value < -1e-10 for value in minimums):
        raise RuntimeError(f"smoke negative weight constraint failed: {minimums}")
    return {
        "control_fingerprint": fingerprint.group(1),
        "factor_counts": factor_counts,
        "ids": ids,
        "max_gross": gross,
        "min_weight": minimums,
    }


def write_outputs(output_dir: Path, rows: dict[str, dict]) -> dict:
    v11 = rows["V11-CONTROL"]
    always = rows["ALWAYS-FILL"]
    candidate_results: list[dict] = []
    for candidate_id in FORMAL_CANDIDATES:
        metrics = rows[candidate_id]
        flags = evaluate_factor(metrics, v11=v11, always_fill=always)
        candidate_results.append({"candidate_id": candidate_id, "metrics": metrics, **flags})
    document = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": "ATM-SVP2-ORTHO-FACTOR-001",
        "strategy_lineage": "orthogonal-factor-family-v1",
        "controls": {"V11-CONTROL": v11, "ALWAYS-FILL": always},
        "candidate_results": candidate_results,
        "admitted_candidates": [row["candidate_id"] for row in candidate_results if row["admit_for_robustness"]],
        "strong_incremental_candidates": [row["candidate_id"] for row in candidate_results if row["strong_incremental"]],
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "candidate-metrics.json"
    json_path.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    csv_path = output_dir / "candidate-metrics.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "candidate_id", "kind", "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades",
            "average_cash_ratio", "max_gross", "min_weight", "fingerprint", "folds_sharpe_ge_always_fill",
            "worst_fold_sharpe", "admit_for_robustness", "strong_incremental",
        ])
        writer.writeheader()
        for control_id in CONTROL_IDS:
            metrics = rows[control_id]
            writer.writerow({
                "candidate_id": control_id,
                "kind": "CONTROL",
                **{key: metrics[key] for key in [
                    "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades", "average_cash_ratio",
                    "max_gross", "min_weight", "fingerprint",
                ]},
                "folds_sharpe_ge_always_fill": "CONTROL",
                "worst_fold_sharpe": min(metrics["fold_sharpes"]),
                "admit_for_robustness": "CONTROL",
                "strong_incremental": "CONTROL",
            })
        for row in candidate_results:
            metrics = row["metrics"]
            writer.writerow({
                "candidate_id": row["candidate_id"],
                "kind": "FACTOR",
                **{key: metrics[key] for key in [
                    "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades", "average_cash_ratio",
                    "max_gross", "min_weight", "fingerprint",
                ]},
                "folds_sharpe_ge_always_fill": row["folds_sharpe_ge_always_fill"],
                "worst_fold_sharpe": row["worst_fold_sharpe"],
                "admit_for_robustness": row["admit_for_robustness"],
                "strong_incremental": row["strong_incremental"],
            })
    return document


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--factor-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--formal", action="store_true")
    args = parser.parse_args()

    fixture = Path(args.fixture)
    factor_dir = Path(args.factor_dir)
    if not fixture.is_file():
        raise SystemExit(f"fixture missing: {fixture}")
    for name in ["T10Y3M.csv", "DXY.csv", "RUT.csv", "RUI.csv"]:
        if not (factor_dir / name).is_file():
            raise SystemExit(f"factor file missing: {factor_dir / name}")

    compile_binary()
    env = os.environ.copy()
    env.update({
        "ATM_HISTORY_FIXTURE": str(fixture),
        "ATM_ORTHOGONAL_FACTOR_V1": "1",
        "ATM_ORTHOGONAL_FACTOR_DATA_DIR": str(factor_dir),
    })
    output_dir = Path(args.output_dir)
    if args.formal:
        env["ATM_ORTHOGONAL_FACTOR_FORMAL"] = "1"
        env["ATM_ORTHOGONAL_FACTOR_OUTPUT_DIR"] = str(output_dir)
    stdout = run([str(BINARY)], env=env, timeout=300)
    if "ORTHOGONAL_FACTOR_FAMILY_V1_COMPLETE" not in stdout:
        raise RuntimeError("Swift factor family did not complete")

    if not args.formal:
        smoke = validate_smoke(stdout)
        if smoke["control_fingerprint"] != FROZEN_V11_FINGERPRINT:
            raise RuntimeError("V11 control fingerprint drifted")
        print(json.dumps({"mode": "SMOKE_NO_PERFORMANCE", **smoke}, ensure_ascii=False, sort_keys=True))
        print("ORTHOGONAL_FACTOR_SMOKE_OK")
        return 0

    rows = parse_formal_output(stdout)
    if rows["V11-CONTROL"]["fingerprint"] != FROZEN_V11_FINGERPRINT:
        raise RuntimeError("formal V11 fingerprint drifted")
    document = write_outputs(output_dir, rows)
    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print("ORTHOGONAL_FACTOR_FORMAL_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
