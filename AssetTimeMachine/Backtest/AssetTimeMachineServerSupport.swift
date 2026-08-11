#if ATM_SERVER
import Foundation

struct Color: Sendable {
    static let yellow = Color()
    static let blue = Color()
    static let orange = Color()
    static let red = Color()
    static let green = Color()
    static let primary = Color()
    static let secondary = Color()
}

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

struct BacktestSeriesPoint: Identifiable, Sendable {
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
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }
}
#endif
