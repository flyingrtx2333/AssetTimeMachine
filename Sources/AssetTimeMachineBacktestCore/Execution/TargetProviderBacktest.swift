import Foundation

nonisolated public enum TargetProviderBacktest {
    public static func researchMarketDataFrame(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        config: ResearchTargetStrategyConfig,
        dateBounds: ClosedRange<Date>? = nil
    ) -> MarketDataFrame? {
        let preparedSeries: [PreparedAdvancedSeries] = assetInputs.compactMap { input in
            guard input.assetSeries != nil,
                  !input.assetOption.requiresHistoricalFX || input.fxSeries != nil else { return nil }
            return MarketInputPreparation.preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard preparedSeries.count == assetInputs.count, preparedSeries.count >= 2 else { return nil }
        let aligned = MarketInputPreparation.alignedRotationPriceSeries(from: preparedSeries, zeroFillBeforeFirstSymbols: config.zeroFillBeforeFirstSymbols)
        let dates = aligned.dates
        let allSymbols = preparedSeries.map(\.assetOption.symbol)
        guard config.signalOnlySymbols.isSubset(of: Set(allSymbols)) else { return nil }
        let tradable = allSymbols.filter { !config.signalOnlySymbols.contains($0) }
        guard !dates.isEmpty, !tradable.isEmpty else { return nil }
        let requested: ClosedRange<Int>
        if let dateBounds {
            guard let start = dates.firstIndex(where: { $0 >= dateBounds.lowerBound }),
                  let end = dates.lastIndex(where: { $0 <= dateBounds.upperBound }), start <= end else { return nil }
            requested = start...end
        } else {
            requested = 0...(dates.count - 1)
        }
        let start = max(requested.lowerBound, max(config.warmupSessions, 1))
        guard start < requested.upperBound else { return nil }
        return MarketDataFrame(
            dates: dates,
            pricesBySymbol: aligned.pricesBySymbol,
            observedBySymbol: aligned.observedBySymbol,
            ohlcBySymbol: Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, $0.ohlcPoints) }),
            tradableSymbols: tradable,
            optionBySymbol: Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, $0.assetOption) }),
            simulationRange: start...requested.upperBound
        )
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
        runResearchTargetProviderStrategyWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            rebalanceDecision: rebalanceDecision,
            contextualRebalanceDecision: contextualRebalanceDecision,
            frozenSchedule: frozenSchedule,
            targetWeights: targetWeights
        )?.report
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
        let preparedSeries: [PreparedAdvancedSeries] = assetInputs.compactMap { input -> PreparedAdvancedSeries? in
            guard input.assetSeries != nil,
                  !input.assetOption.requiresHistoricalFX || input.fxSeries != nil else { return nil }
            return MarketInputPreparation.preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard preparedSeries.count >= 2 else { return nil }

        let normalizedInitialCash = max(initialCash, 0)
        let normalizedFeeRate = max(settings.feeRate, 0) / 100
        let normalizedSlippageRate = max(settings.slippageRate, 0) / 100
        guard normalizedInitialCash > 0 else { return nil }

        let aligned = MarketInputPreparation.alignedRotationPriceSeries(
            from: preparedSeries,
            zeroFillBeforeFirstSymbols: config.zeroFillBeforeFirstSymbols
        )
        let commonDates = aligned.dates
        let pricesBySymbol = aligned.pricesBySymbol
        let optionBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, $0.assetOption) })
        let allPreparedSymbols = preparedSeries.map(\.assetOption.symbol)
        guard config.signalOnlySymbols.isSubset(of: Set(allPreparedSymbols)) else { return nil }
        let tradableSymbols = allPreparedSymbols.filter { !config.signalOnlySymbols.contains($0) }
        guard !commonDates.isEmpty, !tradableSymbols.isEmpty else { return nil }

        let requestedRange: ClosedRange<Int>
        if let dateBounds {
            guard let startIndex = commonDates.firstIndex(where: { $0 >= dateBounds.lowerBound }),
                  let endIndex = commonDates.lastIndex(where: { $0 <= dateBounds.upperBound }),
                  startIndex <= endIndex else { return nil }
            requestedRange = startIndex...endIndex
        } else {
            requestedRange = 0...(commonDates.count - 1)
        }
        let firstSignalReadyIndex = max(requestedRange.lowerBound, max(config.warmupSessions, 1))
        guard firstSignalReadyIndex < requestedRange.upperBound else { return nil }
        let simulationRange = firstSignalReadyIndex...requestedRange.upperBound

        let ohlcBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, $0.ohlcPoints) })
        let dataContext = ResearchTargetDataContext(
            dates: commonDates,
            pricesBySymbol: pricesBySymbol,
            observedBySymbol: aligned.observedBySymbol,
            ohlcBySymbol: ohlcBySymbol,
            tradableSymbols: tradableSymbols
        )
        let frame = MarketDataFrame(
            dates: commonDates,
            pricesBySymbol: pricesBySymbol,
            observedBySymbol: aligned.observedBySymbol,
            ohlcBySymbol: ohlcBySymbol,
            tradableSymbols: tradableSymbols,
            optionBySymbol: optionBySymbol,
            simulationRange: simulationRange
        )
        let precomputedSchedule: FrozenTargetSchedule?
        if let frozenSchedule {
            guard contextualRebalanceDecision == nil,
                  rebalanceDecision == nil,
                  let schedule = frozenSchedule(frame) else { return nil }
            precomputedSchedule = schedule
        } else {
            precomputedSchedule = nil
        }
        let execution = BacktestExecutionConfig(
            initialCash: normalizedInitialCash,
            feeRate: normalizedFeeRate,
            slippageRate: normalizedSlippageRate,
            rebalanceBand: max(config.rebalanceBand, 0),
            tradeToBandBoundary: config.tradeToBandBoundary,
            financingAnnualRate: max(config.financingAnnualRate, 0),
            allowsFinancedExposure: config.allowsFinancedExposure,
            buyReason: config.buyReason
        )
        let provider = StrategyTargetProvider { context in
            let allowedSymbols = Set(tradableSymbols)
            var cleanedWeights: [String: Double] = [:]
            let rawWeights: [String: Double]
            if let precomputedSchedule {
                rawWeights = precomputedSchedule.event(signalIndex: context.signalIndex)?.targetWeights ?? [:]
            } else {
                rawWeights = targetWeights(context, dataContext)
            }
            for symbol in rawWeights.keys.sorted() where allowedSymbols.contains(symbol) {
                let weight = rawWeights[symbol] ?? 0
                guard weight.isFinite, weight > 0 else { continue }
                cleanedWeights[symbol, default: 0] += weight
            }
            let grossWeight = WeightMath.positiveWeightSum(cleanedWeights)
            guard grossWeight > 0 else { return [:] }
            let maxGrossExposure = max(config.maxGrossExposure, 0)
            guard maxGrossExposure > 0 else { return [:] }
            if grossWeight <= maxGrossExposure {
                return cleanedWeights
            }
            return cleanedWeights.mapValues { $0 * maxGrossExposure / grossWeight }
        }

        var lastRebalanceIndex = Int.min / 2
        let firstRebalanceIndex = simulationRange.lowerBound
        let contextualDecision: ((StrategyTargetContext) -> BacktestRebalanceDecision)?
        if let precomputedSchedule {
            contextualDecision = { context in
                BacktestRebalanceDecision(
                    shouldRebalance: precomputedSchedule.event(signalIndex: context.signalIndex) != nil,
                    refreshOverlay: false
                )
            }
        } else if let contextualRebalanceDecision {
            contextualDecision = { context in contextualRebalanceDecision(context, dataContext) }
        } else {
            contextualDecision = nil
        }
        guard let simulation = BacktestDailySimulator.run(
            frame: frame,
            execution: execution,
            provider: provider,
            rebalanceDecision: { index, signalIndex in
                if let rebalanceDecision {
                    return rebalanceDecision(index, signalIndex, dataContext)
                }
                let shouldRebalance = index == firstRebalanceIndex
                    || (index > firstRebalanceIndex && index - lastRebalanceIndex >= max(config.rebalanceSessions, 1))
                return BacktestRebalanceDecision(shouldRebalance: shouldRebalance, refreshOverlay: false)
            },
            contextualRebalanceDecision: contextualDecision,
            didExecuteTarget: { lastRebalanceIndex = $0 }
        ) else { return nil }

        guard let last = simulation.points.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: simulation.points) else { return nil }

        let perAssetBenchmarkSeries = tradableSymbols.compactMap { symbol -> AdvancedBacktestBenchmarkSeries? in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(simulationRange.upperBound),
                  let option = optionBySymbol[symbol] else { return nil }
            let entryIndex = simulationRange.first {
                prices[$0] > 0 && aligned.observedBySymbol[symbol]?[$0] == true
            }
            let allocation = normalizedInitialCash / Double(tradableSymbols.count)
            let seriesPoints = simulationRange.enumerated().map { sequence, index in
                let value: Double
                if let entryIndex, entryIndex <= index, prices[entryIndex] > 0 {
                    value = allocation * prices[index] / prices[entryIndex]
                } else {
                    value = allocation
                }
                return BacktestSeriesPoint(
                    date: commonDates[index],
                    portfolioValue: value,
                    sequence: sequence
                )
            }
            return AdvancedBacktestBenchmarkSeries(id: symbol, title: option.title, points: seriesPoints)
        }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: config.symbol,
            title: config.title,
            points: simulation.points,
            benchmarkPoints: simulation.benchmarkPoints,
            pricePoints: [],
            trades: simulation.trades,
            finalPortfolioValue: last.portfolioValue,
            finalCash: simulation.finalCash,
            finalUnits: simulation.finalUnits,
            exposureRatio: simulation.exposureRatio
        )
        let riskSignalSummary = MarketRiskSignalHistory.summary(
            dates: Array(commonDates[simulationRange]),
            pricesBySymbol: pricesBySymbol.mapValues { Array($0[simulationRange]) }
        )

        let report = AdvancedBacktestReport(
            points: simulation.points,
            benchmarkPoints: simulation.benchmarkPoints,
            benchmarkSeries: perAssetBenchmarkSeries,
            trades: simulation.trades.sorted { lhs, rhs in lhs.date < rhs.date },
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: simulation.finalCash,
            finalUnits: simulation.finalUnits,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: simulation.cashYieldSummary,
            riskSignalSummary: riskSignalSummary,
            exposurePoints: BacktestReportBuilder.exposurePoints(from: simulation.dailyStates),
            assetExposureSeries: BacktestReportBuilder.assetExposureSeries(
                from: simulation.dailyStates,
                symbolOrder: tradableSymbols,
                titlesBySymbol: optionBySymbol.mapValues(\.title)
            )
        )
        return ResearchTargetStrategyRun(report: report, dailyStates: simulation.dailyStates)
    }
}
