import AppKit
import SwiftUI

struct NativeAssetChangeCalendar: View {
    let summaries: [TimeMachineSnapshotProjection]
    let revision: Int
    let selectedID: UUID?
    let selectedDate: Date?
    let select: (UUID) -> Void
    @AppStorage(AssetChangePreferences.key, store: AssetChangePreferences.defaults)
    private var colorRaw = AssetChangeColorScheme.region.rawValue
    @State private var data: AssetChangeYear?
    @State private var hovered: Date?
    private var colors: AssetChangeColorScheme { AssetChangeColorScheme(rawValue: colorRaw) ?? .region }
    private var year: Int {
        Calendar.current.component(.year, from: selectedDate ?? summaries.last?.date ?? .now)
    }
    private var focused: AssetChangeDay? {
        guard let data else { return nil }
        if let hovered { return data.day(on: hovered) }
        return selectedID.flatMap { data.day(snapshotID: $0) }
            ?? data.days.last { $0.snapshotID != nil }
    }

    var body: some View {
        Group {
            if let data { calendar(data) }
            else { Color.clear.frame(height: AssetChangeCellPresentation.gridHeight + 42) }
        }
        .onAppear(perform: rebuild)
        .onChange(of: revision) { _, _ in rebuild() }
        .onChange(of: year) { _, _ in rebuild() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in rebuild() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in rebuild() }
    }

    private func calendar(_ data: AssetChangeYear) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: AssetChangeCellPresentation.gap) {
                Color.clear.frame(height: 18)
                ForEach(0..<7) { weekday in
                    Text(weekdayLabel(weekday)).font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                        .frame(width: 22, height: AssetChangeCellPresentation.height, alignment: .leading)
                }
            }.frame(width: 22).accessibilityHidden(true)
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: AssetChangeCellPresentation.gap) {
                        ForEach(0..<data.weeks, id: \.self) { week in
                            VStack(spacing: AssetChangeCellPresentation.gap) {
                                Text(monthLabel(week)).font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                                    .frame(width: AssetChangeCellPresentation.width, height: 18, alignment: .leading)
                                ForEach(0..<7) { weekday in
                                    if let day = data.day(week: week, weekday: weekday) {
                                        NativeAssetChangeCell(day: day, level: data.intensity(for: day.change), colors: colors,
                                            selected: day.snapshotID != nil && day.snapshotID == selectedID,
                                            localeIdentifier: localeIdentifier, select: select, hover: hover).equatable()
                                    } else {
                                        Color.clear.frame(width: AssetChangeCellPresentation.width, height: AssetChangeCellPresentation.height)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }.id(week)
                        }
                    }.padding(.trailing, 12)
                }
                .onAppear { reader.scrollTo(focusedWeek, anchor: .trailing) }
                .onChange(of: data.year) { _, _ in reader.scrollTo(focusedWeek, anchor: .trailing) }
                .onChange(of: focusedWeek) { _, week in reader.scrollTo(week, anchor: .center) }
            }
        }.frame(height: AssetChangeCellPresentation.gridHeight)
    }
    private var focusedWeek: Int {
        let day = selectedID.flatMap { data.day(snapshotID: $0) } ?? data.days.last { $0.snapshotID != nil }
        let offset = Calendar.current.dateComponents([.day], from: data.days[0].date, to: day?.date ?? .now).day ?? 0
        return max(0, min(data.weeks - 1, (offset + data.leadingDays) / 7))
    }
    private func monthLabel(_ week: Int) -> String {
        (0..<7).compactMap { data.day(week: week, weekday: $0) }
            .first { Calendar.current.component(.day, from: $0.date) == 1 }?
            .date.formatted(.dateTime.month(.abbreviated).locale(AppLocalization.currentLocale)) ?? ""
    }
    private func weekdayLabel(_ index: Int) -> String {
        guard index.isMultiple(of: 2) else { return "" }
        return Calendar.current.date(byAdding: .day, value: index - data.leadingDays, to: data.days[0].date)!
            .formatted(.dateTime.weekday(.narrow).locale(AppLocalization.currentLocale))
    }
}

private struct NativeAssetChangeCell: View, Equatable {
    let day: AssetChangeDay
    let level: Int
    let colors: AssetChangeColorScheme
    let selected: Bool
    let localeIdentifier: String
    let select: (UUID) -> Void
    let hover: (Date?) -> Void
    @Environment(\.colorScheme) private var appearance
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.day == rhs.day && lhs.level == rhs.level && lhs.colors == rhs.colors
            && lhs.selected == rhs.selected && lhs.localeIdentifier == rhs.localeIdentifier
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
        let style = AssetChangeCellPresentation.colors(day: day, level: level, scheme: colors, appearance: appearance)
        return RoundedRectangle(cornerRadius: 4).fill(style.background)
            .overlay {
                Text(day.change.map { AssetChangeCellPresentation.text($0, locale: Locale(identifier: localeIdentifier)) }
                     ?? (day.snapshotID != nil ? "—" : ""))
                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(style.foreground).lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal, 4)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? NativePalette.accent : .clear, lineWidth: 2))
            .frame(width: AssetChangeCellPresentation.width, height: AssetChangeCellPresentation.height)
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
