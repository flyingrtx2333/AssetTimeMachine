#!/usr/bin/env python3
"""Compile or formally execute frozen ATM-SVP2-MACRO-SAHM-CPI-001.

Do not invoke without the repository formal-run guard. Compilation never opens performance.
Formal execution has no input override: every byte is bound to the committed dataset manifest.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL_ID = "ATM-SVP-2"
TRIAL_ID = "ATM-SVP2-MACRO-SAHM-CPI-001"
CANDIDATE_ID = "MACRO-SAHM-CPI-001"
PREREGISTRATION_RECORD_HASH = "ca639b973a6959267a8fed980280b4459cc926f83c87ae79b03d2a2b466d6412"
ENGINE_VERSION = "atm-swift-clock-v3-2026-08-31"
FRAGMENT = ROOT / "tools/macro_sahm_cpi_formal.swiftpart"
ASSEMBLED = Path("/private/tmp/atm_macro_sahm_cpi_formal.swift")
BINARY = Path("/private/tmp/atm_macro_sahm_cpi_formal")
DATASET_MANIFEST = ROOT / "tools/research-results/strategy-validation/datasets" / f"{TRIAL_ID}.json"
FIXTURE = ROOT / "tools/fixtures/backtest-history/public_history.json"
DATA_DIR = ROOT / "tools/research-results/macro-vintages/alfred-initial-release"
EXPECTED_DATASET_PATHS = {
    "tools/fixtures/backtest-history/public_history.json",
    "tools/research-results/macro-vintages/alfred-initial-release/UNRATE_initial_release.csv",
    "tools/research-results/macro-vintages/alfred-initial-release/CPIAUCSL_initial_release.csv",
    "tools/research-results/macro-vintages/alfred-initial-release/UNRATE_missing_reference_months.csv",
    "tools/research-results/macro-vintages/alfred-initial-release/CPIAUCSL_missing_reference_months.csv",
    "tools/research-results/macro-vintages/alfred-initial-release/source-manifest.txt",
}
EXPECTED_OUTPUTS = {
    "candidate-metrics.json",
    "MACRO-SAHM-CPI-001-schedule.csv",
    "CONTROL-NATURAL-50-50-schedule.csv",
    "CONTROL-SWAP-PLACEBO-schedule.csv",
    "MACRO-SAHM-CPI-001-BPS25-portfolio.csv",
    "MACRO-SAHM-CPI-001-APP-portfolio.csv",
    "CONTROL-NATURAL-50-50-portfolio.csv",
    "CONTROL-SWAP-PLACEBO-portfolio.csv",
}


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 600) -> str:
    completed = subprocess.run(
        command, cwd=ROOT, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=timeout, check=False,
    )
    if completed.returncode != 0:
        sys.stderr.write(completed.stdout[-20000:])
        raise RuntimeError(f"command failed ({completed.returncode}): {' '.join(command)}")
    return completed.stdout


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compile_binary() -> None:
    print(run([
        sys.executable, "scripts/assemble_strategy_metric_dump.py",
        "--fragment", str(FRAGMENT.relative_to(ROOT)),
        "--output", str(ASSEMBLED),
    ]), end="")
    print(run([
        "xcrun", "swiftc", "-parse-as-library",
        "-module-cache-path", "/private/tmp/atm-swift-module-cache",
        "AssetTimeMachine/Backtest/BacktestModels.swift",
        "AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift",
        "AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift",
        "AssetTimeMachine/Backtest/BacktestFXConverter.swift",
        "AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift",
        "AssetTimeMachine/Backtest/BacktestEngine.swift",
        "AssetTimeMachine/Backtest/GORQREG25263Strategy.swift",
        "AssetTimeMachine/Backtest/MacroSahmCPIStrategy.swift",
        str(ASSEMBLED), "-o", str(BINARY),
    ]), end="")
    print(f"MACRO_SAHM_CPI_COMPILE_OK binary={BINARY}")


def validate_dataset_manifest() -> None:
    manifest = json.loads(DATASET_MANIFEST.read_text(encoding="utf-8"))
    if manifest.get("protocol_id") != PROTOCOL_ID or manifest.get("trial_id") != TRIAL_ID:
        raise SystemExit("dataset manifest identity mismatch")
    if manifest.get("metadata", {}).get("candidate_id") != CANDIDATE_ID:
        raise SystemExit("dataset manifest candidate mismatch")
    if manifest.get("metadata", {}).get("engine_version") != ENGINE_VERSION:
        raise SystemExit("dataset manifest engine mismatch")
    files = manifest.get("files")
    if not isinstance(files, list):
        raise SystemExit("dataset manifest files missing")
    by_path: dict[str, dict] = {}
    for entry in files:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise SystemExit("dataset manifest file entry malformed")
        by_path[entry["path"]] = entry
    if set(by_path) != EXPECTED_DATASET_PATHS:
        raise SystemExit("dataset manifest exact path set mismatch")
    for relative, entry in by_path.items():
        path = (ROOT / relative).resolve()
        if ROOT.resolve() not in path.parents or not path.is_file():
            raise SystemExit(f"frozen dataset file missing/outside repository: {relative}")
        if path.stat().st_size != entry.get("bytes"):
            raise SystemExit(f"frozen dataset byte count mismatch: {relative}")
        if sha256_file(path) != entry.get("sha256"):
            raise SystemExit(f"frozen dataset sha256 mismatch: {relative}")
    if FIXTURE.resolve() != (ROOT / "tools/fixtures/backtest-history/public_history.json").resolve():
        raise SystemExit("internal fixture binding mismatch")
    if not DATA_DIR.is_dir():
        raise SystemExit("frozen macro directory missing")


def validate_formal_environment() -> None:
    required = [
        "ATM_SVP_PROTOCOL_ID", "ATM_SVP_TRIAL_ID",
        "ATM_SVP_PREREGISTRATION_RECORD_HASH", "ATM_SVP_EXECUTION_GIT_COMMIT",
        "ATM_SVP_RUN_GUARD_RECEIPT",
    ]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise SystemExit(f"Formal guard environment missing: {missing}")
    expected_env = {
        "ATM_SVP_PROTOCOL_ID": PROTOCOL_ID,
        "ATM_SVP_TRIAL_ID": TRIAL_ID,
        "ATM_SVP_PREREGISTRATION_RECORD_HASH": PREREGISTRATION_RECORD_HASH,
    }
    for name, expected in expected_env.items():
        if os.environ[name] != expected:
            raise SystemExit(f"formal guard identity mismatch: {name}")
    receipt_path = Path(os.environ["ATM_SVP_RUN_GUARD_RECEIPT"]).resolve()
    if not receipt_path.is_file():
        raise SystemExit("run guard receipt missing")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    expected_receipt = {
        "protocol_id": PROTOCOL_ID,
        "trial_id": TRIAL_ID,
        "preregistration_record_hash": PREREGISTRATION_RECORD_HASH,
        "ledger_head_at_authorization": PREREGISTRATION_RECORD_HASH,
        "formal_run_budget": 1,
        "candidate_count": 1,
    }
    for key, expected in expected_receipt.items():
        if receipt.get(key) != expected:
            raise SystemExit(f"run guard receipt mismatch: {key}")
    current_head = run(["git", "rev-parse", "HEAD"]).strip()
    execution_commit = os.environ["ATM_SVP_EXECUTION_GIT_COMMIT"]
    if receipt.get("execution_git_commit") != execution_commit or current_head != execution_commit:
        raise SystemExit("execution Git commit mismatch")


def validate_result(output_dir: Path) -> dict:
    for name in sorted(EXPECTED_OUTPUTS):
        path = output_dir / name
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"formal output missing/empty: {name}")
    result = json.loads((output_dir / "candidate-metrics.json").read_text(encoding="utf-8"))
    if result.get("protocol_id") != PROTOCOL_ID or result.get("trial_id") != TRIAL_ID:
        raise RuntimeError("formal result protocol/trial mismatch")
    if result.get("candidate_id") != CANDIDATE_ID or result.get("engine_version") != ENGINE_VERSION:
        raise RuntimeError("formal result candidate/engine mismatch")
    if result.get("same_schedule_replayed_at_both_costs") is not True:
        raise RuntimeError("dual-cost replay did not use one immutable schedule")
    app = result.get("app_product_cost", {})
    bps = result.get("formal_bps25", {})
    controls = result.get("controls", {})
    natural = controls.get("naturally_drifting_50_50", {})
    placebo = controls.get("swap_placebo", {})
    if app.get("constraints", {}).get("pass") is not True:
        raise RuntimeError("App-cost constraint violation")
    review_fingerprints = {
        result.get("macro_review_clock_fingerprint"),
        app.get("review_clock_fingerprint"),
        bps.get("review_clock_fingerprint"),
        natural.get("review_clock_fingerprint"),
        placebo.get("review_clock_fingerprint"),
    }
    if None in review_fingerprints or "" in review_fingerprints or len(review_fingerprints) != 1:
        raise RuntimeError("candidate/control macro review clocks differ")
    if app.get("schedule_fingerprint") != bps.get("schedule_fingerprint"):
        raise RuntimeError("dual-cost schedule fingerprints differ")
    checks = app.get("mechanical_product_gate", {}).get("checks", {})
    for name in ("same_immutable_schedule_at_both_costs", "same_macro_review_clock_for_candidate_and_controls"):
        if checks.get(name) is not True:
            raise RuntimeError(f"mechanical audit check failed: {name}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir")
    parser.add_argument("--compile-only", action="store_true")
    args = parser.parse_args()

    if args.compile_only:
        compile_binary()
        return 0
    validate_formal_environment()
    validate_dataset_manifest()
    if not args.output_dir:
        raise SystemExit("--output-dir is required for formal execution")
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    compile_binary()
    env = os.environ.copy()
    env.update({
        "ATM_HISTORY_FIXTURE": str(FIXTURE),
        "ATM_MACRO_SAHM_CPI_FORMAL": "1",
        "ATM_MACRO_SAHM_CPI_DATA_DIR": str(DATA_DIR),
        "ATM_MACRO_SAHM_CPI_OUTPUT_DIR": str(output_dir),
    })
    stdout = run([str(BINARY)], env=env, timeout=600)
    print(stdout, end="")
    if "MACRO_SAHM_CPI_FORMAL_COMPLETE" not in stdout:
        raise RuntimeError("Swift formal runner did not emit completion marker")
    result = validate_result(output_dir)
    print(json.dumps({
        "trial_id": TRIAL_ID,
        "candidate_id": CANDIDATE_ID,
        "decision": result["decision"],
        "schedule_fingerprint": result["app_product_cost"]["schedule_fingerprint"],
        "review_clock_fingerprint": result["macro_review_clock_fingerprint"],
        "result": str(output_dir / "candidate-metrics.json"),
    }, ensure_ascii=False, sort_keys=True))
    print("MACRO_SAHM_CPI_FORMAL_RESULT_VALID")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
