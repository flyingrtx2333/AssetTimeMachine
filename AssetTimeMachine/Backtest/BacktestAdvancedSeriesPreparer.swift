import Foundation

nonisolated struct PreparedAdvancedSeries {
    let assetOption: BacktestAssetOption
    let pricePoints: [(date: Date, cnyPrice: Double)]
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

        let prices = pricePoints.map { $0.cnyPrice }
        return PreparedAdvancedSeries(
            assetOption: assetOption,
            pricePoints: pricePoints,
            ma20: movingAverage(prices, 20),
            ma60: movingAverage(prices, 60),
            boll20: bollingerBands(prices, 20, 2)
        )
    }
}
