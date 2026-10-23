import AppKit
import SwiftData
import SwiftUI

struct NativeHomeEdgeLight: View {
    var body: some View {
        // Decorative lighting stays static so an untouched window has no animation clock.
        Canvas { graphics, size in
            var curve = Path()
            curve.move(to: CGPoint(x: 0, y: size.height - 3))
            curve.addQuadCurve(to: CGPoint(x: size.width, y: size.height - 3),
                               control: CGPoint(x: size.width * 0.5, y: size.height - 64))
            var bloom = graphics
            bloom.addFilter(.blur(radius: 13))
            bloom.stroke(curve, with: .color(NativeHomeStyle.accent.opacity(0.18)), lineWidth: 12)
            var edge = graphics
            edge.addFilter(.blur(radius: 1))
            edge.stroke(curve, with: .color(NativeHomeStyle.accent.opacity(0.27)), lineWidth: 1)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

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
    let openSettings: () -> Void
    @AppStorage("dashboard.monthlyExpense", store: HomePreferences.defaults) private var monthlyExpense = 3000.0
    @AppStorage("dashboard.monthlySalary", store: HomePreferences.defaults) private var monthlySalary = 10000.0
    @AppStorage("dashboard.annualReturnRate", store: HomePreferences.defaults) private var annualReturnRate = 0.03
    @AppStorage("dashboard.inflationRate", store: HomePreferences.defaults) private var inflationRate = 0.05
    @State private var latestSnapshot: AssetSnapshot?
    @State private var latestSnapshotContext: ModelContext?
    @State private var range = 1
    @State private var parameters = false
    @Namespace private var rangeSelection
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
            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    header(width: geometry.size.width).frame(height: NativeStyle.Layout.homeHeaderHeight)
                    rangeControl.frame(height: NativeStyle.Control.height)
                    NativePanoramaTrend(summaries: visibleTrend, revision: "\(history.generation)-\(range)")
                        .frame(height: min(NativeStyle.Layout.homeChartMaxHeight, max(150, geometry.size.height - 400))).padding(.top, NativeStyle.Space.xxs)
                    rule.padding(.top, NativeStyle.Layout.sectionGap)
                    bottom(width: geometry.size.width - NativeStyle.Layout.pageInset * 2).padding(.top, NativeStyle.Layout.sectionGap)
                    if let error = history.error {
                        HStack {
                            Text(error).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.accentOrange)
                            Button("重试") { Task { await history.load(from: context.container, force: true) } }
                                .buttonStyle(NativeHomeButtonStyle())
                        }.padding(.top, NativeStyle.Space.sm).transition(.opacity)
                    }
                    Spacer(minLength: 12)
                }.padding(NativeStyle.Layout.pageInset)
                    .allowsHitTesting(!parameters)
                if parameters {
                    NativeHomeStyle.ink.opacity(0.55).contentShape(Rectangle())
                        .onTapGesture { parameters = false }.transition(.opacity)
                    NativeHomeParameters(monthlyExpense: $monthlyExpense, monthlySalary: $monthlySalary,
                                         annualReturnRate: $annualReturnRate, inflationRate: $inflationRate) {
                        parameters = false
                    }
                    .padding(.leading, min(260, max(20, geometry.size.width - 390)))
                    .padding(.bottom, 48)
                    .transition(reduced ? .opacity : .offset(y: 14).combined(with: .opacity))
                    .zIndex(1)
                }
            }.animation(NativeStyle.Motion.home(reduced), value: parameters)
        }
        .foregroundStyle(NativeHomeStyle.text).background(NativeHomeStyle.ink)
        .task(id: history.generation) { loadLatestSnapshot() }
        .onDisappear { latestSnapshot = nil; latestSnapshotContext = nil }
        .onExitCommand { parameters = false }
        .animation(NativeStyle.Motion.home(reduced), value: history.generation)
        .animation(NativeStyle.Motion.home(reduced), value: history.loading)
        .animation(NativeStyle.Motion.home(reduced), value: history.error)

    }
    private var rule: some View { Rectangle().fill(NativeHomeStyle.line).frame(height: 0.7) }
    private func header(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: width < 800 ? 12 : 20) {
            VStack(alignment: .leading, spacing: 9) {
                Text("净资产").font(NativeStyle.FontRole.section).foregroundStyle(NativeHomeStyle.secondary)
                Text(NativeHomeStyle.amount(net)).font(NativeStyle.FontRole.display).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(reduced ? .opacity : .numericText())
            }.frame(width: width < 800 ? 205 : 235, alignment: .leading)
            Rectangle().fill(NativeHomeStyle.line).frame(width: 0.7, height: 44).padding(.top, 22)
            metric("总资产", total).padding(.top, 22)
            Rectangle().fill(NativeHomeStyle.line).frame(width: 0.7, height: 44).padding(.top, 22)
            metric("负债", debt).padding(.top, 22)
            Spacer(minLength: 0)
            HStack(spacing: 13) {
                Button(action: openSettings) {
                    if width < 760 {
                        Image(systemName: cloud.indicatorState.cloudSymbolName)
                            .font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary)
                            .frame(width: 20, height: NativeStyle.Control.height)
                            .help(cloud.indicatorLabel)
                    } else {
                        Label(cloud.indicatorLabel, systemImage: cloud.indicatorState.cloudSymbolName)
                            .font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary)
                            .padding(.vertical, NativeStyle.Space.sm).lineLimit(1)
                    }
                }.buttonStyle(NativeHomeButtonStyle()).accessibilityLabel(cloud.indicatorLabel + "，云同步设置")
                Button(action: openRecords) {
                    Label("记录资产", systemImage: "plus").font(NativeStyle.FontRole.action).fixedSize()
                        .foregroundStyle(NativePalette.onAccent).padding(.horizontal, 13).frame(height: NativeStyle.Control.fieldHeight)
                        .background(NativePalette.accent, in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
                }.buttonStyle(NativeHomeButtonStyle())
            }.padding(.top, NativeStyle.Space.sm)
        }.animation(NativeStyle.Motion.home(reduced), value: net)
            .animation(NativeStyle.Motion.home(reduced), value: cloud.indicatorLabel)
    }
    private func metric(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            Text(NativeHomeStyle.amount(value)).font(NativeStyle.FontRole.subheading).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75).contentTransition(reduced ? .opacity : .numericText())
        }.frame(minWidth: 85, alignment: .leading)
    }
    private var rangeControl: some View {
        HStack {
            Text("资产走势").font(NativeStyle.FontRole.section)
            if history.loading { ProgressView().controlSize(.mini).accessibilityLabel("加载资产记录") }
            Spacer()
            HStack(spacing: 10) {
                ForEach(0..<4) { i in
                    Button { range = i } label: {
                        Text(labels[i]).font(NativeStyle.FontRole.caption).foregroundStyle(range == i ? NativeHomeStyle.accent : NativeHomeStyle.secondary)
                            .frame(width: 41, height: 31)
                            .overlay(alignment: .bottom) {
                                if range == i {
                                    if reduced { Rectangle().fill(NativeHomeStyle.accent).frame(height: 1) }
                                    else { Rectangle().fill(NativeHomeStyle.accent).frame(height: 1).matchedGeometryEffect(id: "range", in: rangeSelection) }
                                }
                            }
                    }.buttonStyle(NativeHomeButtonStyle()).accessibilityAddTraits(range == i ? .isSelected : [])
                }
            }
        }.animation(NativeStyle.Motion.home(reduced), value: range)
    }
    private func bottom(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: NativeStyle.Space.xl) {
            NativeHomeComposition(snapshot: latestSnapshot).frame(width: width * 0.25)
            Rectangle().fill(NativeHomeStyle.line.opacity(0.5)).frame(width: 0.7, height: NativeStyle.Layout.homeDetailsHeight)
            VStack(alignment: .leading, spacing: NativeStyle.Space.md) {
                Text("财务自由").font(NativeStyle.FontRole.section)
                Text("\(Int(min(freedom, 1) * 100))%").font(NativeStyle.FontRole.display).monospacedDigit()
                    .contentTransition(reduced ? .opacity : .numericText())
                Button { parameters = true } label: {
                    Label("参数", systemImage: "slider.horizontal.3").font(NativeStyle.FontRole.body)
                        .padding(.horizontal, 14).frame(height: NativeStyle.Control.fieldHeight)
                        .background(NativeHomeStyle.text.opacity(0.035), in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.control).stroke(NativeHomeStyle.line, lineWidth: 0.7))
                }.buttonStyle(NativeHomeButtonStyle())
            }.frame(width: width * 0.155, alignment: .leading)
                .animation(NativeStyle.Motion.home(reduced), value: freedom)
            Rectangle().fill(NativeHomeStyle.line.opacity(0.5)).frame(width: 0.7, height: NativeStyle.Layout.homeDetailsHeight)
            ledger.frame(maxWidth: .infinity)
        }.frame(height: NativeStyle.Layout.homeDetailsHeight, alignment: .top)
    }
    private var ledger: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("最近记录").font(NativeStyle.FontRole.section).padding(.bottom, 5)
            HStack { cell("日期", leading: true); cell("总资产"); cell("净资产"); cell("负债") }
                .font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary)
            rule
            if history.summaries.isEmpty {
                Text("暂无资产记录").font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary).padding(.top, 10)
            } else {
                ForEach(history.summaries.suffix(5).reversed(), id: \.id) { record in
                    NativeHomeHoverRow {
                        HStack {
                            cell(record.date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))), leading: true)
                            cell(record.totalAssets.formatted(.number.precision(.fractionLength(2))))
                            cell((record.totalAssets - record.totalLiabilities).formatted(.number.precision(.fractionLength(2))))
                            cell(record.totalLiabilities.formatted(.number.precision(.fractionLength(2))))
                        }.font(NativeStyle.FontRole.micro).monospacedDigit().frame(height: 18)
                            .contentTransition(reduced ? .opacity : .numericText())
                    }
                    rule
                }
            }
        }
    }
    private func cell(_ text: String, leading: Bool = false) -> some View {
        Text(text).frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .lineLimit(1).minimumScaleFactor(0.75)
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
            .foregroundStyle(hovered ? NativeHomeStyle.text : NativeHomeStyle.secondary)
            .background(NativeHomeStyle.accent.opacity(hovered ? 0.075 : 0), in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
            .onHover { hovered = $0 }.animation(NativeStyle.Motion.home(reduced), value: hovered)
    }
}

private struct NativeHomeComposition: View {
    let snapshot: AssetSnapshot?
    private var slices: [(name: String, amount: Double)] {
        guard let snapshot else { return [] }
        let grouped = Dictionary(grouping: snapshot.entries.filter {
            $0.item?.category?.group != .liability && $0.resolvedAmount > 0
        }, by: { $0.item?.name ?? "其他" })
        let all = grouped.map { (name: $0.key, amount: $0.value.reduce(0) { $0 + $1.resolvedAmount }) }
            .sorted { $0.amount > $1.amount }
        if all.count <= 5 { return all }
        return Array(all.prefix(5)) + [(name: "其他", amount: all.dropFirst(5).reduce(0) { $0 + $1.amount })]
    }
    var body: some View {
        let values = slices
        let total = values.reduce(0) { $0 + $1.amount }
        VStack(alignment: .leading, spacing: NativeStyle.Space.xs) {
            Text("资产构成").font(NativeStyle.FontRole.section).padding(.bottom, NativeStyle.Space.xs)
            if total > 0 {
                ForEach(values.indices, id: \.self) { i in
                    NativeHomeHoverRow {
                        HStack {
                            Text(values[i].name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text((values[i].amount / total).formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                        }.font(NativeStyle.FontRole.body).frame(height: 20)
                    }
                }
            } else {
                Text("暂无资产分布").font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary).padding(.top, 10)
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
        VStack(alignment: .leading, spacing: NativeStyle.Space.lg) {
            HStack {
                Text("财务自由参数").font(NativeStyle.FontRole.subheadingStrong)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(NativeHomeButtonStyle()).accessibilityLabel("关闭参数").keyboardShortcut(.escape, modifiers: [])
            }
            field("月开销", $draft[0], 0)
            field("月薪", $draft[1], 1)
            field("年化收益率", $draft[2], 2, percent: true)
            field("通胀率", $draft[3], 3, percent: true)
            if invalid { Text("请输入有效数值").font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.accentOrange).transition(.opacity) }
            HStack {
                Spacer()
                Button("完成", action: finish).font(NativeStyle.FontRole.body).padding(.horizontal, 18).frame(height: NativeStyle.Control.height)
                    .background(NativeHomeStyle.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
                    .buttonStyle(NativeHomeButtonStyle()).keyboardShortcut(.return, modifiers: [])
            }
        }.padding(22).frame(width: 350)
            .background(NativePalette.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(NativeHomeStyle.text.opacity(0.18), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            .onAppear { focus = 0 }
            .onExitCommand(perform: close)
            .animation(NativeStyle.Motion.home(reduced), value: invalid)
    }
    private func field(_ label: String, _ binding: Binding<Double>, _ index: Int, percent: Bool = false) -> some View {
        HStack {
            Text(label).font(NativeStyle.FontRole.body).foregroundStyle(NativeHomeStyle.secondary)
            Spacer()
            Group {
                if percent { TextField(label, value: binding, format: .percent) }
                else { TextField(label, value: binding, format: .number) }
            }.textFieldStyle(.plain).font(NativeStyle.FontRole.input).monospacedDigit()
                .multilineTextAlignment(.trailing).onSubmit(finish)
                .padding(NativeStyle.Space.sm).frame(width: 115)
                .background(NativeHomeStyle.text.opacity(focus == index ? 0.08 : 0.025), in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.control).stroke(focus == index ? NativeHomeStyle.accent.opacity(0.75) : NativeHomeStyle.line, lineWidth: 0.8))
                .focused($focus, equals: index).animation(NativeStyle.Motion.home(reduced), value: focus)
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
    var animatableData: NativePanoramaVector { get { vector } set { vector = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in stride(from: 0, to: vector.values.count, by: 2) {
            let point = CGPoint(x: vector.values[i] * rect.width, y: vector.values[i + 1] * rect.height)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
struct NativePanoramaTrend: View {
    let summaries: [TimeMachineSnapshotProjection]
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var reduced: Bool { systemReduced || NativeHomeStyle.previewReduced }
    @State private var hovered: Int?
    let revision: String
    var netOnly = false
    var selection: Int? = nil
    var onHover: ((Int?) -> Void)? = nil
    var onSelect: ((Int) -> Void)? = nil
    @State private var domain: (low: Double, span: Double) = (0, 1)
    @State private var totalVector = NativePanoramaVector.zero
    @State private var netVector = NativePanoramaVector.zero
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
        let values = summaries.flatMap { netOnly ? [$0.totalAssets - $0.totalLiabilities] : [$0.totalAssets, $0.totalAssets - $0.totalLiabilities] }
        let low = values.min() ?? 0, high = values.max() ?? 1
        let span = max(high - low, max(abs(high) * 0.02, 1))
        let scale = (low: low - span * 0.1, span: span * 1.27)
        let sampled = NativeStaticTrendCanvas.sample(summaries, limit: 600)
        func vector(net: Bool) -> NativePanoramaVector {
            var points = sampled.map { point($0.element, net: net, scale: scale) }
            points += Array(repeating: points.last ?? .zero, count: 600 - points.count)
            return .init(values: points.flatMap { [Double($0.x), Double($0.y)] })
        }
        domain = scale
        totalVector = vector(net: false)
        netVector = vector(net: true)
        hovered = nil
    }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 90)
            let height = max(1, geometry.size.height - 25)
            let total = totalVector, net = netVector
            ZStack(alignment: .topLeading) {
                if let latest = summaries.last {
                    Group {
                        if !netOnly { NativePanoramaLine(vector: total).stroke(NativePalette.chartSecondary, lineWidth: 1.15) }
                        NativePanoramaLine(vector: net).stroke(NativeHomeStyle.accent, lineWidth: 1.15)
                    }.frame(width: width, height: height)
                        .animation(reduced ? nil : NativeStyle.Motion.home(false), value: total)
                        .animation(reduced ? nil : NativeStyle.Motion.home(false), value: net)
                    let totalPoint = point(latest, net: false), netPoint = point(latest, net: true)
                    Path { p in p.move(to: CGPoint(x: width, y: 0)); p.addLine(to: CGPoint(x: width, y: height)) }
                        .stroke(NativeHomeStyle.text.opacity(0.3), style: StrokeStyle(lineWidth: 0.7, dash: [4, 4]))
                    if !netOnly { endpoint("总资产", latest.totalAssets, NativePalette.chartSecondary, point: totalPoint, width: width, height: height) }
                    endpoint("净资产", latest.totalAssets - latest.totalLiabilities, NativeHomeStyle.accent, point: netPoint,
                             width: width, height: height, labelOffset: !netOnly && abs(totalPoint.y - netPoint.y) * height < 42 ? 42 : 0)
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
                        VStack(alignment: .leading, spacing: 5) {
                            Text(summary.date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))))
                            if !netOnly { Text("总资产 " + NativeHomeStyle.amount(summary.totalAssets)) }
                            Text("净资产 " + NativeHomeStyle.amount(summary.totalAssets - summary.totalLiabilities))
                                .foregroundStyle(NativeHomeStyle.accent)
                        }.font(NativeStyle.FontRole.micro).monospacedDigit().padding(9)
                            .background(NativePalette.surface, in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
                            .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.control).stroke(NativeHomeStyle.line, lineWidth: 0.7))
                            .offset(x: min(max(0, p.x * width + 10), max(0, width - 160)), y: 0)
                    }
                    HStack {
                        Text(summaries.first!.date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))))
                        Spacer(); Text(latest.date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))))
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
                    .onTapGesture { if let hovered { onSelect?(hovered) } }
        }.onAppear(perform: refreshPlot)
            .onChange(of: revision) { _, _ in refreshPlot() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("资产走势")
            .accessibilityValue(summaries.last.map {
                "总资产 " + NativeHomeStyle.amount($0.totalAssets) + "，净资产 " + NativeHomeStyle.amount($0.totalAssets - $0.totalLiabilities)
            } ?? "暂无资产记录")
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

// Shared C/M2 surfaces used only by the three selected native workspace pages.
struct NativeWorkspaceSection<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.frame(maxWidth: .infinity, alignment: .leading) }
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
