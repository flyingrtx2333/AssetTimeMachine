import Foundation

nonisolated public enum RuleBasedOptimization {
    static func scoreAdvancedReport(_ report: AdvancedBacktestReport) -> Double {
        let annualized = report.annualizedReturn ?? report.totalReturn
        let sharpe = report.sharpeRatio ?? 0
        let excess = report.excessReturn ?? 0
        let tradePenalty = report.trades.count < 2 ? 0.35 : 0

        // This is an in-sample recency preference, not an out-of-sample validation score.
        var recentRegimeAdjustment = 0.0
        if report.points.count >= 90 {
            let recentCount = min(max(report.points.count / 3, 60), report.points.count - 1)
            let recentPoints = Array(report.points.suffix(recentCount))
            if let recentMetrics = BacktestReportBuilder.performanceMetrics(from: recentPoints) {
                let recentReturn = recentMetrics.totalReturn
                let recentDrawdown = recentMetrics.maxDrawdown
                recentRegimeAdjustment += max(recentReturn, 0) * 0.18
                recentRegimeAdjustment -= max(-recentReturn, 0) * 0.65
                recentRegimeAdjustment -= max(recentDrawdown - report.maxDrawdown, 0) * 0.35
            }
        }

        return annualized * 1.25
            + max(excess, 0) * 0.45
            + sharpe * 0.18
            + recentRegimeAdjustment
            - report.maxDrawdown * 1.2
            - tradePenalty
    }

    public static func optimizeAdvancedStrategy(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestInstrument,
        fxSeries: PublicHistorySeries?,
        initialCash: Double,
        baseSettings: AdvancedBacktestRiskSettings,
        limit: Int = 3
    ) -> [BacktestCoreCandidate] {
        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return [] }
        guard let preparedSeries = MarketInputPreparation.preparedAdvancedSeries(assetSeries: assetSeries, assetOption: assetOption, fxSeries: fxSeries) else { return [] }

        let maxCandidateCount = max(limit, 1)
        let buyDirections: [AdvancedBacktestSignalDirection] = [
            .alwaysBuy,
            .consecutiveDown,
            .priceAboveMA20,
            .priceAboveMA60,
            .priceCrossesAboveMA20,
            .priceCrossesAboveBollMiddle,
            .touchesBollLower,
            .ma20CrossesAboveMA60
        ]
        let sellDirections: [AdvancedBacktestSignalDirection] = [
            .neverSell,
            .consecutiveUp,
            .priceBelowMA20,
            .priceBelowMA60,
            .priceCrossesBelowMA20,
            .priceCrossesBelowBollMiddle,
            .touchesBollUpper,
            .ma20CrossesBelowMA60
        ]
        let dayThresholds = [2, 3, 5]
        let tradeAmounts = [
            normalizedInitialCash * 0.05,
            normalizedInitialCash * 0.10,
            normalizedInitialCash * 0.20
        ]
        let maxPositionRatios = Array(Set([baseSettings.maxPositionRatio, 35, 50, 70, 100]))
            .filter { $0 > 0 }
            .sorted()

        var topCandidates: [BacktestCoreCandidate] = []
        func retainIfTopCandidate(_ candidate: BacktestCoreCandidate) {
            if topCandidates.count < maxCandidateCount {
                topCandidates.append(candidate)
                topCandidates.sort { $0.score > $1.score }
                return
            }

            guard let weakestCandidate = topCandidates.last,
                  candidate.score > weakestCandidate.score else { return }
            topCandidates.removeLast()
            topCandidates.append(candidate)
            topCandidates.sort { $0.score > $1.score }
        }

        for buyDirection in buyDirections {
            for sellDirection in sellDirections {
                for buyDays in dayThresholds {
                    for sellDays in dayThresholds {
                        for tradeAmount in tradeAmounts {
                            for maxPositionRatio in maxPositionRatios {
                                if Task.isCancelled { return topCandidates }

                                var settings = baseSettings
                                settings.maxPositionRatio = maxPositionRatio
                                let buyRule = AdvancedBacktestRule(direction: buyDirection, days: buyDirection.usesDayThreshold ? buyDays : 1)
                                let sellRule = AdvancedBacktestRule(direction: sellDirection, days: sellDirection.usesDayThreshold ? sellDays : 1)
                                guard let report = RuleBasedStrategy.runAdvancedStrategy(
                                    preparedSeries: preparedSeries,
                                    initialCash: normalizedInitialCash,
                                    tradeAmount: tradeAmount,
                                    buyRule: buyRule,
                                    sellRule: sellRule,
                                    settings: settings
                                ), report.points.count > 20 else { continue }
                                retainIfTopCandidate(
                                    BacktestCoreCandidate(
                                        buyRule: buyRule,
                                        sellRule: sellRule,
                                        tradeAmount: tradeAmount,
                                        settings: settings,
                                        report: report,
                                        score: scoreAdvancedReport(report)
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        return topCandidates
    }

    public static func optimizeAdvancedStrategies(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        baseSettings: AdvancedBacktestRiskSettings,
        limit: Int = 3
    ) -> [BacktestCoreCandidate] {
        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return [] }

        let validInputs = assetInputs.filter { input in
            input.assetSeries != nil && (!input.assetOption.requiresHistoricalFX || input.fxSeries != nil)
        }
        guard !validInputs.isEmpty else { return [] }
        let preparedSeries = validInputs.compactMap { input in
            MarketInputPreparation.preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard !preparedSeries.isEmpty else { return [] }

        let maxCandidateCount = max(limit, 1)
        let buyDirections: [AdvancedBacktestSignalDirection] = [
            .alwaysBuy,
            .consecutiveDown,
            .priceAboveMA20,
            .priceAboveMA60,
            .priceCrossesAboveMA20,
            .priceCrossesAboveBollMiddle,
            .touchesBollLower,
            .ma20CrossesAboveMA60
        ]
        let sellDirections: [AdvancedBacktestSignalDirection] = [
            .neverSell,
            .consecutiveUp,
            .priceBelowMA20,
            .priceBelowMA60,
            .priceCrossesBelowMA20,
            .priceCrossesBelowBollMiddle,
            .touchesBollUpper,
            .ma20CrossesBelowMA60
        ]
        let dayThresholds = [2, 3, 5]
        let tradeAmounts = [
            normalizedInitialCash * 0.05,
            normalizedInitialCash * 0.10,
            normalizedInitialCash * 0.20
        ]
        let maxPositionRatios = Array(Set([baseSettings.maxPositionRatio, 35, 50, 70, 100]))
            .filter { $0 > 0 }
            .sorted()

        var topCandidates: [BacktestCoreCandidate] = []
        func retainIfTopCandidate(_ candidate: BacktestCoreCandidate) {
            if topCandidates.count < maxCandidateCount {
                topCandidates.append(candidate)
                topCandidates.sort { $0.score > $1.score }
                return
            }

            guard let weakestCandidate = topCandidates.last,
                  candidate.score > weakestCandidate.score else { return }
            topCandidates.removeLast()
            topCandidates.append(candidate)
            topCandidates.sort { $0.score > $1.score }
        }

        for buyDirection in buyDirections {
            for sellDirection in sellDirections {
                for buyDays in dayThresholds {
                    for sellDays in dayThresholds {
                        for tradeAmount in tradeAmounts {
                            for maxPositionRatio in maxPositionRatios {
                                if Task.isCancelled { return topCandidates }

                                var settings = baseSettings
                                settings.maxPositionRatio = maxPositionRatio
                                let buyRule = AdvancedBacktestRule(direction: buyDirection, days: buyDirection.usesDayThreshold ? buyDays : 1)
                                let sellRule = AdvancedBacktestRule(direction: sellDirection, days: sellDirection.usesDayThreshold ? sellDays : 1)
                                guard let report = RuleBasedStrategy.runAdvancedStrategies(
                                    preparedSeries: preparedSeries,
                                    initialCash: normalizedInitialCash,
                                    tradeAmount: tradeAmount,
                                    buyRule: buyRule,
                                    sellRule: sellRule,
                                    settings: settings
                                ), report.points.count > 20 else { continue }
                                retainIfTopCandidate(
                                    BacktestCoreCandidate(
                                        buyRule: buyRule,
                                        sellRule: sellRule,
                                        tradeAmount: tradeAmount,
                                        settings: settings,
                                        report: report,
                                        score: scoreAdvancedReport(report)
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        return topCandidates
    }
}
