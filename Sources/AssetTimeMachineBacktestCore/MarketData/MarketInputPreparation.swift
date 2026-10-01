import Foundation

nonisolated public enum MarketInputPreparation {
    typealias HistoricalPricePoint = BacktestHistoricalPricePoint

    typealias HistoricalLookup = BacktestHistoricalLookup

    static func sanitizedDatePriceMap(from series: PublicHistorySeries?) -> [String: Double] {
        BacktestSeriesAlignment.sanitizedDatePriceMap(from: series)
    }

    static func alignedDatePriceMaps(_ maps: [[String: Double]]) -> [(dateText: String, date: Date, prices: [Double])] {
        BacktestSeriesAlignment.alignedDatePriceMaps(maps)
    }

    static func normalizedPricePoints(from series: PublicHistorySeries?) -> [HistoricalPricePoint] {
        BacktestSeriesAlignment.normalizedPricePoints(from: series)
    }

    public static func filteredHistorySeries(_ series: PublicHistorySeries?, within bounds: ClosedRange<Date>? = nil) -> PublicHistorySeries? {
        BacktestSeriesAlignment.filteredHistorySeries(series, within: bounds)
    }

    public static func advancedAssetInput(
        for option: BacktestInstrument,
        historyProvider: (String) -> PublicHistorySeries?
    ) -> (assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?) {
        if option.symbol == "usd_cash" {
            return (
                assetSeries: usdCashHistorySeries(from: historyProvider("usd_per_cny"), label: option.title),
                assetOption: option,
                fxSeries: nil
            )
        }

        return (
            assetSeries: historyProvider(option.symbol),
            assetOption: option,
            fxSeries: option.historicalFXSymbol.flatMap { historyProvider($0) }
        )
    }

    static func usdCashHistorySeries(from fxSeries: PublicHistorySeries?, label: String) -> PublicHistorySeries? {
        BacktestFXConverter.usdCashHistorySeries(from: fxSeries, label: label)
    }

    public static func filteredAdvancedAssetInputs(
        _ assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        within bounds: ClosedRange<Date>?
    ) -> [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)] {
        assetInputs.map { input in
            (
                assetSeries: filteredHistorySeries(input.assetSeries, within: bounds),
                assetOption: input.assetOption,
                fxSeries: filteredHistorySeries(input.fxSeries, within: bounds)
            )
        }
    }

    static func preparedAdvancedSeries(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestInstrument,
        fxSeries: PublicHistorySeries?
    ) -> PreparedAdvancedSeries? {
        BacktestAdvancedSeriesPreparer.preparedAdvancedSeries(
            assetSeries: assetSeries,
            assetOption: assetOption,
            fxSeries: fxSeries,
            movingAverage: { values, period in TechnicalIndicators.movingAverage(values: values, period: period) },
            bollingerBands: { values, period, multiplier in TechnicalIndicators.bollingerBands(values: values, period: period, multiplier: multiplier) }
        )
    }

    static func inputs(
        for mode: AdvancedBacktestStrategyMode,
        from assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)]
    ) -> [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)] {
        let required = Set(mode.requiredSignalAssetSymbols)
        return assetInputs.filter { required.contains($0.assetOption.symbol) }
    }

    public static func alignedRotationPriceSeries(
        from preparedSeries: [PreparedAdvancedSeries],
        zeroFillBeforeFirstSymbols: Set<String> = []
    ) -> AlignedRotationPriceSeries {
        let allDates = BacktestSeriesAlignment.rotationDecisionDates(
            from: preparedSeries,
            zeroFillBeforeFirstSymbols: zeroFillBeforeFirstSymbols
        )
        var indices = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, 0) })
        var latestPrices: [String: Double] = [:]
        var latestPriceDates: [String: Date] = [:]
        var outputDates: [Date] = []
        var pricesBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, [Double]()) })
        var observedBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, [Bool]()) })

        for date in allDates {
            if Task.isCancelled {
                return AlignedRotationPriceSeries(
                    dates: outputDates,
                    pricesBySymbol: pricesBySymbol,
                    observedBySymbol: observedBySymbol
                )
            }
            var observedSymbols = Set<String>()
            for series in preparedSeries {
                let symbol = series.assetOption.symbol
                var index = indices[symbol] ?? 0
                while index < series.pricePoints.count && series.pricePoints[index].date <= date {
                    let point = series.pricePoints[index]
                    if BacktestSeriesAlignment.isStrategySessionDate(point.date) {
                        latestPrices[symbol] = point.cnyPrice
                        latestPriceDates[symbol] = point.date
                        if point.date == date,
                           series.executionObservationDates.contains(date),
                           series.hypotheticalDecisionDate != date {
                            observedSymbols.insert(symbol)
                        }
                    }
                    index += 1
                }
                indices[symbol] = index
            }

            guard preparedSeries.allSatisfy({ series in
                let symbol = series.assetOption.symbol
                guard latestPrices[symbol] != nil,
                      let latestPriceDate = latestPriceDates[symbol] else {
                    return zeroFillBeforeFirstSymbols.contains(symbol)
                }
                let staleDays = historicalSeriesCalendar.dateComponents([.day], from: latestPriceDate, to: date).day ?? Int.max
                return staleDays <= maxForwardFillCalendarDays
            }) else { continue }
            outputDates.append(date)
            for series in preparedSeries {
                let symbol = series.assetOption.symbol
                pricesBySymbol[symbol, default: []].append(latestPrices[symbol] ?? 0)
                observedBySymbol[symbol, default: []].append(observedSymbols.contains(symbol))
            }
        }

        return AlignedRotationPriceSeries(
            dates: outputDates,
            pricesBySymbol: pricesBySymbol,
            observedBySymbol: observedBySymbol
        )
    }

    public static func availableDateBounds(for seriesList: [PublicHistorySeries]) -> ClosedRange<Date>? {
        BacktestSeriesAlignment.availableDateBounds(for: seriesList)
    }

    static func historicalSeriesDateStatic(from text: String) -> Date? {
        BacktestSeriesAlignment.historicalSeriesDate(from: text)
    }

    static let historicalSeriesCalendar = BacktestSeriesAlignment.historicalSeriesCalendar

    static let maxForwardFillCalendarDays = BacktestSeriesAlignment.maxForwardFillCalendarDays

    static func makeHistoricalLookup(from series: PublicHistorySeries?) -> HistoricalLookup? {
        BacktestSeriesAlignment.makeHistoricalLookup(from: series)
    }

    static func cnyPrice(
        for point: HistoricalPricePoint,
        assetOption: BacktestInstrument,
        fxLookup: HistoricalLookup?
    ) -> Double? {
        BacktestFXConverter.cnyPrice(for: point, assetOption: assetOption, fxLookup: fxLookup)
    }
}
