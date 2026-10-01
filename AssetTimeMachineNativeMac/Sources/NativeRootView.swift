import AppKit
import AuthenticationServices
import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum NativePage: String, CaseIterable, Identifiable {
    case home = "首页", records = "记录", timeMachine = "时光机", quant = "量化", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: "house"
        case .records: "square.and.pencil"
        case .timeMachine: "clock.arrow.circlepath"
        case .quant: "chart.xyaxis.line"
        case .settings: "gearshape"
        }
    }
}

private final class NativePreviewTokenStore: CloudTokenStore {
    func loadAccessToken() -> String? { nil }
    func loadRefreshToken() -> String? { nil }
    func save(accessToken: String, refreshToken: String?) throws {}
    func clear() throws {}
}

/// Test-only presentation barrier: includes the SwiftUI update and AppKit drawing turn.
private final class NativeHoverSamples: ObservableObject {
    var milliseconds: [Double] = []
}

private struct NativeHoverPresentationProbe: NSViewRepresentable {
    let startedAt: UInt64
    let samples: NativeHoverSamples

    final class ProbeView: NSView {
        var startedAt: UInt64 = 0
        var lastRequest: UInt64 = 0
        var samples: NativeHoverSamples?
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard startedAt != 0 else { return }
            samples?.milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            startedAt = 0
        }
    }

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        guard startedAt != 0, view.lastRequest != startedAt else { return }
        view.lastRequest = startedAt
        view.samples = samples
        view.startedAt = startedAt
        view.needsDisplay = true
    }
}

@MainActor
final class NativeHistoryModel: ObservableObject {
    @Published private(set) var summaries: [TimeMachineSnapshotProjection] = []
    @Published private(set) var generation = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var requestedRevision: UInt64?

    func load(from container: ModelContainer, force: Bool = false) async {
        let revision = ModelStoreRevisionClock.shared.currentRevision()
        if !force, requestedRevision == revision { return }
        requestedRevision = revision
        loading = true
        error = nil
        do {
            summaries = try await BackgroundTaskWork.run {
                try await MacSnapshotSummaryCache.shared.projections(in: container, revision: revision)
            }
            guard NativeStaticTrendCanvas.validatesExtrema(summaries) else {
                throw NSError(domain: "NativeTrendSampler", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "历史曲线采样校验失败"])
            }
            generation &+= 1
        } catch {
            self.error = error.localizedDescription
            requestedRevision = nil
        }
        loading = false
    }
}

struct NativeRootView: View {
    let startsOffline: Bool
    @Environment(\.modelContext) private var context
    @StateObject private var cloud = NativeRootView.makeCloudStore()
    @StateObject private var history = NativeHistoryModel()
    @State private var page: NativePage = .home
    @State private var recordEditor = NativeRecordEditor()
    @State private var showsAccountChoice = false
    @State private var hasMadeAccountChoice = UserDefaults.standard.bool(forKey: "nativeMac.hasMadeAccountChoice")
    @Environment(\.scenePhase) private var scenePhase
    @State private var performanceTourStarted = false

    private static func makeCloudStore() -> AssetTimeMachineCloudStore {
        guard AppPreviewSession.isActive else { return AssetTimeMachineCloudStore() }
        // Fixture tours must not read or migrate the signed-in user's credentials.
        let defaults = UserDefaults(suiteName: "com.flyingrtx.AssetTimeMachine.preview.\(UUID().uuidString)")!
        return AssetTimeMachineCloudStore(tokenStore: NativePreviewTokenStore(), defaults: defaults)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(NativePalette.line).frame(width: 1)
            Group {
                switch page {
                case .home: NativeHomeView(history: history, cloud: cloud, openRecords: { page = .records })
                case .records: NativeRecordsView(history: history, cloud: cloud, editor: recordEditor)
                case .timeMachine: NativeTimeMachineView(history: history)
                case .quant: NativeQuantView(history: history)
                case .settings: NativeSettingsView(history: history, cloud: cloud)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NativePalette.canvas)
        }
        .frame(minWidth: 900, minHeight: 620)
        .onAppear {
            if AppPreviewSession.isActive { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .task {
            await history.load(from: context.container)
            let recordArguments = ProcessInfo.processInfo.arguments
            if AppPreviewSession.isActive,
               let index = recordArguments.firstIndex(of: "-macCloudSyncProbe"), recordArguments.indices.contains(index + 1) {
                let result = await NativeCloudSyncProbe.run()
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: recordArguments[index + 1]))
                }
                return
            }
            if AppPreviewSession.isActive,
               let index = recordArguments.firstIndex(of: "-macRecordEditorProbe"),
               recordArguments.indices.contains(index + 1) {
                let result = NativeRecordEditorProbe.run(container: context.container)
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: recordArguments[index + 1]))
                }
                await history.load(from: context.container, force: true)
                page = .records
            } else if AppPreviewSession.isActive && recordArguments.contains("-macRecordsPreview") {
                page = .records
            }
            if !AppPreviewSession.isActive && !startsOffline {
                if !hasMadeAccountChoice && !cloud.hasToken { showsAccountChoice = true }
                await cloud.refreshIfNeeded(from: context)
            }
            if ProcessInfo.processInfo.arguments.contains("-macPerfAutoBrowse"), !performanceTourStarted {
                performanceTourStarted = true
                Task { await runPerformanceTour() }
            }
            let arguments = ProcessInfo.processInfo.arguments
            if AppPreviewSession.isActive,
               let index = arguments.firstIndex(of: "-macPerfMutationOutput"),
               arguments.indices.contains(index + 1),
               let importIndex = arguments.firstIndex(of: "-macPerfImportJSON"),
               arguments.indices.contains(importIndex + 1) {
                let outcome = await NativeMutationProbe.run(
                    context: context, history: history,
                    importJSON: URL(fileURLWithPath: arguments[importIndex + 1])
                )
                if let data = try? JSONSerialization.data(withJSONObject: outcome, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: arguments[index + 1]))
                }
            }
            if AppPreviewSession.isActive,
               let index = arguments.firstIndex(of: "-macPerfVideoOutput"),
               arguments.indices.contains(index + 1) {
                let destination = URL(fileURLWithPath: arguments[index + 1])
                do {
                    let temporary = try await NativeTrendVideoExporter.export(history.summaries)
                    try FileManager.default.copyItem(at: temporary, to: destination)
                    try? FileManager.default.removeItem(at: temporary)
                } catch {
                    NSLog("[NativeMac] video probe failed: %@", String(describing: error))
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !AppPreviewSession.isActive, !startsOffline else { return }
            Task { await cloud.refreshIfNeeded(from: context) }
        }
        .onChange(of: cloud.localDataRevision) { _, _ in
            Task { await history.load(from: context.container, force: true) }
        }
        .sheet(isPresented: $showsAccountChoice) {
            NativeAccountChoice(cloud: cloud) {
                hasMadeAccountChoice = true
                UserDefaults.standard.set(true, forKey: "nativeMac.hasMadeAccountChoice")
                showsAccountChoice = false
            }
            .environment(\.modelContext, context)
        }
    }

    private func runPerformanceTour() async {
        let arguments = ProcessInfo.processInfo.arguments
        let rounds: Int = {
            guard let index = arguments.firstIndex(of: "-macPerfContinuousRounds"),
                  arguments.indices.contains(index + 1) else { return 1 }
            return min(max(Int(arguments[index + 1]) ?? 1, 1), 10)
        }()
        for round in 1...rounds {
            for destination in [NativePage.records, .timeMachine, .quant, .settings, .home] {
                page = destination
                try? await Task.sleep(for: destination == .timeMachine ? .seconds(5) : .seconds(1))
            }
            if let index = arguments.firstIndex(of: "-macPerfRoundMarkerPrefix"),
               arguments.indices.contains(index + 1) {
                try? "finished".write(toFile: "\(arguments[index + 1])-\(round).done",
                                      atomically: true, encoding: .utf8)
            }
            if round < rounds { try? await Task.sleep(for: .seconds(32)) }
        }
        if let index = arguments.firstIndex(of: "-macPerfCompletePath"), arguments.indices.contains(index + 1) {
            try? "finished".write(toFile: arguments[index + 1], atomically: true, encoding: .utf8)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(AssetTheme.gold)
                    .frame(width: 34, height: 34)
                    .background(NativePalette.softGold, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("资产时光机").font(.system(size: 14, weight: .semibold))
                    Text("记录资产 · 看见时间")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 24)
            .padding(.bottom, 20)

            ForEach(NativePage.allCases) { item in
                NativeSidebarButton(item: item, isSelected: page == item) {
                    guard page != item else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { page = item }
                }
            }
            Spacer()
            Button { page = .settings } label: {
                HStack(spacing: 7) {
                    Image(systemName: cloud.indicatorState.cloudSymbolName)
                        .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cloud.indicatorLabel).font(.system(size: 10, weight: .medium))
                        Text(cloud.currentUser == nil ? "登录后跨设备同步" : "查看云同步")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9))
                }
                .lineLimit(1)
                .foregroundStyle(cloud.currentUser == nil ? AssetTheme.gold : AssetTheme.positive)
                .padding(9)
                .background(NativePalette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(NativePalette.line))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .frame(width: 184)
        .background(NativePalette.sidebar)
    }
}

private struct NativeSidebarButton: View {
    let item: NativePage
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(item.rawValue, systemImage: item.symbol)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(
                    isSelected ? NativePalette.softGold :
                        (isHovered ? AssetTheme.gold.opacity(0.09) : .clear),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .foregroundStyle(isSelected || isHovered ? AssetTheme.gold : .primary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .padding(.horizontal, 8)
    }
}

struct NativePageHeader: View {
    let title: String
    let subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 24, weight: .semibold))
            if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NativePalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NativePalette.line))
    }
}

private func money(_ value: Double) -> String {
    value.formatted(.currency(code: "CNY").precision(.fractionLength(2)))
}

private func displayDate(_ date: Date) -> String {
    date.formatted(Date.FormatStyle().year().month().day().locale(Locale(identifier: "zh_CN")))
}

struct NativeHomeView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject var history: NativeHistoryModel
    @ObservedObject var cloud: AssetTimeMachineCloudStore
    let openRecords: () -> Void
    @AppStorage("dashboard.monthlyExpense") private var monthlyExpense = 3000.0
    @AppStorage("dashboard.monthlySalary") private var monthlySalary = 10000.0
    @AppStorage("dashboard.annualReturnRate") private var annualReturnRate = 0.03
    @AppStorage("dashboard.inflationRate") private var inflationRate = 0.05
    @State private var latestSnapshot: AssetSnapshot?
    @State private var latestSnapshotContext: ModelContext?
    @State private var showsFreedomSettings = false
    @State private var trendRange = 2

    private var latest: TimeMachineSnapshotProjection? { history.summaries.last }
    private var visibleTrend: [TimeMachineSnapshotProjection] {
        let days = [7, 30, 365, Int.max][trendRange]
        guard days < history.summaries.count else { return history.summaries }
        return Array(history.summaries.suffix(days))
    }
    private var freedomProgress: Double {
        let net = (latest?.totalAssets ?? 0) - (latest?.totalLiabilities ?? 0)
        return monthlyExpense > 0 ? max(0, net * annualReturnRate / 12 / monthlyExpense) : 0
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    NativePageHeader(title: "资产总览", subtitle: nil)
                    Label(cloud.indicatorLabel, systemImage: cloud.indicatorState.cloudSymbolName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(cloud.currentUser == nil ? AssetTheme.gold : AssetTheme.positive)
                }
                NativeCard {
                    HStack(spacing: 12) {
                        metric("总资产 (CNY)", latest?.totalAssets ?? 0)
                        Divider().frame(height: 38)
                        metric("净资产 (CNY)", (latest?.totalAssets ?? 0) - (latest?.totalLiabilities ?? 0))
                        Divider().frame(height: 38)
                        metric("总负债 (CNY)", latest?.totalLiabilities ?? 0)
                        Button("记录今日资产", systemImage: "plus.circle.fill", action: openRecords)
                            .font(.system(size: 11, weight: .semibold))
                            .buttonStyle(.borderedProminent)
                            .tint(AssetTheme.gold)
                            .controlSize(.regular)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    NativeCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("资产趋势").font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Picker("时间范围", selection: $trendRange) {
                                    Text("近 7 天").tag(0)
                                    Text("近 30 天").tag(1)
                                    Text("近 1 年").tag(2)
                                    Text("全部").tag(3)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .tint(AssetTheme.gold)
                                .frame(width: 250)
                                .controlSize(.small)
                            }
                            NativeHomeTrendChart(summaries: visibleTrend)
                                .id(trendRange)
                        }
                    }
                    NativeCard { NativeAssetCompositionView(snapshot: latestSnapshot) }
                    .frame(width: 315)
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("财务自由进度").font(.system(size: 14, weight: .semibold))
                            ProgressView(value: min(freedomProgress, 1))
                                .tint(AssetTheme.gold)
                            Text("\(Int(min(freedomProgress, 1) * 100))%")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(AssetTheme.gold)
                            Button("调整", systemImage: "slider.horizontal.3") { showsFreedomSettings = true }
                                .labelStyle(.iconOnly)
                        }
                        HStack {
                            freedomMetric("月开销", money(monthlyExpense))
                            freedomMetric("月薪", money(monthlySalary))
                            freedomMetric("年化收益", annualReturnRate.formatted(.percent.precision(.fractionLength(1))))
                            freedomMetric("通胀率", inflationRate.formatted(.percent.precision(.fractionLength(1))))
                            freedomMetric("年初至今结余", money((monthlySalary - monthlyExpense) * Double(Calendar.current.component(.month, from: .now))))
                        }
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最近的资产记录").font(.system(size: 14, weight: .semibold))
                        HStack {
                            Text("日期").frame(maxWidth: .infinity, alignment: .leading)
                            Text("总资产").frame(maxWidth: .infinity, alignment: .trailing)
                            Text("净资产").frame(maxWidth: .infinity, alignment: .trailing)
                            Text("总负债").frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        ForEach(history.summaries.suffix(5).reversed(), id: \.id) { snapshot in
                            HStack {
                                Text(displayDate(snapshot.date)).frame(maxWidth: .infinity, alignment: .leading)
                                Text(money(snapshot.totalAssets)).frame(maxWidth: .infinity, alignment: .trailing)
                                Text(money(snapshot.totalAssets - snapshot.totalLiabilities)).frame(maxWidth: .infinity, alignment: .trailing)
                                Text(money(snapshot.totalLiabilities)).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .font(.system(size: 11)).monospacedDigit()
                            Divider()
                        }
                        if history.summaries.isEmpty { Text("暂无资产记录").foregroundStyle(.secondary) }
                    }
                }
                if let error = history.error { Text(error).foregroundStyle(.red) }
            }
            .padding(22)
        }
        .task(id: history.generation) { loadLatestSnapshot() }
        .onDisappear { latestSnapshot = nil; latestSnapshotContext = nil }
        .sheet(isPresented: $showsFreedomSettings) {
            NativeFreedomSettings(
                monthlyExpense: $monthlyExpense, monthlySalary: $monthlySalary,
                annualReturnRate: $annualReturnRate, inflationRate: $inflationRate
            )
        }
    }
    private func metric(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(money(value)).font(.system(size: 18, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func freedomMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func loadLatestSnapshot() {
        guard let id = latest?.id else { latestSnapshot = nil; return }
        do {
            var descriptor = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            let reader = ModelContext(context.container)
            reader.autosaveEnabled = false
            latestSnapshotContext = reader
            latestSnapshot = try reader.fetch(descriptor).first
        } catch { latestSnapshot = nil; latestSnapshotContext = nil }
    }
}

private struct NativeAssetCompositionView: View {
    let snapshot: AssetSnapshot?
    private struct Slice: Identifiable {
        let id: String
        let amount: Double
        let color: Color
    }
    private var slices: [Slice] {
        guard let snapshot else { return [] }
        let grouped = Dictionary(grouping: snapshot.entries.filter {
            $0.item?.category?.group != .liability && $0.resolvedAmount > 0
        }, by: { $0.item?.name ?? "其他" })
        let sorted = grouped.map { (name: $0.key, amount: $0.value.reduce(0) { $0 + $1.resolvedAmount }) }
            .sorted { $0.amount > $1.amount }
        let colors: [Color] = [AssetTheme.gold, .cyan, .green, .purple, .orange, .pink]
        if sorted.count <= 5 {
            return sorted.enumerated().map { Slice(id: $0.element.name, amount: $0.element.amount,
                                                   color: colors[$0.offset]) }
        }
        var result = sorted.prefix(5).enumerated().map {
            Slice(id: $0.element.name, amount: $0.element.amount, color: colors[$0.offset])
        }
        result.append(Slice(id: "__other__", amount: sorted.dropFirst(5).reduce(0) { $0 + $1.amount }, color: colors[5]))
        return result
    }
    var body: some View {
        let values = slices
        let total = values.reduce(0) { $0 + $1.amount }
        VStack(alignment: .leading, spacing: 14) {
            Text("资产构成").font(.system(size: 14, weight: .semibold))
            if total > 0 {
                HStack(alignment: .center, spacing: 15) {
                    ZStack {
                        ForEach(values.indices, id: \.self) { index in
                            let start = values.prefix(index).reduce(0) { $0 + $1.amount } / total
                            let end = start + values[index].amount / total
                            Circle()
                                .trim(from: start, to: end)
                                .stroke(values[index].color, style: StrokeStyle(lineWidth: 15, lineCap: .butt))
                                .rotationEffect(.degrees(-90))
                        }
                        Text("总资产").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(width: 116, height: 116)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(values) { slice in
                            HStack(spacing: 5) {
                                Circle().fill(slice.color).frame(width: 6, height: 6)
                                Text(slice.id == "__other__" ? "其他" : slice.id).lineLimit(1)
                                Spacer(minLength: 2)
                                Text((slice.amount / total).formatted(.percent.precision(.fractionLength(0))))
                                    .monospacedDigit()
                            }
                            .font(.system(size: 10))
                        }
                    }
                }
                .frame(height: 238)
            } else {
                ContentUnavailableView("暂无资产分布", systemImage: "chart.pie")
                    .frame(height: 220)
            }
        }
    }
}

private struct NativeFreedomSettings: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var monthlyExpense: Double
    @Binding var monthlySalary: Double
    @Binding var annualReturnRate: Double
    @Binding var inflationRate: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("财务自由假设").font(.system(size: 18, weight: .semibold))
            Form {
                TextField("月开销", value: $monthlyExpense, format: .number)
                TextField("月薪", value: $monthlySalary, format: .number)
                TextField("年化收益率", value: $annualReturnRate, format: .percent)
                TextField("通胀率", value: $inflationRate, format: .percent)
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}

struct NativeTimeMachineView: View {
    private struct DetailRow: Identifiable {
        let id: UUID
        let name: String
        let amount: Double
        let order: Int
    }
    @Environment(\.modelContext) private var context
    @ObservedObject var history: NativeHistoryModel
    @State private var selectedIndex: Int?
    @State private var hoveredIndex: Int?
    @State private var selectedSnapshot: AssetSnapshot?
    @State private var detailRows: [DetailRow] = []
    @State private var detailError: String?
    @State private var videoTask: Task<Void, Never>?
    @State private var isExportingVideo = false
    @State private var videoError: String?
    @State private var detailFetchSamples: [Double] = []
    @StateObject private var hoverSamples = NativeHoverSamples()
    @State private var hoverStartedAt: UInt64 = 0
    @State private var visibleMonths = 6
    @State private var chartData: [TimeMachineSnapshotProjection] = []
    @State private var chartStart = 0

    private var summaries: [TimeMachineSnapshotProjection] { history.summaries }
    private var activeIndex: Int? { hoveredIndex ?? selectedIndex }
    private var active: TimeMachineSnapshotProjection? {
        guard let activeIndex, summaries.indices.contains(activeIndex) else { return nil }
        return summaries[activeIndex]
    }
    private var chartSelectedIndex: Int? {
        guard let selectedIndex else { return nil }
        let translated = selectedIndex - chartStart
        return chartData.indices.contains(translated) ? translated : nil
    }
    private var selectedNet: Double {
        guard let selectedIndex, summaries.indices.contains(selectedIndex) else { return 0 }
        return summaries[selectedIndex].totalAssets - summaries[selectedIndex].totalLiabilities
    }
    private var dateRailIndices: [Int] {
        guard !summaries.isEmpty else { return [] }
        let center = selectedIndex ?? summaries.count - 1
        let lower = max(0, min(center - 4, summaries.count - 9))
        return Array(lower..<min(lower + 9, summaries.count))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    NativePageHeader(title: "时光机", subtitle: "移动鼠标预览，单击固定日期")
                    if history.loading || isExportingVideo { ProgressView().controlSize(.small) }
                    Picker("时间范围", selection: $visibleMonths) {
                        Text("近 6 个月").tag(6)
                        Text("近 1 年").tag(12)
                        Text("近 5 年").tag(60)
                        Text("全部").tag(1200)
                    }
                    .labelsHidden().frame(width: 120)
                    Button("导出趋势视频", systemImage: "play.rectangle") { startVideoExport() }
                        .labelStyle(.iconOnly)
                        .disabled(isExportingVideo || summaries.count < 2)
                }
                NativeCard {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(active.map { displayDate($0.date) } ?? "选择日期")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            Text(money((active?.totalAssets ?? 0) - (active?.totalLiabilities ?? 0)))
                                .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                            Text("净资产").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        summaryMetric("总资产", active?.totalAssets ?? 0)
                        summaryMetric("总负债", active?.totalLiabilities ?? 0)
                        if let index = activeIndex, index > 0 {
                            let current = summaries[index]
                            let previous = summaries[index - 1]
                            let difference = current.totalAssets - current.totalLiabilities
                                - previous.totalAssets + previous.totalLiabilities
                            summaryMetric("较上次", difference)
                        }
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("资产趋势").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Label("总资产", systemImage: "circle.fill").foregroundStyle(AssetTheme.gold)
                            Label("净资产", systemImage: "circle.fill").foregroundStyle(AssetTheme.positive)
                        }
                        .font(.system(size: 10))
                        NativeTrendCanvas(
                            summaries: chartData,
                            selectedIndex: chartSelectedIndex,
                            hoveredIndex: Binding(
                                get: {
                                    guard let hoveredIndex else { return nil }
                                    let local = hoveredIndex - chartStart
                                    return chartData.indices.contains(local) ? local : nil
                                },
                                set: { local in
                                    let global = local.map { $0 + chartStart }
                                    if hoveredIndex != global { hoveredIndex = global }
                                }
                            ),
                            onSelect: { selectedIndex = $0 + chartStart; hoveredIndex = nil }
                        )
                        .frame(height: 220)
                        HStack {
                            Text("移动鼠标预览 · 单击曲线固定日期")
                            Spacer()
                            Text("共 \(summaries.count) 条记录")
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("历史日期").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button { selectedIndex = max(0, (selectedIndex ?? summaries.count - 1) - 1) } label: {
                                Image(systemName: "chevron.left")
                            }.disabled((selectedIndex ?? 0) <= 0)
                            Button { selectedIndex = min(summaries.count - 1, (selectedIndex ?? 0) + 1) } label: {
                                Image(systemName: "chevron.right")
                            }.disabled((selectedIndex ?? 0) >= summaries.count - 1)
                        }
                        HStack(spacing: 5) {
                            ForEach(dateRailIndices, id: \.self) { index in
                                let day = summaries[index]
                                Button { selectedIndex = index; hoveredIndex = nil } label: {
                                    VStack(spacing: 3) {
                                        Text(dateRailLabel(at: index))
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(money(day.totalAssets - day.totalLiabilities))
                                            .font(.system(size: 9)).monospacedDigit().lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .foregroundStyle(selectedIndex == index ? AssetTheme.gold : .primary)
                                    .background(selectedIndex == index ? NativePalette.softGold : NativePalette.canvas,
                                                in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    NativeCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("当天资产明细").font(.system(size: 14, weight: .semibold))
                            Divider()
                            if selectedSnapshot != nil {
                                ForEach(detailRows) { entry in
                                    HStack {
                                        Text(entry.name).lineLimit(1)
                                        Spacer()
                                        Text(money(entry.amount)).monospacedDigit()
                                    }
                                    .font(.system(size: 11))
                                    .padding(.vertical, 4)
                                    Divider()
                                }
                            } else {
                                Text(detailError ?? "选择日期查看明细")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    NativeCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("当日概览").font(.system(size: 14, weight: .semibold))
                            Divider()
                            reportRow("净资产", money(selectedNet))
                            if let index = selectedIndex, index > 0 {
                                let previous = summaries[index - 1]
                                reportRow("较上次变化", money(selectedNet - previous.totalAssets + previous.totalLiabilities))
                            }
                            reportRow("资产项目", "\(detailRows.count) 项")
                            reportRow("记录时间", selectedSnapshot.map { displayDate($0.date) } ?? "—")
                        }
                    }
                    .frame(width: 250)
                }
                if let detailError { Text(detailError).font(.system(size: 10)).foregroundStyle(.red) }
                if let videoError { Text(videoError).font(.system(size: 10)).foregroundStyle(.red) }
            }
            .padding(22)
        }
        .overlay(alignment: .topLeading) {
            if AppPreviewSession.isActive,
               ProcessInfo.processInfo.arguments.contains("-macPerfInteractionOutput") {
                NativeHoverPresentationProbe(startedAt: hoverStartedAt, samples: hoverSamples)
                    .frame(width: 1, height: 1).allowsHitTesting(false)
            }
        }
        .onChange(of: selectedIndex) { _, newIndex in loadDetail(at: newIndex) }
        .onChange(of: visibleMonths) { _, _ in rebuildChartData() }
        .onChange(of: history.generation) { _, _ in rebuildChartData() }
        .onChange(of: summaries.count) { _, count in
            if selectedIndex == nil, count > 0 { selectedIndex = count - 1 }
        }
        .onAppear {
            rebuildChartData()
            if selectedIndex == nil, !summaries.isEmpty { selectedIndex = summaries.count - 1 }
        }
        .onDisappear {
            selectedSnapshot = nil
            detailRows = []
            chartData = []
            hoveredIndex = nil
            videoTask?.cancel()
            videoTask = nil
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-macPerfAutoBrowse"), summaries.count > 1 else { return }
            visibleMonths = 1200
            try? await Task.sleep(for: .milliseconds(100))
            let step = max(1, summaries.count / 150)
            for (position, index) in stride(from: 0, to: summaries.count, by: step).enumerated() {
                guard !Task.isCancelled else { break }
                hoverStartedAt = DispatchTime.now().uptimeNanoseconds
                hoveredIndex = index
                if position.isMultiple(of: 15) { selectedIndex = index }
                try? await Task.sleep(for: .milliseconds(15))
            }
            hoveredIndex = nil
            selectedIndex = summaries.count - 1
            try? await Task.sleep(for: .milliseconds(100))
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-macPerfInteractionOutput"),
               arguments.indices.contains(index + 1), !detailFetchSamples.isEmpty {
                let sorted = detailFetchSamples.sorted()
                let position = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
                var result: [String: Double] = [
                    "detailFetchP95Milliseconds": sorted[position],
                    "sampleCount": Double(sorted.count)
                ]
                let hover = hoverSamples.milliseconds.sorted()
                if !hover.isEmpty {
                    let p95 = min(hover.count - 1, Int(ceil(Double(hover.count) * 0.95)) - 1)
                    result["hoverPresentationP95Milliseconds"] = hover[p95]
                    result["hoverSampleCount"] = Double(hover.count)
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: arguments[index + 1]))
                }
            }
        }
    }
    private func rebuildChartData() {
        guard !summaries.isEmpty else {
            chartStart = 0
            chartData = []
            return
        }
        chartStart = chartStartIndex
        chartData = Array(summaries[chartStart...])
    }
    private var chartStartIndex: Int {
        guard let last = summaries.last else { return 0 }
        let cutoff = Calendar.current.date(byAdding: .month, value: -visibleMonths, to: last.date) ?? .distantPast
        var lower = 0
        var upper = summaries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if summaries[middle].date < cutoff { lower = middle + 1 } else { upper = middle }
        }
        return min(lower, summaries.count - 1)
    }
    private func reportRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
    }
    private func dateRailLabel(at index: Int) -> String {
        let day = summaries[index].date
        let repeated = (index > 0 && Calendar.current.isDate(day, inSameDayAs: summaries[index - 1].date))
            || (index + 1 < summaries.count && Calendar.current.isDate(day, inSameDayAs: summaries[index + 1].date))
        if repeated { return day.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()) }
        return day.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
    private func summaryMetric(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(money(value)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }.padding(.leading, 18)
    }
    private func loadDetail(at index: Int?) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            if AppPreviewSession.isActive, ProcessInfo.processInfo.arguments.contains("-macPerfInteractionOutput") {
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                detailFetchSamples.append(Double(elapsed) / 1_000_000)
            }
        }
        selectedSnapshot = nil
        detailRows = []
        detailError = nil
        guard let index, summaries.indices.contains(index) else { return }
        let id = summaries[index].id
        do {
            var descriptor = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            selectedSnapshot = try context.fetch(descriptor).first
            if let selectedSnapshot {
                let amounts = PortfolioCalculator.metrics(for: selectedSnapshot)
                let summary = summaries[index]
                if abs(amounts.totalAssets - summary.totalAssets) > 0.01
                    || abs(amounts.totalLiabilities - summary.totalLiabilities) > 0.01 {
                    detailError = "所选日期明细与历史汇总不一致，请重新载入。"
                    self.selectedSnapshot = nil
                } else {
                    detailRows = selectedSnapshot.entries
                        .filter { abs($0.resolvedAmount) > 0.005 }
                        .map { DetailRow(id: $0.id, name: $0.item?.name ?? "未知资产",
                                         amount: $0.resolvedAmount, order: $0.item?.sortOrder ?? 0) }
                        .sorted { $0.order < $1.order }
                }
            }
        } catch { detailError = error.localizedDescription }
    }

    private func startVideoExport() {
        guard videoTask == nil else { return }
        videoError = nil
        isExportingVideo = true
        let source = summaries
        videoTask = Task {
            do {
                let temporaryURL = try await NativeTrendVideoExporter.export(source)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                try Task.checkCancellation()
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.mpeg4Movie]
                panel.nameFieldStringValue = "资产时光机趋势.mp4"
                if panel.runModal() == .OK, let destination = panel.url {
                    try FileManager.default.copyItem(at: temporaryURL, to: destination)
                    NSWorkspace.shared.open(destination)
                }
            } catch is CancellationError {
                // Leaving Time Machine cancels video generation and releases its frame buffers.
            } catch {
                videoError = error.localizedDescription
            }
            isExportingVideo = false
            videoTask = nil
        }
    }
}

private struct NativeHomeTrendChart: View {
    let summaries: [TimeMachineSnapshotProjection]
    @State private var hoveredIndex: Int?

    private var activeSummary: TimeMachineSnapshotProjection? {
        if let hoveredIndex, summaries.indices.contains(hoveredIndex) {
            return summaries[hoveredIndex]
        }
        return summaries.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NativeTrendCanvas(summaries: summaries, selectedIndex: nil,
                              hoveredIndex: $hoveredIndex, allowsHover: true)
                .frame(height: 205)
            HStack(spacing: 12) {
                Text(activeSummary.map { displayDate($0.date) } ?? "暂无记录")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("总资产 " + money(activeSummary?.totalAssets ?? 0))
                    .foregroundStyle(AssetTheme.gold)
                Text("净资产 " + money((activeSummary?.totalAssets ?? 0)
                                      - (activeSummary?.totalLiabilities ?? 0)))
                    .foregroundStyle(Color(red: 0.32, green: 0.72, blue: 0.51))
            }
            .font(.system(size: 10))
            .monospacedDigit()
        }
        .onChange(of: summaries.count) { _, _ in hoveredIndex = nil }
    }
}

private struct NativeTrendCanvas: View {
    let summaries: [TimeMachineSnapshotProjection]
    let selectedIndex: Int?
    @Binding var hoveredIndex: Int?
    var onSelect: ((Int) -> Void)? = nil
    var allowsHover = false
    private let leftInset: CGFloat = 48
    private let rightInset: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let drawing = NativeStaticTrendCanvas(
                summaries: summaries,
                revision: ModelStoreRevisionClock.shared.currentRevision()
            )
            .equatable()
            if allowsHover || onSelect != nil {
                drawing
                    .overlay(alignment: .leading) {
                        if let active = hoveredIndex ?? selectedIndex,
                           summaries.indices.contains(active), summaries.count > 1 {
                            let first = summaries[0].date.timeIntervalSinceReferenceDate
                            let last = summaries[summaries.count - 1].date.timeIntervalSinceReferenceDate
                            let target = summaries[active].date.timeIntervalSinceReferenceDate
                            let x = leftInset + (target - first) / max(last - first, 1)
                                * max(geometry.size.width - leftInset - rightInset, 1)
                            Rectangle()
                                .fill(AssetTheme.gold.opacity(0.75))
                                .frame(width: 1)
                                .padding(.vertical, 5)
                                .offset(x: x)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard summaries.count > 1 else { return }
                            let first = summaries[0].date.timeIntervalSinceReferenceDate
                            let last = summaries[summaries.count - 1].date.timeIntervalSinceReferenceDate
                            let ratio = min(max((point.x - leftInset)
                                / max(geometry.size.width - leftInset - rightInset, 1), 0), 1)
                            let target = first + ratio * (last - first)
                            let index = nearestIndex(target)
                            if hoveredIndex != index { hoveredIndex = index }
                        case .ended: hoveredIndex = nil
                        }
                    }
                    .onTapGesture {
                        if let hoveredIndex { onSelect?(hoveredIndex) }
                    }
            } else {
                drawing.allowsHitTesting(false)
                }
        }
    }

    private func nearestIndex(_ time: Double) -> Int {
        var low = 0
        var high = summaries.count
        while low < high {
            let middle = (low + high) / 2
            if summaries[middle].date.timeIntervalSinceReferenceDate < time { low = middle + 1 }
            else { high = middle }
        }
        if low == 0 { return 0 }
        if low == summaries.count { return summaries.count - 1 }
        let before = summaries[low - 1].date.timeIntervalSinceReferenceDate
        let after = summaries[low].date.timeIntervalSinceReferenceDate
        return abs(time - before) <= abs(after - time) ? low - 1 : low
    }
}

private struct NativeStaticTrendCanvas: View, Equatable {
    let summaries: [TimeMachineSnapshotProjection]
    let revision: UInt64
    private let gold = Color(red: 0.86, green: 0.7, blue: 0.45)
    private let green = Color(red: 0.32, green: 0.72, blue: 0.51)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
            && lhs.summaries.count == rhs.summaries.count
            && lhs.summaries.first?.id == rhs.summaries.first?.id
            && lhs.summaries.last?.id == rhs.summaries.last?.id
    }

    var body: some View {
        Canvas { graphics, size in
            guard summaries.count > 1 else { return }
            let sampled = Self.sample(summaries, limit: 600)
            let allValues = sampled.flatMap { [$0.element.totalAssets, $0.element.totalAssets - $0.element.totalLiabilities] }
            let low = (allValues.min() ?? 0) * 0.95
            let high = max((allValues.max() ?? 1) * 1.05, low + 1)
            let start = summaries[0].date.timeIntervalSinceReferenceDate
            let end = summaries[summaries.count - 1].date.timeIntervalSinceReferenceDate
            let plot = CGRect(x: 48, y: 6, width: max(size.width - 56, 1), height: max(size.height - 30, 1))
            for tick in 0...3 {
                let fraction = Double(tick) / 3
                let y = plot.maxY - fraction * plot.height
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                graphics.stroke(grid, with: .color(.secondary.opacity(0.22)), lineWidth: 0.7)
                let amount = low + fraction * (high - low)
                let label = amount.formatted(.number.notation(.compactName).precision(.fractionLength(0)))
                graphics.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                              at: CGPoint(x: 0, y: y), anchor: .leading)
            }
            for tick in 0...3 {
                let ratio = Double(tick) / 3
                let x = plot.minX + ratio * plot.width
                let date = Date(timeIntervalSinceReferenceDate: start + ratio * (end - start))
                graphics.draw(Text(date.formatted(.dateTime.month(.abbreviated).year()))
                    .font(.system(size: 9)).foregroundStyle(.secondary),
                              at: CGPoint(x: x, y: plot.maxY + 11),
                              anchor: tick == 0 ? .leading : (tick == 3 ? .trailing : .center))
            }
            func point(_ entry: (offset: Int, element: TimeMachineSnapshotProjection), net: Bool) -> CGPoint {
                let x = plot.minX + (entry.element.date.timeIntervalSinceReferenceDate - start)
                    / max(end - start, 1) * plot.width
                let value = net ? entry.element.totalAssets - entry.element.totalLiabilities : entry.element.totalAssets
                return CGPoint(x: x, y: plot.maxY - (value - low) / (high - low) * plot.height)
            }
            for net in [false, true] {
                var path = Path()
                for (position, entry) in sampled.enumerated() {
                    let p = point(entry, net: net)
                    if position == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                graphics.stroke(path, with: .color(net ? green : gold), lineWidth: 1.6)
            }
        }
    }

    /// Keeps the first, last, and both extrema of each bucket; at most 600 points.
    static func validatesExtrema(_ source: [TimeMachineSnapshotProjection]) -> Bool {
        guard !source.isEmpty else { return true }
        let reduced = sample(source, limit: 600).map(\.element)
        guard reduced.count <= 600,
              reduced.first?.id == source.first?.id,
              reduced.last?.id == source.last?.id else { return false }
        let sourceAssets = source.map(\.totalAssets)
        let reducedAssets = reduced.map(\.totalAssets)
        let sourceNet = source.map { $0.totalAssets - $0.totalLiabilities }
        let reducedNet = reduced.map { $0.totalAssets - $0.totalLiabilities }
        return sourceAssets.min() == reducedAssets.min()
            && sourceAssets.max() == reducedAssets.max()
            && sourceNet.min() == reducedNet.min()
            && sourceNet.max() == reducedNet.max()
    }

    /// Keeps the first, last, and both extrema of each bucket; at most 600 points.
    private static func sample(_ source: [TimeMachineSnapshotProjection], limit: Int) -> [EnumeratedSequence<[TimeMachineSnapshotProjection]>.Element] {
        if source.count <= limit { return Array(source.enumerated()) }
        let interior = source.count - 2
        let buckets = max(1, (limit - 2) / 4)
        var indices = [0]
        for bucket in 0..<buckets {
            let start = 1 + interior * bucket / buckets
            let end = min(source.count - 1, 1 + interior * (bucket + 1) / buckets)
            guard start < end else { continue }
            let slice = start..<end
            let assetsLow = slice.min(by: { source[$0].totalAssets < source[$1].totalAssets })!
            let assetsHigh = slice.max(by: { source[$0].totalAssets < source[$1].totalAssets })!
            let netLow = slice.min(by: { source[$0].totalAssets - source[$0].totalLiabilities < source[$1].totalAssets - source[$1].totalLiabilities })!
            let netHigh = slice.max(by: { source[$0].totalAssets - source[$0].totalLiabilities < source[$1].totalAssets - source[$1].totalLiabilities })!
            indices.append(contentsOf: Set([assetsLow, assetsHigh, netLow, netHigh]).sorted())
        }
        indices.append(source.count - 1)
        return indices.map { (offset: $0, element: source[$0]) }
    }
}

struct NativeQuantView: View {
    @ObservedObject var history: NativeHistoryModel
    @State private var launcherError: String?
    var body: some View {
        let values = history.summaries.map { $0.totalAssets - $0.totalLiabilities }
        let first = values.first ?? 0
        let last = values.last ?? 0
        let change = last - first
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                NativePageHeader(title: "量化", subtitle: "基于本机历史记录的轻量分析")
                NativeCard {
                    HStack {
                        quantMetric("记录天数", "\(values.count)")
                        quantMetric("期间净值变化", money(change))
                        quantMetric("最高净资产", money(values.max() ?? 0))
                        quantMetric("最低净资产", money(values.min() ?? 0))
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("净资产走势").font(.system(size: 15, weight: .semibold))
                        NativeTrendCanvas(summaries: history.summaries, selectedIndex: nil, hoveredIndex: .constant(nil))
                            .frame(height: 260)
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("完整策略回测").font(.system(size: 14, weight: .semibold))
                        Text("完整回测和行情计算使用现有 Mac 版，按需启动；切换后本窗口会退出以释放内存。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("打开完整量化", systemImage: "arrow.up.forward.app", action: launchFullQuant)
                        if let launcherError { Text(launcherError).font(.caption).foregroundStyle(.red) }
                    }
                }
            }.padding(24)
        }
    }
    private func quantMetric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func launchFullQuant() {
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
            .appending(path: "AssetTimeMachine-Mac-Signed.app")
        let destination: URL
        if FileManager.default.fileExists(atPath: sibling.path) {
            destination = sibling
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.message = "选择已有的资产时光机 Mac 完整版"
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            destination = selected
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-openQuantTab"]
        let sharedDefaults = UserDefaults(suiteName: "group.com.flyingrtx.AssetTimeMachine")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "nativeMac.openFullQuantAt")
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    sharedDefaults?.removeObject(forKey: "nativeMac.openFullQuantAt")
                    launcherError = error.localizedDescription
                }
                else { NSApp.terminate(nil) }
            }
        }
    }
}
