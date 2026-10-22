import Foundation
import SwiftUI
import AssetTimeMachineBacktestCore

enum BacktestMode: String, CaseIterable, Identifiable {
    case allocation
    case dca

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allocation:
            return AppLocalization.string("配置回测")
        case .dca:
            return AppLocalization.string("定投回测")
        }
    }
}



enum BacktestPage: String, CaseIterable, Identifiable {
    case home
    case standard
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return AppLocalization.string("量化")
        case .standard:
            return AppLocalization.string("基础回测")
        case .advanced:
            return AppLocalization.string("策略回测")
        }
    }
}



enum BacktestTopTab: String, CaseIterable, Identifiable {
    case allocation
    case dca
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allocation:
            return AppLocalization.string("配置")
        case .dca:
            return AppLocalization.string("定投")
        case .advanced:
            return AppLocalization.string("高级")
        }
    }
}



struct AdvancedBacktestComputationResult: Sendable {
    let report: AdvancedBacktestReport?
    let rebalanceAdvice: StrategyRebalanceAdvice?
    let comparisonSeries: [BacktestChartComparisonSeries]
}



struct AdvancedBacktestCandidate: Identifiable {
    let id = UUID()
    let buyRule: AdvancedBacktestRule
    let sellRule: AdvancedBacktestRule
    let tradeAmount: Double
    let settings: AdvancedBacktestRiskSettings
    let report: AdvancedBacktestReport
    let comparisonSeries: [BacktestChartComparisonSeries]
    let score: Double

    var title: String {
        "\(buyRule.direction.localizedShortTitle) / \(sellRule.direction.localizedShortTitle)"
    }
}



struct BacktestIndexOption: Identifiable {
    let symbol: String
    let title: String
    let color: Color

    var id: String { symbol }
}



struct BacktestAssetOption: Identifiable, Sendable {
    let symbol: String
    let title: String
    let color: Color
    let requiresHistoricalFX: Bool
    let historicalFXSymbol: String?
    let category: String
    let iconName: String
    let currency: String
    let unit: String
    let logoURL: String?
    let logoSource: String?

    var id: String { symbol }

    init(
        symbol: String,
        title: String,
        color: Color,
        requiresHistoricalFX: Bool,
        historicalFXSymbol: String?,
        category: String = "other",
        iconName: String = "chart.line.uptrend.xyaxis",
        currency: String = "CNY",
        unit: String = "",
        logoURL: String? = nil,
        logoSource: String? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.color = color
        self.requiresHistoricalFX = requiresHistoricalFX
        self.historicalFXSymbol = historicalFXSymbol
        self.category = category
        self.iconName = iconName
        self.currency = currency
        self.unit = unit
        self.logoURL = logoURL
        self.logoSource = logoSource
    }

}



enum BacktestDefaults {
    /// Current product execution fee, expressed as a percentage: 2.5 bps = 0.025% per side.
    nonisolated static let advancedFeeRatePercent: Double = 0.025
    nonisolated static let advancedSlippageRatePercent: Double = 0.05
    static let cashWeight: Double = 50
    static let goldWeight: Double = 25
    static let dcaAssetSymbol = "gold_cny"
    static let dcaContributionAmount: Double = 1000
    static let dcaIntervalDays = 30
    static var indexOptions: [BacktestIndexOption] { [
        .init(symbol: "sp500", title: AppLocalization.string("标普500"), color: AssetTheme.goldSoft),
        .init(symbol: "nasdaq", title: AppLocalization.string("纳指"), color: AssetTheme.accentBlue),
        .init(symbol: "dowjones", title: AppLocalization.string("道指"), color: AssetTheme.accentOrange),
        .init(symbol: "hsi", title: AppLocalization.string("恒生"), color: AssetTheme.accentRed),
        .init(symbol: "csi300", title: AppLocalization.string("沪深300"), color: AssetTheme.textPrimary),
        .init(symbol: "shanghai_composite", title: AppLocalization.string("上证综指"), color: AssetTheme.textSecondary),
        .init(symbol: "shenzhen_component", title: AppLocalization.string("深成指"), color: AssetTheme.accentRed),
        .init(symbol: "chinext", title: AppLocalization.string("创业板"), color: AssetTheme.positive),
    ] }
    static let indexWeights: [String: Double] = {
        Dictionary(uniqueKeysWithValues: indexOptions.map { option in
            (option.symbol, option.symbol == "nasdaq" ? 25 : 0)
        })
    }()
    static var dcaAssetOptions: [BacktestAssetOption] { [
        .init(symbol: "gold_cny", title: AppLocalization.string("黄金"), color: AssetTheme.gold, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "sp500", title: AppLocalization.string("标普500"), color: AssetTheme.goldSoft, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "nasdaq", title: AppLocalization.string("纳指"), color: AssetTheme.accentBlue, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "dowjones", title: AppLocalization.string("道指"), color: AssetTheme.accentOrange, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "hsi", title: AppLocalization.string("恒生"), color: AssetTheme.accentRed, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "csi300", title: AppLocalization.string("沪深300"), color: AssetTheme.textPrimary, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "shanghai_composite", title: AppLocalization.string("上证综指"), color: AssetTheme.textSecondary, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "shenzhen_component", title: AppLocalization.string("深成指"), color: AssetTheme.accentRed, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "chinext", title: AppLocalization.string("创业板"), color: AssetTheme.positive, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "nikkei", title: AppLocalization.string("日经225"), color: AssetTheme.accentOrange, requiresHistoricalFX: false, historicalFXSymbol: nil),
    ] }
    static var internalStrategyAssetOptions: [BacktestAssetOption] { [
        .init(symbol: "usd_cash", title: AppLocalization.string("美元现金"), color: AssetTheme.textSecondary, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "oil_wti_cny", title: AppLocalization.string("WTI原油"), color: AssetTheme.accentOrange, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "qual", title: AppLocalization.string("QUAL美国质量因子"), color: AssetTheme.accentBlue, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny", category: "etf", iconName: "chart.line.uptrend.xyaxis", currency: "USD", unit: "share"),
        .init(symbol: "money511990_cny", title: AppLocalization.string("511990货币基金"), color: AssetTheme.textSecondary, requiresHistoricalFX: false, historicalFXSymbol: nil, category: "etf", iconName: "banknote", currency: "CNY", unit: "share"),
        .init(symbol: "spy_tr", title: AppLocalization.string("SPY标普500ETF"), color: AssetTheme.goldSoft, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny", category: "etf", iconName: "chart.line.uptrend.xyaxis", currency: "USD", unit: "share"),
        .init(symbol: "oneq_tr", title: AppLocalization.string("ONEQ纳斯达克ETF"), color: AssetTheme.accentBlue, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny", category: "etf", iconName: "chart.line.uptrend.xyaxis", currency: "USD", unit: "share"),
        .init(symbol: "etf510210_cny", title: AppLocalization.string("510210上证综指ETF"), color: AssetTheme.accentOrange, requiresHistoricalFX: false, historicalFXSymbol: nil, category: "etf", iconName: "chart.line.uptrend.xyaxis", currency: "CNY", unit: "share"),
        .init(symbol: "etf510300_cny", title: AppLocalization.string("510300沪深300ETF"), color: AssetTheme.textPrimary, requiresHistoricalFX: false, historicalFXSymbol: nil, category: "etf", iconName: "chart.line.uptrend.xyaxis", currency: "CNY", unit: "share"),
    ] }
    static var strategyAssetOptions: [BacktestAssetOption] { dcaAssetOptions + internalStrategyAssetOptions }

    static func strategyColor(for symbol: String) -> Color {
        strategyAssetOptions.first(where: { $0.symbol == symbol })?.color ?? AssetTheme.gold
    }
}



enum StrategyRebalanceDefaults {
    static let defaultTemplateID = "core-gold-satellite-equity-curve-state-gate-momentum"
    static let recommendedTemplateID = "gold-nasdaq-dual-trend-barbell"

    static var eligibleTemplates: [AdvancedBacktestStrategyTemplate] {
        AdvancedBacktestStrategyTemplate.productCatalog
    }

    static func migratedTemplateID(_ id: String) -> String {
        switch id {
        case "risk-contribution-cash-confidence-router":
            return recommendedTemplateID
        case "online-strategy-allocator",
             "consensus-scale-defense",
             "convex-crash-hedge-composite",
             "risk-contribution-reallocation",
             "risk-contribution-regime-router",
             "risk-contribution-recovery-router":
            return defaultTemplateID
        default:
            return id
        }
    }

    static func template(for id: String) -> AdvancedBacktestStrategyTemplate? {
        let migratedID = migratedTemplateID(id)
        return eligibleTemplates.first { $0.id == migratedID }
            ?? eligibleTemplates.first { $0.id == defaultTemplateID }
            ?? eligibleTemplates.first
    }

    static func pickerTitle(for template: AdvancedBacktestStrategyTemplate) -> String {
        guard BacktestProductStrategyCatalog.isCuratedTemplateID(template.id) else {
            return template.title
        }
        var badges = [AppLocalization.string("精选")]
        if template.id == recommendedTemplateID {
            badges.append(AppLocalization.string("推荐"))
        }
        return "\(template.title) · \(badges.joined(separator: " · "))"
    }

    static func assetOptions(for template: AdvancedBacktestStrategyTemplate) -> [BacktestAssetOption] {
        var selectedSymbols = Set(template.selectedAssetSymbols ?? BacktestDefaults.dcaAssetOptions.map(\.symbol))
        selectedSymbols.formUnion(template.mode.requiredSignalAssetSymbols)
        let options = BacktestDefaults.strategyAssetOptions.filter { selectedSymbols.contains($0.symbol) }
        return options.isEmpty ? BacktestDefaults.dcaAssetOptions : options
    }

    static func historySymbols(for template: AdvancedBacktestStrategyTemplate) -> Set<String> {
        historySymbols(for: assetOptions(for: template))
    }

    static func historySymbols(for assetOptions: [BacktestAssetOption]) -> Set<String> {
        Set(assetOptions.flatMap { option -> [String] in
            var symbols = [option.symbol]
            if let fxSymbol = option.historicalFXSymbol {
                symbols.append(fxSymbol)
            }
            if option.symbol == "usd_cash" {
                symbols.append("usd_per_cny")
            }
            return symbols
        })
    }
}



enum StrategyNotificationDefaults {
    static let defaultHour = 9
}

@MainActor


enum StrategyNotificationContentBuilder {
    static func body(advice: StrategyRebalanceAdvice, actions: [StrategyRebalanceAction]) -> String {
        if advice.isCashDefense || actions.isEmpty {
            return AppLocalization.format(
                "目标现金防守；信号截至 %@，建议下一交易日执行。",
                advice.asOfDate.recordDateString
            )
        }

        let actionable = actions.filter { action in
            switch action.kind {
            case .buy, .sell:
                return true
            case .hold, .targetOnly:
                return false
            }
        }

        let source = actionable.isEmpty ? Array(actions.prefix(2)) : Array(actionable.prefix(2))
        let summary = source.map(actionSummary).joined(separator: "；")
        let suffix: String
        if actionable.isEmpty {
            suffix = AppLocalization.string("偏离不大，今日可保持。")
        } else if actions.count > source.count {
            suffix = AppLocalization.format("另有%d项。", actions.count - source.count)
        } else {
            suffix = ""
        }

        if suffix.isEmpty {
            return AppLocalization.format("%@。信号截至 %@，建议下一交易日执行。", summary, advice.asOfDate.recordDateString)
        }
        return AppLocalization.format("%@；%@ 信号截至 %@，建议下一交易日执行。", summary, suffix, advice.asOfDate.recordDateString)
    }

    private static func actionSummary(_ action: StrategyRebalanceAction) -> String {
        switch action.kind {
        case .buy:
            return AppLocalization.format("%@买入%@", action.title, abs(action.deltaAmount ?? 0).currencyString())
        case .sell:
            return AppLocalization.format("%@卖出%@", action.title, abs(action.deltaAmount ?? 0).currencyString())
        case .hold:
            return AppLocalization.format("%@保持%@", action.title, action.targetWeight.percentString(maxFractionDigits: 1))
        case .targetOnly:
            return AppLocalization.format("%@目标%@", action.title, action.targetWeight.percentString(maxFractionDigits: 1))
        }
    }
}



extension BacktestAssetOption {
    nonisolated var instrument: BacktestInstrument {
        BacktestInstrument(symbol: symbol, title: title,
            requiresHistoricalFX: requiresHistoricalFX, historicalFXSymbol: historicalFXSymbol,
            category: category, iconName: iconName, currency: currency, unit: unit,
            logoURL: logoURL, logoSource: logoSource)
    }
}


extension AdvancedBacktestTradeAction {
    var accent: Color {
        switch self {
        case .buy:
            return AssetTheme.accentRed
        case .sell:
            return AssetTheme.accentBlue
        }
    }
}


extension MarketRiskSignalLevel {
    var accent: Color {
        switch self {
        case .calm:
            return AssetTheme.positive
        case .watch:
            return AssetTheme.gold
        case .stress:
            return AssetTheme.accentOrange
        case .shock:
            return AssetTheme.negative
        }
    }
}

extension StrategyRebalanceActionKind {
    var accent: Color {
        switch self {
        case .buy:
            return AssetTheme.positive
        case .sell:
            return AssetTheme.negative
        case .hold, .targetOnly:
            return AssetTheme.textSecondary
        }
    }
}
extension BacktestRecordKind {
    var chartValueStyle: BacktestChartValueStyle {
        switch self {
        case .allocation:
            return .multiple
        case .dca, .advanced:
            return .currency(code: "CNY")
        }
    }
}

@MainActor
enum StrategyRebalanceActionBuilder {
    static func actions(for advice: StrategyRebalanceAdvice, snapshot: AssetSnapshot?,
                        selectedAssetOptions: [BacktestAssetOption], allAssetOptions: [BacktestAssetOption]) -> [StrategyRebalanceAction] {
        let holdings = snapshot.map { snapshot in
            PortfolioHoldingsSnapshot(entries: snapshot.entries.map { entry in
                let item = entry.item
                return PortfolioHolding(name: item?.name ?? "", hasRecordedItem: item != nil, note: item?.note ?? "",
                    group: PortfolioHoldingGroup(rawValue: (item?.category?.group ?? .financial).rawValue) ?? .financial,
                    amount: entry.resolvedAmount, isAutoPricedGold: item?.resolvedAutoPricedAssetKind == .gold,
                    marketAssetSymbol: item?.marketAssetSymbol, quantStrategyProxySymbol: item?.quantStrategyProxySymbol)
            })
        }
        return BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            AssetTimeMachineBacktestCore.StrategyRebalanceActionBuilder.actions(for: advice, snapshot: holdings,
                selectedAssetOptions: selectedAssetOptions.map(\.instrument), allAssetOptions: allAssetOptions.map(\.instrument))
        }
    }
}

@MainActor
extension BacktestRecord {
    var storedBacktestValue: BacktestStoredRecord {
        BacktestStoredRecord(kindRawValue: kindRawValue, title: title, subtitle: subtitle,
            configSummary: configSummary, createdAt: createdAt, startDate: startDate, endDate: endDate,
            totalReturn: totalReturn, annualizedReturn: annualizedReturn, maxDrawdown: maxDrawdown,
            annualizedVolatility: annualizedVolatility, sharpeRatio: sharpeRatio,
            finalValue: finalValue, totalInvested: totalInvested, profitLoss: profitLoss,
            tradeCount: tradeCount, pointsJSON: pointsJSON, configJSON: configJSON)
    }
}

/// App presentation for the shared immutable catalog. Rules and ordering remain in Core.
struct AdvancedBacktestStrategyTemplate: Identifiable, Sendable {
    let core: AssetTimeMachineBacktestCore.AdvancedBacktestStrategyTemplate
    var id: String { core.id }
    var title: String { AppLocalization.string(core.titleLocalizationKey) }
    var category: String { AppLocalization.string(core.categoryLocalizationKey) }
    var subtitle: String {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) { core.subtitle }
    }
    var mode: AdvancedBacktestStrategyMode { core.mode }
    var selectedAssetSymbols: [String]? { core.selectedAssetSymbols }
    var categoryLocalizationKey: String { core.categoryLocalizationKey }
    var titleLocalizationKey: String { core.titleLocalizationKey }
    var annualizedReturn: Double { core.annualizedReturn }
    var maxDrawdown: Double { core.maxDrawdown }
    var sharpeRatio: Double { core.sharpeRatio }
    var buyRule: AdvancedBacktestRule { core.buyRule }
    var sellRule: AdvancedBacktestRule { core.sellRule }
    var tradeAmountRatio: Double { core.tradeAmountRatio }
    var maxPositionRatio: Double { core.maxPositionRatio }
    var cooldownDays: Int { core.cooldownDays }
    var stopLossRatio: Double { core.stopLossRatio }
    var takeProfitRatio: Double { core.takeProfitRatio }
    static let all = AssetTimeMachineBacktestCore.AdvancedBacktestStrategyTemplate.all.map { Self(core: $0) }
    static let productCatalog = AssetTimeMachineBacktestCore.AdvancedBacktestStrategyTemplate.productCatalog.map { Self(core: $0) }
}

extension AdvancedBacktestStrategyMode {
    var localizedTitle: String { BacktestText.$context.withValue(AppLocalization.backtestTextContext()) { title } }
    var localizedDetail: String { BacktestText.$context.withValue(AppLocalization.backtestTextContext()) { detail } }
}

extension AdvancedBacktestSignalDirection {
    var localizedTitle: String { BacktestText.$context.withValue(AppLocalization.backtestTextContext()) { title } }
    var localizedShortTitle: String { BacktestText.$context.withValue(AppLocalization.backtestTextContext()) { shortTitle } }
}

extension AdvancedBacktestTradeAction {
    var localizedTitle: String { BacktestText.$context.withValue(AppLocalization.backtestTextContext()) { title } }
}

extension StrategyRebalanceActionKind {
    var localizedTitle: String { BacktestText.$context.withValue(AppLocalization.backtestTextContext()) { title } }
}

extension BacktestRecordKind {
    var localizedTitle: String { BacktestText.$context.withValue(AppLocalization.backtestTextContext()) { title } }
}
