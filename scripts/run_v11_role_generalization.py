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
COMMON_WINDOW_RUNS = ["baseline_common_window", *FORMAL_CANDIDATES]
ALL_RUNS = ["baseline_identity", *COMMON_WINDOW_RUNS]
FORMAL_PROTOCOL_ID = "ATM-SVP-2"


def evaluate_g4_v2(
    *,
    common_baseline: dict,
    one_slot_metrics: list[dict],
    all_alternate: dict,
) -> dict:
    if len(one_slot_metrics) != 5:
        raise ValueError("ATM-SVP-2 G4 requires exactly five one-slot metrics")

    one_slot_sharpes = [float(row["sharpe"]) for row in one_slot_metrics]
    median_one_slot = sorted(one_slot_sharpes)[2]
    common_sharpe = float(common_baseline["sharpe"])
    common_mdd = float(common_baseline["mdd_percent"])
    one_slot_min = 0.50 * common_sharpe
    all_alt_sharpe_min = 0.50 * common_sharpe
    all_alt_mdd_max = min(25.0, 1.25 * common_mdd)

    def constraints_pass(row: dict) -> bool:
        return float(row["max_gross"]) <= 1.000000001 and float(row["min_weight"]) >= -1e-10

    positive_count = sum(value > 0 for value in one_slot_sharpes)
    all_candidate_constraints = all(constraints_pass(row) for row in [*one_slot_metrics, all_alternate])
    checks = {
        "common_reference_cagr_gt_0": float(common_baseline["cagr_percent"]) > 0,
        "common_reference_sharpe_gt_0": common_sharpe > 0,
        "common_reference_mdd_le_25pct": common_mdd <= 25.0,
        "common_reference_constraints_pass": constraints_pass(common_baseline),
        "positive_one_slot_sharpe_count_ge_4": positive_count >= 4,
        "one_slot_median_sharpe_relative_pass": median_one_slot >= one_slot_min,
        "all_alternate_cagr_gt_0": float(all_alternate["cagr_percent"]) > 0,
        "all_alternate_sharpe_relative_pass": float(all_alternate["sharpe"]) >= all_alt_sharpe_min,
        "all_alternate_mdd_relative_pass": float(all_alternate["mdd_percent"]) <= all_alt_mdd_max,
        "all_candidate_constraints_pass": all_candidate_constraints,
    }
    return {
        "pass": all(checks.values()),
        "checks": checks,
        "thresholds": {
            "one_slot_median_sharpe_min": one_slot_min,
            "all_alternate_sharpe_min": all_alt_sharpe_min,
            "all_alternate_mdd_max_percent": all_alt_mdd_max,
        },
        "observed": {
            "positive_one_slot_sharpe_count": positive_count,
            "one_slot_median_sharpe": median_one_slot,
        },
    }


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


def expected_evaluation_window(manifest: dict) -> tuple[str, str]:
    configured = manifest.get("evaluation_window") or {}
    start = configured.get("start") or max(slot["metadata_coverage_start"] for slot in manifest["role_slots"])
    end = configured.get("end") or min(slot["metadata_coverage_end"] for slot in manifest["role_slots"])
    if start >= end:
        raise SystemExit(f"Invalid G4 common evaluation window: {start}..{end}")
    return str(start), str(end)


def validate_common_fixture(fixture_path: Path, manifest: dict) -> tuple[str, str]:
    document = json.loads(fixture_path.read_text(encoding="utf-8"))
    normalization = document.get("g4_normalization") or {}
    expected_start, expected_end = expected_evaluation_window(manifest)
    window = normalization.get("evaluation_window") or {}
    if window.get("start") != expected_start or window.get("end") != expected_end:
        raise SystemExit(
            f"G4 common fixture window mismatch: expected={expected_start}..{expected_end}, "
            f"got={window.get('start')}..{window.get('end')}"
        )
    expected_symbols = {
        "atm_g4_gold_safe_haven",
        "atm_g4_us_growth_equity",
        "atm_g4_us_broad_equity",
        "atm_g4_china_large_equity",
        "atm_g4_china_broad_equity",
    }
    if set(normalization.get("role_symbols") or []) != expected_symbols:
        raise SystemExit("G4 common fixture does not contain exactly five neutral role symbols")
    return expected_start, expected_end


def validate_formal_authorization(manifest_path: Path, authorization_path: Path) -> dict:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    authorization = json.loads(authorization_path.read_text(encoding="utf-8"))
    if manifest.get("status") != "FROZEN_UNOPENED":
        raise SystemExit("Formal G4 manifest must be FROZEN_UNOPENED")
    if authorization.get("protocol_id") != FORMAL_PROTOCOL_ID:
        raise SystemExit(f"Formal G4 authorization must be {FORMAL_PROTOCOL_ID}")
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
    parser.add_argument("--baseline-fixture", required=True, help="Original full-history V11 fixture for frozen identity control")
    parser.add_argument("--fixture", required=True, help="Role-normalized fixture clipped to the frozen common evaluation window")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--formal", action="store_true")
    parser.add_argument("--holdout-authorization")
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()

    baseline_fixture = Path(args.baseline_fixture)
    fixture = Path(args.fixture)
    manifest = Path(args.manifest)
    output_dir = Path(args.output_dir)
    if not baseline_fixture.is_file() or not fixture.is_file() or not manifest.is_file():
        raise SystemExit("baseline fixture/common fixture/manifest missing")
    manifest_document = json.loads(manifest.read_text(encoding="utf-8"))
    common_start, common_end = validate_common_fixture(fixture, manifest_document)
    output_dir.mkdir(parents=True, exist_ok=True)

    authorization = None
    if args.formal:
        if not args.holdout_authorization:
            raise SystemExit("Formal G4 requires --holdout-authorization")
        authorization = validate_formal_authorization(manifest, Path(args.holdout_authorization))

    compile_binary()

    def execute(candidate_id: str) -> tuple[str, str]:
        env = os.environ.copy()
        selected_fixture = baseline_fixture if candidate_id == "baseline_identity" else fixture
        env.update({
            "ATM_HISTORY_FIXTURE": str(selected_fixture),
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
    common_baseline = results["baseline_common_window"]["metrics"]
    candidates = [results[candidate_id] for candidate_id in FORMAL_CANDIDATES]
    one_slot_metrics = [results[candidate_id]["metrics"] for candidate_id in ROLE_CANDIDATES]
    all_alternate = results["all_alternate"]["metrics"]
    v2_evaluation = evaluate_g4_v2(
        common_baseline=common_baseline,
        one_slot_metrics=one_slot_metrics,
        all_alternate=all_alternate,
    )
    common_baseline_checks = {
        "cagr_gt_0": v2_evaluation["checks"]["common_reference_cagr_gt_0"],
        "sharpe_gt_0": v2_evaluation["checks"]["common_reference_sharpe_gt_0"],
        "mdd_le_25pct": v2_evaluation["checks"]["common_reference_mdd_le_25pct"],
        "constraints_pass": v2_evaluation["checks"]["common_reference_constraints_pass"],
        "uses_no_replacement_roles": results["baseline_common_window"]["replaced_roles"] == [],
    }
    common_baseline_status = "PASS" if all(common_baseline_checks.values()) else "FAIL"
    constraint_checks = {
        candidate_id: {
            "gross_le_100pct": results[candidate_id]["metrics"]["max_gross"] <= 1.000000001,
            "no_negative_weights": results[candidate_id]["metrics"]["min_weight"] >= -1e-10,
        }
        for candidate_id in FORMAL_CANDIDATES
    }
    g4_checks = {
        "full_history_baseline_identity_pass": baseline_status == "PASS",
        "common_window_baseline_control_pass": common_baseline_status == "PASS",
        "positive_one_slot_sharpe_count_ge_4": v2_evaluation["checks"]["positive_one_slot_sharpe_count_ge_4"],
        "one_slot_median_sharpe_relative_pass": v2_evaluation["checks"]["one_slot_median_sharpe_relative_pass"],
        "all_alternate_cagr_gt_0": v2_evaluation["checks"]["all_alternate_cagr_gt_0"],
        "all_alternate_sharpe_relative_pass": v2_evaluation["checks"]["all_alternate_sharpe_relative_pass"],
        "all_alternate_mdd_relative_pass": v2_evaluation["checks"]["all_alternate_mdd_relative_pass"],
        "all_candidate_constraints_pass": v2_evaluation["checks"]["all_candidate_constraints_pass"],
        "exact_six_formal_candidates_reported": len(candidates) == 6,
    }
    formal_status = "PASS" if all(g4_checks.values()) else "FAIL"

    document = {
        "protocol_id": FORMAL_PROTOCOL_ID,
        "component": "G4_DOMAIN_PRESERVING_GENERALIZATION",
        "formal": args.formal,
        "evidence_class": "H2_PRISTINE_HOLDOUT" if args.formal else "D0_EXPOSED_EXPLORATORY",
        "holdout_authorization": authorization,
        "evaluation_window": {"start": common_start, "end": common_end},
        "baseline_identity": results["baseline_identity"],
        "baseline_checks": baseline_checks,
        "baseline_status": baseline_status,
        "baseline_common_window": results["baseline_common_window"],
        "baseline_common_window_checks": common_baseline_checks,
        "baseline_common_window_status": common_baseline_status,
        "candidate_results": candidates,
        "constraint_checks": constraint_checks,
        "g4_relative_thresholds": v2_evaluation["thresholds"],
        "positive_one_slot_sharpe_count": v2_evaluation["observed"]["positive_one_slot_sharpe_count"],
        "one_slot_median_sharpe": v2_evaluation["observed"]["one_slot_median_sharpe"],
        "g4_checks": g4_checks,
        "g4_status": formal_status if args.formal else "EXPLORATORY_NOT_EVIDENCE",
        "scope_note": "ATM-SVP-2 compares all six formal role substitutions to the same mechanically derived common-window identity baseline. Development mode is plumbing only; formal evidence additionally requires the committed/burned pristine-holdout authorization and immutable result evidence.",
    }
    json_path = output_dir / "candidate-metrics.json"
    json_path.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    csv_path = output_dir / "candidate-metrics.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "candidate_id", "replaced_roles", "cagr_percent", "mdd_percent", "vol_percent", "sharpe", "trades", "max_gross", "min_weight", "fingerprint"
        ])
        writer.writeheader()
        for row in [results["baseline_identity"], results["baseline_common_window"], *candidates]:
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
    if baseline_status != "PASS" or common_baseline_status != "PASS":
        return 3
    if args.formal and formal_status != "PASS":
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
