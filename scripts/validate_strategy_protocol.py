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
PROTOCOL_FILES = {
    "ATM-SVP-1": {
        "version": 1,
        "policy": Path("tools/research-results/strategy-validation/strategy-validation-policy-v1.json"),
        "freeze": Path("tools/research-results/strategy-validation/protocol-freeze-v1.json"),
        "document": Path("docs/strategies/validation/strategy-validation-protocol-v1.md"),
    },
    "ATM-SVP-2": {
        "version": 2,
        "policy": Path("tools/research-results/strategy-validation/strategy-validation-policy-v2.json"),
        "freeze": Path("tools/research-results/strategy-validation/protocol-freeze-v2.json"),
        "document": Path("docs/strategies/validation/strategy-validation-protocol-v2.md"),
    },
}
PUBLIC_CORE = Path("AssetTimeMachine/Backtest/PublicBacktestCore.swift")
BACKTEST_MODELS = Path("AssetTimeMachine/Backtest/BacktestModels.swift")
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


def protocol_files(protocol_id: str) -> dict[str, Any]:
    config = PROTOCOL_FILES.get(protocol_id)
    require(config is not None, f"Unsupported protocol_id: {protocol_id}")
    return config


def validate_policy_freeze(protocol_id: str) -> dict[str, Any]:
    config = protocol_files(protocol_id)
    policy_path = config["policy"]
    freeze_path = config["freeze"]
    document_path = config["document"]
    version = config["version"]
    require(policy_path.exists(), f"Frozen policy missing: {policy_path}")
    require(freeze_path.exists(), f"Protocol freeze record missing: {freeze_path}")
    require(document_path.exists(), f"Protocol document missing: {document_path}")
    freeze = read_json(freeze_path)
    require(freeze["protocol_id"] == protocol_id, "Unexpected freeze protocol_id")
    require(freeze["protocol_version"] == version, "Unexpected freeze protocol_version")
    frozen_files = freeze.get("files")
    require(isinstance(frozen_files, dict) and frozen_files, "Freeze record has no files")
    for raw_path, expected_hash in frozen_files.items():
        path = Path(raw_path)
        require(path.exists(), f"Frozen file missing: {path}")
        actual_hash = file_sha256(path)
        require(
            actual_hash == expected_hash,
            f"Frozen governance file changed in place: {path}; expected={expected_hash}, actual={actual_hash}. Create the next protocol version instead.",
        )
    policy = read_json(policy_path)
    require(policy["protocol_id"] == protocol_id, "Unexpected policy protocol_id")
    require(policy["protocol_version"] == version, "Unexpected policy protocol_version")
    return policy


def validate_policy_consistency(manifest: dict[str, Any], policy: dict[str, Any]) -> None:
    protocol_version = int(manifest["protocol_version"])
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
    if protocol_version == 1:
        for key in [
            "positive_one_slot_sharpe_count_min",
            "one_slot_median_sharpe_retention_min",
            "all_alternate_cagr_min_exclusive",
            "all_alternate_sharpe_retention_min",
            "all_alternate_mdd_multiple_max",
        ]:
            require(g4["thresholds"][key] == p4[key], f"G4 threshold drift: {key}")
    else:
        for key in [
            "reference_frame",
            "evaluation_window_rule",
            "full_history_identity_control_required",
            "common_window_identity_control_required",
            "common_reference_freeze_before_holdout_burn",
            "common_reference_event",
        ]:
            require(g4[key] == p4[key], f"G4 V2 policy drift: {key}")
        threshold_mapping = {
            "common_reference_cagr_min_exclusive": "cagr_min_exclusive",
            "common_reference_sharpe_min_exclusive": "sharpe_min_exclusive",
            "common_reference_mdd_absolute_max": "mdd_absolute_max",
            "positive_one_slot_sharpe_count_min": "positive_one_slot_sharpe_count_min",
            "one_slot_median_sharpe_retention_min": "one_slot_median_sharpe_retention_min",
            "all_alternate_cagr_min_exclusive": "all_alternate_cagr_min_exclusive",
            "all_alternate_sharpe_retention_min": "all_alternate_sharpe_retention_min",
            "all_alternate_mdd_relative_multiple_max": "all_alternate_mdd_relative_multiple_max",
            "all_alternate_mdd_absolute_max": "all_alternate_mdd_absolute_max",
        }
        for manifest_key, policy_key in threshold_mapping.items():
            policy_value = p4.get(policy_key)
            if policy_value is None and policy_key in {"cagr_min_exclusive", "sharpe_min_exclusive", "mdd_absolute_max"}:
                policy_value = p4["common_reference_preconditions"][policy_key]
            require(g4["thresholds"][manifest_key] == policy_value, f"G4 V2 threshold drift: {manifest_key}")

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
    protocol_version = int(manifest["protocol_version"])
    baseline = manifest["frozen_retrospective_baseline"]
    gate = manifest["gates"]["G4_domain_preserving_generalization"]
    thresholds = gate["thresholds"]

    require(gate["formal_runs_allowed"] == gate["one_slot_runs"] + gate["all_alternate_runs"], "G4 run budget mismatch")
    require(len(gate["role_slots"]) == gate["one_slot_runs"], "G4 role-slot count mismatch")

    if protocol_version == 1:
        derived = gate["derived_v11_thresholds"]
        expected_sharpe = baseline["sharpe"] * thresholds["all_alternate_sharpe_retention_min"]
        expected_mdd = baseline["mdd"] * thresholds["all_alternate_mdd_multiple_max"]
        require(close(derived["all_alternate_sharpe_min"], expected_sharpe, 1e-6), "G4 derived Sharpe threshold drifted")
        require(close(derived["all_alternate_mdd_max"], expected_mdd, 1e-6), "G4 derived MDD threshold drifted")
    else:
        require(gate["reference_frame"] == "COMMON_EVALUATION_WINDOW_IDENTITY", "G4 V2 reference frame drifted")
        require(
            gate["evaluation_window_rule"] == "intersection_of_all_role_metadata_coverage",
            "G4 V2 evaluation-window rule drifted",
        )
        common_reference = gate.get("common_reference")
        derived = gate.get("derived_thresholds")
        if common_reference is None:
            require(derived is None, "G4 V2 cannot have derived thresholds before the common reference is frozen")
            require(gate["status"] == "PENDING", "G4 V2 without a common reference must remain PENDING")
        else:
            require(isinstance(common_reference, dict), "G4 V2 common_reference must be an object")
            for key in ["cagr", "sharpe", "mdd"]:
                require(isinstance(common_reference.get(key), (int, float)), f"G4 V2 common reference missing {key}")
            require(common_reference["cagr"] > thresholds["common_reference_cagr_min_exclusive"], "G4 V2 common reference CAGR precondition failed")
            require(common_reference["sharpe"] > thresholds["common_reference_sharpe_min_exclusive"], "G4 V2 common reference Sharpe precondition failed")
            require(common_reference["mdd"] <= thresholds["common_reference_mdd_absolute_max"], "G4 V2 common reference MDD precondition failed")
            require(isinstance(derived, dict), "G4 V2 derived thresholds missing after common reference freeze")
            expected_sharpe = common_reference["sharpe"] * thresholds["all_alternate_sharpe_retention_min"]
            expected_median = common_reference["sharpe"] * thresholds["one_slot_median_sharpe_retention_min"]
            expected_mdd = min(
                thresholds["all_alternate_mdd_absolute_max"],
                common_reference["mdd"] * thresholds["all_alternate_mdd_relative_multiple_max"],
            )
            require(close(derived["all_alternate_sharpe_min"], expected_sharpe, 1e-6), "G4 V2 derived all-alternate Sharpe drifted")
            require(close(derived["one_slot_median_sharpe_min"], expected_median, 1e-6), "G4 V2 derived one-slot median Sharpe drifted")
            require(close(derived["all_alternate_mdd_max"], expected_mdd, 1e-6), "G4 V2 derived MDD drifted")

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


def verify_artifact_manifest(
    path: Path,
    trial_id: str,
    expected_kind: str,
    expected_protocol_id: str,
) -> dict[str, Any]:
    require(path.exists(), f"Evidence manifest missing: {path}")
    manifest = read_json(path)
    require(manifest.get("protocol_id") == expected_protocol_id, f"Evidence manifest protocol mismatch: {path}")
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
    preregistration_protocols: dict[str, str] = {}
    for record in records:
        if record.get("event") != "PREREGISTER":
            continue
        payload = record.get("payload")
        if not isinstance(payload, dict):
            continue
        trial_id = payload.get("trial_id")
        protocol_id = payload.get("protocol_id")
        if isinstance(trial_id, str) and isinstance(protocol_id, str):
            preregistration_protocols[trial_id] = protocol_id

    for record in records:
        if record.get("event") != "RESULT":
            continue
        payload = record["payload"]
        trial_id = str(payload["trial_id"])
        expected_protocol_id = preregistration_protocols.get(trial_id)
        require(expected_protocol_id in PROTOCOL_FILES, f"RESULT trial={trial_id} has unsupported/missing preregistration protocol")
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
            Path(payload["dataset_manifest"]), trial_id, "dataset", expected_protocol_id
        )
        artifact_manifest = verify_artifact_manifest(
            Path(payload["artifact_manifest"]), trial_id, "result", expected_protocol_id
        )
        artifact_paths = {str(entry["path"]) for entry in artifact_manifest["files"]}
        require(str(receipt_path) in artifact_paths, f"Run receipt is not hashed by result manifest: {trial_id}")
        for artifact in payload["artifacts"]:
            require(str(artifact) in artifact_paths, f"RESULT artifact is not covered by result manifest: {artifact}")
        dataset_paths = {str(entry["path"]) for entry in dataset_manifest["files"]}
        require(dataset_paths, f"Dataset manifest is empty for trial={trial_id}")


def verify_ledger(path: Path, protocol_id: str) -> list[dict[str, Any]]:
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
    if protocol_id == "ATM-SVP-2":
        upgrades = [
            record for record in records
            if record.get("event") == "PROTOCOL_UPGRADE"
            and isinstance(record.get("payload"), dict)
            and record["payload"].get("from_protocol") == "ATM-SVP-1"
            and record["payload"].get("to_protocol") == "ATM-SVP-2"
        ]
        require(len(upgrades) == 1, "ATM-SVP-2 requires exactly one committed V1->V2 PROTOCOL_UPGRADE event")
        v2_freezes = [
            record for record in records
            if record.get("event") == "POLICY_FREEZE"
            and isinstance(record.get("payload"), dict)
            and record["payload"].get("protocol_id") == "ATM-SVP-2"
            and record["payload"].get("protocol_version") == 2
        ]
        require(len(v2_freezes) == 1, "ATM-SVP-2 requires exactly one V2 POLICY_FREEZE ledger event")
    print(result.stdout.strip())
    return records


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--ledger", default=str(DEFAULT_LEDGER))
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    ledger_path = Path(args.ledger)
    require(AGENTS.exists(), f"Project instructions missing: {AGENTS}")
    require(manifest_path.exists(), f"Protocol manifest missing: {manifest_path}")
    require(manifest_path == DEFAULT_MANIFEST or manifest_path.suffix == ".json", "Unexpected manifest path")

    manifest = read_json(manifest_path)
    protocol_id = str(manifest.get("protocol_id", ""))
    config = protocol_files(protocol_id)
    protocol_version = config["version"]
    require(manifest.get("protocol_version") == protocol_version, "Unexpected protocol_version")
    require(protocol_id in AGENTS.read_text(encoding="utf-8"), f"AGENTS.md no longer enforces {protocol_id}")
    policy = validate_policy_freeze(protocol_id)
    validate_policy_consistency(manifest, policy)

    validate_strategy_identity(manifest)
    validate_g2(manifest)
    validate_g3(manifest)
    validate_g4(manifest)
    validate_g5(manifest)
    validate_g6(manifest)
    ledger_records = verify_ledger(ledger_path, protocol_id)
    validate_result_evidence(ledger_records)

    gate_status = {
        name: value["status"]
        for name, value in manifest["gates"].items()
        if isinstance(value, dict) and "status" in value
    }
    print(f"PROTOCOL_VALID {protocol_id}")
    for name, status in gate_status.items():
        print(f"{name}={status}")


if __name__ == "__main__":
    try:
        main()
    except ProtocolError as error:
        raise SystemExit(f"PROTOCOL_INVALID: {error}") from error
