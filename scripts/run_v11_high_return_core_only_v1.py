#!/usr/bin/env python3
"""Run the calendar-alignment repair of preregistered MTUM/QUAL role substitutions on the frozen production V11 target path."""
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
FRAGMENT = ROOT / "tools/v11_high_return_core_only_v1.swiftpart"
ASSEMBLED = Path("/private/tmp/atm_v11_high_core_only_v1.swift")
BINARY = Path("/private/tmp/atm_v11_high_core_only_v1")
CANDIDATES = ("S-V11-HIGHCORE-ONLY",)
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
        str(ASSEMBLED), "-o", str(BINARY),
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
        "cagr", "mdd", "vol", "sharpe", "trades", "average_cash", "max_gross", "min_weight", "fingerprint",
        "since2020_cagr", "since2020_sharpe", "since2022_cagr", "since2022_sharpe",
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
        "cagr_percent": float(values["cagr"]), "mdd_percent": float(values["mdd"]), "vol_percent": float(values["vol"]), "sharpe": float(values["sharpe"]),
        "trades": int(values["trades"]), "average_cash_ratio": float(values["average_cash"]), "max_gross": float(values["max_gross"]), "min_weight": float(values["min_weight"]),
        "fingerprint": values["fingerprint"], "since2020_cagr_percent": float(values["since2020_cagr"]), "since2020_sharpe": float(values["since2020_sharpe"]),
        "since2022_cagr_percent": float(values["since2022_cagr"]), "since2022_sharpe": float(values["since2022_sharpe"]),
        "fold_names": fold_names, "fold_sharpes": parse_list(values["fold_sharpes"], candidate_id, "fold_sharpes"),
        "fold_cagrs_percent": parse_list(values["fold_cagrs"], candidate_id, "fold_cagrs"), "fold_mdds_percent": parse_list(values["fold_mdds"], candidate_id, "fold_mdds"),
    }


def parse_formal(stdout: str) -> dict[str, dict]:
    rows: dict[str, dict] = {}
    for chunk in stdout.split("candidate_id=")[1:]:
        block, separator, _ = chunk.partition("END_CANDIDATE")
        if not separator:
            raise RuntimeError("unterminated candidate block")
        row = parse_candidate(block)
        rows[row["candidate_id"]] = row
    expected = {"V11-CONTROL", *CANDIDATES}
    if set(rows) != expected:
        raise RuntimeError(f"formal ids mismatch expected={sorted(expected)} got={sorted(rows)}")
    return rows


def evaluate(metrics: dict, v11: dict, *, fee_invariant: bool) -> dict:
    fold_wins = sum(a >= b for a, b in zip(metrics["fold_sharpes"], v11["fold_sharpes"]))
    worst = min(metrics["fold_sharpes"])
    checks = {
        "cagr_gt_v11": metrics["cagr_percent"] > v11["cagr_percent"],
        "sharpe_ge_v11": metrics["sharpe"] >= v11["sharpe"],
        "mdd_le_10pct": metrics["mdd_percent"] <= 10.0,
        "folds_sharpe_ge_v11_ge_5_of_7": fold_wins >= 5,
        "worst_fold_sharpe_gt_0": worst > 0,
        "constraints_pass": metrics["max_gross"] <= 1.000000001 and metrics["min_weight"] >= -1e-10,
        "fee_invariant_target_fingerprint": fee_invariant,
    }
    return {"admit_for_robustness": all(checks.values()), "folds_sharpe_ge_v11": fold_wins, "worst_fold_sharpe": worst, "admission_checks": checks}


def extract_fingerprints(stdout: str) -> tuple[str, str, str]:
    control = re.search(r"^control_fingerprint=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    candidate = re.search(r"^candidate_fingerprint=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    low_fee = re.search(r"^candidate_low_fee_fingerprint=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    if not control or not candidate or not low_fee:
        raise RuntimeError("fingerprint audit output incomplete")
    return control.group(1), candidate.group(1), low_fee.group(1)


def validate_smoke(stdout: str) -> dict:
    control_fp, candidate_fp, low_fee_fp = extract_fingerprints(stdout)
    gross = re.search(r"^candidate_max_gross=([-+0-9.]+)$", stdout, flags=re.MULTILINE)
    minimum = re.search(r"^candidate_min_weight=([-+0-9.]+)$", stdout, flags=re.MULTILINE)
    if not gross or not minimum:
        raise RuntimeError("smoke constraints missing")
    if control_fp != FROZEN_V11_FINGERPRINT:
        raise RuntimeError("V11 control fingerprint drifted")
    if candidate_fp != low_fee_fp:
        raise RuntimeError("candidate target fingerprint changes with user fee")
    max_gross = float(gross.group(1))
    min_weight = float(minimum.group(1))
    if max_gross > 1.000000001 or min_weight < -1e-10:
        raise RuntimeError("candidate portfolio constraints failed")
    return {"control_fingerprint": control_fp, "candidate_fingerprint": candidate_fp, "fee_invariant_target": True, "max_gross": max_gross, "min_weight": min_weight}


def write_outputs(output_dir: Path, rows: dict[str, dict], stdout: str) -> dict:
    v11 = rows["V11-CONTROL"]
    candidate = rows[CANDIDATES[0]]
    control_fp, candidate_fp, low_fee_fp = extract_fingerprints(stdout)
    if control_fp != FROZEN_V11_FINGERPRINT or v11["fingerprint"] != FROZEN_V11_FINGERPRINT:
        raise RuntimeError("formal V11 fingerprint drifted")
    fee_invariant = candidate_fp == low_fee_fp == candidate["fingerprint"]
    flags = evaluate(candidate, v11, fee_invariant=fee_invariant)
    result = {"candidate_id": CANDIDATES[0], "metrics": candidate, **flags}
    document = {
        "protocol_id": "ATM-SVP-2", "trial_id": "ATM-SVP2-V11-HIGHCORE-001", "strategy_lineage": "v11-simplified-high-return-core-only-v1",
        "v11_control": v11, "candidate_results": [result],
        "admitted_candidates": [CANDIDATES[0]] if result["admit_for_robustness"] else [],
        "fee_invariance": {"one_percent_fingerprint": candidate_fp, "zero_point_zero_three_percent_fingerprint": low_fee_fp, "pass": fee_invariant},
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "candidate-metrics.json").write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    with (output_dir / "candidate-metrics.csv").open("w", encoding="utf-8", newline="") as handle:
        fields = ["candidate_id","kind","cagr_percent","mdd_percent","vol_percent","sharpe","trades","average_cash_ratio","max_gross","min_weight","fingerprint","folds_sharpe_ge_v11","worst_fold_sharpe","admit_for_robustness"]
        writer = csv.DictWriter(handle, fieldnames=fields); writer.writeheader()
        writer.writerow({"candidate_id":"V11-CONTROL","kind":"CONTROL",**{k:v11[k] for k in fields if k in v11},"folds_sharpe_ge_v11":"CONTROL","worst_fold_sharpe":min(v11["fold_sharpes"]),"admit_for_robustness":"CONTROL"})
        writer.writerow({"candidate_id":CANDIDATES[0],"kind":"STRATEGY",**{k:candidate[k] for k in fields if k in candidate},"folds_sharpe_ge_v11":flags["folds_sharpe_ge_v11"],"worst_fold_sharpe":flags["worst_fold_sharpe"],"admit_for_robustness":flags["admit_for_robustness"]})
    return document


def main() -> int:
    parser=argparse.ArgumentParser(); parser.add_argument("--fixture",required=True); parser.add_argument("--output-dir",required=True); parser.add_argument("--formal",action="store_true"); args=parser.parse_args()
    fixture = Path(args.fixture)
    if not fixture.is_file(): raise SystemExit(f"fixture missing: {fixture}")
    compile_binary(); env=os.environ.copy(); env.update({"ATM_HISTORY_FIXTURE":str(fixture),"ATM_V11_HIGH_CORE_ONLY_V1":"1"}); output=Path(args.output_dir)
    if args.formal: env["ATM_V11_HIGH_CORE_ONLY_V1_FORMAL"]="1"; env["ATM_V11_HIGH_CORE_ONLY_V1_OUTPUT_DIR"]=str(output)
    stdout=run([str(BINARY)],env=env,timeout=300)
    if "V11_HIGH_CORE_ONLY_V1_COMPLETE" not in stdout: raise RuntimeError("Swift high-core trial did not complete")
    if not args.formal:
        smoke=validate_smoke(stdout); print(json.dumps({"mode":"SMOKE_NO_PERFORMANCE",**smoke},ensure_ascii=False,sort_keys=True)); print("V11_HIGH_CORE_ONLY_V1_SMOKE_OK"); return 0
    document=write_outputs(output,parse_formal(stdout),stdout); print(json.dumps(document,ensure_ascii=False,sort_keys=True)); print("V11_HIGH_CORE_ONLY_V1_FORMAL_COMPLETE"); return 0


if __name__ == "__main__":
    raise SystemExit(main())
