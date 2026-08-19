#!/usr/bin/env python3
"""ATM-SVP G4 role-preserving generalization runner.

The Swift fragment keeps the five V11 role symbols fixed and substitutes only each role's
pre-normalized price series. Python compiles/orchestrates the exact App engine and applies frozen
G4 gates; it does not simulate strategy returns.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import csv
import hashlib
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FRAGMENT = ROOT / "tools/v11_role_generalization.swiftpart"
ASSEMBLED = Path("/private/tmp/atm_v11_role_generalization.swift")
BINARY = Path("/private/tmp/atm_v11_role_generalization")
EXPECTED_BASELINE = {
    "cagr_percent": 14.345615,
    "mdd_percent": 7.689054,
    "vol_percent": 8.760667,
    "sharpe": 1.522263,
    "trades": 451,
    "fingerprint": "ba67c8aa24bc7168",
}
ROLE_CANDIDATES = [
    "one_slot_gold_safe_haven",
    "one_slot_us_growth_equity",
    "one_slot_us_broad_equity",
    "one_slot_china_large_equity",
    "one_slot_china_broad_equity",
]
FORMAL_CANDIDATES = [*ROLE_CANDIDATES, "all_alternate"]
ALL_RUNS = ["baseline_identity", *FORMAL_CANDIDATES]


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


def parse_candidate(stdout: str, candidate_id: str) -> dict:
    if "V11_ROLE_GENERALIZATION_COMPLETE" not in stdout:
        raise RuntimeError(f"candidate={candidate_id} incomplete Swift output")
    id_match = re.search(r"^candidate_id=(.+)$", stdout, flags=re.MULTILINE)
    if not id_match or id_match.group(1).strip() != candidate_id:
        raise RuntimeError(f"candidate id mismatch for {candidate_id}")
    def number(key: str) -> float:
        match = re.search(rf"^{re.escape(key)}=([-+0-9.]+)$", stdout, flags=re.MULTILINE)
        if not match:
            raise RuntimeError(f"candidate={candidate_id} missing {key}")
        return float(match.group(1))
    trades = re.search(r"^trades=(\d+)$", stdout, flags=re.MULTILINE)
    fp = re.search(r"^fingerprint=([0-9a-f]+)$", stdout, flags=re.MULTILINE)
    roles = re.search(r"^replaced_roles=(.*)$", stdout, flags=re.MULTILINE)
    if not trades or not fp or not roles:
        raise RuntimeError(f"candidate={candidate_id} missing discrete fields")
    return {
        "candidate_id": candidate_id,
        "replaced_roles": [x for x in roles.group(1).split(";") if x],
        "metrics": {
            "cagr_percent": number("cagr"),
            "mdd_percent": number("mdd"),
            "vol_percent": number("vol"),
            "sharpe": number("sharpe"),
            "trades": int(trades.group(1)),
            "max_gross": number("max_gross"),
            "min_weight": number("min_weight"),
            "fingerprint": fp.group(1),
        },
    }


def close(a: float, b: float, tolerance: float) -> bool:
    return math.isclose(a, b, rel_tol=0.0, abs_tol=tolerance)


def validate_formal_authorization(manifest_path: Path, authorization_path: Path) -> dict:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    authorization = json.loads(authorization_path.read_text(encoding="utf-8"))
    if manifest.get("status") != "FROZEN_UNOPENED":
        raise SystemExit("Formal G4 manifest must be FROZEN_UNOPENED")
    if authorization.get("protocol_id") != "ATM-SVP-1":
        raise SystemExit("Formal G4 authorization must be ATM-SVP-1")
    if authorization.get("holdout_id") != manifest.get("holdout_id"):
        raise SystemExit("Holdout authorization does not match manifest")
    if authorization.get("frozen_manifest_path") != manifest_path.as_posix():
        raise SystemExit("Holdout authorization manifest path mismatch")
    actual_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    if authorization.get("frozen_manifest_sha256") != actual_sha:
        raise SystemExit("Holdout authorization does not bind to the exact manifest SHA")
    validation = subprocess.run(
        [sys.executable, "scripts/strategy_validation_holdout.py", "validate", "--manifest", str(manifest_path)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if validation.returncode != 0:
        raise SystemExit(f"Formal holdout manifest validation failed:\n{validation.stdout}")
    return authorization


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--formal", action="store_true")
    parser.add_argument("--holdout-authorization")
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()

    fixture = Path(args.fixture)
    manifest = Path(args.manifest)
    output_dir = Path(args.output_dir)
    if not fixture.is_file() or not manifest.is_file():
        raise SystemExit("fixture/manifest missing")
    output_dir.mkdir(parents=True, exist_ok=True)

    authorization = None
    if args.formal:
        if not args.holdout_authorization:
            raise SystemExit("Formal G4 requires --holdout-authorization")
        authorization = validate_formal_authorization(manifest, Path(args.holdout_authorization))

    compile_binary()

    def execute(candidate_id: str) -> tuple[str, str]:
        env = os.environ.copy()
        env.update({
            "ATM_HISTORY_FIXTURE": str(fixture),
            "ATM_V11_ROLE_GENERALIZATION": "1",
            "ATM_V11_ROLE_MANIFEST": str(manifest),
            "ATM_V11_ROLE_CANDIDATE": candidate_id,
            "ATM_V11_ROLE_OUTPUT_DIR": str(output_dir),
        })
        return candidate_id, run([str(BINARY)], env=env, timeout=300)

    outputs: dict[str, str] = {}
    max_workers = max(1, min(args.workers, len(ALL_RUNS)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = [pool.submit(execute, candidate_id) for candidate_id in ALL_RUNS]
        for future in concurrent.futures.as_completed(futures):
            candidate_id, stdout = future.result()
            outputs[candidate_id] = stdout

    results = {candidate_id: parse_candidate(outputs[candidate_id], candidate_id) for candidate_id in ALL_RUNS}
    baseline = results["baseline_identity"]["metrics"]
    baseline_checks = {
        "cagr_matches_frozen_within_0_01pp": close(baseline["cagr_percent"], EXPECTED_BASELINE["cagr_percent"], 0.01),
        "mdd_matches_frozen_within_0_01pp": close(baseline["mdd_percent"], EXPECTED_BASELINE["mdd_percent"], 0.01),
        "sharpe_matches_frozen_within_0_001": close(baseline["sharpe"], EXPECTED_BASELINE["sharpe"], 0.001),
        "trade_count_matches_frozen": baseline["trades"] == EXPECTED_BASELINE["trades"],
        "target_fingerprint_matches_frozen": baseline["fingerprint"] == EXPECTED_BASELINE["fingerprint"],
        "gross_constraint": baseline["max_gross"] <= 1.000000001,
        "no_negative_weights": baseline["min_weight"] >= -1e-10,
    }
    baseline_status = "PASS" if all(baseline_checks.values()) else "FAIL"

    candidates = [results[candidate_id] for candidate_id in FORMAL_CANDIDATES]
    one_slot_sharpes = [results[candidate_id]["metrics"]["sharpe"] for candidate_id in ROLE_CANDIDATES]
    median_one_slot = sorted(one_slot_sharpes)[len(one_slot_sharpes) // 2]
    all_alternate = results["all_alternate"]["metrics"]
    constraint_checks = {
        candidate_id: {
            "gross_le_100pct": results[candidate_id]["metrics"]["max_gross"] <= 1.000000001,
            "no_negative_weights": results[candidate_id]["metrics"]["min_weight"] >= -1e-10,
        }
        for candidate_id in FORMAL_CANDIDATES
    }
    g4_checks = {
        "baseline_identity_pass": baseline_status == "PASS",
        "positive_one_slot_sharpe_count_ge_4": sum(value > 0 for value in one_slot_sharpes) >= 4,
        "one_slot_median_sharpe_ge_0_761": median_one_slot >= 0.761,
        "all_alternate_cagr_gt_0": all_alternate["cagr_percent"] > 0,
        "all_alternate_sharpe_ge_0_761": all_alternate["sharpe"] >= 0.761,
        "all_alternate_mdd_le_15_378108pct": all_alternate["mdd_percent"] <= 15.378108,
        "all_candidate_constraints_pass": all(all(row.values()) for row in constraint_checks.values()),
        "exact_six_formal_candidates_reported": len(candidates) == 6,
    }
    formal_status = "PASS" if all(g4_checks.values()) else "FAIL"

    document = {
        "protocol_id": "ATM-SVP-1",
        "component": "G4_DOMAIN_PRESERVING_GENERALIZATION",
        "formal": args.formal,
        "evidence_class": "H2_PRISTINE_HOLDOUT" if args.formal else "D0_EXPOSED_EXPLORATORY",
        "holdout_authorization": authorization,
        "baseline_identity": results["baseline_identity"],
        "baseline_checks": baseline_checks,
        "baseline_status": baseline_status,
        "candidate_results": candidates,
        "constraint_checks": constraint_checks,
        "one_slot_median_sharpe": median_one_slot,
        "g4_checks": g4_checks,
        "g4_status": formal_status if args.formal else "EXPLORATORY_NOT_EVIDENCE",
        "scope_note": "Development mode validates plumbing only. Formal status is valid only with a committed/burned holdout authorization and immutable result evidence.",
    }
    json_path = output_dir / "candidate-metrics.json"
    json_path.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    csv_path = output_dir / "candidate-metrics.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "candidate_id", "replaced_roles", "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades", "max_gross", "min_weight", "fingerprint"
        ])
        writer.writeheader()
        for row in [results["baseline_identity"], *candidates]:
            m = row["metrics"]
            writer.writerow({
                "candidate_id": row["candidate_id"],
                "replaced_roles": ";".join(row["replaced_roles"]),
                "cagr_percent": m["cagr_percent"],
                "mdd_percent": m["mdd_percent"],
                "vol_percent": m["vol_percent"],
                "sharpe": m["sharpe"],
                "trades": m["trades"],
                "max_gross": m["max_gross"],
                "min_weight": m["min_weight"],
                "fingerprint": m["fingerprint"],
            })
    for candidate_id, stdout in outputs.items():
        (output_dir / f"{candidate_id}-stdout.txt").write_text(stdout, encoding="utf-8")

    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print(f"G4_ROLE_GENERALIZATION_{document['g4_status']}")
    print(f"OUTPUT_JSON={json_path}")
    print(f"OUTPUT_CSV={csv_path}")
    if baseline_status != "PASS":
        return 3
    if args.formal and formal_status != "PASS":
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
