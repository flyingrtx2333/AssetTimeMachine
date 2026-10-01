import Foundation

nonisolated enum WeightMath {
    static func normalizedWeightMap(
        _ weights: [String: Double],
        maxTotalExposure: Double = 1
    ) -> [String: Double] {
        var normalized: [String: Double] = [:]
        for symbol in weights.keys.sorted() {
            let value = max(weights[symbol] ?? 0, 0)
            if value > 0.0001 {
                normalized[symbol] = value
            }
        }
        let totalExposure = normalized.keys.sorted().reduce(0.0) { $0 + max(normalized[$1] ?? 0, 0) }
        let cappedMaxTotalExposure = min(max(maxTotalExposure, 0), 1)
        if totalExposure > cappedMaxTotalExposure, totalExposure > 0 {
            let scale = cappedMaxTotalExposure / totalExposure
            for symbol in normalized.keys.sorted() {
                normalized[symbol] = max(normalized[symbol] ?? 0, 0) * scale
            }
        }
        var output: [String: Double] = [:]
        for symbol in normalized.keys.sorted() {
            let value = normalized[symbol] ?? 0
            if value > 0.0001 {
                output[symbol] = value
            }
        }
        return output
    }

    static func positiveWeightSum(_ weights: [String: Double]) -> Double {
        weights.keys.sorted().reduce(0.0) { partial, symbol in
            partial + max(weights[symbol] ?? 0, 0)
        }
    }

    static func absoluteWeightDifference(
        _ lhs: [String: Double],
        _ rhs: [String: Double]
    ) -> Double {
        Set(lhs.keys)
            .union(rhs.keys)
            .sorted()
            .reduce(0.0) { partial, symbol in
                partial + abs((lhs[symbol] ?? 0) - (rhs[symbol] ?? 0))
            }
    }

    static func scaledWeightMap(_ weights: [String: Double], by scale: Double) -> [String: Double] {
        var output: [String: Double] = [:]
        for symbol in weights.keys.sorted() {
            output[symbol] = (weights[symbol] ?? 0) * scale
        }
        return output
    }

    static func clampedScaledWeightMap(_ weights: [String: Double], by scale: Double) -> [String: Double] {
        var output: [String: Double] = [:]
        for symbol in weights.keys.sorted() {
            output[symbol] = max(weights[symbol] ?? 0, 0) * scale
        }
        return output
    }

    static func blendedWeightMap(
        _ first: [String: Double],
        _ second: [String: Double],
        firstShare: Double
    ) -> [String: Double] {
        let normalizedFirstShare = min(max(firstShare, 0), 1)
        var output: [String: Double] = [:]
        for symbol in first.keys.sorted() {
            output[symbol, default: 0] += max(first[symbol] ?? 0, 0) * normalizedFirstShare
        }
        for symbol in second.keys.sorted() {
            output[symbol, default: 0] += max(second[symbol] ?? 0, 0) * (1 - normalizedFirstShare)
        }
        return normalizedWeightMap(output)
    }

    static func overlayTotalWeight(_ weights: [String: Double]) -> Double {
        positiveWeightSum(weights)
    }
}
