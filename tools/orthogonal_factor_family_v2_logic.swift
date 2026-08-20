import Foundation

nonisolated enum OrthogonalFactorFamilyV2Logic {
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
        guard maxStaleDays >= 0,
              let signal = parsedDay(signalDate) else { return nil }
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
        guard let index = latest,
              let observation = parsedDay(points[index].date) else { return nil }
        let staleDays = calendar.dateComponents([.day], from: observation, to: signal).day ?? Int.max
        guard staleDays >= 0, staleDays <= maxStaleDays else { return nil }
        return index
    }

    static func commonDerived(
        left: [Point],
        right: [Point],
        transform: (Double, Double) -> Double?
    ) -> [Point] {
        let leftByDate = Dictionary(uniqueKeysWithValues: left.map { ($0.date, $0.value) })
        let rightByDate = Dictionary(uniqueKeysWithValues: right.map { ($0.date, $0.value) })
        return Set(leftByDate.keys).intersection(rightByDate.keys).sorted().compactMap { date in
            guard let lhs = leftByDate[date],
                  let rhs = rightByDate[date],
                  lhs.isFinite,
                  rhs.isFinite,
                  let value = transform(lhs, rhs),
                  value.isFinite else { return nil }
            return Point(date: date, value: value)
        }
    }

    static func fundingRiskOn(
        commercialPaper: [Point],
        fedFunds: [Point],
        signalDate: String,
        lookbackObservations: Int = 20
    ) -> Bool? {
        guard lookbackObservations > 0 else { return nil }
        let spread = commonDerived(left: commercialPaper, right: fedFunds) { cp, ff in
            cp - ff
        }
        guard let index = latestUsableIndex(points: spread, signalDate: signalDate),
              index >= lookbackObservations else { return nil }
        return spread[index].value <= spread[index - lookbackObservations].value
    }

    static func copperGoldRiskOn(
        copper: [Point],
        gold: [Point],
        signalDate: String,
        lookbackObservations: Int = 20
    ) -> Bool? {
        guard lookbackObservations > 0 else { return nil }
        let ratio = commonDerived(left: copper, right: gold) { copperPrice, goldPrice in
            guard copperPrice > 0, goldPrice > 0 else { return nil }
            return copperPrice / goldPrice
        }
        guard let index = latestUsableIndex(points: ratio, signalDate: signalDate),
              index >= lookbackObservations else { return nil }
        return ratio[index].value >= ratio[index - lookbackObservations].value
    }

    static func skewRiskOn(
        points: [Point],
        signalDate: String,
        lookbackObservations: Int = 20
    ) -> Bool? {
        guard lookbackObservations > 0,
              let index = latestUsableIndex(points: points, signalDate: signalDate),
              index >= lookbackObservations else { return nil }
        return points[index].value <= points[index - lookbackObservations].value
    }

    static func completedRiskBudget(
        baseTarget: [String: Double],
        riskOn: Bool
    ) -> [String: Double] {
        let sanitized = baseTarget.reduce(into: [String: Double]()) { result, item in
            let weight = max(item.value, 0)
            if weight > 0 {
                result[item.key] = weight
            }
        }
        let gross = sanitized.values.reduce(0, +)
        guard riskOn, gross > 0, gross < 1 else { return sanitized }
        return sanitized.mapValues { $0 / gross }
    }
}
