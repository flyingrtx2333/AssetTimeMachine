import Combine
import Foundation
import SwiftData
import SwiftUI

struct PublicMarketPrice: Codable, Identifiable {
    let success: Bool
    let symbol: String
    let price: Double
    let currency: String
    let unit: String
    let source: String
    let fetchedAt: Date
    let recordDate: String?

    var id: String { symbol }

    enum CodingKeys: String, CodingKey {
        case success
        case symbol
        case price
        case currency
        case unit
        case source
        case fetchedAt = "fetched_at"
        case recordDate = "record_date"
    }
}

struct PublicMarketOverview: Codable {
    let success: Bool
    let markets: [PublicMarketPrice]
    let updateIntervalHours: Int?

    enum CodingKeys: String, CodingKey {
        case success
        case markets
        case updateIntervalHours = "update_interval_hours"
    }
}

struct PublicExchangeRateItem: Codable, Identifiable {
    let currency: String
    let rate: Double

    var id: String { currency }
}

struct PublicExchangeRates: Codable {
    let success: Bool
    let baseCurrency: String
    let source: String
    let fetchedAt: Date
    let recordDate: String?
    let rates: [PublicExchangeRateItem]

    enum CodingKeys: String, CodingKey {
        case success
        case baseCurrency = "base_currency"
        case source
        case fetchedAt = "fetched_at"
        case recordDate = "record_date"
        case rates
    }
}

struct PublicHistorySeries: Codable, Identifiable {
    let symbol: String
    let category: String
    let label: String
    let currency: String
    let unit: String
    let source: String
    let dates: [String]
    let prices: [Double]

    var id: String { symbol }
}

struct PublicHistoryResponse: Codable {
    let success: Bool
    let series: [PublicHistorySeries]
}

struct MarketEndpointDoc: Identifiable {
    let title: String
    let path: String
    let description: String
    let symbol: String?

    var id: String { path }
}

enum RemoteMarketClient {
    static let baseURL = URL(string: "https://api.flyingrtx.com")!

    static let endpointDocs: [MarketEndpointDoc] = [
        .init(
            title: "黄金价格",
            path: "/api/v1/money/public/gold-price",
            description: "返回人民币计价的黄金单价，单位 gram。",
            symbol: "gold"
        ),
        .init(
            title: "纳指参考价格",
            path: "/api/v1/money/public/nasdaq-price",
            description: "返回统一口径的纳斯达克综合指数美元价格。",
            symbol: "nasdaq"
        ),
        .init(
            title: "行情概览",
            path: "/api/v1/money/public/market-overview",
            description: "汇总返回 gold、nasdaq 两个锚点。",
            symbol: nil
        ),
        .init(
            title: "公共历史走势",
            path: "/api/v1/money/public/history?symbols=nasdaq,sp500,hsi&period=1year",
            description: "统一返回指数、黄金、原油等公共历史序列，适合 App 直接消费。",
            symbol: nil
        ),
    ]

    static func fetchOverview() async throws -> PublicMarketOverview {
        let url = url(for: "/api/v1/money/public/market-overview")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder().decode(PublicMarketOverview.self, from: data)
    }

    static func fetchExchangeRates() async throws -> PublicExchangeRates {
        let url = url(for: "/api/v1/money/public/rmb-exchange-rates")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder().decode(PublicExchangeRates.self, from: data)
    }

    static func fetchHistory(symbols: [String], period: String? = nil, startDate: String? = nil, endDate: String? = nil) async throws -> PublicHistoryResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/money/public/history"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []

        if !symbols.isEmpty {
            queryItems.append(.init(name: "symbols", value: symbols.joined(separator: ",")))
        }
        if let period, !period.isEmpty {
            queryItems.append(.init(name: "period", value: period))
        }
        if let startDate, !startDate.isEmpty {
            queryItems.append(.init(name: "start_date", value: startDate))
        }
        if let endDate, !endDate.isEmpty {
            queryItems.append(.init(name: "end_date", value: endDate))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response, data: data)
        return try decoder().decode(PublicHistoryResponse.self, from: data)
    }

    static func url(for path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = fractionalISO8601DateFormatter.date(from: value) ?? iso8601DateFormatter.date(from: value) ?? localDateFormatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date format: \(value)")
        }
        return decoder
    }

    private static let fractionalISO8601DateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601DateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let localDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    fileprivate static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "RemoteMarketClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: body.isEmpty ? "接口请求失败" : body]
            )
        }
    }
}

@MainActor
final class RemoteMarketStore: ObservableObject {
    @Published var overview: PublicMarketOverview?
    @Published var exchangeRates: [String: Double] = [:]
    @Published var historySeries: [String: PublicHistorySeries] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let overview = try await RemoteMarketClient.fetchOverview()
            self.overview = overview
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        do {
            let exchangeRates = try await RemoteMarketClient.fetchExchangeRates()
            self.exchangeRates = Dictionary(uniqueKeysWithValues: exchangeRates.rates.map { ($0.currency.uppercased(), $0.rate) })
        } catch {
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
        }

        do {
            let historyBatches = [
                ["gold_cny", "nasdaq", "sp500"],
                ["hsi", "nikkei", "csi300", "shanghai_composite"],
                ["dowjones"]
            ]

            var mergedSeries: [PublicHistorySeries] = []
            for batch in historyBatches {
                if let response = try? await RemoteMarketClient.fetchHistory(symbols: batch, period: "all") {
                    mergedSeries.append(contentsOf: response.series)
                }
            }

            if !mergedSeries.isEmpty {
                self.historySeries = Dictionary(uniqueKeysWithValues: mergedSeries.map { (Self.normalizedHistorySymbol($0.symbol), $0) })
            } else if errorMessage == nil {
                errorMessage = "历史数据加载失败"
            }
        }
    }

    private static func normalizedHistorySymbol(_ symbol: String) -> String {
        switch symbol {
        case "nasdaq_composite":
            return "nasdaq"
        default:
            return symbol
        }
    }

    func market(for symbol: String) -> PublicMarketPrice? {
        overview?.markets.first(where: { $0.symbol == symbol })
    }

    func exchangeRate(for currency: String) -> Double? {
        exchangeRates[currency.uppercased()]
    }

    func history(for symbol: String) -> PublicHistorySeries? {
        historySeries[symbol]
    }
}

private struct HistoricalAnchorPoint {
    let day: Date
    let price: Double
}

private struct HistoricalSeries {
    let pointsByDay: [Date: HistoricalAnchorPoint]
    let sortedDays: [Date]

    init(points: [HistoricalAnchorPoint]) {
        let normalized = points.sorted { $0.day < $1.day }
        self.pointsByDay = Dictionary(uniqueKeysWithValues: normalized.map { ($0.day, $0) })
        self.sortedDays = normalized.map(\.day)
    }

    func point(onOrBefore targetDay: Date) -> HistoricalAnchorPoint? {
        guard !sortedDays.isEmpty else { return nil }
        var low = 0
        var high = sortedDays.count - 1
        var bestIndex: Int?

        while low <= high {
            let mid = (low + high) / 2
            let day = sortedDays[mid]
            if day <= targetDay {
                bestIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard let bestIndex else { return nil }
        return pointsByDay[sortedDays[bestIndex]]
    }
}

private struct HistoricalAnchorBundle {
    let goldCNY: HistoricalSeries
    let btcUSD: HistoricalSeries
    let nasdaqUSD: HistoricalSeries
    let usdPerCNY: HistoricalSeries
}

private enum MarketDay {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let nasdaqFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter
    }()

    static func start(of date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func string(from date: Date) -> String {
        dayFormatter.string(from: start(of: date))
    }

    static func parse(_ value: String) -> Date? {
        dayFormatter.date(from: value)
    }

    static func parseNasdaq(_ value: String) -> Date? {
        nasdaqFormatter.date(from: value)
    }

    static func addingDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: start(of: date)) ?? start(of: date)
    }

    static func utcMilliseconds(for date: Date) -> Int64 {
        Int64(start(of: date).timeIntervalSince1970 * 1000)
    }
}

private enum HistoricalAnchorClient {
    static func fetchBundle(startDate: Date, endDate: Date) async throws -> HistoricalAnchorBundle {
        let response = try await RemoteMarketClient.fetchHistory(
            symbols: ["gold_cny", "btc", "nasdaq", "usd_per_cny"],
            startDate: MarketDay.string(from: startDate),
            endDate: MarketDay.string(from: endDate)
        )
        let seriesBySymbol = Dictionary(uniqueKeysWithValues: response.series.map { ($0.symbol, $0) })

        return HistoricalAnchorBundle(
            goldCNY: makeSeries(from: seriesBySymbol["gold_cny"]),
            btcUSD: makeSeries(from: seriesBySymbol["btc"]),
            nasdaqUSD: makeSeries(from: seriesBySymbol["nasdaq"] ?? seriesBySymbol["nasdaq_composite"]),
            usdPerCNY: makeSeries(from: seriesBySymbol["usd_per_cny"])
        )
    }

    private static func makeSeries(from series: PublicHistorySeries?) -> HistoricalSeries {
        let points = zip(series?.dates ?? [], series?.prices ?? []).compactMap { dayText, price -> HistoricalAnchorPoint? in
            guard let day = MarketDay.parse(dayText) else { return nil }
            return HistoricalAnchorPoint(day: MarketDay.start(of: day), price: price)
        }
        return HistoricalSeries(points: points)
    }
}

@MainActor
enum SnapshotAnchorService {
    static func backfillIfNeeded(in context: ModelContext) async {
        do {
            let snapshots = try context.fetch(FetchDescriptor<AssetSnapshot>(sortBy: [SortDescriptor(\.date)]))
            guard let first = snapshots.first, let last = snapshots.last else { return }

            let bundle = try await HistoricalAnchorClient.fetchBundle(
                startDate: first.date,
                endDate: last.date
            )

            for snapshot in snapshots {
                applyHistoricalAnchors(to: snapshot, bundle: bundle)
            }

            try context.save()
        } catch {
            print("[AssetTimeMachine] backfill snapshot anchors failed: \(error)")
        }
    }

    static func captureLiveAnchorsIfPossible(
        for snapshot: AssetSnapshot,
        marketStore: RemoteMarketStore,
        in context: ModelContext
    ) async {
        let day = MarketDay.start(of: snapshot.date)
        var didChange = false

        let goldPrice = marketStore.market(for: "gold")?.price
        if snapshot.goldAnchorPriceCNY != goldPrice {
            snapshot.goldAnchorPriceCNY = goldPrice
            snapshot.goldAnchorPriceDate = goldPrice == nil ? nil : day
            didChange = true
        }

        let btcPrice = marketStore.market(for: "btc")?.price
        if snapshot.btcAnchorPriceUSD != btcPrice {
            snapshot.btcAnchorPriceUSD = btcPrice
            snapshot.btcAnchorPriceDate = btcPrice == nil ? nil : day
            didChange = true
        }

        let nasdaqPrice = marketStore.market(for: "nasdaq")?.price
        if snapshot.nasdaqAnchorPriceUSD != nasdaqPrice {
            snapshot.nasdaqAnchorPriceUSD = nasdaqPrice
            snapshot.nasdaqAnchorPriceDate = nasdaqPrice == nil ? nil : day
            didChange = true
        }

        let usdPerCNY = marketStore.exchangeRate(for: "USD")
        if snapshot.usdPerCNY != usdPerCNY {
            snapshot.usdPerCNY = usdPerCNY
            snapshot.usdPerCNYDate = usdPerCNY == nil ? nil : day
            didChange = true
        }

        if didChange {
            snapshot.marketAnchorsUpdatedAt = .now
            do {
                try context.save()
            } catch {
                print("[AssetTimeMachine] capture live anchors failed: \(error)")
            }
        }
    }

    private static func applyHistoricalAnchors(to snapshot: AssetSnapshot, bundle: HistoricalAnchorBundle) {
        let day = MarketDay.start(of: snapshot.date)

        if let goldPoint = bundle.goldCNY.point(onOrBefore: day) {
            snapshot.goldAnchorPriceCNY = goldPoint.price
            snapshot.goldAnchorPriceDate = goldPoint.day
        }

        if let btcPoint = bundle.btcUSD.point(onOrBefore: day) {
            snapshot.btcAnchorPriceUSD = btcPoint.price
            snapshot.btcAnchorPriceDate = btcPoint.day
        }

        if let nasdaqPoint = bundle.nasdaqUSD.point(onOrBefore: day) {
            snapshot.nasdaqAnchorPriceUSD = nasdaqPoint.price
            snapshot.nasdaqAnchorPriceDate = nasdaqPoint.day
        }

        if let usdPoint = bundle.usdPerCNY.point(onOrBefore: day) {
            snapshot.usdPerCNY = usdPoint.price
            snapshot.usdPerCNYDate = usdPoint.day
        }

        snapshot.marketAnchorsUpdatedAt = .now
    }
}

