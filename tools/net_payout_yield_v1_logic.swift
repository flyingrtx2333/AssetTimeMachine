import Foundation

nonisolated enum NetPayoutYieldV1Logic {
    struct Point: Equatable {
        let quarter: String
        let availableDate: String
        let netPayoutYield: Double
    }

    static func latestRiskOn(
        points: [Point],
        signalDate: String
    ) -> Bool? {
        let usable = points.filter {
            $0.availableDate <= signalDate && $0.netPayoutYield.isFinite && $0.netPayoutYield > 0
        }
        guard usable.count >= 2, let latest = usable.last else { return nil }
        let prior = usable.dropLast().map(\.netPayoutYield).sorted()
        guard let median = median(prior) else { return nil }
        return latest.netPayoutYield >= median
    }

    static func priorMedian(
        points: [Point],
        signalDate: String
    ) -> Double? {
        let usable = points.filter {
            $0.availableDate <= signalDate && $0.netPayoutYield.isFinite && $0.netPayoutYield > 0
        }
        guard usable.count >= 2 else { return nil }
        return median(usable.dropLast().map(\.netPayoutYield).sorted())
    }

    static func latestPoint(
        points: [Point],
        signalDate: String
    ) -> Point? {
        points.last {
            $0.availableDate <= signalDate && $0.netPayoutYield.isFinite && $0.netPayoutYield > 0
        }
    }

    static func isUSDeRiskEvent(
        priorBase: [String: Double],
        currentBase: [String: Double]
    ) -> Bool {
        ["nasdaq", "sp500"].contains { symbol in
            (priorBase[symbol] ?? 0) - (currentBase[symbol] ?? 0) > 1e-10
        }
    }

    static func retainedUSTarget(
        priorBase: [String: Double],
        currentBase: [String: Double],
        retain: Bool,
        retentionFraction: Double = 0.5
    ) -> [String: Double] {
        var target = currentBase.reduce(into: [String: Double]()) { result, item in
            let weight = max(item.value, 0)
            if weight > 0 { result[item.key] = weight }
        }
        guard retain, retentionFraction > 0 else { return normalizedIfNeeded(target) }

        var extras: [String: Double] = [:]
        for symbol in ["nasdaq", "sp500"] {
            let prior = max(priorBase[symbol] ?? 0, 0)
            let current = max(currentBase[symbol] ?? 0, 0)
            let reduction = max(prior - current, 0)
            if reduction > 0 {
                extras[symbol] = reduction * min(retentionFraction, 1.0)
            }
        }
        let desired = extras.values.reduce(0, +)
        guard desired > 0 else { return normalizedIfNeeded(target) }
        let gross = target.values.reduce(0, +)
        let capacity = max(1.0 - gross, 0)
        guard capacity > 0 else { return normalizedIfNeeded(target) }
        let scale = min(1.0, capacity / desired)
        for (symbol, extra) in extras where extra > 0 {
            target[symbol, default: 0] += extra * scale
        }
        return normalizedIfNeeded(target)
    }

    private static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func normalizedIfNeeded(_ target: [String: Double]) -> [String: Double] {
        let gross = target.values.reduce(0, +)
        guard gross > 1.0, gross > 0 else { return target }
        return target.mapValues { $0 / gross }
    }
}
