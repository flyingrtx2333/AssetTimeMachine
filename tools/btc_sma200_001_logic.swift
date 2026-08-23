import Foundation

nonisolated enum BTCSMA200001Logic {
    static func active(signalIndex: Int, prices: [Double], lookback: Int = 200) -> Bool? {
        guard lookback == 200, signalIndex >= lookback - 1, prices.indices.contains(signalIndex) else { return nil }
        let start = signalIndex - lookback + 1
        var sum = 0.0
        for i in start...signalIndex {
            let p = prices[i]
            guard p.isFinite, p > 0 else { return nil }
            sum += p
        }
        let sma = sum / Double(lookback)
        return prices[signalIndex] > sma
    }
}
