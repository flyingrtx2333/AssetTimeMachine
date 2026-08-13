#!/usr/bin/env python3
"""Build a cash-funded true-CTA experiment from the durable CTA research fragment."""

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
    parser.add_argument("--base", default="tools/.risk_contribution_true_cta.swiftpart")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    text = Path(args.base).read_text(encoding="utf-8")
    text = replace_once(
        text,
        'ProcessInfo.processInfo.environment["ATM_RISK_CONTRIBUTION_TRUE_CTA_GRID"]',
        'ProcessInfo.processInfo.environment["ATM_CASH_CONFIDENCE_TRUE_CTA_GRID"]',
    )
    text = replace_once(
        text,
        '''            let lookbackSets: [(String, [Int])] = [
                ("fast", [20, 60, 120]),
                ("slow", [60, 120, 252]),
                ("multi", [20, 60, 120, 252])
            ]
            var ctaConfigs: [TrueCTAConfig] = []
            for lookbackSet in lookbackSets {
                for updateInterval in [5, 20] {
                    for targetVolatility in [0.10, 0.15] {
                        ctaConfigs.append(TrueCTAConfig(
                            name: lookbackSet.0 + "_u" + String(updateInterval) + "_v" + String(Int(targetVolatility * 100)),
                            lookbacks: lookbackSet.1,
                            updateInterval: updateInterval,
                            targetVolatility: targetVolatility
                        ))
                    }
                }
            }''',
        '''            let ctaConfigs: [TrueCTAConfig] = [
                TrueCTAConfig(name: "slow_u20_v10", lookbacks: [60, 120, 252], updateInterval: 20, targetVolatility: 0.10),
                TrueCTAConfig(name: "slow_u20_v15", lookbacks: [60, 120, 252], updateInterval: 20, targetVolatility: 0.15),
                TrueCTAConfig(name: "multi_u20_v10", lookbacks: [20, 60, 120, 252], updateInterval: 20, targetVolatility: 0.10),
                TrueCTAConfig(name: "multi_u20_v15", lookbacks: [20, 60, 120, 252], updateInterval: 20, targetVolatility: 0.15),
            ]''',
    )
    text = replace_once(
        text,
        '''            let mode = AdvancedBacktestStrategyMode.riskContributionReallocation
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.strategyAssetOptions.map { ($0.symbol, $0) })
            let baseInputs = mode.requiredSignalAssetSymbols.compactMap { optionsBySymbol[$0] }.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            guard let baseRun = BacktestEngine.runAdvancedRotationStrategyWithTrace(
                assetInputs: baseInputs,
                initialCash: 100_000,
                settings: settings,
                mode: mode
            ) else {
                print("APP_RISK_CONTRIBUTION_TRUE_CTA_GRID\\nbase_missing")
                return
            }''',
        '''            let mode = AdvancedBacktestStrategyMode.riskContributionCashConfidenceRouter
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.strategyAssetOptions.map { ($0.symbol, $0) })
            let baseInputs = mode.requiredSignalAssetSymbols.compactMap { optionsBySymbol[$0] }.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            Darwin.setenv("ATM_CC_RECOVERY_FAST_BREAK_THRESHOLD", "-0.05", 1)
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
            guard let baseRun = BacktestEngine.researchCashConfidenceRunWithTrace(
                assetInputs: baseInputs,
                initialCash: 100_000,
                settings: settings
            ) else {
                print("APP_CASH_CONFIDENCE_TRUE_CTA_GRID\\nbase_missing")
                return
            }''',
    )
    text = replace_once(
        text,
        '''            let ctaWeightOptions = [0.10, 0.15, 0.20]
            let grossCapOptions = [1.10, 1.20]''',
        '''            let ctaWeightOptions = [0.10]
            let grossCapOptions = [1.00]''',
    )
    text = replace_once(
        text,
        '''                                var target = latestBaseWeights
                                target[ctaOption.symbol] = ctaWeight
                                let gross = target.values.reduce(0, +)
                                if gross > grossCap, gross > 0 {
                                    target = target.mapValues { $0 * grossCap / gross }
                                }''',
        '''                                var target = latestBaseWeights
                                let baseGross = target.values.reduce(0, +)
                                let availableCash = max(grossCap - baseGross, 0)
                                target[ctaOption.symbol] = min(ctaWeight, availableCash)''',
    )
    text = text.replace("APP_RISK_CONTRIBUTION_TRUE_CTA", "APP_CASH_CONFIDENCE_TRUE_CTA")
    text = text.replace('id: "risk_contribution_true_cta"', 'id: "cash_confidence_true_cta"')
    text = text.replace('symbol: "risk_contribution_true_cta"', 'symbol: "cash_confidence_true_cta"')
    text = text.replace('maxGrossExposure: grossCap,\n                            allowsFinancedExposure: grossCap > 1,\n                            financingAnnualRate: grossCap > 1 ? 0.05 : 0,',
                        'maxGrossExposure: 1.0,\n                            allowsFinancedExposure: false,\n                            financingAnnualRate: 0,')
    text = text.replace('format: "冠军+真CTA-%@-C%.0f-G%.0f",', 'format: "现金冠军+真CTA-%@-C%.0f-G%.0f",')

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8")
    print(f"assembled={output} bytes={len(text.encode('utf-8'))}")


if __name__ == "__main__":
    main()
