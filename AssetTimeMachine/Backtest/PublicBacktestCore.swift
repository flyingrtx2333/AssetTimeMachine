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

    public init(strategyID: String, startDate: String, endDate: String, initialCash: Double) {
        self.strategyID = strategyID
        self.startDate = startDate
        self.endDate = endDate
        self.initialCash = initialCash
    }

    enum CodingKeys: String, CodingKey {
        case strategyID = "strategy_id"
        case startDate = "start_date"
        case endDate = "end_date"
        case initialCash = "initial_cash"
    }
}

public enum PublicBacktestComputeMode: String, Codable, Sendable {
    case prewarm
    case run
}

public struct PublicBacktestComputeInvocation: Codable, Sendable {
    public let mode: PublicBacktestComputeMode
    public let datasetPath: String
    public let datasetHash: String
    public let dataStale: Bool
    public let strategyID: String?
    public let request: PublicBacktestRunRequest?

    public init(
        mode: PublicBacktestComputeMode,
        datasetPath: String,
        datasetHash: String,
        dataStale: Bool,
        strategyID: String? = nil,
        request: PublicBacktestRunRequest? = nil
    ) {
        self.mode = mode
        self.datasetPath = datasetPath
        self.datasetHash = datasetHash
        self.dataStale = dataStale
        self.strategyID = strategyID
        self.request = request
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
    case unknownStrategy
    case invalidDate
    case invalidRange(String)
    case invalidInitialCash
    case computationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDataset(let detail):
            return "Invalid market dataset: \(detail)"
        case .unknownStrategy:
            return "Unknown or unavailable strategy"
        case .invalidDate:
            return "Dates must use the yyyy-MM-dd Gregorian format"
        case .invalidRange(let detail):
            return "Invalid backtest range: \(detail)"
        case .invalidInitialCash:
            return "Initial cash must be between CNY 10,000 and CNY 10,000,000"
        case .computationFailed:
            return "The Swift backtest engine could not produce a result"
        }
    }
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

    private static let strategyDescriptors: [StrategyDescriptor] = [
        .init(
            id: "core-gold-satellite-equity-curve-state-gate-momentum",
            name: "均衡权益状态",
            riskLevel: "中等",
            summary: "以跨市场趋势和组合状态协同控制风险预算，在风险走弱阶段自动收缩。",
            assetScope: ["黄金", "美国权益指数", "中国权益指数", "现金"],
            experimental: false,
            maxGrossExposure: 1.0,
            financingRate: nil
        ),
        .init(
            id: "core-gold-satellite-risk-budget-state-gate-momentum",
            name: "进取风险预算",
            riskLevel: "中高",
            summary: "在防守与进取引擎之间分配风险预算，侧重长期宽度确认与成本约束。",
            assetScope: ["黄金", "美国权益指数", "中国权益指数", "现金"],
            experimental: false,
            maxGrossExposure: 1.0,
            financingRate: nil
        ),
        .init(
            id: "core-gold-satellite-profit-lock-momentum",
            name: "稳健锁盈防守",
            riskLevel: "中低",
            summary: "根据组合回撤与快速上涨后的状态平滑降低风险预算，强调持有体验。",
            assetScope: ["黄金", "美国权益指数", "中国权益指数", "现金"],
            experimental: false,
            maxGrossExposure: 1.0,
            financingRate: nil
        ),
        .init(
            id: "risk-contribution-reallocation",
            name: "风险贡献再分配",
            riskLevel: "高",
            summary: "实验性多引擎组合，依据协方差和风险贡献在低相关资产之间再分配。",
            assetScope: ["黄金", "美国权益指数", "中国权益指数", "现金及融资"],
            experimental: true,
            maxGrossExposure: 1.10,
            financingRate: 0.05
        ),
        .init(
            id: "gold-nasdaq-dual-trend-barbell",
            name: "双趋势金纳杠铃",
            riskLevel: "中高",
            summary: "黄金与纳指分别判断长期趋势，弱势时降低对应仓位并保留现金。",
            assetScope: ["黄金", "纳斯达克指数", "现金"],
            experimental: false,
            maxGrossExposure: 1.0,
            financingRate: nil
        )
    ]

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

        guard let descriptor = strategyDescriptors.first(where: { $0.id == request.strategyID }) else {
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
        let settings = AdvancedBacktestRiskSettings(
            feeRate: BacktestDefaults.advancedFeeRatePercent,
            slippageRate: BacktestDefaults.advancedSlippageRatePercent,
            maxPositionRatio: template.maxPositionRatio,
            cooldownDays: template.cooldownDays,
            stopLossRatio: template.stopLossRatio,
            takeProfitRatio: template.takeProfitRatio
        )
        guard let report = BacktestEngine.runAdvancedRotationStrategy(
            assetInputs: inputs,
            initialCash: request.initialCash,
            settings: settings,
            mode: template.mode,
            dateBounds: dateBounds
        ) else {
            if Task.isCancelled { throw CancellationError() }
            throw PublicBacktestCoreError.computationFailed
        }
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
