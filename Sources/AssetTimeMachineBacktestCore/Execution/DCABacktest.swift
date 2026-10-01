import Foundation

nonisolated public enum DCABacktest {
    public static func runDCA(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestInstrument,
        fxSeries: PublicHistorySeries?,
        contributionAmount: Double,
        intervalDays: Int
    ) -> DCABacktestReport? {
        guard let assetSeries else { return nil }
        let normalizedAmount = max(contributionAmount, 0)
        let normalizedInterval = max(intervalDays, 1)
        guard normalizedAmount > 0 else { return nil }

        let fxLookup: MarketInputPreparation.HistoricalLookup?
        if assetOption.requiresHistoricalFX {
            guard let lookup = MarketInputPreparation.makeHistoricalLookup(from: fxSeries), !lookup.points.isEmpty else { return nil }
            fxLookup = lookup
        } else {
            fxLookup = nil
        }

        let assetPricePoints = MarketInputPreparation.normalizedPricePoints(from: assetSeries)

        let pricePoints: [(date: Date, cnyPrice: Double)] = assetPricePoints.compactMap { point in
            guard let cnyPrice = MarketInputPreparation.cnyPrice(for: point, assetOption: assetOption, fxLookup: fxLookup) else { return nil }
            return (date: point.date, cnyPrice: cnyPrice)
        }

        guard let firstPoint = pricePoints.first, let lastPoint = pricePoints.last else { return nil }

        let calendar = BacktestSeriesAlignment.historicalSeriesCalendar
        var scheduledDate = firstPoint.date
        var nextContributionIndex: Int? = 0
        var unitsHeld = 0.0
        var totalInvested = 0.0
        var contributionCount = 0
        var points: [BacktestSeriesPoint] = []
        var cashFlowsByDate: [Date: Double] = [:]

        for (index, point) in pricePoints.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return nil }
            if nextContributionIndex == index {
                unitsHeld += normalizedAmount / point.cnyPrice
                totalInvested += normalizedAmount
                contributionCount += 1
                cashFlowsByDate[point.date, default: 0] += normalizedAmount

                if let nextScheduledDate = calendar.date(byAdding: .day, value: normalizedInterval, to: point.date),
                   nextScheduledDate <= lastPoint.date {
                    scheduledDate = nextScheduledDate
                    var cursor = index + 1
                    while cursor < pricePoints.count, pricePoints[cursor].date < scheduledDate {
                        cursor += 1
                    }
                    nextContributionIndex = cursor < pricePoints.count ? cursor : nil
                } else {
                    nextContributionIndex = nil
                }
            }

            guard unitsHeld > 0 else { continue }
            points.append(.init(date: point.date, portfolioValue: unitsHeld * point.cnyPrice, sequence: points.count))
        }

        guard let finalPoint = points.last, totalInvested > 0 else { return nil }
        let profitLoss = finalPoint.portfolioValue - totalInvested
        let metrics = BacktestReportBuilder.performanceMetrics(from: points, cashFlowsByDate: cashFlowsByDate, cashFlowTiming: .periodStart)
        return DCABacktestReport(
            points: points,
            totalInvested: totalInvested,
            finalPortfolioValue: finalPoint.portfolioValue,
            profitLoss: profitLoss,
            totalReturn: profitLoss / totalInvested,
            annualizedReturn: metrics?.annualizedReturn,
            maxDrawdown: metrics?.maxDrawdown ?? 0,
            annualizedVolatility: metrics?.annualizedVolatility,
            sharpeRatio: metrics?.sharpeRatio,
            contributionCount: contributionCount,
            totalUnits: unitsHeld
        )
    }
}
