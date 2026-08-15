#!/usr/bin/env python3
"""Verify frozen NFCI DualCore V1 and simplified V11 against the exact Swift App engine.

This is a product/research regression guard, not a strategy searcher. It compiles the existing
App engine plus the durable validation fragment, then replays the same pinned fixture under
1.00% and 0.03% execution fees. Frozen strategy targets must not move when execution cost moves.
"""
from __future__ import annotations

import concurrent.futures
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tools/fixtures/backtest-history/generalization_public_history.json"
FRAGMENT = ROOT / "tools/nfci_dual_core_v1_app_validation.swiftpart"
ASSEMBLED = Path("/private/tmp/atm_nfci_dual_frozen_verify.swift")
BINARY = Path("/private/tmp/atm_nfci_dual_frozen_verify")

EXPECTED = {
    "v1": {
        "cagr": 14.580323,
        "mdd": 7.689054,
        "vol": 8.827730,
        "sharpe": 1.533816,
        "trades": 460,
        "fingerprint": "61b49674592ddd88",
    },
    "v11": {
        "cagr": 14.345615,
        "mdd": 7.689054,
        "vol": 8.760667,
        "sharpe": 1.522263,
        "trades": 451,
        "fingerprint": "ba67c8aa24bc7168",
    },
}


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 240) -> str:
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
        print(completed.stdout, file=sys.stderr)
        raise RuntimeError(f"command failed ({completed.returncode}): {' '.join(command)}")
    return completed.stdout


def compile_binary() -> None:
    run([
        "python3",
        "scripts/assemble_strategy_metric_dump.py",
        "--fragment",
        str(FRAGMENT.relative_to(ROOT)),
        "--output",
        str(ASSEMBLED),
    ])
    run([
        "swiftc",
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


def parse(text: str) -> dict[str, str | float | int]:
    result: dict[str, str | float | int] = {}
    for key in ("cagr", "mdd", "vol", "sharpe"):
        match = re.search(rf"^{key}=([-+0-9.]+)$", text, flags=re.MULTILINE)
        if not match:
            raise RuntimeError(f"missing {key} in output:\n{text}")
        result[key] = float(match.group(1))
    trades = re.search(r"^trades=(\d+)$", text, flags=re.MULTILINE)
    fingerprint = re.search(r"^fingerprint=([0-9a-f]+)$", text, flags=re.MULTILINE)
    if not trades or not fingerprint:
        raise RuntimeError(f"missing trades/fingerprint in output:\n{text}")
    result["trades"] = int(trades.group(1))
    result["fingerprint"] = fingerprint.group(1)
    return result


def replay(version: str, fee: str) -> tuple[str, str, dict[str, str | float | int]]:
    env = os.environ.copy()
    env.update({
        "ATM_HISTORY_FIXTURE": str(FIXTURE.relative_to(ROOT)),
        "ATM_NFCI_DUAL_CORE_V1_APP_VALIDATION": "1",
        "ATM_NFCI_DUAL_CORE_V1_FEE": fee,
    })
    if version == "v11":
        env["ATM_NFCI_DUAL_CORE_FORMAL_V11"] = "1"
    output = run([str(BINARY)], env=env, timeout=180)
    return version, fee, parse(output)


def assert_close(label: str, actual: float, expected: float, tolerance: float = 0.0000015) -> None:
    if abs(actual - expected) > tolerance:
        raise AssertionError(f"{label}: actual={actual:.6f} expected={expected:.6f}")


def main() -> int:
    compile_binary()
    jobs = [("v1", "1.0"), ("v1", "0.03"), ("v11", "1.0"), ("v11", "0.03")]
    results: dict[tuple[str, str], dict[str, str | float | int]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(replay, version, fee) for version, fee in jobs]
        for future in concurrent.futures.as_completed(futures):
            version, fee, metrics = future.result()
            results[(version, fee)] = metrics

    for version in ("v1", "v11"):
        baseline = results[(version, "1.0")]
        expected = EXPECTED[version]
        for key in ("cagr", "mdd", "vol", "sharpe"):
            assert_close(f"{version}.{key}", float(baseline[key]), float(expected[key]))
        if baseline["trades"] != expected["trades"]:
            raise AssertionError(f"{version}.trades: {baseline['trades']} != {expected['trades']}")
        if baseline["fingerprint"] != expected["fingerprint"]:
            raise AssertionError(
                f"{version}.fingerprint: {baseline['fingerprint']} != {expected['fingerprint']}"
            )
        low_fee = results[(version, "0.03")]
        if low_fee["fingerprint"] != baseline["fingerprint"]:
            raise AssertionError(
                f"{version} target path changed with fee: 1.0={baseline['fingerprint']} "
                f"0.03={low_fee['fingerprint']}"
            )
        print(
            f"{version.upper()}_OK "
            f"cagr={baseline['cagr']:.6f} mdd={baseline['mdd']:.6f} "
            f"sharpe={baseline['sharpe']:.6f} trades={baseline['trades']} "
            f"fingerprint={baseline['fingerprint']} low_fee_sharpe={low_fee['sharpe']:.6f}"
        )

    print("NFCI_DUAL_CORE_FROZEN_VERSIONS_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
