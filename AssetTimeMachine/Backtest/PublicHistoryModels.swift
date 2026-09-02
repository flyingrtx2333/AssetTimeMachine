import Foundation

nonisolated struct MarketAssetDescriptor: Codable, Equatable, Identifiable, Sendable {
    let symbol: String
    let category: String
    let label: String
    let currency: String
    let unit: String
    let source: String?
    let logoURL: String?
    let logoSource: String?

    var id: String { symbol }

    init(
        symbol: String,
        category: String,
        label: String,
        currency: String,
        unit: String,
        source: String?,
        logoURL: String? = nil,
        logoSource: String? = nil
    ) {
        self.symbol = symbol
        self.category = category
        self.label = label
        self.currency = currency
        self.unit = unit
        self.source = source
        self.logoURL = logoURL
        self.logoSource = logoSource
    }

    enum CodingKeys: String, CodingKey {
        case symbol
        case category
        case label
        case currency
        case unit
        case source
        case logoURL = "logo_url"
        case logoSource = "logo_source"
    }
}

nonisolated struct MarketAssetCatalogResponse: Codable, Equatable, Sendable {
    let success: Bool
    let assets: [MarketAssetDescriptor]
}

nonisolated struct PublicHistoryDailyBar: Codable, Identifiable, Equatable, Sendable {
    let dateText: String
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?

    var id: String { dateText }
}

nonisolated struct PublicHistorySeries: Codable, Identifiable, Equatable, Sendable {
    let symbol: String
    let category: String
    let label: String
    let currency: String
    let unit: String
    let source: String
    let dates: [String]
    let prices: [Double]
    let hasOHLC: Bool?
    let ohlcSource: String?
    let ohlcCoverageRatio: Double?
    let openPrices: [Double?]?
    let highPrices: [Double?]?
    let lowPrices: [Double?]?
    let closePrices: [Double?]?
    let volumes: [Double?]?

    var id: String { symbol }

    var dailyBars: [PublicHistoryDailyBar] {
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        guard
            let openPrices,
            let highPrices,
            let lowPrices,
            let closePrices,
            !openPrices.isEmpty,
            dates.count == openPrices.count,
            dates.count == highPrices.count,
            dates.count == lowPrices.count,
            dates.count == closePrices.count
        else { return [] }

        return dates.indices.compactMap { index in
            guard
                let date = dayFormatter.date(from: dates[index]),
                let open = openPrices[index],
                let high = highPrices[index],
                let low = lowPrices[index],
                let close = closePrices[index],
                open.isFinite,
                high.isFinite,
                low.isFinite,
                close.isFinite,
                open > 0,
                high >= max(open, close, low),
                low <= min(open, close, high)
            else { return nil }

            let volume: Double?
            if let volumes, volumes.indices.contains(index), let rawVolume = volumes[index], rawVolume.isFinite, rawVolume >= 0 {
                volume = rawVolume
            } else {
                volume = nil
            }

            return PublicHistoryDailyBar(
                dateText: dates[index],
                date: date,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case symbol
        case category
        case label
        case currency
        case unit
        case source
        case dates
        case prices
        case hasOHLC = "has_ohlc"
        case ohlcSource = "ohlc_source"
        case ohlcCoverageRatio = "ohlc_coverage_ratio"
        case openPrices = "open_prices"
        case highPrices = "high_prices"
        case lowPrices = "low_prices"
        case closePrices = "close_prices"
        case volumes
    }
}

nonisolated struct PublicHistoryResponse: Codable, Equatable, Sendable {
    let success: Bool
    let series: [PublicHistorySeries]
    let availableSymbols: [String]?
    let catalog: [MarketAssetDescriptor]?

    enum CodingKeys: String, CodingKey {
        case success
        case series
        case availableSymbols = "available_symbols"
        case catalog
    }
}

nonisolated enum MarketHistorySeriesMerger {
    private struct Point {
        var price: Double
        var open: Double?
        var high: Double?
        var low: Double?
        var close: Double?
        var volume: Double?
    }

    static func merge(existing: PublicHistorySeries, incoming: PublicHistorySeries) -> PublicHistorySeries {
        var existingPoints: [String: Point] = [:]
        add(series: existing, to: &existingPoints, preservingMissingFields: false)
        var points = existingPoints
        add(series: incoming, to: &points, preservingMissingFields: true)

        let maximumMove: Double? = {
            let category = incoming.category.lowercased()
            if category == "index" { return 0.30 }
            if category == "fx" || incoming.symbol.lowercased().contains("_per_") { return 0.20 }
            if category == "gold" || incoming.symbol.lowercased() == "gold_cny" { return 0.20 }
            return nil
        }()
        var dates: [String] = []
        var mergedPoints: [Point] = []
        var previousAcceptedPrice: Double?
        for date in points.keys.sorted() {
            guard var point = points[date], point.price.isFinite, point.price > 0 else { continue }
            if let previousAcceptedPrice, let maximumMove,
               abs(point.price / previousAcceptedPrice - 1) > maximumMove {
                guard let fallback = existingPoints[date],
                      fallback.price.isFinite,
                      fallback.price > 0,
                      abs(fallback.price / previousAcceptedPrice - 1) <= maximumMove else {
                    continue
                }
                point = fallback
            }
            if let open = point.open,
               let high = point.high,
               let low = point.low,
               let close = point.close {
                let validGeometry = min(open, high, low, close) > 0
                    && high >= max(open, close, low)
                    && low <= min(open, close, high)
                let matchesPrimary = abs(close - point.price) / point.price <= 0.001
                if !validGeometry || !matchesPrimary {
                    point.open = nil
                    point.high = nil
                    point.low = nil
                    point.close = nil
                    point.volume = nil
                }
            }
            dates.append(date)
            mergedPoints.append(point)
            previousAcceptedPrice = point.price
        }
        let hasAnyOHLC = mergedPoints.contains {
            $0.open != nil || $0.high != nil || $0.low != nil || $0.close != nil
        }
        let hasAnyVolume = mergedPoints.contains { $0.volume != nil }
        let completeOHLCCount = mergedPoints.reduce(into: 0) { count, point in
            if point.open != nil, point.high != nil, point.low != nil, point.close != nil {
                count += 1
            }
        }

        return PublicHistorySeries(
            symbol: incoming.symbol,
            category: incoming.category,
            label: incoming.label,
            currency: incoming.currency,
            unit: incoming.unit,
            source: incoming.source.isEmpty ? existing.source : incoming.source,
            dates: dates,
            prices: mergedPoints.map(\.price),
            hasOHLC: completeOHLCCount > 0,
            ohlcSource: incoming.ohlcSource ?? existing.ohlcSource,
            ohlcCoverageRatio: hasAnyOHLC ? Double(completeOHLCCount) / Double(mergedPoints.count) : nil,
            openPrices: hasAnyOHLC ? mergedPoints.map(\.open) : nil,
            highPrices: hasAnyOHLC ? mergedPoints.map(\.high) : nil,
            lowPrices: hasAnyOHLC ? mergedPoints.map(\.low) : nil,
            closePrices: hasAnyOHLC ? mergedPoints.map(\.close) : nil,
            volumes: hasAnyVolume ? mergedPoints.map(\.volume) : nil
        )
    }

    private static func add(
        series: PublicHistorySeries,
        to points: inout [String: Point],
        preservingMissingFields: Bool
    ) {
        for index in series.dates.indices where series.prices.indices.contains(index) {
            let date = series.dates[index]
            let price = series.prices[index]
            guard BacktestSeriesAlignment.historicalSeriesDate(from: date) != nil,
                  price.isFinite,
                  price > 0 else { continue }
            let previous = preservingMissingFields ? points[date] : nil
            points[date] = Point(
                price: price,
                open: optionalValue(series.openPrices, at: index) ?? previous?.open,
                high: optionalValue(series.highPrices, at: index) ?? previous?.high,
                low: optionalValue(series.lowPrices, at: index) ?? previous?.low,
                close: optionalValue(series.closePrices, at: index) ?? previous?.close,
                volume: optionalValue(series.volumes, at: index) ?? previous?.volume
            )
        }
    }

    private static func optionalValue(_ values: [Double?]?, at index: Int) -> Double? {
        guard let values, values.indices.contains(index) else { return nil }
        return values[index]
    }
}

nonisolated enum MarketHistoryRefreshPlanner {
    static let fullHistoryStartDate = "2000-01-01"
    static let minimumCachedPoints = 30

    static func startDate(
        symbols: [String],
        seriesBySymbol: [String: PublicHistorySeries],
        overlapCalendarDays: Int = 45
    ) -> String {
        guard !symbols.isEmpty else { return fullHistoryStartDate }

        var lastDates: [Date] = []
        for symbol in symbols {
            guard
                let series = seriesBySymbol[symbol],
                series.dates.count >= minimumCachedPoints,
                let lastDateText = series.dates.last,
                let lastDate = parseDay(lastDateText)
            else {
                return fullHistoryStartDate
            }
            lastDates.append(lastDate)
        }

        guard
            let earliestLastDate = lastDates.min(),
            let overlapStart = calendar.date(
                byAdding: .day,
                value: -max(0, overlapCalendarDays),
                to: earliestLastDate
            ),
            let fullStart = parseDay(fullHistoryStartDate)
        else {
            return fullHistoryStartDate
        }
        return formatDay(max(overlapStart, fullStart))
    }

    static func symbolsNeedingRefresh(
        requestedSymbols: Set<String>,
        seriesBySymbol: [String: PublicHistorySeries],
        refreshedAtBySymbol: [String: Date],
        now: Date = Date(),
        refreshInterval: TimeInterval,
        force: Bool = false
    ) -> [String] {
        requestedSymbols.filter { symbol in
            if force { return true }
            guard
                let series = seriesBySymbol[symbol],
                series.dates.count >= minimumCachedPoints,
                series.prices.count >= minimumCachedPoints,
                let refreshedAt = refreshedAtBySymbol[symbol]
            else {
                return true
            }
            return now.timeIntervalSince(refreshedAt) >= refreshInterval
        }.sorted()
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func parseDay(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let requested = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: requested) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard
            resolved.year == requested.year,
            resolved.month == requested.month,
            resolved.day == requested.day
        else {
            return nil
        }
        return date
    }

    private static func formatDay(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
