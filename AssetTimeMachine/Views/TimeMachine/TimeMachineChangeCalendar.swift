import SwiftUI
import UIKit
import Combine

/// Recorded closing balances, independent of the trend chart's display range and live prices.
struct TimeMachineChangeCalendar: View {
    let summaries: [TimeMachineSnapshotProjection]
    let revision: Int
    let selection: TimeMachineSelection
    private var selectedDate: Date? {
        get { selection.date }
        nonmutating set { selection.select(newValue) }
    }
    let amountsVisible: Bool
    let onOpenRecord: (UUID) -> Void
    @AppStorage(AssetChangePreferences.key, store: AssetChangePreferences.defaults)
    private var colorRaw = AssetChangeColorScheme.region.rawValue
    @State private var data: AssetChangeYear?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let cellHeight = AssetChangeCellPresentation.height
    private let gap = AssetChangeCellPresentation.gap
    private var colors: AssetChangeColorScheme { AssetChangeColorScheme(rawValue: colorRaw) ?? .region }
    private var year: Int {
        Calendar.current.component(.year, from: selectedDate ?? summaries.last?.date ?? .now)
    }
    private var focused: AssetChangeDay? {
        guard let data else { return nil }
        return selectedDate.flatMap { data.day(on: $0) }
            ?? data.days.last { $0.snapshotID != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let data {
                grid(data).dynamicTypeSize(...DynamicTypeSize.large)
                detail
            }
        }
        .onAppear(perform: rebuild)
        .onChange(of: revision) { _, _ in rebuild() }
        .onChange(of: summaries.count) { _, _ in rebuild() }
        .onChange(of: year) { _, _ in rebuild() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in rebuild() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in rebuild() }
    }

    private func grid(_ data: AssetChangeYear) -> some View {
        let focusedDate = selectedDate.map { Calendar.current.startOfDay(for: $0) }
        return GeometryReader { geometry in
            let cellWidth = AssetChangeCellPresentation.cellWidth(for: geometry.size.width - 28)
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: gap) {
                    Color.clear.frame(height: 18)
                    ForEach(0..<7) { weekday in
                        Text(weekday.isMultiple(of: 2) ? weekdayLabel(weekday, data: data) : "")
                            .font(.caption2).foregroundStyle(AssetTheme.textSecondary)
                            .frame(width: 22, height: cellHeight)
                    }
                }.frame(width: 22).accessibilityHidden(true)
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // At most 54 weeks; exact offsets keep edge amounts complete.
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(0..<data.weeks, id: \.self) { week in
                                VStack(spacing: gap) {
                                    TimeMachineChangeMonthLabel(data: data, week: week, localeIdentifier: AppLocalization.currentLocale.identifier).equatable()
                                        .font(.caption2).foregroundStyle(AssetTheme.textSecondary)
                                        .fixedSize().frame(width: cellWidth, height: 18, alignment: .leading)
                                    ForEach(0..<7) { weekday in
                                        if let day = data.day(week: week, weekday: weekday) { TimeMachineChangeDayCell(revision: data.id, day: day, level: data.intensity(for: day.change), width: cellWidth,
                                                colors: colors, selected: focusedDate == day.date,
                                                amountsVisible: amountsVisible, localeIdentifier: AppLocalization.currentLocale.identifier) { id in
                                                selectedDate = summaries.first { $0.id == id }?.date
                                            }.equatable() }
                                        else { Color.clear.frame(width: cellWidth, height: cellHeight).accessibilityHidden(true) }
                                    }
                                }.frame(width: cellWidth).id(week)
                            }
                        }.scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, 0, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .onAppear { reader.scrollTo(focusedWeek(data), anchor: .trailing) }
                    .onChange(of: data.year) { _, _ in reader.scrollTo(focusedWeek(data), anchor: .trailing) }
                    .onChange(of: focusedWeek(data)) { _, week in reader.scrollTo(week, anchor: .trailing) }
                    .onChange(of: cellWidth) { _, _ in reader.scrollTo(focusedWeek(data), anchor: .trailing) }
                }
            }
        }.frame(height: AssetChangeCellPresentation.gridHeight)
    }

    private var detail: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                if let day = focused {
                    Text(day.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline).foregroundStyle(AssetTheme.textSecondary)
                    Text(amount(day)).font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(amountsVisible ? day.change.map(colors.color) ?? AssetTheme.textPrimary : AssetTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.65)
                    if let previous = day.previousDate, day.change != nil {
                        Text(AppLocalization.format("较 %@", previous.formatted(date: .numeric, time: .omitted)))
                            .font(.caption).foregroundStyle(AssetTheme.textSecondary)
                    }
                } else {
                    Text(AppLocalization.string("无记录")).foregroundStyle(AssetTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if let id = focused?.snapshotID {
                Button { onOpenRecord(id) } label: {
                    Label(AppLocalization.string("记录"), systemImage: "arrow.up.right")
                        .font(.subheadline).padding(.vertical, 10)
                }.tint(AssetTheme.gold)
            }
        }.frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 110 : 80, alignment: .top)
    }
    private func amount(_ day: AssetChangeDay) -> String {
        guard amountsVisible else { return "••••" }
        guard day.snapshotID != nil else { return AppLocalization.string("无记录") }
        guard let change = day.change else { return AppLocalization.string("无对比记录") }
        return change == 0
            ? change.formatted(.currency(code: "CNY").precision(.fractionLength(2)))
            : change.formatted(.currency(code: "CNY").precision(.fractionLength(2)).sign(strategy: .always()))
    }
    private func weekdayLabel(_ weekday: Int, data: AssetChangeYear) -> String {
        Calendar.current.date(byAdding: .day, value: weekday - data.leadingDays, to: data.days[0].date)!
            .formatted(.dateTime.weekday(.narrow).locale(AppLocalization.currentLocale))
    }
    private func focusedWeek(_ data: AssetChangeYear) -> Int {
        let target = focused?.date ?? Calendar.current.startOfDay(for: .now)
        let offset = Calendar.current.dateComponents([.day], from: data.days[0].date, to: target).day ?? 0
        return max(0, min(data.weeks - 1, (offset + data.leadingDays) / 7))
    }
    private func rebuild() {
        data = AssetChangeYear(year: year, summaries: summaries)
    }
}

/// Only the previous and new selection rebuild their date/amount accessibility text.
private struct TimeMachineChangeDayCell: View, Equatable {
    let revision: UUID
    let day: AssetChangeDay
    let level: Int
    let width: CGFloat
    let colors: AssetChangeColorScheme
    let selected: Bool
    let amountsVisible: Bool
    let localeIdentifier: String
    let select: (UUID) -> Void
    @Environment(\.colorScheme) private var appearance
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision && lhs.day == rhs.day && lhs.level == rhs.level && lhs.width == rhs.width && lhs.colors == rhs.colors
            && lhs.selected == rhs.selected && lhs.amountsVisible == rhs.amountsVisible
            && lhs.localeIdentifier == rhs.localeIdentifier
    }
    var body: some View {
        let style = AssetChangeCellPresentation.colors(day: day, level: level, scheme: colors, appearance: appearance)
        Button { if let id = day.snapshotID { select(id) } } label: {
            RoundedRectangle(cornerRadius: 4).fill(style.background)
                .overlay {
                    Text(cellText).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(style.foreground).lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 4)
                }
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? AssetTheme.gold : .clear, lineWidth: 2))
                .frame(width: width, height: AssetChangeCellPresentation.height)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(day.snapshotID == nil)
            .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
            .accessibilityValue(amount(day))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var cellText: String {
        guard day.snapshotID != nil else { return "" }
        guard amountsVisible else { return "•••" }
        return day.change.map { AssetChangeCellPresentation.text($0, locale: Locale(identifier: localeIdentifier)) } ?? "—"
    }
    private func amount(_ day: AssetChangeDay) -> String {
        guard amountsVisible else { return "••••" }
        guard day.snapshotID != nil else { return AppLocalization.string("无记录") }
        guard let change = day.change else { return AppLocalization.string("无对比记录") }
        return change == 0 ? change.formatted(.currency(code: "CNY").precision(.fractionLength(2)))
            : change.formatted(.currency(code: "CNY").precision(.fractionLength(2)).sign(strategy: .always()))
    }
}

private struct TimeMachineChangeMonthLabel: View, Equatable {
    let data: AssetChangeYear
    let week: Int
    let localeIdentifier: String
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data.id == rhs.data.id && lhs.week == rhs.week && lhs.localeIdentifier == rhs.localeIdentifier
    }
    var body: some View { Text(monthLabel(week, data: data)) }
    private func monthLabel(_ week: Int, data: AssetChangeYear) -> String {
        let first = (0..<7).compactMap { data.day(week: week, weekday: $0) }.first {
            Calendar.current.component(.day, from: $0.date) == 1
        }
        return first?.date.formatted(.dateTime.month(.abbreviated).locale(AppLocalization.currentLocale)) ?? ""
    }
}
