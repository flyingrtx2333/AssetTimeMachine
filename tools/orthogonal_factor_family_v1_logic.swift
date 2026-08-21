import Foundation

nonisolated enum OrthogonalFactorFamilyV1Logic {
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

    static func curveRiskOn(
        points: [Point],
        signalDate: String
    ) -> Bool? {
        guard let index = latestUsableIndex(points: points, signalDate: signalDate) else { return nil }
        return points[index].value > 0
    }

    static func dollarRiskOn(
        points: [Point],
        signalDate: String,
        lookbackObservations: Int = 20
    ) -> Bool? {
        guard lookbackObservations > 0,
              let index = latestUsableIndex(points: points, signalDate: signalDate),
              index >= lookbackObservations else { return nil }
        let current = points[index].value
        let prior = points[index - lookbackObservations].value
        guard current.isFinite, prior.isFinite, current > 0, prior > 0 else { return nil }
        return current <= prior
    }

    static func sizeRiskOn(
        rut: [Point],
        rui: [Point],
        signalDate: String,
        lookbackObservations: Int = 20
    ) -> Bool? {
        guard lookbackObservations > 0 else { return nil }
        let rutByDate = Dictionary(uniqueKeysWithValues: rut.map { ($0.date, $0.value) })
        let ruiByDate = Dictionary(uniqueKeysWithValues: rui.map { ($0.date, $0.value) })
        let common = Set(rutByDate.keys).intersection(ruiByDate.keys).sorted()
        let ratios: [Point] = common.compactMap { date in
            guard let small = rutByDate[date],
                  let large = ruiByDate[date],
                  small.isFinite,
                  large.isFinite,
                  small > 0,
                  large > 0 else { return nil }
            return Point(date: date, value: small / large)
        }
        guard let index = latestUsableIndex(points: ratios, signalDate: signalDate),
              index >= lookbackObservations else { return nil }
        return ratios[index].value >= ratios[index - lookbackObservations].value
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
