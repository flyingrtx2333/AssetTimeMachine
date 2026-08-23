import Foundation

nonisolated enum PermanentPortfolio001Logic {
    static let targetWeights: [String: Double] = [
        "spy_tr": 0.25,
        "tlt_tr": 0.25,
        "gold_cny": 0.25
    ]
    static func calendarYear(_ key: String) -> Int? { key.count >= 4 ? Int(key.prefix(4)) : nil }
    static func shouldRebalance(current: String, previous: String?) -> Bool {
        guard let y = calendarYear(current) else { return false }
        guard let previous, let py = calendarYear(previous) else { return true }
        return y != py
    }
}
