import Foundation

nonisolated struct DayKMultiAsset007Signal: Equatable {
    let symbol: String
    let momentum126: Double
    let sma200: Double
    let volatility63: Double
    let score: Double
}

nonisolated enum DayKMultiAsset007Logic {
    static let roleGroups = [
        ["gold_cny"],
        ["nasdaq", "sp500"],
        ["csi300", "shanghai_composite"],
    ]
    static let trendLookback = 200
    static let momentumLookback = 126
    static let volatilityLookback = 63
    static let rebalanceSessions = 20
    static let targetPortfolioVolatility = 0.10
    static let minimumInverseVolatility = 0.08
    static let maximumAssetWeight = 0.50

    static func trailingReturn(
        prices: [Double], signalIndex: Int, lookback: Int
    ) -> Double? {
        guard lookback > 0,
              prices.indices.contains(signalIndex),
              signalIndex >= lookback else { return nil }
        let current = prices[signalIndex]
        let prior = prices[signalIndex - lookback]
        guard current.isFinite, prior.isFinite, current > 0, prior > 0 else { return nil }
        return current / prior - 1
    }

    static func movingAverage(
        prices: [Double], signalIndex: Int, lookback: Int
    ) -> Double? {
        guard lookback > 0,
              prices.indices.contains(signalIndex),
              signalIndex + 1 >= lookback else { return nil }
        let values = prices[(signalIndex - lookback + 1)...signalIndex]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func annualizedVolatility(
        prices: [Double], signalIndex: Int, lookback: Int
    ) -> Double? {
        guard lookback >= 2,
              prices.indices.contains(signalIndex),
              signalIndex >= lookback else { return nil }
        var returns: [Double] = []
        returns.reserveCapacity(lookback)
        for index in (signalIndex - lookback + 1)...signalIndex {
            let prior = prices[index - 1]
            let current = prices[index]
            guard prior.isFinite, current.isFinite, prior > 0, current > 0 else { return nil }
            returns.append(current / prior - 1)
        }
        guard returns.count >= 2 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0.0) { $0 + pow($1 - mean, 2) }
            / Double(returns.count - 1)
        let value = sqrt(max(variance, 0)) * sqrt(252)
        return value.isFinite && value > 0 ? value : nil
    }

    static func signal(
        symbol: String, prices: [Double], signalIndex: Int
    ) -> DayKMultiAsset007Signal? {
        guard prices.indices.contains(signalIndex),
              let sma200 = movingAverage(
                prices: prices, signalIndex: signalIndex, lookback: trendLookback
              ),
              let momentum126 = trailingReturn(
                prices: prices, signalIndex: signalIndex, lookback: momentumLookback
              ),
              let volatility63 = annualizedVolatility(
                prices: prices, signalIndex: signalIndex, lookback: volatilityLookback
              ),
              prices[signalIndex] > sma200,
              momentum126 > 0 else { return nil }
        let score = momentum126 / max(volatility63, minimumInverseVolatility)
        guard score.isFinite, score > 0 else { return nil }
        return .init(
            symbol: symbol,
            momentum126: momentum126,
            sma200: sma200,
            volatility63: volatility63,
            score: score
        )
    }

    static func selectedSignals(
        pricesBySymbol: [String: [Double]], signalIndex: Int
    ) -> [DayKMultiAsset007Signal] {
        roleGroups.compactMap { group in
            let eligible = group.compactMap { symbol -> DayKMultiAsset007Signal? in
                guard let prices = pricesBySymbol[symbol] else { return nil }
                return signal(symbol: symbol, prices: prices, signalIndex: signalIndex)
            }
            return eligible.sorted {
                if abs($0.score - $1.score) > 1e-12 { return $0.score > $1.score }
                return $0.symbol < $1.symbol
            }.first
        }
    }

    private static func cappedNormalizedWeights(
        signals: [DayKMultiAsset007Signal], useInverseVolatility: Bool
    ) -> [String: Double] {
        guard !signals.isEmpty else { return [:] }
        if signals.count == 1 {
            return [signals[0].symbol: 1]
        }
        let raw = Dictionary(uniqueKeysWithValues: signals.map { signal in
            let value = useInverseVolatility
                ? 1 / max(signal.volatility63, minimumInverseVolatility)
                : 1.0
            return (signal.symbol, value)
        })
        let total = raw.values.reduce(0, +)
        guard total > 0 else { return [:] }
        var normalized = raw.mapValues { $0 / total }
        guard let largest = normalized.max(by: { $0.value < $1.value }),
              largest.value > maximumAssetWeight else { return normalized }
        normalized[largest.key] = maximumAssetWeight
        let otherTotal = raw.reduce(0.0) { partial, item in
            partial + (item.key == largest.key ? 0 : item.value)
        }
        guard otherTotal > 0 else { return [largest.key: maximumAssetWeight] }
        for (symbol, value) in raw where symbol != largest.key {
            normalized[symbol] = (1 - maximumAssetWeight) * value / otherTotal
        }
        return normalized
    }

    static func forecastPortfolioVolatility(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        relativeWeights: [String: Double]
    ) -> Double? {
        guard !relativeWeights.isEmpty,
              signalIndex >= volatilityLookback else { return nil }
        var portfolioReturns: [Double] = []
        portfolioReturns.reserveCapacity(volatilityLookback)
        for index in (signalIndex - volatilityLookback + 1)...signalIndex {
            var value = 0.0
            for (symbol, weight) in relativeWeights {
                guard let prices = pricesBySymbol[symbol],
                      prices.indices.contains(index),
                      prices[index - 1].isFinite,
                      prices[index].isFinite,
                      prices[index - 1] > 0,
                      prices[index] > 0 else { return nil }
                value += weight * (prices[index] / prices[index - 1] - 1)
            }
            portfolioReturns.append(value)
        }
        guard portfolioReturns.count >= 2 else { return nil }
        let mean = portfolioReturns.reduce(0, +) / Double(portfolioReturns.count)
        let variance = portfolioReturns.reduce(0.0) { $0 + pow($1 - mean, 2) }
            / Double(portfolioReturns.count - 1)
        let value = sqrt(max(variance, 0)) * sqrt(252)
        return value.isFinite && value > 0 ? value : nil
    }

    static func candidateTarget(
        pricesBySymbol: [String: [Double]], signalIndex: Int
    ) -> [String: Double] {
        let selected = selectedSignals(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex)
        let relative = cappedNormalizedWeights(signals: selected, useInverseVolatility: true)
        guard let forecastVolatility = forecastPortfolioVolatility(
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            relativeWeights: relative
        ) else { return [:] }
        let grossScale = min(1, targetPortfolioVolatility / forecastVolatility)
        var target = relative.mapValues { $0 * grossScale }
        if selected.count == 1, let symbol = selected.first?.symbol {
            target[symbol] = min(target[symbol] ?? 0, maximumAssetWeight)
        }
        return target.filter { $0.value > 0 }
    }

    static func matchedEqualWeightTarget(
        pricesBySymbol: [String: [Double]], signalIndex: Int
    ) -> [String: Double] {
        let selected = selectedSignals(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex)
        var target = cappedNormalizedWeights(signals: selected, useInverseVolatility: false)
        if selected.count == 1, let symbol = selected.first?.symbol {
            target[symbol] = maximumAssetWeight
        }
        return target.filter { $0.value > 0 }
    }
}
