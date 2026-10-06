import Foundation

nonisolated public struct MarketDataFrame {
    public let dates: [Date]
    public let pricesBySymbol: [String: [Double]]
    /// True only when the symbol has a real observation on the frame date.
    /// Forward-filled prices remain valid for valuation but not for execution.
    public let observedBySymbol: [String: [Bool]]
    public let ohlcBySymbol: [String: [(date: Date, open: Double, high: Double, low: Double, close: Double)]]
    public let tradableSymbols: [String]
    public let optionBySymbol: [String: BacktestInstrument]
    public let simulationRange: ClosedRange<Int>
    public init(
        dates: [Date],
        pricesBySymbol: [String: [Double]],
        observedBySymbol: [String: [Bool]],
        ohlcBySymbol: [String: [(date: Date, open: Double, high: Double, low: Double, close: Double)]],
        tradableSymbols: [String],
        optionBySymbol: [String: BacktestInstrument],
        simulationRange: ClosedRange<Int>
    ) {
        self.dates = dates
        self.pricesBySymbol = pricesBySymbol
        self.observedBySymbol = observedBySymbol
        self.ohlcBySymbol = ohlcBySymbol
        self.tradableSymbols = tradableSymbols
        self.optionBySymbol = optionBySymbol
        self.simulationRange = simulationRange
    }
}


/// Versioned, explicit allocation experiment. Defaults preserve historical execution.
nonisolated public enum BacktestBuyBudgetPolicy: String, Codable, Sendable {
    case symbolOrder = "symbol-order-v1"
    case proportionalGap = "proportional-gap-v1"
}

nonisolated public struct BacktestExecutionConfig {
    public let initialCash: Double
    public let feeRate: Double
    public let slippageRate: Double
    public let rebalanceBand: Double
    public let tradeToBandBoundary: Bool
    public let financingAnnualRate: Double
    public let allowsFinancedExposure: Bool
    public let buyReason: String

    public init(
        initialCash: Double,
        feeRate: Double,
        slippageRate: Double,
        rebalanceBand: Double,
        tradeToBandBoundary: Bool = false,
        financingAnnualRate: Double,
        allowsFinancedExposure: Bool,
        buyReason: String
    ) {
        self.initialCash = initialCash
        self.feeRate = feeRate
        self.slippageRate = slippageRate
        self.rebalanceBand = rebalanceBand
        self.tradeToBandBoundary = tradeToBandBoundary
        self.financingAnnualRate = financingAnnualRate
        self.allowsFinancedExposure = allowsFinancedExposure
        self.buyReason = buyReason
    }
}


nonisolated public struct StrategyTargetContext {
    public let index: Int
    public let signalIndex: Int
    public let date: Date
    public let signalDate: Date
    /// Portfolio value known at the signal close. Target providers must not use
    /// execution-day prices when constructing a strict T-1 target.
    public let signalPortfolioValue: Double
    public let points: [BacktestSeriesPoint]
    public let portfolioValuesByIndex: [Double]
    public let refreshOverlay: Bool
    public init(
        index: Int,
        signalIndex: Int,
        date: Date,
        signalDate: Date,
        signalPortfolioValue: Double,
        points: [BacktestSeriesPoint],
        portfolioValuesByIndex: [Double],
        refreshOverlay: Bool
    ) {
        self.index = index
        self.signalIndex = signalIndex
        self.date = date
        self.signalDate = signalDate
        self.signalPortfolioValue = signalPortfolioValue
        self.points = points
        self.portfolioValuesByIndex = portfolioValuesByIndex
        self.refreshOverlay = refreshOverlay
    }
}


nonisolated public struct AlignedRotationPriceSeries {
    public let dates: [Date]
    public let pricesBySymbol: [String: [Double]]
    public let observedBySymbol: [String: [Bool]]
    public init(
        dates: [Date],
        pricesBySymbol: [String: [Double]],
        observedBySymbol: [String: [Bool]]
    ) {
        self.dates = dates
        self.pricesBySymbol = pricesBySymbol
        self.observedBySymbol = observedBySymbol
    }
}


nonisolated public struct StrategyTargetProvider {
    public let targetWeights: (StrategyTargetContext) -> [String: Double]
    public init(
        targetWeights: @escaping (StrategyTargetContext) -> [String: Double]
    ) {
        self.targetWeights = targetWeights
    }
}


nonisolated public struct ResearchTargetStrategyConfig {
    public let symbol: String
    public let title: String
    public let warmupSessions: Int
    public let rebalanceSessions: Int
    public let rebalanceBand: Double
    public let tradeToBandBoundary: Bool
    public let zeroFillBeforeFirstSymbols: Set<String>
    /// Prepared series that may drive a frozen schedule but can never be held or traded.
    public let signalOnlySymbols: Set<String>
    public let maxGrossExposure: Double
    public let allowsFinancedExposure: Bool
    public let financingAnnualRate: Double
    public let buyReason: String

    public init(
        symbol: String,
        title: String,
        warmupSessions: Int,
        rebalanceSessions: Int,
        rebalanceBand: Double = 0,
        tradeToBandBoundary: Bool = false,
        zeroFillBeforeFirstSymbols: Set<String> = [],
        signalOnlySymbols: Set<String> = [],
        maxGrossExposure: Double = 1,
        allowsFinancedExposure: Bool = false,
        financingAnnualRate: Double = 0,
        buyReason: String = "研究策略调仓"
    ) {
        self.symbol = symbol
        self.title = title
        self.warmupSessions = warmupSessions
        self.rebalanceSessions = rebalanceSessions
        self.rebalanceBand = rebalanceBand
        self.tradeToBandBoundary = tradeToBandBoundary
        self.zeroFillBeforeFirstSymbols = zeroFillBeforeFirstSymbols
        self.signalOnlySymbols = signalOnlySymbols
        self.maxGrossExposure = maxGrossExposure
        self.allowsFinancedExposure = allowsFinancedExposure
        self.financingAnnualRate = financingAnnualRate
        self.buyReason = buyReason
    }
}


nonisolated public struct ResearchTargetDataContext {
    public let dates: [Date]
    public let pricesBySymbol: [String: [Double]]
    public let observedBySymbol: [String: [Bool]]
    public let ohlcBySymbol: [String: [(date: Date, open: Double, high: Double, low: Double, close: Double)]]
    public let tradableSymbols: [String]
    public init(
        dates: [Date],
        pricesBySymbol: [String: [Double]],
        observedBySymbol: [String: [Bool]],
        ohlcBySymbol: [String: [(date: Date, open: Double, high: Double, low: Double, close: Double)]],
        tradableSymbols: [String]
    ) {
        self.dates = dates
        self.pricesBySymbol = pricesBySymbol
        self.observedBySymbol = observedBySymbol
        self.ohlcBySymbol = ohlcBySymbol
        self.tradableSymbols = tradableSymbols
    }
}


nonisolated public struct BacktestDailyState: Codable, Sendable {
    public let date: Date
    public let targetWeights: [String: Double]
    public let cash: Double
    public let holdingsBySymbol: [String: Double]
    public let portfolioValue: Double
    public init(
        date: Date,
        targetWeights: [String: Double],
        cash: Double,
        holdingsBySymbol: [String: Double],
        portfolioValue: Double
    ) {
        self.date = date
        self.targetWeights = targetWeights
        self.cash = cash
        self.holdingsBySymbol = holdingsBySymbol
        self.portfolioValue = portfolioValue
    }
}


nonisolated public struct ResearchTargetStrategyRun {
    public let report: AdvancedBacktestReport
    public let dailyStates: [BacktestDailyState]
    public init(
        report: AdvancedBacktestReport,
        dailyStates: [BacktestDailyState]
    ) {
        self.report = report
        self.dailyStates = dailyStates
    }
}


nonisolated public struct AdvancedRotationStrategyRun {
    public let report: AdvancedBacktestReport
    public let dailyStates: [BacktestDailyState]
    public let latestSignalReason: String?

    public init(report: AdvancedBacktestReport, dailyStates: [BacktestDailyState], latestSignalReason: String? = nil) {
        self.report = report
        self.dailyStates = dailyStates
        self.latestSignalReason = latestSignalReason
    }
}


nonisolated public struct BacktestRebalanceDecision {
    public let shouldRebalance: Bool
    public let refreshOverlay: Bool
    public init(
        shouldRebalance: Bool,
        refreshOverlay: Bool
    ) {
        self.shouldRebalance = shouldRebalance
        self.refreshOverlay = refreshOverlay
    }
}


nonisolated public struct BacktestDailySimulationResult {
    public let points: [BacktestSeriesPoint]
    public let benchmarkPoints: [BacktestSeriesPoint]
    public let trades: [AdvancedBacktestTrade]
    public let finalCash: Double
    public let finalUnits: Double
    public let exposureRatio: Double
    public let cashYieldSummary: CashYieldSummary
    public let portfolioValuesByIndex: [Double]
    public let dailyStates: [BacktestDailyState]
    public init(
        points: [BacktestSeriesPoint],
        benchmarkPoints: [BacktestSeriesPoint],
        trades: [AdvancedBacktestTrade],
        finalCash: Double,
        finalUnits: Double,
        exposureRatio: Double,
        cashYieldSummary: CashYieldSummary,
        portfolioValuesByIndex: [Double],
        dailyStates: [BacktestDailyState]
    ) {
        self.points = points
        self.benchmarkPoints = benchmarkPoints
        self.trades = trades
        self.finalCash = finalCash
        self.finalUnits = finalUnits
        self.exposureRatio = exposureRatio
        self.cashYieldSummary = cashYieldSummary
        self.portfolioValuesByIndex = portfolioValuesByIndex
        self.dailyStates = dailyStates
    }
}

