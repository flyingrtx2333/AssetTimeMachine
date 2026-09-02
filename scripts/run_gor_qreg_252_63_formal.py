#!/usr/bin/env python3
"""Compile or formally execute frozen GOR-QREG-252-63 through the shared Swift engine."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRIAL_ID = "ATM-SVP2-GOR-QREG-001"
FRAGMENT = ROOT / "tools/gor_qreg_252_63_formal.swiftpart"
ASSEMBLED = Path("/private/tmp/atm_gor_qreg_252_63_formal.swift")
BINARY = Path("/private/tmp/atm_gor_qreg_252_63_formal")


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 600) -> str:
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
        sys.stderr.write(completed.stdout[-20000:])
        raise RuntimeError(f"command failed ({completed.returncode}): {' '.join(command)}")
    return completed.stdout


def compile_binary() -> None:
    print(run([
        sys.executable,
        "scripts/assemble_strategy_metric_dump.py",
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
        str(ASSEMBLED),
        "-o", str(BINARY),
    ]), end="")
    print(f"GOR_QREG_COMPILE_OK binary={BINARY}")


def validate_formal_environment() -> None:
    required = [
        "ATM_SVP_PROTOCOL_ID",
        "ATM_SVP_TRIAL_ID",
        "ATM_SVP_PREREGISTRATION_RECORD_HASH",
        "ATM_SVP_EXECUTION_GIT_COMMIT",
        "ATM_SVP_RUN_GUARD_RECEIPT",
    ]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise SystemExit(f"Formal guard environment missing: {missing}")
    if os.environ["ATM_SVP_TRIAL_ID"] != TRIAL_ID:
        raise SystemExit(f"trial mismatch: expected={TRIAL_ID} got={os.environ['ATM_SVP_TRIAL_ID']}")
    if not Path(os.environ["ATM_SVP_RUN_GUARD_RECEIPT"]).is_file():
        raise SystemExit("run guard receipt missing")


def validate_result(path: Path) -> dict:
    result = json.loads(path.read_text(encoding="utf-8"))
    if result.get("trial_id") != TRIAL_ID or result.get("candidate_id") != "GOR-QREG-252-63":
        raise RuntimeError("formal result identity mismatch")
    if result.get("engine_version") != "atm-swift-clock-v3-2026-08-31":
        raise RuntimeError("formal engine version mismatch")
    if result.get("same_schedule_replayed_at_both_costs") is not True:
        raise RuntimeError("dual-cost replay did not use one immutable schedule")
    for key in ["formal_bps25", "app_product_cost"]:
        if result[key]["constraints"].get("pass") is not True:
            raise RuntimeError(f"constraint violation: {key}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", default="tools/fixtures/backtest-history/public_history.json")
    parser.add_argument("--output-dir")
    parser.add_argument("--compile-only", action="store_true")
    args = parser.parse_args()

    compile_binary()
    if args.compile_only:
        return 0
    validate_formal_environment()
    fixture = Path(args.fixture)
    if not fixture.is_file():
        raise SystemExit(f"fixture missing: {fixture}")
    if not args.output_dir:
        raise SystemExit("--output-dir is required for formal execution")
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update({
        "ATM_HISTORY_FIXTURE": str(fixture),
        "ATM_GOR_QREG_FORMAL": "1",
        "ATM_GOR_QREG_OUTPUT_DIR": str(output_dir),
    })
    stdout = run([str(BINARY)], env=env, timeout=600)
    print(stdout, end="")
    if "GOR_QREG_FORMAL_COMPLETE" not in stdout:
        raise RuntimeError("Swift formal runner did not emit completion marker")
    result = validate_result(output_dir / "candidate-metrics.json")
    print(json.dumps({
        "trial_id": TRIAL_ID,
        "candidate_id": result["candidate_id"],
        "decision": result["decision"],
        "schedule_fingerprint": result["formal_bps25"]["schedule_fingerprint"],
        "result": str(output_dir / "candidate-metrics.json"),
    }, ensure_ascii=False, sort_keys=True))
    print("GOR_QREG_FORMAL_RESULT_VALID")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
