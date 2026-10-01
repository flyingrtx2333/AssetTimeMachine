import Foundation

nonisolated enum RegimeRouterStrategy {
    static func runRiskContributionRegimeRouterWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil
    ) -> ResearchTargetStrategyRun? {
        guard let stableRun = RiskContributionStrategy.runRiskContributionReallocationWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            parameters: .stable,
            strategySymbol: "risk_contribution_router_stable",
            strategyTitle: BacktestText.string("制度路由稳健引擎")
        ), let growthRun = RiskContributionStrategy.runRiskContributionReallocationWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            parameters: .growth,
            strategySymbol: "risk_contribution_router_growth",
            strategyTitle: BacktestText.string("制度路由进攻引擎")
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
        let tradeBand = 0.08
        let grossCap = 1.20
        let config = ResearchTargetStrategyConfig(
            symbol: "risk_contribution_regime_router",
            title: BacktestText.string("双引擎制度路由"),
            warmupSessions: 21,
            rebalanceSessions: 1,
            rebalanceBand: tradeBand,
            maxGrossExposure: grossCap,
            allowsFinancedExposure: true,
            financingAnnualRate: 0.05,
            buyReason: BacktestText.string("双引擎制度路由调仓")
        )

        var alignedStableValues: [Double?] = []
        var alignedGrowthValues: [Double?] = []
        var latestStableTarget: [String: Double] = [:]
        var latestGrowthTarget: [String: Double] = [:]
        var pendingWeights: [String: Double] = [:]
        var previousWeights: [String: Double] = [:]
        var growthActive = false
        var lastReviewIndex = -10_000

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

                var target = growthActive ? latestGrowthTarget : latestStableTarget
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
                    : stateChanged || difference > tradeBand
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
