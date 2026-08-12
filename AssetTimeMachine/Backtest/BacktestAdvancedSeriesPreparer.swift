import Foundation

nonisolated struct PreparedAdvancedSeries {
    let assetOption: BacktestAssetOption
    let pricePoints: [(date: Date, cnyPrice: Double)]
    let ohlcPoints: [(date: Date, open: Double, high: Double, low: Double, close: Double)]
    let ma20: [Double?]
    let ma60: [Double?]
    let boll20: [(middle: Double, lower: Double, upper: Double)?]
}

nonisolated enum BacktestAdvancedSeriesPreparer {
    static func preparedAdvancedSeries(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
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
                      let open = openPrices[index],
                      let high = highPrices[index],
                      let low = lowPrices[index],
                      let close = closePrices[index],
                      open.isFinite,
                      high.isFinite,
                      low.isFinite,
                      close.isFinite,
                      min(open, high, low, close) > 0,
                      low <= high,
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
            ohlcPoints: ohlcPoints,
            ma20: movingAverage(prices, 20),
            ma60: movingAverage(prices, 60),
            boll20: bollingerBands(prices, 20, 2)
        )
    }
}
