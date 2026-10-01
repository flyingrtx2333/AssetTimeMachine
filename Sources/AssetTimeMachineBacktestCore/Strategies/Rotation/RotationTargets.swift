import Foundation

nonisolated enum RotationTargets {
    static func targetWeightItems(
        from weights: [String: Double],
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        volatilityBySymbol: [String: [Double?]],
        signalIndex: Int,
        config: RotationParameters.AdvancedRotationConfig
    ) -> [RotationState.AdvancedRotationTargetWeight] {
        weights.keys.sorted().compactMap { symbol -> RotationState.AdvancedRotationTargetWeight? in
            guard let weight = weights[symbol],
                  weight > 0.0001,
                  symbols.contains(symbol),
                  !config.signalOnlySymbols.contains(symbol),
                  let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex) else { return nil }
            return RotationState.AdvancedRotationTargetWeight(
                symbol: symbol,
                weight: weight,
                momentum: TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: config.lookbackSessions) ?? 0,
                annualizedVolatility: volatilityBySymbol[symbol]?[signalIndex] ?? nil
            )
        }
    }

    static func resolvedAdvancedRotationTargetWeights(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        signalIndex: Int,
        signalDate: Date,
        traceIndex: Int,
        config: RotationParameters.AdvancedRotationConfig,
        metaTracesByMode: [AdvancedBacktestStrategyMode: RotationState.AdvancedRotationSimulatedTrace]? = nil,
        engineRouterTracesByMode: [AdvancedBacktestStrategyMode: RotationState.AdvancedRotationSimulatedTrace]? = nil,
        portfolioValues: [Double]? = nil
    ) -> [String: Double] {
        if let engineRouter = config.engineRouter,
           let engineRouterTracesByMode,
           let routerWeights = engineRouterTargetWeights(
            engineRouter: engineRouter,
            signalIndex: signalIndex,
            weightIndex: traceIndex,
            tracesByMode: engineRouterTracesByMode
           ) {
            return RotationOverlayStack.applyPostTargetOverlays(
                to: routerWeights,
                signalIndex: signalIndex,
                signalDate: signalDate,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                portfolioValues: portfolioValues,
                config: config
            )
            .filter { !config.signalOnlySymbols.contains($0.key) }
        }

        let baseWeights: [String: Double]
        if let metaSwitch = config.metaSwitch,
           let metaTracesByMode,
           let rawMetaWeights = metaRotationTargetWeights(
            metaSwitch: metaSwitch,
            stressIndex: signalIndex,
            weightIndex: traceIndex,
            tracesByMode: metaTracesByMode
           ) {
            baseWeights = GoldSatelliteOverlay.applyGoldSatelliteOverlay(
                to: rawMetaWeights,
                signalIndex: signalIndex,
                signalDate: signalDate,
                pricesBySymbol: pricesBySymbol,
                portfolioValues: portfolioValues,
                config: config
            )
        } else {
            baseWeights = Dictionary(uniqueKeysWithValues: advancedRotationTargetWeights(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                signalDate: signalDate,
                config: config
            ).map { ($0.symbol, $0.weight) })
        }

        return RotationOverlayStack.applyPostTargetOverlays(
            to: baseWeights,
            signalIndex: signalIndex,
            signalDate: signalDate,
            pricesBySymbol: pricesBySymbol,
            volatilityBySymbol: volatilityBySymbol,
            portfolioValues: portfolioValues,
            config: config
        )
        .filter { !config.signalOnlySymbols.contains($0.key) }
    }

    static func engineRouterTargetWeights(
        engineRouter: RotationParameters.AdvancedRotationEngineRouter,
        signalIndex: Int,
        weightIndex: Int,
        tracesByMode: [AdvancedBacktestStrategyMode: RotationState.AdvancedRotationSimulatedTrace]
    ) -> [String: Double]? {
        guard let currentTrace = tracesByMode[engineRouter.currentMode],
              let offensiveTrace = tracesByMode[engineRouter.offensiveMode],
              currentTrace.values.indices.contains(signalIndex),
              offensiveTrace.values.indices.contains(signalIndex),
              currentTrace.weightsByIndex.indices.contains(weightIndex),
              offensiveTrace.weightsByIndex.indices.contains(weightIndex) else { return nil }

        let currentWeights = currentTrace.weightsByIndex[weightIndex]
        let offensiveWeights = offensiveTrace.weightsByIndex[weightIndex]
        let currentReturn = PortfolioIndicators.portfolioRollingReturn(
            values: currentTrace.values,
            at: signalIndex,
            lookback: engineRouter.returnLookbackSessions
        )
        let offensiveReturn = PortfolioIndicators.portfolioRollingReturn(
            values: offensiveTrace.values,
            at: signalIndex,
            lookback: engineRouter.returnLookbackSessions
        )
        let offensiveDrawdown = PortfolioIndicators.portfolioRollingDrawdown(
            values: offensiveTrace.values,
            at: signalIndex,
            lookback: engineRouter.drawdownLookbackSessions
        )

        var routedWeights = currentWeights
        var isOffensiveBlend = false
        if let currentReturn,
           let offensiveReturn,
           offensiveReturn > currentReturn {
            if let offensiveDrawdown,
               offensiveDrawdown < -max(engineRouter.drawdownThreshold, 0) {
                routedWeights = WeightMath.blendedWeightMap(
                    currentWeights,
                    offensiveWeights,
                    firstShare: engineRouter.defensiveBlendCurrentShare
                )
            } else {
                routedWeights = WeightMath.blendedWeightMap(
                    offensiveWeights,
                    currentWeights,
                    firstShare: engineRouter.offensiveBlendShare
                )
                isOffensiveBlend = true
            }
        }

        if isOffensiveBlend,
           let currentVolatility = PortfolioIndicators.portfolioAnnualizedVolatility(
            values: currentTrace.values,
            at: signalIndex,
            lookback: engineRouter.volatilityLookbackSessions
           ),
           let offensiveVolatility = PortfolioIndicators.portfolioAnnualizedVolatility(
            values: offensiveTrace.values,
            at: signalIndex,
            lookback: engineRouter.volatilityLookbackSessions
           ),
           offensiveVolatility > currentVolatility,
           offensiveVolatility > 0 {
            let volatilityRatio = currentVolatility / offensiveVolatility
            let scaleFloor = min(max(engineRouter.volatilityScaleFloor, 0), 1)
            let scale = min(max(volatilityRatio, scaleFloor), 1)
            routedWeights = WeightMath.scaledWeightMap(routedWeights, by: scale)
        }

        return WeightMath.normalizedWeightMap(routedWeights)
    }

    static func dynamicSleeveSelectorWeight(
        selector: RotationParameters.AdvancedRotationDynamicSleeveSelector,
        signalIndex: Int,
        satelliteValues: [Double],
        defensiveValues: [Double],
        strategyValues: [Double],
        previousWeight: Double
    ) -> Double {
        guard let satelliteReturn = PortfolioIndicators.portfolioRollingReturn(
            values: satelliteValues,
            at: signalIndex,
            lookback: selector.lookbackSessions
        ),
              let defensiveReturn = PortfolioIndicators.portfolioRollingReturn(
                values: defensiveValues,
                at: signalIndex,
                lookback: selector.lookbackSessions
              ),
              let satelliteDrawdown = PortfolioIndicators.portfolioRollingDrawdown(
                values: satelliteValues,
                at: signalIndex,
                lookback: selector.satelliteDrawdownLookbackSessions
              ) else { return previousWeight }

        let portfolioDrawdown = PortfolioIndicators.portfolioRollingDrawdown(
            values: strategyValues,
            at: strategyValues.count - 1,
            lookback: selector.portfolioDrawdownLookbackSessions
        ) ?? 0
        let lowWeight = min(max(selector.satelliteLowWeight, 0), 1)
        let highWeight = min(max(selector.satelliteHighWeight, lowWeight), 1)
        if portfolioDrawdown < -max(selector.portfolioDrawdownThreshold, 0)
            || satelliteDrawdown < -max(selector.satelliteDrawdownThreshold, 0) {
            return lowWeight
        }

        let midpoint = (highWeight + lowWeight) / 2
        if previousWeight >= midpoint {
            return satelliteReturn < defensiveReturn - selector.returnMargin ? lowWeight : highWeight
        }
        return satelliteReturn > defensiveReturn + selector.returnMargin ? highWeight : lowWeight
    }

    static func dynamicSleeveSelectorTargetWeights(
        selector: RotationParameters.AdvancedRotationDynamicSleeveSelector,
        signalIndex: Int,
        weightIndex: Int,
        tracesByMode: [AdvancedBacktestStrategyMode: RotationState.AdvancedRotationSimulatedTrace],
        strategyValues: [Double],
        previousWeight: Double
    ) -> (weights: [String: Double], satelliteWeight: Double)? {
        guard let satelliteTrace = tracesByMode[selector.satelliteMode],
              let defensiveTrace = tracesByMode[selector.defensiveMode],
              satelliteTrace.values.indices.contains(signalIndex),
              defensiveTrace.values.indices.contains(signalIndex),
              satelliteTrace.weightsByIndex.indices.contains(weightIndex),
              defensiveTrace.weightsByIndex.indices.contains(weightIndex) else { return nil }

        let satelliteWeight = dynamicSleeveSelectorWeight(
            selector: selector,
            signalIndex: signalIndex,
            satelliteValues: satelliteTrace.values,
            defensiveValues: defensiveTrace.values,
            strategyValues: strategyValues,
            previousWeight: previousWeight
        )
        let weights = WeightMath.blendedWeightMap(
            satelliteTrace.weightsByIndex[weightIndex],
            defensiveTrace.weightsByIndex[weightIndex],
            firstShare: satelliteWeight
        )
        return (weights, satelliteWeight)
    }

    static func metaRotationTargetWeights(
        metaSwitch: RotationParameters.AdvancedRotationMetaSwitch,
        stressIndex: Int,
        weightIndex: Int,
        tracesByMode: [AdvancedBacktestStrategyMode: RotationState.AdvancedRotationSimulatedTrace]
    ) -> [String: Double]? {
        guard let defaultTrace = tracesByMode[metaSwitch.defaultMode],
              let defensiveTrace = tracesByMode[metaSwitch.defensiveMode],
              defaultTrace.values.indices.contains(stressIndex),
              defensiveTrace.weightsByIndex.indices.contains(weightIndex),
              defaultTrace.weightsByIndex.indices.contains(weightIndex) else { return nil }

        let recentReturn = PortfolioIndicators.portfolioRollingReturn(
            values: defaultTrace.values,
            at: stressIndex,
            lookback: metaSwitch.lossLookbackSessions
        ) ?? 0
        let recentVolatility = PortfolioIndicators.portfolioAnnualizedVolatility(
            values: defaultTrace.values,
            at: stressIndex,
            lookback: metaSwitch.volatilityLookbackSessions
        ) ?? 0
        let recentDrawdown = PortfolioIndicators.portfolioRollingDrawdown(
            values: defaultTrace.values,
            at: stressIndex,
            lookback: max(metaSwitch.drawdownLookbackSessions, metaSwitch.lossLookbackSessions, metaSwitch.volatilityLookbackSessions)
        ) ?? 0

        let lossStress = recentReturn <= -max(metaSwitch.lossThreshold, 0)
            && recentDrawdown < -max(metaSwitch.lossDrawdownThreshold, 0)
        let volatilityStress = recentVolatility >= max(metaSwitch.volatilityThreshold, 0)
            && recentReturn < 0
            && recentDrawdown < -max(metaSwitch.volatilityDrawdownThreshold, 0)
        let chosenTrace = (lossStress || volatilityStress) ? defensiveTrace : defaultTrace
        return chosenTrace.weightsByIndex[weightIndex]
    }

    static func canaryRegimeTargetWeights(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        volatilityBySymbol: [String: [Double?]],
        signalIndex: Int,
        regime: RotationParameters.AdvancedRotationCanaryRegime,
        config: RotationParameters.AdvancedRotationConfig
    ) -> [RotationState.AdvancedRotationTargetWeight] {
        let availableSymbols = Set(symbols)
        let canaries = regime.canarySymbols.filter { availableSymbols.contains($0) }
        guard !canaries.isEmpty else { return [] }

        func multiMomentum(_ symbol: String) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return PortfolioIndicators.multiPeriodMomentum(
                values: prices,
                at: signalIndex,
                lookbacks: regime.momentumLookbacks,
                weights: regime.momentumWeights
            )
        }

        func isAboveMovingAverage(_ symbol: String, period: Int) -> Bool {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let movingAverage = PortfolioIndicators.movingAverageValue(
                    symbol: symbol,
                    period: period,
                    at: signalIndex,
                    pricesBySymbol: pricesBySymbol
                  ) else { return false }
            return prices[signalIndex] > movingAverage
        }

        let weakCanaryCount = canaries.reduce(0) { partial, symbol in
            let isWeak = (multiMomentum(symbol) ?? -Double.infinity) < regime.canaryMomentumThreshold
                || !isAboveMovingAverage(symbol, period: regime.canaryMovingAveragePeriod)
            return partial + (isWeak ? 1 : 0)
        }
        let riskOn = weakCanaryCount <= max(regime.weakAllowed, 0)
        var targetWeights: [String: Double] = [:]

        if riskOn {
            let ranked: [(score: Double, symbol: String)] = regime.offensiveSymbols.compactMap { symbol in
                guard availableSymbols.contains(symbol),
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex),
                      let momentum = multiMomentum(symbol),
                      momentum > regime.assetMomentumThreshold,
                      isAboveMovingAverage(symbol, period: regime.assetMovingAveragePeriod) else { return nil }
                let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex] ?? nil
                if let annualizedVolatility,
                   annualizedVolatility >= regime.equityVolatilityCap {
                    return nil
                }
                let volatility = max(annualizedVolatility ?? 0.18, 0.05)
                return (momentum / volatility, symbol)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
                return lhs.score > rhs.score
            }

            let selected = Array(ranked.prefix(max(config.topCount, 1)))
            if !selected.isEmpty {
                let offensiveWeight = max(regime.offensiveWeight, 0)
                if regime.equalWeight {
                    let eachWeight = offensiveWeight / Double(selected.count)
                    for item in selected {
                        targetWeights[item.symbol] = eachWeight
                    }
                } else {
                    let inverseVolatilityWeights = selected.map { item -> (symbol: String, value: Double) in
                        let volatility = max(volatilityBySymbol[item.symbol]?[signalIndex] ?? 0.18, 0.05)
                        return (item.symbol, 1 / volatility)
                    }
                    let totalRawWeight = inverseVolatilityWeights.reduce(0.0) { $0 + $1.value }
                    if totalRawWeight > 0 {
                        for item in inverseVolatilityWeights {
                            targetWeights[item.symbol] = offensiveWeight * item.value / totalRawWeight
                        }
                    }
                }
            }

            if availableSymbols.contains(regime.defensiveSymbol),
               let defensiveMomentum = multiMomentum(regime.defensiveSymbol),
               defensiveMomentum > regime.defensiveMomentumThreshold,
               isAboveMovingAverage(regime.defensiveSymbol, period: regime.defensiveMovingAveragePeriod) {
                targetWeights[regime.defensiveSymbol, default: 0] += max(regime.defensiveBallastWeight, 0)
            }
        } else if availableSymbols.contains(regime.defensiveSymbol),
                  let defensiveMomentum = multiMomentum(regime.defensiveSymbol),
                  defensiveMomentum > regime.defensiveMomentumThreshold,
                  isAboveMovingAverage(regime.defensiveSymbol, period: regime.defensiveMovingAveragePeriod) {
            targetWeights[regime.defensiveSymbol] = max(regime.defensiveOnlyWeight, 0)
        }

        let grossExposure = WeightMath.positiveWeightSum(targetWeights)
        let maxExposure = min(max(config.maxExposure, 0), 1)
        if grossExposure > maxExposure, grossExposure > 0 {
            targetWeights = WeightMath.clampedScaledWeightMap(targetWeights, by: maxExposure / grossExposure)
        }

        return targetWeights.keys.sorted().compactMap { symbol -> RotationState.AdvancedRotationTargetWeight? in
            let weight = targetWeights[symbol] ?? 0
            guard weight > 0.0001,
                  let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex) else { return nil }
            return RotationState.AdvancedRotationTargetWeight(
                symbol: symbol,
                weight: weight,
                momentum: multiMomentum(symbol) ?? 0,
                annualizedVolatility: volatilityBySymbol[symbol]?[signalIndex] ?? nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.weight == rhs.weight { return lhs.symbol < rhs.symbol }
            return lhs.weight > rhs.weight
        }
    }

    static func advancedRotationTargetWeights(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        signalIndex: Int,
        signalDate: Date? = nil,
        config: RotationParameters.AdvancedRotationConfig
    ) -> [RotationState.AdvancedRotationTargetWeight] {
        guard signalIndex - config.lookbackSessions >= 0 else { return [] }
        if let canaryRegime = config.canaryRegime {
            return canaryRegimeTargetWeights(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                regime: canaryRegime,
                config: config
            )
        }

        let baseSymbols = config.baseRotationSymbols.map { allowed in
            symbols.filter { allowed.contains($0) }
        } ?? symbols
        let ranked: [(score: Double, momentum: Double, symbol: String)] = baseSymbols.compactMap { symbol in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex) else { return nil }
            let previousPrice = prices[signalIndex - config.lookbackSessions]
            guard previousPrice > 0 else { return nil }
            let momentum = prices[signalIndex] / previousPrice - 1
            var rankingScore = momentum

            switch config.signal {
            case .maMomentum:
                guard momentum > config.minMomentumThreshold,
                      let ma = maBySymbol[symbol]?[signalIndex],
                      prices[signalIndex] >= ma else { return nil }
            case .lowVolMomentum:
                guard momentum > config.minMomentumThreshold else { return nil }
                if let maxSignalAnnualVolatility = config.maxSignalAnnualVolatility {
                    guard let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex],
                          annualizedVolatility <= maxSignalAnnualVolatility else { return nil }
                }
            case .guardedDualMomentum:
                guard let secondaryLookbackSessions = config.secondaryLookbackSessions,
                      let secondaryMomentum = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: secondaryLookbackSessions),
                      let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex],
                      let drawdownLookback = config.signalDrawdownLookbackSessions,
                      let drawdownFromHigh = TechnicalIndicators.rollingDrawdownFromHigh(values: prices, at: signalIndex, period: drawdownLookback) else { return nil }
                guard momentum > config.minMomentumThreshold,
                      secondaryMomentum > (config.secondaryMomentumThreshold ?? config.minMomentumThreshold) else { return nil }
                if let maxSignalAnnualVolatility = config.maxSignalAnnualVolatility {
                    guard annualizedVolatility <= maxSignalAnnualVolatility else { return nil }
                }
                if let maxSignalDrawdown = config.maxSignalDrawdown {
                    guard drawdownFromHigh >= -max(maxSignalDrawdown, 0) else { return nil }
                }

                let rsi = config.rsiLookbackSessions.flatMap { TechnicalIndicators.relativeStrengthIndex(values: prices, at: signalIndex, period: $0) }
                let donchianPosition = config.donchianLookbackSessions.flatMap { TechnicalIndicators.donchianRangePosition(values: prices, at: signalIndex, period: $0) }

                rankingScore = momentum * 1.2
                    + secondaryMomentum * 0.5
                    + max(drawdownFromHigh, -0.5) * 0.4
                    + (1.0 / max(annualizedVolatility, 0.01)) * 0.015
                if let rsi {
                    rankingScore += (1 - abs(rsi - 62) / 62) * 0.05
                }
                if let donchianPosition {
                    rankingScore += donchianPosition * 0.08
                }
                if symbol == "gold_cny" {
                    rankingScore += 0.03
                }
            case .drawdownReentry:
                guard let secondaryLookbackSessions = config.secondaryLookbackSessions,
                      let secondaryMomentum = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: secondaryLookbackSessions),
                      let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex],
                      let drawdownLookback = config.signalDrawdownLookbackSessions,
                      let drawdownFromHigh = TechnicalIndicators.rollingDrawdownFromHigh(values: prices, at: signalIndex, period: drawdownLookback) else { return nil }
                if let maxSignalDrawdown = config.maxSignalDrawdown {
                    guard drawdownFromHigh >= -max(maxSignalDrawdown, 0) else { return nil }
                }

                let rsi = config.rsiLookbackSessions.flatMap { TechnicalIndicators.relativeStrengthIndex(values: prices, at: signalIndex, period: $0) }
                let momentumPass = momentum > config.minMomentumThreshold
                let rsiPass = rsi.map { value in
                    let lower = config.minimumRSI ?? 0
                    return value >= lower
                } ?? false
                guard momentumPass || rsiPass else { return nil }

                let donchianPosition = config.donchianLookbackSessions.flatMap { TechnicalIndicators.donchianRangePosition(values: prices, at: signalIndex, period: $0) }

                rankingScore = momentum * 1.2
                    + secondaryMomentum * 0.5
                    + max(drawdownFromHigh, -0.5) * 0.4
                    + (1.0 / max(annualizedVolatility, 0.01)) * 0.015
                if let rsi {
                    rankingScore += (1 - abs(rsi - 62) / 62) * 0.05
                }
                if let donchianPosition {
                    rankingScore += donchianPosition * 0.08
                    if let minimumDonchianPosition = config.minimumDonchianPosition,
                       donchianPosition < minimumDonchianPosition {
                        rankingScore -= 0.03
                    }
                }
                if symbol == "gold_cny" {
                    rankingScore += 0.03
                }
            }

            return (rankingScore, momentum, symbol)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
            return lhs.score > rhs.score
        }

        var baseWeights: [String: Double] = [:]
        if let fixedBaseWeightsBySymbol = config.fixedBaseWeightsBySymbol {
            let fixedCandidates = Array(ranked.prefix(max(config.topCount, 1)))
            for item in fixedCandidates {
                let fixedWeight = max(fixedBaseWeightsBySymbol[item.symbol] ?? 0, 0)
                if fixedWeight > 0 {
                    baseWeights[item.symbol] = fixedWeight
                }
            }
            let totalFixedWeight = baseWeights.keys.sorted().reduce(0.0) { $0 + max(baseWeights[$1] ?? 0, 0) }
            guard totalFixedWeight > 0 else { return [] }
            if config.renormalizesFixedBaseWeights {
                baseWeights = WeightMath.scaledWeightMap(baseWeights, by: 1 / totalFixedWeight)
            }
        } else {
            let sortedCandidates: [(score: Double, momentum: Double, symbol: String)]
            if config.weighting == .lowVolMomentumInverseVolatility {
                sortedCandidates = ranked.sorted { lhs, rhs in
                    let lhsVolatility = max(volatilityBySymbol[lhs.symbol]?[signalIndex] ?? 9, 0.01)
                    let rhsVolatility = max(volatilityBySymbol[rhs.symbol]?[signalIndex] ?? 9, 0.01)
                    let lhsScore = lhs.momentum / lhsVolatility
                    let rhsScore = rhs.momentum / rhsVolatility
                    if lhsScore == rhsScore { return lhs.symbol < rhs.symbol }
                    return lhsScore > rhsScore
                }
            } else {
                sortedCandidates = ranked
            }

            let picks = Array(sortedCandidates.prefix(max(config.topCount, 1)))
            guard !picks.isEmpty else { return [] }

            switch config.weighting {
            case .winner:
                baseWeights[picks[0].symbol] = 1
            case .momentumInverseVolatility:
                var rawWeights: [(symbol: String, value: Double)] = []
                for pick in picks {
                    let annualizedVolatility = max(volatilityBySymbol[pick.symbol]?[signalIndex] ?? 9, 0.01)
                    rawWeights.append((pick.symbol, max(pick.momentum, 0.0001) / annualizedVolatility))
                }
                let totalRawWeight = rawWeights.reduce(0.0) { $0 + $1.value }
                guard totalRawWeight > 0 else { return [] }
                for rawWeight in rawWeights {
                    baseWeights[rawWeight.symbol] = rawWeight.value / totalRawWeight
                }
            case .lowVolMomentumInverseVolatility:
                var rawWeights: [(symbol: String, value: Double)] = []
                for pick in picks {
                    let annualizedVolatility = max(volatilityBySymbol[pick.symbol]?[signalIndex] ?? 9, 0.01)
                    rawWeights.append((pick.symbol, 1 / annualizedVolatility))
                }
                let totalRawWeight = rawWeights.reduce(0.0) { $0 + $1.value }
                guard totalRawWeight > 0 else { return [] }
                for rawWeight in rawWeights {
                    baseWeights[rawWeight.symbol] = rawWeight.value / totalRawWeight
                }
            case .coreSatelliteWinner:
                if let coreWeightsBySymbol = config.coreWeightsBySymbol {
                    for item in ranked where coreWeightsBySymbol[item.symbol] != nil {
                        let coreWeight = max(coreWeightsBySymbol[item.symbol] ?? 0, 0)
                        if coreWeight > 0 {
                            baseWeights[item.symbol] = coreWeight
                        }
                    }
                }

                let satelliteCandidates = ranked.filter { config.satelliteSymbols.contains($0.symbol) }
                if let satelliteWinner = satelliteCandidates.first {
                    let satelliteWeight = max(config.satelliteWeight, 0)
                    if satelliteWeight > 0 {
                        baseWeights[satelliteWinner.symbol, default: 0] += satelliteWeight
                    }
                }

                guard !baseWeights.isEmpty else { return [] }
            }
        }

        var exposure = min(max(config.maxExposure, 0), 1)
        if let targetAnnualVolatility = config.targetAnnualVolatility {
            let weightedVolatility: Double
            if config.weighting == .lowVolMomentumInverseVolatility {
                let squaredWeightedVolatility = baseWeights.keys.sorted().reduce(0.0) { partial, symbol in
                    let weight = baseWeights[symbol] ?? 0
                    let annualizedVolatility = max(volatilityBySymbol[symbol]?[signalIndex] ?? 9, 0.01)
                    return partial + pow(weight * annualizedVolatility, 2)
                }
                weightedVolatility = sqrt(squaredWeightedVolatility)
            } else {
                weightedVolatility = baseWeights.keys.sorted().reduce(0.0) { partial, symbol in
                    let weight = baseWeights[symbol] ?? 0
                    let annualizedVolatility = max(volatilityBySymbol[symbol]?[signalIndex] ?? 9, 0.01)
                    return partial + weight * annualizedVolatility
                }
            }
            exposure = min(exposure, targetAnnualVolatility / max(weightedVolatility, 0.01))
        }

        var finalWeights = WeightMath.scaledWeightMap(baseWeights, by: exposure)
        var didUseDecelerationLock = false

        func canRedeploy(to symbol: String) -> Bool {
            guard let redeployPrices = pricesBySymbol[symbol],
                  redeployPrices.indices.contains(signalIndex),
                  let redeployMA = TechnicalIndicators.movingAverage(values: redeployPrices, period: 60)[signalIndex],
                  let redeployMomentum = TechnicalIndicators.priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60) else { return false }
            return redeployPrices[signalIndex] >= redeployMA && redeployMomentum > -0.02
        }

        func capTotalExposure(maxExposure: Double, redeploySymbol: String?, redeployRatio: Double) {
            let currentExposure = WeightMath.positiveWeightSum(finalWeights)
            let normalizedMaxExposure = min(max(maxExposure, 0), 1)
            guard currentExposure > normalizedMaxExposure, currentExposure > 0 else { return }
            let scale = normalizedMaxExposure / currentExposure
            var removedWeight = 0.0
            for symbol in finalWeights.keys.sorted() {
                let originalWeight = max(finalWeights[symbol] ?? 0, 0)
                let scaledWeight = originalWeight * scale
                finalWeights[symbol] = scaledWeight
                removedWeight += originalWeight - scaledWeight
            }
            if let redeploySymbol,
               canRedeploy(to: redeploySymbol) {
                finalWeights[redeploySymbol, default: 0] += removedWeight * min(max(redeployRatio, 0), 1)
            }
        }

        if let pairConfirmationGuard = config.pairConfirmationGuard {
            let isPairBroken = pairConfirmationGuard.peerBySymbol.keys.sorted().contains { symbol in
                let peer = pairConfirmationGuard.peerBySymbol[symbol] ?? ""
                guard (finalWeights[symbol] ?? 0) > 0,
                      let peerPrices = pricesBySymbol[peer],
                      peerPrices.indices.contains(signalIndex) else { return false }
                let peerMomentum = TechnicalIndicators.priceMomentum(
                    values: peerPrices,
                    at: signalIndex,
                    lookback: pairConfirmationGuard.peerMomentumLookbackSessions
                )
                let peerDrawdown = TechnicalIndicators.rollingDrawdownFromHigh(
                    values: peerPrices,
                    at: signalIndex,
                    period: pairConfirmationGuard.peerDrawdownLookbackSessions
                )
                return (peerMomentum ?? 0) < pairConfirmationGuard.peerMomentumThreshold
                    || (peerDrawdown ?? 0) <= -max(pairConfirmationGuard.peerDrawdownThreshold, 0)
            }
            if isPairBroken {
                capTotalExposure(
                    maxExposure: pairConfirmationGuard.maxExposure,
                    redeploySymbol: pairConfirmationGuard.redeploySymbol,
                    redeployRatio: pairConfirmationGuard.redeployRatio
                )
            }
        }

        if let overheatBrake = config.overheatBrake {
            let isOverheated = overheatBrake.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex),
                      let heatMomentum = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: overheatBrake.momentumLookbackSessions),
                      let rsi = TechnicalIndicators.relativeStrengthIndex(values: prices, at: signalIndex, period: overheatBrake.rsiLookbackSessions),
                      let donchianPosition = TechnicalIndicators.donchianRangePosition(values: prices, at: signalIndex, period: overheatBrake.donchianLookbackSessions) else { return false }
                return heatMomentum > overheatBrake.momentumThreshold
                    && rsi > overheatBrake.rsiThreshold
                    && donchianPosition > overheatBrake.donchianPositionThreshold
            }

            if isOverheated {
                let currentExposure = WeightMath.positiveWeightSum(finalWeights)
                let maxExposure = min(max(overheatBrake.maxExposure, 0), 1)
                if currentExposure > maxExposure, currentExposure > 0 {
                    let scale = maxExposure / currentExposure
                    var removedWeight = 0.0
                    for symbol in finalWeights.keys.sorted() {
                        let originalWeight = max(finalWeights[symbol] ?? 0, 0)
                        let scaledWeight = originalWeight * scale
                        finalWeights[symbol] = scaledWeight
                        removedWeight += originalWeight - scaledWeight
                    }

                    if let redeploySymbol = overheatBrake.redeploySymbol,
                       let redeployPrices = pricesBySymbol[redeploySymbol],
                       redeployPrices.indices.contains(signalIndex),
                       let redeployMA = TechnicalIndicators.movingAverage(values: redeployPrices, period: 60)[signalIndex],
                       let redeployMomentum = TechnicalIndicators.priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60),
                       redeployPrices[signalIndex] >= redeployMA,
                       redeployMomentum > -0.02 {
                        let redeployRatio = min(max(overheatBrake.redeployRatio, 0), 1)
                        finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                    }
                }
            }
        }

        if let decelerationLock = config.decelerationLock {
            let isDeceleratingAtHighZone = decelerationLock.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex),
                      let shortMomentum = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: decelerationLock.shortMomentumLookbackSessions),
                      let rsi = TechnicalIndicators.relativeStrengthIndex(values: prices, at: signalIndex, period: decelerationLock.rsiLookbackSessions),
                      let donchianPosition = TechnicalIndicators.donchianRangePosition(values: prices, at: signalIndex, period: decelerationLock.donchianLookbackSessions) else { return false }
                return donchianPosition > decelerationLock.donchianPositionThreshold
                    && rsi > decelerationLock.rsiThreshold
                    && shortMomentum < decelerationLock.shortMomentumUpperThreshold
            }

            if isDeceleratingAtHighZone {
                didUseDecelerationLock = true
                let currentExposure = WeightMath.positiveWeightSum(finalWeights)
                let maxExposure = min(max(decelerationLock.maxExposure, 0), 1)
                if currentExposure > maxExposure, currentExposure > 0 {
                    let scale = maxExposure / currentExposure
                    var removedWeight = 0.0
                    for symbol in finalWeights.keys.sorted() {
                        let originalWeight = max(finalWeights[symbol] ?? 0, 0)
                        let scaledWeight = originalWeight * scale
                        finalWeights[symbol] = scaledWeight
                        removedWeight += originalWeight - scaledWeight
                    }

                    if let redeploySymbol = decelerationLock.redeploySymbol,
                       let redeployPrices = pricesBySymbol[redeploySymbol],
                       redeployPrices.indices.contains(signalIndex),
                       let redeployMA = TechnicalIndicators.movingAverage(values: redeployPrices, period: 60)[signalIndex],
                       let redeployMomentum = TechnicalIndicators.priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60),
                       redeployPrices[signalIndex] >= redeployMA,
                       redeployMomentum > -0.02 {
                        let redeployRatio = min(max(decelerationLock.redeployRatio, 0), 1)
                        finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                    }
                }
            }
        }

        if !didUseDecelerationLock, let shortWeaknessLock = config.shortWeaknessLock {
            let isShortWeaknessTriggered = shortWeaknessLock.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      let relativePrices = pricesBySymbol[shortWeaknessLock.relativeSymbol],
                      signalIndex - shortWeaknessLock.relativeLookbackSessions >= 0,
                      prices.indices.contains(signalIndex),
                      prices.indices.contains(signalIndex - shortWeaknessLock.relativeLookbackSessions),
                      relativePrices.indices.contains(signalIndex),
                      relativePrices.indices.contains(signalIndex - shortWeaknessLock.relativeLookbackSessions),
                      let shortMomentum = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: shortWeaknessLock.shortMomentumLookbackSessions) else { return false }

                let previousAssetPrice = prices[signalIndex - shortWeaknessLock.relativeLookbackSessions]
                let previousRelativePrice = relativePrices[signalIndex - shortWeaknessLock.relativeLookbackSessions]
                let currentAssetPrice = prices[signalIndex]
                let currentRelativePrice = relativePrices[signalIndex]
                guard previousAssetPrice > 0,
                      previousRelativePrice > 0,
                      currentAssetPrice > 0,
                      currentRelativePrice > 0 else { return false }

                let relativeMomentum = (currentAssetPrice / previousAssetPrice) / (currentRelativePrice / previousRelativePrice) - 1
                return shortMomentum < shortWeaknessLock.shortMomentumThreshold
                    && relativeMomentum < shortWeaknessLock.relativeMomentumThreshold
            }

            if isShortWeaknessTriggered {
                let currentExposure = WeightMath.positiveWeightSum(finalWeights)
                let maxExposure = min(max(shortWeaknessLock.maxExposure, 0), 1)
                if currentExposure > maxExposure, currentExposure > 0 {
                    let scale = maxExposure / currentExposure
                    var removedWeight = 0.0
                    for symbol in finalWeights.keys.sorted() {
                        let originalWeight = max(finalWeights[symbol] ?? 0, 0)
                        let scaledWeight = originalWeight * scale
                        finalWeights[symbol] = scaledWeight
                        removedWeight += originalWeight - scaledWeight
                    }

                    if let redeploySymbol = shortWeaknessLock.redeploySymbol,
                       let redeployPrices = pricesBySymbol[redeploySymbol],
                       redeployPrices.indices.contains(signalIndex),
                       let redeployMA = TechnicalIndicators.movingAverage(values: redeployPrices, period: 60)[signalIndex],
                       let redeployMomentum = TechnicalIndicators.priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60),
                       redeployPrices[signalIndex] >= redeployMA,
                       redeployMomentum > -0.02 {
                        let redeployRatio = min(max(shortWeaknessLock.redeployRatio, 0), 1)
                        finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                    }
                }
            }
        }

        if let heldBreakdownLock = config.heldBreakdownLock {
            let isHeldBreakdownTriggered = heldBreakdownLock.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      let relativePrices = pricesBySymbol[heldBreakdownLock.relativeSymbol],
                      prices.indices.contains(signalIndex),
                      relativePrices.indices.contains(signalIndex),
                      let donchianPosition = TechnicalIndicators.donchianRangePosition(
                        values: prices,
                        at: signalIndex,
                        period: heldBreakdownLock.donchianLookbackSessions
                      ),
                      donchianPosition > heldBreakdownLock.donchianPositionThreshold else { return false }

                var signalCount = 0
                if let drawdown = TechnicalIndicators.rollingDrawdownFromHigh(
                    values: prices,
                    at: signalIndex,
                    period: heldBreakdownLock.drawdownLookbackSessions
                ), drawdown <= -max(heldBreakdownLock.drawdownThreshold, 0) {
                    signalCount += 1
                }
                if let shortMomentum = TechnicalIndicators.priceMomentum(
                    values: prices,
                    at: signalIndex,
                    lookback: heldBreakdownLock.shortMomentumLookbackSessions
                ), shortMomentum < heldBreakdownLock.shortMomentumThreshold {
                    signalCount += 1
                }
                if let mediumMomentum = TechnicalIndicators.priceMomentum(
                    values: prices,
                    at: signalIndex,
                    lookback: heldBreakdownLock.mediumMomentumLookbackSessions
                ), mediumMomentum < heldBreakdownLock.mediumMomentumThreshold {
                    signalCount += 1
                }
                if signalIndex - heldBreakdownLock.relativeLookbackSessions >= 0,
                   prices.indices.contains(signalIndex - heldBreakdownLock.relativeLookbackSessions),
                   relativePrices.indices.contains(signalIndex - heldBreakdownLock.relativeLookbackSessions) {
                    let previousAssetPrice = prices[signalIndex - heldBreakdownLock.relativeLookbackSessions]
                    let previousRelativePrice = relativePrices[signalIndex - heldBreakdownLock.relativeLookbackSessions]
                    let currentAssetPrice = prices[signalIndex]
                    let currentRelativePrice = relativePrices[signalIndex]
                    if previousAssetPrice > 0,
                       previousRelativePrice > 0,
                       currentAssetPrice > 0,
                       currentRelativePrice > 0 {
                        let relativeMomentum = (currentAssetPrice / previousAssetPrice) / (currentRelativePrice / previousRelativePrice) - 1
                        if relativeMomentum < heldBreakdownLock.relativeMomentumThreshold {
                            signalCount += 1
                        }
                    }
                }

                return signalCount >= max(heldBreakdownLock.requiredSignals, 1)
            }
            if isHeldBreakdownTriggered {
                capTotalExposure(
                    maxExposure: heldBreakdownLock.maxExposure,
                    redeploySymbol: heldBreakdownLock.redeploySymbol,
                    redeployRatio: heldBreakdownLock.redeployRatio
                )
            }
        }

        if let fastCrashBrake = config.fastCrashBrake {
            let lookbackSessions = max(fastCrashBrake.lookbackSessions, 1)
            let isCrashTriggered = fastCrashBrake.triggerSymbols.contains { symbol in
                guard let prices = pricesBySymbol[symbol],
                      signalIndex - lookbackSessions >= 0,
                      prices.indices.contains(signalIndex),
                      prices.indices.contains(signalIndex - lookbackSessions) else { return false }
                let previousPrice = prices[signalIndex - lookbackSessions]
                guard previousPrice > 0 else { return false }
                let shortTermReturn = prices[signalIndex] / previousPrice - 1
                return shortTermReturn <= -max(fastCrashBrake.drawdownThreshold, 0)
            }

            if isCrashTriggered {
                let scale = min(max(fastCrashBrake.scale, 0), 1)
                var removedWeight = 0.0
                for symbol in fastCrashBrake.scaledSymbols {
                    let originalWeight = finalWeights[symbol] ?? 0
                    guard originalWeight > 0 else { continue }
                    let scaledWeight = originalWeight * scale
                    finalWeights[symbol] = scaledWeight
                    removedWeight += originalWeight - scaledWeight
                }

                if let redeploySymbol = fastCrashBrake.redeploySymbol,
                   ranked.contains(where: { $0.symbol == redeploySymbol }) {
                    let redeployRatio = min(max(fastCrashBrake.redeployRatio, 0), 1)
                    finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                }
            }
        }

        if let volatilityBrake = config.volatilityBrake,
           let triggerVolatility = volatilityBySymbol[volatilityBrake.triggerSymbol]?[signalIndex],
           triggerVolatility > volatilityBrake.threshold {
            let scale = min(max(volatilityBrake.scale, 0), 1)
            var removedWeight = 0.0
            for symbol in volatilityBrake.scaledSymbols {
                let originalWeight = finalWeights[symbol] ?? 0
                guard originalWeight > 0 else { continue }
                let scaledWeight = originalWeight * scale
                finalWeights[symbol] = scaledWeight
                removedWeight += originalWeight - scaledWeight
            }

            if let redeploySymbol = volatilityBrake.redeploySymbol,
               ranked.contains(where: { $0.symbol == redeploySymbol }) {
                let redeployRatio = min(max(volatilityBrake.redeployRatio, 0), 1)
                finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
            }
        }

        if let drawdownLadderBrake = config.drawdownLadderBrake {
            var shouldUseHardScale = false
            var shouldUseSoftScale = false
            for symbol in drawdownLadderBrake.triggerThresholdRatiosBySymbol.keys.sorted() {
                let thresholdRatio = max(drawdownLadderBrake.triggerThresholdRatiosBySymbol[symbol] ?? 0, 0.0001)
                guard let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex) else { continue }
                let startIndex = max(0, signalIndex - max(drawdownLadderBrake.lookbackSessions, 1) + 1)
                guard startIndex <= signalIndex,
                      let recentHigh = prices[startIndex...signalIndex].max(),
                      recentHigh > 0 else { continue }
                let drawdownFromHigh = prices[signalIndex] / recentHigh - 1
                if drawdownFromHigh <= -drawdownLadderBrake.hardDrawdown * thresholdRatio {
                    shouldUseHardScale = true
                } else if drawdownFromHigh <= -drawdownLadderBrake.softDrawdown * thresholdRatio {
                    shouldUseSoftScale = true
                }
            }

            let scale: Double?
            if shouldUseHardScale {
                scale = drawdownLadderBrake.hardScale
            } else if shouldUseSoftScale {
                scale = drawdownLadderBrake.softScale
            } else {
                scale = nil
            }

            if let scale {
                let normalizedScale = min(max(scale, 0), 1)
                var removedWeight = 0.0
                for symbol in drawdownLadderBrake.scaledSymbols {
                    let originalWeight = finalWeights[symbol] ?? 0
                    guard originalWeight > 0 else { continue }
                    let scaledWeight = originalWeight * normalizedScale
                    finalWeights[symbol] = scaledWeight
                    removedWeight += originalWeight - scaledWeight
                }

                if let redeploySymbol = drawdownLadderBrake.redeploySymbol,
                   ranked.contains(where: { $0.symbol == redeploySymbol }) {
                    let redeployRatio = min(max(drawdownLadderBrake.redeployRatio, 0), 1)
                    finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                }
            }
        }

        if let monthlyExposureBrake = config.monthlyExposureBrake,
           let signalDate,
           monthlyExposureBrake.months.contains(BacktestSeriesAlignment.historicalSeriesCalendar.component(.month, from: signalDate)) {
            let normalizedScale = min(max(monthlyExposureBrake.scale, 0), 1)
            var removedWeight = 0.0
            for symbol in monthlyExposureBrake.scaledSymbols {
                let originalWeight = finalWeights[symbol] ?? 0
                guard originalWeight > 0 else { continue }
                let scaledWeight = originalWeight * normalizedScale
                finalWeights[symbol] = scaledWeight
                removedWeight += originalWeight - scaledWeight
            }

            if let redeploySymbol = monthlyExposureBrake.redeploySymbol,
               ranked.contains(where: { $0.symbol == redeploySymbol }) {
                let redeployRatio = min(max(monthlyExposureBrake.redeployRatio, 0), 1)
                finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
            }
        }

        return finalWeights.keys.sorted().compactMap { symbol in
            guard let weight = finalWeights[symbol] else { return nil }
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex) else { return nil }
            let momentum = ranked.first(where: { $0.symbol == symbol })?.momentum
                ?? TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: config.lookbackSessions)
                ?? 0
            return RotationState.AdvancedRotationTargetWeight(
                symbol: symbol,
                weight: weight,
                momentum: momentum,
                annualizedVolatility: volatilityBySymbol[symbol]?[signalIndex] ?? nil
            )
        }
    }
}
