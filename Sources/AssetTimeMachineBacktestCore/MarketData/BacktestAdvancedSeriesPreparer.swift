import Foundation

nonisolated public struct PreparedAdvancedSeries {
    public let assetOption: BacktestInstrument
    public let pricePoints: [(date: Date, cnyPrice: Double)]
    public let executionObservationDates: Set<Date>
    public let ohlcPoints: [(date: Date, open: Double, high: Double, low: Double, close: Double)]
    public let hypotheticalDecisionDate: Date?
    public let ma20: [Double?]
    public let ma60: [Double?]
    public let boll20: [(middle: Double, lower: Double, upper: Double)?]
    public init(
        assetOption: BacktestInstrument,
        pricePoints: [(date: Date, cnyPrice: Double)],
        executionObservationDates: Set<Date>,
        ohlcPoints: [(date: Date, open: Double, high: Double, low: Double, close: Double)],
        hypotheticalDecisionDate: Date?,
        ma20: [Double?],
        ma60: [Double?],
        boll20: [(middle: Double, lower: Double, upper: Double)?]
    ) {
        self.assetOption = assetOption
        self.pricePoints = pricePoints
        self.executionObservationDates = executionObservationDates
        self.ohlcPoints = ohlcPoints
        self.hypotheticalDecisionDate = hypotheticalDecisionDate
        self.ma20 = ma20
        self.ma60 = ma60
        self.boll20 = boll20
    }
}


nonisolated public enum BacktestAdvancedSeriesPreparer {
    public static func preparedAdvancedSeries(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestInstrument,
        fxSeries: PublicHistorySeries?,
        movingAverage: ([Double], Int) -> [Double?],
        bollingerBands: ([Double], Int, Double) -> [(middle: Double, lower: Double, upper: Double)?]
    ) -> PreparedAdvancedSeries? {
        guard let assetSeries else { return nil }

        let fxLookup: BacktestHistoricalLookup?
        if assetOption.requiresHistoricalFX {
            guard let lookup = BacktestSeriesAlignment.makeHistoricalLookup(from: fxSeries), !lookup.points.isEmpty else { return nil }
            fxLookup = lookup
        } else {
            fxLookup = nil
        }

        let assetPricePoints = BacktestSeriesAlignment.normalizedPricePoints(from: assetSeries)
        let pricePoints: [(date: Date, cnyPrice: Double)] = assetPricePoints.compactMap { point in
            guard let cnyPrice = BacktestFXConverter.cnyPrice(for: point, assetOption: assetOption, fxLookup: fxLookup) else { return nil }
            return (date: point.date, cnyPrice: cnyPrice)
        }
        guard pricePoints.count >= 2 else { return nil }
        let executionObservationDates = Set(pricePoints.compactMap { point -> Date? in
            guard assetOption.requiresHistoricalFX else { return point.date }
            return BacktestFXConverter.hasSameSessionFXObservation(on: point.date, fxLookup: fxLookup)
                ? point.date
                : nil
        })

        let ohlcPoints: [(date: Date, open: Double, high: Double, low: Double, close: Double)]
        if let openPrices = assetSeries.openPrices,
           let highPrices = assetSeries.highPrices,
           let lowPrices = assetSeries.lowPrices,
           let closePrices = assetSeries.closePrices,
           openPrices.count == assetSeries.dates.count,
           highPrices.count == assetSeries.dates.count,
           lowPrices.count == assetSeries.dates.count,
           closePrices.count == assetSeries.dates.count {
            var rowsByDate: [Date: (open: Double, high: Double, low: Double, close: Double)] = [:]
            for index in assetSeries.dates.indices {
                guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: assetSeries.dates[index]),
                      index < assetSeries.prices.count,
                      assetSeries.prices[index].isFinite,
                      assetSeries.prices[index] > 0,
                      let open = openPrices[index],
                      let high = highPrices[index],
                      let low = lowPrices[index],
                      let close = closePrices[index],
                      open.isFinite,
                      high.isFinite,
                      low.isFinite,
                      close.isFinite,
                      min(open, high, low, close) > 0,
                      high >= max(open, close, low),
                      low <= min(open, close, high),
                      let cnyMultiplier = BacktestFXConverter.cnyMultiplier(
                        on: date,
                        assetOption: assetOption,
                        fxLookup: fxLookup
                      ) else { continue }
                rowsByDate[date] = (
                    open * cnyMultiplier,
                    high * cnyMultiplier,
                    low * cnyMultiplier,
                    close * cnyMultiplier
                )
            }
            ohlcPoints = rowsByDate
                .map { item in
                    (date: item.key, open: item.value.open, high: item.value.high, low: item.value.low, close: item.value.close)
                }
                .sorted { $0.date < $1.date }
        } else {
            ohlcPoints = []
        }

        let prices = pricePoints.map { $0.cnyPrice }
        return PreparedAdvancedSeries(
            assetOption: assetOption,
            pricePoints: pricePoints,
            executionObservationDates: executionObservationDates,
            ohlcPoints: ohlcPoints,
            hypotheticalDecisionDate: assetSeries.source.contains(BacktestSeriesAlignment.hypotheticalDecisionSourceMarker)
                ? pricePoints.last?.date
                : nil,
            ma20: movingAverage(prices, 20),
            ma60: movingAverage(prices, 60),
            boll20: bollingerBands(prices, 20, 2)
        )
    }
}
