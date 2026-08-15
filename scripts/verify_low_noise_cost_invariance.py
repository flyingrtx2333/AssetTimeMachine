#!/usr/bin/env python3
"""Compile and verify that low-noise targets are invariant to user execution fees.

The low-noise strategy intentionally freezes internal shadow-engine research costs at
1.00% fee + 0.05% slippage. User-entered fee changes may alter realized performance,
but must not alter the target-weight path. This check prevents regression of the
2026-08-14 decision/execution-cost coupling bug.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TMP_SWIFT = Path("/private/tmp/atm_low_noise_cost_invariance.swift")
TMP_BIN = Path("/private/tmp/atm_low_noise_cost_invariance")
SOURCES = [
    "AssetTimeMachine/Backtest/BacktestModels.swift",
    "AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift",
    "AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift",
    "AssetTimeMachine/Backtest/BacktestFXConverter.swift",
    "AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift",
    "AssetTimeMachine/Backtest/BacktestEngine.swift",
]


def run(cmd: list[str], env: dict[str, str] | None = None) -> str:
    p = subprocess.run(cmd, cwd=ROOT, env=env, text=True, capture_output=True)
    if p.returncode:
        sys.stderr.write(p.stdout)
        sys.stderr.write(p.stderr)
        raise SystemExit(p.returncode)
    return p.stdout


def main() -> None:
    run([
        "python3", "scripts/assemble_strategy_metric_dump.py",
        "--fragment", "tools/low_noise_fee_sensitivity.swiftpart",
        "--output", str(TMP_SWIFT),
    ])
    run(["swiftc", *SOURCES, str(TMP_SWIFT), "-o", str(TMP_BIN)])
    env = os.environ.copy()
    env["ATM_HISTORY_FIXTURE"] = "tools/fixtures/backtest-history/public_history.json"
    env["ATM_LOW_NOISE_FEE_SENSITIVITY"] = "1"
    output = run([str(TMP_BIN)], env=env)

    rows: list[dict[str, str]] = []
    capture = False
    header: list[str] | None = None
    for raw in output.splitlines():
        line = raw.strip()
        if line == "APP_LOW_NOISE_FEE_SENSITIVITY":
            capture = True
            continue
        if not capture or not line:
            continue
        if header is None:
            header = line.split(",")
            continue
        fields = line.split(",")
        if len(fields) != len(header):
            continue
        rows.append(dict(zip(header, fields)))

    endogenous = [r for r in rows if r.get("kind") == "endogenous"]
    if len(endogenous) < 5:
        raise SystemExit(f"FAIL: expected fee sensitivity rows, got {len(endogenous)}")
    endogenous.sort(key=lambda r: float(r["fee_percent"]), reverse=True)

    fingerprints = {r["target_fingerprint"] for r in endogenous}
    if len(fingerprints) != 1:
        raise SystemExit(f"FAIL: fee changed target path: {sorted(fingerprints)}")

    # As execution fee falls, CAGR/Sharpe should not deteriorate for a frozen target path.
    previous_cagr = float(endogenous[0]["annualized"])
    previous_sharpe = float(endogenous[0]["sharpe"])
    previous_mdd = float(endogenous[0]["max_drawdown"])
    for row in endogenous[1:]:
        cagr = float(row["annualized"])
        sharpe = float(row["sharpe"])
        mdd = float(row["max_drawdown"])
        if cagr + 1e-6 < previous_cagr:
            raise SystemExit(f"FAIL: lower fee reduced CAGR: {previous_cagr} -> {cagr}")
        if sharpe + 1e-6 < previous_sharpe:
            raise SystemExit(f"FAIL: lower fee reduced Sharpe: {previous_sharpe} -> {sharpe}")
        if mdd > previous_mdd + 1e-5:
            raise SystemExit(f"FAIL: lower fee materially increased MDD: {previous_mdd} -> {mdd}")
        previous_cagr, previous_sharpe, previous_mdd = cagr, sharpe, mdd

    print("LOW_NOISE_COST_INVARIANCE_OK")
    print(f"fingerprint={next(iter(fingerprints))}")
    for row in endogenous:
        print(
            f"fee={row['fee_percent']} cagr={row['annualized']} "
            f"mdd={row['max_drawdown']} sharpe={row['sharpe']}"
        )


if __name__ == "__main__":
    main()
