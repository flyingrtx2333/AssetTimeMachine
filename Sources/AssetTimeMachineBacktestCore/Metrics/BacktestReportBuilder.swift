import Foundation

nonisolated public enum BacktestReportBuilder {
    static func performanceMetrics(
        from points: [BacktestSeriesPoint],
        cashFlowsByDate: [Date: Double] = [:],
        cashFlowTiming: BacktestCashFlowTiming = .periodEnd
    ) -> BacktestPerformanceMetrics? {
        BacktestMetricsCalculator.performanceMetrics(
            from: points,
            cashFlowsByDate: cashFlowsByDate,
            cashFlowTiming: cashFlowTiming
        )
    }

    public static func exposurePoints(from dailyStates: [BacktestDailyState]) -> [BacktestExposurePoint] {
        dailyStates.enumerated().compactMap { sequence, state in
            guard state.portfolioValue.isFinite, state.portfolioValue > 0 else { return nil }
            let investedValue = state.holdingsBySymbol.values.reduce(0, +)
            let ratio = max(investedValue / state.portfolioValue, 0)
            guard ratio.isFinite else { return nil }
            return BacktestExposurePoint(date: state.date, ratio: ratio, sequence: sequence)
        }
    }

    public static func assetExposureSeries(
        from dailyStates: [BacktestDailyState],
        symbolOrder: [String],
        titlesBySymbol: [String: String]
    ) -> [BacktestAssetExposureSeries] {
        let heldSymbols = Set(dailyStates.flatMap { $0.holdingsBySymbol.keys })
        var seenSymbols: Set<String> = []
        let orderedSymbols = symbolOrder.filter {
            heldSymbols.contains($0) && seenSymbols.insert($0).inserted
        }
            + heldSymbols.subtracting(symbolOrder).sorted()

        return orderedSymbols.compactMap { symbol in
            let points = dailyStates.enumerated().compactMap { sequence, state -> BacktestExposurePoint? in
                guard state.portfolioValue.isFinite, state.portfolioValue > 0 else { return nil }
                let holdingValue = max(state.holdingsBySymbol[symbol] ?? 0, 0)
                let ratio = holdingValue / state.portfolioValue
                guard ratio.isFinite else { return nil }
                return BacktestExposurePoint(date: state.date, ratio: ratio, sequence: sequence)
            }
            guard points.contains(where: { $0.ratio > 0.000001 }) else { return nil }
            return BacktestAssetExposureSeries(
                symbol: symbol,
                title: titlesBySymbol[symbol] ?? symbol,
                points: BacktestExposureSampling.sampled(
                    points,
                    maxCount: BacktestExposureSampling.assetSeriesMaxCount
                )
            )
        }
    }

    /// Presents a continuous strategy run inside a user-selected measurement window.
    ///
    /// Stateful rotation strategies must see the history before the selected start
    /// date so their long lookbacks, holdings, and online calibration do not restart
    /// from an artificial cold state. The simulator therefore runs from the earliest
    /// available history, then this method trims and rebases every monetary surface
    /// to the requested initial value for display and metric calculation.

    public static func statefulAdvancedReport(
        from report: AdvancedBacktestReport,
        dailyStates: [BacktestDailyState],
        within bounds: ClosedRange<Date>,
        rebasedTo initialPortfolioValue: Double
    ) -> AdvancedBacktestReport? {
        let sourcePoints = report.points.filter { bounds.contains($0.date) }
        guard let sourceFirst = sourcePoints.first,
              sourceFirst.portfolioValue > 0,
              sourcePoints.count > 1 else { return nil }

        let normalizedInitialValue = max(initialPortfolioValue, 0)
        guard normalizedInitialValue > 0 else { return nil }
        let monetaryScale = normalizedInitialValue / sourceFirst.portfolioValue

        func scaledPoints(
            _ source: [BacktestSeriesPoint],
            scale: Double
        ) -> [BacktestSeriesPoint] {
            source.filter { bounds.contains($0.date) }
                .enumerated()
                .map { sequence, point in
                    BacktestSeriesPoint(
                        date: point.date,
                        portfolioValue: point.portfolioValue * scale,
                        sequence: sequence
                    )
                }
        }

        func rebasedPoints(
            _ source: [BacktestSeriesPoint],
            targetStartValue: Double
        ) -> [BacktestSeriesPoint] {
            let filtered = source.filter { bounds.contains($0.date) }
            guard let first = filtered.first, first.portfolioValue > 0 else { return [] }
            return filtered.enumerated().map { sequence, point in
                return BacktestSeriesPoint(
                    date: point.date,
                    portfolioValue: targetStartValue * point.portfolioValue / first.portfolioValue,
                    sequence: sequence
                )
            }
        }

        func scaledTrade(
            _ trade: AdvancedBacktestTrade,
            realizedStatisticsShare: Double = 1
        ) -> AdvancedBacktestTrade {
            let statisticsShare = min(max(realizedStatisticsShare, 0), 1)
            return AdvancedBacktestTrade(
                assetSymbol: trade.assetSymbol,
                assetTitle: trade.assetTitle,
                date: trade.date,
                action: trade.action,
                price: trade.price,
                cashAmount: trade.cashAmount * monetaryScale,
                units: trade.units * monetaryScale,
                reason: trade.reason,
                realizedProfit: statisticsShare > 0
                    ? trade.realizedProfit.map { $0 * monetaryScale * statisticsShare }
                    : nil,
                realizedReturn: statisticsShare > 0 ? trade.realizedReturn : nil,
                holdingDays: statisticsShare >= 0.999999 ? trade.holdingDays : nil
            )
        }

        let points = scaledPoints(sourcePoints, scale: monetaryScale)
        guard let lastPoint = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

        let benchmarkPoints = rebasedPoints(
            report.benchmarkPoints,
            targetStartValue: normalizedInitialValue
        )
        let benchmarkSeries = report.benchmarkSeries.map { series in
            AdvancedBacktestBenchmarkSeries(
                id: series.id,
                title: series.title,
                points: rebasedPoints(series.points, targetStartValue: normalizedInitialValue)
            )
        }
        let statesInRange = dailyStates.filter { bounds.contains($0.date) }
        let exposurePoints = exposurePoints(from: statesInRange)
        let exposureTitles = Dictionary(uniqueKeysWithValues: report.assetExposureSeries.map { ($0.symbol, $0.title) })
            .merging(
                Dictionary(uniqueKeysWithValues: report.benchmarkSeries.map { ($0.id, $0.title) }),
                uniquingKeysWith: { current, _ in current }
            )
        let trimmedAssetExposureSeries = assetExposureSeries(
            from: statesInRange,
            symbolOrder: report.assetExposureSeries.map(\.symbol) + report.benchmarkSeries.map(\.id),
            titlesBySymbol: exposureTitles
        )
        var inheritedUnitsBySymbol: [String: Double] = [:]
        // A slice is measured close-to-close. Trades on the lower-bound close
        // belong to the inherited opening state, not to the selected interval.
        for trade in report.trades where trade.date <= bounds.lowerBound {
            switch trade.action {
            case .buy:
                inheritedUnitsBySymbol[trade.assetSymbol, default: 0] += trade.units
            case .sell:
                inheritedUnitsBySymbol[trade.assetSymbol] = max(
                    (inheritedUnitsBySymbol[trade.assetSymbol] ?? 0) - trade.units,
                    0
                )
            }
        }
        var trades: [AdvancedBacktestTrade] = []
        for trade in report.trades where trade.date > bounds.lowerBound && trade.date <= bounds.upperBound {
            let inheritedUnits = inheritedUnitsBySymbol[trade.assetSymbol] ?? 0
            var statisticsShare = 1.0
            if trade.action == .sell,
               inheritedUnits > Double.leastNonzeroMagnitude,
               trade.units > 0 {
                let inheritedSold = min(inheritedUnits, trade.units)
                statisticsShare = max(trade.units - inheritedSold, 0) / trade.units
                inheritedUnitsBySymbol[trade.assetSymbol] = max(inheritedUnits - inheritedSold, 0)
            }
            trades.append(scaledTrade(trade, realizedStatisticsShare: statisticsShare))
        }

        let averageExposureRatio: Double = {
            let samples = statesInRange.compactMap { state -> Double? in
                guard state.portfolioValue > 0 else { return nil }
                let investedValue = state.holdingsBySymbol.values.reduce(0, +)
                return max(investedValue / state.portfolioValue, 0)
            }
            guard !samples.isEmpty else { return report.averageExposureRatio }
            return samples.reduce(0, +) / Double(samples.count)
        }()
        let averageCashRatio: Double = {
            let samples = statesInRange.compactMap { state -> Double? in
                guard state.portfolioValue > 0 else { return nil }
                return min(max(state.cash / state.portfolioValue, 0), 1)
            }
            guard !samples.isEmpty else { return report.cashYieldSummary.averageCashRatio }
            return samples.reduce(0, +) / Double(samples.count)
        }()

        let cashAccrualStates = Array(statesInRange.dropLast())
        let cashAccrualIntervals = zip(statesInRange.dropLast(), statesInRange.dropFirst())
        let totalCashInterest = cashAccrualIntervals.reduce(0.0) { partial, interval in
            let state = interval.0
            guard state.cash > 0 else { return partial }
            return partial + state.cash * CashYieldCNY.periodReturn(
                from: state.date,
                to: interval.1.date
            ) * monetaryScale
        }
        let averageAnnualRate = cashAccrualStates.isEmpty
            ? 0
            : CashYieldCNY.averageAnnualRate(across: cashAccrualStates.map(\.date))
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: totalCashInterest,
            averageCashRatio: averageCashRatio,
            averageAnnualRate: averageAnnualRate
        )

        let finalCash = (statesInRange.last?.cash ?? report.finalCash) * monetaryScale
        let assetReports = report.assetReports.map { assetReport in
            let assetPoints = scaledPoints(assetReport.points, scale: monetaryScale)
            let assetTrades = trades.filter { $0.assetSymbol == assetReport.symbol }
            return AdvancedBacktestAssetReport(
                symbol: assetReport.symbol,
                title: assetReport.title,
                points: assetPoints,
                benchmarkPoints: rebasedPoints(
                    assetReport.benchmarkPoints,
                    targetStartValue: normalizedInitialValue
                ),
                pricePoints: assetReport.pricePoints
                    .filter { bounds.contains($0.date) }
                    .enumerated()
                    .map { sequence, point in
                        AdvancedBacktestPricePoint(
                            date: point.date,
                            price: point.price,
                            sequence: sequence
                        )
                    },
                trades: assetTrades,
                finalPortfolioValue: assetPoints.last?.portfolioValue ?? lastPoint.portfolioValue,
                finalCash: report.assetReports.count == 1
                    ? finalCash
                    : assetReport.finalCash * monetaryScale,
                finalUnits: assetReport.finalUnits * monetaryScale,
                exposureRatio: report.assetReports.count == 1
                    ? averageExposureRatio
                    : assetReport.exposureRatio
            )
        }

        let riskSignalSummary: MarketRiskSignalSummary? = report.riskSignalSummary.flatMap { summary in
            if let summaryStart = summary.startDate,
               let summaryEnd = summary.endDate,
               bounds.lowerBound <= summaryStart,
               bounds.upperBound >= summaryEnd {
                return summary
            }
            let statisticsPoints = (summary.statisticsPoints ?? summary.signalPoints)
                .filter { bounds.contains($0.date) }
            guard !statisticsPoints.isEmpty else { return nil }
            let stressCount = statisticsPoints.filter {
                $0.level == .stress || $0.level == .shock
            }.count
            return MarketRiskSignalSummary(
                title: summary.title,
                source: summary.source,
                sourceDetail: summary.sourceDetail,
                startDate: statisticsPoints.first?.date,
                endDate: statisticsPoints.last?.date,
                latestPoint: statisticsPoints.last,
                averageScore: statisticsPoints.reduce(0) { $0 + $1.score } / Double(statisticsPoints.count),
                stressSessionRatio: Double(stressCount) / Double(statisticsPoints.count),
                signalPoints: evenlySampledItems(statisticsPoints, maxCount: 360),
                statisticsPoints: statisticsPoints
            )
        }

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: benchmarkPoints,
            benchmarkSeries: benchmarkSeries,
            trades: trades,
            assetReports: assetReports,
            finalPortfolioValue: lastPoint.portfolioValue,
            finalCash: finalCash,
            finalUnits: report.finalUnits * monetaryScale,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: riskSignalSummary,
            exposurePoints: exposurePoints,
            assetExposureSeries: trimmedAssetExposureSeries
        )
    }
}
