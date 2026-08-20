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
