import Foundation

public struct PublicBacktestRange: Codable, Equatable, Sendable {
    public let startDate: String
    public let endDate: String

    public init(startDate: String, endDate: String) {
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct PublicBacktestFixedCosts: Codable, Equatable, Sendable {
    public let transactionFeeRate: Double
    public let slippageRate: Double

    public init(transactionFeeRate: Double = 0.01, slippageRate: Double = 0.0005) {
        self.transactionFeeRate = transactionFeeRate
        self.slippageRate = slippageRate
    }
}

public struct PublicBacktestMetrics: Codable, Equatable, Sendable {
    public let endingValue: Double
    public let totalReturn: Double
    public let annualizedReturn: Double?
    public let maxDrawdown: Double
    public let annualizedVolatility: Double?
    public let sharpeRatio: Double?
    public let calmarRatio: Double?
    public let averageGrossExposure: Double
}

public struct PublicBacktestSeriesPoint: Codable, Equatable, Sendable {
    public let date: String
    public let value: Double
}

public struct PublicBacktestSeriesSet: Codable, Equatable, Sendable {
    public let portfolio: [PublicBacktestSeriesPoint]
    public let benchmark: [PublicBacktestSeriesPoint]
    public let drawdown: [PublicBacktestSeriesPoint]
}

public struct PublicBacktestExposure: Codable, Equatable, Sendable {
    public let name: String
    public let value: Double
}

public struct PublicBacktestSourceInfo: Codable, Equatable, Sendable {
    public let name: String?
    public let provider: String?
    public let description: String?
    public let url: String?
    public let asOf: String?
    public let symbol: String?
    public let label: String?
}

public struct PublicBacktestRunRequest: Codable, Equatable, Sendable {
    public let strategyID: String
    public let startDate: String
    public let endDate: String
    public let initialCash: Double
    public let strategyConfig: PublicBasicStrategyConfig?

    public init(
        strategyID: String,
        startDate: String,
        endDate: String,
        initialCash: Double,
        strategyConfig: PublicBasicStrategyConfig? = nil
    ) {
        self.strategyID = strategyID
        self.startDate = startDate
        self.endDate = endDate
        self.initialCash = initialCash
        self.strategyConfig = strategyConfig
    }

    enum CodingKeys: String, CodingKey {
        case strategyID = "strategy_id"
        case startDate = "start_date"
        case endDate = "end_date"
        case initialCash = "initial_cash"
        case strategyConfig = "strategy_config"
    }
}

public enum PublicBasicStrategyKind: String, Codable, Equatable, Sendable {
    case fixedAllocation = "fixed_allocation"
    case momentumRotation = "momentum_rotation"
    case trendFollowing = "trend_following"
}

public enum PublicBasicRebalanceFrequency: String, Codable, Equatable, Sendable {
    case monthly
    case quarterly
    case yearly

    fileprivate var sessions: Int {
        switch self {
        case .monthly: return 21
        case .quarterly: return 63
        case .yearly: return 252
        }
    }
}

public struct PublicBasicAllocation: Codable, Equatable, Sendable {
    public let symbol: String
    public let weight: Double

    public init(symbol: String, weight: Double) {
        self.symbol = symbol
        self.weight = weight
    }
}

public struct PublicBasicStrategyConfig: Codable, Equatable, Sendable {
    public let name: String
    public let kind: PublicBasicStrategyKind
    public let allocations: [PublicBasicAllocation]
    public let rebalance: PublicBasicRebalanceFrequency
    public let lookbackMonths: Int?
    public let topN: Int?
    public let movingAverageDays: Int?

    public init(
        name: String,
        kind: PublicBasicStrategyKind,
        allocations: [PublicBasicAllocation],
        rebalance: PublicBasicRebalanceFrequency,
        lookbackMonths: Int? = nil,
        topN: Int? = nil,
        movingAverageDays: Int? = nil
    ) {
        self.name = name
        self.kind = kind
        self.allocations = allocations
        self.rebalance = rebalance
        self.lookbackMonths = lookbackMonths
        self.topN = topN
        self.movingAverageDays = movingAverageDays
    }

    enum CodingKeys: String, CodingKey {
        case name, kind, allocations, rebalance
        case lookbackMonths = "lookback_months"
        case topN = "top_n"
        case movingAverageDays = "moving_average_days"
    }
}

public enum PublicBacktestComputeMode: String, Codable, Sendable {
    case prewarm
    case run
    case forward
}

public struct PublicBacktestComputeInvocation: Codable, Sendable {
    public let mode: PublicBacktestComputeMode
    public let datasetPath: String
    public let datasetHash: String
    public let dataStale: Bool
    public let strategyID: String?
    public let request: PublicBacktestRunRequest?
    public let macroPath: String?
    public let decisionAt: Date?

    public init(
        mode: PublicBacktestComputeMode,
        datasetPath: String,
        datasetHash: String,
        dataStale: Bool,
        strategyID: String? = nil,
        request: PublicBacktestRunRequest? = nil,
        macroPath: String? = nil,
        decisionAt: Date? = nil
    ) {
        self.mode = mode
        self.datasetPath = datasetPath
        self.datasetHash = datasetHash
        self.dataStale = dataStale
        self.strategyID = strategyID
        self.request = request
        self.macroPath = macroPath
        self.decisionAt = decisionAt
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case datasetPath = "dataset_path"
        case datasetHash = "dataset_hash"
        case dataStale = "data_stale"
        case strategyID = "strategy_id"
        case request
        case macroPath = "macro_path"
        case decisionAt = "decision_at"
    }
}

/// The worker and the isolated compute executable exchange an internal file payload.
/// Every acronym and snake-case key is declared explicitly on the payload models, so this
/// codec must not apply an additional key-conversion strategy.
public enum PublicBacktestComputeCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct PublicBacktestResult: Codable, Equatable, Sendable {
    public let requestedRange: PublicBacktestRange
    public let evaluationRange: PublicBacktestRange
    public let metrics: PublicBacktestMetrics
    public let series: PublicBacktestSeriesSet
    public let exposure: [PublicBacktestExposure]
    public let tradeCount: Int
    public let source: [PublicBacktestSourceInfo]
    public let engineVersion: String
    public let datasetHash: String
    public let dataCutoff: String
    public let dataStale: Bool
}

public struct PublicBacktestStrategy: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let riskLevel: String
    public let summary: String
    public let assetScope: [String]
    public let availableRange: PublicBacktestRange
    public let defaultMetrics: PublicBacktestMetrics?
    public let experimental: Bool
    public let maxGrossExposure: Double
    public let financingRate: Double?
}

public struct PublicBacktestCatalogResponse: Codable, Equatable, Sendable {
    public let strategies: [PublicBacktestStrategy]
    public let fixedCosts: PublicBacktestFixedCosts
    public let dataCutoff: String
    public let engineVersion: String
    public let datasetHash: String
    public let dataStale: Bool
    public let source: [PublicBacktestSourceInfo]
}

public struct PublicForwardNFCIState: Codable, Equatable, Sendable {
    public let source: String
    public let latestAvailableAt: Date?
    public let creditReleaseDate: String?
    public let creditValue: Double?
    public let creditEightReleaseChange: Double?
    public let creditTriggered: Bool
    public let leverageReleaseDate: String?
    public let leverageValue: Double?
    public let leverageFourReleaseChange: Double?
    public let leverageTriggered: Bool

    enum CodingKeys: String, CodingKey {
        case source
        case latestAvailableAt = "latest_available_at"
        case creditReleaseDate = "credit_release_date"
        case creditValue = "credit_value"
        case creditEightReleaseChange = "credit_eight_release_change"
        case creditTriggered = "credit_triggered"
        case leverageReleaseDate = "leverage_release_date"
        case leverageValue = "leverage_value"
        case leverageFourReleaseChange = "leverage_four_release_change"
        case leverageTriggered = "leverage_triggered"
    }
}

public struct PublicForwardStrategySnapshot: Codable, Equatable, Sendable {
    public let strategyID: String
    public let strategyVersion: String
    public let strategyName: String
    public let frozenAt: String
    public let decisionAt: Date
    public let signalDate: String
    public let executionDateHint: String
    public let dataCutoff: String
    public let datasetHash: String
    public let engineVersion: String
    public let dataStale: Bool
    public let desiredTargetWeights: [String: Double]
    public let desiredCashWeight: Double
    public let desiredGrossExposure: Double
    public let modelExecutedWeights: [String: Double]
    public let modelCashWeight: Double
    public let modelGrossExposure: Double
    public let rebalanceRecommended: Bool
    public let targetFingerprint: String
    public let causalInputFingerprint: String
    public let nfci: PublicForwardNFCIState

    enum CodingKeys: String, CodingKey {
        case strategyID = "strategy_id"
        case strategyVersion = "strategy_version"
        case strategyName = "strategy_name"
        case frozenAt = "frozen_at"
        case decisionAt = "decision_at"
        case signalDate = "signal_date"
        case executionDateHint = "execution_date_hint"
        case dataCutoff = "data_cutoff"
        case datasetHash = "dataset_hash"
        case engineVersion = "engine_version"
        case dataStale = "data_stale"
        case desiredTargetWeights = "desired_target_weights"
        case desiredCashWeight = "desired_cash_weight"
        case desiredGrossExposure = "desired_gross_exposure"
        case modelExecutedWeights = "model_executed_weights"
        case modelCashWeight = "model_cash_weight"
        case modelGrossExposure = "model_gross_exposure"
        case rebalanceRecommended = "rebalance_recommended"
        case targetFingerprint = "target_fingerprint"
        case causalInputFingerprint = "causal_input_fingerprint"
        case nfci
    }
}

public struct PublicBacktestDataset: Sendable {
    public let datasetHash: String
    public let dataCutoff: String
    public let loadedAt: Date
    public let dataStale: Bool
    public let dataSources: [String]

    let response: PublicHistoryResponse
    let seriesBySymbol: [String: PublicHistorySeries]

    fileprivate init(
        datasetHash: String,
        dataCutoff: String,
        loadedAt: Date,
        dataStale: Bool,
        dataSources: [String],
        response: PublicHistoryResponse,
        seriesBySymbol: [String: PublicHistorySeries]
    ) {
        self.datasetHash = datasetHash
        self.dataCutoff = dataCutoff
        self.loadedAt = loadedAt
        self.dataStale = dataStale
        self.dataSources = dataSources
        self.response = response
        self.seriesBySymbol = seriesBySymbol
    }

    public func markingStale(_ stale: Bool) -> PublicBacktestDataset {
        PublicBacktestDataset(
            datasetHash: datasetHash,
            dataCutoff: dataCutoff,
            loadedAt: loadedAt,
            dataStale: stale,
            dataSources: dataSources,
            response: response,
            seriesBySymbol: seriesBySymbol
        )
    }
}

public enum PublicBacktestCoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidDataset(String)
    case invalidMacroData(String)
    case unknownStrategy
    case invalidDate
    case invalidRange(String)
    case invalidInitialCash
    case invalidStrategyConfig(String)
    case computationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDataset(let detail):
            return "Invalid market dataset: \(detail)"
        case .invalidMacroData(let detail):
            return "Invalid point-in-time macro data: \(detail)"
        case .unknownStrategy:
            return "Unknown or unavailable strategy"
        case .invalidDate:
            return "Dates must use the yyyy-MM-dd Gregorian format"
        case .invalidRange(let detail):
            return "Invalid backtest range: \(detail)"
        case .invalidInitialCash:
            return "Initial cash must be between CNY 10,000 and CNY 10,000,000"
        case .invalidStrategyConfig(let detail):
            return "Invalid basic strategy: \(detail)"
        case .computationFailed:
            return "The Swift backtest engine could not produce a result"
        }
    }
}

private struct ForwardMacroPointPayload: Decodable {
    let releaseDate: String
    let referenceDate: String
    let availableAt: String
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

private struct ForwardMacroSeriesPayload: Decodable {
    let seriesID: String
    let points: [ForwardMacroPointPayload]

    enum CodingKeys: String, CodingKey {
        case seriesID = "series_id"
        case points
    }
}

private struct ForwardMacroResponsePayload: Decodable {
    let success: Bool
    let source: String
    let series: [ForwardMacroSeriesPayload]
}

public enum PublicBacktestCore {
    public static let engineVersion: String = {
        let configured = ProcessInfo.processInfo.environment["BACKTEST_ENGINE_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured?.isEmpty == false ? configured! : "atm-swift-dev"
    }()
    public static let fixedCosts = PublicBacktestFixedCosts()
    public static let minimumInitialCash = 10_000.0
    public static let maximumInitialCash = 10_000_000.0
    public static let minimumRangeYears = 3
    public static let maximumSeriesPointCount = 600
    public static let customStrategyID = "custom-basic-v1"
    public static let basicAssetSymbols = ["gold_cny", "sp500", "nasdaq", "csi300", "shanghai_composite"]
    public static let forwardStrategyIDs = ["nfci-dual-core-v1", "nfci-dual-core-v11"]

    private struct ForwardStrategyDescriptor: Sendable {
        let id: String
        let version: String
        let name: String
        let frozenAt: String
        let mode: AdvancedBacktestStrategyMode
    }

    private struct StrategyDescriptor: Sendable {
        let id: String
        let name: String
        let riskLevel: String
        let summary: String
        let assetScope: [String]
        let experimental: Bool
        let maxGrossExposure: Double
        let financingRate: Double?
    }

    private struct StrategyDescriptorProfile: Sendable {
        let riskLevel: String
        let summary: String
        let assetScope: [String]
        let maxGrossExposure: Double
        let financingRate: Double?
    }

    private static let forwardDescriptorsByID: [String: ForwardStrategyDescriptor] = [
        "nfci-dual-core-v1": .init(
            id: "nfci-dual-core-v1",
            version: "dualcore-v1-2026-08-14",
            name: "NFCI 双核心（前瞻）",
            frozenAt: "2026-08-14",
            mode: .nfciDualCoreV1
        ),
        "nfci-dual-core-v11": .init(
            id: "nfci-dual-core-v11",
            version: "dualcore-v11-2026-08-15",
            name: "NFCI 双核心·简化（前瞻）",
            frozenAt: "2026-08-15",
            mode: .nfciDualCoreSimplifiedV11
        ),
    ]

    private static let descriptorProfilesByID: [String: StrategyDescriptorProfile] = [
        "risk-contribution-cash-confidence-low-noise": .init(
            riskLevel: "中等",
            summary: "在严格无杠杆与不允许负现金的约束下，降低无效换手并保留趋势恢复能力。",
            assetScope: ["黄金", "美国权益指数", "中国权益指数", "现金"],
            maxGrossExposure: 1.0,
            financingRate: nil
        ),
        "core-gold-satellite-equity-curve-state-gate-momentum": .init(
            riskLevel: "中等",
            summary: "以跨市场趋势和组合状态协同控制风险预算，在风险走弱阶段自动收缩。",
            assetScope: ["黄金", "美国权益指数", "中国权益指数", "现金"],
            maxGrossExposure: 1.0,
            financingRate: nil
        ),
        "core-gold-satellite-risk-budget-state-gate-momentum": .init(
            riskLevel: "中高",
            summary: "在防守与进取引擎之间分配风险预算，侧重长期宽度确认与成本约束。",
            assetScope: ["黄金", "美国权益指数", "中国权益指数", "现金"],
            maxGrossExposure: 1.0,
            financingRate: nil
        ),
        "core-gold-satellite-profit-lock-momentum": .init(
            riskLevel: "中低",
            summary: "根据组合回撤与快速上涨后的状态平滑降低风险预算，强调持有体验。",
            assetScope: ["黄金", "美国权益指数", "中国权益指数", "现金"],
            maxGrossExposure: 1.0,
            financingRate: nil
        ),
        "gold-nasdaq-dual-trend-barbell": .init(
            riskLevel: "中高",
            summary: "黄金与纳指分别判断长期趋势，弱势时降低对应仓位并保留现金。",
            assetScope: ["黄金", "纳斯达克指数", "现金"],
            maxGrossExposure: 1.0,
            financingRate: nil
        )
    ]

    private static var strategyDescriptors: [StrategyDescriptor] {
        BacktestProductStrategyCatalog.curatedTemplateIDs.compactMap { id in
            guard let template = AdvancedBacktestStrategyTemplate.all.first(where: { $0.id == id }),
                  template.mode.isRotation,
                  let profile = descriptorProfilesByID[id] else { return nil }
            return StrategyDescriptor(
                id: id,
                name: template.title,
                riskLevel: profile.riskLevel,
                summary: profile.summary,
                assetScope: profile.assetScope,
                experimental: false,
                maxGrossExposure: profile.maxGrossExposure,
                financingRate: profile.financingRate
            )
        }
    }

    public static var strategyIDs: [String] {
        strategyDescriptors.map(\.id)
    }

    public static func loadDataset(
        from data: Data,
        datasetHash: String,
        loadedAt: Date = Date(),
        dataStale: Bool = false
    ) throws -> PublicBacktestDataset {
        let response: PublicHistoryResponse
        do {
            response = try JSONDecoder().decode(PublicHistoryResponse.self, from: data)
        } catch {
            throw PublicBacktestCoreError.invalidDataset("JSON decoding failed")
        }
        guard response.success else {
            throw PublicBacktestCoreError.invalidDataset("upstream response is unsuccessful")
        }

        var normalizedSeries: [String: PublicHistorySeries] = [:]
        for series in response.series {
            try validate(series: series)
            let symbol = normalizedHistorySymbol(series.symbol)
            if let existing = normalizedSeries[symbol], existing.dates.count >= series.dates.count {
                continue
            }
            normalizedSeries[symbol] = series
        }

        let requiredSymbols = Set(["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite", "usd_per_cny"])
        let missing = requiredSymbols.subtracting(normalizedSeries.keys)
        guard missing.isEmpty else {
            throw PublicBacktestCoreError.invalidDataset("missing required symbols: \(missing.sorted().joined(separator: ","))")
        }

        guard let fx = normalizedSeries["usd_per_cny"],
              fx.prices.contains(where: { $0.isFinite && $0 > 0 }) else {
            throw PublicBacktestCoreError.invalidDataset("USD/CNY history is unavailable")
        }

        let requiredSeries = requiredSymbols.compactMap { normalizedSeries[$0] }
        guard let bounds = BacktestEngine.availableDateBounds(for: requiredSeries) else {
            throw PublicBacktestCoreError.invalidDataset("required series have no common date range")
        }
        let cutoff = dateString(bounds.upperBound)
        let sources = Array(Set(requiredSeries.map(\.source).filter { !$0.isEmpty })).sorted()
        return PublicBacktestDataset(
            datasetHash: datasetHash,
            dataCutoff: cutoff,
            loadedAt: loadedAt,
            dataStale: dataStale,
            dataSources: sources,
            response: response,
            seriesBySymbol: normalizedSeries
        )
    }

    public static func prewarm(dataset: PublicBacktestDataset) throws -> [String: PublicBacktestResult] {
        var results: [String: PublicBacktestResult] = [:]
        for descriptor in strategyDescriptors {
            try Task.checkCancellation()
            results[descriptor.id] = try prewarm(strategyID: descriptor.id, dataset: dataset)
        }
        return results
    }

    public static func prewarm(
        strategyID: String,
        dataset: PublicBacktestDataset
    ) throws -> PublicBacktestResult {
        guard let descriptor = strategyDescriptors.first(where: { $0.id == strategyID }) else {
            throw PublicBacktestCoreError.unknownStrategy
        }
        let template = try template(for: descriptor.id)
        let bounds = try availableBounds(for: template, dataset: dataset)
        let request = PublicBacktestRunRequest(
            strategyID: descriptor.id,
            startDate: dateString(bounds.lowerBound),
            endDate: dateString(bounds.upperBound),
            initialCash: 100_000
        )
        return try runValidated(
            request: request,
            descriptor: descriptor,
            template: template,
            dataset: dataset,
            dateBounds: nil
        )
    }

    public static func catalog(
        dataset: PublicBacktestDataset,
        defaultResults: [String: PublicBacktestResult] = [:]
    ) throws -> PublicBacktestCatalogResponse {
        let strategies = try strategyDescriptors.map { descriptor -> PublicBacktestStrategy in
            let template = try template(for: descriptor.id)
            let bounds = try availableBounds(for: template, dataset: dataset)
            let fallbackRange = PublicBacktestRange(
                startDate: dateString(bounds.lowerBound),
                endDate: dateString(bounds.upperBound)
            )
            let defaultResult = defaultResults[descriptor.id]
            return PublicBacktestStrategy(
                id: descriptor.id,
                name: descriptor.name,
                riskLevel: descriptor.riskLevel,
                summary: descriptor.summary,
                assetScope: descriptor.assetScope,
                availableRange: fallbackRange,
                defaultMetrics: defaultResult?.metrics,
                experimental: descriptor.experimental,
                maxGrossExposure: descriptor.maxGrossExposure,
                financingRate: descriptor.financingRate
            )
        }

        return PublicBacktestCatalogResponse(
            strategies: strategies,
            fixedCosts: fixedCosts,
            dataCutoff: dataset.dataCutoff,
            engineVersion: engineVersion,
            datasetHash: dataset.datasetHash,
            dataStale: dataset.dataStale,
            source: sourceInfo(dataset: dataset)
        )
    }

    public static func run(
        request: PublicBacktestRunRequest,
        dataset: PublicBacktestDataset
    ) throws -> PublicBacktestResult {
        guard request.initialCash.isFinite,
              request.initialCash >= minimumInitialCash,
              request.initialCash <= maximumInitialCash else {
            throw PublicBacktestCoreError.invalidInitialCash
        }
        guard let startDate = parseDate(request.startDate),
              let endDate = parseDate(request.endDate) else {
            throw PublicBacktestCoreError.invalidDate
        }
        guard startDate <= endDate else {
            throw PublicBacktestCoreError.invalidRange("start_date must not be after end_date")
        }
        guard let minimumEnd = calendar.date(byAdding: .year, value: minimumRangeYears, to: startDate),
              minimumEnd <= endDate else {
            throw PublicBacktestCoreError.invalidRange("at least three Gregorian calendar years are required")
        }

        if request.strategyID == customStrategyID {
            guard let strategyConfig = request.strategyConfig else {
                throw PublicBacktestCoreError.invalidStrategyConfig("strategy_config is required")
            }
            let available = try availableBounds(for: strategyConfig, dataset: dataset)
            guard startDate >= available.lowerBound, endDate <= available.upperBound else {
                throw PublicBacktestCoreError.invalidRange(
                    "requested dates must be within \(dateString(available.lowerBound))...\(dateString(available.upperBound))"
                )
            }
            return try runBasicValidated(
                request: request,
                config: strategyConfig,
                dataset: dataset,
                dateBounds: startDate...endDate,
                availableBounds: available
            )
        }

        guard request.strategyConfig == nil,
              let descriptor = strategyDescriptors.first(where: { $0.id == request.strategyID }) else {
            throw PublicBacktestCoreError.unknownStrategy
        }
        let template = try template(for: descriptor.id)
        let available = try availableBounds(for: template, dataset: dataset)
        guard startDate >= available.lowerBound, endDate <= available.upperBound else {
            throw PublicBacktestCoreError.invalidRange(
                "requested dates must be within \(dateString(available.lowerBound))...\(dateString(available.upperBound))"
            )
        }
        return try runValidated(
            request: request,
            descriptor: descriptor,
            template: template,
            dataset: dataset,
            dateBounds: startDate...endDate
        )
    }

    public static func forwardSnapshot(
        strategyID: String,
        dataset: PublicBacktestDataset,
        nfciData: Data,
        decisionAt: Date = Date()
    ) throws -> PublicForwardStrategySnapshot {
        guard let descriptor = forwardDescriptorsByID[strategyID],
              let template = AdvancedBacktestStrategyTemplate.all.first(where: {
                  $0.mode == descriptor.mode
              }) else {
            throw PublicBacktestCoreError.unknownStrategy
        }

        let nfci = try loadForwardNFCI(from: nfciData, availableAtOrBefore: decisionAt)
        let options = StrategyNotificationDefaults.assetOptions(for: template)
        guard !options.isEmpty else { throw PublicBacktestCoreError.computationFailed }

        guard let commonCutoffDate = parseDate(dataset.dataCutoff) else {
            throw PublicBacktestCoreError.invalidDataset("forward strategy has an invalid common data cutoff")
        }
        let syntheticExecutionDate = nextWeekday(after: commonCutoffDate)
        let syntheticExecutionDateText = dateString(syntheticExecutionDate)

        var extendedSeriesBySymbol = dataset.seriesBySymbol
        var causalSeriesBySymbol: [String: PublicHistorySeries] = [:]
        let neededSymbols = Set(options.flatMap { option in
            [option.symbol, option.historicalFXSymbol].compactMap { $0 }
        })
        for symbol in neededSymbols {
            let normalized = normalizedHistorySymbol(symbol)
            guard let series = extendedSeriesBySymbol[normalized] else {
                throw PublicBacktestCoreError.invalidDataset("forward strategy is missing \(normalized)")
            }
            let commonCutoffSeries = truncatingSeries(series, through: dataset.dataCutoff)
            guard !commonCutoffSeries.dates.isEmpty else {
                throw PublicBacktestCoreError.invalidDataset("forward strategy has no \(normalized) data by common cutoff")
            }
            causalSeriesBySymbol[normalized] = commonCutoffSeries
            extendedSeriesBySymbol[normalized] = appendingSyntheticSession(
                to: commonCutoffSeries,
                dateText: syntheticExecutionDateText
            )
        }

        let historyProvider: (String) -> PublicHistorySeries? = { symbol in
            extendedSeriesBySymbol[normalizedHistorySymbol(symbol)]
        }
        let inputs = options.map { option in
            BacktestEngine.advancedAssetInput(for: option, historyProvider: historyProvider)
        }
        let settings = AdvancedBacktestRiskSettings(
            feeRate: BacktestDefaults.advancedFeeRatePercent,
            slippageRate: BacktestDefaults.advancedSlippageRatePercent,
            maxPositionRatio: template.maxPositionRatio,
            cooldownDays: template.cooldownDays,
            stopLossRatio: template.stopLossRatio,
            takeProfitRatio: template.takeProfitRatio
        )
        guard let run = BacktestEngine.runAdvancedRotationStrategyWithTrace(
            assetInputs: inputs,
            initialCash: 100_000,
            settings: settings,
            mode: descriptor.mode,
            nfciAsOf: nfci
        ), let latestState = run.dailyStates.last,
           latestState.date.recordDateString == syntheticExecutionDateText,
           run.dailyStates.count >= 2 else {
            throw PublicBacktestCoreError.computationFailed
        }

        let signalState = run.dailyStates[run.dailyStates.count - 2]
        let signalDate = signalState.date.recordDateString
        let symbols = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
        var desiredWeights: [String: Double] = [:]
        for symbol in symbols {
            let weight = max(latestState.targetWeights[symbol] ?? 0, 0)
            guard weight.isFinite else { throw PublicBacktestCoreError.computationFailed }
            desiredWeights[symbol] = weight
        }
        let desiredGross = desiredWeights.values.reduce(0, +)
        guard desiredGross <= 1.000001 else { throw PublicBacktestCoreError.computationFailed }

        guard latestState.portfolioValue.isFinite, latestState.portfolioValue > 0 else {
            throw PublicBacktestCoreError.computationFailed
        }
        var executedWeights: [String: Double] = [:]
        for symbol in symbols {
            let weight = max((latestState.holdingsBySymbol[symbol] ?? 0) / latestState.portfolioValue, 0)
            guard weight.isFinite else { throw PublicBacktestCoreError.computationFailed }
            executedWeights[symbol] = weight
        }
        let modelGross = executedWeights.values.reduce(0, +)
        let modelCash = max(latestState.cash / latestState.portfolioValue, 0)
        let desiredCash = max(1 - desiredGross, 0)
        let rebalanceRecommended = run.report.trades.contains {
            $0.date.recordDateString == syntheticExecutionDateText
        }

        return PublicForwardStrategySnapshot(
            strategyID: descriptor.id,
            strategyVersion: descriptor.version,
            strategyName: descriptor.name,
            frozenAt: descriptor.frozenAt,
            decisionAt: decisionAt,
            signalDate: signalDate,
            executionDateHint: syntheticExecutionDateText,
            dataCutoff: dataset.dataCutoff,
            datasetHash: dataset.datasetHash,
            engineVersion: engineVersion,
            dataStale: dataset.dataStale,
            desiredTargetWeights: desiredWeights,
            desiredCashWeight: desiredCash,
            desiredGrossExposure: desiredGross,
            modelExecutedWeights: executedWeights,
            modelCashWeight: modelCash,
            modelGrossExposure: modelGross,
            rebalanceRecommended: rebalanceRecommended,
            targetFingerprint: forwardTargetFingerprint(desiredWeights),
            causalInputFingerprint: forwardCausalInputFingerprint(
                marketSeriesBySymbol: causalSeriesBySymbol,
                nfci: nfci,
                dataCutoff: dataset.dataCutoff
            ),
            nfci: forwardNFCIState(nfci, signalDate: signalDate)
        )
    }

    public static func applyingCurrentDatasetState(
        to result: PublicBacktestResult,
        dataset: PublicBacktestDataset
    ) -> PublicBacktestResult {
        PublicBacktestResult(
            requestedRange: result.requestedRange,
            evaluationRange: result.evaluationRange,
            metrics: result.metrics,
            series: result.series,
            exposure: result.exposure,
            tradeCount: result.tradeCount,
            source: sourceInfo(dataset: dataset),
            engineVersion: engineVersion,
            datasetHash: dataset.datasetHash,
            dataCutoff: dataset.dataCutoff,
            dataStale: dataset.dataStale
        )
    }

    private static func runValidated(
        request: PublicBacktestRunRequest,
        descriptor: StrategyDescriptor,
        template: AdvancedBacktestStrategyTemplate,
        dataset: PublicBacktestDataset,
        dateBounds: ClosedRange<Date>?
    ) throws -> PublicBacktestResult {
        let inputs = try preparedInputs(for: template, dataset: dataset)
        let available = try availableBounds(for: template, dataset: dataset)
        let settings = AdvancedBacktestRiskSettings(
            feeRate: BacktestDefaults.advancedFeeRatePercent,
            slippageRate: BacktestDefaults.advancedSlippageRatePercent,
            maxPositionRatio: template.maxPositionRatio,
            cooldownDays: template.cooldownDays,
            stopLossRatio: template.stopLossRatio,
            takeProfitRatio: template.takeProfitRatio
        )
        let simulationBounds = dateBounds.map { available.lowerBound...$0.upperBound }
        guard let strategyRun = BacktestEngine.runAdvancedRotationStrategyWithTrace(
            assetInputs: inputs,
            initialCash: request.initialCash,
            settings: settings,
            mode: template.mode,
            dateBounds: simulationBounds
        ) else {
            if Task.isCancelled { throw CancellationError() }
            throw PublicBacktestCoreError.computationFailed
        }
        let report: AdvancedBacktestReport
        if let dateBounds {
            guard let slicedReport = BacktestEngine.statefulAdvancedReport(
                from: strategyRun.report,
                dailyStates: strategyRun.dailyStates,
                within: dateBounds,
                rebasedTo: request.initialCash
            ) else {
                throw PublicBacktestCoreError.computationFailed
            }
            report = slicedReport
        } else {
            report = strategyRun.report
        }
        return try makeResult(report: report, request: request, dataset: dataset)
    }

    private static func runBasicValidated(
        request: PublicBacktestRunRequest,
        config: PublicBasicStrategyConfig,
        dataset: PublicBacktestDataset,
        dateBounds: ClosedRange<Date>,
        availableBounds: ClosedRange<Date>
    ) throws -> PublicBacktestResult {
        try validate(config: config)
        let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
        let options = try config.allocations.map { allocation -> BacktestAssetOption in
            guard let option = optionsBySymbol[allocation.symbol] else {
                throw PublicBacktestCoreError.invalidStrategyConfig("unsupported asset \(allocation.symbol)")
            }
            return option
        }
        let historyProvider: (String) -> PublicHistorySeries? = { symbol in
            dataset.seriesBySymbol[normalizedHistorySymbol(symbol)]
        }
        let inputs = options.map { option in
            BacktestEngine.advancedAssetInput(for: option, historyProvider: historyProvider)
        }
        let settings = AdvancedBacktestRiskSettings(
            feeRate: BacktestDefaults.advancedFeeRatePercent,
            slippageRate: BacktestDefaults.advancedSlippageRatePercent,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        )
        let baseWeights = Dictionary(uniqueKeysWithValues: config.allocations.map { ($0.symbol, $0.weight) })
        let lookbackSessions = max((config.lookbackMonths ?? 12) * 21, 1)
        let movingAverageDays = max(config.movingAverageDays ?? 200, 1)
        let warmupSessions: Int
        switch config.kind {
        case .fixedAllocation: warmupSessions = 1
        case .momentumRotation: warmupSessions = lookbackSessions
        case .trendFollowing: warmupSessions = movingAverageDays
        }

        let runConfig = ResearchTargetStrategyConfig(
            symbol: customStrategyID,
            title: config.name,
            warmupSessions: warmupSessions,
            rebalanceSessions: config.rebalance.sessions,
            maxGrossExposure: 1,
            allowsFinancedExposure: false,
            financingAnnualRate: 0,
            buyReason: "基础策略调仓"
        )
        guard let strategyRun = BacktestEngine.runResearchTargetProviderStrategyWithTrace(
            assetInputs: inputs,
            initialCash: request.initialCash,
            settings: settings,
            config: runConfig,
            dateBounds: availableBounds.lowerBound...dateBounds.upperBound,
            targetWeights: { context, data in
                switch config.kind {
                case .fixedAllocation:
                    return baseWeights
                case .momentumRotation:
                    let candidates = data.tradableSymbols.compactMap { symbol -> (String, Double)? in
                        guard let prices = data.pricesBySymbol[symbol],
                              prices.indices.contains(context.signalIndex),
                              prices.indices.contains(context.signalIndex - lookbackSessions),
                              prices[context.signalIndex - lookbackSessions] > 0 else { return nil }
                        let momentum = prices[context.signalIndex] / prices[context.signalIndex - lookbackSessions] - 1
                        guard momentum.isFinite, momentum > 0 else { return nil }
                        return (symbol, momentum)
                    }
                    .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1 }
                    let selected = candidates.prefix(max(config.topN ?? 1, 1)).map(\.0)
                    let selectedTotal = selected.reduce(0) { $0 + (baseWeights[$1] ?? 0) }
                    guard selectedTotal > 0 else { return [:] }
                    return Dictionary(uniqueKeysWithValues: selected.map { symbol in
                        (symbol, (baseWeights[symbol] ?? 0) / selectedTotal)
                    })
                case .trendFollowing:
                    var weights: [String: Double] = [:]
                    for symbol in data.tradableSymbols {
                        guard let prices = data.pricesBySymbol[symbol],
                              prices.indices.contains(context.signalIndex),
                              context.signalIndex - movingAverageDays + 1 >= 0 else { continue }
                        let window = prices[(context.signalIndex - movingAverageDays + 1)...context.signalIndex]
                        let average = window.reduce(0, +) / Double(window.count)
                        if average.isFinite, prices[context.signalIndex] > average {
                            weights[symbol] = baseWeights[symbol] ?? 0
                        }
                    }
                    return weights
                }
            }
        ) else {
            if Task.isCancelled { throw CancellationError() }
            throw PublicBacktestCoreError.computationFailed
        }
        guard let report = BacktestEngine.statefulAdvancedReport(
            from: strategyRun.report,
            dailyStates: strategyRun.dailyStates,
            within: dateBounds,
            rebasedTo: request.initialCash
        ) else {
            throw PublicBacktestCoreError.computationFailed
        }
        return try makeResult(report: report, request: request, dataset: dataset)
    }

    private static func makeResult(
        report: AdvancedBacktestReport,
        request: PublicBacktestRunRequest,
        dataset: PublicBacktestDataset
    ) throws -> PublicBacktestResult {
        guard let first = report.points.first, let last = report.points.last else {
            throw PublicBacktestCoreError.computationFailed
        }
        let metrics = PublicBacktestMetrics(
            endingValue: report.finalPortfolioValue,
            totalReturn: report.totalReturn,
            annualizedReturn: finite(report.annualizedReturn),
            maxDrawdown: report.maxDrawdown,
            annualizedVolatility: finite(report.annualizedVolatility),
            sharpeRatio: finite(report.sharpeRatio),
            calmarRatio: finite(report.calmarRatio),
            averageGrossExposure: report.averageExposureRatio
        )

        let sampledPortfolio = sampled(report.points, maxCount: maximumSeriesPointCount)
        let sampledBenchmark = sampled(report.benchmarkPoints, maxCount: maximumSeriesPointCount)
        let drawdownPoints = drawdownSeries(from: report.points)
        let sampledDrawdown = sampled(drawdownPoints, maxCount: maximumSeriesPointCount)

        let exposures = [
            PublicBacktestExposure(name: "平均风险资产总敞口", value: max(report.averageExposureRatio, 0)),
            PublicBacktestExposure(name: "平均现金仓位", value: max(report.averageCashRatio, 0)),
        ]
        return PublicBacktestResult(
            requestedRange: PublicBacktestRange(startDate: request.startDate, endDate: request.endDate),
            evaluationRange: PublicBacktestRange(startDate: dateString(first.date), endDate: dateString(last.date)),
            metrics: metrics,
            series: PublicBacktestSeriesSet(
                portfolio: sampledPortfolio.map { .init(date: dateString($0.date), value: $0.portfolioValue) },
                benchmark: sampledBenchmark.map { .init(date: dateString($0.date), value: $0.portfolioValue) },
                drawdown: sampledDrawdown.map { .init(date: dateString($0.date), value: $0.portfolioValue) }
            ),
            exposure: exposures,
            tradeCount: report.trades.count,
            source: sourceInfo(dataset: dataset),
            engineVersion: engineVersion,
            datasetHash: dataset.datasetHash,
            dataCutoff: dataset.dataCutoff,
            dataStale: dataset.dataStale
        )
    }

    private static func validate(config: PublicBasicStrategyConfig) throws {
        let trimmedName = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 40 else {
            throw PublicBacktestCoreError.invalidStrategyConfig("name must contain 1...40 characters")
        }
        guard !config.allocations.isEmpty, config.allocations.count <= basicAssetSymbols.count else {
            throw PublicBacktestCoreError.invalidStrategyConfig("select between 1 and 5 assets")
        }
        let symbols = config.allocations.map(\.symbol)
        guard Set(symbols).count == symbols.count,
              Set(symbols).isSubset(of: Set(basicAssetSymbols)) else {
            throw PublicBacktestCoreError.invalidStrategyConfig("assets must be unique and publicly supported")
        }
        guard config.allocations.allSatisfy({ $0.weight.isFinite && $0.weight > 0 && $0.weight <= 1 }) else {
            throw PublicBacktestCoreError.invalidStrategyConfig("weights must be within (0, 1]")
        }
        let totalWeight = config.allocations.reduce(0) { $0 + $1.weight }
        guard totalWeight <= 1.000_000_1 else {
            throw PublicBacktestCoreError.invalidStrategyConfig("gross allocation must not exceed 100%")
        }
        switch config.kind {
        case .fixedAllocation:
            guard config.lookbackMonths == nil, config.topN == nil, config.movingAverageDays == nil else {
                throw PublicBacktestCoreError.invalidStrategyConfig("fixed allocation has no signal parameters")
            }
        case .momentumRotation:
            guard let lookback = config.lookbackMonths, [3, 6, 12].contains(lookback),
                  let topN = config.topN, topN >= 1, topN <= min(3, config.allocations.count),
                  config.movingAverageDays == nil else {
                throw PublicBacktestCoreError.invalidStrategyConfig("momentum requires a 3/6/12 month lookback and valid top_n")
            }
        case .trendFollowing:
            guard let movingAverageDays = config.movingAverageDays, [50, 100, 200].contains(movingAverageDays),
                  config.lookbackMonths == nil, config.topN == nil else {
                throw PublicBacktestCoreError.invalidStrategyConfig("trend following requires a 50/100/200 day moving average")
            }
        }
    }

    private static func availableBounds(
        for config: PublicBasicStrategyConfig,
        dataset: PublicBacktestDataset
    ) throws -> ClosedRange<Date> {
        try validate(config: config)
        let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
        var series: [PublicHistorySeries] = []
        for allocation in config.allocations {
            guard let option = optionsBySymbol[allocation.symbol],
                  let asset = dataset.seriesBySymbol[allocation.symbol] else {
                throw PublicBacktestCoreError.invalidStrategyConfig("unsupported asset \(allocation.symbol)")
            }
            series.append(asset)
            if let fxSymbol = option.historicalFXSymbol,
               let fx = dataset.seriesBySymbol[normalizedHistorySymbol(fxSymbol)] {
                series.append(fx)
            }
        }
        guard let bounds = BacktestEngine.availableDateBounds(for: series) else {
            throw PublicBacktestCoreError.invalidDataset("basic strategy has no common date range")
        }
        return bounds
    }

    private static func preparedInputs(
        for template: AdvancedBacktestStrategyTemplate,
        dataset: PublicBacktestDataset
    ) throws -> [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)] {
        let options = StrategyNotificationDefaults.assetOptions(for: template)
        let historyProvider: (String) -> PublicHistorySeries? = { symbol in
            dataset.seriesBySymbol[normalizedHistorySymbol(symbol)]
        }
        let inputs = options.map { option in
            BacktestEngine.advancedAssetInput(for: option, historyProvider: historyProvider)
        }
        let bounds = try availableBounds(for: template, dataset: dataset)
        return BacktestEngine.filteredAdvancedAssetInputs(inputs, within: bounds)
    }

    private static func availableBounds(
        for template: AdvancedBacktestStrategyTemplate,
        dataset: PublicBacktestDataset
    ) throws -> ClosedRange<Date> {
        let options = StrategyNotificationDefaults.assetOptions(for: template)
        let boundarySymbols = template.mode.dateBoundaryAssetSymbols
        let boundaryOptions = options.filter { boundarySymbols?.contains($0.symbol) ?? true }
        let sourceSeries = boundaryOptions.flatMap { option -> [PublicHistorySeries] in
            var output: [PublicHistorySeries] = []
            if let asset = dataset.seriesBySymbol[normalizedHistorySymbol(option.symbol)] {
                output.append(asset)
            }
            if let fxSymbol = option.historicalFXSymbol,
               let fx = dataset.seriesBySymbol[normalizedHistorySymbol(fxSymbol)] {
                output.append(fx)
            }
            return output
        }
        guard !sourceSeries.isEmpty,
              let bounds = BacktestEngine.availableDateBounds(for: sourceSeries) else {
            throw PublicBacktestCoreError.invalidDataset("strategy \(template.id) has no common date range")
        }
        return bounds
    }

    private static func template(for id: String) throws -> AdvancedBacktestStrategyTemplate {
        guard let template = AdvancedBacktestStrategyTemplate.all.first(where: { $0.id == id }),
              template.mode.isRotation else {
            throw PublicBacktestCoreError.unknownStrategy
        }
        return template
    }

    private static func validate(series: PublicHistorySeries) throws {
        guard !series.symbol.isEmpty,
              series.dates.count == series.prices.count,
              series.dates.count >= 750 else {
            throw PublicBacktestCoreError.invalidDataset("\(series.symbol) has an invalid or short price series")
        }
        var previousDate: Date?
        for index in series.dates.indices {
            let price = series.prices[index]
            guard price.isFinite, price > 0,
                  let date = parseDate(series.dates[index]) else {
                throw PublicBacktestCoreError.invalidDataset("\(series.symbol) contains an invalid date or price")
            }
            if let previousDate, date <= previousDate {
                throw PublicBacktestCoreError.invalidDataset("\(series.symbol) dates are not strictly increasing")
            }
            previousDate = date
        }

        if series.hasOHLC == true {
            guard let opens = series.openPrices,
                  let highs = series.highPrices,
                  let lows = series.lowPrices,
                  let closes = series.closePrices,
                  opens.count == series.dates.count,
                  highs.count == series.dates.count,
                  lows.count == series.dates.count,
                  closes.count == series.dates.count else {
                throw PublicBacktestCoreError.invalidDataset("\(series.symbol) declares malformed OHLC arrays")
            }
            var covered = 0
            for index in series.dates.indices {
                guard let open = opens[index], let high = highs[index], let low = lows[index], let close = closes[index] else {
                    continue
                }
                guard open.isFinite, high.isFinite, low.isFinite, close.isFinite,
                      open > 0, close > 0, low > 0,
                      high >= max(open, close, low),
                      low <= min(open, close, high) else {
                    throw PublicBacktestCoreError.invalidDataset("\(series.symbol) contains an invalid OHLC bar")
                }
                covered += 1
            }
            guard covered > 0 else {
                throw PublicBacktestCoreError.invalidDataset("\(series.symbol) has no usable OHLC bars")
            }
        }
    }

    private static func drawdownSeries(from points: [BacktestSeriesPoint]) -> [BacktestSeriesPoint] {
        var peak = 0.0
        return points.enumerated().map { index, point in
            peak = max(peak, point.portfolioValue)
            let drawdown = peak > 0 ? point.portfolioValue / peak - 1 : 0
            return BacktestSeriesPoint(date: point.date, portfolioValue: drawdown, sequence: index)
        }
    }

    private static func sampled(_ points: [BacktestSeriesPoint], maxCount: Int) -> [BacktestSeriesPoint] {
        guard points.count > maxCount, maxCount > 1 else { return points }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        var output: [BacktestSeriesPoint] = []
        output.reserveCapacity(maxCount)
        for index in 0..<maxCount {
            let sourceIndex = min(points.count - 1, Int((Double(index) * step).rounded()))
            let point = points[sourceIndex]
            if output.last?.date != point.date { output.append(point) }
        }
        if output.last?.date != points.last?.date, let last = points.last { output.append(last) }
        return output
    }

    private static func sourceInfo(dataset: PublicBacktestDataset) -> [PublicBacktestSourceInfo] {
        let requiredSymbols = Set(["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite", "usd_per_cny"])
        var values = dataset.seriesBySymbol.compactMap { symbol, series -> PublicBacktestSourceInfo? in
            guard requiredSymbols.contains(symbol) else { return nil }
            return PublicBacktestSourceInfo(
                name: series.label,
                provider: series.source,
                description: "Historical price index series",
                url: nil,
                asOf: series.dates.last,
                symbol: symbol,
                label: series.label
            )
        }
        .sorted { ($0.symbol ?? "") < ($1.symbol ?? "") }
        values.append(PublicBacktestSourceInfo(
            name: "计算口径",
            provider: "Asset Time Machine Swift engine",
            description: "Price return only; dividends are not reinvested. Benchmark is equal-weight buy-and-hold of the strategy's tradable assets.",
            url: nil,
            asOf: dataset.dataCutoff,
            symbol: nil,
            label: "Methodology"
        ))
        return values
    }

    private static func loadForwardNFCI(
        from data: Data,
        availableAtOrBefore decisionAt: Date
    ) throws -> BacktestNFCIAsOfData {
        let payload: ForwardMacroResponsePayload
        do {
            payload = try JSONDecoder().decode(ForwardMacroResponsePayload.self, from: data)
        } catch {
            throw PublicBacktestCoreError.invalidMacroData("JSON decoding failed")
        }
        guard payload.success,
              let creditSeries = payload.series.first(where: { $0.seriesID == "NFCICREDIT" }),
              let leverageSeries = payload.series.first(where: { $0.seriesID == "NFCILEVERAGE" }) else {
            throw PublicBacktestCoreError.invalidMacroData("NFCICREDIT/NFCILEVERAGE are unavailable")
        }

        func map(_ points: [ForwardMacroPointPayload]) throws -> [BacktestNFCIPoint] {
            var output: [BacktestNFCIPoint] = []
            for point in points {
                guard point.value.isFinite,
                      parseDate(point.releaseDate) != nil,
                      parseDate(point.referenceDate) != nil,
                      let availableAt = parseISO8601(point.availableAt) else {
                    throw PublicBacktestCoreError.invalidMacroData("macro point has invalid date/value fields")
                }
                guard availableAt <= decisionAt else { continue }
                output.append(BacktestNFCIPoint(
                    releaseDate: point.releaseDate,
                    referenceDate: point.referenceDate,
                    availableAt: availableAt,
                    value: point.value
                ))
            }
            return output.sorted { $0.releaseDate < $1.releaseDate }
        }

        let credit = try map(creditSeries.points)
        let leverage = try map(leverageSeries.points)
        let result = BacktestNFCIAsOfData(source: payload.source, credit: credit, leverage: leverage)
        guard result.isReadyForC3L3 else {
            throw PublicBacktestCoreError.invalidMacroData("not enough first-seen NFCI points are available at decision time")
        }
        return result
    }

    private static func forwardNFCIState(
        _ nfci: BacktestNFCIAsOfData,
        signalDate: String
    ) -> PublicForwardNFCIState {
        func latest(_ points: [BacktestNFCIPoint]) -> (Int, BacktestNFCIPoint)? {
            var match: (Int, BacktestNFCIPoint)?
            for (index, point) in points.enumerated() {
                guard point.releaseDate <= signalDate else { break }
                match = (index, point)
            }
            return match
        }
        func change(_ points: [BacktestNFCIPoint], latestIndex: Int?, lookback: Int) -> Double? {
            guard let latestIndex, latestIndex >= lookback else { return nil }
            return points[latestIndex].value - points[latestIndex - lookback].value
        }

        let creditLatest = latest(nfci.credit)
        let leverageLatest = latest(nfci.leverage)
        let creditChange = change(nfci.credit, latestIndex: creditLatest?.0, lookback: 8)
        let leverageChange = change(nfci.leverage, latestIndex: leverageLatest?.0, lookback: 4)
        let latestAvailableAt = (nfci.credit + nfci.leverage)
            .compactMap(\.availableAt)
            .max()
        return PublicForwardNFCIState(
            source: nfci.source,
            latestAvailableAt: latestAvailableAt,
            creditReleaseDate: creditLatest?.1.releaseDate,
            creditValue: creditLatest?.1.value,
            creditEightReleaseChange: creditChange,
            creditTriggered: creditChange.map { $0 <= -0.03 } ?? false,
            leverageReleaseDate: leverageLatest?.1.releaseDate,
            leverageValue: leverageLatest?.1.value,
            leverageFourReleaseChange: leverageChange,
            leverageTriggered: leverageChange.map { $0 <= -0.03 } ?? false
        )
    }

    private static func truncatingSeries(
        _ series: PublicHistorySeries,
        through cutoffDateText: String
    ) -> PublicHistorySeries {
        guard let lastIncludedIndex = series.dates.lastIndex(where: { $0 <= cutoffDateText }) else {
            return PublicHistorySeries(
                symbol: series.symbol,
                category: series.category,
                label: series.label,
                currency: series.currency,
                unit: series.unit,
                source: series.source,
                dates: [],
                prices: [],
                hasOHLC: series.hasOHLC,
                ohlcSource: series.ohlcSource,
                ohlcCoverageRatio: series.ohlcCoverageRatio,
                openPrices: series.openPrices.map { _ in [] },
                highPrices: series.highPrices.map { _ in [] },
                lowPrices: series.lowPrices.map { _ in [] },
                closePrices: series.closePrices.map { _ in [] },
                volumes: series.volumes.map { _ in [] }
            )
        }
        let count = lastIncludedIndex + 1
        func prefix(_ values: [Double?]?) -> [Double?]? {
            values.map { Array($0.prefix(count)) }
        }
        return PublicHistorySeries(
            symbol: series.symbol,
            category: series.category,
            label: series.label,
            currency: series.currency,
            unit: series.unit,
            source: series.source,
            dates: Array(series.dates.prefix(count)),
            prices: Array(series.prices.prefix(count)),
            hasOHLC: series.hasOHLC,
            ohlcSource: series.ohlcSource,
            ohlcCoverageRatio: series.ohlcCoverageRatio,
            openPrices: prefix(series.openPrices),
            highPrices: prefix(series.highPrices),
            lowPrices: prefix(series.lowPrices),
            closePrices: prefix(series.closePrices),
            volumes: prefix(series.volumes)
        )
    }

    private static func appendingSyntheticSession(
        to series: PublicHistorySeries,
        dateText: String
    ) -> PublicHistorySeries {
        guard series.dates.last != dateText,
              let lastPrice = series.prices.last,
              lastPrice.isFinite,
              lastPrice > 0 else { return series }

        func appended(_ values: [Double?]?, value: Double?) -> [Double?]? {
            guard var values else { return nil }
            values.append(value)
            return values
        }
        let lastClose = series.closePrices?.last.flatMap { $0 } ?? lastPrice
        let syntheticPrice = lastClose.isFinite && lastClose > 0 ? lastClose : lastPrice
        return PublicHistorySeries(
            symbol: series.symbol,
            category: series.category,
            label: series.label,
            currency: series.currency,
            unit: series.unit,
            source: series.source,
            dates: series.dates + [dateText],
            prices: series.prices + [lastPrice],
            hasOHLC: series.hasOHLC,
            ohlcSource: series.ohlcSource,
            ohlcCoverageRatio: series.ohlcCoverageRatio,
            openPrices: appended(series.openPrices, value: syntheticPrice),
            highPrices: appended(series.highPrices, value: syntheticPrice),
            lowPrices: appended(series.lowPrices, value: syntheticPrice),
            closePrices: appended(series.closePrices, value: syntheticPrice),
            volumes: appended(series.volumes, value: nil)
        )
    }

    private static func nextWeekday(after date: Date) -> Date {
        var candidate = calendar.date(byAdding: .day, value: 1, to: date)
            ?? date.addingTimeInterval(24 * 60 * 60)
        while true {
            let weekday = calendar.component(.weekday, from: candidate)
            if weekday != 1 && weekday != 7 { return candidate }
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate)
                ?? candidate.addingTimeInterval(24 * 60 * 60)
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func forwardCausalInputFingerprint(
        marketSeriesBySymbol: [String: PublicHistorySeries],
        nfci: BacktestNFCIAsOfData,
        dataCutoff: String
    ) -> String {
        var hash: UInt64 = 1469598103934665603
        func mixByte(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        func mixString(_ value: String) {
            for byte in value.utf8 { mixByte(byte) }
            mixByte(0xff)
        }
        func mixUInt64(_ value: UInt64) {
            var remaining = value
            for _ in 0..<8 {
                mixByte(UInt8(remaining & 0xff))
                remaining >>= 8
            }
        }
        func mixDouble(_ value: Double) {
            mixUInt64(value.bitPattern)
        }
        func mixOptionalDouble(_ value: Double?) {
            guard let value, value.isFinite else {
                mixByte(0)
                return
            }
            mixByte(1)
            mixDouble(value)
        }
        func mixOptionalSeries(_ values: [Double?]?) {
            guard let values else {
                mixByte(0)
                return
            }
            mixByte(1)
            mixUInt64(UInt64(values.count))
            for value in values { mixOptionalDouble(value) }
        }

        mixString("market")
        mixString(dataCutoff)
        for symbol in marketSeriesBySymbol.keys.sorted() {
            guard let series = marketSeriesBySymbol[symbol] else { continue }
            mixString(symbol)
            mixUInt64(UInt64(series.dates.count))
            for index in series.dates.indices {
                mixString(series.dates[index])
                mixDouble(series.prices[index])
            }
            mixOptionalSeries(series.openPrices)
            mixOptionalSeries(series.highPrices)
            mixOptionalSeries(series.lowPrices)
            mixOptionalSeries(series.closePrices)
        }

        func mixNFCIPoints(_ label: String, _ points: [BacktestNFCIPoint]) {
            let causalPoints = points.filter { $0.releaseDate <= dataCutoff }
            mixString(label)
            mixUInt64(UInt64(causalPoints.count))
            for point in causalPoints {
                mixString(point.releaseDate)
                mixString(point.referenceDate)
                mixDouble(point.value)
                if let availableAt = point.availableAt {
                    mixByte(1)
                    mixDouble(availableAt.timeIntervalSince1970)
                } else {
                    mixByte(0)
                }
            }
        }
        mixString("nfci")
        mixString(nfci.source)
        mixNFCIPoints("credit", nfci.credit)
        mixNFCIPoints("leverage", nfci.leverage)
        return String(format: "%016llx", hash)
    }

    private static func forwardTargetFingerprint(_ weights: [String: Double]) -> String {
        var hash: UInt64 = 1469598103934665603
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        for symbol in weights.keys.sorted() {
            for byte in symbol.utf8 { mix(byte) }
            mix(0)
            var quantized = UInt64(bitPattern: Int64(((weights[symbol] ?? 0) * 100_000_000).rounded()))
            for _ in 0..<8 {
                mix(UInt8(quantized & 0xff))
                quantized >>= 8
            }
        }
        return String(format: "%016llx", hash)
    }

    private static func normalizedHistorySymbol(_ symbol: String) -> String {
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
        default:
            return symbol
        }
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }

    private static func parseDate(_ value: String) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = components.date else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day], from: date)
        guard verified.year == year, verified.month == month, verified.day == day else { return nil }
        return date
    }

    private static func dateString(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}
