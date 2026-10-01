#if targetEnvironment(macCatalyst)
import SwiftUI
import SwiftData
import Charts

/// A desktop history browser: one shared time axis above the selected day's ledger.
struct MacTimeMachineContent: View {
    @Environment(\.modelContext) private var modelContext

    let points: [TimeMachineTrendPoint]
    let snapshotIDByDay: [Date: UUID]
    let cacheToken: Int
    @Binding var selectedRange: TimeMachineRange
    @Binding var amountsVisible: Bool
    let onGenerateVideo: () -> Void

    @State private var selectedDate: Date?
    @State private var hoveredDate: Date?
    @State private var snapshot: AssetSnapshot?
    @State private var previousSnapshot: AssetSnapshot?
    @State private var chartPoints: [TimeMachineTrendPoint] = []
    @State private var chartValueDomain: ClosedRange<Double> = 0...1
    #if DEBUG
    @State private var didRunInteractionProbe = false
    #endif
    @State private var interactionProbe: MacTimeMachineInteractionProbe?

    private var selectedIndex: Int? {
        guard !points.isEmpty else { return nil }
        let date = selectedDate ?? points.last!.date
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if points[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        if lower == 0 { return 0 }
        if lower == points.count { return points.count - 1 }
        let previousDistance = abs(points[lower - 1].date.timeIntervalSince(date))
        let nextDistance = abs(points[lower].date.timeIntervalSince(date))
        return previousDistance <= nextDistance ? lower - 1 : lower
    }

    private var selectedPoint: TimeMachineTrendPoint? {
        guard let selectedIndex else { return nil }
        return points[selectedIndex]
    }

    private var previousPoint: TimeMachineTrendPoint? {
        guard let selectedIndex, selectedIndex > 0 else { return nil }
        return points[selectedIndex - 1]
    }

    private var visibleDatePoints: ArraySlice<TimeMachineTrendPoint> {
        guard let selectedIndex else { return [] }
        let lower = max(0, selectedIndex - 18)
        let upper = min(points.count, selectedIndex + 19)
        return points[lower..<upper]
    }

    private var previewPoint: TimeMachineTrendPoint? {
        guard let hoveredDate else { return selectedPoint }
        return nearestChartPoint(points, to: hoveredDate, date: \.date) ?? selectedPoint
    }

    private var selectedSnapshotID: UUID? { snapshotID(for: selectedPoint) }
    private var previousSnapshotID: UUID? { snapshotID(for: previousPoint) }

    private var chartDomain: ClosedRange<Date> {
        let first = points.first?.date ?? .now
        let last = points.last?.date ?? first
        return first < last ? first...last : first.addingTimeInterval(-86_400)...last.addingTimeInterval(86_400)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 10) {
                header
                summary
                chartCard
                    .frame(height: min(270, max(155, geometry.size.height * 0.29)))
                dateStrip
                HStack(alignment: .top, spacing: 10) {
                    ledger
                        .frame(maxWidth: .infinity)
                    dayReport
                        .frame(width: max(245, geometry.size.width * 0.34))
                }
                .frame(maxHeight: .infinity)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if selectedDate == nil { selectedDate = points.last?.date }
            updateChartCache()
            loadSnapshots()
        }
        .onChange(of: cacheToken) { _, _ in
            updateChartCache()
            loadSnapshots()
        }
        .onChange(of: selectedPoint?.date) { _, _ in loadSnapshots() }
        .onChange(of: points.last?.date) { _, latest in
            if selectedDate == nil { selectedDate = latest }
        }
        #if DEBUG
        .task(id: cacheToken) { await runInteractionProbeIfRequested() }
        #endif
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AppLocalization.string("时光机"))
                    .font(.system(size: 20, weight: .semibold))
                Text(AppLocalization.string("回顾历史，查看资产变迁"))
                    .font(.system(size: 10))
                    .foregroundStyle(AssetTheme.textSecondary)
            }
            Spacer(minLength: 8)
            TimeMachineRangeSelector(selectedRange: $selectedRange)
            Button(action: onGenerateVideo) {
                Label(AppLocalization.string("生成视频"), systemImage: "play.rectangle")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 27)
            }
            .buttonStyle(.plain)
            .background(AssetTheme.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(AssetTheme.border))
            .disabled(points.count < 2)
            Button { amountsVisible.toggle() } label: {
                Image(systemName: amountsVisible ? "eye" : "eye.slash")
                    .font(.system(size: 12))
                    .frame(width: 29, height: 27)
            }
            .buttonStyle(.plain)
            .background(AssetTheme.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(AssetTheme.border))
            .accessibilityLabel(AppLocalization.string(amountsVisible ? "隐藏资产金额" : "显示资产金额"))
        }
        .frame(height: 40)
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 0) {
            summaryCell("选中日期", value: previewPoint?.date.formatted(date: .abbreviated, time: .omitted) ?? "—", width: 138)
            Divider().frame(height: 39)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(AppLocalization.string("净资产"))
                    if hoveredDate != nil { Text(AppLocalization.string("预览")).foregroundStyle(AssetTheme.gold) }
                }
                .font(.system(size: 10))
                .foregroundStyle(AssetTheme.textSecondary)
                Text(amount(previewPoint?.netAssets))
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(AssetTheme.goldSoft)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().frame(height: 39)
            summaryCell("总资产", value: amount(previewPoint?.mainAssets), width: 110)
            Divider().frame(height: 39)
            summaryCell("总负债", value: amount(previewPoint?.liabilities), width: 105)
            Divider().frame(height: 39)
            let change = selectedPoint.flatMap { selected in previousPoint.map { selected.netAssets - $0.netAssets } }
            VStack(alignment: .leading, spacing: 5) {
                Text(AppLocalization.string("较上次变化"))
                    .font(.system(size: 10))
                    .foregroundStyle(AssetTheme.textSecondary)
                Text(change.map { signedAmount($0) } ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle((change ?? 0) < 0 ? AssetTheme.negative : AssetTheme.positive)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 105, alignment: .leading)
            .padding(.leading, 12)
        }
        .padding(.horizontal, 12)
        .frame(height: 67)
        .background(AssetTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AssetTheme.border))
    }

    private func summaryCell(_ title: String, value: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(AppLocalization.string(title))
                .font(.system(size: 10))
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: width, alignment: .leading)
        .padding(.leading, 12)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(AppLocalization.string("资产走势"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                legend("总资产", color: AssetTheme.goldSoft)
                legend("净资产", color: AssetTheme.positive)
            }
            if amountsVisible && !points.isEmpty {
                MacTimeMachinePlot(
                    fullPoints: points,
                    sampledPoints: chartPoints,
                    valueDomain: chartValueDomain,
                    previewPoint: previewPoint,
                    hoveredDate: $hoveredDate,
                    interactionProbe: interactionProbe,
                    onSelect: select
                )
            } else {
                ContentUnavailableView(AppLocalization.string(amountsVisible ? "暂无历史记录" : "资产金额已隐藏"), systemImage: amountsVisible ? "chart.xyaxis.line" : "eye.slash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(AppLocalization.string("移动鼠标预览，单击固定日期"))
                .font(.system(size: 9))
                .foregroundStyle(AssetTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .background(AssetTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AssetTheme.border))
    }

    private var dateStrip: some View {
        HStack(spacing: 4) {
            Button { moveSelection(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 34) }
                .disabled((selectedIndex ?? 0) <= 0)
            Divider().frame(height: 22)
            if let first = points.first?.date, let last = points.last?.date {
                DatePicker(
                    AppLocalization.string("日期"),
                    selection: Binding(
                        get: { selectedPoint?.date ?? last },
                        set: { select($0) }
                    ),
                    in: first...last,
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .frame(width: 115)
                Divider().frame(height: 22)
            }
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 2) {
                        ForEach(visibleDatePoints) { point in
                            let isSelected = Calendar.current.isDate(point.date, inSameDayAs: selectedPoint?.date ?? .distantPast)
                            Button { select(point.date) } label: {
                                VStack(spacing: 1) {
                                    Circle()
                                        .fill(isSelected ? AssetTheme.gold : AssetTheme.textSecondary.opacity(0.6))
                                        .frame(width: 3, height: 3)
                                    Text(point.date.formatted(.dateTime.day()))
                                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                        .monospacedDigit()
                                }
                                .foregroundStyle(isSelected ? AssetTheme.gold : AssetTheme.textSecondary)
                                .frame(width: 38, height: 34)
                                .background(isSelected ? AssetTheme.gold.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                let date = hovering ? point.date : nil
                                if hoveredDate != date { hoveredDate = date }
                            }
                            .help(point.date.formatted(date: .complete, time: .omitted))
                            .id(point.date)
                        }
                    }
                }
                .onAppear { if let date = selectedPoint?.date { scrollProxy.scrollTo(date, anchor: .trailing) } }
                .onChange(of: selectedPoint?.date) { _, date in
                    guard let date else { return }
                    withAnimation(.easeOut(duration: 0.2)) { scrollProxy.scrollTo(date, anchor: .center) }
                }
            }
            Divider().frame(height: 22)
            Button { moveSelection(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 34) }
                .disabled((selectedIndex ?? 0) >= points.count - 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .frame(height: 42)
        .background(AssetTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AssetTheme.border))
        .accessibilityLabel(AppLocalization.string("历史日期"))
    }

    private var ledger: some View {
        MacTimeMachineLedger(snapshot: snapshot, previousSnapshot: previousSnapshot, point: selectedPoint, amountsVisible: amountsVisible)
    }

    private var dayReport: some View {
        MacTimeMachineDayReport(snapshot: snapshot, previousSnapshot: previousSnapshot, point: selectedPoint, previousPoint: previousPoint, amountsVisible: amountsVisible)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(AppLocalization.string(title)).font(.system(size: 10)).foregroundStyle(AssetTheme.textSecondary)
        }
    }

    private func amount(_ value: Double?) -> String {
        amountsVisible ? (value?.currencyString() ?? "—") : "••••••"
    }

    private func signedAmount(_ value: Double) -> String {
        guard amountsVisible else { return "••••••" }
        return (value >= 0 ? "+" : "−") + abs(value).currencyString()
    }

    private func snapshotID(for point: TimeMachineTrendPoint?) -> UUID? {
        guard let point else { return nil }
        return snapshotIDByDay[Calendar.current.startOfDay(for: point.date)]
    }

    private func loadSnapshots() {
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        snapshot = fetchSnapshot(selectedSnapshotID)
        previousSnapshot = fetchSnapshot(previousSnapshotID)
        #if DEBUG
        interactionProbe?.recordSelection(milliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1000)
        #endif
    }

    private func updateChartCache() {
        chartPoints = MacTimeMachineSampling.extremaPreserving(points, maxCount: 600)
        #if DEBUG
        if AppPreviewSession.isActive {
            precondition(MacTimeMachineSampling.preservesExtrema(full: points, sampled: chartPoints, maxCount: 600))
        }
        #endif
        let values = points.flatMap { [$0.mainAssets, $0.netAssets] }.filter(\.isFinite)
        guard let lower = values.min(), let upper = values.max() else {
            chartValueDomain = 0...1
            return
        }
        let padding = max((upper - lower) * 0.13, 1)
        chartValueDomain = (lower - padding)...(upper + padding)
    }

    private func fetchSnapshot(_ id: UUID?) -> AssetSnapshot? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func select(_ date: Date) {
        selectedDate = date
        hoveredDate = nil
    }

    private func moveSelection(_ step: Int) {
        guard let selectedIndex, points.indices.contains(selectedIndex + step) else { return }
        select(points[selectedIndex + step].date)
    }

    #if DEBUG
    @MainActor
    private func runInteractionProbeIfRequested() async {
        guard !didRunInteractionProbe, AppPreviewSession.isActive,
              let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "-macPerfInteractionOutput"),
              ProcessInfo.processInfo.arguments.indices.contains(flag + 1),
              points.count > 1 else { return }
        didRunInteractionProbe = true
        let output = ProcessInfo.processInfo.arguments[flag + 1]
        let probe = MacTimeMachineInteractionProbe()
        interactionProbe = probe
        try? await Task.sleep(for: .milliseconds(500))
        let step = max(1, points.count / 100)
        let indices = Array(stride(from: 0, to: points.count, by: step))
        for index in indices {
            guard !Task.isCancelled else { return }
            let date = points[index].date
            probe.beginHover(at: date)
            hoveredDate = date
            try? await Task.sleep(for: .milliseconds(25))
        }
        hoveredDate = nil
        for index in indices {
            guard !Task.isCancelled else { return }
            selectedDate = points[index].date
            try? await Task.sleep(for: .milliseconds(25))
        }
        probe.write(to: output)
        interactionProbe = nil
    }
    #endif

}

enum MacTimeMachineSampling {
    /// Preserve both series' extrema in each time bucket, plus the endpoints.
    static func extremaPreserving(_ points: [TimeMachineTrendPoint], maxCount: Int) -> [TimeMachineTrendPoint] {
        guard maxCount >= 6, points.count > maxCount else { return points }
        let interiorCount = points.count - 2
        let bucketCount = max(1, (maxCount - 2) / 4)
        var indices = [0]
        indices.reserveCapacity(maxCount)

        for bucket in 0..<bucketCount {
            let start = 1 + interiorCount * bucket / bucketCount
            let end = 1 + interiorCount * (bucket + 1) / bucketCount
            guard start < end else { continue }
            var minAssets = start
            var maxAssets = start
            var minNet = start
            var maxNet = start
            for index in start..<end {
                if points[index].mainAssets < points[minAssets].mainAssets { minAssets = index }
                if points[index].mainAssets > points[maxAssets].mainAssets { maxAssets = index }
                if points[index].netAssets < points[minNet].netAssets { minNet = index }
                if points[index].netAssets > points[maxNet].netAssets { maxNet = index }
            }
            indices.append(contentsOf: Set([minAssets, maxAssets, minNet, maxNet]).sorted())
        }
        indices.append(points.count - 1)
        return indices.map { points[$0] }
    }

    static func preservesExtrema(
        full: [TimeMachineTrendPoint],
        sampled: [TimeMachineTrendPoint],
        maxCount: Int
    ) -> Bool {
        guard !full.isEmpty else { return sampled.isEmpty }
        guard sampled.count <= maxCount,
              sampled.first?.date == full.first?.date,
              sampled.last?.date == full.last?.date else { return false }
        let keyPaths: [KeyPath<TimeMachineTrendPoint, Double>] = [\.mainAssets, \.netAssets]
        for keyPath in keyPaths {
            guard full.map({ $0[keyPath: keyPath] }).min() == sampled.map({ $0[keyPath: keyPath] }).min(),
                  full.map({ $0[keyPath: keyPath] }).max() == sampled.map({ $0[keyPath: keyPath] }).max() else {
                return false
            }
        }
        return zip(sampled, sampled.dropFirst()).allSatisfy { $0.0.date <= $0.1.date }
    }

}

private struct MacTimeMachinePlotScale {
    let firstDate: Date
    let lastDate: Date
    let valueDomain: ClosedRange<Double>

    func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 51, y: 8, width: max(1, size.width - 60), height: max(1, size.height - 30))
    }

    func x(for date: Date, in rect: CGRect) -> CGFloat {
        let duration = lastDate.timeIntervalSince(firstDate)
        guard duration > 0 else { return rect.midX }
        let fraction = min(1, max(0, date.timeIntervalSince(firstDate) / duration))
        return rect.minX + rect.width * fraction
    }

    func y(for value: Double, in rect: CGRect) -> CGFloat {
        let span = valueDomain.upperBound - valueDomain.lowerBound
        guard span > 0 else { return rect.midY }
        let fraction = min(1, max(0, (value - valueDomain.lowerBound) / span))
        return rect.maxY - rect.height * fraction
    }

    func nearestDate(at location: CGPoint, in size: CGSize, points: [TimeMachineTrendPoint]) -> Date? {
        let rect = plotRect(in: size)
        guard rect.contains(location), !points.isEmpty else { return nil }
        let fraction = Double((location.x - rect.minX) / rect.width)
        let date = firstDate.addingTimeInterval(lastDate.timeIntervalSince(firstDate) * fraction)
        return nearestChartPoint(points, to: date, date: \.date)?.date
    }
}

/// The heavy line layer has no hover state; only the small marker layer changes on mouse movement.
private struct MacTimeMachinePlot: View {
    let fullPoints: [TimeMachineTrendPoint]
    let sampledPoints: [TimeMachineTrendPoint]
    let valueDomain: ClosedRange<Double>
    let previewPoint: TimeMachineTrendPoint?
    @Binding var hoveredDate: Date?
    let interactionProbe: MacTimeMachineInteractionProbe?
    let onSelect: (Date) -> Void

    private var scale: MacTimeMachinePlotScale {
        MacTimeMachinePlotScale(
            firstDate: fullPoints.first?.date ?? .now,
            lastDate: fullPoints.last?.date ?? .now,
            valueDomain: valueDomain
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                MacTimeMachineStaticPlot(points: sampledPoints, scale: scale)
                MacTimeMachineMarkerPlot(point: previewPoint, scale: scale, interactionProbe: interactionProbe)
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        let date: Date?
                        switch phase {
                        case let .active(location):
                            date = scale.nearestDate(at: location, in: geometry.size, points: fullPoints)
                        case .ended:
                            date = nil
                        }
                        if hoveredDate != date { hoveredDate = date }
                    }
                    .onTapGesture { location in
                        if let date = scale.nearestDate(at: location, in: geometry.size, points: fullPoints) {
                            onSelect(date)
                        }
                    }
            }
        }
    }
}

private struct MacTimeMachineStaticPlot: View {
    let points: [TimeMachineTrendPoint]
    let scale: MacTimeMachinePlotScale

    var body: some View {
        Canvas(opaque: false) { context, size in
            let rect = scale.plotRect(in: size)
            for step in 0...3 {
                let fraction = Double(step) / 3
                let value = scale.valueDomain.lowerBound + (scale.valueDomain.upperBound - scale.valueDomain.lowerBound) * fraction
                let y = scale.y(for: value, in: rect)
                var grid = Path()
                grid.move(to: CGPoint(x: rect.minX, y: y))
                grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.stroke(grid, with: .color(AssetTheme.border.opacity(0.8)), lineWidth: 0.6)
                let label = Text(value.formatted(.number.precision(.fractionLength(0))))
                    .font(.system(size: 9))
                    .foregroundColor(AssetTheme.textSecondary)
                context.draw(context.resolve(label), at: CGPoint(x: rect.minX - 6, y: y), anchor: .trailing)
            }
            for step in 0...3 {
                let fraction = Double(step) / 3
                let date = scale.firstDate.addingTimeInterval(scale.lastDate.timeIntervalSince(scale.firstDate) * fraction)
                let x = scale.x(for: date, in: rect)
                var grid = Path()
                grid.move(to: CGPoint(x: x, y: rect.minY))
                grid.addLine(to: CGPoint(x: x, y: rect.maxY))
                context.stroke(grid, with: .color(AssetTheme.border.opacity(0.5)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                let label = Text(date.formatted(.dateTime.year().month(.abbreviated)))
                    .font(.system(size: 9))
                    .foregroundColor(AssetTheme.textSecondary)
                context.draw(context.resolve(label), at: CGPoint(x: x, y: rect.maxY + 9), anchor: .top)
            }
            let series: [(KeyPath<TimeMachineTrendPoint, Double>, Color)] = [
                (\.mainAssets, AssetTheme.goldSoft), (\.netAssets, AssetTheme.positive)
            ]
            for (keyPath, color) in series {
                var line = Path()
                for (index, point) in points.enumerated() {
                    let position = CGPoint(x: scale.x(for: point.date, in: rect), y: scale.y(for: point[keyPath: keyPath], in: rect))
                    if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
                }
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.7, lineJoin: .round))
            }
        }
        .accessibilityLabel(AppLocalization.string("资产走势"))
    }
}

private struct MacTimeMachineMarkerPlot: View {
    let point: TimeMachineTrendPoint?
    let scale: MacTimeMachinePlotScale
    let interactionProbe: MacTimeMachineInteractionProbe?

    var body: some View {
        Canvas(opaque: false) { context, size in
            guard let point else { return }
            #if DEBUG
            interactionProbe?.finishHover(at: point.date)
            #endif
            let rect = scale.plotRect(in: size)
            let x = scale.x(for: point.date, in: rect)
            var rule = Path()
            rule.move(to: CGPoint(x: x, y: rect.minY))
            rule.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(rule, with: .color(AssetTheme.gold.opacity(0.8)), lineWidth: 1)
            for (value, color) in [(point.mainAssets, AssetTheme.goldSoft), (point.netAssets, AssetTheme.positive)] {
                let y = scale.y(for: value, in: rect)
                context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }
}

private final class MacTimeMachineInteractionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingHover: (date: Date, started: CFAbsoluteTime)?
    private var hoverMilliseconds: [Double] = []
    private var selectionMilliseconds: [Double] = []

    func beginHover(at date: Date) {
        lock.lock()
        pendingHover = (date, CFAbsoluteTimeGetCurrent())
        lock.unlock()
    }

    func finishHover(at date: Date) {
        lock.lock()
        if let pendingHover, pendingHover.date == date {
            hoverMilliseconds.append((CFAbsoluteTimeGetCurrent() - pendingHover.started) * 1000)
            self.pendingHover = nil
        }
        lock.unlock()
    }

    func recordSelection(milliseconds: Double) {
        lock.lock()
        selectionMilliseconds.append(milliseconds)
        lock.unlock()
    }

    func write(to path: String) {
        lock.lock()
        let hover = hoverMilliseconds
        let selection = selectionMilliseconds
        lock.unlock()
        func percentile95(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return -1 }
            let ordered = values.sorted()
            return ordered[min(ordered.count - 1, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
        }
        let result: [String: Any] = [
            "hoverCount": hover.count,
            "hoverPaintP95Ms": percentile95(hover),
            "selectionCount": selection.count,
            "selectionFetchP95Ms": percentile95(selection)
        ]
        guard JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private struct MacTimeMachineLedger: View {
    let snapshot: AssetSnapshot?
    let previousSnapshot: AssetSnapshot?
    let point: TimeMachineTrendPoint?
    let amountsVisible: Bool

    private var entries: [AssetEntry] {
        (snapshot?.entries ?? [])
            .filter { $0.item != nil && abs($0.resolvedAmount) > 0.000_001 }
            .sorted { ($0.item?.sortOrder ?? 0) < ($1.item?.sortOrder ?? 0) }
    }

    private var categories: [AssetCategory] {
        let values = entries.compactMap { $0.item?.category }
        return Dictionary(grouping: values, by: \.id).values.compactMap(\.first)
            .sorted { ($0.group == .liability ? 1 : 0, $0.name) < ($1.group == .liability ? 1 : 0, $1.name) }
    }

    private var previousAmounts: [UUID: Double] {
        (previousSnapshot?.entries ?? []).reduce(into: [UUID: Double]()) { amounts, entry in
            guard let id = entry.item?.id else { return }
            amounts[id, default: 0] += entry.resolvedAmount
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((point?.date.formatted(date: .abbreviated, time: .omitted) ?? "—") + AppLocalization.string(" 的资产明细"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(AppLocalization.string("按分类分组"))
                    .font(.system(size: 10))
                    .foregroundStyle(AssetTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            Divider()
            HStack {
                Text(AppLocalization.string("分类 / 资产账户")).frame(maxWidth: .infinity, alignment: .leading)
                Text(AppLocalization.string("金额")).frame(width: 94, alignment: .trailing)
                Text(AppLocalization.string("较上次")).frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 9))
            .foregroundStyle(AssetTheme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            Divider()
            if snapshot == nil || entries.isEmpty {
                ContentUnavailableView(AppLocalization.string("当天没有保存资产记录"), systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(categories, id: \.id) { category in
                            let items = entries.filter { $0.item?.category?.id == category.id }
                            let total = items.reduce(0) { $0 + $1.resolvedAmount }
                            let prior = (previousSnapshot?.entries ?? [])
                                .filter { $0.item?.category?.id == category.id }
                                .reduce(0) { $0 + $1.resolvedAmount }
                            HStack(spacing: 6) {
                                Image(systemName: category.group == .liability ? "minus.circle.fill" : "square.stack.fill")
                                    .foregroundStyle(category.group == .liability ? AssetTheme.negative : AssetTheme.goldSoft)
                                    .frame(width: 14)
                                Text(category.name).fontWeight(.semibold).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(amountsVisible ? total.currencyString() : "••••••")
                                    .frame(width: 94, alignment: .trailing)
                                Text(amountsVisible && previousSnapshot != nil ? signed(total - prior) : "—")
                                    .foregroundStyle(total - prior < 0 ? AssetTheme.negative : AssetTheme.positive)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .font(.system(size: 10))
                            .padding(.horizontal, 12)
                            .frame(height: 31)
                            .background(AssetTheme.overlayFaint.opacity(0.35))
                            ForEach(items) { entry in
                                HStack(spacing: 6) {
                                    Text(entry.item?.name ?? "—").lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .help(entry.item?.name ?? "")
                                    Text(amountsVisible ? entry.resolvedAmount.currencyString() : "••••••")
                                        .frame(width: 94, alignment: .trailing)
                                    let priorValue = entry.item.flatMap { previousAmounts[$0.id] }
                                    Text(amountsVisible && priorValue != nil ? signed(entry.resolvedAmount - (priorValue ?? 0)) : "—")
                                        .foregroundStyle(entry.resolvedAmount - (priorValue ?? 0) < 0 ? AssetTheme.negative : AssetTheme.positive)
                                        .frame(width: 70, alignment: .trailing)
                                }
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .padding(.leading, 32)
                                .padding(.trailing, 12)
                                .frame(height: 29)
                                Divider().padding(.leading, 32)
                            }
                        }
                    }
                }
            }
        }
        .background(AssetTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AssetTheme.border))
    }

    private func signed(_ value: Double) -> String {
        (value >= 0 ? "+" : "−") + abs(value).currencyString()
    }
}

private struct MacTimeMachineDayReport: View {
    let snapshot: AssetSnapshot?
    let previousSnapshot: AssetSnapshot?
    let point: TimeMachineTrendPoint?
    let previousPoint: TimeMachineTrendPoint?
    let amountsVisible: Bool

    private var allocations: [(String, Double, Color)] {
        let entries = snapshot?.entries ?? []
        let assets = entries.filter { $0.item?.category?.group != .liability }
        let grouped = Dictionary(grouping: assets, by: { $0.item?.category?.name ?? AppLocalization.string("其他") })
        let colors: [Color] = [AssetTheme.positive, AssetTheme.goldSoft, AssetTheme.accentBlue, AssetTheme.accentOrange]
        return grouped.map { ($0.key, $0.value.reduce(0) { $0 + $1.resolvedAmount }) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .enumerated().map { ($0.element.0, $0.element.1, colors[$0.offset % colors.count]) }
    }

    private var changes: [(String, Double)] {
        guard let snapshot, let previousSnapshot else { return [] }
        let prior = (previousSnapshot.entries).reduce(into: [UUID: Double]()) { amounts, entry in
            guard let id = entry.item?.id else { return }
            amounts[id, default: 0] += entry.resolvedAmount
        }
        return snapshot.entries.compactMap { entry in
            guard let item = entry.item, let priorAmount = prior[item.id] else { return nil }
            let change = entry.resolvedAmount - priorAmount
            return abs(change) > 0.000_001 ? (item.name, change) : nil
        }
        .sorted { abs($0.1) > abs($1.1) }
        .prefix(3)
        .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((point?.date.formatted(date: .abbreviated, time: .omitted) ?? "—") + AppLocalization.string(" · 日报"))
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 38)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .top, spacing: 8) {
                        reportMetric("净资产", value: point?.netAssets)
                        reportMetric("总资产", value: point?.mainAssets)
                        reportMetric("总负债", value: point?.liabilities)
                    }
                    if let point, let previousPoint {
                        Divider()
                        HStack {
                            Text(AppLocalization.string("较上次"))
                                .foregroundStyle(AssetTheme.textSecondary)
                            Spacer()
                            let change = point.netAssets - previousPoint.netAssets
                            Text(amountsVisible ? (change >= 0 ? "+" : "−") + abs(change).currencyString() : "••••••")
                                .foregroundStyle(change < 0 ? AssetTheme.negative : AssetTheme.positive)
                        }
                        .font(.system(size: 10, weight: .medium))
                    }
                    Divider()
                    Text(AppLocalization.string("资产分布"))
                        .font(.system(size: 11, weight: .semibold))
                    if allocations.isEmpty {
                        Text(AppLocalization.string("暂无资产分布"))
                            .font(.system(size: 10))
                            .foregroundStyle(AssetTheme.textSecondary)
                    } else {
                        HStack(spacing: 8) {
                            Chart(allocations, id: \.0) { category in
                                SectorMark(angle: .value("金额", category.1), innerRadius: .ratio(0.7))
                                    .foregroundStyle(category.2)
                            }
                            .chartLegend(.hidden)
                            .frame(width: 68, height: 68)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(allocations.prefix(4), id: \.0) { category in
                                    HStack(spacing: 5) {
                                        Circle().fill(category.2).frame(width: 5, height: 5)
                                        Text(category.0).lineLimit(1)
                                        Spacer(minLength: 2)
                                        Text(amountsVisible ? String(format: "%.0f%%", category.1 / max(point?.mainAssets ?? 1, 1) * 100) : "••")
                                            .monospacedDigit()
                                    }
                                    .font(.system(size: 9))
                                }
                            }
                        }
                    }
                    if !changes.isEmpty {
                        Divider()
                        Text(AppLocalization.string("当日关键变动"))
                            .font(.system(size: 11, weight: .semibold))
                        ForEach(changes, id: \.0) { change in
                            HStack {
                                Image(systemName: change.1 >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .foregroundStyle(change.1 >= 0 ? AssetTheme.positive : AssetTheme.negative)
                                Text(change.0).lineLimit(1)
                                Spacer(minLength: 2)
                                Text(amountsVisible ? (change.1 >= 0 ? "+" : "−") + abs(change.1).currencyString() : "••••••")
                                    .monospacedDigit()
                            }
                            .font(.system(size: 9))
                        }
                    }
                    if let note = snapshot?.note, !note.isEmpty {
                        Divider()
                        Text(AppLocalization.string("记录备注"))
                            .font(.system(size: 11, weight: .semibold))
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                }
                .padding(12)
            }
        }
        .background(AssetTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AssetTheme.border))
    }

    private func reportMetric(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalization.string(title))
                .font(.system(size: 9))
                .foregroundStyle(AssetTheme.textSecondary)
            Text(amountsVisible ? (value?.currencyString() ?? "—") : "••••••")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
