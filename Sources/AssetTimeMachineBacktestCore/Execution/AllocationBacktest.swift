import Foundation

nonisolated public enum AllocationBacktest {
    public static func run(
        cashWeight: Double,
        goldWeight: Double,
        goldSeries: PublicHistorySeries?,
        indexWeights: [String: Double],
        indexSeriesBySymbol: [String: PublicHistorySeries]
    ) -> BacktestReport? {
        let normalizedCash = max(cashWeight, 0)
        let normalizedGold = max(goldWeight, 0)
        let normalizedIndices = indexWeights
            .mapValues { max($0, 0) }
            .filter { $0.value > 0 }
        let totalWeight = normalizedCash + normalizedGold + normalizedIndices.values.reduce(0, +)
        guard totalWeight > 0 else { return nil }

        let cw = normalizedCash / totalWeight
        let gw = normalizedGold / totalWeight
        let indexRatios = normalizedIndices.mapValues { $0 / totalWeight }

        if gw > 0, goldSeries == nil { return nil }
        for symbol in indexRatios.keys where indexSeriesBySymbol[symbol] == nil {
            return nil
        }

        let goldMap = MarketInputPreparation.sanitizedDatePriceMap(from: goldSeries)
        let indexMaps: [String: [String: Double]] = Dictionary(uniqueKeysWithValues: indexRatios.keys.compactMap { symbol in
            guard let series = indexSeriesBySymbol[symbol] else { return nil }
            let map = MarketInputPreparation.sanitizedDatePriceMap(from: series)
            guard !map.isEmpty else { return nil }
            return (symbol, map)
        })

        let orderedIndexSymbols = indexRatios.keys.sorted()
        let selectedMaps = (gw > 0 ? [goldMap] : []) + orderedIndexSymbols.compactMap { indexMaps[$0] }
        let alignedRows: [(dateText: String, date: Date, prices: [Double])]
        if selectedMaps.isEmpty {
            let fallbackDates = goldSeries?.dates
                ?? indexSeriesBySymbol.values.first(where: { !$0.dates.isEmpty })?.dates
                ?? []
            alignedRows = fallbackDates.compactMap { dateText in
                guard let date = MarketInputPreparation.historicalSeriesDateStatic(from: dateText) else { return nil }
                return (dateText: dateText, date: date, prices: [])
            }
        } else {
            alignedRows = MarketInputPreparation.alignedDatePriceMaps(selectedMaps)
        }
        guard alignedRows.count >= 2 else { return nil }

        let firstRow = alignedRows[0]
        let firstGold = gw > 0 ? firstRow.prices[0] : 1
        if gw > 0, firstGold <= 0 { return nil }

        var firstIndexPrices: [String: Double] = [:]
        let indexOffset = gw > 0 ? 1 : 0
        for (offset, symbol) in orderedIndexSymbols.enumerated() {
            let price = firstRow.prices[indexOffset + offset]
            guard price > 0 else { return nil }
            firstIndexPrices[symbol] = price
        }
        guard firstIndexPrices.count == indexRatios.count else { return nil }

        var points: [BacktestSeriesPoint] = []
        var returns: [Double] = []
        var previousValue: Double?
        var peakValue: Double = 1
        var peakDate: Date?
        var maxDrawdown: Double = 0
        var maxDrawdownPeakValue: Double?
        var maxDrawdownPeakDate: Date?

        for (rowIndex, row) in alignedRows.enumerated() {
            if rowIndex.isMultiple(of: 256), Task.isCancelled { return nil }
            let goldComponent: Double
            if gw > 0 {
                let goldPrice = row.prices[0]
                guard firstGold > 0 else { continue }
                goldComponent = gw * (goldPrice / firstGold)
            } else {
                goldComponent = 0
            }

            var indexComponent: Double = 0
            for (offset, symbol) in orderedIndexSymbols.enumerated() {
                let indexPrice = row.prices[indexOffset + offset]
                guard let weight = indexRatios[symbol],
                      let firstPrice = firstIndexPrices[symbol],
                      firstPrice > 0 else {
                    return nil
                }
                indexComponent += weight * (indexPrice / firstPrice)
            }

            let portfolioValue = cw + goldComponent + indexComponent
            points.append(.init(date: row.date, portfolioValue: portfolioValue, sequence: points.count))

            if let previousValue, previousValue > 0 {
                returns.append((portfolioValue / previousValue) - 1)
            }
            previousValue = portfolioValue

            if peakDate == nil || portfolioValue >= peakValue {
                peakValue = portfolioValue
                peakDate = row.date
            }

            if peakValue > 0 {
                let drawdown = (peakValue - portfolioValue) / peakValue
                if drawdown > maxDrawdown {
                    maxDrawdown = drawdown
                    maxDrawdownPeakValue = peakValue
                    maxDrawdownPeakDate = peakDate
                }
            }
        }

        guard let first = points.first, let last = points.last, first.portfolioValue > 0 else { return nil }
        let totalReturn = (last.portfolioValue / first.portfolioValue) - 1
        let daySpan = max(BacktestSeriesAlignment.historicalSeriesCalendar.dateComponents([.day], from: first.date, to: last.date).day ?? 0, 1)
        let years = Double(daySpan) / 365.25
        let annualizedReturn = years > 0 ? pow(last.portfolioValue / first.portfolioValue, 1 / years) - 1 : nil
        let observedPeriodsPerYear = years > 0 && !returns.isEmpty
            ? Double(returns.count) / years
            : 0

        let mean = returns.isEmpty ? nil : returns.reduce(0, +) / Double(returns.count)
        let variance = returns.count > 1 && mean != nil
            ? returns.reduce(0) { $0 + pow($1 - mean!, 2) } / Double(returns.count - 1)
            : nil
        let dailyVolatility = variance.map { sqrt($0) }
        let annualizedVolatility = dailyVolatility.flatMap {
            observedPeriodsPerYear > 0 ? $0 * sqrt(observedPeriodsPerYear) : nil
        }
        let sharpeRatio: Double?
        if let mean,
           let dailyVolatility,
           dailyVolatility > 0,
           observedPeriodsPerYear > 0 {
            sharpeRatio = mean / dailyVolatility * sqrt(observedPeriodsPerYear)
        } else {
            sharpeRatio = nil
        }

        let maxDrawdownRecoveryDays: Int?
        if maxDrawdown > 0,
           let maxDrawdownPeakValue,
           let maxDrawdownPeakDate,
           let recoveryPoint = points.first(where: { $0.date > maxDrawdownPeakDate && $0.portfolioValue >= maxDrawdownPeakValue }) {
            maxDrawdownRecoveryDays = BacktestSeriesAlignment.historicalSeriesCalendar.dateComponents([.day], from: maxDrawdownPeakDate, to: recoveryPoint.date).day
        } else {
            maxDrawdownRecoveryDays = nil
        }

        return BacktestReport(
            points: points,
            totalReturn: totalReturn,
            annualizedReturn: annualizedReturn,
            maxDrawdown: maxDrawdown,
            maxDrawdownRecoveryDays: maxDrawdownRecoveryDays,
            annualizedVolatility: annualizedVolatility,
            sharpeRatio: sharpeRatio
        )
    }
}
