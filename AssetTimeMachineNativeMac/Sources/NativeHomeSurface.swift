import AppKit
import SwiftData
import SwiftUI

private enum HomePreferences {
    // Parameter checks in the fixture app never write the user's production preferences.
    static let defaults: UserDefaults = AppPreviewSession.isActive
        ? UserDefaults(suiteName: "com.flyingrtx.AssetTimeMachine.home-preview.\(UUID().uuidString)")!
        : .standard
}

struct NativeHomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var reduced: Bool { systemReduced || NativeHomeStyle.previewReduced }
    @ObservedObject var history: NativeHistoryModel
    @ObservedObject var cloud: AssetTimeMachineCloudStore
    let openRecords: () -> Void
    let openRecord: (UUID) -> Void
    let openCloudSync: () -> Void
    @AppStorage("dashboard.monthlyExpense", store: HomePreferences.defaults) private var monthlyExpense = 3000.0
    @AppStorage("dashboard.monthlySalary", store: HomePreferences.defaults) private var monthlySalary = 10000.0
    @AppStorage("dashboard.annualReturnRate", store: HomePreferences.defaults) private var annualReturnRate = 0.03
    @AppStorage("dashboard.inflationRate", store: HomePreferences.defaults) private var inflationRate = 0.05
    @State private var latestSnapshot: AssetSnapshot?
    @State private var latestSnapshotContext: ModelContext?
    @State private var range = 1
    @State private var parameters = false
    private let labels = ["7天", "30天", "365天", "全部"]
    private var latest: TimeMachineSnapshotProjection? { history.summaries.last }
    private var total: Double { latest?.totalAssets ?? 0 }
    private var debt: Double { latest?.totalLiabilities ?? 0 }
    private var net: Double { total - debt }
    private var freedom: Double { monthlyExpense > 0 ? max(0, net * annualReturnRate / 12 / monthlyExpense) : 0 }
    private var visibleTrend: [TimeMachineSnapshotProjection] {
        Array(history.summaries.suffix([7, 30, 365, Int.max][range]))
    }
    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(1, geometry.size.width - NativeStyle.Layout.pageInset * 2)
            let plotHeight = max(150, min(195, geometry.size.height - 420))
            let compactRail = geometry.size.height < 600
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 20) {
                        overview(plotHeight: plotHeight).frame(maxWidth: .infinity, alignment: .leading)
                        Rectangle().fill(NativePalette.line).frame(width: 0.5)
                        assetRail(compact: compactRail).frame(width: 220)
                    }.fixedSize(horizontal: false, vertical: true)
                    ledger(width: contentWidth)
                    if let error = history.error {
                        HStack {
                            Text(error).foregroundStyle(AssetTheme.negative)
                            Button("重试") { Task { await history.load(from: context.container, force: true) } }
                        }.font(NativeStyle.FontRole.caption)
                    }
                }.padding(NativeStyle.Layout.pageInset)
            }
        }
        .modifier(NativeWorkspaceSurface())
        .sheet(isPresented: $parameters) {
            NativeHomeParameters(monthlyExpense: $monthlyExpense, monthlySalary: $monthlySalary,
                                 annualReturnRate: $annualReturnRate, inflationRate: $inflationRate) {
                parameters = false
            }
        }
        .task(id: history.generation) { loadLatestSnapshot() }
        .onDisappear { latestSnapshot = nil; latestSnapshotContext = nil }
        .animation(NativeStyle.Motion.home(reduced), value: history.generation)
    }
    private var rule: some View { Rectangle().fill(NativeHomeStyle.line).frame(height: 0.5) }
    private func overview(plotHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("净资产").font(NativeStyle.FontRole.bodyStrong)
                    Text(NativeHomeStyle.amount(net)).font(NativeStyle.FontRole.display).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .contentTransition(reduced ? .opacity : .numericText())
                    if let latest {
                        Text(AppLocalization.format("截至 %@", latest.date.formatted(date: .numeric, time: .omitted)))
                            .font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                            .lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                rangeControl
            }.frame(height: 78, alignment: .top)
            HStack(spacing: 16) {
                if history.loading {
                    ProgressView().controlSize(.mini).accessibilityLabel("加载资产记录")
                }
                Spacer(minLength: 0)
                legend("净资产", color: NativePalette.accent)
                legend("总资产", color: NativePalette.chartSecondary)
            }.frame(height: 18)
            NativePanoramaTrend(summaries: visibleTrend, revision: "\(history.generation)-\(range)", compact: true)
                .frame(height: plotHeight + 25)
        }
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 14, height: 2)
            Text(AppLocalization.string(title))
        }.font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
    }
    private var rangeControl: some View {
        Picker("时间范围", selection: $range) {
            ForEach(labels.indices, id: \.self) { index in
                Text(AppLocalization.string(labels[index])).tag(index)
            }
        }.labelsHidden().pickerStyle(.segmented).controlSize(.small).tint(NativePalette.accent).frame(width: 204)
    }
    private func assetRail(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            metric("总资产", total)
            metric("负债", debt)
            rule.padding(.top, 8)
            NativeHomeComposition(snapshot: latestSnapshot, rowHeight: compact ? 24 : 26).padding(.top, 12)
            rule.padding(.top, 12)
            HStack(spacing: 8) {
                Text("财务自由").font(NativeStyle.FontRole.bodyStrong)
                Text("\(Int(min(freedom, 1) * 100))%").monospacedDigit()
                    .contentTransition(reduced ? .opacity : .numericText())
                Spacer(minLength: 0)
                Button { parameters = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 26, height: 28)
                }.help(AppLocalization.string("参数")).accessibilityLabel("参数")
            }.font(NativeStyle.FontRole.body).padding(.top, 8)
        }
    }
    private func metric(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 12) {
            Text(AppLocalization.string(label)).foregroundStyle(NativePalette.secondary)
            Spacer(minLength: 0)
            Text(NativeHomeStyle.amount(value)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.85)
                .contentTransition(reduced ? .opacity : .numericText())
        }.font(NativeStyle.FontRole.body).frame(height: 28)
    }
    private func ledger(width: CGFloat) -> some View {
        let dateWidth = min(170, max(140, width * 0.19))
        return VStack(alignment: .leading, spacing: 0) {
            rule
            HStack(spacing: 12) {
                Text("最近记录").font(NativeStyle.FontRole.bodyStrong)
                Text("单位：元").font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
            }.frame(height: 36, alignment: .leading)
            ledgerRow([AppLocalization.string("日期"), AppLocalization.string("总资产"),
                       AppLocalization.string("净资产"), AppLocalization.string("负债")], dateWidth: dateWidth)
                .font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                .frame(height: 26).background(NativePalette.sidebar.opacity(0.7))
            rule
            if history.summaries.isEmpty {
                Text("暂无资产记录").font(NativeStyle.FontRole.body).foregroundStyle(NativePalette.secondary)
                    .frame(maxWidth: .infinity, minHeight: NativeStyle.Layout.emptyStateHeight)
            } else {
                ForEach(Array(history.summaries.suffix(5).reversed().enumerated()), id: \.element.id) { index, record in
                    Button { openRecord(record.id) } label: {
                        ledgerRow([record.date.formatted(date: .numeric, time: .omitted),
                                   record.totalAssets.formatted(.number.precision(.fractionLength(2))),
                                   (record.totalAssets - record.totalLiabilities).formatted(.number.precision(.fractionLength(2))),
                                   record.totalLiabilities.formatted(.number.precision(.fractionLength(2)))], dateWidth: dateWidth)
                            .font(NativeStyle.FontRole.body).monospacedDigit()
                            .frame(height: NativeStyle.Layout.ledgerRowHeight).contentShape(Rectangle())
                            .background(NativePalette.text.opacity(index.isMultiple(of: 2) ? 0 : 0.025))
                            .contentTransition(reduced ? .opacity : .numericText())
                    }.buttonStyle(.plain).foregroundStyle(NativePalette.text)
                        .help(AppLocalization.format("查看 %@ 的记录", record.date.formatted(date: .numeric, time: .omitted)))
                    rule
                }
            }
        }
    }
    private func ledgerRow(_ values: [String], dateWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                Text(values[index]).lineLimit(1).minimumScaleFactor(0.85)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: index == 0 ? nil : .infinity, maxHeight: .infinity,
                           alignment: index == 0 ? .leading : .trailing)
                    .frame(width: index == 0 ? dateWidth : nil, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if index < values.count - 1 { Rectangle().fill(NativePalette.line.opacity(0.65)).frame(width: 0.5) }
                    }
            }
        }
    }
    private func loadLatestSnapshot() {
        guard let id = latest?.id else { latestSnapshot = nil; latestSnapshotContext = nil; return }
        do {
            var descriptor = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            let reader = ModelContext(context.container); reader.autosaveEnabled = false
            latestSnapshotContext = reader; latestSnapshot = try reader.fetch(descriptor).first
        } catch { latestSnapshot = nil; latestSnapshotContext = nil }
    }
}

struct NativeHomeHoverRow<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var reduced: Bool { systemReduced || NativeHomeStyle.previewReduced }
    @State private var hovered = false
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(.horizontal, 3)
            .foregroundStyle(NativeHomeStyle.text)
            .background(NativeHomeStyle.accent.opacity(hovered ? 0.075 : 0), in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
            .onHover { hovered = $0 }.animation(NativeStyle.Motion.home(reduced), value: hovered)
    }
}

private struct NativeHomeComposition: View {
    let snapshot: AssetSnapshot?
    var rowHeight: CGFloat = 26
    private var slices: [(name: String, amount: Double, icon: String?, group: AssetGroup?)] {
        guard let snapshot else { return [] }
        let grouped = Dictionary(grouping: snapshot.entries.filter {
            $0.item?.category?.group != .liability && $0.resolvedAmount > 0
        }, by: { $0.item?.name ?? "其他" })
        let totals: [(name: String, amount: Double, icon: String?, group: AssetGroup?)] = grouped.map { group in
            let item = group.value.first?.item
            return (name: group.key, amount: group.value.reduce(0) { $0 + $1.resolvedAmount },
                    icon: item.map { AssetItemService.resolvedIconKey(for: $0) }, group: item?.category?.group)
        }
        let all = totals.sorted { lhs, rhs in
            if lhs.amount == rhs.amount { return lhs.name < rhs.name }
            return lhs.amount > rhs.amount
        }
        if all.count <= 5 { return all }
        return Array(all.prefix(5)) + [(name: AppLocalization.string("其他"), amount: all.dropFirst(5).reduce(0) { $0 + $1.amount }, icon: "square.grid.2x2", group: nil)]
    }
    var body: some View {
        let values = slices
        let total = values.reduce(0) { $0 + $1.amount }
        VStack(alignment: .leading, spacing: 0) {
            Text("资产构成").font(NativeStyle.FontRole.bodyStrong).frame(height: 28, alignment: .leading)
            if total > 0 {
                ForEach(values.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        NativeAssetIcon(key: values[index].icon, group: values[index].group, title: values[index].name, size: 16)
                        Text(values[index].name).lineLimit(1).help(values[index].name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(values[index].amount.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                            .frame(width: 94, alignment: .trailing)
                        Text((values[index].amount / total).formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit().frame(width: 32, alignment: .trailing)
                    }.font(NativeStyle.FontRole.body).frame(height: rowHeight)
                    Rectangle().fill(NativePalette.line.opacity(0.6)).frame(height: 0.5)
                }
            } else {
                Text("暂无资产分布").font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            }
        }
    }
}

private struct NativeHomeParameters: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var reduced: Bool { systemReduced || NativeHomeStyle.previewReduced }
    @Binding var monthlyExpense: Double
    @Binding var monthlySalary: Double
    @Binding var annualReturnRate: Double
    @Binding var inflationRate: Double
    let close: () -> Void
    @State private var draft: [Double]
    init(monthlyExpense: Binding<Double>, monthlySalary: Binding<Double>, annualReturnRate: Binding<Double>, inflationRate: Binding<Double>, close: @escaping () -> Void) {
        _monthlyExpense = monthlyExpense; _monthlySalary = monthlySalary
        _annualReturnRate = annualReturnRate; _inflationRate = inflationRate
        _draft = State(initialValue: [monthlyExpense.wrappedValue, monthlySalary.wrappedValue, annualReturnRate.wrappedValue, inflationRate.wrappedValue])
        self.close = close
    }
    @FocusState private var focus: Int?
    @State private var invalid = false
    var body: some View {
        NativeSheet(title: "财务自由参数", width: 400, cancel: close) {
            VStack(spacing: 12) {
                field("月开销", $draft[0], 0)
                field("月薪", $draft[1], 1)
                field("年化收益率", $draft[2], 2, percent: true)
                field("通胀率", $draft[3], 3, percent: true)
                if invalid {
                    Text("请输入有效数值").font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.negative)
                }
            }
        } footer: {
            NativeSheetActions(cancel: close, title: "保存", submit: finish)
        }
        .onAppear { focus = 0 }
        .onExitCommand(perform: close)
    }
    private func field(_ label: String, _ binding: Binding<Double>, _ index: Int, percent: Bool = false) -> some View {
        NativeFormRow(title: label) {
            Group {
                if percent { TextField(label, value: binding, format: .percent) }
                else { TextField(label, value: binding, format: .number) }
            }.textFieldStyle(.roundedBorder).monospacedDigit()
                .focused($focus, equals: index).onSubmit(finish)
        }
    }
    private func finish() {
        invalid = !draft.allSatisfy(\.isFinite) || draft[0] <= 0 || draft[1] < 0
        if !invalid {
            monthlyExpense = draft[0]; monthlySalary = draft[1]
            annualReturnRate = draft[2]; inflationRate = draft[3]
            close()
        }
    }
}

private struct NativePanoramaVector: VectorArithmetic {
    var values: [Double]
    static var zero: Self { .init(values: Array(repeating: 0, count: 1200)) }
    static func + (a: Self, b: Self) -> Self { .init(values: zip(a.values, b.values).map(+)) }
    static func - (a: Self, b: Self) -> Self { .init(values: zip(a.values, b.values).map(-)) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}
private struct NativePanoramaLine: Shape {
    var vector: NativePanoramaVector
    var fillToBaseline = false
    var animatableData: NativePanoramaVector { get { vector } set { vector = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in stride(from: 0, to: vector.values.count, by: 2) {
            let point = CGPoint(x: vector.values[i] * rect.width, y: vector.values[i + 1] * rect.height)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if fillToBaseline, vector.values.count >= 2 {
            path.addLine(to: CGPoint(x: vector.values[vector.values.count - 2] * rect.width, y: rect.maxY))
            path.addLine(to: CGPoint(x: vector.values[0] * rect.width, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
/// Gold uses the same total-assets / recorded CNY-per-gram price as iPhone.
/// Missing quotes split the line; per-bucket extrema keep long histories bounded.
struct NativeGoldEquivalentPlot {
    let values: [Double?]
    let low: Double
    let span: Double
    let path: Path
    var hasValues: Bool { values.contains { $0 != nil } }

    static func value(_ summary: TimeMachineSnapshotProjection) -> Double? {
        guard let price = summary.goldAnchorPriceCNY, price.isFinite, price > 0,
              summary.totalAssets.isFinite else { return nil }
        let value = summary.totalAssets / price
        return value.isFinite ? value : nil
    }

    init(_ summaries: [TimeMachineSnapshotProjection]) {
        let values = summaries.map(Self.value)
        self.values = values
        let valid = values.compactMap { $0 }
        let minimum = valid.min() ?? 0, maximum = valid.max() ?? 1
        let range = max(maximum - minimum, max(abs(maximum) * 0.02, 0.01))
        let low = minimum >= 0 ? max(0, minimum - range * 0.08) : minimum - range * 0.08
        self.low = low
        let span = max(maximum + range * 0.12 - low, 0.01)
        self.span = span
        let first = summaries.first?.date ?? .now
        let duration = max(summaries.last?.date.timeIntervalSince(first) ?? 1, 1)
        let bucketSize = max(1, Int(ceil(Double(summaries.count) / 150)))
        var path = Path()
        var segment: [Int] = []
        func appendSegment() {
            var startsLine = true
            for start in stride(from: 0, to: segment.count, by: bucketSize) {
                let bucket = Array(segment[start..<min(start + bucketSize, segment.count)])
                let indices = Set([bucket.first!, bucket.last!,
                    bucket.min { values[$0]! < values[$1]! }!, bucket.max { values[$0]! < values[$1]! }!]).sorted()
                for index in indices {
                    let x = summaries.count == 1 ? 1 : summaries[index].date.timeIntervalSince(first) / duration
                    let point = CGPoint(x: x, y: 1 - (values[index]! - low) / span)
                    if startsLine { path.move(to: point); startsLine = false }
                    else { path.addLine(to: point) }
                }
            }
            segment.removeAll(keepingCapacity: true)
        }
        for index in values.indices {
            if values[index] != nil { segment.append(index) }
            else { appendSegment() }
        }
        appendSegment()
        self.path = path
    }
}

struct NativePanoramaTrend: View {
    let summaries: [TimeMachineSnapshotProjection]
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var reduced: Bool { systemReduced || NativeHomeStyle.previewReduced }
    @State private var hovered: Int?
    let revision: String
    var compact = false
    var netOnly = false
    var showsGoldEquivalent = false
    var selection: Int? = nil
    var onHover: ((Int?) -> Void)? = nil
    var onSelect: ((Int) -> Void)? = nil
    @State private var domain: (low: Double, span: Double) = (0, 1)
    @State private var totalVector = NativePanoramaVector.zero
    @State private var netVector = NativePanoramaVector.zero
    @State private var goldPlot = NativeGoldEquivalentPlot([])
    private let goldColor = AssetTheme.positive
    private var goldAxisVisible: Bool { showsGoldEquivalent && !compact && goldPlot.hasValues }
    private func point(_ summary: TimeMachineSnapshotProjection, net: Bool,
                       scale: (low: Double, span: Double)? = nil) -> CGPoint {
        let scale = scale ?? domain
        let first = summaries.first?.date.timeIntervalSinceReferenceDate ?? 0
        let last = summaries.last?.date.timeIntervalSinceReferenceDate ?? 1
        let x = summaries.count == 1 ? 1 : (summary.date.timeIntervalSinceReferenceDate - first) / max(last - first, 1)
        let value = summary.totalAssets - (net ? summary.totalLiabilities : 0)
        return CGPoint(x: x, y: 1 - (value - scale.low) / scale.span)
    }
    private func refreshPlot() {
        let values = summaries.flatMap { netOnly ? [$0.totalAssets - $0.totalLiabilities] : [$0.totalAssets, $0.totalAssets - $0.totalLiabilities] }.filter(\.isFinite)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let span = max(high - low, max(max(abs(low), abs(high)) * 0.02, 1))
        // Four readable ticks; positive balances never acquire a negative axis from padding.
        let paddedLow = low >= 0 ? max(0, low - span * 0.08) : low - span * 0.08
        let paddedHigh = high + span * 0.12
        func roundedStep(_ value: Double) -> Double {
            let magnitude = pow(10, floor(log10(value)))
            let fraction = value / magnitude
            return ([1.0, 2, 2.5, 5, 10].first { $0 >= fraction } ?? 10) * magnitude
        }
        var step = roundedStep((paddedHigh - paddedLow) / 3)
        var lower = floor(paddedLow / step) * step
        while lower + step * 3 < high {
            step = roundedStep(step * 1.01)
            lower = floor(paddedLow / step) * step
        }
        let scale = (low: lower, span: step * 3)
        let sampled = NativeStaticTrendCanvas.sample(summaries, limit: 600)
        func vector(net: Bool) -> NativePanoramaVector {
            var points = sampled.map { point($0.element, net: net, scale: scale) }
            points += Array(repeating: points.last ?? .zero, count: 600 - points.count)
            return .init(values: points.flatMap { [Double($0.x), Double($0.y)] })
        }
        domain = scale
        totalVector = vector(net: false)
        netVector = vector(net: true)
        goldPlot = NativeGoldEquivalentPlot(compact ? [] : summaries)
        hovered = nil
    }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - (goldAxisVisible ? 128 : (compact ? 56 : 90)))
            let height = max(1, geometry.size.height - 25)
            let total = totalVector, net = netVector
            ZStack(alignment: .topLeading) {
                if let latest = summaries.last {
                    if compact {
                        ForEach(0..<4) { tick in
                            Path { p in
                                let y = height * CGFloat(tick) / 3
                                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: width, y: y))
                            }.stroke(NativePalette.line.opacity(0.55), lineWidth: 0.5)
                        }
                    }
                    Group {
                        if compact {
                            NativePanoramaLine(vector: net, fillToBaseline: true)
                                .fill(NativePalette.accent.opacity(0.045))
                        }
                        if !netOnly { NativePanoramaLine(vector: total).stroke(NativePalette.chartSecondary, lineWidth: 1.15) }
                        NativePanoramaLine(vector: net).stroke(NativeHomeStyle.accent, lineWidth: 1.15)
                    }.frame(width: width, height: height)
                        .animation(reduced ? nil : NativeStyle.Motion.home(false), value: total)
                        .animation(reduced ? nil : NativeStyle.Motion.home(false), value: net)
                    if goldAxisVisible {
                        Canvas { graphics, _ in
                            graphics.stroke(goldPlot.path.applying(CGAffineTransform(scaleX: width, y: height)),
                                with: .color(goldColor), style: StrokeStyle(lineWidth: 1.4, dash: [5, 3]))
                        }.frame(width: width, height: height).allowsHitTesting(false)
                        ForEach(0..<4) { tick in
                            let value = goldPlot.low + goldPlot.span * (1 - Double(tick) / 3)
                            Text(value.formatted(.number.precision(.significantDigits(1...4))) + " g")
                                .font(NativeStyle.FontRole.caption).monospacedDigit().foregroundStyle(goldColor)
                                .lineLimit(1).minimumScaleFactor(0.75).frame(width: 60, alignment: .leading)
                                .offset(x: width + 8, y: height * CGFloat(tick) / 3 - 6)
                        }
                        if let value = goldPlot.values.last ?? nil {
                            Circle().fill(goldColor).frame(width: 6, height: 6)
                                .offset(x: width - 3, y: (1 - (value - goldPlot.low) / goldPlot.span) * height - 3)
                        }
                    }
                    let totalPoint = point(latest, net: false), netPoint = point(latest, net: true)
                    Path { p in p.move(to: CGPoint(x: width, y: 0)); p.addLine(to: CGPoint(x: width, y: height)) }
                        .stroke(NativeHomeStyle.text.opacity(0.3), style: StrokeStyle(lineWidth: 0.7, dash: [4, 4]))
                    if !compact && !netOnly && !goldAxisVisible { endpoint("总资产", latest.totalAssets, NativePalette.chartSecondary, point: totalPoint, width: width, height: height) }
                    if !compact && !goldAxisVisible {
                        endpoint("净资产", latest.totalAssets - latest.totalLiabilities, NativeHomeStyle.accent, point: netPoint,
                                 width: width, height: height, labelOffset: !netOnly && abs(totalPoint.y - netPoint.y) * height < 42 ? 42 : 0)
                    }
                    if hovered == nil, let selection, summaries.indices.contains(selection) {
                        Rectangle().fill(NativeHomeStyle.accent.opacity(0.45)).frame(width: 0.7, height: height)
                            .offset(x: point(summaries[selection], net: true).x * width)
                            .animation(reduced ? nil : NativeStyle.Motion.home(false), value: selection)
                    }
                    if let index = hovered, summaries.indices.contains(index) {
                        let summary = summaries[index]
                        let p = point(summary, net: false)
                        Rectangle().fill(NativeHomeStyle.accent.opacity(0.45)).frame(width: 0.7, height: height).offset(x: p.x * width)
                        ForEach((netOnly ? 1 : 0)..<2, id: \.self) { i in
                            let v = point(summary, net: i == 1)
                            Circle().fill(i == 0 ? NativePalette.chartSecondary : NativeHomeStyle.accent).frame(width: 5, height: 5)
                                .offset(x: v.x * width - 2.5, y: v.y * height - 2.5)
                        }
                        if goldAxisVisible, let value = NativeGoldEquivalentPlot.value(summary) {
                            Circle().fill(goldColor).frame(width: 5, height: 5)
                                .offset(x: p.x * width - 2.5, y: (1 - (value - goldPlot.low) / goldPlot.span) * height - 2.5)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(summary.date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))))
                            if !netOnly { Text("总资产 " + NativeHomeStyle.amount(summary.totalAssets)) }
                            Text("净资产 " + NativeHomeStyle.amount(summary.totalAssets - summary.totalLiabilities))
                                .foregroundStyle(NativeHomeStyle.accent)
                            if showsGoldEquivalent {
                                Text(AppLocalization.string("等值黄金") + " " + (NativeGoldEquivalentPlot.value(summary)
                                    .map { $0.formatted(.number.precision(.fractionLength(0...4))) + " g" } ?? "—"))
                                    .foregroundStyle(goldColor)
                            }
                        }.font(NativeStyle.FontRole.micro).monospacedDigit().padding(9)
                            .background(NativePalette.surface, in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
                            .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.control).stroke(NativeHomeStyle.line, lineWidth: 0.7))
                            .offset(x: min(max(0, p.x * width + 10), max(0, width - 160)), y: 0)
                    }
                    HStack {
                        Text(axisDate(summaries.first!.date))
                        Spacer()
                        if compact, summaries.count > 2 {
                            let middle = summaries.first!.date.addingTimeInterval(latest.date.timeIntervalSince(summaries.first!.date) / 2)
                            Text(axisDate(middle))
                            Spacer()
                        }
                        Text(axisDate(latest.date))
                    }.font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary)
                        .frame(width: width).offset(y: height + 11)
                } else {
                    Text("暂无资产记录").font(NativeStyle.FontRole.body).foregroundStyle(NativeHomeStyle.secondary)
                        .frame(width: width, height: height)
                }
                Rectangle().fill(NativeHomeStyle.line).frame(width: width, height: 0.7).offset(y: height)
                Color.clear.frame(width: width, height: height).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let next = nearest(min(1, max(0, p.x / width)))
                            if next != hovered { hovered = next; onHover?(next) }
                        case .ended: hovered = nil; onHover?(nil)
                        }
                    }
            }
            .padding(.leading, compact || goldAxisVisible ? 56 : 0)
            .overlay(alignment: .topLeading) {
                if (compact || goldAxisVisible) && !summaries.isEmpty {
                    ForEach(0..<4) { tick in
                        Text((goldAxisVisible ? "¥" : "") + (domain.low + domain.span * (1 - Double(tick) / 3)).formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "zh_CN"))))
                            .font(NativeStyle.FontRole.caption).monospacedDigit().foregroundStyle(NativePalette.secondary)
                            .lineLimit(1).minimumScaleFactor(0.9).frame(width: 50, alignment: .trailing)
                            .offset(y: height * CGFloat(tick) / 3 - 6)
                    }
                }
            }
            .onTapGesture { if let hovered { onSelect?(hovered) } }
        }.onAppear(perform: refreshPlot)
            .onChange(of: revision) { _, _ in refreshPlot() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("资产走势")
            .accessibilityValue(summaries.last.map {
                "总资产 " + NativeHomeStyle.amount($0.totalAssets) + "，净资产 " + NativeHomeStyle.amount($0.totalAssets - $0.totalLiabilities)
                    + (showsGoldEquivalent ? "，" + AppLocalization.string("等值黄金") + " "
                        + (NativeGoldEquivalentPlot.value($0).map { $0.formatted(.number.precision(.fractionLength(0...4))) + " g" } ?? "—") : "")
            } ?? "暂无资产记录")
    }
    private func axisDate(_ date: Date) -> String {
        if compact {
            return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).locale(AppLocalization.currentLocale))
        }
        return date.formatted(.dateTime.month().day().locale(AppLocalization.currentLocale))
    }
    private func nearest(_ ratio: Double) -> Int? {
        guard let first = summaries.first, let last = summaries.last else { return nil }
        let target = first.date.timeIntervalSinceReferenceDate + ratio * last.date.timeIntervalSince(first.date)
        var low = 0, high = summaries.count
        while low < high {
            let mid = (low + high) / 2
            if summaries[mid].date.timeIntervalSinceReferenceDate < target { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return 0 }
        if low == summaries.count { return low - 1 }
        return abs(summaries[low - 1].date.timeIntervalSinceReferenceDate - target)
            <= abs(summaries[low].date.timeIntervalSinceReferenceDate - target) ? low - 1 : low
    }
    private func endpoint(_ label: String, _ value: Double, _ color: Color, point: CGPoint,
                          width: Double, height: Double, labelOffset: Double = 0) -> some View {
        ZStack(alignment: .topLeading) {
            Circle().fill(color).frame(width: 7, height: 7).offset(x: width - 3.5, y: point.y * height - 3.5)
            VStack(alignment: .leading, spacing: NativeStyle.Space.xxs) {
                Text(label).font(NativeStyle.FontRole.micro)
                Text(value.formatted(.number.precision(.fractionLength(2)))).font(NativeStyle.FontRole.inputStrong).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75).contentTransition(reduced ? .opacity : .numericText())
            }.foregroundStyle(color).frame(width: 80, alignment: .leading)
                .offset(x: width + 13, y: min(max(0, point.y * height - 23 + labelOffset), height - 35))
        }
    }
}

struct NativeWorkspaceMetric: View {
    let title: String
    let value: Double
    var primary = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(NativeStyle.FontRole.body).foregroundStyle(NativeHomeStyle.secondary)
            Text(primary ? NativeHomeStyle.amount(value) : value.formatted(.number.precision(.fractionLength(2))))
                .font(primary ? NativeStyle.FontRole.display : NativeStyle.FontRole.metric).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(reduced || NativeHomeStyle.previewReduced ? .opacity : .numericText())
        }.frame(maxWidth: .infinity, alignment: .leading)
            .animation(NativeStyle.Motion.home(reduced || NativeHomeStyle.previewReduced), value: value)
    }
}
