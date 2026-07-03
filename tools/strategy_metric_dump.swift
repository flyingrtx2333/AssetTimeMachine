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

    static func fetchHistory(symbols: [String], period: String? = nil, includeOHLC: Bool = false) async throws -> PublicHistoryResponse {
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
