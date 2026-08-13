import Foundation

nonisolated enum BacktestFXConverter {
    static let maximumForwardFillCalendarDays = 30

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
        guard let fxRate = validatedFXRate(on: point.date, fxLookup: fxLookup) else { return nil }
        if assetOption.historicalFXSymbol?.hasSuffix("_per_cny") == true {
            return point.price / fxRate
        }
        if fxRate < 1 {
            // Preserve the established operation order because threshold-based strategies
            // can legitimately react to sub-ULP differences around a signal boundary.
            return point.price / fxRate
        }
        if fxRate <= 20 {
            return point.price * fxRate
        }
        return nil
    }

    static func cnyMultiplier(
        on date: Date,
        assetOption: BacktestAssetOption,
        fxLookup: BacktestHistoricalLookup?
    ) -> Double? {
        guard assetOption.requiresHistoricalFX else { return 1 }
        guard let fxRate = validatedFXRate(on: date, fxLookup: fxLookup) else { return nil }
        if assetOption.historicalFXSymbol?.hasSuffix("_per_cny") == true {
            return 1 / fxRate
        }
        if fxRate < 1 {
            return 1 / fxRate
        }
        if fxRate <= 20 {
            return fxRate
        }
        return nil
    }

    private static func validatedFXRate(
        on date: Date,
        fxLookup: BacktestHistoricalLookup?
    ) -> Double? {
        guard let fxPoint = fxLookup?.point(onOrBefore: date),
              fxPoint.price.isFinite,
              fxPoint.price > 0 else { return nil }
        let staleDays = BacktestSeriesAlignment.historicalSeriesCalendar.dateComponents(
            [.day],
            from: fxPoint.date,
            to: date
        ).day ?? Int.max
        guard staleDays >= 0, staleDays <= maximumForwardFillCalendarDays else { return nil }
        return fxPoint.price
    }
}
