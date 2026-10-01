import Foundation

nonisolated enum GoldPanicOverlay {
    static func goldPanicOverheated(
        prices: [Double],
        signalIndex: Int,
        lock: RotationParameters.AdvancedRotationGoldPanicLock
    ) -> Bool {
        guard let momentum = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: lock.hotLookbackSessions),
              let longMA = PortfolioIndicators.movingAverageAt(
                values: prices,
                at: signalIndex,
                period: max(80, lock.hotLookbackSessions * 2)
              ) else { return false }
        return momentum > lock.hotThreshold && prices[signalIndex] > longMA * 1.06
    }

    static func goldPanicCracked(
        prices: [Double],
        signalIndex: Int,
        lock: RotationParameters.AdvancedRotationGoldPanicLock
    ) -> Bool {
        guard let momentum = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: lock.crackLookbackSessions),
              let movingAverage = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: lock.movingAveragePeriod),
              let drawdown = TechnicalIndicators.rollingDrawdownFromHigh(
                values: prices,
                at: signalIndex,
                period: max(lock.crackLookbackSessions, 10)
              ) else { return false }
        return momentum < lock.crackThreshold || prices[signalIndex] < movingAverage || drawdown < lock.crackThreshold * 1.4
    }

    static func goldPanicReleaseOK(
        prices: [Double],
        signalIndex: Int,
        lock: RotationParameters.AdvancedRotationGoldPanicLock
    ) -> Bool {
        guard lock.releaseMode != "time_only",
              let movingAverage = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: lock.movingAveragePeriod),
              let momentum = TechnicalIndicators.priceMomentum(
                values: prices,
                at: signalIndex,
                lookback: max(5, lock.crackLookbackSessions)
              ) else { return false }
        if lock.releaseMode == "ma_reclaim" {
            return prices[signalIndex] > movingAverage && momentum > 0
        }
        if lock.releaseMode == "calm_reclaim" {
            let drawdown = TechnicalIndicators.rollingDrawdownFromHigh(values: prices, at: signalIndex, period: 20)
            return prices[signalIndex] > movingAverage && momentum > -0.005 && (drawdown == nil || drawdown! > -0.03)
        }
        return false
    }

    static func applyGoldPanicLock(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: RotationParameters.AdvancedRotationConfig,
        state: inout RotationState.AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard let lock = config.goldPanicLock,
              signalIndex >= 0,
              (rawWeights[lock.symbol] ?? 0) > 0,
              let prices = pricesBySymbol[lock.symbol],
              prices.indices.contains(signalIndex) else { return WeightMath.normalizedWeightMap(rawWeights) }

        if goldPanicOverheated(prices: prices, signalIndex: signalIndex, lock: lock) {
            state.goldPanicArmed = true
        }
        if state.goldPanicArmed && goldPanicCracked(prices: prices, signalIndex: signalIndex, lock: lock) {
            state.goldPanicUntilIndex = max(state.goldPanicUntilIndex, signalIndex + lock.cooldownSessions)
            state.goldPanicArmed = false
        }

        var active = state.goldPanicUntilIndex >= signalIndex
        if active && goldPanicReleaseOK(prices: prices, signalIndex: signalIndex, lock: lock) {
            active = false
            state.goldPanicUntilIndex = signalIndex - 1
        }
        guard active else { return WeightMath.normalizedWeightMap(rawWeights) }

        var output = rawWeights
        output[lock.symbol] = max(output[lock.symbol] ?? 0, 0) * min(max(lock.scale, 0), 1)
        return WeightMath.normalizedWeightMap(output)
    }
}
