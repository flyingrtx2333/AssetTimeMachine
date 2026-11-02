import SwiftUI

// Preview sessions share an isolated suite, never the signed-in user's preferences.
enum AssetChangePreferences {
    // Retain the original Mac preference key when sharing the feature with iOS.
    static let key = "nativeMac.assetChange.colorScheme"
    static let defaults: UserDefaults = AppPreviewSession.isActive
        ? UserDefaults(suiteName: "com.flyingrtx.AssetTimeMachine.change-preview." + UUID().uuidString)!
        : .standard
}

enum AssetChangeColorScheme: String, CaseIterable, Identifiable {
    case region, redRise, greenRise
    var id: String { rawValue }
    var title: String {
        switch self {
        case .region: AppLocalization.string("跟随地区")
        case .redRise: AppLocalization.string("红涨绿跌")
        case .greenRise: AppLocalization.string("绿涨红跌")
        }
    }
    func redIsUp(region: String? = Locale.current.region?.identifier) -> Bool {
        switch self {
        case .region: region == "CN"
        case .redRise: true
        case .greenRise: false
        }
    }
    var up: Color { redIsUp() ? AssetTheme.negative : AssetTheme.positive }
    var down: Color { redIsUp() ? AssetTheme.positive : AssetTheme.negative }
    func color(_ change: Double) -> Color { change == 0 ? AssetTheme.textSecondary : (change > 0 ? up : down) }
}

struct AssetChangeDay: Identifiable {
    let date: Date
    let snapshotID: UUID?
    let previousDate: Date?
    let change: Double?
    let isFuture: Bool
    var id: Date { date }
}

struct AssetChangeYear {
    let year: Int
    let days: [AssetChangeDay]
    let leadingDays: Int
    let weeks: Int
    let maximumChange: Double

    init(year: Int, summaries: [TimeMachineSnapshotProjection], today: Date = .now, calendar: Calendar = .current) {
        self.year = year
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(byAdding: .year, value: 1, to: start)!
        let today = calendar.startOfDay(for: today)
        // Multiple snapshots are closing observations of one day, never additive balances.
        let ordered = summaries.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var closing: [Date: TimeMachineSnapshotProjection] = [:]
        for summary in ordered where summary.date < end {
            let day = calendar.startOfDay(for: summary.date)
            if day <= today { closing[day] = summary }
        }
        var observations: [Date: AssetChangeDay] = [:]
        var previous: (date: Date, net: Double)?
        for date in closing.keys.sorted() {
            let summary = closing[date]!
            let net = summary.totalAssets - summary.totalLiabilities
            let raw = previous.map { net - $0.net }
            let change = raw.flatMap { value -> Double? in
                guard value.isFinite else { return nil }
                let rounded = (value * 100).rounded() / 100
                return rounded.isFinite ? (rounded == 0 ? 0 : rounded) : nil
            }
            if date >= start {
                observations[date] = .init(date: date, snapshotID: summary.id,
                    previousDate: previous?.date, change: change, isFuture: false)
            }
            previous = net.isFinite ? (date, net) : nil
        }
        var result: [AssetChangeDay] = []
        var day = start
        while day < end {
            result.append(observations[day] ?? .init(date: day, snapshotID: nil,
                previousDate: nil, change: nil, isFuture: day > today))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        days = result
        leadingDays = (calendar.component(.weekday, from: start) + 5) % 7
        weeks = (leadingDays + result.count + 6) / 7
        maximumChange = result.compactMap(\.change).map(abs).max() ?? 0
    }

    func day(week: Int, weekday: Int) -> AssetChangeDay? {
        let index = week * 7 + weekday - leadingDays
        return days.indices.contains(index) ? days[index] : nil
    }
}

