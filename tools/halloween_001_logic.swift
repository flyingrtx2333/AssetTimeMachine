import Foundation

nonisolated enum Halloween001Logic {
    static func calendarMonth(_ dateKey: String) -> Int? {
        guard dateKey.count >= 7 else { return nil }
        let start = dateKey.index(dateKey.startIndex, offsetBy: 5)
        let end = dateKey.index(start, offsetBy: 2)
        return Int(dateKey[start..<end])
    }

    /// Fixed Halloween state: equity from November through April, cash from May through October.
    static func equityActive(executionDateKey: String) -> Bool? {
        guard let month = calendarMonth(executionDateKey), (1...12).contains(month) else { return nil }
        return month >= 11 || month <= 4
    }
}
