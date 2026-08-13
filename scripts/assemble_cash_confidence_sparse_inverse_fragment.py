#!/usr/bin/env python3
"""Build a no-financing sparse inverse experiment on the cash-confidence champion."""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match, found {count}: {old[:120]!r}")
    return text.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="tools/.risk_contribution_sparse_inverse.swiftpart")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    text = Path(args.base).read_text(encoding="utf-8")
    text = replace_once(
        text,
        'ProcessInfo.processInfo.environment["ATM_RISK_CONTRIBUTION_SPARSE_INVERSE_GRID"]',
        'ProcessInfo.processInfo.environment["ATM_CASH_CONFIDENCE_SPARSE_INVERSE_GRID"]',
    )
    text = replace_once(
        text,
        '''            let mode = AdvancedBacktestStrategyMode.riskContributionReallocation
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.strategyAssetOptions.map { ($0.symbol, $0) })''',
        '''            let mode = AdvancedBacktestStrategyMode.riskContributionCashConfidenceRouter
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.strategyAssetOptions.map { ($0.symbol, $0) })''',
    )
    text = replace_once(
        text,
        '''            guard let baseRun = BacktestEngine.runAdvancedRotationStrategyWithTrace(
                assetInputs: baseInputs,
                initialCash: 100_000,
                settings: settings,
                mode: mode
            ) else {
                print("APP_RISK_CONTRIBUTION_SPARSE_INVERSE_GRID\\nbase_missing")
                return
            }''',
        '''            Darwin.setenv("ATM_CC_RECOVERY_FAST_BREAK_THRESHOLD", "-0.05", 1)
            Darwin.setenv("ATM_CC_RECOVERY_COOLDOWN_SESSIONS", "150", 1)
            Darwin.setenv("ATM_CC_RECOVERY_MIN_HOLD_SESSIONS", "10", 1)
            Darwin.setenv("ATM_CC_RECOVERY_MIN_WATER_DURATION", "60", 1)
            Darwin.setenv("ATM_CC_RECOVERY_MIN_DRAWDOWN", "0.05", 1)
            Darwin.setenv("ATM_CC_RECOVERY_MAX_ENTRIES", "2", 1)
            Darwin.setenv("ATM_CC_RECOVERY_REVIEW_SESSIONS", "60", 1)
            Darwin.setenv("ATM_CC_RECOVERY_LEADER_SHARE_CAP", "1", 1)
            Darwin.setenv("ATM_CC_RECOVERY_FAST_REVIEW_VOL_THRESHOLD", "99", 1)
            Darwin.setenv("ATM_CC_RECOVERY_LEADER_SWITCH_MIN_SESSIONS", "10000", 1)
            Darwin.setenv("ATM_CC_PORTFOLIO_VOL_TARGET", "99", 1)
            Darwin.setenv("ATM_CC_CALM_CARRY_CAP", "0", 1)
            Darwin.setenv("ATM_CC_CALM_RISK_VOL_FLOOR", "0", 1)
            Darwin.setenv("ATM_CC_SECULAR_CARRY_CAP", "0", 1)
            Darwin.setenv("ATM_CC_GOLD_TO_US_SHIFT_FRACTION", "0", 1)
            Darwin.setenv("ATM_CC_EQUITY_CURVE_RISK_SCALE", "1", 1)
            Darwin.setenv("ATM_CC_USD_CASH_CAP", "0", 1)
            Darwin.setenv("ATM_CC_US_RISK_ALLOCATION_MODE", "0", 1)
            Darwin.setenv("ATM_CC_GLOBAL_RISK_PARITY_BLEND", "0", 1)
            guard let baseRun = BacktestEngine.researchCashConfidenceRunWithTrace(
                assetInputs: baseInputs,
                initialCash: 100_000,
                settings: settings
            ) else {
                print("APP_CASH_CONFIDENCE_SPARSE_INVERSE_GRID\\nbase_missing")
                return
            }''',
    )
    text = replace_once(
        text,
        '''            let hardFiveDayOptions = [-0.050, -0.065]
            let confirmedTwentyDayOptions = [-0.080, -0.120]
            let hedgeWeightOptions = [0.10, 0.15, 0.20, 0.25]
            let minimumHoldOptions = [5, 10]''',
        '''            let hardFiveDayOptions = [-0.050, -0.065]
            let confirmedTwentyDayOptions = [-0.080, -0.120]
            let hedgeWeightOptions = [0.10]
            let minimumHoldOptions = [5]''',
    )
    text = text.replace(
        '''                                maxGrossExposure: 1.35,
                                allowsFinancedExposure: true,
                                financingAnnualRate: 0.05,''',
        '''                                maxGrossExposure: 1.0,
                                allowsFinancedExposure: false,
                                financingAnnualRate: 0,''',
    )
    text = replace_once(
        text,
        '''                                    var target = latestBaseWeights
                                    if hedgeActive {
                                        target[inverseOption.symbol] = hedgeWeight
                                    }
                                    let gross = target.values.reduce(0, +)
                                    if gross > 1.35, gross > 0 {
                                        target = target.mapValues { $0 * 1.35 / gross }
                                    }''',
        '''                                    var target = latestBaseWeights
                                    if hedgeActive {
                                        let baseGross = target.values.reduce(0, +)
                                        target[inverseOption.symbol] = min(
                                            hedgeWeight,
                                            max(1 - baseGross, 0)
                                        )
                                    }''',
    )
    text = text.replace("APP_RISK_CONTRIBUTION_SPARSE_INVERSE", "APP_CASH_CONFIDENCE_SPARSE_INVERSE")
    text = text.replace('id: "risk_contribution_sparse_inverse"', 'id: "cash_confidence_sparse_inverse"')
    text = text.replace('symbol: "risk_contribution_sparse_inverse"', 'symbol: "cash_confidence_sparse_inverse"')

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8")
    print(f"assembled={output} bytes={len(text.encode('utf-8'))}")


if __name__ == "__main__":
    main()
