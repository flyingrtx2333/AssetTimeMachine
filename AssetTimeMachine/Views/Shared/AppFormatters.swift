import Foundation
import SwiftUI

enum AppFormatterCache {
    private static let keyPrefix = "AssetTimeMachine.Formatter."

    private static var currentLocaleIdentifier: String {
        AppLocalization.currentLocale.identifier
    }

    static func currencyFormatter(code: String) -> NumberFormatter {
        let localeIdentifier = currentLocaleIdentifier
        return numberFormatter(key: "currency.\(localeIdentifier).\(code)") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
            formatter.locale = Locale(identifier: localeIdentifier)
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
        let localeIdentifier = currentLocaleIdentifier
        return numberFormatter(key: "percent.\(localeIdentifier).\(maxFractionDigits)") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .percent
            formatter.maximumFractionDigits = maxFractionDigits
            formatter.minimumFractionDigits = 0
            formatter.locale = Locale(identifier: localeIdentifier)
            return formatter
        }
    }

    static func dateFormatter(format: String, localeIdentifier: String? = nil) -> DateFormatter {
        let resolvedLocaleIdentifier = localeIdentifier ?? currentLocaleIdentifier
        return dateFormatter(key: "date.\(resolvedLocaleIdentifier).\(format)") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: resolvedLocaleIdentifier)
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

        let usesChineseLargeNumberUnits: Bool = {
            switch AppLocalization.currentLanguage {
            case .simplifiedChinese, .traditionalChinese:
                return true
            case .english:
                return false
            case .system:
                return AppLocalization.currentLocale.language.languageCode?.identifier == "zh"
            }
        }()

        if currencyCode?.uppercased() == "CNY", usesChineseLargeNumberUnits {
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
        AssetItemService.inferredAutoPricedAssetKind(for: name)
    }

    var resolvedAutoPricedAssetKind: AutoPricedAssetKind? {
        autoPricedAssetKind ?? inferredAutoPricedAssetKind
    }

    var autoPricedMarketSymbol: String? {
        guard valuationMethod == .quantityAndUnitPrice else { return nil }
        return marketAssetSymbol ?? resolvedAutoPricedAssetKind?.marketSymbol
    }

    var autoExchangeRateCurrencyCode: String? {
        guard let kind = resolvedAutoPricedAssetKind, kind.isCurrency else {
            return nil
        }
        return kind.rawValue.uppercased()
    }

    var compactRecordPlaceholder: String {
        if valuationMethod == .quantityAndUnitPrice {
            if let unit = persistedQuantityUnitTitle, !unit.isEmpty {
                return AppLocalization.format("输入数量（%@）", unit)
            }

            return AppLocalization.string("输入数量")
        }

        return AppLocalization.string("输入金额")
    }

    var persistedQuantityUnitTitle: String? {
        guard valuationMethod == .quantityAndUnitPrice else { return nil }
        if let currencyCode = autoExchangeRateCurrencyCode {
            return currencyCode
        }
        guard let symbol = autoPricedMarketSymbol else { return nil }
        if symbol.hasPrefix(MarketAssetDescriptor.recordETFPrefix)
            || symbol.hasPrefix(MarketAssetDescriptor.recordASharePrefix) {
            return AppLocalization.string("份")
        }
        switch BacktestAssetSymbol.normalized(symbol) {
        case "gold_cny", "gold_usd", "gold":
            return "g"
        case "btc", "eth", "bnb", "sol", "xrp", "doge":
            return BacktestAssetSymbol.normalized(symbol).uppercased()
        default:
            return nil
        }
    }

    @MainActor
    func quantityUnitTitle(using marketStore: RemoteMarketStore) -> String? {
        if let persistedQuantityUnitTitle { return persistedQuantityUnitTitle }
        guard let symbol = autoPricedMarketSymbol else { return nil }
        let unit = marketStore.assetDescriptor(for: symbol)?.recordUnitTitle ?? ""
        return unit.isEmpty ? nil : unit
    }

    @MainActor
    func quantityFieldTitle(using marketStore: RemoteMarketStore) -> String {
        guard let unit = quantityUnitTitle(using: marketStore), !unit.isEmpty else {
            return AppLocalization.string("数量")
        }
        return AppLocalization.format("数量（%@）", unit)
    }

    @MainActor
    func resolvedAutoUnitPrice(using marketStore: RemoteMarketStore) -> Double? {
        guard let symbol = autoPricedMarketSymbol else { return nil }
        return marketStore.recordUnitPriceInCNY(for: symbol)
    }

    @MainActor
    func autoPriceDisplayText(using marketStore: RemoteMarketStore) -> String? {
        if let currencyCode = autoExchangeRateCurrencyCode,
           let rate = marketStore.exchangeRate(for: currencyCode),
           rate > 0 {
            return AppLocalization.format("现价 %@", (1 / rate).currencyString())
        }

        guard let symbol = autoPricedMarketSymbol else {
            return nil
        }
        guard let cnyPrice = resolvedAutoUnitPrice(using: marketStore) else { return nil }
        let descriptor = marketStore.assetDescriptor(for: symbol)
        let priceText = cnyPrice.currencyString()
        let unit = (descriptor?.unit ?? marketStore.market(for: symbol)?.unit ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayUnit = descriptor?.recordUnitTitle ?? unit
        let unitSuffix = displayUnit.isEmpty ? "" : "/\(displayUnit)"
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

extension RemoteMarketStore {
    /// Resolves one record unit to CNY so quote previews, saved entries and
    /// portfolio market values all use the same currency convention.
    @MainActor
    func recordUnitPriceInCNY(for symbol: String) -> Double? {
        let normalizedSymbol = BacktestAssetSymbol.normalized(symbol)
        if let kind = AutoPricedAssetKind(rawValue: normalizedSymbol),
           kind.isCurrency,
           let rate = exchangeRate(for: kind.rawValue.uppercased()),
           rate.isFinite,
           rate > 0 {
            return 1 / rate
        }

        let rawPrice = market(for: normalizedSymbol)?.price
            ?? history(for: normalizedSymbol)?.prices.last
        guard let rawPrice, rawPrice.isFinite, rawPrice > 0 else { return nil }

        let rawCurrency = assetDescriptor(for: normalizedSymbol)?.currency
            ?? market(for: normalizedSymbol)?.currency
            ?? "CNY"
        let normalizedCurrency = rawCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let currencyCode = normalizedCurrency == "USDT" ? "USD" : normalizedCurrency
        guard !currencyCode.isEmpty, currencyCode != "CNY" else { return rawPrice }
        guard let rate = exchangeRate(for: currencyCode), rate.isFinite, rate > 0 else { return nil }
        return rawPrice / rate
    }
}

extension AssetCategory {
    func liabilitySortPriority(titleMap: [String: String]) -> Int {
        let normalized = name.replacingOccurrences(of: " ", with: "")
        let longTermTokens = ["长期", "長期", "Long-term", AppLocalization.string("长期")]
        let shortTermTokens = ["短期", "Short-term", AppLocalization.string("短期")]
        if longTermTokens.contains(where: normalized.contains) { return 0 }
        if shortTermTokens.contains(where: normalized.contains) { return 1 }
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
