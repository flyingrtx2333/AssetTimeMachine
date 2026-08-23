import Foundation

nonisolated enum USTurnMonth001Logic {
    /// Returns the execution-date keys on whose closes the strategy must hold equity
    /// into the next real trading session in order to capture the canonical four
    /// turn-of-month close-to-close return days: the last trading day of month M and
    /// the first three trading days of month M+1.
    ///
    /// Thus the active post-close dates are: the penultimate trading day of M, the
    /// last trading day of M, and the first two trading days of M+1. The position is
    /// closed at the third trading day close of M+1.
    static func activeExecutionDates(tradingDates rawDates: [String]) -> Set<String> {
        let dates = Array(Set(rawDates.filter { $0.count >= 10 })).sorted()
        guard dates.count >= 6 else { return [] }

        var byMonth: [String: [String]] = [:]
        for date in dates {
            let month = String(date.prefix(7))
            byMonth[month, default: []].append(date)
        }
        let months = byMonth.keys.sorted()
        var active: Set<String> = []
        guard months.count >= 2 else { return active }

        for index in 0..<(months.count - 1) {
            let current = byMonth[months[index]] ?? []
            let next = byMonth[months[index + 1]] ?? []
            guard current.count >= 2, next.count >= 3 else { continue }
            active.insert(current[current.count - 2])
            active.insert(current[current.count - 1])
            active.insert(next[0])
            active.insert(next[1])
        }
        return active
    }
}
