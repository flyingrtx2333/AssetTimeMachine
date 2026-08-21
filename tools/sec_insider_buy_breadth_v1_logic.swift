import Foundation

nonisolated enum SECInsiderBuyBreadthV1Logic {
    struct Point: Equatable {
        let weekStart: String
        let availableDate: String
        let deltaBuyIssuerCount: Double
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

    static func latestRiskOn(
        points: [Point],
        signalDate: String,
        maxStaleDays: Int = 10
    ) -> Bool? {
        guard maxStaleDays >= 0, let signal = parsedDay(signalDate) else { return nil }
        var latest: Point?
        for point in points {
            guard point.deltaBuyIssuerCount.isFinite else { continue }
            if point.availableDate <= signalDate {
                latest = point
            } else {
                break
            }
        }
        guard let point = latest, let available = parsedDay(point.availableDate) else { return nil }
        let staleDays = calendar.dateComponents([.day], from: available, to: signal).day ?? Int.max
        guard staleDays >= 0, staleDays <= maxStaleDays else { return nil }
        return point.deltaBuyIssuerCount > 0
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

    private static func normalizedIfNeeded(_ target: [String: Double]) -> [String: Double] {
        let gross = target.values.reduce(0, +)
        guard gross > 1.0, gross > 0 else { return target }
        return target.mapValues { $0 / gross }
    }
}
