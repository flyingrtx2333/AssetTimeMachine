import Foundation

nonisolated enum PortfolioIndicators {
    static func portfolioRollingReturn(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index),
              values.indices.contains(index - lookback),
              values[index - lookback] > 0 else { return nil }
        return values[index] / values[index - lookback] - 1
    }

    static func portfolioRollingDrawdown(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index) else { return nil }
        let startIndex = max(0, index - lookback + 1)
        guard startIndex <= index,
              let recentPeak = values[startIndex...index].max(),
              recentPeak > 0 else { return nil }
        return values[index] / recentPeak - 1
    }

    static func portfolioAnnualizedVolatility(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 1,
              values.indices.contains(index) else { return nil }
        let startIndex = max(1, index - lookback + 1)
        guard startIndex <= index else { return nil }
        let returns = (startIndex...index).compactMap { currentIndex -> Double? in
            guard values.indices.contains(currentIndex - 1),
                  values[currentIndex - 1] > 0,
                  values[currentIndex] > 0 else { return nil }
            return values[currentIndex] / values[currentIndex - 1] - 1
        }
        guard returns.count >= 5 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count)
        return sqrt(max(variance, 0)) * sqrt(252)
    }

    static func rollingCorrelation(
        leftValues: [Double],
        rightValueSets: [[Double]],
        at index: Int,
        lookback: Int
    ) -> Double? {
        guard lookback > 1,
              leftValues.indices.contains(index),
              index - lookback + 1 >= 1,
              !rightValueSets.isEmpty else { return nil }

        var leftReturns: [Double] = []
        var rightReturns: [Double] = []
        for cursor in (index - lookback + 1)...index {
            guard leftValues.indices.contains(cursor),
                  leftValues.indices.contains(cursor - 1),
                  leftValues[cursor] > 0,
                  leftValues[cursor - 1] > 0 else { continue }
            let availableRightReturns = rightValueSets.compactMap { values -> Double? in
                guard values.indices.contains(cursor),
                      values.indices.contains(cursor - 1),
                      values[cursor] > 0,
                      values[cursor - 1] > 0 else { return nil }
                return values[cursor] / values[cursor - 1] - 1
            }
            guard !availableRightReturns.isEmpty else { continue }
            leftReturns.append(leftValues[cursor] / leftValues[cursor - 1] - 1)
            rightReturns.append(availableRightReturns.reduce(0, +) / Double(availableRightReturns.count))
        }
        guard leftReturns.count >= 20,
              leftReturns.count == rightReturns.count else { return nil }
        let leftMean = leftReturns.reduce(0, +) / Double(leftReturns.count)
        let rightMean = rightReturns.reduce(0, +) / Double(rightReturns.count)
        let leftVariance = leftReturns.reduce(0) { $0 + pow($1 - leftMean, 2) }
        let rightVariance = rightReturns.reduce(0) { $0 + pow($1 - rightMean, 2) }
        guard leftVariance > 0, rightVariance > 0 else { return nil }
        let covariance = leftReturns.indices.reduce(0.0) { partial, cursor in
            partial + (leftReturns[cursor] - leftMean) * (rightReturns[cursor] - rightMean)
        }
        return covariance / sqrt(leftVariance * rightVariance)
    }

    static func movingAverageAt(values: [Double], at index: Int, period: Int) -> Double? {
        guard period > 0,
              values.indices.contains(index),
              index - period + 1 >= 0 else { return nil }
        let window = values[(index - period + 1)...index]
        guard window.allSatisfy({ $0 > 0 }) else { return nil }
        return window.reduce(0, +) / Double(period)
    }

    static func annualizedVolatilityAt(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 1,
              values.indices.contains(index),
              index - lookback + 1 >= 1 else { return nil }
        let startIndex = index - lookback + 1
        var returns: [Double] = []
        returns.reserveCapacity(lookback)
        for cursor in startIndex...index {
            let previous = values[cursor - 1]
            let current = values[cursor]
            guard previous > 0, current > 0 else { return nil }
            returns.append(log(current / previous))
        }
        guard returns.count > 1 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(returns.count - 1, 1))
        return sqrt(max(variance, 0)) * sqrt(252)
    }

    static func rollingLowRebound(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index),
              index - lookback + 1 >= 0 else { return nil }
        let window = values[(index - lookback + 1)...index].filter { $0 > 0 }
        guard let low = window.min(), low > 0 else { return nil }
        return values[index] / low - 1
    }

    static func goldTrendOK(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Bool {
        guard let prices = pricesBySymbol["gold_cny"],
              prices.indices.contains(signalIndex),
              let ma60 = movingAverageAt(values: prices, at: signalIndex, period: 60),
              let ma120 = movingAverageAt(values: prices, at: signalIndex, period: 120),
              let momentum20 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 20) else { return false }
        return prices[signalIndex] > ma60 && prices[signalIndex] > ma120 && momentum20 > -0.02
    }

    static func multiPeriodMomentum(
        values: [Double],
        at index: Int,
        lookbacks: [Int],
        weights: [Double]
    ) -> Double? {
        guard !lookbacks.isEmpty else { return nil }
        var total = 0.0
        for (offset, lookback) in lookbacks.enumerated() {
            let weight = weights.indices.contains(offset) ? weights[offset] : 1
            guard let momentum = TechnicalIndicators.priceMomentum(values: values, at: index, lookback: lookback) else { return nil }
            total += momentum * weight
        }
        return total
    }

    static func movingAverageValue(
        symbol: String,
        period: Int,
        at index: Int,
        pricesBySymbol: [String: [Double]]
    ) -> Double? {
        guard let prices = pricesBySymbol[symbol],
              prices.indices.contains(index) else { return nil }
        return TechnicalIndicators.movingAverage(values: prices, period: period)[index]
    }
}
