import Foundation
import SwiftUI

func evenlySampledItems<T>(_ items: [T], maxCount: Int) -> [T] {
    guard maxCount > 0, items.count > maxCount else { return items }
    guard maxCount > 1 else { return items.last.map { [$0] } ?? [] }
    let step = Double(items.count - 1) / Double(maxCount - 1)
    return (0..<maxCount).map { index in
        let sourceIndex = min(items.count - 1, Int((Double(index) * step).rounded()))
        return items[sourceIndex]
    }
}

enum AppLocalization {
    static func string(_ value: String) -> String { value }

    static func format(_ format: String, _ arguments: CVarArg...) -> String {
        String(format: format, arguments: arguments)
    }
}

enum AssetTheme {
    static let gold = Color.yellow
    static let goldSoft = Color.yellow
    static let accentBlue = Color.blue
    static let accentOrange = Color.orange
    static let accentRed = Color.red
    static let positive = Color.green
    static let negative = Color.red
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
}

enum AssetGroup: String {
    case financial
    case physical
    case liability
}

enum AutoPricedAssetKind: String {
    case gold
}

final class AssetCategory {
    var group: AssetGroup

    init(group: AssetGroup = .financial) {
        self.group = group
    }
}

final class AssetItem {
    var name: String
    var note: String
    var category: AssetCategory?
    var resolvedAutoPricedAssetKind: AutoPricedAssetKind?

    init(
        name: String = "",
        note: String = "",
        category: AssetCategory? = nil,
        resolvedAutoPricedAssetKind: AutoPricedAssetKind? = nil
    ) {
        self.name = name
        self.note = note
        self.category = category
        self.resolvedAutoPricedAssetKind = resolvedAutoPricedAssetKind
    }
}

final class AssetEntry {
    var amount: Double?
    var quantity: Double?
    var unitPrice: Double?
    var item: AssetItem?

    init(amount: Double? = nil, quantity: Double? = nil, unitPrice: Double? = nil, item: AssetItem? = nil) {
        self.amount = amount
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.item = item
    }

    var resolvedAmount: Double {
        if let amount { return amount }
        if let quantity, let unitPrice { return quantity * unitPrice }
        return 0
    }
}

final class AssetSnapshot {
    var entries: [AssetEntry]

    init(entries: [AssetEntry] = []) {
        self.entries = entries
    }
}

struct BacktestSeriesPoint: Identifiable {
    let id: Int
    let date: Date
    let portfolioValue: Double

    init(date: Date, portfolioValue: Double, sequence: Int = 0) {
        self.id = sequence
        self.date = date
        self.portfolioValue = portfolioValue
    }
}

enum BacktestChartValueStyle {
    case multiple
    case currency(code: String)
}

struct BacktestChartComparisonSeries: Identifiable {
    let id: String
    let title: String
    let points: [BacktestSeriesPoint]
    let color: Color
}

enum AdvancedBacktestPresentation {
    static func comparisonSeries(from report: AdvancedBacktestReport) -> [BacktestChartComparisonSeries] {
        []
    }
}

final class BacktestRecord {
    var kindRawValue: String
    var title: String
    var subtitle: String
    var configSummary: String
    var createdAt: Date
    var startDate: Date?
    var endDate: Date?
    var totalReturn: Double
    var annualizedReturn: Double?
    var maxDrawdown: Double
    var annualizedVolatility: Double?
    var sharpeRatio: Double?
    var finalValue: Double?
    var totalInvested: Double?
    var profitLoss: Double?
    var tradeCount: Int
    var pointsJSON: Data
    var configJSON: Data

    init(
        kindRawValue: String,
        title: String,
        subtitle: String = "",
        configSummary: String = "",
        createdAt: Date = .now,
        startDate: Date? = nil,
        endDate: Date? = nil,
        totalReturn: Double,
        annualizedReturn: Double? = nil,
        maxDrawdown: Double,
        annualizedVolatility: Double? = nil,
        sharpeRatio: Double? = nil,
        finalValue: Double? = nil,
        totalInvested: Double? = nil,
        profitLoss: Double? = nil,
        tradeCount: Int = 0,
        pointsJSON: Data = Data(),
        configJSON: Data = Data()
    ) {
        self.kindRawValue = kindRawValue
        self.title = title
        self.subtitle = subtitle
        self.configSummary = configSummary
        self.createdAt = createdAt
        self.startDate = startDate
        self.endDate = endDate
        self.totalReturn = totalReturn
        self.annualizedReturn = annualizedReturn
        self.maxDrawdown = maxDrawdown
        self.annualizedVolatility = annualizedVolatility
        self.sharpeRatio = sharpeRatio
        self.finalValue = finalValue
        self.totalInvested = totalInvested
        self.profitLoss = profitLoss
        self.tradeCount = tradeCount
        self.pointsJSON = pointsJSON
        self.configJSON = configJSON
    }
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

    enum CodingKeys: String, CodingKey {
        case symbol, category, label, currency, unit, source, dates, prices, volumes
        case hasOHLC = "has_ohlc"
        case ohlcSource = "ohlc_source"
        case ohlcCoverageRatio = "ohlc_coverage_ratio"
        case openPrices = "open_prices"
        case highPrices = "high_prices"
        case lowPrices = "low_prices"
        case closePrices = "close_prices"
    }
}

struct PublicHistoryResponse: Codable {
    let success: Bool
    let series: [PublicHistorySeries]
}

enum RemoteMarketClient {
    static let baseURL = URL(string: "https://api.flyingrtx.com")!

    private static func fixtureHistoryResponseIfConfigured() throws -> PublicHistoryResponse? {
        guard let fixturePath = ProcessInfo.processInfo.environment["ATM_HISTORY_FIXTURE"],
              !fixturePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(PublicHistoryResponse.self, from: data)
    }

    static func fetchHistory(symbols: [String], period: String? = nil, includeOHLC: Bool = false) async throws -> PublicHistoryResponse {
        if let fixtureResponse = try fixtureHistoryResponseIfConfigured() {
            return fixtureResponse
        }

        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/money/public/history"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "symbols", value: symbols.joined(separator: ",")),
            URLQueryItem(name: "period", value: period ?? "all"),
            URLQueryItem(name: "include_ohlc", value: includeOHLC ? "true" : "false")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(PublicHistoryResponse.self, from: data)
    }
}

extension Double {
    func currencyString(code: String = "CNY") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.0f", self)
    }

    func percentString(maxFractionDigits: Int = 2) -> String {
        String(format: "%.\(maxFractionDigits)f%%", self * 100)
    }

    func compactNumberString(maxFractionDigits: Int = 1) -> String {
        String(format: "%.\(maxFractionDigits)f", self)
    }
}

extension Date {
    var recordDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }
}

@main
struct StrategyMetricDump {
    struct MetricRow {
        let title: String
        let id: String
        let annualized: Double?
        let maxDrawdown: Double?
        let volatility: Double?
        let sharpe: Double?
        let start: String
        let end: String
        let pointCount: Int
    }

    struct SliceMetricRow {
        let slice: String
        let row: MetricRow
    }

    private static func metricRow(
        title: String,
        id: String,
        points: [BacktestSeriesPoint]
    ) -> MetricRow {
        guard let first = points.first, let last = points.last, first.portfolioValue > 0 else {
            return MetricRow(title: title, id: id, annualized: nil, maxDrawdown: nil, volatility: nil, sharpe: nil, start: "n/a", end: "n/a", pointCount: points.count)
        }

        var normalizedValue = 1.0
        var previousValue = first.portfolioValue
        var peakNormalizedValue = normalizedValue
        var returns: [Double] = []
        var maxDrawdown = 0.0

        for point in points.dropFirst() {
            guard previousValue > 0, point.portfolioValue > 0 else {
                previousValue = point.portfolioValue
                continue
            }
            let periodReturn = point.portfolioValue / previousValue - 1
            returns.append(periodReturn)
            normalizedValue *= (1 + periodReturn)
            peakNormalizedValue = max(peakNormalizedValue, normalizedValue)
            if peakNormalizedValue > 0 {
                maxDrawdown = max(maxDrawdown, (peakNormalizedValue - normalizedValue) / peakNormalizedValue)
            }
            previousValue = point.portfolioValue
        }

        let daySpan = max(Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0, 1)
        let years = Double(daySpan) / 365.25
        let annualizedReturn = years > 0 ? pow(normalizedValue, 1 / years) - 1 : nil
        let mean = returns.isEmpty ? nil : returns.reduce(0, +) / Double(returns.count)
        let variance = returns.count > 1 && mean != nil
            ? returns.reduce(0) { $0 + pow($1 - mean!, 2) } / Double(returns.count - 1)
            : nil
        let dailyVolatility = variance.map { sqrt($0) }
        let annualizedVolatility = dailyVolatility.map { $0 * sqrt(252) }
        let sharpeRatio: Double?
        if let mean, let dailyVolatility, dailyVolatility > 0 {
            sharpeRatio = (mean * 252) / (dailyVolatility * sqrt(252))
        } else {
            sharpeRatio = nil
        }

        return MetricRow(
            title: title,
            id: id,
            annualized: annualizedReturn,
            maxDrawdown: maxDrawdown,
            volatility: annualizedVolatility,
            sharpe: sharpeRatio,
            start: first.date.recordDateString,
            end: last.date.recordDateString,
            pointCount: points.count
        )
    }

    private static func metricRowsForSlices(
        title: String,
        id: String,
        points: [BacktestSeriesPoint],
        fullRow: MetricRow? = nil
    ) -> [SliceMetricRow] {
        guard let lastDate = points.last?.date else {
            return [SliceMetricRow(slice: "full", row: fullRow ?? metricRow(title: title, id: id, points: points))]
        }

        let calendar = Calendar(identifier: .gregorian)
        let since2020 = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        let since2022 = calendar.date(from: DateComponents(year: 2022, month: 1, day: 1))!
        let last10y = calendar.date(byAdding: .year, value: -10, to: lastDate) ?? lastDate
        let slices: [(String, Date?)] = [
            ("full", nil),
            ("since2020", since2020),
            ("last10y", last10y),
            ("since2022", since2022)
        ]

        return slices.map { slice, startDate in
            if slice == "full", let fullRow {
                return SliceMetricRow(slice: slice, row: fullRow)
            }
            let slicedPoints: [BacktestSeriesPoint]
            if let startDate {
                slicedPoints = points.filter { $0.date >= startDate }
            } else {
                slicedPoints = points
            }
            return SliceMetricRow(slice: slice, row: metricRow(title: title, id: id, points: slicedPoints))
        }
    }

    private static let allRotationModes: [AdvancedBacktestStrategyMode] = [
        .ultraDefensiveRotation,
        .defensiveRotation,
        .lowDrawdownRotation,
        .balancedRotation,
        .enhancedRotation,
        .longTermDefensiveTrend,
        .longTermEnhancedLowDrawdownTrend,
        .steadyDrawdownLadderTrend,
        .septemberGuardLadderTrend,
        .longTermGrowthTrend,
        .longTermLowVolMomentum,
        .robustLowVolMomentum,
        .overheatGuardMomentum,
        .highZoneDecelerationMomentum,
        .pairConfirmDoubleGuardMomentum,
        .tailBreakdownLockMomentum,
        .recentLossVolatilityMetaMomentum,
        .coreGoldSatelliteConservativeMomentum,
        .coreGoldSatelliteBalancedMomentum,
        .coreGoldSatelliteFullMomentum,
        .coreGoldSatelliteHeatCappedMomentum,
        .coreGoldSatelliteGoldHandoffMomentum,
        .coreGoldSatelliteEquityBreadthMomentum,
        .coreGoldSatelliteOneWayVolManagedMomentum,
        .coreGoldSatelliteEquityCurveStateGateMomentum,
        .coreGoldSatelliteSharpeStateGateMomentum,
        .coreGoldSatelliteAssetRiskGateMomentum,
        .coreGoldSatelliteRiskBudgetStateGateMomentum,
        .coreGoldSatelliteConfirmedAccelerationMomentum,
        .coreGoldSatelliteProfitLockMomentum,
        .coreGoldSatelliteDynamicSleeveMomentum,
        .coreGoldSatelliteContagionRepairMomentum,
        .coreGoldSatelliteCurrencyCashMomentum,
        .coreGoldSatelliteGoldPanicLockMomentum,
        .coreGoldSatelliteRiskEfficiencyMomentum,
        .coreGoldSatelliteMonthlyHeatCappedMomentum,
        .coreGoldSatelliteConfirmedExcessMomentum,
        .coreGoldSatelliteAggressiveMomentum,
        .canaryMomentumDefense,
        .drawdownReentryMomentum,
        .goldCoreTrendSatellite,
        .goldNasdaqSteadyRotation,
        .goldNasdaqPortfolioScheduler,
        .strongVolControlledRotation,
        .momentumRotation
    ]

    private static func appFilteredInputs(
        for template: AdvancedBacktestStrategyTemplate,
        seriesBySymbol: [String: PublicHistorySeries]
    ) -> [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)] {
        let options = StrategyNotificationDefaults.assetOptions(for: template)
        let historyProvider: (String) -> PublicHistorySeries? = { symbol in
            seriesBySymbol[normalizedHistorySymbol(symbol)]
        }
        let inputs = options.map { option in
            BacktestEngine.advancedAssetInput(for: option, historyProvider: historyProvider)
        }

        let boundarySymbols = template.mode.dateBoundaryAssetSymbols
        let boundaryOptions = options.filter { option in
            boundarySymbols?.contains(option.symbol) ?? true
        }
        let sourceSeries = boundaryOptions.flatMap { option -> [PublicHistorySeries] in
            let input = BacktestEngine.advancedAssetInput(for: option, historyProvider: historyProvider)
            return [input.assetSeries, input.fxSeries].compactMap { $0 }
        }
        return BacktestEngine.filteredAdvancedAssetInputs(
            inputs,
            within: BacktestEngine.availableDateBounds(for: sourceSeries)
        )
    }

    static func main() async throws {
        let symbols = [
            "gold_cny",
            "nasdaq_composite",
            "sp500",
            "dow_jones",
            "hang_seng",
            "nikkei225",
            "csi300",
            "shanghai_composite",
            "shenzhen_component",
            "chinext",
            "usd_per_cny"
        ]
        let response = try await RemoteMarketClient.fetchHistory(symbols: symbols, period: "all", includeOHLC: false)
        let seriesBySymbol = Dictionary(uniqueKeysWithValues: response.series.map { series in
            (normalizedHistorySymbol(series.symbol), series)
        })
        let settings = AdvancedBacktestRiskSettings(
            feeRate: 1.0,
            slippageRate: 0.05,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        )

        if ProcessInfo.processInfo.environment["ATM_ASSET_RISK_GRID"] == "1"
            || ProcessInfo.processInfo.environment["ATM_ASSET_RISK_FOCUSED_GRID"] == "1" {
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let options = AdvancedBacktestStrategyMode.coreGoldSatelliteAssetRiskGateMomentum.requiredSignalAssetSymbols.compactMap {
                optionsBySymbol[$0]
            }
            let inputs = options.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            let focused = ProcessInfo.processInfo.environment["ATM_ASSET_RISK_FOCUSED_GRID"] == "1"
            let lowScales = focused
                ? [0.55, 0.60, 0.62, 0.65, 0.68, 0.70, 0.73, 0.75]
                : [0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.73, 0.75]
            let multipliers = focused
                ? [1.00, 1.05, 1.10, 1.15, 1.20, 1.25, 1.30, 1.35]
                : [1.00, 1.05, 1.10, 1.15, 1.20, 1.25, 1.30, 1.35, 1.40, 1.50, 1.60, 1.70, 1.80, 1.90, 2.00, 2.10, 2.20]
            print("APP_ASSET_RISK_GRID")
            print("low_scale,multiplier,annualized,max_drawdown,volatility,sharpe,start,end,points")
            for lowScale in lowScales {
                for multiplier in multipliers {
                    BacktestResearchOverrides.assetRiskLowScale = lowScale
                    BacktestResearchOverrides.assetRiskMultiplier = multiplier
                    guard let report = BacktestEngine.runAdvancedRotationStrategy(
                        assetInputs: inputs,
                        initialCash: 100_000,
                        settings: settings,
                        mode: .coreGoldSatelliteAssetRiskGateMomentum
                    ) else {
                        print(String(format: "%.2f,%.2f,n/a,n/a,n/a,n/a,n/a,n/a,0", lowScale, multiplier))
                        continue
                    }
                    print([
                        String(format: "%.2f", lowScale),
                        String(format: "%.2f", multiplier),
                        report.annualizedReturn.map { String(format: "%.6f", $0 * 100) } ?? "n/a",
                        String(format: "%.6f", report.maxDrawdown * 100),
                        report.annualizedVolatility.map { String(format: "%.6f", $0 * 100) } ?? "n/a",
                        report.sharpeRatio.map { String(format: "%.6f", $0) } ?? "n/a",
                        report.points.first?.date.recordDateString ?? "n/a",
                        report.points.last?.date.recordDateString ?? "n/a",
                        "\(report.points.count)"
                    ].joined(separator: ","))
                }
            }
            BacktestResearchOverrides.assetRiskLowScale = nil
            BacktestResearchOverrides.assetRiskMultiplier = nil
            return
        }

        if ProcessInfo.processInfo.environment["ATM_SHARPE_GRID"] == "1"
            || ProcessInfo.processInfo.environment["ATM_SHARPE_FOCUSED_GRID"] == "1" {
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let options = AdvancedBacktestStrategyMode.coreGoldSatelliteSharpeStateGateMomentum.requiredSignalAssetSymbols.compactMap {
                optionsBySymbol[$0]
            }
            let inputs = options.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            let focused = ProcessInfo.processInfo.environment["ATM_SHARPE_FOCUSED_GRID"] == "1"
            let lowScales = focused
                ? [0.20, 0.25, 0.30, 0.35, 0.40, 0.45]
                : [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50]
            let multipliers = focused
                ? [1.00, 1.20, 1.40, 1.60, 1.80, 2.00]
                : [1.00, 1.10, 1.20, 1.30, 1.40, 1.50, 1.60, 1.70, 1.80, 1.90, 2.00, 2.10, 2.20]
            print("APP_SHARPE_GRID")
            print("low_scale,multiplier,annualized,max_drawdown,volatility,sharpe,start,end,points")
            for lowScale in lowScales {
                for multiplier in multipliers {
                    BacktestResearchOverrides.sharpeLowScale = lowScale
                    BacktestResearchOverrides.sharpeMultiplier = multiplier
                    guard let report = BacktestEngine.runAdvancedRotationStrategy(
                        assetInputs: inputs,
                        initialCash: 100_000,
                        settings: settings,
                        mode: .coreGoldSatelliteSharpeStateGateMomentum
                    ) else {
                        print(String(format: "%.2f,%.2f,n/a,n/a,n/a,n/a,n/a,n/a,0", lowScale, multiplier))
                        continue
                    }
                    print([
                        String(format: "%.2f", lowScale),
                        String(format: "%.2f", multiplier),
                        report.annualizedReturn.map { String(format: "%.6f", $0 * 100) } ?? "n/a",
                        String(format: "%.6f", report.maxDrawdown * 100),
                        report.annualizedVolatility.map { String(format: "%.6f", $0 * 100) } ?? "n/a",
                        report.sharpeRatio.map { String(format: "%.6f", $0) } ?? "n/a",
                        report.points.first?.date.recordDateString ?? "n/a",
                        report.points.last?.date.recordDateString ?? "n/a",
                        "\(report.points.count)"
                    ].joined(separator: ","))
                }
            }
            BacktestResearchOverrides.sharpeLowScale = nil
            BacktestResearchOverrides.sharpeMultiplier = nil
            return
        }

        if ProcessInfo.processInfo.environment["ATM_RISK_BUDGET_FOCUSED_GRID"] == "1" {
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let options = AdvancedBacktestStrategyMode.coreGoldSatelliteRiskBudgetStateGateMomentum.requiredSignalAssetSymbols.compactMap {
                optionsBySymbol[$0]
            }
            let inputs = options.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            let lowScales = [0.48, 0.50, 0.52, 0.55, 0.58]
            let multipliers = [1.0]
            let defensiveShares = [0.50, 0.60, 0.70]
            print("APP_RISK_BUDGET_FOCUSED_GRID")
            print("low_scale,multiplier,defensive_share,annualized,max_drawdown,volatility,sharpe,start,end,points")
            for lowScale in lowScales {
                for multiplier in multipliers {
                    for defensiveShare in defensiveShares {
                        BacktestResearchOverrides.riskBudgetLowScale = lowScale
                        BacktestResearchOverrides.riskBudgetMultiplier = multiplier
                        BacktestResearchOverrides.riskBudgetDefensiveShare = defensiveShare
                        guard let report = BacktestEngine.runAdvancedRotationStrategy(
                            assetInputs: inputs,
                            initialCash: 100_000,
                            settings: settings,
                            mode: .coreGoldSatelliteRiskBudgetStateGateMomentum
                        ) else {
                            print(String(format: "%.2f,%.2f,%.2f,n/a,n/a,n/a,n/a,n/a,n/a,0", lowScale, multiplier, defensiveShare))
                            continue
                        }
                        print([
                            String(format: "%.2f", lowScale),
                            String(format: "%.2f", multiplier),
                            String(format: "%.2f", defensiveShare),
                            report.annualizedReturn.map { String(format: "%.6f", $0 * 100) } ?? "n/a",
                            String(format: "%.6f", report.maxDrawdown * 100),
                            report.annualizedVolatility.map { String(format: "%.6f", $0 * 100) } ?? "n/a",
                            report.sharpeRatio.map { String(format: "%.6f", $0) } ?? "n/a",
                            report.points.first?.date.recordDateString ?? "n/a",
                            report.points.last?.date.recordDateString ?? "n/a",
                            "\(report.points.count)"
                        ].joined(separator: ","))
                    }
                }
            }
            BacktestResearchOverrides.riskBudgetLowScale = nil
            BacktestResearchOverrides.riskBudgetMultiplier = nil
            BacktestResearchOverrides.riskBudgetDefensiveShare = nil
            return
        }

        if let variant = ProcessInfo.processInfo.environment["ATM_RISK_BUDGET_VARIANT"] {
            let parts = variant.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard parts.count == 3 else {
                print("APP_RISK_BUDGET_VARIANT")
                print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
                print("风险预算参数候选,invalid,n/a,n/a,n/a,n/a,n/a,n/a,0")
                return
            }
            guard parts[1] <= 1.0001 else {
                print("APP_RISK_BUDGET_VARIANT")
                print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
                print("风险预算参数候选,financing_rejected,n/a,n/a,n/a,n/a,n/a,n/a,0")
                return
            }

            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let options = AdvancedBacktestStrategyMode.coreGoldSatelliteRiskBudgetStateGateMomentum.requiredSignalAssetSymbols.compactMap {
                optionsBySymbol[$0]
            }
            let inputs = options.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            BacktestResearchOverrides.riskBudgetLowScale = parts[0]
            BacktestResearchOverrides.riskBudgetMultiplier = parts[1]
            BacktestResearchOverrides.riskBudgetDefensiveShare = parts[2]
            defer {
                BacktestResearchOverrides.riskBudgetLowScale = nil
                BacktestResearchOverrides.riskBudgetMultiplier = nil
                BacktestResearchOverrides.riskBudgetDefensiveShare = nil
            }
            guard let report = BacktestEngine.runAdvancedRotationStrategy(
                assetInputs: inputs,
                initialCash: 100_000,
                settings: settings,
                mode: .coreGoldSatelliteRiskBudgetStateGateMomentum
            ) else {
                print("APP_RISK_BUDGET_VARIANT")
                print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
                print("风险预算参数候选,risk_budget_variant,n/a,n/a,n/a,n/a,n/a,n/a,0")
                return
            }

            let calendar = Calendar(identifier: .gregorian)
            func startDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
                calendar.date(from: DateComponents(year: year, month: month, day: day))!
            }
            let slices: [(String, String, Date?)] = [
                ("全区间", "full", nil),
                ("最近10年", "recent_10y", startDate(2016, 7, 1)),
                ("2020以来", "since_2020", startDate(2020, 1, 1)),
                ("2022以来", "since_2022", startDate(2022, 1, 1)),
                ("2024以来", "since_2024", startDate(2024, 1, 1))
            ]
            let rows = slices.map { title, id, startDate in
                let points: [BacktestSeriesPoint]
                if let startDate {
                    points = report.points.filter { $0.date >= startDate }
                } else {
                    points = report.points
                }
                return metricRow(
                    title: title,
                    id: id,
                    points: points
                )
            }
            printRows(rows, header: "APP_RISK_BUDGET_VARIANT")
            return
        }

        if let variant = ProcessInfo.processInfo.environment["ATM_ASSET_RISK_VARIANT"] {
            let parts = variant.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard parts.count == 2 else {
                print("APP_ASSET_RISK_VARIANT")
                print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
                print("收益回撤门参数候选,invalid,n/a,n/a,n/a,n/a,n/a,n/a,0")
                return
            }

            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let options = AdvancedBacktestStrategyMode.coreGoldSatelliteAssetRiskGateMomentum.requiredSignalAssetSymbols.compactMap {
                optionsBySymbol[$0]
            }
            let inputs = options.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            BacktestResearchOverrides.assetRiskLowScale = parts[0]
            BacktestResearchOverrides.assetRiskMultiplier = parts[1]
            defer {
                BacktestResearchOverrides.assetRiskLowScale = nil
                BacktestResearchOverrides.assetRiskMultiplier = nil
            }
            guard let report = BacktestEngine.runAdvancedRotationStrategy(
                assetInputs: inputs,
                initialCash: 100_000,
                settings: settings,
                mode: .coreGoldSatelliteAssetRiskGateMomentum
            ) else {
                print("APP_ASSET_RISK_VARIANT")
                print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
                print("收益回撤门参数候选,asset_risk_variant,n/a,n/a,n/a,n/a,n/a,n/a,0")
                return
            }

            let calendar = Calendar(identifier: .gregorian)
            func startDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
                calendar.date(from: DateComponents(year: year, month: month, day: day))!
            }
            let slices: [(String, String, Date?)] = [
                ("全区间", "full", nil),
                ("最近10年", "recent_10y", startDate(2016, 7, 1)),
                ("2020以来", "since_2020", startDate(2020, 1, 1)),
                ("2022以来", "since_2022", startDate(2022, 1, 1)),
                ("2024以来", "since_2024", startDate(2024, 1, 1))
            ]
            let rows = slices.map { title, id, startDate in
                let points = startDate.map { date in report.points.filter { $0.date >= date } } ?? report.points
                return metricRow(title: title, id: id, points: points)
            }
            printRows(rows, header: "APP_ASSET_RISK_VARIANT")
            return
        }

        if ProcessInfo.processInfo.environment["ATM_DUMP_ALL_MODES"] == "1" {
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let allAppAssetOptions = BacktestDefaults.dcaAssetOptions
            var rows: [MetricRow] = []
            for mode in allRotationModes {
                let requiredSymbols = mode.requiredSignalAssetSymbols
                let options: [BacktestAssetOption]
                if requiredSymbols.isEmpty {
                    options = allAppAssetOptions
                } else {
                    options = requiredSymbols.compactMap { optionsBySymbol[$0] }
                }
                let inputs = options.map { option in
                    BacktestEngine.advancedAssetInput(for: option) { symbol in
                        seriesBySymbol[normalizedHistorySymbol(symbol)]
                    }
                }
                guard let report = BacktestEngine.runAdvancedRotationStrategy(
                    assetInputs: inputs,
                    initialCash: 100_000,
                    settings: settings,
                    mode: mode
                ) else {
                    rows.append(MetricRow(
                        title: mode.title,
                        id: mode.rawValue,
                        annualized: nil,
                        maxDrawdown: nil,
                        volatility: nil,
                        sharpe: nil,
                        start: "n/a",
                        end: "n/a",
                        pointCount: 0
                    ))
                    continue
                }
                rows.append(MetricRow(
                    title: mode.title,
                    id: mode.rawValue,
                    annualized: report.annualizedReturn,
                    maxDrawdown: report.maxDrawdown,
                    volatility: report.annualizedVolatility,
                    sharpe: report.sharpeRatio,
                    start: report.points.first?.date.recordDateString ?? "n/a",
                    end: report.points.last?.date.recordDateString ?? "n/a",
                    pointCount: report.points.count
                ))
            }
            printRows(rows, header: "APP_ALL_MODE_METRICS")
            return
        }

        if ProcessInfo.processInfo.environment["ATM_CALENDAR_BUCKET_TURBO"] == "1" {
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let options = AdvancedBacktestStrategyMode.coreGoldSatelliteRiskBudgetStateGateMomentum.requiredSignalAssetSymbols.compactMap {
                optionsBySymbol[$0]
            }
            let inputs = options.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            guard let report = BacktestEngine.runCalendarBucketTurboCompositeStrategy(
                assetInputs: inputs,
                initialCash: 100_000,
                settings: settings
            ) else {
                print("APP_CALENDAR_BUCKET_TURBO")
                print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
                print("日历桶风险预算复合,calendar_bucket_turbo_composite,n/a,n/a,n/a,n/a,n/a,n/a,0")
                return
            }
            printRows([
                MetricRow(
                    title: "日历桶风险预算复合",
                    id: "calendar_bucket_turbo_composite",
                    annualized: report.annualizedReturn,
                    maxDrawdown: report.maxDrawdown,
                    volatility: report.annualizedVolatility,
                    sharpe: report.sharpeRatio,
                    start: report.points.first?.date.recordDateString ?? "n/a",
                    end: report.points.last?.date.recordDateString ?? "n/a",
                    pointCount: report.points.count
                )
            ], header: "APP_CALENDAR_BUCKET_TURBO")
            return
        }

        if ProcessInfo.processInfo.environment["ATM_COARSE_CALENDAR_BUCKET_TURBO"] == "1" {
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let options = AdvancedBacktestStrategyMode.coreGoldSatelliteRiskBudgetStateGateMomentum.requiredSignalAssetSymbols.compactMap {
                optionsBySymbol[$0]
            }
            let inputs = options.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            guard let report = BacktestEngine.runCoarseCalendarBucketTurboCompositeStrategy(
                assetInputs: inputs,
                initialCash: 100_000,
                settings: settings
            ) else {
                print("APP_COARSE_CALENDAR_BUCKET_TURBO")
                print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
                print("粗日历桶风险预算复合,coarse_calendar_bucket_turbo_composite,n/a,n/a,n/a,n/a,n/a,n/a,0")
                return
            }
            printRows([
                MetricRow(
                    title: "粗日历桶风险预算复合",
                    id: "coarse_calendar_bucket_turbo_composite",
                    annualized: report.annualizedReturn,
                    maxDrawdown: report.maxDrawdown,
                    volatility: report.annualizedVolatility,
                    sharpe: report.sharpeRatio,
                    start: report.points.first?.date.recordDateString ?? "n/a",
                    end: report.points.last?.date.recordDateString ?? "n/a",
                    pointCount: report.points.count
                )
            ], header: "APP_COARSE_CALENDAR_BUCKET_TURBO")
            return
        }

        if ProcessInfo.processInfo.environment["ATM_COMPACT_CALENDAR_BUCKET_TURBO"] == "1" {
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let options = AdvancedBacktestStrategyMode.coreGoldSatelliteRiskBudgetStateGateMomentum.requiredSignalAssetSymbols.compactMap {
                optionsBySymbol[$0]
            }
            let inputs = options.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            guard let report = BacktestEngine.runCompactCalendarBucketTurboCompositeStrategy(
                assetInputs: inputs,
                initialCash: 100_000,
                settings: settings
            ) else {
                print("APP_COMPACT_CALENDAR_BUCKET_TURBO")
                print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
                print("压缩日历桶风险预算复合,compact_calendar_bucket_turbo_composite,n/a,n/a,n/a,n/a,n/a,n/a,0")
                return
            }
            printRows([
                MetricRow(
                    title: "压缩日历桶风险预算复合",
                    id: "compact_calendar_bucket_turbo_composite",
                    annualized: report.annualizedReturn,
                    maxDrawdown: report.maxDrawdown,
                    volatility: report.annualizedVolatility,
                    sharpe: report.sharpeRatio,
                    start: report.points.first?.date.recordDateString ?? "n/a",
                    end: report.points.last?.date.recordDateString ?? "n/a",
                    pointCount: report.points.count
                )
            ], header: "APP_COMPACT_CALENDAR_BUCKET_TURBO")
            return
        }

        if ProcessInfo.processInfo.environment["ATM_NO_CALENDAR_LOWDD_COMPOSITE"] == "1" {
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let options = AdvancedBacktestStrategyMode.coreGoldSatelliteRiskBudgetStateGateMomentum.requiredSignalAssetSymbols.compactMap {
                optionsBySymbol[$0]
            }
            let inputs = options.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            guard let report = BacktestEngine.runNoCalendarLowDrawdownCompositeStrategy(
                assetInputs: inputs,
                initialCash: 100_000,
                settings: settings
            ) else {
                print("APP_NO_CALENDAR_LOWDD_COMPOSITE")
                print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
                print("无日历低回撤复合,no_calendar_lowdd_composite,n/a,n/a,n/a,n/a,n/a,n/a,0")
                return
            }
            printRows([
                MetricRow(
                    title: "无日历低回撤复合",
                    id: "no_calendar_lowdd_composite",
                    annualized: report.annualizedReturn,
                    maxDrawdown: report.maxDrawdown,
                    volatility: report.annualizedVolatility,
                    sharpe: report.sharpeRatio,
                    start: report.points.first?.date.recordDateString ?? "n/a",
                    end: report.points.last?.date.recordDateString ?? "n/a",
                    pointCount: report.points.count
                )
            ], header: "APP_NO_CALENDAR_LOWDD_COMPOSITE")
            return
        }

        if ProcessInfo.processInfo.environment["ATM_NO_CALENDAR_HIGH_RETURN_COMPOSITE"] == "1" {
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let options = AdvancedBacktestStrategyMode.coreGoldSatelliteRiskBudgetStateGateMomentum.requiredSignalAssetSymbols.compactMap {
                optionsBySymbol[$0]
            }
            let inputs = options.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            guard let report = BacktestEngine.runNoCalendarHighReturnCompositeStrategy(
                assetInputs: inputs,
                initialCash: 100_000,
                settings: settings
            ) else {
                print("APP_NO_CALENDAR_HIGH_RETURN_COMPOSITE")
                print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
                print("无日历高收益复合,no_calendar_high_return_composite,n/a,n/a,n/a,n/a,n/a,n/a,0")
                return
            }
            printRows([
                MetricRow(
                    title: "无日历高收益复合",
                    id: "no_calendar_high_return_composite",
                    annualized: report.annualizedReturn,
                    maxDrawdown: report.maxDrawdown,
                    volatility: report.annualizedVolatility,
                    sharpe: report.sharpeRatio,
                    start: report.points.first?.date.recordDateString ?? "n/a",
                    end: report.points.last?.date.recordDateString ?? "n/a",
                    pointCount: report.points.count
                )
            ], header: "APP_NO_CALENDAR_HIGH_RETURN_COMPOSITE")
            return
        }

        if ProcessInfo.processInfo.environment["ATM_NO_CALENDAR_THREE_SLEEVE_COMPOSITE"] == "1" {
            let optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestDefaults.dcaAssetOptions.map { ($0.symbol, $0) })
            let options = AdvancedBacktestStrategyMode.coreGoldSatelliteRiskBudgetStateGateMomentum.requiredSignalAssetSymbols.compactMap {
                optionsBySymbol[$0]
            }
            let inputs = options.map { option in
                BacktestEngine.advancedAssetInput(for: option) { symbol in
                    seriesBySymbol[normalizedHistorySymbol(symbol)]
                }
            }
            guard let report = BacktestEngine.runNoCalendarThreeSleeveCompositeStrategy(
                assetInputs: inputs,
                initialCash: 100_000,
                settings: settings
            ) else {
                print("APP_NO_CALENDAR_THREE_SLEEVE_COMPOSITE")
                print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
                print("无日历三袖套复合,no_calendar_three_sleeve_composite,n/a,n/a,n/a,n/a,n/a,n/a,0")
                return
            }
            printRows([
                MetricRow(
                    title: "无日历三袖套复合",
                    id: "no_calendar_three_sleeve_composite",
                    annualized: report.annualizedReturn,
                    maxDrawdown: report.maxDrawdown,
                    volatility: report.annualizedVolatility,
                    sharpe: report.sharpeRatio,
                    start: report.points.first?.date.recordDateString ?? "n/a",
                    end: report.points.last?.date.recordDateString ?? "n/a",
                    pointCount: report.points.count
                )
            ], header: "APP_NO_CALENDAR_THREE_SLEEVE_COMPOSITE")
            return
        }

        var rows: [MetricRow] = []
        var sliceRows: [SliceMetricRow] = []
        for template in AdvancedBacktestStrategyTemplate.all {
            let inputs = appFilteredInputs(for: template, seriesBySymbol: seriesBySymbol)
            let report: AdvancedBacktestReport?
            if template.mode.isRotation {
                report = BacktestEngine.runAdvancedRotationStrategy(
                    assetInputs: inputs,
                    initialCash: 100_000,
                    settings: settings,
                    mode: template.mode
                )
            } else {
                report = BacktestEngine.runAdvancedStrategies(
                    assetInputs: inputs,
                    initialCash: 100_000,
                    tradeAmount: 100_000 * template.tradeAmountRatio,
                    buyRule: template.buyRule,
                    sellRule: template.sellRule,
                    settings: AdvancedBacktestRiskSettings(
                        feeRate: 1.0,
                        slippageRate: 0.05,
                        maxPositionRatio: template.maxPositionRatio,
                        cooldownDays: template.cooldownDays,
                        stopLossRatio: template.stopLossRatio,
                        takeProfitRatio: template.takeProfitRatio
                    )
                )
            }
            guard let report else {
                rows.append(MetricRow(
                    title: template.title,
                    id: template.id,
                    annualized: nil,
                    maxDrawdown: nil,
                    volatility: nil,
                    sharpe: nil,
                    start: "n/a",
                    end: "n/a",
                    pointCount: 0
                ))
                continue
            }
            let row = MetricRow(
                title: template.title,
                id: template.id,
                annualized: report.annualizedReturn,
                maxDrawdown: report.maxDrawdown,
                volatility: report.annualizedVolatility,
                sharpe: report.sharpeRatio,
                start: report.points.first?.date.recordDateString ?? "n/a",
                end: report.points.last?.date.recordDateString ?? "n/a",
                pointCount: report.points.count
            )
            rows.append(row)
            sliceRows.append(contentsOf: metricRowsForSlices(title: template.title, id: template.id, points: report.points, fullRow: row))
        }

        if ProcessInfo.processInfo.environment["ATM_DUMP_SLICES"] == "1" {
            printSliceRows(sliceRows, header: "APP_STRATEGY_SLICE_METRICS")
        } else {
            printRows(rows, header: "APP_STRATEGY_METRICS")
        }
    }

    private static func printRows(_ rows: [MetricRow], header: String) {
        print(header)
        print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points")
        for row in rows {
            print([
                row.title,
                row.id,
                format(row.annualized),
                format(row.maxDrawdown),
                format(row.volatility),
                format(row.sharpe, digits: 6, percent: false),
                row.start,
                row.end,
                String(row.pointCount)
            ].joined(separator: ","))
        }
    }

    private static func printSliceRows(_ rows: [SliceMetricRow], header: String) {
        print(header)
        print("title,id,slice,annualized,max_drawdown,volatility,sharpe,start,end,points")
        for sliceRow in rows {
            let row = sliceRow.row
            print([
                row.title,
                row.id,
                sliceRow.slice,
                format(row.annualized),
                format(row.maxDrawdown),
                format(row.volatility),
                format(row.sharpe, digits: 6, percent: false),
                row.start,
                row.end,
                String(row.pointCount)
            ].joined(separator: ","))
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
        default:
            return symbol
        }
    }

    private static func format(_ value: Double?, digits: Int = 6, percent: Bool = true) -> String {
        guard let value, value.isFinite else { return "n/a" }
        let scaled = percent ? value * 100 : value
        return String(format: "%.\(digits)f", scaled)
    }
}
