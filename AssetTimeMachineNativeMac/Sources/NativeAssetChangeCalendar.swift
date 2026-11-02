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

    private func cell(_ day: AssetChangeDay, size: CGFloat) -> some View {
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
    private func fill(_ day: AssetChangeDay) -> Color {
        guard let change = day.change, change != 0 else {
            return NativePalette.line.opacity(day.isFuture ? 0.15 : (day.snapshotID == nil ? 0.4 : 0.85))
        }
        let ratio = log1p(abs(change)) / max(log1p(data?.maximumChange ?? 0), 0.01)
        let level = min(3, Int(ratio * 4))
        return colors.color(change).opacity(0.3 + Double(level) * 0.2)
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
    private func weekdayLabel(_ index: Int) -> String {
        guard index.isMultiple(of: 2), let data else { return "" }
        return Calendar.current.date(byAdding: .day, value: index - data.leadingDays, to: data.days[0].date)!
            .formatted(.dateTime.weekday(.narrow).locale(AppLocalization.currentLocale))
    }
    private func rebuild() {
        let currentYear = Calendar.current.component(.year, from: Date.now)
        years = Array(Set(summaries.map { Calendar.current.component(.year, from: $0.date) }.filter { $0 <= currentYear } + [currentYear, year])).sorted(by: >)
        data = AssetChangeYear(year: year, summaries: summaries)
        hovered = nil
    }
}
