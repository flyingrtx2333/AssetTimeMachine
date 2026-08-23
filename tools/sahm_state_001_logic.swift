import Foundation

nonisolated enum SahmState001Logic {
    struct Point: Equatable {
        let date: String
        let value: Double
    }
    static let trigger = 0.50
    static let reviewDayFloor = 15

    static func monthKey(_ dateKey: String) -> String? {
        guard dateKey.count >= 7 else { return nil }
        return String(dateKey.prefix(7))
    }

    static func dayOfMonth(_ dateKey: String) -> Int? {
        guard dateKey.count >= 10 else { return nil }
        return Int(dateKey.dropFirst(8).prefix(2))
    }

    /// Conservative causal use: at a mid-month review, only observations from a
    /// strictly earlier calendar month are eligible.
    static func latestPriorMonthValue(points: [Point], executionDateKey: String) -> Double? {
        guard let executionMonth = monthKey(executionDateKey) else { return nil }
        var latest: Double?
        for point in points {
            guard point.value.isFinite, let pointMonth = monthKey(point.date) else { continue }
            if pointMonth < executionMonth { latest = point.value } else { break }
        }
        return latest
    }

    static func owner(points: [Point], executionDateKey: String) -> String? {
        guard let value = latestPriorMonthValue(points: points, executionDateKey: executionDateKey) else { return nil }
        return value >= trigger ? "gold_cny" : "nasdaq"
    }

    static func isReviewDate(currentDateKey: String, priorDateKey: String) -> Bool {
        guard let currentMonth = monthKey(currentDateKey),
              let priorMonth = monthKey(priorDateKey),
              let currentDay = dayOfMonth(currentDateKey),
              let priorDay = dayOfMonth(priorDateKey),
              currentDay >= reviewDayFloor else { return false }
        return currentMonth != priorMonth || priorDay < reviewDayFloor
    }
}
