import Foundation

nonisolated enum CboeEquityPutCallExecutionV1Logic {
    struct Point: Equatable {
        let tradeDate: String
        let availableDate: String
        let ratio: Double
    }

    static let stableStartDate = "2012-06-11"
    static let interventionStartDate = "2013-01-01"
    static let usSymbols = ["nasdaq", "sp500"]

    /// Returns true when the latest prior-close Cboe Equity Put/Call ratio is high relative to
    /// its own strictly-prior stable-definition history. `executionDate` is used intentionally:
    /// the prior close's Daily Market Statistics are observable before the next session executes.
    static func highPutCallState(points: [Point], executionDate: String) -> Bool? {
        guard executionDate >= interventionStartDate else { return nil }
        let usable = points.filter {
            $0.tradeDate >= stableStartDate
                && $0.availableDate <= executionDate
                && $0.ratio.isFinite
                && $0.ratio >= 0
        }
        guard usable.count >= 2, let latest = usable.last else { return nil }
        let prior = usable.dropLast().map(\.ratio).sorted()
        guard let threshold = median(prior) else { return nil }
        return latest.ratio > threshold
    }

    static func latestPoint(points: [Point], executionDate: String) -> Point? {
        guard executionDate >= interventionStartDate else { return nil }
        return points.last {
            $0.tradeDate >= stableStartDate
                && $0.availableDate <= executionDate
                && $0.ratio.isFinite
                && $0.ratio >= 0
        }
    }

    static func priorExpandingMedian(points: [Point], executionDate: String) -> Double? {
        guard executionDate >= interventionStartDate else { return nil }
        let usable = points.filter {
            $0.tradeDate >= stableStartDate
                && $0.availableDate <= executionDate
                && $0.ratio.isFinite
                && $0.ratio >= 0
        }
        guard usable.count >= 2 else { return nil }
        return median(usable.dropLast().map(\.ratio).sorted())
    }

    static func hasUSRiskIncrease(priorBase: [String: Double], currentBase: [String: Double]) -> Bool {
        usSymbols.contains { symbol in
            max(currentBase[symbol] ?? 0, 0) > max(priorBase[symbol] ?? 0, 0) + 1e-10
        }
    }

    /// Executes all V11 reductions and non-U.S. changes immediately while postponing only the
    /// positive Nasdaq/S&P increment. The next session may then complete to currentBase.
    static func delayedUSIncreaseTarget(
        priorBase: [String: Double],
        currentBase: [String: Double],
        delay: Bool
    ) -> [String: Double] {
        var target = currentBase.mapValues { max($0, 0) }
        guard delay else { return normalizedIfNeeded(target) }
        for symbol in usSymbols {
            let prior = max(priorBase[symbol] ?? 0, 0)
            let current = max(currentBase[symbol] ?? 0, 0)
            if current > prior {
                target[symbol] = prior
            }
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
