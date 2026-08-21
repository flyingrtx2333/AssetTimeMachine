import Foundation

nonisolated enum HighReturnArchitectureV1Logic {
    static let roleSymbols = [
        "gold_cny",
        "nasdaq",
        "sp500",
        "csi300",
        "shanghai_composite",
    ]
    static let trendHorizons = [20, 60, 120, 252]

    static func trailingReturn(
        _ prices: [Double],
        signalIndex: Int,
        horizon: Int
    ) -> Double? {
        guard horizon > 0,
              prices.indices.contains(signalIndex),
              signalIndex >= horizon else { return nil }
        let current = prices[signalIndex]
        let prior = prices[signalIndex - horizon]
        guard current.isFinite,
              prior.isFinite,
              current > 0,
              prior > 0 else { return nil }
        return current / prior - 1.0
    }

    static func annualizedVolatility(
        _ prices: [Double],
        signalIndex: Int,
        sessions: Int = 60
    ) -> Double? {
        guard sessions >= 2,
              prices.indices.contains(signalIndex),
              signalIndex >= sessions else { return nil }
        let start = signalIndex - sessions
        var returns: [Double] = []
        returns.reserveCapacity(sessions)
        for index in (start + 1)...signalIndex {
            let prior = prices[index - 1]
            let current = prices[index]
            guard prior.isFinite,
                  current.isFinite,
                  prior > 0,
                  current > 0 else { return nil }
            returns.append(current / prior - 1.0)
        }
        guard returns.count >= 2 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0.0) { partial, value in
            partial + pow(value - mean, 2)
        } / Double(returns.count - 1)
        return sqrt(max(variance, 0)) * sqrt(252.0)
    }

    static func trendTarget(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> [String: Double] {
        var ranked: [(symbol: String, strength: Double)] = []
        for symbol in roleSymbols {
            guard let prices = pricesBySymbol[symbol] else { continue }
            let returns = trendHorizons.compactMap {
                trailingReturn(prices, signalIndex: signalIndex, horizon: $0)
            }
            guard returns.count == trendHorizons.count else { continue }
            let positiveVotes = returns.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
            let score = Double(positiveVotes) / Double(trendHorizons.count)
            guard score >= 0.75,
                  let volatility = annualizedVolatility(prices, signalIndex: signalIndex, sessions: 60) else {
                continue
            }
            ranked.append((symbol, score / max(volatility, 0.08)))
        }

        ranked.sort {
            if abs($0.strength - $1.strength) > 1e-12 {
                return $0.strength > $1.strength
            }
            return $0.symbol < $1.symbol
        }
        let selected = ranked.prefix(2)
        let total = selected.reduce(0.0) { $0 + $1.strength }
        guard total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: selected.map {
            ($0.symbol, $0.strength / total)
        })
    }

    static func riskBudgetTarget(
        baseTarget: [String: Double],
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> [String: Double] {
        var sanitized: [String: Double] = [:]
        for symbol in roleSymbols {
            let weight = max(baseTarget[symbol] ?? 0, 0)
            if weight > 0 {
                sanitized[symbol] = weight
            }
        }

        var breadth = 0
        for symbol in roleSymbols {
            guard let prices = pricesBySymbol[symbol],
                  let r60 = trailingReturn(prices, signalIndex: signalIndex, horizon: 60),
                  let r120 = trailingReturn(prices, signalIndex: signalIndex, horizon: 120) else {
                continue
            }
            if r60 > 0 && r120 > 0 {
                breadth += 1
            }
        }

        let gross = sanitized.values.reduce(0, +)
        guard gross > 0 else { return [:] }
        if gross > 1.0 {
            return sanitized.mapValues { $0 / gross }
        }
        guard breadth >= 4, gross < 1.0 else { return sanitized }
        return sanitized.mapValues { $0 / gross }
    }

    static func blendedTarget(
        trend: [String: Double],
        budget: [String: Double]
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        for symbol in roleSymbols {
            let weight = 0.5 * max(trend[symbol] ?? 0, 0)
                + 0.5 * max(budget[symbol] ?? 0, 0)
            if weight > 0 {
                result[symbol] = weight
            }
        }
        let gross = result.values.reduce(0, +)
        if gross > 1.0, gross > 0 {
            return result.mapValues { $0 / gross }
        }
        return result
    }
}
