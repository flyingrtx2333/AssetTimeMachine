import Foundation

nonisolated enum VRPProxyV1Logic {
    struct Point: Equatable {
        let date: String
        let value: Double
    }

    private static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }()

    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "yyyy-MM-dd"
        return value
    }()

    private static func parsedDay(_ value: String) -> Date? {
        formatter.date(from: value)
    }

    static func latestUsableValue(
        points: [Point],
        signalDate: String,
        maxStaleDays: Int = 7
    ) -> Double? {
        guard maxStaleDays >= 0, let signal = parsedDay(signalDate) else { return nil }
        var latest: Point?
        for point in points {
            guard point.value.isFinite, point.value > 0 else { continue }
            if point.date <= signalDate {
                latest = point
            } else {
                break
            }
        }
        guard let point = latest, let observation = parsedDay(point.date) else { return nil }
        let staleDays = calendar.dateComponents([.day], from: observation, to: signal).day ?? Int.max
        guard staleDays >= 0, staleDays <= maxStaleDays else { return nil }
        return point.value
    }

    static func annualizedRealizedVariance(
        prices: [Double],
        signalIndex: Int,
        lookbackReturns: Int = 21
    ) -> Double? {
        guard lookbackReturns > 0,
              prices.indices.contains(signalIndex),
              signalIndex >= lookbackReturns else { return nil }
        var sumSquares = 0.0
        for index in (signalIndex - lookbackReturns + 1)...signalIndex {
            let current = prices[index]
            let prior = prices[index - 1]
            guard current.isFinite, prior.isFinite, current > 0, prior > 0 else { return nil }
            let value = log(current / prior)
            sumSquares += value * value
        }
        return (252.0 / Double(lookbackReturns)) * sumSquares
    }

    static func vrpProxy(vixPercent: Double, realizedVariance: Double) -> Double? {
        guard vixPercent.isFinite, vixPercent > 0,
              realizedVariance.isFinite, realizedVariance >= 0 else { return nil }
        let impliedVariance = pow(vixPercent / 100.0, 2)
        return impliedVariance - realizedVariance
    }

    static func median(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return nil }
        let middle = finite.count / 2
        if finite.count.isMultiple(of: 2) {
            return (finite[middle - 1] + finite[middle]) / 2.0
        }
        return finite[middle]
    }

    static func completionTarget(
        base: [String: Double],
        factorRiskOn: Bool,
        fillFraction: Double = 0.5
    ) -> [String: Double] {
        var target = base.reduce(into: [String: Double]()) { result, item in
            let weight = max(item.value, 0)
            if weight > 0 { result[item.key] = weight }
        }
        guard factorRiskOn, fillFraction > 0 else { return normalizedIfNeeded(target) }
        let gross = target.values.reduce(0, +)
        guard gross > 0, gross < 1 else { return normalizedIfNeeded(target) }
        let addition = (1.0 - gross) * min(fillFraction, 1.0)
        for (symbol, weight) in target {
            target[symbol] = weight + addition * (weight / gross)
        }
        return normalizedIfNeeded(target)
    }

    private static func normalizedIfNeeded(_ target: [String: Double]) -> [String: Double] {
        let gross = target.values.reduce(0, +)
        guard gross > 1.0, gross > 0 else { return target }
        return target.mapValues { $0 / gross }
    }
}
