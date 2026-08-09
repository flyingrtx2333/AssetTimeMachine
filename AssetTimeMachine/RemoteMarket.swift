import Combine
import Foundation
import SwiftData
import SwiftUI

nonisolated struct PublicMarketPrice: Codable, Identifiable, Equatable, Sendable {
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

nonisolated struct PublicMarketOverview: Codable, Equatable, Sendable {
    let success: Bool
    let markets: [PublicMarketPrice]
    let updateIntervalHours: Int?

    enum CodingKeys: String, CodingKey {
        case success
        case markets
        case updateIntervalHours = "update_interval_hours"
    }
}

nonisolated struct PublicExchangeRateItem: Codable, Identifiable, Equatable, Sendable {
    let currency: String
    let rate: Double

    var id: String { currency }
}

nonisolated struct PublicExchangeRates: Codable, Equatable, Sendable {
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
}

nonisolated struct MarketEndpointDoc: Identifiable, Sendable {
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
        return try await decode(PublicMarketOverview.self, from: data)
    }

    static func fetchExchangeRates() async throws -> PublicExchangeRates {
        let url = url(for: "/api/v1/money/public/rmb-exchange-rates")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try await decode(PublicExchangeRates.self, from: data)
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
        return try await decode(PublicHistoryResponse.self, from: data)
    }

    static func url(for path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    nonisolated private static func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from data: Data
    ) async throws -> Value {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try decoder().decode(type, from: data)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let dateParser = FlexibleAPIDateParser()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = dateParser.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date format: \(value)")
        }
        return decoder
    }

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

nonisolated private struct HistoryBatchFetchResult: Sendable {
    let series: [PublicHistorySeries]
    let errorMessage: String?
}

nonisolated private struct MarketHistoryMergeResult: Sendable {
    let seriesBySymbol: [String: PublicHistorySeries]
    let didChange: Bool
}

nonisolated private enum MarketHistoryMergeProcessor {
    static func merge(
        existing: [String: PublicHistorySeries],
        incoming: [PublicHistorySeries]
    ) throws -> MarketHistoryMergeResult {
        var normalizedSeries = existing
        var didChange = false

        for (index, series) in incoming.enumerated() {
            if index.isMultiple(of: 8) { try Task.checkCancellation() }
            let normalizedSymbol = RemoteMarketStore.normalizedHistorySymbol(series.symbol)
            if let current = normalizedSeries[normalizedSymbol] {
                let currentLastDate = current.dates.last ?? ""
                let nextLastDate = series.dates.last ?? ""
                if currentLastDate > nextLastDate {
                    continue
                }
                if currentLastDate == nextLastDate, current.dates.count > series.dates.count {
                    continue
                }
                if current == series { continue }
            }
            normalizedSeries[normalizedSymbol] = series
            didChange = true
        }

        return MarketHistoryMergeResult(
            seriesBySymbol: normalizedSeries,
            didChange: didChange
        )
    }
}

nonisolated private struct MarketHistoryCacheEntry: Codable, Sendable {
    let savedAt: Date
    let seriesBySymbol: [String: PublicHistorySeries]
}

private enum MarketHistoryDiskCache {
    nonisolated private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AssetTimeMachine", isDirectory: true)
            .appendingPathComponent("market-history-v1.json", isDirectory: false)
    }

    nonisolated static func load() -> MarketHistoryCacheEntry? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(MarketHistoryCacheEntry.self, from: data)
    }

    nonisolated static func save(seriesBySymbol: [String: PublicHistorySeries], at date: Date) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(MarketHistoryCacheEntry(
                savedAt: date,
                seriesBySymbol: seriesBySymbol
            ))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A cache write failure must not affect live market data.
        }
    }
}

@MainActor
final class RemoteMarketStore: ObservableObject {
    @Published var overview: PublicMarketOverview?
    @Published var exchangeRates: [String: Double] = [:]
    @Published var exchangeRatesFetchedAt: Date?
    @Published var historySeries: [String: PublicHistorySeries] = [:] {
        didSet { historyRevision &+= 1 }
    }
    @Published private(set) var historyRevision = 0
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
    private var didLoadHistoryDiskCache = false
    private var historyDiskCacheLoadTask: Task<MarketHistoryCacheEntry?, Never>?
    private var historyRefreshTask: Task<Void, Never>?
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
    func refreshLiveData(
        commitIf shouldCommit: @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard shouldCommit() else { return false }
        if isRefreshingLiveData {
            await waitForLiveDataRefreshToFinish()
            return shouldCommit() && lastLiveDataRefreshSucceeded
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
        var refreshedExchangeRates: [String: Double]?
        var refreshedExchangeRatesFetchedAt: Date?
        var refreshedOverview: PublicMarketOverview?

        async let exchangeRatesRequest = RemoteMarketClient.fetchExchangeRates()
        async let overviewRequest = RemoteMarketClient.fetchOverview()

        do {
            let exchangeRates = try await exchangeRatesRequest
            refreshedExchangeRates = exchangeRates.rates.reduce(into: [String: Double]()) { result, item in
                result[item.currency.uppercased()] = item.rate
            }
            refreshedExchangeRatesFetchedAt = exchangeRates.fetchedAt
            didRefreshExchangeRates = true
        } catch {
            firstErrorMessage = error.localizedDescription
        }

        do {
            refreshedOverview = try await overviewRequest
            didRefreshOverview = true
        } catch {
            firstErrorMessage = firstErrorMessage ?? error.localizedDescription
        }

        // Network work may have started before a cloud import. Publish the batch only
        // if its owner still accepts it, so an import cannot be interleaved with stale
        // market-driven UI or model updates.
        guard shouldCommit() else { return false }

        if let refreshedExchangeRates,
           self.exchangeRates != refreshedExchangeRates {
            self.exchangeRates = refreshedExchangeRates
        }
        if let refreshedExchangeRatesFetchedAt,
           self.exchangeRatesFetchedAt != refreshedExchangeRatesFetchedAt {
            self.exchangeRatesFetchedAt = refreshedExchangeRatesFetchedAt
        }
        if let refreshedOverview,
           self.overview != refreshedOverview {
            self.overview = refreshedOverview
        }

        let didRefreshAllLiveData = didRefreshExchangeRates && didRefreshOverview
        lastLiveDataRefreshSucceeded = didRefreshAllLiveData
        liveDataErrorMessage = didRefreshAllLiveData ? nil : (firstErrorMessage ?? AppLocalization.string("接口请求失败"))
        updateErrorMessage()
        return didRefreshAllLiveData
    }

    func refreshHistoryIfNeeded(force: Bool = false) async {
        await loadHistoryDiskCacheIfNeeded()

        if let historyRefreshTask {
            await historyRefreshTask.value
            return
        }

        guard force || shouldRefreshHistory else { return }

        let refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshHistory()
        }
        historyRefreshTask = refreshTask
        await refreshTask.value
        if historyRefreshTask != nil {
            historyRefreshTask = nil
        }
    }

    private func loadHistoryDiskCacheIfNeeded() async {
        if didLoadHistoryDiskCache { return }

        let task: Task<MarketHistoryCacheEntry?, Never>
        if let historyDiskCacheLoadTask {
            task = historyDiskCacheLoadTask
        } else {
            task = Task.detached(priority: .utility) {
                MarketHistoryDiskCache.load()
            }
            historyDiskCacheLoadTask = task
        }

        let cached = await task.value
        historyDiskCacheLoadTask = nil
        didLoadHistoryDiskCache = true

        guard historySeries.isEmpty, let cached else { return }
        historySeries = cached.seriesBySymbol
        if !isMissingRequiredHistorySeries {
            lastHistoryRefreshAt = cached.savedAt
        }
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
            (["shenzhen_component", "chinext", "nikkei225", "oil_wti_cny"], true),
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
            let existingSeries = historySeries
            let incomingSeries = mergedSeries
            let mergeResult: MarketHistoryMergeResult
            do {
                mergeResult = try await BackgroundTaskWork.run {
                    try MarketHistoryMergeProcessor.merge(
                        existing: existingSeries,
                        incoming: incomingSeries
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                historyErrorMessage = error.localizedDescription
                updateErrorMessage()
                return
            }

            if mergeResult.didChange {
                historySeries = mergeResult.seriesBySymbol
            }

            if batchErrorMessages.isEmpty {
                lastHistoryRefreshAt = .now
                historyErrorMessage = nil
            } else {
                lastHistoryRefreshAt = nil
                historyErrorMessage = AppLocalization.string("部分历史行情暂时不可用，稍后会自动重试")
            }

            let cachedSeries = self.historySeries
            let cacheDate = lastHistoryRefreshAt ?? Date()
            _ = Task.detached(priority: .utility) {
                MarketHistoryDiskCache.save(seriesBySymbol: cachedSeries, at: cacheDate)
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

    nonisolated fileprivate static func normalizedHistorySymbol(_ symbol: String) -> String {
        switch symbol {
        case "nasdaq_composite", "nasdaq":
            return "nasdaq"
        case "hang_seng", "hsi":
            return "hsi"
        case "nikkei225", "nikkei":
            return "nikkei"
        case "oil_wti", "oil_wti_cny", "wti":
            return "oil_wti_cny"
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

    nonisolated private static func historyLookupSymbols(for symbol: String) -> [String] {
        let normalizedSymbol = normalizedHistorySymbol(symbol)
        switch normalizedSymbol {
        case "nasdaq":
            return ["nasdaq", "nasdaq_composite"]
        case "hsi":
            return ["hsi", "hang_seng"]
        case "nikkei":
            return ["nikkei", "nikkei225"]
        case "oil_wti_cny":
            return ["oil_wti_cny", "oil_wti", "wti"]
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

nonisolated private struct HistoricalAnchorPoint: Sendable {
    let day: Date
    let price: Double
}

nonisolated private struct HistoricalSeries: Sendable {
    let pointsByDay: [Date: HistoricalAnchorPoint]
    let sortedDays: [Date]

    init(points: [HistoricalAnchorPoint]) {
        var normalizedByDay: [Date: HistoricalAnchorPoint] = [:]
        normalizedByDay.reserveCapacity(points.count)
        for point in points {
            // Upstream history can contain the same trading day more than once.
            // Preserve the latest occurrence instead of trapping in
            // Dictionary(uniqueKeysWithValues:).
            normalizedByDay[point.day] = point
        }
        self.pointsByDay = normalizedByDay
        self.sortedDays = normalizedByDay.keys.sorted()
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

nonisolated private struct HistoricalAnchorBundle: Sendable {
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
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return HistoricalAnchorProjectionProcessor.makeBundle(from: response.series)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

nonisolated private enum HistoricalAnchorProjectionProcessor {
    static func makeBundle(from series: [PublicHistorySeries]) -> HistoricalAnchorBundle {
        let seriesBySymbol = series.reduce(into: [String: PublicHistorySeries]()) { result, item in
            result[item.symbol] = item
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        func makeSeries(from series: PublicHistorySeries?) -> HistoricalSeries {
            let dates = series?.dates ?? []
            let prices = series?.prices ?? []
            let count = min(dates.count, prices.count)
            var points: [HistoricalAnchorPoint] = []
            points.reserveCapacity(count)

            for index in 0..<count {
                if index.isMultiple(of: 256), Task.isCancelled { break }
                guard let parsedDay = formatter.date(from: dates[index]) else { continue }
                points.append(
                    HistoricalAnchorPoint(
                        day: calendar.startOfDay(for: parsedDay),
                        price: prices[index]
                    )
                )
            }
            return HistoricalSeries(points: points)
        }

        return HistoricalAnchorBundle(
            goldCNY: makeSeries(from: seriesBySymbol["gold_cny"]),
            btcUSD: makeSeries(from: seriesBySymbol["btc"]),
            nasdaqUSD: makeSeries(from: seriesBySymbol["nasdaq"] ?? seriesBySymbol["nasdaq_composite"]),
            usdPerCNY: makeSeries(from: seriesBySymbol["usd_per_cny"])
        )
    }
}

nonisolated private struct SnapshotAnchorBackfillBounds: Sendable {
    let firstDate: Date
    let lastDate: Date
}

@ModelActor
private actor SnapshotAnchorBackfillStore {
    func pendingBounds() throws -> SnapshotAnchorBackfillBounds? {
        let descriptor = FetchDescriptor<AssetSnapshot>(
            predicate: #Predicate { $0.marketAnchorsUpdatedAt == nil },
            sortBy: [SortDescriptor(\.date)]
        )
        let snapshots = try modelContext.fetch(descriptor)
        guard let first = snapshots.first, let last = snapshots.last else { return nil }
        return SnapshotAnchorBackfillBounds(firstDate: first.date, lastDate: last.date)
    }

    func apply(_ bundle: HistoricalAnchorBundle) async throws {
        let descriptor = FetchDescriptor<AssetSnapshot>(
            predicate: #Predicate { $0.marketAnchorsUpdatedAt == nil },
            sortBy: [SortDescriptor(\.date)]
        )
        let snapshots = try modelContext.fetch(descriptor)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

        for (index, snapshot) in snapshots.enumerated() {
            try Task.checkCancellation()
            let day = calendar.startOfDay(for: snapshot.date)

            if let point = bundle.goldCNY.point(onOrBefore: day), point.price > 0 {
                snapshot.goldAnchorPriceCNY = point.price
                snapshot.goldAnchorPriceDate = point.day
            }
            if let point = bundle.btcUSD.point(onOrBefore: day), point.price > 0 {
                snapshot.btcAnchorPriceUSD = point.price
                snapshot.btcAnchorPriceDate = point.day
            }
            if let point = bundle.nasdaqUSD.point(onOrBefore: day), point.price > 0 {
                snapshot.nasdaqAnchorPriceUSD = point.price
                snapshot.nasdaqAnchorPriceDate = point.day
            }
            if let point = bundle.usdPerCNY.point(onOrBefore: day), point.price > 0 {
                snapshot.usdPerCNY = point.price
                snapshot.usdPerCNYDate = point.day
            }

            let hasCompleteAnchors = (snapshot.goldAnchorPriceCNY ?? 0) > 0
                && (snapshot.btcAnchorPriceUSD ?? 0) > 0
                && (snapshot.nasdaqAnchorPriceUSD ?? 0) > 0
                && (snapshot.usdPerCNY ?? 0) > 0
            snapshot.marketAnchorsUpdatedAt = hasCompleteAnchors ? .now : nil

            if index > 0, index.isMultiple(of: 400) {
                try modelContext.save()
                await Task.yield()
            }
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
    }
}

@MainActor
enum SnapshotAnchorService {
    static func backfillIfNeeded(in context: ModelContext) async {
        do {
            let container = context.container
            try await BackgroundTaskWork.run {
                let store = SnapshotAnchorBackfillStore(modelContainer: container)
                guard let bounds = try await store.pendingBounds() else { return }

                let bundle = try await HistoricalAnchorClient.fetchBundle(
                    startDate: bounds.firstDate,
                    endDate: bounds.lastDate
                )
                try Task.checkCancellation()
                try await store.apply(bundle)
            }
        } catch is CancellationError {
            return
        } catch {
            print("[AssetTimeMachine] backfill snapshot anchors failed: \(error)")
        }
    }

    static func captureLiveAnchorsIfPossible(
        for snapshot: AssetSnapshot,
        marketStore: RemoteMarketStore,
        in context: ModelContext,
        commitIf shouldCommit: @MainActor () -> Bool = { true }
    ) async {
        guard shouldCommit() else { return }
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

}
