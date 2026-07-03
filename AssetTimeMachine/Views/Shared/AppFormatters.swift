import Foundation
import SwiftUI

enum AppFormatterCache {
    private static let keyPrefix = "AssetTimeMachine.Formatter."

    static func currencyFormatter(code: String) -> NumberFormatter {
        numberFormatter(key: "currency.\(code)") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
            formatter.locale = Locale(identifier: "zh_CN")
            return formatter
        }
    }

    static func plainNumberFormatter() -> NumberFormatter {
        numberFormatter(key: "decimal.plain") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 4
            formatter.minimumFractionDigits = 0
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }
    }

    static func compactNumberFormatter(maxFractionDigits: Int) -> NumberFormatter {
        numberFormatter(key: "decimal.compact.\(maxFractionDigits)") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = maxFractionDigits
            formatter.minimumFractionDigits = 0
            formatter.usesGroupingSeparator = false
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }
    }

    static func percentFormatter(maxFractionDigits: Int) -> NumberFormatter {
        numberFormatter(key: "percent.\(maxFractionDigits)") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .percent
            formatter.maximumFractionDigits = maxFractionDigits
            formatter.minimumFractionDigits = 0
            formatter.locale = Locale(identifier: "zh_CN")
            return formatter
        }
    }

    static func dateFormatter(format: String, localeIdentifier: String = "zh_CN") -> DateFormatter {
        dateFormatter(key: "date.\(localeIdentifier).\(format)") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: localeIdentifier)
            formatter.dateFormat = format
            return formatter
        }
    }

    private static func numberFormatter(key: String, make: () -> NumberFormatter) -> NumberFormatter {
        let cacheKey = keyPrefix + key
        if let formatter = Thread.current.threadDictionary[cacheKey] as? NumberFormatter {
            return formatter
        }
        let formatter = make()
        Thread.current.threadDictionary[cacheKey] = formatter
        return formatter
    }

    private static func dateFormatter(key: String, make: () -> DateFormatter) -> DateFormatter {
        let cacheKey = keyPrefix + key
        if let formatter = Thread.current.threadDictionary[cacheKey] as? DateFormatter {
            return formatter
        }
        let formatter = make()
        Thread.current.threadDictionary[cacheKey] = formatter
        return formatter
    }
}

extension Double {
    func currencyString(code: String = "CNY") -> String {
        let formatter = AppFormatterCache.currencyFormatter(code: code)
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.2f", self)
    }

    func plainNumberString() -> String {
        let formatter = AppFormatterCache.plainNumberFormatter()
        return formatter.string(from: NSNumber(value: self)) ?? String(self)
    }

    func compactNumberString(maxFractionDigits: Int = 1, currencyCode: String? = nil) -> String {
        let formatter = AppFormatterCache.compactNumberFormatter(maxFractionDigits: maxFractionDigits)

        let absValue = abs(self)
        let sign = self < 0 ? "-" : ""

        func formattedUnit(_ value: Double, suffix: String) -> String {
            let number = formatter.string(from: NSNumber(value: value)) ?? String(value)
            return "\(sign)\(number)\(suffix)"
        }

        if currencyCode?.uppercased() == "CNY" {
            switch absValue {
            case 100_000_000...:
                return formattedUnit(absValue / 100_000_000, suffix: AppLocalization.string("亿"))
            case 10_000...:
                return formattedUnit(absValue / 10_000, suffix: AppLocalization.string("万"))
            default:
                return formatter.string(from: NSNumber(value: self)) ?? String(self)
            }
        }

        switch absValue {
        case 1_000_000_000...:
            return formattedUnit(absValue / 1_000_000_000, suffix: "B")
        case 1_000_000...:
            return formattedUnit(absValue / 1_000_000, suffix: "M")
        case 1_000...:
            return formattedUnit(absValue / 1_000, suffix: "K")
        default:
            return formatter.string(from: NSNumber(value: self)) ?? String(self)
        }
    }

    func chartAxisCurrencyLabel(code: String, maxFractionDigits: Int = 1) -> String {
        let symbol: String
        switch code.uppercased() {
        case "USD":
            symbol = "$"
        case "HKD":
            symbol = "HK$"
        case "JPY":
            symbol = "¥"
        case "GBP":
            symbol = "£"
        case "EUR":
            symbol = "€"
        default:
            symbol = "¥"
        }
        return "\(symbol)\(compactNumberString(maxFractionDigits: maxFractionDigits, currencyCode: code))"
    }

    func percentString(maxFractionDigits: Int = 2) -> String {
        let formatter = AppFormatterCache.percentFormatter(maxFractionDigits: maxFractionDigits)
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.2f%%", self * 100)
    }
}

extension AssetCategory {
    var activeSortedItems: [AssetItem] {
        items
            .filter(\.isActive)
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.sortOrder < rhs.sortOrder
            }
    }
}

extension AssetItem {
    var latestEntry: AssetEntry? {
        entries.max { lhs, rhs in
            (lhs.snapshot?.date ?? .distantPast) < (rhs.snapshot?.date ?? .distantPast)
        }
    }

    var inferredAutoPricedAssetKind: AutoPricedAssetKind? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        if trimmedName == AppLocalization.string("黄金") || trimmedName.caseInsensitiveCompare("gold") == .orderedSame {
            return .gold
        }

        let uppercasedName = trimmedName.uppercased()
        let legacyMappings: [(AutoPricedAssetKind, [String])] = [
            (.btc, ["BTC", "BITCOIN"]),
            (.eth, ["ETH", "ETHEREUM"]),
            (.bnb, ["BNB"]),
            (.sol, ["SOL", "SOLANA"]),
            (.xrp, ["XRP"]),
            (.doge, ["DOGE", "DOGECOIN"]),
        ]

        for (kind, candidates) in legacyMappings {
            if candidates.contains(uppercasedName) {
                return kind
            }
        }

        for currencyCode in ["USD", "EUR", "GBP", "JPY", "HKD", "SGD", "AUD", "CAD", "KRW"] {
            if uppercasedName.hasSuffix(" \(currencyCode)") || uppercasedName == currencyCode {
                return AutoPricedAssetKind(rawValue: currencyCode.lowercased())
            }
        }

        return nil
    }

    var resolvedAutoPricedAssetKind: AutoPricedAssetKind? {
        autoPricedAssetKind ?? inferredAutoPricedAssetKind
    }

    var autoPricedMarketSymbol: String? {
        guard valuationMethod == .quantityAndUnitPrice else { return nil }
        return resolvedAutoPricedAssetKind?.marketSymbol
    }

    var autoExchangeRateCurrencyCode: String? {
        guard let kind = resolvedAutoPricedAssetKind, kind.isCurrency else {
            return nil
        }
        return kind.rawValue.uppercased()
    }

    var prefersCompactRecordInput: Bool {
        true
    }

    var compactRecordPlaceholder: String {
        if valuationMethod == .quantityAndUnitPrice {
            if let currencyCode = autoExchangeRateCurrencyCode {
                return AppLocalization.format("输入%@ 数量", currencyCode)
            }

            if let autoKind = resolvedAutoPricedAssetKind {
                return AppLocalization.format("输入%@ 数量", AppLocalization.string(autoKind.defaultName))
            }

            return AppLocalization.string("输入数量")
        }

        return AppLocalization.string("输入金额")
    }

    @MainActor
    func resolvedAutoUnitPrice(using marketStore: RemoteMarketStore) -> Double? {
        if let currencyCode = autoExchangeRateCurrencyCode,
           let rate = marketStore.exchangeRate(for: currencyCode),
           rate > 0 {
            return 1 / rate
        }

        if let symbol = autoPricedMarketSymbol {
            return marketStore.market(for: symbol)?.price
        }

        return nil
    }

    @MainActor
    func autoPriceDisplayText(using marketStore: RemoteMarketStore) -> String? {
        if let currencyCode = autoExchangeRateCurrencyCode,
           let rate = marketStore.exchangeRate(for: currencyCode),
           rate > 0 {
            return AppLocalization.format("现价 %@", (1 / rate).currencyString())
        }

        guard let symbol = autoPricedMarketSymbol,
              let market = marketStore.market(for: symbol) else {
            return nil
        }

        let currencyCode = market.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let priceText: String
        if currencyCode.count == 3 {
            priceText = market.price.currencyString(code: currencyCode)
        } else if currencyCode.isEmpty {
            priceText = market.price.plainNumberString()
        } else {
            priceText = "\(market.price.plainNumberString()) \(currencyCode)"
        }

        let unit = market.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let unitSuffix = unit.isEmpty ? "" : "/\(unit)"
        return AppLocalization.format("现价 %@%@", priceText, unitSuffix)
    }

    @MainActor
    func autoPriceFetchedAt(using marketStore: RemoteMarketStore) -> Date? {
        if autoExchangeRateCurrencyCode != nil {
            return marketStore.exchangeRatesFetchedAt
        }

        if let symbol = autoPricedMarketSymbol {
            return marketStore.market(for: symbol)?.fetchedAt
        }

        return nil
    }

}

extension AssetGroup {
    var sortPriority: Int {
        switch self {
        case .financial: return 0
        case .physical: return 1
        case .liability: return 2
        }
    }
}

extension AssetCategory {
    func liabilitySortPriority(titleMap: [String: String]) -> Int {
        let normalized = name.replacingOccurrences(of: " ", with: "")
        if normalized.contains(AppLocalization.string("长期")) { return 0 }
        if normalized.contains(AppLocalization.string("短期")) { return 1 }
        if titleMap[normalized] != nil { return 0 }
        return 2
    }
}

extension Date {
    var shortDateString: String {
        AppFormatterCache.dateFormatter(format: AppLocalization.string("M月d日")).string(from: self)
    }

    var longDateString: String {
        AppFormatterCache.dateFormatter(format: AppLocalization.string("yyyy年M月d日")).string(from: self)
    }

    var chineseLongDateString: String {
        AppFormatterCache.dateFormatter(format: AppLocalization.string("yyyy年M月d日")).string(from: self)
    }

    var recordDateString: String {
        AppFormatterCache.dateFormatter(format: "yyyy.M.d").string(from: self)
    }

    var chartAxisDateString: String {
        AppFormatterCache.dateFormatter(format: "yyyy.MM.dd").string(from: self)
    }

    var chartAxisShortDateString: String {
        AppFormatterCache.dateFormatter(format: "yy.MM.dd").string(from: self)
    }

    var chartAxisCompactTickString: String {
        AppFormatterCache.dateFormatter(format: "M.d").string(from: self)
    }

    var dashboardAxisDateString: String {
        AppFormatterCache.dateFormatter(format: "yy.MM").string(from: self)
    }

    var yearAxisDateString: String {
        AppFormatterCache.dateFormatter(format: "yyyy").string(from: self)
    }

    var recordTimeString: String {
        AppFormatterCache.dateFormatter(format: "HH:mm").string(from: self)
    }
}
