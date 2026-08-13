import Foundation
import SwiftUI

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
            unit: asset.unit
        )
    }

    var marketDescriptor: MarketAssetDescriptor {
        MarketAssetDescriptor(
            symbol: symbol,
            category: category,
            label: title,
            currency: currency,
            unit: unit,
            source: nil
        )
    }
}

extension RemoteMarketStore {
    var backtestAssetOptions: [BacktestAssetOption] {
        selectableAssetCatalog.map(BacktestAssetOption.init(asset:))
    }
}

extension MarketAssetDescriptor {
    var canonicalSymbol: String {
        BacktestAssetSymbol.normalized(symbol)
    }

    var sectionID: String {
        switch category.lowercased() {
        case "oil", "commodity": return "commodity"
        case "gold": return "precious_metal"
        default: return category.lowercased()
        }
    }

    var isUserSelectable: Bool {
        !["fx", "yield_signal", "fund"].contains(category.lowercased())
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

    var subtitle: String {
        let currencyText = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return currencyText.isEmpty ? canonicalSymbol.uppercased() : "\(canonicalSymbol.uppercased()) · \(currencyText)"
    }
}

enum MarketAssetCatalog {
    static func normalized(_ assets: [MarketAssetDescriptor]) -> [MarketAssetDescriptor] {
        var seen = Set<String>()
        return assets
            .filter(\.isUserSelectable)
            .sorted { lhs, rhs in
                if lhs.sectionID != rhs.sectionID { return sectionPriority(lhs.sectionID) < sectionPriority(rhs.sectionID) }
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
            .compactMap { asset in
                let symbol = asset.canonicalSymbol
                guard seen.insert(symbol).inserted else { return nil }
                return MarketAssetDescriptor(
                    symbol: symbol,
                    category: asset.category,
                    label: asset.label,
                    currency: asset.currency,
                    unit: asset.unit,
                    source: asset.source
                )
            }
    }

    static func sectionPriority(_ sectionID: String) -> Int {
        switch sectionID {
        case "index": return 0
        case "commodity": return 1
        case "precious_metal": return 2
        case "crypto": return 3
        case "fx": return 4
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sections) { asset in
                    Button {
                        selectedSectionID = asset.sectionID
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: asset.sectionIconName)
                                .font(AppTypography.chartCaption)
                            Text(asset.sectionTitle)
                                .font(AppTypography.captionStrong)
                        }
                        .foregroundStyle(selectedSectionID == asset.sectionID ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selectedSectionID == asset.sectionID ? AssetTheme.gold.opacity(0.14) : AssetTheme.overlaySubtle,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct MarketAssetOptionTile: View {
    let asset: MarketAssetDescriptor
    let isSelected: Bool
    var showsCheckbox = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: asset.assetIconName)
                    .font(AppTypography.blockTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? AssetTheme.gold : asset.color)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.displayTitle)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AssetTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(asset.subtitle)
                        .font(AppTypography.microLabel)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(1)
                }

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
            .frame(minHeight: 58)
            .background(isSelected ? AssetTheme.gold.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MarketAssetCatalogSelector: View {
    let assets: [MarketAssetDescriptor]
    @Binding var selectedSymbol: String?
    let isLocked: Bool
    var onSelect: ((MarketAssetDescriptor?) -> Void)?
    @State private var selectedSectionID: String

    init(
        assets: [MarketAssetDescriptor],
        selectedSymbol: Binding<String?>,
        isLocked: Bool,
        onSelect: ((MarketAssetDescriptor?) -> Void)? = nil
    ) {
        self.assets = assets
        _selectedSymbol = selectedSymbol
        self.isLocked = isLocked
        self.onSelect = onSelect
        let initialSymbol = selectedSymbol.wrappedValue.map(BacktestAssetSymbol.normalized)
        let initialSection = assets.first {
            $0.canonicalSymbol == initialSymbol
        }?.sectionID ?? assets.first?.sectionID ?? "index"
        _selectedSectionID = State(initialValue: initialSection)
    }

    private var visibleAssets: [MarketAssetDescriptor] {
        assets.filter { $0.sectionID == selectedSectionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarketAssetCategoryStrip(assets: assets, selectedSectionID: $selectedSectionID)

            VStack(spacing: 0) {
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

                ForEach(Array(visibleAssets.enumerated()), id: \.element.id) { index, asset in
                    MarketAssetOptionTile(
                        asset: asset,
                        isSelected: selectedSymbol.map(BacktestAssetSymbol.normalized) == asset.canonicalSymbol
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
            }
            .background(AssetTheme.overlaySubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .onChange(of: assets.map(\.id)) { _, _ in
            guard !assets.contains(where: { $0.sectionID == selectedSectionID }) else { return }
            selectedSectionID = assets.first?.sectionID ?? "index"
        }
    }
}
