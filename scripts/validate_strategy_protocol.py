#!/usr/bin/env python3
"""Machine-checkable governance checks for ATM-SVP-1.

This script validates protocol metadata and evidence bookkeeping. It deliberately does not
reimplement strategy simulation; App-facing strategy metrics must still come from the Swift engine.
"""
from __future__ import annotations

import argparse
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


def verify_ledger(path: Path) -> None:
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
    ]:
        require(required_event in events, f"Trial ledger missing required event: {required_event}")
    print(result.stdout.strip())


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

    manifest = read_json(manifest_path)
    require(manifest["protocol_id"] == "ATM-SVP-1", "Unexpected protocol_id")
    require(manifest["protocol_version"] == 1, "Unexpected protocol_version")

    validate_strategy_identity(manifest)
    validate_g2(manifest)
    validate_g3(manifest)
    validate_g4(manifest)
    validate_g5(manifest)
    validate_g6(manifest)
    verify_ledger(ledger_path)

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
