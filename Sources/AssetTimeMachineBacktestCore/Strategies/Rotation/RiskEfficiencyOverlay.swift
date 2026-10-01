import Foundation

nonisolated enum RiskEfficiencyOverlay {
    static func targetRiskQuality(
        weights: [String: Double],
        governor: RotationParameters.AdvancedRotationRiskEfficiencyGovernor,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> (expectedVolatility: Double?, quality: Double, checked: Int, healthy: Int) {
        var weightedVariance = 0.0
        var weightedMomentum = 0.0
        var momentumWeight = 0.0
        var checked = 0
        var healthy = 0
        for symbol in weights.keys.sorted() {
            let weight = max(weights[symbol] ?? 0, 0)
            guard symbol != "usd_cash",
                  weight > 0,
                  let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex) else { continue }
            if let volatility = PortfolioIndicators.annualizedVolatilityAt(
                values: prices,
                at: signalIndex,
                lookback: governor.volatilityLookbackSessions
            ) {
                weightedVariance += pow(weight * volatility, 2)
            }
            if let momentum = TechnicalIndicators.priceMomentum(
                values: prices,
                at: signalIndex,
                lookback: governor.momentumLookbackSessions
            ) {
                weightedMomentum += weight * momentum
                momentumWeight += weight
            }
            if let ma60 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 60),
               let momentum20 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 20) {
                checked += 1
                if prices[signalIndex] > ma60 && momentum20 > -0.015 {
                    healthy += 1
                }
            }
        }
        let expectedVolatility = weightedVariance > 0 ? sqrt(weightedVariance) : nil
        let quality = momentumWeight > 0 ? weightedMomentum / momentumWeight : 0
        return (expectedVolatility, quality, checked, healthy)
    }

    static func applyRiskEfficiencyGovernor(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: RotationParameters.AdvancedRotationConfig
    ) -> [String: Double] {
        guard let governor = config.riskEfficiencyGovernor,
              signalIndex >= 0 else { return WeightMath.normalizedWeightMap(rawWeights) }
        let risk = targetRiskQuality(
            weights: rawWeights,
            governor: governor,
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex
        )
        guard let expectedVolatility = risk.expectedVolatility,
              expectedVolatility > governor.triggerVolatility else { return WeightMath.normalizedWeightMap(rawWeights) }
        let shouldScale: Bool
        switch governor.mode {
        case "weak_momentum":
            shouldScale = risk.quality < governor.momentumThreshold
        case "weak_breadth":
            shouldScale = risk.checked >= 4 && risk.healthy <= max(1, risk.checked / 2)
        case "inefficient":
            shouldScale = risk.quality < governor.momentumThreshold
                || (risk.checked >= 4 && risk.healthy <= max(1, risk.checked / 2))
        default:
            shouldScale = false
        }
        guard shouldScale else { return WeightMath.normalizedWeightMap(rawWeights) }
        let scale = min(1, governor.targetVolatility / max(expectedVolatility, 0.001))
        guard scale < 0.995 else { return WeightMath.normalizedWeightMap(rawWeights) }
        var output = rawWeights
        for symbol in output.keys.sorted() where symbol != "usd_cash" {
            output[symbol] = max(output[symbol] ?? 0, 0) * scale
        }
        return WeightMath.normalizedWeightMap(output)
    }
}
