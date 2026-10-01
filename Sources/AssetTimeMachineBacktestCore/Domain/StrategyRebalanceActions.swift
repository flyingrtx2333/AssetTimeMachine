import Foundation

public enum StrategyRebalanceActionKind {
    case buy
    case sell
    case hold
    case targetOnly

    public var title: String {
        switch self {
        case .buy:
            return BacktestText.string("买入")
        case .sell:
            return BacktestText.string("卖出")
        case .hold:
            return BacktestText.string("保持")
        case .targetOnly:
            return BacktestText.string("目标")
        }
    }


}


public struct StrategyHoldingMatch {
    public let amount: Double
    public let itemNames: [String]

    public var isMatched: Bool { !itemNames.isEmpty }
    public init(
        amount: Double,
        itemNames: [String]
    ) {
        self.amount = amount
        self.itemNames = itemNames
    }
}


public struct StrategyRebalanceAction: Identifiable {
    public let symbol: String
    public let title: String
    public let currentAmount: Double?
    public let currentWeight: Double?
    public let targetWeight: Double
    public let targetAmount: Double?
    public let deltaAmount: Double?
    public let investmentBase: Double?
    public let matchedItemNames: [String]
    public let kind: StrategyRebalanceActionKind
    public let momentum: Double?
    public let annualizedVolatility: Double?

    public var id: String { symbol }

    public var isMatched: Bool { !matchedItemNames.isEmpty }

    public func detailText(lookbackSessions: Int) -> String {
        let currentText = currentWeight.map { BacktestText.format("当前 %@", $0.backtestPercentString(maxFractionDigits: 1)) }
            ?? (isMatched ? BacktestText.string("当前 --") : BacktestText.string("未记录"))
        let targetText = BacktestText.format("目标 %@", targetWeight.backtestPercentString(maxFractionDigits: 1))
        let signalText: String
        if let momentum {
            signalText = BacktestText.format(" · %d日动量 %@", lookbackSessions, momentum.backtestPercentString(maxFractionDigits: 1))
        } else {
            signalText = ""
        }
        return "\(currentText) · \(targetText)\(signalText)"
    }

    public var amountText: String {
        switch kind {
        case .buy, .sell:
            return (abs(deltaAmount ?? 0)).backtestCurrencyString()
        case .hold:
            return BacktestText.string("偏离小")
        case .targetOnly:
            return targetWeight.backtestPercentString(maxFractionDigits: 1)
        }
    }
    public init(
        symbol: String,
        title: String,
        currentAmount: Double?,
        currentWeight: Double?,
        targetWeight: Double,
        targetAmount: Double?,
        deltaAmount: Double?,
        investmentBase: Double?,
        matchedItemNames: [String],
        kind: StrategyRebalanceActionKind,
        momentum: Double?,
        annualizedVolatility: Double?
    ) {
        self.symbol = symbol
        self.title = title
        self.currentAmount = currentAmount
        self.currentWeight = currentWeight
        self.targetWeight = targetWeight
        self.targetAmount = targetAmount
        self.deltaAmount = deltaAmount
        self.investmentBase = investmentBase
        self.matchedItemNames = matchedItemNames
        self.kind = kind
        self.momentum = momentum
        self.annualizedVolatility = annualizedVolatility
    }
}


public enum StrategyRebalanceActionBuilder {
    public static func actions(
        for advice: StrategyRebalanceAdvice,
        snapshot: PortfolioHoldingsSnapshot?,
        selectedAssetOptions: [BacktestInstrument],
        allAssetOptions: [BacktestInstrument]
    ) -> [StrategyRebalanceAction] {
        let targetAllocationsBySymbol = Dictionary(uniqueKeysWithValues: advice.allocations.map { ($0.symbol, $0) })
        let orderedSymbols = orderedStrategySymbols(for: advice, selectedAssetOptions: selectedAssetOptions)

        guard let snapshot else {
            return advice.allocations.map { allocation in
                targetOnlyAction(allocation: allocation)
            }
        }

        let matchesBySymbol = Dictionary(uniqueKeysWithValues: orderedSymbols.map { symbol in
            (symbol, strategyHoldingMatch(for: symbol, in: snapshot))
        })
        let investmentBase = strategyInvestmentBase(in: snapshot, matches: Array(matchesBySymbol.values))
        guard investmentBase > 0 else {
            return advice.allocations.map { allocation in
                targetOnlyAction(allocation: allocation)
            }
        }

        let minimumTradeAmount = max(investmentBase * 0.01, 500)
        return orderedSymbols.compactMap { symbol -> StrategyRebalanceAction? in
            let allocation = targetAllocationsBySymbol[symbol]
            let targetWeight = allocation?.targetWeight ?? 0
            let match = matchesBySymbol[symbol] ?? StrategyHoldingMatch(amount: 0, itemNames: [])
            let currentAmount = match.amount
            let targetAmount = investmentBase * targetWeight
            let deltaAmount = targetAmount - currentAmount

            guard targetWeight > 0.0001 || currentAmount > minimumTradeAmount else { return nil }

            let kind: StrategyRebalanceActionKind
            if deltaAmount > minimumTradeAmount {
                kind = .buy
            } else if deltaAmount < -minimumTradeAmount {
                kind = .sell
            } else {
                kind = .hold
            }

            return StrategyRebalanceAction(
                symbol: symbol,
                title: allocation?.title ?? strategyTitle(for: symbol, allAssetOptions: allAssetOptions),
                currentAmount: currentAmount,
                currentWeight: currentAmount / investmentBase,
                targetWeight: targetWeight,
                targetAmount: targetAmount,
                deltaAmount: deltaAmount,
                investmentBase: investmentBase,
                matchedItemNames: match.itemNames,
                kind: kind,
                momentum: allocation?.momentum,
                annualizedVolatility: allocation?.annualizedVolatility
            )
        }
        .sorted { lhs, rhs in
            if lhs.kind == .hold && rhs.kind != .hold { return false }
            if lhs.kind != .hold && rhs.kind == .hold { return true }
            if lhs.targetWeight != rhs.targetWeight { return lhs.targetWeight > rhs.targetWeight }
            return abs(lhs.deltaAmount ?? 0) > abs(rhs.deltaAmount ?? 0)
        }
    }

    private static func targetOnlyAction(allocation: StrategyRebalanceAllocation) -> StrategyRebalanceAction {
        StrategyRebalanceAction(
            symbol: allocation.symbol,
            title: allocation.title,
            currentAmount: nil,
            currentWeight: nil,
            targetWeight: allocation.targetWeight,
            targetAmount: nil,
            deltaAmount: nil,
            investmentBase: nil,
            matchedItemNames: [],
            kind: .targetOnly,
            momentum: allocation.momentum,
            annualizedVolatility: allocation.annualizedVolatility
        )
    }

    private static func orderedStrategySymbols(
        for advice: StrategyRebalanceAdvice,
        selectedAssetOptions: [BacktestInstrument]
    ) -> [String] {
        var seen = Set<String>()
        var symbols: [String] = []
        for symbol in selectedAssetOptions.map(\.symbol) + advice.allocations.map(\.symbol) {
            guard !seen.contains(symbol) else { continue }
            seen.insert(symbol)
            symbols.append(symbol)
        }
        return symbols
    }

    private static func strategyInvestmentBase(in snapshot: PortfolioHoldingsSnapshot, matches: [StrategyHoldingMatch]) -> Double {
        let financialAmount = snapshot.entries.reduce(0.0) { partial, entry in
            guard entry.amount > 0,
                  entry.group == .financial else { return partial }
            return partial + entry.amount
        }
        let matchedAmount = matches.reduce(0.0) { $0 + $1.amount }
        return max(financialAmount, matchedAmount)
    }

    private static func strategyHoldingMatch(for symbol: String, in snapshot: PortfolioHoldingsSnapshot) -> StrategyHoldingMatch {
        let matchedEntries = snapshot.entries.filter { entry in
            guard entry.amount > 0,
                  entry.group != .liability else { return false }
            return entry.hasRecordedItem && itemMatchesStrategySymbol(entry, symbol: symbol)
        }
        let amount = matchedEntries.reduce(0.0) { $0 + $1.amount }
        let itemNames = Array(Set(matchedEntries.map { $0.name })).sorted()
        return StrategyHoldingMatch(amount: amount, itemNames: itemNames)
    }

    private static func itemMatchesStrategySymbol(_ item: PortfolioHolding, symbol: String) -> Bool {
        if let proxySymbol = item.quantStrategyProxySymbol {
            return BacktestAssetSymbol.normalized(proxySymbol) == BacktestAssetSymbol.normalized(symbol)
        }

        if let marketSymbol = item.marketAssetSymbol,
           BacktestAssetSymbol.normalized(marketSymbol) == BacktestAssetSymbol.normalized(symbol) {
            return true
        }
        if symbol == "gold_cny", item.isAutoPricedGold {
            return true
        }

        let searchText = "\(item.name) \(item.note)"
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        return strategyKeywords(for: symbol).contains { keyword in
            searchText.contains(keyword)
        }
    }

    private static func strategyKeywords(for symbol: String) -> [String] {
        switch symbol {
        case "gold_cny":
            return ["黄金", "gold", "au9999", "au99", "金"]
        case "nasdaq":
            return ["纳指", "纳斯达克", "nasdaq", "qqq", "ndx"]
        case "sp500":
            return ["标普500", "标普 500", "s&p500", "s&p 500", "sp500", "spy", "voo"]
        case "dowjones":
            return ["道指", "道琼斯", "dowjones", "dow jones", "djia", "dia"]
        case "hsi":
            return ["恒生", "恒生指数", "hang seng", "hsi", "2800"]
        case "nikkei":
            return ["日经", "日经225", "nikkei", "nikkei225", "1321"]
        case "csi300":
            return ["沪深300", "沪深 300", "csi300", "hs300"]
        case "shanghai_composite":
            return ["上证综指", "上证指数", "上证", "shanghai composite", "shanghai_composite", "000001"]
        case "shenzhen_component":
            return ["深证成指", "深成指", "shenzhen component", "shenzhen_component", "399001"]
        case "chinext":
            return ["创业板", "创业板指", "chinext", "399006"]
        case "usd_cash":
            return ["美元现金", "美元", "usd", "us dollar", "dollar"]
        case "qual":
            return ["qual", "美国质量", "质量因子", "usa quality", "msci usa quality"]
        default:
            return [symbol.lowercased()]
        }
    }

    private static func strategyTitle(for symbol: String, allAssetOptions: [BacktestInstrument]) -> String {
        allAssetOptions.first(where: { $0.symbol == symbol })?.title ?? symbol
    }
}

