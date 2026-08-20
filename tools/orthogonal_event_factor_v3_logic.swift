import Foundation

nonisolated enum OrthogonalEventFactorV3Logic {
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

    static func isoDay(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static func parsedDay(_ value: String) -> Date? {
        formatter.date(from: value)
    }

    static func latestUsableIndex(
        points: [Point],
        signalDate: String,
        maxStaleDays: Int = 7
    ) -> Int? {
        guard maxStaleDays >= 0, let signal = parsedDay(signalDate) else { return nil }
        var latest: Int?
        for index in points.indices {
            let point = points[index]
            guard point.value.isFinite else { continue }
            if point.date <= signalDate {
                latest = index
            } else {
                break
            }
        }
        guard let index = latest, let observation = parsedDay(points[index].date) else { return nil }
        let staleDays = calendar.dateComponents([.day], from: observation, to: signal).day ?? Int.max
        guard staleDays >= 0, staleDays <= maxStaleDays else { return nil }
        return index
    }

    static func commonRatio(
        numerator: [Point],
        denominator: [Point]
    ) -> [Point] {
        let numeratorByDate = Dictionary(uniqueKeysWithValues: numerator.map { ($0.date, $0.value) })
        let denominatorByDate = Dictionary(uniqueKeysWithValues: denominator.map { ($0.date, $0.value) })
        return Set(numeratorByDate.keys).intersection(denominatorByDate.keys).sorted().compactMap { date in
            guard let lhs = numeratorByDate[date],
                  let rhs = denominatorByDate[date],
                  lhs.isFinite,
                  rhs.isFinite,
                  lhs > 0,
                  rhs > 0 else { return nil }
            return Point(date: date, value: lhs / rhs)
        }
    }

    static func risingRiskOn(
        points: [Point],
        signalDate: String,
        lookbackObservations: Int = 20
    ) -> Bool? {
        guard lookbackObservations > 0,
              let index = latestUsableIndex(points: points, signalDate: signalDate),
              index >= lookbackObservations else { return nil }
        return points[index].value >= points[index - lookbackObservations].value
    }

    static func ratioRiskOn(
        numerator: [Point],
        denominator: [Point],
        signalDate: String,
        lookbackObservations: Int = 20
    ) -> Bool? {
        risingRiskOn(
            points: commonRatio(numerator: numerator, denominator: denominator),
            signalDate: signalDate,
            lookbackObservations: lookbackObservations
        )
    }

    static func isDeRiskEvent(
        priorBase: [String: Double],
        currentBase: [String: Double]
    ) -> Bool {
        let symbols = Set(priorBase.keys).union(currentBase.keys)
        return symbols.contains { symbol in
            (priorBase[symbol] ?? 0) - (currentBase[symbol] ?? 0) > 1e-10
        }
    }

    static func retainedTarget(
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
        let symbols = Set(priorBase.keys).union(currentBase.keys)
        for symbol in symbols {
            let prior = max(priorBase[symbol] ?? 0, 0)
            let current = max(currentBase[symbol] ?? 0, 0)
            let reduction = max(prior - current, 0)
            if reduction > 0 {
                extras[symbol] = reduction * min(retentionFraction, 1)
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
