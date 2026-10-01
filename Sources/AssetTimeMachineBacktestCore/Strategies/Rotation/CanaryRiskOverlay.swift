import Foundation

nonisolated enum CanaryRiskOverlay {
    static func applyCanaryRiskBrake(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: RotationParameters.AdvancedRotationConfig
    ) -> [String: Double] {
        guard let brake = config.canaryRiskBrake,
              !rawWeights.isEmpty,
              signalIndex >= 0 else {
            return WeightMath.normalizedWeightMap(rawWeights)
        }

        func isWeak(_ symbol: String) -> Bool {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let momentum = PortfolioIndicators.multiPeriodMomentum(
                    values: prices,
                    at: signalIndex,
                    lookbacks: brake.momentumLookbacks,
                    weights: brake.momentumWeights
                  ),
                  let movingAverage = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: brake.movingAveragePeriod) else {
                return true
            }
            return momentum < brake.momentumThreshold || prices[signalIndex] < movingAverage
        }

        let checkedSymbols = brake.symbols.filter { pricesBySymbol[$0]?.indices.contains(signalIndex) == true }
        guard !checkedSymbols.isEmpty else { return WeightMath.normalizedWeightMap(rawWeights) }
        let weakCount = checkedSymbols.reduce(0) { $0 + (isWeak($1) ? 1 : 0) }
        guard weakCount > max(brake.weakAllowed, 0) else { return WeightMath.normalizedWeightMap(rawWeights) }

        let scale = min(max(brake.scale, 0), 1)
        var output = rawWeights
        var removedWeight = 0.0
        for symbol in output.keys.sorted() where symbol != "usd_cash" {
            let originalWeight = max(output[symbol] ?? 0, 0)
            let scaledWeight = originalWeight * scale
            output[symbol] = scaledWeight
            removedWeight += max(originalWeight - scaledWeight, 0)
        }

        if removedWeight > 0,
           brake.redeployGoldRatio > 0,
           !isWeak("gold_cny"),
           rawWeights["gold_cny", default: 0] < 0.95 {
            output["gold_cny", default: 0] += removedWeight * min(max(brake.redeployGoldRatio, 0), 1)
        }

        return WeightMath.normalizedWeightMap(output)
    }
}
