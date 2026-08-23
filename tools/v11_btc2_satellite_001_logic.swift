import Foundation

nonisolated enum V11BTC2Satellite001Logic {
    static let coreScale = 0.98
    static let btcWeight = 0.02

    static func overlay(base: [String: Double]) -> [String: Double]? {
        guard coreScale == 0.98, btcWeight == 0.02 else { return nil }
        var out: [String: Double] = [:]
        for (symbol, weight) in base {
            guard weight.isFinite, weight >= 0 else { return nil }
            out[symbol] = weight * coreScale
        }
        out["btc_cny"] = btcWeight
        let gross = out.values.reduce(0,+)
        guard gross <= 1.000000001 else { return nil }
        return out
    }
}
