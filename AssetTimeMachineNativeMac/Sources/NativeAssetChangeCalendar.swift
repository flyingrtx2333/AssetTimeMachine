import AppKit
import SwiftUI

struct NativeAssetChangeCalendar: View {
    let summaries: [TimeMachineSnapshotProjection]
    let revision: Int
    let selectedID: UUID?
    let select: (UUID) -> Void
    @AppStorage(AssetChangePreferences.key, store: AssetChangePreferences.defaults)
    private var colorRaw = AssetChangeColorScheme.region.rawValue
    @State private var year = Calendar.current.component(.year, from: Date.now)
    @State private var years = [Calendar.current.component(.year, from: Date.now)]
    @State private var data: AssetChangeYear?
    @State private var hovered: Date?
    private var colors: AssetChangeColorScheme { AssetChangeColorScheme(rawValue: colorRaw) ?? .region }
    private var focused: AssetChangeDay? {
        guard let data else { return nil }
        if let hovered { return data.day(on: hovered) }
        return selectedID.flatMap { data.day(snapshotID: $0) }
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

    private func calendar(_ data: AssetChangeYear) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AppLocalization.string("每日净资产变动")).font(NativeStyle.FontRole.section)
                Spacer()
                Picker(AppLocalization.string("年份"), selection: $year) {
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }.labelsHidden().frame(width: 85)
                Menu {
                    Picker(AppLocalization.string("涨跌配色"), selection: $colorRaw) {
                        ForEach(AssetChangeColorScheme.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } label: { Image(systemName: "paintpalette") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(AppLocalization.string("涨跌配色"))
                    .accessibilityValue(colors.title).help(AppLocalization.string("涨跌配色"))
            }
            NativeAssetChangeGrid(data: data, selectedID: selectedID, colors: colors,
                localeIdentifier: AppLocalization.currentLocale.identifier,
                select: select, hover: { hovered = $0 }).equatable()
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

    private func amount(_ day: AssetChangeDay) -> String {
        guard day.snapshotID != nil else { return AppLocalization.string("无记录") }
        guard let change = day.change else { return AppLocalization.string("无对比记录") }
        if change == 0 { return change.formatted(.currency(code: "CNY").precision(.fractionLength(2))) }
        return change.formatted(.currency(code: "CNY").precision(.fractionLength(2)).sign(strategy: .always()))
    }
    private func comparison(_ day: AssetChangeDay) -> String {
        guard let previous = day.previousDate, day.change != nil else { return "" }
        return AppLocalization.format("较 %@", previous.formatted(date: .numeric, time: .omitted))
    }
    private func rebuild() {
        let currentYear = Calendar.current.component(.year, from: Date.now)
        years = Array(Set(summaries.map { Calendar.current.component(.year, from: $0.date) }.filter { $0 <= currentYear } + [currentYear, year])).sorted(by: >)
        data = AssetChangeYear(year: year, summaries: summaries)
        hovered = nil
    }
}

/// Hover changes only the footer; a new selection updates just the two affected cells.
private struct NativeAssetChangeGrid: View, Equatable {
    let data: AssetChangeYear
    let selectedID: UUID?
    let colors: AssetChangeColorScheme
    let localeIdentifier: String
    let select: (UUID) -> Void
    let hover: (Date?) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data.id == rhs.data.id && lhs.selectedID == rhs.selectedID
            && lhs.colors == rhs.colors && lhs.localeIdentifier == rhs.localeIdentifier
    }
    var body: some View {
            GeometryReader { geometry in
                let gap: CGFloat = 3
                let size = min(12, max(3, (geometry.size.width - 26 - gap * CGFloat(data.weeks - 1)) / CGFloat(data.weeks)))
                VStack(alignment: .leading, spacing: 5) {
                    ZStack(alignment: .topLeading) {
                        ForEach(1...12, id: \.self) { month in
                            let date = Calendar.current.date(from: DateComponents(year: data.year, month: month, day: 1))!
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
                                            NativeAssetChangeCell(day: day, maximumChange: data.maximumChange, colors: colors,
                                                selected: day.snapshotID != nil && day.snapshotID == selectedID,
                                                size: size, localeIdentifier: localeIdentifier, select: select, hover: hover).equatable()
                                        } else { Color.clear.frame(width: size, height: size).accessibilityHidden(true) }
                                    }
                                }
                            }
                        }
                    }
                }
            }.frame(height: 122)
    }
    private func weekdayLabel(_ index: Int) -> String {
        guard index.isMultiple(of: 2) else { return "" }
        return Calendar.current.date(byAdding: .day, value: index - data.leadingDays, to: data.days[0].date)!
            .formatted(.dateTime.weekday(.narrow).locale(AppLocalization.currentLocale))
    }
}

private struct NativeAssetChangeCell: View, Equatable {
    let day: AssetChangeDay
    let maximumChange: Double
    let colors: AssetChangeColorScheme
    let selected: Bool
    let size: CGFloat
    let localeIdentifier: String
    let select: (UUID) -> Void
    let hover: (Date?) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.day == rhs.day && lhs.maximumChange == rhs.maximumChange && lhs.colors == rhs.colors
            && lhs.selected == rhs.selected && lhs.size == rhs.size && lhs.localeIdentifier == rhs.localeIdentifier
    }
    var body: some View {
        let dateText: String = day.date.formatted(date: .complete, time: .omitted)
        let amountText: String = amount
        let comparisonText: String = comparison
        let detailText = amountText + " " + comparisonText
        let tooltip = dateText + "\n" + amountText + "\n" + comparisonText
        return Button { if let id = day.snapshotID { select(id) } } label: { glyph }
            .buttonStyle(.plain).disabled(day.snapshotID == nil)
            .onHover { inside in hover(inside ? day.date : nil) }
            .help(Text(tooltip))
            .accessibilityLabel(Text(dateText))
            .accessibilityValue(Text(detailText))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var glyph: some View {
        RoundedRectangle(cornerRadius: 2).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(selected ? NativePalette.accent : .clear, lineWidth: 1.5))
            .frame(width: size, height: size)
    }
    private var fill: Color {
        guard let change = day.change, change != 0 else {
            return NativePalette.line.opacity(day.isFuture ? 0.15 : (day.snapshotID == nil ? 0.4 : 0.85))
        }
        let ratio = log1p(abs(change)) / max(log1p(maximumChange), 0.01)
        return colors.color(change).opacity(0.3 + Double(min(3, Int(ratio * 4))) * 0.2)
    }
    private var amount: String {
        guard day.snapshotID != nil else { return AppLocalization.string("无记录") }
        guard let change = day.change else { return AppLocalization.string("无对比记录") }
        return change == 0 ? change.formatted(.currency(code: "CNY").precision(.fractionLength(2)))
            : change.formatted(.currency(code: "CNY").precision(.fractionLength(2)).sign(strategy: .always()))
    }
    private var comparison: String {
        guard let previous = day.previousDate, day.change != nil else { return "" }
        return AppLocalization.format("较 %@", previous.formatted(date: .numeric, time: .omitted))
    }
}
