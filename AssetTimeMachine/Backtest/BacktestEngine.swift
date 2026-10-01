import Foundation
import AssetTimeMachineBacktestCore

/// App adapter: presentation input and instrument mapping only. Calculations live in SwiftPM.
nonisolated enum BacktestEngine {
    static let defaultEngineVersion = BacktestCoreEngine.defaultEngineVersion

    static func filteredHistorySeries(_ series: PublicHistorySeries?, within bounds: ClosedRange<Date>? = nil) -> PublicHistorySeries? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.filteredHistorySeries(series, within: bounds)
        }
    }

    static func advancedAssetInput(
        for option: BacktestAssetOption,
        historyProvider: (String) -> PublicHistorySeries?
    ) -> (assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?) {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            let value = BacktestCoreEngine.advancedAssetInput(for: option.instrument, historyProvider: historyProvider)
            return (value.assetSeries, option, value.fxSeries)
        }
    }

    static func filteredAdvancedAssetInputs(
        _ assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        within bounds: ClosedRange<Date>?
    ) -> [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)] {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            let values = BacktestCoreEngine.filteredAdvancedAssetInputs(assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, within: bounds)
            return zip(values, assetInputs).map { ($0.0.assetSeries, $0.1.assetOption, $0.0.fxSeries) }
        }
    }

    static func exposurePoints(from dailyStates: [BacktestDailyState]) -> [BacktestExposurePoint] {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.exposurePoints(from: dailyStates)
        }
    }

    static func assetExposureSeries(
        from dailyStates: [BacktestDailyState],
        symbolOrder: [String],
        titlesBySymbol: [String: String]
    ) -> [BacktestAssetExposureSeries] {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.assetExposureSeries(from: dailyStates, symbolOrder: symbolOrder, titlesBySymbol: titlesBySymbol)
        }
    }

    static func statefulAdvancedReport(
        from report: AdvancedBacktestReport,
        dailyStates: [BacktestDailyState],
        within bounds: ClosedRange<Date>,
        rebasedTo initialPortfolioValue: Double
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.statefulAdvancedReport(from: report, dailyStates: dailyStates, within: bounds, rebasedTo: initialPortfolioValue)
        }
    }

    static func run(
        cashWeight: Double,
        goldWeight: Double,
        goldSeries: PublicHistorySeries?,
        indexWeights: [String: Double],
        indexSeriesBySymbol: [String: PublicHistorySeries]
    ) -> BacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.run(cashWeight: cashWeight, goldWeight: goldWeight, goldSeries: goldSeries, indexWeights: indexWeights, indexSeriesBySymbol: indexSeriesBySymbol)
        }
    }

    static func runDCA(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?,
        contributionAmount: Double,
        intervalDays: Int
    ) -> DCABacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runDCA(assetSeries: assetSeries, assetOption: assetOption.instrument, fxSeries: fxSeries, contributionAmount: contributionAmount, intervalDays: intervalDays)
        }
    }

    static func runAdvancedStrategy(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?,
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runAdvancedStrategy(assetSeries: assetSeries, assetOption: assetOption.instrument, fxSeries: fxSeries, initialCash: initialCash, tradeAmount: tradeAmount, buyRule: buyRule, sellRule: sellRule, settings: settings)
        }
    }

    static func runAdvancedStrategies(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runAdvancedStrategies(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, tradeAmount: tradeAmount, buyRule: buyRule, sellRule: sellRule, settings: settings)
        }
    }

    static func runAdvancedMomentumRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runAdvancedMomentumRotation(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings)
        }
    }

    static func runAdvancedLowDrawdownRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runAdvancedLowDrawdownRotation(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings)
        }
    }

    static func runGoldNasdaqDualTrendBarbell(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runGoldNasdaqDualTrendBarbell(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings, dateBounds: dateBounds)
        }
    }

    static func runAdvancedRotationStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        mode: AdvancedBacktestStrategyMode,
        nfciAsOf: BacktestNFCIAsOfData? = nil,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runAdvancedRotationStrategy(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings, mode: mode, nfciAsOf: nfciAsOf, dateBounds: dateBounds)
        }
    }

    static func runAdvancedRotationStrategyWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        mode: AdvancedBacktestStrategyMode,
        nfciAsOf: BacktestNFCIAsOfData? = nil,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedRotationStrategyRun? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings, mode: mode, nfciAsOf: nfciAsOf, dateBounds: dateBounds)
        }
    }

    static func researchMarketDataFrame(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        config: ResearchTargetStrategyConfig,
        dateBounds: ClosedRange<Date>? = nil
    ) -> MarketDataFrame? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.researchMarketDataFrame(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, config: config, dateBounds: dateBounds)
        }
    }

    static func runResearchTargetProviderStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        config: ResearchTargetStrategyConfig,
        dateBounds: ClosedRange<Date>? = nil,
        rebalanceDecision: ((Int, Int, ResearchTargetDataContext) -> BacktestRebalanceDecision)? = nil,
        contextualRebalanceDecision: ((StrategyTargetContext, ResearchTargetDataContext) -> BacktestRebalanceDecision)? = nil,
        frozenSchedule: ((MarketDataFrame) -> FrozenTargetSchedule?)? = nil,
        targetWeights: @escaping (StrategyTargetContext, ResearchTargetDataContext) -> [String: Double]
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runResearchTargetProviderStrategy(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings, config: config, dateBounds: dateBounds, rebalanceDecision: rebalanceDecision, contextualRebalanceDecision: contextualRebalanceDecision, frozenSchedule: frozenSchedule, targetWeights: targetWeights)
        }
    }

    static func runResearchTargetProviderStrategyWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        config: ResearchTargetStrategyConfig,
        dateBounds: ClosedRange<Date>? = nil,
        rebalanceDecision: ((Int, Int, ResearchTargetDataContext) -> BacktestRebalanceDecision)? = nil,
        contextualRebalanceDecision: ((StrategyTargetContext, ResearchTargetDataContext) -> BacktestRebalanceDecision)? = nil,
        frozenSchedule: ((MarketDataFrame) -> FrozenTargetSchedule?)? = nil,
        targetWeights: @escaping (StrategyTargetContext, ResearchTargetDataContext) -> [String: Double]
    ) -> ResearchTargetStrategyRun? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runResearchTargetProviderStrategyWithTrace(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings, config: config, dateBounds: dateBounds, rebalanceDecision: rebalanceDecision, contextualRebalanceDecision: contextualRebalanceDecision, frozenSchedule: frozenSchedule, targetWeights: targetWeights)
        }
    }

    static func runCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runCalendarBucketTurboCompositeStrategy(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings)
        }
    }

    static func runCoarseCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runCoarseCalendarBucketTurboCompositeStrategy(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings)
        }
    }

    static func runCompactCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runCompactCalendarBucketTurboCompositeStrategy(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings)
        }
    }

    static func runNoCalendarLowDrawdownCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runNoCalendarLowDrawdownCompositeStrategy(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings)
        }
    }

    static func runNoCalendarHighReturnCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runNoCalendarHighReturnCompositeStrategy(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings)
        }
    }

    static func runNoCalendarThreeSleeveCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.runNoCalendarThreeSleeveCompositeStrategy(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, settings: settings)
        }
    }

    static func advancedRuleBasedRebalanceAdvice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        template: AdvancedBacktestStrategyTemplate,
        initialCash: Double = 100_000
    ) -> StrategyRebalanceAdvice? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.advancedRuleBasedRebalanceAdvice(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, template: template.core, initialCash: initialCash)
        }
    }

    static func advancedRotationRebalanceAdvice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        mode: AdvancedBacktestStrategyMode,
        initialCash: Double = 100_000,
        settings: AdvancedBacktestRiskSettings? = nil,
        nfciAsOf: BacktestNFCIAsOfData? = nil,
        strategyRun: AdvancedRotationStrategyRun? = nil
    ) -> StrategyRebalanceAdvice? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.advancedRotationRebalanceAdvice(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, mode: mode, initialCash: initialCash, settings: settings, nfciAsOf: nfciAsOf, strategyRun: strategyRun)
        }
    }

    static func alignedRotationPriceSeries(
        from preparedSeries: [PreparedAdvancedSeries],
        zeroFillBeforeFirstSymbols: Set<String> = []
    ) -> AlignedRotationPriceSeries {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.alignedRotationPriceSeries(from: preparedSeries, zeroFillBeforeFirstSymbols: zeroFillBeforeFirstSymbols)
        }
    }

    static func optimizeAdvancedStrategy(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?,
        initialCash: Double,
        baseSettings: AdvancedBacktestRiskSettings,
        limit: Int = 3
    ) -> [AdvancedBacktestCandidate] {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.optimizeAdvancedStrategy(assetSeries: assetSeries, assetOption: assetOption.instrument, fxSeries: fxSeries, initialCash: initialCash, baseSettings: baseSettings, limit: limit).map { candidate in
                AdvancedBacktestCandidate(buyRule: candidate.buyRule, sellRule: candidate.sellRule,
                    tradeAmount: candidate.tradeAmount, settings: candidate.settings, report: candidate.report,
                    comparisonSeries: AdvancedBacktestPresentation.comparisonSeries(from: candidate.report),
                    score: candidate.score)
            }
        }
    }

    static func optimizeAdvancedStrategies(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        baseSettings: AdvancedBacktestRiskSettings,
        limit: Int = 3
    ) -> [AdvancedBacktestCandidate] {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.optimizeAdvancedStrategies(assetInputs: assetInputs.map { ($0.assetSeries, $0.assetOption.instrument, $0.fxSeries) }, initialCash: initialCash, baseSettings: baseSettings, limit: limit).map { candidate in
                AdvancedBacktestCandidate(buyRule: candidate.buyRule, sellRule: candidate.sellRule,
                    tradeAmount: candidate.tradeAmount, settings: candidate.settings, report: candidate.report,
                    comparisonSeries: AdvancedBacktestPresentation.comparisonSeries(from: candidate.report),
                    score: candidate.score)
            }
        }
    }

    static func availableDateBounds(for seriesList: [PublicHistorySeries]) -> ClosedRange<Date>? {
        BacktestText.$context.withValue(AppLocalization.backtestTextContext()) {
            return BacktestCoreEngine.availableDateBounds(for: seriesList)
        }
    }
}
