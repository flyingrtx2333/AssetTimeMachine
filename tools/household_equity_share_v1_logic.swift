import Foundation

nonisolated enum HouseholdEquityShareV1Logic {
    struct Point: Equatable {
        let quarter: String
        let availableDate: String
        let householdEquityShare: Double
    }

    static let stableStartQuarter = "2016Q3"

    static func latestRiskOn(
        points: [Point],
        signalDate: String
    ) -> Bool? {
        let usable = stableUsable(points: points, signalDate: signalDate)
        guard usable.count >= 2, let latest = usable.last else { return nil }
        guard let priorMedian = median(usable.dropLast().map(\.householdEquityShare).sorted()) else {
            return nil
        }
        // Yang-Zhang: a lower household equity share predicts higher future U.S. equity returns.
        return latest.householdEquityShare <= priorMedian
    }

    static func latestPoint(
        points: [Point],
        signalDate: String
    ) -> Point? {
        stableUsable(points: points, signalDate: signalDate).last
    }

    static func priorMedian(
        points: [Point],
        signalDate: String
    ) -> Double? {
        let usable = stableUsable(points: points, signalDate: signalDate)
        guard usable.count >= 2 else { return nil }
        return median(usable.dropLast().map(\.householdEquityShare).sorted())
    }

    static func isEligibleUnderinvestedEvent(
        baseTarget: [String: Double]
    ) -> Bool {
        let sanitized = baseTarget.mapValues { max($0, 0) }
        let gross = sanitized.values.reduce(0, +)
        let usGross = max(sanitized["nasdaq"] ?? 0, 0) + max(sanitized["sp500"] ?? 0, 0)
        return gross > 0 && gross < 1.0 - 1e-10 && usGross > 1e-10
    }

    static func completedUSRiskBudget(
        baseTarget: [String: Double],
        riskOn: Bool
    ) -> [String: Double] {
        var target = baseTarget.reduce(into: [String: Double]()) { result, item in
            let weight = max(item.value, 0)
            if weight > 0 { result[item.key] = weight }
        }
        let gross = target.values.reduce(0, +)
        guard riskOn, gross > 0, gross < 1.0 else { return normalizedIfNeeded(target) }

        let usSymbols = ["nasdaq", "sp500"]
        let usGross = usSymbols.reduce(0.0) { $0 + max(target[$1] ?? 0, 0) }
        guard usGross > 0 else { return normalizedIfNeeded(target) }

        let capacity = max(1.0 - gross, 0)
        guard capacity > 0 else { return normalizedIfNeeded(target) }
        for symbol in usSymbols {
            let current = max(target[symbol] ?? 0, 0)
            guard current > 0 else { continue }
            target[symbol, default: 0] += capacity * current / usGross
        }
        return normalizedIfNeeded(target)
    }

    private static func stableUsable(
        points: [Point],
        signalDate: String
    ) -> [Point] {
        points.filter {
            $0.quarter >= stableStartQuarter
                && $0.availableDate <= signalDate
                && $0.householdEquityShare.isFinite
                && $0.householdEquityShare > 0
                && $0.householdEquityShare < 1
        }
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
