import Foundation

nonisolated public enum BacktestCoreEngine {
    public static let defaultEngineVersion = BacktestExecutionVersion.defaultEngineVersion

    public static func filteredHistorySeries(_ series: PublicHistorySeries?, within bounds: ClosedRange<Date>? = nil) -> PublicHistorySeries? {
        MarketInputPreparation.filteredHistorySeries(series, within: bounds)
    }

    public static func advancedAssetInput(
        for option: BacktestInstrument,
        historyProvider: (String) -> PublicHistorySeries?
    ) -> (assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?) {
        MarketInputPreparation.advancedAssetInput(for: option, historyProvider: historyProvider)
    }

    public static func filteredAdvancedAssetInputs(
        _ assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        within bounds: ClosedRange<Date>?
    ) -> [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)] {
        MarketInputPreparation.filteredAdvancedAssetInputs(assetInputs, within: bounds)
    }

    public static func exposurePoints(from dailyStates: [BacktestDailyState]) -> [BacktestExposurePoint] {
        BacktestReportBuilder.exposurePoints(from: dailyStates)
    }

    public static func assetExposureSeries(
        from dailyStates: [BacktestDailyState],
        symbolOrder: [String],
        titlesBySymbol: [String: String]
    ) -> [BacktestAssetExposureSeries] {
        BacktestReportBuilder.assetExposureSeries(from: dailyStates, symbolOrder: symbolOrder, titlesBySymbol: titlesBySymbol)
    }

    public static func statefulAdvancedReport(
        from report: AdvancedBacktestReport,
        dailyStates: [BacktestDailyState],
        within bounds: ClosedRange<Date>,
        rebasedTo initialPortfolioValue: Double
    ) -> AdvancedBacktestReport? {
        BacktestReportBuilder.statefulAdvancedReport(from: report, dailyStates: dailyStates, within: bounds, rebasedTo: initialPortfolioValue)
    }

    public static func run(
        cashWeight: Double,
        goldWeight: Double,
        goldSeries: PublicHistorySeries?,
        indexWeights: [String: Double],
        indexSeriesBySymbol: [String: PublicHistorySeries]
    ) -> BacktestReport? {
        AllocationBacktest.run(cashWeight: cashWeight, goldWeight: goldWeight, goldSeries: goldSeries, indexWeights: indexWeights, indexSeriesBySymbol: indexSeriesBySymbol)
    }

    public static func runDCA(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestInstrument,
        fxSeries: PublicHistorySeries?,
        contributionAmount: Double,
        intervalDays: Int
    ) -> DCABacktestReport? {
        DCABacktest.runDCA(assetSeries: assetSeries, assetOption: assetOption, fxSeries: fxSeries, contributionAmount: contributionAmount, intervalDays: intervalDays)
    }

    public static func runAdvancedStrategy(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestInstrument,
        fxSeries: PublicHistorySeries?,
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        RuleBasedStrategy.runAdvancedStrategy(assetSeries: assetSeries, assetOption: assetOption, fxSeries: fxSeries, initialCash: initialCash, tradeAmount: tradeAmount, buyRule: buyRule, sellRule: sellRule, settings: settings)
    }

    public static func runAdvancedStrategies(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        RuleBasedStrategy.runAdvancedStrategies(assetInputs: assetInputs, initialCash: initialCash, tradeAmount: tradeAmount, buyRule: buyRule, sellRule: sellRule, settings: settings)
    }

    public static func runAdvancedMomentumRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        RotationStrategy.runAdvancedMomentumRotation(assetInputs: assetInputs, initialCash: initialCash, settings: settings)
    }

    public static func runAdvancedLowDrawdownRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        RotationStrategy.runAdvancedLowDrawdownRotation(assetInputs: assetInputs, initialCash: initialCash, settings: settings)
    }

    public static func runGoldNasdaqDualTrendBarbell(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedBacktestReport? {
        GoldNasdaqBarbellStrategy.runGoldNasdaqDualTrendBarbell(assetInputs: assetInputs, initialCash: initialCash, settings: settings, dateBounds: dateBounds)
    }

    public static func runAdvancedRotationStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        mode: AdvancedBacktestStrategyMode,
        nfciAsOf: BacktestNFCIAsOfData? = nil,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedBacktestReport? {
        runAdvancedRotationStrategyWithTrace(assetInputs: assetInputs, initialCash: initialCash,
            settings: settings, mode: mode, nfciAsOf: nfciAsOf, dateBounds: dateBounds)?.report
    }

    public static func runAdvancedRotationStrategyWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        mode: AdvancedBacktestStrategyMode,
        nfciAsOf: BacktestNFCIAsOfData? = nil,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedRotationStrategyRun? {
        StrategyRuntimeRegistry.run(mode: mode, input: .init(assetInputs: assetInputs,
            initialCash: initialCash, settings: settings, nfciAsOf: nfciAsOf, dateBounds: dateBounds))
    }

    public static func researchMarketDataFrame(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        config: ResearchTargetStrategyConfig,
        dateBounds: ClosedRange<Date>? = nil
    ) -> MarketDataFrame? {
        TargetProviderBacktest.researchMarketDataFrame(assetInputs: assetInputs, config: config, dateBounds: dateBounds)
    }

    public static func runResearchTargetProviderStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        config: ResearchTargetStrategyConfig,
        dateBounds: ClosedRange<Date>? = nil,
        rebalanceDecision: ((Int, Int, ResearchTargetDataContext) -> BacktestRebalanceDecision)? = nil,
        contextualRebalanceDecision: ((StrategyTargetContext, ResearchTargetDataContext) -> BacktestRebalanceDecision)? = nil,
        frozenSchedule: ((MarketDataFrame) -> FrozenTargetSchedule?)? = nil,
        targetWeights: @escaping (StrategyTargetContext, ResearchTargetDataContext) -> [String: Double]
    ) -> AdvancedBacktestReport? {
        TargetProviderBacktest.runResearchTargetProviderStrategy(assetInputs: assetInputs, initialCash: initialCash, settings: settings, config: config, dateBounds: dateBounds, rebalanceDecision: rebalanceDecision, contextualRebalanceDecision: contextualRebalanceDecision, frozenSchedule: frozenSchedule, targetWeights: targetWeights)
    }

    public static func runResearchTargetProviderStrategyWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        config: ResearchTargetStrategyConfig,
        dateBounds: ClosedRange<Date>? = nil,
        rebalanceDecision: ((Int, Int, ResearchTargetDataContext) -> BacktestRebalanceDecision)? = nil,
        contextualRebalanceDecision: ((StrategyTargetContext, ResearchTargetDataContext) -> BacktestRebalanceDecision)? = nil,
        frozenSchedule: ((MarketDataFrame) -> FrozenTargetSchedule?)? = nil,
        targetWeights: @escaping (StrategyTargetContext, ResearchTargetDataContext) -> [String: Double]
    ) -> ResearchTargetStrategyRun? {
        TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(assetInputs: assetInputs, initialCash: initialCash, settings: settings, config: config, dateBounds: dateBounds, rebalanceDecision: rebalanceDecision, contextualRebalanceDecision: contextualRebalanceDecision, frozenSchedule: frozenSchedule, targetWeights: targetWeights)
    }

    public static func runCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        CalendarCompositeStrategies.runCalendarBucketTurboCompositeStrategy(assetInputs: assetInputs, initialCash: initialCash, settings: settings)
    }

    public static func runCoarseCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        CalendarCompositeStrategies.runCoarseCalendarBucketTurboCompositeStrategy(assetInputs: assetInputs, initialCash: initialCash, settings: settings)
    }

    public static func runCompactCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        CalendarCompositeStrategies.runCompactCalendarBucketTurboCompositeStrategy(assetInputs: assetInputs, initialCash: initialCash, settings: settings)
    }

    public static func runNoCalendarLowDrawdownCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        CalendarCompositeStrategies.runNoCalendarLowDrawdownCompositeStrategy(assetInputs: assetInputs, initialCash: initialCash, settings: settings)
    }

    public static func runNoCalendarHighReturnCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        CalendarCompositeStrategies.runNoCalendarHighReturnCompositeStrategy(assetInputs: assetInputs, initialCash: initialCash, settings: settings)
    }

    public static func runNoCalendarThreeSleeveCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        CalendarCompositeStrategies.runNoCalendarThreeSleeveCompositeStrategy(assetInputs: assetInputs, initialCash: initialCash, settings: settings)
    }

    public static func advancedRuleBasedRebalanceAdvice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        template: AdvancedBacktestStrategyTemplate,
        initialCash: Double = 100_000
    ) -> StrategyRebalanceAdvice? {
        StrategyAdviceCalculator.advancedRuleBasedRebalanceAdvice(assetInputs: assetInputs, template: template, initialCash: initialCash)
    }

    public static func advancedRotationRebalanceAdvice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        mode: AdvancedBacktestStrategyMode,
        initialCash: Double = 100_000,
        settings: AdvancedBacktestRiskSettings? = nil,
        nfciAsOf: BacktestNFCIAsOfData? = nil,
        strategyRun: AdvancedRotationStrategyRun? = nil
    ) -> StrategyRebalanceAdvice? {
        StrategyAdviceCalculator.advancedRotationRebalanceAdvice(assetInputs: assetInputs, mode: mode, initialCash: initialCash, settings: settings, nfciAsOf: nfciAsOf, strategyRun: strategyRun)
    }

    public static func alignedRotationPriceSeries(
        from preparedSeries: [PreparedAdvancedSeries],
        zeroFillBeforeFirstSymbols: Set<String> = []
    ) -> AlignedRotationPriceSeries {
        MarketInputPreparation.alignedRotationPriceSeries(from: preparedSeries, zeroFillBeforeFirstSymbols: zeroFillBeforeFirstSymbols)
    }

    public static func optimizeAdvancedStrategy(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestInstrument,
        fxSeries: PublicHistorySeries?,
        initialCash: Double,
        baseSettings: AdvancedBacktestRiskSettings,
        limit: Int = 3
    ) -> [BacktestCoreCandidate] {
        RuleBasedOptimization.optimizeAdvancedStrategy(assetSeries: assetSeries, assetOption: assetOption, fxSeries: fxSeries, initialCash: initialCash, baseSettings: baseSettings, limit: limit)
    }

    public static func optimizeAdvancedStrategies(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        baseSettings: AdvancedBacktestRiskSettings,
        limit: Int = 3
    ) -> [BacktestCoreCandidate] {
        RuleBasedOptimization.optimizeAdvancedStrategies(assetInputs: assetInputs, initialCash: initialCash, baseSettings: baseSettings, limit: limit)
    }

    public static func availableDateBounds(for seriesList: [PublicHistorySeries]) -> ClosedRange<Date>? {
        MarketInputPreparation.availableDateBounds(for: seriesList)
    }
}
