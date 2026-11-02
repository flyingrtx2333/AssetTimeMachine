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

struct AssetChangeDay: Identifiable, Equatable {
    let date: Date
    let snapshotID: UUID?
    let previousDate: Date?
    let change: Double?
    let isFuture: Bool
    var id: Date { date }
}

struct AssetChangeYear {
    let id = UUID()
    private let indicesBySnapshot: [UUID: Int]
    let year: Int
    let days: [AssetChangeDay]
    let leadingDays: Int
    let weeks: Int
    let maximumChange: Double
    private let intensityBreaks: [Double]

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
        indicesBySnapshot = Dictionary(result.enumerated().compactMap { index, day in
            day.snapshotID.map { ($0, index) }
        }, uniquingKeysWith: { _, last in last })
        leadingDays = (calendar.component(.weekday, from: start) + 5) % 7
        weeks = (leadingDays + result.count + 6) / 7
        maximumChange = result.compactMap(\.change).map(abs).max() ?? 0
        let magnitudes = Array(Set(result.compactMap(\.change).map(abs).filter { $0 > 0 })).sorted()
        intensityBreaks = magnitudes.count > 1 ? (1...4).map { step in
            let position = Double(magnitudes.count - 1) * Double(step) / 5
            let lower = Int(position)
            let upper = min(lower + 1, magnitudes.count - 1)
            return magnitudes[lower] + (magnitudes[upper] - magnitudes[lower]) * (position - Double(lower))
        } : []
    }

    // Rank distinct magnitudes once, so equal changes stay equal and an outlier cannot wash out the year.
    func intensity(for change: Double?) -> Int {
        guard let change, change.isFinite, change != 0 else { return 0 }
        guard !intensityBreaks.isEmpty else { return 3 }
        return 1 + intensityBreaks.filter { abs(change) > $0 }.count
    }

    func day(snapshotID: UUID) -> AssetChangeDay? {
        indicesBySnapshot[snapshotID].map { days[$0] }
    }

    func day(on date: Date, calendar: Calendar = .current) -> AssetChangeDay? {
        guard calendar.component(.year, from: date) == year,
              let ordinal = calendar.ordinality(of: .day, in: .year, for: date),
              days.indices.contains(ordinal - 1) else { return nil }
        return days[ordinal - 1]
    }

    func day(week: Int, weekday: Int) -> AssetChangeDay? {
        let index = week * 7 + weekday - leadingDays
        return days.indices.contains(index) ? days[index] : nil
    }
}

enum AssetChangeCellPresentation {
    static let width: CGFloat = 56
    static let height: CGFloat = 40
    static let gap: CGFloat = 4
    static let gridHeight: CGFloat = 18 + 7 * (height + gap)

    static func text(_ change: Double, locale: Locale) -> String {
        guard change.isFinite else { return "—" }
        let magnitude = abs(change) < 1e14 ? (abs(change) * 100).rounded() / 100 : abs(change)
        guard magnitude > 0 else { return 0.0.formatted(.number.locale(locale).precision(.fractionLength(2))) }
        let sign = change < 0 ? "−" : "+"
        if magnitude >= 1e16 {
            return sign + magnitude.formatted(.number.locale(locale).notation(.scientific).precision(.fractionLength(0)))
        }
        if magnitude < 100 {
            return sign + magnitude.formatted(.number.locale(locale).precision(.fractionLength(2)))
        }
        let units: [(Double, String)] = locale.language.languageCode?.identifier == "zh"
            ? [(1, ""), (100, AppLocalization.string("百")), (1_000, AppLocalization.string("千")),
               (10_000, AppLocalization.string("万")), (100_000_000, AppLocalization.string("亿")),
               (1_000_000_000_000, AppLocalization.string("兆"))]
            : [(1, ""), (1_000, "K"), (1_000_000, "M"), (1_000_000_000, "B"), (1_000_000_000_000, "T")]
        var index = units.lastIndex { magnitude >= $0.0 } ?? 0
        var value = magnitude / units[index].0
        var digits = index > 0 && value < 10 ? 1 : 0
        var scale = digits == 1 ? 10.0 : 1.0
        var rounded = (value * scale).rounded() / scale
        if index + 1 < units.count, rounded * units[index].0 >= units[index + 1].0 {
            index += 1
            value = magnitude / units[index].0
            digits = value < 10 ? 1 : 0
            scale = digits == 1 ? 10 : 1
            rounded = (value * scale).rounded() / scale
        }
        return sign + rounded.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(0...digits))) + units[index].1
    }

    private static let lightRed: [UInt32] = [0xFCE8E6, 0xF8C7C3, 0xEE9189, 0xC23F3B, 0x8F2429]
    private static let lightGreen: [UInt32] = [0xE6F4EA, 0xB7DFC4, 0x79C695, 0x2A7D46, 0x185C34]
    private static let darkRed: [UInt32] = [0x431F25, 0x722D35, 0xAA3F45, 0xD96B6B, 0xF2A4A1]
    private static let darkGreen: [UInt32] = [0x173627, 0x245F3E, 0x2D8550, 0x54AF76, 0x8DD9A7]

    static func colors(day: AssetChangeDay, level: Int, scheme: AssetChangeColorScheme,
                       appearance: ColorScheme) -> (background: Color, foreground: Color) {
        let dark = appearance == .dark
        guard let change = day.change, change != 0 else {
            let neutral: UInt32 = day.snapshotID != nil ? (dark ? 0x34383C : 0xE3E5E8) : (dark ? 0x1E2228 : 0xF1F2F4)
            return (color(neutral).opacity(day.isFuture ? 0.4 : 1), dark ? .white : color(0x202124))
        }
        let red = change > 0 ? scheme.redIsUp() : !scheme.redIsUp()
        let shades = dark ? (red ? darkRed : darkGreen) : (red ? lightRed : lightGreen)
        let index = max(0, min(4, level - 1))
        let whiteText = dark ? index < 3 : index >= 3
        return (color(shades[index]), whiteText ? .white : color(0x202124))
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
}

