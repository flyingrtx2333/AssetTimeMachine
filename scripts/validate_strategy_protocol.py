#!/usr/bin/env python3
"""Machine-checkable governance checks for ATM-SVP-1.

This script validates protocol metadata and evidence bookkeeping. It deliberately does not
reimplement strategy simulation; App-facing strategy metrics must still come from the Swift engine.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import subprocess
from pathlib import Path
from typing import Any

DEFAULT_MANIFEST = Path(
    "tools/research-results/strategy-validation/v11-protocol-manifest.json"
)
DEFAULT_LEDGER = Path(
    "tools/research-results/strategy-validation/trial-ledger.jsonl"
)
POLICY = Path(
    "tools/research-results/strategy-validation/strategy-validation-policy-v1.json"
)
FREEZE = Path(
    "tools/research-results/strategy-validation/protocol-freeze-v1.json"
)
PUBLIC_CORE = Path("AssetTimeMachine/Backtest/PublicBacktestCore.swift")
BACKTEST_MODELS = Path("AssetTimeMachine/Backtest/BacktestModels.swift")
PROTOCOL_DOC = Path(
    "docs/strategies/validation/strategy-validation-protocol-v1.md"
)
AGENTS = Path("AGENTS.md")


class ProtocolError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProtocolError(message)


def close(a: float, b: float, tolerance: float = 1e-9) -> bool:
    return math.isclose(a, b, rel_tol=tolerance, abs_tol=tolerance)


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(value, dict), f"Manifest must be a JSON object: {path}")
    return value


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_policy_freeze() -> dict[str, Any]:
    require(POLICY.exists(), f"Frozen policy missing: {POLICY}")
    require(FREEZE.exists(), f"Protocol freeze record missing: {FREEZE}")
    freeze = read_json(FREEZE)
    require(freeze["protocol_id"] == "ATM-SVP-1", "Unexpected freeze protocol_id")
    require(freeze["protocol_version"] == 1, "Unexpected freeze protocol_version")
    frozen_files = freeze.get("files")
    require(isinstance(frozen_files, dict) and frozen_files, "Freeze record has no files")
    for raw_path, expected_hash in frozen_files.items():
        path = Path(raw_path)
        require(path.exists(), f"Frozen file missing: {path}")
        actual_hash = file_sha256(path)
        require(
            actual_hash == expected_hash,
            f"Frozen governance file changed in place: {path}; expected={expected_hash}, actual={actual_hash}. Create ATM-SVP-2 instead.",
        )
    policy = read_json(POLICY)
    require(policy["protocol_id"] == "ATM-SVP-1", "Unexpected policy protocol_id")
    require(policy["protocol_version"] == 1, "Unexpected policy protocol_version")
    return policy


def validate_policy_consistency(manifest: dict[str, Any], policy: dict[str, Any]) -> None:
    strategy = manifest["strategy"]
    require(strategy["strategy_id"] == policy["strategy_id"], "Strategy ID drifted from frozen policy")
    require(strategy["strategy_version"] == policy["strategy_version"], "Strategy version drifted from frozen policy")
    require(
        manifest["frozen_retrospective_baseline"] == policy["frozen_retrospective_baseline"],
        "Frozen retrospective baseline drifted from policy",
    )

    gates = manifest["gates"]
    require(
        gates["G2_retrospective_robustness"]["thresholds"] == policy["G2_retrospective_robustness"],
        "G2 thresholds drifted from frozen policy",
    )

    g3 = gates["G3_model_selection_risk"]
    p3 = policy["G3_model_selection_risk"]
    for key in ["dsr_probability_pass_min", "dsr_probability_weak_min", "pbo_pass_max", "pbo_strong_max"]:
        require(g3[key] == p3[key], f"G3 policy drift: {key}")
    require(g3["overall_dsr_status"] == p3["legacy_v11_dsr_status"], "G3 legacy DSR status drifted")

    g4 = gates["G4_domain_preserving_generalization"]
    p4 = policy["G4_domain_preserving_generalization"]
    for key in ["role_slots", "one_slot_runs", "all_alternate_runs", "formal_runs_allowed"]:
        require(g4[key] == p4[key], f"G4 policy drift: {key}")
    for key in [
        "positive_one_slot_sharpe_count_min",
        "one_slot_median_sharpe_retention_min",
        "all_alternate_cagr_min_exclusive",
        "all_alternate_sharpe_retention_min",
        "all_alternate_mdd_multiple_max",
    ]:
        require(g4["thresholds"][key] == p4[key], f"G4 threshold drift: {key}")

    g5 = gates["G5_execution_robustness"]
    p5 = policy["G5_execution_robustness"]
    require(g5["base"] == p5["base"], "G5 base execution assumptions drifted")
    require(g5["adverse_stress"] == p5["adverse_stress"], "G5 adverse stress assumptions drifted")
    for key in ["stress_cagr_min_exclusive", "stress_sharpe_min_exclusive", "stress_mdd_multiple_max"]:
        require(g5["thresholds"][key] == p5[key], f"G5 threshold drift: {key}")

    g6 = gates["G6_prospective_oos"]
    p6 = policy["G6_prospective_oos"]
    require(g6["protocol_threshold_freeze"] == p6["threshold_freeze"], "G6 threshold-freeze facts drifted")
    for key in ["milestones", "primary_decision_sessions", "strong_validation_sessions"]:
        require(g6[key] == p6[key], f"G6 policy drift: {key}")
    for key in ["cagr_min_exclusive", "sharpe_min_exclusive", "mdd_multiple_max"]:
        require(g6["primary_thresholds"][key] == p6["primary"][key], f"G6 primary threshold drift: {key}")
    for key in ["sharpe_retention_min", "cagr_retention_min", "mdd_multiple_max", "must_beat_cash_yield_cny"]:
        require(g6["strong_thresholds"][key] == p6["strong"][key], f"G6 strong threshold drift: {key}")


def validate_strategy_identity(manifest: dict[str, Any]) -> None:
    strategy = manifest["strategy"]
    strategy_id = strategy["strategy_id"]
    strategy_version = strategy["strategy_version"]
    app_mode = strategy["app_mode"]

    core = PUBLIC_CORE.read_text(encoding="utf-8")
    models = BACKTEST_MODELS.read_text(encoding="utf-8")
    require(strategy_id in core, f"strategy_id missing from {PUBLIC_CORE}")
    require(strategy_version in core, f"strategy_version missing from {PUBLIC_CORE}")
    require(app_mode in core or app_mode in models, f"app_mode missing from Swift sources: {app_mode}")
    require(strategy_id in models, f"strategy_id missing from product/research models: {strategy_id}")


def validate_g2(manifest: dict[str, Any]) -> None:
    baseline = manifest["frozen_retrospective_baseline"]
    gate = manifest["gates"]["G2_retrospective_robustness"]
    thresholds = gate["thresholds"]

    checks = [
        baseline["cagr"] >= thresholds["cagr_min"],
        baseline["sharpe"] >= thresholds["sharpe_min"],
        baseline["mdd"] <= thresholds["mdd_max"],
        baseline["folds_sharpe_gt_1"] >= thresholds["folds_sharpe_gt_1_min"],
        baseline["worst_fold_sharpe"] > thresholds["worst_fold_sharpe_min_exclusive"],
        baseline["block63_sharpe_p025"] >= thresholds["block63_sharpe_p025_min"],
        baseline["block63_mdd_p975"] <= thresholds["block63_mdd_p975_max"],
    ]
    expected = "PASS" if all(checks) else "FAIL"
    require(gate["status"] == expected, f"G2 status should be {expected}, got {gate['status']}")


def validate_g3(manifest: dict[str, Any]) -> None:
    legacy = manifest["legacy_research_exposure"]
    gate = manifest["gates"]["G3_model_selection_risk"]
    require(legacy["complete_trial_count_known"] is False, "Legacy trial count is incorrectly marked complete")
    require(
        legacy["retrospective_dsr_status"] == "NOT_CERTIFIED_LEGACY_TRIAL_COUNT",
        "Legacy DSR must remain uncertified until a complete historical trial census exists",
    )
    require(gate["future_trial_ledger_required"] is True, "Future trial ledger must be mandatory")
    require(gate["pbo_strong_max"] <= gate["pbo_pass_max"], "PBO strong threshold must be stricter")


def validate_g4(manifest: dict[str, Any]) -> None:
    baseline = manifest["frozen_retrospective_baseline"]
    gate = manifest["gates"]["G4_domain_preserving_generalization"]
    thresholds = gate["thresholds"]
    derived = gate["derived_v11_thresholds"]

    expected_sharpe = baseline["sharpe"] * thresholds["all_alternate_sharpe_retention_min"]
    expected_mdd = baseline["mdd"] * thresholds["all_alternate_mdd_multiple_max"]
    require(close(derived["all_alternate_sharpe_min"], expected_sharpe, 1e-6), "G4 derived Sharpe threshold drifted")
    require(close(derived["all_alternate_mdd_max"], expected_mdd, 1e-6), "G4 derived MDD threshold drifted")
    require(gate["formal_runs_allowed"] == gate["one_slot_runs"] + gate["all_alternate_runs"], "G4 run budget mismatch")
    require(len(gate["role_slots"]) == gate["one_slot_runs"], "G4 role-slot count mismatch")

    legacy = gate["legacy_country_equity_test"]
    legacy_pass = (
        legacy["portfolio_sharpe"] >= legacy["preregistered_sharpe_min"]
        and legacy["portfolio_mdd"] <= legacy["preregistered_mdd_max"]
    )
    expected_legacy = "PASS" if legacy_pass else "FAIL"
    require(legacy["status"] == expected_legacy, "Legacy country-equity test status mismatch")


def validate_g5(manifest: dict[str, Any]) -> None:
    gate = manifest["gates"]["G5_execution_robustness"]
    base = gate["base"]
    stress = gate["adverse_stress"]
    require(stress["fee"] > base["fee"], "Execution stress fee must be worse than base")
    require(stress["slippage"] > base["slippage"], "Execution stress slippage must be worse than base")
    require(stress["extra_execution_delay_sessions"] > base["extra_execution_delay_sessions"], "Execution stress delay must be worse than base")


def validate_g6(manifest: dict[str, Any]) -> None:
    baseline = manifest["frozen_retrospective_baseline"]
    gate = manifest["gates"]["G6_prospective_oos"]
    require(gate["milestones"] == [63, 126, 252, 504], "Prospective milestones changed")
    require(gate["primary_decision_sessions"] == 252, "Primary prospective decision must remain 252 sessions")
    require(gate["strong_validation_sessions"] == 504, "Strong prospective validation must remain 504 sessions")

    primary = gate["primary_thresholds"]
    strong = gate["strong_thresholds"]
    require(
        close(primary["derived_v11_mdd_max"], baseline["mdd"] * primary["mdd_multiple_max"], 1e-6),
        "Primary prospective MDD threshold drifted",
    )
    require(
        close(strong["derived_v11_sharpe_min"], baseline["sharpe"] * strong["sharpe_retention_min"], 1e-6),
        "Strong prospective Sharpe threshold drifted",
    )
    require(
        close(strong["derived_v11_cagr_min"], baseline["cagr"] * strong["cagr_retention_min"], 1e-6),
        "Strong prospective CAGR threshold drifted",
    )
    require(
        close(strong["derived_v11_mdd_max"], baseline["mdd"] * strong["mdd_multiple_max"], 1e-6),
        "Strong prospective MDD threshold drifted",
    )


def verify_artifact_manifest(path: Path, trial_id: str, expected_kind: str) -> dict[str, Any]:
    require(path.exists(), f"Evidence manifest missing: {path}")
    manifest = read_json(path)
    require(manifest.get("protocol_id") == "ATM-SVP-1", f"Evidence manifest protocol mismatch: {path}")
    require(manifest.get("trial_id") == trial_id, f"Evidence manifest trial mismatch: {path}")
    require(manifest.get("kind") == expected_kind, f"Evidence manifest kind mismatch: {path}")
    files = manifest.get("files")
    require(isinstance(files, list) and files, f"Evidence manifest has no files: {path}")
    for entry in files:
        require(isinstance(entry, dict), f"Invalid evidence entry in {path}")
        artifact_path = Path(str(entry.get("path", "")))
        require(artifact_path.is_file(), f"Evidence file missing: {artifact_path}")
        actual = file_sha256(artifact_path)
        require(actual == entry.get("sha256"), f"Evidence SHA mismatch: {artifact_path}")
        require(artifact_path.stat().st_size == entry.get("bytes"), f"Evidence size mismatch: {artifact_path}")
    return manifest


def validate_result_evidence(records: list[dict[str, Any]]) -> None:
    for record in records:
        if record.get("event") != "RESULT":
            continue
        payload = record["payload"]
        trial_id = str(payload["trial_id"])
        receipt_path = Path(payload["run_guard_receipt"])
        require(receipt_path.exists(), f"Run-guard receipt missing for trial={trial_id}: {receipt_path}")
        receipt = read_json(receipt_path)
        require(receipt.get("trial_id") == trial_id, f"Run receipt trial mismatch: {trial_id}")
        require(
            receipt.get("preregistration_record_hash") == payload["preregistration_record_hash"],
            f"Run receipt preregistration mismatch: {trial_id}",
        )
        require(
            receipt.get("execution_git_commit") == payload["execution_git_commit"],
            f"Run receipt execution commit mismatch: {trial_id}",
        )
        git_commit = subprocess.run(
            ["git", "cat-file", "-e", f"{payload['execution_git_commit']}^{{commit}}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        require(git_commit.returncode == 0, f"Execution Git commit is unavailable: {payload['execution_git_commit']}")

        dataset_manifest = verify_artifact_manifest(
            Path(payload["dataset_manifest"]), trial_id, "dataset"
        )
        artifact_manifest = verify_artifact_manifest(
            Path(payload["artifact_manifest"]), trial_id, "result"
        )
        artifact_paths = {str(entry["path"]) for entry in artifact_manifest["files"]}
        require(str(receipt_path) in artifact_paths, f"Run receipt is not hashed by result manifest: {trial_id}")
        for artifact in payload["artifacts"]:
            require(str(artifact) in artifact_paths, f"RESULT artifact is not covered by result manifest: {artifact}")
        dataset_paths = {str(entry["path"]) for entry in dataset_manifest["files"]}
        require(dataset_paths, f"Dataset manifest is empty for trial={trial_id}")


def verify_ledger(path: Path) -> list[dict[str, Any]]:
    result = subprocess.run(
        ["python3", "scripts/strategy_validation_ledger.py", "--ledger", str(path), "verify"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    require(result.returncode == 0, f"Trial ledger verification failed:\n{result.stdout}")
    records = [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    events = [record["event"] for record in records]
    for required_event in [
        "PROTOCOL_ACTIVATION",
        "LEGACY_EXPOSURE_BOUNDARY",
        "PROSPECTIVE_THRESHOLD_FREEZE",
        "POLICY_FREEZE",
    ]:
        require(required_event in events, f"Trial ledger missing required event: {required_event}")
    print(result.stdout.strip())
    return records


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--ledger", default=str(DEFAULT_LEDGER))
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    ledger_path = Path(args.ledger)
    require(PROTOCOL_DOC.exists(), f"Protocol document missing: {PROTOCOL_DOC}")
    require(AGENTS.exists(), f"Project instructions missing: {AGENTS}")
    require("ATM-SVP-1" in AGENTS.read_text(encoding="utf-8"), "AGENTS.md no longer enforces ATM-SVP-1")
    require(manifest_path.exists(), f"Protocol manifest missing: {manifest_path}")
    require(manifest_path == DEFAULT_MANIFEST or manifest_path.suffix == ".json", "Unexpected manifest path")

    policy = validate_policy_freeze()
    manifest = read_json(manifest_path)
    require(manifest["protocol_id"] == "ATM-SVP-1", "Unexpected protocol_id")
    require(manifest["protocol_version"] == 1, "Unexpected protocol_version")
    validate_policy_consistency(manifest, policy)

    validate_strategy_identity(manifest)
    validate_g2(manifest)
    validate_g3(manifest)
    validate_g4(manifest)
    validate_g5(manifest)
    validate_g6(manifest)
    ledger_records = verify_ledger(ledger_path)
    validate_result_evidence(ledger_records)

    gate_status = {
        name: value["status"]
        for name, value in manifest["gates"].items()
        if isinstance(value, dict) and "status" in value
    }
    print("PROTOCOL_VALID ATM-SVP-1")
    for name, status in gate_status.items():
        print(f"{name}={status}")


if __name__ == "__main__":
    try:
        main()
    except ProtocolError as error:
        raise SystemExit(f"PROTOCOL_INVALID: {error}") from error
