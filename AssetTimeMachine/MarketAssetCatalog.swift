import Foundation
import SwiftUI
import UIKit

extension MarketAssetDescriptor {
    nonisolated init(series: PublicHistorySeries) {
        self.init(
            symbol: series.symbol,
            category: series.category,
            label: series.label,
            currency: series.currency,
            unit: series.unit,
            source: series.source
        )
    }
}

extension BacktestAssetOption {
    init(asset: MarketAssetDescriptor) {
        let currency = asset.currency.uppercased()
        let pricingCurrency = currency == "USDT" ? "USD" : currency
        let historicalFXSymbol: String? = switch pricingCurrency {
        case "USD": "usd_per_cny"
        case "HKD": "hkd_per_cny"
        case "JPY": "jpy_per_cny"
        default: nil
        }
        self.init(
            symbol: asset.canonicalSymbol,
            title: asset.displayTitle,
            color: asset.color,
            requiresHistoricalFX: historicalFXSymbol != nil,
            historicalFXSymbol: historicalFXSymbol,
            category: asset.sectionID,
            iconName: asset.assetIconName,
            currency: currency,
            unit: asset.unit,
            logoURL: asset.logoURL,
            logoSource: asset.logoSource
        )
    }

    var marketDescriptor: MarketAssetDescriptor {
        MarketAssetDescriptor(
            symbol: symbol,
            category: category,
            label: title,
            currency: currency,
            unit: unit,
            source: nil,
            logoURL: logoURL,
            logoSource: logoSource
        )
    }
}

extension RemoteMarketStore {
    var backtestAssetOptions: [BacktestAssetOption] {
        selectableAssetCatalog.map(BacktestAssetOption.init(asset:))
    }
}

private struct MarketAssetLogoStyle {
    let monogram: String?
    let systemImage: String?
    let colors: [Color]
    let foreground: Color
}

@MainActor
enum MarketAssetLogoRegistry {
    private static var logoURLsBySymbol: [String: String] = [:]

    static func register(_ assets: [MarketAssetDescriptor]) {
        for asset in assets {
            guard let logoURL = asset.logoURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !logoURL.isEmpty else { continue }
            logoURLsBySymbol[asset.canonicalSymbol] = logoURL

            guard asset.category.caseInsensitiveCompare("fx") == .orderedSame else { continue }
            let rawSymbol = asset.symbol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let currencyKind = AutoPricedAssetKind(rawValue: asset.currency.lowercased()),
               currencyKind.isCurrency {
                logoURLsBySymbol[currencyKind.marketSymbol] = logoURL
            }
            if rawSymbol.hasSuffix("_per_cny") {
                let currencyCode = String(rawSymbol.dropLast("_per_cny".count))
                if let currencyKind = AutoPricedAssetKind(rawValue: currencyCode),
                   currencyKind.isCurrency {
                    logoURLsBySymbol[currencyKind.marketSymbol] = logoURL
                }
            }
        }
    }

    static func logoURL(for symbol: String) -> String? {
        logoURLsBySymbol[BacktestAssetSymbol.normalized(symbol)]
    }
}

struct MarketAssetLogoView: View {
    let symbol: String
    let sectionID: String
    let title: String
    let logoURL: String?
    var size: CGFloat = 30
    @State private var remoteImage: UIImage?

    init(asset: MarketAssetDescriptor, size: CGFloat = 30) {
        symbol = asset.canonicalSymbol
        sectionID = asset.sectionID
        title = asset.displayTitle
        logoURL = asset.logoURL
        self.size = size
    }

    init(symbol: String, sectionID: String, title: String, logoURL: String? = nil, size: CGFloat = 30) {
        self.symbol = BacktestAssetSymbol.normalized(symbol)
        self.sectionID = sectionID
        self.title = title
        self.logoURL = logoURL
        self.size = size
    }

    private var style: MarketAssetLogoStyle {
        Self.logoStyle(symbol: symbol, sectionID: sectionID, title: title)
    }

    private var remoteLogoURL: URL? {
        let explicitLogoURL = logoURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLogoURL = explicitLogoURL?.isEmpty == false
            ? explicitLogoURL
            : MarketAssetLogoRegistry.logoURL(for: symbol)
        if let logoURL = resolvedLogoURL {
            return URL(string: logoURL, relativeTo: RemoteMarketClient.baseURL)?.absoluteURL
        }

        let serverSymbol: String
        let assetType: String
        if symbol.hasPrefix(MarketAssetDescriptor.recordETFPrefix) {
            serverSymbol = MarketAssetDescriptor.recordETFServerSymbol(from: symbol)
            assetType = "etf"
        } else if symbol.hasPrefix(MarketAssetDescriptor.recordASharePrefix) {
            serverSymbol = MarketAssetDescriptor.recordAShareServerSymbol(from: symbol)
            assetType = "a_share"
        } else {
            return nil
        }
        let encodedSymbol = serverSymbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serverSymbol
        return RemoteMarketClient.url(for: "/api/v1/money/public/asset-logos/\(assetType)/\(encodedSymbol).svg")
    }

    var body: some View {
        ZStack {
            backgroundShape

            if let systemImage = style.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.43, weight: .bold))
                    .symbolRenderingMode(.monochrome)
            } else {
                Text(style.monogram ?? "•")
                    .font(.system(size: monogramFontSize, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.62)
                    .lineLimit(1)
                    .padding(.horizontal, size * 0.08)
            }

            if let remoteImage {
                Image(uiImage: remoteImage)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            }
        }
        .foregroundStyle(style.foreground)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .shadow(color: style.colors.last?.opacity(0.18) ?? .clear, radius: size * 0.1, y: size * 0.04)
        .accessibilityHidden(true)
        .task(id: remoteLogoURL?.absoluteString) {
            guard let remoteLogoURL else {
                remoteImage = nil
                return
            }
            remoteImage = await MarketAssetLogoImageLoader.image(
                for: remoteLogoURL,
                pointSize: max(48, size * UIScreen.main.scale)
            )
        }
    }

    @ViewBuilder
    private var backgroundShape: some View {
        let gradient = LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        switch sectionID {
        case "index":
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(gradient)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.7)
                }
        case "fx":
            Circle()
                .fill(gradient)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.7), lineWidth: max(1, size * 0.06))
                        .padding(size * 0.12)
                }
        case "commodity", "precious_metal":
            RoundedRectangle(cornerRadius: size * 0.38, style: .continuous)
                .fill(gradient)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.38, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                }
        default:
            Circle()
                .fill(gradient)
                .overlay {
                    Circle().stroke(Color.white.opacity(0.16), lineWidth: 0.7)
                }
        }
    }

    private var monogramFontSize: CGFloat {
        let length = style.monogram?.count ?? 1
        return size * (length >= 4 ? 0.25 : length == 3 ? 0.29 : 0.38)
    }

    private static func logoStyle(symbol: String, sectionID: String, title: String) -> MarketAssetLogoStyle {
        let canonical = BacktestAssetSymbol.normalized(symbol)
        let serverSymbol = canonical.hasPrefix(MarketAssetDescriptor.recordASharePrefix)
            ? MarketAssetDescriptor.recordAShareServerSymbol(from: canonical)
            : MarketAssetDescriptor.recordETFServerSymbol(from: canonical)
        let ticker = normalizedTicker(from: serverSymbol)

        switch canonical {
        case "sp500": return textStyle("500", palette: 0)
        case "nasdaq": return textStyle("N", palette: 1)
        case "dowjones": return textStyle("DJ", palette: 5)
        case "nikkei": return textStyle("225", palette: 4)
        case "csi300": return textStyle("300", palette: 2)
        case "hsi": return textStyle("HS", palette: 6)
        case "shanghai_composite": return textStyle("SH", palette: 7)
        case "shenzhen_component": return textStyle("SZ", palette: 3)
        case "chinext": return textStyle("GEM", palette: 1)
        case "gold_cny", "gold_usd", "gold":
            return imageStyle("sparkles", colors: [Color(red: 0.95, green: 0.70, blue: 0.12), Color(red: 0.68, green: 0.39, blue: 0.04)], foreground: Color.white)
        case "silver_cny", "silver_usd", "silver":
            return imageStyle("hexagon.fill", colors: [Color(red: 0.78, green: 0.82, blue: 0.88), Color(red: 0.39, green: 0.45, blue: 0.55)], foreground: Color.white)
        case let value where value.contains("oil"):
            return imageStyle("drop.fill", colors: [Color(red: 0.18, green: 0.20, blue: 0.23), Color(red: 0.02, green: 0.03, blue: 0.04)], foreground: Color.white)
        case let value where value.contains("copper"):
            return imageStyle("circle.hexagonpath.fill", colors: [Color(red: 0.83, green: 0.43, blue: 0.20), Color(red: 0.48, green: 0.20, blue: 0.08)], foreground: Color.white)
        case "btc":
            return imageStyle("bitcoinsign", colors: [Color(red: 1.0, green: 0.66, blue: 0.12), Color(red: 0.92, green: 0.39, blue: 0.03)], foreground: Color.white)
        case "eth":
            return imageStyle("diamond.fill", colors: [Color(red: 0.50, green: 0.49, blue: 0.92), Color(red: 0.25, green: 0.24, blue: 0.61)], foreground: Color.white)
        case "sol":
            return imageStyle("bolt.fill", colors: [Color(red: 0.12, green: 0.87, blue: 0.67), Color(red: 0.43, green: 0.16, blue: 0.78)], foreground: Color.white)
        default:
            break
        }

        if sectionID == "fx" {
            return textStyle(currencyMark(symbol: canonical, title: title), palette: stablePaletteIndex(for: canonical))
        }

        switch ticker {
        case "AAPL":
            return imageStyle("apple.logo", colors: [Color(red: 0.44, green: 0.46, blue: 0.50), Color(red: 0.16, green: 0.17, blue: 0.19)], foreground: Color.white)
        case "MSFT":
            return imageStyle("square.grid.2x2.fill", colors: [Color(red: 0.14, green: 0.51, blue: 0.93), Color(red: 0.07, green: 0.30, blue: 0.68)], foreground: Color.white)
        case "NVDA":
            return imageStyle("cpu.fill", colors: [Color(red: 0.49, green: 0.78, blue: 0.12), Color(red: 0.21, green: 0.48, blue: 0.03)], foreground: Color.white)
        case "TSLA":
            return imageStyle("bolt.car.fill", colors: [Color(red: 0.95, green: 0.20, blue: 0.17), Color(red: 0.66, green: 0.03, blue: 0.07)], foreground: Color.white)
        case "AMZN": return textStyle("a", palette: 8)
        case "META": return textStyle("M", palette: 1)
        case "GOOG", "GOOGL": return textStyle("G", palette: 6)
        case "JPM", "BAC", "C", "GS":
            return imageStyle("building.columns.fill", colors: palette(at: stablePaletteIndex(for: ticker)), foreground: Color.white)
        case "QQQ": return textStyle("Q", palette: 9)
        case "SPY": return textStyle("SPY", palette: 0)
        case "VOO": return textStyle("V", palette: 5)
        case "GLD":
            return imageStyle("sparkles", colors: [Color(red: 0.95, green: 0.70, blue: 0.12), Color(red: 0.68, green: 0.39, blue: 0.04)], foreground: Color.white)
        default:
            let monogram = tickerMonogram(ticker: ticker, title: title)
            return textStyle(monogram, palette: stablePaletteIndex(for: canonical + title))
        }
    }

    private static func normalizedTicker(from symbol: String) -> String {
        let uppercased = symbol.uppercased()
        let components = uppercased.split(whereSeparator: { ".:/-_".contains($0) }).map(String.init)
        if let securityCode = components.first,
           !securityCode.isEmpty,
           securityCode.allSatisfy(\.isNumber) {
            return securityCode
        }
        if let letters = components.first(where: { $0.rangeOfCharacter(from: .letters) != nil }), letters.count <= 6 {
            return letters
        }
        return components.first ?? uppercased
    }

    private static func tickerMonogram(ticker: String, title: String) -> String {
        let compactTicker = ticker.filter(\.isLetter)
        if !compactTicker.isEmpty {
            return String(compactTicker.prefix(4)).uppercased()
        }
        let digits = ticker.filter(\.isNumber)
        if !digits.isEmpty {
            return String(digits.suffix(3))
        }
        let words = title.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let initials = words.prefix(3).compactMap(\.first).map(String.init).joined()
        return initials.isEmpty ? "•" : initials.uppercased()
    }

    private static func currencyMark(symbol: String, title: String) -> String {
        let combined = "\(symbol) \(title)".uppercased()
        if combined.contains("EUR") { return "€" }
        if combined.contains("GBP") { return "£" }
        if combined.contains("KRW") { return "₩" }
        if combined.contains("JPY") || combined.contains("CNY") { return "¥" }
        if combined.contains("HKD") { return "HK$" }
        if combined.contains("AUD") { return "A$" }
        if combined.contains("CAD") { return "C$" }
        if combined.contains("SGD") { return "S$" }
        return "$"
    }

    private static func stablePaletteIndex(for value: String) -> Int {
        value.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff } % palettes.count
    }

    private static func textStyle(_ text: String, palette index: Int) -> MarketAssetLogoStyle {
        MarketAssetLogoStyle(monogram: text, systemImage: nil, colors: palette(at: index), foreground: Color.white)
    }

    private static func imageStyle(_ systemImage: String, colors: [Color], foreground: Color) -> MarketAssetLogoStyle {
        MarketAssetLogoStyle(monogram: nil, systemImage: systemImage, colors: colors, foreground: foreground)
    }

    private static func palette(at index: Int) -> [Color] {
        palettes[index % palettes.count]
    }

    private static let palettes: [[Color]] = [
        [Color(red: 0.22, green: 0.47, blue: 0.92), Color(red: 0.09, green: 0.23, blue: 0.60)],
        [Color(red: 0.04, green: 0.69, blue: 0.79), Color(red: 0.04, green: 0.34, blue: 0.56)],
        [Color(red: 0.18, green: 0.68, blue: 0.47), Color(red: 0.04, green: 0.37, blue: 0.25)],
        [Color(red: 0.49, green: 0.37, blue: 0.90), Color(red: 0.26, green: 0.16, blue: 0.61)],
        [Color(red: 0.91, green: 0.33, blue: 0.39), Color(red: 0.58, green: 0.08, blue: 0.15)],
        [Color(red: 0.25, green: 0.35, blue: 0.65), Color(red: 0.12, green: 0.16, blue: 0.37)],
        [Color(red: 0.97, green: 0.52, blue: 0.18), Color(red: 0.69, green: 0.24, blue: 0.04)],
        [Color(red: 0.78, green: 0.28, blue: 0.72), Color(red: 0.44, green: 0.09, blue: 0.46)],
        [Color(red: 0.18, green: 0.20, blue: 0.23), Color(red: 0.04, green: 0.05, blue: 0.07)],
        [Color(red: 0.58, green: 0.38, blue: 0.96), Color(red: 0.28, green: 0.13, blue: 0.65)]
    ]
}

extension MarketAssetDescriptor {
    nonisolated static let recordETFPrefix = "record_etf:"
    nonisolated static let recordASharePrefix = "record_a_share:"

    nonisolated static func recordETFSymbol(from serverSymbol: String) -> String {
        let normalized = serverSymbol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "" }
        return recordETFPrefix + normalized
    }

    nonisolated static func recordETFServerSymbol(from symbol: String) -> String {
        let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.lowercased().hasPrefix(recordETFPrefix) else { return normalized.uppercased() }
        return String(normalized.dropFirst(recordETFPrefix.count)).uppercased()
    }

    nonisolated static func recordAShareSymbol(from serverSymbol: String) -> String {
        let normalized = serverSymbol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "" }
        return recordASharePrefix + normalized
    }

    nonisolated static func recordAShareServerSymbol(from symbol: String) -> String {
        let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.lowercased().hasPrefix(recordASharePrefix) else { return normalized.uppercased() }
        return String(normalized.dropFirst(recordASharePrefix.count)).uppercased()
    }

    var isRecordETF: Bool {
        canonicalSymbol.hasPrefix(Self.recordETFPrefix) || category.lowercased() == "etf"
    }

    var isRecordAShare: Bool {
        canonicalSymbol.hasPrefix(Self.recordASharePrefix) || category.lowercased() == "a_share"
    }

    var isRecordSecurity: Bool {
        isRecordETF || isRecordAShare
    }

    var recordUnitTitle: String {
        if isRecordSecurity { return AppLocalization.string("份") }

        switch unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "share", "shares", "unit", "units", "份":
            return AppLocalization.string("份")
        case "gram", "grams", "g":
            return "g"
        case "index", "point", "points":
            return AppLocalization.string("点")
        case "currency", "cash":
            return currency.uppercased()
        case "coin", "coins":
            return canonicalSymbol.uppercased()
        case let value where !value.isEmpty:
            return value
        default:
            return ""
        }
    }

    var canonicalSymbol: String {
        BacktestAssetSymbol.normalized(symbol)
    }

    var sectionID: String {
        if isRecordETF { return "etf" }
        if isRecordAShare { return "a_share" }
        switch category.lowercased() {
        case "oil", "commodity": return "commodity"
        case "gold": return "precious_metal"
        default: return category.lowercased()
        }
    }

    var isUserSelectable: Bool {
        switch category.lowercased() {
        case "fx":
            return AutoPricedAssetKind(rawValue: canonicalSymbol)?.isCurrency == true
        case "yield_signal", "fund":
            return false
        default:
            return true
        }
    }

    var displayTitle: String {
        let localizedKey: String
        switch canonicalSymbol {
        case "gold_cny", "gold_usd": localizedKey = "黄金"
        case "nasdaq": localizedKey = "纳斯达克综合指数"
        case "sp500": localizedKey = "标普500"
        case "dowjones": localizedKey = "道指"
        case "nikkei": localizedKey = "日经225"
        case "shanghai_composite": localizedKey = "上证综指"
        case "shenzhen_component": localizedKey = "深成指"
        case "csi300": localizedKey = "沪深300"
        case "chinext": localizedKey = "创业板"
        case "hsi": localizedKey = "恒生"
        case "oil_wti_cny", "oil_wti_usd": localizedKey = "WTI原油"
        case "oil_brent_cny", "oil_brent_usd": localizedKey = "布伦特原油"
        case "silver_cny", "silver_usd": localizedKey = "白银"
        case "copper_cny", "copper_usd": localizedKey = "铜"
        case "btc": localizedKey = "比特币 BTC"
        case "eth": localizedKey = "以太坊 ETH"
        default: return label.isEmpty ? symbol : label
        }
        let localizedTitle = AppLocalization.string(localizedKey)
        let hasCurrencyVariant = canonicalSymbol.hasSuffix("_cny") || canonicalSymbol.hasSuffix("_usd")
        return hasCurrencyVariant ? "\(localizedTitle) · \(currency.uppercased())" : localizedTitle
    }

    var sectionTitle: String {
        switch sectionID {
        case "etf": return "ETF"
        case "a_share": return AppLocalization.string("A股")
        case "index": return AppLocalization.string("指数")
        case "commodity": return AppLocalization.string("大宗商品")
        case "precious_metal": return AppLocalization.string("贵金属")
        case "crypto": return AppLocalization.string("数字货币")
        case "fx": return AppLocalization.string("外汇")
        default: return AppLocalization.string(category.isEmpty ? "其他" : category)
        }
    }

    var sectionIconName: String {
        switch sectionID {
        case "etf": return "chart.pie.fill"
        case "a_share": return "building.2.fill"
        case "index": return "chart.line.uptrend.xyaxis"
        case "commodity": return "shippingbox.fill"
        case "precious_metal": return "seal.fill"
        case "crypto": return "cube.transparent.fill"
        case "fx": return "arrow.left.arrow.right.circle.fill"
        default: return "square.grid.2x2.fill"
        }
    }

    var color: Color {
        switch sectionID {
        case "etf": return AssetTheme.accentBlue
        case "a_share": return AssetTheme.accentRed
        case "index": return AssetTheme.accentBlue
        case "commodity": return AssetTheme.accentOrange
        case "precious_metal": return AssetTheme.gold
        case "crypto": return AssetTheme.positive
        case "fx": return AssetTheme.accentRed
        default: return AssetTheme.textSecondary
        }
    }

    var assetIconName: String {
        let variants: [String]
        switch sectionID {
        case "etf":
            variants = ["chart.pie.fill", "chart.bar.xaxis", "building.columns.fill", "globe.asia.australia.fill", "waveform.path.ecg"]
        case "a_share":
            variants = ["building.2.fill", "chart.line.uptrend.xyaxis", "building.columns.fill", "waveform.path.ecg"]
        case "index":
            variants = ["chart.line.uptrend.xyaxis", "globe.americas.fill", "building.columns.fill", "waveform.path.ecg"]
        case "commodity":
            variants = ["drop.fill", "flame.fill", "circle.hexagongrid.fill", "shippingbox.fill"]
        case "precious_metal":
            variants = ["seal.fill", "sparkles", "hexagon.fill"]
        case "crypto":
            variants = ["bitcoinsign.circle.fill", "cube.transparent.fill", "circle.hexagonpath.fill", "network"]
        case "fx":
            variants = ["dollarsign.circle.fill", "arrow.left.arrow.right.circle.fill"]
        default:
            variants = ["square.grid.2x2.fill"]
        }
        let stableIndex = canonicalSymbol.unicodeScalars.reduce(0) { $0 + Int($1.value) } % variants.count
        return variants[stableIndex]
    }

    var suggestedIconKey: String {
        "market_asset|\(sectionID)|\(canonicalSymbol)"
    }

}

enum MarketAssetCatalog {
    static var recordCurrencyAssets: [MarketAssetDescriptor] {
        AutoPricedAssetKind.allCases.compactMap { kind in
            guard kind.isCurrency else { return nil }
            return MarketAssetDescriptor(
                symbol: kind.marketSymbol,
                category: "fx",
                label: kind.displayName,
                currency: kind.rawValue.uppercased(),
                unit: "currency",
                source: nil
            )
        }
    }

    static func normalized(_ assets: [MarketAssetDescriptor]) -> [MarketAssetDescriptor] {
        var assetsBySymbol: [String: MarketAssetDescriptor] = [:]
        for asset in assets where asset.isUserSelectable {
            let symbol = asset.canonicalSymbol
            if let existing = assetsBySymbol[symbol],
               existing.logoURL?.isEmpty == false,
               asset.logoURL?.isEmpty != false {
                continue
            }
            assetsBySymbol[symbol] = MarketAssetDescriptor(
                symbol: symbol,
                category: asset.category,
                label: asset.label,
                currency: asset.currency,
                unit: asset.unit,
                source: asset.source,
                logoURL: asset.logoURL,
                logoSource: asset.logoSource
            )
        }

        return assetsBySymbol.values
            .sorted { lhs, rhs in
                if lhs.sectionID != rhs.sectionID { return sectionPriority(lhs.sectionID) < sectionPriority(rhs.sectionID) }
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
    }

    static func sectionPriority(_ sectionID: String) -> Int {
        switch sectionID {
        case "etf": return 0
        case "a_share": return 1
        case "index": return 2
        case "commodity": return 3
        case "precious_metal": return 4
        case "crypto": return 5
        case "fx": return 6
        default: return 10
        }
    }

    static var offlineFallback: [MarketAssetDescriptor] {
        let legacy = BacktestDefaults.dcaAssetOptions.map { option in
            MarketAssetDescriptor(
                symbol: option.symbol,
                category: option.symbol == "gold_cny" ? "gold" : "index",
                label: option.title,
                currency: option.requiresHistoricalFX ? "USD" : "CNY",
                unit: option.symbol == "gold_cny" ? "gram" : "index",
                source: nil
            )
        }
        let crypto = AutoPricedAssetKind.allCases.compactMap { kind -> MarketAssetDescriptor? in
            guard !kind.isCurrency, kind != .gold else { return nil }
            return MarketAssetDescriptor(
                symbol: kind.marketSymbol,
                category: "crypto",
                label: kind.displayName,
                currency: "USD",
                unit: "coin",
                source: nil
            )
        }
        return normalized(legacy + crypto)
    }
}

struct MarketAssetCategoryStrip: View {
    let assets: [MarketAssetDescriptor]
    @Binding var selectedSectionID: String

    private var sections: [MarketAssetDescriptor] {
        var seen = Set<String>()
        return assets.filter { seen.insert($0.sectionID).inserted }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sections) { asset in
                        Button {
                            selectedSectionID = asset.sectionID
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(asset.sectionID, anchor: .center)
                            }
                        } label: {
                            Text(asset.sectionTitle)
                                .font(AppTypography.captionStrong)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(selectedSectionID == asset.sectionID ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    selectedSectionID == asset.sectionID ? AssetTheme.gold.opacity(0.14) : AssetTheme.overlaySubtle,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .id(asset.sectionID)
                    }
                }
                .padding(.trailing, 2)
            }
            .onChange(of: selectedSectionID) { _, sectionID in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(sectionID, anchor: .center)
                }
            }
        }
    }
}

struct MarketAssetOptionTile: View {
    let asset: MarketAssetDescriptor
    let isSelected: Bool
    var showsCheckbox = false
    var isDeemphasized = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                MarketAssetLogoView(asset: asset, size: 30)
                    .saturation(isDeemphasized ? 0 : 1)
                    .opacity(isDeemphasized ? 0.46 : 1)

                Text(asset.displayTitle)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(isDeemphasized ? AssetTheme.textSecondary.opacity(0.58) : AssetTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                if showsCheckbox {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(AppTypography.blockTitle)
                        .foregroundStyle(isSelected ? AssetTheme.gold : AssetTheme.textSecondary.opacity(0.55))
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(AssetTheme.gold)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 50)
            .background(isSelected ? AssetTheme.gold.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum MarketAssetCatalogPresentationStyle {
    case grouped
    case flat
}

struct MarketAssetCatalogSelector: View {
    let assets: [MarketAssetDescriptor]
    @Binding var selectedSymbol: String?
    @Binding var searchText: String
    let isLocked: Bool
    let isSearching: Bool
    let searchMessage: String?
    let presentationStyle: MarketAssetCatalogPresentationStyle
    let canLoadMore: ((String) -> Bool)?
    let isLoadingMore: ((String) -> Bool)?
    let onLoadMore: ((String) -> Void)?
    var onSelect: ((MarketAssetDescriptor?) -> Void)?
    @State private var selectedSectionID: String

    init(
        assets: [MarketAssetDescriptor],
        selectedSymbol: Binding<String?>,
        searchText: Binding<String> = .constant(""),
        isLocked: Bool,
        isSearching: Bool = false,
        searchMessage: String? = nil,
        presentationStyle: MarketAssetCatalogPresentationStyle = .grouped,
        canLoadMore: ((String) -> Bool)? = nil,
        isLoadingMore: ((String) -> Bool)? = nil,
        onLoadMore: ((String) -> Void)? = nil,
        onSelect: ((MarketAssetDescriptor?) -> Void)? = nil
    ) {
        self.assets = assets
        _selectedSymbol = selectedSymbol
        _searchText = searchText
        self.isLocked = isLocked
        self.isSearching = isSearching
        self.searchMessage = searchMessage
        self.presentationStyle = presentationStyle
        self.canLoadMore = canLoadMore
        self.isLoadingMore = isLoadingMore
        self.onLoadMore = onLoadMore
        self.onSelect = onSelect
        let initialSymbol = selectedSymbol.wrappedValue.map(BacktestAssetSymbol.normalized)
        let initialSection = assets.first {
            $0.canonicalSymbol == initialSymbol
        }?.sectionID ?? assets.first?.sectionID ?? "index"
        _selectedSectionID = State(initialValue: initialSection)
    }

    private var visibleAssets: [MarketAssetDescriptor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return assets.filter { asset in
                asset.displayTitle.localizedCaseInsensitiveContains(query)
                    || MarketAssetDescriptor.recordETFServerSymbol(from: asset.symbol).localizedCaseInsensitiveContains(query)
                    || MarketAssetDescriptor.recordAShareServerSymbol(from: asset.symbol).localizedCaseInsensitiveContains(query)
            }
        }
        return assets.filter { $0.sectionID == selectedSectionID }
    }

    private var showsLoadMore: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && canLoadMore?(selectedSectionID) == true
    }

    private var isLoadingSelectedSection: Bool {
        isLoadingMore?(selectedSectionID) == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isLocked {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(AssetTheme.textSecondary)
                    TextField(AppLocalization.string("搜索股票、ETF 或资产"), text: $searchText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AssetTheme.textPrimary)
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AssetTheme.gold)
                    } else if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(AssetTheme.overlaySubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarketAssetCategoryStrip(assets: assets, selectedSectionID: $selectedSectionID)
            }

            assetList

            if let searchMessage, !searchMessage.isEmpty {
                Text(searchMessage)
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .padding(.horizontal, 4)
            }
        }
        .onChange(of: assets.map(\.id)) { _, _ in
            guard !assets.contains(where: { $0.sectionID == selectedSectionID }) else { return }
            selectedSectionID = assets.first?.sectionID ?? "index"
        }
    }

    @ViewBuilder
    private var assetList: some View {
        let content = LazyVStack(spacing: 0) {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    guard !isLocked else { return }
                    selectedSymbol = nil
                    onSelect?(nil)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(AppTypography.blockTitle)
                            .foregroundStyle(selectedSymbol == nil ? AssetTheme.gold : AssetTheme.textSecondary)
                            .frame(width: 28, height: 28)
                        Text(AppLocalization.string("不关联市场标的"))
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(AssetTheme.textPrimary)
                        Spacer()
                        if selectedSymbol == nil {
                            Image(systemName: "checkmark")
                                .font(AppTypography.captionStrong)
                                .foregroundStyle(AssetTheme.gold)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLocked)

                Divider().overlay(AssetTheme.border.opacity(0.36))
            }

            ForEach(Array(visibleAssets.enumerated()), id: \.element.id) { index, asset in
                MarketAssetOptionTile(
                    asset: asset,
                    isSelected: selectedSymbol.map(BacktestAssetSymbol.normalized) == asset.canonicalSymbol,
                    isDeemphasized: selectedSymbol == nil
                ) {
                    guard !isLocked else { return }
                    selectedSymbol = asset.canonicalSymbol
                    onSelect?(asset)
                }
                .disabled(isLocked)

                if index < visibleAssets.count - 1 {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.28))
                        .padding(.leading, 51)
                }
            }

            if showsLoadMore {
                if !visibleAssets.isEmpty {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.28))
                        .padding(.leading, 51)
                }

                Button {
                    onLoadMore?(selectedSectionID)
                } label: {
                    HStack(spacing: 8) {
                        if isLoadingSelectedSection {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AssetTheme.gold)
                        } else {
                            Image(systemName: "chevron.down")
                                .font(AppTypography.chartCaption)
                        }
                        Text(AppLocalization.string("加载更多"))
                            .font(AppTypography.captionStrong)
                    }
                    .foregroundStyle(AssetTheme.goldSoft)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLoadingSelectedSection)
            }

            if visibleAssets.isEmpty, !isSearching {
                Text(AppLocalization.string("未找到匹配的资产"))
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
        }

        if presentationStyle == .grouped {
            content
                .background(AssetTheme.overlaySubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            content
                .overlay(alignment: .top) {
                    Divider().overlay(AssetTheme.border.opacity(0.24))
                }
                .overlay(alignment: .bottom) {
                    Divider().overlay(AssetTheme.border.opacity(0.24))
                }
        }
    }
}
