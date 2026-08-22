#!/usr/bin/env python3
"""Run IWD versus SPY matched-total-return production-path role trial without comparator mismatch."""
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
FRAGMENT = ROOT / "tools/us_total_return_matched_role_v1.swiftpart"
ASSEMBLED = Path("/private/tmp/atm_us_total_return_matched_role_v1.swift")
BINARY = Path("/private/tmp/atm_us_total_return_matched_role_v1")
CANDIDATE_ID = "S-IWD-VS-SPY-TR-ROLE"
MATCHED_CONTROL_ID = "C-SPY-TR-PROD-SP500-ROLE"
FROZEN_V11_FINGERPRINT = "ba67c8aa24bc7168"
EVALUATION_START = "2000-05-30"
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
    run(
        [
            sys.executable,
            "scripts/assemble_strategy_metric_dump.py",
            "--fragment",
            str(FRAGMENT.relative_to(ROOT)),
            "--output",
            str(ASSEMBLED),
        ]
    )
    run(
        [
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
        ],
        timeout=300,
    )


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
        "full_cagr",
        "full_mdd",
        "full_sharpe",
        "evaluation_cagr",
        "evaluation_mdd",
        "evaluation_sharpe",
        "trades",
        "average_cash",
        "max_gross",
        "min_weight",
        "fingerprint",
        "since2020_cagr",
        "since2020_sharpe",
        "since2022_cagr",
        "since2022_sharpe",
        "fold_names",
        "fold_sharpes",
        "fold_cagrs",
        "fold_mdds",
    }
    missing = required - set(values)
    if missing:
        raise RuntimeError(f"candidate={candidate_id} missing {sorted(missing)}")
    fold_names = [value for value in values["fold_names"].split(";") if value]
    if len(fold_names) != FOLD_COUNT:
        raise RuntimeError(f"candidate={candidate_id} fold_names must have {FOLD_COUNT} values")
    return {
        "candidate_id": candidate_id,
        "full_cagr_percent": float(values["full_cagr"]),
        "full_mdd_percent": float(values["full_mdd"]),
        "full_sharpe": float(values["full_sharpe"]),
        "evaluation_cagr_percent": float(values["evaluation_cagr"]),
        "evaluation_mdd_percent": float(values["evaluation_mdd"]),
        "evaluation_sharpe": float(values["evaluation_sharpe"]),
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
        "fold_sharpes": parse_list(values["fold_sharpes"], candidate_id, "fold_sharpes"),
        "fold_cagrs_percent": parse_list(values["fold_cagrs"], candidate_id, "fold_cagrs"),
        "fold_mdds_percent": parse_list(values["fold_mdds"], candidate_id, "fold_mdds"),
    }


def parse_formal(stdout: str) -> dict[str, dict]:
    rows: dict[str, dict] = {}
    for chunk in stdout.split("candidate_id=")[1:]:
        block, separator, _ = chunk.partition("END_CANDIDATE")
        if not separator:
            raise RuntimeError("unterminated candidate block")
        row = parse_candidate(block)
        if row["candidate_id"] in rows:
            raise RuntimeError(f"duplicate candidate block: {row['candidate_id']}")
        rows[row["candidate_id"]] = row
    expected = {"V11-CONTROL", MATCHED_CONTROL_ID, CANDIDATE_ID}
    if set(rows) != expected:
        raise RuntimeError(f"formal ids mismatch expected={sorted(expected)} got={sorted(rows)}")
    return rows


def evaluate(candidate: dict, matched: dict) -> dict:
    fold_wins = sum(a >= b for a, b in zip(candidate["fold_sharpes"], matched["fold_sharpes"]))
    worst = min(candidate["fold_sharpes"])
    constraints = (
        candidate["max_gross"] <= 1.000000001
        and candidate["min_weight"] >= -1e-10
        and candidate["fingerprint"] == matched["fingerprint"]
    )
    checks = {
        "evaluation_cagr_gt_spy_matched": candidate["evaluation_cagr_percent"] > matched["evaluation_cagr_percent"],
        "evaluation_sharpe_ge_spy_matched": candidate["evaluation_sharpe"] >= matched["evaluation_sharpe"],
        "evaluation_mdd_le_10pct": candidate["evaluation_mdd_percent"] <= 10.0,
        "folds_sharpe_ge_spy_ge_5_of_7": fold_wins >= 5,
        "worst_fold_sharpe_gt_0": worst > 0,
        "constraints_and_target_identity_pass": constraints,
    }
    return {
        "admit_for_robustness": all(checks.values()),
        "folds_sharpe_ge_matched": fold_wins,
        "worst_fold_sharpe": worst,
        "admission_checks": checks,
    }


def validate_smoke(stdout: str) -> dict:
    identity = re.search(r"^SMOKE_IDENTITY_MATCH=(true|false)$", stdout, flags=re.MULTILINE)
    fingerprint = re.search(r"^source_target_fingerprint=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    event_fingerprint = re.search(r"^source_event_target_fingerprint=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    events = re.search(r"^source_event_count=(\d+)$", stdout, flags=re.MULTILINE)
    start = re.search(r"^substitution_start=(\d{4}-\d{2}-\d{2})$", stdout, flags=re.MULTILINE)
    ids = re.findall(r"^SMOKE_MQ_ROLE_PATH=(.+)$", stdout, flags=re.MULTILINE)
    target_fps = re.findall(r"^SMOKE_TARGET_FINGERPRINT=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    gross = [float(v) for v in re.findall(r"^SMOKE_MAX_GROSS=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    mins = [float(v) for v in re.findall(r"^SMOKE_MIN_WEIGHT=([-+0-9.]+)$", stdout, flags=re.MULTILINE)]
    if (
        not identity
        or identity.group(1) != "true"
        or not fingerprint
        or fingerprint.group(1) != FROZEN_V11_FINGERPRINT
        or not event_fingerprint
        or not events
        or not start
        or start.group(1) != EVALUATION_START
    ):
        raise RuntimeError("matched-total-return smoke identity failed")
    expected_event_fp = event_fingerprint.group(1)
    if ids != [MATCHED_CONTROL_ID, CANDIDATE_ID] or target_fps != [expected_event_fp, expected_event_fp]:
        raise RuntimeError(f"execution-event target drift ids={ids} fps={target_fps} source={expected_event_fp}")
    if len(gross) != 2 or any(v > 1.000000001 for v in gross) or len(mins) != 2 or any(v < -1e-10 for v in mins):
        raise RuntimeError("portfolio constraints failed")
    return {
        "identity_match": True,
        "source_target_fingerprint": fingerprint.group(1),
        "source_event_target_fingerprint": expected_event_fp,
        "source_event_count": int(events.group(1)),
        "substitution_start": start.group(1),
        "path_ids": ids,
    }


def write_outputs(output_dir: Path, rows: dict[str, dict]) -> dict:
    v11 = rows["V11-CONTROL"]
    matched = rows[MATCHED_CONTROL_ID]
    candidate = rows[CANDIDATE_ID]
    flags = evaluate(candidate, matched)
    result = {"candidate_id": CANDIDATE_ID, "matched_control_id": MATCHED_CONTROL_ID, "metrics": candidate, **flags}
    document = {
        "protocol_id": "ATM-SVP-2",
        "trial_id": "ATM-SVP2-IWD-SPY-TR-001",
        "strategy_lineage": "iwd-vs-spy-total-return-production-role-v1",
        "evaluation_start": EVALUATION_START,
        "v11_price_index_control": v11,
        "matched_control": matched,
        "candidate_results": [result],
        "admitted_candidates": [CANDIDATE_ID] if result["admit_for_robustness"] else [],
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "candidate-metrics.json").write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    with (output_dir / "candidate-metrics.csv").open("w", encoding="utf-8", newline="") as handle:
        fields = [
            "candidate_id",
            "kind",
            "evaluation_cagr_percent",
            "evaluation_mdd_percent",
            "evaluation_sharpe",
            "full_cagr_percent",
            "full_mdd_percent",
            "full_sharpe",
            "folds_sharpe_ge_matched",
            "worst_fold_sharpe",
            "admit_for_robustness",
        ]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for path_id, kind in [("V11-CONTROL", "PRICE_INDEX_BACKGROUND"), (MATCHED_CONTROL_ID, "MATCHED_CONTROL")]:
            path = rows[path_id]
            writer.writerow(
                {
                    "candidate_id": path_id,
                    "kind": kind,
                    **{key: path[key] for key in fields if key in path},
                    "folds_sharpe_ge_matched": "CONTROL",
                    "worst_fold_sharpe": min(path["fold_sharpes"]),
                    "admit_for_robustness": "CONTROL",
                }
            )
        writer.writerow(
            {
                "candidate_id": CANDIDATE_ID,
                "kind": "ASSET_ROLE_STRATEGY",
                **{key: candidate[key] for key in fields if key in candidate},
                "folds_sharpe_ge_matched": flags["folds_sharpe_ge_matched"],
                "worst_fold_sharpe": flags["worst_fold_sharpe"],
                "admit_for_robustness": flags["admit_for_robustness"],
            }
        )
    return document


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--iwd-input", required=True)
    parser.add_argument("--spy-input", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--formal", action="store_true")
    args = parser.parse_args()
    for path in (Path(args.fixture), Path(args.iwd_input), Path(args.spy_input)):
        if not path.is_file():
            raise SystemExit(f"input missing: {path}")
    compile_binary()
    env = os.environ.copy()
    env.update(
        {
            "ATM_HISTORY_FIXTURE": args.fixture,
            "ATM_US_TR_MATCHED_ROLE_V1": "1",
            "ATM_US_TR_MATCHED_ROLE_V1_IWD_PATH": args.iwd_input,
            "ATM_US_TR_MATCHED_ROLE_V1_SPY_PATH": args.spy_input,
        }
    )
    output = Path(args.output_dir)
    if args.formal:
        env["ATM_US_TR_MATCHED_ROLE_V1_FORMAL"] = "1"
        env["ATM_US_TR_MATCHED_ROLE_V1_OUTPUT_DIR"] = str(output)
    stdout = run([str(BINARY)], env=env, timeout=300)
    if "US_TR_MATCHED_ROLE_V1_COMPLETE" not in stdout:
        raise RuntimeError("Swift matched-total-return role trial did not complete")
    if not args.formal:
        smoke = validate_smoke(stdout)
        print(json.dumps({"mode": "SMOKE_NO_PERFORMANCE", **smoke}, ensure_ascii=False, sort_keys=True))
        print("US_TR_MATCHED_ROLE_V1_SMOKE_OK")
        return 0
    source_fp = re.search(r"^source_target_fingerprint=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    if not source_fp or source_fp.group(1) != FROZEN_V11_FINGERPRINT:
        raise RuntimeError("formal production V11 fingerprint drifted")
    document = write_outputs(output, parse_formal(stdout))
    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print("US_TR_MATCHED_ROLE_V1_FORMAL_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
