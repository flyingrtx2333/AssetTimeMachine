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

nonisolated struct PublicMacroAsOfPoint: Codable, Equatable, Sendable {
    let releaseDate: String
    let referenceDate: String
    let availableAt: Date
    let value: Double
    let source: String

    enum CodingKeys: String, CodingKey {
        case releaseDate = "release_date"
        case referenceDate = "reference_date"
        case availableAt = "available_at"
        case value
        case source
    }
}

nonisolated struct PublicNFCISeries: Codable, Equatable, Sendable {
    let seriesID: String
    let label: String
    let frequency: String
    let lookbackReleases: Int
    let points: [PublicMacroAsOfPoint]

    enum CodingKeys: String, CodingKey {
        case seriesID = "series_id"
        case label
        case frequency
        case lookbackReleases = "lookback_releases"
        case points
    }
}

nonisolated struct PublicNFCIAsOfResponse: Codable, Equatable, Sendable {
    let success: Bool
    let source: String
    let latestAvailableAt: Date?
    let series: [PublicNFCISeries]
    let availableSeries: [String]

    enum CodingKeys: String, CodingKey {
        case success
        case source
        case latestAvailableAt = "latest_available_at"
        case series
        case availableSeries = "available_series"
    }
}

nonisolated struct PublicForwardValidationStrategy: Codable, Equatable, Identifiable, Sendable {
    let strategyID: String
    let strategyVersion: String
    let strategyName: String
    let frozenAt: String
    let signalCount: Int
    let newSessions: Int
    let firstSignalDate: String
    let latestSignalDate: String
    let latestExecutionDateHint: String
    let latestTargetFingerprint: String
    let latestPayloadSHA256: String
    let latestDesiredCashWeight: Double
    let latestModelCashWeight: Double
    let latestRebalanceRecommended: Bool

    var id: String { strategyVersion }

    enum CodingKeys: String, CodingKey {
        case strategyID = "strategy_id"
        case strategyVersion = "strategy_version"
        case strategyName = "strategy_name"
        case frozenAt = "frozen_at"
        case signalCount = "signal_count"
        case newSessions = "new_sessions"
        case firstSignalDate = "first_signal_date"
        case latestSignalDate = "latest_signal_date"
        case latestExecutionDateHint = "latest_execution_date_hint"
        case latestTargetFingerprint = "latest_target_fingerprint"
        case latestPayloadSHA256 = "latest_payload_sha256"
        case latestDesiredCashWeight = "latest_desired_cash_weight"
        case latestModelCashWeight = "latest_model_cash_weight"
        case latestRebalanceRecommended = "latest_rebalance_recommended"
    }
}

nonisolated struct PublicForwardValidationMilestone: Codable, Equatable, Identifiable, Sendable {
    let sessions: Int
    let label: String
    let reached: Bool

    var id: Int { sessions }
}

nonisolated struct PublicForwardValidationResponse: Codable, Equatable, Sendable {
    let success: Bool
    let startSignalDate: String?
    let latestSignalDate: String?
    let newSessions: Int
    let primaryDecisionSessions: Int
    let strategies: [PublicForwardValidationStrategy]
    let milestones: [PublicForwardValidationMilestone]

    enum CodingKeys: String, CodingKey {
        case success
        case startSignalDate = "start_signal_date"
        case latestSignalDate = "latest_signal_date"
        case newSessions = "new_sessions"
        case primaryDecisionSessions = "primary_decision_sessions"
        case strategies
        case milestones
    }
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
        .init(
            title: "NFCI 实时点时序列",
            path: "/api/v1/money/public/nfci-asof",
            description: "返回 NFCI Credit / Leverage 首次可用值；历史值不可被后续修订覆盖。",
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

    static func fetchNFCIAsOf(startDate: String? = nil, endDate: String? = nil) async throws -> PublicNFCIAsOfResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/money/public/nfci-asof"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []
        if let startDate, !startDate.isEmpty {
            queryItems.append(.init(name: "start_date", value: startDate))
        }
        if let endDate, !endDate.isEmpty {
            queryItems.append(.init(name: "end_date", value: endDate))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response: response, data: data)
        return try await decode(PublicNFCIAsOfResponse.self, from: data)
    }

    static func fetchForwardValidation() async throws -> PublicForwardValidationResponse {
        let url = url(for: "/api/v1/money/public/strategy-forward-validation")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try await decode(PublicForwardValidationResponse.self, from: data)
    }

    static func fetchAssetCatalog() async throws -> [MarketAssetDescriptor] {
        let url = url(for: "/api/v1/money/public/history-catalog")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try await decode(MarketAssetCatalogResponse.self, from: data).assets
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
    let catalog: [MarketAssetDescriptor]
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

nonisolated private struct MarketAssetCatalogCacheEntry: Codable, Sendable {
    let savedAt: Date
    let assets: [MarketAssetDescriptor]
}

private enum MarketAssetCatalogDiskCache {
    nonisolated private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AssetTimeMachine", isDirectory: true)
            .appendingPathComponent("market-asset-catalog-v1.json", isDirectory: false)
    }

    nonisolated static func load() -> MarketAssetCatalogCacheEntry? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(MarketAssetCatalogCacheEntry.self, from: data)
    }

    nonisolated static func save(_ entry: MarketAssetCatalogCacheEntry) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(entry).write(to: fileURL, options: .atomic)
        } catch {
            // Catalog cache failures must not block record or backtest flows.
        }
    }
}

nonisolated extension PublicNFCIAsOfResponse {
    var backtestNFCIAsOfData: BacktestNFCIAsOfData? {
        guard success,
              let credit = series.first(where: { $0.seriesID == "NFCICREDIT" }),
              let leverage = series.first(where: { $0.seriesID == "NFCILEVERAGE" }) else {
            return nil
        }
        func mapPoints(_ points: [PublicMacroAsOfPoint]) -> [BacktestNFCIPoint] {
            points.map {
                BacktestNFCIPoint(
                    releaseDate: $0.releaseDate,
                    referenceDate: $0.referenceDate,
                    availableAt: $0.availableAt,
                    value: $0.value
                )
            }
        }
        return BacktestNFCIAsOfData(
            source: source,
            credit: mapPoints(credit.points),
            leverage: mapPoints(leverage.points)
        )
    }
}

@MainActor
final class RemoteMarketStore: ObservableObject {
    @Published var overview: PublicMarketOverview?
    @Published var exchangeRates: [String: Double] = [:]
    @Published var exchangeRatesFetchedAt: Date?
    @Published var nfciAsOf: PublicNFCIAsOfResponse? {
        didSet {
            BacktestMacroSnapshotStore.shared.updateNFCIAsOf(nfciAsOf?.backtestNFCIAsOfData)
        }
    }
    @Published var historySeries: [String: PublicHistorySeries] = [:] {
        didSet { historyRevision &+= 1 }
    }
    @Published private(set) var historyRevision = 0
    @Published private(set) var assetCatalog: [MarketAssetDescriptor] = []
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
    private var targetedHistoryRefreshTask: Task<Void, Never>?
    private var assetCatalogRefreshTask: Task<Void, Never>?
    private var didLoadAssetCatalogDiskCache = false
    private var assetCatalogSavedAt: Date?
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
        await refreshAssetCatalogIfNeeded(force: true)
        await refreshHistoryIfNeeded(force: true)
    }

    func refreshAssetCatalogIfNeeded(force: Bool = false) async {
        await loadAssetCatalogDiskCacheIfNeeded()

        if let assetCatalogRefreshTask {
            await assetCatalogRefreshTask.value
            return
        }

        let isFresh = assetCatalogSavedAt.map { Date().timeIntervalSince($0) < 7 * 24 * 60 * 60 } == true
        guard force || assetCatalog.isEmpty || !isFresh else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let assets: [MarketAssetDescriptor]
            do {
                assets = try await RemoteMarketClient.fetchAssetCatalog()
            } catch {
                // Older servers do not expose the lightweight catalog yet. A one-day
                // history response carries the same metadata and keeps the rollout compatible.
                let day = MarketDay.string(from: .now)
                guard let response = try? await RemoteMarketClient.fetchHistory(
                    symbols: [],
                    startDate: day,
                    endDate: day
                ) else { return }
                assets = response.catalog ?? response.series.map { MarketAssetDescriptor(series: $0) }
                await mergeCatalogHistory(response.series)
            }

            let normalized = MarketAssetCatalog.normalized(assets)
            guard !normalized.isEmpty else { return }
            assetCatalog = normalized
            assetCatalogSavedAt = .now
            let entry = MarketAssetCatalogCacheEntry(savedAt: .now, assets: normalized)
            _ = Task.detached(priority: .utility) {
                MarketAssetCatalogDiskCache.save(entry)
            }
        }
        assetCatalogRefreshTask = task
        await task.value
        assetCatalogRefreshTask = nil
    }

    var selectableAssetCatalog: [MarketAssetDescriptor] {
        assetCatalog.isEmpty ? MarketAssetCatalog.offlineFallback : assetCatalog
    }

    func assetDescriptor(for symbol: String) -> MarketAssetDescriptor? {
        let normalized = Self.normalizedHistorySymbol(symbol)
        return selectableAssetCatalog.first { Self.normalizedHistorySymbol($0.symbol) == normalized }
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
        var refreshedNFCIAsOf: PublicNFCIAsOfResponse?

        async let exchangeRatesRequest = RemoteMarketClient.fetchExchangeRates()
        async let overviewRequest = RemoteMarketClient.fetchOverview()
        async let nfciRequest = RemoteMarketClient.fetchNFCIAsOf()

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

        do {
            refreshedNFCIAsOf = try await nfciRequest
        } catch {
            // Rollout-compatible soft dependency: older servers may not expose NFCI yet.
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
        if let refreshedNFCIAsOf,
           self.nfciAsOf != refreshedNFCIAsOf {
            self.nfciAsOf = refreshedNFCIAsOf
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

    func refreshHistory(for requestedSymbols: Set<String>, force: Bool = false) async {
        await loadHistoryDiskCacheIfNeeded()

        if let historyRefreshTask {
            await historyRefreshTask.value
        }
        if let targetedHistoryRefreshTask {
            await targetedHistoryRefreshTask.value
            self.targetedHistoryRefreshTask = nil
        }

        let symbols = Set(requestedSymbols.map(Self.normalizedHistorySymbol))
            .filter { $0 != "usd_cash" && (force || needsFullHistory(for: $0)) }
            .sorted()
        guard !symbols.isEmpty else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshTargetedHistory(symbols: symbols)
        }
        targetedHistoryRefreshTask = task
        await task.value
        targetedHistoryRefreshTask = nil
    }

    private func needsFullHistory(for symbol: String) -> Bool {
        guard let series = history(for: symbol) else { return true }
        return series.dates.count < 30 || series.prices.count < 30
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

    private func loadAssetCatalogDiskCacheIfNeeded() async {
        guard !didLoadAssetCatalogDiskCache else { return }
        didLoadAssetCatalogDiskCache = true
        guard let cached = await Task.detached(priority: .utility, operation: {
            MarketAssetCatalogDiskCache.load()
        }).value else { return }
        let normalized = MarketAssetCatalog.normalized(cached.assets)
        if !normalized.isEmpty {
            assetCatalog = normalized
            assetCatalogSavedAt = cached.savedAt
        }
    }

    private func mergeCatalogHistory(_ series: [PublicHistorySeries]) async {
        guard !series.isEmpty else { return }
        let existingSeries = historySeries
        let result = try? await BackgroundTaskWork.run {
            try MarketHistoryMergeProcessor.merge(existing: existingSeries, incoming: series)
        }
        if let result, result.didChange {
            historySeries = result.seriesBySymbol
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
                        let catalog = response.catalog ?? response.series.map { MarketAssetDescriptor(series: $0) }
                        return HistoryBatchFetchResult(series: response.series, catalog: catalog, errorMessage: nil)
                    } catch {
                        return HistoryBatchFetchResult(series: [], catalog: [], errorMessage: error.localizedDescription)
                    }
                }
            }

            var discoveredCatalog: [MarketAssetDescriptor] = []
            for await result in group {
                if !result.series.isEmpty {
                    mergedSeries.append(contentsOf: result.series)
                }
                discoveredCatalog.append(contentsOf: result.catalog)
                if let errorMessage = result.errorMessage {
                    batchErrorMessages.append(errorMessage)
                }
            }

            if !discoveredCatalog.isEmpty {
                let normalized = MarketAssetCatalog.normalized(discoveredCatalog)
                if !normalized.isEmpty, assetCatalog.isEmpty {
                    assetCatalog = normalized
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

    private func refreshTargetedHistory(symbols: [String]) async {
        guard !symbols.isEmpty else { return }
        guard !isRefreshingHistory else {
            await waitForHistoryRefreshToFinish()
            return
        }

        isRefreshingHistory = true
        updateLoadingState()
        defer {
            isRefreshingHistory = false
            updateLoadingState()
        }

        do {
            let response = try await RemoteMarketClient.fetchHistory(
                symbols: symbols,
                startDate: "2000-01-01",
                endDate: MarketDay.string(from: .now),
                includeOHLC: true
            )
            let existingSeries = historySeries
            let incomingSeries = response.series
            let mergeResult = try await BackgroundTaskWork.run {
                try MarketHistoryMergeProcessor.merge(
                    existing: existingSeries,
                    incoming: incomingSeries
                )
            }
            guard !Task.isCancelled else { return }

            if mergeResult.didChange {
                historySeries = mergeResult.seriesBySymbol
            }

            let discoveredCatalog = response.catalog ?? response.series.map(MarketAssetDescriptor.init(series:))
            if !discoveredCatalog.isEmpty {
                let normalizedCatalog = MarketAssetCatalog.normalized(assetCatalog + discoveredCatalog)
                if normalizedCatalog != assetCatalog {
                    assetCatalog = normalizedCatalog
                    assetCatalogSavedAt = .now
                    let entry = MarketAssetCatalogCacheEntry(savedAt: .now, assets: normalizedCatalog)
                    _ = Task.detached(priority: .utility) {
                        MarketAssetCatalogDiskCache.save(entry)
                    }
                }
            }

            historyErrorMessage = nil
            updateErrorMessage()
            let cachedSeries = historySeries
            _ = Task.detached(priority: .utility) {
                MarketHistoryDiskCache.save(seriesBySymbol: cachedSeries, at: .now)
            }
        } catch is CancellationError {
            return
        } catch {
            historyErrorMessage = error.localizedDescription
            updateErrorMessage()
        }
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

    nonisolated static func normalizedHistorySymbol(_ symbol: String) -> String {
        BacktestAssetSymbol.normalized(symbol)
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
