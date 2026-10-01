import Foundation

@frozen public enum BacktestRecordKind: String, Codable, CaseIterable {
    case allocation
    case dca
    case advanced

    public var title: String {
        switch self {
        case .allocation:
            return BacktestText.string("配置回测")
        case .dca:
            return BacktestText.string("定投回测")
        case .advanced:
            return BacktestText.string("策略回测")
        }
    }

    public var entryIconName: String {
        switch self {
        case .allocation:
            return "chart.pie.fill"
        case .dca:
            return "calendar.badge.plus"
        case .advanced:
            return "slider.horizontal.3"
        }
    }



}


public struct BacktestRecordPointPayload: Codable {
    public let date: Date
    public let value: Double
    public let sequence: Int

    public init(date: Date, value: Double, sequence: Int) {
        self.date = date
        self.value = value
        self.sequence = sequence
    }

    public init(point: BacktestSeriesPoint, sequence: Int) {
        self.date = point.date
        self.value = point.portfolioValue
        self.sequence = sequence
    }

    public var seriesPoint: BacktestSeriesPoint {
        BacktestSeriesPoint(date: date, portfolioValue: value, sequence: sequence)
    }
}


public struct BacktestRecordAdvancedPricePayload: Codable, Identifiable {
    public let date: Date
    public let price: Double
    public let sequence: Int

    public var id: Int { sequence }

    public var pricePoint: AdvancedBacktestPricePoint {
        AdvancedBacktestPricePoint(date: date, price: price, sequence: sequence)
    }
    public init(
        date: Date,
        price: Double,
        sequence: Int
    ) {
        self.date = date
        self.price = price
        self.sequence = sequence
    }
}


public struct BacktestRecordAdvancedTradePayload: Codable, Identifiable {
    public let assetSymbol: String
    public let assetTitle: String
    public let date: Date
    public let actionRawValue: String
    public let price: Double
    public let cashAmount: Double
    public let units: Double
    public let reason: String?
    public let realizedProfit: Double?
    public let realizedReturn: Double?
    public let holdingDays: Int?
    public let sequence: Int

    public var id: String { "\(assetSymbol)-\(actionRawValue)-\(date.timeIntervalSinceReferenceDate)-\(sequence)" }

    public var action: AdvancedBacktestTradeAction {
        AdvancedBacktestTradeAction(rawValue: actionRawValue) ?? .buy
    }

    public init(
        assetSymbol: String,
        assetTitle: String,
        date: Date,
        actionRawValue: String,
        price: Double,
        cashAmount: Double,
        units: Double,
        reason: String? = nil,
        realizedProfit: Double? = nil,
        realizedReturn: Double? = nil,
        holdingDays: Int? = nil,
        sequence: Int
    ) {
        self.assetSymbol = assetSymbol
        self.assetTitle = assetTitle
        self.date = date
        self.actionRawValue = actionRawValue
        self.price = price
        self.cashAmount = cashAmount
        self.units = units
        self.reason = reason
        self.realizedProfit = realizedProfit
        self.realizedReturn = realizedReturn
        self.holdingDays = holdingDays
        self.sequence = sequence
    }

    public init(trade: AdvancedBacktestTrade, sequence: Int) {
        self.assetSymbol = trade.assetSymbol
        self.assetTitle = trade.assetTitle
        self.date = trade.date
        self.actionRawValue = trade.action.rawValue
        self.price = trade.price
        self.cashAmount = trade.cashAmount
        self.units = trade.units
        self.reason = trade.reason
        self.realizedProfit = trade.realizedProfit
        self.realizedReturn = trade.realizedReturn
        self.holdingDays = trade.holdingDays
        self.sequence = sequence
    }

    public var advancedTrade: AdvancedBacktestTrade {
        AdvancedBacktestTrade(
            assetSymbol: assetSymbol,
            assetTitle: assetTitle,
            date: date,
            action: action,
            price: price,
            cashAmount: cashAmount,
            units: units,
            reason: reason ?? "",
            realizedProfit: realizedProfit,
            realizedReturn: realizedReturn,
            holdingDays: holdingDays
        )
    }
}


public struct BacktestRecordAdvancedAssetChartPayload: Codable, Identifiable {
    public let symbol: String
    public let title: String
    public let pricePoints: [BacktestRecordAdvancedPricePayload]
    public var portfolioPoints: [BacktestRecordPointPayload]? = nil
    public let benchmarkPoints: [BacktestRecordPointPayload]?
    public let trades: [BacktestRecordAdvancedTradePayload]
    public var finalPortfolioValue: Double? = nil
    public var finalCash: Double? = nil
    public var finalUnits: Double? = nil
    public var exposureRatio: Double? = nil

    public var id: String { symbol }

    public var decodedBenchmarkPoints: [BacktestSeriesPoint] {
        (benchmarkPoints ?? [])
            .sorted { $0.sequence < $1.sequence }
            .map(\.seriesPoint)
    }

    public var decodedPortfolioPoints: [BacktestSeriesPoint] {
        (portfolioPoints ?? [])
            .sorted { $0.sequence < $1.sequence }
            .map(\.seriesPoint)
    }
    public init(
        symbol: String,
        title: String,
        pricePoints: [BacktestRecordAdvancedPricePayload],
        portfolioPoints: [BacktestRecordPointPayload]? = nil,
        benchmarkPoints: [BacktestRecordPointPayload]?,
        trades: [BacktestRecordAdvancedTradePayload],
        finalPortfolioValue: Double? = nil,
        finalCash: Double? = nil,
        finalUnits: Double? = nil,
        exposureRatio: Double? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.pricePoints = pricePoints
        self.portfolioPoints = portfolioPoints
        self.benchmarkPoints = benchmarkPoints
        self.trades = trades
        self.finalPortfolioValue = finalPortfolioValue
        self.finalCash = finalCash
        self.finalUnits = finalUnits
        self.exposureRatio = exposureRatio
    }
}


public struct BacktestRecordAdvancedBenchmarkSeriesPayload: Codable, Identifiable {
    public let id: String
    public let title: String
    public let points: [BacktestRecordPointPayload]

    public var decodedPoints: [BacktestSeriesPoint] {
        points
            .sorted { $0.sequence < $1.sequence }
            .map(\.seriesPoint)
    }
    public init(
        id: String,
        title: String,
        points: [BacktestRecordPointPayload]
    ) {
        self.id = id
        self.title = title
        self.points = points
    }
}


public struct BacktestRecordExposurePointPayload: Codable {
    public let date: Date
    public let ratio: Double
    public let sequence: Int

    public init(point: BacktestExposurePoint, sequence: Int) {
        date = point.date
        ratio = point.ratio
        self.sequence = sequence
    }

    public var exposurePoint: BacktestExposurePoint {
        BacktestExposurePoint(date: date, ratio: ratio, sequence: sequence)
    }
}


public struct BacktestRecordAssetExposureSeriesPayload: Codable {
    public let symbol: String
    public let title: String
    public let points: [BacktestRecordExposurePointPayload]

    public init(series: BacktestAssetExposureSeries, maxPointCount: Int) {
        symbol = series.symbol
        title = series.title
        points = BacktestExposureSampling.sampled(series.points, maxCount: maxPointCount)
            .enumerated()
            .map { index, point in
                BacktestRecordExposurePointPayload(point: point, sequence: index)
            }
    }

    public var assetExposureSeries: BacktestAssetExposureSeries {
        BacktestAssetExposureSeries(
            symbol: symbol,
            title: title,
            points: points.sorted { $0.sequence < $1.sequence }.map(\.exposurePoint)
        )
    }
}


public struct BacktestRecordCashYieldRatePointPayload: Codable {
    public let date: Date
    public let annualRate: Double

    public init(point: CashYieldRatePoint) {
        date = point.date
        annualRate = point.annualRate
    }

    public var ratePoint: CashYieldRatePoint {
        CashYieldRatePoint(date: date, annualRate: annualRate)
    }
}


public struct BacktestRecordCashYieldSummaryPayload: Codable {
    public let title: String
    public let source: String
    public let sourceDetail: String
    public let startDate: Date?
    public let endDate: Date?
    public let latestRateDate: Date?
    public let latestAnnualRate: Double
    public let averageAnnualRate: Double
    public let averageCashRatio: Double
    public let totalCashInterest: Double
    public let ratePoints: [BacktestRecordCashYieldRatePointPayload]

    public init(summary: CashYieldSummary, maxRatePointCount: Int = 60) {
        title = summary.title
        source = summary.source
        sourceDetail = summary.sourceDetail
        startDate = summary.startDate
        endDate = summary.endDate
        latestRateDate = summary.latestRateDate
        latestAnnualRate = summary.latestAnnualRate
        averageAnnualRate = summary.averageAnnualRate
        averageCashRatio = summary.averageCashRatio
        totalCashInterest = summary.totalCashInterest
        let sampledPoints = evenlySampledItems(summary.ratePoints, maxCount: maxRatePointCount)
        ratePoints = sampledPoints.map(BacktestRecordCashYieldRatePointPayload.init(point:))
    }

    public var cashYieldSummary: CashYieldSummary {
        CashYieldSummary(
            title: title,
            source: source,
            sourceDetail: sourceDetail,
            startDate: startDate,
            endDate: endDate,
            latestRateDate: latestRateDate,
            latestAnnualRate: latestAnnualRate,
            averageAnnualRate: averageAnnualRate,
            averageCashRatio: averageCashRatio,
            totalCashInterest: totalCashInterest,
            ratePoints: ratePoints.map(\.ratePoint)
        )
    }
}


public struct BacktestRecordRiskSignalPointPayload: Codable {
    public let date: Date
    public let score: Double
    public let levelRawValue: String
    public let sourceTitle: String
    public let shortReturn: Double?
    public let monthlyReturn: Double?
    public let drawdownFromHigh: Double?
    public let annualizedVolatility: Double?

    public init(point: MarketRiskSignalPoint) {
        date = point.date
        score = point.score
        levelRawValue = point.level.rawValue
        sourceTitle = point.sourceTitle
        shortReturn = point.shortReturn
        monthlyReturn = point.monthlyReturn
        drawdownFromHigh = point.drawdownFromHigh
        annualizedVolatility = point.annualizedVolatility
    }

    public var signalPoint: MarketRiskSignalPoint {
        MarketRiskSignalPoint(
            date: date,
            score: score,
            level: MarketRiskSignalLevel(rawValue: levelRawValue) ?? .calm,
            sourceTitle: sourceTitle,
            shortReturn: shortReturn,
            monthlyReturn: monthlyReturn,
            drawdownFromHigh: drawdownFromHigh,
            annualizedVolatility: annualizedVolatility
        )
    }
}


public struct BacktestRecordRiskSignalSummaryPayload: Codable {
    public let title: String
    public let source: String
    public let sourceDetail: String
    public let startDate: Date?
    public let endDate: Date?
    public let latestPoint: BacktestRecordRiskSignalPointPayload?
    public let averageScore: Double
    public let stressSessionRatio: Double
    public let signalPoints: [BacktestRecordRiskSignalPointPayload]

    public init(summary: MarketRiskSignalSummary, maxSignalPointCount: Int = 120) {
        title = summary.title
        source = summary.source
        sourceDetail = summary.sourceDetail
        startDate = summary.startDate
        endDate = summary.endDate
        latestPoint = summary.latestPoint.map(BacktestRecordRiskSignalPointPayload.init(point:))
        averageScore = summary.averageScore
        stressSessionRatio = summary.stressSessionRatio
        let sampledPoints = evenlySampledItems(summary.signalPoints, maxCount: maxSignalPointCount)
        signalPoints = sampledPoints.map(BacktestRecordRiskSignalPointPayload.init(point:))
    }

    public var riskSignalSummary: MarketRiskSignalSummary {
        let points = signalPoints.map(\.signalPoint)
        return MarketRiskSignalSummary(
            title: title,
            source: source,
            sourceDetail: sourceDetail,
            startDate: startDate,
            endDate: endDate,
            latestPoint: latestPoint?.signalPoint ?? points.last,
            averageScore: averageScore,
            stressSessionRatio: stressSessionRatio,
            signalPoints: points
        )
    }
}


/// Additive record metadata. Older records have nil provenance; their missing
/// source/data identity is never inferred from the current build.
public struct BacktestRecordRuntimeProvenance: Codable, Sendable {
    public let strategy: StrategyReference?
    public let executionVersion: String
    public let frozenParametersJSON: Data?
    public let parametersSHA256: String?
    public let datasetSHA256: String?
    public let sourceCommit: String

    public init(strategy: StrategyReference?, executionVersion: String,
                frozenParametersJSON: Data? = nil, parametersSHA256: String? = nil,
                datasetSHA256: String? = nil, sourceCommit: String = "unknown") {
        self.strategy = strategy; self.executionVersion = executionVersion
        self.frozenParametersJSON = frozenParametersJSON; self.parametersSHA256 = parametersSHA256
        self.datasetSHA256 = datasetSHA256; self.sourceCommit = sourceCommit
    }
}

public struct BacktestRecordConfigPayload: Codable {
    public var kind: BacktestRecordKind
    public var cashWeight: Double? = nil
    public var goldWeight: Double? = nil
    public var indexWeights: [String: Double]? = nil
    public var dcaAssetSymbol: String? = nil
    public var dcaContributionAmount: Double? = nil
    public var dcaIntervalDays: Int? = nil
    public var selectedAssetSymbol: String? = nil
    public var selectedAssetSymbols: [String]? = nil
    public var initialCash: Double? = nil
    public var tradeAmount: Double? = nil
    public var feeRate: Double? = nil
    public var slippageRate: Double? = nil
    public var maxPositionRatio: Double? = nil
    public var cooldownDays: Int? = nil
    public var stopLossRatio: Double? = nil
    public var takeProfitRatio: Double? = nil
    public var strategyModeRawValue: String? = nil
    public var buyDirectionRawValue: String? = nil
    public var buyDays: Int? = nil
    public var sellDirectionRawValue: String? = nil
    public var sellDays: Int? = nil
    public var advancedTrades: [BacktestRecordAdvancedTradePayload]? = nil
    public var advancedAssetCharts: [BacktestRecordAdvancedAssetChartPayload]? = nil
    public var advancedBenchmarkSeries: [BacktestRecordAdvancedBenchmarkSeriesPayload]? = nil
    public var advancedCombinedBenchmarkPoints: [BacktestRecordPointPayload]? = nil
    public var advancedExposurePoints: [BacktestRecordExposurePointPayload]? = nil
    public var advancedAssetExposureSeries: [BacktestRecordAssetExposureSeriesPayload]? = nil
    public var advancedAverageExposureRatio: Double? = nil
    public var finalCash: Double? = nil
    public var finalUnits: Double? = nil
    public var cashYieldSummary: BacktestRecordCashYieldSummaryPayload? = nil
    public var riskSignalSummary: BacktestRecordRiskSignalSummaryPayload? = nil
    public var runtimeProvenance: BacktestRecordRuntimeProvenance? = nil
    public init(
        kind: BacktestRecordKind,
        cashWeight: Double? = nil,
        goldWeight: Double? = nil,
        indexWeights: [String: Double]? = nil,
        dcaAssetSymbol: String? = nil,
        dcaContributionAmount: Double? = nil,
        dcaIntervalDays: Int? = nil,
        selectedAssetSymbol: String? = nil,
        selectedAssetSymbols: [String]? = nil,
        initialCash: Double? = nil,
        tradeAmount: Double? = nil,
        feeRate: Double? = nil,
        slippageRate: Double? = nil,
        maxPositionRatio: Double? = nil,
        cooldownDays: Int? = nil,
        stopLossRatio: Double? = nil,
        takeProfitRatio: Double? = nil,
        strategyModeRawValue: String? = nil,
        buyDirectionRawValue: String? = nil,
        buyDays: Int? = nil,
        sellDirectionRawValue: String? = nil,
        sellDays: Int? = nil,
        advancedTrades: [BacktestRecordAdvancedTradePayload]? = nil,
        advancedAssetCharts: [BacktestRecordAdvancedAssetChartPayload]? = nil,
        advancedBenchmarkSeries: [BacktestRecordAdvancedBenchmarkSeriesPayload]? = nil,
        advancedCombinedBenchmarkPoints: [BacktestRecordPointPayload]? = nil,
        advancedExposurePoints: [BacktestRecordExposurePointPayload]? = nil,
        advancedAssetExposureSeries: [BacktestRecordAssetExposureSeriesPayload]? = nil,
        advancedAverageExposureRatio: Double? = nil,
        finalCash: Double? = nil,
        finalUnits: Double? = nil,
        cashYieldSummary: BacktestRecordCashYieldSummaryPayload? = nil,
        riskSignalSummary: BacktestRecordRiskSignalSummaryPayload? = nil,
        runtimeProvenance: BacktestRecordRuntimeProvenance? = nil
    ) {
        self.kind = kind
        self.cashWeight = cashWeight
        self.goldWeight = goldWeight
        self.indexWeights = indexWeights
        self.dcaAssetSymbol = dcaAssetSymbol
        self.dcaContributionAmount = dcaContributionAmount
        self.dcaIntervalDays = dcaIntervalDays
        self.selectedAssetSymbol = selectedAssetSymbol
        self.selectedAssetSymbols = selectedAssetSymbols
        self.initialCash = initialCash
        self.tradeAmount = tradeAmount
        self.feeRate = feeRate
        self.slippageRate = slippageRate
        self.maxPositionRatio = maxPositionRatio
        self.cooldownDays = cooldownDays
        self.stopLossRatio = stopLossRatio
        self.takeProfitRatio = takeProfitRatio
        self.strategyModeRawValue = strategyModeRawValue
        self.buyDirectionRawValue = buyDirectionRawValue
        self.buyDays = buyDays
        self.sellDirectionRawValue = sellDirectionRawValue
        self.sellDays = sellDays
        self.advancedTrades = advancedTrades
        self.advancedAssetCharts = advancedAssetCharts
        self.advancedBenchmarkSeries = advancedBenchmarkSeries
        self.advancedCombinedBenchmarkPoints = advancedCombinedBenchmarkPoints
        self.advancedExposurePoints = advancedExposurePoints
        self.advancedAssetExposureSeries = advancedAssetExposureSeries
        self.advancedAverageExposureRatio = advancedAverageExposureRatio
        self.finalCash = finalCash
        self.finalUnits = finalUnits
        self.cashYieldSummary = cashYieldSummary
        self.riskSignalSummary = riskSignalSummary
        self.runtimeProvenance = runtimeProvenance
    }
}


public struct AdvancedBacktestRestoreRequest {
    public let id: UUID
    public let config: BacktestRecordConfigPayload
    public let startDate: Date?
    public let endDate: Date?
    public init(
        id: UUID,
        config: BacktestRecordConfigPayload,
        startDate: Date?,
        endDate: Date?
    ) {
        self.id = id
        self.config = config
        self.startDate = startDate
        self.endDate = endDate
    }
}


public enum BacktestRecordCodec {
    public static func recordSignature(
        kindRawValue: String,
        subtitle: String,
        configSummary: String,
        startDate: Date?,
        endDate: Date?,
        totalReturn: Double,
        maxDrawdown: Double,
        finalValue: Double?,
        tradeCount: Int
    ) -> String {
        [
            kindRawValue,
            subtitle,
            configSummary,
            startDate?.backtestDateKey ?? "nil",
            endDate?.backtestDateKey ?? "nil",
            String(format: "%.8f", totalReturn),
            String(format: "%.8f", maxDrawdown),
            String(format: "%.4f", finalValue ?? 0),
            String(tradeCount)
        ].joined(separator: "|")
    }

    private static func encodeOrFallback<T: Encodable>(
        _ payload: T,
        fallbackJSON: String,
        context: String
    ) -> Data {
        do {
            return try JSONEncoder().encode(payload)
        } catch {
            print("[AssetTimeMachine] encode backtest record \(context) failed: \(error)")
            return Data(fallbackJSON.utf8)
        }
    }

    public static func pointsData(from points: [BacktestSeriesPoint], maxCount: Int = 240) -> Data {
        let payload = pointPayloads(from: points, maxCount: maxCount)
        return encodeOrFallback(payload, fallbackJSON: "[]", context: "points")
    }

    public static func pointPayloads(
        from points: [BacktestSeriesPoint],
        maxCount: Int = 240
    ) -> [BacktestRecordPointPayload] {
        sampled(points, maxCount: maxCount).enumerated().map { index, point in
            BacktestRecordPointPayload(point: point, sequence: index)
        }
    }

    public static func configData(from payload: BacktestRecordConfigPayload) -> Data {
        encodeOrFallback(payload, fallbackJSON: "{}", context: "config")
    }

    public static func cashYieldSummaryPayload(from summary: CashYieldSummary, maxRatePointCount: Int = 60) -> BacktestRecordCashYieldSummaryPayload {
        BacktestRecordCashYieldSummaryPayload(summary: summary, maxRatePointCount: maxRatePointCount)
    }

    public static func riskSignalSummaryPayload(from summary: MarketRiskSignalSummary, maxSignalPointCount: Int = 120) -> BacktestRecordRiskSignalSummaryPayload {
        BacktestRecordRiskSignalSummaryPayload(summary: summary, maxSignalPointCount: maxSignalPointCount)
    }

    public static func advancedTradePayloads(from trades: [AdvancedBacktestTrade]) -> [BacktestRecordAdvancedTradePayload] {
        trades.enumerated().map { index, trade in
            BacktestRecordAdvancedTradePayload(trade: trade, sequence: index)
        }
    }

    public static func advancedBenchmarkSeriesPayloads(
        from series: [AdvancedBacktestBenchmarkSeries],
        maxPointCount: Int = 240
    ) -> [BacktestRecordAdvancedBenchmarkSeriesPayload] {
        series.map { benchmarkSeries in
            let sampledPoints = sampled(benchmarkSeries.points, maxCount: maxPointCount)
                .enumerated()
                .map { index, point in
                    BacktestRecordPointPayload(point: point, sequence: index)
                }
            return BacktestRecordAdvancedBenchmarkSeriesPayload(
                id: benchmarkSeries.id,
                title: benchmarkSeries.title,
                points: sampledPoints
            )
        }
    }

    public static func exposurePointPayloads(
        from points: [BacktestExposurePoint],
        maxCount: Int = 360
    ) -> [BacktestRecordExposurePointPayload] {
        BacktestExposureSampling.sampled(points, maxCount: maxCount).enumerated().map { index, point in
            BacktestRecordExposurePointPayload(point: point, sequence: index)
        }
    }

    public static func assetExposureSeriesPayloads(
        from series: [BacktestAssetExposureSeries],
        maxPointCount: Int = BacktestExposureSampling.assetSeriesMaxCount
    ) -> [BacktestRecordAssetExposureSeriesPayload] {
        series.map { BacktestRecordAssetExposureSeriesPayload(series: $0, maxPointCount: maxPointCount) }
    }

    public static func advancedAssetChartPayloads(from assetReports: [AdvancedBacktestAssetReport], maxPricePointCount: Int = 240) -> [BacktestRecordAdvancedAssetChartPayload] {
        assetReports.map { assetReport in
            let sampledPricePoints = sampled(assetReport.pricePoints, maxCount: maxPricePointCount)
                .enumerated()
                .map { index, point in
                    BacktestRecordAdvancedPricePayload(date: point.date, price: point.price, sequence: index)
                }
            let sampledBenchmarkPoints = sampled(assetReport.benchmarkPoints, maxCount: maxPricePointCount)
                .enumerated()
                .map { index, point in
                    BacktestRecordPointPayload(point: point, sequence: index)
                }
            let sampledPortfolioPoints = sampled(assetReport.points, maxCount: maxPricePointCount)
                .enumerated()
                .map { index, point in
                    BacktestRecordPointPayload(point: point, sequence: index)
                }
            let trades = advancedTradePayloads(from: assetReport.trades)
            return BacktestRecordAdvancedAssetChartPayload(
                symbol: assetReport.symbol,
                title: assetReport.title,
                pricePoints: sampledPricePoints,
                portfolioPoints: sampledPortfolioPoints,
                benchmarkPoints: sampledBenchmarkPoints,
                trades: trades,
                finalPortfolioValue: assetReport.finalPortfolioValue,
                finalCash: assetReport.finalCash,
                finalUnits: assetReport.finalUnits,
                exposureRatio: assetReport.exposureRatio
            )
        }
    }

    public static func decodePoints(from record: BacktestStoredRecord) -> [BacktestSeriesPoint] {
        guard !record.pointsJSON.isEmpty else {
            return []
        }
        let payload: [BacktestRecordPointPayload]
        do {
            payload = try JSONDecoder().decode([BacktestRecordPointPayload].self, from: record.pointsJSON)
        } catch {
            print("[AssetTimeMachine] decode backtest record points failed: title=\(record.title) kind=\(record.kindRawValue) error=\(error)")
            return []
        }
        return payload
            .sorted { $0.sequence < $1.sequence }
            .map(\.seriesPoint)
    }

    public static func decodeConfig(from record: BacktestStoredRecord) -> BacktestRecordConfigPayload? {
        guard !record.configJSON.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(BacktestRecordConfigPayload.self, from: record.configJSON)
        } catch {
            print("[AssetTimeMachine] decode backtest record config failed: title=\(record.title) kind=\(record.kindRawValue) error=\(error)")
            return nil
        }
    }

    public static func kind(for record: BacktestStoredRecord) -> BacktestRecordKind {
        BacktestRecordKind(rawValue: record.kindRawValue) ?? .allocation
    }

    public static func advancedStrategyDisplayTitle(for record: BacktestStoredRecord) -> String {
        guard kind(for: record) == .advanced else { return BacktestText.string(record.title) }

        // Newer records persist the strategy title at the front of the summary.
        // Prefer that lightweight field so scrolling history does not fault and
        // decode every externally stored configuration payload.
        let summaryLead = record.configSummary
            .split(separator: "·", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        if let summaryLead, !summaryLead.isEmpty {
            return BacktestText.string(summaryLead)
        }

        // Keep decoding as a compatibility fallback for old records that were
        // saved before configSummary included a strategy title.
        if let config = decodeConfig(from: record),
           let modeRaw = config.strategyModeRawValue,
           let mode = AdvancedBacktestStrategyMode(rawValue: modeRaw) {
            if mode != .ruleBased {
                return mode.title
            }
            if let template = AdvancedBacktestStrategyTemplate.all.first(where: { matchesStrategyTemplate($0, config: config) }) {
                return template.title
            }
        }

        if !record.subtitle.isEmpty,
           !record.subtitle.contains("·") {
            return record.subtitle
        }

        return AdvancedBacktestStrategyMode.ruleBased.title
    }

    private static func matchesStrategyTemplate(
        _ template: AdvancedBacktestStrategyTemplate,
        config: BacktestRecordConfigPayload
    ) -> Bool {
        guard let modeRaw = config.strategyModeRawValue,
              let mode = AdvancedBacktestStrategyMode(rawValue: modeRaw),
              mode == template.mode else {
            return false
        }

        if let selectedSymbols = template.selectedAssetSymbols {
            let recordSymbols = Set(config.selectedAssetSymbols ?? config.selectedAssetSymbol.map { [$0] } ?? [])
            if recordSymbols != Set(selectedSymbols) {
                return false
            }
        }

        if template.mode.isRotation {
            let feeRate = config.feeRate ?? BacktestCoreDefaults.advancedFeeRatePercent
            let slippageRate = config.slippageRate ?? BacktestCoreDefaults.advancedSlippageRatePercent
            return abs(feeRate - BacktestCoreDefaults.advancedFeeRatePercent) < 0.01 && abs(slippageRate - BacktestCoreDefaults.advancedSlippageRatePercent) < 0.01
        }

        guard let buyDirectionRawValue = config.buyDirectionRawValue,
              let buyDirection = AdvancedBacktestSignalDirection(rawValue: buyDirectionRawValue),
              let sellDirectionRawValue = config.sellDirectionRawValue,
              let sellDirection = AdvancedBacktestSignalDirection(rawValue: sellDirectionRawValue),
              let initialCash = config.initialCash,
              let tradeAmount = config.tradeAmount,
              let maxPositionRatio = config.maxPositionRatio,
              let feeRate = config.feeRate,
              let slippageRate = config.slippageRate,
              let cooldownDays = config.cooldownDays,
              let stopLossRatio = config.stopLossRatio,
              let takeProfitRatio = config.takeProfitRatio,
              let buyDays = config.buyDays,
              let sellDays = config.sellDays else {
            return false
        }

        let expectedTradeAmount = max(initialCash * template.tradeAmountRatio, 1)
        let tradeTolerance = max(expectedTradeAmount * 0.005, 1)

        return buyDirection == template.buyRule.direction
            && buyDays == template.buyRule.days
            && sellDirection == template.sellRule.direction
            && sellDays == template.sellRule.days
            && abs(tradeAmount - expectedTradeAmount) <= tradeTolerance
            && abs(maxPositionRatio - template.maxPositionRatio) < 0.01
            && abs(feeRate - BacktestCoreDefaults.advancedFeeRatePercent) < 0.01
            && abs(slippageRate - BacktestCoreDefaults.advancedSlippageRatePercent) < 0.01
            && abs(Double(cooldownDays) - Double(template.cooldownDays)) < 0.01
            && abs(stopLossRatio - template.stopLossRatio) < 0.01
            && abs(takeProfitRatio - template.takeProfitRatio) < 0.01
    }

    public static func advancedReport(from record: BacktestStoredRecord) -> AdvancedBacktestReport? {
        guard kind(for: record) == .advanced,
              let config = decodeConfig(from: record) else { return nil }

        let points = decodePoints(from: record)
        guard !points.isEmpty else { return nil }

        let trades = (config.advancedTrades ?? []).map(\.advancedTrade)
        let benchmarkSeries = (config.advancedBenchmarkSeries ?? []).map {
            AdvancedBacktestBenchmarkSeries(id: $0.id, title: $0.title, points: $0.decodedPoints)
        }
        let storedCombinedBenchmarkPoints = (config.advancedCombinedBenchmarkPoints ?? [])
            .sorted { $0.sequence < $1.sequence }
            .map(\.seriesPoint)
        let benchmarkPoints = storedCombinedBenchmarkPoints.isEmpty
            ? combinedBenchmarkPoints(
                from: benchmarkSeries,
                initialPortfolioValue: points.first?.portfolioValue ?? 0
            )
            : storedCombinedBenchmarkPoints
        let assetReports = advancedAssetReports(from: config)
        let finalPortfolioValue = record.finalValue ?? points.last?.portfolioValue ?? 0
        let exposurePoints = (config.advancedExposurePoints ?? [])
            .sorted { $0.sequence < $1.sequence }
            .map(\.exposurePoint)
        let assetExposureSeries = (config.advancedAssetExposureSeries ?? [])
            .map(\.assetExposureSeries)

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: benchmarkPoints,
            benchmarkSeries: benchmarkSeries,
            trades: trades,
            assetReports: assetReports,
            finalPortfolioValue: finalPortfolioValue,
            finalCash: config.finalCash ?? 0,
            finalUnits: config.finalUnits ?? 0,
            totalReturn: record.totalReturn,
            annualizedReturn: record.annualizedReturn,
            maxDrawdown: record.maxDrawdown,
            annualizedVolatility: record.annualizedVolatility,
            sharpeRatio: record.sharpeRatio,
            cashYieldSummary: config.cashYieldSummary?.cashYieldSummary ?? defaultCashYieldSummary(for: points),
            riskSignalSummary: config.riskSignalSummary?.riskSignalSummary,
            exposurePoints: exposurePoints,
            assetExposureSeries: assetExposureSeries,
            averageExposureRatio: config.advancedAverageExposureRatio
        )
    }

    private static func defaultCashYieldSummary(for points: [BacktestSeriesPoint]) -> CashYieldSummary {
        CashYieldSummary(
            title: CashYieldCNY.title,
            source: CashYieldCNY.source,
            sourceDetail: CashYieldCNY.sourceDetail,
            startDate: points.first?.date,
            endDate: points.last?.date,
            latestRateDate: nil,
            latestAnnualRate: 0,
            averageAnnualRate: 0,
            averageCashRatio: 0,
            totalCashInterest: 0,
            ratePoints: []
        )
    }

    private static func advancedAssetReports(from config: BacktestRecordConfigPayload) -> [AdvancedBacktestAssetReport] {
        (config.advancedAssetCharts ?? []).map { chart in
            let trades = chart.trades.map(\.advancedTrade)
            let pricePoints = chart.pricePoints
                .sorted { $0.sequence < $1.sequence }
                .map(\.pricePoint)
            let portfolioPoints = chart.decodedPortfolioPoints
            return AdvancedBacktestAssetReport(
                symbol: chart.symbol,
                title: chart.title,
                points: portfolioPoints,
                benchmarkPoints: chart.decodedBenchmarkPoints,
                pricePoints: pricePoints,
                trades: trades,
                finalPortfolioValue: chart.finalPortfolioValue ?? portfolioPoints.last?.portfolioValue ?? 0,
                finalCash: chart.finalCash ?? 0,
                finalUnits: chart.finalUnits ?? trades.last(where: { $0.action == .buy })?.units ?? 0,
                exposureRatio: chart.exposureRatio ?? 0
            )
        }
    }

    private static func combinedBenchmarkPoints(
        from series: [AdvancedBacktestBenchmarkSeries],
        initialPortfolioValue: Double
    ) -> [BacktestSeriesPoint] {
        let normalizedSeries = series.compactMap { benchmark -> [BacktestSeriesPoint]? in
            let points = benchmark.points.sorted { $0.date < $1.date }
            guard let firstValue = points.first?.portfolioValue,
                  firstValue.isFinite,
                  firstValue > 0 else { return nil }
            return points
        }
        guard !normalizedSeries.isEmpty,
              initialPortfolioValue.isFinite,
              initialPortfolioValue > 0 else { return [] }

        let dates = Set(normalizedSeries.flatMap { $0.map(\.date) }).sorted()
        let equalWeightValue = initialPortfolioValue / Double(normalizedSeries.count)
        var cursors = Array(repeating: 0, count: normalizedSeries.count)
        var latestValues = normalizedSeries.map { $0[0].portfolioValue }
        let baseValues = latestValues

        return dates.enumerated().map { sequence, date in
            for index in normalizedSeries.indices {
                let points = normalizedSeries[index]
                var cursor = cursors[index]
                while cursor < points.count, points[cursor].date <= date {
                    latestValues[index] = points[cursor].portfolioValue
                    cursor += 1
                }
                cursors[index] = cursor
            }
            let combinedValue = normalizedSeries.indices.reduce(0.0) { result, index in
                result + equalWeightValue * latestValues[index] / baseValues[index]
            }
            return BacktestSeriesPoint(date: date, portfolioValue: combinedValue, sequence: sequence)
        }
    }

    private static func sampled(_ points: [BacktestSeriesPoint], maxCount: Int) -> [BacktestSeriesPoint] {
        guard points.count > maxCount, maxCount > 1 else { return points }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        var sampled: [BacktestSeriesPoint] = []
        sampled.reserveCapacity(maxCount)

        for index in 0 ..< maxCount {
            let rawIndex = Int((Double(index) * step).rounded())
            let safeIndex = min(max(rawIndex, 0), points.count - 1)
            let point = points[safeIndex]
            if sampled.last?.date != point.date {
                sampled.append(point)
            }
        }

        if sampled.last?.date != points.last?.date, let last = points.last {
            sampled.append(last)
        }
        return sampled
    }

    private static func sampled(_ points: [AdvancedBacktestPricePoint], maxCount: Int) -> [AdvancedBacktestPricePoint] {
        guard points.count > maxCount, maxCount > 1 else { return points }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        var sampled: [AdvancedBacktestPricePoint] = []
        sampled.reserveCapacity(maxCount)

        for index in 0 ..< maxCount {
            let rawIndex = Int((Double(index) * step).rounded())
            let safeIndex = min(max(rawIndex, 0), points.count - 1)
            let point = points[safeIndex]
            if sampled.last?.date != point.date {
                sampled.append(point)
            }
        }

        if sampled.last?.date != points.last?.date, let last = points.last {
            sampled.append(last)
        }
        return sampled
    }
}
