import Foundation

nonisolated enum DualMomentum001Logic {
    static let lookbackSessions = 252

    static func owner(
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        symbols: [String]
    ) -> String? {
        guard signalIndex >= lookbackSessions else { return nil }
        var best: (symbol: String, momentum: Double)?
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  prices.indices.contains(signalIndex - lookbackSessions) else { continue }
            let current = prices[signalIndex]
            let prior = prices[signalIndex - lookbackSessions]
            guard current.isFinite, prior.isFinite, current > 0, prior > 0 else { continue }
            let momentum = current / prior - 1.0
            guard momentum.isFinite, momentum > 0 else { continue }
            if best == nil || momentum > best!.momentum {
                best = (symbol, momentum)
            }
        }
        return best?.symbol
    }
}
