import Foundation

nonisolated enum RiskContributionStrategy {
    struct RiskContributionReallocationParameters: Codable, Sendable {
        let sharpeShare: Double
        let riskShare: Double
        let dualShare: Double
        let highScale: Double
        let mediumScale: Double
        let grossCap: Double
        let reallocationRatio: Double
        let volatilityExponent: Double
        let correlationPenalty: Double
        let crossMarketHandoffIncreasePassThrough: Double

        static let stable = RiskContributionReallocationParameters(
            sharpeShare: 0.40,
            riskShare: 0.25,
            dualShare: 0.35,
            highScale: 1.40,
            mediumScale: 1.20,
            grossCap: 1.10,
            reallocationRatio: 0.60,
            volatilityExponent: 1.40,
            correlationPenalty: 1.75,
            crossMarketHandoffIncreasePassThrough: 0.50
        )

        static let growth = RiskContributionReallocationParameters(
            sharpeShare: 0.35,
            riskShare: 0.30,
            dualShare: 0.35,
            highScale: 1.60,
            mediumScale: 1.30,
            grossCap: 1.20,
            reallocationRatio: 1.00,
            volatilityExponent: 2.00,
            correlationPenalty: 3.00,
            crossMarketHandoffIncreasePassThrough: 0.50
        )

        static let recoveryStable = RiskContributionReallocationParameters(
            sharpeShare: 0.40,
            riskShare: 0.25,
            dualShare: 0.35,
            highScale: 1.40,
            mediumScale: 1.20,
            grossCap: 1.10,
            reallocationRatio: 0.60,
            volatilityExponent: 1.40,
            correlationPenalty: 1.75,
            crossMarketHandoffIncreasePassThrough: 0.26
        )

        static let recoveryGrowth = RiskContributionReallocationParameters(
            sharpeShare: 0.35,
            riskShare: 0.30,
            dualShare: 0.35,
            highScale: 1.60,
            mediumScale: 1.30,
            grossCap: 1.20,
            reallocationRatio: 1.00,
            volatilityExponent: 2.00,
            correlationPenalty: 3.00,
            crossMarketHandoffIncreasePassThrough: 0.26
        )
    }

    static func runRiskContributionReallocationWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil,
        parameters: RiskContributionReallocationParameters = .stable,
        strategySymbol: String = "risk_contribution_reallocation",
        strategyTitle: String? = nil
    ) -> ResearchTargetStrategyRun? {
        let sharpeMode = AdvancedBacktestStrategyMode.coreGoldSatelliteSharpeStateGateMomentum
        let riskMode = AdvancedBacktestStrategyMode.coreGoldSatelliteRiskBudgetStateGateMomentum
        let dualMode = AdvancedBacktestStrategyMode.goldNasdaqDualTrendBarbell
        let modes = [sharpeMode, riskMode, dualMode]
        let shares: [AdvancedBacktestStrategyMode: Double] = [
            sharpeMode: parameters.sharpeShare,
            riskMode: parameters.riskShare,
            dualMode: parameters.dualShare,
        ]
        let requiredSymbols = Set(modes.flatMap(\.requiredSignalAssetSymbols))
        let simulationInputs = assetInputs.filter { requiredSymbols.contains($0.assetOption.symbol) }

        var targetMaps: [AdvancedBacktestStrategyMode: [String: [String: Double]]] = [:]
        for mode in modes {
            guard let run = BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(
                assetInputs: MarketInputPreparation.inputs(for: mode, from: assetInputs),
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            targetMaps[mode] = Dictionary(uniqueKeysWithValues: run.dailyStates.map {
                ($0.date.backtestDateString, $0.targetWeights)
            })
        }

        let lookback = 126
        let reviewSessions = 42
        let riskContributionTrigger = 0.65
        let reallocationRatio = parameters.reallocationRatio
        let volatilityExponent = parameters.volatilityExponent
        let correlationPenalty = parameters.correlationPenalty
        let tradeBand = 0.08
        let usJumpBrakeMomentumLookback = 5
        let usJumpBrakeMinimumPreviousWeight = 0.10
        let usJumpBrakeMinimumIncrease = 0.10
        let usJumpBrakeMaximumIncrease = 0.20
        let usJumpBrakeIncreasePassThrough = 0.60
        let crossMarketHandoffMomentumLookback = 5
        let crossMarketHandoffMinimumUSIncrease = 0.05
        let crossMarketHandoffMaximumUSIncrease = 0.10
        let crossMarketHandoffMinimumChinaReduction = 0.15
        let crossMarketHandoffIncreasePassThrough = parameters.crossMarketHandoffIncreasePassThrough
        let config = ResearchTargetStrategyConfig(
            symbol: strategySymbol,
            title: strategyTitle ?? BacktestText.string("风险贡献再分配"),
            warmupSessions: 21,
            rebalanceSessions: 1,
            rebalanceBand: tradeBand,
            maxGrossExposure: parameters.grossCap,
            allowsFinancedExposure: true,
            financingAnnualRate: 0.05,
            buyReason: strategyTitle ?? BacktestText.string("风险贡献再分配调仓")
        )
        var latestTargets: [AdvancedBacktestStrategyMode: [String: Double]] = [:]
        var pendingWeights: [String: Double] = [:]
        var previousWeights: [String: Double] = [:]
        var lastReviewIndex = -10_000

        return TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
            assetInputs: simulationInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            rebalanceDecision: { index, signalIndex, data in
                guard data.dates.indices.contains(index),
                      data.dates.indices.contains(signalIndex),
                      signalIndex >= 20 else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                let executionKey = data.dates[index].backtestDateString
                var underlyingChanged = false
                for mode in modes {
                    if let weights = targetMaps[mode]?[executionKey] {
                        let oldWeights = latestTargets[mode] ?? [:]
                        let symbols = Set(oldWeights.keys).union(weights.keys)
                        let difference = symbols.reduce(0.0) {
                            $0 + abs((oldWeights[$1] ?? 0) - (weights[$1] ?? 0))
                        }
                        if difference > 0.0000001 { underlyingChanged = true }
                        latestTargets[mode] = weights
                    }
                }
                let scheduledReview = signalIndex - lastReviewIndex >= reviewSessions
                guard latestTargets.count == modes.count,
                      underlyingChanged || scheduledReview || previousWeights.isEmpty else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }
                lastReviewIndex = signalIndex

                var baseTarget: [String: Double] = [:]
                var modeGrosses: [Double] = []
                for mode in modes {
                    let weights = latestTargets[mode] ?? [:]
                    modeGrosses.append(weights.values.reduce(0, +))
                    let share = shares[mode] ?? 0
                    for (symbol, weight) in weights {
                        baseTarget[symbol, default: 0] += share * weight
                    }
                }

                let baseGross = baseTarget.values.reduce(0, +)
                let minimumModeGross = modeGrosses.min() ?? 0
                let scale: Double
                if baseGross >= 0.75, minimumModeGross >= 0.20 {
                    scale = parameters.highScale
                } else if baseGross >= 0.30 {
                    scale = parameters.mediumScale
                } else {
                    scale = 1.00
                }
                var target = baseTarget.mapValues { $0 * scale }

                let activeSymbols = target.keys.filter {
                    (target[$0] ?? 0) > 0.000001 && data.pricesBySymbol[$0] != nil
                }
                let effectiveLookback = min(lookback, signalIndex)
                var returnsBySymbol: [String: [Double]] = [:]
                var hasValidCovarianceData = activeSymbols.count >= 2
                if hasValidCovarianceData {
                    for symbol in activeSymbols {
                        guard let prices = data.pricesBySymbol[symbol],
                              prices.indices.contains(signalIndex - effectiveLookback),
                              prices.indices.contains(signalIndex) else {
                            hasValidCovarianceData = false
                            break
                        }
                        var returns: [Double] = []
                        returns.reserveCapacity(effectiveLookback)
                        for cursor in (signalIndex - effectiveLookback + 1)...signalIndex {
                            guard prices[cursor - 1] > 0, prices[cursor] > 0 else {
                                hasValidCovarianceData = false
                                break
                            }
                            returns.append(prices[cursor] / prices[cursor - 1] - 1)
                        }
                        if !hasValidCovarianceData { break }
                        returnsBySymbol[symbol] = returns
                    }
                }

                if hasValidCovarianceData {
                    var means: [String: Double] = [:]
                    var volatilities: [String: Double] = [:]
                    for symbol in activeSymbols {
                        let values = returnsBySymbol[symbol] ?? []
                        let mean = values.reduce(0, +) / Double(max(values.count, 1))
                        means[symbol] = mean
                        let variance = values.count > 1
                            ? values.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
                            : 0
                        volatilities[symbol] = sqrt(max(variance, 0)) * sqrt(252)
                    }

                    var covariance: [String: [String: Double]] = [:]
                    for lhs in activeSymbols {
                        var row: [String: Double] = [:]
                        for rhs in activeSymbols {
                            let lhsReturns = returnsBySymbol[lhs] ?? []
                            let rhsReturns = returnsBySymbol[rhs] ?? []
                            let count = min(lhsReturns.count, rhsReturns.count)
                            if count > 1 {
                                var sum = 0.0
                                for cursor in 0..<count {
                                    sum += (lhsReturns[cursor] - (means[lhs] ?? 0))
                                        * (rhsReturns[cursor] - (means[rhs] ?? 0))
                                }
                                row[rhs] = sum / Double(count - 1)
                            } else {
                                row[rhs] = 0
                            }
                        }
                        covariance[lhs] = row
                    }

                    var dailyVariance = 0.0
                    var marginalBySymbol: [String: Double] = [:]
                    for lhs in activeSymbols {
                        var marginal = 0.0
                        for rhs in activeSymbols {
                            marginal += (covariance[lhs]?[rhs] ?? 0) * (target[rhs] ?? 0)
                        }
                        marginalBySymbol[lhs] = marginal
                        dailyVariance += (target[lhs] ?? 0) * marginal
                    }

                    var maximumRiskContribution = 0.0
                    if dailyVariance > 0 {
                        for symbol in activeSymbols {
                            let contribution = (target[symbol] ?? 0)
                                * (marginalBySymbol[symbol] ?? 0)
                                / dailyVariance
                            maximumRiskContribution = max(maximumRiskContribution, contribution)
                        }
                    }

                    if maximumRiskContribution > riskContributionTrigger {
                        var adjustedRaw: [String: Double] = [:]
                        for symbol in activeSymbols {
                            let ownVolatility = max(volatilities[symbol] ?? 0, 0.03)
                            var positiveCorrelationSum = 0.0
                            var positiveCorrelationCount = 0
                            for other in activeSymbols where other != symbol {
                                let otherVolatility = max(volatilities[other] ?? 0, 0.03)
                                let dailyCovariance = covariance[symbol]?[other] ?? 0
                                let dailyVolatilityProduct = (ownVolatility / sqrt(252))
                                    * (otherVolatility / sqrt(252))
                                if dailyVolatilityProduct > 0 {
                                    let correlation = dailyCovariance / dailyVolatilityProduct
                                    if correlation > 0 {
                                        positiveCorrelationSum += min(correlation, 1)
                                        positiveCorrelationCount += 1
                                    }
                                }
                            }
                            let averagePositiveCorrelation = positiveCorrelationCount > 0
                                ? positiveCorrelationSum / Double(positiveCorrelationCount)
                                : 0
                            let diversificationPenalty = 1 + correlationPenalty * averagePositiveCorrelation
                            let adjustment = pow(ownVolatility, volatilityExponent)
                                * diversificationPenalty
                            adjustedRaw[symbol] = (target[symbol] ?? 0) / max(adjustment, 0.0001)
                        }

                        let targetGross = target.values.reduce(0, +)
                        let adjustedGross = adjustedRaw.values.reduce(0, +)
                        if adjustedGross > 0 {
                            for symbol in activeSymbols {
                                let riskBalancedWeight = (adjustedRaw[symbol] ?? 0)
                                    * targetGross / adjustedGross
                                target[symbol] = (1 - reallocationRatio) * (target[symbol] ?? 0)
                                    + reallocationRatio * riskBalancedWeight
                            }
                        }
                    }
                }

                let gross = target.values.reduce(0, +)
                if gross > parameters.grossCap, gross > 0 {
                    target = target.mapValues { $0 * parameters.grossCap / gross }
                }

                // T-1 jump brake: do not fully accelerate US-equity exposure when
                // both major indices have already turned down over the last week.
                // Normal increases, large regime resets, and all reductions remain untouched.
                let usSymbols: Set<String> = ["nasdaq", "sp500"]
                let previousUSWeight = previousWeights.reduce(0.0) {
                    $0 + (usSymbols.contains($1.key) ? $1.value : 0)
                }
                let proposedUSWeight = target.reduce(0.0) {
                    $0 + (usSymbols.contains($1.key) ? $1.value : 0)
                }
                let proposedUSIncrease = proposedUSWeight - previousUSWeight
                if previousUSWeight >= usJumpBrakeMinimumPreviousWeight,
                   proposedUSIncrease > usJumpBrakeMinimumIncrease,
                   proposedUSIncrease <= usJumpBrakeMaximumIncrease,
                   let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   let sp500Prices = data.pricesBySymbol["sp500"],
                   let nasdaqMomentum = TechnicalIndicators.priceMomentum(
                       values: nasdaqPrices,
                       at: signalIndex,
                       lookback: usJumpBrakeMomentumLookback
                   ),
                   let sp500Momentum = TechnicalIndicators.priceMomentum(
                       values: sp500Prices,
                       at: signalIndex,
                       lookback: usJumpBrakeMomentumLookback
                   ),
                   nasdaqMomentum <= 0,
                   sp500Momentum <= 0 {
                    let allowedUSWeight = previousUSWeight
                        + usJumpBrakeIncreasePassThrough * proposedUSIncrease
                    if proposedUSWeight > 0, allowedUSWeight < proposedUSWeight {
                        let scale = allowedUSWeight / proposedUSWeight
                        for symbol in usSymbols where target[symbol] != nil {
                            target[symbol] = (target[symbol] ?? 0) * scale
                        }
                    }
                }

                // T-1 cross-market handoff brake: when a large China-equity reduction
                // is immediately redirected into a moderate US-equity increase, require
                // short-term confirmation before executing the new US exposure in full.
                let chinaSymbols: Set<String> = ["csi300", "shanghai_composite"]
                let previousChinaWeight = previousWeights.reduce(0.0) {
                    $0 + (chinaSymbols.contains($1.key) ? $1.value : 0)
                }
                let proposedChinaWeight = target.reduce(0.0) {
                    $0 + (chinaSymbols.contains($1.key) ? $1.value : 0)
                }
                let chinaReduction = previousChinaWeight - proposedChinaWeight
                let handoffUSIncrease = proposedUSWeight - previousUSWeight
                if handoffUSIncrease > crossMarketHandoffMinimumUSIncrease,
                   handoffUSIncrease <= crossMarketHandoffMaximumUSIncrease,
                   chinaReduction >= crossMarketHandoffMinimumChinaReduction,
                   let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   let sp500Prices = data.pricesBySymbol["sp500"],
                   let nasdaqMomentum = TechnicalIndicators.priceMomentum(
                       values: nasdaqPrices,
                       at: signalIndex,
                       lookback: crossMarketHandoffMomentumLookback
                   ),
                   let sp500Momentum = TechnicalIndicators.priceMomentum(
                       values: sp500Prices,
                       at: signalIndex,
                       lookback: crossMarketHandoffMomentumLookback
                   ),
                   nasdaqMomentum <= 0 || sp500Momentum <= 0 {
                    let allowedUSWeight = previousUSWeight
                        + crossMarketHandoffIncreasePassThrough * handoffUSIncrease
                    if proposedUSWeight > 0, allowedUSWeight < proposedUSWeight {
                        let scale = allowedUSWeight / proposedUSWeight
                        for symbol in usSymbols where target[symbol] != nil {
                            target[symbol] = (target[symbol] ?? 0) * scale
                        }
                    }
                }

                let symbols = Set(previousWeights.keys).union(target.keys)
                let difference = symbols.reduce(0.0) {
                    $0 + abs((previousWeights[$1] ?? 0) - (target[$1] ?? 0))
                }
                pendingWeights = target
                let shouldRebalance = previousWeights.isEmpty
                    ? !target.isEmpty
                    : difference > tradeBand
                if shouldRebalance { previousWeights = target }
                return BacktestRebalanceDecision(
                    shouldRebalance: shouldRebalance,
                    refreshOverlay: false
                )
            },
            targetWeights: { _, _ in pendingWeights }
        )
    }

    static func runRiskContributionRecoveryBaseWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil,
        growthStateScale: Double = 1.082,
        fastBridgeRatio: Double = 0.185
    ) -> ResearchTargetStrategyRun? {
        guard let stableRun = runRiskContributionReallocationWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            parameters: .recoveryStable,
            strategySymbol: "risk_contribution_recovery_stable",
            strategyTitle: BacktestText.string("水下恢复稳健引擎")
        ), let growthRun = runRiskContributionReallocationWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            parameters: .recoveryGrowth,
            strategySymbol: "risk_contribution_recovery_growth",
            strategyTitle: BacktestText.string("水下恢复进攻引擎")
        ) else { return nil }

        let stableTargets = Dictionary(uniqueKeysWithValues: stableRun.dailyStates.map {
            ($0.date.backtestDateString, $0.targetWeights)
        })
        let growthTargets = Dictionary(uniqueKeysWithValues: growthRun.dailyStates.map {
            ($0.date.backtestDateString, $0.targetWeights)
        })
        let stableValues = Dictionary(uniqueKeysWithValues: stableRun.report.points.map {
            ($0.date.backtestDateString, $0.portfolioValue)
        })
        let growthValues = Dictionary(uniqueKeysWithValues: growthRun.report.points.map {
            ($0.date.backtestDateString, $0.portfolioValue)
        })

        let lookback = 252
        let reviewSessions = 63
        let entryRelativeReturn = 0.025
        let exitRelativeReturn = -0.03
        let growthTrendLookback = 63
        let exitTrendRatio = 0.97
        let growthBoostLookback = 28
        let growthBoostMaximumDrawdown = 0.015
        let growthBoostMarketMA = 120
        let growthBoostMarketMomentum = 60
        let fastBridgeHoldSessions = 12
        let fastBridgeCooldownSessions = 30
        let fastBridgeGrowthLookback = 10
        let fastBridgeGrowthMinimumReturn = 0.020
        let fastBridgeUSMomentum = 0.025
        let fastBridgeExitUSMomentum = -0.015
        let fastBridgeTradeBand = 0.015
        let tradeBand = 0.08
        let grossCap = 1.20
        let config = ResearchTargetStrategyConfig(
            symbol: "risk_contribution_recovery_base",
            title: BacktestText.string("水下恢复基础路由"),
            warmupSessions: 21,
            rebalanceSessions: 1,
            rebalanceBand: tradeBand,
            maxGrossExposure: grossCap,
            allowsFinancedExposure: true,
            financingAnnualRate: 0.05,
            buyReason: BacktestText.string("双引擎水下恢复调仓")
        )

        var alignedStableValues: [Double?] = []
        var alignedGrowthValues: [Double?] = []
        var latestStableTarget: [String: Double] = [:]
        var latestGrowthTarget: [String: Double] = [:]
        var pendingWeights: [String: Double] = [:]
        var previousWeights: [String: Double] = [:]
        var growthActive = false
        var lastReviewIndex = -10_000
        var fastBridgeUntilIndex = -10_000
        var fastBridgeLastEventIndex = -10_000
        var fastBridgeActive = false

        return TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            rebalanceDecision: { index, signalIndex, data in
                guard signalIndex >= 20,
                      data.dates.indices.contains(index),
                      data.dates.indices.contains(signalIndex) else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                if alignedStableValues.isEmpty {
                    var lastStableValue: Double?
                    var lastGrowthValue: Double?
                    for date in data.dates {
                        let key = date.backtestDateString
                        if let value = stableValues[key] { lastStableValue = value }
                        if let value = growthValues[key] { lastGrowthValue = value }
                        alignedStableValues.append(lastStableValue)
                        alignedGrowthValues.append(lastGrowthValue)
                    }
                }

                let executionKey = data.dates[index].backtestDateString
                if let weights = stableTargets[executionKey], !weights.isEmpty {
                    latestStableTarget = weights
                }
                if let weights = growthTargets[executionKey], !weights.isEmpty {
                    latestGrowthTarget = weights
                }
                guard !latestStableTarget.isEmpty, !latestGrowthTarget.isEmpty else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                var stateChanged = false
                if signalIndex >= lookback,
                   signalIndex - lastReviewIndex >= reviewSessions,
                   let stableNow = alignedStableValues[signalIndex],
                   let stableStart = alignedStableValues[signalIndex - lookback],
                   let growthNow = alignedGrowthValues[signalIndex],
                   let growthStart = alignedGrowthValues[signalIndex - lookback],
                   stableStart > 0,
                   growthStart > 0 {
                    let stableReturn = stableNow / stableStart - 1
                    let growthReturn = growthNow / growthStart - 1
                    let relativeReturn = growthReturn - stableReturn
                    let trendStart = max(0, signalIndex - growthTrendLookback + 1)
                    let growthWindow = alignedGrowthValues[trendStart...signalIndex].compactMap { $0 }
                    let growthAverage = growthWindow.isEmpty
                        ? growthNow
                        : growthWindow.reduce(0, +) / Double(growthWindow.count)
                    let previousState = growthActive

                    if !growthActive,
                       relativeReturn >= entryRelativeReturn,
                       growthNow >= growthAverage {
                        growthActive = true
                    } else if growthActive,
                              (relativeReturn <= exitRelativeReturn
                                || growthNow < growthAverage * exitTrendRatio) {
                        growthActive = false
                    }
                    stateChanged = growthActive != previousState
                    lastReviewIndex = signalIndex
                }

                let boostStartIndex = max(0, signalIndex - growthBoostLookback)
                let growthBoostWindow = alignedGrowthValues[boostStartIndex...signalIndex].compactMap { $0 }
                let growthCurrentValue = alignedGrowthValues[signalIndex] ?? 0
                let growthStartValue = alignedGrowthValues[boostStartIndex] ?? 0
                let growthBoostMomentum = growthStartValue > 0
                    ? growthCurrentValue / growthStartValue - 1
                    : -1
                let growthBoostPeak = growthBoostWindow.max() ?? growthCurrentValue
                let growthBoostDrawdown = growthBoostPeak > 0
                    ? 1 - growthCurrentValue / growthBoostPeak
                    : 1

                func marketTrendConfirmed(_ symbol: String) -> Bool {
                    guard let prices = data.pricesBySymbol[symbol],
                          prices.indices.contains(signalIndex),
                          signalIndex + 1 >= growthBoostMarketMA,
                          let momentum = TechnicalIndicators.priceMomentum(
                            values: prices,
                            at: signalIndex,
                            lookback: growthBoostMarketMomentum
                          ) else { return false }
                    let averageStart = signalIndex - growthBoostMarketMA + 1
                    let average = prices[averageStart...signalIndex].reduce(0, +)
                        / Double(growthBoostMarketMA)
                    return prices[signalIndex] >= average && momentum > 0
                }

                let marketBoostConfirmed = marketTrendConfirmed("nasdaq")
                    || marketTrendConfirmed("sp500")
                let growthBoostConfirmed = growthBoostMomentum > 0
                    && growthBoostDrawdown <= growthBoostMaximumDrawdown
                    && marketBoostConfirmed
                let effectiveGrowthScale = growthActive && growthBoostConfirmed
                    ? growthStateScale
                    : 1.0
                var target = growthActive
                    ? latestGrowthTarget.mapValues { $0 * effectiveGrowthScale }
                    : latestStableTarget

                var fastBridgeChanged = false
                if !growthActive {
                    let bridgeStartIndex = max(0, signalIndex - fastBridgeGrowthLookback)
                    let growthNow = alignedGrowthValues[signalIndex] ?? 0
                    let growthStart = alignedGrowthValues[bridgeStartIndex] ?? 0
                    let growthReturn = growthStart > 0 ? growthNow / growthStart - 1 : -1
                    let growthWindow = alignedGrowthValues[bridgeStartIndex...signalIndex].compactMap { $0 }
                    let growthPeak = growthWindow.max() ?? growthNow
                    let growthDrawdown = growthPeak > 0 ? 1 - growthNow / growthPeak : 1
                    let bridgeSymbols = ["nasdaq", "sp500", "csi300", "shanghai_composite"]
                    var validCount = 0
                    var positive10Count = 0
                    var aboveMA20Count = 0
                    var nasdaqM3 = 0.0
                    var nasdaqM10 = 0.0
                    var sp500M3 = 0.0
                    var sp500M10 = 0.0

                    for symbol in bridgeSymbols {
                        guard let prices = data.pricesBySymbol[symbol],
                              prices.indices.contains(signalIndex),
                              let m3 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 3),
                              let m10 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 10),
                              let ma20 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 20) else {
                            continue
                        }
                        validCount += 1
                        if m10 > 0 { positive10Count += 1 }
                        if prices[signalIndex] >= ma20 { aboveMA20Count += 1 }
                        if symbol == "nasdaq" {
                            nasdaqM3 = m3
                            nasdaqM10 = m10
                        } else if symbol == "sp500" {
                            sp500M3 = m3
                            sp500M10 = m10
                        }
                    }

                    let broadThrust = validCount >= 4
                        && positive10Count >= 3
                        && aboveMA20Count >= 3
                        && (nasdaqM10 >= fastBridgeUSMomentum
                            || sp500M10 >= fastBridgeUSMomentum)
                        && growthReturn >= fastBridgeGrowthMinimumReturn
                        && growthDrawdown <= 0.02
                    let fastBreak = nasdaqM3 <= fastBridgeExitUSMomentum
                        && sp500M3 <= fastBridgeExitUSMomentum
                    let cooldownElapsed = signalIndex - fastBridgeLastEventIndex
                        >= fastBridgeCooldownSessions
                    let previousBridgeState = fastBridgeActive

                    if !fastBridgeActive, broadThrust, cooldownElapsed {
                        fastBridgeActive = true
                        fastBridgeUntilIndex = signalIndex + fastBridgeHoldSessions
                        fastBridgeLastEventIndex = signalIndex
                    } else if fastBridgeActive,
                              (fastBreak || signalIndex >= fastBridgeUntilIndex) {
                        fastBridgeActive = false
                        fastBridgeLastEventIndex = signalIndex
                    }
                    fastBridgeChanged = fastBridgeActive != previousBridgeState
                } else if fastBridgeActive {
                    fastBridgeActive = false
                    fastBridgeChanged = true
                }

                if fastBridgeActive, !growthActive {
                    let symbols = Set(latestStableTarget.keys).union(latestGrowthTarget.keys)
                    target = Dictionary(uniqueKeysWithValues: symbols.map { symbol in
                        let stableWeight = latestStableTarget[symbol] ?? 0
                        let growthWeight = latestGrowthTarget[symbol] ?? 0
                        return (
                            symbol,
                            stableWeight * (1 - fastBridgeRatio) + growthWeight * fastBridgeRatio
                        )
                    })
                }

                let gross = target.values.reduce(0, +)
                if gross > grossCap, gross > 0 {
                    target = target.mapValues { $0 * grossCap / gross }
                }
                let symbols = Set(previousWeights.keys).union(target.keys)
                let difference = symbols.reduce(0.0) {
                    $0 + abs((previousWeights[$1] ?? 0) - (target[$1] ?? 0))
                }
                pendingWeights = target
                let shouldRebalance = previousWeights.isEmpty
                    ? !target.isEmpty
                    : stateChanged
                        || difference > tradeBand
                        || (fastBridgeChanged && difference > fastBridgeTradeBand)
                if shouldRebalance { previousWeights = target }
                return BacktestRebalanceDecision(
                    shouldRebalance: shouldRebalance,
                    refreshOverlay: false
                )
            },
            targetWeights: { _, _ in pendingWeights }
        )
    }

    struct RecoverySleeveQualityConfig: Codable, Sendable {
        let dynamicVolatilityThreshold: Double
        let dynamicSleeveCap: Double
        let momentumLookback: Int
        let momentumScale: Double
        let volatilityExponent: Double
        let downsideVolatilityBlend: Double
        let baseQualityExponent: Double
        let highQualityExponent: Double
        let qualityGapThreshold: Double
        let trendEfficiencyScale: Double

        static let cashConfidenceAdaptive = RecoverySleeveQualityConfig(
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
        )
    }

    static func runRiskContributionRecoveryRouterWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil,
        growthStateScale: Double = 1.082,
        fastBridgeRatio: Double = 0.185,
        sleeveCap: Double = 0.15,
        recoveryQualityConfig: RecoverySleeveQualityConfig? = nil,
        recoveryCooldownSessions: Int = 180,
        recoveryFastBreakThreshold: Double = -0.03
    ) -> ResearchTargetStrategyRun? {
        guard let baseRun = runRiskContributionRecoveryBaseWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            dateBounds: dateBounds,
            growthStateScale: growthStateScale,
            fastBridgeRatio: fastBridgeRatio
        ) else { return nil }

        let baseTargets = Dictionary(uniqueKeysWithValues: baseRun.dailyStates.map {
            ($0.date.backtestDateString, $0.targetWeights)
        })
        let baseValues = Dictionary(uniqueKeysWithValues: baseRun.report.points.map {
            ($0.date.backtestDateString, $0.portfolioValue)
        })
        let baseCashRatios = Dictionary(uniqueKeysWithValues: baseRun.dailyStates.map { state in
            let ratio = state.portfolioValue > 0 ? max(state.cash / state.portfolioValue, 0) : 0
            return (state.date.backtestDateString, ratio)
        })
        let baseGrosses = Dictionary(uniqueKeysWithValues: baseRun.dailyStates.map {
            ($0.date.backtestDateString, $0.targetWeights.values.reduce(0, +))
        })

        let minimumWaterDuration = 60
        let minimumDrawdown = 0.05
        let trendMA = 100
        let momentumLookback = 60
        let reviewSessions = 60
        let cooldownSessions = recoveryCooldownSessions
        let minimumHoldSessions = 10
        let maximumEntriesPerEpisode = 2
        let fastBreakThreshold = recoveryFastBreakThreshold
        let cashReserve = 0.05
        let grossCap = 1.20
        let tradeBand = 0.08
        let config = ResearchTargetStrategyConfig(
            symbol: "risk_contribution_recovery_router",
            title: BacktestText.string("双引擎水下恢复"),
            warmupSessions: 21,
            rebalanceSessions: 1,
            rebalanceBand: tradeBand,
            maxGrossExposure: grossCap,
            allowsFinancedExposure: true,
            financingAnnualRate: 0.05,
            buyReason: BacktestText.string("双引擎水下恢复调仓")
        )

        var alignedBaseValues: [Double?] = []
        var alignedCashRatios: [Double] = []
        var alignedBaseGrosses: [Double] = []
        var latestBaseTarget: [String: Double] = [:]
        var pendingWeights: [String: Double] = [:]
        var previousWeights: [String: Double] = [:]
        var recoveryWeights: [String: Double] = [:]
        var basePeakValue = 0.0
        var basePeakIndex = 0
        var recoveryActive = false
        var recoveryEnteredIndex = -10_000
        var lastRecoveryReviewIndex = -10_000
        var lastRecoveryExitIndex = -10_000
        var entriesThisEpisode = 0

        return TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            rebalanceDecision: { index, signalIndex, data in
                guard signalIndex >= max(trendMA, momentumLookback),
                      data.dates.indices.contains(index),
                      data.dates.indices.contains(signalIndex) else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                if alignedBaseValues.isEmpty {
                    var lastValue: Double?
                    var lastCashRatio = 0.0
                    var lastGross = 0.0
                    for date in data.dates {
                        let key = date.backtestDateString
                        if let value = baseValues[key] { lastValue = value }
                        if let value = baseCashRatios[key] { lastCashRatio = value }
                        if let value = baseGrosses[key] { lastGross = value }
                        alignedBaseValues.append(lastValue)
                        alignedCashRatios.append(lastCashRatio)
                        alignedBaseGrosses.append(lastGross)
                    }
                    basePeakValue = alignedBaseValues.compactMap { $0 }.first ?? initialCash
                }

                let executionKey = data.dates[index].backtestDateString
                var baseTargetChanged = false
                if let weights = baseTargets[executionKey], !weights.isEmpty {
                    baseTargetChanged = WeightMath.absoluteWeightDifference(latestBaseTarget, weights) > 0.0000001
                    latestBaseTarget = weights
                }
                guard !latestBaseTarget.isEmpty,
                      let baseValue = alignedBaseValues[signalIndex] else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                var recoveryChanged = false
                if baseValue >= basePeakValue {
                    basePeakValue = baseValue
                    basePeakIndex = signalIndex
                    entriesThisEpisode = 0
                    if recoveryActive || !recoveryWeights.isEmpty {
                        recoveryActive = false
                        recoveryWeights = [:]
                        recoveryChanged = true
                    }
                }
                let baseDrawdown = basePeakValue > 0 ? 1 - baseValue / basePeakValue : 0
                let waterDuration = signalIndex - basePeakIndex

                guard let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                      let sp500Prices = data.pricesBySymbol["sp500"],
                      nasdaqPrices.indices.contains(signalIndex),
                      sp500Prices.indices.contains(signalIndex),
                      let nasdaqMA = PortfolioIndicators.movingAverageAt(
                        values: nasdaqPrices,
                        at: signalIndex,
                        period: trendMA
                      ),
                      let sp500MA = PortfolioIndicators.movingAverageAt(
                        values: sp500Prices,
                        at: signalIndex,
                        period: trendMA
                      ) else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                let nasdaqMomentum = TechnicalIndicators.priceMomentum(
                    values: nasdaqPrices,
                    at: signalIndex,
                    lookback: momentumLookback
                ) ?? 0
                let sp500Momentum = TechnicalIndicators.priceMomentum(
                    values: sp500Prices,
                    at: signalIndex,
                    lookback: momentumLookback
                ) ?? 0
                let nasdaqPositive = nasdaqPrices[signalIndex] >= nasdaqMA
                    && nasdaqMomentum > 0
                let sp500Positive = sp500Prices[signalIndex] >= sp500MA
                    && sp500Momentum > 0
                let trendConfirmed = nasdaqPositive || sp500Positive

                if !recoveryActive,
                   entriesThisEpisode < maximumEntriesPerEpisode,
                   signalIndex - lastRecoveryExitIndex >= cooldownSessions,
                   waterDuration >= minimumWaterDuration,
                   baseDrawdown >= minimumDrawdown,
                   trendConfirmed {
                    recoveryActive = true
                    recoveryEnteredIndex = signalIndex
                    lastRecoveryReviewIndex = -10_000
                    entriesThisEpisode += 1
                    recoveryChanged = true
                }

                if recoveryActive,
                   signalIndex - lastRecoveryReviewIndex >= reviewSessions {
                    let availableCash = max(alignedCashRatios[index] - cashReserve, 0)
                    let availableGross = max(grossCap - alignedBaseGrosses[index], 0)
                    var effectiveSleeveCap = sleeveCap
                    if let recoveryQualityConfig, signalIndex >= 60 {
                        var recentBaseReturns: [Double] = []
                        recentBaseReturns.reserveCapacity(60)
                        for cursor in (signalIndex - 59)...signalIndex {
                            guard cursor > 0,
                                  let previousValue = alignedBaseValues[cursor - 1],
                                  let currentValue = alignedBaseValues[cursor],
                                  previousValue > 0 else { continue }
                            recentBaseReturns.append(currentValue / previousValue - 1)
                        }
                        if recentBaseReturns.count > 1 {
                            let mean = recentBaseReturns.reduce(0, +) / Double(recentBaseReturns.count)
                            let variance = recentBaseReturns.reduce(0.0) {
                                $0 + pow($1 - mean, 2)
                            } / Double(recentBaseReturns.count - 1)
                            let annualizedVolatility = sqrt(max(variance, 0)) * sqrt(252)
                            if annualizedVolatility >= recoveryQualityConfig.dynamicVolatilityThreshold {
                                effectiveSleeveCap = min(
                                    sleeveCap,
                                    recoveryQualityConfig.dynamicSleeveCap
                                )
                            }
                        }
                    }
                    let totalWeight = min(effectiveSleeveCap, availableCash, availableGross)

                    func recoveryTrendEfficiency(
                        prices: [Double],
                        lookback: Int
                    ) -> Double {
                        guard lookback > 0,
                              signalIndex >= lookback,
                              prices[signalIndex - lookback] > 0 else { return 0 }
                        var pathLength = 0.0
                        for cursor in (signalIndex - lookback + 1)...signalIndex {
                            guard prices[cursor - 1] > 0 else { continue }
                            pathLength += abs(prices[cursor] / prices[cursor - 1] - 1)
                        }
                        guard pathLength > 0 else { return 0 }
                        let netReturn = max(
                            prices[signalIndex] / prices[signalIndex - lookback] - 1,
                            0
                        )
                        return min(max(netReturn / pathLength, 0), 1)
                    }

                    func recoveryEffectiveVolatility(
                        prices: [Double],
                        totalVolatility: Double,
                        downsideBlend: Double
                    ) -> Double {
                        guard downsideBlend > 0, signalIndex >= 40 else {
                            return totalVolatility
                        }
                        var downsideSquares = 0.0
                        var observations = 0
                        for cursor in (signalIndex - 39)...signalIndex {
                            guard cursor > 0, prices[cursor - 1] > 0 else { continue }
                            let dailyReturn = prices[cursor] / prices[cursor - 1] - 1
                            downsideSquares += pow(min(dailyReturn, 0), 2)
                            observations += 1
                        }
                        guard observations > 1 else { return totalVolatility }
                        let downsideVolatility = sqrt(
                            downsideSquares / Double(observations)
                        ) * sqrt(252)
                        let blend = min(max(downsideBlend, 0), 1)
                        return (1 - blend) * totalVolatility
                            + blend * max(downsideVolatility, 0.03)
                    }

                    let nasdaqAllocationMomentum = recoveryQualityConfig.flatMap { config in
                        TechnicalIndicators.priceMomentum(
                            values: nasdaqPrices,
                            at: signalIndex,
                            lookback: config.momentumLookback
                        )
                    } ?? nasdaqMomentum
                    let sp500AllocationMomentum = recoveryQualityConfig.flatMap { config in
                        TechnicalIndicators.priceMomentum(
                            values: sp500Prices,
                            at: signalIndex,
                            lookback: config.momentumLookback
                        )
                    } ?? sp500Momentum
                    let nasdaqQualityMomentum = max(nasdaqAllocationMomentum, 0)
                    let sp500QualityMomentum = max(sp500AllocationMomentum, 0)
                    let qualityGap = abs(nasdaqQualityMomentum - sp500QualityMomentum)
                    let activeQualityExponent = recoveryQualityConfig.map { config in
                        qualityGap >= config.qualityGapThreshold
                            ? config.highQualityExponent
                            : config.baseQualityExponent
                    } ?? 1

                    var eligible: [(String, Double)] = []
                    if nasdaqPositive,
                       let volatility = PortfolioIndicators.annualizedVolatilityAt(
                        values: nasdaqPrices,
                        at: signalIndex,
                        lookback: 40
                       ) {
                        if let recoveryQualityConfig {
                            let effectiveVolatility = recoveryEffectiveVolatility(
                                prices: nasdaqPrices,
                                totalVolatility: volatility,
                                downsideBlend: recoveryQualityConfig.downsideVolatilityBlend
                            )
                            let trendEfficiency = recoveryTrendEfficiency(
                                prices: nasdaqPrices,
                                lookback: recoveryQualityConfig.momentumLookback
                            )
                            let qualityBase = max(
                                (1 + recoveryQualityConfig.momentumScale * nasdaqQualityMomentum)
                                    * (1 + recoveryQualityConfig.trendEfficiencyScale * trendEfficiency),
                                0.0001
                            )
                            let score = pow(
                                qualityBase,
                                max(activeQualityExponent, 0.05)
                            ) / pow(
                                max(effectiveVolatility, 0.05),
                                recoveryQualityConfig.volatilityExponent
                            )
                            eligible.append(("nasdaq", score))
                        } else {
                            eligible.append(("nasdaq", 1 / max(volatility, 0.05)))
                        }
                    }
                    if sp500Positive,
                       let volatility = PortfolioIndicators.annualizedVolatilityAt(
                        values: sp500Prices,
                        at: signalIndex,
                        lookback: 40
                       ) {
                        if let recoveryQualityConfig {
                            let effectiveVolatility = recoveryEffectiveVolatility(
                                prices: sp500Prices,
                                totalVolatility: volatility,
                                downsideBlend: recoveryQualityConfig.downsideVolatilityBlend
                            )
                            let trendEfficiency = recoveryTrendEfficiency(
                                prices: sp500Prices,
                                lookback: recoveryQualityConfig.momentumLookback
                            )
                            let qualityBase = max(
                                (1 + recoveryQualityConfig.momentumScale * sp500QualityMomentum)
                                    * (1 + recoveryQualityConfig.trendEfficiencyScale * trendEfficiency),
                                0.0001
                            )
                            let score = pow(
                                qualityBase,
                                max(activeQualityExponent, 0.05)
                            ) / pow(
                                max(effectiveVolatility, 0.05),
                                recoveryQualityConfig.volatilityExponent
                            )
                            eligible.append(("sp500", score))
                        } else {
                            eligible.append(("sp500", 1 / max(volatility, 0.05)))
                        }
                    }
                    var nextRecoveryWeights: [String: Double] = [:]
                    if totalWeight > 0, !eligible.isEmpty {
                        let denominator = eligible.reduce(0.0) { $0 + $1.1 }
                        for item in eligible {
                            nextRecoveryWeights[item.0] = denominator > 0
                                ? totalWeight * item.1 / denominator
                                : totalWeight / Double(eligible.count)
                        }
                    }
                    if nextRecoveryWeights != recoveryWeights {
                        recoveryChanged = true
                    }
                    recoveryWeights = nextRecoveryWeights
                    lastRecoveryReviewIndex = signalIndex
                }

                let nasdaqM3 = TechnicalIndicators.priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 3) ?? 0
                let sp500M3 = TechnicalIndicators.priceMomentum(values: sp500Prices, at: signalIndex, lookback: 3) ?? 0
                let fastBreak = nasdaqM3 <= fastBreakThreshold
                    && sp500M3 <= fastBreakThreshold
                let minimumHoldElapsed = signalIndex - recoveryEnteredIndex >= minimumHoldSessions
                if recoveryActive,
                   minimumHoldElapsed,
                   (!trendConfirmed || fastBreak) {
                    recoveryActive = false
                    recoveryWeights = [:]
                    lastRecoveryExitIndex = signalIndex
                    recoveryChanged = true
                }

                var target = latestBaseTarget
                for (symbol, weight) in recoveryWeights {
                    target[symbol, default: 0] += weight
                }
                let gross = target.values.reduce(0, +)
                if gross > grossCap, gross > 0 {
                    target = target.mapValues { $0 * grossCap / gross }
                }
                let symbols = Set(previousWeights.keys).union(target.keys)
                let difference = symbols.reduce(0.0) {
                    $0 + abs((previousWeights[$1] ?? 0) - (target[$1] ?? 0))
                }
                pendingWeights = target
                let shouldRebalance = previousWeights.isEmpty
                    ? !target.isEmpty
                    : baseTargetChanged || recoveryChanged || difference > tradeBand
                if shouldRebalance { previousWeights = target }
                return BacktestRebalanceDecision(
                    shouldRebalance: shouldRebalance,
                    refreshOverlay: false
                )
            },
            targetWeights: { _, _ in pendingWeights }
        )
    }
}
