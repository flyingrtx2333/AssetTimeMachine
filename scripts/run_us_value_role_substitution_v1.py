#!/usr/bin/env python3
"""Run preregistered U.S. value-role substitutions through the shared Swift App engine."""
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
FRAGMENT = ROOT / "tools/us_value_role_substitution_v1.swiftpart"
ASSEMBLED = Path("/private/tmp/atm_us_value_role_v1.swift")
BINARY = Path("/private/tmp/atm_us_value_role_v1")
CANDIDATES = ("F-IWD-SP500-ROLE", "F-VBR-SP500-ROLE")
FOLD_COUNT = 7


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
        str(ASSEMBLED),
        "-o", str(BINARY),
    ], timeout=300)


def parse_float_list(raw: str, *, candidate_id: str, field: str) -> list[float]:
    values = [float(value) for value in raw.split(";") if value]
    if len(values) != FOLD_COUNT:
        raise RuntimeError(f"candidate={candidate_id} {field} must have {FOLD_COUNT} values")
    return values


def parse_candidate(block: str) -> dict:
    lines = [line.strip() for line in block.splitlines() if line.strip()]
    candidate_id = lines[0]
    values = dict(line.split("=", 1) for line in lines[1:] if "=" in line)
    required = {
        "cagr", "mdd", "vol", "sharpe", "trades", "average_cash", "max_gross", "min_weight",
        "fingerprint", "since2020_cagr", "since2020_sharpe", "since2022_cagr", "since2022_sharpe",
        "fold_names", "fold_sharpes", "fold_cagrs", "fold_mdds",
    }
    missing = required - set(values)
    if missing:
        raise RuntimeError(f"candidate={candidate_id} missing {sorted(missing)}")
    fold_names = [value for value in values["fold_names"].split(";") if value]
    if len(fold_names) != FOLD_COUNT:
        raise RuntimeError(f"candidate={candidate_id} fold_names must have {FOLD_COUNT} values")
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
        if row["candidate_id"] in rows:
            raise RuntimeError(f"duplicate candidate block: {row['candidate_id']}")
        rows[row["candidate_id"]] = row
    expected = {"V11-CONTROL", *CANDIDATES}
    if set(rows) != expected:
        raise RuntimeError(f"formal path ids mismatch expected={sorted(expected)} got={sorted(rows)}")
    return rows


def evaluate_candidate(metrics: dict, *, v11: dict) -> dict:
    fold_wins = sum(
        candidate >= control
        for candidate, control in zip(metrics["fold_sharpes"], v11["fold_sharpes"])
    )
    worst = min(metrics["fold_sharpes"])
    constraints_pass = (
        metrics["max_gross"] <= 1.000000001
        and metrics["min_weight"] >= -1e-10
    )
    checks = {
        "cagr_gt_v11": metrics["cagr_percent"] > v11["cagr_percent"],
        "sharpe_ge_v11": metrics["sharpe"] >= v11["sharpe"],
        "mdd_le_10pct": metrics["mdd_percent"] <= 10.0,
        "folds_sharpe_ge_v11_ge_5_of_7": fold_wins >= 5,
        "worst_fold_sharpe_gt_0": worst > 0,
        "constraints_pass": constraints_pass,
    }
    return {
        "admit_for_robustness": all(checks.values()),
        "constraints_pass": constraints_pass,
        "folds_sharpe_ge_v11": fold_wins,
        "worst_fold_sharpe": worst,
        "admission_checks": checks,
    }


def validate_smoke(stdout: str) -> dict:
    identity = re.search(r"^SMOKE_IDENTITY_MATCH=(true|false)$", stdout, flags=re.MULTILINE)
    fingerprint = re.search(r"^source_target_fingerprint=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    event_count = re.search(r"^source_event_count=(\d+)$", stdout, flags=re.MULTILINE)
    ids = re.findall(r"^SMOKE_VALUE_ROLE_PATH=(.+)$", stdout, flags=re.MULTILINE)
    gross = [float(value) for value in re.findall(r"^SMOKE_MAX_GROSS=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    minimums = [float(value) for value in re.findall(r"^SMOKE_MIN_WEIGHT=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    if not identity or identity.group(1) != "true" or not fingerprint or not event_count:
        raise RuntimeError("identity/fingerprint/event smoke check failed")
    if ids != list(CANDIDATES):
        raise RuntimeError(f"smoke candidate ids mismatch: {ids}")
    if len(gross) != 2 or any(value > 1.000000001 for value in gross):
        raise RuntimeError(f"gross constraint failed: {gross}")
    if len(minimums) != 2 or any(value < -1e-10 for value in minimums):
        raise RuntimeError(f"negative-weight constraint failed: {minimums}")
    return {
        "identity_match": True,
        "source_target_fingerprint": fingerprint.group(1),
        "source_event_count": int(event_count.group(1)),
        "candidate_ids": ids,
    }


def write_outputs(output_dir: Path, rows: dict[str, dict]) -> dict:
    v11 = rows["V11-CONTROL"]
    results = []
    for candidate_id in CANDIDATES:
        metrics = rows[candidate_id]
        flags = evaluate_candidate(metrics, v11=v11)
        results.append({"candidate_id": candidate_id, "metrics": metrics, **flags})
    document = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": "ATM-SVP2-US-VALUE-ROLE-001",
        "strategy_lineage": "us-value-role-substitution-v1",
        "common_evaluation_start": "2004-01-30",
        "v11_control": v11,
        "candidate_results": results,
        "admitted_candidates": [row["candidate_id"] for row in results if row["admit_for_robustness"]],
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "candidate-metrics.json").write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    fields = [
        "candidate_id", "kind", "cagr_percent", "mdd_percent", "sharpe", "trades",
        "average_cash_ratio", "max_gross", "min_weight", "folds_sharpe_ge_v11",
        "worst_fold_sharpe", "admit_for_robustness",
    ]
    with (output_dir / "candidate-metrics.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerow({
            "candidate_id": "V11-CONTROL", "kind": "CONTROL",
            **{key: v11[key] for key in ("cagr_percent", "mdd_percent", "sharpe", "trades", "average_cash_ratio", "max_gross", "min_weight")},
            "folds_sharpe_ge_v11": "CONTROL", "worst_fold_sharpe": min(v11["fold_sharpes"]), "admit_for_robustness": "CONTROL",
        })
        for result in results:
            metrics = result["metrics"]
            writer.writerow({
                "candidate_id": result["candidate_id"], "kind": "ASSET_ROLE_STRATEGY",
                **{key: metrics[key] for key in ("cagr_percent", "mdd_percent", "sharpe", "trades", "average_cash_ratio", "max_gross", "min_weight")},
                "folds_sharpe_ge_v11": result["folds_sharpe_ge_v11"],
                "worst_fold_sharpe": result["worst_fold_sharpe"],
                "admit_for_robustness": result["admit_for_robustness"],
            })
    return document


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--iwd-input", required=True)
    parser.add_argument("--vbr-input", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--formal", action="store_true")
    args = parser.parse_args()

    for path in (Path(args.fixture), Path(args.iwd_input), Path(args.vbr_input)):
        if not path.is_file():
            raise SystemExit(f"input missing: {path}")
    compile_binary()
    env = os.environ.copy()
    env.update({
        "ATM_HISTORY_FIXTURE": args.fixture,
        "ATM_US_VALUE_ROLE_V1": "1",
        "ATM_US_VALUE_ROLE_V1_IWD_PATH": args.iwd_input,
        "ATM_US_VALUE_ROLE_V1_VBR_PATH": args.vbr_input,
    })
    output_dir = Path(args.output_dir)
    if args.formal:
        env["ATM_US_VALUE_ROLE_V1_FORMAL"] = "1"
        env["ATM_US_VALUE_ROLE_V1_OUTPUT_DIR"] = str(output_dir)
    stdout = run([str(BINARY)], env=env, timeout=300)
    if "US_VALUE_ROLE_V1_COMPLETE" not in stdout:
        raise RuntimeError("Swift U.S. value role trial did not complete")

    if not args.formal:
        smoke = validate_smoke(stdout)
        print(json.dumps({"mode": "SMOKE_NO_PERFORMANCE", **smoke}, ensure_ascii=False, sort_keys=True))
        print("US_VALUE_ROLE_V1_SMOKE_OK")
        return 0

    document = write_outputs(output_dir, parse_formal_output(stdout))
    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print("US_VALUE_ROLE_V1_FORMAL_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
