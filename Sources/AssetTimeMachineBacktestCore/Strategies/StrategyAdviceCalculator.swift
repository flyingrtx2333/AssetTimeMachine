import Foundation

nonisolated public enum StrategyAdviceCalculator {
    static func traceBackedRebalanceAdvice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        mode: AdvancedBacktestStrategyMode,
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings?,
        nfciAsOf: BacktestNFCIAsOfData? = nil,
        strategyRun: AdvancedRotationStrategyRun? = nil
    ) -> StrategyRebalanceAdvice? {
        let normalizedInitialCash = max(initialCash, 0)
        let resolvedSettings = settings ?? AdvancedBacktestRiskSettings(
            feeRate: BacktestCoreDefaults.advancedFeeRatePercent,
            slippageRate: BacktestCoreDefaults.advancedSlippageRatePercent,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        )
        guard normalizedInitialCash > 0 else { return nil }
        let resolvedRun: AdvancedRotationStrategyRun?
        let adviceAsOfDate: Date?
        if let strategyRun {
            resolvedRun = strategyRun
            adviceAsOfDate = strategyRun.dailyStates.last?.date
        } else {
            let sourceSeries = assetInputs.flatMap { input in
                [input.assetSeries, input.fxSeries].compactMap { $0 }
            }
            guard let bounds = MarketInputPreparation.availableDateBounds(for: sourceSeries) else { return nil }
            let decisionDate = BacktestSeriesAlignment.nextStrategyWeekday(after: bounds.upperBound)
            let decisionInputs = assetInputs.map { input in
                (
                    assetSeries: BacktestSeriesAlignment.appendingFlatDecisionSession(
                        to: input.assetSeries,
                        cutoff: bounds.upperBound,
                        decisionDate: decisionDate
                    ),
                    assetOption: input.assetOption,
                    fxSeries: BacktestSeriesAlignment.appendingFlatDecisionSession(
                        to: input.fxSeries,
                        cutoff: bounds.upperBound,
                        decisionDate: decisionDate
                    )
                )
            }
            resolvedRun = BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(
                assetInputs: decisionInputs,
                initialCash: normalizedInitialCash,
                settings: resolvedSettings,
                mode: mode,
                nfciAsOf: nfciAsOf
            )
            adviceAsOfDate = bounds.upperBound
        }
        guard let run = resolvedRun,
              let latestState = run.dailyStates.last else {
            return nil
        }

        var optionsBySymbol = Dictionary(uniqueKeysWithValues: BacktestCoreDefaults.strategyAssetOptions.map { ($0.symbol, $0) })
        for input in assetInputs { optionsBySymbol[input.assetOption.symbol] = input.assetOption }
        let allocations = latestState.targetWeights
            .filter { $0.value > 0.0001 }
            .compactMap { symbol, weight -> StrategyRebalanceAllocation? in
                let outputSymbol = mode == .nfciDualCoreSimplifiedV11QualRole && symbol == "sp500"
                    ? "qual"
                    : symbol
                guard let option = optionsBySymbol[outputSymbol] ?? optionsBySymbol[symbol] else { return nil }
                return StrategyRebalanceAllocation(
                    symbol: outputSymbol,
                    title: option.title,
                    targetWeight: weight,
                    momentum: nil,
                    annualizedVolatility: nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.targetWeight == rhs.targetWeight { return lhs.title < rhs.title }
                return lhs.targetWeight > rhs.targetWeight
            }

        return StrategyRebalanceAdvice(
            strategyTitle: mode.title,
            asOfDate: adviceAsOfDate ?? latestState.date,
            lookbackSessions: 0,
            rebalanceSessions: 0,
            targetAnnualVolatility: nil,
            allocations: allocations,
            signalReason: run.latestSignalReason ?? recentWindowAdviceReason(for: mode),
            nextReviewDate: RecentWindowOverlayStrategy.mode(for: mode) == nil
                ? nil
                : BacktestSeriesAlignment.nextStrategyWeekday(after: adviceAsOfDate ?? latestState.date)
        )
    }

    static func recentWindowAdviceReason(for mode: AdvancedBacktestStrategyMode) -> String? {
        switch mode {
        case .recentVolatilityManagedIdleCash:
            return BacktestText.string("严格使用上一交易日数据：63日组合波动低于10%目标时，仅用闲置现金等比例增配；否则保持低噪增强基准仓位。")
        case .recentPairSpreadZ252Shift25:
            return BacktestText.string("严格使用上一交易日数据：两组252日配对Z分数超过±1时卖出相对偏贵一侧、买入相对偏低一侧；区间内保持基准。")
        case .recentGoldEquityRelativeZ252Shift25:
            return BacktestText.string("严格使用上一交易日数据：黄金/可用权益篮子252日Z分数超过±1时做25%均值回归转移；区间内保持基准。")
        default:
            return nil
        }
    }

    public static func advancedRuleBasedRebalanceAdvice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        template: AdvancedBacktestStrategyTemplate,
        initialCash: Double = 100_000
    ) -> StrategyRebalanceAdvice? {
        guard template.mode == .ruleBased else { return nil }
        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }

        let settings = AdvancedBacktestRiskSettings(
            feeRate: BacktestCoreDefaults.advancedFeeRatePercent,
            slippageRate: BacktestCoreDefaults.advancedSlippageRatePercent,
            maxPositionRatio: template.maxPositionRatio,
            cooldownDays: template.cooldownDays,
            stopLossRatio: template.stopLossRatio,
            takeProfitRatio: template.takeProfitRatio
        )
        guard let report = RuleBasedStrategy.runAdvancedStrategies(
            assetInputs: assetInputs,
            initialCash: normalizedInitialCash,
            tradeAmount: max(normalizedInitialCash * template.tradeAmountRatio, 1),
            buyRule: template.buyRule,
            sellRule: template.sellRule,
            settings: settings
        ), let asOfDate = report.points.last?.date,
           report.finalPortfolioValue > 0 else { return nil }

        let allocations = report.assetReports.compactMap { assetReport -> StrategyRebalanceAllocation? in
            let investedValue = max(assetReport.finalPortfolioValue * assetReport.exposureRatio, 0)
            let targetWeight = investedValue / report.finalPortfolioValue
            guard targetWeight > 0.0001 else { return nil }
            return StrategyRebalanceAllocation(
                symbol: assetReport.symbol,
                title: assetReport.title,
                targetWeight: targetWeight,
                momentum: nil,
                annualizedVolatility: nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.targetWeight == rhs.targetWeight { return lhs.title < rhs.title }
            return lhs.targetWeight > rhs.targetWeight
        }

        return StrategyRebalanceAdvice(
            strategyTitle: template.title,
            asOfDate: asOfDate,
            lookbackSessions: 0,
            rebalanceSessions: 0,
            targetAnnualVolatility: nil,
            allocations: allocations
        )
    }

    public static func advancedRotationRebalanceAdvice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        mode: AdvancedBacktestStrategyMode,
        initialCash: Double = 100_000,
        settings: AdvancedBacktestRiskSettings? = nil,
        nfciAsOf: BacktestNFCIAsOfData? = nil,
        strategyRun: AdvancedRotationStrategyRun? = nil
    ) -> StrategyRebalanceAdvice? {
        guard let config = RotationParameters.advancedRotationConfig(for: mode) else {
            return traceBackedRebalanceAdvice(
                assetInputs: assetInputs,
                mode: mode,
                initialCash: initialCash,
                settings: settings,
                nfciAsOf: nfciAsOf,
                strategyRun: strategyRun
            )
        }
        let normalizedInitialCash = max(initialCash, 0)
        let normalizedFeeRate = max(settings?.feeRate ?? BacktestCoreDefaults.advancedFeeRatePercent, 0) / 100
        let normalizedSlippageRate = max(settings?.slippageRate ?? BacktestCoreDefaults.advancedSlippageRatePercent, 0) / 100
        guard normalizedInitialCash > 0 else { return nil }

        let preparedSeries: [PreparedAdvancedSeries] = assetInputs.compactMap { input -> PreparedAdvancedSeries? in
            guard input.assetSeries != nil,
                  !input.assetOption.requiresHistoricalFX || input.fxSeries != nil else { return nil }
            return MarketInputPreparation.preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard preparedSeries.count >= 2 else { return nil }

        let aligned = MarketInputPreparation.alignedRotationPriceSeries(
            from: preparedSeries,
            zeroFillBeforeFirstSymbols: config.zeroFillBeforeFirstSymbols
        )
        let commonDates = aligned.dates
        let pricesBySymbol = aligned.pricesBySymbol
        let optionBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, $0.assetOption) })
        let symbols = preparedSeries.map { $0.assetOption.symbol }
        let tradableSymbols = symbols.filter { !config.signalOnlySymbols.contains($0) }
        guard !tradableSymbols.isEmpty else { return nil }
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
        guard commonDates.count > minimumWarmup,
              let signalIndex = commonDates.indices.last else { return nil }

        var maBySymbol: [String: [Double?]] = [:]
        var volatilityBySymbol: [String: [Double?]] = [:]
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            let maFilterPeriod = config.maFilterPeriodBySymbol?[symbol] ?? config.maFilterPeriod
            maBySymbol[symbol] = TechnicalIndicators.movingAverage(values: prices, period: maFilterPeriod)
            volatilityBySymbol[symbol] = TechnicalIndicators.rollingAnnualizedVolatility(values: prices, period: config.volatilityLookbackSessions)
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
        let dynamicSleeveTrace = config.dynamicSleeveSelector.flatMap { _ in
            RotationSimulation.simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                observedBySymbol: aligned.observedBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: config,
                initialCash: normalizedInitialCash,
                feeRate: normalizedFeeRate,
                slippageRate: normalizedSlippageRate
            )
        }
        if config.dynamicSleeveSelector != nil, dynamicSleeveTrace == nil {
            return nil
        }
        let equityCurveStateTrace = config.equityCurveStateGate.flatMap { _ in
            RotationSimulation.simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                observedBySymbol: aligned.observedBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: config,
                initialCash: normalizedInitialCash,
                feeRate: normalizedFeeRate,
                slippageRate: normalizedSlippageRate
            )
        }
        if config.equityCurveStateGate != nil, equityCurveStateTrace == nil {
            return nil
        }

        let targetWeightItems: [RotationState.AdvancedRotationTargetWeight]
        let portfolioGuardScale: Double
        if config.dynamicSleeveSelector != nil {
            guard let dynamicSleeveTrace,
                  dynamicSleeveTrace.weightsByIndex.indices.contains(signalIndex) else { return nil }
            portfolioGuardScale = 1
            targetWeightItems = RotationTargets.targetWeightItems(
                from: dynamicSleeveTrace.weightsByIndex[signalIndex],
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                config: config
            )
        } else if config.equityCurveStateGate != nil {
            guard let equityCurveStateTrace,
                  equityCurveStateTrace.weightsByIndex.indices.contains(signalIndex) else { return nil }
            portfolioGuardScale = 1
            targetWeightItems = RotationTargets.targetWeightItems(
                from: equityCurveStateTrace.weightsByIndex[signalIndex],
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                config: config
            )
        } else if config.engineRouter != nil {
            guard let engineRouterTracesByMode else { return nil }
            portfolioGuardScale = 1
            let weights = RotationTargets.resolvedAdvancedRotationTargetWeights(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                traceIndex: signalIndex,
                config: config,
                engineRouterTracesByMode: engineRouterTracesByMode
            )
            targetWeightItems = RotationTargets.targetWeightItems(
                from: weights,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                config: config
            )
        } else if let metaSwitch = config.metaSwitch {
            guard let tracesByMode = RotationSimulation.metaEngineTraces(
                for: metaSwitch,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates
            ),
                  let rawMetaWeights = RotationTargets.metaRotationTargetWeights(
                    metaSwitch: metaSwitch,
                    stressIndex: signalIndex,
                    weightIndex: signalIndex,
                    tracesByMode: tracesByMode
                  ) else { return nil }
            let overlayWeights = GoldSatelliteOverlay.applyGoldSatelliteOverlay(
                to: rawMetaWeights,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                pricesBySymbol: pricesBySymbol,
                portfolioValues: tracesByMode[metaSwitch.defaultMode]?.values,
                config: config
            )
            let metaWeights = RotationOverlayStack.applyPostTargetOverlays(
                to: overlayWeights,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                portfolioValues: tracesByMode[metaSwitch.defaultMode]?.values,
                config: config
            )
            portfolioGuardScale = 1
            targetWeightItems = metaWeights.keys.sorted().compactMap { symbol -> RotationState.AdvancedRotationTargetWeight? in
                let weight = metaWeights[symbol] ?? 0
                guard !config.signalOnlySymbols.contains(symbol),
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex) else { return nil }
                return RotationState.AdvancedRotationTargetWeight(
                    symbol: symbol,
                    weight: weight,
                    momentum: TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: config.lookbackSessions) ?? 0,
                    annualizedVolatility: volatilityBySymbol[symbol]?[signalIndex] ?? nil
                )
            }
        } else {
            portfolioGuardScale = RotationSimulation.simulatedPortfolioDrawdownGuardScale(
                symbols: tradableSymbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: config
            )
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
            let adjustedWeights = RotationOverlayStack.applyPostTargetOverlays(
                to: rawWeights,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                portfolioValues: nil,
                config: config
            )
            targetWeightItems = RotationTargets.targetWeightItems(
                from: adjustedWeights,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                config: config
            )
            .filter { !config.signalOnlySymbols.contains($0.symbol) }
        }

        let allocations = targetWeightItems
        .compactMap { target -> StrategyRebalanceAllocation? in
            let adjustedWeight = target.weight * portfolioGuardScale
            guard adjustedWeight > 0,
                  !config.signalOnlySymbols.contains(target.symbol),
                  let option = optionBySymbol[target.symbol] else { return nil }
            return StrategyRebalanceAllocation(
                symbol: target.symbol,
                title: option.title,
                targetWeight: adjustedWeight,
                momentum: target.momentum,
                annualizedVolatility: target.annualizedVolatility
            )
        }
        .sorted { lhs, rhs in
            if lhs.targetWeight == rhs.targetWeight { return lhs.title < rhs.title }
            return lhs.targetWeight > rhs.targetWeight
        }

        return StrategyRebalanceAdvice(
            strategyTitle: config.title,
            asOfDate: commonDates[signalIndex],
            lookbackSessions: config.lookbackSessions,
            rebalanceSessions: config.rebalanceSessions,
            targetAnnualVolatility: config.targetAnnualVolatility,
            allocations: allocations
        )
    }
}
