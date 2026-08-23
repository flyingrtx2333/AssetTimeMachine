import Foundation

nonisolated enum VolatilitySwitch001Logic {
    static let shortWindow = 21
    static let longWindow = 252

    static func sampleVolatility(prices: [Double], endingAt index: Int, returns: Int) -> Double? {
        guard returns >= 2, index >= returns, prices.indices.contains(index) else { return nil }
        var values: [Double] = []
        values.reserveCapacity(returns)
        for i in (index - returns + 1)...index {
            let previous = prices[i - 1]
            let current = prices[i]
            guard previous.isFinite, current.isFinite, previous > 0, current > 0 else { return nil }
            values.append(current / previous - 1.0)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        let vol = sqrt(max(variance, 0))
        return vol.isFinite ? vol : nil
    }

    /// Low/normal Nasdaq realized-vol regime owns Nasdaq; a short-vol spike above
    /// its own 252-session baseline owns gold. All inputs end at signalIndex (T-1).
    static func owner(nasdaqPrices: [Double], signalIndex: Int) -> String? {
        guard let shortVol = sampleVolatility(prices: nasdaqPrices, endingAt: signalIndex, returns: shortWindow),
              let longVol = sampleVolatility(prices: nasdaqPrices, endingAt: signalIndex, returns: longWindow),
              longVol > 0 else { return nil }
        return shortVol > longVol ? "gold_cny" : "nasdaq"
    }
}
