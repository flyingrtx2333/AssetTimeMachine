import Foundation

nonisolated enum EquityRiskOverlays {
    static func applyConfirmedEquityBreadthOverlay(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        volatilityBySymbol: [String: [Double?]],
        config: RotationParameters.AdvancedRotationConfig
    ) -> [String: Double] {
        guard let breadth = config.confirmedEquityBreadth else {
            return WeightMath.normalizedWeightMap(rawWeights)
        }

        let confirmed: [(score: Double, symbol: String)] = breadth.equitySymbols.compactMap { symbol in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let shortMomentum = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: breadth.shortMomentumLookbackSessions),
                  let longMomentum = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: breadth.longMomentumLookbackSessions),
                  shortMomentum > 0,
                  longMomentum > 0,
                  let movingAverage = TechnicalIndicators.movingAverage(values: prices, period: breadth.movingAveragePeriod)[signalIndex],
                  prices[signalIndex] >= movingAverage else { return nil }
            let volatility = max(volatilityBySymbol[symbol]?[signalIndex] ?? 9, 0.01)
            let score = max(0, (longMomentum + 0.5 * shortMomentum) / volatility)
            guard score > 0 else { return nil }
            return (score, symbol)
        }

        guard confirmed.count >= max(breadth.minConfirmedCount, 1) else {
            return WeightMath.normalizedWeightMap(rawWeights, maxTotalExposure: breadth.maxTotalExposure)
        }

        var finalWeights = rawWeights
        let currentExposure = WeightMath.positiveWeightSum(finalWeights)
        let maxTotalExposure = min(max(breadth.maxTotalExposure, 0), 1)
        let budget = max(0, maxTotalExposure - currentExposure)
        guard budget > 0 else {
            return WeightMath.normalizedWeightMap(finalWeights, maxTotalExposure: maxTotalExposure)
        }

        let totalScore = confirmed.reduce(0.0) { $0 + $1.score }
        guard totalScore > 0 else {
            return WeightMath.normalizedWeightMap(finalWeights, maxTotalExposure: maxTotalExposure)
        }

        for item in confirmed {
            finalWeights[item.symbol, default: 0] += budget * item.score / totalScore
        }
        return WeightMath.normalizedWeightMap(finalWeights, maxTotalExposure: maxTotalExposure)
    }

    static func applyConfirmedAccelerationSatelliteOverlay(
        to rawWeights: [String: Double],
        signalIndex: Int,
        signalDate: Date,
        pricesBySymbol: [String: [Double]],
        config: RotationParameters.AdvancedRotationConfig
    ) -> [String: Double] {
        guard let satellite = config.confirmedAccelerationSatellite else {
            return WeightMath.normalizedWeightMap(rawWeights)
        }
        guard !satellite.weakMonths.contains(BacktestSeriesAlignment.historicalSeriesCalendar.component(.month, from: signalDate)) else {
            return WeightMath.normalizedWeightMap(rawWeights)
        }

        func momentum(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: lookback)
        }

        func volatility(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return TechnicalIndicators.rollingAnnualizedVolatility(values: prices, period: lookback)[signalIndex] ?? nil
        }

        func drawdown(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return TechnicalIndicators.rollingDrawdownFromHigh(values: prices, at: signalIndex, period: lookback)
        }

        func isAboveMovingAverage(_ symbol: String, _ period: Int) -> Bool {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let movingAverage = TechnicalIndicators.movingAverage(values: prices, period: period)[signalIndex] else { return false }
            return prices[signalIndex] >= movingAverage
        }

        func trendConfirmed(_ symbol: String) -> Bool {
            guard let mom60 = momentum(symbol, 60) else { return false }
            return mom60 > 0 && isAboveMovingAverage(symbol, 120)
        }

        func breadthCount(_ symbols: [String]) -> Int {
            symbols.reduce(0) { $0 + (trendConfirmed($1) ? 1 : 0) }
        }

        func chinaBubbleRollover() -> Bool {
            var broken = 0
            for symbol in satellite.chinaMarketSymbols {
                guard pricesBySymbol[symbol] != nil,
                      let mom20 = momentum(symbol, 20),
                      let mom60 = momentum(symbol, 60),
                      let mom120 = momentum(symbol, 120),
                      let dd20 = drawdown(symbol, 20),
                      let dd60 = drawdown(symbol, 60),
                      let vol20 = volatility(symbol, 20),
                      let vol120 = volatility(symbol, 120) else { continue }
                let hot = mom120 > 0.32 || mom60 > 0.22
                let cracking = mom20 < -0.02 || dd20 < -0.045 || dd60 < -0.09 || !isAboveMovingAverage(symbol, 60)
                let volExpanding = vol120 > 0 && vol20 > vol120 * 1.30
                if hot && (cracking || volExpanding) {
                    broken += 1
                }
            }
            return broken >= 1
        }

        func crossMarketSupport(_ symbol: String) -> Bool {
            let usBreadth = breadthCount(satellite.usMarketSymbols)
            let chinaBreadth = breadthCount(satellite.chinaMarketSymbols)
            if symbol == "dowjones" {
                return usBreadth >= 1
            }
            if satellite.chinaExtraSymbols.contains(symbol) {
                return !chinaBubbleRollover() && chinaBreadth >= 2
            }
            return false
        }

        func assetScore(_ symbol: String) -> Double? {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let mom20 = momentum(symbol, 20),
                  let mom60 = momentum(symbol, 60),
                  let mom120 = momentum(symbol, 120),
                  let mom240 = momentum(symbol, 240),
                  let vol20 = volatility(symbol, 20),
                  let vol60 = volatility(symbol, 60),
                  let vol120 = volatility(symbol, 120),
                  let dd20 = drawdown(symbol, 20),
                  let dd60 = drawdown(symbol, 60),
                  let dd120 = drawdown(symbol, 120) else { return nil }
            guard mom60 > 0,
                  mom120 > 0,
                  isAboveMovingAverage(symbol, 120),
                  vol60 <= 0.36,
                  dd60 >= -0.10,
                  dd120 >= -0.17,
                  mom20 > 0.004,
                  mom60 >= max(0.015, mom120 * 0.20),
                  vol20 < vol60 * 0.95 || vol20 < vol120 * 0.90 else { return nil }
            if satellite.chinaExtraSymbols.contains(symbol), chinaBubbleRollover() {
                return nil
            }

            let compressionBonus = vol20 < vol60 ? 0.10 : 0
            let repairBonus = dd20 > -0.015 ? 0.05 : 0
            let hotPenalty = satellite.chinaExtraSymbols.contains(symbol) && mom120 > 0.38 && vol20 > vol60 ? 0.15 : 0
            let score = (
                mom120
                + 0.60 * mom60
                + 0.35 * mom20
                + 0.15 * max(mom240, -0.20)
                + 0.20 * max(dd60, -0.30)
            ) / max(vol60, 0.05) + compressionBonus + repairBonus - hotPenalty
            return score > 0 && prices[signalIndex] > 0 ? score : nil
        }

        let scored = satellite.extraSymbols.compactMap { symbol -> (score: Double, symbol: String)? in
            guard pricesBySymbol[symbol] != nil,
                  crossMarketSupport(symbol),
                  let score = assetScore(symbol) else { return nil }
            return (score, symbol)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
            return lhs.score > rhs.score
        }
        let selected = Array(scored.prefix(max(satellite.topCount, 1)))
        let scoreTotal = selected.reduce(0.0) { $0 + $1.score }
        var finalWeights = rawWeights
        let availableBudget = min(max(1 - WeightMath.positiveWeightSum(finalWeights), 0), max(satellite.cap, 0))
        guard availableBudget > 0, scoreTotal > 0 else {
            return WeightMath.normalizedWeightMap(finalWeights)
        }

        for item in selected {
            let addition = min(max(satellite.perAssetCap, 0), availableBudget * item.score / scoreTotal)
            if addition > 0 {
                finalWeights[item.symbol, default: 0] += addition
            }
        }
        return WeightMath.normalizedWeightMap(finalWeights)
    }

    static func applyProfitLockBudget(
        to rawWeights: [String: Double],
        signalIndex: Int,
        portfolioValues: [Double]?,
        config: RotationParameters.AdvancedRotationConfig
    ) -> [String: Double] {
        guard let budget = config.profitLockBudget else {
            return WeightMath.normalizedWeightMap(rawWeights)
        }

        func cleanValues() -> [Double] {
            guard let portfolioValues else { return [] }
            let upperBound = min(signalIndex, portfolioValues.count - 1)
            guard upperBound >= 0 else { return [] }
            return portfolioValues[0...upperBound].filter { $0 > 0 }
        }

        let values = cleanValues()
        guard !values.isEmpty else { return WeightMath.normalizedWeightMap(rawWeights) }
        let lookbackValues = Array(values.suffix(max(budget.lookbackSessions, 1)))
        guard let peak = lookbackValues.max(), peak > 0 else { return WeightMath.normalizedWeightMap(rawWeights) }
        let drawdown = lookbackValues.last.map { $0 / peak - 1 } ?? 0
        let stress = abs(min(drawdown, 0))
        let baseScale: Double
        if stress <= budget.softDrawdown {
            baseScale = 1
        } else if stress >= budget.hardDrawdown {
            baseScale = min(max(budget.minScale, 0), 1)
        } else {
            let span = max(budget.hardDrawdown - budget.softDrawdown, 0.0001)
            let progress = (stress - budget.softDrawdown) / span
            baseScale = 1 - progress * (1 - min(max(budget.minScale, 0), 1))
        }

        let profitScale: Double
        if values.count > budget.profitLookbackSessions,
           let current = values.last {
            let previous = values[values.count - budget.profitLookbackSessions - 1]
            let recentReturn = previous > 0 ? current / previous - 1 : 0
            profitScale = recentReturn > budget.profitThreshold && drawdown > -budget.shallowDrawdownThreshold
                ? min(baseScale, min(max(budget.profitScale, 0), 1))
                : baseScale
        } else {
            profitScale = baseScale
        }
        return WeightMath.normalizedWeightMap(WeightMath.scaledWeightMap(rawWeights, by: min(max(profitScale, 0), 1)))
    }

    static func applyEquityCurveStateGate(
        to rawWeights: [String: Double],
        signalIndex: Int,
        portfolioValues: [Double]?,
        config: RotationParameters.AdvancedRotationConfig,
        state: inout RotationState.AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard let gate = config.equityCurveStateGate,
              let portfolioValues,
              portfolioValues.indices.contains(signalIndex),
              !rawWeights.isEmpty else {
            return WeightMath.normalizedWeightMap(rawWeights)
        }

        let lookbackSessions = max(gate.lookbackSessions, 1)
        let recentReturn = PortfolioIndicators.portfolioRollingReturn(values: portfolioValues, at: signalIndex, lookback: lookbackSessions)
        let recentDrawdown = PortfolioIndicators.portfolioRollingDrawdown(values: portfolioValues, at: signalIndex, lookback: lookbackSessions)

        if state.equityCurveStateGateDefensive {
            let returnRecovered = recentReturn.map { $0 > gate.exitReturnThreshold } ?? false
            let drawdownRecovered = recentDrawdown.map { $0 > -max(gate.exitDrawdownThreshold, 0) } ?? false
            if returnRecovered || drawdownRecovered {
                state.equityCurveStateGateDefensive = false
            }
        } else {
            let returnWeak = recentReturn.map { $0 < gate.enterReturnThreshold } ?? false
            let drawdownWeak = recentDrawdown.map { $0 < -max(gate.enterDrawdownThreshold, 0) } ?? false
            if returnWeak || drawdownWeak {
                state.equityCurveStateGateDefensive = true
            }
        }

        let scale = state.equityCurveStateGateDefensive
            ? min(max(gate.lowRiskScale, 0), 1)
            : 1
        return WeightMath.normalizedWeightMap(WeightMath.scaledWeightMap(rawWeights, by: scale))
    }

    static func applyAssetRiskStateGate(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        portfolioValues: [Double]?,
        config: RotationParameters.AdvancedRotationConfig,
        state: inout RotationState.AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard let gate = config.assetRiskStateGate,
              !rawWeights.isEmpty else {
            return WeightMath.normalizedWeightMap(rawWeights)
        }

        func momentum(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: lookback)
        }

        func drawdownMagnitude(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol],
                  let drawdown = TechnicalIndicators.rollingDrawdownFromHigh(values: prices, at: signalIndex, period: lookback) else { return nil }
            return abs(min(drawdown, 0))
        }

        func annualizedVolatility(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return PortfolioIndicators.annualizedVolatilityAt(values: prices, at: signalIndex, lookback: lookback)
        }

        func donchianPosition(_ symbol: String, _ lookback: Int) -> Double? {
            guard lookback > 1,
                  let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  signalIndex - lookback + 1 >= 0 else { return nil }
            let window = prices[(signalIndex - lookback + 1)...signalIndex]
            guard let low = window.min(),
                  let high = window.max(),
                  high > low else { return nil }
            return (prices[signalIndex] - low) / (high - low)
        }

        func chinaBubbleRollover(_ symbol: String) -> Bool {
            guard let mediumMomentum = momentum(symbol, 60),
                  let shortDrawdown = drawdownMagnitude(symbol, 20),
                  let highZone = donchianPosition(symbol, 120) else { return false }
            return mediumMomentum > 0.30 && shortDrawdown > 0.06 && highZone > 0.80
        }

        func maxAvailable(_ values: [Double?]) -> Double? {
            let compact = values.compactMap { $0 }
            return compact.isEmpty ? nil : compact.max()
        }

        var guardedWeights = rawWeights
        for symbol in ["csi300", "shanghai_composite"] where chinaBubbleRollover(symbol) {
            guardedWeights[symbol] = 0
        }

        let usMomentum = maxAvailable([
            momentum("nasdaq", gate.usMomentumLookbackSessions),
            momentum("sp500", gate.usMomentumLookbackSessions)
        ])
        let usDrawdown = maxAvailable([
            drawdownMagnitude("nasdaq", gate.usDrawdownLookbackSessions),
            drawdownMagnitude("sp500", gate.usDrawdownLookbackSessions)
        ])
        let usVolatility = maxAvailable([
            annualizedVolatility("nasdaq", gate.usVolatilityLookbackSessions),
            annualizedVolatility("sp500", gate.usVolatilityLookbackSessions)
        ])
        let goldReturn = momentum("gold_cny", gate.goldRelativeLookbackSessions)
        let goldRelative = maxAvailable([
            momentum("nasdaq", gate.goldRelativeLookbackSessions).flatMap { usReturn in
                goldReturn.map { $0 - usReturn }
            },
            momentum("sp500", gate.goldRelativeLookbackSessions).flatMap { usReturn in
                goldReturn.map { $0 - usReturn }
            }
        ])
        let chinaDrawdown = maxAvailable([
            drawdownMagnitude("csi300", gate.chinaDrawdownLookbackSessions),
            drawdownMagnitude("shanghai_composite", gate.chinaDrawdownLookbackSessions)
        ])
        let portfolioDrawdown = portfolioValues.flatMap {
            PortfolioIndicators.portfolioRollingDrawdown(values: $0, at: signalIndex, lookback: gate.portfolioDrawdownLookbackSessions)
        }.map { abs(min($0, 0)) }

        var signalCount = 0
        signalCount += (usMomentum.map { $0 < gate.usMomentumThreshold } ?? false) ? 1 : 0
        signalCount += (usDrawdown.map { $0 > gate.usDrawdownThreshold } ?? false) ? 1 : 0
        signalCount += (usVolatility.map { $0 > gate.usVolatilityThreshold } ?? false) ? 1 : 0
        signalCount += (goldRelative.map { $0 > gate.goldRelativeThreshold } ?? false) ? 1 : 0
        signalCount += (chinaDrawdown.map { $0 > gate.chinaDrawdownThreshold } ?? false) ? 1 : 0
        signalCount += (portfolioDrawdown.map { $0 > gate.portfolioDrawdownThreshold } ?? false) ? 1 : 0

        if signalCount >= max(gate.requiredSignalCount, 1) {
            state.assetRiskDefensiveUntilIndex = max(
                state.assetRiskDefensiveUntilIndex,
                signalIndex + max(gate.cooldownSessions, 0)
            )
            state.assetRiskRecoveryUntilIndex = max(
                state.assetRiskRecoveryUntilIndex,
                state.assetRiskDefensiveUntilIndex + max(gate.recoverySessions, 0)
            )
        }

        let scale: Double
        if signalIndex <= state.assetRiskDefensiveUntilIndex {
            scale = gate.defensiveScale
        } else if signalIndex <= state.assetRiskRecoveryUntilIndex {
            scale = gate.recoveryScale
        } else {
            scale = gate.normalScale
        }
        return WeightMath.normalizedWeightMap(WeightMath.scaledWeightMap(guardedWeights, by: min(max(scale, 0), 1)))
    }
}
