import Combine
import Foundation
import SwiftData
import SwiftUI

struct PublicMarketPrice: Codable, Identifiable, Equatable {
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

struct PublicMarketOverview: Codable, Equatable {
    let success: Bool
    let markets: [PublicMarketPrice]
    let updateIntervalHours: Int?

    enum CodingKeys: String, CodingKey {
        case success
        case markets
        case updateIntervalHours = "update_interval_hours"
    }
}

struct PublicExchangeRateItem: Codable, Identifiable, Equatable {
    let currency: String
    let rate: Double

    var id: String { currency }
}

struct PublicExchangeRates: Codable, Equatable {
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

struct PublicHistoryDailyBar: Codable, Identifiable, Equatable {
    let dateText: String
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?

    var id: String { dateText }
}

struct PublicHistorySeries: Codable, Identifiable, Equatable {
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
                let date = MarketDay.parse(dates[index]),
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

struct PublicHistoryResponse: Codable, Equatable {
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
            description: "返回人民币计价的黄金单价，单位为 gram。",
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
            description: "返回 gold 与 nasdaq 锚点概览。",
            symbol: nil
        ),
        .init(
            title: "公共历史走势",
            path: "/api/v1/money/public/history?symbols=nasdaq,sp500,hsi&period=1year",
            description: "返回指数、黄金、原油与国债收益率基准信号等公共历史序列。",
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

    static func fetchHistory(symbols: [String], period: String? = nil, startDate: String? = nil, endDate: String? = nil, includeOHLC: Bool = false) async throws -> PublicHistoryResponse {
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
        if includeOHLC {
            queryItems.append(.init(name: "include_ohlc", value: "true"))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response, data: data)
        return try decoder().decode(PublicHistoryResponse.self, from: data)
    }

    static func url(for path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    static func decoder() -> JSONDecoder {
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
                userInfo: [NSLocalizedDescriptionKey: body.isEmpty ? AppLocalization.string("接口请求失败") : body]
            )
        }
    }
}

private struct HistoryBatchFetchResult {
    let series: [PublicHistorySeries]
    let errorMessage: String?
}

@MainActor
final class RemoteMarketStore: ObservableObject {
    @Published var overview: PublicMarketOverview?
    @Published var exchangeRates: [String: Double] = [:]
    @Published var exchangeRatesFetchedAt: Date?
    @Published var historySeries: [String: PublicHistorySeries] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    private static let historyRefreshInterval: TimeInterval = 12 * 60 * 60
    private static let failedHistoryRetryInterval: TimeInterval = 5 * 60
    private static let treasuryYieldSignalSymbols = ["cn_10y_yield", "us_10y_yield", "us_2y_yield", "us_3m_yield"]
    private static let requiredHistorySymbols = [
        "gold_cny", "nasdaq", "sp500", "usd_per_cny",
        "hsi", "csi300", "shanghai_composite", "dowjones",
        "shenzhen_component", "chinext"
    ] + treasuryYieldSignalSymbols
    private var isRefreshingLiveData = false
    private var isRefreshingHistory = false
    private var lastHistoryRefreshAt: Date?
    private var lastHistoryAttemptAt: Date?
    private var liveDataErrorMessage: String?
    private var historyErrorMessage: String?
    private var lastLiveDataRefreshSucceeded = false

    private var shouldRefreshHistory: Bool {
        if historySeries.isEmpty {
            guard let lastHistoryAttemptAt else { return true }
            return Date().timeIntervalSince(lastHistoryAttemptAt) >= Self.failedHistoryRetryInterval
        }

        if isMissingRequiredHistorySeries {
            guard let lastHistoryAttemptAt else { return true }
            return Date().timeIntervalSince(lastHistoryAttemptAt) >= Self.failedHistoryRetryInterval
        }

        guard let lastHistoryRefreshAt else {
            guard let lastHistoryAttemptAt else { return true }
            return Date().timeIntervalSince(lastHistoryAttemptAt) >= Self.failedHistoryRetryInterval
        }
        return Date().timeIntervalSince(lastHistoryRefreshAt) >= Self.historyRefreshInterval
    }

    private var isMissingRequiredHistorySeries: Bool {
        Self.requiredHistorySymbols.contains { history(for: $0) == nil }
    }

    func refresh() async {
        await refreshLiveData()
        await refreshHistoryIfNeeded(force: true)
    }

    @discardableResult
    func refreshLiveData() async -> Bool {
        if isRefreshingLiveData {
            await waitForLiveDataRefreshToFinish()
            return lastLiveDataRefreshSucceeded
        }

        isRefreshingLiveData = true
        updateLoadingState()
        defer {
            isRefreshingLiveData = false
            updateLoadingState()
        }

        var didRefreshExchangeRates = false
        var didRefreshOverview = false
        var firstErrorMessage: String?

        do {
            let exchangeRates = try await RemoteMarketClient.fetchExchangeRates()
            let mappedRates = Dictionary(uniqueKeysWithValues: exchangeRates.rates.map { ($0.currency.uppercased(), $0.rate) })
            if self.exchangeRates != mappedRates {
                self.exchangeRates = mappedRates
            }
            if self.exchangeRatesFetchedAt != exchangeRates.fetchedAt {
                self.exchangeRatesFetchedAt = exchangeRates.fetchedAt
            }
            didRefreshExchangeRates = true
        } catch {
            firstErrorMessage = error.localizedDescription
        }

        do {
            let overview = try await RemoteMarketClient.fetchOverview()
            if self.overview != overview {
                self.overview = overview
            }
            didRefreshOverview = true
        } catch {
            firstErrorMessage = firstErrorMessage ?? error.localizedDescription
        }

        let didRefreshAllLiveData = didRefreshExchangeRates && didRefreshOverview
        lastLiveDataRefreshSucceeded = didRefreshAllLiveData
        liveDataErrorMessage = didRefreshAllLiveData ? nil : (firstErrorMessage ?? AppLocalization.string("接口请求失败"))
        updateErrorMessage()
        return didRefreshAllLiveData
    }

    func refreshHistoryIfNeeded(force: Bool = false) async {
        if isRefreshingHistory {
            await waitForHistoryRefreshToFinish()
            return
        }

        guard force || shouldRefreshHistory else { return }
        await refreshHistory()
    }

    private func waitForLiveDataRefreshToFinish() async {
        while isRefreshingLiveData && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func waitForHistoryRefreshToFinish() async {
        while isRefreshingHistory && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func refreshHistory() async {
        guard !isRefreshingHistory else {
            await waitForHistoryRefreshToFinish()
            return
        }
        isRefreshingHistory = true
        lastHistoryAttemptAt = .now
        updateLoadingState()
        defer {
            isRefreshingHistory = false
            updateLoadingState()
        }

        let historyBatches: [(symbols: [String], includeOHLC: Bool)] = [
            (["gold_cny", "nasdaq", "sp500", "usd_per_cny"], true),
            (["hang_seng", "csi300", "shanghai_composite", "dow_jones"], true),
            (["shenzhen_component", "chinext"], true),
            (Self.treasuryYieldSignalSymbols, false)
        ]
        let fullHistoryStartDate = "2000-01-01"
        let fullHistoryEndDate = MarketDay.string(from: .now)

        var mergedSeries: [PublicHistorySeries] = []
        var batchErrorMessages: [String] = []
        await withTaskGroup(of: HistoryBatchFetchResult.self) { group in
            for batch in historyBatches {
                group.addTask {
                    do {
                        let response = try await RemoteMarketClient.fetchHistory(
                            symbols: batch.symbols,
                            startDate: fullHistoryStartDate,
                            endDate: fullHistoryEndDate,
                            includeOHLC: batch.includeOHLC
                        )
                        return HistoryBatchFetchResult(series: response.series, errorMessage: nil)
                    } catch {
                        return HistoryBatchFetchResult(series: [], errorMessage: error.localizedDescription)
                    }
                }
            }

            for await result in group {
                if !result.series.isEmpty {
                    mergedSeries.append(contentsOf: result.series)
                }
                if let errorMessage = result.errorMessage {
                    batchErrorMessages.append(errorMessage)
                }
            }
        }

        if !mergedSeries.isEmpty {
            var normalizedSeries = self.historySeries
            for series in mergedSeries {
                let normalizedSymbol = Self.normalizedHistorySymbol(series.symbol)
                if let existing = normalizedSeries[normalizedSymbol] {
                    let existingLastDate = existing.dates.last ?? ""
                    let nextLastDate = series.dates.last ?? ""
                    if existingLastDate > nextLastDate {
                        continue
                    }
                    if existingLastDate == nextLastDate, existing.dates.count >= series.dates.count {
                        continue
                    }
                }
                normalizedSeries[normalizedSymbol] = series
            }

            if self.historySeries != normalizedSeries {
                self.historySeries = normalizedSeries
            }

            if batchErrorMessages.isEmpty {
                lastHistoryRefreshAt = .now
                historyErrorMessage = nil
            } else {
                lastHistoryRefreshAt = nil
                historyErrorMessage = AppLocalization.string("部分历史行情暂时不可用，稍后会自动重试")
            }
        } else {
            lastHistoryRefreshAt = nil
            historyErrorMessage = batchErrorMessages.first ?? AppLocalization.string("历史数据加载失败")
        }
        updateErrorMessage()
    }

    private func updateLoadingState() {
        let nextValue = isRefreshingLiveData || isRefreshingHistory
        if isLoading != nextValue {
            isLoading = nextValue
        }
    }

    private func updateErrorMessage() {
        let nextErrorMessage = liveDataErrorMessage ?? historyErrorMessage
        if errorMessage != nextErrorMessage {
            errorMessage = nextErrorMessage
        }
    }

    private static func normalizedHistorySymbol(_ symbol: String) -> String {
        switch symbol {
        case "nasdaq_composite", "nasdaq":
            return "nasdaq"
        case "hang_seng", "hsi":
            return "hsi"
        case "nikkei225", "nikkei":
            return "nikkei"
        case "dow_jones", "dowjones":
            return "dowjones"
        case "cn_10y", "china_10y", "china_10y_yield", "cgb_10y", "cn_10y_yield":
            return "cn_10y_yield"
        case "us10y", "us_10y", "treasury_10y", "us_treasury_10y", "us_10y_yield":
            return "us_10y_yield"
        case "us2y", "us_2y", "us_2y_yield":
            return "us_2y_yield"
        case "us3m", "us_3m", "us_3m_yield":
            return "us_3m_yield"
        default:
            return symbol
        }
    }

    private static func historyLookupSymbols(for symbol: String) -> [String] {
        let normalizedSymbol = normalizedHistorySymbol(symbol)
        switch normalizedSymbol {
        case "nasdaq":
            return ["nasdaq", "nasdaq_composite"]
        case "hsi":
            return ["hsi", "hang_seng"]
        case "nikkei":
            return ["nikkei", "nikkei225"]
        case "dowjones":
            return ["dowjones", "dow_jones"]
        case "cn_10y_yield":
            return ["cn_10y_yield", "cn_10y", "china_10y"]
        case "us_10y_yield":
            return ["us_10y_yield", "us10y", "us_10y"]
        case "us_2y_yield":
            return ["us_2y_yield", "us2y", "us_2y"]
        case "us_3m_yield":
            return ["us_3m_yield", "us3m", "us_3m"]
        default:
            return [normalizedSymbol, symbol]
        }
    }

    func market(for symbol: String) -> PublicMarketPrice? {
        overview?.markets.first(where: { $0.symbol == symbol })
    }

    func exchangeRate(for currency: String) -> Double? {
        exchangeRates[currency.uppercased()]
    }

    func history(for symbol: String) -> PublicHistorySeries? {
        for lookupSymbol in Self.historyLookupSymbols(for: symbol) {
            if let series = historySeries[lookupSymbol] {
                return series
            }
        }
        return nil
    }

    func historyRelevanceToken(for symbols: some Sequence<String>) -> String {
        Array(Set(symbols)).sorted().map { symbol in
            guard let series = history(for: symbol) else { return "\(symbol):nil" }
            return "\(symbol):\(series.dates.count):\(series.dates.last ?? "")"
        }.joined(separator: "|")
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
            let descriptor = FetchDescriptor<AssetSnapshot>(
                predicate: #Predicate { $0.marketAnchorsUpdatedAt == nil },
                sortBy: [SortDescriptor(\.date)]
            )
            let snapshotsNeedingBackfill = try context.fetch(descriptor)
            guard let first = snapshotsNeedingBackfill.first, let last = snapshotsNeedingBackfill.last else { return }

            let bundle = try await HistoricalAnchorClient.fetchBundle(
                startDate: first.date,
                endDate: last.date
            )

            for (index, snapshot) in snapshotsNeedingBackfill.enumerated() {
                guard !Task.isCancelled else { return }
                applyHistoricalAnchors(to: snapshot, bundle: bundle)

                if index > 0, index.isMultiple(of: 40) {
                    try context.save()
                    await Task.yield()
                }
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

        if let goldPrice = marketStore.market(for: "gold")?.price,
           snapshot.goldAnchorPriceCNY != goldPrice {
            snapshot.goldAnchorPriceCNY = goldPrice
            snapshot.goldAnchorPriceDate = day
            didChange = true
        }

        if let btcPrice = marketStore.market(for: "btc")?.price,
           snapshot.btcAnchorPriceUSD != btcPrice {
            snapshot.btcAnchorPriceUSD = btcPrice
            snapshot.btcAnchorPriceDate = day
            didChange = true
        }

        if let nasdaqPrice = marketStore.market(for: "nasdaq")?.price,
           snapshot.nasdaqAnchorPriceUSD != nasdaqPrice {
            snapshot.nasdaqAnchorPriceUSD = nasdaqPrice
            snapshot.nasdaqAnchorPriceDate = day
            didChange = true
        }

        if let usdPerCNY = marketStore.exchangeRate(for: "USD"),
           snapshot.usdPerCNY != usdPerCNY {
            snapshot.usdPerCNY = usdPerCNY
            snapshot.usdPerCNYDate = day
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
