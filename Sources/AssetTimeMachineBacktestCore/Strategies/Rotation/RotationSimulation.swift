import Foundation

nonisolated enum RotationSimulation {
    static func simulatedPortfolioDrawdownGuardScale(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        config: RotationParameters.AdvancedRotationConfig
    ) -> Double {
        guard let guardConfig = config.portfolioDrawdownGuard,
              commonDates.count > 2 else { return 1 }

        func guardScale(currentValue: Double, historyValues: [Double]) -> Double {
            guard !historyValues.isEmpty else { return 1 }
            let lookbackSessions = max(guardConfig.lookbackSessions, 1)
            var recentValues = Array(historyValues.suffix(lookbackSessions))
            recentValues.append(currentValue)
            guard let recentPeak = recentValues.max(), recentPeak > 0 else { return 1 }
            let drawdownFromPeak = currentValue / recentPeak - 1
            guard drawdownFromPeak < -max(guardConfig.drawdownThreshold, 0) else { return 1 }
            return min(max(guardConfig.scale, 0), 1)
        }

        var weightsBySymbol: [String: Double] = [:]
        var values: [Double] = [100_000]
        var value = 100_000.0
        let rebalanceSessions = max(config.rebalanceSessions, 1)

        for index in commonDates.indices.dropFirst() {
            var dailyReturn = 0.0
            for symbol in symbols {
                guard let weight = weightsBySymbol[symbol],
                      weight > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(index),
                      prices.indices.contains(index - 1),
                      prices[index - 1] > 0 else { continue }
                dailyReturn += weight * (prices[index] / prices[index - 1] - 1)
            }
            let investedWeight = WeightMath.positiveWeightSum(weightsBySymbol)
            let cashWeight = max(0, 1 - investedWeight)
            dailyReturn += cashWeight * CashYieldCNY.periodReturn(
                from: commonDates[index - 1],
                to: commonDates[index]
            )
            value *= 1 + dailyReturn
            guard value.isFinite, value > 0 else { return 1 }

            if index % rebalanceSessions == 0 {
                let signalIndex = index - 1
                let baseWeights = Dictionary(uniqueKeysWithValues: RotationTargets.advancedRotationTargetWeights(
                    symbols: symbols,
                    pricesBySymbol: pricesBySymbol,
                    maBySymbol: maBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    config: config
                ).map { ($0.symbol, $0.weight) })
                let scale = guardScale(currentValue: value, historyValues: values)
                weightsBySymbol = WeightMath.scaledWeightMap(baseWeights, by: scale)
            }

            values.append(value)
        }

        return guardScale(currentValue: value, historyValues: values)
    }

    static func simulatedRotationTrace(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        config: RotationParameters.AdvancedRotationConfig
    ) -> RotationState.AdvancedRotationSimulatedTrace {
        var weightsBySymbol: [String: Double] = [:]
        var values: [Double] = [100_000]
        var weightsByIndex: [[String: Double]] = [weightsBySymbol]
        var value = 100_000.0
        let rebalanceSessions = max(config.rebalanceSessions, 1)

        func applyPortfolioGuard(to targetWeights: [String: Double], currentValue: Double) -> [String: Double] {
            guard let guardConfig = config.portfolioDrawdownGuard,
                  !targetWeights.isEmpty else { return targetWeights }
            let lookbackSessions = max(guardConfig.lookbackSessions, 1)
            var recentValues = Array(values.suffix(lookbackSessions))
            recentValues.append(currentValue)
            guard let recentPeak = recentValues.max(), recentPeak > 0 else { return targetWeights }
            let drawdownFromPeak = currentValue / recentPeak - 1
            guard drawdownFromPeak < -max(guardConfig.drawdownThreshold, 0) else { return targetWeights }
            let scale = min(max(guardConfig.scale, 0), 1)
            return WeightMath.scaledWeightMap(targetWeights, by: scale)
        }

        for index in commonDates.indices.dropFirst() {
            var dailyReturn = 0.0
            for symbol in symbols {
                guard let weight = weightsBySymbol[symbol],
                      weight > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(index),
                      prices.indices.contains(index - 1),
                      prices[index - 1] > 0 else { continue }
                dailyReturn += weight * (prices[index] / prices[index - 1] - 1)
            }
            let investedWeight = WeightMath.positiveWeightSum(weightsBySymbol)
            let cashWeight = max(0, 1 - investedWeight)
            dailyReturn += cashWeight * CashYieldCNY.periodReturn(
                from: commonDates[index - 1],
                to: commonDates[index]
            )
            value *= 1 + dailyReturn
            if !value.isFinite || value <= 0 {
                value = values.last ?? 100_000
            }

            if index == 1 || index % rebalanceSessions == 0 {
                let signalIndex = index - 1
                let baseWeights = Dictionary(uniqueKeysWithValues: RotationTargets.advancedRotationTargetWeights(
                    symbols: symbols,
                    pricesBySymbol: pricesBySymbol,
                    maBySymbol: maBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    config: config
                ).map { ($0.symbol, $0.weight) })
                weightsBySymbol = applyPortfolioGuard(to: baseWeights, currentValue: value)
            }

            values.append(value)
            weightsByIndex.append(weightsBySymbol)
        }

        return RotationState.AdvancedRotationSimulatedTrace(values: values, weightsByIndex: weightsByIndex)
    }

    static func metaEngineTraces(
        for metaSwitch: RotationParameters.AdvancedRotationMetaSwitch,
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        initialCash: Double = 100_000,
        feeRate: Double = 0.01,
        slippageRate: Double = 0.0005
    ) -> [AdvancedBacktestStrategyMode: RotationState.AdvancedRotationSimulatedTrace]? {
        guard let defaultConfig = RotationParameters.advancedRotationConfig(for: metaSwitch.defaultMode),
              defaultConfig.metaSwitch == nil,
              let defensiveConfig = RotationParameters.advancedRotationConfig(for: metaSwitch.defensiveMode),
              defensiveConfig.metaSwitch == nil else { return nil }
        return [
            metaSwitch.defaultMode: simulatedRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: defaultConfig
            ),
            metaSwitch.defensiveMode: simulatedRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: defensiveConfig
            ),
        ]
    }

    static func engineRouterTraces(
        for engineRouter: RotationParameters.AdvancedRotationEngineRouter,
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        observedBySymbol: [String: [Bool]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        initialCash: Double = 100_000,
        feeRate: Double = 0.01,
        slippageRate: Double = 0.0005
    ) -> [AdvancedBacktestStrategyMode: RotationState.AdvancedRotationSimulatedTrace]? {
        guard let currentConfig = RotationParameters.advancedRotationConfig(for: engineRouter.currentMode),
              currentConfig.engineRouter == nil,
              let offensiveConfig = RotationParameters.advancedRotationConfig(for: engineRouter.offensiveMode),
              offensiveConfig.engineRouter == nil else { return nil }
        return [
            engineRouter.currentMode: simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                observedBySymbol: observedBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: currentConfig,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            ),
            engineRouter.offensiveMode: simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                observedBySymbol: observedBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: offensiveConfig,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            ),
        ]
    }

    static func dynamicSleeveSelectorTraces(
        for selector: RotationParameters.AdvancedRotationDynamicSleeveSelector,
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        observedBySymbol: [String: [Bool]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        initialCash: Double = 100_000,
        feeRate: Double = 0.01,
        slippageRate: Double = 0.0005
    ) -> [AdvancedBacktestStrategyMode: RotationState.AdvancedRotationSimulatedTrace]? {
        guard let satelliteConfig = RotationParameters.advancedRotationConfig(for: selector.satelliteMode),
              satelliteConfig.dynamicSleeveSelector == nil,
              let defensiveConfig = RotationParameters.advancedRotationConfig(for: selector.defensiveMode),
              defensiveConfig.dynamicSleeveSelector == nil else { return nil }
        return [
            selector.satelliteMode: simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                observedBySymbol: observedBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: satelliteConfig,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            ),
            selector.defensiveMode: simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                observedBySymbol: observedBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: defensiveConfig,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            ),
        ]
    }

    static func simulatedFullRotationTrace(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        observedBySymbol: [String: [Bool]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        config: RotationParameters.AdvancedRotationConfig,
        initialCash: Double = 100_000,
        feeRate: Double = 0.01,
        slippageRate: Double = 0.0005
    ) -> RotationState.AdvancedRotationSimulatedTrace {
        let tradableSymbols = symbols.filter { !config.signalOnlySymbols.contains($0) }
        guard !tradableSymbols.isEmpty, !commonDates.isEmpty else {
            return RotationState.AdvancedRotationSimulatedTrace(values: [max(initialCash, 0)], weightsByIndex: [[:]])
        }
        let optionBySymbol = Dictionary(uniqueKeysWithValues: tradableSymbols.map { symbol in
            (
                symbol,
                BacktestInstrument(
                    symbol: symbol,
                    title: symbol,

                    requiresHistoricalFX: false,
                    historicalFXSymbol: nil
                )
            )
        })
        var weightsByIndex = Array(repeating: [String: Double](), count: commonDates.count)
        var didSetWeightsByIndex = Array(repeating: false, count: commonDates.count)
        let rebalanceSessions = max(config.rebalanceSessions, 1)
        var lastRebalanceIndex = Int.min / 2
        let normalizedFeeRate = max(feeRate, 0)
        let normalizedSlippageRate = max(slippageRate, 0)
        let normalizedRiskBudgetMultiplier = max(config.riskBudgetEnhancer?.multiplier ?? 1, 0)
        let normalizedFinancingAnnualRate = max(config.riskBudgetEnhancer?.annualFinancingRate ?? 0, 0)
        let allowsFinancedExposure = normalizedRiskBudgetMultiplier > 1.0001
        let metaTracesByMode = config.metaSwitch.flatMap { metaSwitch in
            metaEngineTraces(
                for: metaSwitch,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates
            )
        }
        let engineRouterTracesByMode = config.engineRouter.flatMap { engineRouter in
            engineRouterTraces(
                for: engineRouter,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                observedBySymbol: observedBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            )
        }
        let dynamicSleeveTracesByMode = config.dynamicSleeveSelector.flatMap { selector in
            dynamicSleeveSelectorTraces(
                for: selector,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                observedBySymbol: observedBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            )
        }
        var dynamicSleeveWeight = config.dynamicSleeveSelector?.initialSatelliteWeight ?? 0.80
        var overlayState = RotationState.AdvancedRotationOverlayState()

        func applyPortfolioGuard(
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

        let firstRebalanceIndex = commonDates.count > 1 ? 1 : 0
        let frame = MarketDataFrame(
            dates: commonDates,
            pricesBySymbol: pricesBySymbol,
            observedBySymbol: observedBySymbol,
            ohlcBySymbol: [:],
            tradableSymbols: tradableSymbols,
            optionBySymbol: optionBySymbol,
            simulationRange: 0...(commonDates.count - 1)
        )
        let execution = BacktestExecutionConfig(
            initialCash: max(initialCash, 0),
            feeRate: normalizedFeeRate,
            slippageRate: normalizedSlippageRate,
            rebalanceBand: max(config.rebalanceBand, 0),
            financingAnnualRate: normalizedFinancingAnnualRate,
            allowsFinancedExposure: allowsFinancedExposure,
            buyReason: config.buyReason
        )
        let provider = StrategyTargetProvider { context in
            let signalIndex = context.signalIndex
            let baseWeights: [String: Double]
            if let selector = config.dynamicSleeveSelector,
               let dynamicSleeveTracesByMode,
               let routed = RotationTargets.dynamicSleeveSelectorTargetWeights(
                selector: selector,
                signalIndex: signalIndex,
                weightIndex: context.index,
                tracesByMode: dynamicSleeveTracesByMode,
                strategyValues: context.points.map(\.portfolioValue),
                previousWeight: dynamicSleeveWeight
               ) {
                dynamicSleeveWeight = routed.satelliteWeight
                baseWeights = routed.weights
            } else {
                baseWeights = RotationTargets.resolvedAdvancedRotationTargetWeights(
                    symbols: symbols,
                    pricesBySymbol: pricesBySymbol,
                    maBySymbol: maBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    traceIndex: context.index,
                    config: config,
                    metaTracesByMode: metaTracesByMode,
                    engineRouterTracesByMode: engineRouterTracesByMode,
                    portfolioValues: context.portfolioValuesByIndex
                )
            }
            let rawWeights = RotationOverlayStack.applyAdvancedOverlayStack(
                to: baseWeights,
                signalIndex: signalIndex,
                pricesBySymbol: pricesBySymbol,
                config: config,
                state: &overlayState,
                refreshRepairOverlay: context.refreshOverlay,
                ohlcFeaturesBySymbol: nil,
                portfolioValues: context.portfolioValuesByIndex
            )
            .filter { !config.signalOnlySymbols.contains($0.key) }
            let guardedWeights = config.metaSwitch == nil
                ? applyPortfolioGuard(
                    to: rawWeights,
                    currentValue: context.signalPortfolioValue,
                    currentPoints: context.points
                )
                : rawWeights
            let finalWeights = normalizedRiskBudgetMultiplier == 1
                ? guardedWeights
                : WeightMath.scaledWeightMap(guardedWeights, by: normalizedRiskBudgetMultiplier)
            if weightsByIndex.indices.contains(context.index) {
                weightsByIndex[context.index] = finalWeights
                didSetWeightsByIndex[context.index] = true
            }
            return finalWeights
        }

        let simulation = BacktestDailySimulator.run(
            frame: frame,
            execution: execution,
            provider: provider,
            rebalanceDecision: { index, _ in
                let overlayRebalanceSessions = config.globalRepairStack.map { max($0.overlayRebalanceSessions, 1) }
                let shouldOverlayRebalance = overlayRebalanceSessions.map {
                    index == firstRebalanceIndex || (index > 0 && index % $0 == 0)
                } ?? false
                let shouldBaseRebalance: Bool
                if config.rebalancesFromFirstSignal {
                    shouldBaseRebalance = index > 0 && index - lastRebalanceIndex >= rebalanceSessions
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
        )

        guard let simulation else {
            return RotationState.AdvancedRotationSimulatedTrace(values: [max(initialCash, 0)], weightsByIndex: [[:]])
        }

        var currentWeights: [String: Double] = [:]
        for index in weightsByIndex.indices {
            if didSetWeightsByIndex[index] {
                currentWeights = weightsByIndex[index]
            } else {
                weightsByIndex[index] = currentWeights
            }
        }
        return RotationState.AdvancedRotationSimulatedTrace(
            values: simulation.points.map(\.portfolioValue),
            weightsByIndex: weightsByIndex
        )
    }
}
