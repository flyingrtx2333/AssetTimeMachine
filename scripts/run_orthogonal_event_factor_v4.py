#!/usr/bin/env python3
"""Run preregistered Orthogonal Event Factor Family V4 through the shared Swift engine."""
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
FRAGMENT = ROOT / "tools/orthogonal_event_factor_v4.swiftpart"
LOGIC = ROOT / "tools/orthogonal_event_factor_v3_logic.swift"
ASSEMBLED = Path("/private/tmp/atm_orthogonal_event_factor_v4.swift")
BINARY = Path("/private/tmp/atm_orthogonal_event_factor_v4")
FORMAL_CANDIDATES = ["F-HIGHBETA", "F-INDUTIL", "F-BANKS"]
MATCHED_CONTROLS = {
    "F-HIGHBETA": "C-HIGHBETA-ALWAYS",
    "F-INDUTIL": "C-INDUTIL-ALWAYS",
    "F-BANKS": "C-BANKS-ALWAYS",
}
CONTROL_IDS = ["V11-CONTROL", *MATCHED_CONTROLS.values()]
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


def evaluate_factor(metrics: dict, *, v11: dict, matched_control: dict) -> dict:
    candidate_folds = [float(value) for value in metrics["fold_sharpes"]]
    matched_folds = [float(value) for value in matched_control["fold_sharpes"]]
    if len(candidate_folds) != 7 or len(matched_folds) != 7:
        raise ValueError("candidate and matched control must both have exactly seven fold Sharpes")
    fold_wins = sum(candidate >= control for candidate, control in zip(candidate_folds, matched_folds))
    worst = min(candidate_folds)
    constraints_pass = (
        float(metrics["max_gross"]) <= 1.000000001
        and float(metrics["min_weight"]) >= -1e-10
    )
    checks = {
        "cagr_gt_v11": float(metrics["cagr_percent"]) > float(v11["cagr_percent"]),
        "sharpe_gt_matched_control": float(metrics["sharpe"]) > float(matched_control["sharpe"]),
        "mdd_le_12pct": float(metrics["mdd_percent"]) <= 12.0,
        "folds_sharpe_ge_matched_ge_4": fold_wins >= 4,
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
        "folds_sharpe_ge_matched": fold_wins,
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
        "fingerprint", "source_events", "derisk_events", "available_derisk_events", "retained_events",
        "since2020_cagr", "since2020_sharpe", "since2022_cagr", "since2022_sharpe",
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
        "source_events": int(values["source_events"]),
        "derisk_events": int(values["derisk_events"]),
        "available_derisk_events": int(values["available_derisk_events"]),
        "retained_events": int(values["retained_events"]),
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
    expected = {"V11-CONTROL", *MATCHED_CONTROLS.values(), *FORMAL_CANDIDATES}
    if set(rows) != expected:
        raise RuntimeError(f"formal path ids mismatch expected={sorted(expected)} got={sorted(rows)}")
    return rows


def validate_smoke(stdout: str) -> dict:
    source_fingerprint = re.search(r"^source_target_fingerprint=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    identity = re.search(r"^SMOKE_IDENTITY_MATCH=(true|false)$", stdout, flags=re.MULTILINE)
    ids = re.findall(r"^SMOKE_EVENT_PATH=(.+)$", stdout, flags=re.MULTILINE)
    source_counts = [int(value) for value in re.findall(r"^SMOKE_EVENT_SOURCE_COUNT=(\d+)$", stdout, flags=re.MULTILINE)]
    derisk_counts = [int(value) for value in re.findall(r"^SMOKE_EVENT_DERISK_COUNT=(\d+)$", stdout, flags=re.MULTILINE)]
    gross = [float(value) for value in re.findall(r"^SMOKE_MAX_GROSS=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    minimums = [float(value) for value in re.findall(r"^SMOKE_MIN_WEIGHT=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    expected_ids = [
        "C-HIGHBETA-ALWAYS", "F-HIGHBETA",
        "C-INDUTIL-ALWAYS", "F-INDUTIL",
        "C-BANKS-ALWAYS", "F-BANKS",
    ]
    if not source_fingerprint or not identity:
        raise RuntimeError("smoke output missing source fingerprint or identity check")
    if identity.group(1) != "true":
        raise RuntimeError("identity replay did not match frozen V11")
    if ids != expected_ids:
        raise RuntimeError(f"smoke path ids mismatch: {ids}")
    if len(source_counts) != 6 or len(set(source_counts)) != 1 or source_counts[0] <= 0:
        raise RuntimeError(f"smoke source event count mismatch: {source_counts}")
    if len(derisk_counts) != 6 or len(set(derisk_counts)) != 1 or derisk_counts[0] <= 0:
        raise RuntimeError(f"smoke de-risk event count mismatch: {derisk_counts}")
    if len(gross) != 6 or any(value > 1.000000001 for value in gross):
        raise RuntimeError(f"smoke gross constraint failed: {gross}")
    if len(minimums) != 6 or any(value < -1e-10 for value in minimums):
        raise RuntimeError(f"smoke negative weight constraint failed: {minimums}")
    return {
        "source_fingerprint": source_fingerprint.group(1),
        "identity_match": True,
        "ids": ids,
        "source_events": source_counts[0],
        "derisk_events": derisk_counts[0],
        "max_gross": gross,
        "min_weight": minimums,
    }


def write_outputs(output_dir: Path, rows: dict[str, dict]) -> dict:
    v11 = rows["V11-CONTROL"]
    controls = {control_id: rows[control_id] for control_id in MATCHED_CONTROLS.values()}
    candidate_results: list[dict] = []
    for candidate_id in FORMAL_CANDIDATES:
        control_id = MATCHED_CONTROLS[candidate_id]
        metrics = rows[candidate_id]
        flags = evaluate_factor(metrics, v11=v11, matched_control=rows[control_id])
        candidate_results.append({
            "candidate_id": candidate_id,
            "matched_control_id": control_id,
            "metrics": metrics,
            **flags,
        })
    document = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": "ATM-SVP2-ORTHO-FACTOR-004",
        "strategy_lineage": "orthogonal-event-factor-family-v4",
        "v11_control": v11,
        "matched_controls": controls,
        "candidate_results": candidate_results,
        "admitted_candidates": [row["candidate_id"] for row in candidate_results if row["admit_for_robustness"]],
        "strong_incremental_candidates": [row["candidate_id"] for row in candidate_results if row["strong_incremental"]],
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "candidate-metrics.json").write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    with (output_dir / "candidate-metrics.csv").open("w", encoding="utf-8", newline="") as handle:
        fields = [
            "candidate_id", "kind", "matched_control_id", "cagr_percent", "mdd_percent", "vol_percent",
            "sharpe", "trades", "average_cash_ratio", "max_gross", "min_weight", "fingerprint",
            "source_events", "derisk_events", "available_derisk_events", "retained_events",
            "folds_sharpe_ge_matched", "worst_fold_sharpe", "admit_for_robustness", "strong_incremental",
        ]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerow({
            "candidate_id": "V11-CONTROL", "kind": "CONTROL", "matched_control_id": "",
            **{key: v11[key] for key in [
                "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades", "average_cash_ratio",
                "max_gross", "min_weight", "fingerprint", "source_events", "derisk_events",
                "available_derisk_events", "retained_events",
            ]},
            "folds_sharpe_ge_matched": "CONTROL", "worst_fold_sharpe": min(v11["fold_sharpes"]),
            "admit_for_robustness": "CONTROL", "strong_incremental": "CONTROL",
        })
        for control_id in MATCHED_CONTROLS.values():
            metrics = rows[control_id]
            writer.writerow({
                "candidate_id": control_id, "kind": "MATCHED_CONTROL", "matched_control_id": "",
                **{key: metrics[key] for key in [
                    "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades", "average_cash_ratio",
                    "max_gross", "min_weight", "fingerprint", "source_events", "derisk_events",
                    "available_derisk_events", "retained_events",
                ]},
                "folds_sharpe_ge_matched": "CONTROL", "worst_fold_sharpe": min(metrics["fold_sharpes"]),
                "admit_for_robustness": "CONTROL", "strong_incremental": "CONTROL",
            })
        for result in candidate_results:
            metrics = result["metrics"]
            writer.writerow({
                "candidate_id": result["candidate_id"], "kind": "FACTOR",
                "matched_control_id": result["matched_control_id"],
                **{key: metrics[key] for key in [
                    "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades", "average_cash_ratio",
                    "max_gross", "min_weight", "fingerprint", "source_events", "derisk_events",
                    "available_derisk_events", "retained_events",
                ]},
                "folds_sharpe_ge_matched": result["folds_sharpe_ge_matched"],
                "worst_fold_sharpe": result["worst_fold_sharpe"],
                "admit_for_robustness": result["admit_for_robustness"],
                "strong_incremental": result["strong_incremental"],
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
    for name in ["SPHB.csv", "SPLV.csv", "XLI.csv", "XLU.csv", "KRE.csv", "SPY.csv"]:
        if not (factor_dir / name).is_file():
            raise SystemExit(f"factor file missing: {factor_dir / name}")

    compile_binary()
    env = os.environ.copy()
    env.update({
        "ATM_HISTORY_FIXTURE": str(fixture),
        "ATM_ORTHOGONAL_EVENT_FACTOR_V4": "1",
        "ATM_ORTHOGONAL_EVENT_FACTOR_V4_DATA_DIR": str(factor_dir),
    })
    output_dir = Path(args.output_dir)
    if args.formal:
        env["ATM_ORTHOGONAL_EVENT_FACTOR_V4_FORMAL"] = "1"
        env["ATM_ORTHOGONAL_EVENT_FACTOR_V4_OUTPUT_DIR"] = str(output_dir)
    stdout = run([str(BINARY)], env=env, timeout=300)
    if "ORTHOGONAL_EVENT_FACTOR_V4_COMPLETE" not in stdout:
        raise RuntimeError("Swift event-factor family did not complete")

    if not args.formal:
        smoke = validate_smoke(stdout)
        if smoke["source_fingerprint"] != FROZEN_V11_FINGERPRINT:
            raise RuntimeError("V11 source fingerprint drifted")
        print(json.dumps({"mode": "SMOKE_NO_PERFORMANCE", **smoke}, ensure_ascii=False, sort_keys=True))
        print("ORTHOGONAL_EVENT_FACTOR_V4_SMOKE_OK")
        return 0

    rows = parse_formal_output(stdout)
    if rows["V11-CONTROL"]["fingerprint"] != FROZEN_V11_FINGERPRINT:
        raise RuntimeError("formal V11 fingerprint drifted")
    document = write_outputs(output_dir, rows)
    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print("ORTHOGONAL_EVENT_FACTOR_V4_FORMAL_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
