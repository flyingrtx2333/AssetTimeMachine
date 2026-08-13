#!/usr/bin/env python3
"""Create a temporary production-engine variant for recovery cadence/cap research."""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match, found {count}: {old!r}")
    return text.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="AssetTimeMachine/Backtest/BacktestEngine.swift")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    text = Path(args.base).read_text(encoding="utf-8")

    # Research-only closed-loop actual-gross guard. The production simulator
    # remains untouched; the temporary engine can force a maintenance rebalance
    # when mark-to-market drift pushes real invested value above a configured cap.
    text = replace_once(
        text,
        '''            let signalIndex = index - 1
            let preRebalanceValue = portfolioValue(at: index)
            let signalDate = signalIndex >= 0 && frame.dates.indices.contains(signalIndex)''',
        '''            let signalIndex = index - 1
            let preRebalanceValue = portfolioValue(at: index)
            let researchActualGrossCap = Double(
                ProcessInfo.processInfo.environment["ATM_RESEARCH_ACTUAL_GROSS_CAP"] ?? "99"
            ) ?? 99
            let preRebalanceInvestedValue = frame.tradableSymbols.reduce(0.0) { partial, symbol in
                partial + (unitsBySymbol[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?[index] ?? 0)
            }
            let preRebalanceGross = preRebalanceValue > 0
                ? preRebalanceInvestedValue / preRebalanceValue
                : 0
            let forceActualGrossRebalance = researchActualGrossCap < 99
                && preRebalanceGross > researchActualGrossCap
            let signalDate = signalIndex >= 0 && frame.dates.indices.contains(signalIndex)''',
    )
    text = replace_once(
        text,
        '''            let decision = contextualRebalanceDecision?(decisionContext)
                ?? rebalanceDecision(index, signalIndex)
            if decision.shouldRebalance {''',
        '''            var decision = contextualRebalanceDecision?(decisionContext)
                ?? rebalanceDecision(index, signalIndex)
            if forceActualGrossRebalance {
                decision = BacktestRebalanceDecision(shouldRebalance: true, refreshOverlay: false)
            }
            if decision.shouldRebalance {''',
    )
    text = replace_once(
        text,
        "                let targetWeights: [String: Double]",
        "                var targetWeights: [String: Double]",
    )
    text = replace_once(
        text,
        '''                currentTargetWeights = targetWeights
                let targetSymbols = Set(targetWeights.keys)''',
        '''                if forceActualGrossRebalance {
                    let researchActualGrossResetCap = Double(
                        ProcessInfo.processInfo.environment["ATM_RESEARCH_ACTUAL_GROSS_RESET_CAP"]
                            ?? String(researchActualGrossCap)
                    ) ?? researchActualGrossCap
                    let targetGross = targetWeights.values.reduce(0, +)
                    if targetGross > researchActualGrossResetCap, targetGross > 0 {
                        targetWeights = targetWeights.mapValues {
                            $0 * researchActualGrossResetCap / targetGross
                        }
                    }
                }
                currentTargetWeights = targetWeights
                let effectiveRebalanceBand = forceActualGrossRebalance ? 0 : execution.rebalanceBand
                let targetSymbols = Set(targetWeights.keys)''',
    )
    text = replace_once(
        text,
        '                    let grossValueToSell = currentValue > targetValue * (1 + execution.rebalanceBand)',
        '                    let grossValueToSell = currentValue > targetValue * (1 + effectiveRebalanceBand)',
    )
    text = replace_once(
        text,
        '                    let amountToInvest = currentValue < targetValue * (1 - execution.rebalanceBand)',
        '                    let amountToInvest = currentValue < targetValue * (1 - effectiveRebalanceBand)',
    )
    text = replace_once(
        text,
        '''            let value = portfolioValue(at: index)
            points.append(.init(date: date, portfolioValue: value, sequence: points.count))''',
        '''            let researchPostTradeGrossCap = Double(
                ProcessInfo.processInfo.environment["ATM_RESEARCH_POST_TRADE_GROSS_CAP"] ?? "99"
            ) ?? 99
            if researchPostTradeGrossCap < 99 {
                let maintenanceValue = portfolioValue(at: index)
                let maintenanceHoldings = frame.tradableSymbols.reduce(0.0) { partial, symbol in
                    partial + (unitsBySymbol[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?[index] ?? 0)
                }
                let maintenanceGross = maintenanceValue > 0
                    ? maintenanceHoldings / maintenanceValue
                    : 0
                if maintenanceGross > researchPostTradeGrossCap,
                   maintenanceHoldings > 0,
                   maintenanceValue > 0 {
                    let executionProceedsFactor = max(
                        (1 - execution.slippageRate) * (1 - execution.feeRate),
                        0.0001
                    )
                    let denominator = max(
                        1 - researchPostTradeGrossCap * (1 - executionProceedsFactor),
                        0.0001
                    )
                    let requiredMarketSale = min(
                        max(
                            (maintenanceHoldings - researchPostTradeGrossCap * maintenanceValue) / denominator,
                            0
                        ),
                        maintenanceHoldings
                    )
                    for symbol in frame.tradableSymbols.sorted() {
                        guard requiredMarketSale > 0,
                              let price = frame.pricesBySymbol[symbol]?[index],
                              price > 0,
                              let currentUnits = unitsBySymbol[symbol],
                              currentUnits > 0,
                              let option = frame.optionBySymbol[symbol] else { continue }
                        let currentMarketValue = currentUnits * price
                        guard currentMarketValue > 0 else { continue }
                        let marketValueToSell = requiredMarketSale * currentMarketValue / maintenanceHoldings
                        let unitsToSell = min(currentUnits, marketValueToSell / price)
                        guard unitsToSell > 0 else { continue }
                        let executionPrice = max(price * (1 - execution.slippageRate), 0)
                        let grossValue = unitsToSell * executionPrice
                        let cashAmount = grossValue * (1 - execution.feeRate)
                        cash += cashAmount
                        let remainingUnits = max(currentUnits - unitsToSell, 0)
                        unitsBySymbol[symbol] = remainingUnits
                        let averageCost = averageCostBySymbol[symbol] ?? 0
                        let realizedCostBasis = averageCost * unitsToSell
                        let realizedProfit = cashAmount - realizedCostBasis
                        let realizedReturn = realizedCostBasis > 0 ? realizedProfit / realizedCostBasis : nil
                        let holdingDays = entryDateBySymbol[symbol].map {
                            Calendar.current.dateComponents([.day], from: $0, to: date).day ?? 0
                        }
                        trades.append(.init(
                            assetSymbol: symbol,
                            assetTitle: option.title,
                            date: date,
                            action: .sell,
                            price: executionPrice,
                            cashAmount: cashAmount,
                            units: unitsToSell,
                            reason: "研究实际杠杆维护",
                            realizedProfit: realizedProfit,
                            realizedReturn: realizedReturn,
                            holdingDays: holdingDays
                        ))
                        if remainingUnits <= Double.leastNonzeroMagnitude {
                            averageCostBySymbol[symbol] = 0
                            entryDateBySymbol[symbol] = nil
                            heldSymbols.remove(symbol)
                        }
                    }
                }
            }

            let value = portfolioValue(at: index)
            points.append(.init(date: date, portfolioValue: value, sequence: points.count))''',
    )

    # Build 158 moved the validated recovery-exit parameters and near-peak
    # de-risk buffer into production. Remove only the production buffer layer
    # before injecting research variants, otherwise experiments would be
    # applied twice.
    production_constants = '''        let nearPeakDeRiskExecutionFraction = 0.875
        let nearPeakDeRiskDrawdownThreshold = 0.04
        let nearPeakDeRiskMaximumRetention = 0.25
        let broadUnwindTurnoverThreshold = 0.60
'''
    if production_constants in text:
        text = text.replace(production_constants, "", 1)

    production_buffer_start = '''                if !previousWeights.isEmpty {
                    let priorGross = previousWeights.values.reduce(0, +)
                    let targetGross = pendingWeights.values.reduce(0, +)
                    if targetGross >= 0.05,
                       targetGross < priorGross - 0.02,
                       alignedBaseValues.indices.contains(signalIndex),
                       let currentBaseValue = alignedBaseValues[signalIndex],
                       currentBaseValue > 0 {
'''
    production_buffer_end = '''                let gross = pendingWeights.values.reduce(0, +)
'''
    buffer_start_index = text.find(production_buffer_start)
    if buffer_start_index >= 0:
        buffer_end_index = text.find(production_buffer_end, buffer_start_index)
        if buffer_end_index < 0:
            raise SystemExit("production near-peak buffer end anchor not found")
        text = text[:buffer_start_index] + text[buffer_end_index:]

    text = replace_once(
        text,
        '''        static let cashConfidenceAdaptive = RecoverySleeveQualityConfig(
            dynamicVolatilityThreshold: 0.06,
            dynamicSleeveCap: 0.19,
            momentumLookback: 95,
            momentumScale: 50,
            volatilityExponent: 0.60,
            downsideVolatilityBlend: 0.75,
            baseQualityExponent: 4,
            highQualityExponent: 12,
            qualityGapThreshold: 0.035,
            trendEfficiencyScale: 1.75
        )''',
        '''        static var cashConfidenceAdaptive: RecoverySleeveQualityConfig {
            RecoverySleeveQualityConfig(
                dynamicVolatilityThreshold: Double(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_DYNAMIC_VOL_THRESHOLD"] ?? "0.06") ?? 0.06,
                dynamicSleeveCap: Double(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_DYNAMIC_SLEEVE_CAP"] ?? "0.19") ?? 0.19,
                momentumLookback: Int(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_QUALITY_MOMENTUM_LOOKBACK"] ?? "95") ?? 95,
                momentumScale: Double(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_QUALITY_MOMENTUM_SCALE"] ?? "50") ?? 50,
                volatilityExponent: Double(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_QUALITY_VOL_EXPONENT"] ?? "0.60") ?? 0.60,
                downsideVolatilityBlend: Double(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_QUALITY_DOWNSIDE_BLEND"] ?? "0.75") ?? 0.75,
                baseQualityExponent: Double(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_QUALITY_BASE_EXPONENT"] ?? "4") ?? 4,
                highQualityExponent: Double(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_QUALITY_HIGH_EXPONENT"] ?? "12") ?? 12,
                qualityGapThreshold: Double(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_QUALITY_GAP_THRESHOLD"] ?? "0.035") ?? 0.035,
                trendEfficiencyScale: Double(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_QUALITY_TREND_EFFICIENCY"] ?? "1.75") ?? 1.75
            )
        }''',
    )
    text = replace_once(
        text,
        '''        guard let baseRun = runRiskContributionRecoveryRouterWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            dateBounds: dateBounds,
            growthStateScale: 1.05,
            fastBridgeRatio: 0.15,
            sleeveCap: 0.2075,
            recoveryQualityConfig: .cashConfidenceAdaptive,
            recoveryCooldownSessions: 150,
            recoveryFastBreakThreshold: -0.05
        ) else { return nil }''',
        '''        let baseAssetInputs = assetInputs.filter {
            $0.assetOption.symbol != "usd_cash"
        }
        let researchRecoverySleeveCap = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_SLEEVE_CAP"] ?? "0.2075"
        ) ?? 0.2075
        guard let baseRun = runRiskContributionRecoveryRouterWithTrace(
            assetInputs: baseAssetInputs,
            initialCash: initialCash,
            settings: settings,
            dateBounds: dateBounds,
            growthStateScale: 1.05,
            fastBridgeRatio: 0.15,
            sleeveCap: researchRecoverySleeveCap,
            recoveryQualityConfig: .cashConfidenceAdaptive,
            recoveryCooldownSessions: 150,
            recoveryFastBreakThreshold: -0.05
        ) else { return nil }''',
    )
    text = replace_once(
        text,
        "        let tradeBand = 0.20",
        '        let tradeBand = Double(ProcessInfo.processInfo.environment["ATM_CC_TRADE_BAND"] ?? "0.20") ?? 0.20',
    )
    text = replace_once(
        text,
        "        let matureNasdaqMAPeriod = 40",
        '        let matureNasdaqMAPeriod = Int(ProcessInfo.processInfo.environment["ATM_CC_NASDAQ_MA"] ?? "40") ?? 40',
    )
    text = replace_once(
        text,
        "        let matureNasdaqScale = 0.88",
        '        let matureNasdaqScale = Double(ProcessInfo.processInfo.environment["ATM_CC_NASDAQ_SCALE"] ?? "0.88") ?? 0.88',
    )
    text = replace_once(
        text,
        "        let matureOtherAssetScale = 0.80",
        '        let matureOtherAssetScale = Double(ProcessInfo.processInfo.environment["ATM_CC_OTHER_SCALE"] ?? "0.80") ?? 0.80',
    )
    text = replace_once(
        text,
        "        let grossCap = 1.0",
        '''        let grossCap = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RETURN_GROSS_CAP"] ?? "1.0"
        ) ?? 1.0
        let returnScale = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RETURN_SCALE"] ?? "1.0"
        ) ?? 1.0
        let returnGoldScale = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RETURN_GOLD_SCALE"] ?? String(returnScale)
        ) ?? returnScale
        let returnUSScale = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RETURN_US_SCALE"] ?? String(returnScale)
        ) ?? returnScale
        let returnNasdaqScale = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RETURN_NASDAQ_SCALE"] ?? String(returnUSScale)
        ) ?? returnUSScale
        let returnSP500Scale = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RETURN_SP500_SCALE"] ?? String(returnUSScale)
        ) ?? returnUSScale
        let returnChinaScale = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RETURN_CHINA_SCALE"] ?? String(returnScale)
        ) ?? returnScale
        let returnChinaStrongScale = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RETURN_CHINA_STRONG_SCALE"] ?? String(returnChinaScale)
        ) ?? returnChinaScale
        let returnFinancingAnnualRate = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RETURN_FINANCING_RATE"] ?? "0.05"
        ) ?? 0.05
        let returnDeRiskDrawdownThreshold = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RETURN_DD_THRESHOLD"] ?? "99"
        ) ?? 99
        let returnDeRiskScale = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RETURN_DERISK_SCALE"] ?? String(returnScale)
        ) ?? returnScale''',
    )
    text = replace_once(
        text,
        '''            maxGrossExposure: grossCap,
            allowsFinancedExposure: false,
            financingAnnualRate: 0,''',
        '''            maxGrossExposure: grossCap,
            allowsFinancedExposure: grossCap > 1.000001,
            financingAnnualRate: grossCap > 1.000001 ? returnFinancingAnnualRate : 0,''',
    )
    text = replace_once(
        text,
        '''        var leadershipFailures: [String: Double] = [:]

        func leaderName''',
        '''        var leadershipFailures: [String: Double] = [:]
        var stagedHandoffTargetLeader: String?
        var stagedHandoffPriorLeader: String?
        var stagedHandoffResolveIndex = -1
        var stagedHandoffStartPrices: [String: Double] = [:]
        var buyConfirmationStreaks: [String: Int] = [:]
        var deRiskCalibrationTrials: [OnlineLeadershipTrial] = []
        var deRiskCalibrationSuccesses: [String: Double] = [:]
        var deRiskCalibrationFailures: [String: Double] = [:]
        var deRiskBufferLeader: String?
        var deRiskBufferWeights: [String: Double] = [:]
        var deRiskBufferEntryIndex = -1
        var deRiskBufferBaseTargetGross = 0.0
        var deRiskBufferEntryBaseValue = 0.0
        var exitSentinelWeights: [String: Double] = [:]
        var exitSentinelRemainingSessions = 0
        var exitSentinelEntryIndex = -1
        var mediumExitConfirmationStreak = 0
        var idleDualTrendSleeveWeights: [String: Double] = [:]
        var idleDualTrendLastReviewIndex = -10_000
        var secularCarryActive = false
        var secularCarryRiskOnStreak = 0
        var secularCarryRiskOffStreak = 0
        var equityCurveRiskOffActive = false
        var equityCurveRiskOffStreak = 0
        var equityCurveRiskOnStreak = 0
        var usdCashActive = false
        var usdCashRiskOnStreak = 0
        var usdCashRiskOffStreak = 0

        func leaderName''',
    )
    text = replace_once(
        text,
        '''        let leadershipEvaluationSessions = 10
        let leadershipPriorEvidence = 2.0''',
        '''        let leadershipEvaluationSessions = 10
        let disableMidGrossCliffs = ProcessInfo.processInfo.environment["ATM_CC_DISABLE_MID_GROSS_CLIFFS"] == "1"
        let disableBreadthMicroBrakes = ProcessInfo.processInfo.environment["ATM_CC_DISABLE_BREADTH_MICRO_BRAKES"] == "1"
        let breadthMicroBrakeStrength = disableBreadthMicroBrakes
            ? 0
            : min(max(
                Double(ProcessInfo.processInfo.environment["ATM_CC_BREADTH_MICRO_BRAKE_STRENGTH"] ?? "1") ?? 1,
                0
            ), 1)
        let breadthBrake40OneStrength = breadthMicroBrakeStrength * min(max(
            Double(ProcessInfo.processInfo.environment["ATM_CC_BREADTH_BRAKE_40_ONE_STRENGTH"] ?? "1") ?? 1,
            0
        ), 1)
        let breadthBrake10FourStrength = breadthMicroBrakeStrength * min(max(
            Double(ProcessInfo.processInfo.environment["ATM_CC_BREADTH_BRAKE_10_FOUR_STRENGTH"] ?? "1") ?? 1,
            0
        ), 1)
        let breadthBrake20OneStrength = breadthMicroBrakeStrength * min(max(
            Double(ProcessInfo.processInfo.environment["ATM_CC_BREADTH_BRAKE_20_ONE_STRENGTH"] ?? "1") ?? 1,
            0
        ), 1)
        let disableHoldHysteresis = ProcessInfo.processInfo.environment["ATM_CC_DISABLE_HOLD_HYSTERESIS"] == "1"
        let disableMatureNasdaqBrake = ProcessInfo.processInfo.environment["ATM_CC_DISABLE_MATURE_NASDAQ_BRAKE"] == "1"
        let disableChinaPurge = ProcessInfo.processInfo.environment["ATM_CC_DISABLE_CHINA_PURGE"] == "1"
        let grossConfidenceShape = Int(
            ProcessInfo.processInfo.environment["ATM_CC_GROSS_CONFIDENCE_SHAPE"] ?? "0"
        ) ?? 0
        let stagedHandoffMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_STAGED_HANDOFF_MODE"] ?? "0"
        ) ?? 0
        let stagedHandoffInitialMigration = Double(
            ProcessInfo.processInfo.environment["ATM_CC_STAGED_HANDOFF_INITIAL_MIGRATION"] ?? "0.50"
        ) ?? 0.50
        let stagedHandoffEvaluationSessions = Int(
            ProcessInfo.processInfo.environment["ATM_CC_STAGED_HANDOFF_EVALUATION_SESSIONS"] ?? "10"
        ) ?? 10
        let stagedHandoffRequiredEdge = Double(
            ProcessInfo.processInfo.environment["ATM_CC_STAGED_HANDOFF_REQUIRED_EDGE"] ?? "0"
        ) ?? 0
        let componentRebalanceMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_COMPONENT_REBALANCE_MODE"] ?? "0"
        ) ?? 0
        let componentRebalanceBand = Double(
            ProcessInfo.processInfo.environment["ATM_CC_COMPONENT_REBALANCE_BAND"] ?? "0"
        ) ?? 0
        let componentRebalanceVolatilityCeiling = Double(
            ProcessInfo.processInfo.environment["ATM_CC_COMPONENT_REBALANCE_VOL_CEILING"] ?? "99"
        ) ?? 99
        let buyConfirmationSessions = Int(
            ProcessInfo.processInfo.environment["ATM_CC_BUY_CONFIRMATION_SESSIONS"] ?? "1"
        ) ?? 1
        let nearPeakDeRiskMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_MODE"] ?? "1"
        ) ?? 1
        let nearPeakDeRiskFraction = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_FRACTION"] ?? "1"
        ) ?? 1
        let nearPeakDeRiskDrawdownThreshold = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_DD_THRESHOLD"] ?? "0"
        ) ?? 0
        let nearPeakDeRiskDrawdownDecayMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_DD_DECAY_MODE"] ?? "0"
        ) ?? 0
        let nearPeakDeRiskIncludesExit = ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_INCLUDE_EXIT"] == "1"
        let nearPeakDeRiskGrossDropThreshold = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_GROSS_DROP_THRESHOLD"] ?? "0.02"
        ) ?? 0.02
        let nearPeakDeRiskSeverityMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_SEVERITY_MODE"] ?? "0"
        ) ?? 0
        let nearPeakDeRiskMaximumRetention = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_MAX_RETENTION"] ?? "0.25"
        ) ?? 0.25
        let nearPeakDeRiskMinimumRetention = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_MIN_RETENTION"] ?? "0"
        ) ?? 0
        let nearPeakDeRiskCutBudgetMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_CUT_BUDGET_MODE"] ?? "0"
        ) ?? 0
        let nearPeakDeRiskCutBudget = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_CUT_BUDGET"] ?? "0.20"
        ) ?? 0.20
        let nearPeakDeRiskLeaderSaleCap = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_LEADER_SALE_CAP"] ?? "0"
        ) ?? 0
        let nearPeakDeRiskBroadUnwindTurnoverThreshold = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_BROAD_UNWIND_TURNOVER_THRESHOLD"] ?? "99"
        ) ?? 99
        let nearPeakDeRiskBlendTurnoverStart = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_BLEND_TURNOVER_START"] ?? "0.40"
        ) ?? 0.40
        let nearPeakDeRiskBlendTurnoverEnd = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_BLEND_TURNOVER_END"] ?? "0.80"
        ) ?? 0.80
        let nearPeakDeRiskScope = Int(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_SCOPE"] ?? "0"
        ) ?? 0
        let nearPeakDeRiskTrendGate = Int(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_TREND_GATE"] ?? "0"
        ) ?? 0
        let nearPeakDeRiskLeaderGate = Int(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_LEADER_GATE"] ?? "0"
        ) ?? 0
        let nearPeakDeRiskHighVolThreshold = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_HIGH_VOL_THRESHOLD"] ?? "99"
        ) ?? 99
        let nearPeakDeRiskHighVolFraction = Double(
            ProcessInfo.processInfo.environment["ATM_CC_NEAR_PEAK_DERISK_HIGH_VOL_FRACTION"] ?? String(nearPeakDeRiskFraction)
        ) ?? nearPeakDeRiskFraction
        let deRiskCalibrationMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_DERISK_CALIBRATION_MODE"] ?? "0"
        ) ?? 0
        let deRiskCalibrationEvaluationSessions = Int(
            ProcessInfo.processInfo.environment["ATM_CC_DERISK_CALIBRATION_EVALUATION_SESSIONS"] ?? "20"
        ) ?? 20
        let deRiskCalibrationPriorEvidence = Double(
            ProcessInfo.processInfo.environment["ATM_CC_DERISK_CALIBRATION_PRIOR"] ?? "2"
        ) ?? 2
        let deRiskCalibrationMaximumRetention = Double(
            ProcessInfo.processInfo.environment["ATM_CC_DERISK_CALIBRATION_MAX_RETENTION"] ?? "0.25"
        ) ?? 0.25
        let deRiskBufferMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_DERISK_BUFFER_MODE"] ?? "0"
        ) ?? 0
        let deRiskBufferMaximumSessions = Int(
            ProcessInfo.processInfo.environment["ATM_CC_DERISK_BUFFER_MAX_SESSIONS"] ?? "60"
        ) ?? 60
        let deRiskBufferLossThreshold = Double(
            ProcessInfo.processInfo.environment["ATM_CC_DERISK_BUFFER_LOSS_THRESHOLD"] ?? "0.02"
        ) ?? 0.02
        let exitSentinelWeight = Double(
            ProcessInfo.processInfo.environment["ATM_CC_EXIT_SENTINEL_WEIGHT"] ?? "0"
        ) ?? 0
        let exitSentinelConfirmationSessions = Int(
            ProcessInfo.processInfo.environment["ATM_CC_EXIT_SENTINEL_CONFIRMATION_SESSIONS"] ?? "1"
        ) ?? 1
        let exitSentinelDrawdownThreshold = Double(
            ProcessInfo.processInfo.environment["ATM_CC_EXIT_SENTINEL_DD_THRESHOLD"] ?? "0.02"
        ) ?? 0.02
        let exitSentinelVolatilityMinimum = Double(
            ProcessInfo.processInfo.environment["ATM_CC_EXIT_SENTINEL_VOL_MIN"] ?? "0"
        ) ?? 0
        let exitSentinelVolatilityMaximum = Double(
            ProcessInfo.processInfo.environment["ATM_CC_EXIT_SENTINEL_VOL_MAX"] ?? "99"
        ) ?? 99
        let exitSentinelPriorGrossMinimum = Double(
            ProcessInfo.processInfo.environment["ATM_CC_EXIT_SENTINEL_PRIOR_GROSS_MIN"] ?? "0"
        ) ?? 0
        let exitSentinelPriorGrossMaximum = Double(
            ProcessInfo.processInfo.environment["ATM_CC_EXIT_SENTINEL_PRIOR_GROSS_MAX"] ?? "1.01"
        ) ?? 1.01
        let exitSentinelLeaderGate = Int(
            ProcessInfo.processInfo.environment["ATM_CC_EXIT_SENTINEL_LEADER_GATE"] ?? "0"
        ) ?? 0
        let riskIncreaseMigrationFloor = Double(
            ProcessInfo.processInfo.environment["ATM_CC_RISK_INCREASE_MIGRATION_FLOOR"] ?? "0"
        ) ?? 0
        let riskIncreaseGrossCompletionMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_RISK_INCREASE_GROSS_COMPLETION_MODE"] ?? "0"
        ) ?? 0
        let sp500CrossConfirmationMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_SP500_CROSS_CONFIRMATION_MODE"] ?? "0"
        ) ?? 0
        let sp500CrossConfirmationRetainedIncrease = Double(
            ProcessInfo.processInfo.environment["ATM_CC_SP500_CROSS_CONFIRMATION_RETAINED_INCREASE"] ?? "1"
        ) ?? 1
        let sp500CrossConfirmationMinimumIncrease = Double(
            ProcessInfo.processInfo.environment["ATM_CC_SP500_CROSS_CONFIRMATION_MIN_INCREASE"] ?? "0.10"
        ) ?? 0.10
        let sp500CrossConfirmationMinimumTarget = Double(
            ProcessInfo.processInfo.environment["ATM_CC_SP500_CROSS_CONFIRMATION_MIN_TARGET"] ?? "0.20"
        ) ?? 0.20
        let idleDualTrendSleeveCap = Double(
            ProcessInfo.processInfo.environment["ATM_CC_IDLE_DUAL_TREND_SLEEVE_CAP"] ?? "0"
        ) ?? 0
        let idleDualTrendBaseGrossMaximum = Double(
            ProcessInfo.processInfo.environment["ATM_CC_IDLE_DUAL_TREND_BASE_GROSS_MAX"] ?? "0.40"
        ) ?? 0.40
        let idleDualTrendReviewSessions = Int(
            ProcessInfo.processInfo.environment["ATM_CC_IDLE_DUAL_TREND_REVIEW_SESSIONS"] ?? "63"
        ) ?? 63
        let idleDualTrendSleeveMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_IDLE_DUAL_TREND_SLEEVE_MODE"] ?? "0"
        ) ?? 0
        let outputAssetAblationMode = Int(
            ProcessInfo.processInfo.environment["ATM_CC_OUTPUT_ASSET_ABLATION_MODE"] ?? "0"
        ) ?? 0
        let outputSP500Scale = Double(
            ProcessInfo.processInfo.environment["ATM_CC_OUTPUT_SP500_SCALE"] ?? "1"
        ) ?? 1
        let leadershipPriorEvidence = 2.0''',
    )
    text = replace_once(
        text,
        "        let reviewSessions = 60",
        '''        let reviewSessions = recoveryQualityConfig == nil
            ? 60
            : (Int(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_REVIEW_SESSIONS"] ?? "60") ?? 60)''',
    )
    text = replace_once(
        text,
        "        let minimumWaterDuration = 60",
        '''        let minimumWaterDuration = recoveryQualityConfig == nil
            ? 60
            : (Int(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_MIN_WATER_DURATION"] ?? "60") ?? 60)''',
    )
    text = replace_once(
        text,
        "        let minimumDrawdown = 0.05",
        '''        let minimumDrawdown = recoveryQualityConfig == nil
            ? 0.05
            : (Double(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_MIN_DRAWDOWN"] ?? "0.05") ?? 0.05)''',
    )
    text = replace_once(
        text,
        "        let maximumEntriesPerEpisode = 2",
        '''        let maximumEntriesPerEpisode = recoveryQualityConfig == nil
            ? 2
            : (Int(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_MAX_ENTRIES"] ?? "2") ?? 2)''',
    )
    text = replace_once(
        text,
        "        let cooldownSessions = recoveryCooldownSessions",
        '''        let cooldownSessions = recoveryQualityConfig == nil
            ? recoveryCooldownSessions
            : (Int(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_COOLDOWN_SESSIONS"] ?? String(recoveryCooldownSessions)) ?? recoveryCooldownSessions)''',
    )
    text = replace_once(
        text,
        "        let minimumHoldSessions = 10",
        '''        let minimumHoldSessions = recoveryQualityConfig == nil
            ? 10
            : (Int(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_MIN_HOLD_SESSIONS"] ?? "10") ?? 10)''',
    )
    text = replace_once(
        text,
        "        let fastBreakThreshold = recoveryFastBreakThreshold",
        '''        let fastBreakThreshold = recoveryQualityConfig == nil
            ? recoveryFastBreakThreshold
            : (Double(ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_FAST_BREAK_THRESHOLD"] ?? String(recoveryFastBreakThreshold)) ?? recoveryFastBreakThreshold)''',
    )
    text = replace_once(
        text,
        '''                if recoveryActive,
                   signalIndex - lastRecoveryReviewIndex >= reviewSessions {''',
        '''                let fastReviewVolatilityThreshold = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_FAST_REVIEW_VOL_THRESHOLD"] ?? "99"
                ) ?? 99
                let fastReviewSessions = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_FAST_REVIEW_SESSIONS"] ?? "40"
                ) ?? 40
                let fastReviewQualityGapThreshold = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_FAST_REVIEW_QUALITY_GAP_THRESHOLD"] ?? "0"
                ) ?? 0
                var activeReviewSessions = reviewSessions
                if recoveryQualityConfig != nil,
                   fastReviewVolatilityThreshold < 99,
                   signalIndex >= 60 {
                    var recentReturns: [Double] = []
                    for cursor in (signalIndex - 59)...signalIndex {
                        guard cursor > 0,
                              let previousValue = alignedBaseValues[cursor - 1],
                              let currentValue = alignedBaseValues[cursor],
                              previousValue > 0 else { continue }
                        recentReturns.append(currentValue / previousValue - 1)
                    }
                    if recentReturns.count > 1 {
                        let mean = recentReturns.reduce(0, +) / Double(recentReturns.count)
                        let variance = recentReturns.reduce(0.0) {
                            $0 + pow($1 - mean, 2)
                        } / Double(recentReturns.count - 1)
                        let annualizedVolatility = sqrt(max(variance, 0)) * sqrt(252)
                        let qualityGap = recoveryQualityConfig.flatMap { config -> Double? in
                            guard let nasdaqMomentum = priceMomentum(
                                values: nasdaqPrices,
                                at: signalIndex,
                                lookback: config.momentumLookback
                            ), let sp500Momentum = priceMomentum(
                                values: sp500Prices,
                                at: signalIndex,
                                lookback: config.momentumLookback
                            ) else { return nil }
                            return abs(max(nasdaqMomentum, 0) - max(sp500Momentum, 0))
                        } ?? 0
                        if annualizedVolatility >= fastReviewVolatilityThreshold,
                           qualityGap >= fastReviewQualityGapThreshold {
                            activeReviewSessions = max(fastReviewSessions, 1)
                        }
                    }
                }
                let leaderSwitchMinimumSessions = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_LEADER_SWITCH_MIN_SESSIONS"] ?? "10000"
                ) ?? 10000
                let leaderSwitchMomentumGap = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_LEADER_SWITCH_MOMENTUM_GAP"] ?? "99"
                ) ?? 99
                var leaderSwitchReviewDue = false
                let elapsedSinceReview = signalIndex - lastRecoveryReviewIndex
                if recoveryQualityConfig != nil,
                   recoveryActive,
                   elapsedSinceReview >= leaderSwitchMinimumSessions,
                   let currentLeader = recoveryWeights.max(by: { $0.value < $1.value })?.key,
                   let nasdaqSwitchMomentum = priceMomentum(
                    values: nasdaqPrices,
                    at: signalIndex,
                    lookback: 95
                   ),
                   let sp500SwitchMomentum = priceMomentum(
                    values: sp500Prices,
                    at: signalIndex,
                    lookback: 95
                   ) {
                    let nextLeader = nasdaqSwitchMomentum >= sp500SwitchMomentum
                        ? "nasdaq"
                        : "sp500"
                    let gap = abs(nasdaqSwitchMomentum - sp500SwitchMomentum)
                    leaderSwitchReviewDue = nextLeader != currentLeader
                        && gap >= leaderSwitchMomentumGap
                }
                if recoveryActive,
                   elapsedSinceReview >= activeReviewSessions || leaderSwitchReviewDue {''',
    )
    text = replace_once(
        text,
        '''                        for item in eligible {
                            nextRecoveryWeights[item.0] = denominator > 0
                                ? totalWeight * item.1 / denominator
                                : totalWeight / Double(eligible.count)
                        }''',
        '''                        for item in eligible {
                            nextRecoveryWeights[item.0] = denominator > 0
                                ? totalWeight * item.1 / denominator
                                : totalWeight / Double(eligible.count)
                        }
                        if recoveryQualityConfig != nil,
                           eligible.count == 2,
                           let leaderCap = Double(
                            ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_LEADER_SHARE_CAP"] ?? "1"
                           ),
                           leaderCap >= 0.5,
                           leaderCap < 1,
                           let leader = nextRecoveryWeights.max(by: { $0.value < $1.value }),
                           leader.value > totalWeight * leaderCap {
                            let otherSymbol = eligible.first(where: { $0.0 != leader.key })?.0
                            nextRecoveryWeights[leader.key] = totalWeight * leaderCap
                            if let otherSymbol {
                                nextRecoveryWeights[otherSymbol] = totalWeight * (1 - leaderCap)
                            }
                        }''',
    )
    text = replace_once(
        text,
        '''                let gross = pendingWeights.values.reduce(0, +)
                if gross > grossCap, gross > 0 {
                    pendingWeights = pendingWeights.mapValues { $0 * grossCap / gross }
                }
                let symbols = Set(previousWeights.keys).union(pendingWeights.keys)''',
        '''                let globalRiskParityBlend = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_GLOBAL_RISK_PARITY_BLEND"] ?? "0"
                ) ?? 0
                let globalRiskParityLookback = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_GLOBAL_RISK_PARITY_LOOKBACK"] ?? "63"
                ) ?? 63
                if globalRiskParityBlend > 0,
                   signalIndex >= globalRiskParityLookback {
                    let activeSymbols = pendingWeights.keys.filter {
                        (pendingWeights[$0] ?? 0) >= 0.02
                            && data.pricesBySymbol[$0] != nil
                    }
                    let activeGross = activeSymbols.reduce(0.0) {
                        $0 + (pendingWeights[$1] ?? 0)
                    }
                    if activeSymbols.count >= 2, activeGross > 0 {
                        var inverseVolatilityScores: [String: Double] = [:]
                        for symbol in activeSymbols {
                            guard let prices = data.pricesBySymbol[symbol],
                                  prices.indices.contains(signalIndex),
                                  let volatility = annualizedVolatilityAt(
                                    values: prices,
                                    at: signalIndex,
                                    lookback: globalRiskParityLookback
                                  ) else { continue }
                            inverseVolatilityScores[symbol] = 1 / max(volatility, 0.05)
                        }
                        let denominator = inverseVolatilityScores.values.reduce(0, +)
                        if denominator > 0,
                           inverseVolatilityScores.count == activeSymbols.count {
                            let blend = min(max(globalRiskParityBlend, 0), 1)
                            for symbol in activeSymbols {
                                let currentWeight = pendingWeights[symbol] ?? 0
                                let parityWeight = activeGross
                                    * (inverseVolatilityScores[symbol] ?? 0)
                                    / denominator
                                pendingWeights[symbol] = (1 - blend) * currentWeight
                                    + blend * parityWeight
                            }
                        }
                    }
                }

                let usRiskAllocationMode = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_US_RISK_ALLOCATION_MODE"] ?? "0"
                ) ?? 0
                let usRiskAllocationBlend = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_US_RISK_ALLOCATION_BLEND"] ?? "0"
                ) ?? 0
                let usRiskAllocationLookback = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_US_RISK_ALLOCATION_LOOKBACK"] ?? "63"
                ) ?? 63
                let usRiskMomentumGapScale = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_US_RISK_MOMENTUM_GAP_SCALE"] ?? "0.20"
                ) ?? 0.20
                let currentNasdaqWeight = pendingWeights["nasdaq"] ?? 0
                let currentSP500Weight = pendingWeights["sp500"] ?? 0
                let currentUSTotal = currentNasdaqWeight + currentSP500Weight
                if usRiskAllocationMode > 0,
                   usRiskAllocationBlend > 0,
                   currentUSTotal >= 0.05,
                   signalIndex >= max(usRiskAllocationLookback, 126),
                   let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   let sp500Prices = data.pricesBySymbol["sp500"],
                   nasdaqPrices.indices.contains(signalIndex),
                   sp500Prices.indices.contains(signalIndex),
                   let nasdaqMA = movingAverageAt(values: nasdaqPrices, at: signalIndex, period: 100),
                   let sp500MA = movingAverageAt(values: sp500Prices, at: signalIndex, period: 100),
                   let nasdaqMomentum = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 126),
                   let sp500Momentum = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 126),
                   nasdaqPrices[signalIndex] >= nasdaqMA,
                   sp500Prices[signalIndex] >= sp500MA,
                   nasdaqMomentum > 0,
                   sp500Momentum > 0 {
                    var nasdaqReturns: [Double] = []
                    var sp500Returns: [Double] = []
                    for cursor in (signalIndex - usRiskAllocationLookback + 1)...signalIndex {
                        guard cursor > 0,
                              nasdaqPrices[cursor - 1] > 0,
                              sp500Prices[cursor - 1] > 0 else { continue }
                        nasdaqReturns.append(nasdaqPrices[cursor] / nasdaqPrices[cursor - 1] - 1)
                        sp500Returns.append(sp500Prices[cursor] / sp500Prices[cursor - 1] - 1)
                    }
                    if nasdaqReturns.count > 1,
                       nasdaqReturns.count == sp500Returns.count {
                        let count = Double(nasdaqReturns.count)
                        let meanN = nasdaqReturns.reduce(0, +) / count
                        let meanS = sp500Returns.reduce(0, +) / count
                        var varianceN = 0.0
                        var varianceS = 0.0
                        var covariance = 0.0
                        for index in nasdaqReturns.indices {
                            let dn = nasdaqReturns[index] - meanN
                            let ds = sp500Returns[index] - meanS
                            varianceN += dn * dn
                            varianceS += ds * ds
                            covariance += dn * ds
                        }
                        varianceN /= Double(nasdaqReturns.count - 1)
                        varianceS /= Double(sp500Returns.count - 1)
                        covariance /= Double(nasdaqReturns.count - 1)
                        let targetNasdaqShare: Double
                        var targetUSTotal = currentUSTotal
                        switch usRiskAllocationMode {
                        case 1:
                            let volatilityN = sqrt(max(varianceN, 0))
                            let volatilityS = sqrt(max(varianceS, 0))
                            let scoreN = 1 / max(volatilityN, 0.0001)
                            let scoreS = 1 / max(volatilityS, 0.0001)
                            targetNasdaqShare = scoreN / (scoreN + scoreS)
                        case 2:
                            let denominator = varianceN + varianceS - 2 * covariance
                            targetNasdaqShare = denominator > 0
                                ? min(max((varianceS - covariance) / denominator, 0.10), 0.90)
                                : 0.50
                        case 3:
                            targetNasdaqShare = 0.50
                        case 4:
                            let scale = max(usRiskMomentumGapScale, 0.01)
                            let relativeTilt = 0.5 * (nasdaqMomentum - sp500Momentum) / scale
                            targetNasdaqShare = min(max(0.50 + relativeTilt, 0.20), 0.80)
                        case 5:
                            let currentShare = currentNasdaqWeight / currentUSTotal
                            let gap = nasdaqMomentum - sp500Momentum
                            if gap > 0 {
                                let scale = max(usRiskMomentumGapScale, 0.01)
                                let momentumShare = min(max(0.50 + 0.5 * gap / scale, 0.50), 0.80)
                                targetNasdaqShare = max(currentShare, momentumShare)
                            } else {
                                targetNasdaqShare = currentShare
                            }
                        case 6, 7:
                            let volatilityN = sqrt(max(varianceN, 0)) * sqrt(252)
                            let volatilityS = sqrt(max(varianceS, 0)) * sqrt(252)
                            let scoreN = max(nasdaqMomentum, 0.01) / max(volatilityN, 0.05)
                            let scoreS = max(sp500Momentum, 0.01) / max(volatilityS, 0.05)
                            let denominator = scoreN + scoreS
                            let qualityShare = denominator > 0
                                ? min(max(scoreN / denominator, 0.20), 0.80)
                                : 0.50
                            if usRiskAllocationMode == 7 {
                                targetNasdaqShare = max(
                                    currentNasdaqWeight / currentUSTotal,
                                    qualityShare
                                )
                            } else {
                                targetNasdaqShare = qualityShare
                            }
                        case 8:
                            let currentShare = currentNasdaqWeight / currentUSTotal
                            let migration = min(max(usRiskAllocationBlend, 0), 1)
                            targetNasdaqShare = min(
                                currentShare + migration * (1 - currentShare),
                                0.85
                            )
                        case 9:
                            let volatilityN = sqrt(max(varianceN, 0))
                            let volatilityS = sqrt(max(varianceS, 0))
                            let riskEquivalentNasdaq = currentSP500Weight
                                * min(volatilityS / max(volatilityN, 0.0001), 1)
                            targetUSTotal = currentNasdaqWeight + riskEquivalentNasdaq
                            targetNasdaqShare = 1
                        default:
                            targetNasdaqShare = currentNasdaqWeight / currentUSTotal
                        }
                        let currentNasdaqShare = currentNasdaqWeight / currentUSTotal
                        let blend = min(max(usRiskAllocationBlend, 0), 1)
                        if usRiskAllocationMode == 9 {
                            pendingWeights["nasdaq"] = (1 - blend) * currentNasdaqWeight
                                + blend * targetUSTotal
                            pendingWeights["sp500"] = (1 - blend) * currentSP500Weight
                        } else {
                            let finalNasdaqShare = (1 - blend) * currentNasdaqShare
                                + blend * targetNasdaqShare
                            pendingWeights["nasdaq"] = currentUSTotal * finalNasdaqShare
                            pendingWeights["sp500"] = currentUSTotal * (1 - finalNasdaqShare)
                        }
                    }
                }

                let lowGrossSP500HandoffGrossMaximum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_LOW_GROSS_SP500_HANDOFF_GROSS_MAX"] ?? "0"
                ) ?? 0
                let lowGrossSP500HandoffMomentumGap = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_LOW_GROSS_SP500_HANDOFF_GAP"] ?? "0.02"
                ) ?? 0.02
                let lowGrossSP500HandoffFraction = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_LOW_GROSS_SP500_HANDOFF_FRACTION"] ?? "0.25"
                ) ?? 0.25
                let lowGrossSP500HandoffGross = pendingWeights.values.reduce(0, +)
                if lowGrossSP500HandoffGrossMaximum > 0,
                   lowGrossSP500HandoffGross >= 0.10,
                   lowGrossSP500HandoffGross <= lowGrossSP500HandoffGrossMaximum,
                   (pendingWeights["nasdaq"] ?? 0) >= 0.05,
                   signalIndex >= 126,
                   let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   let sp500Prices = data.pricesBySymbol["sp500"],
                   nasdaqPrices.indices.contains(signalIndex),
                   sp500Prices.indices.contains(signalIndex),
                   let nasdaqMomentum126 = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 126),
                   let sp500Momentum126 = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 126),
                   let sp500Momentum63 = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 63),
                   let sp500MA100 = movingAverageAt(values: sp500Prices, at: signalIndex, period: 100),
                   sp500Momentum126 - nasdaqMomentum126 >= lowGrossSP500HandoffMomentumGap,
                   sp500Momentum63 > 0,
                   sp500Prices[signalIndex] >= sp500MA100 {
                    let nasdaqWeight = pendingWeights["nasdaq"] ?? 0
                    let shift = nasdaqWeight * min(max(lowGrossSP500HandoffFraction, 0), 1)
                    pendingWeights["nasdaq"] = max(nasdaqWeight - shift, 0)
                    pendingWeights["sp500", default: 0] += shift
                }

                var usdCashStateChanged = false
                let usdCashCap = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_USD_CASH_CAP"] ?? "0"
                ) ?? 0
                let usdCashMAPeriod = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_USD_CASH_MA_PERIOD"] ?? "126"
                ) ?? 126
                let usdCashMomentumLookback = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_USD_CASH_MOMENTUM_LOOKBACK"] ?? "126"
                ) ?? 126
                let usdCashEntrySessions = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_USD_CASH_ENTRY_SESSIONS"] ?? "10"
                ) ?? 10
                let usdCashExitSessions = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_USD_CASH_EXIT_SESSIONS"] ?? "10"
                ) ?? 10
                if usdCashCap > 0,
                   signalIndex >= max(usdCashMAPeriod, usdCashMomentumLookback),
                   let usdCashPrices = data.pricesBySymbol["usd_cash"],
                   usdCashPrices.indices.contains(signalIndex),
                   let usdCashMA = movingAverageAt(
                    values: usdCashPrices,
                    at: signalIndex,
                    period: usdCashMAPeriod
                   ),
                   let usdCashMomentum = priceMomentum(
                    values: usdCashPrices,
                    at: signalIndex,
                    lookback: usdCashMomentumLookback
                   ) {
                    let riskOn = usdCashPrices[signalIndex] >= usdCashMA && usdCashMomentum > 0
                    let riskOff = usdCashPrices[signalIndex] < usdCashMA && usdCashMomentum < 0
                    usdCashRiskOnStreak = riskOn ? usdCashRiskOnStreak + 1 : 0
                    usdCashRiskOffStreak = riskOff ? usdCashRiskOffStreak + 1 : 0
                    let priorUsdCashActive = usdCashActive
                    if !usdCashActive,
                       usdCashRiskOnStreak >= max(usdCashEntrySessions, 1) {
                        usdCashActive = true
                        usdCashRiskOffStreak = 0
                    } else if usdCashActive,
                              usdCashRiskOffStreak >= max(usdCashExitSessions, 1) {
                        usdCashActive = false
                        usdCashRiskOnStreak = 0
                    }
                    usdCashStateChanged = priorUsdCashActive != usdCashActive
                    if usdCashActive {
                        let currentGross = pendingWeights.values.reduce(0, +)
                        let usdWeight = min(max(usdCashCap, 0), max(grossCap - currentGross, 0))
                        if usdWeight > 0 {
                            pendingWeights["usd_cash", default: 0] += usdWeight
                        }
                    }
                } else if usdCashCap <= 0 {
                    usdCashActive = false
                    usdCashRiskOnStreak = 0
                    usdCashRiskOffStreak = 0
                }

                var equityCurveStateChanged = false
                let equityCurveRiskScale = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_EQUITY_CURVE_RISK_SCALE"] ?? "1"
                ) ?? 1
                let equityCurveMAPeriod = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_EQUITY_CURVE_MA_PERIOD"] ?? "200"
                ) ?? 200
                let equityCurveMomentumLookback = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_EQUITY_CURVE_MOMENTUM_LOOKBACK"] ?? "63"
                ) ?? 63
                let equityCurveConfirmationSessions = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_EQUITY_CURVE_CONFIRMATION_SESSIONS"] ?? "5"
                ) ?? 5
                if equityCurveRiskScale < 1,
                   signalIndex >= max(equityCurveMAPeriod, equityCurveMomentumLookback),
                   let currentBaseValue = alignedBaseValues[signalIndex],
                   let priorBaseValue = alignedBaseValues[signalIndex - equityCurveMomentumLookback],
                   priorBaseValue > 0 {
                    let maStart = signalIndex - equityCurveMAPeriod + 1
                    let maValues = alignedBaseValues[maStart...signalIndex].compactMap { $0 }
                    if maValues.count >= max(equityCurveMAPeriod * 9 / 10, 2) {
                        let equityCurveMA = maValues.reduce(0, +) / Double(maValues.count)
                        let equityCurveMomentum = currentBaseValue / priorBaseValue - 1
                        let riskOffSignal = currentBaseValue < equityCurveMA && equityCurveMomentum < 0
                        let riskOnSignal = currentBaseValue >= equityCurveMA && equityCurveMomentum > 0
                        equityCurveRiskOffStreak = riskOffSignal ? equityCurveRiskOffStreak + 1 : 0
                        equityCurveRiskOnStreak = riskOnSignal ? equityCurveRiskOnStreak + 1 : 0
                        let priorRiskOffActive = equityCurveRiskOffActive
                        if !equityCurveRiskOffActive,
                           equityCurveRiskOffStreak >= max(equityCurveConfirmationSessions, 1) {
                            equityCurveRiskOffActive = true
                            equityCurveRiskOnStreak = 0
                        } else if equityCurveRiskOffActive,
                                  equityCurveRiskOnStreak >= max(equityCurveConfirmationSessions, 1) {
                            equityCurveRiskOffActive = false
                            equityCurveRiskOffStreak = 0
                        }
                        equityCurveStateChanged = priorRiskOffActive != equityCurveRiskOffActive
                        if equityCurveRiskOffActive {
                            let scale = min(max(equityCurveRiskScale, 0), 1)
                            pendingWeights = pendingWeights.mapValues { $0 * scale }
                        }
                    }
                } else if equityCurveRiskScale >= 1 {
                    equityCurveRiskOffActive = false
                    equityCurveRiskOffStreak = 0
                    equityCurveRiskOnStreak = 0
                }

                let goldToUSShiftFraction = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_GOLD_TO_US_SHIFT_FRACTION"] ?? "0"
                ) ?? 0
                let goldToUSShiftMode = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_GOLD_TO_US_SHIFT_MODE"] ?? "0"
                ) ?? 0
                if goldToUSShiftFraction > 0,
                   goldToUSShiftMode > 0,
                   signalIndex >= 200,
                   let goldPrices = data.pricesBySymbol["gold_cny"],
                   let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   let sp500Prices = data.pricesBySymbol["sp500"],
                   goldPrices.indices.contains(signalIndex),
                   nasdaqPrices.indices.contains(signalIndex),
                   sp500Prices.indices.contains(signalIndex),
                   let goldMA = movingAverageAt(values: goldPrices, at: signalIndex, period: 200),
                   let nasdaqMA = movingAverageAt(values: nasdaqPrices, at: signalIndex, period: 200),
                   let sp500MA = movingAverageAt(values: sp500Prices, at: signalIndex, period: 200),
                   let goldMomentum = priceMomentum(values: goldPrices, at: signalIndex, lookback: 126),
                   let nasdaqMomentum = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 126),
                   let sp500Momentum = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 126) {
                    let usRiskOn = nasdaqPrices[signalIndex] >= nasdaqMA
                        && sp500Prices[signalIndex] >= sp500MA
                        && nasdaqMomentum > 0
                        && sp500Momentum > 0
                    let goldWeak: Bool
                    switch goldToUSShiftMode {
                    case 1:
                        goldWeak = goldPrices[signalIndex] < goldMA && goldMomentum < 0
                    case 2:
                        goldWeak = goldPrices[signalIndex] < goldMA
                    case 3:
                        goldWeak = goldMomentum < min(nasdaqMomentum, sp500Momentum)
                    case 4:
                        goldWeak = goldMomentum + 0.05 < min(nasdaqMomentum, sp500Momentum)
                    default:
                        goldWeak = false
                    }
                    let goldWeight = pendingWeights["gold_cny"] ?? 0
                    if usRiskOn, goldWeak, goldWeight > 0 {
                        let shiftedWeight = min(max(goldToUSShiftFraction, 0), 1) * goldWeight
                        if shiftedWeight > 0,
                           let nasdaqVolatility = annualizedVolatilityAt(
                            values: nasdaqPrices,
                            at: signalIndex,
                            lookback: 63
                           ),
                           let sp500Volatility = annualizedVolatilityAt(
                            values: sp500Prices,
                            at: signalIndex,
                            lookback: 63
                           ) {
                            let nasdaqScore = 1 / max(nasdaqVolatility, 0.05)
                            let sp500Score = 1 / max(sp500Volatility, 0.05)
                            let denominator = nasdaqScore + sp500Score
                            pendingWeights["gold_cny"] = max(goldWeight - shiftedWeight, 0)
                            pendingWeights["nasdaq", default: 0] += denominator > 0
                                ? shiftedWeight * nasdaqScore / denominator
                                : shiftedWeight * 0.5
                            pendingWeights["sp500", default: 0] += denominator > 0
                                ? shiftedWeight * sp500Score / denominator
                                : shiftedWeight * 0.5
                        }
                    }
                }

                var secularCarryStateChanged = false
                let secularCarryCap = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_SECULAR_CARRY_CAP"] ?? "0"
                ) ?? 0
                let secularCarryEntrySessions = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_SECULAR_CARRY_ENTRY_SESSIONS"] ?? "40"
                ) ?? 40
                let secularCarryExitSessions = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_SECULAR_CARRY_EXIT_SESSIONS"] ?? "10"
                ) ?? 10
                if secularCarryCap > 0,
                   signalIndex >= 200,
                   let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   let sp500Prices = data.pricesBySymbol["sp500"],
                   nasdaqPrices.indices.contains(signalIndex),
                   sp500Prices.indices.contains(signalIndex),
                   let nasdaqMA = movingAverageAt(values: nasdaqPrices, at: signalIndex, period: 200),
                   let sp500MA = movingAverageAt(values: sp500Prices, at: signalIndex, period: 200),
                   let nasdaqMomentum126 = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 126),
                   let sp500Momentum126 = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 126),
                   let nasdaqMomentum63 = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 63),
                   let sp500Momentum63 = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 63) {
                    let riskOn = nasdaqPrices[signalIndex] >= nasdaqMA
                        && sp500Prices[signalIndex] >= sp500MA
                        && nasdaqMomentum126 > 0
                        && sp500Momentum126 > 0
                    let riskOff = (nasdaqPrices[signalIndex] < nasdaqMA
                            && sp500Prices[signalIndex] < sp500MA)
                        || (nasdaqMomentum63 < 0 && sp500Momentum63 < 0)
                    secularCarryRiskOnStreak = riskOn ? secularCarryRiskOnStreak + 1 : 0
                    secularCarryRiskOffStreak = riskOff ? secularCarryRiskOffStreak + 1 : 0
                    let priorSecularCarryActive = secularCarryActive
                    if !secularCarryActive,
                       secularCarryRiskOnStreak >= max(secularCarryEntrySessions, 1) {
                        secularCarryActive = true
                        secularCarryRiskOffStreak = 0
                    } else if secularCarryActive,
                              secularCarryRiskOffStreak >= max(secularCarryExitSessions, 1) {
                        secularCarryActive = false
                        secularCarryRiskOnStreak = 0
                    }
                    secularCarryStateChanged = priorSecularCarryActive != secularCarryActive
                    if secularCarryActive {
                        let currentGross = pendingWeights.values.reduce(0, +)
                        let sleeveWeight = min(max(secularCarryCap, 0), max(grossCap - currentGross, 0))
                        if sleeveWeight > 0,
                           let nasdaqVolatility = annualizedVolatilityAt(
                            values: nasdaqPrices,
                            at: signalIndex,
                            lookback: 63
                           ),
                           let sp500Volatility = annualizedVolatilityAt(
                            values: sp500Prices,
                            at: signalIndex,
                            lookback: 63
                           ) {
                            let nasdaqScore = 1 / max(nasdaqVolatility, 0.05)
                            let sp500Score = 1 / max(sp500Volatility, 0.05)
                            let denominator = nasdaqScore + sp500Score
                            pendingWeights["nasdaq", default: 0] += denominator > 0
                                ? sleeveWeight * nasdaqScore / denominator
                                : sleeveWeight * 0.5
                            pendingWeights["sp500", default: 0] += denominator > 0
                                ? sleeveWeight * sp500Score / denominator
                                : sleeveWeight * 0.5
                        }
                    }
                } else if secularCarryCap <= 0 {
                    secularCarryActive = false
                    secularCarryRiskOnStreak = 0
                    secularCarryRiskOffStreak = 0
                }

                let calmCarryCap = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_CALM_CARRY_CAP"] ?? "0"
                ) ?? 0
                let calmCarryMAPeriod = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_CALM_CARRY_MA_PERIOD"] ?? "200"
                ) ?? 200
                let calmCarryMomentumLookback = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_CALM_CARRY_MOMENTUM_LOOKBACK"] ?? "126"
                ) ?? 126
                let calmCarryVolatilityThreshold = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_CALM_CARRY_VOL_THRESHOLD"] ?? "0.18"
                ) ?? 0.18
                let calmCarryBaseDrawdownMaximum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_CALM_CARRY_BASE_DD_MAX"] ?? "0.03"
                ) ?? 0.03
                if calmCarryCap > 0,
                   signalIndex >= max(calmCarryMAPeriod, calmCarryMomentumLookback, 63),
                   let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   let sp500Prices = data.pricesBySymbol["sp500"],
                   nasdaqPrices.indices.contains(signalIndex),
                   sp500Prices.indices.contains(signalIndex),
                   let nasdaqMA = movingAverageAt(
                    values: nasdaqPrices,
                    at: signalIndex,
                    period: calmCarryMAPeriod
                   ),
                   let sp500MA = movingAverageAt(
                    values: sp500Prices,
                    at: signalIndex,
                    period: calmCarryMAPeriod
                   ),
                   let nasdaqMomentum = priceMomentum(
                    values: nasdaqPrices,
                    at: signalIndex,
                    lookback: calmCarryMomentumLookback
                   ),
                   let sp500Momentum = priceMomentum(
                    values: sp500Prices,
                    at: signalIndex,
                    lookback: calmCarryMomentumLookback
                   ),
                   let nasdaqVolatility = annualizedVolatilityAt(
                    values: nasdaqPrices,
                    at: signalIndex,
                    lookback: 63
                   ),
                   let sp500Volatility = annualizedVolatilityAt(
                    values: sp500Prices,
                    at: signalIndex,
                    lookback: 63
                   ) {
                    let baseValue = alignedBaseValues[signalIndex] ?? 0
                    let peakStart = max(0, signalIndex - 251)
                    let basePeak = alignedBaseValues[peakStart...signalIndex]
                        .compactMap { $0 }
                        .max() ?? baseValue
                    let baseDrawdown = basePeak > 0 ? max(1 - baseValue / basePeak, 0) : 0
                    let calmRiskOn = nasdaqPrices[signalIndex] >= nasdaqMA
                        && sp500Prices[signalIndex] >= sp500MA
                        && nasdaqMomentum > 0
                        && sp500Momentum > 0
                        && max(nasdaqVolatility, sp500Volatility) <= calmCarryVolatilityThreshold
                        && baseDrawdown <= calmCarryBaseDrawdownMaximum
                    if calmRiskOn {
                        let currentGross = pendingWeights.values.reduce(0, +)
                        let carryWeight = min(max(calmCarryCap, 0), max(grossCap - currentGross, 0))
                        if carryWeight > 0 {
                            pendingWeights["nasdaq", default: 0] += carryWeight * 0.5
                            pendingWeights["sp500", default: 0] += carryWeight * 0.5
                        }
                    }
                }
                var gross = pendingWeights.values.reduce(0, +)
                if gross > grossCap, gross > 0 {
                    pendingWeights = pendingWeights.mapValues { $0 * grossCap / gross }
                    gross = grossCap
                }
                let calmRiskVolatilityFloor = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_CALM_RISK_VOL_FLOOR"] ?? "0"
                ) ?? 0
                let calmRiskMaximumScale = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_CALM_RISK_MAX_SCALE"] ?? "1"
                ) ?? 1
                let calmRiskLeaderGate = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_CALM_RISK_LEADER_GATE"] ?? "0"
                ) ?? 0
                let calmRiskLeader = leaderName(pendingWeights)
                let calmRiskLeaderAllowed = calmRiskLeaderGate == 0
                    || (calmRiskLeaderGate == 1 && ["nasdaq", "sp500"].contains(calmRiskLeader))
                    || (calmRiskLeaderGate == 2 && calmRiskLeader != "gold")
                    || (calmRiskLeaderGate == 3 && calmRiskLeader == "china")
                let calmRiskLeaderMomentumGate = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_CALM_RISK_LEADER_MOMENTUM_GATE"] ?? "0"
                ) ?? 0
                let calmRiskMomentumSymbol: String = {
                    if calmRiskLeader == "china" {
                        return (pendingWeights["csi300"] ?? 0) >= (pendingWeights["shanghai_composite"] ?? 0)
                            ? "csi300"
                            : "shanghai_composite"
                    }
                    return calmRiskLeader
                }()
                var calmRiskLeaderMomentumAllowed = true
                if calmRiskLeaderMomentumGate > 0,
                   let leaderPrices = data.pricesBySymbol[calmRiskMomentumSymbol],
                   leaderPrices.indices.contains(signalIndex) {
                    let momentum20 = priceMomentum(values: leaderPrices, at: signalIndex, lookback: 20) ?? -1
                    let momentum63 = priceMomentum(values: leaderPrices, at: signalIndex, lookback: 63) ?? -1
                    calmRiskLeaderMomentumAllowed = momentum20 > 0
                        && (calmRiskLeaderMomentumGate == 1 || momentum63 > 0)
                }
                if calmRiskVolatilityFloor > 0,
                   calmRiskLeaderAllowed,
                   calmRiskLeaderMomentumAllowed,
                   gross >= 0.20,
                   gross < grossCap,
                   signalIndex >= 200,
                   let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   let sp500Prices = data.pricesBySymbol["sp500"],
                   nasdaqPrices.indices.contains(signalIndex),
                   sp500Prices.indices.contains(signalIndex),
                   let nasdaqMA = movingAverageAt(values: nasdaqPrices, at: signalIndex, period: 200),
                   let sp500MA = movingAverageAt(values: sp500Prices, at: signalIndex, period: 200),
                   let nasdaqMomentum = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 126),
                   let sp500Momentum = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 126),
                   nasdaqPrices[signalIndex] >= nasdaqMA,
                   sp500Prices[signalIndex] >= sp500MA,
                   nasdaqMomentum > 0,
                   sp500Momentum > 0 {
                    let baseValue = alignedBaseValues[signalIndex] ?? 0
                    let peakStart = max(0, signalIndex - 251)
                    let basePeak = alignedBaseValues[peakStart...signalIndex]
                        .compactMap { $0 }
                        .max() ?? baseValue
                    let baseDrawdown = basePeak > 0 ? max(1 - baseValue / basePeak, 0) : 0
                    if baseDrawdown <= 0.03 {
                        var riskReturns: [Double] = []
                        for cursor in (signalIndex - 62)...signalIndex {
                            var dailyReturn = 0.0
                            var valid = true
                            for (symbol, weight) in pendingWeights where weight > 0 {
                                guard let prices = data.pricesBySymbol[symbol],
                                      prices.indices.contains(cursor),
                                      cursor > 0,
                                      prices[cursor - 1] > 0 else {
                                    valid = false
                                    break
                                }
                                dailyReturn += weight * (prices[cursor] / prices[cursor - 1] - 1)
                            }
                            if valid { riskReturns.append(dailyReturn) }
                        }
                        if riskReturns.count > 1 {
                            let mean = riskReturns.reduce(0, +) / Double(riskReturns.count)
                            let variance = riskReturns.reduce(0.0) {
                                $0 + pow($1 - mean, 2)
                            } / Double(riskReturns.count - 1)
                            let forecastVolatility = sqrt(max(variance, 0)) * sqrt(252)
                            let calmRiskShortLongVolatilityRatioMaximum = Double(
                                ProcessInfo.processInfo.environment["ATM_CC_CALM_RISK_SHORT_LONG_VOL_RATIO_MAX"] ?? "99"
                            ) ?? 99
                            var shortVolatility = forecastVolatility
                            if riskReturns.count >= 20 {
                                let shortReturns = Array(riskReturns.suffix(20))
                                let shortMean = shortReturns.reduce(0, +) / Double(shortReturns.count)
                                let shortVariance = shortReturns.reduce(0.0) {
                                    $0 + pow($1 - shortMean, 2)
                                } / Double(shortReturns.count - 1)
                                shortVolatility = sqrt(max(shortVariance, 0)) * sqrt(252)
                            }
                            let volatilityAccelerationAllowed = calmRiskShortLongVolatilityRatioMaximum >= 99
                                || shortVolatility <= forecastVolatility * max(calmRiskShortLongVolatilityRatioMaximum, 0)
                            if forecastVolatility > 0,
                               forecastVolatility < calmRiskVolatilityFloor,
                               volatilityAccelerationAllowed {
                                let scale = min(
                                    calmRiskVolatilityFloor / forecastVolatility,
                                    grossCap / gross,
                                    max(calmRiskMaximumScale, 1)
                                )
                                let targetGross = gross * scale
                                let extraGross = max(targetGross - gross, 0)
                                let calmRiskAllocationMode = Int(
                                    ProcessInfo.processInfo.environment["ATM_CC_CALM_RISK_ALLOCATION_MODE"] ?? "0"
                                ) ?? 0
                                if calmRiskAllocationMode == 1, extraGross > 0 {
                                    switch calmRiskLeader {
                                    case "nasdaq":
                                        pendingWeights["nasdaq", default: 0] += extraGross
                                    case "sp500":
                                        pendingWeights["sp500", default: 0] += extraGross
                                    case "china":
                                        let chinaSymbols = ["csi300", "shanghai_composite"]
                                        let chinaGross = chinaSymbols.reduce(0.0) { $0 + (pendingWeights[$1] ?? 0) }
                                        if chinaGross > 0 {
                                            for symbol in chinaSymbols where (pendingWeights[symbol] ?? 0) > 0 {
                                                pendingWeights[symbol, default: 0] += extraGross * (pendingWeights[symbol] ?? 0) / chinaGross
                                            }
                                        }
                                    default:
                                        pendingWeights = pendingWeights.mapValues { $0 * scale }
                                    }
                                } else if calmRiskAllocationMode == 2, extraGross > 0 {
                                    if ["nasdaq", "sp500"].contains(calmRiskLeader) {
                                        let usSymbols = ["nasdaq", "sp500"]
                                        let usGross = usSymbols.reduce(0.0) { $0 + (pendingWeights[$1] ?? 0) }
                                        if usGross > 0 {
                                            for symbol in usSymbols where (pendingWeights[symbol] ?? 0) > 0 {
                                                pendingWeights[symbol, default: 0] += extraGross * (pendingWeights[symbol] ?? 0) / usGross
                                            }
                                        }
                                    } else if calmRiskLeader == "china" {
                                        let chinaSymbols = ["csi300", "shanghai_composite"]
                                        let chinaGross = chinaSymbols.reduce(0.0) { $0 + (pendingWeights[$1] ?? 0) }
                                        if chinaGross > 0 {
                                            for symbol in chinaSymbols where (pendingWeights[symbol] ?? 0) > 0 {
                                                pendingWeights[symbol, default: 0] += extraGross * (pendingWeights[symbol] ?? 0) / chinaGross
                                            }
                                        }
                                    } else {
                                        pendingWeights = pendingWeights.mapValues { $0 * scale }
                                    }
                                } else if calmRiskAllocationMode == 3, extraGross > 0,
                                          ["nasdaq", "sp500"].contains(calmRiskLeader) {
                                    pendingWeights[calmRiskLeader, default: 0] += extraGross
                                } else if calmRiskAllocationMode == 4, extraGross > 0,
                                          calmRiskLeader == "nasdaq" {
                                    pendingWeights["nasdaq", default: 0] += extraGross
                                } else {
                                    pendingWeights = pendingWeights.mapValues { $0 * scale }
                                }
                                gross = pendingWeights.values.reduce(0, +)
                            }
                        }
                    }
                }
                let confirmedUSGrossFloor = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_CONFIRMED_US_GROSS_FLOOR"] ?? "0"
                ) ?? 0
                if confirmedUSGrossFloor > 0,
                   gross >= 0.20,
                   gross < min(confirmedUSGrossFloor, grossCap),
                   ["nasdaq", "sp500"].contains(leaderName(pendingWeights)),
                   signalIndex >= 200,
                   let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   let sp500Prices = data.pricesBySymbol["sp500"],
                   nasdaqPrices.indices.contains(signalIndex),
                   sp500Prices.indices.contains(signalIndex),
                   let nasdaqMA = movingAverageAt(values: nasdaqPrices, at: signalIndex, period: 200),
                   let sp500MA = movingAverageAt(values: sp500Prices, at: signalIndex, period: 200),
                   let nasdaqM20 = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 20),
                   let sp500M20 = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 20),
                   let nasdaqM63 = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 63),
                   let sp500M63 = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 63),
                   let nasdaqM126 = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 126),
                   let sp500M126 = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 126),
                   nasdaqPrices[signalIndex] >= nasdaqMA,
                   sp500Prices[signalIndex] >= sp500MA,
                   nasdaqM20 > 0,
                   sp500M20 > 0,
                   nasdaqM63 > 0,
                   sp500M63 > 0,
                   nasdaqM126 > 0,
                   sp500M126 > 0 {
                    let targetGross = min(confirmedUSGrossFloor, grossCap)
                    let scale = gross > 0 ? targetGross / gross : 1
                    pendingWeights = pendingWeights.mapValues { $0 * scale }
                    gross = targetGross
                }
                let strictIdleUSGrossFloor = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_STRICT_IDLE_US_GROSS_FLOOR"] ?? "0"
                ) ?? 0
                if strictIdleUSGrossFloor > 0,
                   gross < 0.20,
                   signalIndex >= 200,
                   let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   let sp500Prices = data.pricesBySymbol["sp500"],
                   nasdaqPrices.indices.contains(signalIndex),
                   sp500Prices.indices.contains(signalIndex),
                   let nasdaqMA200 = movingAverageAt(values: nasdaqPrices, at: signalIndex, period: 200),
                   let sp500MA200 = movingAverageAt(values: sp500Prices, at: signalIndex, period: 200),
                   let nasdaqM63 = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 63),
                   let sp500M63 = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 63),
                   let nasdaqM126 = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 126),
                   let sp500M126 = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 126),
                   let nasdaqVol20 = annualizedVolatilityAt(values: nasdaqPrices, at: signalIndex, lookback: 20),
                   let nasdaqVol63 = annualizedVolatilityAt(values: nasdaqPrices, at: signalIndex, lookback: 63),
                   let sp500Vol20 = annualizedVolatilityAt(values: sp500Prices, at: signalIndex, lookback: 20),
                   let sp500Vol63 = annualizedVolatilityAt(values: sp500Prices, at: signalIndex, lookback: 63),
                   nasdaqPrices[signalIndex] >= nasdaqMA200,
                   sp500Prices[signalIndex] >= sp500MA200,
                   nasdaqM63 > 0,
                   sp500M63 > 0,
                   nasdaqM126 > 0,
                   sp500M126 > 0,
                   nasdaqVol20 <= nasdaqVol63,
                   sp500Vol20 <= sp500Vol63 {
                    let currentBaseValue = alignedBaseValues[signalIndex] ?? 0
                    let peakStart = max(0, signalIndex - 251)
                    let peakValue = alignedBaseValues[peakStart...signalIndex]
                        .compactMap { $0 }
                        .max() ?? currentBaseValue
                    let baseDrawdown = peakValue > 0 ? max(1 - currentBaseValue / peakValue, 0) : 0
                    if baseDrawdown <= 0.03 {
                        let targetGross = min(max(strictIdleUSGrossFloor, gross), grossCap)
                        let extraGross = max(targetGross - gross, 0)
                        if extraGross > 0 {
                            pendingWeights["nasdaq", default: 0] += extraGross * 0.70
                            pendingWeights["sp500", default: 0] += extraGross * 0.30
                            gross = pendingWeights.values.reduce(0, +)
                        }
                    }
                }
                let portfolioVolatilityTarget = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_PORTFOLIO_VOL_TARGET"] ?? "99"
                ) ?? 99
                let portfolioVolatilityLookback = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_PORTFOLIO_VOL_LOOKBACK"] ?? "63"
                ) ?? 63
                let portfolioVolatilityMinimumScale = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_PORTFOLIO_VOL_MIN_SCALE"] ?? "0"
                ) ?? 0
                if portfolioVolatilityTarget < 99,
                   gross > 0,
                   portfolioVolatilityLookback > 1,
                   signalIndex >= portfolioVolatilityLookback {
                    var portfolioReturns: [Double] = []
                    portfolioReturns.reserveCapacity(portfolioVolatilityLookback)
                    for cursor in (signalIndex - portfolioVolatilityLookback + 1)...signalIndex {
                        var dailyReturn = 0.0
                        var valid = true
                        for (symbol, weight) in pendingWeights where weight > 0 {
                            guard let prices = data.pricesBySymbol[symbol],
                                  prices.indices.contains(cursor),
                                  cursor > 0,
                                  prices[cursor - 1] > 0 else {
                                valid = false
                                break
                            }
                            dailyReturn += weight * (prices[cursor] / prices[cursor - 1] - 1)
                        }
                        if valid {
                            portfolioReturns.append(dailyReturn)
                        }
                    }
                    if portfolioReturns.count > 1 {
                        let mean = portfolioReturns.reduce(0, +) / Double(portfolioReturns.count)
                        let variance = portfolioReturns.reduce(0.0) {
                            $0 + pow($1 - mean, 2)
                        } / Double(portfolioReturns.count - 1)
                        let forecastVolatility = sqrt(max(variance, 0)) * sqrt(252)
                        if forecastVolatility > portfolioVolatilityTarget {
                            let scale = max(
                                min(portfolioVolatilityTarget / forecastVolatility, 1),
                                min(max(portfolioVolatilityMinimumScale, 0), 1)
                            )
                            pendingWeights = pendingWeights.mapValues { $0 * scale }
                            gross *= scale
                        }
                    }
                }
                let slowAddFraction = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_SLOW_ADD_FRACTION"] ?? "1"
                ) ?? 1
                if slowAddFraction < 1, !previousWeights.isEmpty {
                    let fraction = min(max(slowAddFraction, 0), 1)
                    let adjustmentSymbols = Set(previousWeights.keys).union(pendingWeights.keys)
                    pendingWeights = Dictionary(uniqueKeysWithValues: adjustmentSymbols.map { symbol in
                        let prior = previousWeights[symbol] ?? 0
                        let target = pendingWeights[symbol] ?? 0
                        let adjusted = target > prior
                            ? prior + fraction * (target - prior)
                            : target
                        return (symbol, adjusted)
                    })
                    gross = pendingWeights.values.reduce(0, +)
                }
                let activeReturnLeader = leaderName(pendingWeights)
                var activeReturnScale: Double
                switch activeReturnLeader {
                case "gold":
                    activeReturnScale = returnGoldScale
                case "nasdaq":
                    activeReturnScale = returnNasdaqScale
                case "sp500":
                    activeReturnScale = returnSP500Scale
                case "china":
                    activeReturnScale = returnChinaScale
                    if returnChinaStrongScale > returnChinaScale,
                       signalIndex >= 200,
                       let csiPrices = data.pricesBySymbol["csi300"],
                       let shanghaiPrices = data.pricesBySymbol["shanghai_composite"],
                       csiPrices.indices.contains(signalIndex),
                       shanghaiPrices.indices.contains(signalIndex),
                       let csiMA = movingAverageAt(values: csiPrices, at: signalIndex, period: 200),
                       let shanghaiMA = movingAverageAt(values: shanghaiPrices, at: signalIndex, period: 200),
                       let csiM63 = priceMomentum(values: csiPrices, at: signalIndex, lookback: 63),
                       let shanghaiM63 = priceMomentum(values: shanghaiPrices, at: signalIndex, lookback: 63),
                       let csiM126 = priceMomentum(values: csiPrices, at: signalIndex, lookback: 126),
                       let shanghaiM126 = priceMomentum(values: shanghaiPrices, at: signalIndex, lookback: 126),
                       csiPrices[signalIndex] >= csiMA,
                       shanghaiPrices[signalIndex] >= shanghaiMA,
                       csiM63 > 0,
                       shanghaiM63 > 0,
                       csiM126 > 0,
                       shanghaiM126 > 0 {
                        activeReturnScale = returnChinaStrongScale
                    }
                default:
                    activeReturnScale = returnScale
                }
                let trendEfficiencyReturnScale = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_TREND_EFFICIENCY_RETURN_SCALE"] ?? "0"
                ) ?? 0
                let trendEfficiencyThreshold = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_TREND_EFFICIENCY_THRESHOLD"] ?? "0.15"
                ) ?? 0.15
                let trendEfficiencyGrossMaximum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_TREND_EFFICIENCY_GROSS_MAX"] ?? "0.65"
                ) ?? 0.65
                if trendEfficiencyReturnScale > activeReturnScale,
                   gross <= trendEfficiencyGrossMaximum,
                   ["nasdaq", "sp500"].contains(activeReturnLeader),
                   let leaderPrices = data.pricesBySymbol[activeReturnLeader],
                   leaderPrices.indices.contains(signalIndex),
                   signalIndex >= 63,
                   let leaderMomentum63 = priceMomentum(values: leaderPrices, at: signalIndex, lookback: 63),
                   let leaderVol20 = annualizedVolatilityAt(values: leaderPrices, at: signalIndex, lookback: 20),
                   let leaderVol63 = annualizedVolatilityAt(values: leaderPrices, at: signalIndex, lookback: 63),
                   leaderMomentum63 > 0,
                   leaderVol20 <= leaderVol63 {
                    var pathLength = 0.0
                    for cursor in (signalIndex - 62)...signalIndex {
                        guard cursor > 0, leaderPrices[cursor - 1] > 0 else { continue }
                        pathLength += abs(leaderPrices[cursor] / leaderPrices[cursor - 1] - 1)
                    }
                    let trendEfficiency = pathLength > 0 ? max(leaderMomentum63, 0) / pathLength : 0
                    if trendEfficiency >= trendEfficiencyThreshold {
                        activeReturnScale = trendEfficiencyReturnScale
                    }
                }
                let decliningVolReturnScale = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_DECLINING_VOL_RETURN_SCALE"] ?? "0"
                ) ?? 0
                let decliningVolReturnLeaderGate = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_DECLINING_VOL_RETURN_LEADER_GATE"] ?? "0"
                ) ?? 0
                let decliningVolReturnLeaderAllowed = decliningVolReturnLeaderGate == 0
                    || (decliningVolReturnLeaderGate == 1 && activeReturnLeader == "nasdaq")
                    || (decliningVolReturnLeaderGate == 2 && activeReturnLeader == "sp500")
                if decliningVolReturnScale > activeReturnScale,
                   decliningVolReturnLeaderAllowed,
                   ["nasdaq", "sp500"].contains(activeReturnLeader),
                   let leaderPrices = data.pricesBySymbol[activeReturnLeader],
                   leaderPrices.indices.contains(signalIndex),
                   signalIndex >= 63,
                   let leaderMomentum63 = priceMomentum(values: leaderPrices, at: signalIndex, lookback: 63),
                   let leaderVol20 = annualizedVolatilityAt(values: leaderPrices, at: signalIndex, lookback: 20),
                   let leaderVol63 = annualizedVolatilityAt(values: leaderPrices, at: signalIndex, lookback: 63),
                   leaderMomentum63 > 0,
                   leaderVol20 <= leaderVol63 {
                    activeReturnScale = decliningVolReturnScale
                }
                if returnDeRiskDrawdownThreshold < 99,
                   signalIndex >= 0,
                   alignedBaseValues.indices.contains(signalIndex),
                   let currentBaseValue = alignedBaseValues[signalIndex],
                   currentBaseValue > 0 {
                    let peakStart = max(0, signalIndex - 251)
                    let peakValue = alignedBaseValues[peakStart...signalIndex]
                        .compactMap { $0 }
                        .max() ?? currentBaseValue
                    let baseDrawdown = peakValue > 0
                        ? max(1 - currentBaseValue / peakValue, 0)
                        : 0
                    if baseDrawdown >= returnDeRiskDrawdownThreshold {
                        activeReturnScale = min(returnScale, max(returnDeRiskScale, 0))
                    }
                }
                if abs(activeReturnScale - 1) > 0.000001 {
                    pendingWeights = pendingWeights.mapValues { max($0 * activeReturnScale, 0) }
                    gross = pendingWeights.values.reduce(0, +)
                    if gross > grossCap, gross > 0 {
                        pendingWeights = pendingWeights.mapValues { $0 * grossCap / gross }
                        gross = grossCap
                    }
                }
                let strongGoldCarryCap = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_STRONG_GOLD_CARRY_CAP"] ?? "0"
                ) ?? 0
                if strongGoldCarryCap > 0,
                   gross >= 0.20,
                   gross < grossCap,
                   leaderName(pendingWeights) == "gold",
                   signalIndex >= 252,
                   let goldPrices = data.pricesBySymbol["gold_cny"],
                   goldPrices.indices.contains(signalIndex),
                   let goldMA200 = movingAverageAt(values: goldPrices, at: signalIndex, period: 200),
                   let goldM63 = priceMomentum(values: goldPrices, at: signalIndex, lookback: 63),
                   let goldM126 = priceMomentum(values: goldPrices, at: signalIndex, lookback: 126),
                   let goldM252 = priceMomentum(values: goldPrices, at: signalIndex, lookback: 252),
                   let goldVol20 = annualizedVolatilityAt(values: goldPrices, at: signalIndex, lookback: 20),
                   let goldVol63 = annualizedVolatilityAt(values: goldPrices, at: signalIndex, lookback: 63),
                   goldPrices[signalIndex] >= goldMA200,
                   goldM63 > 0,
                   goldM126 > 0,
                   goldM252 > 0,
                   goldVol20 <= goldVol63 {
                    let carry = min(max(strongGoldCarryCap, 0), max(grossCap - gross, 0))
                    if carry > 0 {
                        pendingWeights["gold_cny", default: 0] += carry
                        gross += carry
                    }
                }
                let lowVolEntryScale = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_LOW_VOL_ENTRY_SCALE"] ?? "1"
                ) ?? 1
                let lowVolEntryVolatilityMaximum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_LOW_VOL_ENTRY_VOL_MAX"] ?? "0.04"
                ) ?? 0.04
                let lowVolEntryDrawdownMaximum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_LOW_VOL_ENTRY_DD_MAX"] ?? "0.02"
                ) ?? 0.02
                let priorGrossBeforeEntryBoost = previousWeights.values.reduce(0, +)
                if lowVolEntryScale > 1,
                   priorGrossBeforeEntryBoost < 0.05,
                   gross >= 0.20,
                   gross < grossCap,
                   signalIndex >= 60,
                   alignedBaseValues.indices.contains(signalIndex),
                   let currentBaseValue = alignedBaseValues[signalIndex],
                   currentBaseValue > 0 {
                    let peakStart = max(0, signalIndex - 251)
                    let peakValue = alignedBaseValues[peakStart...signalIndex]
                        .compactMap { $0 }
                        .max() ?? currentBaseValue
                    let baseDrawdown = peakValue > 0 ? max(1 - currentBaseValue / peakValue, 0) : 0
                    if baseDrawdown <= lowVolEntryDrawdownMaximum {
                        var targetReturns: [Double] = []
                        for cursor in (signalIndex - 59)...signalIndex {
                            guard cursor > 0 else { continue }
                            var dailyReturn = 0.0
                            var valid = true
                            for (symbol, weight) in pendingWeights where weight > 0 {
                                guard let prices = data.pricesBySymbol[symbol],
                                      prices.indices.contains(cursor),
                                      prices[cursor - 1] > 0 else {
                                    valid = false
                                    break
                                }
                                dailyReturn += weight * (prices[cursor] / prices[cursor - 1] - 1)
                            }
                            if valid { targetReturns.append(dailyReturn) }
                        }
                        if targetReturns.count > 1 {
                            let mean = targetReturns.reduce(0, +) / Double(targetReturns.count)
                            let variance = targetReturns.reduce(0.0) {
                                $0 + pow($1 - mean, 2)
                            } / Double(targetReturns.count - 1)
                            let targetVolatility = sqrt(max(variance, 0)) * sqrt(252)
                            if targetVolatility < lowVolEntryVolatilityMaximum {
                                let scale = min(max(lowVolEntryScale, 1), grossCap / gross)
                                pendingWeights = pendingWeights.mapValues { $0 * scale }
                                gross *= scale
                            }
                        }
                    }
                }
                let reRiskIncrementMultiplier = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_RERISK_INCREMENT_MULTIPLIER"] ?? "1"
                ) ?? 1
                let priorGrossBeforeReRiskBoost = previousWeights.values.reduce(0, +)
                if reRiskIncrementMultiplier > 1,
                   priorGrossBeforeReRiskBoost >= 0.05,
                   gross > priorGrossBeforeReRiskBoost + 0.02,
                   gross < grossCap {
                    let boostedGross = min(
                        priorGrossBeforeReRiskBoost
                            + reRiskIncrementMultiplier * (gross - priorGrossBeforeReRiskBoost),
                        grossCap
                    )
                    if boostedGross > gross {
                        let scale = boostedGross / gross
                        pendingWeights = pendingWeights.mapValues { $0 * scale }
                        gross = boostedGross
                    }
                }
                let symbols = Set(previousWeights.keys).union(pendingWeights.keys)''',
    )

    text = replace_once(
        text,
        '''                let shouldRebalance = previousWeights.isEmpty
                    ? !pendingWeights.isEmpty
                    : baseTargetChanged || difference > tradeBand''',
        '''                let costAwareRebalance = ProcessInfo.processInfo.environment["ATM_CC_COST_AWARE_REBALANCE"] == "1"
                let costAwareBand = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_COST_AWARE_BAND"] ?? String(tradeBand)
                ) ?? tradeBand
                let rebalanceTriggerMode = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_REBALANCE_TRIGGER_MODE"] ?? "0"
                ) ?? 0
                let rebalanceTriggerBand = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_REBALANCE_TRIGGER_BAND"] ?? String(tradeBand)
                ) ?? tradeBand
                let smallReRiskTurnoverFloor = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_SMALL_RERISK_TURNOVER_FLOOR"] ?? "0"
                ) ?? 0
                let smallReRiskSameLeaderOnly = ProcessInfo.processInfo.environment["ATM_CC_SMALL_RERISK_SAME_LEADER_ONLY"] == "1"
                let goldDeRiskTurnoverFloor = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_GOLD_DERISK_TURNOVER_FLOOR"] ?? "0"
                ) ?? 0
                let priorGrossForTrade = previousWeights.values.reduce(0, +)
                let targetGrossForTrade = pendingWeights.values.reduce(0, +)
                let immediateRiskReduction = targetGrossForTrade < priorGrossForTrade - 0.02
                    || targetGrossForTrade < 0.05
                let priorLeaderForTrade = leaderName(previousWeights)
                let targetLeaderForTrade = leaderName(pendingWeights)
                let sameLeaderForTrade = priorLeaderForTrade == targetLeaderForTrade
                let earlyReRiskBand = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_EARLY_RERISK_BAND"] ?? "0"
                ) ?? 0
                let earlyReRiskSymbol: String = {
                    if targetLeaderForTrade == "china" {
                        return (pendingWeights["csi300"] ?? 0) >= (pendingWeights["shanghai_composite"] ?? 0)
                            ? "csi300"
                            : "shanghai_composite"
                    }
                    return targetLeaderForTrade
                }()
                var earlyReRiskVolatilityDeclining = false
                if earlyReRiskBand > 0,
                   let leaderPrices = data.pricesBySymbol[earlyReRiskSymbol],
                   leaderPrices.indices.contains(signalIndex),
                   signalIndex >= 63,
                   let volatility20 = annualizedVolatilityAt(values: leaderPrices, at: signalIndex, lookback: 20),
                   let volatility63 = annualizedVolatilityAt(values: leaderPrices, at: signalIndex, lookback: 63) {
                    earlyReRiskVolatilityDeclining = volatility20 <= volatility63
                }
                let earlyReRisk = earlyReRiskBand > 0
                    && sameLeaderForTrade
                    && targetLeaderForTrade != "gold"
                    && targetLeaderForTrade != "cash"
                    && targetGrossForTrade > priorGrossForTrade + 0.02
                    && difference >= earlyReRiskBand
                    && difference < tradeBand
                    && earlyReRiskVolatilityDeclining
                let sameLeaderReweightMinimumTurnover = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_SAME_LEADER_REWEIGHT_MIN_TURNOVER"] ?? "0"
                ) ?? 0
                let sameLeaderReweightBaseTurnover = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_SAME_LEADER_REWEIGHT_BASE_TURNOVER"] ?? "0"
                ) ?? 0
                let sameLeaderReweightLeaderGate = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_SAME_LEADER_REWEIGHT_LEADER_GATE"] ?? "0"
                ) ?? 0
                let sameLeaderReweightGrossDeltaMaximum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_SAME_LEADER_REWEIGHT_GROSS_DELTA_MAX"] ?? "0.02"
                ) ?? 0.02
                let sameLeaderReweightLeaderAllowed = sameLeaderReweightLeaderGate == 0
                    || (sameLeaderReweightLeaderGate == 1 && targetLeaderForTrade != "china")
                    || (sameLeaderReweightLeaderGate == 2 && ["nasdaq", "gold"].contains(targetLeaderForTrade))
                let sameLeaderReweightVolatilityMinimum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_SAME_LEADER_REWEIGHT_VOL_MIN"] ?? "0"
                ) ?? 0
                let sameLeaderReweightExtremeVolatilityMinimum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_SAME_LEADER_REWEIGHT_EXTREME_VOL_MIN"] ?? "99"
                ) ?? 99
                let sameLeaderReweightExtremeLeaderGate = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_SAME_LEADER_REWEIGHT_EXTREME_LEADER_GATE"] ?? "0"
                ) ?? 0
                let sameLeaderReweightMidTurnover = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_SAME_LEADER_REWEIGHT_MID_TURNOVER"] ?? "0"
                ) ?? 0
                let sameLeaderReweightMidVolatilityMinimum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_SAME_LEADER_REWEIGHT_MID_VOL_MIN"] ?? "0.06"
                ) ?? 0.06
                var sameLeaderReweightAnnualizedVolatility = 0.0
                var sameLeaderReweightVolatilityAllowed = sameLeaderReweightVolatilityMinimum <= 0
                if (sameLeaderReweightVolatilityMinimum > 0 || sameLeaderReweightMidTurnover > 0),
                   signalIndex >= 60 {
                    var recentReturns: [Double] = []
                    for cursor in (signalIndex - 59)...signalIndex {
                        guard cursor > 0 else { continue }
                        var dailyReturn = 0.0
                        var valid = true
                        for (symbol, weight) in previousWeights where weight > 0 {
                            guard let prices = data.pricesBySymbol[symbol],
                                  prices.indices.contains(cursor),
                                  prices[cursor - 1] > 0 else {
                                valid = false
                                break
                            }
                            dailyReturn += weight * (prices[cursor] / prices[cursor - 1] - 1)
                        }
                        if valid { recentReturns.append(dailyReturn) }
                    }
                    if recentReturns.count > 1 {
                        let mean = recentReturns.reduce(0, +) / Double(recentReturns.count)
                        let variance = recentReturns.reduce(0.0) {
                            $0 + pow($1 - mean, 2)
                        } / Double(recentReturns.count - 1)
                        let annualizedVolatility = sqrt(max(variance, 0)) * sqrt(252)
                        sameLeaderReweightAnnualizedVolatility = annualizedVolatility
                        let extremeLeaderAllowed = sameLeaderReweightExtremeLeaderGate == 0
                            || (sameLeaderReweightExtremeLeaderGate == 1 && ["nasdaq", "sp500"].contains(targetLeaderForTrade))
                            || (sameLeaderReweightExtremeLeaderGate == 2 && targetLeaderForTrade == "gold")
                            || (sameLeaderReweightExtremeLeaderGate == 3 && targetLeaderForTrade == "china")
                        let extremeOverrideActive = sameLeaderReweightExtremeVolatilityMinimum < 99
                            && annualizedVolatility >= sameLeaderReweightExtremeVolatilityMinimum
                            && extremeLeaderAllowed
                        sameLeaderReweightVolatilityAllowed = annualizedVolatility >= sameLeaderReweightVolatilityMinimum
                            && !extremeOverrideActive
                    }
                }
                let sameLeaderReweightTurnoverFiltered = difference < sameLeaderReweightBaseTurnover
                    || (sameLeaderReweightMidTurnover > 0
                        && sameLeaderReweightAnnualizedVolatility >= sameLeaderReweightMidVolatilityMinimum
                        && difference < sameLeaderReweightMidTurnover)
                    || (sameLeaderReweightMinimumTurnover > 0
                        && sameLeaderReweightVolatilityAllowed
                        && difference < sameLeaderReweightMinimumTurnover)
                let suppressSameLeaderReweight = sameLeaderReweightLeaderAllowed
                    && sameLeaderForTrade
                    && targetLeaderForTrade != "cash"
                    && abs(targetGrossForTrade - priorGrossForTrade) <= max(sameLeaderReweightGrossDeltaMaximum, 0)
                    && sameLeaderReweightTurnoverFiltered
                let suppressSmallReRisk = smallReRiskTurnoverFloor > 0
                    && targetGrossForTrade > priorGrossForTrade + 0.02
                    && difference < smallReRiskTurnoverFloor
                    && (!smallReRiskSameLeaderOnly || sameLeaderForTrade)
                let suppressGoldDeRisk = goldDeRiskTurnoverFloor > 0
                    && priorLeaderForTrade == "gold"
                    && targetLeaderForTrade == "gold"
                    && targetGrossForTrade >= 0.05
                    && targetGrossForTrade < priorGrossForTrade - 0.005
                    && difference < goldDeRiskTurnoverFloor
                let shouldRebalance: Bool
                if previousWeights.isEmpty {
                    shouldRebalance = !pendingWeights.isEmpty
                } else if suppressSameLeaderReweight || suppressSmallReRisk || suppressGoldDeRisk {
                    shouldRebalance = false
                } else if rebalanceTriggerMode == 1 {
                    shouldRebalance = usdCashStateChanged
                        || secularCarryStateChanged
                        || equityCurveStateChanged
                        || difference > rebalanceTriggerBand
                } else if rebalanceTriggerMode == 2 {
                    shouldRebalance = immediateRiskReduction
                        || usdCashStateChanged
                        || secularCarryStateChanged
                        || equityCurveStateChanged
                        || difference > rebalanceTriggerBand
                } else if costAwareRebalance {
                    shouldRebalance = immediateRiskReduction
                        || usdCashStateChanged
                        || secularCarryStateChanged
                        || equityCurveStateChanged
                        || difference > costAwareBand
                } else {
                    shouldRebalance = baseTargetChanged
                        || usdCashStateChanged
                        || secularCarryStateChanged
                        || equityCurveStateChanged
                        || earlyReRisk
                        || difference > tradeBand
                }''',
    )
    text = replace_once(
        text,
        '''    private static func runRiskContributionRegimeRouterWithTrace(
''',
        '''    static func researchCashConfidenceRunWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil
    ) -> ResearchTargetStrategyRun? {
        runRiskContributionCashConfidenceRouterWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            dateBounds: dateBounds
        )
    }

    private static func runRiskContributionRegimeRouterWithTrace(
''',
    )

    text = replace_once(
        text,
        '''                    let grossScale: Double
                    if baseGross < 0.20 {
                        grossScale = 0
                    } else if baseGross < 0.60 {
                        grossScale = 1
                    } else if baseGross < 0.80 {
                        grossScale = 0.65
                    } else {
                        grossScale = 1
                    }''',
        '''                    let grossScale: Double
                    if grossConfidenceShape == 0 {
                        if baseGross < 0.20 {
                            grossScale = 0
                        } else if baseGross < 0.60 {
                            grossScale = 1
                        } else if baseGross < 0.80 {
                            if disableMidGrossCliffs {
                                grossScale = 1
                            } else {
                                let midGrossHealthyScale = Double(
                                    ProcessInfo.processInfo.environment["ATM_CC_MID_GROSS_HEALTHY_SCALE"] ?? "0.65"
                                ) ?? 0.65
                                let baseLeader = leaderName(latestBaseTarget)
                                let leaderSymbol: String = {
                                    if baseLeader == "china" {
                                        return (latestBaseTarget["csi300"] ?? 0) >= (latestBaseTarget["shanghai_composite"] ?? 0)
                                            ? "csi300"
                                            : "shanghai_composite"
                                    }
                                    return baseLeader
                                }()
                                var midGrossHealthy = false
                                if midGrossHealthyScale > 0.65,
                                   baseLeader != "gold",
                                   baseLeader != "cash",
                                   let leaderPrices = data.pricesBySymbol[leaderSymbol],
                                   leaderPrices.indices.contains(signalIndex),
                                   signalIndex >= 100,
                                   let leaderMA100 = movingAverageAt(values: leaderPrices, at: signalIndex, period: 100),
                                   let leaderM63 = priceMomentum(values: leaderPrices, at: signalIndex, lookback: 63),
                                   let leaderVol20 = annualizedVolatilityAt(values: leaderPrices, at: signalIndex, lookback: 20),
                                   let leaderVol63 = annualizedVolatilityAt(values: leaderPrices, at: signalIndex, lookback: 63) {
                                    midGrossHealthy = leaderPrices[signalIndex] >= leaderMA100
                                        && leaderM63 > 0
                                        && leaderVol20 <= leaderVol63
                                }
                                grossScale = midGrossHealthy ? midGrossHealthyScale : 0.65
                            }
                        } else {
                            grossScale = 1
                        }
                    } else if baseGross <= 0.20 {
                        grossScale = 0
                    } else if baseGross >= 0.80 {
                        grossScale = 1
                    } else {
                        let normalized = min(max((baseGross - 0.20) / 0.60, 0), 1)
                        let targetGross: Double
                        switch grossConfidenceShape {
                        case 1:
                            targetGross = 0.80 * normalized
                        case 2:
                            targetGross = 0.80 * pow(normalized, 1.5)
                        case 3:
                            targetGross = 0.80 * pow(normalized, 2.0)
                        case 4:
                            targetGross = 0.80 * normalized * normalized * (3 - 2 * normalized)
                        case 5:
                            if baseGross < 0.60 {
                                targetGross = 0.39 * (baseGross - 0.20) / 0.40
                            } else {
                                targetGross = 0.39 + (0.80 - 0.39) * (baseGross - 0.60) / 0.20
                            }
                        case 6:
                            if baseGross < 0.60 {
                                targetGross = 0.50 * (baseGross - 0.20) / 0.40
                            } else {
                                targetGross = 0.50 + (0.80 - 0.50) * (baseGross - 0.60) / 0.20
                            }
                        default:
                            targetGross = baseGross
                        }
                        grossScale = baseGross > 0 ? min(max(targetGross / baseGross, 0), 1) : 0
                    }''',
    )
    text = replace_once(
        text,
        '''                if adjustedGross >= 0.20,
                   adjustedGross <= lowConfidenceChinaGrossMaximum,''',
        '''                if !disableChinaPurge,
                   adjustedGross >= 0.20,
                   adjustedGross <= lowConfidenceChinaGrossMaximum,''',
    )
    text = replace_once(
        text,
        '''                    if matureGross >= matureNasdaqGrossMinimum,
                       nasdaqWeight >= matureNasdaqMinimumWeight,''',
        '''                    if !disableMatureNasdaqBrake,
                       matureGross >= matureNasdaqGrossMinimum,
                       nasdaqWeight >= matureNasdaqMinimumWeight,''',
    )
    text = replace_once(
        text,
        '''                if residualGross > 0,
                   residualGross <= residualNasdaqGrossMaximum,''',
        '''                if !disableMatureNasdaqBrake,
                   residualGross > 0,
                   residualGross <= residualNasdaqGrossMaximum,''',
    )
    text = replace_once(
        text,
        '''                if stateGross >= 0.30,
                   stateGross < 0.40,''',
        '''                if !disableMidGrossCliffs,
                   stateGross >= 0.30,
                   stateGross < 0.40,''',
    )
    text = replace_once(
        text,
        '''                if postGoldGross >= 0.50,
                   postGoldGross < 0.60,''',
        '''                if !disableMidGrossCliffs,
                   postGoldGross >= 0.50,
                   postGoldGross < 0.60,''',
    )
    text = replace_once(
        text,
        '''                if !disableMidGrossCliffs,
                   postGoldGross >= 0.50,
                   postGoldGross < 0.60,
                   nasdaqDominant {
                    pendingWeights = pendingWeights.mapValues { $0 * 0.0 }
                }''',
        '''                if !disableMidGrossCliffs,
                   postGoldGross >= 0.50,
                   postGoldGross < 0.60,
                   nasdaqDominant {
                    let nasdaqMidGrossCliffMode = Int(
                        ProcessInfo.processInfo.environment["ATM_CC_NASDAQ_MID_GROSS_CLIFF_MODE"] ?? "0"
                    ) ?? 0
                    var healthyNasdaqMidGross = false
                    if nasdaqMidGrossCliffMode > 0,
                       signalIndex >= 100,
                       let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                       let sp500Prices = data.pricesBySymbol["sp500"],
                       nasdaqPrices.indices.contains(signalIndex),
                       sp500Prices.indices.contains(signalIndex),
                       let nasdaqMA100 = movingAverageAt(values: nasdaqPrices, at: signalIndex, period: 100),
                       let sp500MA100 = movingAverageAt(values: sp500Prices, at: signalIndex, period: 100),
                       let nasdaqM63 = priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 63),
                       let sp500M63 = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 63),
                       let nasdaqVol20 = annualizedVolatilityAt(values: nasdaqPrices, at: signalIndex, lookback: 20),
                       let nasdaqVol63 = annualizedVolatilityAt(values: nasdaqPrices, at: signalIndex, lookback: 63) {
                        healthyNasdaqMidGross = nasdaqPrices[signalIndex] >= nasdaqMA100
                            && sp500Prices[signalIndex] >= sp500MA100
                            && nasdaqM63 > 0
                            && sp500M63 > 0
                            && nasdaqVol20 <= nasdaqVol63
                    }
                    if nasdaqMidGrossCliffMode == 4 {
                        var sp500Healthy = false
                        if let sp500Prices = data.pricesBySymbol["sp500"],
                           sp500Prices.indices.contains(signalIndex),
                           let sp500MA100 = movingAverageAt(values: sp500Prices, at: signalIndex, period: 100),
                           let sp500M63 = priceMomentum(values: sp500Prices, at: signalIndex, lookback: 63),
                           let sp500Vol20 = annualizedVolatilityAt(values: sp500Prices, at: signalIndex, lookback: 20),
                           let sp500Vol63 = annualizedVolatilityAt(values: sp500Prices, at: signalIndex, lookback: 63) {
                            sp500Healthy = sp500Prices[signalIndex] >= sp500MA100
                                && sp500M63 > 0
                                && sp500Vol20 <= sp500Vol63
                        }
                        pendingWeights = sp500Healthy ? ["sp500": 0.20] : [:]
                    } else if nasdaqMidGrossCliffMode == 5 {
                        if healthyNasdaqMidGross {
                            pendingWeights = ["nasdaq": 0.10, "sp500": 0.10]
                        } else {
                            pendingWeights = [:]
                        }
                    } else if !healthyNasdaqMidGross {
                        pendingWeights = pendingWeights.mapValues { $0 * 0.0 }
                    } else if nasdaqMidGrossCliffMode == 2 {
                        pendingWeights = pendingWeights.mapValues { $0 * 0.65 }
                    } else if nasdaqMidGrossCliffMode == 3 {
                        pendingWeights = pendingWeights.mapValues { $0 * 0.85 }
                    }
                }''',
    )
    text = replace_once(
        text,
        '''                if positiveBreadthCount(40) == 1 {
                    pendingWeights = pendingWeights.mapValues { $0 * 0.91 }
                }
                if positiveBreadthCount(10) == 4 {
                    pendingWeights = pendingWeights.mapValues { $0 * 0.90 }
                }
                if positiveBreadthCount(20) == 1 {
                    pendingWeights = pendingWeights.mapValues { $0 * 0.94 }
                }''',
        '''                if breadthBrake40OneStrength > 0, positiveBreadthCount(40) == 1 {
                    let scale = 1 - 0.09 * breadthBrake40OneStrength
                    pendingWeights = pendingWeights.mapValues { $0 * scale }
                }
                if breadthBrake10FourStrength > 0, positiveBreadthCount(10) == 4 {
                    let scale = 1 - 0.10 * breadthBrake10FourStrength
                    pendingWeights = pendingWeights.mapValues { $0 * scale }
                }
                if breadthBrake20OneStrength > 0, positiveBreadthCount(20) == 1 {
                    let scale = 1 - 0.06 * breadthBrake20OneStrength
                    pendingWeights = pendingWeights.mapValues { $0 * scale }
                }''',
    )
    text = replace_once(
        text,
        '''                    if holdGross >= 0.10,
                       holdGross < 0.18,''',
        '''                    if !disableHoldHysteresis,
                       holdGross >= 0.10,
                       holdGross < 0.18,''',
    )
    text = replace_once(
        text,
        '''                    if holdGross >= 0.18,
                       holdGross < 0.23,''',
        '''                    if !disableHoldHysteresis,
                       holdGross >= 0.18,
                       holdGross < 0.23,''',
    )
    text = replace_once(
        text,
        '''                if !previousWeights.isEmpty,
                   [5, 6, 7, 9, 10].contains(where: {''',
        '''                if !disableHoldHysteresis,
                   !previousWeights.isEmpty,
                   [5, 6, 7, 9, 10].contains(where: {''',
    )
    text = replace_once(
        text,
        '''                if preHoldGross >= 0.05,
                   preHoldGross < 0.06,''',
        '''                if !disableHoldHysteresis,
                   preHoldGross >= 0.05,
                   preHoldGross < 0.06,''',
    )
    text = replace_once(
        text,
        '''                if !previousWeights.isEmpty {
                    let priorLeader = leaderName(previousWeights)
                    let targetLeader = leaderName(pendingWeights)
                    let priorGross = previousWeights.values.reduce(0, +)
                    let targetGross = pendingWeights.values.reduce(0, +)
                    if baseTargetChanged,
                       targetLeader != priorLeader,
                       targetLeader != "cash",
                       priorLeader != "cash",
                       targetGross >= priorGross - 0.000001 {
                        let successes = leadershipSuccesses[targetLeader, default: 0]
                        let failures = leadershipFailures[targetLeader, default: 0]
                        let posteriorMean = (leadershipPriorEvidence + successes)
                            / (2 * leadershipPriorEvidence + successes + failures)
                        let leadershipEdge = min(max(2 * posteriorMean - 1, 0), 1)
                        let migration = minimumLeadershipMigration
                            + (1 - minimumLeadershipMigration) * leadershipEdge
                        let originalTarget = pendingWeights
                        let symbols = Set(previousWeights.keys)
                            .union(originalTarget.keys)
                            .sorted()
                        pendingWeights = Dictionary(uniqueKeysWithValues: symbols.map { symbol in
                            let prior = previousWeights[symbol] ?? 0
                            let target = originalTarget[symbol] ?? 0
                            return (symbol, prior + migration * (target - prior))
                        })
                        leadershipTrials.append(
                            OnlineLeadershipTrial(
                                resolveIndex: signalIndex + leadershipEvaluationSessions,
                                targetLeader: targetLeader,
                                priorLeader: priorLeader,
                                startPrices: capturedPrices(
                                    pricesBySymbol: data.pricesBySymbol,
                                    at: signalIndex
                                )
                            )
                        )
                    }
                }''',
        '''                if sp500CrossConfirmationMode > 0,
                   !previousWeights.isEmpty,
                   signalIndex >= 40,
                   let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   let nasdaqMomentum10 = priceMomentum(
                    values: nasdaqPrices,
                    at: signalIndex,
                    lookback: 10
                   ),
                   let nasdaqMomentum20 = priceMomentum(
                    values: nasdaqPrices,
                    at: signalIndex,
                    lookback: 20
                   ),
                   let nasdaqMomentum40 = priceMomentum(
                    values: nasdaqPrices,
                    at: signalIndex,
                    lookback: 40
                   ) {
                    let priorSP500 = previousWeights["sp500"] ?? 0
                    let targetSP500 = pendingWeights["sp500"] ?? 0
                    let increase = targetSP500 - priorSP500
                    let confirmationFailed: Bool
                    switch sp500CrossConfirmationMode {
                    case 1:
                        confirmationFailed = nasdaqMomentum20 < 0
                            && nasdaqMomentum40 < 0
                    case 2:
                        confirmationFailed = nasdaqMomentum10 < 0
                            && nasdaqMomentum20 < 0
                            && nasdaqMomentum40 < 0
                    case 3:
                        confirmationFailed = nasdaqMomentum20 < 0
                    default:
                        confirmationFailed = false
                    }
                    if increase >= max(sp500CrossConfirmationMinimumIncrease, 0),
                       targetSP500 >= max(sp500CrossConfirmationMinimumTarget, 0),
                       confirmationFailed {
                        let retained = min(max(
                            sp500CrossConfirmationRetainedIncrease,
                            0
                        ), 1)
                        pendingWeights["sp500"] = priorSP500 + retained * increase
                    }
                }

                if stagedHandoffMode > 0,
                   let stagedTargetLeader = stagedHandoffTargetLeader,
                   let stagedPriorLeader = stagedHandoffPriorLeader {
                    let currentTargetLeader = leaderName(pendingWeights)
                    if currentTargetLeader != stagedTargetLeader {
                        stagedHandoffTargetLeader = nil
                        stagedHandoffPriorLeader = nil
                        stagedHandoffResolveIndex = -1
                        stagedHandoffStartPrices = [:]
                    } else if signalIndex < stagedHandoffResolveIndex {
                        pendingWeights = previousWeights
                    } else {
                        let targetReturn = leaderReturn(
                            stagedTargetLeader,
                            startPrices: stagedHandoffStartPrices,
                            pricesBySymbol: data.pricesBySymbol,
                            at: signalIndex
                        )
                        let priorReturn = leaderReturn(
                            stagedPriorLeader,
                            startPrices: stagedHandoffStartPrices,
                            pricesBySymbol: data.pricesBySymbol,
                            at: signalIndex
                        )
                        let relativeValidated = targetReturn != nil
                            && priorReturn != nil
                            && targetReturn! >= priorReturn! + stagedHandoffRequiredEdge
                        let absoluteValidated = stagedHandoffMode < 2
                            || (targetReturn ?? -Double.infinity) > 0
                        if !(relativeValidated && absoluteValidated) {
                            pendingWeights = previousWeights
                        }
                        stagedHandoffTargetLeader = nil
                        stagedHandoffPriorLeader = nil
                        stagedHandoffResolveIndex = -1
                        stagedHandoffStartPrices = [:]
                    }
                }

                if stagedHandoffTargetLeader == nil, !previousWeights.isEmpty {
                    let priorLeader = leaderName(previousWeights)
                    let targetLeader = leaderName(pendingWeights)
                    let priorGross = previousWeights.values.reduce(0, +)
                    let targetGross = pendingWeights.values.reduce(0, +)
                    if baseTargetChanged,
                       targetLeader != priorLeader,
                       targetLeader != "cash",
                       priorLeader != "cash",
                       targetGross >= priorGross - 0.000001 {
                        let successes = leadershipSuccesses[targetLeader, default: 0]
                        let failures = leadershipFailures[targetLeader, default: 0]
                        let posteriorMean = (leadershipPriorEvidence + successes)
                            / (2 * leadershipPriorEvidence + successes + failures)
                        let leadershipEdge = min(max(2 * posteriorMean - 1, 0), 1)
                        let migration = minimumLeadershipMigration
                            + (1 - minimumLeadershipMigration) * leadershipEdge
                        let riskIncreaseMigration = targetGross > priorGross + 0.02
                            ? max(migration, min(max(riskIncreaseMigrationFloor, 0), 1))
                            : migration
                        let originalTarget = pendingWeights
                        let baseEffectiveMigration = stagedHandoffMode > 0
                            ? min(
                                riskIncreaseMigration,
                                min(max(stagedHandoffInitialMigration, 0), 1)
                            )
                            : riskIncreaseMigration
                        let usInternalLeadershipMigrationCap = Double(
                            ProcessInfo.processInfo.environment["ATM_CC_US_INTERNAL_LEADERSHIP_MIGRATION_CAP"] ?? "1"
                        ) ?? 1
                        let usInternalLeadershipSwitch = ["nasdaq", "sp500"].contains(priorLeader)
                            && ["nasdaq", "sp500"].contains(targetLeader)
                            && priorLeader != targetLeader
                        let usInternalEffectiveMigration = usInternalLeadershipSwitch
                            ? min(baseEffectiveMigration, min(max(usInternalLeadershipMigrationCap, 0), 1))
                            : baseEffectiveMigration
                        let highVolLeadershipThreshold = Double(
                            ProcessInfo.processInfo.environment["ATM_CC_HIGH_VOL_LEADERSHIP_THRESHOLD"] ?? "99"
                        ) ?? 99
                        let highVolLeadershipMigrationCap = Double(
                            ProcessInfo.processInfo.environment["ATM_CC_HIGH_VOL_LEADERSHIP_MIGRATION_CAP"] ?? "1"
                        ) ?? 1
                        let highVolLeadershipGate = Int(
                            ProcessInfo.processInfo.environment["ATM_CC_HIGH_VOL_LEADERSHIP_GATE"] ?? "0"
                        ) ?? 0
                        let highVolLeadershipGateAllows = highVolLeadershipGate == 0
                            || (highVolLeadershipGate == 1 && priorLeader == "china")
                            || (highVolLeadershipGate == 2 && targetLeader == "china")
                            || (highVolLeadershipGate == 3 && (priorLeader == "china" || targetLeader == "china"))
                            || (highVolLeadershipGate == 4 && ["nasdaq", "sp500"].contains(priorLeader) && ["nasdaq", "sp500"].contains(targetLeader))
                        var highVolLeadershipSwitch = false
                        if highVolLeadershipThreshold < 99,
                           highVolLeadershipGateAllows,
                           signalIndex >= 60 {
                            let highVolLeadershipVolatilityMode = Int(
                                ProcessInfo.processInfo.environment["ATM_CC_HIGH_VOL_LEADERSHIP_VOL_MODE"] ?? "0"
                            ) ?? 0
                            var recentReturns: [Double] = []
                            if highVolLeadershipVolatilityMode == 1 {
                                for cursor in (signalIndex - 59)...signalIndex {
                                    guard cursor > 0 else { continue }
                                    var dailyReturn = 0.0
                                    var valid = true
                                    for (symbol, weight) in previousWeights where weight > 0 {
                                        guard let prices = data.pricesBySymbol[symbol],
                                              prices.indices.contains(cursor),
                                              prices[cursor - 1] > 0 else {
                                            valid = false
                                            break
                                        }
                                        dailyReturn += weight * (prices[cursor] / prices[cursor - 1] - 1)
                                    }
                                    if valid { recentReturns.append(dailyReturn) }
                                }
                            } else {
                                for cursor in (signalIndex - 59)...signalIndex {
                                    guard cursor > 0,
                                          let priorValue = alignedBaseValues[cursor - 1],
                                          let currentValue = alignedBaseValues[cursor],
                                          priorValue > 0 else { continue }
                                    recentReturns.append(currentValue / priorValue - 1)
                                }
                            }
                            if recentReturns.count > 1 {
                                let mean = recentReturns.reduce(0, +) / Double(recentReturns.count)
                                let variance = recentReturns.reduce(0.0) {
                                    $0 + pow($1 - mean, 2)
                                } / Double(recentReturns.count - 1)
                                let annualizedVolatility = sqrt(max(variance, 0)) * sqrt(252)
                                highVolLeadershipSwitch = annualizedVolatility >= highVolLeadershipThreshold
                            }
                        }
                        let effectiveMigration = highVolLeadershipSwitch
                            ? min(usInternalEffectiveMigration, min(max(highVolLeadershipMigrationCap, 0), 1))
                            : usInternalEffectiveMigration
                        let symbols = Set(previousWeights.keys)
                            .union(originalTarget.keys)
                            .sorted()
                        pendingWeights = Dictionary(uniqueKeysWithValues: symbols.map { symbol in
                            let prior = previousWeights[symbol] ?? 0
                            let target = originalTarget[symbol] ?? 0
                            return (symbol, prior + effectiveMigration * (target - prior))
                        })
                        if riskIncreaseGrossCompletionMode > 0,
                           targetGross > priorGross + 0.02 {
                            let interpolatedGross = pendingWeights.values.reduce(0, +)
                            let missingGross = max(targetGross - interpolatedGross, 0)
                            if missingGross > 0 {
                                switch riskIncreaseGrossCompletionMode {
                                case 1:
                                    let denominator = originalTarget.values
                                        .filter { $0 > 0 }
                                        .reduce(0, +)
                                    if denominator > 0 {
                                        for (symbol, targetWeight) in originalTarget where targetWeight > 0 {
                                            pendingWeights[symbol, default: 0] += missingGross
                                                * targetWeight / denominator
                                        }
                                    }
                                case 2:
                                    let positiveDeltas = Dictionary(uniqueKeysWithValues: symbols.compactMap { symbol -> (String, Double)? in
                                        let delta = (originalTarget[symbol] ?? 0)
                                            - (previousWeights[symbol] ?? 0)
                                        return delta > 0 ? (symbol, delta) : nil
                                    })
                                    let denominator = positiveDeltas.values.reduce(0, +)
                                    if denominator > 0 {
                                        for (symbol, delta) in positiveDeltas {
                                            pendingWeights[symbol, default: 0] += missingGross
                                                * delta / denominator
                                        }
                                    }
                                case 3:
                                    if targetLeader == "china" {
                                        let targetCSI = originalTarget["csi300"] ?? 0
                                        let targetShanghai = originalTarget["shanghai_composite"] ?? 0
                                        let targetChina = targetCSI + targetShanghai
                                        if targetChina > 0 {
                                            pendingWeights["csi300", default: 0] += missingGross
                                                * targetCSI / targetChina
                                            pendingWeights["shanghai_composite", default: 0] += missingGross
                                                * targetShanghai / targetChina
                                        }
                                    } else {
                                        pendingWeights[targetLeader, default: 0] += missingGross
                                    }
                                default:
                                    break
                                }
                            }
                        }
                        let startPrices = capturedPrices(
                            pricesBySymbol: data.pricesBySymbol,
                            at: signalIndex
                        )
                        if stagedHandoffMode > 0 {
                            stagedHandoffTargetLeader = targetLeader
                            stagedHandoffPriorLeader = priorLeader
                            stagedHandoffResolveIndex = signalIndex
                                + max(stagedHandoffEvaluationSessions, 1)
                            stagedHandoffStartPrices = startPrices
                        }
                        leadershipTrials.append(
                            OnlineLeadershipTrial(
                                resolveIndex: signalIndex + leadershipEvaluationSessions,
                                targetLeader: targetLeader,
                                priorLeader: priorLeader,
                                startPrices: startPrices
                            )
                        )
                    }
                }

                if deRiskCalibrationMode > 0, !deRiskCalibrationTrials.isEmpty {
                    var unresolvedDeRiskTrials: [OnlineLeadershipTrial] = []
                    for trial in deRiskCalibrationTrials {
                        if trial.resolveIndex <= signalIndex,
                           let realizedReturn = leaderReturn(
                            trial.targetLeader,
                            startPrices: trial.startPrices,
                            pricesBySymbol: data.pricesBySymbol,
                            at: signalIndex
                           ) {
                            let key = deRiskCalibrationMode == 1
                                ? "global"
                                : trial.targetLeader
                            if realizedReturn > 0 {
                                deRiskCalibrationSuccesses[key, default: 0] += 1
                            } else {
                                deRiskCalibrationFailures[key, default: 0] += 1
                            }
                        } else {
                            unresolvedDeRiskTrials.append(trial)
                        }
                    }
                    deRiskCalibrationTrials = unresolvedDeRiskTrials
                }

                let basePendingGrossBeforeBuffer = pendingWeights.values.reduce(0, +)
                if deRiskBufferMode > 0, !deRiskBufferWeights.isEmpty {
                    let currentBaseValue = alignedBaseValues.indices.contains(signalIndex)
                        ? alignedBaseValues[signalIndex]
                        : nil
                    let peakStart = max(0, signalIndex - 251)
                    let peakValue = alignedBaseValues.indices.contains(signalIndex)
                        ? (alignedBaseValues[peakStart...signalIndex].compactMap { $0 }.max() ?? currentBaseValue ?? 0)
                        : 0
                    let baseDrawdown = currentBaseValue != nil && peakValue > 0
                        ? max(1 - currentBaseValue! / peakValue, 0)
                        : 0
                    let bufferGross = deRiskBufferWeights.values.reduce(0, +)
                    let signalRecovered = basePendingGrossBeforeBuffer
                        > deRiskBufferBaseTargetGross + max(0.5 * bufferGross, 0.005)
                    let signalConfirmed = baseTargetChanged
                        && signalIndex > deRiskBufferEntryIndex
                        && basePendingGrossBeforeBuffer <= deRiskBufferBaseTargetGross + 0.000001
                    let fullExit = basePendingGrossBeforeBuffer < 0.05
                    let deeperDrawdown = baseDrawdown >= nearPeakDeRiskDrawdownThreshold
                    let baseLossConfirmed = currentBaseValue != nil
                        && deRiskBufferEntryBaseValue > 0
                        && currentBaseValue! / deRiskBufferEntryBaseValue - 1
                            <= -max(deRiskBufferLossThreshold, 0)
                    let timedOut = signalIndex - deRiskBufferEntryIndex
                        >= max(deRiskBufferMaximumSessions, 1)
                    let shouldRelease: Bool
                    switch deRiskBufferMode {
                    case 1:
                        shouldRelease = fullExit || signalRecovered || deeperDrawdown
                    case 2:
                        shouldRelease = fullExit || signalRecovered || deeperDrawdown
                            || signalConfirmed
                    case 3:
                        shouldRelease = fullExit || signalRecovered || deeperDrawdown
                            || baseLossConfirmed
                    default:
                        shouldRelease = fullExit || signalRecovered || deeperDrawdown
                            || signalConfirmed || baseLossConfirmed || timedOut
                    }
                    if shouldRelease {
                        deRiskBufferLeader = nil
                        deRiskBufferWeights = [:]
                        deRiskBufferEntryIndex = -1
                        deRiskBufferBaseTargetGross = 0
                        deRiskBufferEntryBaseValue = 0
                    } else {
                        for (symbol, weight) in deRiskBufferWeights where weight > 0 {
                            pendingWeights[symbol, default: 0] += weight
                        }
                    }
                }

                if nearPeakDeRiskFraction < 1,
                   nearPeakDeRiskDrawdownThreshold > 0,
                   (deRiskBufferMode == 0 || deRiskBufferWeights.isEmpty),
                   !previousWeights.isEmpty {
                    let priorGross = previousWeights.values.reduce(0, +)
                    let targetGross = pendingWeights.values.reduce(0, +)
                    let priorScopeLeader = leaderName(previousWeights)
                    let targetScopeLeader = leaderName(pendingWeights)
                    let scopeAllows = nearPeakDeRiskScope == 0
                        || (nearPeakDeRiskScope == 1 && priorScopeLeader != targetScopeLeader)
                        || (nearPeakDeRiskScope == 2 && priorScopeLeader == targetScopeLeader)
                    let leaderAllows: Bool
                    switch nearPeakDeRiskLeaderGate {
                    case 1:
                        leaderAllows = priorScopeLeader != "china"
                    case 2:
                        leaderAllows = priorScopeLeader == "gold"
                    case 3:
                        leaderAllows = priorScopeLeader == "nasdaq" || priorScopeLeader == "sp500"
                    case 4:
                        leaderAllows = priorScopeLeader == "china"
                    default:
                        leaderAllows = true
                    }
                    func leaderMomentum(_ leader: String, lookback: Int) -> Double? {
                        func assetMomentum(_ symbol: String) -> Double? {
                            guard let prices = data.pricesBySymbol[symbol],
                                  prices.indices.contains(signalIndex),
                                  prices.indices.contains(signalIndex - lookback),
                                  prices[signalIndex - lookback] > 0 else { return nil }
                            return prices[signalIndex] / prices[signalIndex - lookback] - 1
                        }
                        switch leader {
                        case "china":
                            guard let csi = assetMomentum("csi300"),
                                  let shanghai = assetMomentum("shanghai_composite") else { return nil }
                            return 0.5 * (csi + shanghai)
                        case "cash":
                            return nil
                        default:
                            return assetMomentum(leader)
                        }
                    }
                    func leaderAboveMA(_ leader: String, period: Int) -> Bool {
                        func assetAboveMA(_ symbol: String) -> Bool? {
                            guard let prices = data.pricesBySymbol[symbol],
                                  prices.indices.contains(signalIndex),
                                  let average = movingAverageAt(
                                    values: prices,
                                    at: signalIndex,
                                    period: period
                                  ) else { return nil }
                            return prices[signalIndex] >= average
                        }
                        switch leader {
                        case "china":
                            guard let csi = assetAboveMA("csi300"),
                                  let shanghai = assetAboveMA("shanghai_composite") else { return false }
                            return csi && shanghai
                        case "cash":
                            return false
                        default:
                            return assetAboveMA(leader) ?? false
                        }
                    }
                    let trendAllows: Bool
                    switch nearPeakDeRiskTrendGate {
                    case 1:
                        trendAllows = (leaderMomentum(priorScopeLeader, lookback: 20) ?? -Double.infinity) > 0
                    case 2:
                        trendAllows = (leaderMomentum(priorScopeLeader, lookback: 60) ?? -Double.infinity) > 0
                    case 3:
                        trendAllows = leaderAboveMA(priorScopeLeader, period: 60)
                    case 4:
                        trendAllows = (leaderMomentum(priorScopeLeader, lookback: 20) ?? -Double.infinity) > 0
                            && (leaderMomentum(priorScopeLeader, lookback: 60) ?? -Double.infinity) > 0
                    default:
                        trendAllows = true
                    }
                    if scopeAllows,
                       leaderAllows,
                       trendAllows,
                       (targetGross >= 0.05 || nearPeakDeRiskIncludesExit),
                       targetGross < priorGross - max(nearPeakDeRiskGrossDropThreshold, 0),
                       signalIndex >= 0,
                       alignedBaseValues.indices.contains(signalIndex),
                       let currentBaseValue = alignedBaseValues[signalIndex],
                       currentBaseValue > 0 {
                        let peakStart = max(0, signalIndex - 251)
                        let peakValue = alignedBaseValues[peakStart...signalIndex]
                            .compactMap { $0 }
                            .max() ?? currentBaseValue
                        let baseDrawdown = peakValue > 0
                            ? max(1 - currentBaseValue / peakValue, 0)
                            : 0
                        if baseDrawdown < nearPeakDeRiskDrawdownThreshold {
                            var recentBaseReturns: [Double] = []
                            if signalIndex >= 60 {
                                for cursor in (signalIndex - 59)...signalIndex {
                                    guard cursor > 0,
                                          let priorValue = alignedBaseValues[cursor - 1],
                                          let currentValue = alignedBaseValues[cursor],
                                          priorValue > 0 else { continue }
                                    recentBaseReturns.append(currentValue / priorValue - 1)
                                }
                            }
                            let recentBaseVolatility: Double = {
                                guard recentBaseReturns.count > 1 else { return 0 }
                                let mean = recentBaseReturns.reduce(0, +)
                                    / Double(recentBaseReturns.count)
                                let variance = recentBaseReturns.reduce(0.0) {
                                    $0 + pow($1 - mean, 2)
                                } / Double(recentBaseReturns.count - 1)
                                return sqrt(max(variance, 0)) * sqrt(252)
                            }()
                            let goldHighVolDeRiskThreshold = Double(
                                ProcessInfo.processInfo.environment["ATM_CC_GOLD_HIGH_VOL_DERISK_THRESHOLD"] ?? "99"
                            ) ?? 99
                            let goldHighVolDeRiskFraction = Double(
                                ProcessInfo.processInfo.environment["ATM_CC_GOLD_HIGH_VOL_DERISK_FRACTION"] ?? String(nearPeakDeRiskFraction)
                            ) ?? nearPeakDeRiskFraction
                            let deRiskPortfolioMidVolatilityMinimum = Double(
                                ProcessInfo.processInfo.environment["ATM_CC_DERISK_PORTFOLIO_MID_VOL_MIN"] ?? "99"
                            ) ?? 99
                            let deRiskPortfolioMidVolatilityMaximum = Double(
                                ProcessInfo.processInfo.environment["ATM_CC_DERISK_PORTFOLIO_MID_VOL_MAX"] ?? "99"
                            ) ?? 99
                            let deRiskPortfolioMidVolatilityFraction = Double(
                                ProcessInfo.processInfo.environment["ATM_CC_DERISK_PORTFOLIO_MID_VOL_FRACTION"] ?? String(nearPeakDeRiskFraction)
                            ) ?? nearPeakDeRiskFraction
                            var priorPortfolioVolatility = 0.0
                            if (deRiskPortfolioMidVolatilityMaximum < 99
                                || (priorScopeLeader == "gold" && goldHighVolDeRiskThreshold < 99)),
                               signalIndex >= 60 {
                                var priorPortfolioReturns: [Double] = []
                                for cursor in (signalIndex - 59)...signalIndex {
                                    guard cursor > 0 else { continue }
                                    var dailyReturn = 0.0
                                    var valid = true
                                    for (symbol, weight) in previousWeights where weight > 0 {
                                        guard let prices = data.pricesBySymbol[symbol],
                                              prices.indices.contains(cursor),
                                              prices[cursor - 1] > 0 else {
                                            valid = false
                                            break
                                        }
                                        dailyReturn += weight * (prices[cursor] / prices[cursor - 1] - 1)
                                    }
                                    if valid { priorPortfolioReturns.append(dailyReturn) }
                                }
                                if priorPortfolioReturns.count > 1 {
                                    let mean = priorPortfolioReturns.reduce(0, +) / Double(priorPortfolioReturns.count)
                                    let variance = priorPortfolioReturns.reduce(0.0) {
                                        $0 + pow($1 - mean, 2)
                                    } / Double(priorPortfolioReturns.count - 1)
                                    priorPortfolioVolatility = sqrt(max(variance, 0)) * sqrt(252)
                                }
                            }
                            let fixedConfiguredFraction: Double
                            if priorPortfolioVolatility >= deRiskPortfolioMidVolatilityMinimum,
                               priorPortfolioVolatility < deRiskPortfolioMidVolatilityMaximum {
                                fixedConfiguredFraction = deRiskPortfolioMidVolatilityFraction
                            } else if priorScopeLeader == "gold",
                                      priorPortfolioVolatility >= goldHighVolDeRiskThreshold {
                                fixedConfiguredFraction = goldHighVolDeRiskFraction
                            } else if recentBaseVolatility >= nearPeakDeRiskHighVolThreshold {
                                fixedConfiguredFraction = nearPeakDeRiskHighVolFraction
                            } else {
                                fixedConfiguredFraction = nearPeakDeRiskFraction
                            }
                            let configuredFraction: Double
                            if deRiskCalibrationMode > 0 {
                                let key = deRiskCalibrationMode == 1
                                    ? "global"
                                    : priorScopeLeader
                                let successes = deRiskCalibrationSuccesses[key, default: 0]
                                let failures = deRiskCalibrationFailures[key, default: 0]
                                let prior = max(deRiskCalibrationPriorEvidence, 0.0001)
                                let prematureProbability = (prior + successes)
                                    / (2 * prior + successes + failures)
                                let maximumRetention = min(
                                    max(deRiskCalibrationMaximumRetention, 0),
                                    1
                                )
                                configuredFraction = 1 - maximumRetention * prematureProbability
                            } else {
                                configuredFraction = fixedConfiguredFraction
                            }
                            let grossDrop = max(priorGross - targetGross, 0)
                            let executionSymbols = Set(previousWeights.keys)
                                .union(pendingWeights.keys)
                            let executionTurnover = executionSymbols.reduce(0.0) {
                                $0 + abs((pendingWeights[$1] ?? 0) - (previousWeights[$1] ?? 0))
                            }
                            let baseRetention = min(max(1 - configuredFraction, 0), 1)
                            let maximumRetention = min(
                                max(nearPeakDeRiskMaximumRetention, baseRetention),
                                1
                            )
                            let severityRetention: Double
                            switch nearPeakDeRiskSeverityMode {
                            case 1:
                                severityRetention = min(
                                    maximumRetention,
                                    baseRetention * max(grossDrop / 0.20, 0)
                                )
                            case 2:
                                severityRetention = min(
                                    maximumRetention,
                                    baseRetention * sqrt(max(grossDrop / 0.20, 0))
                                )
                            case 3:
                                severityRetention = grossDrop >= 0.40
                                    ? maximumRetention
                                    : baseRetention
                            case 4:
                                severityRetention = min(
                                    maximumRetention,
                                    baseRetention * max(executionTurnover / 0.40, 0)
                                )
                            case 5:
                                let grossSeverity = max(grossDrop / 0.20, 0)
                                let turnoverSeverity = max(executionTurnover / 0.40, 0)
                                severityRetention = min(
                                    maximumRetention,
                                    baseRetention * max(grossSeverity, turnoverSeverity)
                                )
                            case 6:
                                let grossSeverity = max(grossDrop / 0.20, 0)
                                let turnoverSeverity = max(executionTurnover / 0.40, 0)
                                severityRetention = min(
                                    maximumRetention,
                                    baseRetention * 0.5 * (grossSeverity + turnoverSeverity)
                                )
                            case 7:
                                let grossSeverity = max(grossDrop / 0.20, 0)
                                let turnoverSeverity = max(executionTurnover / 0.40, 0)
                                let rmsSeverity = sqrt(
                                    0.5 * (grossSeverity * grossSeverity
                                        + turnoverSeverity * turnoverSeverity)
                                )
                                severityRetention = min(
                                    maximumRetention,
                                    baseRetention * rmsSeverity
                                )
                            case 8:
                                let grossSeverity = max(grossDrop / 0.20, 0)
                                let turnoverSeverity = max(executionTurnover / 0.40, 0)
                                severityRetention = min(
                                    maximumRetention,
                                    baseRetention * sqrt(grossSeverity * turnoverSeverity)
                                )
                            default:
                                severityRetention = baseRetention
                            }
                            let drawdownRetentionMultiplier: Double
                            switch nearPeakDeRiskDrawdownDecayMode {
                            case 1:
                                drawdownRetentionMultiplier = nearPeakDeRiskDrawdownThreshold > 0
                                    ? min(max(
                                        1 - baseDrawdown / nearPeakDeRiskDrawdownThreshold,
                                        0
                                    ), 1)
                                    : 0
                            case 2:
                                let plateau = 0.02
                                if baseDrawdown <= plateau {
                                    drawdownRetentionMultiplier = 1
                                } else if nearPeakDeRiskDrawdownThreshold > plateau {
                                    drawdownRetentionMultiplier = min(max(
                                        (nearPeakDeRiskDrawdownThreshold - baseDrawdown)
                                            / (nearPeakDeRiskDrawdownThreshold - plateau),
                                        0
                                    ), 1)
                                } else {
                                    drawdownRetentionMultiplier = 0
                                }
                            case 3:
                                let plateau = 0.04
                                if baseDrawdown <= plateau {
                                    drawdownRetentionMultiplier = 1
                                } else if nearPeakDeRiskDrawdownThreshold > plateau {
                                    drawdownRetentionMultiplier = min(max(
                                        (nearPeakDeRiskDrawdownThreshold - baseDrawdown)
                                            / (nearPeakDeRiskDrawdownThreshold - plateau),
                                        0
                                    ), 1)
                                } else {
                                    drawdownRetentionMultiplier = 0
                                }
                            default:
                                drawdownRetentionMultiplier = 1
                            }
                            let adjustedSeverityRetention = min(
                                max(
                                    severityRetention,
                                    max(nearPeakDeRiskMinimumRetention, 0)
                                ),
                                maximumRetention
                            ) * drawdownRetentionMultiplier
                            let severityRetainedGross = grossDrop
                                * adjustedSeverityRetention
                            let retainedGross: Double
                            switch nearPeakDeRiskCutBudgetMode {
                            case 1:
                                retainedGross = max(
                                    grossDrop - max(nearPeakDeRiskCutBudget, 0),
                                    0
                                ) * drawdownRetentionMultiplier
                            case 2:
                                retainedGross = max(
                                    grossDrop - priorGross * max(nearPeakDeRiskCutBudget, 0),
                                    0
                                ) * drawdownRetentionMultiplier
                            default:
                                retainedGross = severityRetainedGross
                            }
                            let effectiveRetention = grossDrop > 0
                                ? min(max(retainedGross / grossDrop, 0), 1)
                                : 0
                            let fraction = 1 - effectiveRetention
                            switch nearPeakDeRiskMode {
                            case 2:
                                if priorGross > 0, retainedGross > 0 {
                                    for (symbol, priorWeight) in previousWeights where priorWeight > 0 {
                                        pendingWeights[symbol, default: 0] += retainedGross
                                            * priorWeight / priorGross
                                    }
                                }
                            case 3:
                                if retainedGross > 0 {
                                    let priorLeader = leaderName(previousWeights)
                                    let leaderSale: Double
                                    switch priorLeader {
                                    case "china":
                                        let priorChina = (previousWeights["csi300"] ?? 0)
                                            + (previousWeights["shanghai_composite"] ?? 0)
                                        let targetChina = (pendingWeights["csi300"] ?? 0)
                                            + (pendingWeights["shanghai_composite"] ?? 0)
                                        leaderSale = max(priorChina - targetChina, 0)
                                    case "cash":
                                        leaderSale = 0
                                    default:
                                        leaderSale = max(
                                            (previousWeights[priorLeader] ?? 0)
                                                - (pendingWeights[priorLeader] ?? 0),
                                            0
                                        )
                                    }
                                    let effectiveRetainedGross = nearPeakDeRiskLeaderSaleCap > 0
                                        ? min(
                                            retainedGross,
                                            leaderSale * nearPeakDeRiskLeaderSaleCap
                                        )
                                        : retainedGross
                                    var createdBufferWeights: [String: Double] = [:]
                                    switch priorLeader {
                                    case "china":
                                        let priorCSI = previousWeights["csi300"] ?? 0
                                        let priorShanghai = previousWeights["shanghai_composite"] ?? 0
                                        let priorChina = priorCSI + priorShanghai
                                        if priorChina > 0 {
                                            createdBufferWeights["csi300"] = effectiveRetainedGross
                                                * priorCSI / priorChina
                                            createdBufferWeights["shanghai_composite"] = effectiveRetainedGross
                                                * priorShanghai / priorChina
                                        }
                                    case "cash":
                                        break
                                    default:
                                        createdBufferWeights[priorLeader] = effectiveRetainedGross
                                    }
                                    for (symbol, weight) in createdBufferWeights where weight > 0 {
                                        pendingWeights[symbol, default: 0] += weight
                                    }
                                    if deRiskBufferMode > 0, !createdBufferWeights.isEmpty {
                                        deRiskBufferLeader = priorLeader
                                        deRiskBufferWeights = createdBufferWeights
                                        deRiskBufferEntryIndex = signalIndex
                                        deRiskBufferBaseTargetGross = targetGross
                                        deRiskBufferEntryBaseValue = currentBaseValue
                                    }
                                }
                            case 9, 10, 11, 12, 13, 14:
                                if retainedGross > 0 {
                                    func oldLeaderBuffer() -> [String: Double] {
                                        let priorLeader = leaderName(previousWeights)
                                        switch priorLeader {
                                        case "china":
                                            let priorCSI = previousWeights["csi300"] ?? 0
                                            let priorShanghai = previousWeights["shanghai_composite"] ?? 0
                                            let priorChina = priorCSI + priorShanghai
                                            guard priorChina > 0 else { return [:] }
                                            return [
                                                "csi300": retainedGross * priorCSI / priorChina,
                                                "shanghai_composite": retainedGross * priorShanghai / priorChina,
                                            ]
                                        case "cash":
                                            return [:]
                                        default:
                                            return [priorLeader: retainedGross]
                                        }
                                    }

                                    func soldAssetBuffer(proRata: Bool) -> [String: Double] {
                                        let saleSymbols = Set(previousWeights.keys)
                                            .union(pendingWeights.keys)
                                        let sales = Dictionary(uniqueKeysWithValues: saleSymbols.compactMap { symbol -> (String, Double)? in
                                            let sale = max(
                                                (previousWeights[symbol] ?? 0)
                                                    - (pendingWeights[symbol] ?? 0),
                                                0
                                            )
                                            return sale > 0 ? (symbol, sale) : nil
                                        })
                                        let totalSales = sales.values.reduce(0, +)
                                        let effectiveRetainedGross = min(retainedGross, totalSales)
                                        guard effectiveRetainedGross > 0, totalSales > 0 else { return [:] }
                                        if proRata {
                                            return Dictionary(uniqueKeysWithValues: sales.map { symbol, sale in
                                                (symbol, effectiveRetainedGross * sale / totalSales)
                                            })
                                        }
                                        let priorLeader = leaderName(previousWeights)
                                        let leaderSymbols: Set<String> = priorLeader == "china"
                                            ? ["csi300", "shanghai_composite"]
                                            : [priorLeader]
                                        let leaderSales = sales.filter { leaderSymbols.contains($0.key) }
                                        let leaderSaleTotal = leaderSales.values.reduce(0, +)
                                        let leaderAllocation = min(
                                            effectiveRetainedGross,
                                            leaderSaleTotal
                                        )
                                        var result: [String: Double] = [:]
                                        if leaderAllocation > 0, leaderSaleTotal > 0 {
                                            for (symbol, sale) in leaderSales {
                                                result[symbol] = leaderAllocation * sale / leaderSaleTotal
                                            }
                                        }
                                        let remainingAllocation = effectiveRetainedGross - leaderAllocation
                                        let otherSales = sales.filter { !leaderSymbols.contains($0.key) }
                                        let otherSaleTotal = otherSales.values.reduce(0, +)
                                        if remainingAllocation > 0, otherSaleTotal > 0 {
                                            for (symbol, sale) in otherSales {
                                                result[symbol, default: 0] += remainingAllocation
                                                    * sale / otherSaleTotal
                                            }
                                        }
                                        return result
                                    }

                                    func volatilityRankedSoldAssetBuffer(
                                        inverseVolatility: Bool
                                    ) -> [String: Double] {
                                        let saleSymbols = Set(previousWeights.keys)
                                            .union(pendingWeights.keys)
                                        let sales = Dictionary(uniqueKeysWithValues: saleSymbols.compactMap { symbol -> (String, Double)? in
                                            let sale = max(
                                                (previousWeights[symbol] ?? 0)
                                                    - (pendingWeights[symbol] ?? 0),
                                                0
                                            )
                                            return sale > 0 ? (symbol, sale) : nil
                                        })
                                        let totalSales = sales.values.reduce(0, +)
                                        let effectiveRetainedGross = min(retainedGross, totalSales)
                                        guard effectiveRetainedGross > 0, totalSales > 0 else { return [:] }
                                        let rows = sales.map { symbol, sale -> (String, Double, Double) in
                                            let volatility = data.pricesBySymbol[symbol].flatMap {
                                                annualizedVolatilityAt(
                                                    values: $0,
                                                    at: signalIndex,
                                                    lookback: 63
                                                )
                                            } ?? 0.20
                                            return (symbol, sale, max(volatility, 0.03))
                                        }
                                        if !inverseVolatility {
                                            var remaining = effectiveRetainedGross
                                            var result: [String: Double] = [:]
                                            for row in rows.sorted(by: { lhs, rhs in
                                                if lhs.2 == rhs.2 { return lhs.0 < rhs.0 }
                                                return lhs.2 < rhs.2
                                            }) where remaining > 0 {
                                                let allocation = min(row.1, remaining)
                                                result[row.0] = allocation
                                                remaining -= allocation
                                            }
                                            return result
                                        }
                                        var remaining = effectiveRetainedGross
                                        var capacities = Dictionary(uniqueKeysWithValues: rows.map { ($0.0, $0.1) })
                                        let volatilities = Dictionary(uniqueKeysWithValues: rows.map { ($0.0, $0.2) })
                                        var result: [String: Double] = [:]
                                        while remaining > 0.0000001, !capacities.isEmpty {
                                            let scoreTotal = capacities.reduce(0.0) { partial, item in
                                                partial + item.value / max(volatilities[item.key] ?? 0.20, 0.03)
                                            }
                                            guard scoreTotal > 0 else { break }
                                            var distributed = 0.0
                                            var exhausted: [String] = []
                                            for (symbol, capacity) in capacities {
                                                let score = capacity / max(volatilities[symbol] ?? 0.20, 0.03)
                                                let proposed = remaining * score / scoreTotal
                                                let allocation = min(capacity, proposed)
                                                if allocation > 0 {
                                                    result[symbol, default: 0] += allocation
                                                    capacities[symbol] = max(capacity - allocation, 0)
                                                    distributed += allocation
                                                }
                                                if (capacities[symbol] ?? 0) <= 0.0000001 {
                                                    exhausted.append(symbol)
                                                }
                                            }
                                            for symbol in exhausted { capacities.removeValue(forKey: symbol) }
                                            if distributed <= 0.0000001 { break }
                                            remaining -= distributed
                                        }
                                        return result
                                    }

                                    let createdBufferWeights: [String: Double]
                                    if nearPeakDeRiskMode == 9 {
                                        createdBufferWeights = soldAssetBuffer(proRata: true)
                                    } else if nearPeakDeRiskMode == 10 {
                                        createdBufferWeights = soldAssetBuffer(proRata: false)
                                    } else if nearPeakDeRiskMode == 11 {
                                        createdBufferWeights = executionTurnover
                                            >= nearPeakDeRiskBroadUnwindTurnoverThreshold
                                            ? soldAssetBuffer(proRata: false)
                                            : oldLeaderBuffer()
                                    } else if nearPeakDeRiskMode == 13 {
                                        createdBufferWeights = volatilityRankedSoldAssetBuffer(
                                            inverseVolatility: false
                                        )
                                    } else if nearPeakDeRiskMode == 14 {
                                        createdBufferWeights = volatilityRankedSoldAssetBuffer(
                                            inverseVolatility: true
                                        )
                                    } else {
                                        let start = nearPeakDeRiskBlendTurnoverStart
                                        let end = max(nearPeakDeRiskBlendTurnoverEnd, start + 0.000001)
                                        let blend = min(max(
                                            (executionTurnover - start) / (end - start),
                                            0
                                        ), 1)
                                        let oldWeights = oldLeaderBuffer()
                                        let soldWeights = soldAssetBuffer(proRata: false)
                                        let blendSymbols = Set(oldWeights.keys).union(soldWeights.keys)
                                        createdBufferWeights = Dictionary(uniqueKeysWithValues: blendSymbols.map { symbol in
                                            let oldWeight = oldWeights[symbol] ?? 0
                                            let soldWeight = soldWeights[symbol] ?? 0
                                            return (symbol, (1 - blend) * oldWeight + blend * soldWeight)
                                        })
                                    }
                                    for (symbol, weight) in createdBufferWeights where weight > 0 {
                                        pendingWeights[symbol, default: 0] += weight
                                    }
                                }
                            default:
                                let deRiskSymbols = Set(previousWeights.keys)
                                    .union(pendingWeights.keys)
                                pendingWeights = Dictionary(uniqueKeysWithValues: deRiskSymbols.map { symbol in
                                    let prior = previousWeights[symbol] ?? 0
                                    let target = pendingWeights[symbol] ?? 0
                                    return (symbol, prior + fraction * (target - prior))
                                })
                            }
                            if deRiskCalibrationMode > 0,
                               retainedGross > 0,
                               priorScopeLeader != "cash" {
                                deRiskCalibrationTrials.append(
                                    OnlineLeadershipTrial(
                                        resolveIndex: signalIndex
                                            + max(deRiskCalibrationEvaluationSessions, 1),
                                        targetLeader: priorScopeLeader,
                                        priorLeader: "cash",
                                        startPrices: capturedPrices(
                                            pricesBySymbol: data.pricesBySymbol,
                                            at: signalIndex
                                        )
                                    )
                                )
                            }
                        }
                    }
                }

                let mediumExitConfirmationSessions = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_MEDIUM_EXIT_CONFIRM_SESSIONS"] ?? "1"
                ) ?? 1
                let mediumExitPriorGrossMinimum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_MEDIUM_EXIT_PRIOR_GROSS_MIN"] ?? "0.20"
                ) ?? 0.20
                let mediumExitPriorGrossMaximum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_MEDIUM_EXIT_PRIOR_GROSS_MAX"] ?? "0.80"
                ) ?? 0.80
                let mediumExitVolatilityMinimum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_MEDIUM_EXIT_VOL_MIN"] ?? "0.04"
                ) ?? 0.04
                let mediumExitVolatilityMaximum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_MEDIUM_EXIT_VOL_MAX"] ?? "0.08"
                ) ?? 0.08
                let mediumExitDrawdownMaximum = Double(
                    ProcessInfo.processInfo.environment["ATM_CC_MEDIUM_EXIT_DD_MAX"] ?? "0.02"
                ) ?? 0.02
                let mediumExitLeaderGate = Int(
                    ProcessInfo.processInfo.environment["ATM_CC_MEDIUM_EXIT_LEADER_GATE"] ?? "0"
                ) ?? 0
                if mediumExitConfirmationSessions > 1,
                   !previousWeights.isEmpty {
                    let currentExitTargetGross = pendingWeights.values.reduce(0, +)
                    let priorExitGross = previousWeights.values.reduce(0, +)
                    let priorExitLeader = leaderName(previousWeights)
                    let mediumExitLeaderAllowed = mediumExitLeaderGate == 0
                        || (mediumExitLeaderGate == 1 && priorExitLeader == "gold")
                        || (mediumExitLeaderGate == 2 && priorExitLeader == "nasdaq")
                        || (mediumExitLeaderGate == 3 && priorExitLeader == "sp500")
                        || (mediumExitLeaderGate == 4 && priorExitLeader == "china")
                        || (mediumExitLeaderGate == 5 && ["nasdaq", "sp500"].contains(priorExitLeader))
                    var qualifiesForExitConfirmation = false
                    if mediumExitLeaderAllowed,
                       currentExitTargetGross < 0.05,
                       priorExitGross >= mediumExitPriorGrossMinimum,
                       priorExitGross < mediumExitPriorGrossMaximum,
                       signalIndex >= 60,
                       alignedBaseValues.indices.contains(signalIndex),
                       let currentBaseValue = alignedBaseValues[signalIndex],
                       currentBaseValue > 0 {
                        let peakStart = max(0, signalIndex - 251)
                        let peakValue = alignedBaseValues[peakStart...signalIndex]
                            .compactMap { $0 }
                            .max() ?? currentBaseValue
                        let baseDrawdown = peakValue > 0 ? max(1 - currentBaseValue / peakValue, 0) : 0
                        var priorPortfolioReturns: [Double] = []
                        for cursor in (signalIndex - 59)...signalIndex {
                            guard cursor > 0 else { continue }
                            var dailyReturn = 0.0
                            var valid = true
                            for (symbol, weight) in previousWeights where weight > 0 {
                                guard let prices = data.pricesBySymbol[symbol],
                                      prices.indices.contains(cursor),
                                      prices[cursor - 1] > 0 else {
                                    valid = false
                                    break
                                }
                                dailyReturn += weight * (prices[cursor] / prices[cursor - 1] - 1)
                            }
                            if valid { priorPortfolioReturns.append(dailyReturn) }
                        }
                        if priorPortfolioReturns.count > 1 {
                            let mean = priorPortfolioReturns.reduce(0, +) / Double(priorPortfolioReturns.count)
                            let variance = priorPortfolioReturns.reduce(0.0) {
                                $0 + pow($1 - mean, 2)
                            } / Double(priorPortfolioReturns.count - 1)
                            let volatility = sqrt(max(variance, 0)) * sqrt(252)
                            qualifiesForExitConfirmation = baseDrawdown < mediumExitDrawdownMaximum
                                && volatility >= mediumExitVolatilityMinimum
                                && volatility < mediumExitVolatilityMaximum
                        }
                    }
                    if qualifiesForExitConfirmation {
                        mediumExitConfirmationStreak += 1
                        if mediumExitConfirmationStreak < mediumExitConfirmationSessions {
                            pendingWeights = previousWeights
                        }
                    } else {
                        mediumExitConfirmationStreak = 0
                    }
                } else if mediumExitConfirmationSessions <= 1 {
                    mediumExitConfirmationStreak = 0
                }

                if exitSentinelWeight > 0 {
                    let currentTargetGross = pendingWeights.values.reduce(0, +)
                    if !exitSentinelWeights.isEmpty {
                        if currentTargetGross >= 0.05 {
                            exitSentinelWeights = [:]
                            exitSentinelRemainingSessions = 0
                            exitSentinelEntryIndex = -1
                        } else if exitSentinelRemainingSessions > 0 {
                            for (symbol, weight) in exitSentinelWeights where weight > 0 {
                                pendingWeights[symbol, default: 0] += weight
                            }
                            exitSentinelRemainingSessions -= 1
                        } else {
                            exitSentinelWeights = [:]
                            exitSentinelEntryIndex = -1
                        }
                    }

                    let targetGrossAfterExistingSentinel = pendingWeights.values.reduce(0, +)
                    let priorGrossForExitSentinel = previousWeights.values.reduce(0, +)
                    if exitSentinelWeights.isEmpty,
                       baseTargetChanged,
                       targetGrossAfterExistingSentinel < 0.05,
                       priorGrossForExitSentinel >= max(exitSentinelPriorGrossMinimum, 0.05),
                       priorGrossForExitSentinel < exitSentinelPriorGrossMaximum,
                       signalIndex >= 0,
                       alignedBaseValues.indices.contains(signalIndex),
                       let currentBaseValue = alignedBaseValues[signalIndex],
                       currentBaseValue > 0 {
                        let peakStart = max(0, signalIndex - 251)
                        let peakValue = alignedBaseValues[peakStart...signalIndex]
                            .compactMap { $0 }
                            .max() ?? currentBaseValue
                        let baseDrawdown = peakValue > 0
                            ? max(1 - currentBaseValue / peakValue, 0)
                            : 0
                        var recentBaseReturns: [Double] = []
                        if signalIndex >= 60 {
                            for cursor in (signalIndex - 59)...signalIndex {
                                guard cursor > 0,
                                      let priorValue = alignedBaseValues[cursor - 1],
                                      let currentValue = alignedBaseValues[cursor],
                                      priorValue > 0 else { continue }
                                recentBaseReturns.append(currentValue / priorValue - 1)
                            }
                        }
                        let recentBaseVolatility: Double = {
                            guard recentBaseReturns.count > 1 else { return 0 }
                            let mean = recentBaseReturns.reduce(0, +)
                                / Double(recentBaseReturns.count)
                            let variance = recentBaseReturns.reduce(0.0) {
                                $0 + pow($1 - mean, 2)
                            } / Double(recentBaseReturns.count - 1)
                            return sqrt(max(variance, 0)) * sqrt(252)
                        }()
                        let volatilityAllows = recentBaseVolatility >= exitSentinelVolatilityMinimum
                            && recentBaseVolatility < exitSentinelVolatilityMaximum
                        let priorLeader = leaderName(previousWeights)
                        let leaderAllows: Bool
                        switch exitSentinelLeaderGate {
                        case 1:
                            leaderAllows = priorLeader == "gold"
                        case 2:
                            leaderAllows = priorLeader == "nasdaq"
                        case 3:
                            leaderAllows = priorLeader == "sp500"
                        case 4:
                            leaderAllows = priorLeader == "china"
                        case 5:
                            leaderAllows = priorLeader == "nasdaq" || priorLeader == "sp500"
                        default:
                            leaderAllows = true
                        }
                        if baseDrawdown < exitSentinelDrawdownThreshold,
                           volatilityAllows,
                           leaderAllows {
                            let sentinelGross = min(
                                max(exitSentinelWeight, 0),
                                priorGrossForExitSentinel
                            )
                            var createdSentinel: [String: Double] = [:]
                            if priorLeader == "china" {
                                let priorCSI = previousWeights["csi300"] ?? 0
                                let priorShanghai = previousWeights["shanghai_composite"] ?? 0
                                let priorChina = priorCSI + priorShanghai
                                if priorChina > 0 {
                                    createdSentinel["csi300"] = sentinelGross * priorCSI / priorChina
                                    createdSentinel["shanghai_composite"] = sentinelGross * priorShanghai / priorChina
                                }
                            } else if priorLeader != "cash" {
                                createdSentinel[priorLeader] = sentinelGross
                            }
                            for (symbol, weight) in createdSentinel where weight > 0 {
                                pendingWeights[symbol, default: 0] += weight
                            }
                            if !createdSentinel.isEmpty {
                                exitSentinelWeights = createdSentinel
                                exitSentinelRemainingSessions = max(
                                    exitSentinelConfirmationSessions - 1,
                                    0
                                )
                                exitSentinelEntryIndex = signalIndex
                            }
                        }
                    }
                } else {
                    exitSentinelWeights = [:]
                    exitSentinelRemainingSessions = 0
                    exitSentinelEntryIndex = -1
                }

                if buyConfirmationSessions > 1, !previousWeights.isEmpty {
                    let requiredSessions = max(buyConfirmationSessions, 1)
                    let confirmationSymbols = Set(previousWeights.keys)
                        .union(pendingWeights.keys)
                    pendingWeights = Dictionary(uniqueKeysWithValues: confirmationSymbols.map { symbol in
                        let prior = previousWeights[symbol] ?? 0
                        let target = pendingWeights[symbol] ?? 0
                        if target > prior + 0.000001 {
                            let streak = buyConfirmationStreaks[symbol, default: 0] + 1
                            buyConfirmationStreaks[symbol] = streak
                            return (symbol, streak >= requiredSessions ? target : prior)
                        }
                        buyConfirmationStreaks[symbol] = 0
                        return (symbol, target)
                    })
                } else if buyConfirmationSessions <= 1 {
                    buyConfirmationStreaks = [:]
                }

                let componentRebalanceActive: Bool = {
                    guard componentRebalanceVolatilityCeiling < 99 else { return true }
                    guard signalIndex >= 60 else { return false }
                    var returns: [Double] = []
                    for cursor in (signalIndex - 59)...signalIndex {
                        guard cursor > 0,
                              let prior = alignedBaseValues[cursor - 1],
                              let current = alignedBaseValues[cursor],
                              prior > 0 else { continue }
                        returns.append(current / prior - 1)
                    }
                    guard returns.count > 1 else { return false }
                    let mean = returns.reduce(0, +) / Double(returns.count)
                    let variance = returns.reduce(0.0) {
                        $0 + pow($1 - mean, 2)
                    } / Double(returns.count - 1)
                    let volatility = sqrt(max(variance, 0)) * sqrt(252)
                    return volatility <= componentRebalanceVolatilityCeiling
                }()

                if componentRebalanceMode > 0,
                   componentRebalanceBand > 0,
                   componentRebalanceActive,
                   !previousWeights.isEmpty {
                    let band = min(max(componentRebalanceBand, 0), 1)
                    let componentSymbols = Set(previousWeights.keys)
                        .union(pendingWeights.keys)
                    pendingWeights = Dictionary(uniqueKeysWithValues: componentSymbols.map { symbol in
                        let prior = previousWeights[symbol] ?? 0
                        let target = pendingWeights[symbol] ?? 0
                        let delta = target - prior
                        let adjusted: Double
                        switch componentRebalanceMode {
                        case 1:
                            adjusted = abs(delta) < band ? prior : target
                        case 2:
                            if delta > band {
                                adjusted = max(target - band, 0)
                            } else if delta < -band {
                                adjusted = max(target + band, 0)
                            } else {
                                adjusted = prior
                            }
                        case 3:
                            if delta > band {
                                adjusted = max(target - band, 0)
                            } else if delta < 0 {
                                adjusted = target
                            } else {
                                adjusted = prior
                            }
                        case 4:
                            let volatility = data.pricesBySymbol[symbol].flatMap {
                                annualizedVolatilityAt(
                                    values: $0,
                                    at: signalIndex,
                                    lookback: 63
                                )
                            } ?? 0.20
                            adjusted = abs(delta) * max(volatility, 0.05) < band
                                ? prior
                                : target
                        case 5:
                            let volatility = data.pricesBySymbol[symbol].flatMap {
                                annualizedVolatilityAt(
                                    values: $0,
                                    at: signalIndex,
                                    lookback: 63
                                )
                            } ?? 0.20
                            let weightBand = band / max(volatility, 0.05)
                            if delta > weightBand {
                                adjusted = max(target - weightBand, 0)
                            } else if delta < -weightBand {
                                adjusted = max(target + weightBand, 0)
                            } else {
                                adjusted = prior
                            }
                        default:
                            adjusted = target
                        }
                        return (symbol, adjusted)
                    })
                }''',
    )
    text = replace_once(
        text,
        '''                let symbols = Set(previousWeights.keys).union(pendingWeights.keys)
                let difference = symbols.reduce(0.0) {''',
        '''                if idleDualTrendSleeveCap > 0 {
                    let baseGross = pendingWeights.values.reduce(0, +)
                    if baseGross <= idleDualTrendBaseGrossMaximum,
                       signalIndex >= 252,
                       let goldPrices = data.pricesBySymbol["gold_cny"],
                       let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                       goldPrices.indices.contains(signalIndex),
                       nasdaqPrices.indices.contains(signalIndex) {
                        let reviewDue = idleDualTrendSleeveWeights.isEmpty
                            || signalIndex - idleDualTrendLastReviewIndex
                                >= max(idleDualTrendReviewSessions, 1)
                        if reviewDue,
                           let goldMA200 = movingAverageAt(
                            values: goldPrices,
                            at: signalIndex,
                            period: 200
                           ),
                           let nasdaqMA200 = movingAverageAt(
                            values: nasdaqPrices,
                            at: signalIndex,
                            period: 200
                           ),
                           let goldMomentum126 = priceMomentum(
                            values: goldPrices,
                            at: signalIndex,
                            lookback: 126
                           ),
                           let nasdaqMomentum126 = priceMomentum(
                            values: nasdaqPrices,
                            at: signalIndex,
                            lookback: 126
                           ),
                           let goldMomentum252 = priceMomentum(
                            values: goldPrices,
                            at: signalIndex,
                            lookback: 252
                           ),
                           let nasdaqMomentum252 = priceMomentum(
                            values: nasdaqPrices,
                            at: signalIndex,
                            lookback: 252
                           ) {
                            let goldStrong = goldPrices[signalIndex] > goldMA200
                                && goldMomentum126 > 0
                            let nasdaqStrong = nasdaqPrices[signalIndex] > nasdaqMA200
                                && nasdaqMomentum126 > 0
                            let goldWeak = goldPrices[signalIndex] < goldMA200
                                && goldMomentum252 < 0
                            let nasdaqWeak = nasdaqPrices[signalIndex] < nasdaqMA200
                                && nasdaqMomentum252 < 0
                            let goldScale = goldStrong ? 1.0 : (goldWeak ? 0.15 : 0.65)
                            let nasdaqScale = nasdaqStrong ? 1.0 : (nasdaqWeak ? 0.10 : 0.60)
                            let cap = min(max(idleDualTrendSleeveCap, 0), 1)
                            switch idleDualTrendSleeveMode {
                            case 1:
                                idleDualTrendSleeveWeights = [
                                    "gold_cny": goldStrong ? cap * 0.55 : 0,
                                    "nasdaq": nasdaqStrong ? cap * 0.45 : 0,
                                ]
                            case 2:
                                let goldScore = goldStrong ? 0.55 : 0
                                let nasdaqScore = nasdaqStrong ? 0.45 : 0
                                let denominator = goldScore + nasdaqScore
                                idleDualTrendSleeveWeights = denominator > 0
                                    ? [
                                        "gold_cny": cap * goldScore / denominator,
                                        "nasdaq": cap * nasdaqScore / denominator,
                                    ]
                                    : [:]
                            default:
                                idleDualTrendSleeveWeights = [
                                    "gold_cny": cap * 0.55 * goldScale,
                                    "nasdaq": cap * 0.45 * nasdaqScale,
                                ]
                            }
                            idleDualTrendLastReviewIndex = signalIndex
                        }
                        let sleeveGross = idleDualTrendSleeveWeights.values.reduce(0, +)
                        let availableGross = max(grossCap - baseGross, 0)
                        let sleeveScale = sleeveGross > 0
                            ? min(availableGross / sleeveGross, 1)
                            : 0
                        if sleeveScale > 0 {
                            for (symbol, weight) in idleDualTrendSleeveWeights where weight > 0 {
                                pendingWeights[symbol, default: 0] += weight * sleeveScale
                            }
                        }
                    } else {
                        idleDualTrendSleeveWeights = [:]
                    }
                } else {
                    idleDualTrendSleeveWeights = [:]
                }

                switch outputAssetAblationMode {
                case 1:
                    pendingWeights["csi300"] = 0
                    pendingWeights["shanghai_composite"] = 0
                case 2:
                    pendingWeights["sp500"] = 0
                case 3:
                    pendingWeights["nasdaq"] = 0
                case 4:
                    pendingWeights["gold_cny"] = 0
                default:
                    break
                }
                if outputSP500Scale < 1 {
                    pendingWeights["sp500"] = max(
                        (pendingWeights["sp500"] ?? 0) * max(outputSP500Scale, 0),
                        0
                    )
                }

                let symbols = Set(previousWeights.keys).union(pendingWeights.keys)
                let difference = symbols.reduce(0.0) {''',
    )

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8")
    print(f"assembled={output} bytes={len(text.encode('utf-8'))}")


if __name__ == "__main__":
    main()
