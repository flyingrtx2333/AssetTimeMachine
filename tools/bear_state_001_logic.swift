import Foundation

nonisolated enum BearState001Logic {
    static let lookbackSessions = 252
    static let bearDrawdown = 0.20

    static func drawdown(prices: [Double], signalIndex: Int) -> Double? {
        guard signalIndex >= lookbackSessions - 1, prices.indices.contains(signalIndex) else { return nil }
        let start = signalIndex - lookbackSessions + 1
        let window = prices[start...signalIndex]
        guard window.allSatisfy({ $0.isFinite && $0 > 0 }), let peak = window.max(), peak > 0 else { return nil }
        let current = prices[signalIndex]
        return current / peak - 1.0
    }

    static func owner(nasdaqPrices: [Double], signalIndex: Int) -> String? {
        guard let dd = drawdown(prices: nasdaqPrices, signalIndex: signalIndex) else { return nil }
        return dd <= -bearDrawdown ? "gold_cny" : "nasdaq"
    }
}
