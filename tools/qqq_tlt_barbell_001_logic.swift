import Foundation

nonisolated enum QQQTLTBarbell001Logic {
    static func calendarYear(_ dateKey: String) -> Int? {
        guard dateKey.count >= 4 else { return nil }
        return Int(dateKey.prefix(4))
    }

    static func shouldAnnualRebalance(currentDateKey: String, previousDateKey: String?) -> Bool {
        guard let currentYear = calendarYear(currentDateKey) else { return false }
        guard let previousDateKey, let previousYear = calendarYear(previousDateKey) else { return true }
        return currentYear != previousYear
    }

    static let targetWeights: [String: Double] = ["qqq_tr": 0.5, "tlt_tr": 0.5]
}
