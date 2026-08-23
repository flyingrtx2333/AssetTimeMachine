import Foundation

nonisolated enum BTCHalving001Logic {
    static let halvingDates = ["2012-11-28", "2016-07-09", "2020-05-11", "2024-04-20"]

    static func active(executionDateKey: String, holdingCalendarDays: Int = 365) -> Bool? {
        guard holdingCalendarDays == 365 else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        guard let execution = f.date(from: executionDateKey) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        for key in halvingDates.reversed() {
            guard let event = f.date(from: key) else { continue }
            if execution <= event { continue }
            guard let end = calendar.date(byAdding: .day, value: holdingCalendarDays, to: event) else { continue }
            return execution <= end
        }
        return false
    }
}
