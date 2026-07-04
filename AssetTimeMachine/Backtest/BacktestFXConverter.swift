import Foundation

nonisolated enum BacktestFXConverter {
    static func usdCashHistorySeries(from fxSeries: PublicHistorySeries?, label: String) -> PublicHistorySeries? {
        guard let fxSeries else { return nil }

        var dates: [String] = []
        var prices: [Double] = []
        for (dateText, rawPrice) in zip(fxSeries.dates, fxSeries.prices) {
            guard BacktestSeriesAlignment.historicalSeriesDate(from: dateText) != nil,
                  rawPrice.isFinite,
                  rawPrice > 0 else { continue }
            dates.append(dateText)
            prices.append(rawPrice < 1 ? 1 / rawPrice : rawPrice)
        }
        guard dates.count >= 2 else { return nil }

        return PublicHistorySeries(
            symbol: "usd_cash",
            category: "cash",
            label: label,
            currency: "CNY",
            unit: "USD",
            source: fxSeries.source,
            dates: dates,
            prices: prices,
            hasOHLC: false,
            ohlcSource: nil,
            ohlcCoverageRatio: nil,
            openPrices: nil,
            highPrices: nil,
            lowPrices: nil,
            closePrices: nil,
            volumes: nil
        )
    }

    static func cnyPrice(
        for point: BacktestHistoricalPricePoint,
        assetOption: BacktestAssetOption,
        fxLookup: BacktestHistoricalLookup?
    ) -> Double? {
        guard assetOption.requiresHistoricalFX else { return point.price }
        guard let fxRate = fxLookup?.price(onOrBefore: point.date), fxRate.isFinite, fxRate > 0 else { return nil }
        if fxRate < 1 {
            // Expected contract: USD per CNY, e.g. 0.14. USD asset price / (USD/CNY) = CNY price.
            return point.price / fxRate
        }
        if fxRate <= 20 {
            // Defensive fallback for common CNY per USD feeds, e.g. 7.2. USD asset price * (CNY/USD) = CNY price.
            return point.price * fxRate
        }
        return nil
    }
}
