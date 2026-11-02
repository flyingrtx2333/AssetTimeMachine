import AppKit
import SwiftUI

// Preview sessions share an isolated suite, never the signed-in user's preferences.
enum NativeAssetChangePreferences {
    static let key = "nativeMac.assetChange.colorScheme"
    static let defaults: UserDefaults = AppPreviewSession.isActive
        ? UserDefaults(suiteName: "com.flyingrtx.AssetTimeMachine.change-preview." + UUID().uuidString)!
        : .standard
}

enum NativeAssetChangeColors: String, CaseIterable, Identifiable {
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
    func color(_ change: Double) -> Color { change == 0 ? NativePalette.secondary : (change > 0 ? up : down) }
}

struct NativeAssetChangeDay: Identifiable {
    let date: Date
    let snapshotID: UUID?
    let previousDate: Date?
    let change: Double?
    let isFuture: Bool
    var id: Date { date }
}

struct NativeAssetChangeYear {
    let year: Int
    let days: [NativeAssetChangeDay]
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
        var observations: [Date: NativeAssetChangeDay] = [:]
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
        var result: [NativeAssetChangeDay] = []
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

    func day(week: Int, weekday: Int) -> NativeAssetChangeDay? {
        let index = week * 7 + weekday - leadingDays
        return days.indices.contains(index) ? days[index] : nil
    }
}

struct NativeAssetChangeCalendar: View {
    let summaries: [TimeMachineSnapshotProjection]
    let revision: Int
    let selectedID: UUID?
    let select: (UUID) -> Void
    @AppStorage(NativeAssetChangePreferences.key, store: NativeAssetChangePreferences.defaults)
    private var colorRaw = NativeAssetChangeColors.region.rawValue
    @State private var year = Calendar.current.component(.year, from: Date.now)
    @State private var years = [Calendar.current.component(.year, from: Date.now)]
    @State private var data: NativeAssetChangeYear?
    @State private var hovered: Date?
    private var colors: NativeAssetChangeColors { NativeAssetChangeColors(rawValue: colorRaw) ?? .region }
    private var focused: NativeAssetChangeDay? {
        guard let data else { return nil }
        if let hovered { return data.days.first { $0.date == hovered } }
        return data.days.first { $0.snapshotID != nil && $0.snapshotID == selectedID }
            ?? data.days.last { $0.snapshotID != nil }
    }

    var body: some View {
        Group {
            if let data { calendar(data) }
            else { Color.clear.frame(height: 196) }
        }
        .onAppear(perform: rebuild)
        .onChange(of: revision) { _, _ in rebuild() }
        .onChange(of: year) { _, _ in rebuild() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in rebuild() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in rebuild() }
    }

    private func calendar(_ data: NativeAssetChangeYear) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AppLocalization.string("每日净资产变动")).font(NativeStyle.FontRole.section)
                Spacer()
                Picker(AppLocalization.string("年份"), selection: $year) {
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }.labelsHidden().frame(width: 85)
                Menu {
                    Picker(AppLocalization.string("涨跌配色"), selection: $colorRaw) {
                        ForEach(NativeAssetChangeColors.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } label: { Image(systemName: "paintpalette") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(AppLocalization.string("涨跌配色"))
                    .accessibilityValue(colors.title).help(AppLocalization.string("涨跌配色"))
            }
            GeometryReader { geometry in
                let gap: CGFloat = 3
                let size = min(12, max(3, (geometry.size.width - 26 - gap * CGFloat(data.weeks - 1)) / CGFloat(data.weeks)))
                VStack(alignment: .leading, spacing: 5) {
                    ZStack(alignment: .topLeading) {
                        ForEach(1...12, id: \.self) { month in
                            let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))!
                            let offset = Calendar.current.dateComponents([.day], from: data.days[0].date, to: date).day ?? 0
                            Text(date.formatted(.dateTime.month(.abbreviated).locale(AppLocalization.currentLocale)))
                                .font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                                .offset(x: 26 + CGFloat((offset + data.leadingDays) / 7) * (size + gap))
                        }
                    }.frame(height: 15)
                    HStack(alignment: .top, spacing: 4) {
                        VStack(spacing: gap) {
                            ForEach(0..<7) { weekday in
                                Text(weekdayLabel(weekday)).font(.system(size: 9)).foregroundStyle(NativePalette.secondary)
                                    .frame(width: 22, height: size, alignment: .leading)
                            }
                        }
                        HStack(spacing: gap) {
                            ForEach(0..<data.weeks, id: \.self) { week in
                                VStack(spacing: gap) {
                                    ForEach(0..<7) { weekday in
                                        if let day = data.day(week: week, weekday: weekday) {
                                            cell(day, size: size)
                                        } else { Color.clear.frame(width: size, height: size).accessibilityHidden(true) }
                                    }
                                }
                            }
                        }
                    }
                }
            }.frame(height: 122)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let day = focused {
                        HStack(spacing: 8) {
                            Text(day.date.formatted(date: .numeric, time: .omitted))
                            Text(amount(day)).foregroundStyle(day.change.map(colors.color) ?? NativePalette.secondary)
                        }.monospacedDigit()
                        Text(comparison(day)).foregroundStyle(NativePalette.secondary)
                    } else { Text(AppLocalization.string("无记录")).foregroundStyle(NativePalette.secondary) }
                }.frame(height: 32, alignment: .topLeading).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text("−")
                    ForEach(0..<4) { level in RoundedRectangle(cornerRadius: 2).fill(colors.down.opacity(0.3 + Double(level) * 0.2)).frame(width: 9, height: 9) }
                    Text("+").padding(.leading, 5)
                    ForEach(0..<4) { level in RoundedRectangle(cornerRadius: 2).fill(colors.up.opacity(0.3 + Double(level) * 0.2)).frame(width: 9, height: 9) }
                }.foregroundStyle(NativePalette.secondary).accessibilityHidden(true)
            }.font(NativeStyle.FontRole.caption)
        }
    }

    private func cell(_ day: NativeAssetChangeDay, size: CGFloat) -> some View {
        let selected = day.snapshotID != nil && day.snapshotID == selectedID
        return Button { if let id = day.snapshotID { select(id) } } label: {
            RoundedRectangle(cornerRadius: 2).fill(fill(day))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(selected ? NativePalette.accent : .clear, lineWidth: 1.5))
                .frame(width: size, height: size)
        }.buttonStyle(.plain).disabled(day.snapshotID == nil)
            .onHover { inside in hovered = inside ? day.date : nil }
            .help(day.date.formatted(date: .complete, time: .omitted) + "\n" + amount(day) + "\n" + comparison(day))
            .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
            .accessibilityValue(amount(day) + " " + comparison(day))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func fill(_ day: NativeAssetChangeDay) -> Color {
        guard let change = day.change, change != 0 else {
            return NativePalette.line.opacity(day.isFuture ? 0.15 : (day.snapshotID == nil ? 0.4 : 0.85))
        }
        let ratio = log1p(abs(change)) / max(log1p(data?.maximumChange ?? 0), 0.01)
        let level = min(3, Int(ratio * 4))
        return colors.color(change).opacity(0.3 + Double(level) * 0.2)
    }
    private func amount(_ day: NativeAssetChangeDay) -> String {
        guard day.snapshotID != nil else { return AppLocalization.string("无记录") }
        guard let change = day.change else { return AppLocalization.string("无对比记录") }
        if change == 0 { return change.formatted(.currency(code: "CNY").precision(.fractionLength(2))) }
        return change.formatted(.currency(code: "CNY").precision(.fractionLength(2)).sign(strategy: .always()))
    }
    private func comparison(_ day: NativeAssetChangeDay) -> String {
        guard let previous = day.previousDate, day.change != nil else { return "" }
        return AppLocalization.format("较 %@", previous.formatted(date: .numeric, time: .omitted))
    }
    private func weekdayLabel(_ index: Int) -> String {
        guard index.isMultiple(of: 2), let data else { return "" }
        return Calendar.current.date(byAdding: .day, value: index - data.leadingDays, to: data.days[0].date)!
            .formatted(.dateTime.weekday(.narrow).locale(AppLocalization.currentLocale))
    }
    private func rebuild() {
        let currentYear = Calendar.current.component(.year, from: Date.now)
        years = Array(Set(summaries.map { Calendar.current.component(.year, from: $0.date) }.filter { $0 <= currentYear } + [currentYear, year])).sorted(by: >)
        data = NativeAssetChangeYear(year: year, summaries: summaries)
        hovered = nil
    }
}
