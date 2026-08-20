#!/usr/bin/env python3
"""ATM-SVP-1 G5 component: fixed V11 execution-cost stress via the exact Swift App engine.

This orchestrator does not implement strategy logic. It assembles the durable Swift validation
fragment, compiles the current App engine, and runs exactly two preregisterable execution cases:
base (1.00% fee, 0.05% slippage) and adverse_cost (1.50% fee, 0.10% slippage).
The extra-one-session execution-delay component of G5 is intentionally NOT simulated here; full G5
must remain incomplete until a same-engine delay implementation is available.
"""
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
FIXTURE = ROOT / "tools/fixtures/backtest-history/generalization_public_history.json"
FRAGMENT = ROOT / "tools/nfci_dual_core_v1_app_validation.swiftpart"
ASSEMBLED = Path("/private/tmp/atm_v11_execution_cost_stress.swift")
BINARY = Path("/private/tmp/atm_v11_execution_cost_stress")

CASES = [
    {"candidate_id": "base_execution", "fee_percent": 1.00, "slippage_percent": 0.05},
    {"candidate_id": "adverse_cost", "fee_percent": 1.50, "slippage_percent": 0.10},
]


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
        sys.stderr.write(completed.stdout[-12000:])
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
    ])


def parse_metrics(text: str) -> dict[str, float | int | str]:
    result: dict[str, float | int | str] = {}
    for key in ["cagr", "mdd", "vol", "sharpe"]:
        match = re.search(rf"^{key}=([-+0-9.]+)$", text, flags=re.MULTILINE)
        if not match:
            raise RuntimeError(f"missing {key} in Swift output")
        result[key] = float(match.group(1))
    trades = re.search(r"^trades=(\d+)$", text, flags=re.MULTILINE)
    fingerprint = re.search(r"^fingerprint=([0-9a-f]+)$", text, flags=re.MULTILINE)
    if not trades or not fingerprint:
        raise RuntimeError("missing trades/fingerprint in Swift output")
    result["trades"] = int(trades.group(1))
    result["fingerprint"] = fingerprint.group(1)
    return result


def replay(case: dict[str, float | str], output_dir: Path) -> dict:
    candidate_id = str(case["candidate_id"])
    series_path = output_dir / f"{candidate_id}-portfolio.csv"
    env = os.environ.copy()
    env.update({
        "ATM_HISTORY_FIXTURE": str(FIXTURE.relative_to(ROOT)),
        "ATM_NFCI_DUAL_CORE_V1_APP_VALIDATION": "1",
        "ATM_NFCI_DUAL_CORE_FORMAL_V11": "1",
        "ATM_NFCI_DUAL_CORE_V1_FEE": f"{float(case['fee_percent']):.6f}",
        "ATM_NFCI_DUAL_CORE_V1_SLIPPAGE": f"{float(case['slippage_percent']):.6f}",
        "ATM_NFCI_DUAL_CORE_OUTPUT": str(series_path),
    })
    stdout = run([str(BINARY)], env=env, timeout=240)
    metrics = parse_metrics(stdout)
    return {
        "candidate_id": candidate_id,
        "execution": {
            "fee_percent": float(case["fee_percent"]),
            "slippage_percent": float(case["slippage_percent"]),
            "extra_execution_delay_sessions": 0,
        },
        "metrics": metrics,
        "portfolio_series": str(series_path),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    compile_binary()
    results = [replay(case, output_dir) for case in CASES]
    by_id = {row["candidate_id"]: row for row in results}
    base = by_id["base_execution"]
    adverse = by_id["adverse_cost"]

    same_target_path = base["metrics"]["fingerprint"] == adverse["metrics"]["fingerprint"]
    base_mdd = float(base["metrics"]["mdd"])
    adverse_mdd = float(adverse["metrics"]["mdd"])
    component_pass = (
        float(adverse["metrics"]["cagr"]) > 0
        and float(adverse["metrics"]["sharpe"]) > 0
        and adverse_mdd <= 2.0 * base_mdd
        and same_target_path
    )

    document = {
        "protocol_id": "ATM-SVP-1",
        "component": "G5_EXECUTION_COST_ONLY",
        "full_g5_status": "PENDING_DELAY_STRESS",
        "candidate_results": results,
        "checks": {
            "adverse_cagr_gt_0": float(adverse["metrics"]["cagr"]) > 0,
            "adverse_sharpe_gt_0": float(adverse["metrics"]["sharpe"]) > 0,
            "adverse_mdd_le_2x_base": adverse_mdd <= 2.0 * base_mdd,
            "target_fingerprint_unchanged": same_target_path,
        },
        "component_status": "PASS" if component_pass else "FAIL",
        "scope_note": "This result does not include the frozen +1 session execution-delay stress and therefore cannot by itself set G5=PASS.",
    }
    json_path = output_dir / "candidate-metrics.json"
    json_path.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    csv_path = output_dir / "candidate-metrics.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["candidate_id", "fee_percent", "slippage_percent", "cagr", "mdd", "vol", "sharpe", "trades", "fingerprint"],
        )
        writer.writeheader()
        for row in results:
            metrics = row["metrics"]
            writer.writerow({
                "candidate_id": row["candidate_id"],
                "fee_percent": row["execution"]["fee_percent"],
                "slippage_percent": row["execution"]["slippage_percent"],
                "cagr": metrics["cagr"],
                "mdd": metrics["mdd"],
                "vol": metrics["vol"],
                "sharpe": metrics["sharpe"],
                "trades": metrics["trades"],
                "fingerprint": metrics["fingerprint"],
            })

    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    print(f"G5_EXECUTION_COST_COMPONENT_{document['component_status']}")
    print(f"OUTPUT_JSON={json_path}")
    print(f"OUTPUT_CSV={csv_path}")
    return 0 if component_pass else 2


if __name__ == "__main__":
    raise SystemExit(main())
