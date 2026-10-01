import Foundation

nonisolated public enum RotationStrategy {
    public static func runAdvancedMomentumRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestCoreEngine.runAdvancedRotationStrategy(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            mode: .momentumRotation
        )
    }

    public static func runAdvancedLowDrawdownRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        BacktestCoreEngine.runAdvancedRotationStrategy(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            mode: .lowDrawdownRotation
        )
    }

    static func runAdvancedRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        config: RotationParameters.AdvancedRotationConfig,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedBacktestReport? {
        runAdvancedRotationWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds
        )?.report
    }

    static func runAdvancedRotationWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        config: RotationParameters.AdvancedRotationConfig,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedRotationStrategyRun? {
        let preparedSeries: [PreparedAdvancedSeries] = assetInputs.compactMap { input -> PreparedAdvancedSeries? in
            guard input.assetSeries != nil,
                  !input.assetOption.requiresHistoricalFX || input.fxSeries != nil else { return nil }
            return MarketInputPreparation.preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard preparedSeries.count >= 2 else { return nil }

        let normalizedInitialCash = max(initialCash, 0)
        let normalizedFeeRate = max(settings.feeRate, 0) / 100
        let normalizedSlippageRate = max(settings.slippageRate, 0) / 100
        let normalizedRebalanceBand = max(config.rebalanceBand, 0)
        let normalizedRiskBudgetMultiplier = max(config.riskBudgetEnhancer?.multiplier ?? 1, 0)
        let normalizedFinancingAnnualRate = max(config.riskBudgetEnhancer?.annualFinancingRate ?? 0, 0)
        let allowsFinancedExposure = normalizedRiskBudgetMultiplier > 1.0001
        guard normalizedInitialCash > 0 else { return nil }

        let aligned = MarketInputPreparation.alignedRotationPriceSeries(
            from: preparedSeries,
            zeroFillBeforeFirstSymbols: config.zeroFillBeforeFirstSymbols
        )
        let commonDates = aligned.dates
        let pricesBySymbol = aligned.pricesBySymbol
        let ohlcFeaturesBySymbol = config.ohlcRiskOverlay == nil
            ? nil
            : OHLCRiskOverlay.alignedOHLCRiskFeatures(from: preparedSeries, commonDates: commonDates)
        let optionBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, $0.assetOption) })
        let symbols = preparedSeries.map { $0.assetOption.symbol }
        let tradableSymbols = symbols.filter { !config.signalOnlySymbols.contains($0) }
        guard !tradableSymbols.isEmpty else { return nil }
        let simulationRange: ClosedRange<Int>
        if let dateBounds {
            guard let startIndex = commonDates.firstIndex(where: { $0 >= dateBounds.lowerBound }),
                  let endIndex = commonDates.lastIndex(where: { $0 <= dateBounds.upperBound }),
                  startIndex <= endIndex else { return nil }
            simulationRange = startIndex...endIndex
        } else {
            guard let startIndex = commonDates.indices.first,
                  let endIndex = commonDates.indices.last else { return nil }
            simulationRange = startIndex...endIndex
        }
        guard simulationRange.count > 1 else { return nil }
        let maxMAFilterPeriod = max(config.maFilterPeriodBySymbol?.values.max() ?? config.maFilterPeriod, config.maFilterPeriod)
        let fastCrashBrakeLookback = config.fastCrashBrake?.lookbackSessions ?? 0
        let overheatBrakeWarmup = max(
            config.overheatBrake?.momentumLookbackSessions ?? 0,
            config.overheatBrake?.rsiLookbackSessions ?? 0,
            config.overheatBrake?.donchianLookbackSessions ?? 0
        )
        let decelerationLockWarmup = max(
            config.decelerationLock?.shortMomentumLookbackSessions ?? 0,
            config.decelerationLock?.rsiLookbackSessions ?? 0,
            config.decelerationLock?.donchianLookbackSessions ?? 0
        )
        let shortWeaknessLockWarmup = max(
            config.shortWeaknessLock?.shortMomentumLookbackSessions ?? 0,
            config.shortWeaknessLock?.relativeLookbackSessions ?? 0
        )
        let pairConfirmationGuardWarmup = max(
            config.pairConfirmationGuard?.peerMomentumLookbackSessions ?? 0,
            config.pairConfirmationGuard?.peerDrawdownLookbackSessions ?? 0
        )
        let heldBreakdownLockWarmup = max(
            config.heldBreakdownLock?.drawdownLookbackSessions ?? 0,
            config.heldBreakdownLock?.shortMomentumLookbackSessions ?? 0,
            config.heldBreakdownLock?.mediumMomentumLookbackSessions ?? 0,
            config.heldBreakdownLock?.relativeLookbackSessions ?? 0,
            config.heldBreakdownLock?.donchianLookbackSessions ?? 0
        )
        let metaSwitchWarmup = max(
            config.metaSwitch?.lossLookbackSessions ?? 0,
            config.metaSwitch?.volatilityLookbackSessions ?? 0,
            config.metaSwitch?.drawdownLookbackSessions ?? 0
        )
        let overlayPortfolioBrakeWarmup = config.goldSatelliteOverlay?.portfolioEquityBrake?.lookbackSessions ?? 0
        let confirmedEquityBreadthWarmup = max(
            config.confirmedEquityBreadth?.shortMomentumLookbackSessions ?? 0,
            config.confirmedEquityBreadth?.longMomentumLookbackSessions ?? 0,
            config.confirmedEquityBreadth?.movingAveragePeriod ?? 0,
            config.confirmedEquityBreadth?.volatilityLookbackSessions ?? 0
        )
        let engineRouterWarmup = max(
            config.engineRouter?.returnLookbackSessions ?? 0,
            config.engineRouter?.drawdownLookbackSessions ?? 0,
            config.engineRouter?.volatilityLookbackSessions ?? 0
        )
        let confirmedAccelerationWarmup = config.confirmedAccelerationSatellite == nil ? 0 : 240
        let profitLockWarmup = max(
            config.profitLockBudget?.lookbackSessions ?? 0,
            config.profitLockBudget?.profitLookbackSessions ?? 0
        )
        let dynamicSleeveWarmup = max(
            config.dynamicSleeveSelector?.lookbackSessions ?? 0,
            config.dynamicSleeveSelector?.satelliteDrawdownLookbackSessions ?? 0,
            config.dynamicSleeveSelector?.portfolioDrawdownLookbackSessions ?? 0
        )
        let canaryRegimeWarmup = max(
            config.canaryRegime?.momentumLookbacks.max() ?? 0,
            config.canaryRegime?.canaryMovingAveragePeriod ?? 0,
            config.canaryRegime?.assetMovingAveragePeriod ?? 0,
            config.canaryRegime?.defensiveMovingAveragePeriod ?? 0
        )
        let extraIndicatorWarmup = [
            config.secondaryLookbackSessions ?? 0,
            config.signalDrawdownLookbackSessions ?? 0,
            config.rsiLookbackSessions ?? 0,
            config.donchianLookbackSessions ?? 0,
            overheatBrakeWarmup,
            decelerationLockWarmup,
            shortWeaknessLockWarmup,
            pairConfirmationGuardWarmup,
            heldBreakdownLockWarmup,
            config.portfolioDrawdownGuard?.lookbackSessions ?? 0,
            metaSwitchWarmup,
            overlayPortfolioBrakeWarmup,
            confirmedEquityBreadthWarmup,
            engineRouterWarmup,
            confirmedAccelerationWarmup,
            profitLockWarmup,
            dynamicSleeveWarmup,
            canaryRegimeWarmup,
            RotationParameters.advancedOverlayWarmup(for: config),
        ].max() ?? 0
        let minimumWarmup = ([
            config.lookbackSessions,
            maxMAFilterPeriod,
            config.volatilityLookbackSessions,
            fastCrashBrakeLookback,
            extraIndicatorWarmup,
        ].max() ?? 0) + 1
        guard commonDates.count > minimumWarmup else { return nil }

        var maBySymbol: [String: [Double?]] = [:]
        var volatilityBySymbol: [String: [Double?]] = [:]
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            let maFilterPeriod = config.maFilterPeriodBySymbol?[symbol] ?? config.maFilterPeriod
            maBySymbol[symbol] = TechnicalIndicators.movingAverage(values: prices, period: maFilterPeriod)
            volatilityBySymbol[symbol] = TechnicalIndicators.rollingAnnualizedVolatility(values: prices, period: config.volatilityLookbackSessions)
        }

        let metaTracesByMode = config.metaSwitch.flatMap { metaSwitch in
            RotationSimulation.metaEngineTraces(
                for: metaSwitch,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates
            )
        }
        if config.metaSwitch != nil, metaTracesByMode == nil {
            return nil
        }
        let engineRouterTracesByMode = config.engineRouter.flatMap { engineRouter in
            RotationSimulation.engineRouterTraces(
                for: engineRouter,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                observedBySymbol: aligned.observedBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                initialCash: normalizedInitialCash,
                feeRate: normalizedFeeRate,
                slippageRate: normalizedSlippageRate
            )
        }
        if config.engineRouter != nil, engineRouterTracesByMode == nil {
            return nil
        }
        let dynamicSleeveTracesByMode = config.dynamicSleeveSelector.flatMap { selector in
            RotationSimulation.dynamicSleeveSelectorTraces(
                for: selector,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                observedBySymbol: aligned.observedBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                initialCash: normalizedInitialCash,
                feeRate: normalizedFeeRate,
                slippageRate: normalizedSlippageRate
            )
        }
        if config.dynamicSleeveSelector != nil, dynamicSleeveTracesByMode == nil {
            return nil
        }

        var dynamicSleeveWeight = config.dynamicSleeveSelector?.initialSatelliteWeight ?? 0.80
        var overlayState = RotationState.AdvancedRotationOverlayState()

        func targetWeights(
            at signalIndex: Int,
            traceIndex: Int,
            refreshRepairOverlay: Bool,
            currentPoints: [BacktestSeriesPoint],
            portfolioValuesByCommonIndex: [Double]
        ) -> [String: Double] {
            let baseWeights: [String: Double]
            if let selector = config.dynamicSleeveSelector,
               let dynamicSleeveTracesByMode,
               let routed = RotationTargets.dynamicSleeveSelectorTargetWeights(
                selector: selector,
                signalIndex: signalIndex,
                weightIndex: traceIndex,
                tracesByMode: dynamicSleeveTracesByMode,
                strategyValues: currentPoints.map(\.portfolioValue),
                previousWeight: dynamicSleeveWeight
               ) {
                dynamicSleeveWeight = routed.satelliteWeight
                baseWeights = routed.weights
            } else if config.engineRouter != nil,
                      let engineRouterTracesByMode {
                baseWeights = RotationTargets.resolvedAdvancedRotationTargetWeights(
                    symbols: symbols,
                    pricesBySymbol: pricesBySymbol,
                    maBySymbol: maBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    traceIndex: traceIndex,
                    config: config,
                    engineRouterTracesByMode: engineRouterTracesByMode,
                    portfolioValues: portfolioValuesByCommonIndex
                )
            } else if let metaSwitch = config.metaSwitch,
                      let metaTracesByMode,
                      let rawMetaWeights = RotationTargets.metaRotationTargetWeights(
                metaSwitch: metaSwitch,
                stressIndex: signalIndex,
                weightIndex: traceIndex,
                tracesByMode: metaTracesByMode
              ) {
                let overlayWeights = GoldSatelliteOverlay.applyGoldSatelliteOverlay(
                    to: rawMetaWeights,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    pricesBySymbol: pricesBySymbol,
                    portfolioValues: portfolioValuesByCommonIndex,
                    config: config
                )
                baseWeights = RotationOverlayStack.applyPostTargetOverlays(
                    to: overlayWeights,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    pricesBySymbol: pricesBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    portfolioValues: portfolioValuesByCommonIndex,
                    config: config
                )
                .filter { !config.signalOnlySymbols.contains($0.key) }
            } else {
                let rawWeights = Dictionary(uniqueKeysWithValues: RotationTargets.advancedRotationTargetWeights(
                    symbols: symbols,
                    pricesBySymbol: pricesBySymbol,
                    maBySymbol: maBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    config: config
                )
                .filter { !config.signalOnlySymbols.contains($0.symbol) }
                .map { ($0.symbol, $0.weight) })
                baseWeights = RotationOverlayStack.applyPostTargetOverlays(
                    to: rawWeights,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    pricesBySymbol: pricesBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    portfolioValues: portfolioValuesByCommonIndex,
                    config: config
                )
                .filter { !config.signalOnlySymbols.contains($0.key) }
            }

            return RotationOverlayStack.applyAdvancedOverlayStack(
                to: baseWeights,
                signalIndex: signalIndex,
                pricesBySymbol: pricesBySymbol,
                config: config,
                state: &overlayState,
                refreshRepairOverlay: refreshRepairOverlay,
                ohlcFeaturesBySymbol: ohlcFeaturesBySymbol,
                portfolioValues: portfolioValuesByCommonIndex
            )
            .filter { !config.signalOnlySymbols.contains($0.key) }
        }

        func applyPortfolioDrawdownGuard(
            to targetWeights: [String: Double],
            currentValue: Double,
            currentPoints: [BacktestSeriesPoint]
        ) -> [String: Double] {
            guard let guardConfig = config.portfolioDrawdownGuard,
                  !targetWeights.isEmpty,
                  !currentPoints.isEmpty else { return targetWeights }
            let lookbackSessions = max(guardConfig.lookbackSessions, 1)
            var recentValues = currentPoints.suffix(lookbackSessions).map(\.portfolioValue)
            recentValues.append(currentValue)
            guard let recentPeak = recentValues.max(), recentPeak > 0 else { return targetWeights }
            let drawdownFromPeak = currentValue / recentPeak - 1
            guard drawdownFromPeak < -max(guardConfig.drawdownThreshold, 0) else { return targetWeights }
            let scale = min(max(guardConfig.scale, 0), 1)
            return WeightMath.scaledWeightMap(targetWeights, by: scale)
        }

        var lastRebalanceIndex = Int.min / 2
        let firstRebalanceIndex = max(simulationRange.lowerBound, 1)
        let rebalanceSessions = max(config.rebalanceSessions, 1)
        let overlayRebalanceSessions = config.globalRepairStack.map { max($0.overlayRebalanceSessions, 1) }
        let frame = MarketDataFrame(
            dates: commonDates,
            pricesBySymbol: pricesBySymbol,
            observedBySymbol: aligned.observedBySymbol,
            ohlcBySymbol: Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, $0.ohlcPoints) }),
            tradableSymbols: tradableSymbols,
            optionBySymbol: optionBySymbol,
            simulationRange: simulationRange
        )
        let execution = BacktestExecutionConfig(
            initialCash: normalizedInitialCash,
            feeRate: normalizedFeeRate,
            slippageRate: normalizedSlippageRate,
            rebalanceBand: normalizedRebalanceBand,
            financingAnnualRate: normalizedFinancingAnnualRate,
            allowsFinancedExposure: allowsFinancedExposure,
            buyReason: config.buyReason
        )
        let provider = StrategyTargetProvider { context in
            let baseTargetWeights = targetWeights(
                at: context.signalIndex,
                traceIndex: context.index,
                refreshRepairOverlay: context.refreshOverlay,
                currentPoints: context.points,
                portfolioValuesByCommonIndex: context.portfolioValuesByIndex
            )
            let guardedTargetWeights = config.metaSwitch == nil
                ? applyPortfolioDrawdownGuard(
                    to: baseTargetWeights,
                    currentValue: context.signalPortfolioValue,
                    currentPoints: context.points
                )
                : baseTargetWeights
            return normalizedRiskBudgetMultiplier == 1
                ? guardedTargetWeights
                : WeightMath.scaledWeightMap(guardedTargetWeights, by: normalizedRiskBudgetMultiplier)
        }

        guard let simulation = BacktestDailySimulator.run(
            frame: frame,
            execution: execution,
            provider: provider,
            rebalanceDecision: { index, _ in
                let shouldOverlayRebalance = overlayRebalanceSessions.map {
                    index == firstRebalanceIndex || (index > 0 && index % $0 == 0)
                } ?? false
                let shouldBaseRebalance: Bool
                if config.rebalancesFromFirstSignal {
                    shouldBaseRebalance = index == firstRebalanceIndex
                        || (index > 0 && index - lastRebalanceIndex >= rebalanceSessions)
                } else {
                    shouldBaseRebalance = index == firstRebalanceIndex || (index > 0 && index % rebalanceSessions == 0)
                }
                let shouldRebalance = shouldBaseRebalance || shouldOverlayRebalance
                return BacktestRebalanceDecision(
                    shouldRebalance: shouldRebalance,
                    refreshOverlay: shouldOverlayRebalance
                )
            },
            didExecuteTarget: { lastRebalanceIndex = $0 }
        ) else { return nil }

        let points = simulation.points
        let benchmarkPoints = simulation.benchmarkPoints
        let trades = simulation.trades

        guard let last = points.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: points) else { return nil }

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
            points: points,
            benchmarkPoints: benchmarkPoints,
            pricePoints: [],
            trades: trades,
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
            points: points,
            benchmarkPoints: benchmarkPoints,
            benchmarkSeries: perAssetBenchmarkSeries,
            trades: trades.sorted { lhs, rhs in lhs.date < rhs.date },
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
        return AdvancedRotationStrategyRun(report: report, dailyStates: simulation.dailyStates)
    }
}
