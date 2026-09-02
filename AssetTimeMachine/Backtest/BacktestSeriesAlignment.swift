import Foundation

nonisolated struct BacktestHistoricalPricePoint {
    let date: Date
    let price: Double
}

nonisolated struct BacktestHistoricalLookup {
    let points: [BacktestHistoricalPricePoint]

    nonisolated func point(onOrBefore targetDate: Date) -> BacktestHistoricalPricePoint? {
        guard !points.isEmpty else { return nil }

        var low = 0
        var high = points.count - 1
        var bestIndex: Int?

        while low <= high {
            let mid = (low + high) / 2
            if points[mid].date <= targetDate {
                bestIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard let bestIndex else { return nil }
        return points[bestIndex]
    }

    nonisolated func price(onOrBefore targetDate: Date) -> Double? {
        point(onOrBefore: targetDate)?.price
    }
}

nonisolated enum BacktestSeriesAlignment {
    static let hypotheticalDecisionSourceMarker = "atm-hypothetical-decision"
    static let historicalSeriesCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    static let maxForwardFillCalendarDays = 4

    static func historicalSeriesDateString(from date: Date) -> String {
        let components = historicalSeriesCalendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Strategy bars advance only when every started dependency has a real
    /// observation. This makes a 60-bar lookback mean 60 observations for every
    /// asset instead of mixing real returns with another venue's holiday fills.
    /// Explicit zero-fill symbols are ignored only before their own inception.
    static func rotationDecisionDates(
        from preparedSeries: [PreparedAdvancedSeries],
        zeroFillBeforeFirstSymbols: Set<String> = []
    ) -> [Date] {
        let eligibleSeries = preparedSeries.filter {
            !zeroFillBeforeFirstSymbols.contains($0.assetOption.symbol)
        }
        guard !eligibleSeries.isEmpty else { return [] }

        var commonDates = Set(eligibleSeries[0].executionObservationDates.filter(isStrategySessionDate))
        for series in eligibleSeries.dropFirst() {
            commonDates.formIntersection(series.executionObservationDates.filter(isStrategySessionDate))
        }

        for series in preparedSeries where zeroFillBeforeFirstSymbols.contains(series.assetOption.symbol) {
            let observedDates = Set(series.executionObservationDates.filter(isStrategySessionDate))
            guard let inception = observedDates.min() else { continue }
            commonDates = Set(commonDates.filter { $0 < inception || observedDates.contains($0) })
        }
        return commonDates.sorted()
    }

    /// The current product strategy universe contains exchange-traded weekday
    /// assets only. Weekend observations can remain available to display and
    /// crypto-specific features, but they are not valid strategy observations.
    static func isStrategySessionDate(_ date: Date) -> Bool {
        let weekday = historicalSeriesCalendar.component(.weekday, from: date)
        return weekday != 1 && weekday != 7
    }

    static func nextStrategyWeekday(after date: Date) -> Date {
        var candidate = historicalSeriesCalendar.date(byAdding: .day, value: 1, to: date)
            ?? date.addingTimeInterval(24 * 60 * 60)
        while !isStrategySessionDate(candidate) {
            candidate = historicalSeriesCalendar.date(byAdding: .day, value: 1, to: candidate)
                ?? candidate.addingTimeInterval(24 * 60 * 60)
        }
        return candidate
    }

    /// Adds a flat, explicitly hypothetical decision row. Callers must keep the
    /// resulting row out of executable/real-observation masks.
    static func appendingFlatDecisionSession(
        to series: PublicHistorySeries?,
        cutoff: Date,
        decisionDate: Date
    ) -> PublicHistorySeries? {
        guard let series,
              let firstDate = normalizedPricePoints(from: series).first?.date,
              let truncated = filteredHistorySeries(series, within: firstDate...cutoff),
              let lastPrice = truncated.prices.last,
              lastPrice.isFinite,
              lastPrice > 0 else { return nil }

        let dateText = historicalSeriesDateString(from: decisionDate)
        if truncated.dates.last == dateText { return truncated }

        func appended(_ values: [Double?]?, value: Double?) -> [Double?]? {
            guard var values else { return nil }
            values.append(value)
            return values
        }

        let lastClose = truncated.closePrices?.last.flatMap { $0 } ?? lastPrice
        let flatOHLC = lastClose.isFinite && lastClose > 0 ? lastClose : lastPrice
        return PublicHistorySeries(
            symbol: truncated.symbol,
            category: truncated.category,
            label: truncated.label,
            currency: truncated.currency,
            unit: truncated.unit,
            source: "\(truncated.source)|\(hypotheticalDecisionSourceMarker)",
            dates: truncated.dates + [dateText],
            prices: truncated.prices + [lastPrice],
            hasOHLC: truncated.hasOHLC,
            ohlcSource: truncated.ohlcSource,
            ohlcCoverageRatio: truncated.ohlcCoverageRatio,
            openPrices: appended(truncated.openPrices, value: flatOHLC),
            highPrices: appended(truncated.highPrices, value: flatOHLC),
            lowPrices: appended(truncated.lowPrices, value: flatOHLC),
            closePrices: appended(truncated.closePrices, value: flatOHLC),
            volumes: appended(truncated.volumes, value: nil)
        )
    }

    static func sanitizedDatePriceMap(from series: PublicHistorySeries?) -> [String: Double] {
        guard let series else { return [:] }

        var map: [String: Double] = [:]
        for (dateText, price) in zip(series.dates, series.prices) {
            guard historicalSeriesDate(from: dateText) != nil,
                  price.isFinite,
                  price > 0 else { continue }
            map[dateText] = price
        }

        return map
    }

    static func alignedDatePriceMaps(_ maps: [[String: Double]]) -> [(dateText: String, date: Date, prices: [Double])] {
        guard !maps.isEmpty else { return [] }

        let allDates = Set(maps.flatMap { $0.keys }).compactMap { dateText -> (String, Date)? in
            guard let date = historicalSeriesDate(from: dateText) else { return nil }
            return (dateText, date)
        }
        .sorted { $0.1 < $1.1 }

        var latestPrices = Array<Double?>(repeating: nil, count: maps.count)
        var latestPriceDates = Array<Date?>(repeating: nil, count: maps.count)
        var output: [(dateText: String, date: Date, prices: [Double])] = []

        for (dateText, date) in allDates {
            for index in maps.indices {
                if let price = maps[index][dateText] {
                    latestPrices[index] = price
                    latestPriceDates[index] = date
                }
            }

            var prices: [Double] = []
            var allFresh = true
            for index in maps.indices {
                guard let price = latestPrices[index],
                      let priceDate = latestPriceDates[index] else {
                    allFresh = false
                    break
                }
                let staleDays = historicalSeriesCalendar.dateComponents([.day], from: priceDate, to: date).day ?? Int.max
                guard staleDays <= maxForwardFillCalendarDays else {
                    allFresh = false
                    break
                }
                prices.append(price)
            }

            if allFresh {
                output.append((dateText: dateText, date: date, prices: prices))
            }
        }

        return output
    }

    static func normalizedPricePoints(from series: PublicHistorySeries?) -> [BacktestHistoricalPricePoint] {
        guard let series else { return [] }

        var priceByDate: [Date: Double] = [:]
        for (dateText, price) in zip(series.dates, series.prices) {
            guard let date = historicalSeriesDate(from: dateText),
                  price.isFinite,
                  price > 0 else { continue }
            priceByDate[date] = price
        }

        return priceByDate
            .map { BacktestHistoricalPricePoint(date: $0.key, price: $0.value) }
            .sorted { $0.date < $1.date }
    }

    static func filteredHistorySeries(_ series: PublicHistorySeries?, within bounds: ClosedRange<Date>? = nil) -> PublicHistorySeries? {
        guard let series else { return nil }

        var filteredRows: [(date: Date, index: Int, dateText: String, price: Double)] = []
        for index in series.dates.indices {
            if index.isMultiple(of: 256), Task.isCancelled { return nil }
            guard index < series.prices.count else { continue }
            let dateText = series.dates[index]
            let price = series.prices[index]
            guard let date = historicalSeriesDate(from: dateText),
                  price.isFinite,
                  price > 0 else { continue }
            if let bounds, (date < bounds.lowerBound || date > bounds.upperBound) {
                continue
            }
            filteredRows.append((date, index, dateText, price))
        }

        let sortedRows = filteredRows.sorted { $0.date < $1.date }
        guard sortedRows.count >= 2 else { return nil }

        func filteredOptionalValues(_ values: [Double?]?) -> [Double?]? {
            guard let values, values.count == series.dates.count else { return nil }
            return sortedRows.map { values[$0.index] }
        }

        let filteredOpenPrices = filteredOptionalValues(series.openPrices)
        let filteredHighPrices = filteredOptionalValues(series.highPrices)
        let filteredLowPrices = filteredOptionalValues(series.lowPrices)
        let filteredClosePrices = filteredOptionalValues(series.closePrices)
        let filteredVolumes = filteredOptionalValues(series.volumes)
        let filteredCoverageRatio: Double?
        let filteredHasOHLC: Bool?
        if let filteredOpenPrices,
           let filteredHighPrices,
           let filteredLowPrices,
           let filteredClosePrices {
            let coveredCount = sortedRows.indices.filter { index in
                filteredOpenPrices[index] != nil
                    && filteredHighPrices[index] != nil
                    && filteredLowPrices[index] != nil
                    && filteredClosePrices[index] != nil
            }.count
            filteredCoverageRatio = sortedRows.isEmpty ? 0 : Double(coveredCount) / Double(sortedRows.count)
            filteredHasOHLC = coveredCount > 0
        } else {
            filteredCoverageRatio = series.ohlcCoverageRatio
            filteredHasOHLC = series.hasOHLC
        }

        return PublicHistorySeries(
            symbol: series.symbol,
            category: series.category,
            label: series.label,
            currency: series.currency,
            unit: series.unit,
            source: series.source,
            dates: sortedRows.map(\.dateText),
            prices: sortedRows.map(\.price),
            hasOHLC: filteredHasOHLC,
            ohlcSource: series.ohlcSource,
            ohlcCoverageRatio: filteredCoverageRatio,
            openPrices: filteredOpenPrices,
            highPrices: filteredHighPrices,
            lowPrices: filteredLowPrices,
            closePrices: filteredClosePrices,
            volumes: filteredVolumes
        )
    }

    static func availableDateBounds(for seriesList: [PublicHistorySeries]) -> ClosedRange<Date>? {
        var lowerBound: Date?
        var upperBound: Date?
        for series in seriesList {
            let normalizedPoints = normalizedPricePoints(from: series)
            guard let firstDate = normalizedPoints.first?.date,
                  let lastDate = normalizedPoints.last?.date else {
                continue
            }
            lowerBound = lowerBound.map { max($0, firstDate) } ?? firstDate
            upperBound = upperBound.map { min($0, lastDate) } ?? lastDate
        }
        guard let lowerBound, let upperBound, lowerBound <= upperBound else { return nil }
        return lowerBound...upperBound
    }

    static func historicalSeriesDate(from text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = historicalSeriesCalendar
        components.timeZone = historicalSeriesCalendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = components.date else { return nil }
        let resolved = historicalSeriesCalendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day else { return nil }
        return date
    }

    static func makeHistoricalLookup(from series: PublicHistorySeries?) -> BacktestHistoricalLookup? {
        BacktestHistoricalLookup(points: normalizedPricePoints(from: series))
    }
}

extension Date {
    nonisolated var backtestDateString: String {
        BacktestSeriesAlignment.historicalSeriesDateString(from: self)
    }
}
