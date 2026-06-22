import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers
import UIKit
import UserNotifications
import Darwin

enum AppTab: Hashable {
    case dashboard
    case snapshots
    case timeMachine
    case backtest
    case settings
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @AppStorage("app.onboarding.completed") private var hasCompletedOnboarding = false
    @AppStorage("app.notifications.enabled") private var notificationEnabled = false
    @AppStorage("app.notifications.intervalHours") private var notificationIntervalHours: Double = 1
    @AppStorage("app.strategyNotifications.enabled") private var strategyNotificationEnabled = false
    @AppStorage("app.strategyNotifications.templateID") private var strategyNotificationTemplateID = StrategyNotificationDefaults.defaultTemplateID
    @AppStorage("app.strategyNotifications.hour") private var strategyNotificationHour: Int = StrategyNotificationDefaults.defaultHour
    @StateObject private var marketStore = RemoteMarketStore()
    @StateObject private var cloudStore = AssetTimeMachineCloudStore()
    @State private var selectedTab: AppTab = .dashboard
    @State private var activeWorkTab: AppTab? = .dashboard
    @State private var loadedTabs: Set<AppTab> = [.dashboard]
    @State private var didRunStartup = false
    @State private var lastMarketRefreshAt: Date?
    @State private var showsOnboarding = false
    @State private var onboardingReturnTab: AppTab = .dashboard
    @State private var activeOnboardingAnchorID: OnboardingAnchorID?
    @State private var pendingActiveTabActivationTask: Task<Void, Never>?
    @State private var pendingSnapshotNotificationRefreshTask: Task<Void, Never>?
    #if DEBUG
    @State private var debugTabSwitchTask: Task<Void, Never>?
    #endif

    private static let foregroundMarketRefreshInterval: TimeInterval = 3600
    private static let activeTabWorkActivationDelayNanoseconds: UInt64 = 260_000_000

    private var notificationSnapshot: AssetSnapshot? {
        snapshots.first(where: { Calendar.current.isDateInToday($0.date) }) ?? snapshots.first
    }

    private var notificationRefreshToken: String {
        guard let notificationSnapshot else { return "empty" }
        return "\(notificationSnapshot.id.uuidString)-\(notificationSnapshot.updatedAt.timeIntervalSinceReferenceDate)"
    }

    private var shouldRefreshLiveMarketData: Bool {
        guard let lastMarketRefreshAt else { return true }
        return Date().timeIntervalSince(lastMarketRefreshAt) >= Self.foregroundMarketRefreshInterval
    }

    private var nextMarketRefreshDelayNanoseconds: UInt64 {
        guard let lastMarketRefreshAt else {
            return UInt64(Self.foregroundMarketRefreshInterval * 1_000_000_000)
        }

        let elapsed = Date().timeIntervalSince(lastMarketRefreshAt)
        let remaining = max(60, Self.foregroundMarketRefreshInterval - elapsed)
        return UInt64(remaining * 1_000_000_000)
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                deferredTabContent(for: .dashboard) {
                    DashboardView(cloudStore: cloudStore, isActive: activeWorkTab == .dashboard)
                }
                    .tabItem {
                        Label(AppLocalization.string("首页"), systemImage: "house")
                    }
                    .tag(AppTab.dashboard)

                deferredTabContent(for: .snapshots) {
                    SnapshotListView(
                        marketStore: marketStore,
                        isActive: activeWorkTab == .snapshots,
                        onboardingActiveAnchorID: activeOnboardingAnchorID
                    )
                }
                    .tabItem {
                        Label(AppLocalization.string("记录"), systemImage: "square.and.pencil")
                    }
                    .tag(AppTab.snapshots)

                deferredTabContent(for: .timeMachine) {
                    TimeMachineView(marketStore: marketStore, isActive: activeWorkTab == .timeMachine)
                }
                    .tabItem {
                        Label(AppLocalization.string("时光机"), systemImage: "clock.arrow.circlepath")
                    }
                    .tag(AppTab.timeMachine)

                deferredTabContent(for: .backtest) {
                    BacktestView(marketStore: marketStore, isActive: activeWorkTab == .backtest)
                }
                    .tabItem {
                        Label(AppLocalization.string("量化"), systemImage: "chart.xyaxis.line")
                    }
                    .tag(AppTab.backtest)

                deferredTabContent(for: .settings) {
                    SettingsView(cloudStore: cloudStore) {
                        presentOnboarding()
                    }
                }
                    .tabItem {
                        Label(AppLocalization.string("设置"), systemImage: "gearshape")
                    }
                    .tag(AppTab.settings)
            }
        }
        .overlayPreferenceValue(OnboardingAnchorPreferenceKey.self) { anchors in
            if showsOnboarding {
                OnboardingTutorialView(
                    selectedTab: $selectedTab,
                    activeAnchorID: $activeOnboardingAnchorID,
                    anchors: anchors
                ) {
                    finishOnboarding()
                } onSkip: {
                    finishOnboarding()
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .tint(AssetTheme.gold)
        .onChange(of: selectedTab) { _, newValue in
            activeWorkTab = nil
            scheduleActiveWorkTabActivation(for: newValue)
        }
        .task {
            await runStartupIfNeeded()
            #if DEBUG
            scheduleDebugTabSwitchLoopIfNeeded()
            #endif
            await cloudStore.refreshIfNeeded(from: modelContext)
            await refreshAssetNotifications()
            await refreshStrategyNotifications()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }

            while !didRunStartup && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled else { return }

            await refreshLiveMarketDataIfNeeded(force: false)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nextMarketRefreshDelayNanoseconds)
                guard !Task.isCancelled else { return }
                await refreshLiveMarketDataIfNeeded(force: true)
            }
        }
        .onChange(of: notificationEnabled) { _, _ in
            Task { await refreshAssetNotifications() }
        }
        .onChange(of: notificationIntervalHours) { _, _ in
            Task { await refreshAssetNotifications() }
        }
        .onChange(of: notificationRefreshToken) { _, _ in
            scheduleSnapshotNotificationRefresh()
        }
        .onChange(of: strategyNotificationEnabled) { _, _ in
            Task { await refreshStrategyNotifications() }
        }
        .onChange(of: strategyNotificationTemplateID) { _, _ in
            Task { await refreshStrategyNotifications() }
        }
        .onChange(of: strategyNotificationHour) { _, _ in
            Task { await refreshStrategyNotifications() }
        }
    }

    @ViewBuilder
    private func deferredTabContent<Content: View>(for tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        if loadedTabs.contains(tab) {
            content()
        } else if selectedTab == tab {
            AssetTheme.pageGradient.ignoresSafeArea()
        } else {
            Color.clear
        }
    }

    @MainActor
    private func runStartupIfNeeded() async {
        guard !didRunStartup else { return }
        didRunStartup = true

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-openSnapshotsTab") {
            selectedTab = .snapshots
            activeWorkTab = .snapshots
            loadedTabs.insert(.snapshots)
        }

        if let importPath = launchArgumentValue(after: "-importJSONPath") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: importPath))
                try ImportExportService.importJSON(
                    data,
                    into: modelContext,
                    replaceExisting: ProcessInfo.processInfo.arguments.contains("-replaceExistingImport")
                )
                try? "success".write(
                    to: URL(fileURLWithPath: "/tmp/assettimemachine-import-status.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                let message = "[AssetTimeMachine] import failed: \(error)"
                print(message)
                try? message.write(
                    to: URL(fileURLWithPath: "/tmp/assettimemachine-import-status.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        } else {
            try? SeedDataService.seedDefaultCategoriesIfNeeded(in: modelContext)
        }
        #else
        try? SeedDataService.seedDefaultCategoriesIfNeeded(in: modelContext)
        #endif

        try? SeedDataService.ensureDefaultFinancialItems(in: modelContext)
        try? AssetItemService.migrateLegacyAutoPricedItemsIfNeeded(in: modelContext)

        if !hasCompletedOnboarding {
            presentOnboarding()
        }

        await marketStore.refreshLiveData()
        lastMarketRefreshAt = .now
        await syncTodaySnapshotWithLatestMarketData()
        if strategyNotificationEnabled {
            await marketStore.refreshHistoryIfNeeded(force: false)
        }
    }

    @MainActor
    private func scheduleActiveWorkTabActivation(for tab: AppTab) {
        pendingActiveTabActivationTask?.cancel()

        pendingActiveTabActivationTask = Task {
            try? await Task.sleep(nanoseconds: Self.activeTabWorkActivationDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard selectedTab == tab else { return }
                loadedTabs.insert(tab)
                activeWorkTab = tab
                pendingActiveTabActivationTask = nil
            }
        }
    }

    @MainActor
    private func scheduleSnapshotNotificationRefresh() {
        pendingSnapshotNotificationRefreshTask?.cancel()
        pendingSnapshotNotificationRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await refreshAssetNotifications()
            if strategyNotificationEnabled {
                await refreshStrategyNotifications()
            }
            await MainActor.run {
                pendingSnapshotNotificationRefreshTask = nil
            }
        }
    }

    #if DEBUG
    @MainActor
    private func scheduleDebugTabSwitchLoopIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-profileTabSwitchLoop"),
              debugTabSwitchTask == nil else { return }

        func debugName(for tab: AppTab) -> String {
            switch tab {
            case .dashboard: return "dashboard"
            case .snapshots: return "snapshots"
            case .timeMachine: return "timeMachine"
            case .backtest: return "backtest"
            case .settings: return "settings"
            }
        }

        print("[tab-profile] scheduling auto tab switch loop")
        loadedTabs.formUnion([.dashboard, .snapshots, .timeMachine, .backtest, .settings])
        let sequence: [AppTab] = [
            .snapshots, .timeMachine, .backtest, .settings, .dashboard,
            .snapshots, .timeMachine, .backtest, .settings, .dashboard
        ]

        debugTabSwitchTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            for tab in sequence {
                guard !Task.isCancelled else { return }
                print("[tab-profile] switching to \(debugName(for: tab))")
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                }
                try? await Task.sleep(for: .milliseconds(650))
            }
            await MainActor.run {
                debugTabSwitchTask = nil
            }
        }
    }
    #endif

    @MainActor
    private func refreshLiveMarketDataIfNeeded(force: Bool) async {
        guard force || shouldRefreshLiveMarketData else { return }
        await marketStore.refreshLiveData()
        lastMarketRefreshAt = .now
        await syncTodaySnapshotWithLatestMarketData()
        await refreshAssetNotifications()
        await refreshStrategyNotifications()
    }

    @MainActor
    private func syncTodaySnapshotWithLatestMarketData() async {
        do {
            let snapshot = try SnapshotService.createSnapshot(
                on: .now,
                inheritPrevious: true,
                createMissingEntries: true,
                in: modelContext
            )
            try syncAutoPricedEntries(in: snapshot)
            await SnapshotAnchorService.captureLiveAnchorsIfPossible(for: snapshot, marketStore: marketStore, in: modelContext)
        } catch {
            print("[AssetTimeMachine] sync today snapshot failed: \(error)")
        }
    }

    @MainActor
    private func presentOnboarding() {
        onboardingReturnTab = selectedTab
        showsOnboarding = true
    }

    @MainActor
    private func finishOnboarding() {
        hasCompletedOnboarding = true
        showsOnboarding = false
        activeOnboardingAnchorID = nil
        selectedTab = onboardingReturnTab
    }

    @MainActor
    private func syncAutoPricedEntries(in snapshot: AssetSnapshot) throws {
        var didChange = false

        for entry in snapshot.entries {
            guard let item = entry.item,
                  item.valuationMethod == .quantityAndUnitPrice,
                  let liveUnitPrice = item.resolvedAutoUnitPrice(using: marketStore) else {
                continue
            }

            if entry.unitPrice == nil || abs((entry.unitPrice ?? 0) - liveUnitPrice) > 0.0001 {
                entry.unitPrice = liveUnitPrice
                entry.updatedAt = .now
                item.updatedAt = .now
                didChange = true
            }
        }

        if didChange {
            snapshot.updatedAt = .now
            try modelContext.save()
        }
    }

    @MainActor
    private func refreshAssetNotifications() async {
        do {
            let granted = try await AssetNotificationService.refreshSchedule(
                isEnabled: notificationEnabled,
                intervalHours: notificationIntervalHours,
                snapshot: notificationSnapshot
            )
            if notificationEnabled && !granted {
                notificationEnabled = false
            }
        } catch {
            print("[AssetTimeMachine] refresh notifications failed: \(error)")
        }
    }

    @MainActor
    private func refreshStrategyNotifications() async {
        do {
            guard !StrategyNotificationDefaults.eligibleTemplates.isEmpty else {
                if strategyNotificationEnabled {
                    strategyNotificationEnabled = false
                }
                _ = try await AssetNotificationService.refreshStrategySchedule(
                    isEnabled: false,
                    hour: strategyNotificationHour,
                    strategyTitle: AppLocalization.string("策略提醒"),
                    body: nil
                )
                return
            }

            let content = await currentStrategyNotificationContent()
            let granted = try await AssetNotificationService.refreshStrategySchedule(
                isEnabled: strategyNotificationEnabled,
                hour: strategyNotificationHour,
                strategyTitle: content.title,
                body: content.body
            )
            if strategyNotificationEnabled && !granted {
                strategyNotificationEnabled = false
            }
        } catch {
            print("[AssetTimeMachine] refresh strategy notifications failed: \(error)")
        }
    }

    @MainActor
    private func currentStrategyNotificationContent() async -> (title: String, body: String?) {
        guard let template = StrategyNotificationDefaults.template(for: strategyNotificationTemplateID) else {
            return (AppLocalization.string("策略提醒"), AppLocalization.string("打开资产时光机，选择一个策略作为每日提醒。"))
        }

        guard strategyNotificationEnabled else {
            return (template.title, nil)
        }

        await marketStore.refreshHistoryIfNeeded(force: false)

        let assetOptions = StrategyNotificationDefaults.assetOptions(for: template)
        let assetInputs = assetOptions.map { option in
            (
                assetSeries: marketStore.history(for: option.symbol),
                assetOption: option,
                fxSeries: option.historicalFXSymbol.flatMap { marketStore.history(for: $0) }
            )
        }
        guard let advice = BacktestEngine.advancedRotationRebalanceAdvice(assetInputs: assetInputs, mode: template.mode) else {
            return (template.title, AppLocalization.string("历史行情暂时不足，打开 App 后会自动重试生成今日调仓。"))
        }

        let actions = StrategyRebalanceActionBuilder.actions(
            for: advice,
            snapshot: notificationSnapshot,
            selectedAssetOptions: assetOptions,
            allAssetOptions: BacktestDefaults.dcaAssetOptions
        )
        return (template.title, StrategyNotificationContentBuilder.body(advice: advice, actions: actions))
    }

    #if DEBUG
    private func launchArgumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
    #endif
}

private struct DashboardSnapshotSummary {
    let totalAssets: Double
    let totalLiabilities: Double
}

private struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("dashboard.monthlyExpense") private var monthlyExpense: Double = 3000
    @AppStorage("dashboard.monthlyExpenseSeedVersion") private var monthlyExpenseSeedVersion: Int = 0
    @AppStorage("dashboard.inflationRate") private var inflationRate: Double = 0.05
    @AppStorage("dashboard.inflationRateSeedVersion") private var inflationRateSeedVersion: Int = 0
    @AppStorage("dashboard.monthlySalary") private var monthlySalary: Double = 10000
    @AppStorage("dashboard.monthlySalarySeedVersion") private var monthlySalarySeedVersion: Int = 0
    @AppStorage("dashboard.annualReturnRate") private var annualReturnRate: Double = 0.03
    let cloudStore: AssetTimeMachineCloudStore
    let isActive: Bool
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @Query private var items: [AssetItem]
    @Query private var categories: [AssetCategory]
    @State private var cachedAllocationSlices: [DashboardAllocationSlice] = []
    @State private var cachedTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedFreedomProjection: FinancialFreedomProjection?
    @State private var cachedSnapshotSummary: DashboardSnapshotSummary?
    @State private var lastDashboardCacheToken: Int?
    @State private var pendingDashboardRefreshTask: Task<Void, Never>?
    @State private var pendingAutoSyncTask: Task<Void, Never>?
    @State private var showsCloudSyncModal = false

    private var latestSnapshot: AssetSnapshot? { snapshots.first }

    private var totalAssets: Double {
        cachedSnapshotSummary?.totalAssets ?? 0
    }

    private var allocationSlices: [DashboardAllocationSlice] {
        cachedAllocationSlices
    }

    private var trendPoints: [TimeMachineTrendPoint] {
        cachedTrendPoints
    }

    private var freedomProjection: FinancialFreedomProjection? {
        cachedFreedomProjection
    }

    private var dashboardCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(snapshots.count)

        for snapshot in snapshots {
            hasher.combine(snapshot.id)
            hasher.combine(snapshot.date.timeIntervalSinceReferenceDate)
            hasher.combine(snapshot.updatedAt.timeIntervalSinceReferenceDate)
        }

        hasher.combine(items.count)
        hasher.combine(items.reduce(0) { max($0, $1.updatedAt.timeIntervalSinceReferenceDate) })
        hasher.combine(categories.count)
        hasher.combine(monthlyExpense)
        hasher.combine(inflationRate)
        hasher.combine(monthlySalary)
        hasher.combine(annualReturnRate)
        return hasher.finalize()
    }

    private var autoSyncTrigger: String {
        let latestSnapshotUpdate = latestSnapshot?.updatedAt.timeIntervalSince1970 ?? 0
        let latestSnapshotID = latestSnapshot?.id.uuidString ?? "none"
        let latestItemUpdate = items.reduce(0) { max($0, $1.updatedAt.timeIntervalSince1970) }
        return [
            String(categories.count),
            String(items.count),
            String(snapshots.count),
            latestSnapshotID,
            String(Int(latestSnapshotUpdate)),
            String(Int(latestItemUpdate))
        ].joined(separator: ":")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        Group {
                            if lastDashboardCacheToken == nil {
                                LoadingStateCard(
                                    title: AppLocalization.string("首页加载中"),
                                    message: AppLocalization.string("正在整理你的资产概览…")
                                )
                            } else {
                                VStack(alignment: .leading, spacing: 22) {
                                    summaryStrip
                                    freedomSection
                                        .id("dashboard-freedom-section")
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                        .padding(.bottom, 172)
                    }
                    .task {
                        migrateDashboardDefaultsIfNeeded()
                        await cloudStore.refreshIfNeeded()
                        await focusFreedomSectionIfNeeded(using: proxy)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: autoSyncTrigger) { _, _ in
                guard isActive else { return }
                scheduleCloudAutoSync()
            }
        }
        .task(id: isActive) {
            if isActive {
                scheduleDashboardRefresh(delayNanoseconds: 0, force: true)
            } else {
                pendingDashboardRefreshTask?.cancel()
                pendingAutoSyncTask?.cancel()
            }
        }
        .onChange(of: dashboardCacheToken) { _, _ in
            guard isActive else { return }
            scheduleDashboardRefresh(delayNanoseconds: 40_000_000)
        }
        .sheet(isPresented: $showsCloudSyncModal) {
            NavigationStack {
                AssetTimeMachineCloudPage(store: cloudStore)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @MainActor
    private func scheduleCloudAutoSync(delayNanoseconds: UInt64 = 6_000_000_000) {
        guard cloudStore.currentUser != nil else { return }
        pendingAutoSyncTask?.cancel()
        pendingAutoSyncTask = Task {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await cloudStore.autoSyncIfNeeded(from: modelContext, quietly: true)
            await MainActor.run {
                pendingAutoSyncTask = nil
            }
        }
    }

    @MainActor
    private func scheduleDashboardRefresh(delayNanoseconds: UInt64, force: Bool = false) {
        pendingDashboardRefreshTask?.cancel()
        pendingDashboardRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isActive else { return }
                refreshDashboardCacheIfNeeded(force: force)
            }
        }
    }

    @MainActor
    private func refreshDashboardCacheIfNeeded(force: Bool = false) {
        let token = dashboardCacheToken
        guard force || token != lastDashboardCacheToken else { return }
        refreshDashboardCache()
        lastDashboardCacheToken = token
    }

    @MainActor
    private func refreshDashboardCache() {
        cachedSnapshotSummary = buildLatestSnapshotSummary()
        cachedAllocationSlices = buildAllocationSlices()
        let nextTrendPoints = buildTrendPoints()
        cachedTrendPoints = nextTrendPoints
        cachedFreedomProjection = FinancialFreedomEstimator.estimate(
            points: nextTrendPoints,
            monthlySalary: monthlySalary,
            annualReturnRate: annualReturnRate,
            monthlyExpense: monthlyExpense,
            annualInflationRate: inflationRate
        )
    }

    private func buildLatestSnapshotSummary() -> DashboardSnapshotSummary? {
        guard let latestSnapshot else { return nil }
        let metrics = PortfolioCalculator.metrics(for: latestSnapshot)
        return DashboardSnapshotSummary(
            totalAssets: metrics.totalAssets,
            totalLiabilities: metrics.totalLiabilities
        )
    }

    private func buildAllocationSlices() -> [DashboardAllocationSlice] {
        guard let latestSnapshot else { return [] }

        let grouped = Dictionary(grouping: latestSnapshot.entries.filter {
            ($0.item?.category?.group ?? .financial) != .liability && $0.resolvedAmount > 0
        }) { entry in
            AppLocalization.string(entry.item?.name ?? "未命名")
        }

        let sortedDetails = grouped
            .map { name, entries in
                DashboardAllocationDetail(
                    title: name,
                    amount: entries.reduce(0) { $0 + $1.resolvedAmount }
                )
            }
            .sorted { $0.amount > $1.amount }

        let topLimit = 5
        var slices: [DashboardAllocationSlice] = Array(sortedDetails.prefix(topLimit)).enumerated().map { index, detail in
            DashboardAllocationSlice(
                title: detail.title,
                amount: detail.amount,
                color: DashboardAllocationPalette.colors[index % DashboardAllocationPalette.colors.count],
                details: [detail]
            )
        }

        if sortedDetails.count > topLimit {
            let otherDetails = Array(sortedDetails.dropFirst(topLimit))
            let otherAmount = otherDetails.reduce(0) { $0 + $1.amount }
            if otherAmount > 0 {
                slices.append(
                    DashboardAllocationSlice(
                        title: AppLocalization.string("其他"),
                        amount: otherAmount,
                        color: DashboardAllocationPalette.colors[slices.count % DashboardAllocationPalette.colors.count],
                        details: otherDetails
                    )
                )
            }
        }

        return slices
    }

    private func buildTrendPoints() -> [TimeMachineTrendPoint] {
        let orderedSnapshots = Array(snapshots.reversed())
        let sourceSnapshots: [AssetSnapshot]

        if let latestDate = orderedSnapshots.last?.date,
           let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: latestDate) {
            let recentSnapshots = orderedSnapshots.filter { $0.date >= oneYearAgo }
            sourceSnapshots = recentSnapshots.count >= 2 ? recentSnapshots : orderedSnapshots
        } else {
            sourceSnapshots = orderedSnapshots
        }

        return sourceSnapshots.map { snapshot in
            let metrics = PortfolioCalculator.metrics(for: snapshot)
            let mainAssets = metrics.totalAssets

            return TimeMachineTrendPoint(
                date: snapshot.date,
                mainAssets: mainAssets,
                netAssets: metrics.netAssets,
                liabilities: metrics.totalLiabilities,
                goldEquivalent: snapshot.goldAnchorPriceCNY.map { $0 > 0 ? mainAssets / $0 : nil } ?? nil,
                btcEquivalent: snapshot.btcAnchorPriceCNY.map { $0 > 0 ? mainAssets / $0 : nil } ?? nil,
                nasdaqEquivalent: snapshot.nasdaqAnchorPriceCNY.map { $0 > 0 ? mainAssets / $0 : nil } ?? nil,
                goldAnchorPriceCNY: snapshot.goldAnchorPriceCNY,
                goldAnchorDate: snapshot.goldAnchorPriceDate,
                btcAnchorPriceUSD: snapshot.btcAnchorPriceUSD,
                btcAnchorPriceCNY: snapshot.btcAnchorPriceCNY,
                btcAnchorDate: snapshot.btcAnchorPriceDate,
                nasdaqAnchorPriceUSD: snapshot.nasdaqAnchorPriceUSD,
                nasdaqAnchorPriceCNY: snapshot.nasdaqAnchorPriceCNY,
                nasdaqAnchorDate: snapshot.nasdaqAnchorPriceDate
            )
        }
    }

    private func migrateDashboardDefaultsIfNeeded() {
        if monthlyExpenseSeedVersion < 1 {
            if abs(monthlyExpense - 8000) < 0.5 {
                monthlyExpense = 3000
            }
            monthlyExpenseSeedVersion = 1
        }

        if inflationRateSeedVersion < 1 {
            if abs(inflationRate - 0.03) < 0.0005 {
                inflationRate = 0.05
            }
            inflationRateSeedVersion = 1
        }

        if monthlySalarySeedVersion < 1 {
            if abs(monthlySalary) < 0.5 || abs(monthlySalary - 5000) < 0.5 {
                monthlySalary = 10000
            }
            monthlySalarySeedVersion = 1
        }
    }

    private var shouldFocusFreedomSectionForDebug: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-focusDashboardFreedom")
        #else
        false
        #endif
    }

    @MainActor
    private func focusFreedomSectionIfNeeded(using proxy: ScrollViewProxy) async {
        guard shouldFocusFreedomSectionForDebug else { return }
        try? await Task.sleep(for: .milliseconds(450))
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo("dashboard-freedom-section", anchor: .top)
        }
    }

    private var summaryStrip: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                Button {
                    showsCloudSyncModal = true
                } label: {
                    AssetTimeMachineCloudEntryButton(store: cloudStore)
                }
                .buttonStyle(.plain)
            }

            if !allocationSlices.isEmpty {
                DashboardAllocationChart(
                    slices: allocationSlices,
                    totalAmount: totalAssets
                )
            } else {
                EmptyStateCard(
                    title: AppLocalization.string("暂无资产分布"),
                    systemImage: "chart.pie.fill"
                )
            }

            Rectangle()
                .fill(AssetTheme.border.opacity(0.55))
                .frame(height: 1)
        }
        .onboardingAnchor(.dashboardAllocation)
    }

    private var freedomSection: some View {
        DashboardFreedomSection(
            projection: freedomProjection,
            monthlySalary: $monthlySalary,
            annualReturnRate: $annualReturnRate,
            monthlyExpense: $monthlyExpense,
            inflationRate: $inflationRate
        )
        .onboardingAnchor(.dashboardFreedom)
    }

}

private struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("app.appearanceMode") private var appearanceModeRawValue: String = AppAppearanceMode.system.rawValue
    @AppStorage("app.language") private var appLanguageRawValue: String = AppLanguage.system.rawValue
    @AppStorage("app.notifications.enabled") private var notificationEnabled = false
    @AppStorage("app.notifications.intervalHours") private var notificationIntervalHours: Double = 1
    @AppStorage("app.strategyNotifications.enabled") private var strategyNotificationEnabled = false
    @AppStorage("app.strategyNotifications.templateID") private var strategyNotificationTemplateID = StrategyNotificationDefaults.defaultTemplateID
    @AppStorage("app.strategyNotifications.hour") private var strategyNotificationHour: Int = StrategyNotificationDefaults.defaultHour
    @ObservedObject var cloudStore: AssetTimeMachineCloudStore
    let onReplayOnboarding: () -> Void
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showsLogoutConfirmation = false

    private var latestSnapshot: AssetSnapshot? {
        snapshots.first(where: { Calendar.current.isDateInToday($0.date) }) ?? snapshots.first
    }

    private var notificationPreview: String {
        guard let latestSnapshot else { return AppLocalization.string("暂无资产记录") }

        return AppLocalization.format(
            AppLocalization.string("总资产 %@ · 净资产 %@ · 负债 %@"),
            PortfolioCalculator.totalAssets(for: latestSnapshot).currencyString(),
            PortfolioCalculator.netAssets(for: latestSnapshot).currencyString(),
            PortfolioCalculator.totalLiabilities(for: latestSnapshot).currencyString()
        )
    }

    private var selectedStrategyTemplate: AdvancedBacktestStrategyTemplate? {
        StrategyNotificationDefaults.template(for: strategyNotificationTemplateID)
    }

    private var strategyNotificationPreview: String {
        guard let selectedStrategyTemplate else {
            return AppLocalization.string("请选择一个策略")
        }

        return AppLocalization.format(
            "%@ · 每天%@",
            selectedStrategyTemplate.title,
            strategyHourLabel(strategyNotificationHour)
        )
    }

    private var strategyNotificationFooter: String {
        if strategyNotificationEnabled {
            return AppLocalization.string("会用最近一次刷新到的行情和资产记录生成调仓提醒；打开 App 或回到前台会自动更新。")
        }
        return AppLocalization.string("选择一个策略后，可每天收到目标仓位和买卖金额提醒。")
    }

    private var canLogout: Bool {
        cloudStore.currentUser != nil || cloudStore.hasToken
    }

    private var currentAppearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    private var currentAppLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)) where !version.isEmpty && !build.isEmpty:
            return "\(version) (\(build))"
        case let (.some(version), _) where !version.isEmpty:
            return version
        case let (_, .some(build)) where !build.isEmpty:
            return build
        default:
            return AppLocalization.string("未知版本")
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.background.ignoresSafeArea()

                List {
                    Section {
                            Menu {
                                Picker(AppLocalization.string("外观"), selection: $appearanceModeRawValue) {
                                    ForEach(AppAppearanceMode.allCases) { mode in
                                        Text(mode.title).tag(mode.rawValue)
                                    }
                            }
                        } label: {
                            LabeledContent {
                                SettingsValueText(currentAppearanceMode.title)
                            } label: {
                                SettingsRowLabel(
                                    title: AppLocalization.string("外观"),
                                    systemImage: "circle.lefthalf.filled",
                                    color: AssetTheme.accentBlue
                                )
                            }
                        }
                        .foregroundStyle(AssetTheme.textPrimary)
                        .listRowBackground(AssetTheme.surface)
                        .onboardingAnchor(.settingsAppearance)

                        Menu {
                            Picker(AppLocalization.string("语言"), selection: $appLanguageRawValue) {
                                ForEach(AppLanguage.allCases) { language in
                                    Text(language.title).tag(language.rawValue)
                                }
                            }
                        } label: {
                            LabeledContent {
                                SettingsValueText(currentAppLanguage.title)
                            } label: {
                                SettingsRowLabel(
                                    title: AppLocalization.string("语言"),
                                    systemImage: "globe",
                                    color: AssetTheme.accentOrange
                                )
                            }
                        }
                        .foregroundStyle(AssetTheme.textPrimary)
                        .listRowBackground(AssetTheme.surface)

                        Button(action: onReplayOnboarding) {
                            HStack(spacing: 12) {
                                SettingsRowLabel(
                                    title: AppLocalization.string("重新查看新手引导"),
                                    systemImage: "sparkles.rectangle.stack",
                                    color: AssetTheme.gold
                                )

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AssetTheme.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(AssetTheme.surface)
                        .onboardingAnchor(.settingsReplay)
                    } header: {
                        Text(AppLocalization.string("通用"))
                    }

                    Section {
                        Toggle(isOn: $notificationEnabled) {
                            SettingsRowLabel(
                                title: AppLocalization.string("定时资产播报"),
                                systemImage: "bell.badge.fill",
                                color: AssetTheme.accentRed
                            )
                        }
                        .tint(AssetTheme.gold)
                        .listRowBackground(AssetTheme.surface)
                        .onboardingAnchor(.settingsNotifications)

                        if notificationEnabled {
                            Menu {
                                Picker(AppLocalization.string("播报频率"), selection: $notificationIntervalHours) {
                                    ForEach(AssetNotificationService.intervalOptions, id: \.self) { hours in
                                        Text(intervalLabel(hours)).tag(hours)
                                    }
                                }
                            } label: {
                                LabeledContent {
                                    SettingsValueText(intervalLabel(notificationIntervalHours))
                                } label: {
                                    Text(AppLocalization.string("播报频率"))
                                        .foregroundStyle(AssetTheme.textPrimary)
                                }
                            }
                            .foregroundStyle(AssetTheme.textPrimary)
                            .listRowBackground(AssetTheme.surface)
                        }

                        Toggle(isOn: $strategyNotificationEnabled) {
                            SettingsRowLabel(
                                title: AppLocalization.string("每日调仓提醒"),
                                systemImage: "chart.line.uptrend.xyaxis",
                                color: AssetTheme.gold
                            )
                        }
                        .tint(AssetTheme.gold)
                        .disabled(StrategyNotificationDefaults.eligibleTemplates.isEmpty)
                        .listRowBackground(AssetTheme.surface)

                        if !StrategyNotificationDefaults.eligibleTemplates.isEmpty {
                            Menu {
                                Picker(AppLocalization.string("提醒策略"), selection: $strategyNotificationTemplateID) {
                                    ForEach(StrategyNotificationDefaults.eligibleTemplates) { template in
                                        Text(template.title).tag(template.id)
                                    }
                                }
                            } label: {
                                LabeledContent {
                                    SettingsValueText(selectedStrategyTemplate?.title ?? AppLocalization.string("未选择"))
                                } label: {
                                    Text(AppLocalization.string("提醒策略"))
                                        .foregroundStyle(AssetTheme.textPrimary)
                                }
                            }
                            .foregroundStyle(AssetTheme.textPrimary)
                            .listRowBackground(AssetTheme.surface)
                        } else {
                            LabeledContent {
                                SettingsValueText(AppLocalization.string("暂无策略"))
                            } label: {
                                Text(AppLocalization.string("提醒策略"))
                                    .foregroundStyle(AssetTheme.textPrimary)
                            }
                            .listRowBackground(AssetTheme.surface)
                        }

                        Menu {
                            Picker(AppLocalization.string("提醒时间"), selection: $strategyNotificationHour) {
                                ForEach(AssetNotificationService.strategyHourOptions, id: \.self) { hour in
                                    Text(strategyHourLabel(hour)).tag(hour)
                                }
                            }
                        } label: {
                            LabeledContent {
                                SettingsValueText(strategyHourLabel(strategyNotificationHour))
                            } label: {
                                Text(AppLocalization.string("提醒时间"))
                                    .foregroundStyle(AssetTheme.textPrimary)
                            }
                        }
                        .foregroundStyle(AssetTheme.textPrimary)
                        .listRowBackground(AssetTheme.surface)

                        if notificationStatus == .denied {
                            Button {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                openURL(url)
                            } label: {
                                HStack(spacing: 12) {
                                    SettingsRowLabel(
                                        title: AppLocalization.string("打开系统通知设置"),
                                        systemImage: "gearshape.fill",
                                        color: .gray
                                    )

                                    Spacer()

                                    Image(systemName: "arrow.up.right.square")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(AssetTheme.surface)
                        }
                    } header: {
                        Text(AppLocalization.string("通知"))
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if notificationStatus == .denied {
                                Text(AppLocalization.string("通知权限已关闭，请前往系统设置开启。"))
                                    .foregroundStyle(AssetTheme.textSecondary)
                            } else {
                                if notificationEnabled {
                                    Text(notificationPreview)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                        .monospacedDigit()
                                }

                                if strategyNotificationEnabled {
                                    Text(strategyNotificationPreview)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }

                                Text(strategyNotificationFooter)
                                    .foregroundStyle(AssetTheme.textSecondary)
                            }
                        }
                    }

                    if canLogout {
                        Section {
                            LabeledContent {
                                if let currentUser = cloudStore.currentUser {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(currentUser.displayName)
                                            .foregroundStyle(AssetTheme.textPrimary)
                                        if let email = currentUser.userEmail, !email.isEmpty {
                                            Text(email)
                                                .font(.caption)
                                                .foregroundStyle(AssetTheme.textSecondary)
                                        }
                                    }
                                } else {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(AppLocalization.string("已连接"))
                                            .foregroundStyle(AssetTheme.textPrimary)
                                        Text(AppLocalization.string("云同步凭证已保存"))
                                            .font(.caption)
                                            .foregroundStyle(AssetTheme.textSecondary)
                                    }
                                }
                            } label: {
                                SettingsRowLabel(
                                    title: AppLocalization.string("云同步"),
                                    systemImage: "icloud.fill",
                                    color: AssetTheme.accentBlue
                                )
                            }
                            .listRowBackground(AssetTheme.surface)

                            Button(role: .destructive) {
                                showsLogoutConfirmation = true
                            } label: {
                                SettingsRowLabel(
                                    title: AppLocalization.string("退出云同步"),
                                    systemImage: "rectangle.portrait.and.arrow.right",
                                    color: AssetTheme.negative
                                )
                            }
                            .foregroundStyle(AssetTheme.negative)
                            .listRowBackground(AssetTheme.surface)
                        } header: {
                            Text(AppLocalization.string("账户"))
                        }
                    }

                    Section {
                        LabeledContent {
                            SettingsValueText(appVersionText)
                                .monospacedDigit()
                        } label: {
                            SettingsRowLabel(
                                title: AppLocalization.string("版本"),
                                systemImage: "number.circle.fill",
                                color: AssetTheme.gold
                            )
                        }
                        .listRowBackground(AssetTheme.surface)
                    } header: {
                        Text(AppLocalization.string("关于"))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 54)
            }
            .navigationTitle(AppLocalization.string("设置"))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                normalizeStrategyNotificationTemplateIfNeeded()
                await reloadNotificationStatus()
            }
            .onChange(of: notificationEnabled) { _, _ in
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await reloadNotificationStatus()
                }
            }
            .onChange(of: strategyNotificationEnabled) { _, _ in
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await reloadNotificationStatus()
                }
            }
            .alert(AppLocalization.string("退出云同步"), isPresented: $showsLogoutConfirmation) {
                Button(AppLocalization.string("取消"), role: .cancel) {}
                Button(AppLocalization.string("退出"), role: .destructive) {
                    cloudStore.logout()
                }
            }
        }
    }

    private func intervalLabel(_ hours: Double) -> String {
        let integer = Int(hours)
        if integer == 24 {
            return AppLocalization.string("每天一次")
        }

        return AppLocalization.format("每 %d 小时", integer)
    }

    private func strategyHourLabel(_ hour: Int) -> String {
        AppLocalization.format("%02d:00", min(max(hour, 0), 23))
    }

    private func normalizeStrategyNotificationTemplateIfNeeded() {
        guard StrategyNotificationDefaults.template(for: strategyNotificationTemplateID)?.id != strategyNotificationTemplateID else { return }
        strategyNotificationTemplateID = StrategyNotificationDefaults.defaultTemplateID
    }

    private func reloadNotificationStatus() async {
        notificationStatus = await AssetNotificationService.authorizationStatus()
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                )

            Text(AppLocalization.string(title))
                .foregroundStyle(AssetTheme.textPrimary)
        }
    }
}

private struct SettingsValueText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(AssetTheme.textSecondary)
    }
}

private struct SnapshotListView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var marketStore: RemoteMarketStore
    let isActive: Bool
    let onboardingActiveAnchorID: OnboardingAnchorID?
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @Query private var categories: [AssetCategory]

    @State private var currentSnapshotID: UUID?
    @State private var amountInputs: [UUID: String] = [:]
    @State private var quantityInputs: [UUID: String] = [:]
    @State private var unitPriceInputs: [UUID: String] = [:]
    @State private var didPrepare = false
    @State private var isPreparingInitialSnapshot = false
    @State private var showsAddAssetItemSheet = false
    @State private var editingAssetItem: AssetItem?
    @State private var quickEditingAssetItem: AssetItem?
    @State private var focusedField: RecordInputField?
    @State private var pendingAutoRateSyncTask: Task<Void, Never>?

    private let liabilitySectionTitleMap: [String: String] = [
        AppLocalization.string("长期负债"): AppLocalization.string("长期负债"),
        AppLocalization.string("短期负债"): AppLocalization.string("短期负债")
    ]

    private var currentSnapshot: AssetSnapshot? {
        if let currentSnapshotID,
           let snapshot = snapshots.first(where: { $0.id == currentSnapshotID }) {
            return snapshot
        }
        return snapshots.first(where: { Calendar.current.isDateInToday($0.date) }) ?? snapshots.first
    }

    private var nonLiabilityCategories: [AssetCategory] {
        categories
            .filter { $0.group != .liability && !$0.activeSortedItems.isEmpty }
            .sorted {
                if $0.group.sortPriority == $1.group.sortPriority {
                    return $0.createdAt < $1.createdAt
                }
                return $0.group.sortPriority < $1.group.sortPriority
            }
    }

    private var liabilityCategories: [AssetCategory] {
        categories
            .filter { $0.group == .liability && !$0.activeSortedItems.isEmpty }
            .sorted {
                let lhsPriority = $0.liabilitySortPriority(titleMap: liabilitySectionTitleMap)
                let rhsPriority = $1.liabilitySortPriority(titleMap: liabilitySectionTitleMap)
                if lhsPriority == rhsPriority {
                    return $0.createdAt < $1.createdAt
                }
                return lhsPriority < rhsPriority
            }
    }

    private var displayedTotalAssets: Double {
        let itemsByCategoryID = Dictionary(uniqueKeysWithValues: nonLiabilityCategories.map { ($0.id, $0.activeSortedItems) })
        return displayedTotalAmount(for: itemsByCategoryID.values, entriesByItemID: currentSnapshotEntriesByItemID)
    }

    private var displayedTotalLiabilities: Double {
        let itemsByCategoryID = Dictionary(uniqueKeysWithValues: liabilityCategories.map { ($0.id, $0.activeSortedItems) })
        return displayedTotalAmount(for: itemsByCategoryID.values, entriesByItemID: currentSnapshotEntriesByItemID)
    }

    private var displayedNetAssets: Double {
        displayedTotalAssets - displayedTotalLiabilities
    }

    private var onboardingInputTargetItem: AssetItem? {
        nonLiabilityCategories.first?.activeSortedItems.first
    }

    #if DEBUG
    private var debugAutoPricedItem: AssetItem? {
        nonLiabilityCategories
            .flatMap(\.activeSortedItems)
            .first(where: { $0.autoPricedAssetKind != nil })
        ?? liabilityCategories
            .flatMap(\.activeSortedItems)
            .first(where: { $0.autoPricedAssetKind != nil })
    }

    private var forcedDebugQuickEditItem: AssetItem? {
        guard ProcessInfo.processInfo.arguments.contains("-showDebugQuickEditPreview") else { return nil }
        return debugAutoPricedItem
    }
    #endif

    private var currentSnapshotEntriesByItemID: [UUID: AssetEntry] {
        guard let currentSnapshot else { return [:] }
        return Dictionary(uniqueKeysWithValues: currentSnapshot.entries.compactMap { entry in
            guard let itemID = entry.item?.id else { return nil }
            return (itemID, entry)
        })
    }

    @ViewBuilder
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-openSnapshotArchive") {
            SnapshotArchiveView()
        } else {
            snapshotListBody
        }
        #else
        snapshotListBody
        #endif
    }

    private var snapshotListBody: some View {
        let currentSnapshotValue = currentSnapshot
        let nonLiabilityCategoriesValue = nonLiabilityCategories
        let liabilityCategoriesValue = liabilityCategories
        let nonLiabilityItemsByCategoryID = Dictionary(uniqueKeysWithValues: nonLiabilityCategoriesValue.map { ($0.id, $0.activeSortedItems) })
        let liabilityItemsByCategoryID = Dictionary(uniqueKeysWithValues: liabilityCategoriesValue.map { ($0.id, $0.activeSortedItems) })
        let snapshotEntriesByItemIDValue = snapshotEntriesByItemID(for: currentSnapshotValue)
        let displayedTotalAssetsValue = displayedTotalAmount(for: nonLiabilityItemsByCategoryID.values, entriesByItemID: snapshotEntriesByItemIDValue)
        let displayedTotalLiabilitiesValue = displayedTotalAmount(for: liabilityItemsByCategoryID.values, entriesByItemID: snapshotEntriesByItemIDValue)
        let displayedNetAssetsValue = displayedTotalAssetsValue - displayedTotalLiabilitiesValue
        let onboardingInputTargetCategoryID = nonLiabilityCategoriesValue.first?.id

        return NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let currentSnapshot = currentSnapshotValue {
                            RecordPageHero(
                                snapshot: currentSnapshot,
                                totalAssets: displayedTotalAssetsValue,
                                netAssets: displayedNetAssetsValue,
                                totalLiabilities: displayedTotalLiabilitiesValue,
                                onAddAsset: {
                                    dismissKeyboard()
                                    showsAddAssetItemSheet = true
                                }
                            )
                            .padding(.bottom, 2)

                            ForEach(nonLiabilityCategoriesValue) { category in
                                RecordCategoryCard(
                                    category: category,
                                    items: nonLiabilityItemsByCategoryID[category.id] ?? [],
                                    snapshotEntriesByItemID: snapshotEntriesByItemIDValue,
                                    onboardingInputItemID: category.id == onboardingInputTargetCategoryID ? nonLiabilityItemsByCategoryID[category.id]?.first?.id : nil,
                                    onboardingActiveAnchorID: onboardingActiveAnchorID,
                                    marketStore: marketStore,
                                    amountInputs: $amountInputs,
                                    quantityInputs: $quantityInputs,
                                    unitPriceInputs: $unitPriceInputs,
                                    focusedField: $focusedField,
                                    onEdit: { item in
                                        dismissKeyboard()
                                        editingAssetItem = item
                                    },
                                    onEditValue: { item in
                                        dismissKeyboard()
                                        quickEditingAssetItem = item
                                    }
                                )
                            }

                            ForEach(liabilityCategoriesValue) { category in
                                LiabilityCategorySection(
                                    category: category,
                                    items: liabilityItemsByCategoryID[category.id] ?? [],
                                    snapshotEntriesByItemID: snapshotEntriesByItemIDValue,
                                    amountInputs: $amountInputs,
                                    quantityInputs: $quantityInputs,
                                    focusedField: $focusedField,
                                    onEdit: { item in
                                        dismissKeyboard()
                                        editingAssetItem = item
                                    },
                                    onEditValue: { item in
                                        dismissKeyboard()
                                        quickEditingAssetItem = item
                                    }
                                )
                            }

                        } else if isPreparingInitialSnapshot || !didPrepare {
                            LoadingStateCard(
                                title: AppLocalization.string("记录加载中"),
                                message: AppLocalization.string("正在准备今天的资产快照…")
                            )
                        } else {
                            EmptyStateCard(
                                title: AppLocalization.string("暂无记录"),
                                systemImage: "calendar.badge.plus"
                            )
                        }

                        Color.clear
                            .frame(height: 180)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissKeyboard()
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 104)
                }
                .scrollDismissesKeyboard(.never)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showsAddAssetItemSheet) {
            AddAssetItemSheet()
        }
        .sheet(item: $editingAssetItem) { item in
            EditAssetItemSheet(item: item, snapshot: currentSnapshot)
        }
        .overlay {
            #if DEBUG
            let presentedItem = quickEditingAssetItem ?? forcedDebugQuickEditItem
            #else
            let presentedItem = quickEditingAssetItem
            #endif

            if let item = presentedItem {
                ZStack {
                    Rectangle()
                        .fill(.black.opacity(0.42))
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismissKeyboard()
                            quickEditingAssetItem = nil
                        }

                    QuickRecordValueSheet(
                        item: item,
                        snapshot: currentSnapshot,
                        marketStore: marketStore,
                        onCancel: {
                            dismissKeyboard()
                            quickEditingAssetItem = nil
                        },
                        onSaved: {
                            if let snapshot = currentSnapshot {
                                hydrateInputs(for: item, from: snapshot)
                            }
                            dismissKeyboard()
                            quickEditingAssetItem = nil
                        }
                    )
                    .padding(.horizontal, 24)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: quickEditingAssetItem?.id)
        .task {
            await prepareSnapshotIfNeeded()
            #if DEBUG
            await ensureDebugAutoPricedItemIfNeeded()
            if ProcessInfo.processInfo.arguments.contains("-openFirstAutoPricedQuickEdit"),
               let debugAutoPricedItem,
               quickEditingAssetItem == nil {
                try? await Task.sleep(for: .milliseconds(250))
                quickEditingAssetItem = debugAutoPricedItem
            }
            #endif
            if isActive {
                scheduleAutoRateSync(delayNanoseconds: 650_000_000)
            }
        }
        .task(id: isActive) {
            if isActive {
                scheduleAutoRateSync(delayNanoseconds: 650_000_000)
            } else {
                pendingAutoRateSyncTask?.cancel()
            }
        }
        #if DEBUG
        .task(id: debugAutoPricedItem?.id) {
            await ensureDebugAutoPricedItemIfNeeded()
            guard ProcessInfo.processInfo.arguments.contains("-openFirstAutoPricedQuickEdit"),
                  quickEditingAssetItem == nil,
                  let debugAutoPricedItem else { return }
            try? await Task.sleep(for: .milliseconds(250))
            quickEditingAssetItem = debugAutoPricedItem
        }
        #endif
        .onChange(of: marketStore.exchangeRates) { _, _ in
            guard isActive else { return }
            scheduleAutoRateSync(delayNanoseconds: 300_000_000)
        }
        .onReceive(marketStore.$overview) { _ in
            guard isActive else { return }
            scheduleAutoRateSync(delayNanoseconds: 300_000_000)
        }
        .onChange(of: focusedField) { previousField, newField in
            guard let previousField, previousField != newField,
                  let item = item(for: previousField) else { return }
            persist(item: item)
        }
    }

    @MainActor
    private func dismissKeyboard() {
        focusedField = nil
        dismissActiveKeyboard()
    }

    private func item(for field: RecordInputField) -> AssetItem? {
        let itemID: UUID
        switch field {
        case let .amount(id), let .quantity(id), let .unitPrice(id):
            itemID = id
        }
        return categories.flatMap(\.items).first(where: { $0.id == itemID })
    }

    @MainActor
    private func prepareSnapshotIfNeeded() async {
        guard !didPrepare else { return }
        didPrepare = true
        isPreparingInitialSnapshot = true
        defer { isPreparingInitialSnapshot = false }

        do {
            try SeedDataService.seedDefaultCategoriesIfNeeded(in: modelContext)
            let snapshot = try SnapshotService.createSnapshot(on: .now, inheritPrevious: true, createMissingEntries: true, in: modelContext)
            currentSnapshotID = snapshot.id
            hydrateInputs(from: snapshot)
            await SnapshotAnchorService.captureLiveAnchorsIfPossible(for: snapshot, marketStore: marketStore, in: modelContext)
        } catch {
            print("[AssetTimeMachine] prepare snapshot failed: \(error)")
        }
    }

    #if DEBUG
    @MainActor
    private func ensureDebugAutoPricedItemIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-ensureDebugAutoPricedAsset"),
              let snapshot = currentSnapshot else { return }

        let shouldOpenQuickEdit = ProcessInfo.processInfo.arguments.contains("-openFirstAutoPricedQuickEdit")

        if let debugAutoPricedItem {
            if snapshot.entries.first(where: { $0.item?.id == debugAutoPricedItem.id }) == nil {
                let unitPrice = debugAutoPricedItem.resolvedAutoUnitPrice(using: marketStore)
                try? SnapshotService.upsertEntry(
                    snapshot: snapshot,
                    item: debugAutoPricedItem,
                    quantity: 1,
                    unitPrice: unitPrice,
                    in: modelContext
                )
                hydrateInputs(for: debugAutoPricedItem, from: snapshot)
            }
            if shouldOpenQuickEdit {
                quickEditingAssetItem = debugAutoPricedItem
            }
            return
        }

        guard let targetCategory = categories.first(where: { $0.group == .financial }) ?? categories.first else { return }

        do {
            let item = try AssetItemService.createItem(
                name: AppLocalization.string("黄金"),
                category: targetCategory,
                valuationMethod: .quantityAndUnitPrice,
                autoPricedAssetKind: .gold,
                note: "DEBUG",
                in: modelContext
            )
            let unitPrice = item.resolvedAutoUnitPrice(using: marketStore)
            try SnapshotService.upsertEntry(
                snapshot: snapshot,
                item: item,
                quantity: 1,
                unitPrice: unitPrice,
                in: modelContext
            )
            hydrateInputs(for: item, from: snapshot)
            if shouldOpenQuickEdit {
                quickEditingAssetItem = item
            }
        } catch {
            print("[AssetTimeMachine] debug auto-priced asset setup failed: \(error)")
        }
    }
    #endif

    @MainActor
    private func hydrateInputs(from snapshot: AssetSnapshot) {
        for entry in snapshot.entries {
            guard let item = entry.item else { continue }
            amountInputs[item.id] = item.valuationMethod == .directAmount ? (entry.amount?.plainNumberString() ?? "") : ""
            quantityInputs[item.id] = item.valuationMethod == .quantityAndUnitPrice ? (entry.quantity?.plainNumberString() ?? "") : ""
            unitPriceInputs[item.id] = item.valuationMethod == .quantityAndUnitPrice ? (entry.unitPrice?.plainNumberString() ?? "") : ""
        }
    }

    @MainActor
    private func hydrateInputs(for item: AssetItem, from snapshot: AssetSnapshot) {
        guard let entry = snapshot.entries.first(where: { $0.item?.id == item.id }) else { return }
        amountInputs[item.id] = item.valuationMethod == .directAmount ? (entry.amount?.plainNumberString() ?? "") : ""
        quantityInputs[item.id] = item.valuationMethod == .quantityAndUnitPrice ? (entry.quantity?.plainNumberString() ?? "") : ""
        unitPriceInputs[item.id] = item.valuationMethod == .quantityAndUnitPrice ? (entry.unitPrice?.plainNumberString() ?? "") : ""
    }

    @MainActor
    private func scheduleAutoRateSync(delayNanoseconds: UInt64) {
        pendingAutoRateSyncTask?.cancel()
        pendingAutoRateSyncTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await syncAutoRatesIfPossible()
        }
    }

    @MainActor
    private func syncAutoRatesIfPossible() async {
        guard let snapshot = currentSnapshot else { return }
        guard snapshot.entries.contains(where: { entry in
            entry.item?.resolvedAutoPricedAssetKind != nil
        }) else { return }

        var didMutateEntries = false

        for entry in snapshot.entries {
            guard let item = entry.item else {
                continue
            }

            let liveUnitPrice = item.resolvedAutoUnitPrice(using: marketStore)

            guard let rate = liveUnitPrice else {
                continue
            }

            let rateText = rate.plainNumberString()
            if unitPriceInputs[item.id] != rateText {
                unitPriceInputs[item.id] = rateText
            }

            let currentRate = entry.unitPrice ?? 0
            if abs(currentRate - rate) > 0.0001 {
                let resolvedQuantity = normalizedNumber(from: quantityInputs[item.id]) ?? entry.quantity
                entry.quantity = resolvedQuantity
                entry.unitPrice = rate
                entry.updatedAt = .now
                item.updatedAt = .now
                didMutateEntries = true
            }
        }

        if didMutateEntries {
            snapshot.updatedAt = .now
            do {
                try modelContext.save()
                await SnapshotAnchorService.captureLiveAnchorsIfPossible(for: snapshot, marketStore: marketStore, in: modelContext)
            } catch {
                print("[AssetTimeMachine] sync auto rate failed: \(error)")
            }
        }
    }

    @MainActor
    private func persist(item: AssetItem) {
        guard let snapshot = currentSnapshot else { return }

        do {
            switch item.valuationMethod {
            case .directAmount:
                let amount = normalizedNumber(from: amountInputs[item.id], forcePositive: item.category?.group == .liability)
                try SnapshotService.upsertEntry(snapshot: snapshot, item: item, amount: amount, in: modelContext)
            case .quantityAndUnitPrice:
                let quantity = normalizedNumber(from: quantityInputs[item.id])
                let autoRate = item.resolvedAutoUnitPrice(using: marketStore)
                let unitPrice = autoRate ?? normalizedNumber(from: unitPriceInputs[item.id])
                if let autoRate {
                    unitPriceInputs[item.id] = autoRate.plainNumberString()
                }
                try SnapshotService.upsertEntry(snapshot: snapshot, item: item, quantity: quantity, unitPrice: unitPrice, in: modelContext)
            }
        } catch {
            print("[AssetTimeMachine] persist entry failed: \(error)")
        }
    }

    private func normalizedNumber(from text: String?, forcePositive: Bool = false) -> Double? {
        guard let raw = text?.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Double(raw) else {
            return nil
        }
        return forcePositive ? abs(value) : value
    }

    private func snapshotEntriesByItemID(for snapshot: AssetSnapshot?) -> [UUID: AssetEntry] {
        guard let snapshot else { return [:] }
        return Dictionary(uniqueKeysWithValues: snapshot.entries.compactMap { entry in
            guard let itemID = entry.item?.id else { return nil }
            return (itemID, entry)
        })
    }

    private func displayedTotalAmount(for itemGroups: Dictionary<UUID, [AssetItem]>.Values, entriesByItemID: [UUID: AssetEntry]) -> Double {
        itemGroups
            .flatMap { $0 }
            .reduce(0) { partialResult, item in
                partialResult + (displayEntry(for: item, entriesByItemID: entriesByItemID)?.resolvedAmount ?? 0)
            }
    }

    private func displayEntry(for item: AssetItem, entriesByItemID: [UUID: AssetEntry]) -> AssetEntry? {
        if let snapshotEntry = entriesByItemID[item.id],
           snapshotEntry.amount != nil || snapshotEntry.quantity != nil || snapshotEntry.unitPrice != nil {
            return snapshotEntry
        }

        return item.latestEntry
    }
}

private enum RecordInputField: Hashable {
    case amount(UUID)
    case quantity(UUID)
    case unitPrice(UUID)
}

@MainActor
private func dismissActiveKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private struct RecordHeroMetric: View {
    let title: String
    let value: String
    let valueColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppLocalization.string(title))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private struct RecordHeroActionChip: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .bold))
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(AssetTheme.textPrimary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6.5)
        .background(AssetTheme.overlaySoft.opacity(0.62), in: Capsule())
        .overlay(
            Capsule()
                .stroke(AssetTheme.border.opacity(0.34), lineWidth: 1)
        )
    }
}

private struct RecordPageHero: View {
    let snapshot: AssetSnapshot
    let totalAssets: Double
    let netAssets: Double
    let totalLiabilities: Double
    let onAddAsset: () -> Void

    private var netAssetColor: Color {
        netAssets < 0 ? AssetTheme.negative : AssetTheme.textPrimary
    }

    private var totalAssetText: Text {
        let amount = totalAssets.currencyString()
        guard let dotIndex = amount.lastIndex(of: ".") else {
            return Text(amount)
                .font(.system(size: 32, weight: .semibold))
        }

        let major = String(amount[..<dotIndex])
        let minor = String(amount[dotIndex...])
        return Text(major)
            .font(.system(size: 32, weight: .semibold))
        + Text(minor)
            .font(.system(size: 19, weight: .semibold))
            .baselineOffset(1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    Text(AppLocalization.string("总资产"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.94))

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [AssetTheme.goldSoft.opacity(0.52), AssetTheme.border.opacity(0.08)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 28, height: 1)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    NavigationLink {
                        SnapshotArchiveView()
                    } label: {
                        RecordHeroActionChip(
                            systemImage: "clock.arrow.circlepath",
                            title: AppLocalization.string("历史记录")
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: onAddAsset) {
                        RecordHeroActionChip(
                            systemImage: "plus",
                            title: AppLocalization.string("新增资产")
                        )
                    }
                    .buttonStyle(.plain)
                    .onboardingAnchor(.recordsAddAsset)
                }
            }

            totalAssetText
                .foregroundStyle(
                    LinearGradient(
                        colors: [AssetTheme.textPrimary, AssetTheme.goldSoft.opacity(0.84)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .lineLimit(1)
                .minimumScaleFactor(0.74)
                .monospacedDigit()
                .onboardingAnchor(.recordsTotal)

            HStack(alignment: .bottom, spacing: 12) {
                Text(snapshot.date.recordDateString)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.9))

                Spacer(minLength: 12)

                HStack(spacing: 14) {
                    RecordHeroMetric(title: AppLocalization.string("净资产"), value: netAssets.currencyString(), valueColor: netAssetColor)

                    Rectangle()
                        .fill(AssetTheme.border.opacity(0.18))
                        .frame(width: 1, height: 24)

                    RecordHeroMetric(title: AppLocalization.string("负债"), value: totalLiabilities.currencyString(), valueColor: AssetTheme.negative.opacity(0.92))
                }
            }

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), AssetTheme.border.opacity(0.08)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.top, 4)
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

private struct AssetItemGlyph: View {
    let item: AssetItem
    var accent: Color = AssetTheme.goldSoft
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: AssetItemService.displaySymbolName(for: item))
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(accent)
            .frame(width: size + 3, height: size + 3)
    }
}

private struct RecordEntryGlyph: View {
    let item: AssetItem
    let tint: Color
    var glyphSize: CGFloat = 10

    var body: some View {
        AssetItemGlyph(item: item, accent: tint, size: glyphSize)
            .frame(width: 16, height: 18, alignment: .center)
    }
}

private struct RecordSectionHeader: View {
    let title: String
    let amount: String
    var amountColor: Color = AssetTheme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(AppLocalization.string(title))
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.94))
                .lineLimit(1)

            Spacer(minLength: 10)

            Text(amount)
                .font(.system(size: 15.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(amountColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }
}

private struct RecordCategoryCard: View {
    private let inputWidth: CGFloat = 74

    private enum InputBlock: Identifiable {
        case compact([AssetItem])
        case expanded(AssetItem)

        var id: String {
            switch self {
            case let .compact(items):
                return "compact-\(items.map(\.id.uuidString).joined(separator: "-"))"
            case let .expanded(item):
                return "expanded-\(item.id.uuidString)"
            }
        }
    }

    let category: AssetCategory
    let items: [AssetItem]
    let snapshotEntriesByItemID: [UUID: AssetEntry]
    let onboardingInputItemID: UUID?
    let onboardingActiveAnchorID: OnboardingAnchorID?
    @ObservedObject var marketStore: RemoteMarketStore
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    @Binding var unitPriceInputs: [UUID: String]
    @Binding var focusedField: RecordInputField?
    let onEdit: (AssetItem) -> Void
    let onEditValue: (AssetItem) -> Void
    @State private var draggedItemID: UUID?

    private let compactColumns = [
        GridItem(.flexible(), spacing: 0, alignment: .top),
        GridItem(.flexible(), spacing: 0, alignment: .top)
    ]


    private var categoryTotal: Double {
        items.reduce(0) { partialResult, item in
            partialResult + (snapshotEntry(for: item)?.resolvedAmount ?? 0)
        }
    }

    private func snapshotEntry(for item: AssetItem) -> AssetEntry? {
        snapshotEntriesByItemID[item.id] ?? item.latestEntry
    }

    private var inputBlocks: [InputBlock] {
        var blocks: [InputBlock] = []
        var compactItems: [AssetItem] = []

        func flushCompactItems() {
            guard !compactItems.isEmpty else { return }
            blocks.append(.compact(compactItems))
            compactItems.removeAll()
        }

        for item in items {
            if item.prefersCompactRecordInput {
                compactItems.append(item)
            } else {
                flushCompactItems()
                blocks.append(.expanded(item))
            }
        }

        flushCompactItems()
        return blocks
    }

    private func showsRightDivider(at index: Int, total: Int) -> Bool {
        index % 2 == 0 && index + 1 < total
    }

    private func showsBottomDivider(at index: Int, total: Int) -> Bool {
        let rowCount = Int(ceil(Double(total) / 2.0))
        return index / 2 < rowCount - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordSectionHeader(
                title: category.name,
                amount: categoryTotal.currencyString(),
                amountColor: AssetTheme.textPrimary
            )

            VStack(spacing: 10) {
                ForEach(inputBlocks) { block in
                    switch block {
                    case let .compact(compactItems):
                        RecordMatrixSurface {
                            LazyVGrid(columns: compactColumns, alignment: .leading, spacing: 0) {
                                ForEach(Array(compactItems.enumerated()), id: \.element.id) { index, item in
                                    ReorderableRecordCell(category: category, item: item, draggedItemID: $draggedItemID) {
                                        AssetEntryCompactCard(
                                            item: item,
                                            snapshotEntry: snapshotEntry(for: item),
                                            marketStore: marketStore,
                                            amountText: Binding(
                                                get: { amountInputs[item.id] ?? "" },
                                                set: { newValue in
                                                    amountInputs[item.id] = newValue
                                                }
                                            ),
                                            quantityText: Binding(
                                                get: { quantityInputs[item.id] ?? "" },
                                                set: { newValue in
                                                    quantityInputs[item.id] = newValue
                                                }
                                            ),
                                            focusedField: $focusedField,
                                            inputWidth: inputWidth,
                                            isOnboardingTarget: item.id == onboardingInputItemID,
                                            showsOnboardingInputPreview: onboardingActiveAnchorID == .recordsFirstInput && item.id == onboardingInputItemID,
                                            onEdit: {
                                                onEdit(item)
                                            },
                                            onEditValue: {
                                                onEditValue(item)
                                            }
                                        )
                                    }
                                    .overlay(alignment: .trailing) {
                                        if showsRightDivider(at: index, total: compactItems.count) {
                                            Rectangle()
                                                .fill(AssetTheme.border.opacity(0.34))
                                                .frame(width: 1)
                                        }
                                    }
                                    .overlay(alignment: .bottom) {
                                        if showsBottomDivider(at: index, total: compactItems.count) {
                                            Rectangle()
                                                .fill(AssetTheme.border.opacity(0.34))
                                                .frame(height: 1)
                                        }
                                    }
                                }
                            }
                        }
                    case let .expanded(item):
                        RecordMatrixSurface {
                            ReorderableRecordCell(category: category, item: item, draggedItemID: $draggedItemID) {
                                AssetEntryInputRow(
                                    item: item,
                                    snapshotEntry: snapshotEntry(for: item),
                                    marketStore: marketStore,
                                    amountText: Binding(
                                        get: { amountInputs[item.id] ?? "" },
                                        set: { newValue in
                                            amountInputs[item.id] = newValue
                                        }
                                    ),
                                    quantityText: Binding(
                                        get: { quantityInputs[item.id] ?? "" },
                                        set: { newValue in
                                            quantityInputs[item.id] = newValue
                                        }
                                    ),
                                    unitPriceText: Binding(
                                        get: { unitPriceInputs[item.id] ?? "" },
                                        set: { newValue in
                                            unitPriceInputs[item.id] = newValue
                                        }
                                    ),
                                    focusedField: $focusedField,
                                    inputWidth: inputWidth,
                                    isOnboardingTarget: item.id == onboardingInputItemID,
                                    showsOnboardingInputPreview: onboardingActiveAnchorID == .recordsFirstInput && item.id == onboardingInputItemID,
                                    onEdit: {
                                        onEdit(item)
                                    },
                                    onEditValue: {
                                        onEditValue(item)
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct LiabilityCategorySection: View {
    private let inputWidth: CGFloat = 74

    let category: AssetCategory
    let items: [AssetItem]
    let snapshotEntriesByItemID: [UUID: AssetEntry]
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    @Binding var focusedField: RecordInputField?
    let onEdit: (AssetItem) -> Void
    let onEditValue: (AssetItem) -> Void
    @State private var draggedItemID: UUID?

    private let columns = [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)]


    private var categoryTotal: Double {
        items.reduce(0) { partialResult, item in
            partialResult + (snapshotEntry(for: item)?.resolvedAmount ?? 0)
        }
    }

    private func snapshotEntry(for item: AssetItem) -> AssetEntry? {
        snapshotEntriesByItemID[item.id] ?? item.latestEntry
    }

    private func showsRightDivider(at index: Int, total: Int) -> Bool {
        index % 2 == 0 && index + 1 < total
    }

    private func showsBottomDivider(at index: Int, total: Int) -> Bool {
        let rowCount = Int(ceil(Double(total) / 2.0))
        return index / 2 < rowCount - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordSectionHeader(
                title: category.name,
                amount: categoryTotal.currencyString(),
                amountColor: AssetTheme.negative.opacity(0.94)
            )

            RecordMatrixSurface {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ReorderableRecordCell(category: category, item: item, draggedItemID: $draggedItemID) {
                            LiabilityEntryCard(
                                item: item,
                                snapshotEntry: snapshotEntry(for: item),
                                amountText: Binding(
                                    get: { amountInputs[item.id] ?? "" },
                                    set: { newValue in
                                        amountInputs[item.id] = newValue
                                    }
                                ),
                                quantityText: Binding(
                                    get: { quantityInputs[item.id] ?? "" },
                                    set: { newValue in
                                        quantityInputs[item.id] = newValue
                                    }
                                ),
                                focusedField: $focusedField,
                                inputWidth: inputWidth,
                                onEdit: {
                                    onEdit(item)
                                },
                                onEditValue: {
                                    onEditValue(item)
                                }
                            )
                        }
                        .overlay(alignment: .trailing) {
                            if showsRightDivider(at: index, total: items.count) {
                                Rectangle()
                                    .fill(AssetTheme.border.opacity(0.34))
                                    .frame(width: 1)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if showsBottomDivider(at: index, total: items.count) {
                                Rectangle()
                                    .fill(AssetTheme.border.opacity(0.34))
                                    .frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct LiabilityEntryCard: View {
    let item: AssetItem
    let snapshotEntry: AssetEntry?
    @Binding var amountText: String
    @Binding var quantityText: String
    @Binding var focusedField: RecordInputField?
    let inputWidth: CGFloat
    let onEdit: () -> Void
    let onEditValue: () -> Void

    private var activeField: RecordInputField {
        item.valuationMethod == .directAmount ? .amount(item.id) : .quantity(item.id)
    }

    private var isEditing: Bool {
        focusedField == activeField
    }

    private var hasDisplayValue: Bool {
        displayValue != "--"
    }

    var body: some View {
        RecordInputCard {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    onEdit()
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        RecordEntryGlyph(item: item, tint: hasDisplayValue ? AssetTheme.negative : AssetTheme.negative.opacity(0.72))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalization.string(item.name))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(hasDisplayValue ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .allowsTightening(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isEditing {
                    if item.valuationMethod == .directAmount {
                        ATMInputField(
                            text: $amountText,
                            placeholder: "0",
                            width: inputWidth,
                            focusedField: $focusedField,
                            focusValue: .amount(item.id),
                            centered: true,
                            fontSize: 12,
                            fontWeight: .medium,
                            height: 32,
                            backgroundOpacity: 0.54,
                            strokeOpacity: 0.18
                        )
                    } else {
                        ATMInputField(
                            text: $quantityText,
                            placeholder: item.compactRecordPlaceholder,
                            width: inputWidth,
                            focusedField: $focusedField,
                            focusValue: .quantity(item.id),
                            centered: true,
                            fontSize: 12,
                            fontWeight: .medium,
                            height: 32,
                            backgroundOpacity: 0.54,
                            strokeOpacity: 0.18
                        )
                    }
                } else {
                    Button {
                        onEditValue()
                    } label: {
                        Text(displayValue)
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .foregroundStyle(hasDisplayValue ? AssetTheme.textPrimary : AssetTheme.textSecondary.opacity(0.78))
                            .frame(width: inputWidth, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var displayValue: String {
        if item.valuationMethod == .directAmount {
            if !amountText.isEmpty { return amountText }
            if let latestAmount = snapshotEntry?.amount {
                return latestAmount.plainNumberString()
            }
        } else {
            if !quantityText.isEmpty { return quantityText }
            if let latestQuantity = snapshotEntry?.quantity {
                return latestQuantity.plainNumberString()
            }
        }
        return "--"
    }
}

private struct RecordMatrixSurface<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape
                .fill(
                    LinearGradient(
                        colors: [AssetTheme.surface.opacity(0.24), AssetTheme.background.opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            shape
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), AssetTheme.goldSoft.opacity(0.08), AssetTheme.border.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .clipShape(shape)
    }
}

private struct RecordInputCard<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
    }
}

private struct ReorderableRecordCell<Content: View>: View {
    @Environment(\.modelContext) private var modelContext

    let category: AssetCategory
    let item: AssetItem
    @Binding var draggedItemID: UUID?
    @ViewBuilder var content: Content

    init(
        category: AssetCategory,
        item: AssetItem,
        draggedItemID: Binding<UUID?>,
        @ViewBuilder content: () -> Content
    ) {
        self.category = category
        self.item = item
        self._draggedItemID = draggedItemID
        self.content = content()
    }

    var body: some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(draggedItemID == item.id ? 0.55 : 1)
            .scaleEffect(draggedItemID == item.id ? 0.98 : 1)
            .onDrag {
                draggedItemID = item.id
                return NSItemProvider(object: item.id.uuidString as NSString)
            }
            .onDrop(of: [UTType.plainText], delegate: RecordItemDropDelegate(
                targetItem: item,
                category: category,
                draggedItemID: $draggedItemID,
                modelContext: modelContext
            ))
    }
}

private struct RecordItemDropDelegate: DropDelegate {
    let targetItem: AssetItem
    let category: AssetCategory
    @Binding var draggedItemID: UUID?
    let modelContext: ModelContext

    func dropEntered(info: DropInfo) {
        guard let draggedItemID,
              draggedItemID != targetItem.id else { return }

        let orderedItems = category.activeSortedItems
        guard let fromIndex = orderedItems.firstIndex(where: { $0.id == draggedItemID }),
              let toIndex = orderedItems.firstIndex(where: { $0.id == targetItem.id }),
              fromIndex != toIndex else { return }

        var reorderedIDs = orderedItems.map(\.id)
        reorderedIDs.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)

        withAnimation(.easeInOut(duration: 0.16)) {
            try? AssetItemService.reorderItems(in: category, itemIDsInOrder: reorderedIDs, context: modelContext)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
    }

    func dropExited(info: DropInfo) {
        if draggedItemID == targetItem.id {
            draggedItemID = nil
        }
    }
}

private struct AssetEntryCompactCard: View {
    let item: AssetItem
    let snapshotEntry: AssetEntry?
    @ObservedObject var marketStore: RemoteMarketStore
    @Binding var amountText: String
    @Binding var quantityText: String
    @Binding var focusedField: RecordInputField?
    let inputWidth: CGFloat
    let isOnboardingTarget: Bool
    let showsOnboardingInputPreview: Bool
    let onEdit: () -> Void
    let onEditValue: () -> Void

    private var activeField: RecordInputField {
        item.valuationMethod == .directAmount ? .amount(item.id) : .quantity(item.id)
    }

    private var isEditing: Bool {
        focusedField == activeField
    }

    private var hasDisplayValue: Bool {
        displayValue != "--"
    }

    private var showsEditableField: Bool {
        isEditing || showsOnboardingInputPreview
    }

    var body: some View {
        RecordInputCard {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    onEdit()
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        RecordEntryGlyph(item: item, tint: hasDisplayValue ? AssetTheme.goldSoft : AssetTheme.goldSoft.opacity(0.74))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLocalization.string(item.name))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(hasDisplayValue ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .allowsTightening(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showsEditableField {
                    if item.valuationMethod == .directAmount {
                        ATMInputField(text: $amountText, placeholder: "0", width: inputWidth, focusedField: $focusedField, focusValue: .amount(item.id), centered: true, fontSize: 12, fontWeight: .medium, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                            .onboardingAnchorIf(isOnboardingTarget, .recordsFirstInput)
                    } else {
                        ATMInputField(text: $quantityText, placeholder: "0", width: inputWidth, focusedField: $focusedField, focusValue: .quantity(item.id), centered: true, fontSize: 12, fontWeight: .medium, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                            .onboardingAnchorIf(isOnboardingTarget, .recordsFirstInput)
                    }
                } else {
                    Button {
                        onEditValue()
                    } label: {
                        Text(displayValue)
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .foregroundStyle(hasDisplayValue ? AssetTheme.textPrimary : AssetTheme.textSecondary.opacity(0.78))
                            .frame(width: inputWidth, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .onboardingAnchorIf(isOnboardingTarget, .recordsFirstInput)
                }
            }
        }
    }

    private var displayValue: String {
        if item.valuationMethod == .directAmount {
            if !amountText.isEmpty { return amountText }
            if let latestAmount = snapshotEntry?.amount {
                return latestAmount.plainNumberString()
            }
        } else {
            if !quantityText.isEmpty { return quantityText }
            if let latestQuantity = snapshotEntry?.quantity {
                return latestQuantity.plainNumberString()
            }
        }
        return "--"
    }
}

private struct AssetEntryInputRow: View {
    let item: AssetItem
    let snapshotEntry: AssetEntry?
    @ObservedObject var marketStore: RemoteMarketStore
    @Binding var amountText: String
    @Binding var quantityText: String
    @Binding var unitPriceText: String
    @Binding var focusedField: RecordInputField?
    let inputWidth: CGFloat
    let isOnboardingTarget: Bool
    let showsOnboardingInputPreview: Bool
    let onEdit: () -> Void
    let onEditValue: () -> Void

    private var isEditing: Bool {
        focusedField == .quantity(item.id) || focusedField == .unitPrice(item.id)
    }

    private var resolvedValueText: String {
        if !quantityText.isEmpty { return quantityText }
        return snapshotEntry?.quantity?.plainNumberString() ?? "--"
    }

    private var hasResolvedValue: Bool {
        resolvedValueText != "--"
    }

    private var showsEditableField: Bool {
        isEditing || showsOnboardingInputPreview
    }

    var body: some View {
        RecordInputCard {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    onEdit()
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        RecordEntryGlyph(item: item, tint: hasResolvedValue ? AssetTheme.goldSoft : AssetTheme.goldSoft.opacity(0.74))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLocalization.string(item.name))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(hasResolvedValue ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .allowsTightening(true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .layoutPriority(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {

                    if showsEditableField {
                        HStack(spacing: 6) {
                            ATMInputField(text: $quantityText, placeholder: AppLocalization.string("数量"), width: inputWidth, focusedField: $focusedField, focusValue: .quantity(item.id), centered: true, fontSize: 12, fontWeight: .medium, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                                .onboardingAnchorIf(isOnboardingTarget, .recordsFirstInput)
                        }
                    } else {
                        HStack(spacing: 12) {
                            Button {
                                onEditValue()
                            } label: {
                                recordValueLabel(title: AppLocalization.string("数量"), value: quantityText)
                            }
                            .buttonStyle(.plain)
                            .onboardingAnchorIf(isOnboardingTarget, .recordsFirstInput)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recordValueLabel(title: String, value: String) -> some View {
        let fallbackValue = (title == AppLocalization.string("数量"))
            ? (snapshotEntry?.quantity?.plainNumberString() ?? "--")
            : (snapshotEntry?.unitPrice?.plainNumberString() ?? "--")
        let resolvedValue = value.isEmpty ? fallbackValue : value

        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AssetTheme.textSecondary)
            Text(resolvedValue)
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(resolvedValue == "--" ? AssetTheme.textSecondary.opacity(0.78) : AssetTheme.textPrimary)
        }
        .frame(width: inputWidth, alignment: .trailing)
    }
}

private struct ATMInputField: View {
    @Binding var text: String
    let placeholder: String
    var width: CGFloat? = nil
    @Binding var focusedField: RecordInputField?
    let focusValue: RecordInputField
    var centered: Bool = false
    var fontSize: CGFloat = 17
    var fontWeight: Font.Weight = .medium
    var height: CGFloat = 42
    var backgroundOpacity: Double = 0.66
    var strokeOpacity: Double = 0.52

    var body: some View {
        ATMUIKitInputField(
            text: $text,
            placeholder: placeholder,
            focusedField: $focusedField,
            focusValue: focusValue,
            centered: centered,
            fontSize: fontSize,
            fontWeight: fontWeight
        )
        .padding(.horizontal, 2)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: centered ? .center : .trailing)
        .frame(width: width, height: height)
        .background(AssetTheme.background.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AssetTheme.border.opacity(strokeOpacity), lineWidth: 1)
        )
    }
}

private struct ATMUIKitInputField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var focusedField: RecordInputField?
    let focusValue: RecordInputField
    var centered: Bool = false
    var fontSize: CGFloat = 17
    var fontWeight: Font.Weight = .semibold

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.keyboardType = .decimalPad
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.tintColor = UIColor(AssetTheme.textPrimary)
        textField.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isBeingDismantled = false

        if uiView.text != text {
            uiView.text = text
        }

        uiView.textAlignment = centered ? .center : .right
        uiView.font = .systemFont(ofSize: fontSize, weight: fontWeight.uiFontWeight)
        uiView.textColor = UIColor(AssetTheme.textPrimary)
        uiView.attributedPlaceholder = NSAttributedString(
            string: AppLocalization.string(placeholder),
            attributes: [.foregroundColor: UIColor(AssetTheme.textSecondary)]
        )

        let shouldBeFirstResponder = focusedField == focusValue
        if shouldBeFirstResponder, !uiView.isFirstResponder {
            context.coordinator.isSyncingFirstResponder = true
            DispatchQueue.main.async {
                guard context.coordinator.parent.focusedField == context.coordinator.parent.focusValue,
                      !uiView.isFirstResponder else { return }
                uiView.becomeFirstResponder()
                context.coordinator.moveCaretToEnd(in: uiView)
            }
        } else if !shouldBeFirstResponder, uiView.isFirstResponder {
            context.coordinator.isSyncingFirstResponder = true
            DispatchQueue.main.async {
                guard context.coordinator.parent.focusedField != context.coordinator.parent.focusValue,
                      uiView.isFirstResponder else { return }
                uiView.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: UITextField, coordinator: Coordinator) {
        coordinator.isBeingDismantled = true
        uiView.delegate = nil
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ATMUIKitInputField
        var isSyncingFirstResponder = false
        var isBeingDismantled = false

        init(parent: ATMUIKitInputField) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isSyncingFirstResponder = false
            parent.focusedField = parent.focusValue
            moveCaretToEnd(in: textField)
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            // Keep user typing fluid. Forcing the caret on every selection update
            // can fight UIKit's own text editing cycle and makes record inputs feel sticky.
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            defer { isSyncingFirstResponder = false }

            guard !isBeingDismantled else { return }
            guard !isSyncingFirstResponder else { return }
            guard parent.focusedField == parent.focusValue else { return }

            parent.focusedField = nil
        }

        func moveCaretToEnd(in textField: UITextField) {
            let end = textField.endOfDocument
            guard let range = textField.textRange(from: end, to: end) else { return }
            textField.selectedTextRange = range
        }
    }
}

private extension Font.Weight {
    var uiFontWeight: UIFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

private let assetIconOptions = AssetIconRegistry.definitions

private let autoAssetGridColumns = [
    GridItem(.flexible(), spacing: 6),
    GridItem(.flexible(), spacing: 6),
    GridItem(.flexible(), spacing: 6),
    GridItem(.flexible(), spacing: 6)
]

private func autoAssetSymbolName(for kind: AutoPricedAssetKind) -> String {
    switch kind {
    case .gold: return "seal.fill"
    case .btc: return "bitcoinsign.circle.fill"
    case .eth: return "e.circle.fill"
    case .bnb: return "b.circle.fill"
    case .sol: return "s.circle.fill"
    case .xrp: return "x.circle.fill"
    case .doge: return "d.circle.fill"
    case .usd: return "dollarsign.circle.fill"
    case .eur: return "eurosign.circle.fill"
    case .gbp: return "sterlingsign.circle.fill"
    case .jpy: return "yensign.circle.fill"
    case .hkd: return "dollarsign.circle.fill"
    case .sgd: return "dollarsign.circle.fill"
    case .aud: return "dollarsign.circle.fill"
    case .cad: return "dollarsign.circle.fill"
    case .krw: return "wonsign.circle.fill"
    }
}

private struct AssetIconView: View {
    let iconKey: String
    var fallbackSymbolName: String
    var accent: Color = AssetTheme.goldSoft
    var iconSize: CGFloat = 14
    var frameSize: CGFloat? = nil

    private var definition: AssetIconDefinition? {
        AssetIconRegistry.definition(for: iconKey)
    }

    var body: some View {
        Image(systemName: definition?.symbolName ?? fallbackSymbolName)
            .font(.system(size: iconSize, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(accent)
            .frame(width: iconSize, height: iconSize)
            .frame(width: frameSize ?? iconSize, height: frameSize ?? iconSize)
    }
}

private struct AssetEditorForm: View {
    @Binding var name: String
    @Binding var selectedCategoryID: UUID?
    @Binding var selectedAutoPricedAssetKind: AutoPricedAssetKind?
    @Binding var selectedIconName: String
    let sortedCategories: [AssetCategory]
    let isAutoPricedLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLocalization.string("名称"))
                            .font(.headline)
                            .foregroundStyle(AssetTheme.textPrimary)

                        TextField(AppLocalization.string("示例：银行卡、房产、车辆"), text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AssetTheme.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(AssetTheme.background.opacity(0.66), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(AssetTheme.border.opacity(0.52), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLocalization.string("归类"))
                            .font(.headline)
                            .foregroundStyle(AssetTheme.textPrimary)

                        Picker(AppLocalization.string("归类"), selection: Binding(
                            get: { selectedCategoryID ?? sortedCategories.first?.id },
                            set: { selectedCategoryID = $0 }
                        )) {
                            ForEach(sortedCategories) { category in
                                Text(AppLocalization.string(category.name)).tag(Optional.some(category.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(height: 48)
                        .frame(maxWidth: .infinity)
                        .background(AssetTheme.background.opacity(0.66), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AssetTheme.border.opacity(0.52), lineWidth: 1)
                        )
                    }
                    .frame(width: 132)
                }

                Text(AppLocalization.string("图标"))
                    .font(.headline)
                    .foregroundStyle(AssetTheme.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(assetIconOptions) { option in
                            Button {
                                selectedIconName = option.key
                            } label: {
                                VStack(spacing: 6) {
                                    AssetIconView(
                                        iconKey: option.key,
                                        fallbackSymbolName: option.symbolName,
                                        accent: selectedIconName == option.key ? AssetTheme.gold : AssetTheme.textPrimary,
                                        iconSize: 22,
                                        frameSize: 34
                                    )
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(selectedIconName == option.key ? AssetTheme.overlayStrong : AssetTheme.overlaySubtle)
                                        )
                                    Text(AppLocalization.string(option.label))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(selectedIconName == option.key ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                                }
                                .padding(.vertical, 3)
                                .frame(width: 56)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.string("特殊资产"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)

                Text(AppLocalization.string(isAutoPricedLocked ? "该资产已绑定自动定价类型。如需调整，请新建资产类型。" : "以下资产支持数量录入，价格将自动更新。"))
                    .font(.footnote)
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.8))

                LazyVGrid(columns: autoAssetGridColumns, alignment: .leading, spacing: 10) {
                    Button {
                        guard !isAutoPricedLocked else { return }
                        selectedAutoPricedAssetKind = nil
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "square.grid.2x2")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(selectedAutoPricedAssetKind == nil ? AssetTheme.gold : AssetTheme.textPrimary)
                                .shadow(color: selectedAutoPricedAssetKind == nil ? AssetTheme.gold.opacity(0.45) : .clear, radius: 10)
                            Text(AppLocalization.string("普通资产"))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(selectedAutoPricedAssetKind == nil ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .shadow(color: selectedAutoPricedAssetKind == nil ? AssetTheme.gold.opacity(0.3) : .clear, radius: 8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .opacity(isAutoPricedLocked ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isAutoPricedLocked)

                    ForEach(AutoPricedAssetKind.allCases) { kind in
                        Button {
                            guard !isAutoPricedLocked else { return }
                            selectedAutoPricedAssetKind = kind
                            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                name = kind.defaultName
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: autoAssetSymbolName(for: kind))
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(selectedAutoPricedAssetKind == kind ? AssetTheme.gold : AssetTheme.textPrimary)
                                    .shadow(color: selectedAutoPricedAssetKind == kind ? AssetTheme.gold.opacity(0.45) : .clear, radius: 10)
                                Text(kind.defaultName)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(selectedAutoPricedAssetKind == kind ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .shadow(color: selectedAutoPricedAssetKind == kind ? AssetTheme.gold.opacity(0.3) : .clear, radius: 8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .opacity(isAutoPricedLocked && selectedAutoPricedAssetKind != kind ? 0.5 : 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(isAutoPricedLocked)
                    }
                }
            }
        }
    }
}

private struct AddAssetItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var categories: [AssetCategory]

    @State private var name = ""
    @State private var selectedCategoryID: UUID?
    @State private var selectedAutoPricedAssetKind: AutoPricedAssetKind?
    @State private var selectedIconName = ""
    @State private var errorMessage: String?

    private var sortedCategories: [AssetCategory] {
        categories.sorted {
            if $0.group.sortPriority == $1.group.sortPriority {
                return $0.createdAt < $1.createdAt
            }
            return $0.group.sortPriority < $1.group.sortPriority
        }
    }

    private var canSave: Bool {
        !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategory != nil
    }

    private var selectedCategory: AssetCategory? {
        guard let selectedCategoryID else { return sortedCategories.first }
        return sortedCategories.first(where: { $0.id == selectedCategoryID })
    }

    private var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return selectedAutoPricedAssetKind?.defaultName ?? ""
    }

    private var resolvedIconName: String {
        let trimmed = selectedIconName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return AssetItemService.suggestedIconName(for: resolvedName, autoPricedAssetKind: selectedAutoPricedAssetKind)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        AssetEditorForm(
                            name: $name,
                            selectedCategoryID: $selectedCategoryID,
                            selectedAutoPricedAssetKind: $selectedAutoPricedAssetKind,
                            selectedIconName: $selectedIconName,
                            sortedCategories: sortedCategories,
                            isAutoPricedLocked: false
                        )

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(AssetTheme.negative)
                                .padding(.horizontal, 4)
                        }

                        Color.clear
                            .frame(height: 180)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissActiveKeyboard()
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissActiveKeyboard()
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("添加资产类型"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("保存")) {
                        save()
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? AssetTheme.gold : AssetTheme.textSecondary)
                }
            }
            .task {
                if selectedCategoryID == nil {
                    selectedCategoryID = sortedCategories.first?.id
                }
            }
        }
    }

    @MainActor
    private func save() {
        guard let selectedCategory else { return }

        do {
            try AssetItemService.createItem(
                name: resolvedName,
                category: selectedCategory,
                valuationMethod: selectedAutoPricedAssetKind == nil ? .directAmount : .quantityAndUnitPrice,
                autoPricedAssetKind: selectedAutoPricedAssetKind,
                iconName: resolvedIconName,
                in: modelContext
            )
            dismiss()
        } catch {
            errorMessage = AppLocalization.string("保存失败，请稍后再试")
            print("[AssetTimeMachine] create item failed: \(error)")
        }
    }
}

private struct QuickRecordValueSheet: View {
    @Environment(\.modelContext) private var modelContext

    private enum QuickRecordValueField: Hashable {
        case primary
        case unitPrice
    }

    let item: AssetItem
    let snapshot: AssetSnapshot?
    @ObservedObject var marketStore: RemoteMarketStore
    let onCancel: () -> Void
    let onSaved: () -> Void

    @State private var amountText: String
    @State private var quantityText: String
    @State private var unitPriceText: String
    @State private var errorMessage: String?
    @State private var isRefreshingAutoPrice = false
    @FocusState private var focusedField: QuickRecordValueField?

    init(item: AssetItem, snapshot: AssetSnapshot?, marketStore: RemoteMarketStore, onCancel: @escaping () -> Void, onSaved: @escaping () -> Void) {
        self.item = item
        self.snapshot = snapshot
        self.marketStore = marketStore
        self.onCancel = onCancel
        self.onSaved = onSaved

        let currentEntry = snapshot?.entries.first(where: { $0.item?.id == item.id })
        _amountText = State(initialValue: currentEntry?.amount?.plainNumberString() ?? "")
        _quantityText = State(initialValue: currentEntry?.quantity?.plainNumberString() ?? "")
        _unitPriceText = State(initialValue: currentEntry?.unitPrice?.plainNumberString() ?? item.resolvedAutoUnitPrice(using: marketStore)?.plainNumberString() ?? "")
    }

    private var isLiability: Bool {
        item.category?.group == .liability
    }

    private var primaryFieldTitle: String {
        switch item.valuationMethod {
        case .directAmount:
            return AppLocalization.string(isLiability ? "负债数额" : "资产数额")
        case .quantityAndUnitPrice:
            return AppLocalization.string("数量")
        }
    }

    private var displayedUnitPriceText: String? {
        let trimmed = unitPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private var trailingUnitPriceTitle: String? {
        guard item.valuationMethod == .quantityAndUnitPrice else { return nil }
        return AppLocalization.string(item.autoPricedAssetKind == nil ? "单价" : "参考单价")
    }

    private var trailingUnitPriceValue: String? {
        guard item.valuationMethod == .quantityAndUnitPrice else { return nil }
        if item.autoPricedAssetKind != nil,
           let rate = item.resolvedAutoUnitPrice(using: marketStore) {
            return rate.currencyString()
        }
        return displayedUnitPriceText
    }

    private var trailingUnitPriceTimestamp: String? {
        guard item.valuationMethod == .quantityAndUnitPrice,
              item.autoPricedAssetKind != nil,
              let fetchedAt = item.autoPriceFetchedAt(using: marketStore) else {
            return nil
        }
        return AppLocalization.format("%@更新", fetchedAt.recordTimeString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                chromeButton(title: AppLocalization.string("取消"), tint: AssetTheme.textSecondary, action: onCancel)

                Spacer(minLength: 8)

                Text(AppLocalization.string("修改本次记录"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                chromeButton(title: AppLocalization.string("保存"), tint: AssetTheme.gold, action: save)
            }

            HStack(alignment: .center, spacing: 12) {
                AssetItemGlyph(item: item, accent: isLiability ? AssetTheme.negative : AssetTheme.gold, size: 18)

                Text(AppLocalization.string(item.name))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 8)

                if let trailingUnitPriceTitle,
                   let trailingUnitPriceValue {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(trailingUnitPriceTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AssetTheme.textSecondary)
                        Text(trailingUnitPriceValue)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(AssetTheme.textPrimary)
                        if let trailingUnitPriceTimestamp {
                            Text(trailingUnitPriceTimestamp)
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                }
            }

            if item.autoPricedAssetKind != nil {
                HStack(spacing: 8) {
                    Button {
                        Task { await refreshAutoPriceManually() }
                    } label: {
                        HStack(spacing: 6) {
                            if isRefreshingAutoPrice {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(AssetTheme.gold)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption.weight(.bold))
                            }
                            Text(AppLocalization.string(isRefreshingAutoPrice ? "刷新中" : "手动刷新最新价格"))
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(AssetTheme.goldSoft)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AssetTheme.overlayMedium.opacity(0.85), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshingAutoPrice)

                    Spacer(minLength: 0)
                }
            }

            quickEditField(
                title: primaryFieldTitle,
                text: bindingForPrimaryField(),
                placeholder: AppLocalization.format("输入%@", primaryFieldTitle),
                focus: .primary
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(AssetTheme.negative)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), AssetTheme.gold.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.28), radius: 30, x: 0, y: 18)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-disableQuickEditAutoFocus") {
                return
            }
            #endif
            await Task.yield()
            focusedField = .primary
        }
    }

    @ViewBuilder
    private func quickEditField(title: String, text: Binding<String>, placeholder: String, focus: QuickRecordValueField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string(title))
                .font(.caption.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                .foregroundStyle(AssetTheme.textPrimary)
                .focused($focusedField, equals: focus)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AssetTheme.overlayMedium.opacity(0.9))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                }
        }
    }

    private func chromeButton(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(AppLocalization.string(title), action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func bindingForPrimaryField() -> Binding<String> {
        switch item.valuationMethod {
        case .directAmount:
            return $amountText
        case .quantityAndUnitPrice:
            return $quantityText
        }
    }

    @MainActor
    private func save() {
        guard let snapshot else {
            errorMessage = AppLocalization.string("今日记录尚未加载，请稍后再试")
            return
        }

        do {
            try saveCurrentValues(into: snapshot)
            onSaved()
        } catch let error as QuickRecordValueValidationError {
            errorMessage = error.message
        } catch {
            errorMessage = AppLocalization.string("保存失败，请稍后再试")
            print("[AssetTimeMachine] quick record save failed: \(error)")
        }
    }

    @MainActor
    private func saveCurrentValues(into snapshot: AssetSnapshot) throws {
        switch item.valuationMethod {
        case .directAmount:
            let amount = try validatedNumber(from: amountText, forcePositive: isLiability, fieldName: primaryFieldTitle)
            try SnapshotService.upsertEntry(snapshot: snapshot, item: item, amount: amount, in: modelContext)
        case .quantityAndUnitPrice:
            let quantity = try validatedNumber(from: quantityText, fieldName: primaryFieldTitle)
            let unitPrice: Double?
            if let autoRate = item.resolvedAutoUnitPrice(using: marketStore), item.autoPricedAssetKind != nil {
                unitPrice = autoRate
                unitPriceText = autoRate.plainNumberString()
            } else {
                unitPrice = normalizedReadonlyNumber(from: unitPriceText)
                    ?? snapshot.entries.first(where: { $0.item?.id == item.id })?.unitPrice
                    ?? item.latestEntry?.unitPrice
            }
            try SnapshotService.upsertEntry(snapshot: snapshot, item: item, quantity: quantity, unitPrice: unitPrice, in: modelContext)
        }
    }

    @MainActor
    private func refreshAutoPriceManually() async {
        guard item.autoPricedAssetKind != nil else { return }
        isRefreshingAutoPrice = true
        errorMessage = nil
        defer { isRefreshingAutoPrice = false }

        await marketStore.refreshLiveData()

        guard let latestRate = item.resolvedAutoUnitPrice(using: marketStore) else {
            errorMessage = AppLocalization.string("暂时没拿到最新价格，稍后再试")
            return
        }

        unitPriceText = latestRate.plainNumberString()

        guard let snapshot else { return }
        do {
            try saveCurrentValues(into: snapshot)
        } catch let error as QuickRecordValueValidationError {
            errorMessage = error.message
        } catch {
            errorMessage = AppLocalization.string("刷新后写入记录失败，请稍后再试")
            print("[AssetTimeMachine] manual auto price refresh failed: \(error)")
        }
    }

    private func validatedNumber(from text: String, forcePositive: Bool = false, fieldName: String) throws -> Double? {
        let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let value = Double(raw) else {
            throw QuickRecordValueValidationError(message: AppLocalization.format("%@请输入有效数字", fieldName))
        }
        return forcePositive ? abs(value) : value
    }

    private func normalizedReadonlyNumber(from text: String) -> Double? {
        let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return Double(raw)
    }
}

private struct QuickRecordValueValidationError: Error {
    let message: String
}

private struct EditAssetItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var categories: [AssetCategory]

    let item: AssetItem
    let snapshot: AssetSnapshot?
    @State private var name: String
    @State private var selectedCategoryID: UUID?
    @State private var selectedAutoPricedAssetKind: AutoPricedAssetKind?
    @State private var selectedIconName: String
    @State private var recordQuantityText: String
    @State private var recordUnitPriceText: String
    @State private var errorMessage: String?

    init(item: AssetItem, snapshot: AssetSnapshot?) {
        self.item = item
        self.snapshot = snapshot
        _name = State(initialValue: item.name)
        _selectedCategoryID = State(initialValue: item.category?.id)
        _selectedAutoPricedAssetKind = State(initialValue: item.autoPricedAssetKind)
        let storedIconName = (item.iconName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let initialIcon = storedIconName.isEmpty
            ? AssetItemService.suggestedIconName(for: item.name, autoPricedAssetKind: item.autoPricedAssetKind)
            : storedIconName
        _selectedIconName = State(initialValue: initialIcon)
        let currentEntry = snapshot?.entries.first(where: { $0.item?.id == item.id })
        _recordQuantityText = State(initialValue: currentEntry?.quantity?.plainNumberString() ?? "")
        _recordUnitPriceText = State(initialValue: currentEntry?.unitPrice?.plainNumberString() ?? "")
    }

    private var sortedCategories: [AssetCategory] {
        categories.sorted {
            if $0.group.sortPriority == $1.group.sortPriority {
                return $0.createdAt < $1.createdAt
            }
            return $0.group.sortPriority < $1.group.sortPriority
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategory != nil
    }

    private var selectedCategory: AssetCategory? {
        guard let selectedCategoryID else { return sortedCategories.first }
        return sortedCategories.first(where: { $0.id == selectedCategoryID })
    }

    private var resolvedIconName: String {
        let trimmed = selectedIconName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return AssetItemService.suggestedIconName(for: name, autoPricedAssetKind: selectedAutoPricedAssetKind)
    }

    private var showsRecordPricingEditor: Bool {
        item.valuationMethod == .quantityAndUnitPrice
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        AssetEditorForm(
                            name: $name,
                            selectedCategoryID: $selectedCategoryID,
                            selectedAutoPricedAssetKind: $selectedAutoPricedAssetKind,
                            selectedIconName: $selectedIconName,
                            sortedCategories: sortedCategories,
                            isAutoPricedLocked: item.autoPricedAssetKind != nil
                        )

                        if showsRecordPricingEditor {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(AppLocalization.string("本次记录"))
                                    .font(.headline)
                                    .foregroundStyle(AssetTheme.textPrimary)

                                VStack(alignment: .leading, spacing: 8) {
                                    Text(AppLocalization.string("数量"))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AssetTheme.textSecondary)
                                    TextField(AppLocalization.string("输入数量"), text: $recordQuantityText)
                                        .keyboardType(.decimalPad)
                                        .textFieldStyle(.plain)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(AssetTheme.textPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(AssetTheme.overlayMedium, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    Text(AppLocalization.string("单价"))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AssetTheme.textSecondary)
                                    TextField(AppLocalization.string("输入单价"), text: $recordUnitPriceText)
                                        .keyboardType(.decimalPad)
                                        .textFieldStyle(.plain)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(AssetTheme.textPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(AssetTheme.overlayMedium, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(AssetTheme.negative)
                                .padding(.horizontal, 4)
                        }

                        Color.clear
                            .frame(height: 180)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissActiveKeyboard()
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissActiveKeyboard()
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("编辑资产类型"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("保存")) {
                        save()
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? AssetTheme.gold : AssetTheme.textSecondary)
                }
            }
            .task {
                if selectedCategoryID == nil {
                    selectedCategoryID = item.category?.id ?? sortedCategories.first?.id
                }
            }
        }
    }

    @MainActor
    private func save() {
        guard let selectedCategory else { return }

        do {
            try AssetItemService.updateItem(
                item,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                iconName: resolvedIconName,
                category: selectedCategory,
                in: modelContext
            )

            if showsRecordPricingEditor, let snapshot {
                try SnapshotService.upsertEntry(
                    snapshot: snapshot,
                    item: item,
                    quantity: normalizedNumber(from: recordQuantityText),
                    unitPrice: normalizedNumber(from: recordUnitPriceText),
                    in: modelContext
                )
            }

            dismiss()
        } catch {
            errorMessage = AppLocalization.string("保存失败，请稍后再试")
            print("[AssetTimeMachine] update item failed: \(error)")
        }
    }

    private func normalizedNumber(from text: String) -> Double? {
        let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let value = Double(raw) else { return nil }
        return value
    }
}

private struct SummaryColumnMetric: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string(title))
                .font(AppTypography.eyebrow)
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(AppTypography.metricValue)
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            RoundedRectangle(cornerRadius: 999)
                .fill(accent)
                .frame(width: 24, height: 2)
        }
    }
}

private struct SnapshotArchiveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @State private var pendingDeletionSnapshot: AssetSnapshot?

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            if snapshots.isEmpty {
                EmptyStateCard(
                    title: AppLocalization.string("暂无记录"),
                    systemImage: "calendar.badge.plus"
                )
                .padding(.horizontal, 20)
            } else {
                List {
                    ForEach(snapshots) { snapshot in
                        NavigationLink {
                            SnapshotDetailView(snapshot: snapshot)
                        } label: {
                            SnapshotArchiveRow(snapshot: snapshot)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                pendingDeletionSnapshot = snapshot
                            } label: {
                                Label(AppLocalization.string("删除"), systemImage: "trash")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(AssetTheme.surface.opacity(0.94))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .alert(
            AppLocalization.string("确认删除这条记录？"),
            isPresented: Binding(
                get: { pendingDeletionSnapshot != nil },
                set: { if !$0 { pendingDeletionSnapshot = nil } }
            ),
            presenting: pendingDeletionSnapshot
        ) { snapshot in
            Button(AppLocalization.string("取消"), role: .cancel) {
                pendingDeletionSnapshot = nil
            }
            Button(AppLocalization.string("删除"), role: .destructive) {
                delete(snapshot: snapshot)
                pendingDeletionSnapshot = nil
            }
        } message: { snapshot in
            Text(AppLocalization.format(
                AppLocalization.string("将删除 %@ 的资产记录，删除后无法恢复。"),
                snapshot.date.longDateString
            ))
        }
    }

    @MainActor
    private func delete(snapshot: AssetSnapshot) {
        do {
            modelContext.delete(snapshot)
            try modelContext.save()
        } catch {
            print("[AssetTimeMachine] delete snapshot failed: \(error)")
        }
    }
}

private struct SnapshotArchiveRow: View {
    let snapshot: AssetSnapshot

    var body: some View {
        let metrics = PortfolioCalculator.metrics(for: snapshot)

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.date.longDateString)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)

                Text(AppLocalization.format("%d 项 · 负债 %@", snapshot.entries.count, metrics.totalLiabilities.currencyString()))
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(metrics.netAssets.currencyString())
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AssetTheme.goldSoft)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.vertical, 2)
    }
}

private struct SnapshotDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: AssetSnapshot
    @State private var editingEntry: AssetEntry?

    private var groupedEntries: [(group: AssetGroup, entries: [AssetEntry])] {
        AssetGroup.allCases.compactMap { group in
            let entries = snapshot.entries
                .filter { $0.item?.category?.group == group }
                .sorted { lhs, rhs in
                    (lhs.item?.sortOrder ?? 0) < (rhs.item?.sortOrder ?? 0)
                }
            guard !entries.isEmpty else { return nil }
            return (group, entries)
        }
    }

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ATMHeader(title: snapshot.date.longDateString) {
                        ATMBackButton {
                            dismiss()
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(PortfolioCalculator.netAssets(for: snapshot).currencyString())
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(AssetTheme.goldSoft)

                        HStack(spacing: 12) {
                            CompactStat(title: AppLocalization.string("资产"), value: PortfolioCalculator.totalAssets(for: snapshot).currencyString(), accent: AssetTheme.gold)
                            CompactStat(title: AppLocalization.string("负债"), value: PortfolioCalculator.totalLiabilities(for: snapshot).currencyString(), accent: AssetTheme.negative)
                        }
                    }
                    .atmCardStyle()

                    ForEach(groupedEntries, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(section.group.displayName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(AssetTheme.textPrimary)

                            ForEach(section.entries) { entry in
                                Button {
                                    editingEntry = entry
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(AppLocalization.string(entry.item?.name ?? "未命名"))
                                                .font(.headline)
                                                .foregroundStyle(AssetTheme.textPrimary)

                                            if let quantity = entry.quantity, let unitPrice = entry.unitPrice {
                                                Text("\(quantity.plainNumberString()) × \(unitPrice.plainNumberString())")
                                                    .font(.footnote)
                                                    .foregroundStyle(AssetTheme.textSecondary)
                                            } else {
                                                Text(AppLocalization.string("点按编辑这条历史记录"))
                                                    .font(.footnote)
                                                    .foregroundStyle(AssetTheme.textSecondary)
                                            }
                                        }

                                        Spacer()

                                        VStack(alignment: .trailing, spacing: 6) {
                                            Text(entry.resolvedAmount.currencyString())
                                                .font(.headline.weight(.semibold))
                                                .foregroundStyle(section.group == .liability ? AssetTheme.negative : AssetTheme.goldSoft)
                                            Image(systemName: "pencil")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(AssetTheme.textSecondary)
                                        }
                                        .monospacedDigit()
                                        .lineLimit(1)
                                    }
                                    .padding(14)
                                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .atmCardStyle()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editingEntry) { entry in
            SnapshotEntryEditSheet(entry: entry)
        }
    }
}

private enum SnapshotEntryEditField: Hashable {
    case amount
    case quantity
    case unitPrice
}

private struct SnapshotEntryEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let entry: AssetEntry

    @State private var amountText: String
    @State private var quantityText: String
    @State private var unitPriceText: String
    @State private var errorMessage: String?
    @FocusState private var focusedField: SnapshotEntryEditField?

    init(entry: AssetEntry) {
        self.entry = entry
        _amountText = State(initialValue: entry.amount?.plainNumberString() ?? "")
        _quantityText = State(initialValue: entry.quantity?.plainNumberString() ?? "")
        _unitPriceText = State(initialValue: entry.unitPrice?.plainNumberString() ?? "")
    }

    private var item: AssetItem? {
        entry.item
    }

    private var itemName: String {
        AppLocalization.string(item?.name ?? "未命名")
    }

    private var isLiability: Bool {
        item?.category?.group == .liability
    }

    private var usesQuantityAndUnitPrice: Bool {
        item?.valuationMethod == .quantityAndUnitPrice
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            if let item {
                                AssetItemGlyph(item: item, accent: isLiability ? AssetTheme.negative : AssetTheme.gold, size: 20)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(itemName)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(AssetTheme.textPrimary)
                                if let snapshotDate = entry.snapshot?.date {
                                    Text(snapshotDate.longDateString)
                                        .font(.footnote)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                            }
                        }
                        .atmCardStyle()

                        VStack(alignment: .leading, spacing: 14) {
                            if usesQuantityAndUnitPrice {
                                editField(
                                    title: AppLocalization.string("数量"),
                                    text: $quantityText,
                                    placeholder: AppLocalization.string("输入数量"),
                                    focus: .quantity
                                )
                                editField(
                                    title: AppLocalization.string("单价"),
                                    text: $unitPriceText,
                                    placeholder: AppLocalization.string("输入单价"),
                                    focus: .unitPrice
                                )
                            } else {
                                editField(
                                    title: AppLocalization.string(isLiability ? "负债数额" : "资产数额"),
                                    text: $amountText,
                                    placeholder: AppLocalization.string("输入金额"),
                                    focus: .amount
                                )
                            }

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(AssetTheme.negative)
                            }
                        }
                        .atmCardStyle()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 48)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("编辑历史记录"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("保存")) {
                        save()
                    }
                    .foregroundStyle(AssetTheme.gold)
                }
            }
            .task {
                await Task.yield()
                focusedField = usesQuantityAndUnitPrice ? .quantity : .amount
            }
        }
    }

    private func editField(title: String, text: Binding<String>, placeholder: String, focus: SnapshotEntryEditField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                .foregroundStyle(AssetTheme.textPrimary)
                .focused($focusedField, equals: focus)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(AssetTheme.overlayMedium, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @MainActor
    private func save() {
        guard let item = entry.item,
              let snapshot = entry.snapshot else {
            errorMessage = AppLocalization.string("记录数据不完整，暂时无法保存")
            return
        }

        do {
            if usesQuantityAndUnitPrice {
                try SnapshotService.upsertEntry(
                    snapshot: snapshot,
                    item: item,
                    quantity: try validatedNumber(from: quantityText, fieldName: AppLocalization.string("数量")),
                    unitPrice: try validatedNumber(from: unitPriceText, fieldName: AppLocalization.string("单价")),
                    in: modelContext
                )
            } else {
                let amount = try validatedNumber(
                    from: amountText,
                    forcePositive: isLiability,
                    fieldName: AppLocalization.string(isLiability ? "负债数额" : "资产数额")
                )
                try SnapshotService.upsertEntry(snapshot: snapshot, item: item, amount: amount, in: modelContext)
            }
            dismiss()
        } catch let error as QuickRecordValueValidationError {
            errorMessage = error.message
        } catch {
            errorMessage = AppLocalization.string("保存失败，请稍后再试")
            print("[AssetTimeMachine] update historical entry failed: \(error)")
        }
    }

    private func validatedNumber(from text: String, forcePositive: Bool = false, fieldName: String) throws -> Double? {
        let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let value = Double(raw) else {
            throw QuickRecordValueValidationError(message: AppLocalization.format("%@请输入有效数字", fieldName))
        }
        return forcePositive ? abs(value) : value
    }
}

private struct TimeMachineView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var marketStore: RemoteMarketStore
    let isActive: Bool
    @Query(sort: \AssetSnapshot.date, order: .forward) private var snapshots: [AssetSnapshot]
    @State private var selectedRange: TimeMachineRange = .sixMonths
    @State private var cachedTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedFilteredTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedMonthlySurplusPoints: [TimeMachineMonthlySurplusPoint] = []
    @State private var cachedAnnualSurplusPoints: [TimeMachineAnnualSurplusPoint] = []
    @State private var cachedHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]] = [:]
    @State private var cachedFullHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]] = [:]
    @State private var cachedDetailTrendCards: [TimeMachineCombinedTrendDescriptor] = []
    @State private var lastFullHistoryPointsCacheToken: Int?
    @State private var lastVisualizationCacheToken: Int?
    @State private var lastDetailTrendCardsCacheToken: Int?
    @State private var deferredDetailCardsTask: Task<Void, Never>?
    @State private var pendingVisualizationRefreshTask: Task<Void, Never>?
    @State private var selectedHistoryDrilldown: TimeMachineHistoryDrilldown?

    private var trendPoints: [TimeMachineTrendPoint] {
        cachedTrendPoints
    }

    private var filteredTrendPoints: [TimeMachineTrendPoint] {
        cachedFilteredTrendPoints
    }

    private var latestPoint: TimeMachineTrendPoint? {
        cachedFilteredTrendPoints.last ?? cachedTrendPoints.last
    }

    private var monthlySurplusPoints: [TimeMachineMonthlySurplusPoint] {
        cachedMonthlySurplusPoints
    }

    private var annualSurplusPoints: [TimeMachineAnnualSurplusPoint] {
        cachedAnnualSurplusPoints
    }

    private var liveUSDPerCNY: Double? {
        marketStore.exchangeRate(for: "USD")
    }

    private var liveGoldAnchorPrice: Double? {
        marketStore.market(for: "gold")?.price
    }

    private var liveBTCAnchorPriceUSD: Double? {
        marketStore.market(for: "btc")?.price
    }

    private var liveBTCAnchorPriceCNY: Double? {
        guard let liveBTCAnchorPriceUSD,
              let liveUSDPerCNY,
              liveUSDPerCNY > 0 else {
            return nil
        }
        return liveBTCAnchorPriceUSD / liveUSDPerCNY
    }

    private var liveNasdaqAnchorPriceUSD: Double? {
        marketStore.market(for: "nasdaq")?.price
    }

    private var liveNasdaqAnchorPriceCNY: Double? {
        guard let liveNasdaqAnchorPriceUSD,
              let liveUSDPerCNY,
              liveUSDPerCNY > 0 else {
            return nil
        }
        return liveNasdaqAnchorPriceUSD / liveUSDPerCNY
    }

    private var detailTrendCards: [TimeMachineCombinedTrendDescriptor] {
        cachedDetailTrendCards
    }

    private static let publicIndexConfigs: [(symbol: String, title: String, color: Color)] = [
        ("sp500", AppLocalization.string("标普500"), AssetTheme.goldSoft),
        ("dowjones", AppLocalization.string("道指"), AssetTheme.accentOrange),
        ("hsi", AppLocalization.string("恒生"), AssetTheme.accentBlue),
        ("nikkei", AppLocalization.string("日经225"), AssetTheme.positive),
        ("csi300", AppLocalization.string("沪深300"), AssetTheme.textPrimary),
        ("shanghai_composite", AppLocalization.string("上证综指"), AssetTheme.textSecondary)
    ]

    private func historySeriesPoints(_ series: PublicHistorySeries, range: TimeMachineRange? = nil) -> [TimeMachineSingleAxisPoint] {
        let points: [TimeMachineSingleAxisPoint] = Array(zip(series.dates, series.prices)).compactMap { (dateText: String, price: Double) -> TimeMachineSingleAxisPoint? in
            guard let date = historicalSeriesDate(from: dateText), price.isFinite, price > 0 else { return nil }
            return TimeMachineSingleAxisPoint(date: date, value: price)
        }
        let sortedPoints = points.sorted { $0.date < $1.date }
        guard let range else { return sortedPoints }
        return range.filter(sortedPoints)
    }

    private func historySeriesCandlesticks(_ series: PublicHistorySeries, range: TimeMachineRange? = nil) -> [TimeMachineCandlestickPoint] {
        let candlesticks = series.dailyBars.compactMap { bar -> TimeMachineCandlestickPoint? in
            guard
                bar.open.isFinite,
                bar.high.isFinite,
                bar.low.isFinite,
                bar.close.isFinite,
                bar.open > 0,
                bar.high >= max(bar.open, bar.close, bar.low),
                bar.low <= min(bar.open, bar.close, bar.high)
            else { return nil }

            return TimeMachineCandlestickPoint(
                date: bar.date,
                open: bar.open,
                high: bar.high,
                low: bar.low,
                close: bar.close,
                volume: bar.volume
            )
        }
        .sorted { $0.date < $1.date }

        guard let range else { return candlesticks }
        return range.filter(candlesticks)
    }

    private func historicalSeriesDate(from text: String) -> Date? {
        Self.historicalSeriesDateFormatter.date(from: text)
    }

    private static let historicalSeriesDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func liveGoldAnchorPriceIfToday(for snapshot: AssetSnapshot) -> Double? {
        Calendar.current.isDateInToday(snapshot.date) ? liveGoldAnchorPrice : nil
    }

    private func liveBTCAnchorPriceUSDIfToday(for snapshot: AssetSnapshot) -> Double? {
        Calendar.current.isDateInToday(snapshot.date) ? liveBTCAnchorPriceUSD : nil
    }

    private func liveBTCAnchorPriceCNYIfToday(for snapshot: AssetSnapshot) -> Double? {
        Calendar.current.isDateInToday(snapshot.date) ? liveBTCAnchorPriceCNY : nil
    }

    private func liveNasdaqAnchorPriceUSDIfToday(for snapshot: AssetSnapshot) -> Double? {
        Calendar.current.isDateInToday(snapshot.date) ? liveNasdaqAnchorPriceUSD : nil
    }

    private func liveNasdaqAnchorPriceCNYIfToday(for snapshot: AssetSnapshot) -> Double? {
        Calendar.current.isDateInToday(snapshot.date) ? liveNasdaqAnchorPriceCNY : nil
    }

    private func liveAnchorDateIfToday(for snapshot: AssetSnapshot, hasValue: Bool) -> Date? {
        hasValue && Calendar.current.isDateInToday(snapshot.date) ? snapshot.date : nil
    }

    private var snapshotCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(snapshots.count)

        for snapshot in snapshots {
            hasher.combine(snapshot.id)
            hasher.combine(snapshot.date.timeIntervalSinceReferenceDate)
            hasher.combine(snapshot.updatedAt.timeIntervalSinceReferenceDate)
            hasher.combine(snapshot.goldAnchorPriceCNY)
            hasher.combine(snapshot.goldAnchorPriceDate?.timeIntervalSinceReferenceDate)
            hasher.combine(snapshot.btcAnchorPriceUSD)
            hasher.combine(snapshot.btcAnchorPriceDate?.timeIntervalSinceReferenceDate)
            hasher.combine(snapshot.nasdaqAnchorPriceUSD)
            hasher.combine(snapshot.nasdaqAnchorPriceDate?.timeIntervalSinceReferenceDate)
            hasher.combine(snapshot.usdPerCNY)
            hasher.combine(snapshot.usdPerCNYDate?.timeIntervalSinceReferenceDate)
            hasher.combine(snapshot.marketAnchorsUpdatedAt?.timeIntervalSinceReferenceDate)
            hasher.combine(snapshot.entries.count)
        }

        return hasher.finalize()
    }

    private var historyCacheToken: Int {
        var hasher = Hasher()
        let symbols = marketStore.historySeries.keys.sorted()
        hasher.combine(symbols.count)

        for symbol in symbols {
            guard let series = marketStore.historySeries[symbol] else { continue }
            hasher.combine(symbol)
            hasher.combine(series.dates.count)
            hasher.combine(series.dates.last)
            hasher.combine(series.prices.last)
            hasher.combine(series.currency)
            hasher.combine(series.hasOHLC)
            hasher.combine(series.ohlcSource)
            hasher.combine(series.ohlcCoverageRatio)
            hasher.combine(series.openPrices?.count ?? 0)
            hasher.combine(series.openPrices?.last ?? nil)
            hasher.combine(series.highPrices?.last ?? nil)
            hasher.combine(series.lowPrices?.last ?? nil)
            hasher.combine(series.closePrices?.last ?? nil)
        }

        return hasher.finalize()
    }

    private var overviewCacheToken: Int {
        var hasher = Hasher()
        let markets = (marketStore.overview?.markets ?? []).sorted { $0.symbol < $1.symbol }
        hasher.combine(markets.count)

        for market in markets {
            hasher.combine(market.symbol)
            hasher.combine(market.price)
            hasher.combine(market.currency)
            hasher.combine(market.fetchedAt.timeIntervalSinceReferenceDate)
        }

        return hasher.finalize()
    }

    private var exchangeRateCacheToken: Int {
        var hasher = Hasher()
        let rates = marketStore.exchangeRates.sorted { $0.key < $1.key }
        hasher.combine(rates.count)

        for (currency, rate) in rates {
            hasher.combine(currency)
            hasher.combine(rate)
        }

        return hasher.finalize()
    }

    private var visualizationCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(selectedRange.rawValue)
        hasher.combine(snapshotCacheToken)
        hasher.combine(historyCacheToken)
        hasher.combine(overviewCacheToken)
        hasher.combine(exchangeRateCacheToken)
        return hasher.finalize()
    }

    @MainActor
    private func scheduleVisualizationRefresh(
        force: Bool = false,
        includeDetailCards: Bool = true,
        delayNanoseconds: UInt64 = 60_000_000
    ) {
        pendingVisualizationRefreshTask?.cancel()
        pendingVisualizationRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isActive else { return }
                refreshVisualizationCacheIfNeeded(force: force, includeDetailCards: includeDetailCards)
            }
        }
    }

    @MainActor
    private func refreshVisualizationCacheIfNeeded(force: Bool = false, includeDetailCards: Bool = true) {
        let token = visualizationCacheToken
        if !force, token == lastVisualizationCacheToken {
            if includeDetailCards {
                refreshDetailTrendCardsIfNeeded()
            } else if cachedDetailTrendCards.isEmpty {
                scheduleDeferredDetailCardsRefresh(for: token)
            }
            return
        }
        refreshVisualizationCache(includeDetailCards: includeDetailCards)
        lastVisualizationCacheToken = token
    }

    @MainActor
    private func refreshVisualizationCache(includeDetailCards: Bool = true) {
        let trendPoints = snapshots.map { snapshot in
            let mainAssets = PortfolioCalculator.totalAssets(for: snapshot)
            let liabilities = PortfolioCalculator.totalLiabilities(for: snapshot)
            let netAssets = mainAssets - liabilities

            let goldAnchorPrice = snapshot.goldAnchorPriceCNY ?? liveGoldAnchorPriceIfToday(for: snapshot)
            let btcAnchorPriceCNY = snapshot.btcAnchorPriceCNY ?? liveBTCAnchorPriceCNYIfToday(for: snapshot)
            let nasdaqAnchorPriceCNY = snapshot.nasdaqAnchorPriceCNY ?? liveNasdaqAnchorPriceCNYIfToday(for: snapshot)
            let btcAnchorPriceUSD = snapshot.btcAnchorPriceUSD ?? liveBTCAnchorPriceUSDIfToday(for: snapshot)
            let nasdaqAnchorPriceUSD = snapshot.nasdaqAnchorPriceUSD ?? liveNasdaqAnchorPriceUSDIfToday(for: snapshot)

            return TimeMachineTrendPoint(
                date: snapshot.date,
                mainAssets: mainAssets,
                netAssets: netAssets,
                liabilities: liabilities,
                goldEquivalent: goldAnchorPrice.map { $0 > 0 ? mainAssets / $0 : nil } ?? nil,
                btcEquivalent: btcAnchorPriceCNY.map { $0 > 0 ? mainAssets / $0 : nil } ?? nil,
                nasdaqEquivalent: nasdaqAnchorPriceCNY.map { $0 > 0 ? mainAssets / $0 : nil } ?? nil,
                goldAnchorPriceCNY: goldAnchorPrice,
                goldAnchorDate: snapshot.goldAnchorPriceDate ?? liveAnchorDateIfToday(for: snapshot, hasValue: goldAnchorPrice != nil),
                btcAnchorPriceUSD: btcAnchorPriceUSD,
                btcAnchorPriceCNY: btcAnchorPriceCNY,
                btcAnchorDate: snapshot.btcAnchorPriceDate ?? liveAnchorDateIfToday(for: snapshot, hasValue: btcAnchorPriceUSD != nil),
                nasdaqAnchorPriceUSD: nasdaqAnchorPriceUSD,
                nasdaqAnchorPriceCNY: nasdaqAnchorPriceCNY,
                nasdaqAnchorDate: snapshot.nasdaqAnchorPriceDate ?? liveAnchorDateIfToday(for: snapshot, hasValue: nasdaqAnchorPriceUSD != nil)
            )
        }

        let filteredTrendPoints = selectedRange.filter(trendPoints)

        cachedTrendPoints = trendPoints
        cachedFilteredTrendPoints = filteredTrendPoints
        cachedMonthlySurplusPoints = buildMonthlySurplusPoints(from: trendPoints)
        cachedAnnualSurplusPoints = buildAnnualSurplusPoints(from: trendPoints)

        guard !filteredTrendPoints.isEmpty else {
            cachedHistoryPointsBySymbol = [:]
            cachedDetailTrendCards = []
            lastDetailTrendCardsCacheToken = nil
            deferredDetailCardsTask?.cancel()
            return
        }

        let fullHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]]
        if historyCacheToken == lastFullHistoryPointsCacheToken {
            fullHistoryPointsBySymbol = cachedFullHistoryPointsBySymbol
        } else {
            fullHistoryPointsBySymbol = buildFullHistoryPointsBySymbol()
            cachedFullHistoryPointsBySymbol = fullHistoryPointsBySymbol
            lastFullHistoryPointsCacheToken = historyCacheToken
        }
        let historyPointsBySymbol = buildHistoryPointsBySymbol(
            fullHistoryPointsBySymbol: fullHistoryPointsBySymbol,
            trendPoints: filteredTrendPoints
        )

        cachedHistoryPointsBySymbol = historyPointsBySymbol

        if includeDetailCards {
            refreshDetailTrendCards(for: visualizationCacheToken)
        } else {
            cachedDetailTrendCards = []
            lastDetailTrendCardsCacheToken = nil
            scheduleDeferredDetailCardsRefresh(for: visualizationCacheToken)
        }
    }

    @MainActor
    private func refreshDetailTrendCardsIfNeeded(force: Bool = false) {
        let token = visualizationCacheToken
        guard force || token != lastDetailTrendCardsCacheToken else { return }
        if token != lastVisualizationCacheToken {
            refreshVisualizationCache(includeDetailCards: true)
            lastVisualizationCacheToken = token
        } else {
            refreshDetailTrendCards(for: token)
        }
    }

    @MainActor
    private func refreshDetailTrendCards(for token: Int) {
        cachedDetailTrendCards = buildDetailTrendCards(
            filteredTrendPoints: cachedFilteredTrendPoints,
            latestPoint: cachedFilteredTrendPoints.last ?? cachedTrendPoints.last,
            historyPointsBySymbol: cachedHistoryPointsBySymbol,
            fullHistoryPointsBySymbol: cachedFullHistoryPointsBySymbol
        )
        lastDetailTrendCardsCacheToken = token
    }

    @MainActor
    private func scheduleDeferredDetailCardsRefresh(for token: Int) {
        deferredDetailCardsTask?.cancel()
        deferredDetailCardsTask = Task {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isActive, token == visualizationCacheToken else { return }
                refreshDetailTrendCardsIfNeeded()
            }
        }
    }

    private func buildFullHistoryPointsBySymbol() -> [String: [TimeMachineSingleAxisPoint]] {
        let symbols = ["gold_cny", "nasdaq"] + Self.publicIndexConfigs.map(\.symbol)
        return Dictionary(uniqueKeysWithValues: symbols.compactMap { symbol in
            guard let series = marketStore.history(for: symbol) else { return nil }
            let points = historySeriesPoints(series)
            guard !points.isEmpty else { return nil }
            return (symbol, points)
        })
    }

    private func buildHistoryPointsBySymbol(
        fullHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]],
        trendPoints: [TimeMachineTrendPoint]
    ) -> [String: [TimeMachineSingleAxisPoint]] {
        guard let firstDate = trendPoints.first?.date,
              let lastDate = trendPoints.last?.date else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: fullHistoryPointsBySymbol.compactMap { symbol, points in
            let clippedPoints = points.filter { $0.date >= firstDate && $0.date <= lastDate }
            guard !clippedPoints.isEmpty else { return nil }
            return (symbol, clippedPoints)
        })
    }

    private func buildMonthlySurplusPoints(
        from source: [TimeMachineTrendPoint],
        calendar: Calendar = .current
    ) -> [TimeMachineMonthlySurplusPoint] {
        guard !source.isEmpty else { return [] }

        let grouped = Dictionary(grouping: source) { point in
            calendar.dateInterval(of: .month, for: point.date)?.start ?? calendar.startOfDay(for: point.date)
        }

        let sortedMonthStarts = grouped.keys.sorted()
        var points: [TimeMachineMonthlySurplusPoint] = []
        points.reserveCapacity(sortedMonthStarts.count)
        var previousMonthEndNetAssets: Double?

        for monthStart in sortedMonthStarts {
            guard let monthPoints = grouped[monthStart]?.sorted(by: { $0.date < $1.date }),
                  let firstPoint = monthPoints.first,
                  let lastPoint = monthPoints.last else {
                continue
            }

            let baseline = previousMonthEndNetAssets ?? firstPoint.netAssets
            let surplus = lastPoint.netAssets - baseline
            points.append(
                TimeMachineMonthlySurplusPoint(
                    monthStart: monthStart,
                    date: lastPoint.date,
                    surplus: surplus,
                    monthEndNetAssets: lastPoint.netAssets
                )
            )
            previousMonthEndNetAssets = lastPoint.netAssets
        }

        return filterMonthlySurplusPoints(points, calendar: calendar)
    }

    private func filterMonthlySurplusPoints(
        _ points: [TimeMachineMonthlySurplusPoint],
        calendar: Calendar = .current
    ) -> [TimeMachineMonthlySurplusPoint] {
        guard let latestDate = points.last?.date else { return [] }

        let startDate: Date?
        switch selectedRange {
        case .halfMonth:
            startDate = calendar.date(byAdding: .day, value: -15, to: latestDate)
        case .oneMonth:
            startDate = calendar.date(byAdding: .month, value: -1, to: latestDate)
        case .sixMonths:
            startDate = calendar.date(byAdding: .month, value: -6, to: latestDate)
        case .oneYear:
            startDate = calendar.date(byAdding: .year, value: -1, to: latestDate)
        case .threeYears:
            startDate = calendar.date(byAdding: .year, value: -3, to: latestDate)
        case .all:
            startDate = nil
        }

        guard let startDate else { return points }
        let filteredPoints = points.filter { $0.date >= startDate }
        guard let monthlyBucketLimit = selectedRange.monthlyBucketLimit else { return filteredPoints }
        return Array(filteredPoints.suffix(monthlyBucketLimit))
    }

    private func buildAnnualSurplusPoints(
        from source: [TimeMachineTrendPoint],
        calendar: Calendar = .current
    ) -> [TimeMachineAnnualSurplusPoint] {
        guard !source.isEmpty else { return [] }

        let grouped = Dictionary(grouping: source) { point in
            calendar.dateInterval(of: .year, for: point.date)?.start ?? calendar.startOfDay(for: point.date)
        }

        let sortedYearStarts = grouped.keys.sorted()
        var points: [TimeMachineAnnualSurplusPoint] = []
        points.reserveCapacity(sortedYearStarts.count)
        var previousYearEndNetAssets: Double?

        for yearStart in sortedYearStarts {
            guard let yearPoints = grouped[yearStart]?.sorted(by: { $0.date < $1.date }),
                  let firstPoint = yearPoints.first,
                  let lastPoint = yearPoints.last else {
                continue
            }

            let baseline = previousYearEndNetAssets ?? firstPoint.netAssets
            let surplus = lastPoint.netAssets - baseline
            points.append(
                TimeMachineAnnualSurplusPoint(
                    yearStart: yearStart,
                    date: lastPoint.date,
                    surplus: surplus,
                    yearEndNetAssets: lastPoint.netAssets,
                    isCurrentYear: calendar.isDate(lastPoint.date, equalTo: .now, toGranularity: .year)
                )
            )
            previousYearEndNetAssets = lastPoint.netAssets
        }

        return points
    }

    private func buildDetailTrendCards(
        filteredTrendPoints: [TimeMachineTrendPoint],
        latestPoint: TimeMachineTrendPoint?,
        historyPointsBySymbol: [String: [TimeMachineSingleAxisPoint]],
        fullHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]]
    ) -> [TimeMachineCombinedTrendDescriptor] {
        let goldLeftOnlyPoints = historyPointsBySymbol["gold_cny"] ?? singleAxisPoints(for: filteredTrendPoints, range: selectedRange, left: \.goldAnchorPriceCNY)
        let nasdaqLeftOnlyPoints = historyPointsBySymbol["nasdaq"] ?? singleAxisPoints(for: filteredTrendPoints, range: selectedRange, left: \.nasdaqAnchorPriceUSD)

        let primaryCards = [
            TimeMachineCombinedTrendDescriptor(
                title: AppLocalization.string("黄金"),
                subtitle: nil,
                leftTitle: AppLocalization.string("价格"),
                rightTitle: AppLocalization.string("折算"),
                points: pairedPoints(for: filteredTrendPoints, range: selectedRange, left: \.goldAnchorPriceCNY, right: \.goldEquivalent),
                leftOnlyPoints: goldLeftOnlyPoints,
                leftColor: AssetTheme.gold,
                rightColor: AssetTheme.positive,
                leftLatestLabel: goldLeftOnlyPoints.last.map { "\($0.value.currencyString())/g" } ?? "--",
                rightLatestLabel: latestPoint?.goldEquivalent.map { "\($0.plainNumberString()) g" } ?? "--",
                leftAxisStyle: .currency(code: "CNY"),
                rightAxisStyle: .quantity(unit: "g", maxFractionDigits: 2),
                showsComparisonLine: true,
                historyDrilldown: historyDrilldown(
                    symbol: "gold_cny",
                    title: AppLocalization.string("黄金"),
                    subtitle: AppLocalization.string("人民币计价"),
                    color: AssetTheme.gold,
                    axisStyle: .currency(code: "CNY", suffix: "/g"),
                    fullHistoryPointsBySymbol: fullHistoryPointsBySymbol
                )
            ),
            TimeMachineCombinedTrendDescriptor(
                title: AppLocalization.string("纳指"),
                subtitle: nil,
                leftTitle: AppLocalization.string("价格"),
                rightTitle: AppLocalization.string("折算"),
                points: pairedPoints(for: filteredTrendPoints, range: selectedRange, left: \.nasdaqAnchorPriceUSD, right: \.nasdaqEquivalent),
                leftOnlyPoints: nasdaqLeftOnlyPoints,
                leftColor: AssetTheme.accentBlue,
                rightColor: AssetTheme.positive,
                leftLatestLabel: nasdaqLeftOnlyPoints.last.map { $0.value.currencyString(code: "USD") } ?? "--",
                rightLatestLabel: latestPoint?.nasdaqEquivalent.map { AppLocalization.format("%@ 份", $0.plainNumberString()) } ?? "--",
                leftAxisStyle: .currency(code: "USD"),
                rightAxisStyle: .quantity(unit: AppLocalization.string("份"), maxFractionDigits: 2),
                showsComparisonLine: true,
                historyDrilldown: historyDrilldown(
                    symbol: "nasdaq",
                    title: AppLocalization.string("纳指"),
                    subtitle: AppLocalization.string("纳斯达克综合指数"),
                    color: AssetTheme.accentBlue,
                    axisStyle: .currency(code: "USD"),
                    fullHistoryPointsBySymbol: fullHistoryPointsBySymbol
                )
            )
        ]

        let publicIndexCards: [TimeMachineCombinedTrendDescriptor] = Self.publicIndexConfigs.compactMap { config -> TimeMachineCombinedTrendDescriptor? in
            guard let leftOnlyPoints = historyPointsBySymbol[config.symbol], leftOnlyPoints.count >= 2 else { return nil }
            let currency = marketStore.history(for: config.symbol)?.currency ?? "CNY"
            let comparisonPoints = pairedPublicIndexPoints(
                historyPoints: leftOnlyPoints,
                against: filteredTrendPoints,
                range: selectedRange,
                currency: currency
            )
            let displayedLeftPoints = comparisonPoints.isEmpty
                ? leftOnlyPoints
                : comparisonPoints.map { TimeMachineSingleAxisPoint(date: $0.date, value: $0.leftValue) }
            let latestLeftPoint = displayedLeftPoints.last
            let latestComparisonPoint = comparisonPoints.last
            return TimeMachineCombinedTrendDescriptor(
                title: config.title,
                subtitle: currency == "CNY" ? AppLocalization.string("按当前总资产折算") : AppLocalization.string("按当前总资产、当前汇率估算"),
                leftTitle: AppLocalization.string("指数现价"),
                rightTitle: AppLocalization.string("资产折算"),
                points: comparisonPoints,
                leftOnlyPoints: displayedLeftPoints,
                leftColor: config.color,
                rightColor: AssetTheme.positive,
                leftLatestLabel: latestLeftPoint.map { $0.value.currencyString(code: currency) } ?? "--",
                rightLatestLabel: latestComparisonPoint.map { AppLocalization.format("%@ 份", $0.rightValue.plainNumberString()) } ?? "--",
                leftAxisStyle: .currency(code: currency),
                rightAxisStyle: .quantity(unit: AppLocalization.string("份"), maxFractionDigits: 2),
                showsComparisonLine: comparisonPoints.count >= 2,
                historyDrilldown: historyDrilldown(
                    symbol: config.symbol,
                    title: config.title,
                    subtitle: nil,
                    color: config.color,
                    axisStyle: .currency(code: currency),
                    fullHistoryPointsBySymbol: fullHistoryPointsBySymbol
                )
            )
        }

        return primaryCards + publicIndexCards
    }

    private func historyDrilldown(
        symbol: String,
        title: String,
        subtitle: String?,
        color: Color,
        axisStyle: TimeMachineAxisValueStyle,
        fullHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]]
    ) -> TimeMachineHistoryDrilldown? {
        guard let points = fullHistoryPointsBySymbol[symbol], points.count >= 2 else { return nil }
        let candlesticks = marketStore.history(for: symbol).map { historySeriesCandlesticks($0) } ?? []
        return TimeMachineHistoryDrilldown(
            symbol: symbol,
            title: title,
            subtitle: subtitle,
            points: points,
            candlesticks: candlesticks,
            color: color,
            axisStyle: axisStyle
        )
    }

    private func pairedPoints(
        for source: [TimeMachineTrendPoint],
        range: TimeMachineRange,
        left leftKeyPath: KeyPath<TimeMachineTrendPoint, Double?>,
        right rightKeyPath: KeyPath<TimeMachineTrendPoint, Double?>
    ) -> [TimeMachineDualAxisPoint] {
        let cleanedPoints = source.compactMap { point -> TimeMachineDualAxisPoint? in
            guard let leftValue = point[keyPath: leftKeyPath],
                  let rightValue = point[keyPath: rightKeyPath],
                  leftValue.isFinite,
                  rightValue.isFinite,
                  leftValue > 0,
                  rightValue > 0 else {
                return nil
            }
            return TimeMachineDualAxisPoint(date: point.date, leftValue: leftValue, rightValue: rightValue)
        }

        return range.aggregateDetailChartPoints(cleanedPoints)
    }

    private func pairedPublicIndexPoints(
        historyPoints: [TimeMachineSingleAxisPoint],
        against trendPoints: [TimeMachineTrendPoint],
        range: TimeMachineRange,
        currency: String
    ) -> [TimeMachineDualAxisPoint] {
        guard !historyPoints.isEmpty, !trendPoints.isEmpty else { return [] }

        var cleanedPoints: [TimeMachineDualAxisPoint] = []
        cleanedPoints.reserveCapacity(historyPoints.count)

        var nearestTrendIndex = 0

        for point in historyPoints {
            while nearestTrendIndex + 1 < trendPoints.count {
                let currentDistance = abs(trendPoints[nearestTrendIndex].date.timeIntervalSince(point.date))
                let nextDistance = abs(trendPoints[nearestTrendIndex + 1].date.timeIntervalSince(point.date))
                guard nextDistance <= currentDistance else { break }
                nearestTrendIndex += 1
            }

            guard let priceInCNY = convertedPriceToCNY(point.value, currency: currency),
                  priceInCNY.isFinite,
                  priceInCNY > 0 else {
                continue
            }

            let equivalent = trendPoints[nearestTrendIndex].mainAssets / priceInCNY
            guard equivalent.isFinite, equivalent > 0 else { continue }

            cleanedPoints.append(
                TimeMachineDualAxisPoint(
                    date: point.date,
                    leftValue: point.value,
                    rightValue: equivalent
                )
            )
        }

        return range.aggregateDetailChartPoints(cleanedPoints)
    }

    private func convertedPriceToCNY(_ price: Double, currency: String) -> Double? {
        guard price.isFinite, price > 0 else { return nil }
        let code = currency.uppercased()
        guard code != "CNY" else { return price }
        guard let rate = marketStore.exchangeRate(for: code), rate.isFinite, rate > 0 else { return nil }
        return price / rate
    }

    private func singleAxisPoints(
        for source: [TimeMachineTrendPoint],
        range: TimeMachineRange,
        left leftKeyPath: KeyPath<TimeMachineTrendPoint, Double?>
    ) -> [TimeMachineSingleAxisPoint] {
        let cleanedPoints = source.compactMap { point -> TimeMachineSingleAxisPoint? in
            guard let value = point[keyPath: leftKeyPath], value.isFinite, value > 0 else {
                return nil
            }
            return TimeMachineSingleAxisPoint(date: point.date, value: value)
        }

        let aggregated = range.aggregateDetailChartPoints(cleanedPoints.map {
            TimeMachineDualAxisPoint(date: $0.date, leftValue: $0.value, rightValue: $0.value)
        })

        return aggregated.map { TimeMachineSingleAxisPoint(date: $0.date, value: $0.leftValue) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        if lastVisualizationCacheToken == nil {
                            LoadingStateCard(
                                title: AppLocalization.string("时光机加载中"),
                                message: AppLocalization.string("正在整理历史趋势和对照数据…")
                            )
                        } else if let latestPoint, !filteredTrendPoints.isEmpty {
                            TimeMachineHeroTrendCard(
                                points: filteredTrendPoints,
                                latestPoint: latestPoint,
                                selectedRange: $selectedRange
                            )

                            if !monthlySurplusPoints.isEmpty || !annualSurplusPoints.isEmpty {
                                TimeMachineMonthlySurplusCard(
                                    points: monthlySurplusPoints,
                                    annualPoints: annualSurplusPoints
                                )
                            }

                            LazyVStack(spacing: 12) {
                                ForEach(detailTrendCards) { card in
                                    TimeMachineDualAxisTrendCard(descriptor: card) { history in
                                        selectedHistoryDrilldown = history
                                    }
                                }
                            }
                            .onboardingAnchor(.timeMachineAnchors)
                        } else {
                            EmptyStateCard(
                                title: AppLocalization.string("暂无趋势数据"),
                                message: AppLocalization.string("请先在记录页保存历史资产快照。"),
                                systemImage: "chart.line.uptrend.xyaxis"
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 136)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $selectedHistoryDrilldown) { descriptor in
            TimeMachineHistoryDrilldownSheet(descriptor: descriptor)
        }
        .task(id: isActive) {
            if isActive {
                await marketStore.refreshHistoryIfNeeded()
                guard !Task.isCancelled else { return }
                await SnapshotAnchorService.backfillIfNeeded(in: modelContext)
                guard !Task.isCancelled else { return }
                scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 90_000_000)
            } else {
                pendingVisualizationRefreshTask?.cancel()
                deferredDetailCardsTask?.cancel()
            }
        }
        .onChange(of: selectedRange) { _, _ in
            guard isActive else { return }
            scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 0)
        }
        .onChange(of: snapshotCacheToken) { _, _ in
            guard isActive else { return }
            scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 40_000_000)
        }
        .onReceive(marketStore.$historySeries) { _ in
            guard isActive else { return }
            scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 40_000_000)
        }
        .onReceive(marketStore.$overview) { _ in
            guard isActive else { return }
            scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 40_000_000)
        }
        .onReceive(marketStore.$exchangeRates) { _ in
            guard isActive else { return }
            scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 40_000_000)
        }
    }
}

private nonisolated struct BacktestSeriesPoint: Identifiable {
    let id: Int
    let date: Date
    let portfolioValue: Double

    init(date: Date, portfolioValue: Double, sequence: Int = 0) {
        self.id = sequence
        self.date = date
        self.portfolioValue = portfolioValue
    }
}

private enum BacktestMode: String, CaseIterable, Identifiable {
    case allocation
    case dca

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allocation:
            return AppLocalization.string("配置回测")
        case .dca:
            return AppLocalization.string("定投回测")
        }
    }
}

private enum BacktestPage: String, CaseIterable, Identifiable {
    case standard
    case advanced
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            return AppLocalization.string("基础回测")
        case .advanced:
            return AppLocalization.string("高级回测")
        case .history:
            return AppLocalization.string("回测记录")
        }
    }
}

private enum BacktestTopTab: String, CaseIterable, Identifiable {
    case allocation
    case dca
    case advanced
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allocation:
            return AppLocalization.string("配置")
        case .dca:
            return AppLocalization.string("定投")
        case .advanced:
            return AppLocalization.string("高级")
        case .history:
            return AppLocalization.string("记录")
        }
    }
}

private enum AdvancedBacktestSignalDirection: String, CaseIterable, Identifiable {
    case alwaysBuy
    case neverSell
    case consecutiveDown
    case consecutiveUp
    case priceAboveMA20
    case priceBelowMA20
    case priceAboveMA60
    case priceBelowMA60
    case priceCrossesAboveMA20
    case priceCrossesBelowMA20
    case ma20CrossesAboveMA60
    case ma20CrossesBelowMA60
    case priceCrossesAboveBollMiddle
    case priceCrossesBelowBollMiddle
    case touchesBollLower
    case touchesBollUpper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysBuy:
            return AppLocalization.string("持续买入")
        case .neverSell:
            return AppLocalization.string("不主动卖出")
        case .consecutiveDown:
            return AppLocalization.string("连续下跌")
        case .consecutiveUp:
            return AppLocalization.string("连续上涨")
        case .priceAboveMA20:
            return AppLocalization.string("价格高于 MA20")
        case .priceBelowMA20:
            return AppLocalization.string("价格低于 MA20")
        case .priceAboveMA60:
            return AppLocalization.string("价格高于 MA60")
        case .priceBelowMA60:
            return AppLocalization.string("价格低于 MA60")
        case .priceCrossesAboveMA20:
            return AppLocalization.string("价格上穿 MA20")
        case .priceCrossesBelowMA20:
            return AppLocalization.string("价格下穿 MA20")
        case .ma20CrossesAboveMA60:
            return AppLocalization.string("MA20 上穿 MA60")
        case .ma20CrossesBelowMA60:
            return AppLocalization.string("MA20 下穿 MA60")
        case .priceCrossesAboveBollMiddle:
            return AppLocalization.string("价格上穿 BOLL 中轨")
        case .priceCrossesBelowBollMiddle:
            return AppLocalization.string("价格下穿 BOLL 中轨")
        case .touchesBollLower:
            return AppLocalization.string("跌破/触及 BOLL 下轨")
        case .touchesBollUpper:
            return AppLocalization.string("突破/触及 BOLL 上轨")
        }
    }

    var shortTitle: String {
        switch self {
        case .alwaysBuy:
            return AppLocalization.string("持续买")
        case .neverSell:
            return AppLocalization.string("持有")
        case .consecutiveDown:
            return AppLocalization.string("跌")
        case .consecutiveUp:
            return AppLocalization.string("涨")
        case .priceAboveMA20:
            return AppLocalization.string("高于MA20")
        case .priceBelowMA20:
            return AppLocalization.string("低于MA20")
        case .priceAboveMA60:
            return AppLocalization.string("高于MA60")
        case .priceBelowMA60:
            return AppLocalization.string("低于MA60")
        case .priceCrossesAboveMA20:
            return AppLocalization.string("价上穿MA20")
        case .priceCrossesBelowMA20:
            return AppLocalization.string("价下穿MA20")
        case .ma20CrossesAboveMA60:
            return AppLocalization.string("MA金叉")
        case .ma20CrossesBelowMA60:
            return AppLocalization.string("MA死叉")
        case .priceCrossesAboveBollMiddle:
            return AppLocalization.string("上穿BOLL中轨")
        case .priceCrossesBelowBollMiddle:
            return AppLocalization.string("下穿BOLL中轨")
        case .touchesBollLower:
            return AppLocalization.string("BOLL下轨")
        case .touchesBollUpper:
            return AppLocalization.string("BOLL上轨")
        }
    }

    nonisolated var usesDayThreshold: Bool {
        switch self {
        case .consecutiveDown, .consecutiveUp:
            return true
        case .alwaysBuy,
             .neverSell,
             .priceAboveMA20,
             .priceBelowMA20,
             .priceAboveMA60,
             .priceBelowMA60,
             .priceCrossesAboveMA20,
             .priceCrossesBelowMA20,
             .ma20CrossesAboveMA60,
             .ma20CrossesBelowMA60,
             .priceCrossesAboveBollMiddle,
             .priceCrossesBelowBollMiddle,
             .touchesBollLower,
             .touchesBollUpper:
            return false
        }
    }

    nonisolated var isBuySignalOption: Bool {
        switch self {
        case .alwaysBuy,
             .consecutiveDown,
             .priceAboveMA20,
             .priceAboveMA60,
             .priceCrossesAboveMA20,
             .ma20CrossesAboveMA60,
             .priceCrossesAboveBollMiddle,
             .touchesBollLower:
            return true
        case .neverSell,
             .consecutiveUp,
             .priceBelowMA20,
             .priceBelowMA60,
             .priceCrossesBelowMA20,
             .ma20CrossesBelowMA60,
             .priceCrossesBelowBollMiddle,
             .touchesBollUpper:
            return false
        }
    }

    nonisolated var isSellSignalOption: Bool {
        switch self {
        case .neverSell,
             .consecutiveUp,
             .priceBelowMA20,
             .priceBelowMA60,
             .priceCrossesBelowMA20,
             .ma20CrossesBelowMA60,
             .priceCrossesBelowBollMiddle,
             .touchesBollUpper:
            return true
        case .alwaysBuy,
             .consecutiveDown,
             .priceAboveMA20,
             .priceAboveMA60,
             .priceCrossesAboveMA20,
             .ma20CrossesAboveMA60,
             .priceCrossesAboveBollMiddle,
             .touchesBollLower:
            return false
        }
    }
}

private enum AdvancedBacktestTradeAction: String {
    case buy
    case sell

    var title: String {
        switch self {
        case .buy:
            return AppLocalization.string("买入")
        case .sell:
            return AppLocalization.string("卖出")
        }
    }

    var accent: Color {
        switch self {
        case .buy:
            return AssetTheme.accentRed
        case .sell:
            return AssetTheme.accentBlue
        }
    }
}

private struct AdvancedBacktestRule {
    var direction: AdvancedBacktestSignalDirection
    var days: Int
}

private enum AdvancedBacktestStrategyMode: String, Codable {
    case ruleBased
    case ultraDefensiveRotation
    case defensiveRotation
    case lowDrawdownRotation
    case balancedRotation
    case enhancedRotation
    case longTermDefensiveTrend
    case longTermEnhancedLowDrawdownTrend
    case steadyDrawdownLadderTrend
    case septemberGuardLadderTrend
    case longTermGrowthTrend
    case longTermLowVolMomentum
    case robustLowVolMomentum
    case overheatGuardMomentum
    case highZoneDecelerationMomentum
    case pairConfirmDoubleGuardMomentum
    case tailBreakdownLockMomentum
    case recentLossVolatilityMetaMomentum
    case coreGoldSatelliteConservativeMomentum
    case coreGoldSatelliteBalancedMomentum
    case coreGoldSatelliteFullMomentum
    case coreGoldSatelliteHeatCappedMomentum
    case coreGoldSatelliteAggressiveMomentum
    case canaryMomentumDefense
    case drawdownReentryMomentum
    case goldCoreTrendSatellite
    case goldNasdaqSteadyRotation
    case goldNasdaqPortfolioScheduler
    case strongVolControlledRotation
    case momentumRotation

    var title: String {
        switch self {
        case .ruleBased:
            return AppLocalization.string("自定义策略")
        case .ultraDefensiveRotation:
            return AppLocalization.string("极稳轮动")
        case .defensiveRotation:
            return AppLocalization.string("稳健轮动")
        case .lowDrawdownRotation:
            return AppLocalization.string("低回撤轮动")
        case .balancedRotation:
            return AppLocalization.string("均衡轮动")
        case .enhancedRotation:
            return AppLocalization.string("增强轮动")
        case .longTermDefensiveTrend:
            return AppLocalization.string("长期低回撤趋势")
        case .longTermEnhancedLowDrawdownTrend:
            return AppLocalization.string("长期增强低回撤趋势")
        case .steadyDrawdownLadderTrend:
            return AppLocalization.string("稳健回撤阶梯趋势")
        case .septemberGuardLadderTrend:
            return AppLocalization.string("九月风险闸门趋势")
        case .longTermGrowthTrend:
            return AppLocalization.string("长期进取趋势")
        case .longTermLowVolMomentum:
            return AppLocalization.string("长期低波动动量")
        case .robustLowVolMomentum:
            return AppLocalization.string("稳健低波动动量")
        case .overheatGuardMomentum:
            return AppLocalization.string("A股过热不追高动量")
        case .highZoneDecelerationMomentum:
            return AppLocalization.string("高位短弱双守门动量")
        case .pairConfirmDoubleGuardMomentum:
            return AppLocalization.string("配对确认双守门动量")
        case .tailBreakdownLockMomentum:
            return AppLocalization.string("持有中破位锁盈防守")
        case .recentLossVolatilityMetaMomentum:
            return AppLocalization.string("近期亏损波动元策略")
        case .coreGoldSatelliteConservativeMomentum:
            return AppLocalization.string("核心动量+黄金卫星（保守）")
        case .coreGoldSatelliteBalancedMomentum:
            return AppLocalization.string("核心动量+黄金卫星（平衡）")
        case .coreGoldSatelliteFullMomentum:
            return AppLocalization.string("核心动量+黄金卫星（满核心）")
        case .coreGoldSatelliteHeatCappedMomentum:
            return AppLocalization.string("热度上限元策略")
        case .coreGoldSatelliteAggressiveMomentum:
            return AppLocalization.string("核心动量+黄金卫星（进攻）")
        case .canaryMomentumDefense:
            return AppLocalization.string("双金丝雀动量防守")
        case .drawdownReentryMomentum:
            return AppLocalization.string("回撤再入场动量")
        case .goldCoreTrendSatellite:
            return AppLocalization.string("核心黄金趋势卫星")
        case .goldNasdaqSteadyRotation:
            return AppLocalization.string("金纳低回撤轮动")
        case .goldNasdaqPortfolioScheduler:
            return AppLocalization.string("金纳组合调度")
        case .strongVolControlledRotation:
            return AppLocalization.string("强势控波轮动")
        case .momentumRotation:
            return AppLocalization.string("强势轮动")
        }
    }

    var detail: String {
        switch self {
        case .ruleBased:
            return AppLocalization.string("按买入/卖出条件独立回测每个资产")
        case .ultraDefensiveRotation:
            return AppLocalization.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动6%，最高投入35%")
        case .defensiveRotation:
            return AppLocalization.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动8%，最高投入55%")
        case .lowDrawdownRotation:
            return AppLocalization.string("40日强弱排序，每20个交易日在合格资产里分散持有，按动量/波动加权，目标波动10%，最多投入65%")
        case .balancedRotation:
            return AppLocalization.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动12%，最高投入75%")
        case .enhancedRotation:
            return AppLocalization.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动12%，最高投入90%")
        case .longTermDefensiveTrend:
            return AppLocalization.string("2001年以来优选：黄金65%、标普15.7%、纳指19.3%，需站上MA200且120日动量为正；每20个交易日再平衡，目标波动8.5%")
        case .longTermEnhancedLowDrawdownTrend:
            return AppLocalization.string("长期增强候选：黄金73%、标普1%、纳指26%，需站上MA220且120日动量为正；目标波动9.5%，纳指波动过热时自动降权益仓。")
        case .steadyDrawdownLadderTrend:
            return AppLocalization.string("更重视持有体验：黄金73%、标普1%、纳指26%，需站上MA220且120日动量为正；权益从180日高点回撤超过6%/12%时分级降仓，优先转向黄金或现金。")
        case .septemberGuardLadderTrend:
            return AppLocalization.string("在稳健回撤阶梯趋势上叠加九月风险闸门：9月仅保留25%权益仓，砍掉的权益优先转向趋势有效的黄金；目标是降低近期独立区间最大回撤。")
        case .longTermGrowthTrend:
            return AppLocalization.string("2001年以来进取候选：黄金50%、标普15%、纳指35%，需站上MA220且120日动量为正；每20个交易日再平衡，目标波动11%")
        case .longTermLowVolMomentum:
            return AppLocalization.string("非均线长期候选：黄金、纳指、标普、沪深300、上证综指中筛选240日动量为正且波动较低的资产；每60个交易日再平衡，目标波动10.5%")
        case .robustLowVolMomentum:
            return AppLocalization.string("新搜索候选：黄金、标普、纳指中筛选180日动量为正且30日年化波动低于18%的资产；按低波动分散，每40个交易日再平衡，目标波动7.5%，最高仓位55%")
        case .overheatGuardMomentum:
            return AppLocalization.string("收益优先候选：黄金、纳指、标普、沪深300、上证综指中只拿最强资产；当A股泡沫式加速时不追满仓，主仓降到保护仓位并优先让黄金承接。")
        case .highZoneDecelerationMomentum:
            return AppLocalization.string("突破候选：沿用最强资产动量框架，但新增双守门；高位动量钝化时先锁盈，若风险资产20日转弱且相对黄金明显落后，则把风险预算降到现金防守。")
        case .pairConfirmDoubleGuardMomentum:
            return AppLocalization.string("稳健增强候选：保留高位短弱双守门主体，但美股/A股持仓需要同组兄弟指数确认；若兄弟指数已明显走弱，先把总仓位压到60%，优先转向黄金或现金。")
        case .tailBreakdownLockMomentum:
            return AppLocalization.string("防守发动机：保留双守门动量主体，并在持有期间检查高位破位、短动量转弱和相对黄金落后；多项风险同时出现时先锁盈降仓。")
        case .recentLossVolatilityMetaMomentum:
            return AppLocalization.string("综合冠军候选：平时跟随高位短弱双守门动量；当该策略自身近期亏损和波动同时放大时，临时切到持有中破位锁盈防守发动机，恢复后再进攻。")
        case .coreGoldSatelliteConservativeMomentum:
            return AppLocalization.string("稳健增强候选：以近期亏损波动元策略为核心，只使用95%核心仓位；当黄金90日动量为正、站上120日均线且60日跑赢标普时，挂10%黄金卫星；2月权益走弱时压低权益仓位。")
        case .coreGoldSatelliteBalancedMomentum:
            return AppLocalization.string("推荐候选：以近期亏损波动元策略为核心，核心仓位提升到97.5%；黄金趋势和相对强度同时有效时挂10%黄金卫星，兼顾收益和9%左右回撤控制。")
        case .coreGoldSatelliteFullMomentum:
            return AppLocalization.string("新冠军候选：近期亏损波动元策略保持满核心，黄金趋势和相对强度有效时挂10%黄金卫星；总仓位封顶85%，并用二月弱权益刹车和净值轻刹车控制回撤。")
        case .coreGoldSatelliteHeatCappedMomentum:
            return AppLocalization.string("上架候选：以近期亏损波动元策略为核心，黄金趋势和相对强度有效时挂10%黄金卫星；组合总仓位封顶85%，单个权益指数最多64%，并保留二月弱势刹车和净值轻刹车。")
        case .coreGoldSatelliteAggressiveMomentum:
            return AppLocalization.string("进取候选：核心仍为近期亏损波动元策略，核心仓位97.5%，黄金卫星提高到15%；历史收益更高，但最大回撤更接近10%。")
        case .canaryMomentumDefense:
            return AppLocalization.string("2002年以来候选：纳指+标普做金丝雀，20/60/120/240日动量判断风险环境；进攻选强势权益前2并保留黄金底仓，转弱时只留黄金或现金防守。")
        case .drawdownReentryMomentum:
            return AppLocalization.string("收益优先候选：黄金作防守底仓，纳指/标普/A股指数只在90日回撤可控且动量或RSI重新转强时入场；每40个交易日再平衡，目标波动7.5%，最高仓位65%。")
        case .goldCoreTrendSatellite:
            return AppLocalization.string("黄金作为防守核心，纳指/标普只做趋势卫星；黄金看MA120，权益看MA250，每20个交易日再平衡，目标波动9.5%。")
        case .goldNasdaqSteadyRotation:
            return AppLocalization.string("黄金/纳指双资产择强：近20日涨幅需超过2%，且站上MA250；每40个交易日切到更强资产，目标波动8%，最高投入90%")
        case .goldNasdaqPortfolioScheduler:
            return AppLocalization.string("资产只在纳指、黄金、现金之间调度；后台读取多年美股压力信号作为风控源。纳指/黄金按趋势和强弱给目标仓位，压力升温时自动降低纳指、提高黄金或现金。")
        case .strongVolControlledRotation:
            return AppLocalization.string("20日强弱排序，每20个交易日持有最强资产；目标波动12%，最高投入90%")
        case .momentumRotation:
            return AppLocalization.string("20日强弱排序，每20个交易日切到最强资产，需站上MA60，否则空仓")
        }
    }

    var ruleSummary: String {
        switch self {
        case .ruleBased:
            return AppLocalization.string("买卖条件")
        case .ultraDefensiveRotation:
            return AppLocalization.string("40日强弱 · 目标波动6% · 最高仓位35%")
        case .defensiveRotation:
            return AppLocalization.string("40日强弱 · 目标波动8% · 最高仓位55%")
        case .lowDrawdownRotation:
            return AppLocalization.string("40日强弱 · 目标波动10% · 最高仓位65%")
        case .balancedRotation:
            return AppLocalization.string("40日强弱 · 目标波动12% · 最高仓位75%")
        case .enhancedRotation:
            return AppLocalization.string("40日强弱 · 目标波动12% · 最高仓位90%")
        case .longTermDefensiveTrend:
            return AppLocalization.string("黄金65% · MA200 · 目标波动8.5%")
        case .longTermEnhancedLowDrawdownTrend:
            return AppLocalization.string("黄金73% · MA220 · 目标波动9.5% · 波动刹车")
        case .steadyDrawdownLadderTrend:
            return AppLocalization.string("黄金73% · MA220 · 目标波动8.5% · 回撤阶梯")
        case .septemberGuardLadderTrend:
            return AppLocalization.string("回撤阶梯 · 9月权益25% · 黄金承接")
        case .longTermGrowthTrend:
            return AppLocalization.string("黄金50% · MA220 · 目标波动11%")
        case .longTermLowVolMomentum:
            return AppLocalization.string("240日动量 · 波动<18% · 目标波动10.5%")
        case .robustLowVolMomentum:
            return AppLocalization.string("180日动量 · 波动<18% · 目标波动7.5%")
        case .overheatGuardMomentum:
            return AppLocalization.string("Top1动量 · A股过热降仓 · 目标波动11%")
        case .highZoneDecelerationMomentum:
            return AppLocalization.string("高位钝化 · 短弱接管 · 目标波动11%")
        case .pairConfirmDoubleGuardMomentum:
            return AppLocalization.string("同组确认 · 双守门 · 最大仓位75%")
        case .tailBreakdownLockMomentum:
            return AppLocalization.string("持有破位锁盈 · 防守发动机 · 目标波动11%")
        case .recentLossVolatilityMetaMomentum:
            return AppLocalization.string("亏损+波动切防守 · 恢复后进攻")
        case .coreGoldSatelliteConservativeMomentum:
            return AppLocalization.string("核心95% · 黄金卫星10% · 最大回撤约8.9%")
        case .coreGoldSatelliteBalancedMomentum:
            return AppLocalization.string("核心97.5% · 黄金卫星10% · 平衡推荐")
        case .coreGoldSatelliteFullMomentum:
            return AppLocalization.string("核心100% · 黄金卫星10% · 净值轻刹车")
        case .coreGoldSatelliteHeatCappedMomentum:
            return AppLocalization.string("单权益64% · 黄金卫星10% · 总仓85%")
        case .coreGoldSatelliteAggressiveMomentum:
            return AppLocalization.string("核心97.5% · 黄金卫星15% · 进取收益")
        case .canaryMomentumDefense:
            return AppLocalization.string("双金丝雀 · 前2强势 · 黄金/现金防守")
        case .drawdownReentryMomentum:
            return AppLocalization.string("回撤<8% · 动量/RSI再入场 · 目标波动7.5%")
        case .goldCoreTrendSatellite:
            return AppLocalization.string("黄金核心35% · 权益卫星55% · 分线过滤")
        case .goldNasdaqSteadyRotation:
            return AppLocalization.string("黄金/纳指 · 20日强弱 · MA250 · 目标波动8%")
        case .goldNasdaqPortfolioScheduler:
            return AppLocalization.string("纳指/黄金/现金 · 组合调度 · 风险信号")
        case .strongVolControlledRotation:
            return AppLocalization.string("20日强弱 · 单一强势 · 目标波动12%")
        case .momentumRotation:
            return AppLocalization.string("20日强弱 · 每20交易日 · MA60过滤 · 空仓")
        }
    }

    nonisolated var isRotation: Bool {
        self != .ruleBased
    }

    nonisolated var requiredSignalAssetSymbols: [String] {
        switch self {
        case .recentLossVolatilityMetaMomentum,
             .coreGoldSatelliteConservativeMomentum,
             .coreGoldSatelliteBalancedMomentum,
             .coreGoldSatelliteFullMomentum,
             .coreGoldSatelliteHeatCappedMomentum,
             .coreGoldSatelliteAggressiveMomentum:
            return ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
        case .goldNasdaqPortfolioScheduler:
            return ["sp500"]
        default:
            return []
        }
    }
}

private struct AdvancedBacktestTrade: Identifiable {
    let id = UUID()
    let assetSymbol: String
    let assetTitle: String
    let date: Date
    let action: AdvancedBacktestTradeAction
    let price: Double
    let cashAmount: Double
    let units: Double
    let reason: String
    let realizedProfit: Double?
    let realizedReturn: Double?
    let holdingDays: Int?
}

private struct AdvancedBacktestPricePoint: Identifiable {
    let date: Date
    let price: Double
    let sequence: Int

    var id: Int { sequence }
}

private struct AdvancedBacktestAssetReport: Identifiable {
    let symbol: String
    let title: String
    let points: [BacktestSeriesPoint]
    let benchmarkPoints: [BacktestSeriesPoint]
    let pricePoints: [AdvancedBacktestPricePoint]
    let trades: [AdvancedBacktestTrade]
    let finalPortfolioValue: Double
    let finalCash: Double
    let finalUnits: Double
    let exposureRatio: Double

    var id: String { symbol }
}

private struct AdvancedBacktestBenchmarkSeries: Identifiable {
    let id: String
    let title: String
    let points: [BacktestSeriesPoint]
}

private struct CashYieldRatePoint: Identifiable {
    let date: Date
    let annualRate: Double

    var id: Date { date }
}

private struct CashYieldSummary {
    let title: String
    let source: String
    let sourceDetail: String
    let startDate: Date?
    let endDate: Date?
    let latestRateDate: Date?
    let latestAnnualRate: Double
    let averageAnnualRate: Double
    let averageCashRatio: Double
    let totalCashInterest: Double
    let ratePoints: [CashYieldRatePoint]
}

private enum MarketRiskSignalLevel: String {
    case calm
    case watch
    case stress
    case shock

    var title: String {
        switch self {
        case .calm:
            return AppLocalization.string("平稳")
        case .watch:
            return AppLocalization.string("观察")
        case .stress:
            return AppLocalization.string("压力")
        case .shock:
            return AppLocalization.string("冲击")
        }
    }

    var accent: Color {
        switch self {
        case .calm:
            return AssetTheme.positive
        case .watch:
            return AssetTheme.gold
        case .stress:
            return AssetTheme.accentOrange
        case .shock:
            return AssetTheme.negative
        }
    }
}

private struct MarketRiskSignalPoint: Identifiable {
    let date: Date
    let score: Double
    let level: MarketRiskSignalLevel
    let sourceTitle: String
    let shortReturn: Double?
    let monthlyReturn: Double?
    let drawdownFromHigh: Double?
    let annualizedVolatility: Double?

    var id: Date { date }
}

private struct MarketRiskSignalSummary {
    let title: String
    let source: String
    let sourceDetail: String
    let startDate: Date?
    let endDate: Date?
    let latestPoint: MarketRiskSignalPoint?
    let averageScore: Double
    let stressSessionRatio: Double
    let signalPoints: [MarketRiskSignalPoint]
}

private enum CashYieldCNY {
    static let title = AppLocalization.string("人民币活期存款基准利率")
    static let source = AppLocalization.string("中国人民银行 · 金融机构人民币存款基准利率")
    static let sourceDetail = AppLocalization.string("回测中未投入资产的现金仓按历史活期存款基准利率日化计息；实际银行、货币基金或现金管理产品收益可能不同。")
    private static let tradingDaysPerYear = 252.0
    private static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    static let ratePoints: [CashYieldRatePoint] = [
        .init(date: date(1990, 4, 15), annualRate: 0.0288),
        .init(date: date(1990, 8, 21), annualRate: 0.0216),
        .init(date: date(1991, 4, 21), annualRate: 0.0180),
        .init(date: date(1993, 5, 15), annualRate: 0.0216),
        .init(date: date(1993, 7, 11), annualRate: 0.0315),
        .init(date: date(1996, 5, 1), annualRate: 0.0297),
        .init(date: date(1996, 8, 23), annualRate: 0.0198),
        .init(date: date(1997, 10, 23), annualRate: 0.0171),
        .init(date: date(1998, 3, 25), annualRate: 0.0171),
        .init(date: date(1998, 7, 1), annualRate: 0.0144),
        .init(date: date(1998, 12, 7), annualRate: 0.0144),
        .init(date: date(1999, 6, 10), annualRate: 0.0099),
        .init(date: date(2002, 2, 21), annualRate: 0.0072),
        .init(date: date(2004, 10, 29), annualRate: 0.0072),
        .init(date: date(2006, 8, 19), annualRate: 0.0072),
        .init(date: date(2007, 3, 18), annualRate: 0.0072),
        .init(date: date(2007, 5, 19), annualRate: 0.0072),
        .init(date: date(2007, 7, 21), annualRate: 0.0081),
        .init(date: date(2007, 8, 22), annualRate: 0.0081),
        .init(date: date(2007, 9, 15), annualRate: 0.0081),
        .init(date: date(2007, 12, 21), annualRate: 0.0072),
        .init(date: date(2008, 10, 9), annualRate: 0.0072),
        .init(date: date(2008, 10, 30), annualRate: 0.0072),
        .init(date: date(2008, 11, 27), annualRate: 0.0036),
        .init(date: date(2008, 12, 23), annualRate: 0.0036),
        .init(date: date(2010, 10, 20), annualRate: 0.0036),
        .init(date: date(2010, 12, 26), annualRate: 0.0036),
        .init(date: date(2011, 2, 9), annualRate: 0.0040),
        .init(date: date(2011, 4, 6), annualRate: 0.0050),
        .init(date: date(2011, 7, 7), annualRate: 0.0050),
        .init(date: date(2012, 6, 8), annualRate: 0.0040),
        .init(date: date(2012, 7, 6), annualRate: 0.0035),
        .init(date: date(2015, 3, 1), annualRate: 0.0035),
        .init(date: date(2015, 5, 11), annualRate: 0.0035),
        .init(date: date(2015, 6, 28), annualRate: 0.0035),
        .init(date: date(2015, 8, 26), annualRate: 0.0035),
        .init(date: date(2015, 10, 24), annualRate: 0.0035),
    ]

    static func annualRate(on date: Date) -> Double {
        let day = calendar.startOfDay(for: date)
        var effectiveRate = ratePoints.first?.annualRate ?? 0
        for point in ratePoints {
            if point.date <= day {
                effectiveRate = point.annualRate
            } else {
                break
            }
        }
        return effectiveRate
    }

    static func dailyReturn(on date: Date) -> Double {
        dailyReturn(fromAnnualRate: annualRate(on: date))
    }

    static func dailyReturn(fromAnnualRate annualRate: Double) -> Double {
        max(annualRate, 0) / tradingDaysPerYear
    }

    static func averageAnnualRate(across dates: [Date]) -> Double {
        guard !dates.isEmpty else { return 0 }
        return dates.reduce(0) { $0 + annualRate(on: $1) } / Double(dates.count)
    }

    static func summary(
        startDate: Date?,
        endDate: Date?,
        totalCashInterest: Double,
        averageCashRatio: Double,
        averageAnnualRate: Double
    ) -> CashYieldSummary {
        let latestDate = endDate ?? Date()
        let latestPoint = ratePoints.last(where: { $0.date <= latestDate }) ?? ratePoints.last
        return CashYieldSummary(
            title: title,
            source: source,
            sourceDetail: sourceDetail,
            startDate: startDate,
            endDate: endDate,
            latestRateDate: latestPoint?.date,
            latestAnnualRate: latestPoint?.annualRate ?? 0,
            averageAnnualRate: averageAnnualRate,
            averageCashRatio: averageCashRatio,
            totalCashInterest: totalCashInterest,
            ratePoints: applicableRatePoints(startDate: startDate, endDate: endDate)
        )
    }

    private static func applicableRatePoints(startDate: Date?, endDate: Date?) -> [CashYieldRatePoint] {
        guard let startDate, let endDate else { return ratePoints }
        let start = calendar.startOfDay(for: min(startDate, endDate))
        let end = calendar.startOfDay(for: max(startDate, endDate))
        var points = ratePoints.filter { $0.date >= start && $0.date <= end }
        if let activeAtStart = ratePoints.last(where: { $0.date <= start }),
           !points.contains(where: { calendar.isDate($0.date, inSameDayAs: activeAtStart.date) }) {
            points.insert(activeAtStart, at: 0)
        }
        return points
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}

private enum MarketRiskSignalHistory {
    static let title = AppLocalization.string("美股压力信号")
    static let source = AppLocalization.string("标普500/纳指历史价格 · 仅作风控信号")
    static let sourceDetail = AppLocalization.string("该信号使用标普500优先、纳指备用的多年历史价格，综合短期跌幅、月度跌幅、阶段回撤和波动升温，给组合调度提供风险温度；它不是可买卖持仓，也不改变可见资产范围。")

    static func summary(
        dates: [Date],
        pricesBySymbol: [String: [Double]],
        preferredSymbol: String = "sp500",
        fallbackSymbol: String = "nasdaq"
    ) -> MarketRiskSignalSummary? {
        guard let sourceSymbol = pricesBySymbol[preferredSymbol] != nil ? preferredSymbol : (pricesBySymbol[fallbackSymbol] != nil ? fallbackSymbol : nil),
              let prices = pricesBySymbol[sourceSymbol],
              dates.count == prices.count,
              prices.count > 65 else { return nil }

        let sourceTitle = marketRiskSourceTitle(for: sourceSymbol)
        var points: [MarketRiskSignalPoint] = []
        points.reserveCapacity(max(prices.count - 60, 0))

        for index in prices.indices where index >= 60 {
            let shortReturn = priceReturn(prices, index: index, lookback: 5)
            let monthlyReturn = priceReturn(prices, index: index, lookback: 21)
            let drawdown = rollingDrawdown(prices, index: index, lookback: 63)
            let annualizedVolatility = rollingAnnualizedVolatility(prices, index: index, lookback: 20)
            let score = riskScore(
                shortReturn: shortReturn,
                monthlyReturn: monthlyReturn,
                drawdownFromHigh: drawdown,
                annualizedVolatility: annualizedVolatility
            )
            points.append(
                MarketRiskSignalPoint(
                    date: dates[index],
                    score: score,
                    level: level(for: score),
                    sourceTitle: sourceTitle,
                    shortReturn: shortReturn,
                    monthlyReturn: monthlyReturn,
                    drawdownFromHigh: drawdown,
                    annualizedVolatility: annualizedVolatility
                )
            )
        }

        guard !points.isEmpty else { return nil }
        let averageScore = points.reduce(0) { $0 + $1.score } / Double(points.count)
        let stressCount = points.filter { $0.level == .stress || $0.level == .shock }.count
        return MarketRiskSignalSummary(
            title: title,
            source: source,
            sourceDetail: AppLocalization.format("%@。当前采用%@作为压力源。", sourceDetail, sourceTitle),
            startDate: points.first?.date,
            endDate: points.last?.date,
            latestPoint: points.last,
            averageScore: averageScore,
            stressSessionRatio: Double(stressCount) / Double(points.count),
            signalPoints: downsample(points, maxCount: 360)
        )
    }

    static func latestLevel(
        dates: [Date],
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        preferredSymbol: String = "sp500",
        fallbackSymbol: String = "nasdaq"
    ) -> MarketRiskSignalLevel? {
        guard let sourceSymbol = pricesBySymbol[preferredSymbol] != nil ? preferredSymbol : (pricesBySymbol[fallbackSymbol] != nil ? fallbackSymbol : nil),
              let prices = pricesBySymbol[sourceSymbol],
              prices.indices.contains(signalIndex),
              signalIndex >= 60 else { return nil }
        let score = riskScore(
            shortReturn: priceReturn(prices, index: signalIndex, lookback: 5),
            monthlyReturn: priceReturn(prices, index: signalIndex, lookback: 21),
            drawdownFromHigh: rollingDrawdown(prices, index: signalIndex, lookback: 63),
            annualizedVolatility: rollingAnnualizedVolatility(prices, index: signalIndex, lookback: 20)
        )
        return level(for: score)
    }

    private static func marketRiskSourceTitle(for symbol: String) -> String {
        switch symbol {
        case "sp500": return AppLocalization.string("标普500")
        case "nasdaq": return AppLocalization.string("纳指")
        default: return symbol.uppercased()
        }
    }

    private static func priceReturn(_ values: [Double], index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index),
              values.indices.contains(index - lookback),
              values[index - lookback] > 0 else { return nil }
        return values[index] / values[index - lookback] - 1
    }

    private static func rollingDrawdown(_ values: [Double], index: Int, lookback: Int) -> Double? {
        guard lookback > 1, values.indices.contains(index) else { return nil }
        let start = max(0, index - lookback + 1)
        guard let high = values[start...index].max(), high > 0 else { return nil }
        return values[index] / high - 1
    }

    private static func rollingAnnualizedVolatility(_ values: [Double], index: Int, lookback: Int) -> Double? {
        guard lookback > 1,
              values.indices.contains(index),
              index - lookback + 1 > 0 else { return nil }
        let start = index - lookback + 1
        let returns = (start...index).compactMap { current -> Double? in
            guard values.indices.contains(current - 1),
                  values[current - 1] > 0,
                  values[current] > 0 else { return nil }
            return log(values[current] / values[current - 1])
        }
        guard returns.count >= lookback / 2 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count)
        return sqrt(max(variance, 0)) * sqrt(252)
    }

    private static func riskScore(
        shortReturn: Double?,
        monthlyReturn: Double?,
        drawdownFromHigh: Double?,
        annualizedVolatility: Double?
    ) -> Double {
        var score = 0.0
        if let shortReturn {
            if shortReturn < -0.065 { score += 32 }
            else if shortReturn < -0.040 { score += 20 }
            else if shortReturn < -0.020 { score += 10 }
        }
        if let monthlyReturn {
            if monthlyReturn < -0.120 { score += 34 }
            else if monthlyReturn < -0.080 { score += 24 }
            else if monthlyReturn < -0.045 { score += 13 }
        }
        if let drawdownFromHigh {
            if drawdownFromHigh < -0.180 { score += 25 }
            else if drawdownFromHigh < -0.120 { score += 17 }
            else if drawdownFromHigh < -0.070 { score += 9 }
        }
        if let annualizedVolatility {
            if annualizedVolatility > 0.38 { score += 18 }
            else if annualizedVolatility > 0.28 { score += 11 }
            else if annualizedVolatility > 0.22 { score += 6 }
        }
        return min(max(score, 0), 100)
    }

    private static func level(for score: Double) -> MarketRiskSignalLevel {
        switch score {
        case 75...:
            return .shock
        case 50..<75:
            return .stress
        case 25..<50:
            return .watch
        default:
            return .calm
        }
    }

    private static func downsample(_ points: [MarketRiskSignalPoint], maxCount: Int) -> [MarketRiskSignalPoint] {
        guard points.count > maxCount, maxCount > 0 else { return points }
        let stride = Double(points.count - 1) / Double(maxCount - 1)
        var sampled: [MarketRiskSignalPoint] = []
        sampled.reserveCapacity(maxCount)
        for index in 0..<maxCount {
            let sourceIndex = min(points.count - 1, Int((Double(index) * stride).rounded()))
            sampled.append(points[sourceIndex])
        }
        return sampled
    }
}

private struct AdvancedBacktestReport {
    let points: [BacktestSeriesPoint]
    let benchmarkPoints: [BacktestSeriesPoint]
    let benchmarkSeries: [AdvancedBacktestBenchmarkSeries]
    let trades: [AdvancedBacktestTrade]
    let assetReports: [AdvancedBacktestAssetReport]
    let finalPortfolioValue: Double
    let finalCash: Double
    let finalUnits: Double
    let totalReturn: Double
    let annualizedReturn: Double?
    let maxDrawdown: Double
    let annualizedVolatility: Double?
    let sharpeRatio: Double?
    let cashYieldSummary: CashYieldSummary
    let riskSignalSummary: MarketRiskSignalSummary?

    var initialPortfolioValue: Double {
        points.first?.portfolioValue ?? 0
    }

    var profitLoss: Double {
        finalPortfolioValue - initialPortfolioValue
    }

    var benchmarkTotalReturn: Double? {
        guard let first = benchmarkPoints.first,
              let last = benchmarkPoints.last,
              first.portfolioValue > 0 else { return nil }
        return (last.portfolioValue / first.portfolioValue) - 1
    }

    var excessReturn: Double? {
        benchmarkTotalReturn.map { totalReturn - $0 }
    }

    var calmarRatio: Double? {
        guard maxDrawdown > 0 else { return nil }
        return (annualizedReturn ?? totalReturn) / maxDrawdown
    }

    var averageExposureRatio: Double {
        guard !assetReports.isEmpty else { return 0 }
        return assetReports.reduce(0) { $0 + $1.exposureRatio } / Double(assetReports.count)
    }

    var averageCashRatio: Double {
        cashYieldSummary.averageCashRatio
    }

    var buyCount: Int {
        trades.filter { $0.action == .buy }.count
    }

    var sellCount: Int {
        trades.filter { $0.action == .sell }.count
    }

    var completedTradeCount: Int {
        trades.filter { $0.action == .sell && $0.realizedProfit != nil }.count
    }

    var winningTradeCount: Int {
        trades.filter { $0.action == .sell && ($0.realizedProfit ?? 0) > 0 }.count
    }

    var winRate: Double? {
        let completedCount = completedTradeCount
        guard completedCount > 0 else { return nil }
        return Double(winningTradeCount) / Double(completedCount)
    }
}

private struct StrategyRebalanceAllocation: Identifiable, Sendable {
    let symbol: String
    let title: String
    let targetWeight: Double
    let momentum: Double
    let annualizedVolatility: Double?

    var id: String { symbol }
}

private struct StrategyRebalanceAdvice: Sendable {
    let strategyTitle: String
    let asOfDate: Date
    let lookbackSessions: Int
    let rebalanceSessions: Int
    let targetAnnualVolatility: Double?
    let allocations: [StrategyRebalanceAllocation]

    var totalTargetWeight: Double {
        allocations.reduce(0) { $0 + $1.targetWeight }
    }

    var cashWeight: Double {
        max(0, 1 - totalTargetWeight)
    }

    var isCashDefense: Bool {
        allocations.isEmpty || totalTargetWeight <= 0.0001
    }
}

private enum StrategyRebalanceActionKind {
    case buy
    case sell
    case hold
    case missingRecord
    case targetOnly

    var title: String {
        switch self {
        case .buy:
            return AppLocalization.string("买入")
        case .sell:
            return AppLocalization.string("卖出")
        case .hold:
            return AppLocalization.string("保持")
        case .missingRecord:
            return AppLocalization.string("未记录")
        case .targetOnly:
            return AppLocalization.string("目标")
        }
    }

    var accent: Color {
        switch self {
        case .buy:
            return AssetTheme.positive
        case .sell:
            return AssetTheme.negative
        case .hold, .targetOnly:
            return AssetTheme.textSecondary
        case .missingRecord:
            return AssetTheme.accentOrange
        }
    }
}

private struct StrategyHoldingMatch {
    let amount: Double
    let itemNames: [String]

    var isMatched: Bool { !itemNames.isEmpty }
}

private struct StrategyRebalanceAction: Identifiable {
    let symbol: String
    let title: String
    let currentAmount: Double?
    let currentWeight: Double?
    let targetWeight: Double
    let targetAmount: Double?
    let deltaAmount: Double?
    let investmentBase: Double?
    let matchedItemNames: [String]
    let kind: StrategyRebalanceActionKind
    let momentum: Double?
    let annualizedVolatility: Double?

    var id: String { symbol }

    var isMatched: Bool { !matchedItemNames.isEmpty }
}

private enum StrategyRebalanceActionBuilder {
    static func actions(
        for advice: StrategyRebalanceAdvice,
        snapshot: AssetSnapshot?,
        selectedAssetOptions: [BacktestAssetOption],
        allAssetOptions: [BacktestAssetOption]
    ) -> [StrategyRebalanceAction] {
        let targetAllocationsBySymbol = Dictionary(uniqueKeysWithValues: advice.allocations.map { ($0.symbol, $0) })
        let orderedSymbols = orderedStrategySymbols(for: advice, selectedAssetOptions: selectedAssetOptions)

        guard let snapshot else {
            return advice.allocations.map { allocation in
                targetOnlyAction(allocation: allocation)
            }
        }

        let matchesBySymbol = Dictionary(uniqueKeysWithValues: orderedSymbols.map { symbol in
            (symbol, strategyHoldingMatch(for: symbol, in: snapshot))
        })
        let investmentBase = strategyInvestmentBase(in: snapshot, matches: Array(matchesBySymbol.values))
        guard investmentBase > 0 else {
            return advice.allocations.map { allocation in
                targetOnlyAction(allocation: allocation)
            }
        }

        let minimumTradeAmount = max(investmentBase * 0.01, 500)
        return orderedSymbols.compactMap { symbol -> StrategyRebalanceAction? in
            let allocation = targetAllocationsBySymbol[symbol]
            let targetWeight = allocation?.targetWeight ?? 0
            let match = matchesBySymbol[symbol] ?? StrategyHoldingMatch(amount: 0, itemNames: [])
            let currentAmount = match.amount
            let targetAmount = investmentBase * targetWeight
            let deltaAmount = targetAmount - currentAmount

            guard targetWeight > 0.0001 || currentAmount > minimumTradeAmount else { return nil }

            let kind: StrategyRebalanceActionKind
            if !match.isMatched, targetWeight > 0.0001 {
                kind = .missingRecord
            } else if deltaAmount > minimumTradeAmount {
                kind = .buy
            } else if deltaAmount < -minimumTradeAmount {
                kind = .sell
            } else {
                kind = .hold
            }

            return StrategyRebalanceAction(
                symbol: symbol,
                title: allocation?.title ?? strategyTitle(for: symbol, allAssetOptions: allAssetOptions),
                currentAmount: currentAmount,
                currentWeight: currentAmount / investmentBase,
                targetWeight: targetWeight,
                targetAmount: targetAmount,
                deltaAmount: deltaAmount,
                investmentBase: investmentBase,
                matchedItemNames: match.itemNames,
                kind: kind,
                momentum: allocation?.momentum,
                annualizedVolatility: allocation?.annualizedVolatility
            )
        }
        .sorted { lhs, rhs in
            if lhs.kind == .hold && rhs.kind != .hold { return false }
            if lhs.kind != .hold && rhs.kind == .hold { return true }
            if lhs.targetWeight != rhs.targetWeight { return lhs.targetWeight > rhs.targetWeight }
            return abs(lhs.deltaAmount ?? 0) > abs(rhs.deltaAmount ?? 0)
        }
    }

    private static func targetOnlyAction(allocation: StrategyRebalanceAllocation) -> StrategyRebalanceAction {
        StrategyRebalanceAction(
            symbol: allocation.symbol,
            title: allocation.title,
            currentAmount: nil,
            currentWeight: nil,
            targetWeight: allocation.targetWeight,
            targetAmount: nil,
            deltaAmount: nil,
            investmentBase: nil,
            matchedItemNames: [],
            kind: .targetOnly,
            momentum: allocation.momentum,
            annualizedVolatility: allocation.annualizedVolatility
        )
    }

    private static func orderedStrategySymbols(
        for advice: StrategyRebalanceAdvice,
        selectedAssetOptions: [BacktestAssetOption]
    ) -> [String] {
        var seen = Set<String>()
        var symbols: [String] = []
        for symbol in selectedAssetOptions.map(\.symbol) + advice.allocations.map(\.symbol) {
            guard !seen.contains(symbol) else { continue }
            seen.insert(symbol)
            symbols.append(symbol)
        }
        return symbols
    }

    private static func strategyInvestmentBase(in snapshot: AssetSnapshot, matches: [StrategyHoldingMatch]) -> Double {
        let financialAmount = snapshot.entries.reduce(0.0) { partial, entry in
            guard entry.resolvedAmount > 0,
                  (entry.item?.category?.group ?? .financial) == .financial else { return partial }
            return partial + entry.resolvedAmount
        }
        let matchedAmount = matches.reduce(0.0) { $0 + $1.amount }
        return max(financialAmount, matchedAmount)
    }

    private static func strategyHoldingMatch(for symbol: String, in snapshot: AssetSnapshot) -> StrategyHoldingMatch {
        let matchedEntries = snapshot.entries.filter { entry in
            guard entry.resolvedAmount > 0,
                  let item = entry.item,
                  (item.category?.group ?? .financial) != .liability else { return false }
            return itemMatchesStrategySymbol(item, symbol: symbol)
        }
        let amount = matchedEntries.reduce(0.0) { $0 + $1.resolvedAmount }
        let itemNames = Array(Set(matchedEntries.compactMap { $0.item?.name })).sorted()
        return StrategyHoldingMatch(amount: amount, itemNames: itemNames)
    }

    private static func itemMatchesStrategySymbol(_ item: AssetItem, symbol: String) -> Bool {
        if symbol == "gold_cny", item.resolvedAutoPricedAssetKind == .gold {
            return true
        }

        let searchText = "\(item.name) \(item.note)"
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        return strategyKeywords(for: symbol).contains { keyword in
            searchText.contains(keyword)
        }
    }

    private static func strategyKeywords(for symbol: String) -> [String] {
        switch symbol {
        case "gold_cny":
            return ["黄金", "gold", "au9999", "au99", "金"]
        case "nasdaq":
            return ["纳指", "纳斯达克", "nasdaq", "qqq", "ndx"]
        case "sp500":
            return ["标普500", "标普 500", "s&p500", "s&p 500", "sp500", "spy", "voo"]
        case "dowjones":
            return ["道指", "道琼斯", "dowjones", "dow jones", "djia", "dia"]
        case "csi300":
            return ["沪深300", "沪深 300", "csi300", "hs300"]
        case "shanghai_composite":
            return ["上证综指", "上证指数", "上证", "shanghai composite", "shanghai_composite", "000001"]
        default:
            return [symbol.lowercased()]
        }
    }

    private static func strategyTitle(for symbol: String, allAssetOptions: [BacktestAssetOption]) -> String {
        allAssetOptions.first(where: { $0.symbol == symbol })?.title ?? symbol
    }
}

private struct AdvancedBacktestComputationResult {
    let report: AdvancedBacktestReport?
    let rebalanceAdvice: StrategyRebalanceAdvice?
}

private struct AdvancedBacktestRiskSettings {
    var feeRate: Double
    var slippageRate: Double
    var maxPositionRatio: Double
    var cooldownDays: Int
    var stopLossRatio: Double
    var takeProfitRatio: Double
}

private struct AdvancedBacktestCandidate: Identifiable {
    let id = UUID()
    let buyRule: AdvancedBacktestRule
    let sellRule: AdvancedBacktestRule
    let tradeAmount: Double
    let settings: AdvancedBacktestRiskSettings
    let report: AdvancedBacktestReport
    let score: Double

    var title: String {
        "\(buyRule.direction.shortTitle) / \(sellRule.direction.shortTitle)"
    }
}

private struct AdvancedBacktestStrategyTemplate: Identifiable {
    let id: String
    var mode: AdvancedBacktestStrategyMode = .ruleBased
    var selectedAssetSymbols: [String]? = nil
    let category: String
    let title: String
    let annualizedReturn: Double
    let maxDrawdown: Double
    let sharpeRatio: Double
    let buyRule: AdvancedBacktestRule
    let sellRule: AdvancedBacktestRule
    let tradeAmountRatio: Double
    let maxPositionRatio: Double
    let cooldownDays: Int
    let stopLossRatio: Double
    let takeProfitRatio: Double

    var subtitle: String {
        if annualizedReturn == 0, maxDrawdown == 0, sharpeRatio == 0 {
            return AppLocalization.string("使用当前回测区间和真实行情实时计算")
        }
        return AppLocalization.format(
            "年化约%@ 最大回撤约%@ 夏普约%.2f",
            annualizedReturn.percentString(maxFractionDigits: 1),
            maxDrawdown.percentString(maxFractionDigits: 1),
            sharpeRatio
        )
    }

    static let all: [AdvancedBacktestStrategyTemplate] = [
        .init(
            id: "gold-nasdaq-portfolio-scheduler",
            mode: .goldNasdaqPortfolioScheduler,
            selectedAssetSymbols: ["gold_cny", "nasdaq"],
            category: AppLocalization.string("组合调度"),
            title: AppLocalization.string("金纳组合调度"),
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 90,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-heat-capped-momentum",
            mode: .coreGoldSatelliteHeatCappedMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            category: AppLocalization.string("低回撤策略"),
            title: AppLocalization.string("热度上限元策略"),
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 85,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "canary-momentum-defense",
            mode: .canaryMomentumDefense,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"],
            category: AppLocalization.string("低回撤策略"),
            title: AppLocalization.string("双金丝雀动量防守"),
            annualizedReturn: 0.0703387374544846,
            maxDrawdown: 0.09943170981525871,
            sharpeRatio: 0.9850207562980984,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 95,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        )
    ]
}

private struct BacktestReport {
    let points: [BacktestSeriesPoint]
    let totalReturn: Double
    let annualizedReturn: Double?
    let maxDrawdown: Double
    let maxDrawdownRecoveryDays: Int?
    let annualizedVolatility: Double?
    let sharpeRatio: Double?
}

private struct DCABacktestReport {
    let points: [BacktestSeriesPoint]
    let totalInvested: Double
    let finalPortfolioValue: Double
    let profitLoss: Double
    let totalReturn: Double
    let annualizedReturn: Double?
    let maxDrawdown: Double
    let annualizedVolatility: Double?
    let sharpeRatio: Double?
    let contributionCount: Int
    let totalUnits: Double
}

private enum BacktestRecordKind: String, Codable, CaseIterable {
    case allocation
    case dca
    case advanced

    var title: String {
        switch self {
        case .allocation:
            return AppLocalization.string("配置回测")
        case .dca:
            return AppLocalization.string("定投回测")
        case .advanced:
            return AppLocalization.string("高级回测")
        }
    }

    var entryIconName: String {
        switch self {
        case .allocation:
            return "chart.pie.fill"
        case .dca:
            return "calendar.badge.plus"
        case .advanced:
            return "slider.horizontal.3"
        }
    }


    var chartValueStyle: BacktestChartValueStyle {
        switch self {
        case .allocation:
            return .multiple
        case .dca, .advanced:
            return .currency(code: "CNY")
        }
    }
}

private struct BacktestRecordPointPayload: Codable {
    let date: Date
    let value: Double
    let sequence: Int

    init(date: Date, value: Double, sequence: Int) {
        self.date = date
        self.value = value
        self.sequence = sequence
    }

    init(point: BacktestSeriesPoint, sequence: Int) {
        self.date = point.date
        self.value = point.portfolioValue
        self.sequence = sequence
    }

    var seriesPoint: BacktestSeriesPoint {
        BacktestSeriesPoint(date: date, portfolioValue: value, sequence: sequence)
    }
}

private struct BacktestRecordAdvancedPricePayload: Codable, Identifiable {
    let date: Date
    let price: Double
    let sequence: Int

    var id: Int { sequence }

    var pricePoint: AdvancedBacktestPricePoint {
        AdvancedBacktestPricePoint(date: date, price: price, sequence: sequence)
    }
}

private struct BacktestRecordAdvancedTradePayload: Codable, Identifiable {
    let assetSymbol: String
    let assetTitle: String
    let date: Date
    let actionRawValue: String
    let price: Double
    let cashAmount: Double
    let units: Double
    let reason: String?
    let realizedProfit: Double?
    let realizedReturn: Double?
    let holdingDays: Int?
    let sequence: Int

    var id: String { "\(assetSymbol)-\(actionRawValue)-\(date.timeIntervalSinceReferenceDate)-\(sequence)" }

    var action: AdvancedBacktestTradeAction {
        AdvancedBacktestTradeAction(rawValue: actionRawValue) ?? .buy
    }

    init(
        assetSymbol: String,
        assetTitle: String,
        date: Date,
        actionRawValue: String,
        price: Double,
        cashAmount: Double,
        units: Double,
        reason: String? = nil,
        realizedProfit: Double? = nil,
        realizedReturn: Double? = nil,
        holdingDays: Int? = nil,
        sequence: Int
    ) {
        self.assetSymbol = assetSymbol
        self.assetTitle = assetTitle
        self.date = date
        self.actionRawValue = actionRawValue
        self.price = price
        self.cashAmount = cashAmount
        self.units = units
        self.reason = reason
        self.realizedProfit = realizedProfit
        self.realizedReturn = realizedReturn
        self.holdingDays = holdingDays
        self.sequence = sequence
    }

    init(trade: AdvancedBacktestTrade, sequence: Int) {
        self.assetSymbol = trade.assetSymbol
        self.assetTitle = trade.assetTitle
        self.date = trade.date
        self.actionRawValue = trade.action.rawValue
        self.price = trade.price
        self.cashAmount = trade.cashAmount
        self.units = trade.units
        self.reason = trade.reason
        self.realizedProfit = trade.realizedProfit
        self.realizedReturn = trade.realizedReturn
        self.holdingDays = trade.holdingDays
        self.sequence = sequence
    }
}

private struct BacktestRecordAdvancedAssetChartPayload: Codable, Identifiable {
    let symbol: String
    let title: String
    let pricePoints: [BacktestRecordAdvancedPricePayload]
    let benchmarkPoints: [BacktestRecordPointPayload]?
    let trades: [BacktestRecordAdvancedTradePayload]

    var id: String { symbol }

    var decodedBenchmarkPoints: [BacktestSeriesPoint] {
        (benchmarkPoints ?? [])
            .sorted { $0.sequence < $1.sequence }
            .map(\.seriesPoint)
    }
}

private struct BacktestRecordAdvancedBenchmarkSeriesPayload: Codable, Identifiable {
    let id: String
    let title: String
    let points: [BacktestRecordPointPayload]

    var decodedPoints: [BacktestSeriesPoint] {
        points
            .sorted { $0.sequence < $1.sequence }
            .map(\.seriesPoint)
    }
}

private struct BacktestRecordDetailConfigPayload: Codable {
    var kind: BacktestRecordKind
    var advancedBenchmarkSeries: [BacktestRecordAdvancedBenchmarkSeriesPayload]? = nil
}

private struct BacktestRecordAdvancedTradesConfigPayload: Codable {
    var advancedTrades: [BacktestRecordAdvancedTradePayload]? = nil
}

private struct BacktestRecordAdvancedChartsConfigPayload: Codable {
    var advancedAssetCharts: [BacktestRecordAdvancedAssetChartPayload]? = nil
}

private struct BacktestRecordConfigPayload: Codable {
    var kind: BacktestRecordKind
    var cashWeight: Double? = nil
    var goldWeight: Double? = nil
    var indexWeights: [String: Double]? = nil
    var dcaAssetSymbol: String? = nil
    var dcaContributionAmount: Double? = nil
    var dcaIntervalDays: Int? = nil
    var selectedAssetSymbol: String? = nil
    var selectedAssetSymbols: [String]? = nil
    var initialCash: Double? = nil
    var tradeAmount: Double? = nil
    var feeRate: Double? = nil
    var slippageRate: Double? = nil
    var maxPositionRatio: Double? = nil
    var cooldownDays: Int? = nil
    var stopLossRatio: Double? = nil
    var takeProfitRatio: Double? = nil
    var strategyModeRawValue: String? = nil
    var buyDirectionRawValue: String? = nil
    var buyDays: Int? = nil
    var sellDirectionRawValue: String? = nil
    var sellDays: Int? = nil
    var advancedTrades: [BacktestRecordAdvancedTradePayload]? = nil
    var advancedAssetCharts: [BacktestRecordAdvancedAssetChartPayload]? = nil
    var advancedBenchmarkSeries: [BacktestRecordAdvancedBenchmarkSeriesPayload]? = nil
}

private struct AdvancedBacktestRestoreRequest {
    let id: UUID
    let config: BacktestRecordConfigPayload
    let startDate: Date?
    let endDate: Date?
}

private enum BacktestRecordCodec {
    static func pointsData(from points: [BacktestSeriesPoint], maxCount: Int = 240) -> Data {
        let sampledPoints = sampled(points, maxCount: maxCount)
        let payload = sampledPoints.enumerated().map { index, point in
            BacktestRecordPointPayload(point: point, sequence: index)
        }
        return (try? JSONEncoder().encode(payload)) ?? Data()
    }

    static func configData(from payload: BacktestRecordConfigPayload) -> Data {
        (try? JSONEncoder().encode(payload)) ?? Data()
    }

    static func advancedTradePayloads(from trades: [AdvancedBacktestTrade]) -> [BacktestRecordAdvancedTradePayload] {
        trades.enumerated().map { index, trade in
            BacktestRecordAdvancedTradePayload(trade: trade, sequence: index)
        }
    }

    static func advancedBenchmarkSeriesPayloads(
        from series: [AdvancedBacktestBenchmarkSeries],
        maxPointCount: Int = 240
    ) -> [BacktestRecordAdvancedBenchmarkSeriesPayload] {
        series.map { benchmarkSeries in
            let sampledPoints = sampled(benchmarkSeries.points, maxCount: maxPointCount)
                .enumerated()
                .map { index, point in
                    BacktestRecordPointPayload(point: point, sequence: index)
                }
            return BacktestRecordAdvancedBenchmarkSeriesPayload(
                id: benchmarkSeries.id,
                title: benchmarkSeries.title,
                points: sampledPoints
            )
        }
    }

    static func advancedAssetChartPayloads(from assetReports: [AdvancedBacktestAssetReport], maxPricePointCount: Int = 240) -> [BacktestRecordAdvancedAssetChartPayload] {
        assetReports.map { assetReport in
            let sampledPricePoints = sampled(assetReport.pricePoints, maxCount: maxPricePointCount)
                .enumerated()
                .map { index, point in
                    BacktestRecordAdvancedPricePayload(date: point.date, price: point.price, sequence: index)
                }
            let sampledBenchmarkPoints = sampled(assetReport.benchmarkPoints, maxCount: maxPricePointCount)
                .enumerated()
                .map { index, point in
                    BacktestRecordPointPayload(point: point, sequence: index)
                }
            let trades = advancedTradePayloads(from: assetReport.trades)
            return BacktestRecordAdvancedAssetChartPayload(
                symbol: assetReport.symbol,
                title: assetReport.title,
                pricePoints: sampledPricePoints,
                benchmarkPoints: sampledBenchmarkPoints,
                trades: trades
            )
        }
    }

    static func decodePoints(from record: BacktestRecord) -> [BacktestSeriesPoint] {
        guard !record.pointsJSON.isEmpty,
              let payload = try? JSONDecoder().decode([BacktestRecordPointPayload].self, from: record.pointsJSON) else {
            return []
        }
        return payload
            .sorted { $0.sequence < $1.sequence }
            .map(\.seriesPoint)
    }

    static func decodeConfig(from record: BacktestRecord) -> BacktestRecordConfigPayload? {
        guard !record.configJSON.isEmpty else { return nil }
        return try? JSONDecoder().decode(BacktestRecordConfigPayload.self, from: record.configJSON)
    }

    static func decodeDetailConfig(from record: BacktestRecord) -> BacktestRecordDetailConfigPayload? {
        guard !record.configJSON.isEmpty else { return nil }
        return try? JSONDecoder().decode(BacktestRecordDetailConfigPayload.self, from: record.configJSON)
    }

    static func decodeAdvancedTrades(from record: BacktestRecord) -> [BacktestRecordAdvancedTradePayload] {
        guard !record.configJSON.isEmpty,
              let payload = try? JSONDecoder().decode(BacktestRecordAdvancedTradesConfigPayload.self, from: record.configJSON) else {
            return []
        }
        return (payload.advancedTrades ?? [])
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.sequence < rhs.sequence }
                return lhs.date < rhs.date
            }
    }

    static func decodeAdvancedAssetCharts(from record: BacktestRecord) -> [BacktestRecordAdvancedAssetChartPayload] {
        guard !record.configJSON.isEmpty,
              let payload = try? JSONDecoder().decode(BacktestRecordAdvancedChartsConfigPayload.self, from: record.configJSON) else {
            return []
        }
        return payload.advancedAssetCharts ?? []
    }

    static func kind(for record: BacktestRecord) -> BacktestRecordKind {
        BacktestRecordKind(rawValue: record.kindRawValue) ?? .allocation
    }

    private static func sampled(_ points: [BacktestSeriesPoint], maxCount: Int) -> [BacktestSeriesPoint] {
        guard points.count > maxCount, maxCount > 1 else { return points }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        var sampled: [BacktestSeriesPoint] = []
        sampled.reserveCapacity(maxCount)

        for index in 0 ..< maxCount {
            let rawIndex = Int((Double(index) * step).rounded())
            let safeIndex = min(max(rawIndex, 0), points.count - 1)
            let point = points[safeIndex]
            if sampled.last?.date != point.date {
                sampled.append(point)
            }
        }

        if sampled.last?.date != points.last?.date, let last = points.last {
            sampled.append(last)
        }
        return sampled
    }

    private static func sampled(_ points: [AdvancedBacktestPricePoint], maxCount: Int) -> [AdvancedBacktestPricePoint] {
        guard points.count > maxCount, maxCount > 1 else { return points }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        var sampled: [AdvancedBacktestPricePoint] = []
        sampled.reserveCapacity(maxCount)

        for index in 0 ..< maxCount {
            let rawIndex = Int((Double(index) * step).rounded())
            let safeIndex = min(max(rawIndex, 0), points.count - 1)
            let point = points[safeIndex]
            if sampled.last?.date != point.date {
                sampled.append(point)
            }
        }

        if sampled.last?.date != points.last?.date, let last = points.last {
            sampled.append(last)
        }
        return sampled
    }
}

private struct BacktestIndexOption: Identifiable {
    let symbol: String
    let title: String
    let color: Color

    var id: String { symbol }
}

private struct BacktestAssetOption: Identifiable {
    let symbol: String
    let title: String
    let color: Color
    let requiresHistoricalFX: Bool
    let historicalFXSymbol: String?

    var id: String { symbol }
}

private struct BacktestPerformanceMetrics {
    let totalReturn: Double
    let annualizedReturn: Double?
    let maxDrawdown: Double
    let annualizedVolatility: Double?
    let sharpeRatio: Double?
}

private enum BacktestDefaults {
    static let cashWeight: Double = 50
    static let goldWeight: Double = 25
    static let dcaAssetSymbol = "gold_cny"
    static let dcaContributionAmount: Double = 1000
    static let dcaIntervalDays = 30
    static let indexOptions: [BacktestIndexOption] = [
        .init(symbol: "sp500", title: AppLocalization.string("标普500"), color: AssetTheme.goldSoft),
        .init(symbol: "nasdaq", title: AppLocalization.string("纳指"), color: AssetTheme.accentBlue),
        .init(symbol: "dowjones", title: AppLocalization.string("道指"), color: AssetTheme.accentOrange),
        .init(symbol: "hsi", title: AppLocalization.string("恒生"), color: AssetTheme.accentRed),
        .init(symbol: "nikkei", title: AppLocalization.string("日经225"), color: AssetTheme.positive),
        .init(symbol: "csi300", title: AppLocalization.string("沪深300"), color: AssetTheme.textPrimary),
        .init(symbol: "shanghai_composite", title: AppLocalization.string("上证综指"), color: AssetTheme.textSecondary),
    ]
    static let indexWeights: [String: Double] = {
        Dictionary(uniqueKeysWithValues: indexOptions.map { option in
            (option.symbol, option.symbol == "nasdaq" ? 25 : 0)
        })
    }()
    static let dcaAssetOptions: [BacktestAssetOption] = [
        .init(symbol: "gold_cny", title: AppLocalization.string("黄金"), color: AssetTheme.gold, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "sp500", title: AppLocalization.string("标普500"), color: AssetTheme.goldSoft, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "nasdaq", title: AppLocalization.string("纳指"), color: AssetTheme.accentBlue, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "dowjones", title: AppLocalization.string("道指"), color: AssetTheme.accentOrange, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "csi300", title: AppLocalization.string("沪深300"), color: AssetTheme.textPrimary, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "shanghai_composite", title: AppLocalization.string("上证综指"), color: AssetTheme.textSecondary, requiresHistoricalFX: false, historicalFXSymbol: nil),
    ]
}

private enum StrategyNotificationDefaults {
    static let defaultTemplateID = "gold-nasdaq-portfolio-scheduler"
    static let defaultHour = 9

    static var eligibleTemplates: [AdvancedBacktestStrategyTemplate] {
        AdvancedBacktestStrategyTemplate.all.filter { $0.mode.isRotation }
    }

    static func template(for id: String) -> AdvancedBacktestStrategyTemplate? {
        eligibleTemplates.first { $0.id == id } ?? eligibleTemplates.first { $0.id == defaultTemplateID } ?? eligibleTemplates.first
    }

    static func assetOptions(for template: AdvancedBacktestStrategyTemplate) -> [BacktestAssetOption] {
        var selectedSymbols = Set(template.selectedAssetSymbols ?? BacktestDefaults.dcaAssetOptions.map(\.symbol))
        selectedSymbols.formUnion(template.mode.requiredSignalAssetSymbols)
        let options = BacktestDefaults.dcaAssetOptions.filter { selectedSymbols.contains($0.symbol) }
        return options.isEmpty ? BacktestDefaults.dcaAssetOptions : options
    }
}

@MainActor
private enum StrategyNotificationContentBuilder {
    static func body(advice: StrategyRebalanceAdvice, actions: [StrategyRebalanceAction]) -> String {
        if advice.isCashDefense || actions.isEmpty {
            return AppLocalization.format(
                "目标现金防守；信号截至 %@，建议下一交易日执行。",
                advice.asOfDate.recordDateString
            )
        }

        let actionable = actions.filter { action in
            switch action.kind {
            case .buy, .sell, .missingRecord:
                return true
            case .hold, .targetOnly:
                return false
            }
        }

        let source = actionable.isEmpty ? Array(actions.prefix(2)) : Array(actionable.prefix(2))
        let summary = source.map(actionSummary).joined(separator: "；")
        let suffix: String
        if actionable.isEmpty {
            suffix = AppLocalization.string("偏离不大，今日可保持。")
        } else if actions.count > source.count {
            suffix = AppLocalization.format("另有%d项。", actions.count - source.count)
        } else {
            suffix = ""
        }

        if suffix.isEmpty {
            return AppLocalization.format("%@。信号截至 %@，建议下一交易日执行。", summary, advice.asOfDate.recordDateString)
        }
        return AppLocalization.format("%@；%@ 信号截至 %@，建议下一交易日执行。", summary, suffix, advice.asOfDate.recordDateString)
    }

    static func preview(template: AdvancedBacktestStrategyTemplate, advice: StrategyRebalanceAdvice?, actions: [StrategyRebalanceAction]) -> String {
        guard let advice else {
            return AppLocalization.format("%@ · 等待历史行情后生成今日调仓", template.title)
        }
        return body(advice: advice, actions: actions)
    }

    private static func actionSummary(_ action: StrategyRebalanceAction) -> String {
        switch action.kind {
        case .buy:
            return AppLocalization.format("%@买入%@", action.title, abs(action.deltaAmount ?? 0).currencyString())
        case .sell:
            return AppLocalization.format("%@卖出%@", action.title, abs(action.deltaAmount ?? 0).currencyString())
        case .missingRecord:
            if let targetAmount = action.targetAmount {
                return AppLocalization.format("%@未记录，目标%@", action.title, targetAmount.currencyString())
            }
            return AppLocalization.format("%@未记录，目标%@", action.title, action.targetWeight.percentString(maxFractionDigits: 1))
        case .hold:
            return AppLocalization.format("%@保持%@", action.title, action.targetWeight.percentString(maxFractionDigits: 1))
        case .targetOnly:
            return AppLocalization.format("%@目标%@", action.title, action.targetWeight.percentString(maxFractionDigits: 1))
        }
    }
}

private nonisolated enum BacktestEngine {
    private struct HistoricalPricePoint {
        let date: Date
        let price: Double
    }

    private struct HistoricalLookup {
        let points: [HistoricalPricePoint]

        func price(onOrBefore targetDate: Date) -> Double? {
            guard !points.isEmpty else { return nil }

            var low = 0
            var high = points.count - 1
            var bestIndex: Int?

            while low <= high {
                let mid = (low + high) / 2
                if points[mid].date <= targetDate {
                    bestIndex = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }

            guard let bestIndex else { return nil }
            return points[bestIndex].price
        }
    }

    private static func sanitizedDatePriceMap(from series: PublicHistorySeries?) -> [String: Double] {
        guard let series else { return [:] }

        var map: [String: Double] = [:]
        for (dateText, price) in zip(series.dates, series.prices) {
            guard historicalSeriesDateStatic(from: dateText) != nil,
                  price.isFinite,
                  price > 0 else { continue }
            map[dateText] = price
        }

        return map
    }

    private static func normalizedPricePoints(from series: PublicHistorySeries?) -> [HistoricalPricePoint] {
        guard let series else { return [] }

        var priceByDate: [Date: Double] = [:]
        for (dateText, price) in zip(series.dates, series.prices) {
            guard let date = historicalSeriesDateStatic(from: dateText),
                  price.isFinite,
                  price > 0 else { continue }
            priceByDate[date] = price
        }

        return priceByDate
            .map { HistoricalPricePoint(date: $0.key, price: $0.value) }
            .sorted { $0.date < $1.date }
    }

    static func filteredHistorySeries(_ series: PublicHistorySeries?, within bounds: ClosedRange<Date>? = nil) -> PublicHistorySeries? {
        guard let series else { return nil }

        var filteredRows: [(date: Date, index: Int, dateText: String, price: Double)] = []
        for index in series.dates.indices {
            guard index < series.prices.count else { continue }
            let dateText = series.dates[index]
            let price = series.prices[index]
            guard let date = historicalSeriesDateStatic(from: dateText),
                  price.isFinite,
                  price > 0 else { continue }
            if let bounds, (date < bounds.lowerBound || date > bounds.upperBound) {
                continue
            }
            filteredRows.append((date, index, dateText, price))
        }

        let sortedRows = filteredRows.sorted { $0.date < $1.date }
        guard sortedRows.count >= 2 else { return nil }

        func filteredOptionalValues(_ values: [Double?]?) -> [Double?]? {
            guard let values, values.count == series.dates.count else { return nil }
            return sortedRows.map { values[$0.index] }
        }

        let filteredOpenPrices = filteredOptionalValues(series.openPrices)
        let filteredHighPrices = filteredOptionalValues(series.highPrices)
        let filteredLowPrices = filteredOptionalValues(series.lowPrices)
        let filteredClosePrices = filteredOptionalValues(series.closePrices)
        let filteredVolumes = filteredOptionalValues(series.volumes)
        let filteredCoverageRatio: Double?
        let filteredHasOHLC: Bool?
        if let filteredOpenPrices,
           let filteredHighPrices,
           let filteredLowPrices,
           let filteredClosePrices {
            let coveredCount = sortedRows.indices.filter { index in
                filteredOpenPrices[index] != nil
                    && filteredHighPrices[index] != nil
                    && filteredLowPrices[index] != nil
                    && filteredClosePrices[index] != nil
            }.count
            filteredCoverageRatio = sortedRows.isEmpty ? 0 : Double(coveredCount) / Double(sortedRows.count)
            filteredHasOHLC = coveredCount > 0
        } else {
            filteredCoverageRatio = series.ohlcCoverageRatio
            filteredHasOHLC = series.hasOHLC
        }

        return PublicHistorySeries(
            symbol: series.symbol,
            category: series.category,
            label: series.label,
            currency: series.currency,
            unit: series.unit,
            source: series.source,
            dates: sortedRows.map(\.dateText),
            prices: sortedRows.map(\.price),
            hasOHLC: filteredHasOHLC,
            ohlcSource: series.ohlcSource,
            ohlcCoverageRatio: filteredCoverageRatio,
            openPrices: filteredOpenPrices,
            highPrices: filteredHighPrices,
            lowPrices: filteredLowPrices,
            closePrices: filteredClosePrices,
            volumes: filteredVolumes
        )
    }

    static func filteredAdvancedAssetInputs(
        _ assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        within bounds: ClosedRange<Date>?
    ) -> [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)] {
        assetInputs.map { input in
            (
                assetSeries: filteredHistorySeries(input.assetSeries, within: bounds),
                assetOption: input.assetOption,
                fxSeries: filteredHistorySeries(input.fxSeries, within: bounds)
            )
        }
    }

    private static func performanceMetrics(
        from points: [BacktestSeriesPoint],
        cashFlowsByDate: [Date: Double] = [:]
    ) -> BacktestPerformanceMetrics? {
        guard let first = points.first, let last = points.last, first.portfolioValue > 0 else { return nil }

        var normalizedValue = 1.0
        var previousValue = first.portfolioValue
        var peakNormalizedValue = normalizedValue
        var returns: [Double] = []
        var maxDrawdown = 0.0

        for point in points.dropFirst() {
            let cashFlow = cashFlowsByDate[point.date, default: 0]
            let adjustedEndingValue = point.portfolioValue - cashFlow
            guard previousValue > 0, adjustedEndingValue > 0 else {
                previousValue = point.portfolioValue
                continue
            }

            let periodReturn = (adjustedEndingValue / previousValue) - 1
            returns.append(periodReturn)
            normalizedValue *= (1 + periodReturn)
            peakNormalizedValue = max(peakNormalizedValue, normalizedValue)

            if peakNormalizedValue > 0 {
                maxDrawdown = max(maxDrawdown, (peakNormalizedValue - normalizedValue) / peakNormalizedValue)
            }

            previousValue = point.portfolioValue
        }

        let totalReturn = normalizedValue - 1
        let daySpan = max(Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0, 1)
        let years = Double(daySpan) / 365.25
        let annualizedReturn = years > 0 ? pow(normalizedValue, 1 / years) - 1 : nil

        let mean = returns.isEmpty ? nil : returns.reduce(0, +) / Double(returns.count)
        let variance = returns.count > 1 && mean != nil
            ? returns.reduce(0) { $0 + pow($1 - mean!, 2) } / Double(returns.count - 1)
            : nil
        let dailyVolatility = variance.map { sqrt($0) }
        let annualizedVolatility = dailyVolatility.map { $0 * sqrt(252) }
        let sharpeRatio: Double?
        if let mean, let dailyVolatility, dailyVolatility > 0 {
            sharpeRatio = (mean * 252) / (dailyVolatility * sqrt(252))
        } else {
            sharpeRatio = nil
        }

        return BacktestPerformanceMetrics(
            totalReturn: totalReturn,
            annualizedReturn: annualizedReturn,
            maxDrawdown: maxDrawdown,
            annualizedVolatility: annualizedVolatility,
            sharpeRatio: sharpeRatio
        )
    }

    static func run(
        cashWeight: Double,
        goldWeight: Double,
        goldSeries: PublicHistorySeries?,
        indexWeights: [String: Double],
        indexSeriesBySymbol: [String: PublicHistorySeries]
    ) -> BacktestReport? {
        let normalizedCash = max(cashWeight, 0)
        let normalizedGold = max(goldWeight, 0)
        let normalizedIndices = indexWeights
            .mapValues { max($0, 0) }
            .filter { $0.value > 0 }
        let totalWeight = normalizedCash + normalizedGold + normalizedIndices.values.reduce(0, +)
        guard totalWeight > 0 else { return nil }

        let cw = normalizedCash / totalWeight
        let gw = normalizedGold / totalWeight
        let indexRatios = normalizedIndices.mapValues { $0 / totalWeight }

        if gw > 0, goldSeries == nil { return nil }
        for symbol in indexRatios.keys where indexSeriesBySymbol[symbol] == nil {
            return nil
        }

        let goldMap = sanitizedDatePriceMap(from: goldSeries)
        let indexMaps: [String: [String: Double]] = Dictionary(uniqueKeysWithValues: indexRatios.keys.compactMap { symbol in
            guard let series = indexSeriesBySymbol[symbol] else { return nil }
            let map = sanitizedDatePriceMap(from: series)
            guard !map.isEmpty else { return nil }
            return (symbol, map)
        })

        let selectedDateSets = (gw > 0 ? [Set(goldMap.keys)] : []) + indexMaps.values.map { Set($0.keys) }
        let sharedDates: [String]
        if let firstSet = selectedDateSets.first {
            sharedDates = selectedDateSets
                .dropFirst()
                .reduce(firstSet) { partial, next in partial.intersection(next) }
                .sorted()
        } else {
            sharedDates = goldSeries?.dates
                ?? indexSeriesBySymbol.values.first(where: { !$0.dates.isEmpty })?.dates
                ?? []
        }
        guard sharedDates.count >= 2 else { return nil }

        let firstGold = gw > 0 ? goldMap[sharedDates[0]] : 1
        if gw > 0, firstGold == nil || firstGold ?? 0 <= 0 { return nil }

        let firstIndexPrices: [String: Double] = Dictionary(uniqueKeysWithValues: indexRatios.keys.compactMap { symbol in
            guard let price = indexMaps[symbol]?[sharedDates[0]], price > 0 else { return nil }
            return (symbol, price)
        })
        guard firstIndexPrices.count == indexRatios.count else { return nil }

        var points: [BacktestSeriesPoint] = []
        var returns: [Double] = []
        var previousValue: Double?
        var peakValue: Double = 1
        var peakDate: Date?
        var maxDrawdown: Double = 0
        var maxDrawdownPeakValue: Double?
        var maxDrawdownPeakDate: Date?

        dateLoop: for dateText in sharedDates {
            guard let date = historicalSeriesDateStatic(from: dateText) else { continue }

            let goldComponent: Double
            if gw > 0 {
                guard let goldPrice = goldMap[dateText], let firstGold, firstGold > 0 else { continue }
                goldComponent = gw * (goldPrice / firstGold)
            } else {
                goldComponent = 0
            }

            var indexComponent: Double = 0
            for (symbol, weight) in indexRatios {
                guard let indexPrice = indexMaps[symbol]?[dateText],
                      let firstPrice = firstIndexPrices[symbol],
                      firstPrice > 0 else {
                    continue dateLoop
                }
                indexComponent += weight * (indexPrice / firstPrice)
            }

            let portfolioValue = cw + goldComponent + indexComponent
            points.append(.init(date: date, portfolioValue: portfolioValue, sequence: points.count))

            if let previousValue, previousValue > 0 {
                returns.append((portfolioValue / previousValue) - 1)
            }
            previousValue = portfolioValue

            if peakDate == nil || portfolioValue >= peakValue {
                peakValue = portfolioValue
                peakDate = date
            }

            if peakValue > 0 {
                let drawdown = (peakValue - portfolioValue) / peakValue
                if drawdown > maxDrawdown {
                    maxDrawdown = drawdown
                    maxDrawdownPeakValue = peakValue
                    maxDrawdownPeakDate = peakDate
                }
            }
        }

        guard let first = points.first, let last = points.last, first.portfolioValue > 0 else { return nil }
        let totalReturn = (last.portfolioValue / first.portfolioValue) - 1
        let daySpan = max(Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0, 1)
        let years = Double(daySpan) / 365.25
        let annualizedReturn = years > 0 ? pow(last.portfolioValue / first.portfolioValue, 1 / years) - 1 : nil

        let mean = returns.isEmpty ? nil : returns.reduce(0, +) / Double(returns.count)
        let variance = returns.count > 1 && mean != nil
            ? returns.reduce(0) { $0 + pow($1 - mean!, 2) } / Double(returns.count - 1)
            : nil
        let dailyVolatility = variance.map { sqrt($0) }
        let annualizedVolatility = dailyVolatility.map { $0 * sqrt(252) }
        let sharpeRatio: Double?
        if let mean, let dailyVolatility, dailyVolatility > 0 {
            sharpeRatio = (mean * 252) / (dailyVolatility * sqrt(252))
        } else {
            sharpeRatio = nil
        }

        let maxDrawdownRecoveryDays: Int?
        if maxDrawdown > 0,
           let maxDrawdownPeakValue,
           let maxDrawdownPeakDate,
           let recoveryPoint = points.first(where: { $0.date > maxDrawdownPeakDate && $0.portfolioValue >= maxDrawdownPeakValue }) {
            maxDrawdownRecoveryDays = Calendar.current.dateComponents([.day], from: maxDrawdownPeakDate, to: recoveryPoint.date).day
        } else {
            maxDrawdownRecoveryDays = nil
        }

        return BacktestReport(
            points: points,
            totalReturn: totalReturn,
            annualizedReturn: annualizedReturn,
            maxDrawdown: maxDrawdown,
            maxDrawdownRecoveryDays: maxDrawdownRecoveryDays,
            annualizedVolatility: annualizedVolatility,
            sharpeRatio: sharpeRatio
        )
    }

    static func runDCA(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?,
        contributionAmount: Double,
        intervalDays: Int
    ) -> DCABacktestReport? {
        guard let assetSeries else { return nil }
        let normalizedAmount = max(contributionAmount, 0)
        let normalizedInterval = max(intervalDays, 1)
        guard normalizedAmount > 0 else { return nil }

        let fxLookup: HistoricalLookup?
        if assetOption.requiresHistoricalFX {
            guard let lookup = makeHistoricalLookup(from: fxSeries), !lookup.points.isEmpty else { return nil }
            fxLookup = lookup
        } else {
            fxLookup = nil
        }

        let assetPricePoints = normalizedPricePoints(from: assetSeries)

        let pricePoints: [(date: Date, cnyPrice: Double)] = assetPricePoints.compactMap { point in
            guard let cnyPrice = cnyPrice(for: point, assetOption: assetOption, fxLookup: fxLookup) else { return nil }
            return (date: point.date, cnyPrice: cnyPrice)
        }

        guard let firstPoint = pricePoints.first, let lastPoint = pricePoints.last else { return nil }

        let calendar = Calendar(identifier: .gregorian)
        var scheduledDate = firstPoint.date
        var nextContributionIndex: Int? = 0
        var unitsHeld = 0.0
        var totalInvested = 0.0
        var contributionCount = 0
        var points: [BacktestSeriesPoint] = []
        var cashFlowsByDate: [Date: Double] = [:]

        for (index, point) in pricePoints.enumerated() {
            if nextContributionIndex == index {
                unitsHeld += normalizedAmount / point.cnyPrice
                totalInvested += normalizedAmount
                contributionCount += 1
                cashFlowsByDate[point.date, default: 0] += normalizedAmount

                if let nextScheduledDate = calendar.date(byAdding: .day, value: normalizedInterval, to: point.date),
                   nextScheduledDate <= lastPoint.date {
                    scheduledDate = nextScheduledDate
                    var cursor = index + 1
                    while cursor < pricePoints.count, pricePoints[cursor].date < scheduledDate {
                        cursor += 1
                    }
                    nextContributionIndex = cursor < pricePoints.count ? cursor : nil
                } else {
                    nextContributionIndex = nil
                }
            }

            guard unitsHeld > 0 else { continue }
            points.append(.init(date: point.date, portfolioValue: unitsHeld * point.cnyPrice, sequence: points.count))
        }

        guard let finalPoint = points.last, totalInvested > 0 else { return nil }
        let profitLoss = finalPoint.portfolioValue - totalInvested
        let metrics = performanceMetrics(from: points, cashFlowsByDate: cashFlowsByDate)
        return DCABacktestReport(
            points: points,
            totalInvested: totalInvested,
            finalPortfolioValue: finalPoint.portfolioValue,
            profitLoss: profitLoss,
            totalReturn: profitLoss / totalInvested,
            annualizedReturn: metrics?.annualizedReturn,
            maxDrawdown: metrics?.maxDrawdown ?? 0,
            annualizedVolatility: metrics?.annualizedVolatility,
            sharpeRatio: metrics?.sharpeRatio,
            contributionCount: contributionCount,
            totalUnits: unitsHeld
        )
    }

    private struct PreparedAdvancedSeries {
        let assetOption: BacktestAssetOption
        let pricePoints: [(date: Date, cnyPrice: Double)]
        let ma20: [Double?]
        let ma60: [Double?]
        let boll20: [(middle: Double, lower: Double, upper: Double)?]
    }

    private static func preparedAdvancedSeries(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?
    ) -> PreparedAdvancedSeries? {
        guard let assetSeries else { return nil }

        let fxLookup: HistoricalLookup?
        if assetOption.requiresHistoricalFX {
            guard let lookup = makeHistoricalLookup(from: fxSeries), !lookup.points.isEmpty else { return nil }
            fxLookup = lookup
        } else {
            fxLookup = nil
        }

        let assetPricePoints = normalizedPricePoints(from: assetSeries)
        let pricePoints: [(date: Date, cnyPrice: Double)] = assetPricePoints.compactMap { point in
            guard let cnyPrice = cnyPrice(for: point, assetOption: assetOption, fxLookup: fxLookup) else { return nil }
            return (date: point.date, cnyPrice: cnyPrice)
        }
        guard pricePoints.count >= 2 else { return nil }

        let prices = pricePoints.map { $0.cnyPrice }
        return PreparedAdvancedSeries(
            assetOption: assetOption,
            pricePoints: pricePoints,
            ma20: movingAverage(values: prices, period: 20),
            ma60: movingAverage(values: prices, period: 60),
            boll20: bollingerBands(values: prices, period: 20, multiplier: 2)
        )
    }

    static func runAdvancedStrategy(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?,
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        guard let preparedSeries = preparedAdvancedSeries(assetSeries: assetSeries, assetOption: assetOption, fxSeries: fxSeries) else { return nil }
        return runAdvancedStrategy(
            preparedSeries: preparedSeries,
            initialCash: initialCash,
            tradeAmount: tradeAmount,
            buyRule: buyRule,
            sellRule: sellRule,
            settings: settings
        )
    }

    private static func runAdvancedStrategy(
        preparedSeries: PreparedAdvancedSeries,
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let assetOption = preparedSeries.assetOption
        let pricePoints = preparedSeries.pricePoints
        let ma20 = preparedSeries.ma20
        let ma60 = preparedSeries.ma60
        let boll20 = preparedSeries.boll20
        let normalizedInitialCash = max(initialCash, 0)
        let normalizedTradeAmount = max(tradeAmount, 0)
        let normalizedFeeRate = max(settings.feeRate, 0) / 100
        let normalizedSlippageRate = max(settings.slippageRate, 0) / 100
        let normalizedMaxPositionRatio = min(max(settings.maxPositionRatio, 0), 100) / 100
        let normalizedCooldownDays = max(settings.cooldownDays, 0)
        let normalizedStopLossRatio = max(settings.stopLossRatio, 0) / 100
        let normalizedTakeProfitRatio = max(settings.takeProfitRatio, 0) / 100
        guard normalizedInitialCash > 0, normalizedTradeAmount > 0, normalizedMaxPositionRatio > 0 else { return nil }

        let buyThreshold = max(buyRule.days, 1)
        let sellThreshold = max(sellRule.days, 1)

        var cash = normalizedInitialCash
        var unitsHeld = 0.0
        var averageEntryPrice: Double?
        var firstEntryDate: Date?
        var lastTradeDate: Date?
        var upStreakByIndex = Array(repeating: 0, count: pricePoints.count)
        var downStreakByIndex = Array(repeating: 0, count: pricePoints.count)
        if pricePoints.count > 1 {
            for index in 1..<pricePoints.count {
                let currentPrice = pricePoints[index].cnyPrice
                let previousPrice = pricePoints[index - 1].cnyPrice
                if currentPrice > previousPrice {
                    upStreakByIndex[index] = upStreakByIndex[index - 1] + 1
                    downStreakByIndex[index] = 0
                } else if currentPrice < previousPrice {
                    upStreakByIndex[index] = 0
                    downStreakByIndex[index] = downStreakByIndex[index - 1] + 1
                } else {
                    upStreakByIndex[index] = 0
                    downStreakByIndex[index] = 0
                }
            }
        }
        var points: [BacktestSeriesPoint] = []
        var trades: [AdvancedBacktestTrade] = []
        var peakValue = normalizedInitialCash
        var maxDrawdown = 0.0
        var exposureSum = 0.0
        var exposureSampleCount = 0
        var cashRatioSum = 0.0
        var cashRatioSampleCount = 0
        var cashInterestEarned = 0.0
        var cashAnnualRateSum = 0.0
        var cashAnnualRateSampleCount = 0

        for (index, point) in pricePoints.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return nil }

            if index > 0 {
                let annualCashRate = CashYieldCNY.annualRate(on: pricePoints[index - 1].date)
                cashAnnualRateSum += annualCashRate
                cashAnnualRateSampleCount += 1
                if cash > 0 {
                    let cashInterest = cash * CashYieldCNY.dailyReturn(fromAnnualRate: annualCashRate)
                    if cashInterest.isFinite, cashInterest > 0 {
                        cash += cashInterest
                        cashInterestEarned += cashInterest
                    }
                }
            }

            if index > 0 {
                let signalIndex = index - 1
                let signalPoint = pricePoints[signalIndex]
                let shouldBuy = advancedRuleTriggered(
                    buyRule,
                    at: signalIndex,
                    pricePoints: pricePoints,
                    ma20: ma20,
                    ma60: ma60,
                    boll20: boll20,
                    upStreak: upStreakByIndex[signalIndex],
                    downStreak: downStreakByIndex[signalIndex],
                    threshold: buyThreshold
                )
                let shouldSell = advancedRuleTriggered(
                    sellRule,
                    at: signalIndex,
                    pricePoints: pricePoints,
                    ma20: ma20,
                    ma60: ma60,
                    boll20: boll20,
                    upStreak: upStreakByIndex[signalIndex],
                    downStreak: downStreakByIndex[signalIndex],
                    threshold: sellThreshold
                )

                let daysSinceLastTrade = lastTradeDate.map { Calendar.current.dateComponents([.day], from: $0, to: point.date).day ?? 0 } ?? Int.max
                let cooldownAllowsTrade = daysSinceLastTrade >= normalizedCooldownDays
                let positionMarketValue = unitsHeld * point.cnyPrice
                let portfolioBeforeTrade = cash + positionMarketValue
                let stopLossTriggered = normalizedStopLossRatio > 0
                    && unitsHeld > 0
                    && averageEntryPrice.map { signalPoint.cnyPrice <= $0 * (1 - normalizedStopLossRatio) } == true
                let takeProfitTriggered = normalizedTakeProfitRatio > 0
                    && unitsHeld > 0
                    && averageEntryPrice.map { signalPoint.cnyPrice >= $0 * (1 + normalizedTakeProfitRatio) } == true

                if (shouldSell || stopLossTriggered || takeProfitTriggered), unitsHeld > 0, cooldownAllowsTrade {
                    let executionPrice = max(point.cnyPrice * (1 - normalizedSlippageRate), 0)
                    let grossProceeds = unitsHeld * executionPrice
                    let fee = grossProceeds * normalizedFeeRate
                    let proceeds = max(grossProceeds - fee, 0)
                    let positionCostBasis = (averageEntryPrice ?? executionPrice) * unitsHeld
                    let realizedProfit = proceeds - positionCostBasis
                    let realizedReturn = positionCostBasis > 0 ? realizedProfit / positionCostBasis : nil
                    let holdingDays = firstEntryDate.map { Calendar.current.dateComponents([.day], from: $0, to: point.date).day ?? 0 }
                    let sellReason: String
                    if stopLossTriggered {
                        sellReason = AppLocalization.string("止损触发")
                    } else if takeProfitTriggered {
                        sellReason = AppLocalization.string("止盈触发")
                    } else {
                        sellReason = sellRule.direction.shortTitle
                    }
                    trades.append(
                        AdvancedBacktestTrade(
                            assetSymbol: assetOption.symbol,
                            assetTitle: assetOption.title,
                            date: point.date,
                            action: .sell,
                            price: executionPrice,
                            cashAmount: proceeds,
                            units: unitsHeld,
                            reason: sellReason,
                            realizedProfit: realizedProfit,
                            realizedReturn: realizedReturn,
                            holdingDays: holdingDays
                        )
                    )
                    cash += proceeds
                    unitsHeld = 0
                    averageEntryPrice = nil
                    firstEntryDate = nil
                    lastTradeDate = point.date
                } else if shouldBuy, cash > 0, cooldownAllowsTrade {
                    let maxPositionValue = portfolioBeforeTrade * normalizedMaxPositionRatio
                    let remainingPositionCapacity = max(maxPositionValue - positionMarketValue, 0)
                    let amountToSpend = min(cash, normalizedTradeAmount, remainingPositionCapacity)
                    if amountToSpend > 0 {
                        let executionPrice = point.cnyPrice * (1 + normalizedSlippageRate)
                        let fee = amountToSpend * normalizedFeeRate
                        let amountToInvest = max(amountToSpend - fee, 0)
                        let boughtUnits = executionPrice > 0 ? amountToInvest / executionPrice : 0
                        if boughtUnits > 0 {
                            let wasFlat = unitsHeld <= 0
                            let previousCost = (averageEntryPrice ?? 0) * unitsHeld
                            let newCost = previousCost + amountToInvest
                            trades.append(
                                AdvancedBacktestTrade(
                                    assetSymbol: assetOption.symbol,
                                    assetTitle: assetOption.title,
                                    date: point.date,
                                    action: .buy,
                                    price: executionPrice,
                                    cashAmount: amountToSpend,
                                    units: boughtUnits,
                                    reason: buyRule.direction.shortTitle,
                                    realizedProfit: nil,
                                    realizedReturn: nil,
                                    holdingDays: nil
                                )
                            )
                            cash -= amountToSpend
                            unitsHeld += boughtUnits
                            if wasFlat {
                                firstEntryDate = point.date
                            }
                            averageEntryPrice = unitsHeld > 0 ? newCost / unitsHeld : nil
                            lastTradeDate = point.date
                        }
                    }
                }
            }

            let portfolioValue = cash + unitsHeld * point.cnyPrice
            peakValue = max(peakValue, portfolioValue)
            if peakValue > 0 {
                maxDrawdown = max(maxDrawdown, (peakValue - portfolioValue) / peakValue)
            }
            if portfolioValue > 0 {
                exposureSum += min(max((unitsHeld * point.cnyPrice) / portfolioValue, 0), 1)
                exposureSampleCount += 1
                cashRatioSum += min(max(cash / portfolioValue, 0), 1)
                cashRatioSampleCount += 1
            }
            points.append(.init(date: point.date, portfolioValue: portfolioValue, sequence: points.count))
        }

        guard let last = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

        let priceHistory = pricePoints.enumerated().map { index, point in
            AdvancedBacktestPricePoint(date: point.date, price: point.cnyPrice, sequence: index)
        }
        let benchmarkPoints: [BacktestSeriesPoint]
        if let firstPrice = pricePoints.first?.cnyPrice, firstPrice > 0 {
            benchmarkPoints = pricePoints.enumerated().map { index, point in
                BacktestSeriesPoint(date: point.date, portfolioValue: normalizedInitialCash * point.cnyPrice / firstPrice, sequence: index)
            }
        } else {
            benchmarkPoints = []
        }
        let assetReport = AdvancedBacktestAssetReport(
            symbol: assetOption.symbol,
            title: assetOption.title,
            points: points,
            benchmarkPoints: benchmarkPoints,
            pricePoints: priceHistory,
            trades: trades,
            finalPortfolioValue: last.portfolioValue,
            finalCash: cash,
            finalUnits: unitsHeld,
            exposureRatio: exposureSampleCount > 0 ? exposureSum / Double(exposureSampleCount) : 0
        )

        let benchmarkSeries = AdvancedBacktestBenchmarkSeries(
            id: assetOption.symbol,
            title: assetOption.title,
            points: benchmarkPoints
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: cashInterestEarned,
            averageCashRatio: cashRatioSampleCount > 0 ? cashRatioSum / Double(cashRatioSampleCount) : 0,
            averageAnnualRate: cashAnnualRateSampleCount > 0 ? cashAnnualRateSum / Double(cashAnnualRateSampleCount) : 0
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: benchmarkPoints,
            benchmarkSeries: [benchmarkSeries],
            trades: trades,
            assetReports: [assetReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: cash,
            finalUnits: unitsHeld,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    static func runAdvancedStrategies(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let validInputs = assetInputs.filter { input in
            input.assetSeries != nil && (!input.assetOption.requiresHistoricalFX || input.fxSeries != nil)
        }
        guard !validInputs.isEmpty else { return nil }

        let normalizedInitialCash = max(initialCash, 0)
        let perAssetInitialCash = normalizedInitialCash / Double(validInputs.count)
        guard perAssetInitialCash > 0 else { return nil }

        let preparedSeries = validInputs.compactMap { input in
            preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard !preparedSeries.isEmpty else { return nil }

        return runAdvancedStrategies(
            preparedSeries: preparedSeries,
            initialCash: initialCash,
            tradeAmount: tradeAmount,
            buyRule: buyRule,
            sellRule: sellRule,
            settings: settings
        )
    }

    static func runAdvancedMomentumRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        runAdvancedRotationStrategy(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            mode: .momentumRotation
        )
    }

    static func runAdvancedLowDrawdownRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        runAdvancedRotationStrategy(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            mode: .lowDrawdownRotation
        )
    }

    static func runAdvancedRotationStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        mode: AdvancedBacktestStrategyMode
    ) -> AdvancedBacktestReport? {
        guard let config = advancedRotationConfig(for: mode) else { return nil }
        return runAdvancedRotation(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            config: config
        )
    }

    private static func recentLossVolatilityMetaConfig(
        mode: AdvancedBacktestStrategyMode,
        symbol: String = "recent_loss_volatility_meta_momentum",
        coreScale: Double? = nil,
        goldSatelliteWeight: Double = 0,
        portfolioEquityBrake: AdvancedRotationOverlayPortfolioEquityBrake? = nil,
        singleAssetExposureCap: AdvancedRotationSingleAssetExposureCap? = nil,
        buyReason: String? = nil
    ) -> AdvancedRotationConfig {
        var config = AdvancedRotationConfig(
            symbol: symbol,
            title: mode.title,
            lookbackSessions: 180,
            rebalanceSessions: 60,
            maFilterPeriod: 1,
            topCount: 1,
            maxExposure: coreScale == nil ? 0.75 : 0.85,
            targetAnnualVolatility: 0.11,
            volatilityLookbackSessions: 60,
            weighting: .winner,
            signal: .guardedDualMomentum,
            minMomentumThreshold: -0.02,
            maxSignalAnnualVolatility: 0.18,
            secondaryLookbackSessions: 60,
            secondaryMomentumThreshold: -0.04,
            signalDrawdownLookbackSessions: 60,
            maxSignalDrawdown: 0.15,
            rsiLookbackSessions: 14,
            donchianLookbackSessions: 240,
            metaSwitch: .init(
                defaultMode: .highZoneDecelerationMomentum,
                defensiveMode: .tailBreakdownLockMomentum,
                lossLookbackSessions: 60,
                lossThreshold: 0.035,
                volatilityLookbackSessions: 20,
                volatilityThreshold: 0.13,
                drawdownLookbackSessions: 60,
                lossDrawdownThreshold: 0.015,
                volatilityDrawdownThreshold: 0.025
            ),
            buyReason: buyReason ?? AppLocalization.string("近期亏损波动元策略建仓")
        )
        if let coreScale {
            config.goldSatelliteOverlay = .init(
                coreScale: coreScale,
                satelliteSymbol: "gold_cny",
                satelliteWeight: goldSatelliteWeight,
                maxTotalExposure: 0.85,
                satelliteMomentumLookbackSessions: 90,
                satelliteMomentumThreshold: 0,
                satelliteMovingAveragePeriod: 120,
                relativeSymbol: "sp500",
                relativeLookbackSessions: 60,
                relativeMomentumThreshold: 0,
                portfolioEquityBrake: portfolioEquityBrake,
                singleAssetExposureCap: singleAssetExposureCap,
                weakMonthEquityBrake: .init(
                    months: [2],
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    momentumLookbackSessions: 60,
                    momentumThreshold: -0.02,
                    maxEquityExposure: 0.35
                )
            )
        }
        return config
    }

    private static func advancedRotationConfig(for mode: AdvancedBacktestStrategyMode) -> AdvancedRotationConfig? {
        switch mode {
        case .ultraDefensiveRotation:
            return .init(
                symbol: "ultra_defensive_rotation",
                title: mode.title,
                lookbackSessions: 40,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 3,
                maxExposure: 0.35,
                targetAnnualVolatility: 0.06,
                volatilityLookbackSessions: 20,
                weighting: .momentumInverseVolatility,
                buyReason: AppLocalization.string("极稳轮动建仓")
            )
        case .defensiveRotation:
            return .init(
                symbol: "defensive_rotation",
                title: mode.title,
                lookbackSessions: 40,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 3,
                maxExposure: 0.55,
                targetAnnualVolatility: 0.08,
                volatilityLookbackSessions: 20,
                weighting: .momentumInverseVolatility,
                buyReason: AppLocalization.string("稳健轮动建仓")
            )
        case .lowDrawdownRotation:
            return .init(
                symbol: "low_drawdown_rotation",
                title: mode.title,
                lookbackSessions: 40,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 3,
                maxExposure: 0.65,
                targetAnnualVolatility: 0.10,
                volatilityLookbackSessions: 20,
                weighting: .momentumInverseVolatility,
                buyReason: AppLocalization.string("低回撤轮动建仓")
            )
        case .balancedRotation:
            return .init(
                symbol: "balanced_rotation",
                title: mode.title,
                lookbackSessions: 40,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 3,
                maxExposure: 0.75,
                targetAnnualVolatility: 0.12,
                volatilityLookbackSessions: 20,
                weighting: .momentumInverseVolatility,
                buyReason: AppLocalization.string("均衡轮动建仓")
            )
        case .enhancedRotation:
            return .init(
                symbol: "enhanced_rotation",
                title: mode.title,
                lookbackSessions: 40,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 3,
                maxExposure: 0.90,
                targetAnnualVolatility: 0.12,
                volatilityLookbackSessions: 20,
                weighting: .momentumInverseVolatility,
                buyReason: AppLocalization.string("增强轮动建仓")
            )
        case .longTermDefensiveTrend:
            return .init(
                symbol: "long_term_defensive_trend",
                title: mode.title,
                lookbackSessions: 120,
                rebalanceSessions: 20,
                maFilterPeriod: 200,
                topCount: 3,
                maxExposure: 0.85,
                targetAnnualVolatility: 0.085,
                volatilityLookbackSessions: 30,
                weighting: .winner,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.65,
                    "sp500": 0.157,
                    "nasdaq": 0.193,
                ],
                renormalizesFixedBaseWeights: true,
                buyReason: AppLocalization.string("长期低回撤趋势建仓")
            )
        case .longTermEnhancedLowDrawdownTrend:
            return .init(
                symbol: "long_term_enhanced_low_drawdown_trend",
                title: mode.title,
                lookbackSessions: 120,
                rebalanceSessions: 20,
                maFilterPeriod: 220,
                topCount: 3,
                maxExposure: 0.95,
                targetAnnualVolatility: 0.095,
                volatilityLookbackSessions: 30,
                weighting: .winner,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.73,
                    "sp500": 0.01,
                    "nasdaq": 0.26,
                ],
                renormalizesFixedBaseWeights: true,
                volatilityBrake: .init(
                    triggerSymbol: "nasdaq",
                    threshold: 0.28,
                    scaledSymbols: ["nasdaq", "sp500"],
                    scale: 0.5,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.7
                ),
                buyReason: AppLocalization.string("长期增强低回撤趋势建仓")
            )
        case .steadyDrawdownLadderTrend, .septemberGuardLadderTrend:
            return .init(
                symbol: mode == .septemberGuardLadderTrend ? "september_guard_ladder_trend" : "steady_drawdown_ladder_trend",
                title: mode.title,
                lookbackSessions: 120,
                rebalanceSessions: 20,
                maFilterPeriod: 220,
                topCount: 3,
                maxExposure: 0.95,
                targetAnnualVolatility: 0.085,
                volatilityLookbackSessions: 30,
                weighting: .winner,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.73,
                    "sp500": 0.01,
                    "nasdaq": 0.26,
                ],
                renormalizesFixedBaseWeights: true,
                drawdownLadderBrake: .init(
                    lookbackSessions: 180,
                    triggerThresholdRatiosBySymbol: [
                        "nasdaq": 1.0,
                        "sp500": 0.8,
                    ],
                    scaledSymbols: ["nasdaq", "sp500"],
                    softDrawdown: 0.06,
                    hardDrawdown: 0.12,
                    softScale: 0.55,
                    hardScale: 0.15,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.8
                ),
                monthlyExposureBrake: mode == .septemberGuardLadderTrend ? .init(
                    months: [9],
                    scaledSymbols: ["nasdaq", "sp500"],
                    scale: 0.25,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.8
                ) : nil,
                buyReason: mode == .septemberGuardLadderTrend
                    ? AppLocalization.string("九月风险闸门趋势建仓")
                    : AppLocalization.string("稳健回撤阶梯趋势建仓")
            )
        case .goldCoreTrendSatellite:
            return .init(
                symbol: "gold_core_trend_satellite",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 20,
                maFilterPeriod: 250,
                maFilterPeriodBySymbol: [
                    "gold_cny": 120,
                    "sp500": 250,
                    "nasdaq": 250,
                ],
                topCount: 3,
                maxExposure: 0.95,
                targetAnnualVolatility: 0.095,
                volatilityLookbackSessions: 30,
                weighting: .coreSatelliteWinner,
                coreWeightsBySymbol: [
                    "gold_cny": 0.35,
                ],
                satelliteSymbols: ["nasdaq", "sp500"],
                satelliteWeight: 0.55,
                buyReason: AppLocalization.string("核心黄金趋势卫星建仓")
            )
        case .longTermGrowthTrend:
            return .init(
                symbol: "long_term_growth_trend",
                title: mode.title,
                lookbackSessions: 120,
                rebalanceSessions: 20,
                maFilterPeriod: 220,
                topCount: 3,
                maxExposure: 0.85,
                targetAnnualVolatility: 0.11,
                volatilityLookbackSessions: 20,
                weighting: .winner,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.50,
                    "sp500": 0.15,
                    "nasdaq": 0.35,
                ],
                renormalizesFixedBaseWeights: true,
                buyReason: AppLocalization.string("长期进取趋势建仓")
            )
        case .longTermLowVolMomentum:
            return .init(
                symbol: "long_term_low_vol_momentum",
                title: mode.title,
                lookbackSessions: 240,
                rebalanceSessions: 60,
                maFilterPeriod: 1,
                topCount: 3,
                maxExposure: 0.65,
                targetAnnualVolatility: 0.105,
                volatilityLookbackSessions: 30,
                weighting: .winner,
                signal: .lowVolMomentum,
                minMomentumThreshold: 0,
                maxSignalAnnualVolatility: 0.18,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.524,
                    "nasdaq": 0.085,
                    "sp500": 0.093,
                    "csi300": 0.155,
                    "shanghai_composite": 0.144,
                ],
                renormalizesFixedBaseWeights: true,
                buyReason: AppLocalization.string("长期低波动动量建仓")
            )
        case .robustLowVolMomentum:
            return .init(
                symbol: "robust_low_vol_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 40,
                maFilterPeriod: 1,
                topCount: 3,
                maxExposure: 0.55,
                targetAnnualVolatility: 0.075,
                volatilityLookbackSessions: 30,
                weighting: .lowVolMomentumInverseVolatility,
                signal: .lowVolMomentum,
                minMomentumThreshold: 0,
                maxSignalAnnualVolatility: 0.18,
                buyReason: AppLocalization.string("稳健低波动动量建仓")
            )
        case .overheatGuardMomentum:
            return .init(
                symbol: "overheat_guard_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 60,
                maFilterPeriod: 1,
                topCount: 1,
                maxExposure: 0.75,
                targetAnnualVolatility: 0.11,
                volatilityLookbackSessions: 60,
                weighting: .winner,
                signal: .guardedDualMomentum,
                minMomentumThreshold: -0.02,
                maxSignalAnnualVolatility: 0.18,
                secondaryLookbackSessions: 60,
                secondaryMomentumThreshold: -0.04,
                signalDrawdownLookbackSessions: 60,
                maxSignalDrawdown: 0.15,
                rsiLookbackSessions: 14,
                donchianLookbackSessions: 240,
                overheatBrake: .init(
                    triggerSymbols: ["csi300", "shanghai_composite"],
                    momentumLookbackSessions: 60,
                    momentumThreshold: 0.18,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 68,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.35,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.75
                ),
                portfolioDrawdownGuard: .init(
                    lookbackSessions: 240,
                    drawdownThreshold: 0.06,
                    scale: 0.25
                ),
                buyReason: AppLocalization.string("A股过热不追高动量建仓")
            )
        case .highZoneDecelerationMomentum:
            return .init(
                symbol: "high_zone_deceleration_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 60,
                maFilterPeriod: 1,
                topCount: 1,
                maxExposure: 0.75,
                targetAnnualVolatility: 0.11,
                volatilityLookbackSessions: 60,
                weighting: .winner,
                signal: .guardedDualMomentum,
                minMomentumThreshold: -0.02,
                maxSignalAnnualVolatility: 0.18,
                secondaryLookbackSessions: 60,
                secondaryMomentumThreshold: -0.04,
                signalDrawdownLookbackSessions: 60,
                maxSignalDrawdown: 0.15,
                rsiLookbackSessions: 14,
                donchianLookbackSessions: 240,
                overheatBrake: .init(
                    triggerSymbols: ["csi300", "shanghai_composite"],
                    momentumLookbackSessions: 60,
                    momentumThreshold: 0.18,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 68,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.50,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 1.0
                ),
                decelerationLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumUpperThreshold: 0.06,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 65,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.30,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.75
                ),
                shortWeaknessLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumThreshold: -0.005,
                    relativeSymbol: "gold_cny",
                    relativeLookbackSessions: 60,
                    relativeMomentumThreshold: -0.05,
                    maxExposure: 0.35,
                    redeploySymbol: nil,
                    redeployRatio: 0
                ),
                portfolioDrawdownGuard: .init(
                    lookbackSessions: 240,
                    drawdownThreshold: 0.06,
                    scale: 0.25
                ),
                buyReason: AppLocalization.string("高位短弱双守门动量建仓")
            )
        case .pairConfirmDoubleGuardMomentum:
            return .init(
                symbol: "pair_confirm_double_guard_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 60,
                maFilterPeriod: 1,
                topCount: 1,
                maxExposure: 0.75,
                targetAnnualVolatility: 0.11,
                volatilityLookbackSessions: 60,
                weighting: .winner,
                signal: .guardedDualMomentum,
                minMomentumThreshold: -0.02,
                maxSignalAnnualVolatility: 0.18,
                secondaryLookbackSessions: 60,
                secondaryMomentumThreshold: -0.04,
                signalDrawdownLookbackSessions: 60,
                maxSignalDrawdown: 0.15,
                rsiLookbackSessions: 14,
                donchianLookbackSessions: 240,
                overheatBrake: .init(
                    triggerSymbols: ["csi300", "shanghai_composite"],
                    momentumLookbackSessions: 60,
                    momentumThreshold: 0.18,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 68,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.50,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 1.0
                ),
                decelerationLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumUpperThreshold: 0.06,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 65,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.30,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.75
                ),
                shortWeaknessLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumThreshold: -0.005,
                    relativeSymbol: "gold_cny",
                    relativeLookbackSessions: 60,
                    relativeMomentumThreshold: -0.05,
                    maxExposure: 0.35,
                    redeploySymbol: nil,
                    redeployRatio: 0
                ),
                pairConfirmationGuard: .init(
                    peerBySymbol: [
                        "nasdaq": "sp500",
                        "sp500": "nasdaq",
                        "csi300": "shanghai_composite",
                        "shanghai_composite": "csi300",
                    ],
                    peerMomentumLookbackSessions: 60,
                    peerMomentumThreshold: -0.04,
                    peerDrawdownLookbackSessions: 60,
                    peerDrawdownThreshold: 0.08,
                    maxExposure: 0.60,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.50
                ),
                portfolioDrawdownGuard: .init(
                    lookbackSessions: 240,
                    drawdownThreshold: 0.06,
                    scale: 0.18
                ),
                buyReason: AppLocalization.string("配对确认双守门动量建仓")
            )
        case .tailBreakdownLockMomentum:
            return .init(
                symbol: "tail_breakdown_lock_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 20,
                maFilterPeriod: 1,
                topCount: 1,
                maxExposure: 0.75,
                targetAnnualVolatility: 0.11,
                volatilityLookbackSessions: 60,
                weighting: .winner,
                signal: .guardedDualMomentum,
                minMomentumThreshold: -0.02,
                maxSignalAnnualVolatility: 0.18,
                secondaryLookbackSessions: 60,
                secondaryMomentumThreshold: -0.04,
                signalDrawdownLookbackSessions: 60,
                maxSignalDrawdown: 0.15,
                rsiLookbackSessions: 14,
                donchianLookbackSessions: 240,
                overheatBrake: .init(
                    triggerSymbols: ["csi300", "shanghai_composite"],
                    momentumLookbackSessions: 60,
                    momentumThreshold: 0.18,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 68,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.50,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 1.0
                ),
                decelerationLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumUpperThreshold: 0.06,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 65,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.30,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.75
                ),
                shortWeaknessLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumThreshold: -0.005,
                    relativeSymbol: "gold_cny",
                    relativeLookbackSessions: 60,
                    relativeMomentumThreshold: -0.05,
                    maxExposure: 0.35,
                    redeploySymbol: nil,
                    redeployRatio: 0
                ),
                heldBreakdownLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    drawdownLookbackSessions: 40,
                    drawdownThreshold: 0.045,
                    shortMomentumLookbackSessions: 10,
                    shortMomentumThreshold: -0.01,
                    mediumMomentumLookbackSessions: 20,
                    mediumMomentumThreshold: 0.01,
                    relativeSymbol: "gold_cny",
                    relativeLookbackSessions: 60,
                    relativeMomentumThreshold: -0.04,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.55,
                    requiredSignals: 2,
                    maxExposure: 0.55,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.50
                ),
                portfolioDrawdownGuard: .init(
                    lookbackSessions: 240,
                    drawdownThreshold: 0.06,
                    scale: 0.18
                ),
                buyReason: AppLocalization.string("持有中破位锁盈防守建仓")
            )
        case .recentLossVolatilityMetaMomentum:
            return recentLossVolatilityMetaConfig(mode: mode)
        case .coreGoldSatelliteConservativeMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_conservative_momentum",
                coreScale: 0.95,
                goldSatelliteWeight: 0.10,
                buyReason: AppLocalization.string("核心动量+黄金卫星保守建仓")
            )
        case .coreGoldSatelliteBalancedMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_balanced_momentum",
                coreScale: 0.975,
                goldSatelliteWeight: 0.10,
                buyReason: AppLocalization.string("核心动量+黄金卫星平衡建仓")
            )
        case .coreGoldSatelliteFullMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_full_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                portfolioEquityBrake: .init(
                    lookbackSessions: 60,
                    drawdownThreshold: 0.065,
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    equityScale: 0.85
                ),
                buyReason: AppLocalization.string("核心动量+黄金卫星满核心建仓")
            )
        case .coreGoldSatelliteHeatCappedMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_heat_capped_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                portfolioEquityBrake: .init(
                    lookbackSessions: 60,
                    drawdownThreshold: 0.065,
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    equityScale: 0.85
                ),
                singleAssetExposureCap: .init(
                    symbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    maxWeight: 0.64
                ),
                buyReason: AppLocalization.string("热度上限元策略建仓")
            )
        case .coreGoldSatelliteAggressiveMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_aggressive_momentum",
                coreScale: 0.975,
                goldSatelliteWeight: 0.15,
                buyReason: AppLocalization.string("核心动量+黄金卫星进攻建仓")
            )
        case .canaryMomentumDefense:
            return .init(
                symbol: "canary_momentum_defense",
                title: mode.title,
                lookbackSessions: 240,
                rebalanceSessions: 20,
                maFilterPeriod: 220,
                topCount: 2,
                maxExposure: 0.95,
                targetAnnualVolatility: nil,
                volatilityLookbackSessions: 60,
                weighting: .winner,
                canaryRegime: .init(
                    canarySymbols: ["nasdaq", "sp500"],
                    offensiveSymbols: ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"],
                    defensiveSymbol: "gold_cny",
                    momentumLookbacks: [20, 60, 120, 240],
                    momentumWeights: [12, 4, 2, 1],
                    weakAllowed: 1,
                    canaryMovingAveragePeriod: 180,
                    assetMovingAveragePeriod: 220,
                    defensiveMovingAveragePeriod: 220,
                    canaryMomentumThreshold: 0,
                    assetMomentumThreshold: 0,
                    defensiveMomentumThreshold: 0,
                    equityVolatilityCap: 0.45,
                    offensiveWeight: 0.40,
                    defensiveBallastWeight: 0.30,
                    defensiveOnlyWeight: 0.20,
                    equalWeight: false
                ),
                rebalancesFromFirstSignal: true,
                rebalanceBand: 0.02,
                buyReason: AppLocalization.string("双金丝雀动量防守建仓")
            )
        case .drawdownReentryMomentum:
            return .init(
                symbol: "drawdown_reentry_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 40,
                maFilterPeriod: 1,
                topCount: 3,
                maxExposure: 0.65,
                targetAnnualVolatility: 0.075,
                volatilityLookbackSessions: 20,
                weighting: .winner,
                signal: .drawdownReentry,
                minMomentumThreshold: 0.01,
                secondaryLookbackSessions: 90,
                signalDrawdownLookbackSessions: 90,
                maxSignalDrawdown: 0.08,
                rsiLookbackSessions: 21,
                minimumRSI: 55,
                maximumRSI: 75,
                donchianLookbackSessions: 180,
                minimumDonchianPosition: 0.50,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.673,
                    "nasdaq": 0.205,
                    "sp500": 0.036,
                    "csi300": 0.047,
                    "shanghai_composite": 0.039,
                ],
                renormalizesFixedBaseWeights: true,
                buyReason: AppLocalization.string("回撤再入场动量建仓")
            )
        case .goldNasdaqSteadyRotation:
            return .init(
                symbol: "gold_nasdaq_steady_rotation",
                title: mode.title,
                lookbackSessions: 20,
                rebalanceSessions: 40,
                maFilterPeriod: 250,
                topCount: 1,
                maxExposure: 0.90,
                targetAnnualVolatility: 0.08,
                volatilityLookbackSessions: 20,
                weighting: .winner,
                minMomentumThreshold: 0.02,
                buyReason: AppLocalization.string("金纳低回撤轮动建仓")
            )
        case .goldNasdaqPortfolioScheduler:
            return .init(
                symbol: "gold_nasdaq_portfolio_scheduler",
                title: mode.title,
                lookbackSessions: 120,
                rebalanceSessions: 20,
                maFilterPeriod: 180,
                maFilterPeriodBySymbol: [
                    "gold_cny": 120,
                    "nasdaq": 200,
                    "sp500": 200,
                ],
                topCount: 2,
                maxExposure: 0.90,
                targetAnnualVolatility: 0.095,
                volatilityLookbackSessions: 40,
                weighting: .winner,
                minMomentumThreshold: -0.01,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.35,
                    "nasdaq": 0.55,
                ],
                volatilityBrake: .init(
                    triggerSymbol: "sp500",
                    threshold: 0.28,
                    scaledSymbols: ["nasdaq"],
                    scale: 0.45,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.50
                ),
                fastCrashBrake: .init(
                    triggerSymbols: ["sp500", "nasdaq"],
                    lookbackSessions: 5,
                    drawdownThreshold: 0.06,
                    scaledSymbols: ["nasdaq"],
                    scale: 0.25,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.50
                ),
                signalOnlySymbols: ["sp500"],
                rebalancesFromFirstSignal: true,
                rebalanceBand: 0.015,
                buyReason: AppLocalization.string("金纳组合调度建仓")
            )
        case .strongVolControlledRotation:
            return .init(
                symbol: "strong_vol_controlled_rotation",
                title: mode.title,
                lookbackSessions: 20,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 1,
                maxExposure: 0.90,
                targetAnnualVolatility: 0.12,
                volatilityLookbackSessions: 20,
                weighting: .winner,
                buyReason: AppLocalization.string("强势控波轮动建仓")
            )
        case .momentumRotation:
            return .init(
                symbol: "momentum_rotation",
                title: mode.title,
                lookbackSessions: 20,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 1,
                maxExposure: 1,
                targetAnnualVolatility: nil,
                volatilityLookbackSessions: 20,
                weighting: .winner,
                buyReason: AppLocalization.string("20日强势轮动")
            )
        case .ruleBased:
            return nil
        }
    }

    private enum AdvancedRotationWeighting {
        case winner
        case momentumInverseVolatility
        case lowVolMomentumInverseVolatility
        case coreSatelliteWinner
    }

    private enum AdvancedRotationSignal {
        case maMomentum
        case lowVolMomentum
        case guardedDualMomentum
        case drawdownReentry
    }

    private struct AdvancedRotationConfig {
        let symbol: String
        let title: String
        let lookbackSessions: Int
        let rebalanceSessions: Int
        let maFilterPeriod: Int
        var maFilterPeriodBySymbol: [String: Int]? = nil
        let topCount: Int
        let maxExposure: Double
        let targetAnnualVolatility: Double?
        let volatilityLookbackSessions: Int
        let weighting: AdvancedRotationWeighting
        var signal: AdvancedRotationSignal = .maMomentum
        var minMomentumThreshold: Double = 0
        var maxSignalAnnualVolatility: Double? = nil
        var secondaryLookbackSessions: Int? = nil
        var secondaryMomentumThreshold: Double? = nil
        var signalDrawdownLookbackSessions: Int? = nil
        var maxSignalDrawdown: Double? = nil
        var rsiLookbackSessions: Int? = nil
        var minimumRSI: Double? = nil
        var maximumRSI: Double? = nil
        var donchianLookbackSessions: Int? = nil
        var minimumDonchianPosition: Double? = nil
        var fixedBaseWeightsBySymbol: [String: Double]? = nil
        var renormalizesFixedBaseWeights: Bool = false
        var coreWeightsBySymbol: [String: Double]? = nil
        var satelliteSymbols: [String] = []
        var satelliteWeight: Double = 0
        var volatilityBrake: AdvancedRotationVolatilityBrake? = nil
        var fastCrashBrake: AdvancedRotationFastCrashBrake? = nil
        var drawdownLadderBrake: AdvancedRotationDrawdownLadderBrake? = nil
        var monthlyExposureBrake: AdvancedRotationMonthlyExposureBrake? = nil
        var overheatBrake: AdvancedRotationOverheatBrake? = nil
        var decelerationLock: AdvancedRotationDecelerationLock? = nil
        var shortWeaknessLock: AdvancedRotationShortWeaknessLock? = nil
        var pairConfirmationGuard: AdvancedRotationPairConfirmationGuard? = nil
        var heldBreakdownLock: AdvancedRotationHeldBreakdownLock? = nil
        var portfolioDrawdownGuard: AdvancedRotationPortfolioDrawdownGuard? = nil
        var metaSwitch: AdvancedRotationMetaSwitch? = nil
        var goldSatelliteOverlay: AdvancedRotationGoldSatelliteOverlay? = nil
        var canaryRegime: AdvancedRotationCanaryRegime? = nil
        var signalOnlySymbols: Set<String> = []
        var rebalancesFromFirstSignal: Bool = false
        var rebalanceBand: Double = 0
        let buyReason: String
    }

    private struct AdvancedRotationCanaryRegime {
        let canarySymbols: [String]
        let offensiveSymbols: [String]
        let defensiveSymbol: String
        let momentumLookbacks: [Int]
        let momentumWeights: [Double]
        let weakAllowed: Int
        let canaryMovingAveragePeriod: Int
        let assetMovingAveragePeriod: Int
        let defensiveMovingAveragePeriod: Int
        let canaryMomentumThreshold: Double
        let assetMomentumThreshold: Double
        let defensiveMomentumThreshold: Double
        let equityVolatilityCap: Double
        let offensiveWeight: Double
        let defensiveBallastWeight: Double
        let defensiveOnlyWeight: Double
        let equalWeight: Bool
    }

    private struct AdvancedRotationOverheatBrake {
        let triggerSymbols: [String]
        let momentumLookbackSessions: Int
        let momentumThreshold: Double
        let rsiLookbackSessions: Int
        let rsiThreshold: Double
        let donchianLookbackSessions: Int
        let donchianPositionThreshold: Double
        let maxExposure: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationDecelerationLock {
        let triggerSymbols: [String]
        let shortMomentumLookbackSessions: Int
        let shortMomentumUpperThreshold: Double
        let rsiLookbackSessions: Int
        let rsiThreshold: Double
        let donchianLookbackSessions: Int
        let donchianPositionThreshold: Double
        let maxExposure: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationShortWeaknessLock {
        let triggerSymbols: [String]
        let shortMomentumLookbackSessions: Int
        let shortMomentumThreshold: Double
        let relativeSymbol: String
        let relativeLookbackSessions: Int
        let relativeMomentumThreshold: Double
        let maxExposure: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationPairConfirmationGuard {
        let peerBySymbol: [String: String]
        let peerMomentumLookbackSessions: Int
        let peerMomentumThreshold: Double
        let peerDrawdownLookbackSessions: Int
        let peerDrawdownThreshold: Double
        let maxExposure: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationHeldBreakdownLock {
        let triggerSymbols: [String]
        let drawdownLookbackSessions: Int
        let drawdownThreshold: Double
        let shortMomentumLookbackSessions: Int
        let shortMomentumThreshold: Double
        let mediumMomentumLookbackSessions: Int
        let mediumMomentumThreshold: Double
        let relativeSymbol: String
        let relativeLookbackSessions: Int
        let relativeMomentumThreshold: Double
        let donchianLookbackSessions: Int
        let donchianPositionThreshold: Double
        let requiredSignals: Int
        let maxExposure: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationGoldSatelliteOverlay {
        let coreScale: Double
        let satelliteSymbol: String
        let satelliteWeight: Double
        let maxTotalExposure: Double
        let satelliteMomentumLookbackSessions: Int
        let satelliteMomentumThreshold: Double
        let satelliteMovingAveragePeriod: Int
        let relativeSymbol: String
        let relativeLookbackSessions: Int
        let relativeMomentumThreshold: Double
        let portfolioEquityBrake: AdvancedRotationOverlayPortfolioEquityBrake?
        let singleAssetExposureCap: AdvancedRotationSingleAssetExposureCap?
        let weakMonthEquityBrake: AdvancedRotationWeakMonthEquityBrake?
    }

    private struct AdvancedRotationSingleAssetExposureCap {
        let symbols: [String]
        let maxWeight: Double
    }

    private struct AdvancedRotationOverlayPortfolioEquityBrake {
        let lookbackSessions: Int
        let drawdownThreshold: Double
        let equitySymbols: [String]
        let equityScale: Double
    }

    private struct AdvancedRotationWeakMonthEquityBrake {
        let months: Set<Int>
        let equitySymbols: [String]
        let momentumLookbackSessions: Int
        let momentumThreshold: Double
        let maxEquityExposure: Double
    }

    private struct AdvancedRotationMetaSwitch {
        let defaultMode: AdvancedBacktestStrategyMode
        let defensiveMode: AdvancedBacktestStrategyMode
        let lossLookbackSessions: Int
        let lossThreshold: Double
        let volatilityLookbackSessions: Int
        let volatilityThreshold: Double
        let drawdownLookbackSessions: Int
        let lossDrawdownThreshold: Double
        let volatilityDrawdownThreshold: Double
    }

    private struct AdvancedRotationPortfolioDrawdownGuard {
        let lookbackSessions: Int
        let drawdownThreshold: Double
        let scale: Double
    }

    private struct AdvancedRotationVolatilityBrake {
        let triggerSymbol: String
        let threshold: Double
        let scaledSymbols: [String]
        let scale: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationFastCrashBrake {
        let triggerSymbols: [String]
        let lookbackSessions: Int
        let drawdownThreshold: Double
        let scaledSymbols: [String]
        let scale: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationDrawdownLadderBrake {
        let lookbackSessions: Int
        let triggerThresholdRatiosBySymbol: [String: Double]
        let scaledSymbols: [String]
        let softDrawdown: Double
        let hardDrawdown: Double
        let softScale: Double
        let hardScale: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationMonthlyExposureBrake {
        let months: Set<Int>
        let scaledSymbols: [String]
        let scale: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationTargetWeight {
        let symbol: String
        let weight: Double
        let momentum: Double
        let annualizedVolatility: Double?
    }

    private struct AdvancedRotationSimulatedTrace {
        let values: [Double]
        let weightsByIndex: [[String: Double]]
    }

    static func advancedRotationRebalanceAdvice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        mode: AdvancedBacktestStrategyMode
    ) -> StrategyRebalanceAdvice? {
        guard let config = advancedRotationConfig(for: mode) else { return nil }
        let preparedSeries: [PreparedAdvancedSeries] = assetInputs.compactMap { input -> PreparedAdvancedSeries? in
            guard input.assetSeries != nil,
                  !input.assetOption.requiresHistoricalFX || input.fxSeries != nil else { return nil }
            return preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard preparedSeries.count >= 2 else { return nil }

        let aligned = alignedRotationPriceSeries(from: preparedSeries)
        let commonDates = aligned.dates
        let pricesBySymbol = aligned.pricesBySymbol
        let optionBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, $0.assetOption) })
        let symbols = preparedSeries.map { $0.assetOption.symbol }
        let tradableSymbols = symbols.filter { !config.signalOnlySymbols.contains($0) }
        guard !tradableSymbols.isEmpty else { return nil }
        let maxMAFilterPeriod = max(config.maFilterPeriodBySymbol?.values.max() ?? config.maFilterPeriod, config.maFilterPeriod)
        let fastCrashBrakeLookback = config.fastCrashBrake?.lookbackSessions ?? 0
        let overheatBrakeWarmup = max(
            config.overheatBrake?.momentumLookbackSessions ?? 0,
            config.overheatBrake?.rsiLookbackSessions ?? 0,
            config.overheatBrake?.donchianLookbackSessions ?? 0
        )
        let decelerationLockWarmup = max(
            config.decelerationLock?.shortMomentumLookbackSessions ?? 0,
            config.decelerationLock?.rsiLookbackSessions ?? 0,
            config.decelerationLock?.donchianLookbackSessions ?? 0
        )
        let shortWeaknessLockWarmup = max(
            config.shortWeaknessLock?.shortMomentumLookbackSessions ?? 0,
            config.shortWeaknessLock?.relativeLookbackSessions ?? 0
        )
        let pairConfirmationGuardWarmup = max(
            config.pairConfirmationGuard?.peerMomentumLookbackSessions ?? 0,
            config.pairConfirmationGuard?.peerDrawdownLookbackSessions ?? 0
        )
        let heldBreakdownLockWarmup = max(
            config.heldBreakdownLock?.drawdownLookbackSessions ?? 0,
            config.heldBreakdownLock?.shortMomentumLookbackSessions ?? 0,
            config.heldBreakdownLock?.mediumMomentumLookbackSessions ?? 0,
            config.heldBreakdownLock?.relativeLookbackSessions ?? 0,
            config.heldBreakdownLock?.donchianLookbackSessions ?? 0
        )
        let metaSwitchWarmup = max(
            config.metaSwitch?.lossLookbackSessions ?? 0,
            config.metaSwitch?.volatilityLookbackSessions ?? 0,
            config.metaSwitch?.drawdownLookbackSessions ?? 0
        )
        let overlayPortfolioBrakeWarmup = config.goldSatelliteOverlay?.portfolioEquityBrake?.lookbackSessions ?? 0
        let canaryRegimeWarmup = max(
            config.canaryRegime?.momentumLookbacks.max() ?? 0,
            config.canaryRegime?.canaryMovingAveragePeriod ?? 0,
            config.canaryRegime?.assetMovingAveragePeriod ?? 0,
            config.canaryRegime?.defensiveMovingAveragePeriod ?? 0
        )
        let extraIndicatorWarmup = [
            config.secondaryLookbackSessions ?? 0,
            config.signalDrawdownLookbackSessions ?? 0,
            config.rsiLookbackSessions ?? 0,
            config.donchianLookbackSessions ?? 0,
            overheatBrakeWarmup,
            decelerationLockWarmup,
            shortWeaknessLockWarmup,
            pairConfirmationGuardWarmup,
            heldBreakdownLockWarmup,
            config.portfolioDrawdownGuard?.lookbackSessions ?? 0,
            metaSwitchWarmup,
            overlayPortfolioBrakeWarmup,
            canaryRegimeWarmup,
        ].max() ?? 0
        let minimumWarmup = ([
            config.lookbackSessions,
            maxMAFilterPeriod,
            config.volatilityLookbackSessions,
            fastCrashBrakeLookback,
            extraIndicatorWarmup,
        ].max() ?? 0) + 1
        guard commonDates.count > minimumWarmup,
              let signalIndex = commonDates.indices.last else { return nil }

        var maBySymbol: [String: [Double?]] = [:]
        var volatilityBySymbol: [String: [Double?]] = [:]
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            let maFilterPeriod = config.maFilterPeriodBySymbol?[symbol] ?? config.maFilterPeriod
            maBySymbol[symbol] = movingAverage(values: prices, period: maFilterPeriod)
            volatilityBySymbol[symbol] = rollingAnnualizedVolatility(values: prices, period: config.volatilityLookbackSessions)
        }

        let targetWeightItems: [AdvancedRotationTargetWeight]
        let portfolioGuardScale: Double
        if let metaSwitch = config.metaSwitch {
            guard let tracesByMode = metaEngineTraces(
                for: metaSwitch,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates
            ),
                  let rawMetaWeights = metaRotationTargetWeights(
                    metaSwitch: metaSwitch,
                    stressIndex: signalIndex,
                    weightIndex: signalIndex,
                    tracesByMode: tracesByMode
                  ) else { return nil }
            let metaWeights = applyGoldSatelliteOverlay(
                to: rawMetaWeights,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                pricesBySymbol: pricesBySymbol,
                portfolioValues: tracesByMode[metaSwitch.defaultMode]?.values,
                config: config
            )
            portfolioGuardScale = 1
            targetWeightItems = metaWeights.compactMap { item -> AdvancedRotationTargetWeight? in
                let symbol = item.key
                let weight = item.value
                guard !config.signalOnlySymbols.contains(symbol),
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex) else { return nil }
                return AdvancedRotationTargetWeight(
                    symbol: symbol,
                    weight: weight,
                    momentum: priceMomentum(values: prices, at: signalIndex, lookback: config.lookbackSessions) ?? 0,
                    annualizedVolatility: volatilityBySymbol[symbol]?[signalIndex] ?? nil
                )
            }
        } else {
            portfolioGuardScale = simulatedPortfolioDrawdownGuardScale(
                symbols: tradableSymbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: config
            )
            targetWeightItems = advancedRotationTargetWeights(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                config: config
            )
            .filter { !config.signalOnlySymbols.contains($0.symbol) }
        }

        let allocations = targetWeightItems
        .compactMap { target -> StrategyRebalanceAllocation? in
            let adjustedWeight = target.weight * portfolioGuardScale
            guard adjustedWeight > 0,
                  !config.signalOnlySymbols.contains(target.symbol),
                  let option = optionBySymbol[target.symbol] else { return nil }
            return StrategyRebalanceAllocation(
                symbol: target.symbol,
                title: option.title,
                targetWeight: adjustedWeight,
                momentum: target.momentum,
                annualizedVolatility: target.annualizedVolatility
            )
        }
        .sorted { lhs, rhs in
            if lhs.targetWeight == rhs.targetWeight { return lhs.title < rhs.title }
            return lhs.targetWeight > rhs.targetWeight
        }

        return StrategyRebalanceAdvice(
            strategyTitle: config.title,
            asOfDate: commonDates[signalIndex],
            lookbackSessions: config.lookbackSessions,
            rebalanceSessions: config.rebalanceSessions,
            targetAnnualVolatility: config.targetAnnualVolatility,
            allocations: allocations
        )
    }

    private static func simulatedPortfolioDrawdownGuardScale(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        config: AdvancedRotationConfig
    ) -> Double {
        guard let guardConfig = config.portfolioDrawdownGuard,
              commonDates.count > 2 else { return 1 }

        func guardScale(currentValue: Double, historyValues: [Double]) -> Double {
            guard !historyValues.isEmpty else { return 1 }
            let lookbackSessions = max(guardConfig.lookbackSessions, 1)
            var recentValues = Array(historyValues.suffix(lookbackSessions))
            recentValues.append(currentValue)
            guard let recentPeak = recentValues.max(), recentPeak > 0 else { return 1 }
            let drawdownFromPeak = currentValue / recentPeak - 1
            guard drawdownFromPeak < -max(guardConfig.drawdownThreshold, 0) else { return 1 }
            return min(max(guardConfig.scale, 0), 1)
        }

        var weightsBySymbol: [String: Double] = [:]
        var values: [Double] = [100_000]
        var value = 100_000.0
        let rebalanceSessions = max(config.rebalanceSessions, 1)

        for index in commonDates.indices.dropFirst() {
            var dailyReturn = 0.0
            for symbol in symbols {
                guard let weight = weightsBySymbol[symbol],
                      weight > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(index),
                      prices.indices.contains(index - 1),
                      prices[index - 1] > 0 else { continue }
                dailyReturn += weight * (prices[index] / prices[index - 1] - 1)
            }
            let investedWeight = weightsBySymbol.values.reduce(0) { $0 + max($1, 0) }
            let cashWeight = max(0, 1 - investedWeight)
            dailyReturn += cashWeight * CashYieldCNY.dailyReturn(on: commonDates[index - 1])
            value *= 1 + dailyReturn
            guard value.isFinite, value > 0 else { return 1 }

            if index % rebalanceSessions == 0 {
                let signalIndex = index - 1
                let baseWeights = Dictionary(uniqueKeysWithValues: advancedRotationTargetWeights(
                    symbols: symbols,
                    pricesBySymbol: pricesBySymbol,
                    maBySymbol: maBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    config: config
                ).map { ($0.symbol, $0.weight) })
                let scale = guardScale(currentValue: value, historyValues: values)
                weightsBySymbol = baseWeights.mapValues { $0 * scale }
            }

            values.append(value)
        }

        return guardScale(currentValue: value, historyValues: values)
    }

    private static func simulatedRotationTrace(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        config: AdvancedRotationConfig
    ) -> AdvancedRotationSimulatedTrace {
        var weightsBySymbol: [String: Double] = [:]
        var values: [Double] = [100_000]
        var weightsByIndex: [[String: Double]] = [weightsBySymbol]
        var value = 100_000.0
        let rebalanceSessions = max(config.rebalanceSessions, 1)

        func applyPortfolioGuard(to targetWeights: [String: Double], currentValue: Double) -> [String: Double] {
            guard let guardConfig = config.portfolioDrawdownGuard,
                  !targetWeights.isEmpty else { return targetWeights }
            let lookbackSessions = max(guardConfig.lookbackSessions, 1)
            var recentValues = Array(values.suffix(lookbackSessions))
            recentValues.append(currentValue)
            guard let recentPeak = recentValues.max(), recentPeak > 0 else { return targetWeights }
            let drawdownFromPeak = currentValue / recentPeak - 1
            guard drawdownFromPeak < -max(guardConfig.drawdownThreshold, 0) else { return targetWeights }
            let scale = min(max(guardConfig.scale, 0), 1)
            return targetWeights.mapValues { $0 * scale }
        }

        for index in commonDates.indices.dropFirst() {
            var dailyReturn = 0.0
            for symbol in symbols {
                guard let weight = weightsBySymbol[symbol],
                      weight > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(index),
                      prices.indices.contains(index - 1),
                      prices[index - 1] > 0 else { continue }
                dailyReturn += weight * (prices[index] / prices[index - 1] - 1)
            }
            let investedWeight = weightsBySymbol.values.reduce(0) { $0 + max($1, 0) }
            let cashWeight = max(0, 1 - investedWeight)
            dailyReturn += cashWeight * CashYieldCNY.dailyReturn(on: commonDates[index - 1])
            value *= 1 + dailyReturn
            if !value.isFinite || value <= 0 {
                value = values.last ?? 100_000
            }

            if index == 1 || index % rebalanceSessions == 0 {
                let signalIndex = index - 1
                let baseWeights = Dictionary(uniqueKeysWithValues: advancedRotationTargetWeights(
                    symbols: symbols,
                    pricesBySymbol: pricesBySymbol,
                    maBySymbol: maBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    config: config
                ).map { ($0.symbol, $0.weight) })
                weightsBySymbol = applyPortfolioGuard(to: baseWeights, currentValue: value)
            }

            values.append(value)
            weightsByIndex.append(weightsBySymbol)
        }

        return AdvancedRotationSimulatedTrace(values: values, weightsByIndex: weightsByIndex)
    }

    private static func portfolioRollingReturn(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index),
              values.indices.contains(index - lookback),
              values[index - lookback] > 0 else { return nil }
        return values[index] / values[index - lookback] - 1
    }

    private static func portfolioRollingDrawdown(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index) else { return nil }
        let startIndex = max(0, index - lookback + 1)
        guard startIndex <= index,
              let recentPeak = values[startIndex...index].max(),
              recentPeak > 0 else { return nil }
        return values[index] / recentPeak - 1
    }

    private static func portfolioAnnualizedVolatility(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 1,
              values.indices.contains(index) else { return nil }
        let startIndex = max(1, index - lookback + 1)
        guard startIndex <= index else { return nil }
        let returns = (startIndex...index).compactMap { currentIndex -> Double? in
            guard values.indices.contains(currentIndex - 1),
                  values[currentIndex - 1] > 0,
                  values[currentIndex] > 0 else { return nil }
            return values[currentIndex] / values[currentIndex - 1] - 1
        }
        guard returns.count >= 5 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count)
        return sqrt(max(variance, 0)) * sqrt(252)
    }

    private static func applyGoldSatelliteOverlay(
        to rawWeights: [String: Double],
        signalIndex: Int,
        signalDate: Date,
        pricesBySymbol: [String: [Double]],
        portfolioValues: [Double]? = nil,
        config: AdvancedRotationConfig
    ) -> [String: Double] {
        guard let overlay = config.goldSatelliteOverlay else { return rawWeights }
        var finalWeights = rawWeights.mapValues { max($0, 0) * min(max(overlay.coreScale, 0), 1) }

        func priceMomentum(symbol: String, lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return Self.priceMomentum(values: prices, at: signalIndex, lookback: lookback)
        }

        func isAboveMovingAverage(symbol: String, period: Int) -> Bool {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let movingAverage = movingAverage(values: prices, period: period)[signalIndex] else { return false }
            return prices[signalIndex] >= movingAverage
        }

        func satellitePassesTrendFilter() -> Bool {
            guard let satelliteMomentum = priceMomentum(
                symbol: overlay.satelliteSymbol,
                lookback: overlay.satelliteMomentumLookbackSessions
            ),
                  satelliteMomentum > overlay.satelliteMomentumThreshold,
                  isAboveMovingAverage(symbol: overlay.satelliteSymbol, period: overlay.satelliteMovingAveragePeriod),
                  let satellitePrices = pricesBySymbol[overlay.satelliteSymbol],
                  let relativePrices = pricesBySymbol[overlay.relativeSymbol],
                  signalIndex - overlay.relativeLookbackSessions >= 0,
                  satellitePrices.indices.contains(signalIndex),
                  satellitePrices.indices.contains(signalIndex - overlay.relativeLookbackSessions),
                  relativePrices.indices.contains(signalIndex),
                  relativePrices.indices.contains(signalIndex - overlay.relativeLookbackSessions) else { return false }
            let previousSatellitePrice = satellitePrices[signalIndex - overlay.relativeLookbackSessions]
            let previousRelativePrice = relativePrices[signalIndex - overlay.relativeLookbackSessions]
            let currentSatellitePrice = satellitePrices[signalIndex]
            let currentRelativePrice = relativePrices[signalIndex]
            guard previousSatellitePrice > 0,
                  previousRelativePrice > 0,
                  currentSatellitePrice > 0,
                  currentRelativePrice > 0 else { return false }
            let relativeMomentum = (currentSatellitePrice / previousSatellitePrice) / (currentRelativePrice / previousRelativePrice) - 1
            return relativeMomentum > overlay.relativeMomentumThreshold
        }

        let canUseSatellite = satellitePassesTrendFilter()
        if canUseSatellite {
            finalWeights[overlay.satelliteSymbol, default: 0] += max(overlay.satelliteWeight, 0)
        }

        if let portfolioEquityBrake = overlay.portfolioEquityBrake,
           let portfolioValues,
           portfolioValues.indices.contains(signalIndex) {
            let lookbackSessions = max(portfolioEquityBrake.lookbackSessions, 1)
            let startIndex = max(0, signalIndex - lookbackSessions + 1)
            if startIndex <= signalIndex,
               let recentPeak = portfolioValues[startIndex...signalIndex].max(),
               recentPeak > 0 {
                let drawdownFromPeak = portfolioValues[signalIndex] / recentPeak - 1
                if drawdownFromPeak < -max(portfolioEquityBrake.drawdownThreshold, 0) {
                    let scale = min(max(portfolioEquityBrake.equityScale, 0), 1)
                    for symbol in portfolioEquityBrake.equitySymbols {
                        guard let originalWeight = finalWeights[symbol], originalWeight > 0 else { continue }
                        finalWeights[symbol] = originalWeight * scale
                    }
                }
            }
        }

        if let weakMonthEquityBrake = overlay.weakMonthEquityBrake,
           weakMonthEquityBrake.months.contains(Calendar.current.component(.month, from: signalDate)) {
            let equitySymbolsToBrake = weakMonthEquityBrake.equitySymbols.filter { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let momentum = priceMomentum(symbol: symbol, lookback: weakMonthEquityBrake.momentumLookbackSessions) else { return false }
                return momentum < weakMonthEquityBrake.momentumThreshold
            }
            let currentEquityExposure = weakMonthEquityBrake.equitySymbols.reduce(0.0) { $0 + max(finalWeights[$1] ?? 0, 0) }
            let maxEquityExposure = min(max(weakMonthEquityBrake.maxEquityExposure, 0), 1)
            if !equitySymbolsToBrake.isEmpty,
               currentEquityExposure > maxEquityExposure,
               currentEquityExposure > 0 {
                let scale = maxEquityExposure / currentEquityExposure
                for symbol in weakMonthEquityBrake.equitySymbols {
                    guard let originalWeight = finalWeights[symbol], originalWeight > 0 else { continue }
                    finalWeights[symbol] = originalWeight * scale
                }
            }
        }

        if let singleAssetExposureCap = overlay.singleAssetExposureCap {
            let cap = min(max(singleAssetExposureCap.maxWeight, 0), 1)
            for symbol in singleAssetExposureCap.symbols {
                guard let originalWeight = finalWeights[symbol], originalWeight > cap else { continue }
                finalWeights[symbol] = cap
            }
        }

        let totalExposure = finalWeights.reduce(0.0) { $0 + max($1.value, 0) }
        let maxTotalExposure = min(max(overlay.maxTotalExposure, 0), 1)
        if totalExposure > maxTotalExposure, totalExposure > 0 {
            let scale = maxTotalExposure / totalExposure
            finalWeights = finalWeights.mapValues { max($0, 0) * scale }
        }

        return finalWeights.filter { $0.value > 0.0001 }
    }

    private static func metaRotationTargetWeights(
        metaSwitch: AdvancedRotationMetaSwitch,
        stressIndex: Int,
        weightIndex: Int,
        tracesByMode: [AdvancedBacktestStrategyMode: AdvancedRotationSimulatedTrace]
    ) -> [String: Double]? {
        guard let defaultTrace = tracesByMode[metaSwitch.defaultMode],
              let defensiveTrace = tracesByMode[metaSwitch.defensiveMode],
              defaultTrace.values.indices.contains(stressIndex),
              defensiveTrace.weightsByIndex.indices.contains(weightIndex),
              defaultTrace.weightsByIndex.indices.contains(weightIndex) else { return nil }

        let recentReturn = portfolioRollingReturn(
            values: defaultTrace.values,
            at: stressIndex,
            lookback: metaSwitch.lossLookbackSessions
        ) ?? 0
        let recentVolatility = portfolioAnnualizedVolatility(
            values: defaultTrace.values,
            at: stressIndex,
            lookback: metaSwitch.volatilityLookbackSessions
        ) ?? 0
        let recentDrawdown = portfolioRollingDrawdown(
            values: defaultTrace.values,
            at: stressIndex,
            lookback: max(metaSwitch.drawdownLookbackSessions, metaSwitch.lossLookbackSessions, metaSwitch.volatilityLookbackSessions)
        ) ?? 0

        let lossStress = recentReturn <= -max(metaSwitch.lossThreshold, 0)
            && recentDrawdown < -max(metaSwitch.lossDrawdownThreshold, 0)
        let volatilityStress = recentVolatility >= max(metaSwitch.volatilityThreshold, 0)
            && recentReturn < 0
            && recentDrawdown < -max(metaSwitch.volatilityDrawdownThreshold, 0)
        let chosenTrace = (lossStress || volatilityStress) ? defensiveTrace : defaultTrace
        return chosenTrace.weightsByIndex[weightIndex]
    }

    private static func metaEngineTraces(
        for metaSwitch: AdvancedRotationMetaSwitch,
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date]
    ) -> [AdvancedBacktestStrategyMode: AdvancedRotationSimulatedTrace]? {
        guard let defaultConfig = advancedRotationConfig(for: metaSwitch.defaultMode),
              defaultConfig.metaSwitch == nil,
              let defensiveConfig = advancedRotationConfig(for: metaSwitch.defensiveMode),
              defensiveConfig.metaSwitch == nil else { return nil }
        return [
            metaSwitch.defaultMode: simulatedRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: defaultConfig
            ),
            metaSwitch.defensiveMode: simulatedRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: defensiveConfig
            ),
        ]
    }

    private static func multiPeriodMomentum(
        values: [Double],
        at index: Int,
        lookbacks: [Int],
        weights: [Double]
    ) -> Double? {
        guard !lookbacks.isEmpty else { return nil }
        var total = 0.0
        for (offset, lookback) in lookbacks.enumerated() {
            let weight = weights.indices.contains(offset) ? weights[offset] : 1
            guard let momentum = priceMomentum(values: values, at: index, lookback: lookback) else { return nil }
            total += momentum * weight
        }
        return total
    }

    private static func movingAverageValue(
        symbol: String,
        period: Int,
        at index: Int,
        pricesBySymbol: [String: [Double]]
    ) -> Double? {
        guard let prices = pricesBySymbol[symbol],
              prices.indices.contains(index) else { return nil }
        return movingAverage(values: prices, period: period)[index]
    }

    private static func canaryRegimeTargetWeights(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        volatilityBySymbol: [String: [Double?]],
        signalIndex: Int,
        regime: AdvancedRotationCanaryRegime,
        config: AdvancedRotationConfig
    ) -> [AdvancedRotationTargetWeight] {
        let availableSymbols = Set(symbols)
        let canaries = regime.canarySymbols.filter { availableSymbols.contains($0) }
        guard !canaries.isEmpty else { return [] }

        func multiMomentum(_ symbol: String) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return multiPeriodMomentum(
                values: prices,
                at: signalIndex,
                lookbacks: regime.momentumLookbacks,
                weights: regime.momentumWeights
            )
        }

        func isAboveMovingAverage(_ symbol: String, period: Int) -> Bool {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let movingAverage = movingAverageValue(
                    symbol: symbol,
                    period: period,
                    at: signalIndex,
                    pricesBySymbol: pricesBySymbol
                  ) else { return false }
            return prices[signalIndex] > movingAverage
        }

        let weakCanaryCount = canaries.reduce(0) { partial, symbol in
            let isWeak = (multiMomentum(symbol) ?? -Double.infinity) < regime.canaryMomentumThreshold
                || !isAboveMovingAverage(symbol, period: regime.canaryMovingAveragePeriod)
            return partial + (isWeak ? 1 : 0)
        }
        let riskOn = weakCanaryCount <= max(regime.weakAllowed, 0)
        var targetWeights: [String: Double] = [:]

        if riskOn {
            let ranked: [(score: Double, symbol: String)] = regime.offensiveSymbols.compactMap { symbol in
                guard availableSymbols.contains(symbol),
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex),
                      let momentum = multiMomentum(symbol),
                      momentum > regime.assetMomentumThreshold,
                      isAboveMovingAverage(symbol, period: regime.assetMovingAveragePeriod) else { return nil }
                let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex] ?? nil
                if let annualizedVolatility,
                   annualizedVolatility >= regime.equityVolatilityCap {
                    return nil
                }
                let volatility = max(annualizedVolatility ?? 0.18, 0.05)
                return (momentum / volatility, symbol)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
                return lhs.score > rhs.score
            }

            let selected = Array(ranked.prefix(max(config.topCount, 1)))
            if !selected.isEmpty {
                let offensiveWeight = max(regime.offensiveWeight, 0)
                if regime.equalWeight {
                    let eachWeight = offensiveWeight / Double(selected.count)
                    for item in selected {
                        targetWeights[item.symbol] = eachWeight
                    }
                } else {
                    let inverseVolatilityWeights = selected.map { item -> (symbol: String, value: Double) in
                        let volatility = max(volatilityBySymbol[item.symbol]?[signalIndex] ?? 0.18, 0.05)
                        return (item.symbol, 1 / volatility)
                    }
                    let totalRawWeight = inverseVolatilityWeights.reduce(0.0) { $0 + $1.value }
                    if totalRawWeight > 0 {
                        for item in inverseVolatilityWeights {
                            targetWeights[item.symbol] = offensiveWeight * item.value / totalRawWeight
                        }
                    }
                }
            }

            if availableSymbols.contains(regime.defensiveSymbol),
               let defensiveMomentum = multiMomentum(regime.defensiveSymbol),
               defensiveMomentum > regime.defensiveMomentumThreshold,
               isAboveMovingAverage(regime.defensiveSymbol, period: regime.defensiveMovingAveragePeriod) {
                targetWeights[regime.defensiveSymbol, default: 0] += max(regime.defensiveBallastWeight, 0)
            }
        } else if availableSymbols.contains(regime.defensiveSymbol),
                  let defensiveMomentum = multiMomentum(regime.defensiveSymbol),
                  defensiveMomentum > regime.defensiveMomentumThreshold,
                  isAboveMovingAverage(regime.defensiveSymbol, period: regime.defensiveMovingAveragePeriod) {
            targetWeights[regime.defensiveSymbol] = max(regime.defensiveOnlyWeight, 0)
        }

        let grossExposure = targetWeights.reduce(0.0) { $0 + max($1.value, 0) }
        let maxExposure = min(max(config.maxExposure, 0), 1)
        if grossExposure > maxExposure, grossExposure > 0 {
            targetWeights = targetWeights.mapValues { max($0, 0) * maxExposure / grossExposure }
        }

        return targetWeights.compactMap { item -> AdvancedRotationTargetWeight? in
            guard item.value > 0.0001,
                  let prices = pricesBySymbol[item.key],
                  prices.indices.contains(signalIndex) else { return nil }
            return AdvancedRotationTargetWeight(
                symbol: item.key,
                weight: item.value,
                momentum: multiMomentum(item.key) ?? 0,
                annualizedVolatility: volatilityBySymbol[item.key]?[signalIndex] ?? nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.weight == rhs.weight { return lhs.symbol < rhs.symbol }
            return lhs.weight > rhs.weight
        }
    }

    private static func advancedRotationTargetWeights(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        signalIndex: Int,
        signalDate: Date? = nil,
        config: AdvancedRotationConfig
    ) -> [AdvancedRotationTargetWeight] {
        guard signalIndex - config.lookbackSessions >= 0 else { return [] }
        if let canaryRegime = config.canaryRegime {
            return canaryRegimeTargetWeights(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                regime: canaryRegime,
                config: config
            )
        }

        let ranked: [(score: Double, momentum: Double, symbol: String)] = symbols.compactMap { symbol in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex) else { return nil }
            let previousPrice = prices[signalIndex - config.lookbackSessions]
            guard previousPrice > 0 else { return nil }
            let momentum = prices[signalIndex] / previousPrice - 1
            var rankingScore = momentum

            switch config.signal {
            case .maMomentum:
                guard momentum > config.minMomentumThreshold,
                      let ma = maBySymbol[symbol]?[signalIndex],
                      prices[signalIndex] >= ma else { return nil }
            case .lowVolMomentum:
                guard momentum > config.minMomentumThreshold else { return nil }
                if let maxSignalAnnualVolatility = config.maxSignalAnnualVolatility {
                    guard let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex],
                          annualizedVolatility <= maxSignalAnnualVolatility else { return nil }
                }
            case .guardedDualMomentum:
                guard let secondaryLookbackSessions = config.secondaryLookbackSessions,
                      let secondaryMomentum = priceMomentum(values: prices, at: signalIndex, lookback: secondaryLookbackSessions),
                      let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex],
                      let drawdownLookback = config.signalDrawdownLookbackSessions,
                      let drawdownFromHigh = rollingDrawdownFromHigh(values: prices, at: signalIndex, period: drawdownLookback) else { return nil }
                guard momentum > config.minMomentumThreshold,
                      secondaryMomentum > (config.secondaryMomentumThreshold ?? config.minMomentumThreshold) else { return nil }
                if let maxSignalAnnualVolatility = config.maxSignalAnnualVolatility {
                    guard annualizedVolatility <= maxSignalAnnualVolatility else { return nil }
                }
                if let maxSignalDrawdown = config.maxSignalDrawdown {
                    guard drawdownFromHigh >= -max(maxSignalDrawdown, 0) else { return nil }
                }

                let rsi = config.rsiLookbackSessions.flatMap { relativeStrengthIndex(values: prices, at: signalIndex, period: $0) }
                let donchianPosition = config.donchianLookbackSessions.flatMap { donchianRangePosition(values: prices, at: signalIndex, period: $0) }

                rankingScore = momentum * 1.2
                    + secondaryMomentum * 0.5
                    + max(drawdownFromHigh, -0.5) * 0.4
                    + (1.0 / max(annualizedVolatility, 0.01)) * 0.015
                if let rsi {
                    rankingScore += (1 - abs(rsi - 62) / 62) * 0.05
                }
                if let donchianPosition {
                    rankingScore += donchianPosition * 0.08
                }
                if symbol == "gold_cny" {
                    rankingScore += 0.03
                }
            case .drawdownReentry:
                guard let secondaryLookbackSessions = config.secondaryLookbackSessions,
                      let secondaryMomentum = priceMomentum(values: prices, at: signalIndex, lookback: secondaryLookbackSessions),
                      let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex],
                      let drawdownLookback = config.signalDrawdownLookbackSessions,
                      let drawdownFromHigh = rollingDrawdownFromHigh(values: prices, at: signalIndex, period: drawdownLookback) else { return nil }
                if let maxSignalDrawdown = config.maxSignalDrawdown {
                    guard drawdownFromHigh >= -max(maxSignalDrawdown, 0) else { return nil }
                }

                let rsi = config.rsiLookbackSessions.flatMap { relativeStrengthIndex(values: prices, at: signalIndex, period: $0) }
                let momentumPass = momentum > config.minMomentumThreshold
                let rsiPass = rsi.map { value in
                    let lower = config.minimumRSI ?? 0
                    return value >= lower
                } ?? false
                guard momentumPass || rsiPass else { return nil }

                let donchianPosition = config.donchianLookbackSessions.flatMap { donchianRangePosition(values: prices, at: signalIndex, period: $0) }

                rankingScore = momentum * 1.2
                    + secondaryMomentum * 0.5
                    + max(drawdownFromHigh, -0.5) * 0.4
                    + (1.0 / max(annualizedVolatility, 0.01)) * 0.015
                if let rsi {
                    rankingScore += (1 - abs(rsi - 62) / 62) * 0.05
                }
                if let donchianPosition {
                    rankingScore += donchianPosition * 0.08
                    if let minimumDonchianPosition = config.minimumDonchianPosition,
                       donchianPosition < minimumDonchianPosition {
                        rankingScore -= 0.03
                    }
                }
                if symbol == "gold_cny" {
                    rankingScore += 0.03
                }
            }

            return (rankingScore, momentum, symbol)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
            return lhs.score > rhs.score
        }

        var baseWeights: [String: Double] = [:]
        if let fixedBaseWeightsBySymbol = config.fixedBaseWeightsBySymbol {
            let fixedCandidates = Array(ranked.prefix(max(config.topCount, 1)))
            for item in fixedCandidates {
                let fixedWeight = max(fixedBaseWeightsBySymbol[item.symbol] ?? 0, 0)
                if fixedWeight > 0 {
                    baseWeights[item.symbol] = fixedWeight
                }
            }
            let totalFixedWeight = baseWeights.reduce(0.0) { $0 + $1.value }
            guard totalFixedWeight > 0 else { return [] }
            if config.renormalizesFixedBaseWeights {
                baseWeights = baseWeights.mapValues { $0 / totalFixedWeight }
            }
        } else {
            let sortedCandidates: [(score: Double, momentum: Double, symbol: String)]
            if config.weighting == .lowVolMomentumInverseVolatility {
                sortedCandidates = ranked.sorted { lhs, rhs in
                    let lhsVolatility = max(volatilityBySymbol[lhs.symbol]?[signalIndex] ?? 9, 0.01)
                    let rhsVolatility = max(volatilityBySymbol[rhs.symbol]?[signalIndex] ?? 9, 0.01)
                    let lhsScore = lhs.momentum / lhsVolatility
                    let rhsScore = rhs.momentum / rhsVolatility
                    if lhsScore == rhsScore { return lhs.symbol < rhs.symbol }
                    return lhsScore > rhsScore
                }
            } else {
                sortedCandidates = ranked
            }

            let picks = Array(sortedCandidates.prefix(max(config.topCount, 1)))
            guard !picks.isEmpty else { return [] }

            switch config.weighting {
            case .winner:
                baseWeights[picks[0].symbol] = 1
            case .momentumInverseVolatility:
                var rawWeights: [(symbol: String, value: Double)] = []
                for pick in picks {
                    let annualizedVolatility = max(volatilityBySymbol[pick.symbol]?[signalIndex] ?? 9, 0.01)
                    rawWeights.append((pick.symbol, max(pick.momentum, 0.0001) / annualizedVolatility))
                }
                let totalRawWeight = rawWeights.reduce(0.0) { $0 + $1.value }
                guard totalRawWeight > 0 else { return [] }
                for rawWeight in rawWeights {
                    baseWeights[rawWeight.symbol] = rawWeight.value / totalRawWeight
                }
            case .lowVolMomentumInverseVolatility:
                var rawWeights: [(symbol: String, value: Double)] = []
                for pick in picks {
                    let annualizedVolatility = max(volatilityBySymbol[pick.symbol]?[signalIndex] ?? 9, 0.01)
                    rawWeights.append((pick.symbol, 1 / annualizedVolatility))
                }
                let totalRawWeight = rawWeights.reduce(0.0) { $0 + $1.value }
                guard totalRawWeight > 0 else { return [] }
                for rawWeight in rawWeights {
                    baseWeights[rawWeight.symbol] = rawWeight.value / totalRawWeight
                }
            case .coreSatelliteWinner:
                if let coreWeightsBySymbol = config.coreWeightsBySymbol {
                    for item in ranked where coreWeightsBySymbol[item.symbol] != nil {
                        let coreWeight = max(coreWeightsBySymbol[item.symbol] ?? 0, 0)
                        if coreWeight > 0 {
                            baseWeights[item.symbol] = coreWeight
                        }
                    }
                }

                let satelliteCandidates = ranked.filter { config.satelliteSymbols.contains($0.symbol) }
                if let satelliteWinner = satelliteCandidates.first {
                    let satelliteWeight = max(config.satelliteWeight, 0)
                    if satelliteWeight > 0 {
                        baseWeights[satelliteWinner.symbol, default: 0] += satelliteWeight
                    }
                }

                guard !baseWeights.isEmpty else { return [] }
            }
        }

        var exposure = min(max(config.maxExposure, 0), 1)
        if let targetAnnualVolatility = config.targetAnnualVolatility {
            let weightedVolatility: Double
            if config.weighting == .lowVolMomentumInverseVolatility {
                let squaredWeightedVolatility = baseWeights.reduce(0.0) { partial, item in
                    let symbol = item.key
                    let weight = item.value
                    let annualizedVolatility = max(volatilityBySymbol[symbol]?[signalIndex] ?? 9, 0.01)
                    return partial + pow(weight * annualizedVolatility, 2)
                }
                weightedVolatility = sqrt(squaredWeightedVolatility)
            } else {
                weightedVolatility = baseWeights.reduce(0.0) { partial, item in
                    let symbol = item.key
                    let weight = item.value
                    let annualizedVolatility = max(volatilityBySymbol[symbol]?[signalIndex] ?? 9, 0.01)
                    return partial + weight * annualizedVolatility
                }
            }
            exposure = min(exposure, targetAnnualVolatility / max(weightedVolatility, 0.01))
        }

        var finalWeights = baseWeights.mapValues { $0 * exposure }
        var didUseDecelerationLock = false

        func canRedeploy(to symbol: String) -> Bool {
            guard let redeployPrices = pricesBySymbol[symbol],
                  redeployPrices.indices.contains(signalIndex),
                  let redeployMA = movingAverage(values: redeployPrices, period: 60)[signalIndex],
                  let redeployMomentum = priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60) else { return false }
            return redeployPrices[signalIndex] >= redeployMA && redeployMomentum > -0.02
        }

        func capTotalExposure(maxExposure: Double, redeploySymbol: String?, redeployRatio: Double) {
            let currentExposure = finalWeights.reduce(0.0) { $0 + max($1.value, 0) }
            let normalizedMaxExposure = min(max(maxExposure, 0), 1)
            guard currentExposure > normalizedMaxExposure, currentExposure > 0 else { return }
            let scale = normalizedMaxExposure / currentExposure
            var removedWeight = 0.0
            for item in finalWeights {
                let originalWeight = max(item.value, 0)
                let scaledWeight = originalWeight * scale
                finalWeights[item.key] = scaledWeight
                removedWeight += originalWeight - scaledWeight
            }
            if let redeploySymbol,
               canRedeploy(to: redeploySymbol) {
                finalWeights[redeploySymbol, default: 0] += removedWeight * min(max(redeployRatio, 0), 1)
            }
        }

        if let pairConfirmationGuard = config.pairConfirmationGuard {
            let isPairBroken = pairConfirmationGuard.peerBySymbol.contains { item in
                let symbol = item.key
                let peer = item.value
                guard (finalWeights[symbol] ?? 0) > 0,
                      let peerPrices = pricesBySymbol[peer],
                      peerPrices.indices.contains(signalIndex) else { return false }
                let peerMomentum = priceMomentum(
                    values: peerPrices,
                    at: signalIndex,
                    lookback: pairConfirmationGuard.peerMomentumLookbackSessions
                )
                let peerDrawdown = rollingDrawdownFromHigh(
                    values: peerPrices,
                    at: signalIndex,
                    period: pairConfirmationGuard.peerDrawdownLookbackSessions
                )
                return (peerMomentum ?? 0) < pairConfirmationGuard.peerMomentumThreshold
                    || (peerDrawdown ?? 0) <= -max(pairConfirmationGuard.peerDrawdownThreshold, 0)
            }
            if isPairBroken {
                capTotalExposure(
                    maxExposure: pairConfirmationGuard.maxExposure,
                    redeploySymbol: pairConfirmationGuard.redeploySymbol,
                    redeployRatio: pairConfirmationGuard.redeployRatio
                )
            }
        }

        if let overheatBrake = config.overheatBrake {
            let isOverheated = overheatBrake.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex),
                      let heatMomentum = priceMomentum(values: prices, at: signalIndex, lookback: overheatBrake.momentumLookbackSessions),
                      let rsi = relativeStrengthIndex(values: prices, at: signalIndex, period: overheatBrake.rsiLookbackSessions),
                      let donchianPosition = donchianRangePosition(values: prices, at: signalIndex, period: overheatBrake.donchianLookbackSessions) else { return false }
                return heatMomentum > overheatBrake.momentumThreshold
                    && rsi > overheatBrake.rsiThreshold
                    && donchianPosition > overheatBrake.donchianPositionThreshold
            }

            if isOverheated {
                let currentExposure = finalWeights.reduce(0.0) { $0 + max($1.value, 0) }
                let maxExposure = min(max(overheatBrake.maxExposure, 0), 1)
                if currentExposure > maxExposure, currentExposure > 0 {
                    let scale = maxExposure / currentExposure
                    var removedWeight = 0.0
                    for item in finalWeights {
                        let originalWeight = max(item.value, 0)
                        let scaledWeight = originalWeight * scale
                        finalWeights[item.key] = scaledWeight
                        removedWeight += originalWeight - scaledWeight
                    }

                    if let redeploySymbol = overheatBrake.redeploySymbol,
                       let redeployPrices = pricesBySymbol[redeploySymbol],
                       redeployPrices.indices.contains(signalIndex),
                       let redeployMA = movingAverage(values: redeployPrices, period: 60)[signalIndex],
                       let redeployMomentum = priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60),
                       redeployPrices[signalIndex] >= redeployMA,
                       redeployMomentum > -0.02 {
                        let redeployRatio = min(max(overheatBrake.redeployRatio, 0), 1)
                        finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                    }
                }
            }
        }

        if let decelerationLock = config.decelerationLock {
            let isDeceleratingAtHighZone = decelerationLock.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex),
                      let shortMomentum = priceMomentum(values: prices, at: signalIndex, lookback: decelerationLock.shortMomentumLookbackSessions),
                      let rsi = relativeStrengthIndex(values: prices, at: signalIndex, period: decelerationLock.rsiLookbackSessions),
                      let donchianPosition = donchianRangePosition(values: prices, at: signalIndex, period: decelerationLock.donchianLookbackSessions) else { return false }
                return donchianPosition > decelerationLock.donchianPositionThreshold
                    && rsi > decelerationLock.rsiThreshold
                    && shortMomentum < decelerationLock.shortMomentumUpperThreshold
            }

            if isDeceleratingAtHighZone {
                didUseDecelerationLock = true
                let currentExposure = finalWeights.reduce(0.0) { $0 + max($1.value, 0) }
                let maxExposure = min(max(decelerationLock.maxExposure, 0), 1)
                if currentExposure > maxExposure, currentExposure > 0 {
                    let scale = maxExposure / currentExposure
                    var removedWeight = 0.0
                    for item in finalWeights {
                        let originalWeight = max(item.value, 0)
                        let scaledWeight = originalWeight * scale
                        finalWeights[item.key] = scaledWeight
                        removedWeight += originalWeight - scaledWeight
                    }

                    if let redeploySymbol = decelerationLock.redeploySymbol,
                       let redeployPrices = pricesBySymbol[redeploySymbol],
                       redeployPrices.indices.contains(signalIndex),
                       let redeployMA = movingAverage(values: redeployPrices, period: 60)[signalIndex],
                       let redeployMomentum = priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60),
                       redeployPrices[signalIndex] >= redeployMA,
                       redeployMomentum > -0.02 {
                        let redeployRatio = min(max(decelerationLock.redeployRatio, 0), 1)
                        finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                    }
                }
            }
        }

        if !didUseDecelerationLock, let shortWeaknessLock = config.shortWeaknessLock {
            let isShortWeaknessTriggered = shortWeaknessLock.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      let relativePrices = pricesBySymbol[shortWeaknessLock.relativeSymbol],
                      signalIndex - shortWeaknessLock.relativeLookbackSessions >= 0,
                      prices.indices.contains(signalIndex),
                      prices.indices.contains(signalIndex - shortWeaknessLock.relativeLookbackSessions),
                      relativePrices.indices.contains(signalIndex),
                      relativePrices.indices.contains(signalIndex - shortWeaknessLock.relativeLookbackSessions),
                      let shortMomentum = priceMomentum(values: prices, at: signalIndex, lookback: shortWeaknessLock.shortMomentumLookbackSessions) else { return false }

                let previousAssetPrice = prices[signalIndex - shortWeaknessLock.relativeLookbackSessions]
                let previousRelativePrice = relativePrices[signalIndex - shortWeaknessLock.relativeLookbackSessions]
                let currentAssetPrice = prices[signalIndex]
                let currentRelativePrice = relativePrices[signalIndex]
                guard previousAssetPrice > 0,
                      previousRelativePrice > 0,
                      currentAssetPrice > 0,
                      currentRelativePrice > 0 else { return false }

                let relativeMomentum = (currentAssetPrice / previousAssetPrice) / (currentRelativePrice / previousRelativePrice) - 1
                return shortMomentum < shortWeaknessLock.shortMomentumThreshold
                    && relativeMomentum < shortWeaknessLock.relativeMomentumThreshold
            }

            if isShortWeaknessTriggered {
                let currentExposure = finalWeights.reduce(0.0) { $0 + max($1.value, 0) }
                let maxExposure = min(max(shortWeaknessLock.maxExposure, 0), 1)
                if currentExposure > maxExposure, currentExposure > 0 {
                    let scale = maxExposure / currentExposure
                    var removedWeight = 0.0
                    for item in finalWeights {
                        let originalWeight = max(item.value, 0)
                        let scaledWeight = originalWeight * scale
                        finalWeights[item.key] = scaledWeight
                        removedWeight += originalWeight - scaledWeight
                    }

                    if let redeploySymbol = shortWeaknessLock.redeploySymbol,
                       let redeployPrices = pricesBySymbol[redeploySymbol],
                       redeployPrices.indices.contains(signalIndex),
                       let redeployMA = movingAverage(values: redeployPrices, period: 60)[signalIndex],
                       let redeployMomentum = priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60),
                       redeployPrices[signalIndex] >= redeployMA,
                       redeployMomentum > -0.02 {
                        let redeployRatio = min(max(shortWeaknessLock.redeployRatio, 0), 1)
                        finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                    }
                }
            }
        }

        if let heldBreakdownLock = config.heldBreakdownLock {
            let isHeldBreakdownTriggered = heldBreakdownLock.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      let relativePrices = pricesBySymbol[heldBreakdownLock.relativeSymbol],
                      prices.indices.contains(signalIndex),
                      relativePrices.indices.contains(signalIndex),
                      let donchianPosition = donchianRangePosition(
                        values: prices,
                        at: signalIndex,
                        period: heldBreakdownLock.donchianLookbackSessions
                      ),
                      donchianPosition > heldBreakdownLock.donchianPositionThreshold else { return false }

                var signalCount = 0
                if let drawdown = rollingDrawdownFromHigh(
                    values: prices,
                    at: signalIndex,
                    period: heldBreakdownLock.drawdownLookbackSessions
                ), drawdown <= -max(heldBreakdownLock.drawdownThreshold, 0) {
                    signalCount += 1
                }
                if let shortMomentum = priceMomentum(
                    values: prices,
                    at: signalIndex,
                    lookback: heldBreakdownLock.shortMomentumLookbackSessions
                ), shortMomentum < heldBreakdownLock.shortMomentumThreshold {
                    signalCount += 1
                }
                if let mediumMomentum = priceMomentum(
                    values: prices,
                    at: signalIndex,
                    lookback: heldBreakdownLock.mediumMomentumLookbackSessions
                ), mediumMomentum < heldBreakdownLock.mediumMomentumThreshold {
                    signalCount += 1
                }
                if signalIndex - heldBreakdownLock.relativeLookbackSessions >= 0,
                   prices.indices.contains(signalIndex - heldBreakdownLock.relativeLookbackSessions),
                   relativePrices.indices.contains(signalIndex - heldBreakdownLock.relativeLookbackSessions) {
                    let previousAssetPrice = prices[signalIndex - heldBreakdownLock.relativeLookbackSessions]
                    let previousRelativePrice = relativePrices[signalIndex - heldBreakdownLock.relativeLookbackSessions]
                    let currentAssetPrice = prices[signalIndex]
                    let currentRelativePrice = relativePrices[signalIndex]
                    if previousAssetPrice > 0,
                       previousRelativePrice > 0,
                       currentAssetPrice > 0,
                       currentRelativePrice > 0 {
                        let relativeMomentum = (currentAssetPrice / previousAssetPrice) / (currentRelativePrice / previousRelativePrice) - 1
                        if relativeMomentum < heldBreakdownLock.relativeMomentumThreshold {
                            signalCount += 1
                        }
                    }
                }

                return signalCount >= max(heldBreakdownLock.requiredSignals, 1)
            }
            if isHeldBreakdownTriggered {
                capTotalExposure(
                    maxExposure: heldBreakdownLock.maxExposure,
                    redeploySymbol: heldBreakdownLock.redeploySymbol,
                    redeployRatio: heldBreakdownLock.redeployRatio
                )
            }
        }

        if let fastCrashBrake = config.fastCrashBrake {
            let lookbackSessions = max(fastCrashBrake.lookbackSessions, 1)
            let isCrashTriggered = fastCrashBrake.triggerSymbols.contains { symbol in
                guard let prices = pricesBySymbol[symbol],
                      signalIndex - lookbackSessions >= 0,
                      prices.indices.contains(signalIndex),
                      prices.indices.contains(signalIndex - lookbackSessions) else { return false }
                let previousPrice = prices[signalIndex - lookbackSessions]
                guard previousPrice > 0 else { return false }
                let shortTermReturn = prices[signalIndex] / previousPrice - 1
                return shortTermReturn <= -max(fastCrashBrake.drawdownThreshold, 0)
            }

            if isCrashTriggered {
                let scale = min(max(fastCrashBrake.scale, 0), 1)
                var removedWeight = 0.0
                for symbol in fastCrashBrake.scaledSymbols {
                    let originalWeight = finalWeights[symbol] ?? 0
                    guard originalWeight > 0 else { continue }
                    let scaledWeight = originalWeight * scale
                    finalWeights[symbol] = scaledWeight
                    removedWeight += originalWeight - scaledWeight
                }

                if let redeploySymbol = fastCrashBrake.redeploySymbol,
                   ranked.contains(where: { $0.symbol == redeploySymbol }) {
                    let redeployRatio = min(max(fastCrashBrake.redeployRatio, 0), 1)
                    finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                }
            }
        }

        if let volatilityBrake = config.volatilityBrake,
           let triggerVolatility = volatilityBySymbol[volatilityBrake.triggerSymbol]?[signalIndex],
           triggerVolatility > volatilityBrake.threshold {
            let scale = min(max(volatilityBrake.scale, 0), 1)
            var removedWeight = 0.0
            for symbol in volatilityBrake.scaledSymbols {
                let originalWeight = finalWeights[symbol] ?? 0
                guard originalWeight > 0 else { continue }
                let scaledWeight = originalWeight * scale
                finalWeights[symbol] = scaledWeight
                removedWeight += originalWeight - scaledWeight
            }

            if let redeploySymbol = volatilityBrake.redeploySymbol,
               ranked.contains(where: { $0.symbol == redeploySymbol }) {
                let redeployRatio = min(max(volatilityBrake.redeployRatio, 0), 1)
                finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
            }
        }

        if let drawdownLadderBrake = config.drawdownLadderBrake {
            var shouldUseHardScale = false
            var shouldUseSoftScale = false
            for item in drawdownLadderBrake.triggerThresholdRatiosBySymbol {
                let symbol = item.key
                let thresholdRatio = max(item.value, 0.0001)
                guard let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex) else { continue }
                let startIndex = max(0, signalIndex - max(drawdownLadderBrake.lookbackSessions, 1) + 1)
                guard startIndex <= signalIndex,
                      let recentHigh = prices[startIndex...signalIndex].max(),
                      recentHigh > 0 else { continue }
                let drawdownFromHigh = prices[signalIndex] / recentHigh - 1
                if drawdownFromHigh <= -drawdownLadderBrake.hardDrawdown * thresholdRatio {
                    shouldUseHardScale = true
                } else if drawdownFromHigh <= -drawdownLadderBrake.softDrawdown * thresholdRatio {
                    shouldUseSoftScale = true
                }
            }

            let scale: Double?
            if shouldUseHardScale {
                scale = drawdownLadderBrake.hardScale
            } else if shouldUseSoftScale {
                scale = drawdownLadderBrake.softScale
            } else {
                scale = nil
            }

            if let scale {
                let normalizedScale = min(max(scale, 0), 1)
                var removedWeight = 0.0
                for symbol in drawdownLadderBrake.scaledSymbols {
                    let originalWeight = finalWeights[symbol] ?? 0
                    guard originalWeight > 0 else { continue }
                    let scaledWeight = originalWeight * normalizedScale
                    finalWeights[symbol] = scaledWeight
                    removedWeight += originalWeight - scaledWeight
                }

                if let redeploySymbol = drawdownLadderBrake.redeploySymbol,
                   ranked.contains(where: { $0.symbol == redeploySymbol }) {
                    let redeployRatio = min(max(drawdownLadderBrake.redeployRatio, 0), 1)
                    finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                }
            }
        }

        if let monthlyExposureBrake = config.monthlyExposureBrake,
           let signalDate,
           monthlyExposureBrake.months.contains(Calendar.current.component(.month, from: signalDate)) {
            let normalizedScale = min(max(monthlyExposureBrake.scale, 0), 1)
            var removedWeight = 0.0
            for symbol in monthlyExposureBrake.scaledSymbols {
                let originalWeight = finalWeights[symbol] ?? 0
                guard originalWeight > 0 else { continue }
                let scaledWeight = originalWeight * normalizedScale
                finalWeights[symbol] = scaledWeight
                removedWeight += originalWeight - scaledWeight
            }

            if let redeploySymbol = monthlyExposureBrake.redeploySymbol,
               ranked.contains(where: { $0.symbol == redeploySymbol }) {
                let redeployRatio = min(max(monthlyExposureBrake.redeployRatio, 0), 1)
                finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
            }
        }

        return finalWeights.compactMap { symbol, weight in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex) else { return nil }
            let momentum = ranked.first(where: { $0.symbol == symbol })?.momentum
                ?? priceMomentum(values: prices, at: signalIndex, lookback: config.lookbackSessions)
                ?? 0
            return AdvancedRotationTargetWeight(
                symbol: symbol,
                weight: weight,
                momentum: momentum,
                annualizedVolatility: volatilityBySymbol[symbol]?[signalIndex] ?? nil
            )
        }
    }

    private static func runAdvancedRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        config: AdvancedRotationConfig
    ) -> AdvancedBacktestReport? {
        let preparedSeries: [PreparedAdvancedSeries] = assetInputs.compactMap { input -> PreparedAdvancedSeries? in
            guard input.assetSeries != nil,
                  !input.assetOption.requiresHistoricalFX || input.fxSeries != nil else { return nil }
            return preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard preparedSeries.count >= 2 else { return nil }

        let normalizedInitialCash = max(initialCash, 0)
        let normalizedFeeRate = max(settings.feeRate, 0) / 100
        let normalizedSlippageRate = max(settings.slippageRate, 0) / 100
        let normalizedRebalanceBand = max(config.rebalanceBand, 0)
        guard normalizedInitialCash > 0 else { return nil }

        let aligned = alignedRotationPriceSeries(from: preparedSeries)
        let commonDates = aligned.dates
        let pricesBySymbol = aligned.pricesBySymbol
        let optionBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, $0.assetOption) })
        let symbols = preparedSeries.map { $0.assetOption.symbol }
        let tradableSymbols = symbols.filter { !config.signalOnlySymbols.contains($0) }
        guard !tradableSymbols.isEmpty else { return nil }
        let maxMAFilterPeriod = max(config.maFilterPeriodBySymbol?.values.max() ?? config.maFilterPeriod, config.maFilterPeriod)
        let fastCrashBrakeLookback = config.fastCrashBrake?.lookbackSessions ?? 0
        let overheatBrakeWarmup = max(
            config.overheatBrake?.momentumLookbackSessions ?? 0,
            config.overheatBrake?.rsiLookbackSessions ?? 0,
            config.overheatBrake?.donchianLookbackSessions ?? 0
        )
        let decelerationLockWarmup = max(
            config.decelerationLock?.shortMomentumLookbackSessions ?? 0,
            config.decelerationLock?.rsiLookbackSessions ?? 0,
            config.decelerationLock?.donchianLookbackSessions ?? 0
        )
        let shortWeaknessLockWarmup = max(
            config.shortWeaknessLock?.shortMomentumLookbackSessions ?? 0,
            config.shortWeaknessLock?.relativeLookbackSessions ?? 0
        )
        let pairConfirmationGuardWarmup = max(
            config.pairConfirmationGuard?.peerMomentumLookbackSessions ?? 0,
            config.pairConfirmationGuard?.peerDrawdownLookbackSessions ?? 0
        )
        let heldBreakdownLockWarmup = max(
            config.heldBreakdownLock?.drawdownLookbackSessions ?? 0,
            config.heldBreakdownLock?.shortMomentumLookbackSessions ?? 0,
            config.heldBreakdownLock?.mediumMomentumLookbackSessions ?? 0,
            config.heldBreakdownLock?.relativeLookbackSessions ?? 0,
            config.heldBreakdownLock?.donchianLookbackSessions ?? 0
        )
        let metaSwitchWarmup = max(
            config.metaSwitch?.lossLookbackSessions ?? 0,
            config.metaSwitch?.volatilityLookbackSessions ?? 0,
            config.metaSwitch?.drawdownLookbackSessions ?? 0
        )
        let overlayPortfolioBrakeWarmup = config.goldSatelliteOverlay?.portfolioEquityBrake?.lookbackSessions ?? 0
        let canaryRegimeWarmup = max(
            config.canaryRegime?.momentumLookbacks.max() ?? 0,
            config.canaryRegime?.canaryMovingAveragePeriod ?? 0,
            config.canaryRegime?.assetMovingAveragePeriod ?? 0,
            config.canaryRegime?.defensiveMovingAveragePeriod ?? 0
        )
        let extraIndicatorWarmup = [
            config.secondaryLookbackSessions ?? 0,
            config.signalDrawdownLookbackSessions ?? 0,
            config.rsiLookbackSessions ?? 0,
            config.donchianLookbackSessions ?? 0,
            overheatBrakeWarmup,
            decelerationLockWarmup,
            shortWeaknessLockWarmup,
            pairConfirmationGuardWarmup,
            heldBreakdownLockWarmup,
            config.portfolioDrawdownGuard?.lookbackSessions ?? 0,
            metaSwitchWarmup,
            overlayPortfolioBrakeWarmup,
            canaryRegimeWarmup,
        ].max() ?? 0
        let minimumWarmup = ([
            config.lookbackSessions,
            maxMAFilterPeriod,
            config.volatilityLookbackSessions,
            fastCrashBrakeLookback,
            extraIndicatorWarmup,
        ].max() ?? 0) + 1
        guard commonDates.count > minimumWarmup else { return nil }

        var maBySymbol: [String: [Double?]] = [:]
        var volatilityBySymbol: [String: [Double?]] = [:]
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            let maFilterPeriod = config.maFilterPeriodBySymbol?[symbol] ?? config.maFilterPeriod
            maBySymbol[symbol] = movingAverage(values: prices, period: maFilterPeriod)
            volatilityBySymbol[symbol] = rollingAnnualizedVolatility(values: prices, period: config.volatilityLookbackSessions)
        }

        let metaTracesByMode = config.metaSwitch.flatMap { metaSwitch in
            metaEngineTraces(
                for: metaSwitch,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates
            )
        }
        if config.metaSwitch != nil, metaTracesByMode == nil {
            return nil
        }

        var cash = normalizedInitialCash
        var unitsBySymbol: [String: Double] = Dictionary(uniqueKeysWithValues: tradableSymbols.map { ($0, 0.0) })
        var averageCostBySymbol: [String: Double] = Dictionary(uniqueKeysWithValues: tradableSymbols.map { ($0, 0.0) })
        var entryDateBySymbol: [String: Date] = [:]
        var heldSymbols = Set<String>()
        var points: [BacktestSeriesPoint] = []
        var benchmarkPoints: [BacktestSeriesPoint] = []
        var trades: [AdvancedBacktestTrade] = []
        var exposureSum = 0.0
        var exposureSamples = 0
        var cashRatioSum = 0.0
        var cashRatioSamples = 0
        var cashInterestEarned = 0.0
        var cashAnnualRateSum = 0.0
        var cashAnnualRateSamples = 0

        func portfolioValue(at index: Int) -> Double {
            cash + tradableSymbols.reduce(0.0) { partial, symbol in
                partial + (unitsBySymbol[symbol] ?? 0) * (pricesBySymbol[symbol]?[index] ?? 0)
            }
        }

        func targetWeights(at signalIndex: Int, traceIndex: Int) -> [String: Double] {
            if let metaSwitch = config.metaSwitch,
               let metaTracesByMode,
               let rawMetaWeights = metaRotationTargetWeights(
                metaSwitch: metaSwitch,
                stressIndex: signalIndex,
                weightIndex: traceIndex,
                tracesByMode: metaTracesByMode
               ) {
                return applyGoldSatelliteOverlay(
                    to: rawMetaWeights,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    pricesBySymbol: pricesBySymbol,
                    portfolioValues: points.map(\.portfolioValue),
                    config: config
                )
                .filter { !config.signalOnlySymbols.contains($0.key) }
            }

            return Dictionary(uniqueKeysWithValues: advancedRotationTargetWeights(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                config: config
            )
            .filter { !config.signalOnlySymbols.contains($0.symbol) }
            .map { ($0.symbol, $0.weight) })
        }

        func applyPortfolioDrawdownGuard(
            to targetWeights: [String: Double],
            currentValue: Double
        ) -> [String: Double] {
            guard let guardConfig = config.portfolioDrawdownGuard,
                  !targetWeights.isEmpty,
                  !points.isEmpty else { return targetWeights }
            let lookbackSessions = max(guardConfig.lookbackSessions, 1)
            var recentValues = points.suffix(lookbackSessions).map(\.portfolioValue)
            recentValues.append(currentValue)
            guard let recentPeak = recentValues.max(), recentPeak > 0 else { return targetWeights }
            let drawdownFromPeak = currentValue / recentPeak - 1
            guard drawdownFromPeak < -max(guardConfig.drawdownThreshold, 0) else { return targetWeights }
            let scale = min(max(guardConfig.scale, 0), 1)
            return targetWeights.mapValues { $0 * scale }
        }

        var lastRebalanceIndex = Int.min / 2

        for index in commonDates.indices {
            let date = commonDates[index]

            if index > 0 {
                let annualCashRate = CashYieldCNY.annualRate(on: commonDates[index - 1])
                cashAnnualRateSum += annualCashRate
                cashAnnualRateSamples += 1
                if cash > 0 {
                    let cashInterest = cash * CashYieldCNY.dailyReturn(fromAnnualRate: annualCashRate)
                    if cashInterest.isFinite, cashInterest > 0 {
                        cash += cashInterest
                        cashInterestEarned += cashInterest
                    }
                }
            }

            let rebalanceSessions = max(config.rebalanceSessions, 1)
            let shouldRebalance: Bool
            if config.rebalancesFromFirstSignal {
                shouldRebalance = index > 0 && index - lastRebalanceIndex >= rebalanceSessions
            } else {
                shouldRebalance = index == 0 || index % rebalanceSessions == 0
            }

            if shouldRebalance {
                let signalIndex = index - 1
                let preRebalanceValue = portfolioValue(at: index)
                let baseTargetWeights = signalIndex >= 0 ? targetWeights(at: signalIndex, traceIndex: index) : [:]
                let targetWeights = config.metaSwitch == nil
                    ? applyPortfolioDrawdownGuard(
                        to: baseTargetWeights,
                        currentValue: preRebalanceValue
                    )
                    : baseTargetWeights
                let targetSymbols = Set(targetWeights.keys)

                for symbol in heldSymbols.subtracting(targetSymbols) {
                    guard let price = pricesBySymbol[symbol]?[index],
                          let units = unitsBySymbol[symbol],
                          units > 0,
                          let option = optionBySymbol[symbol] else { continue }
                    let executionPrice = max(price * (1 - normalizedSlippageRate), 0)
                    let grossValue = units * executionPrice
                    let cashAmount = grossValue * (1 - normalizedFeeRate)
                    cash += cashAmount
                    unitsBySymbol[symbol] = 0
                    let averageCost = averageCostBySymbol[symbol] ?? 0
                    let realizedProfit = (executionPrice - averageCost) * units - grossValue * normalizedFeeRate
                    let realizedReturn = averageCost > 0 ? (executionPrice / averageCost - 1) : nil
                    let holdingDays = entryDateBySymbol[symbol].map { Calendar.current.dateComponents([.day], from: $0, to: date).day ?? 0 }
                    trades.append(.init(
                        assetSymbol: symbol,
                        assetTitle: option.title,
                        date: date,
                        action: .sell,
                        price: executionPrice,
                        cashAmount: cashAmount,
                        units: units,
                        reason: AppLocalization.string("轮动切换/空仓"),
                        realizedProfit: realizedProfit,
                        realizedReturn: realizedReturn,
                        holdingDays: holdingDays
                    ))
                    averageCostBySymbol[symbol] = 0
                    entryDateBySymbol[symbol] = nil
                }

                heldSymbols = heldSymbols.intersection(targetSymbols)

                for symbol in targetSymbols.sorted() {
                    guard let targetWeight = targetWeights[symbol],
                          let price = pricesBySymbol[symbol]?[index],
                          price > 0,
                          let currentUnits = unitsBySymbol[symbol],
                          currentUnits > 0,
                          let option = optionBySymbol[symbol] else { continue }
                    let currentValue = currentUnits * price
                    let targetValue = preRebalanceValue * targetWeight
                    let grossValueToSell = currentValue > targetValue * (1 + normalizedRebalanceBand)
                        ? Swift.max(currentValue - targetValue, 0.0)
                        : 0.0
                    guard grossValueToSell > 0 else { continue }
                    let unitsToSell = Swift.min(currentUnits, grossValueToSell / price)
                    guard unitsToSell > 0 else { continue }
                    let executionPrice = max(price * (1 - normalizedSlippageRate), 0)
                    let grossValue = unitsToSell * executionPrice
                    let cashAmount = grossValue * (1 - normalizedFeeRate)
                    cash += cashAmount
                    let remainingUnits = Swift.max(currentUnits - unitsToSell, 0)
                    unitsBySymbol[symbol] = remainingUnits
                    let averageCost = averageCostBySymbol[symbol] ?? 0
                    let realizedProfit = (executionPrice - averageCost) * unitsToSell - grossValue * normalizedFeeRate
                    let realizedReturn = averageCost > 0 ? (executionPrice / averageCost - 1) : nil
                    let holdingDays = entryDateBySymbol[symbol].map { Calendar.current.dateComponents([.day], from: $0, to: date).day ?? 0 }
                    trades.append(.init(
                        assetSymbol: symbol,
                        assetTitle: option.title,
                        date: date,
                        action: .sell,
                        price: executionPrice,
                        cashAmount: cashAmount,
                        units: unitsToSell,
                        reason: AppLocalization.string("轮动再平衡"),
                        realizedProfit: realizedProfit,
                        realizedReturn: realizedReturn,
                        holdingDays: holdingDays
                    ))
                    if remainingUnits <= Double.leastNonzeroMagnitude {
                        averageCostBySymbol[symbol] = 0
                        entryDateBySymbol[symbol] = nil
                        heldSymbols.remove(symbol)
                    }
                }

                let totalValue = portfolioValue(at: index)
                for symbol in targetSymbols.sorted() {
                    guard let targetWeight = targetWeights[symbol],
                          let price = pricesBySymbol[symbol]?[index],
                          price > 0,
                          let option = optionBySymbol[symbol] else { continue }
                    let currentValue = (unitsBySymbol[symbol] ?? 0) * price
                    let targetValue = totalValue * targetWeight
                    let amountToInvest = currentValue < targetValue * (1 - normalizedRebalanceBand)
                        ? Swift.min(cash, Swift.max(targetValue - currentValue, 0.0))
                        : 0.0
                    if amountToInvest > 0 {
                        let executionPrice = price * (1 + normalizedSlippageRate)
                        let invested = amountToInvest * (1 - normalizedFeeRate)
                        let units = executionPrice > 0 ? invested / executionPrice : 0
                        let previousUnits = unitsBySymbol[symbol] ?? 0
                        let previousCost = (averageCostBySymbol[symbol] ?? 0) * previousUnits
                        unitsBySymbol[symbol] = previousUnits + units
                        averageCostBySymbol[symbol] = (previousCost + invested) / Swift.max(previousUnits + units, Double.leastNonzeroMagnitude)
                        cash -= amountToInvest
                        heldSymbols.insert(symbol)
                        if entryDateBySymbol[symbol] == nil { entryDateBySymbol[symbol] = date }
                        trades.append(.init(
                            assetSymbol: symbol,
                            assetTitle: option.title,
                            date: date,
                            action: .buy,
                            price: executionPrice,
                            cashAmount: amountToInvest,
                            units: units,
                            reason: config.buyReason,
                            realizedProfit: nil,
                            realizedReturn: nil,
                            holdingDays: nil
                        ))
                    }
                }
                lastRebalanceIndex = index
            }

            let value = portfolioValue(at: index)
            points.append(.init(date: date, portfolioValue: value, sequence: points.count))
            let investedValue = tradableSymbols.reduce(0.0) { partial, symbol in
                partial + (unitsBySymbol[symbol] ?? 0) * (pricesBySymbol[symbol]?[index] ?? 0)
            }
            exposureSum += value > 0 ? investedValue / value : 0
            exposureSamples += 1
            cashRatioSum += value > 0 ? min(max(cash / value, 0), 1) : 0
            cashRatioSamples += 1

            let benchmarkValue = tradableSymbols.reduce(0.0) { partial, symbol in
                guard let prices = pricesBySymbol[symbol], let firstPrice = prices.first, firstPrice > 0 else { return partial }
                return partial + normalizedInitialCash / Double(tradableSymbols.count) * prices[index] / firstPrice
            }
            benchmarkPoints.append(.init(date: date, portfolioValue: benchmarkValue, sequence: benchmarkPoints.count))
        }

        guard let last = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

        let perAssetBenchmarkSeries = tradableSymbols.compactMap { symbol -> AdvancedBacktestBenchmarkSeries? in
            guard let prices = pricesBySymbol[symbol],
                  let firstPrice = prices.first,
                  firstPrice > 0,
                  let option = optionBySymbol[symbol] else { return nil }
            let seriesPoints = prices.enumerated().map { index, price in
                BacktestSeriesPoint(
                    date: commonDates[index],
                    portfolioValue: normalizedInitialCash / Double(tradableSymbols.count) * price / firstPrice,
                    sequence: index
                )
            }
            return AdvancedBacktestBenchmarkSeries(id: symbol, title: option.title, points: seriesPoints)
        }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: config.symbol,
            title: config.title,
            points: points,
            benchmarkPoints: benchmarkPoints,
            pricePoints: [],
            trades: trades,
            finalPortfolioValue: last.portfolioValue,
            finalCash: cash,
            finalUnits: unitsBySymbol.values.reduce(0, +),
            exposureRatio: exposureSamples > 0 ? exposureSum / Double(exposureSamples) : 0
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: cashInterestEarned,
            averageCashRatio: cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0,
            averageAnnualRate: cashAnnualRateSamples > 0 ? cashAnnualRateSum / Double(cashAnnualRateSamples) : 0
        )
        let riskSignalSummary = MarketRiskSignalHistory.summary(
            dates: commonDates,
            pricesBySymbol: pricesBySymbol
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: benchmarkPoints,
            benchmarkSeries: perAssetBenchmarkSeries,
            trades: trades.sorted { lhs, rhs in lhs.date < rhs.date },
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: cash,
            finalUnits: unitsBySymbol.values.reduce(0, +),
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: riskSignalSummary
        )
    }

    private static func alignedRotationPriceSeries(
        from preparedSeries: [PreparedAdvancedSeries]
    ) -> (dates: [Date], pricesBySymbol: [String: [Double]]) {
        let allDates = Set(preparedSeries.flatMap { $0.pricePoints.map(\.date) }).sorted()
        var indices = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, 0) })
        var latestPrices: [String: Double] = [:]
        var latestPriceDates: [String: Date] = [:]
        var outputDates: [Date] = []
        var pricesBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, [Double]()) })

        for date in allDates {
            for series in preparedSeries {
                let symbol = series.assetOption.symbol
                var index = indices[symbol] ?? 0
                while index < series.pricePoints.count && series.pricePoints[index].date <= date {
                    latestPrices[symbol] = series.pricePoints[index].cnyPrice
                    latestPriceDates[symbol] = series.pricePoints[index].date
                    index += 1
                }
                indices[symbol] = index
            }

            guard preparedSeries.allSatisfy({ series in
                let symbol = series.assetOption.symbol
                guard latestPrices[symbol] != nil,
                      let latestPriceDate = latestPriceDates[symbol] else { return false }
                let staleDays = historicalSeriesCalendar.dateComponents([.day], from: latestPriceDate, to: date).day ?? Int.max
                return staleDays <= maxForwardFillCalendarDays
            }) else { continue }
            outputDates.append(date)
            for series in preparedSeries {
                let symbol = series.assetOption.symbol
                pricesBySymbol[symbol, default: []].append(latestPrices[symbol] ?? 0)
            }
        }

        return (outputDates, pricesBySymbol)
    }

    private static func runAdvancedStrategies(
        preparedSeries: [PreparedAdvancedSeries],
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        guard !preparedSeries.isEmpty else { return nil }

        let normalizedInitialCash = max(initialCash, 0)
        let perAssetInitialCash = normalizedInitialCash / Double(preparedSeries.count)
        guard perAssetInitialCash > 0 else { return nil }

        let reports = preparedSeries.compactMap { series in
            runAdvancedStrategy(
                preparedSeries: series,
                initialCash: perAssetInitialCash,
                tradeAmount: tradeAmount,
                buyRule: buyRule,
                sellRule: sellRule,
                settings: settings
            )
        }
        guard !reports.isEmpty else { return nil }
        if reports.count == 1, let report = reports.first { return report }

        let allDates = Set(reports.flatMap { $0.points.map(\.date) }).sorted()
        guard !allDates.isEmpty else { return nil }

        var valueByReportIndex = Array(repeating: perAssetInitialCash, count: reports.count)
        var benchmarkValueByReportIndex = Array(repeating: perAssetInitialCash, count: reports.count)
        var cursors = Array(repeating: 0, count: reports.count)
        var benchmarkCursors = Array(repeating: 0, count: reports.count)
        var combinedPoints: [BacktestSeriesPoint] = []
        var combinedBenchmarkPoints: [BacktestSeriesPoint] = []
        combinedPoints.reserveCapacity(allDates.count)
        combinedBenchmarkPoints.reserveCapacity(allDates.count)

        for date in allDates {
            for reportIndex in reports.indices {
                let reportPoints = reports[reportIndex].points
                var cursor = cursors[reportIndex]
                while cursor < reportPoints.count, reportPoints[cursor].date <= date {
                    valueByReportIndex[reportIndex] = reportPoints[cursor].portfolioValue
                    cursor += 1
                }
                cursors[reportIndex] = cursor

                let benchmarkPoints = reports[reportIndex].benchmarkPoints
                var benchmarkCursor = benchmarkCursors[reportIndex]
                while benchmarkCursor < benchmarkPoints.count, benchmarkPoints[benchmarkCursor].date <= date {
                    benchmarkValueByReportIndex[reportIndex] = benchmarkPoints[benchmarkCursor].portfolioValue
                    benchmarkCursor += 1
                }
                benchmarkCursors[reportIndex] = benchmarkCursor
            }

            let totalValue = valueByReportIndex.reduce(0, +)
            let totalBenchmarkValue = benchmarkValueByReportIndex.reduce(0, +)
            combinedPoints.append(BacktestSeriesPoint(date: date, portfolioValue: totalValue, sequence: combinedPoints.count))
            combinedBenchmarkPoints.append(BacktestSeriesPoint(date: date, portfolioValue: totalBenchmarkValue, sequence: combinedBenchmarkPoints.count))
        }

        guard let last = combinedPoints.last,
              let metrics = performanceMetrics(from: combinedPoints) else { return nil }

        let assetReports = reports.flatMap(\.assetReports)
        let benchmarkSeries = reports.flatMap(\.benchmarkSeries)
        let trades = reports.flatMap(\.trades).sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.assetSymbol < rhs.assetSymbol }
            return lhs.date < rhs.date
        }
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: combinedPoints.first?.date,
            endDate: combinedPoints.last?.date,
            totalCashInterest: reports.reduce(0) { $0 + $1.cashYieldSummary.totalCashInterest },
            averageCashRatio: reports.isEmpty ? 0 : reports.reduce(0) { $0 + $1.cashYieldSummary.averageCashRatio } / Double(reports.count),
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: allDates)
        )

        return AdvancedBacktestReport(
            points: combinedPoints,
            benchmarkPoints: combinedBenchmarkPoints,
            benchmarkSeries: benchmarkSeries,
            trades: trades,
            assetReports: assetReports,
            finalPortfolioValue: last.portfolioValue,
            finalCash: reports.reduce(0) { $0 + $1.finalCash },
            finalUnits: reports.reduce(0) { $0 + $1.finalUnits },
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    private static func scoreAdvancedReport(_ report: AdvancedBacktestReport) -> Double {
        let annualized = report.annualizedReturn ?? report.totalReturn
        let sharpe = report.sharpeRatio ?? 0
        let excess = report.excessReturn ?? 0
        let tradePenalty = report.trades.count < 2 ? 0.35 : 0

        var validationAdjustment = 0.0
        if report.points.count >= 90 {
            let validationCount = min(max(report.points.count / 3, 60), report.points.count - 1)
            let validationPoints = Array(report.points.suffix(validationCount))
            if let validationMetrics = performanceMetrics(from: validationPoints) {
                let recentReturn = validationMetrics.totalReturn
                let recentDrawdown = validationMetrics.maxDrawdown
                validationAdjustment += max(recentReturn, 0) * 0.18
                validationAdjustment -= max(-recentReturn, 0) * 0.65
                validationAdjustment -= max(recentDrawdown - report.maxDrawdown, 0) * 0.35
            }
        }

        return annualized * 1.25
            + max(excess, 0) * 0.45
            + sharpe * 0.18
            + validationAdjustment
            - report.maxDrawdown * 1.2
            - tradePenalty
    }

    static func optimizeAdvancedStrategy(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?,
        initialCash: Double,
        baseSettings: AdvancedBacktestRiskSettings,
        limit: Int = 3
    ) -> [AdvancedBacktestCandidate] {
        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return [] }
        guard let preparedSeries = preparedAdvancedSeries(assetSeries: assetSeries, assetOption: assetOption, fxSeries: fxSeries) else { return [] }

        let maxCandidateCount = max(limit, 1)
        let buyDirections: [AdvancedBacktestSignalDirection] = [
            .alwaysBuy,
            .consecutiveDown,
            .priceAboveMA20,
            .priceAboveMA60,
            .priceCrossesAboveMA20,
            .priceCrossesAboveBollMiddle,
            .touchesBollLower,
            .ma20CrossesAboveMA60
        ]
        let sellDirections: [AdvancedBacktestSignalDirection] = [
            .neverSell,
            .consecutiveUp,
            .priceBelowMA20,
            .priceBelowMA60,
            .priceCrossesBelowMA20,
            .priceCrossesBelowBollMiddle,
            .touchesBollUpper,
            .ma20CrossesBelowMA60
        ]
        let dayThresholds = [2, 3, 5]
        let tradeAmounts = [
            normalizedInitialCash * 0.05,
            normalizedInitialCash * 0.10,
            normalizedInitialCash * 0.20
        ]
        let maxPositionRatios = Array(Set([baseSettings.maxPositionRatio, 35, 50, 70, 100]))
            .filter { $0 > 0 }
            .sorted()

        var topCandidates: [AdvancedBacktestCandidate] = []
        func retainIfTopCandidate(_ candidate: AdvancedBacktestCandidate) {
            if topCandidates.count < maxCandidateCount {
                topCandidates.append(candidate)
                topCandidates.sort { $0.score > $1.score }
                return
            }

            guard let weakestCandidate = topCandidates.last,
                  candidate.score > weakestCandidate.score else { return }
            topCandidates.removeLast()
            topCandidates.append(candidate)
            topCandidates.sort { $0.score > $1.score }
        }

        for buyDirection in buyDirections {
            for sellDirection in sellDirections {
                for buyDays in dayThresholds {
                    for sellDays in dayThresholds {
                        for tradeAmount in tradeAmounts {
                            for maxPositionRatio in maxPositionRatios {
                                if Task.isCancelled { return topCandidates }

                                var settings = baseSettings
                                settings.maxPositionRatio = maxPositionRatio
                                let buyRule = AdvancedBacktestRule(direction: buyDirection, days: buyDirection.usesDayThreshold ? buyDays : 1)
                                let sellRule = AdvancedBacktestRule(direction: sellDirection, days: sellDirection.usesDayThreshold ? sellDays : 1)
                                guard let report = runAdvancedStrategy(
                                    preparedSeries: preparedSeries,
                                    initialCash: normalizedInitialCash,
                                    tradeAmount: tradeAmount,
                                    buyRule: buyRule,
                                    sellRule: sellRule,
                                    settings: settings
                                ), report.points.count > 20 else { continue }
                                retainIfTopCandidate(
                                    AdvancedBacktestCandidate(
                                        buyRule: buyRule,
                                        sellRule: sellRule,
                                        tradeAmount: tradeAmount,
                                        settings: settings,
                                        report: report,
                                        score: scoreAdvancedReport(report)
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        return topCandidates
    }

    static func optimizeAdvancedStrategies(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        baseSettings: AdvancedBacktestRiskSettings,
        limit: Int = 3
    ) -> [AdvancedBacktestCandidate] {
        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return [] }

        let validInputs = assetInputs.filter { input in
            input.assetSeries != nil && (!input.assetOption.requiresHistoricalFX || input.fxSeries != nil)
        }
        guard !validInputs.isEmpty else { return [] }
        let preparedSeries = validInputs.compactMap { input in
            preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard !preparedSeries.isEmpty else { return [] }

        let maxCandidateCount = max(limit, 1)
        let buyDirections: [AdvancedBacktestSignalDirection] = [
            .alwaysBuy,
            .consecutiveDown,
            .priceAboveMA20,
            .priceAboveMA60,
            .priceCrossesAboveMA20,
            .priceCrossesAboveBollMiddle,
            .touchesBollLower,
            .ma20CrossesAboveMA60
        ]
        let sellDirections: [AdvancedBacktestSignalDirection] = [
            .neverSell,
            .consecutiveUp,
            .priceBelowMA20,
            .priceBelowMA60,
            .priceCrossesBelowMA20,
            .priceCrossesBelowBollMiddle,
            .touchesBollUpper,
            .ma20CrossesBelowMA60
        ]
        let dayThresholds = [2, 3, 5]
        let tradeAmounts = [
            normalizedInitialCash * 0.05,
            normalizedInitialCash * 0.10,
            normalizedInitialCash * 0.20
        ]
        let maxPositionRatios = Array(Set([baseSettings.maxPositionRatio, 35, 50, 70, 100]))
            .filter { $0 > 0 }
            .sorted()

        var topCandidates: [AdvancedBacktestCandidate] = []
        func retainIfTopCandidate(_ candidate: AdvancedBacktestCandidate) {
            if topCandidates.count < maxCandidateCount {
                topCandidates.append(candidate)
                topCandidates.sort { $0.score > $1.score }
                return
            }

            guard let weakestCandidate = topCandidates.last,
                  candidate.score > weakestCandidate.score else { return }
            topCandidates.removeLast()
            topCandidates.append(candidate)
            topCandidates.sort { $0.score > $1.score }
        }

        for buyDirection in buyDirections {
            for sellDirection in sellDirections {
                for buyDays in dayThresholds {
                    for sellDays in dayThresholds {
                        for tradeAmount in tradeAmounts {
                            for maxPositionRatio in maxPositionRatios {
                                if Task.isCancelled { return topCandidates }

                                var settings = baseSettings
                                settings.maxPositionRatio = maxPositionRatio
                                let buyRule = AdvancedBacktestRule(direction: buyDirection, days: buyDirection.usesDayThreshold ? buyDays : 1)
                                let sellRule = AdvancedBacktestRule(direction: sellDirection, days: sellDirection.usesDayThreshold ? sellDays : 1)
                                guard let report = runAdvancedStrategies(
                                    preparedSeries: preparedSeries,
                                    initialCash: normalizedInitialCash,
                                    tradeAmount: tradeAmount,
                                    buyRule: buyRule,
                                    sellRule: sellRule,
                                    settings: settings
                                ), report.points.count > 20 else { continue }
                                retainIfTopCandidate(
                                    AdvancedBacktestCandidate(
                                        buyRule: buyRule,
                                        sellRule: sellRule,
                                        tradeAmount: tradeAmount,
                                        settings: settings,
                                        report: report,
                                        score: scoreAdvancedReport(report)
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        return topCandidates
    }

    private static func rollingAnnualizedVolatility(values: [Double], period: Int) -> [Double?] {
        guard period > 1, values.count > 1 else { return Array(repeating: nil, count: values.count) }

        var logReturns = Array<Double>(repeating: 0, count: values.count)
        for index in values.indices.dropFirst() {
            let previous = values[index - 1]
            let current = values[index]
            logReturns[index] = previous > 0 && current > 0 ? log(current / previous) : 0
        }

        var result = Array<Double?>(repeating: nil, count: values.count)
        var rollingSum = 0.0
        var rollingSquaredSum = 0.0

        for index in logReturns.indices {
            let value = logReturns[index]
            rollingSum += value
            rollingSquaredSum += value * value

            if index >= period {
                let removed = logReturns[index - period]
                rollingSum -= removed
                rollingSquaredSum -= removed * removed
            }

            if index >= period {
                let mean = rollingSum / Double(period)
                let variance = max((rollingSquaredSum / Double(period)) - (mean * mean), 0)
                result[index] = sqrt(variance) * sqrt(252)
            }
        }

        return result
    }

    private static func movingAverage(values: [Double], period: Int) -> [Double?] {
        guard period > 0, !values.isEmpty else { return Array(repeating: nil, count: values.count) }

        var result = Array<Double?>(repeating: nil, count: values.count)
        var rollingSum = 0.0

        for index in values.indices {
            rollingSum += values[index]
            if index >= period {
                rollingSum -= values[index - period]
            }
            if index >= period - 1 {
                result[index] = rollingSum / Double(period)
            }
        }

        return result
    }

    private static func priceMomentum(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index),
              values.indices.contains(index - lookback) else { return nil }
        let previous = values[index - lookback]
        guard previous > 0 else { return nil }
        return values[index] / previous - 1
    }

    private static func rollingDrawdownFromHigh(values: [Double], at index: Int, period: Int) -> Double? {
        guard period > 0,
              values.indices.contains(index),
              index - period + 1 >= 0 else { return nil }
        let startIndex = index - period + 1
        guard let peak = values[startIndex...index].max(), peak > 0 else { return nil }
        return values[index] / peak - 1
    }

    private static func relativeStrengthIndex(values: [Double], at index: Int, period: Int) -> Double? {
        guard period > 0,
              values.indices.contains(index),
              index >= period,
              values.count > period else { return nil }

        var averageGain = 0.0
        var averageLoss = 0.0
        for cursor in 1...period {
            let previous = values[cursor - 1]
            let change = previous > 0 ? values[cursor] / previous - 1 : 0
            averageGain += max(change, 0)
            averageLoss += max(-change, 0)
        }
        averageGain /= Double(period)
        averageLoss /= Double(period)

        if index > period {
            for cursor in (period + 1)...index {
                let previous = values[cursor - 1]
                let change = previous > 0 ? values[cursor] / previous - 1 : 0
                let gain = max(change, 0)
                let loss = max(-change, 0)
                averageGain = (averageGain * Double(period - 1) + gain) / Double(period)
                averageLoss = (averageLoss * Double(period - 1) + loss) / Double(period)
            }
        }

        if averageLoss == 0 { return 100 }
        let relativeStrength = averageGain / averageLoss
        return 100 - 100 / (1 + relativeStrength)
    }

    private static func donchianRangePosition(values: [Double], at index: Int, period: Int) -> Double? {
        guard period > 0,
              values.indices.contains(index),
              index - period + 1 >= 0 else { return nil }
        let startIndex = index - period + 1
        guard let high = values[startIndex...index].max(),
              let low = values[startIndex...index].min() else { return nil }
        return (values[index] - low) / max(high - low, 1e-12)
    }

    private static func bollingerBands(values: [Double], period: Int, multiplier: Double) -> [(middle: Double, lower: Double, upper: Double)?] {
        guard period > 0, !values.isEmpty else { return Array(repeating: nil, count: values.count) }

        var result = Array<(middle: Double, lower: Double, upper: Double)?>(repeating: nil, count: values.count)
        var rollingSum = 0.0
        var rollingSquaredSum = 0.0

        for index in values.indices {
            let value = values[index]
            rollingSum += value
            rollingSquaredSum += value * value

            if index >= period {
                let removed = values[index - period]
                rollingSum -= removed
                rollingSquaredSum -= removed * removed
            }

            if index >= period - 1 {
                let mean = rollingSum / Double(period)
                let variance = max((rollingSquaredSum / Double(period)) - (mean * mean), 0)
                let deviation = sqrt(variance)
                result[index] = (
                    middle: mean,
                    lower: mean - multiplier * deviation,
                    upper: mean + multiplier * deviation
                )
            }
        }

        return result
    }

    private static func advancedRuleTriggered(
        _ rule: AdvancedBacktestRule,
        at index: Int,
        pricePoints: [(date: Date, cnyPrice: Double)],
        ma20: [Double?],
        ma60: [Double?],
        boll20: [(middle: Double, lower: Double, upper: Double)?],
        upStreak: Int,
        downStreak: Int,
        threshold: Int
    ) -> Bool {
        guard index > 0 else { return false }

        switch rule.direction {
        case .alwaysBuy:
            return true
        case .neverSell:
            return false
        case .consecutiveDown:
            return downStreak == threshold
        case .consecutiveUp:
            return upStreak == threshold
        case .priceAboveMA20:
            guard let currentMA20 = ma20[index] else { return false }
            return pricePoints[index].cnyPrice > currentMA20
        case .priceBelowMA20:
            guard let currentMA20 = ma20[index] else { return false }
            return pricePoints[index].cnyPrice < currentMA20
        case .priceAboveMA60:
            guard let currentMA60 = ma60[index] else { return false }
            return pricePoints[index].cnyPrice > currentMA60
        case .priceBelowMA60:
            guard let currentMA60 = ma60[index] else { return false }
            return pricePoints[index].cnyPrice < currentMA60
        case .priceCrossesAboveMA20:
            guard let previousMA20 = ma20[index - 1], let currentMA20 = ma20[index] else { return false }
            return pricePoints[index - 1].cnyPrice <= previousMA20 && pricePoints[index].cnyPrice > currentMA20
        case .priceCrossesBelowMA20:
            guard let previousMA20 = ma20[index - 1], let currentMA20 = ma20[index] else { return false }
            return pricePoints[index - 1].cnyPrice >= previousMA20 && pricePoints[index].cnyPrice < currentMA20
        case .ma20CrossesAboveMA60:
            guard let previousMA20 = ma20[index - 1],
                  let currentMA20 = ma20[index],
                  let previousMA60 = ma60[index - 1],
                  let currentMA60 = ma60[index] else { return false }
            return previousMA20 <= previousMA60 && currentMA20 > currentMA60
        case .ma20CrossesBelowMA60:
            guard let previousMA20 = ma20[index - 1],
                  let currentMA20 = ma20[index],
                  let previousMA60 = ma60[index - 1],
                  let currentMA60 = ma60[index] else { return false }
            return previousMA20 >= previousMA60 && currentMA20 < currentMA60
        case .priceCrossesAboveBollMiddle:
            guard let previousBand = boll20[index - 1], let currentBand = boll20[index] else { return false }
            return pricePoints[index - 1].cnyPrice <= previousBand.middle && pricePoints[index].cnyPrice > currentBand.middle
        case .priceCrossesBelowBollMiddle:
            guard let previousBand = boll20[index - 1], let currentBand = boll20[index] else { return false }
            return pricePoints[index - 1].cnyPrice >= previousBand.middle && pricePoints[index].cnyPrice < currentBand.middle
        case .touchesBollLower:
            guard let previousBand = boll20[index - 1], let currentBand = boll20[index] else { return false }
            return pricePoints[index - 1].cnyPrice > previousBand.lower && pricePoints[index].cnyPrice <= currentBand.lower
        case .touchesBollUpper:
            guard let previousBand = boll20[index - 1], let currentBand = boll20[index] else { return false }
            return pricePoints[index - 1].cnyPrice < previousBand.upper && pricePoints[index].cnyPrice >= currentBand.upper
        }
    }

    static func availableDateBounds(for seriesList: [PublicHistorySeries]) -> ClosedRange<Date>? {
        let seriesBounds = seriesList.compactMap { series -> ClosedRange<Date>? in
            guard let firstText = series.dates.first,
                  let lastText = series.dates.last,
                  let firstDate = historicalSeriesDateStatic(from: firstText),
                  let lastDate = historicalSeriesDateStatic(from: lastText) else {
                return nil
            }
            return firstDate...lastDate
        }

        guard let lowerBound = seriesBounds.map(\.lowerBound).max(),
              let upperBound = seriesBounds.map(\.upperBound).min(),
              lowerBound <= upperBound else {
            return nil
        }

        return lowerBound...upperBound
    }

    fileprivate static func historicalSeriesDateStatic(from text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }

        var components = DateComponents()
        components.calendar = historicalSeriesCalendar
        components.timeZone = historicalSeriesCalendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        return components.date
    }

    private static let historicalSeriesCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    private static let maxForwardFillCalendarDays = 30

    private static func makeHistoricalLookup(from series: PublicHistorySeries?) -> HistoricalLookup? {
        HistoricalLookup(points: normalizedPricePoints(from: series))
    }

    private static func cnyPrice(
        for point: HistoricalPricePoint,
        assetOption: BacktestAssetOption,
        fxLookup: HistoricalLookup?
    ) -> Double? {
        guard assetOption.requiresHistoricalFX else { return point.price }
        guard let fxRate = fxLookup?.price(onOrBefore: point.date), fxRate.isFinite, fxRate > 0 else { return nil }
        if fxRate < 1 {
            // Expected contract: USD per CNY, e.g. 0.14. USD asset price / (USD/CNY) = CNY price.
            return point.price / fxRate
        }
        if fxRate <= 20 {
            // Defensive fallback for common CNY per USD feeds, e.g. 7.2. USD asset price * (CNY/USD) = CNY price.
            return point.price * fxRate
        }
        return nil
    }
}

private enum BacktestChartValueStyle {
    case multiple
    case currency(code: String)

    func label(for value: Double) -> String {
        switch self {
        case .multiple:
            return String(format: "%.2fx", value)
        case let .currency(code):
            return value.currencyString(code: code)
        }
    }
}

private enum BacktestChartSeriesTitle {
    static var strategy: String { AppLocalization.string("策略净值") }
}

private enum BacktestChartSeriesKey {
    static let strategy = "strategy"
    static let legacyBenchmark = "benchmark"
}

private struct BacktestChartComparisonSeries: Identifiable {
    let id: String
    let title: String
    let points: [BacktestSeriesPoint]
    let color: Color
}

private struct BacktestChartLegendItem: Identifiable {
    let id: String
    let title: String
    let color: Color
    let isDashed: Bool
}

private struct BacktestChartLegendFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 8

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        var isEmpty: Bool { items.isEmpty }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = arrangedRows(for: subviews, maxWidth: proposal.width)
        let maxRowWidth = rows.map(\.width).max() ?? 0
        let totalHeight = rows.enumerated().reduce(CGFloat.zero) { partial, item in
            partial + item.element.height + (item.offset == 0 ? 0 : verticalSpacing)
        }

        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            return CGSize(width: proposedWidth, height: totalHeight)
        }
        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrangedRows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX + max((bounds.width - row.width) / 2, 0)
            for item in row.items {
                let itemY = y + max((row.height - item.size.height) / 2, 0)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: itemY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func arrangedRows(for subviews: Subviews, maxWidth proposedMaxWidth: CGFloat?) -> [Row] {
        let maxWidth = proposedMaxWidth?.isFinite == true ? max(proposedMaxWidth ?? 0, 0) : .infinity
        var rows: [Row] = []
        var currentRow = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let spacing = currentRow.isEmpty ? CGFloat.zero : horizontalSpacing
            let candidateWidth = currentRow.width + spacing + size.width

            if !currentRow.isEmpty, candidateWidth > maxWidth {
                rows.append(currentRow)
                currentRow = Row()
            }

            let itemSpacing = currentRow.isEmpty ? CGFloat.zero : horizontalSpacing
            currentRow.items.append((index, size))
            currentRow.width += itemSpacing + size.width
            currentRow.height = max(currentRow.height, size.height)
        }

        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }
}

private enum BacktestChartPalette {
    static var strategyLine: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 1.00, green: 0.74, blue: 0.14, alpha: 1)
                : UIColor(red: 0.78, green: 0.36, blue: 0.02, alpha: 1)
        })
    }

    static var benchmarkLine: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.00, green: 0.86, blue: 1.00, alpha: 1)
                : UIColor(red: 0.00, green: 0.28, blue: 0.86, alpha: 1)
        })
    }

    static func comparisonLine(at index: Int) -> Color {
        let palette: [Color] = [
            benchmarkLine,
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.56, green: 0.95, blue: 0.56, alpha: 1)
                    : UIColor(red: 0.00, green: 0.48, blue: 0.24, alpha: 1)
            }),
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.78, green: 0.64, blue: 1.00, alpha: 1)
                    : UIColor(red: 0.42, green: 0.25, blue: 0.86, alpha: 1)
            }),
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 1.00, green: 0.58, blue: 0.44, alpha: 1)
                    : UIColor(red: 0.84, green: 0.22, blue: 0.12, alpha: 1)
            }),
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.52, green: 0.82, blue: 1.00, alpha: 1)
                    : UIColor(red: 0.04, green: 0.42, blue: 0.68, alpha: 1)
            })
        ]
        return palette[abs(index) % palette.count]
    }

    static var strategyAreaTop: Color { strategyLine.opacity(0.18) }
    static var strategyAreaBottom: Color { strategyLine.opacity(0.025) }
}

private struct InteractiveBacktestChart: View {
    let points: [BacktestSeriesPoint]
    var comparisonPoints: [BacktestSeriesPoint] = []
    var comparisonSeries: [BacktestChartComparisonSeries] = []
    var valueStyle: BacktestChartValueStyle = .multiple
    var visibleSeriesIDs: Set<String> = []
    @State private var selectedDate: Date?

    private var resolvedComparisonSeries: [BacktestChartComparisonSeries] {
        let explicitSeries = comparisonSeries.filter { !$0.points.isEmpty }
        if !explicitSeries.isEmpty { return explicitSeries }
        guard !comparisonPoints.isEmpty else { return [] }
        return [
            BacktestChartComparisonSeries(
                id: BacktestChartSeriesKey.legacyBenchmark,
                title: AppLocalization.string("买入持有"),
                points: comparisonPoints,
                color: BacktestChartPalette.comparisonLine(at: 0)
            )
        ]
    }

    private var availableSeriesIDs: Set<String> {
        Set([BacktestChartSeriesKey.strategy] + resolvedComparisonSeries.map(\.id))
    }

    private var effectiveVisibleSeriesIDs: Set<String> {
        let visibleAvailableSeries = visibleSeriesIDs.intersection(availableSeriesIDs)
        return visibleAvailableSeries.isEmpty ? availableSeriesIDs : visibleAvailableSeries
    }

    private var interactionSeriesID: String? {
        let visibleSeriesIDs = effectiveVisibleSeriesIDs
        if visibleSeriesIDs.contains(BacktestChartSeriesKey.strategy) { return BacktestChartSeriesKey.strategy }
        return resolvedComparisonSeries.first(where: { visibleSeriesIDs.contains($0.id) })?.id
    }

    private var interactionPoints: [BacktestSeriesPoint] {
        guard let interactionSeriesID else { return [] }
        if interactionSeriesID == BacktestChartSeriesKey.strategy { return points }
        return resolvedComparisonSeries.first(where: { $0.id == interactionSeriesID })?.points ?? []
    }

    private var interactionColor: Color {
        guard let interactionSeriesID else { return BacktestChartPalette.strategyLine }
        if interactionSeriesID == BacktestChartSeriesKey.strategy { return BacktestChartPalette.strategyLine }
        return resolvedComparisonSeries.first(where: { $0.id == interactionSeriesID })?.color ?? BacktestChartPalette.benchmarkLine
    }

    private var selectedPoint: BacktestSeriesPoint? {
        let activePoints = interactionPoints
        guard let selectedDate else { return activePoints.last }
        return Self.nearestPoint(to: selectedDate, in: activePoints)
    }

    private var valueDomain: ClosedRange<Double> {
        var minValue = Double.infinity
        var maxValue = -Double.infinity
        let visibleSeriesIDs = effectiveVisibleSeriesIDs

        if visibleSeriesIDs.contains(BacktestChartSeriesKey.strategy) {
            for point in points where point.portfolioValue.isFinite {
                minValue = min(minValue, point.portfolioValue)
                maxValue = max(maxValue, point.portfolioValue)
            }
        }
        for series in resolvedComparisonSeries where visibleSeriesIDs.contains(series.id) {
            for point in series.points where point.portfolioValue.isFinite {
                minValue = min(minValue, point.portfolioValue)
                maxValue = max(maxValue, point.portfolioValue)
            }
        }

        guard minValue.isFinite, maxValue.isFinite else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }

    private var foregroundStyleDomain: [String] {
        [BacktestChartSeriesTitle.strategy] + resolvedComparisonSeries.map(\.title)
    }

    private var foregroundStyleRange: [Color] {
        [BacktestChartPalette.strategyLine] + resolvedComparisonSeries.map(\.color)
    }

    private static func nearestPoint(to date: Date, in points: [BacktestSeriesPoint]) -> BacktestSeriesPoint? {
        guard !points.isEmpty else { return nil }
        guard points.count > 1 else { return points[0] }

        var lowerBound = 0
        var upperBound = points.count - 1
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if points[middle].date < date {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        if lowerBound == 0 { return points[0] }
        let nextPoint = points[lowerBound]
        let previousPoint = points[lowerBound - 1]
        return abs(previousPoint.date.timeIntervalSince(date)) <= abs(nextPoint.date.timeIntervalSince(date)) ? previousPoint : nextPoint
    }

    @ChartContentBuilder
    private func strategyMarks(domain: ClosedRange<Double>, strategySeries: String) -> some ChartContent {
        if effectiveVisibleSeriesIDs.contains(BacktestChartSeriesKey.strategy) {
            ForEach(points) { point in
                AreaMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    yStart: .value(AppLocalization.string("组合净值下沿"), domain.lowerBound),
                    yEnd: .value(AppLocalization.string("组合净值"), point.portfolioValue)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [BacktestChartPalette.strategyAreaTop, BacktestChartPalette.strategyAreaBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    y: .value(AppLocalization.string("组合净值"), point.portfolioValue)
                )
                .foregroundStyle(by: .value(AppLocalization.string("系列"), strategySeries))
                .lineStyle(StrokeStyle(lineWidth: 2.9, lineCap: .round, lineJoin: .round))
            }
        }
    }

    @ChartContentBuilder
    private func comparisonMarks(seriesList: [BacktestChartComparisonSeries], visibleSeriesIDs: Set<String>) -> some ChartContent {
        ForEach(seriesList) { series in
            if visibleSeriesIDs.contains(series.id) {
                ForEach(series.points) { point in
                    LineMark(
                        x: .value(AppLocalization.string("日期"), point.date),
                        y: .value(series.title, point.portfolioValue)
                    )
                    .foregroundStyle(by: .value(AppLocalization.string("系列"), series.title))
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round, dash: [8, 5]))
                }
            }
        }
    }

    @ChartContentBuilder
    private func selectionMarks() -> some ChartContent {
        if let selectedPoint {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedPoint.date),
                y: .value(AppLocalization.string("组合净值"), selectedPoint.portfolioValue)
            )
            .foregroundStyle(interactionColor)
            .symbolSize(44)
        }

        if selectedDate != nil, let selectedPoint {
            RuleMark(x: .value(AppLocalization.string("选中日期"), selectedPoint.date))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    @ViewBuilder
    private var selectedValueBadge: some View {
        if selectedDate != nil, let selectedPoint {
            VStack(alignment: .trailing, spacing: 2) {
                Text(AppLocalization.string("资产"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                Text(selectedPoint.portfolioValue.currencyString())
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(AssetTheme.overlaySoft.opacity(0.96), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.16), radius: 8, y: 4)
            .padding(.top, 8)
            .padding(.trailing, 8)
            .allowsHitTesting(false)
        }
    }

    var body: some View {
        let domain = valueDomain
        let visibleSeriesIDs = effectiveVisibleSeriesIDs
        let comparisonSeries = resolvedComparisonSeries
        let strategySeries = BacktestChartSeriesTitle.strategy

        Chart {
            strategyMarks(domain: domain, strategySeries: strategySeries)
            comparisonMarks(seriesList: comparisonSeries, visibleSeriesIDs: visibleSeriesIDs)
            selectionMarks()
        }
        .frame(height: 220)
        .clipped()
        .chartYScale(domain: domain)
        .chartForegroundStyleScale(domain: foregroundStyleDomain, range: foregroundStyleRange)
        .animation(.easeInOut(duration: 0.2), value: visibleSeriesIDs)
        .chartPlotStyle { plotArea in
            plotArea
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                    .foregroundStyle(AssetTheme.border.opacity(0.35))
                AxisValueLabel(format: .dateTime.year())
                    .foregroundStyle(AssetTheme.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                    .foregroundStyle(AssetTheme.border.opacity(0.35))
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(valueStyle.label(for: doubleValue))
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            TimeMachineDragOverlay(proxy: proxy) { date in
                selectedDate = date
            } onEnded: {
                selectedDate = nil
            }
        }
        .overlay(alignment: .topTrailing) {
            selectedValueBadge
        }
    }

}

private enum BacktestChartData {
    static func sampledPoints(from points: [BacktestSeriesPoint], maxCount: Int = 240) -> [BacktestSeriesPoint] {
        guard points.count > maxCount, maxCount > 1 else { return points }

        let step = Double(points.count - 1) / Double(maxCount - 1)
        var sampled: [BacktestSeriesPoint] = []
        sampled.reserveCapacity(maxCount)

        for index in 0 ..< maxCount {
            let rawIndex = Int((Double(index) * step).rounded())
            let safeIndex = min(max(rawIndex, 0), points.count - 1)
            let point = points[safeIndex]
            if sampled.last?.date != point.date {
                sampled.append(point)
            }
        }

        if sampled.last?.date != points.last?.date, let last = points.last {
            sampled.append(last)
        }

        return sampled.enumerated().map { index, point in
            BacktestSeriesPoint(date: point.date, portfolioValue: point.portfolioValue, sequence: index)
        }
    }

    static func normalizedComparisonPoints(
        _ points: [BacktestSeriesPoint],
        targetStartValue: Double?
    ) -> [BacktestSeriesPoint] {
        guard let targetStartValue,
              targetStartValue.isFinite,
              targetStartValue > 0,
              let firstValue = points.first?.portfolioValue,
              firstValue.isFinite,
              firstValue > 0 else {
            return points
        }

        let scale = targetStartValue / firstValue
        guard scale.isFinite, abs(scale - 1) > 0.000001 else { return points }

        return points.map { point in
            BacktestSeriesPoint(
                date: point.date,
                portfolioValue: point.portfolioValue * scale,
                sequence: point.id
            )
        }
    }

    static func legendItems(for comparisonSeries: [BacktestChartComparisonSeries]) -> [BacktestChartLegendItem] {
        [
            BacktestChartLegendItem(
                id: BacktestChartSeriesKey.strategy,
                title: BacktestChartSeriesTitle.strategy,
                color: BacktestChartPalette.strategyLine,
                isDashed: false
            )
        ] + comparisonSeries.map { series in
            BacktestChartLegendItem(id: series.id, title: series.title, color: series.color, isDashed: true)
        }
    }
}

private struct BacktestValueChartSection: View {
    let points: [BacktestSeriesPoint]
    var comparisonSeries: [BacktestChartComparisonSeries] = []
    var valueStyle: BacktestChartValueStyle = .multiple
    var title: String = AppLocalization.string("净值走势")
    var footnote: String? = nil
    @State private var visibleSeriesIDs: Set<String> = []

    private var chartPoints: [BacktestSeriesPoint] {
        BacktestChartData.sampledPoints(from: points)
    }

    private var chartComparisonSeries: [BacktestChartComparisonSeries] {
        comparisonSeries.compactMap { series in
            let sampledPoints = BacktestChartData.sampledPoints(from: series.points)
            guard !sampledPoints.isEmpty else { return nil }
            return BacktestChartComparisonSeries(
                id: series.id,
                title: series.title,
                points: sampledPoints,
                color: series.color
            )
        }
    }

    private var legendItems: [BacktestChartLegendItem] {
        BacktestChartData.legendItems(for: chartComparisonSeries)
    }

    private var availableSeriesIDs: [String] {
        legendItems.map(\.id)
    }

    private var effectiveVisibleSeriesIDs: Set<String> {
        let availableSet = Set(availableSeriesIDs)
        let visibleAvailableSeries = visibleSeriesIDs.intersection(availableSet)
        return visibleAvailableSeries.isEmpty ? availableSet : visibleAvailableSeries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            InteractiveBacktestChart(
                points: chartPoints,
                comparisonSeries: chartComparisonSeries,
                valueStyle: valueStyle,
                visibleSeriesIDs: effectiveVisibleSeriesIDs
            )

            if legendItems.count > 1 {
                BacktestChartLegendFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(legendItems) { series in
                        legendToggle(
                            series: series,
                            isVisible: effectiveVisibleSeriesIDs.contains(series.id),
                            canHide: effectiveVisibleSeriesIDs.count > 1
                        )
                    }
                }
                .padding(.top, -2)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if let footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggleSeries(_ seriesID: String) {
        let availableSet = Set(availableSeriesIDs)
        var nextVisibleSeries = effectiveVisibleSeriesIDs

        if nextVisibleSeries.contains(seriesID) {
            guard nextVisibleSeries.count > 1 else { return }
            nextVisibleSeries.remove(seriesID)
        } else {
            nextVisibleSeries.insert(seriesID)
        }

        visibleSeriesIDs = nextVisibleSeries.intersection(availableSet)
    }

    private func legendToggle(series: BacktestChartLegendItem, isVisible: Bool, canHide: Bool) -> some View {
        Button {
            guard !isVisible || canHide else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                toggleSeries(series.id)
            }
        } label: {
            HStack(spacing: 6) {
                if series.isDashed {
                    Capsule()
                        .stroke(series.color, style: StrokeStyle(lineWidth: 2.4, dash: [6, 4]))
                        .frame(width: 24, height: 7)
                } else {
                    Circle()
                        .fill(series.color)
                        .frame(width: 9, height: 9)
                }

                Text(series.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isVisible ? AssetTheme.textSecondary : AssetTheme.textSecondary.opacity(0.58))
                    .strikethrough(!isVisible, color: AssetTheme.textSecondary.opacity(0.72))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isVisible ? AssetTheme.overlaySoft : AssetTheme.overlayFaint, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(isVisible ? series.color.opacity(0.45) : AssetTheme.border.opacity(0.4), lineWidth: 1)
            )
            .opacity(isVisible ? 1 : 0.48)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isVisible && !canHide)
        .accessibilityLabel(series.title)
        .accessibilityHint(AppLocalization.string(isVisible ? "点击隐藏曲线" : "点击显示曲线"))
    }
}

private struct BacktestAllocationSlice: Identifiable {
    let title: String
    let amount: Double
    let color: Color

    var id: String { title }
}

private struct BacktestView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var marketStore: RemoteMarketStore
    let isActive: Bool
    @Query(sort: \BacktestRecord.createdAt, order: .reverse) private var backtestRecords: [BacktestRecord]
    @State private var selectedPage: BacktestPage = .history
    @State private var backtestMode: BacktestMode = .allocation
    @State private var cashWeight: Double = BacktestDefaults.cashWeight
    @State private var goldWeight: Double = BacktestDefaults.goldWeight
    @State private var indexWeights: [String: Double] = BacktestDefaults.indexWeights
    @State private var dcaAssetSymbol: String = BacktestDefaults.dcaAssetSymbol
    @State private var dcaContributionAmount: Double = BacktestDefaults.dcaContributionAmount
    @State private var dcaIntervalDays: Int = BacktestDefaults.dcaIntervalDays
    @State private var selectedStartDate: Date?
    @State private var selectedEndDate: Date?
    @State private var animationProgress: Double = 1
    @State private var showsAllocationSheet = false
    @State private var showsRangeSheet = false
    @State private var hasStartedBacktest = false
    @State private var hasPlayedInitialBacktestAnimation = false
    @State private var isBacktestLoading = false
    @State private var backtestRefreshToken = 0
    @State private var allocationReport: BacktestReport?
    @State private var dcaReport: DCABacktestReport?
    @State private var displayPoints: [BacktestSeriesPoint] = []
    @State private var cachedSelectedDCAAssetOption: BacktestAssetOption?
    @State private var cachedFilteredGoldSeries: PublicHistorySeries?
    @State private var cachedFilteredIndexSeriesBySymbol: [String: PublicHistorySeries] = [:]
    @State private var cachedFilteredDCASeries: PublicHistorySeries?
    @State private var cachedFilteredDCAFXSeries: PublicHistorySeries?
    @State private var cachedAvailableBacktestBounds: ClosedRange<Date>?
    @State private var cachedEffectiveBacktestBounds: ClosedRange<Date>?
    @State private var lastBacktestDataCacheToken: Int?
    @State private var pendingBacktestDataRefreshTask: Task<Void, Never>?
    @State private var pendingBacktestComputationTask: Task<Void, Never>?
    @State private var selectedBacktestRecord: BacktestRecord?
    @State private var pendingAdvancedRestoreRequest: AdvancedBacktestRestoreRequest?
    @State private var showsAdvancedStrategyLibrary = false
    @State private var lastSavedBacktestSignature: String?
    @State private var isRestoringBacktestRecord = false

    private enum DCAConfigSheet: String, Identifiable {
        case asset
        case amount
        case interval

        var id: String { rawValue }
    }

    private enum StandardBacktestComputationResult {
        case allocation(BacktestReport?)
        case dca(DCABacktestReport?)

        var points: [BacktestSeriesPoint] {
            switch self {
            case .allocation(let report):
                return report?.points ?? []
            case .dca(let report):
                return report?.points ?? []
            }
        }
    }

    @State private var activeDCAConfigSheet: DCAConfigSheet?

    private let indexOptions = BacktestDefaults.indexOptions
    private let dcaAssetOptions = BacktestDefaults.dcaAssetOptions
    private let strategyTemplates = AdvancedBacktestStrategyTemplate.all

    private var filteredGoldSeries: PublicHistorySeries? {
        cachedFilteredGoldSeries
    }

    private var filteredIndexSeriesBySymbol: [String: PublicHistorySeries] {
        cachedFilteredIndexSeriesBySymbol
    }

    private var positiveIndexOptions: [BacktestIndexOption] {
        indexOptions.filter { indexWeights[$0.symbol, default: 0] > 0 }
    }

    private var selectedDCAAssetOption: BacktestAssetOption? {
        cachedSelectedDCAAssetOption
    }

    private var filteredDCASeries: PublicHistorySeries? {
        cachedFilteredDCASeries
    }

    private var filteredDCAFXSeries: PublicHistorySeries? {
        cachedFilteredDCAFXSeries
    }

    private var animatedPoints: [BacktestSeriesPoint] {
        guard !displayPoints.isEmpty else { return [] }
        let count = max(Int(Double(displayPoints.count) * animationProgress), min(displayPoints.count, 2))
        return Array(displayPoints.prefix(count))
    }

    private var allocationSlices: [BacktestAllocationSlice] {
        [
            BacktestAllocationSlice(title: AppLocalization.string("现金"), amount: cashWeight, color: AssetTheme.textSecondary),
            BacktestAllocationSlice(title: AppLocalization.string("黄金"), amount: goldWeight, color: AssetTheme.gold)
        ] + positiveIndexOptions.map { option in
            BacktestAllocationSlice(title: option.title, amount: indexWeights[option.symbol, default: 0], color: option.color)
        }
        .filter { $0.amount > 0 }
    }

    private var activeAllocationSummary: String {
        let titles = allocationSlices.map(\.title)
        switch titles.count {
        case 0:
            return AppLocalization.string("未配置")
        case 1, 2:
            return titles.joined(separator: " + ")
        default:
            return AppLocalization.format("%d类资产", titles.count)
        }
    }

    private var availableBacktestBounds: ClosedRange<Date>? {
        cachedAvailableBacktestBounds
    }

    private var effectiveBacktestBounds: ClosedRange<Date>? {
        cachedEffectiveBacktestBounds
    }

    private var backtestDataCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(backtestMode.rawValue)
        hasher.combine(cashWeight)
        hasher.combine(goldWeight)
        hasher.combine(dcaAssetSymbol)
        hasher.combine(dcaContributionAmount)
        hasher.combine(dcaIntervalDays)
        hasher.combine(selectedStartDate?.timeIntervalSinceReferenceDate)
        hasher.combine(selectedEndDate?.timeIntervalSinceReferenceDate)

        let symbols = marketStore.historySeries.keys.sorted()
        hasher.combine(symbols.count)
        for symbol in symbols {
            guard let series = marketStore.historySeries[symbol] else { continue }
            hasher.combine(symbol)
            hasher.combine(series.dates.count)
            hasher.combine(series.dates.last)
            hasher.combine(series.prices.last)
            hasher.combine(series.currency)
        }
        return hasher.finalize()
    }

    private var selectedDateRangeLabel: String {
        guard let effectiveBacktestBounds else { return AppLocalization.string("调整时间") }
        return "\(effectiveBacktestBounds.lowerBound.recordDateString) - \(effectiveBacktestBounds.upperBound.recordDateString)"
    }

    private var selectedDateFilterToken: String {
        let startToken = selectedStartDate?.recordDateString ?? "nil"
        let endToken = selectedEndDate?.recordDateString ?? "nil"
        return "\(backtestMode.rawValue)|\(startToken)|\(endToken)"
    }

    private var hasActiveReport: Bool {
        switch backtestMode {
        case .allocation:
            return allocationReport != nil
        case .dca:
            return dcaReport != nil
        }
    }

    private var selectedTopTab: BacktestTopTab {
        switch selectedPage {
        case .advanced:
            return .advanced
        case .history:
            return .history
        case .standard:
            switch backtestMode {
            case .allocation:
                return .allocation
            case .dca:
                return .dca
            }
        }
    }

    private var topTabBinding: Binding<BacktestTopTab> {
        Binding(
            get: { selectedTopTab },
            set: { newValue in
                switch newValue {
                case .allocation:
                    selectedPage = .standard
                    backtestMode = .allocation
                case .dca:
                    selectedPage = .standard
                    backtestMode = .dca
                case .advanced:
                    selectedPage = .advanced
                case .history:
                    selectedPage = .history
                }
            }
        )
    }

    private var activeBacktestPageTitle: String {
        switch selectedPage {
        case .standard:
            return backtestMode.title
        case .advanced:
            return BacktestRecordKind.advanced.title
        case .history:
            return BacktestPage.history.title
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                GeometryReader { geometry in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            if selectedPage == .history {
                                BacktestHistoryView(
                                    records: backtestRecords,
                                    onStart: { kind in
                                        openBacktestPage(kind)
                                    },
                                    onSelect: { record in
                                        selectedBacktestRecord = record
                                    },
                                    onRestore: { record in
                                        restoreBacktestRecord(record)
                                    },
                                    onDelete: { record in
                                        deleteBacktestRecord(record)
                                    }
                                )
                            } else {
                                BacktestReturnHeader(title: activeBacktestPageTitle) {
                                    selectedPage = .history
                                }

                                if selectedPage == .advanced {
                                    AdvancedBacktestView(
                                        marketStore: marketStore,
                                        restoreRequest: pendingAdvancedRestoreRequest,
                                        showsStrategyLibrary: $showsAdvancedStrategyLibrary
                                    )
                                } else {
                                    VStack(spacing: 18) {
                                        if backtestMode == .allocation {
                                            BacktestAllocationCard(
                                                slices: allocationSlices,
                                                activeAllocationSummary: activeAllocationSummary,
                                                selectedDateRangeLabel: selectedDateRangeLabel,
                                                onTapRange: {
                                                    showsRangeSheet = true
                                                },
                                                onTapAllocation: {
                                                    showsAllocationSheet = true
                                                },
                                                onTapPrimaryAction: hasActiveReport ? nil : {
                                                    hasStartedBacktest = true
                                                    scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: true)
                                                }
                                            )
                                            .onboardingAnchor(.backtestConfiguration)
                                        } else {
                                            BacktestDCACard(
                                                assetTitle: AppLocalization.string(selectedDCAAssetOption?.title ?? "未选择资产"),
                                                amount: dcaContributionAmount,
                                                intervalDays: dcaIntervalDays,
                                                selectedDateRangeLabel: selectedDateRangeLabel,
                                                accent: selectedDCAAssetOption?.color ?? AssetTheme.gold,
                                                onTapRange: {
                                                    showsRangeSheet = true
                                                },
                                                onTapAsset: {
                                                    activeDCAConfigSheet = .asset
                                                },
                                                onTapAmount: {
                                                    activeDCAConfigSheet = .amount
                                                },
                                                onTapInterval: {
                                                    activeDCAConfigSheet = .interval
                                                },
                                                onTapPrimaryAction: hasActiveReport ? nil : {
                                                    hasStartedBacktest = true
                                                    scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: true)
                                                }
                                            )
                                            .onboardingAnchor(.backtestConfiguration)
                                        }

                                        if !isBacktestLoading, hasActiveReport {
                                            HStack(spacing: 10) {
                                                BacktestActionChip(title: AppLocalization.string("重置回测"), systemImage: "arrow.counterclockwise") {
                                                    resetBacktest()
                                                }
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity)

                                    if isBacktestLoading {
                                        BacktestLoadingView()
                                            .padding(.top, 8)
                                    }

                                    if !isBacktestLoading {
                                        switch backtestMode {
                                        case .allocation:
                                            if let allocationReport {
                                                allocationReportSection(report: allocationReport)
                                            }
                                        case .dca:
                                            if let dcaReport {
                                                dcaReportSection(report: dcaReport)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: max(0, geometry.size.width - 40), alignment: .topLeading)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, selectedPage == .advanced || selectedPage == .history || hasActiveReport ? 136 : 24)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showsAllocationSheet) {
                BacktestAllocationSheet(
                    cashWeight: cashWeight,
                    goldWeight: goldWeight,
                    indexWeights: indexWeights,
                    indexOptions: indexOptions
                ) { updatedCashWeight, updatedGoldWeight, updatedIndexWeights in
                    applyAllocation(
                        cashWeight: updatedCashWeight,
                        goldWeight: updatedGoldWeight,
                        indexWeights: updatedIndexWeights
                    )
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $activeDCAConfigSheet) { sheet in
                switch sheet {
                case .asset:
                    BacktestDCAAssetSheet(
                        selectedSymbol: dcaAssetSymbol,
                        assetOptions: dcaAssetOptions
                    ) { updatedSymbol in
                        applyDCAConfiguration(
                            assetSymbol: updatedSymbol,
                            contributionAmount: dcaContributionAmount,
                            intervalDays: dcaIntervalDays
                        )
                    }
                    .presentationDetents([.fraction(0.52), .large])
                    .presentationDragIndicator(.visible)
                case .amount:
                    BacktestDCAAmountSheet(amount: dcaContributionAmount) { updatedAmount in
                        applyDCAConfiguration(
                            assetSymbol: dcaAssetSymbol,
                            contributionAmount: updatedAmount,
                            intervalDays: dcaIntervalDays
                        )
                    }
                    .presentationDetents([.fraction(0.48), .large])
                    .presentationDragIndicator(.visible)
                case .interval:
                    BacktestDCAIntervalSheet(intervalDays: dcaIntervalDays) { updatedIntervalDays in
                        applyDCAConfiguration(
                            assetSymbol: dcaAssetSymbol,
                            contributionAmount: dcaContributionAmount,
                            intervalDays: updatedIntervalDays
                        )
                    }
                    .presentationDetents([.fraction(0.46), .large])
                    .presentationDragIndicator(.visible)
                }
            }
            .sheet(isPresented: $showsRangeSheet) {
                if let availableBacktestBounds, let effectiveBacktestBounds {
                    BacktestDateRangeSheet(
                        availableBounds: availableBacktestBounds,
                        selectedBounds: effectiveBacktestBounds
                    ) { startDate, endDate in
                        selectedStartDate = startDate
                        selectedEndDate = endDate
                    }
                    .presentationDetents([.fraction(0.82), .large])
                    .presentationDragIndicator(.visible)
                } else {
                    ContentUnavailableView(AppLocalization.string("暂无可用历史数据"), systemImage: "calendar.badge.exclamationmark")
                        .presentationDetents([.fraction(0.32)])
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(item: $selectedBacktestRecord) { record in
                BacktestRecordDetailView(
                    record: record,
                    onRestore: { restoredRecord in
                        restoreBacktestRecord(restoredRecord)
                        selectedBacktestRecord = nil
                    },
                    onDelete: { deletedRecord in
                        deleteBacktestRecord(deletedRecord)
                        selectedBacktestRecord = nil
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .task(id: isActive) {
            if isActive {
                if selectedPage != .history {
                    await marketStore.refreshHistoryIfNeeded()
                    guard !Task.isCancelled else { return }
                }
                scheduleBacktestDataRefresh(delayNanoseconds: 0)
                if hasStartedBacktest, !hasActiveReport {
                    scheduleBacktestRefresh(animated: !hasPlayedInitialBacktestAnimation)
                }
            } else {
                pendingBacktestDataRefreshTask?.cancel()
                pendingBacktestComputationTask?.cancel()
                pendingBacktestComputationTask = nil
                isBacktestLoading = false
            }
        }
        .onChange(of: selectedPage) { _, newValue in
            guard isActive, !isRestoringBacktestRecord else { return }
            if newValue != .history {
                Task { await marketStore.refreshHistoryIfNeeded() }
            }
            guard newValue == .standard else { return }
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: true)
        }
        .onChange(of: backtestMode) { _, _ in
            guard isActive, !isRestoringBacktestRecord, selectedPage == .standard else { return }
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: true)
        }
        .onChange(of: selectedDateFilterToken) { _, _ in
            guard isActive, !isRestoringBacktestRecord else { return }
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: true)
        }
        .onReceive(marketStore.$historySeries) { _ in
            guard isActive, !isRestoringBacktestRecord else { return }
            scheduleBacktestDataRefresh(delayNanoseconds: 40_000_000, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: !hasActiveReport && !hasPlayedInitialBacktestAnimation, saveRecord: true)
        }
    }

    @MainActor
    private func scheduleBacktestDataRefresh(delayNanoseconds: UInt64, force: Bool = false) {
        pendingBacktestDataRefreshTask?.cancel()
        pendingBacktestDataRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isActive else { return }
                refreshBacktestDataCacheIfNeeded(force: force)
            }
        }
    }

    @MainActor
    private func refreshBacktestDataCacheIfNeeded(force: Bool = false) {
        let token = backtestDataCacheToken
        guard force || token != lastBacktestDataCacheToken else { return }
        refreshBacktestDataCache()
        lastBacktestDataCacheToken = token
    }

    @MainActor
    private func refreshBacktestDataCache() {
        let selectedOption = dcaAssetOptions.first(where: { $0.symbol == dcaAssetSymbol })
        cachedSelectedDCAAssetOption = selectedOption

        let sourceSeries = resolveActiveBacktestSourceSeries(selectedOption: selectedOption)
        let bounds = BacktestEngine.availableDateBounds(for: sourceSeries)
        cachedAvailableBacktestBounds = bounds

        let effectiveBounds: ClosedRange<Date>?
        if let bounds {
            let start = max(selectedStartDate ?? bounds.lowerBound, bounds.lowerBound)
            let end = min(selectedEndDate ?? bounds.upperBound, bounds.upperBound)
            effectiveBounds = start <= end ? (start...end) : bounds
        } else {
            effectiveBounds = nil
        }
        cachedEffectiveBacktestBounds = effectiveBounds

        cachedFilteredGoldSeries = filteredHistorySeries(marketStore.history(for: "gold_cny"), within: effectiveBounds)
        cachedFilteredIndexSeriesBySymbol = Dictionary(uniqueKeysWithValues: indexOptions.compactMap { option in
            guard let series = filteredHistorySeries(marketStore.history(for: option.symbol), within: effectiveBounds) else { return nil }
            return (option.symbol, series)
        })
        cachedFilteredDCASeries = filteredHistorySeries(marketStore.history(for: dcaAssetSymbol), within: effectiveBounds)
        if let fxSymbol = selectedOption?.historicalFXSymbol {
            cachedFilteredDCAFXSeries = filteredHistorySeries(marketStore.history(for: fxSymbol), within: effectiveBounds)
        } else {
            cachedFilteredDCAFXSeries = nil
        }
    }

    private func resolveActiveBacktestSourceSeries(selectedOption: BacktestAssetOption?) -> [PublicHistorySeries] {
        if backtestMode == .dca {
            guard let assetSeries = marketStore.history(for: dcaAssetSymbol) else { return [] }
            guard let selectedOption else { return [assetSeries] }

            if let fxSymbol = selectedOption.historicalFXSymbol {
                guard let fxSeries = marketStore.history(for: fxSymbol) else { return [] }
                return [assetSeries, fxSeries]
            }

            return [assetSeries]
        }

        var series: [PublicHistorySeries] = []

        if goldWeight > 0, let goldSeries = marketStore.history(for: "gold_cny") {
            series.append(goldSeries)
        }

        series.append(contentsOf: positiveIndexOptions.compactMap { option in
            marketStore.history(for: option.symbol)
        })

        if !series.isEmpty {
            return series
        }

        if let goldSeries = marketStore.history(for: "gold_cny") {
            series.append(goldSeries)
        }

        series.append(contentsOf: indexOptions.compactMap { option in
            marketStore.history(for: option.symbol)
        })

        return series
    }

    @MainActor
    private func openBacktestPage(_ kind: BacktestRecordKind) {
        switch kind {
        case .allocation:
            selectedPage = .standard
            backtestMode = .allocation
        case .dca:
            selectedPage = .standard
            backtestMode = .dca
        case .advanced:
            selectedPage = .advanced
        }
    }

    private func applyAllocation(cashWeight: Double, goldWeight: Double, indexWeights: [String: Double]) {
        self.cashWeight = cashWeight
        self.goldWeight = goldWeight
        self.indexWeights = indexWeights

        if isActive {
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
        }
        guard hasStartedBacktest else { return }
        scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: true)
    }

    private func applyDCAConfiguration(assetSymbol: String, contributionAmount: Double, intervalDays: Int) {
        dcaAssetSymbol = assetSymbol
        dcaContributionAmount = contributionAmount
        dcaIntervalDays = intervalDays

        if isActive {
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
        }
        guard hasStartedBacktest else { return }
        scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: true)
    }

    @MainActor
    private func scheduleBacktestRefresh(
        animated: Bool,
        forceAnimation: Bool = false,
        showLoading: Bool = false,
        saveRecord: Bool = false
    ) {
        backtestRefreshToken += 1
        let currentToken = backtestRefreshToken
        pendingBacktestComputationTask?.cancel()
        pendingBacktestComputationTask = nil

        if showLoading {
            isBacktestLoading = true
        }

        let delayNanoseconds: UInt64 = showLoading ? 350_000_000 : 0
        pendingBacktestComputationTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            refreshBacktestDataCacheIfNeeded()
            let mode = backtestMode
            let capturedCashWeight = cashWeight
            let capturedGoldWeight = goldWeight
            let capturedGoldSeries = filteredGoldSeries
            let capturedIndexWeights = indexWeights
            let capturedIndexSeriesBySymbol = filteredIndexSeriesBySymbol
            let capturedDCASeries = filteredDCASeries
            let capturedDCAAssetOption = selectedDCAAssetOption ?? BacktestDefaults.dcaAssetOptions[0]
            let capturedDCAFXSeries = filteredDCAFXSeries
            let capturedDCAContributionAmount = dcaContributionAmount
            let capturedDCAIntervalDays = dcaIntervalDays

            let computationTask = Task.detached(priority: .userInitiated) { () -> StandardBacktestComputationResult in
                switch mode {
                case .allocation:
                    return .allocation(BacktestEngine.run(
                        cashWeight: capturedCashWeight,
                        goldWeight: capturedGoldWeight,
                        goldSeries: capturedGoldSeries,
                        indexWeights: capturedIndexWeights,
                        indexSeriesBySymbol: capturedIndexSeriesBySymbol
                    ))
                case .dca:
                    return .dca(BacktestEngine.runDCA(
                        assetSeries: capturedDCASeries,
                        assetOption: capturedDCAAssetOption,
                        fxSeries: capturedDCAFXSeries,
                        contributionAmount: capturedDCAContributionAmount,
                        intervalDays: capturedDCAIntervalDays
                    ))
                }
            }

            let result = await withTaskCancellationHandler {
                await computationTask.value
            } onCancel: {
                computationTask.cancel()
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard currentToken == backtestRefreshToken else { return }
                applyBacktestResult(result, animated: animated, forceAnimation: forceAnimation, saveRecord: saveRecord)
                isBacktestLoading = false
                pendingBacktestComputationTask = nil
            }
        }
    }

    @MainActor
    private func applyBacktestResult(_ result: StandardBacktestComputationResult, animated: Bool, forceAnimation: Bool = false, saveRecord: Bool = false) {
        switch result {
        case .allocation(let report):
            allocationReport = report
            dcaReport = nil
        case .dca(let report):
            dcaReport = report
            allocationReport = nil
        }

        displayPoints = sampledChartPoints(from: result.points)
        if saveRecord {
            saveCurrentBacktestRecordIfNeeded()
        }

        let shouldAnimate = animated && !displayPoints.isEmpty && (forceAnimation || !hasPlayedInitialBacktestAnimation)
        guard shouldAnimate else {
            animationProgress = 1
            return
        }

        hasPlayedInitialBacktestAnimation = true
        restartAnimation()
    }

    @MainActor
    private func saveCurrentBacktestRecordIfNeeded() {
        switch backtestMode {
        case .allocation:
            guard let report = allocationReport, !report.points.isEmpty else { return }
            let configSummary = allocationConfigSummary()
            let config = BacktestRecordConfigPayload(
                kind: .allocation,
                cashWeight: cashWeight,
                goldWeight: goldWeight,
                indexWeights: indexWeights
            )
            let record = BacktestRecord(
                kindRawValue: BacktestRecordKind.allocation.rawValue,
                title: BacktestRecordKind.allocation.title,
                subtitle: AppLocalization.format("%@ · %@", selectedDateRangeLabel, activeAllocationSummary),
                configSummary: configSummary,
                startDate: report.points.first?.date,
                endDate: report.points.last?.date,
                totalReturn: report.totalReturn,
                annualizedReturn: report.annualizedReturn,
                maxDrawdown: report.maxDrawdown,
                annualizedVolatility: report.annualizedVolatility,
                sharpeRatio: report.sharpeRatio,
                finalValue: report.points.last?.portfolioValue,
                tradeCount: 0,
                pointsJSON: BacktestRecordCodec.pointsData(from: report.points),
                configJSON: BacktestRecordCodec.configData(from: config)
            )
            insertBacktestRecord(record)
        case .dca:
            guard let report = dcaReport, !report.points.isEmpty else { return }
            let assetTitle = AppLocalization.string(selectedDCAAssetOption?.title ?? "单资产")
            let config = BacktestRecordConfigPayload(
                kind: .dca,
                dcaAssetSymbol: dcaAssetSymbol,
                dcaContributionAmount: dcaContributionAmount,
                dcaIntervalDays: dcaIntervalDays
            )
            let record = BacktestRecord(
                kindRawValue: BacktestRecordKind.dca.rawValue,
                title: BacktestRecordKind.dca.title,
                subtitle: AppLocalization.format("%@ · %@", selectedDateRangeLabel, assetTitle),
                configSummary: AppLocalization.format("%@ · 每%d天投入%@", assetTitle, dcaIntervalDays, dcaContributionAmount.currencyString()),
                startDate: report.points.first?.date,
                endDate: report.points.last?.date,
                totalReturn: report.totalReturn,
                annualizedReturn: report.annualizedReturn,
                maxDrawdown: report.maxDrawdown,
                annualizedVolatility: report.annualizedVolatility,
                sharpeRatio: report.sharpeRatio,
                finalValue: report.finalPortfolioValue,
                totalInvested: report.totalInvested,
                profitLoss: report.profitLoss,
                tradeCount: report.contributionCount,
                pointsJSON: BacktestRecordCodec.pointsData(from: report.points),
                configJSON: BacktestRecordCodec.configData(from: config)
            )
            insertBacktestRecord(record)
        }
    }

    @MainActor
    private func insertBacktestRecord(_ record: BacktestRecord) {
        let signature = [
            record.kindRawValue,
            record.subtitle,
            record.configSummary,
            record.startDate?.recordDateString ?? "nil",
            record.endDate?.recordDateString ?? "nil",
            String(format: "%.8f", record.totalReturn),
            String(format: "%.8f", record.maxDrawdown),
            String(format: "%.4f", record.finalValue ?? 0),
            String(record.tradeCount)
        ].joined(separator: "|")

        guard signature != lastSavedBacktestSignature else { return }
        lastSavedBacktestSignature = signature

        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            print("[AssetTimeMachine] save backtest record failed: \(error)")
        }
    }

    private func allocationConfigSummary() -> String {
        let parts = allocationSlices.map { slice in
            AppLocalization.format("%@ %.0f%%", slice.title, slice.amount)
        }
        return parts.isEmpty ? AppLocalization.string("未配置资产") : parts.joined(separator: " · ")
    }

    @MainActor
    private func deleteBacktestRecord(_ record: BacktestRecord) {
        modelContext.delete(record)
        do {
            try modelContext.save()
        } catch {
            print("[AssetTimeMachine] delete backtest record failed: \(error)")
        }
    }

    @MainActor
    private func restoreBacktestRecord(_ record: BacktestRecord) {
        guard let config = BacktestRecordCodec.decodeConfig(from: record) else { return }
        isRestoringBacktestRecord = true
        defer {
            Task { @MainActor in
                await Task.yield()
                isRestoringBacktestRecord = false
            }
        }

        switch config.kind {
        case .allocation:
            selectedPage = .standard
            backtestMode = .allocation
            cashWeight = config.cashWeight ?? BacktestDefaults.cashWeight
            goldWeight = config.goldWeight ?? BacktestDefaults.goldWeight
            indexWeights = config.indexWeights ?? BacktestDefaults.indexWeights
            selectedStartDate = record.startDate
            selectedEndDate = record.endDate
            hasStartedBacktest = true
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: false)
        case .dca:
            selectedPage = .standard
            backtestMode = .dca
            dcaAssetSymbol = config.dcaAssetSymbol ?? BacktestDefaults.dcaAssetSymbol
            dcaContributionAmount = config.dcaContributionAmount ?? BacktestDefaults.dcaContributionAmount
            dcaIntervalDays = config.dcaIntervalDays ?? BacktestDefaults.dcaIntervalDays
            selectedStartDate = record.startDate
            selectedEndDate = record.endDate
            hasStartedBacktest = true
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: false)
        case .advanced:
            selectedPage = .advanced
            pendingAdvancedRestoreRequest = AdvancedBacktestRestoreRequest(
                id: UUID(),
                config: config,
                startDate: record.startDate,
                endDate: record.endDate
            )
        }
    }

    private func resetBacktest() {
        backtestRefreshToken += 1
        hasStartedBacktest = false
        hasPlayedInitialBacktestAnimation = false
        isBacktestLoading = false
        backtestMode = .allocation
        cashWeight = BacktestDefaults.cashWeight
        goldWeight = BacktestDefaults.goldWeight
        indexWeights = BacktestDefaults.indexWeights
        dcaAssetSymbol = BacktestDefaults.dcaAssetSymbol
        dcaContributionAmount = BacktestDefaults.dcaContributionAmount
        dcaIntervalDays = BacktestDefaults.dcaIntervalDays
        selectedStartDate = nil
        selectedEndDate = nil
        allocationReport = nil
        dcaReport = nil
        displayPoints = []
        animationProgress = 1
    }

    private func restartAnimation() {
        animationProgress = 0.02
        withAnimation(.easeOut(duration: 1.6)) {
            animationProgress = 1
        }
    }

    private func intervalLabel(for report: BacktestReport) -> String {
        guard let first = report.points.first?.date, let last = report.points.last?.date else { return "--" }
        return "\(first.shortDateString) - \(last.shortDateString)"
    }

    private func filteredHistorySeries(_ series: PublicHistorySeries?, within bounds: ClosedRange<Date>? = nil) -> PublicHistorySeries? {
        BacktestEngine.filteredHistorySeries(series, within: bounds ?? effectiveBacktestBounds)
    }

    private func sampledChartPoints(from points: [BacktestSeriesPoint], maxCount: Int = 180) -> [BacktestSeriesPoint] {
        guard points.count > maxCount else { return points }

        let step = Double(points.count - 1) / Double(maxCount - 1)
        var sampled: [BacktestSeriesPoint] = []
        sampled.reserveCapacity(maxCount)

        for index in 0 ..< maxCount {
            let rawIndex = Int((Double(index) * step).rounded())
            let safeIndex = min(max(rawIndex, 0), points.count - 1)
            let point = points[safeIndex]
            if sampled.last?.date != point.date {
                sampled.append(point)
            }
        }

        if sampled.last?.date != points.last?.date, let last = points.last {
            sampled.append(last)
        }

        return sampled.enumerated().map { index, point in
            BacktestSeriesPoint(date: point.date, portfolioValue: point.portfolioValue, sequence: index)
        }
    }

    private func recoveryTimeLabel(for report: BacktestReport) -> String {
        guard report.maxDrawdown > 0 else { return "--" }
        guard let days = report.maxDrawdownRecoveryDays else { return AppLocalization.string("未修复") }
        if days >= 365 {
            let years = Double(days) / 365.25
            return AppLocalization.format("%.1f年", years)
        }
        return AppLocalization.format("%d天", days)
    }

    @ViewBuilder
    private func allocationReportSection(report: BacktestReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppLocalization.string("组合净值"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Spacer()
            }

            InteractiveBacktestChart(points: animatedPoints)
        }
        .padding(.top, 8)

        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalization.string("分析报告"))
                .font(.headline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                BacktestMetricCard(title: AppLocalization.string("总收益"), value: report.totalReturn.percentString())
                BacktestMetricCard(title: AppLocalization.string("年化收益"), value: report.annualizedReturn?.percentString() ?? "--")
                BacktestMetricCard(title: AppLocalization.string("最大回撤"), value: report.maxDrawdown.percentString(), accent: AssetTheme.negative)
                BacktestMetricCard(title: AppLocalization.string("修复时间"), value: recoveryTimeLabel(for: report))
                BacktestMetricCard(title: AppLocalization.string("年化波动"), value: report.annualizedVolatility?.percentString() ?? "--")
                BacktestMetricCard(title: AppLocalization.string("夏普比率"), value: report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                BacktestMetricCard(title: AppLocalization.string("区间"), value: intervalLabel(for: report))
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func dcaReportSection(report: DCABacktestReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppLocalization.string("定投市值"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Spacer()
            }

            InteractiveBacktestChart(points: animatedPoints, valueStyle: .currency(code: "CNY"))
        }
        .padding(.top, 8)

        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalization.string("分析报告"))
                .font(.headline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                BacktestMetricCard(title: AppLocalization.string("累计投入"), value: report.totalInvested.currencyString())
                BacktestMetricCard(title: AppLocalization.string("期末市值"), value: report.finalPortfolioValue.currencyString())
                BacktestMetricCard(
                    title: AppLocalization.string("累计盈亏"),
                    value: report.profitLoss.currencyString(),
                    accent: report.profitLoss >= 0 ? AssetTheme.positive : AssetTheme.negative
                )
                BacktestMetricCard(
                    title: AppLocalization.string("收益率"),
                    value: report.totalReturn.percentString(),
                    accent: report.totalReturn >= 0 ? AssetTheme.positive : AssetTheme.negative
                )
                BacktestMetricCard(title: AppLocalization.string("年化收益"), value: report.annualizedReturn?.percentString() ?? "--")
                BacktestMetricCard(title: AppLocalization.string("最大回撤"), value: report.maxDrawdown.percentString(), accent: AssetTheme.negative)
                BacktestMetricCard(title: AppLocalization.string("年化波动"), value: report.annualizedVolatility?.percentString() ?? "--")
                BacktestMetricCard(title: AppLocalization.string("夏普比率"), value: report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                BacktestMetricCard(title: AppLocalization.string("定投次数"), value: AppLocalization.format("%d次", report.contributionCount))
                BacktestMetricCard(title: AppLocalization.string("持有份额"), value: report.totalUnits.plainNumberString())
                BacktestMetricCard(title: AppLocalization.string("区间"), value: intervalLabel(points: report.points))
                BacktestMetricCard(title: AppLocalization.string("定投频率"), value: AppLocalization.format("每%d天", dcaIntervalDays))
            }
        }
        .padding(.top, 8)
    }

    private func intervalLabel(points: [BacktestSeriesPoint]) -> String {
        guard let first = points.first?.date, let last = points.last?.date else { return "--" }
        return "\(first.shortDateString) - \(last.shortDateString)"
    }

}

private struct BacktestAllocationCard: View {
    let slices: [BacktestAllocationSlice]
    let activeAllocationSummary: String
    let selectedDateRangeLabel: String
    let onTapRange: () -> Void
    let onTapAllocation: () -> Void
    let onTapPrimaryAction: (() -> Void)?

    private let chartSize: CGFloat = 148
    private let summaryCardWidth: CGFloat = 168

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: onTapRange) {
                    HStack(spacing: 8) {
                        Text(selectedDateRangeLabel)
                            .font(.headline.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(AssetTheme.textPrimary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)

                Button(action: onTapAllocation) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Button(action: onTapAllocation) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        Chart(slices) { slice in
                            SectorMark(
                                angle: .value(AppLocalization.string("占比"), slice.amount),
                                innerRadius: .ratio(0.72),
                                angularInset: 2
                            )
                            .foregroundStyle(slice.color)
                        }
                        .frame(width: chartSize, height: chartSize)
                        .chartLegend(.hidden)

                        VStack(spacing: 4) {
                            Text(activeAllocationSummary)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AssetTheme.textPrimary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.72)
                        }
                        .padding(.horizontal, 14)
                    }
                    .frame(width: chartSize, height: chartSize)

                    VStack(spacing: 0) {
                        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                            BacktestAllocationRow(slice: slice, showsDivider: index < slices.count - 1)
                        }
                    }
                    .frame(width: summaryCardWidth, height: chartSize, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .buttonStyle(.plain)

            if let onTapPrimaryAction {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(AssetTheme.border.opacity(0.34))
                        .frame(height: 1)
                        .padding(.horizontal, 18)

                    HStack {
                        BacktestPrimaryActionButton(title: AppLocalization.string("开始回测"), systemImage: "play.fill", action: onTapPrimaryAction)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .onboardingAnchor(.backtestStart)
            }
        }
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.04), AssetTheme.overlaySoft.opacity(0.3), Color.black.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.1), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.1), radius: 16, y: 8)
        .frame(maxWidth: .infinity)
    }
}

private struct BacktestAllocationRow: View {
    let slice: BacktestAllocationSlice
    let showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(slice.color)
                    .frame(width: 9, height: 9)

                Text(AppLocalization.string(slice.title))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(Int(slice.amount.rounded()))%")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if showsDivider {
                Rectangle()
                    .fill(AssetTheme.border.opacity(0.45))
                    .frame(height: 1)
                    .padding(.leading, 33)
            }
        }
    }
}

private struct BacktestTopTabPicker: View {
    @Binding var selectedTab: BacktestTopTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(BacktestTopTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.title)
                        .font(selectedTab == tab ? .subheadline.weight(.semibold) : .subheadline.weight(.medium))
                        .foregroundStyle(selectedTab == tab ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selectedTab == tab
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.1), AssetTheme.overlayMedium.opacity(0.96)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(selectedTab == tab ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1)
                        )
                        .shadow(color: selectedTab == tab ? Color.black.opacity(0.16) : .clear, radius: 8, y: 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.025), AssetTheme.overlaySoft.opacity(0.52)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct CashYieldDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let summary: CashYieldSummary

    private var periodText: String {
        guard let startDate = summary.startDate, let endDate = summary.endDate else {
            return AppLocalization.string("全部可用区间")
        }
        return "\(startDate.recordDateString) - \(endDate.recordDateString)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                        Text(summary.sourceDetail)
                            .font(.footnote)
                            .foregroundStyle(AssetTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        CashYieldMetricTile(
                            title: AppLocalization.string("现金利息"),
                            value: summary.totalCashInterest.currencyString(),
                            accent: AssetTheme.positive
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("平均现金仓"),
                            value: summary.averageCashRatio.percentString(maxFractionDigits: 1)
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("区间平均年利率"),
                            value: summary.averageAnnualRate.percentString(maxFractionDigits: 2)
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("最新年利率"),
                            value: summary.latestAnnualRate.percentString(maxFractionDigits: 2),
                            subtitle: summary.latestRateDate?.recordDateString
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLocalization.string("数据来源"))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                        Text(summary.source)
                            .font(.footnote)
                            .foregroundStyle(AssetTheme.textSecondary)
                        Text(AppLocalization.format("适用区间 %@", periodText))
                            .font(.caption)
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.9))
                    }
                    .padding(14)
                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AssetTheme.border.opacity(0.5), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text(AppLocalization.string("历史活期利率"))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)

                        VStack(spacing: 0) {
                            ForEach(summary.ratePoints.indices, id: \.self) { index in
                                let point = summary.ratePoints[index]
                                HStack(spacing: 12) {
                                    Text(point.date.recordDateString)
                                        .font(.footnote.weight(.medium).monospacedDigit())
                                        .foregroundStyle(AssetTheme.textPrimary)
                                    Spacer(minLength: 12)
                                    Text(point.annualRate.percentString(maxFractionDigits: 2))
                                        .font(.footnote.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(AssetTheme.gold)
                                }
                                .padding(.vertical, 10)

                                if index < summary.ratePoints.count - 1 {
                                    Divider()
                                        .overlay(AssetTheme.border.opacity(0.45))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(AssetTheme.border.opacity(0.5), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(AssetTheme.background.ignoresSafeArea())
            .navigationTitle(AppLocalization.string("现金利率明细"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct MarketRiskSignalDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let summary: MarketRiskSignalSummary

    private var latestLevel: MarketRiskSignalLevel {
        summary.latestPoint?.level ?? .calm
    }

    private var periodText: String {
        guard let startDate = summary.startDate, let endDate = summary.endDate else {
            return AppLocalization.string("全部可用区间")
        }
        return "\(startDate.recordDateString) - \(endDate.recordDateString)"
    }

    private var displayPoints: [MarketRiskSignalPoint] {
        Array(summary.signalPoints.reversed())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                        Text(summary.sourceDetail)
                            .font(.footnote)
                            .foregroundStyle(AssetTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        CashYieldMetricTile(
                            title: AppLocalization.string("当前状态"),
                            value: latestLevel.title,
                            subtitle: summary.latestPoint?.date.recordDateString,
                            accent: latestLevel.accent
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("当前分数"),
                            value: summary.latestPoint.map { String(format: "%.0f", $0.score) } ?? "--",
                            accent: latestLevel.accent
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("压力日占比"),
                            value: summary.stressSessionRatio.percentString(maxFractionDigits: 1)
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("区间平均分"),
                            value: String(format: "%.0f", summary.averageScore)
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLocalization.string("数据来源"))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                        Text(summary.source)
                            .font(.footnote)
                            .foregroundStyle(AssetTheme.textSecondary)
                        Text(AppLocalization.format("适用区间 %@", periodText))
                            .font(.caption)
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.9))
                    }
                    .padding(14)
                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AssetTheme.border.opacity(0.5), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text(AppLocalization.string("历史风险信号"))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)

                        VStack(spacing: 0) {
                            ForEach(displayPoints.indices, id: \.self) { index in
                                let point = displayPoints[index]
                                marketRiskSignalPointRow(point)

                                if index < displayPoints.count - 1 {
                                    Divider()
                                        .overlay(AssetTheme.border.opacity(0.45))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(AssetTheme.border.opacity(0.5), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(AssetTheme.background.ignoresSafeArea())
            .navigationTitle(AppLocalization.string("风险信号明细"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func marketRiskSignalPointRow(_ point: MarketRiskSignalPoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(point.date.recordDateString)
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(point.level.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(point.level.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(point.level.accent.opacity(0.12), in: Capsule())

                Spacer(minLength: 10)

                Text(String(format: "%.0f", point.score))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(point.level.accent)
            }

            Text(AppLocalization.format(
                "5日%@ · 21日%@ · 回撤%@ · 波动%@",
                point.shortReturn?.percentString(maxFractionDigits: 1) ?? "--",
                point.monthlyReturn?.percentString(maxFractionDigits: 1) ?? "--",
                point.drawdownFromHigh?.percentString(maxFractionDigits: 1) ?? "--",
                point.annualizedVolatility?.percentString(maxFractionDigits: 1) ?? "--"
            ))
            .font(.caption)
            .foregroundStyle(AssetTheme.textSecondary)
            .lineLimit(1)
        }
        .padding(.vertical, 10)
    }
}

private struct CashYieldMetricTile: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var accent: Color = AssetTheme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(accent)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AssetTheme.overlaySoft.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.42), lineWidth: 1)
        )
    }
}

private struct AdvancedBacktestView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var marketStore: RemoteMarketStore
    let restoreRequest: AdvancedBacktestRestoreRequest?
    @Binding var showsStrategyLibrary: Bool
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @State private var selectedAssetSymbols: Set<String> = [BacktestDefaults.dcaAssetSymbol]
    @State private var initialCash: Double = 100_000
    @State private var tradeAmount: Double = 10_000
    @State private var feeRate: Double = 0.1
    @State private var slippageRate: Double = 0.05
    @State private var maxPositionRatio: Double = 70
    @State private var cooldownDays: Double = 3
    @State private var stopLossRatio: Double = 0
    @State private var takeProfitRatio: Double = 0
    @State private var strategyMode: AdvancedBacktestStrategyMode = .ruleBased
    @State private var buyDirection: AdvancedBacktestSignalDirection = .consecutiveDown
    @State private var buyDays: Int = 3
    @State private var sellDirection: AdvancedBacktestSignalDirection = .consecutiveUp
    @State private var sellDays: Int = 3
    @State private var selectedStartDate: Date?
    @State private var selectedEndDate: Date?
    @State private var showsRangeSheet = false
    @State private var showsAssetSheet = false
    @State private var showsCashYieldSheet = false
    @State private var showsRiskSignalSheet = false
    @State private var hasStartedBacktest = false
    @State private var report: AdvancedBacktestReport?
    @State private var rebalanceAdvice: StrategyRebalanceAdvice?
    @State private var bestCandidates: [AdvancedBacktestCandidate] = []
    @State private var hasOptimizedStrategies = false
    @State private var isRefreshingReport = false
    @State private var isOptimizingStrategies = false
    @State private var pendingRefreshTask: Task<Void, Never>?
    @State private var pendingReportComputationTask: Task<AdvancedBacktestComputationResult, Never>?
    @State private var pendingOptimizationComputationTask: Task<[AdvancedBacktestCandidate], Never>?
    @State private var lastSavedAdvancedBacktestSignature: String?

    private var assetOptions: [BacktestAssetOption] {
        BacktestDefaults.dcaAssetOptions
    }

    private var latestSnapshot: AssetSnapshot? {
        snapshots.first
    }

    private var strategyTemplates: [AdvancedBacktestStrategyTemplate] {
        AdvancedBacktestStrategyTemplate.all
    }

    private var activeStrategyTemplateID: String? {
        strategyTemplates.first(where: isStrategyTemplateActive)?.id
    }

    private var buySignalOptions: [AdvancedBacktestSignalDirection] {
        AdvancedBacktestSignalDirection.allCases.filter(\.isBuySignalOption)
    }

    private var sellSignalOptions: [AdvancedBacktestSignalDirection] {
        AdvancedBacktestSignalDirection.allCases.filter(\.isSellSignalOption)
    }

    private var selectedAssetOptions: [BacktestAssetOption] {
        let selected = assetOptions.filter { selectedAssetSymbols.contains($0.symbol) }
        return selected.isEmpty ? Array(assetOptions.prefix(1)) : selected
    }

    private var calculationAssetOptions: [BacktestAssetOption] {
        var options = selectedAssetOptions
        var symbols = Set(options.map(\.symbol))
        for signalSymbol in strategyMode.requiredSignalAssetSymbols where !symbols.contains(signalSymbol) {
            if let option = assetOptions.first(where: { $0.symbol == signalSymbol }) {
                options.append(option)
                symbols.insert(signalSymbol)
            }
        }
        return options
    }

    private var selectedAssetSummary: String {
        let titles = selectedAssetOptions.map { AppLocalization.string($0.title) }
        switch titles.count {
        case 0:
            return AppLocalization.string("未选择资产")
        case 1, 2:
            return titles.joined(separator: " + ")
        default:
            return AppLocalization.format("%d种资产", titles.count)
        }
    }

    private var selectedAssetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)] {
        calculationAssetOptions.map { option in
            (
                assetSeries: marketStore.history(for: option.symbol),
                assetOption: option,
                fxSeries: option.historicalFXSymbol.flatMap { marketStore.history(for: $0) }
            )
        }
    }

    private var availableDateBounds: ClosedRange<Date>? {
        let sourceSeries = calculationAssetOptions.flatMap { option -> [PublicHistorySeries] in
            var series: [PublicHistorySeries] = []
            if let assetSeries = marketStore.history(for: option.symbol) {
                series.append(assetSeries)
            }
            if let fxSymbol = option.historicalFXSymbol,
               let fxSeries = marketStore.history(for: fxSymbol) {
                series.append(fxSeries)
            }
            return series
        }
        return BacktestEngine.availableDateBounds(for: sourceSeries)
    }

    private var displayDateBounds: ClosedRange<Date>? {
        if let effectiveDateBounds {
            return effectiveDateBounds
        }

        if let start = selectedStartDate, let end = selectedEndDate {
            return min(start, end)...max(start, end)
        }

        if let firstSeries = selectedAssetInputs.compactMap(\.assetSeries).first,
           let assetBounds = BacktestEngine.availableDateBounds(for: [firstSeries]) {
            return assetBounds
        }

        return availableDateBounds
    }

    private var effectiveDateBounds: ClosedRange<Date>? {
        guard let bounds = availableDateBounds else { return nil }
        let start = max(selectedStartDate ?? bounds.lowerBound, bounds.lowerBound)
        let end = min(selectedEndDate ?? bounds.upperBound, bounds.upperBound)
        return start <= end ? (start...end) : bounds
    }

    private var selectedDateRangeLabel: String {
        guard let displayDateBounds else { return "--" }
        return "\(displayDateBounds.lowerBound.recordDateString) - \(displayDateBounds.upperBound.recordDateString)"
    }

    private var riskSettings: AdvancedBacktestRiskSettings {
        AdvancedBacktestRiskSettings(
            feeRate: feeRate,
            slippageRate: slippageRate,
            maxPositionRatio: maxPositionRatio,
            cooldownDays: Int(cooldownDays.rounded()),
            stopLossRatio: stopLossRatio,
            takeProfitRatio: takeProfitRatio
        )
    }

    private var refreshToken: String {
        [
            selectedAssetOptions.map(\.symbol).joined(separator: ","),
            String(initialCash),
            String(tradeAmount),
            String(feeRate),
            String(slippageRate),
            String(maxPositionRatio),
            String(cooldownDays),
            String(stopLossRatio),
            String(takeProfitRatio),
            strategyMode.rawValue,
            buyDirection.rawValue,
            String(buyDays),
            sellDirection.rawValue,
            String(sellDays),
            selectedStartDate?.recordDateString ?? "nil",
            selectedEndDate?.recordDateString ?? "nil"
        ].joined(separator: ":")
    }

    private var unavailableResultState: (message: String, isLoading: Bool) {
        if isRefreshingReport {
            return (AppLocalization.string("正在计算回测…"), true)
        }

        if selectedAssetInputs.contains(where: { $0.assetSeries == nil }) {
            if marketStore.isLoading {
                return (AppLocalization.string("正在加载历史数据…"), true)
            }
            return (AppLocalization.string("部分资产历史数据暂时不可用，请稍后再试"), false)
        }

        if selectedAssetInputs.contains(where: { $0.assetOption.requiresHistoricalFX && $0.fxSeries == nil }) {
            if marketStore.isLoading {
                return (AppLocalization.string("正在加载汇率数据…"), true)
            }
            return (AppLocalization.string("部分资产汇率数据暂时不可用，请稍后再试"), false)
        }

        let filteredInputs = selectedAssetInputs.map { input in
            (
                assetSeries: filteredHistorySeries(input.assetSeries, within: effectiveDateBounds),
                assetOption: input.assetOption,
                fxSeries: filteredHistorySeries(input.fxSeries, within: effectiveDateBounds)
            )
        }
        if filteredInputs.contains(where: { $0.assetSeries == nil }) {
            return (AppLocalization.string("当前回测区间内部分资产历史数据不足"), false)
        }

        if filteredInputs.contains(where: { $0.assetOption.requiresHistoricalFX && $0.fxSeries == nil }) {
            return (AppLocalization.string("当前回测区间内部分汇率数据不足"), false)
        }

        return (AppLocalization.string("当前数据暂时无法完成回测"), false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            configSection

            if hasStartedBacktest {
                advancedStartedContent
            }
        }
        .sheet(isPresented: $showsAssetSheet) {
            AdvancedBacktestAssetPickerSheet(
                selectedSymbols: selectedAssetSymbols,
                assetOptions: assetOptions
            ) { updatedSymbols in
                selectedAssetSymbols = updatedSymbols.isEmpty ? [BacktestDefaults.dcaAssetSymbol] : updatedSymbols
            }
            .presentationDetents([.fraction(0.62), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsRangeSheet) {
            if let availableDateBounds, let effectiveDateBounds {
                BacktestDateRangeSheet(
                    availableBounds: availableDateBounds,
                    selectedBounds: effectiveDateBounds
                ) { startDate, endDate in
                    selectedStartDate = startDate
                    selectedEndDate = endDate
                }
            }
        }
        .sheet(isPresented: $showsStrategyLibrary) {
            AdvancedStrategyLibrarySheet(
                templates: strategyTemplates,
                activeTemplateID: activeStrategyTemplateID
            ) { template in
                applyStrategyTemplate(template)
                showsStrategyLibrary = false
            }
            .presentationDetents([.fraction(0.72), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsCashYieldSheet) {
            if let report {
                CashYieldDetailSheet(summary: report.cashYieldSummary)
                    .presentationDetents([.fraction(0.58), .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showsRiskSignalSheet) {
            if let report, let riskSignalSummary = report.riskSignalSummary {
                MarketRiskSignalDetailSheet(summary: riskSignalSummary)
                    .presentationDetents([.fraction(0.62), .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: refreshToken) { _, _ in
            guard hasStartedBacktest else { return }
            scheduleRefresh(delayNanoseconds: 120_000_000)
        }
        .onReceive(marketStore.$historySeries) { _ in
            guard hasStartedBacktest else { return }
            scheduleRefresh(delayNanoseconds: 80_000_000)
        }
        .onReceive(marketStore.$isLoading) { isLoading in
            guard hasStartedBacktest, !isLoading else { return }
            scheduleRefresh(delayNanoseconds: 40_000_000)
        }
        .onDisappear {
            cancelPendingAdvancedBacktestTasks()
        }
        .task(id: restoreRequest?.id) {
            guard let restoreRequest else { return }
            await MainActor.run {
                applyRestoreRequest(restoreRequest)
            }
        }
    }

    @ViewBuilder
    private var advancedStartedContent: some View {
        if let report {
            resultSection(report)
            if strategyMode == .ruleBased {
                bestStrategySection()
            }
            tradeSection(report)
        } else {
            let state = unavailableResultState
            advancedPanel {
                if state.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AssetTheme.gold)

                        Text(state.message)
                            .font(.subheadline)
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(state.message)
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(AppLocalization.string("策略设置"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 12)

                Button {
                    showsStrategyLibrary = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.bold))
                        Text(AppLocalization.string("策略大全"))
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AssetTheme.gold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(AssetTheme.overlaySoft, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AssetTheme.gold.opacity(0.36), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            advancedPanel {
                advancedButtonRow(
                    title: AppLocalization.string("回测资产"),
                    value: selectedAssetSummary,
                    showsDivider: true
                ) {
                    showsAssetSheet = true
                }

                advancedButtonRow(
                    title: AppLocalization.string("回测区间"),
                    value: selectedDateRangeLabel,
                    showsDivider: true
                ) {
                    guard availableDateBounds != nil else { return }
                    showsRangeSheet = true
                }

                advancedNumericInputRow(
                    title: AppLocalization.string("初始资金"),
                    value: $initialCash,
                    placeholder: AppLocalization.string("例如 100000"),
                    showsDivider: true
                )

                advancedPairedNumericInputRow(
                    leadingTitle: AppLocalization.string("交易费率"),
                    leadingValue: $feeRate,
                    leadingPlaceholder: AppLocalization.string("例如 0.1"),
                    leadingUnit: "%",
                    trailingTitle: AppLocalization.string("滑点"),
                    trailingValue: $slippageRate,
                    trailingPlaceholder: AppLocalization.string("例如 0.05"),
                    trailingUnit: "%",
                    showsDivider: true
                )

                if strategyMode.isRotation {
                    advancedStaticRow(
                        title: AppLocalization.string("策略模式"),
                        value: strategyMode.title,
                        showsDivider: true
                    )

                    advancedStaticRow(
                        title: AppLocalization.string("轮动规则"),
                        value: strategyMode.ruleSummary,
                        showsDivider: false
                    )
                } else {
                    advancedNumericInputRow(
                        title: AppLocalization.string("单次买入金额"),
                        value: $tradeAmount,
                        placeholder: AppLocalization.string("例如 10000"),
                        showsDivider: true
                    )

                    advancedPairedNumericInputRow(
                        leadingTitle: AppLocalization.string("最大仓位"),
                        leadingValue: $maxPositionRatio,
                        leadingPlaceholder: AppLocalization.string("例如 70"),
                        leadingUnit: "%",
                        trailingTitle: AppLocalization.string("冷却天数"),
                        trailingValue: $cooldownDays,
                        trailingPlaceholder: AppLocalization.string("例如 3"),
                        trailingUnit: AppLocalization.string("天"),
                        showsDivider: true
                    )

                    advancedPairedNumericInputRow(
                        leadingTitle: AppLocalization.string("止损线"),
                        leadingValue: $stopLossRatio,
                        leadingPlaceholder: AppLocalization.string("0为关闭"),
                        leadingUnit: "%",
                        trailingTitle: AppLocalization.string("止盈线"),
                        trailingValue: $takeProfitRatio,
                        trailingPlaceholder: AppLocalization.string("0为关闭"),
                        trailingUnit: "%",
                        showsDivider: true
                    )

                    advancedRuleRow(
                        title: AppLocalization.string("买入条件"),
                        direction: $buyDirection,
                        days: $buyDays,
                        options: buySignalOptions,
                        accent: AssetTheme.positive,
                        showsDivider: false
                    )

                    advancedRuleSwapRow()

                    advancedRuleRow(
                        title: AppLocalization.string("卖出条件"),
                        direction: $sellDirection,
                        days: $sellDays,
                        options: sellSignalOptions,
                        accent: AssetTheme.accentOrange,
                        showsDivider: false
                    )
                }
            }

            BacktestPrimaryActionButton(
                title: hasStartedBacktest ? AppLocalization.string("重新回测") : AppLocalization.string("开始回测"),
                systemImage: hasStartedBacktest ? "arrow.clockwise" : "play.fill"
            ) {
                hasStartedBacktest = true
                scheduleRefresh(delayNanoseconds: 0)
            }
        }
    }

    private func isStrategyTemplateActive(_ template: AdvancedBacktestStrategyTemplate) -> Bool {
        if strategyMode != template.mode { return false }
        if let selectedSymbols = template.selectedAssetSymbols,
           selectedAssetSymbols != Set(selectedSymbols) {
            return false
        }

        if template.mode.isRotation {
            return abs(feeRate - 0.1) < 0.01
                && abs(slippageRate - 0.05) < 0.01
        }

        let expectedTradeAmount = max(initialCash * template.tradeAmountRatio, 1)
        let tradeTolerance = max(expectedTradeAmount * 0.005, 1)

        return buyDirection == template.buyRule.direction
            && buyDays == template.buyRule.days
            && sellDirection == template.sellRule.direction
            && sellDays == template.sellRule.days
            && abs(tradeAmount - expectedTradeAmount) <= tradeTolerance
            && abs(maxPositionRatio - template.maxPositionRatio) < 0.01
            && abs(slippageRate - 0.05) < 0.01
            && abs(cooldownDays - Double(template.cooldownDays)) < 0.01
            && abs(stopLossRatio - template.stopLossRatio) < 0.01
            && abs(takeProfitRatio - template.takeProfitRatio) < 0.01
    }

    private func applyStrategyTemplate(_ template: AdvancedBacktestStrategyTemplate) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            strategyMode = template.mode
            if let selectedSymbols = template.selectedAssetSymbols {
                selectedAssetSymbols = Set(selectedSymbols)
            }
            buyDirection = template.buyRule.direction
            buyDays = template.buyRule.days
            sellDirection = template.sellRule.direction
            sellDays = template.sellRule.days
            tradeAmount = max(initialCash * template.tradeAmountRatio, 1)
            slippageRate = 0.05
            maxPositionRatio = template.maxPositionRatio
            cooldownDays = Double(template.cooldownDays)
            stopLossRatio = template.stopLossRatio
            takeProfitRatio = template.takeProfitRatio
        }
    }

    private var advancedBacktestExecutionAssumptionText: String {
        let timingText = strategyMode.isRotation
            ? AppLocalization.string("轮动策略使用上一交易日信号、下一调仓日收盘价成交")
            : AppLocalization.string("条件信号使用上一交易日收盘确认、下一交易日收盘价成交")
        return AppLocalization.format(
            "%@；已计入%.2f%%交易费和%.2f%%滑点。",
            timingText,
            feeRate,
            slippageRate
        )
    }

    private func resultSection(_ report: AdvancedBacktestReport) -> some View {
        let comparisonSeries = benchmarkComparisonSeries(from: report)
        let benchmarkMetricTitle = report.benchmarkSeries.count == 1
            ? (report.benchmarkSeries.first?.title ?? AppLocalization.string("资产基准"))
            : AppLocalization.string("资产基准")

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 16) {
                BacktestValueChartSection(
                    points: report.points,
                    comparisonSeries: comparisonSeries,
                    valueStyle: .currency(code: "CNY"),
                    footnote: advancedBacktestExecutionAssumptionText
                )

                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))

                rebalanceAdviceSection(rebalanceAdvice)

                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    BacktestMetricCard(title: AppLocalization.string("期末资产"), value: report.finalPortfolioValue.currencyString())
                    BacktestMetricCard(title: AppLocalization.string("盈亏"), value: report.profitLoss.currencyString(), accent: report.profitLoss >= 0 ? AssetTheme.positive : AssetTheme.negative)
                    BacktestMetricCard(title: AppLocalization.string("策略收益"), value: report.totalReturn.percentString(), accent: report.totalReturn >= 0 ? AssetTheme.positive : AssetTheme.negative)
                    BacktestMetricCard(title: benchmarkMetricTitle, value: report.benchmarkTotalReturn?.percentString() ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("超额收益"), value: report.excessReturn?.percentString() ?? "--", accent: (report.excessReturn ?? 0) >= 0 ? AssetTheme.positive : AssetTheme.negative)
                    BacktestMetricCard(title: AppLocalization.string("年化收益"), value: report.annualizedReturn?.percentString() ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("最大回撤"), value: report.maxDrawdown.percentString(), accent: AssetTheme.negative)
                    BacktestMetricCard(title: AppLocalization.string("年化波动"), value: report.annualizedVolatility?.percentString() ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("夏普比率"), value: report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("回撤收益比"), subtitle: AppLocalization.string("Calmar"), value: report.calmarRatio.map { String(format: "%.2f", $0) } ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("平均仓位"), value: report.averageExposureRatio.percentString())
                    BacktestMetricCard(title: AppLocalization.string("交易次数"), value: AppLocalization.format("买%d · 卖%d", report.buyCount, report.sellCount))
                    BacktestMetricCard(
                        title: AppLocalization.string("胜率"),
                        subtitle: report.completedTradeCount > 0 ? AppLocalization.format("赢%d / 平仓%d", report.winningTradeCount, report.completedTradeCount) : nil,
                        value: report.winRate?.percentString(maxFractionDigits: 0) ?? "--",
                        accent: (report.winRate ?? 0) >= 0.5 ? AssetTheme.positive : AssetTheme.textPrimary
                    )
                    BacktestMetricCard(title: AppLocalization.string("剩余现金"), value: report.finalCash.currencyString())
                }

                cashYieldInfoRow(report.cashYieldSummary)
                if let riskSignalSummary = report.riskSignalSummary {
                    riskSignalInfoRow(riskSignalSummary)
                }

                if report.assetReports.count > 1 {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.6))

                    VStack(alignment: .leading, spacing: 10) {
                        Text(AppLocalization.string("分资产结果"))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)

                        ForEach(report.assetReports) { assetReport in
                            assetReportRow(assetReport)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, -8)
        }
    }

    private func cashYieldInfoRow(_ summary: CashYieldSummary) -> some View {
        Button {
            showsCashYieldSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "banknote")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.gold)
                    .frame(width: 28, height: 28)
                    .background(AssetTheme.gold.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.string("现金收益按活期计息"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AssetTheme.textPrimary)
                    Text(AppLocalization.format(
                        "现金利息%@ · 平均现金仓%@ · 最新年利率%@",
                        summary.totalCashInterest.currencyString(),
                        summary.averageCashRatio.percentString(maxFractionDigits: 1),
                        summary.latestAnnualRate.percentString(maxFractionDigits: 2)
                    ))
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 10)

                Text(AppLocalization.string("明细"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AssetTheme.gold)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.65))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func riskSignalInfoRow(_ summary: MarketRiskSignalSummary) -> some View {
        Button {
            showsRiskSignalSheet = true
        } label: {
            HStack(spacing: 10) {
                let latestLevel = summary.latestPoint?.level ?? .calm
                Image(systemName: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(latestLevel.accent)
                    .frame(width: 28, height: 28)
                    .background(latestLevel.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.string("外部风险信号"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AssetTheme.textPrimary)
                    Text(AppLocalization.format(
                        "当前%@ · 压力日%@ · 平均分%.0f",
                        latestLevel.title,
                        summary.stressSessionRatio.percentString(maxFractionDigits: 1),
                        summary.averageScore
                    ))
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 10)

                Text(AppLocalization.string("明细"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(latestLevel.accent)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.65))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func rebalanceAdviceSection(_ advice: StrategyRebalanceAdvice?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(AppLocalization.string("今日调仓建议"))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 12)

                Text(rebalanceAdviceTrailingText(advice))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(strategyMode.isRotation ? AssetTheme.textSecondary : AssetTheme.accentOrange)
                    .lineLimit(1)
            }

            if strategyMode.isRotation {
                if let advice {
                    let actions = rebalanceActions(for: advice)

                    Text(rebalanceAdviceSummary(advice, actions: actions))
                        .font(.footnote)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        if actions.isEmpty {
                            rebalanceCashRow(
                                weight: 1,
                                title: AppLocalization.string("现金防守"),
                                detail: AppLocalization.string("当前没有资产满足策略条件")
                            )
                        } else {
                            ForEach(actions) { action in
                                rebalanceActionRow(action, lookbackSessions: advice.lookbackSessions)
                            }

                            if advice.cashWeight > 0.005 {
                                rebalanceCashRow(
                                    weight: advice.cashWeight,
                                    title: AppLocalization.string("现金/其他"),
                                    detail: AppLocalization.string("未投入部分保留为防守仓位")
                                )
                            }
                        }
                    }

                } else {
                    Text(AppLocalization.string("当前资产数据不足，暂时无法计算今日目标仓位。"))
                        .font(.footnote)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            } else {
                Text(AppLocalization.string("自定义策略暂不支持即时调仓建议；建议先使用策略大全里的轮动/长期策略。"))
                    .font(.footnote)
                    .foregroundStyle(AssetTheme.textSecondary)
            }
        }
    }

    private func rebalanceAdviceTrailingText(_ advice: StrategyRebalanceAdvice?) -> String {
        if let advice {
            return AppLocalization.format("信号截至 %@", advice.asOfDate.recordDateString)
        }
        return strategyMode.isRotation ? AppLocalization.string("等待数据") : AppLocalization.string("暂不支持")
    }

    private func rebalanceAdviceSummary(_ advice: StrategyRebalanceAdvice, actions: [StrategyRebalanceAction]) -> String {
        let basePrefix: String
        if let investmentBase = actions.compactMap(\.investmentBase).first, investmentBase > 0 {
            basePrefix = AppLocalization.format("按最新记录%@估算；", investmentBase.currencyString())
        } else if latestSnapshot == nil {
            basePrefix = AppLocalization.string("暂无资产记录；")
        } else {
            basePrefix = AppLocalization.string("当前记录缺少可投资资产；")
        }

        if advice.isCashDefense && actions.isEmpty {
            return basePrefix + AppLocalization.format(
                "%d日信号未通过，策略建议暂不投入。",
                advice.lookbackSessions
            )
        }

        if let targetAnnualVolatility = advice.targetAnnualVolatility {
            return basePrefix + AppLocalization.format(
                "目标投入 %@，现金 %@；按%d日信号、目标波动%@评估。",
                advice.totalTargetWeight.percentString(maxFractionDigits: 1),
                advice.cashWeight.percentString(maxFractionDigits: 1),
                advice.lookbackSessions,
                targetAnnualVolatility.percentString(maxFractionDigits: 1)
            )
        }

        return basePrefix + AppLocalization.format(
            "目标投入 %@，现金 %@；按%d日信号评估。",
            advice.totalTargetWeight.percentString(maxFractionDigits: 1),
            advice.cashWeight.percentString(maxFractionDigits: 1),
            advice.lookbackSessions
        )
    }

    private func rebalanceActionRow(_ action: StrategyRebalanceAction, lookbackSessions: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(colorForStrategySymbol(action.symbol))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(rebalanceActionDetail(action, lookbackSessions: lookbackSessions))
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(action.kind.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(action.kind.accent)

                Text(rebalanceActionAmountText(action))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(action.kind.accent)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func rebalanceActionDetail(_ action: StrategyRebalanceAction, lookbackSessions: Int) -> String {
        let currentText = action.currentWeight.map { AppLocalization.format("当前 %@", $0.percentString(maxFractionDigits: 1)) }
            ?? (action.isMatched ? AppLocalization.string("当前 --") : AppLocalization.string("未记录"))
        let targetText = AppLocalization.format("目标 %@", action.targetWeight.percentString(maxFractionDigits: 1))
        let signalText: String
        if let momentum = action.momentum {
            signalText = AppLocalization.format(" · %d日动量 %@", lookbackSessions, momentum.percentString(maxFractionDigits: 1))
        } else {
            signalText = ""
        }
        return "\(currentText) · \(targetText)\(signalText)"
    }

    private func rebalanceActionAmountText(_ action: StrategyRebalanceAction) -> String {
        switch action.kind {
        case .buy, .sell:
            return (abs(action.deltaAmount ?? 0)).currencyString()
        case .missingRecord:
            if let targetAmount = action.targetAmount {
                return AppLocalization.format("需 %@", targetAmount.currencyString())
            }
            return action.targetWeight.percentString(maxFractionDigits: 1)
        case .hold:
            return AppLocalization.string("偏离小")
        case .targetOnly:
            return action.targetWeight.percentString(maxFractionDigits: 1)
        }
    }

    private func rebalanceAllocationRow(_ allocation: StrategyRebalanceAllocation, lookbackSessions: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(colorForStrategySymbol(allocation.symbol))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(allocation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(rebalanceAllocationDetail(allocation, lookbackSessions: lookbackSessions))
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(allocation.targetWeight.percentString(maxFractionDigits: 1))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(AssetTheme.goldSoft)
        }
        .padding(.vertical, 2)
    }

    private func rebalanceCashRow(weight: Double, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .stroke(AssetTheme.textSecondary.opacity(0.55), lineWidth: 1.5)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(weight.percentString(maxFractionDigits: 1))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(AssetTheme.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func rebalanceAllocationDetail(_ allocation: StrategyRebalanceAllocation, lookbackSessions: Int) -> String {
        let momentumText = AppLocalization.format(
            "%d日动量 %@",
            lookbackSessions,
            allocation.momentum.percentString(maxFractionDigits: 1)
        )
        if let annualizedVolatility = allocation.annualizedVolatility {
            return AppLocalization.format(
                "%@ · 波动 %@",
                momentumText,
                annualizedVolatility.percentString(maxFractionDigits: 1)
            )
        }
        return momentumText
    }

    private func colorForStrategySymbol(_ symbol: String) -> Color {
        assetOptions.first(where: { $0.symbol == symbol })?.color ?? AssetTheme.gold
    }

    private func rebalanceActions(for advice: StrategyRebalanceAdvice) -> [StrategyRebalanceAction] {
        StrategyRebalanceActionBuilder.actions(
            for: advice,
            snapshot: latestSnapshot,
            selectedAssetOptions: selectedAssetOptions,
            allAssetOptions: assetOptions
        )
    }

    private func benchmarkComparisonSeries(from report: AdvancedBacktestReport) -> [BacktestChartComparisonSeries] {
        let sourceSeries: [AdvancedBacktestBenchmarkSeries]
        if !report.benchmarkSeries.isEmpty {
            sourceSeries = report.benchmarkSeries
        } else {
            sourceSeries = report.assetReports.map {
                AdvancedBacktestBenchmarkSeries(id: $0.symbol, title: $0.title, points: $0.benchmarkPoints)
            }
        }

        return sourceSeries.enumerated().compactMap { index, series in
            let points = BacktestChartData.normalizedComparisonPoints(
                series.points,
                targetStartValue: report.points.first?.portfolioValue
            )
            guard !points.isEmpty else { return nil }
            return BacktestChartComparisonSeries(
                id: "asset-benchmark-\(series.id)",
                title: series.title,
                points: points,
                color: BacktestChartPalette.comparisonLine(at: index)
            )
        }
    }

    private func assetReportRow(_ assetReport: AdvancedBacktestAssetReport) -> some View {
        let initialValue = assetReport.points.first?.portfolioValue ?? 0
        let assetReturn = initialValue > 0 ? (assetReport.finalPortfolioValue - initialValue) / initialValue : 0
        let tradeCounts = assetReport.trades.reduce(into: (buy: 0, sell: 0)) { counts, trade in
            switch trade.action {
            case .buy:
                counts.buy += 1
            case .sell:
                counts.sell += 1
            }
        }

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(assetReport.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Text(AppLocalization.format("买%d · 卖%d", tradeCounts.buy, tradeCounts.sell))
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(assetReport.finalPortfolioValue.currencyString())
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Text(assetReturn.percentString())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(assetReturn >= 0 ? AssetTheme.positive : AssetTheme.negative)
            }
        }
        .padding(12)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func bestStrategySection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                AppLocalization.string("智能优选策略"),
                trailing: AppLocalization.string("手动扫描 · 综合排序"),
                trailingColor: AssetTheme.gold
            )

            advancedPanel {
                if isOptimizingStrategies {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AssetTheme.gold)
                        Text(AppLocalization.string("正在寻找候选策略…"))
                            .font(.subheadline)
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if bestCandidates.isEmpty {
                        Text(AppLocalization.string(hasOptimizedStrategies ? "暂无可用候选策略，请调整资产或区间后重试" : "需要时再扫描候选策略，避免回测结束卡顿"))
                            .font(.subheadline)
                            .foregroundStyle(AssetTheme.textSecondary)
                    } else {
                        ForEach(Array(bestCandidates.enumerated()), id: \.element.id) { index, candidate in
                            Button {
                                applyCandidate(candidate)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("#\(index + 1)")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(AssetTheme.gold)
                                        Spacer()
                                        Text(candidate.report.totalReturn.percentString())
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(candidate.report.totalReturn >= 0 ? AssetTheme.positive : AssetTheme.negative)
                                    }

                                    Text(AppLocalization.format(
                                        "单次%@ · 仓位%.0f%% · 费率%.2f%% · 滑点%.2f%% · 年化%@ · 回撤%@ · 夏普%@",
                                        candidate.tradeAmount.currencyString(),
                                        candidate.settings.maxPositionRatio,
                                        candidate.settings.feeRate,
                                        candidate.settings.slippageRate,
                                        candidate.report.annualizedReturn?.percentString() ?? "--",
                                        candidate.report.maxDrawdown.percentString(),
                                        candidate.report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--"
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(AssetTheme.textSecondary)
                                    .lineLimit(2)

                                    HStack(spacing: 6) {
                                        ForEach(candidateTags(for: candidate), id: \.self) { tag in
                                            candidateTagPill(tag)
                                        }
                                    }
                                    .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .overlay(AssetTheme.border.opacity(0.6))
                        }
                    }

                    BacktestActionChip(
                        title: bestCandidates.isEmpty ? "扫描候选策略" : "重新扫描",
                        systemImage: bestCandidates.isEmpty ? "sparkles" : "arrow.clockwise"
                    ) {
                        optimizeStrategies()
                    }
                    .disabled(isRefreshingReport)
                    .opacity(isRefreshingReport ? 0.55 : 1)
                }
            }
        }
    }

    private func candidateTags(for candidate: AdvancedBacktestCandidate) -> [String] {
        var tags: [String] = []
        if candidate.report.excessReturn ?? 0 > 0 {
            tags.append(AppLocalization.string("跑赢持有"))
        }
        if candidate.report.maxDrawdown <= 0.18 {
            tags.append(AppLocalization.string("低回撤"))
        }
        if (candidate.report.sharpeRatio ?? 0) >= 1 {
            tags.append(AppLocalization.string("高夏普"))
        }
        if candidate.report.trades.count <= 8 {
            tags.append(AppLocalization.string("低频"))
        }
        if tags.isEmpty {
            tags.append(AppLocalization.string("候选"))
        }
        return Array(tags.prefix(3))
    }

    private func candidateTagPill(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AssetTheme.gold)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(AssetTheme.gold.opacity(0.1), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(AssetTheme.gold.opacity(0.18), lineWidth: 1)
            )
    }

    private func tradeSection(_ report: AdvancedBacktestReport) -> some View {
        let recentTrades = Array(report.trades.suffix(6).reversed())

        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(AppLocalization.string("最近交易"))

            advancedPanel {
                if report.trades.isEmpty {
                    Text(AppLocalization.string("暂无成交"))
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(recentTrades.enumerated()), id: \.element.id) { index, trade in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(trade.action.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(trade.action.accent)
                                Text("\(trade.assetTitle) · \(trade.date.shortDateString) · \(trade.price.currencyString())")
                                    .font(.footnote)
                                    .foregroundStyle(AssetTheme.textSecondary)
                                if !trade.reason.isEmpty {
                                    Text(AppLocalization.format("触发：%@", trade.reason))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.78))
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text((trade.action == .buy ? "-" : "+") + trade.cashAmount.currencyString())
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AssetTheme.textPrimary)
                                Text(AppLocalization.format("%@份", trade.units.plainNumberString()))
                                    .font(.footnote)
                                    .foregroundStyle(AssetTheme.textSecondary)
                                if let realizedProfit = trade.realizedProfit {
                                    Text("\(realizedProfit >= 0 ? "+" : "")\(realizedProfit.currencyString())")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(realizedProfit >= 0 ? AssetTheme.positive : AssetTheme.negative)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if index < recentTrades.count - 1 {
                            Divider()
                                .overlay(AssetTheme.border.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func cancelPendingAdvancedBacktestTasks() {
        pendingRefreshTask?.cancel()
        pendingReportComputationTask?.cancel()
        pendingOptimizationComputationTask?.cancel()
        pendingRefreshTask = nil
        pendingReportComputationTask = nil
        pendingOptimizationComputationTask = nil
        isRefreshingReport = false
        isOptimizingStrategies = false
    }

    @MainActor
    private func scheduleRefresh(delayNanoseconds: UInt64, saveRecord: Bool = true) {
        pendingRefreshTask?.cancel()
        pendingReportComputationTask?.cancel()
        pendingOptimizationComputationTask?.cancel()
        pendingReportComputationTask = nil
        pendingOptimizationComputationTask = nil

        let capturedAssetInputs = selectedAssetInputs
        guard !capturedAssetInputs.isEmpty,
              capturedAssetInputs.allSatisfy({ $0.assetSeries != nil && (!$0.assetOption.requiresHistoricalFX || $0.fxSeries != nil) }) else {
            report = nil
            rebalanceAdvice = nil
            bestCandidates = []
            hasOptimizedStrategies = false
            isRefreshingReport = false
            isOptimizingStrategies = false
            pendingRefreshTask = nil
            return
        }

        let capturedDateBounds = effectiveDateBounds
        let capturedInitialCash = self.initialCash
        let capturedTradeAmount = self.tradeAmount
        let capturedStrategyMode = self.strategyMode
        let buyRule = AdvancedBacktestRule(direction: buyDirection, days: buyDays)
        let sellRule = AdvancedBacktestRule(direction: sellDirection, days: sellDays)
        let capturedRiskSettings = self.riskSettings

        isRefreshingReport = true
        bestCandidates = []
        hasOptimizedStrategies = false
        isOptimizingStrategies = false
        pendingRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            let computationTask = Task.detached(priority: .userInitiated) { () -> AdvancedBacktestComputationResult in
                let filteredAssetInputs = BacktestEngine.filteredAdvancedAssetInputs(capturedAssetInputs, within: capturedDateBounds)
                guard !Task.isCancelled,
                      !filteredAssetInputs.isEmpty,
                      filteredAssetInputs.allSatisfy({ $0.assetSeries != nil && (!$0.assetOption.requiresHistoricalFX || $0.fxSeries != nil) }) else {
                    return AdvancedBacktestComputationResult(report: nil, rebalanceAdvice: nil)
                }

                let advice = capturedStrategyMode.isRotation
                    ? BacktestEngine.advancedRotationRebalanceAdvice(
                        assetInputs: capturedAssetInputs,
                        mode: capturedStrategyMode
                    )
                    : nil

                let report: AdvancedBacktestReport?
                if capturedStrategyMode.isRotation {
                    report = BacktestEngine.runAdvancedRotationStrategy(
                        assetInputs: filteredAssetInputs,
                        initialCash: capturedInitialCash,
                        settings: capturedRiskSettings,
                        mode: capturedStrategyMode
                    )
                } else {
                    report = BacktestEngine.runAdvancedStrategies(
                        assetInputs: filteredAssetInputs,
                        initialCash: capturedInitialCash,
                        tradeAmount: capturedTradeAmount,
                        buyRule: buyRule,
                        sellRule: sellRule,
                        settings: capturedRiskSettings
                    )
                }

                return AdvancedBacktestComputationResult(report: report, rebalanceAdvice: advice)
            }
            await MainActor.run {
                pendingReportComputationTask = computationTask
            }

            let refreshedResult = await withTaskCancellationHandler {
                await computationTask.value
            } onCancel: {
                computationTask.cancel()
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                pendingReportComputationTask = nil
                report = refreshedResult.report
                rebalanceAdvice = refreshedResult.rebalanceAdvice
                if saveRecord {
                    saveAdvancedBacktestRecordIfNeeded(refreshedResult.report)
                }
                bestCandidates = []
                hasOptimizedStrategies = false
                isRefreshingReport = false
                isOptimizingStrategies = false
                pendingRefreshTask = nil
            }
        }
    }

    @MainActor
    private func optimizeStrategies() {
        guard !isRefreshingReport, !isOptimizingStrategies else { return }
        pendingRefreshTask?.cancel()
        pendingReportComputationTask?.cancel()
        pendingOptimizationComputationTask?.cancel()
        pendingReportComputationTask = nil
        pendingOptimizationComputationTask = nil

        let capturedAssetInputs = selectedAssetInputs
        guard !capturedAssetInputs.isEmpty,
              capturedAssetInputs.allSatisfy({ $0.assetSeries != nil && (!$0.assetOption.requiresHistoricalFX || $0.fxSeries != nil) }) else {
            bestCandidates = []
            hasOptimizedStrategies = true
            isOptimizingStrategies = false
            pendingRefreshTask = nil
            return
        }

        let capturedDateBounds = effectiveDateBounds
        let capturedInitialCash = self.initialCash
        let capturedRiskSettings = self.riskSettings

        bestCandidates = []
        hasOptimizedStrategies = false
        isOptimizingStrategies = true
        pendingRefreshTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }

            let computationTask = Task.detached(priority: .utility) { () -> [AdvancedBacktestCandidate] in
                let filteredAssetInputs = BacktestEngine.filteredAdvancedAssetInputs(capturedAssetInputs, within: capturedDateBounds)
                guard !Task.isCancelled,
                      !filteredAssetInputs.isEmpty,
                      filteredAssetInputs.allSatisfy({ $0.assetSeries != nil && (!$0.assetOption.requiresHistoricalFX || $0.fxSeries != nil) }) else {
                    return []
                }

                return BacktestEngine.optimizeAdvancedStrategies(
                    assetInputs: filteredAssetInputs,
                    initialCash: capturedInitialCash,
                    baseSettings: capturedRiskSettings,
                    limit: 3
                )
            }
            await MainActor.run {
                pendingOptimizationComputationTask = computationTask
            }

            let optimizedCandidates = await withTaskCancellationHandler {
                await computationTask.value
            } onCancel: {
                computationTask.cancel()
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                pendingOptimizationComputationTask = nil
                bestCandidates = optimizedCandidates
                hasOptimizedStrategies = true
                isOptimizingStrategies = false
                pendingRefreshTask = nil
            }
        }
    }

    @MainActor
    private func saveAdvancedBacktestRecordIfNeeded(_ report: AdvancedBacktestReport?) {
        guard let report, !report.points.isEmpty else { return }
        let config = BacktestRecordConfigPayload(
            kind: .advanced,
            selectedAssetSymbol: selectedAssetOptions.first?.symbol,
            selectedAssetSymbols: selectedAssetOptions.map(\.symbol),
            initialCash: initialCash,
            tradeAmount: tradeAmount,
            feeRate: feeRate,
            slippageRate: slippageRate,
            maxPositionRatio: maxPositionRatio,
            cooldownDays: Int(cooldownDays.rounded()),
            stopLossRatio: stopLossRatio,
            takeProfitRatio: takeProfitRatio,
            strategyModeRawValue: strategyMode.rawValue,
            buyDirectionRawValue: buyDirection.rawValue,
            buyDays: buyDays,
            sellDirectionRawValue: sellDirection.rawValue,
            sellDays: sellDays,
            advancedTrades: BacktestRecordCodec.advancedTradePayloads(from: report.trades),
            advancedAssetCharts: BacktestRecordCodec.advancedAssetChartPayloads(from: report.assetReports),
            advancedBenchmarkSeries: BacktestRecordCodec.advancedBenchmarkSeriesPayloads(from: report.benchmarkSeries)
        )
        let configSummary = advancedConfigSummary()
        let record = BacktestRecord(
            kindRawValue: BacktestRecordKind.advanced.rawValue,
            title: BacktestRecordKind.advanced.title,
            subtitle: strategyMode.title,
            configSummary: configSummary,
            startDate: report.points.first?.date,
            endDate: report.points.last?.date,
            totalReturn: report.totalReturn,
            annualizedReturn: report.annualizedReturn,
            maxDrawdown: report.maxDrawdown,
            annualizedVolatility: report.annualizedVolatility,
            sharpeRatio: report.sharpeRatio,
            finalValue: report.finalPortfolioValue,
            totalInvested: initialCash,
            profitLoss: report.finalPortfolioValue - initialCash,
            tradeCount: report.buyCount + report.sellCount,
            pointsJSON: BacktestRecordCodec.pointsData(from: report.points),
            configJSON: BacktestRecordCodec.configData(from: config)
        )
        insertAdvancedBacktestRecord(record)
    }

    @MainActor
    private func insertAdvancedBacktestRecord(_ record: BacktestRecord) {
        let signature = [
            record.kindRawValue,
            record.subtitle,
            record.configSummary,
            record.startDate?.recordDateString ?? "nil",
            record.endDate?.recordDateString ?? "nil",
            String(format: "%.8f", record.totalReturn),
            String(format: "%.8f", record.maxDrawdown),
            String(format: "%.4f", record.finalValue ?? 0),
            String(record.tradeCount)
        ].joined(separator: "|")

        guard signature != lastSavedAdvancedBacktestSignature else { return }
        lastSavedAdvancedBacktestSignature = signature

        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            print("[AssetTimeMachine] save advanced backtest record failed: \(error)")
        }
    }

    private func advancedConfigSummary() -> String {
        if strategyMode.isRotation {
            return AppLocalization.format(
                "%@ · %@ · 费率%.2f%% · 滑点%.2f%%",
                strategyMode.title,
                strategyMode.ruleSummary,
                feeRate,
                slippageRate
            )
        }

        return AppLocalization.format(
            "%@ · %@ · 单次%@ · 仓位%.0f%% · 费率%.2f%% · 滑点%.2f%%",
            advancedRuleSummary(direction: buyDirection, days: buyDays),
            advancedRuleSummary(direction: sellDirection, days: sellDays),
            tradeAmount.currencyString(),
            maxPositionRatio,
            feeRate,
            slippageRate
        )
    }

    @MainActor
    private func applyRestoreRequest(_ request: AdvancedBacktestRestoreRequest) {
        let config = request.config
        let restoredSymbols = config.selectedAssetSymbols ?? config.selectedAssetSymbol.map { [$0] } ?? [BacktestDefaults.dcaAssetSymbol]
        selectedAssetSymbols = Set(restoredSymbols).isEmpty ? [BacktestDefaults.dcaAssetSymbol] : Set(restoredSymbols)
        initialCash = config.initialCash ?? 100_000
        tradeAmount = config.tradeAmount ?? 10_000
        feeRate = config.feeRate ?? 0.1
        slippageRate = config.slippageRate ?? 0.05
        maxPositionRatio = config.maxPositionRatio ?? 70
        cooldownDays = Double(config.cooldownDays ?? 3)
        stopLossRatio = config.stopLossRatio ?? 0
        takeProfitRatio = config.takeProfitRatio ?? 0
        strategyMode = .ruleBased
        buyDirection = config.buyDirectionRawValue.flatMap(AdvancedBacktestSignalDirection.init(rawValue:)) ?? .consecutiveDown
        buyDays = config.buyDays ?? 3
        sellDirection = config.sellDirectionRawValue.flatMap(AdvancedBacktestSignalDirection.init(rawValue:)) ?? .consecutiveUp
        sellDays = config.sellDays ?? 3
        selectedStartDate = request.startDate
        selectedEndDate = request.endDate
        hasStartedBacktest = true
        bestCandidates = []
        hasOptimizedStrategies = false
        isOptimizingStrategies = false
        scheduleRefresh(delayNanoseconds: 0, saveRecord: false)
    }

    private func filteredHistorySeries(_ series: PublicHistorySeries?, within bounds: ClosedRange<Date>?) -> PublicHistorySeries? {
        BacktestEngine.filteredHistorySeries(series, within: bounds)
    }

    private func sectionHeader(_ title: String, trailing: String? = nil, trailingColor: Color = AssetTheme.textSecondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)
            Spacer()
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(trailingColor)
                    .lineLimit(1)
            }
        }
    }

    private func advancedPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AssetTheme.surface.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
        )
    }

    private func advancedMenuRow<Content: View>(title: String, value: String, accent: Color = AssetTheme.textPrimary, showsDivider: Bool, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AssetTheme.textSecondary)
                    Spacer()
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .padding(.vertical, 2)

                if showsDivider {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.6))
                        .padding(.top, 14)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func advancedNumericInputRow(
        title: String,
        value: Binding<Double>,
        placeholder: String,
        unit: String = AppLocalization.string("元"),
        showsDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AssetTheme.textSecondary)

                Spacer(minLength: 12)

                TextField(
                    placeholder,
                    value: Binding(
                        get: { value.wrappedValue },
                        set: { value.wrappedValue = max($0, 0) }
                    ),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(minWidth: 110, maxWidth: 160)

                Text(unit)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
            }
            .padding(.vertical, 2)

            if showsDivider {
                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))
                    .padding(.top, 14)
            }
        }
    }

    private func advancedPairedNumericInputRow(
        leadingTitle: String,
        leadingValue: Binding<Double>,
        leadingPlaceholder: String,
        leadingUnit: String,
        trailingTitle: String,
        trailingValue: Binding<Double>,
        trailingPlaceholder: String,
        trailingUnit: String,
        showsDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                advancedCompactNumericInput(
                    title: leadingTitle,
                    value: leadingValue,
                    placeholder: leadingPlaceholder,
                    unit: leadingUnit
                )

                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))
                    .frame(height: 24)

                advancedCompactNumericInput(
                    title: trailingTitle,
                    value: trailingValue,
                    placeholder: trailingPlaceholder,
                    unit: trailingUnit
                )
            }
            .padding(.vertical, 2)

            if showsDivider {
                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))
                    .padding(.top, 14)
            }
        }
    }

    private func advancedCompactNumericInput(
        title: String,
        value: Binding<Double>,
        placeholder: String,
        unit: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)

            Spacer(minLength: 6)

            TextField(
                placeholder,
                value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = max($0, 0) }
                ),
                format: .number.precision(.fractionLength(0...2))
            )
            .keyboardType(.decimalPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AssetTheme.textPrimary)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(minWidth: 44, maxWidth: 72)

            Text(unit)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func advancedStaticRow(title: String, value: String, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AssetTheme.textSecondary)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 2)

            if showsDivider {
                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))
                    .padding(.top, 14)
            }
        }
    }

    private func advancedButtonRow(title: String, value: String, showsDivider: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AssetTheme.textSecondary)
                    Spacer()
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AssetTheme.textPrimary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .padding(.vertical, 2)

                if showsDivider {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.6))
                        .padding(.top, 14)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func advancedRuleRow(title: String, direction: Binding<AdvancedBacktestSignalDirection>, days: Binding<Int>, options: [AdvancedBacktestSignalDirection], accent: Color, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Menu {
                        Picker("", selection: direction) {
                            ForEach(options) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .labelsHidden()
                    } label: {
                        HStack(spacing: 8) {
                            Text(direction.wrappedValue.title)
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(AssetTheme.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if direction.wrappedValue.usesDayThreshold {
                        Stepper(value: days, in: 1...10) {
                            Text(AppLocalization.format("%d天", days.wrappedValue))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AssetTheme.textPrimary)
                        }
                        .tint(accent)
                    } else {
                        Text(AppLocalization.string("固定参数"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                }
            }
            .accessibilityLabel(title)

            if showsDivider {
                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))
                    .padding(.top, 14)
            }
        }
    }

    private func advancedRuleSwapRow() -> some View {
        VStack(spacing: 12) {
            Divider()
                .overlay(AssetTheme.border.opacity(0.6))

            HStack {
                Spacer()

                Button(action: swapAdvancedRules) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption.weight(.bold))
                        Text(AppLocalization.string("互换条件"))
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AssetTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AssetTheme.overlaySubtle, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()
            }

            Divider()
                .overlay(AssetTheme.border.opacity(0.6))
        }
    }

    private func swapAdvancedRules() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            let originalBuyDirection = buyDirection
            let originalBuyDays = buyDays
            let originalSellDirection = sellDirection
            let originalSellDays = sellDays
            buyDirection = originalSellDirection.isBuySignalOption ? originalSellDirection : .alwaysBuy
            buyDays = originalSellDirection.isBuySignalOption ? originalSellDays : 1
            sellDirection = originalBuyDirection.isSellSignalOption ? originalBuyDirection : .neverSell
            sellDays = originalBuyDirection.isSellSignalOption ? originalBuyDays : 1
        }
    }

    private func applyCandidate(_ candidate: AdvancedBacktestCandidate) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            strategyMode = .ruleBased
            buyDirection = candidate.buyRule.direction
            buyDays = candidate.buyRule.days
            sellDirection = candidate.sellRule.direction
            sellDays = candidate.sellRule.days
            tradeAmount = candidate.tradeAmount
            feeRate = candidate.settings.feeRate
            slippageRate = candidate.settings.slippageRate
            maxPositionRatio = candidate.settings.maxPositionRatio
            cooldownDays = Double(candidate.settings.cooldownDays)
            stopLossRatio = candidate.settings.stopLossRatio
            takeProfitRatio = candidate.settings.takeProfitRatio
            report = candidate.report
            saveAdvancedBacktestRecordIfNeeded(candidate.report)
        }
    }

    private func advancedRuleSummary(direction: AdvancedBacktestSignalDirection, days: Int) -> String {
        if direction.usesDayThreshold {
            return AppLocalization.format("%@ %d天", direction.title, days)
        }

        return direction.title
    }
}

private struct BacktestModeEntryPanel: View {
    let onStart: (BacktestRecordKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(BacktestRecordKind.allCases.enumerated()), id: \.element.rawValue) { index, kind in
                    Button {
                        onStart(kind)
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: kind.entryIconName)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AssetTheme.gold)
                                .frame(height: 20)

                            Text(kind.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AssetTheme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < BacktestRecordKind.allCases.count - 1 {
                        Divider()
                            .overlay(AssetTheme.border.opacity(0.55))
                            .frame(height: 54)
                    }
                }
            }
            .background(AssetTheme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.62), lineWidth: 1)
            )
        }
    }
}

private struct BacktestReturnHeader: View {
    let title: String
    var trailingTitle: String? = nil
    var trailingSystemImage: String? = nil
    var onTrailingAction: (() -> Void)? = nil
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                    Text(AppLocalization.string("记录"))
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(AssetTheme.gold)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(AssetTheme.gold.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let trailingTitle, let onTrailingAction {
                Button(action: onTrailingAction) {
                    HStack(spacing: 6) {
                        if let trailingSystemImage {
                            Image(systemName: trailingSystemImage)
                                .font(.caption.weight(.bold))
                        }
                        Text(trailingTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(AssetTheme.textPrimary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 11)
                    .background(AssetTheme.overlaySubtle, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }
}

private enum BacktestHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case allocation
    case dca
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return AppLocalization.string("全部")
        case .allocation:
            return BacktestRecordKind.allocation.title
        case .dca:
            return BacktestRecordKind.dca.title
        case .advanced:
            return BacktestRecordKind.advanced.title
        }
    }

    var iconName: String {
        switch self {
        case .all:
            return "tray.full"
        case .allocation:
            return BacktestRecordKind.allocation.entryIconName
        case .dca:
            return BacktestRecordKind.dca.entryIconName
        case .advanced:
            return BacktestRecordKind.advanced.entryIconName
        }
    }

    private var kind: BacktestRecordKind? {
        switch self {
        case .all:
            return nil
        case .allocation:
            return .allocation
        case .dca:
            return .dca
        case .advanced:
            return .advanced
        }
    }

    func includes(_ record: BacktestRecord) -> Bool {
        guard let kind else { return true }
        return BacktestRecordCodec.kind(for: record) == kind
    }
}

private struct BacktestHistorySectionHeader: View {
    @Binding var selectedFilter: BacktestHistoryFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(AssetTheme.border.opacity(0.48))
                .frame(height: 1)

            HStack(alignment: .center, spacing: 12) {
                Text(AppLocalization.string("记录"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 12)

                Menu {
                    ForEach(BacktestHistoryFilter.allCases) { filter in
                        Button {
                            selectedFilter = filter
                        } label: {
                            Label(filter.title, systemImage: selectedFilter == filter ? "checkmark" : filter.iconName)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.footnote.weight(.semibold))
                        Text(selectedFilter.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(AssetTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(AssetTheme.overlaySoft, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }
}

private struct BacktestHistoryView: View {
    let records: [BacktestRecord]
    let onStart: (BacktestRecordKind) -> Void
    let onSelect: (BacktestRecord) -> Void
    let onRestore: (BacktestRecord) -> Void
    let onDelete: (BacktestRecord) -> Void

    @State private var selectedFilter: BacktestHistoryFilter = .all

    private var filteredRecords: [BacktestRecord] {
        records.filter { selectedFilter.includes($0) }
    }

    private var emptyTitle: String {
        guard !records.isEmpty else { return AppLocalization.string("还没有回测记录") }
        return AppLocalization.format("暂无%@记录", selectedFilter.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BacktestModeEntryPanel(onStart: onStart)

            BacktestHistorySectionHeader(selectedFilter: $selectedFilter)

            if filteredRecords.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: records.isEmpty ? "tray" : "line.3.horizontal.decrease.circle")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(AssetTheme.gold)
                    Text(emptyTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredRecords.enumerated()), id: \.element.id) { index, record in
                        BacktestHistoryRow(
                            record: record,
                            onSelect: { onSelect(record) },
                            onRestore: { onRestore(record) },
                            onDelete: { onDelete(record) }
                        )

                        if index < filteredRecords.count - 1 {
                            Divider()
                                .overlay(AssetTheme.border.opacity(0.55))
                                .padding(.leading, 18)
                        }
                    }
                }
                .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
                )
            }
        }
    }
}

private struct BacktestHistoryRow: View {
    let record: BacktestRecord
    let onSelect: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void

    private var kind: BacktestRecordKind {
        BacktestRecordCodec.kind(for: record)
    }

    private var iconName: String {
        switch kind {
        case .allocation:
            return "chart.pie.fill"
        case .dca:
            return "calendar.badge.plus"
        case .advanced:
            return "slider.horizontal.3"
        }
    }

    private var annualizedReturnText: String {
        record.annualizedReturn?.percentString() ?? "--"
    }

    private var annualizedReturnColor: Color {
        guard let annualizedReturn = record.annualizedReturn else { return AssetTheme.textPrimary }
        return annualizedReturn >= 0 ? AssetTheme.positive : AssetTheme.negative
    }

    private var sharpeRatioText: String {
        record.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--"
    }

    private var displaySubtitle: String {
        switch kind {
        case .advanced:
            return advancedStrategyDisplayName()
        case .allocation, .dca:
            return record.title
        }
    }

    private func advancedStrategyDisplayName() -> String {
        let summaryLead = record.configSummary
            .split(separator: "·", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        if let summaryLead, !summaryLead.isEmpty {
            let knownTitles = Set(AdvancedBacktestStrategyTemplate.all.map(\.title) + [AdvancedBacktestStrategyMode.ruleBased.title])
            if knownTitles.contains(summaryLead) {
                return summaryLead
            }
        }

        if !record.subtitle.isEmpty,
           !record.subtitle.contains("·") {
            return record.subtitle
        }

        return AdvancedBacktestStrategyMode.ruleBased.title
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AssetTheme.gold)
                    .frame(width: 32, height: 32)
                    .background(AssetTheme.gold.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(record.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AssetTheme.textPrimary)
                            .lineLimit(1)
                        Text(record.createdAt.recordDateString)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                    }

                    Text(displaySubtitle)
                        .font(.caption2)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 4) {
                        historyMetricLine(
                            title: AppLocalization.string("平均年化"),
                            value: annualizedReturnText,
                            valueColor: annualizedReturnColor
                        )
                        historyMetricLine(
                            title: AppLocalization.string("最大回撤"),
                            value: record.maxDrawdown.percentString(),
                            valueColor: AssetTheme.negative
                        )
                        historyMetricLine(
                            title: AppLocalization.string("夏普"),
                            value: sharpeRatioText,
                            valueColor: AssetTheme.textPrimary
                        )
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(AppLocalization.string("恢复参数"), systemImage: "arrow.uturn.backward") {
                onRestore()
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(AppLocalization.string("删除记录"), systemImage: "trash")
            }
        }
    }

    private func historyMetricLine(title: String, value: String, valueColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
            Text(value)
                .font(.caption2.weight(.bold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
        }
        .lineLimit(1)
    }
}

private struct BacktestRecordDetailSnapshot {
    let kind: BacktestRecordKind
    let points: [BacktestSeriesPoint]
    let detailConfig: BacktestRecordDetailConfigPayload?
    let advancedBenchmarkSeries: [BacktestRecordAdvancedBenchmarkSeriesPayload]

    var canRestore: Bool { detailConfig != nil }

    init(record: BacktestRecord) {
        let decodedDetailConfig = BacktestRecordCodec.decodeDetailConfig(from: record)
        self.kind = BacktestRecordCodec.kind(for: record)
        self.points = BacktestRecordCodec.decodePoints(from: record)
        self.detailConfig = decodedDetailConfig
        self.advancedBenchmarkSeries = decodedDetailConfig?.advancedBenchmarkSeries ?? []
    }
}

private struct BacktestRecordDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let record: BacktestRecord
    let onRestore: (BacktestRecord) -> Void
    let onDelete: (BacktestRecord) -> Void
    private let snapshot: BacktestRecordDetailSnapshot
    @State private var loadedAdvancedTrades: [BacktestRecordAdvancedTradePayload]?
    @State private var visibleTradeCount = 40

    init(record: BacktestRecord, onRestore: @escaping (BacktestRecord) -> Void, onDelete: @escaping (BacktestRecord) -> Void) {
        self.record = record
        self.onRestore = onRestore
        self.onDelete = onDelete
        self.snapshot = BacktestRecordDetailSnapshot(record: record)
    }

    private var kind: BacktestRecordKind {
        snapshot.kind
    }

    private var points: [BacktestSeriesPoint] {
        snapshot.points
    }

    private var canRestore: Bool {
        snapshot.canRestore
    }

    private var advancedTrades: [BacktestRecordAdvancedTradePayload] {
        loadedAdvancedTrades ?? []
    }

    private var displayedAdvancedTrades: [BacktestRecordAdvancedTradePayload] {
        Array(advancedTrades.reversed().prefix(visibleTradeCount))
    }

    private var hasMoreAdvancedTrades: Bool {
        advancedTrades.count > displayedAdvancedTrades.count
    }

    private var advancedBenchmarkSeries: [BacktestChartComparisonSeries] {
        snapshot.advancedBenchmarkSeries.enumerated().compactMap { index, series in
            let normalizedPoints = BacktestChartData.normalizedComparisonPoints(
                series.decodedPoints,
                targetStartValue: points.first?.portfolioValue
            )
            guard !normalizedPoints.isEmpty else { return nil }
            return BacktestChartComparisonSeries(
                id: "record-asset-benchmark-\(series.id)",
                title: series.title,
                points: normalizedPoints,
                color: BacktestChartPalette.comparisonLine(at: index)
            )
        }
    }

    private var chartComparisonSeries: [BacktestChartComparisonSeries] {
        kind == .advanced ? advancedBenchmarkSeries : []
    }

    private var displayTitle: String {
        if kind == .advanced, !record.subtitle.isEmpty {
            return AppLocalization.format("%@-%@", record.title, record.subtitle)
        }
        return record.title
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(displayTitle)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    detailPanel {
                        if points.isEmpty {
                            Text(AppLocalization.string("这条记录没有可展示的曲线快照。"))
                                .font(.subheadline)
                                .foregroundStyle(AssetTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            BacktestValueChartSection(
                                points: points,
                                comparisonSeries: chartComparisonSeries,
                                valueStyle: kind.chartValueStyle
                            )
                        }
                    }

                    detailPanel {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            BacktestMetricCard(title: AppLocalization.string("总收益"), value: record.totalReturn.percentString(), accent: record.totalReturn >= 0 ? AssetTheme.positive : AssetTheme.negative)
                            BacktestMetricCard(title: AppLocalization.string("年化收益"), value: record.annualizedReturn?.percentString() ?? "--")
                            BacktestMetricCard(title: AppLocalization.string("最大回撤"), value: record.maxDrawdown.percentString(), accent: AssetTheme.negative)
                            BacktestMetricCard(title: AppLocalization.string("夏普比率"), value: record.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                            BacktestMetricCard(title: AppLocalization.string("期末资产"), value: record.finalValue?.currencyString() ?? "--")
                            BacktestMetricCard(title: AppLocalization.string("交易次数"), value: record.tradeCount > 0 ? AppLocalization.format("%d次", record.tradeCount) : "--")
                        }
                    }

                    detailPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            detailLine(title: AppLocalization.string("保存时间"), value: record.createdAt.longDateString)
                            detailLine(title: AppLocalization.string("回测区间"), value: rangeText)
                            detailLine(title: AppLocalization.string("策略参数"), value: record.configSummary)
                            if let totalInvested = record.totalInvested {
                                detailLine(title: AppLocalization.string("投入/本金"), value: totalInvested.currencyString())
                            }
                            if let profitLoss = record.profitLoss {
                                detailLine(title: AppLocalization.string("盈亏"), value: profitLoss.currencyString())
                            }
                        }
                    }

                    if kind == .advanced {
                        detailPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    detailSectionTitle(AppLocalization.string("买卖历史"))
                                    Spacer(minLength: 8)
                                    if let loadedAdvancedTrades {
                                        Text(AppLocalization.format("%d笔", loadedAdvancedTrades.count))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AssetTheme.textSecondary)
                                    }
                                }

                                if loadedAdvancedTrades == nil {
                                    Text(AppLocalization.string("为避免打开记录卡顿，买卖明细不会自动加载。"))
                                        .font(.caption)
                                        .foregroundStyle(AssetTheme.textSecondary)

                                    Button {
                                        loadedAdvancedTrades = BacktestRecordCodec.decodeAdvancedTrades(from: record)
                                        visibleTradeCount = 40
                                    } label: {
                                        Label(
                                            record.tradeCount > 0
                                                ? AppLocalization.format("加载%d笔买卖明细", record.tradeCount)
                                                : AppLocalization.string("加载买卖明细"),
                                            systemImage: "list.bullet.rectangle"
                                        )
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                } else if advancedTrades.isEmpty {
                                    Text(AppLocalization.string("暂无买卖成交"))
                                        .font(.subheadline)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                } else {
                                    ForEach(displayedAdvancedTrades) { trade in
                                        AdvancedRecordTradeRow(trade: trade)
                                        if trade.id != displayedAdvancedTrades.last?.id {
                                            Divider()
                                                .overlay(AssetTheme.border.opacity(0.55))
                                        }
                                    }

                                    if hasMoreAdvancedTrades {
                                        Button {
                                            visibleTradeCount += 40
                                        } label: {
                                            Text(AppLocalization.format("再显示%d笔", min(40, advancedTrades.count - displayedAdvancedTrades.count)))
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            onRestore(record)
                        } label: {
                            Label(AppLocalization.string("恢复参数"), systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AssetTheme.gold)
                        .disabled(!canRestore)

                        Button(role: .destructive) {
                            onDelete(record)
                        } label: {
                            Label(AppLocalization.string("删除"), systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
            .background(AssetTheme.background.ignoresSafeArea())
            .navigationTitle(AppLocalization.string("记录详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var rangeText: String {
        guard let startDate = record.startDate, let endDate = record.endDate else { return "--" }
        return "\(startDate.recordDateString) - \(endDate.recordDateString)"
    }

    private func detailPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(16)
        .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
        )
    }

    private func detailSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline.weight(.bold))
            .foregroundStyle(AssetTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailLine(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AssetTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AdvancedLiveAssetChartView: View {
    let assetReport: AdvancedBacktestAssetReport
    private let pricePoints: [AdvancedBacktestPricePoint]
    private let trades: [AdvancedBacktestTrade]
    private let chartPoints: [BacktestSeriesPoint]

    init(assetReport: AdvancedBacktestAssetReport) {
        self.assetReport = assetReport
        let sortedPricePoints = assetReport.pricePoints.sorted { $0.sequence < $1.sequence }
        self.pricePoints = sortedPricePoints
        self.trades = assetReport.trades.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.assetSymbol < rhs.assetSymbol }
            return lhs.date < rhs.date
        }
        self.chartPoints = sortedPricePoints.map { point in
            BacktestSeriesPoint(date: point.date, portfolioValue: point.price, sequence: point.sequence)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(assetReport.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                    Text(AppLocalization.format("%d条价格 · %d笔交易", pricePoints.count, trades.count))
                        .font(.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                }

                Spacer(minLength: 8)

                Text(pricePoints.last?.price.currencyString() ?? "--")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AssetTheme.gold)
                    .monospacedDigit()
            }

            if chartPoints.isEmpty {
                Text(AppLocalization.string("暂无该资产行情快照"))
                    .font(.subheadline)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                InteractiveBacktestChart(
                    points: chartPoints,
                    valueStyle: .currency(code: "CNY")
                )
                .padding(.vertical, 8)
                .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack {
                    Text(chartPoints.first?.date.recordDateString ?? "--")
                    Spacer()
                    Text(chartPoints.last?.date.recordDateString ?? "--")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.78))
            }
        }
    }
}

private struct AdvancedRecordAssetChartView: View {
    let chart: BacktestRecordAdvancedAssetChartPayload
    private let pricePoints: [BacktestRecordAdvancedPricePayload]
    private let chartPoints: [BacktestSeriesPoint]
    private let trades: [BacktestRecordAdvancedTradePayload]

    init(chart: BacktestRecordAdvancedAssetChartPayload) {
        self.chart = chart
        let sortedPricePoints = chart.pricePoints.sorted { $0.sequence < $1.sequence }
        self.pricePoints = sortedPricePoints
        self.chartPoints = sortedPricePoints.map { point in
            BacktestSeriesPoint(date: point.date, portfolioValue: point.price, sequence: point.sequence)
        }
        self.trades = chart.trades.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.sequence < rhs.sequence }
            return lhs.date < rhs.date
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chart.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                    Text(AppLocalization.format("%d条价格 · %d笔交易", pricePoints.count, trades.count))
                        .font(.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                }

                Spacer(minLength: 8)

                Text(pricePoints.last?.price.currencyString() ?? "--")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }

            if chartPoints.isEmpty {
                Text(AppLocalization.string("暂无该资产行情快照"))
                    .font(.subheadline)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                InteractiveBacktestChart(
                    points: chartPoints,
                    valueStyle: .currency(code: "CNY")
                )
                .padding(.vertical, 8)
                .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack {
                    Text(chartPoints.first?.date.recordDateString ?? "--")
                    Spacer()
                    Text(chartPoints.last?.date.recordDateString ?? "--")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.78))
            }
        }
    }
}

private struct AdvancedRecordTradeRow: View {
    let trade: BacktestRecordAdvancedTradePayload

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(trade.action == .buy ? "BUY" : "SELL")
                .font(.caption2.weight(.black))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(trade.action.accent, in: Capsule())

            VStack(alignment: .leading, spacing: 4) {
                Text("\(trade.assetTitle) · \(trade.action.title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Text("\(trade.date.longDateString) · 价格 \(trade.price.currencyString())")
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                if let reason = trade.reason, !reason.isEmpty {
                    Text(AppLocalization.format("触发：%@", reason))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.78))
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(trade.cashAmount.currencyString())
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(trade.action.accent)
                Text(String(format: "%.4f份", trade.units))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AssetTheme.textSecondary)
                if let realizedProfit = trade.realizedProfit {
                    Text("\(realizedProfit >= 0 ? "+" : "")\(realizedProfit.currencyString())")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(realizedProfit >= 0 ? AssetTheme.positive : AssetTheme.negative)
                }
                if let holdingDays = trade.holdingDays {
                    Text(AppLocalization.format("持有%d天", holdingDays))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.78))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BacktestDCACard: View {
    let assetTitle: String
    let amount: Double
    let intervalDays: Int
    let selectedDateRangeLabel: String
    let accent: Color
    let onTapRange: () -> Void
    let onTapAsset: () -> Void
    let onTapAmount: () -> Void
    let onTapInterval: () -> Void
    let onTapPrimaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: onTapRange) {
                    HStack(spacing: 8) {
                        Text(selectedDateRangeLabel)
                            .font(.headline.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(AssetTheme.textPrimary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 0) {
                Button(action: onTapAsset) {
                    BacktestInfoRow(title: AppLocalization.string("回测资产"), value: assetTitle, valueColor: accent, showsDivider: true, showsChevron: true)
                }
                .buttonStyle(.plain)

                Button(action: onTapAmount) {
                    BacktestInfoRow(title: AppLocalization.string("每次投入"), value: amount.currencyString(), valueColor: AssetTheme.textPrimary, showsDivider: true, showsChevron: true)
                }
                .buttonStyle(.plain)

                Button(action: onTapInterval) {
                    BacktestInfoRow(title: AppLocalization.string("定投频率"), value: AppLocalization.format("每%d天", intervalDays), valueColor: AssetTheme.textPrimary, showsDivider: false, showsChevron: true)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 18)

            if let onTapPrimaryAction {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(AssetTheme.border.opacity(0.34))
                        .frame(height: 1)
                        .padding(.horizontal, 18)

                    HStack {
                        BacktestPrimaryActionButton(title: AppLocalization.string("开始回测"), systemImage: "play.fill", action: onTapPrimaryAction)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .onboardingAnchor(.backtestStart)
            }
        }
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.04), AssetTheme.overlaySoft.opacity(0.3), Color.black.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.1), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.1), radius: 16, y: 8)
        .frame(maxWidth: .infinity)
    }
}

private struct BacktestInfoRow: View {
    let title: String
    let value: String
    var valueColor: Color = AssetTheme.textPrimary
    let showsDivider: Bool
    var showsChevron = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(AppLocalization.string(title))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AssetTheme.textSecondary)

                Spacer()

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            if showsDivider {
                Rectangle()
                    .fill(AssetTheme.border.opacity(0.45))
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
    }
}

private struct BacktestPrimaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Image(systemName: systemImage)
                    .font(.footnote.weight(.bold))

                Text(AppLocalization.string(title))
                    .font(.subheadline.weight(.bold))

                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.black.opacity(0.88))
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [AssetTheme.gold.opacity(0.98), AssetTheme.goldSoft.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: AssetTheme.gold.opacity(0.12), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct BacktestActionChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AssetTheme.textSecondary)
                Text(AppLocalization.string(title))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.68), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct BacktestDateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var endDate: Date
    let availableBounds: ClosedRange<Date>
    let onApply: (Date, Date) -> Void

    init(
        availableBounds: ClosedRange<Date>,
        selectedBounds: ClosedRange<Date>,
        onApply: @escaping (Date, Date) -> Void
    ) {
        _startDate = State(initialValue: selectedBounds.lowerBound)
        _endDate = State(initialValue: selectedBounds.upperBound)
        self.availableBounds = availableBounds
        self.onApply = onApply
    }

    private var calendar: Calendar {
        Calendar(identifier: .gregorian)
    }

    private var selectedSpanDays: Int {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        return max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { startDate },
            set: { startDate = min($0, endDate) }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { endDate },
            set: { endDate = max($0, startDate) }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        summaryCard

                        VStack(alignment: .leading, spacing: 10) {
                            Text(AppLocalization.string("快速选择"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AssetTheme.textSecondary)

                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                                spacing: 10
                            ) {
                                BacktestRangePresetButton(
                                    title: AppLocalization.string("全部历史"),
                                    isSelected: matchesRange(start: availableBounds.lowerBound, end: availableBounds.upperBound)
                                ) {
                                    startDate = availableBounds.lowerBound
                                    endDate = availableBounds.upperBound
                                }

                                BacktestRangePresetButton(
                                    title: AppLocalization.string("近1年"),
                                    isSelected: matchesPreset(yearsBack: 1)
                                ) {
                                    applyRelativePreset(yearsBack: 1)
                                }

                                BacktestRangePresetButton(
                                    title: AppLocalization.string("近6个月"),
                                    isSelected: matchesPreset(monthsBack: 6)
                                ) {
                                    applyRelativePreset(monthsBack: 6)
                                }
                            }
                        }

                        BacktestCalendarCard(
                            title: AppLocalization.string("开始日期"),
                            value: startDate.longDateString,
                            accent: AssetTheme.gold,
                            selection: startDateBinding,
                            bounds: availableBounds.lowerBound...endDate
                        )

                        BacktestCalendarCard(
                            title: AppLocalization.string("结束日期"),
                            value: endDate.longDateString,
                            accent: AssetTheme.goldSoft,
                            selection: endDateBinding,
                            bounds: startDate...availableBounds.upperBound
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 36)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("调整时间"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(startDate, endDate)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(AssetTheme.gold)
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLocalization.string("已选区间"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AssetTheme.textSecondary)

                    Text("\(startDate.recordDateString) - \(endDate.recordDateString)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(AssetTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(AppLocalization.string("天数"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AssetTheme.textSecondary)
                    Text(AppLocalization.format("%d天", selectedSpanDays))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AssetTheme.gold)
                }
            }

            Rectangle()
                .fill(AssetTheme.border.opacity(0.4))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalization.string("可选范围"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)

                Text("\(availableBounds.lowerBound.longDateString) - \(availableBounds.upperBound.longDateString)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.05), AssetTheme.overlaySoft.opacity(0.35), Color.black.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 8)
    }

    private func applyRelativePreset(monthsBack: Int? = nil, yearsBack: Int? = nil) {
        let targetStart: Date
        if let monthsBack {
            targetStart = calendar.date(byAdding: .month, value: -monthsBack, to: availableBounds.upperBound) ?? availableBounds.lowerBound
        } else if let yearsBack {
            targetStart = calendar.date(byAdding: .year, value: -yearsBack, to: availableBounds.upperBound) ?? availableBounds.lowerBound
        } else {
            targetStart = availableBounds.lowerBound
        }

        startDate = max(targetStart, availableBounds.lowerBound)
        endDate = availableBounds.upperBound
    }

    private func matchesPreset(monthsBack: Int? = nil, yearsBack: Int? = nil) -> Bool {
        let presetStart: Date
        if let monthsBack {
            presetStart = calendar.date(byAdding: .month, value: -monthsBack, to: availableBounds.upperBound) ?? availableBounds.lowerBound
        } else if let yearsBack {
            presetStart = calendar.date(byAdding: .year, value: -yearsBack, to: availableBounds.upperBound) ?? availableBounds.lowerBound
        } else {
            presetStart = availableBounds.lowerBound
        }

        return matchesRange(start: max(presetStart, availableBounds.lowerBound), end: availableBounds.upperBound)
    }

    private func matchesRange(start: Date, end: Date) -> Bool {
        calendar.isDate(startDate, inSameDayAs: start) && calendar.isDate(endDate, inSameDayAs: end)
    }
}

private struct BacktestRangePresetButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(AppLocalization.string(title))
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? Color.black.opacity(0.88) : AssetTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [AssetTheme.gold.opacity(0.98), AssetTheme.goldSoft.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        : AnyShapeStyle(AssetTheme.overlaySoft),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isSelected ? Color.white.opacity(0.12) : AssetTheme.border.opacity(0.7),
                            lineWidth: 1
                        )
                )
                .shadow(color: isSelected ? AssetTheme.gold.opacity(0.14) : .clear, radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }
}

private struct BacktestCalendarCard: View {
    let title: String
    let value: String
    let accent: Color
    let selection: Binding<Date>
    let bounds: ClosedRange<Date>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLocalization.string(title))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AssetTheme.textSecondary)
                    Text(value)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(accent)
                }

                Spacer(minLength: 8)

                Image(systemName: "calendar")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(accent)
                    .padding(10)
                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
                    )
            }

            DatePicker(title, selection: selection, in: bounds, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
                .tint(AssetTheme.gold)
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.04), AssetTheme.overlaySoft.opacity(0.32), Color.black.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.1), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.1), radius: 16, y: 8)
    }
}

private struct BacktestLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(AssetTheme.gold)
                .scaleEffect(1.15)
            Text(AppLocalization.string("正在重新回测..."))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

private struct AdvancedStrategyLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    let templates: [AdvancedBacktestStrategyTemplate]
    let activeTemplateID: String?
    let onSelect: (AdvancedBacktestStrategyTemplate) -> Void
    @State private var searchText = ""
    @State private var selectedCategory: String? = nil

    private var categoryFilters: [String] {
        var seen = Set<String>()
        return templates.compactMap { template in
            guard !seen.contains(template.category) else { return nil }
            seen.insert(template.category)
            return template.category
        }
    }

    private var visibleTemplates: [AdvancedBacktestStrategyTemplate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return templates.filter { template in
            let categoryMatches = selectedCategory.map { template.category == $0 } ?? true
            guard categoryMatches else { return false }
            guard !query.isEmpty else { return true }
            return template.title.localizedCaseInsensitiveContains(query)
                || template.subtitle.localizedCaseInsensitiveContains(query)
                || template.category.localizedCaseInsensitiveContains(query)
                || template.mode.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var shouldShowCategoryHeaders: Bool {
        selectedCategory == nil && visibleTemplates.count > 1
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(AppLocalization.string("策略大全"))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                            .padding(.bottom, 2)

                        strategySearchAndFilterArea

                        if visibleTemplates.isEmpty {
                            strategyEmptyState
                        } else {
                            ForEach(visibleTemplates.indices, id: \.self) { index in
                                let template = visibleTemplates[index]
                                if shouldShowCategoryHeaders && showsCategoryHeader(at: index, in: visibleTemplates) {
                                    Text(template.category)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(AssetTheme.textSecondary)
                                        .padding(.top, index == visibleTemplates.startIndex ? 0 : 8)
                                }

                                AdvancedStrategyTemplateRow(
                                    template: template,
                                    isActive: template.id == activeTemplateID
                                ) {
                                    onSelect(template)
                                    dismiss()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.gold)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var strategySearchAndFilterArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                TextField(AppLocalization.string("搜索策略、指标或资产"), text: $searchText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.76))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.55), lineWidth: 1)
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    strategyFilterChip(title: AppLocalization.string("全部"), isSelected: selectedCategory == nil) {
                        selectedCategory = nil
                    }
                    ForEach(categoryFilters, id: \.self) { category in
                        strategyFilterChip(title: category, isSelected: selectedCategory == category) {
                            selectedCategory = category
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.bottom, 2)
    }

    private var strategyEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string("没有匹配策略"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)
            Text(AppLocalization.string("换个关键词，或切回全部分类。"))
                .font(.caption)
                .foregroundStyle(AssetTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.55), lineWidth: 1)
        )
    }

    private func strategyFilterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? AssetTheme.background : AssetTheme.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(isSelected ? AssetTheme.gold : AssetTheme.overlayFaint, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? AssetTheme.gold.opacity(0.8) : AssetTheme.border.opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func showsCategoryHeader(at index: Int, in templates: [AdvancedBacktestStrategyTemplate]) -> Bool {
        index == templates.startIndex || templates[index - 1].category != templates[index].category
    }
}

private struct AdvancedStrategyTemplateRow: View {
    let template: AdvancedBacktestStrategyTemplate
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                        Text(template.subtitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AssetTheme.gold)
                    }

                    if template.mode.isRotation {
                        let chipTitles = rotationChipTitles(for: template.mode)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                ForEach(chipTitles, id: \.self) { title in
                                    strategyChip(title)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    ForEach(Array(chipTitles.prefix(2)), id: \.self) { title in
                                        strategyChip(title)
                                    }
                                }
                                HStack(spacing: 6) {
                                    ForEach(Array(chipTitles.dropFirst(2)), id: \.self) { title in
                                        strategyChip(title)
                                    }
                                }
                            }
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                strategyChip(AppLocalization.format("买 %@", ruleLabel(template.buyRule)))
                                strategyChip(AppLocalization.format("卖 %@", ruleLabel(template.sellRule)))
                                strategyChip(AppLocalization.format("单次 %@", template.tradeAmountRatio.percentString(maxFractionDigits: 0)))
                                strategyChip(AppLocalization.format("仓位 %@", (template.maxPositionRatio / 100).percentString(maxFractionDigits: 0)))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    strategyChip(AppLocalization.format("买 %@", ruleLabel(template.buyRule)))
                                    strategyChip(AppLocalization.format("卖 %@", ruleLabel(template.sellRule)))
                                }
                                HStack(spacing: 6) {
                                    strategyChip(AppLocalization.format("单次 %@", template.tradeAmountRatio.percentString(maxFractionDigits: 0)))
                                    strategyChip(AppLocalization.format("仓位 %@", (template.maxPositionRatio / 100).percentString(maxFractionDigits: 0)))
                                }
                            }
                        }
                    }

                    if template.mode == .ruleBased && (template.stopLossRatio > 0 || template.takeProfitRatio > 0) {
                        HStack(spacing: 6) {
                            if template.stopLossRatio > 0 {
                                strategyChip(AppLocalization.format("止损 %@", (template.stopLossRatio / 100).percentString(maxFractionDigits: 0)))
                            }
                            if template.takeProfitRatio > 0 {
                                strategyChip(AppLocalization.format("止盈 %@", (template.takeProfitRatio / 100).percentString(maxFractionDigits: 0)))
                            }
                            strategyChip(AppLocalization.format("冷却 %d天", template.cooldownDays))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 7) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "chevron.right")
                        .font(isActive ? .title3.weight(.semibold) : .caption.weight(.bold))
                        .foregroundStyle(isActive ? AssetTheme.gold : AssetTheme.textSecondary.opacity(0.72))
                    StrategyCapabilityRadarChart(profile: template.capabilityProfile)
                }
                .frame(width: 86, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(isActive ? AssetTheme.gold.opacity(0.13) : AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isActive ? AssetTheme.gold.opacity(0.72) : AssetTheme.border.opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func ruleLabel(_ rule: AdvancedBacktestRule) -> String {
        if rule.direction.usesDayThreshold {
            return AppLocalization.format("%@%d天", rule.direction.shortTitle, rule.days)
        }
        return rule.direction.shortTitle
    }

    private func rotationChipTitles(for mode: AdvancedBacktestStrategyMode) -> [String] {
        switch mode {
        case .ultraDefensiveRotation:
            return [
                AppLocalization.string("40日强弱"),
                AppLocalization.string("目标波动6%"),
                AppLocalization.string("最高仓位35%"),
                AppLocalization.string("现金防守")
            ]
        case .defensiveRotation:
            return [
                AppLocalization.string("40日强弱"),
                AppLocalization.string("目标波动8%"),
                AppLocalization.string("最高仓位55%"),
                AppLocalization.string("现金防守")
            ]
        case .lowDrawdownRotation:
            return [
                AppLocalization.string("40日强弱"),
                AppLocalization.string("分散持有"),
                AppLocalization.string("目标波动10%"),
                AppLocalization.string("最高仓位65%")
            ]
        case .balancedRotation:
            return [
                AppLocalization.string("40日强弱"),
                AppLocalization.string("分散持有"),
                AppLocalization.string("目标波动12%"),
                AppLocalization.string("最高仓位75%")
            ]
        case .enhancedRotation:
            return [
                AppLocalization.string("40日强弱"),
                AppLocalization.string("分散持有"),
                AppLocalization.string("目标波动12%"),
                AppLocalization.string("最高仓位90%")
            ]
        case .longTermDefensiveTrend:
            return [
                AppLocalization.string("黄金65%"),
                AppLocalization.string("MA200过滤"),
                AppLocalization.string("目标波动8.5%"),
                AppLocalization.string("现金防守")
            ]
        case .longTermEnhancedLowDrawdownTrend:
            return [
                AppLocalization.string("黄金73%"),
                AppLocalization.string("MA220过滤"),
                AppLocalization.string("目标波动9.5%"),
                AppLocalization.string("波动刹车")
            ]
        case .steadyDrawdownLadderTrend:
            return [
                AppLocalization.string("黄金73%"),
                AppLocalization.string("MA220过滤"),
                AppLocalization.string("目标波动8.5%"),
                AppLocalization.string("回撤阶梯")
            ]
        case .septemberGuardLadderTrend:
            return [
                AppLocalization.string("回撤阶梯"),
                AppLocalization.string("9月权益25%"),
                AppLocalization.string("黄金承接"),
                AppLocalization.string("目标波动8.5%")
            ]
        case .longTermGrowthTrend:
            return [
                AppLocalization.string("黄金50%"),
                AppLocalization.string("MA220过滤"),
                AppLocalization.string("目标波动11%"),
                AppLocalization.string("进取")
            ]
        case .longTermLowVolMomentum:
            return [
                AppLocalization.string("非均线"),
                AppLocalization.string("240日动量"),
                AppLocalization.string("波动<18%"),
                AppLocalization.string("最多3项")
            ]
        case .robustLowVolMomentum:
            return [
                AppLocalization.string("180日动量"),
                AppLocalization.string("波动<18%"),
                AppLocalization.string("最高仓位55%"),
                AppLocalization.string("目标波动7.5%")
            ]
        case .overheatGuardMomentum:
            return [
                AppLocalization.string("Top1动量"),
                AppLocalization.string("A股过热降仓"),
                AppLocalization.string("最高仓位75%"),
                AppLocalization.string("目标波动11%")
            ]
        case .highZoneDecelerationMomentum:
            return [
                AppLocalization.string("Top1动量"),
                AppLocalization.string("高位锁盈"),
                AppLocalization.string("短弱接管"),
                AppLocalization.string("目标波动11%")
            ]
        case .pairConfirmDoubleGuardMomentum:
            return [
                AppLocalization.string("Top1动量"),
                AppLocalization.string("同组确认"),
                AppLocalization.string("双守门"),
                AppLocalization.string("目标波动11%")
            ]
        case .tailBreakdownLockMomentum:
            return [
                AppLocalization.string("Top1动量"),
                AppLocalization.string("持有破位"),
                AppLocalization.string("锁盈降仓"),
                AppLocalization.string("防守发动机")
            ]
        case .recentLossVolatilityMetaMomentum:
            return [
                AppLocalization.string("亏损监控"),
                AppLocalization.string("波动监控"),
                AppLocalization.string("临时防守"),
                AppLocalization.string("恢复进攻")
            ]
        case .coreGoldSatelliteConservativeMomentum:
            return [
                AppLocalization.string("核心95%"),
                AppLocalization.string("黄金卫星10%"),
                AppLocalization.string("2月弱势刹车"),
                AppLocalization.string("回撤优先")
            ]
        case .coreGoldSatelliteBalancedMomentum:
            return [
                AppLocalization.string("核心97.5%"),
                AppLocalization.string("黄金卫星10%"),
                AppLocalization.string("2月弱势刹车"),
                AppLocalization.string("平衡推荐")
            ]
        case .coreGoldSatelliteFullMomentum:
            return [
                AppLocalization.string("核心100%"),
                AppLocalization.string("黄金卫星10%"),
                AppLocalization.string("总仓85%"),
                AppLocalization.string("净值轻刹车")
            ]
        case .coreGoldSatelliteHeatCappedMomentum:
            return [
                AppLocalization.string("单权益64%"),
                AppLocalization.string("黄金卫星10%"),
                AppLocalization.string("总仓85%"),
                AppLocalization.string("回撤优先")
            ]
        case .coreGoldSatelliteAggressiveMomentum:
            return [
                AppLocalization.string("核心97.5%"),
                AppLocalization.string("黄金卫星15%"),
                AppLocalization.string("2月弱势刹车"),
                AppLocalization.string("收益进取")
            ]
        case .canaryMomentumDefense:
            return [
                AppLocalization.string("双金丝雀"),
                AppLocalization.string("前2强势"),
                AppLocalization.string("黄金底仓"),
                AppLocalization.string("现金防守")
            ]
        case .drawdownReentryMomentum:
            return [
                AppLocalization.string("90日回撤<8%"),
                AppLocalization.string("动量/RSI再入场"),
                AppLocalization.string("最高仓位65%"),
                AppLocalization.string("目标波动7.5%")
            ]
        case .goldCoreTrendSatellite:
            return [
                AppLocalization.string("黄金核心"),
                AppLocalization.string("趋势卫星"),
                AppLocalization.string("分线过滤"),
                AppLocalization.string("现金防守")
            ]
        case .goldNasdaqSteadyRotation:
            return [
                AppLocalization.string("黄金/纳指"),
                AppLocalization.string("20日强弱>2%"),
                AppLocalization.string("MA250过滤"),
                AppLocalization.string("目标波动8%")
            ]
        case .goldNasdaqPortfolioScheduler:
            return [
                AppLocalization.string("纳指/黄金"),
                AppLocalization.string("现金防守"),
                AppLocalization.string("压力信号"),
                AppLocalization.string("目标波动9.5%")
            ]
        case .strongVolControlledRotation:
            return [
                AppLocalization.string("20日强弱"),
                AppLocalization.string("单一强势"),
                AppLocalization.string("目标波动12%"),
                AppLocalization.string("最高仓位90%")
            ]
        case .momentumRotation:
            return [
                AppLocalization.string("20日强弱"),
                AppLocalization.string("每20交易日"),
                AppLocalization.string("MA60过滤"),
                AppLocalization.string("空仓防守")
            ]
        case .ruleBased:
            return []
        }
    }

    private func strategyChip(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AssetTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AssetTheme.overlayFaint, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(AssetTheme.border.opacity(0.45), lineWidth: 1)
            )
    }
}

private struct StrategyCapabilityProfile {
    struct Metric: Identifiable {
        let label: String
        let value: Double
        var id: String { label }
    }

    let metrics: [Metric]
    let summary: String

    init(summary: String, metrics: [(String, Double)]) {
        self.summary = summary
        self.metrics = metrics.map { Metric(label: $0.0, value: min(max($0.1, 0), 1)) }
    }
}

private struct StrategyCapabilityRadarChart: View {
    let profile: StrategyCapabilityProfile

    var body: some View {
        VStack(spacing: 3) {
            Canvas { context, size in
                let metrics = profile.metrics
                guard metrics.count >= 3 else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.34
                let labelRadius = min(size.width, size.height) * 0.47

                func point(index: Int, radius: CGFloat, valueScale: Double = 1) -> CGPoint {
                    let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(metrics.count)
                    let scaledRadius = radius * CGFloat(valueScale)
                    return CGPoint(
                        x: center.x + CGFloat(cos(angle)) * scaledRadius,
                        y: center.y + CGFloat(sin(angle)) * scaledRadius
                    )
                }

                for step in 1...3 {
                    var gridPath = Path()
                    for index in metrics.indices {
                        let item = point(index: index, radius: radius, valueScale: Double(step) / 3)
                        if index == metrics.startIndex {
                            gridPath.move(to: item)
                        } else {
                            gridPath.addLine(to: item)
                        }
                    }
                    gridPath.closeSubpath()
                    context.stroke(gridPath, with: .color(AssetTheme.border.opacity(step == 3 ? 0.48 : 0.24)), lineWidth: step == 3 ? 0.8 : 0.55)
                }

                for index in metrics.indices {
                    var axisPath = Path()
                    axisPath.move(to: center)
                    axisPath.addLine(to: point(index: index, radius: radius))
                    context.stroke(axisPath, with: .color(AssetTheme.border.opacity(0.28)), lineWidth: 0.55)

                    let labelPoint = point(index: index, radius: labelRadius)
                    context.draw(
                        Text(metrics[index].label)
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.92)),
                        at: labelPoint,
                        anchor: .center
                    )
                }

                var valuePath = Path()
                for index in metrics.indices {
                    let item = point(index: index, radius: radius, valueScale: metrics[index].value)
                    if index == metrics.startIndex {
                        valuePath.move(to: item)
                    } else {
                        valuePath.addLine(to: item)
                    }
                }
                valuePath.closeSubpath()
                context.fill(valuePath, with: .color(AssetTheme.gold.opacity(0.22)))
                context.stroke(valuePath, with: .color(AssetTheme.gold.opacity(0.92)), lineWidth: 1.2)
            }
            .frame(width: 82, height: 82)
            .accessibilityHidden(true)

            Text(profile.summary)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityLabel(AppLocalization.format("策略能力：%@", profile.summary))
    }
}

private extension AdvancedBacktestStrategyTemplate {
    var capabilityProfile: StrategyCapabilityProfile {
        var growth = 0.35 + min(maxPositionRatio / 100, 1) * 0.45
        var stability = 0.88 - min(maxPositionRatio / 100, 1) * 0.36
        var defense = 0.34 + (1 - min(maxPositionRatio / 100, 1)) * 0.36
        var flexibility = mode.isRotation ? 0.72 : 0.42

        if (selectedAssetSymbols?.count ?? 1) >= 3 {
            flexibility += 0.10
            stability += 0.06
        }
        if stopLossRatio > 0 {
            defense += 0.18
            stability += 0.08
        }
        if takeProfitRatio > 0 {
            growth += 0.08
            defense += 0.06
        }

        switch mode {
        case .ultraDefensiveRotation:
            growth = 0.36; stability = 0.93; defense = 0.94; flexibility = 0.74
        case .defensiveRotation:
            growth = 0.48; stability = 0.86; defense = 0.88; flexibility = 0.78
        case .lowDrawdownRotation:
            growth = 0.60; stability = 0.80; defense = 0.78; flexibility = 0.82
        case .balancedRotation:
            growth = 0.70; stability = 0.70; defense = 0.68; flexibility = 0.84
        case .enhancedRotation:
            growth = 0.82; stability = 0.58; defense = 0.58; flexibility = 0.86
        case .longTermDefensiveTrend:
            growth = 0.64; stability = 0.86; defense = 0.90; flexibility = 0.66
        case .longTermEnhancedLowDrawdownTrend:
            growth = 0.82; stability = 0.78; defense = 0.76; flexibility = 0.68
        case .steadyDrawdownLadderTrend:
            growth = 0.68; stability = 0.88; defense = 0.88; flexibility = 0.68
        case .septemberGuardLadderTrend:
            growth = 0.72; stability = 0.90; defense = 0.91; flexibility = 0.72
        case .longTermGrowthTrend:
            growth = 0.86; stability = 0.62; defense = 0.60; flexibility = 0.66
        case .longTermLowVolMomentum:
            growth = 0.78; stability = 0.82; defense = 0.78; flexibility = 0.88
        case .robustLowVolMomentum:
            growth = 0.66; stability = 0.90; defense = 0.92; flexibility = 0.86
        case .overheatGuardMomentum:
            growth = 0.90; stability = 0.84; defense = 0.86; flexibility = 0.88
        case .highZoneDecelerationMomentum:
            growth = 0.92; stability = 0.86; defense = 0.88; flexibility = 0.90
        case .pairConfirmDoubleGuardMomentum:
            growth = 0.90; stability = 0.88; defense = 0.90; flexibility = 0.90
        case .tailBreakdownLockMomentum:
            growth = 0.76; stability = 0.90; defense = 0.92; flexibility = 0.88
        case .recentLossVolatilityMetaMomentum:
            growth = 0.94; stability = 0.90; defense = 0.92; flexibility = 0.94
        case .coreGoldSatelliteConservativeMomentum:
            growth = 0.92; stability = 0.93; defense = 0.94; flexibility = 0.94
        case .coreGoldSatelliteBalancedMomentum:
            growth = 0.96; stability = 0.91; defense = 0.92; flexibility = 0.95
        case .coreGoldSatelliteFullMomentum:
            growth = 0.99; stability = 0.90; defense = 0.91; flexibility = 0.96
        case .coreGoldSatelliteHeatCappedMomentum:
            growth = 0.97; stability = 0.94; defense = 0.94; flexibility = 0.96
        case .coreGoldSatelliteAggressiveMomentum:
            growth = 0.98; stability = 0.86; defense = 0.88; flexibility = 0.95
        case .canaryMomentumDefense:
            growth = 0.82; stability = 0.92; defense = 0.94; flexibility = 0.94
        case .drawdownReentryMomentum:
            growth = 0.82; stability = 0.84; defense = 0.88; flexibility = 0.86
        case .goldCoreTrendSatellite:
            growth = 0.62; stability = 0.88; defense = 0.92; flexibility = 0.74
        case .goldNasdaqSteadyRotation:
            growth = 0.58; stability = 0.82; defense = 0.82; flexibility = 0.76
        case .goldNasdaqPortfolioScheduler:
            growth = 0.74; stability = 0.86; defense = 0.90; flexibility = 0.88
        case .strongVolControlledRotation:
            growth = 0.78; stability = 0.66; defense = 0.66; flexibility = 0.78
        case .momentumRotation:
            growth = 0.86; stability = 0.50; defense = 0.48; flexibility = 0.72
        case .ruleBased:
            switch id {
            case "gold-dip-take-profit":
                growth = 0.78; stability = 0.56; defense = 0.60; flexibility = 0.45
            case "index-compound-take-profit":
                growth = 0.84; stability = 0.52; defense = 0.54; flexibility = 0.45
            case "ma60-strength":
                growth = 0.72; stability = 0.70; defense = 0.74; flexibility = 0.48
            case "ma20-index-follow":
                growth = 0.78; stability = 0.58; defense = 0.58; flexibility = 0.48
            case "rebound":
                growth = 0.48; stability = 0.62; defense = 0.56; flexibility = 0.50
            case "trend":
                growth = 0.64; stability = 0.56; defense = 0.52; flexibility = 0.54
            case "golden-cross":
                growth = 0.58; stability = 0.70; defense = 0.62; flexibility = 0.50
            case "bollinger":
                growth = 0.45; stability = 0.68; defense = 0.62; flexibility = 0.50
            default:
                break
            }
        }

        let summary: String
        if defense >= 0.86 && stability >= 0.82 {
            summary = AppLocalization.string("防守型")
        } else if growth >= 0.82 {
            summary = AppLocalization.string("进取型")
        } else if flexibility >= 0.82 {
            summary = AppLocalization.string("轮动型")
        } else {
            summary = AppLocalization.string("均衡型")
        }

        return StrategyCapabilityProfile(
            summary: summary,
            metrics: [
                (AppLocalization.string("收益"), growth),
                (AppLocalization.string("防守"), defense),
                (AppLocalization.string("弹性"), flexibility)
            ]
        )
    }
}

private struct BacktestDCASettingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var assetSymbol: String
    @State private var contributionAmount: Double
    @State private var intervalDays: Int
    let assetOptions: [BacktestAssetOption]
    let onApply: (String, Double, Int) -> Void

    init(
        assetSymbol: String,
        contributionAmount: Double,
        intervalDays: Int,
        assetOptions: [BacktestAssetOption],
        onApply: @escaping (String, Double, Int) -> Void
    ) {
        _assetSymbol = State(initialValue: assetSymbol)
        _contributionAmount = State(initialValue: contributionAmount)
        _intervalDays = State(initialValue: intervalDays)
        self.assetOptions = assetOptions
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(AppLocalization.string("回测资产"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AssetTheme.textPrimary)

                            Picker(AppLocalization.string("回测资产"), selection: $assetSymbol) {
                                ForEach(assetOptions) { option in
                                    Text(AppLocalization.string(option.title)).tag(option.symbol)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(AssetTheme.textPrimary)

                            Text(AppLocalization.string("每次投入固定为人民币。美元资产会按历史 USD/CNY 折算，人民币资产保持原口径。"))
                                .font(.caption)
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                        .padding(16)
                        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
                        )

                        BacktestStepperCard(
                            title: AppLocalization.string("每次投入"),
                            valueText: contributionAmount.currencyString(),
                            caption: AppLocalization.string("按人民币计价，支持按固定金额持续定投。"),
                            decrementTitle: AppLocalization.string("减少"),
                            incrementTitle: AppLocalization.string("增加")
                        ) {
                            contributionAmount = max(100, contributionAmount - 100)
                        } onIncrement: {
                            contributionAmount = min(1_000_000, contributionAmount + 100)
                        }

                        BacktestStepperCard(
                            title: AppLocalization.string("定投间隔"),
                            valueText: AppLocalization.format("每%d天", intervalDays),
                            caption: AppLocalization.string("若计划日无行情，则顺延到下一可用历史点执行。"),
                            decrementTitle: AppLocalization.string("缩短"),
                            incrementTitle: AppLocalization.string("拉长")
                        ) {
                            intervalDays = max(1, intervalDays - 1)
                        } onIncrement: {
                            intervalDays = min(365, intervalDays + 1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("重置")) {
                        assetSymbol = BacktestDefaults.dcaAssetSymbol
                        contributionAmount = BacktestDefaults.dcaContributionAmount
                        intervalDays = BacktestDefaults.dcaIntervalDays
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("定投参数"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(assetSymbol, contributionAmount, intervalDays)
                        dismiss()
                    }
                    .tint(AssetTheme.gold)
                }
            }
        }
    }
}

private struct AdvancedBacktestAssetPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSymbols: Set<String>
    let assetOptions: [BacktestAssetOption]
    let onApply: (Set<String>) -> Void

    init(selectedSymbols: Set<String>, assetOptions: [BacktestAssetOption], onApply: @escaping (Set<String>) -> Void) {
        _selectedSymbols = State(initialValue: selectedSymbols.isEmpty ? [BacktestDefaults.dcaAssetSymbol] : selectedSymbols)
        self.assetOptions = assetOptions
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(AppLocalization.string("可同时勾选多种资产；初始资金会按资产数量平均分配，每种资产独立执行同一套买卖规则。"))
                            .font(.footnote)
                            .foregroundStyle(AssetTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)

                        ForEach(assetOptions) { option in
                            Button {
                                toggle(option.symbol)
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 10, height: 10)

                                    Text(AppLocalization.string(option.title))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AssetTheme.textPrimary)

                                    Spacer(minLength: 12)

                                    Image(systemName: selectedSymbols.contains(option.symbol) ? "checkmark.circle.fill" : "circle")
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(selectedSymbols.contains(option.symbol) ? option.color : AssetTheme.textSecondary.opacity(0.7))
                                }
                                .padding(16)
                                .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(selectedSymbols.contains(option.symbol) ? option.color.opacity(0.45) : AssetTheme.border.opacity(0.68), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("回测资产"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(selectedSymbols.isEmpty ? [BacktestDefaults.dcaAssetSymbol] : selectedSymbols)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .tint(AssetTheme.gold)
                }
            }
        }
    }

    private func toggle(_ symbol: String) {
        if selectedSymbols.contains(symbol) {
            guard selectedSymbols.count > 1 else { return }
            selectedSymbols.remove(symbol)
        } else {
            selectedSymbols.insert(symbol)
        }
    }
}

private struct BacktestDCAAssetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSymbol: String
    let assetOptions: [BacktestAssetOption]
    let onApply: (String) -> Void

    init(selectedSymbol: String, assetOptions: [BacktestAssetOption], onApply: @escaping (String) -> Void) {
        _selectedSymbol = State(initialValue: selectedSymbol)
        self.assetOptions = assetOptions
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(assetOptions) { option in
                            Button {
                                selectedSymbol = option.symbol
                                onApply(option.symbol)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 10, height: 10)

                                    Text(AppLocalization.string(option.title))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AssetTheme.textPrimary)

                                    Spacer(minLength: 12)

                                    Image(systemName: selectedSymbol == option.symbol ? "checkmark.circle.fill" : "circle")
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(selectedSymbol == option.symbol ? option.color : AssetTheme.textSecondary.opacity(0.7))
                                }
                                .padding(16)
                                .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(AssetTheme.border.opacity(0.68), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("关闭")) {
                        dismiss()
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("回测资产"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }
            }
        }
    }
}

private struct BacktestDCAAmountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Double
    let onApply: (Double) -> Void

    private let presetAmounts: [Double] = [500, 1000, 2000, 3000, 5000, 10000, 20000, 50000]

    init(amount: Double, onApply: @escaping (Double) -> Void) {
        _amount = State(initialValue: amount)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(presetAmounts, id: \.self) { preset in
                                BacktestSelectionChip(
                                    title: preset.currencyString(),
                                    isSelected: amount == preset,
                                    accent: AssetTheme.gold
                                ) {
                                    amount = preset
                                }
                            }
                        }

                        BacktestStepperCard(
                            title: AppLocalization.string("每次投入"),
                            valueText: amount.currencyString(),
                            caption: AppLocalization.string("按人民币计价，支持按固定金额持续定投。"),
                            decrementTitle: AppLocalization.string("减少"),
                            incrementTitle: AppLocalization.string("增加")
                        ) {
                            amount = max(100, amount - 100)
                        } onIncrement: {
                            amount = min(1_000_000, amount + 100)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("重置")) {
                        amount = BacktestDefaults.dcaContributionAmount
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("每次投入"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(amount)
                        dismiss()
                    }
                    .tint(AssetTheme.gold)
                }
            }
        }
    }
}

private struct BacktestDCAIntervalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var intervalDays: Int
    let onApply: (Int) -> Void

    private let presetIntervals: [Int] = [1, 7, 14, 30, 60, 90, 180, 365]

    init(intervalDays: Int, onApply: @escaping (Int) -> Void) {
        _intervalDays = State(initialValue: intervalDays)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(presetIntervals, id: \.self) { preset in
                                BacktestSelectionChip(
                                    title: AppLocalization.format("每%d天", preset),
                                    isSelected: intervalDays == preset,
                                    accent: AssetTheme.gold
                                ) {
                                    intervalDays = preset
                                }
                            }
                        }

                        BacktestStepperCard(
                            title: AppLocalization.string("定投间隔"),
                            valueText: AppLocalization.format("每%d天", intervalDays),
                            caption: AppLocalization.string("若计划日无行情，则顺延到下一可用历史点执行。"),
                            decrementTitle: AppLocalization.string("缩短"),
                            incrementTitle: AppLocalization.string("拉长")
                        ) {
                            intervalDays = max(1, intervalDays - 1)
                        } onIncrement: {
                            intervalDays = min(365, intervalDays + 1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("重置")) {
                        intervalDays = BacktestDefaults.dcaIntervalDays
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("定投频率"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(intervalDays)
                        dismiss()
                    }
                    .tint(AssetTheme.gold)
                }
            }
        }
    }
}

private struct BacktestSelectionChip: View {
    let title: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.black.opacity(0.86) : AssetTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [accent.opacity(0.96), AssetTheme.goldSoft.opacity(0.88)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        : AnyShapeStyle(AssetTheme.overlaySoft),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isSelected ? Color.white.opacity(0.08) : AssetTheme.border.opacity(0.68), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct BacktestAllocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cashWeight: Double
    @State private var goldWeight: Double
    @State private var indexWeights: [String: Double]
    let indexOptions: [BacktestIndexOption]
    let onApply: (Double, Double, [String: Double]) -> Void

    private enum AllocationSlot: Hashable {
        case cash
        case gold
        case index(String)
    }

    init(
        cashWeight: Double,
        goldWeight: Double,
        indexWeights: [String: Double],
        indexOptions: [BacktestIndexOption],
        onApply: @escaping (Double, Double, [String: Double]) -> Void
    ) {
        _cashWeight = State(initialValue: cashWeight)
        _goldWeight = State(initialValue: goldWeight)
        _indexWeights = State(initialValue: indexWeights)
        self.indexOptions = indexOptions
        self.onApply = onApply
    }

    private var totalWeight: Double {
        cashWeight + goldWeight + indexOptions.reduce(0) { partial, option in
            partial + indexWeights[option.symbol, default: 0]
        }
    }

    private var remainingWeight: Int {
        Int((100 - totalWeight).rounded())
    }

    private var isAllocationComplete: Bool {
        remainingWeight == 0
    }

    private var quotaText: String {
        if remainingWeight > 0 {
            return AppLocalization.format("剩余配额 %d%%", remainingWeight)
        }
        if remainingWeight < 0 {
            return AppLocalization.format("超出 %d%%", -remainingWeight)
        }
        return AppLocalization.string("剩余配额 0%")
    }

    private var quotaColor: Color {
        if remainingWeight > 0 {
            return AssetTheme.textSecondary
        }
        if remainingWeight < 0 {
            return AssetTheme.negative
        }
        return AssetTheme.gold
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        BacktestWeightRow(title: AppLocalization.string("现金"), value: binding(for: .cash), tint: AssetTheme.textSecondary)
                        BacktestWeightRow(title: AppLocalization.string("黄金"), value: binding(for: .gold), tint: AssetTheme.gold)

                        ForEach(indexOptions) { option in
                            BacktestWeightRow(
                                title: option.title,
                                value: binding(for: .index(option.symbol)),
                                tint: option.color
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("重置")) {
                        resetDraft()
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(AppLocalization.string("调整配置"))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                        Text(quotaText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(quotaColor)
                    }
                    .multilineTextAlignment(.center)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(cashWeight, goldWeight, indexWeights)
                        dismiss()
                    }
                    .tint(isAllocationComplete ? AssetTheme.gold : AssetTheme.textSecondary)
                    .disabled(!isAllocationComplete)
                }
            }
        }
    }

    private func binding(for slot: AllocationSlot) -> Binding<Double> {
        Binding(
            get: { currentWeight(for: slot) },
            set: { updateWeight(for: slot, to: $0) }
        )
    }

    private func currentWeight(for slot: AllocationSlot) -> Double {
        switch slot {
        case .cash:
            return cashWeight
        case .gold:
            return goldWeight
        case let .index(symbol):
            return indexWeights[symbol, default: 0]
        }
    }

    private func otherWeightTotal(excluding slot: AllocationSlot) -> Double {
        switch slot {
        case .cash:
            return goldWeight + indexOptions.reduce(0) { $0 + indexWeights[$1.symbol, default: 0] }
        case .gold:
            return cashWeight + indexOptions.reduce(0) { $0 + indexWeights[$1.symbol, default: 0] }
        case let .index(symbol):
            return cashWeight + goldWeight + indexOptions.reduce(0) { partial, option in
                guard option.symbol != symbol else { return partial }
                return partial + indexWeights[option.symbol, default: 0]
            }
        }
    }

    private func updateWeight(for slot: AllocationSlot, to newValue: Double) {
        let clampedValue = min(max(0, newValue.rounded()), max(0, 100 - otherWeightTotal(excluding: slot)))

        switch slot {
        case .cash:
            cashWeight = clampedValue
        case .gold:
            goldWeight = clampedValue
        case let .index(symbol):
            indexWeights[symbol] = clampedValue
        }
    }

    private func resetDraft() {
        cashWeight = BacktestDefaults.cashWeight
        goldWeight = BacktestDefaults.goldWeight
        indexWeights = BacktestDefaults.indexWeights
    }
}

private struct BacktestStepperCard: View {
    let title: String
    let valueText: String
    let caption: String
    let decrementTitle: String
    let incrementTitle: String
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLocalization.string(title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Spacer()
                Text(valueText)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AssetTheme.goldSoft)
            }

            Text(AppLocalization.string(caption))
                .font(.caption)
                .foregroundStyle(AssetTheme.textSecondary)

            HStack(spacing: 10) {
                Button(AppLocalization.string(decrementTitle), action: onDecrement)
                    .buttonStyle(BacktestMiniControlButtonStyle())
                Button(AppLocalization.string(incrementTitle), action: onIncrement)
                    .buttonStyle(BacktestMiniControlButtonStyle(filled: true))
            }
        }
        .padding(16)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
        )
    }
}

private struct BacktestMiniControlButtonStyle: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(filled ? Color.black.opacity(configuration.isPressed ? 0.7 : 0.88) : AssetTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                filled
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [AssetTheme.goldSoft, AssetTheme.gold],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    : AnyShapeStyle(AssetTheme.overlaySoft),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        filled ? AssetTheme.gold.opacity(0.32) : AssetTheme.border.opacity(0.7),
                        lineWidth: 1
                    )
            )
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

private struct BacktestWeightRow: View {
    let title: String
    @Binding var value: Double
    var tint: Color = AssetTheme.gold

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AppLocalization.string(title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Spacer()
                Text("\(Int(value.rounded()))%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
            }

            Slider(value: $value, in: 0...100, step: 1)
                .tint(tint)
        }
        .padding(14)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
        )
    }
}

private struct BacktestMetricCard: View {
    let title: String
    var subtitle: String? = nil
    let value: String
    var accent: Color = AssetTheme.gold

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.string(title))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                if let subtitle {
                    Text(AppLocalization.string(subtitle))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                }
            }
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(accent)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private enum TimeMachineRange: String, CaseIterable, Identifiable {
    case halfMonth
    case oneMonth
    case sixMonths
    case oneYear
    case threeYears
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .halfMonth: return AppLocalization.string("半个月")
        case .oneMonth: return AppLocalization.string("1个月")
        case .sixMonths: return AppLocalization.string("6个月")
        case .oneYear: return AppLocalization.string("1年")
        case .threeYears: return AppLocalization.string("3年")
        case .all: return AppLocalization.string("全部")
        }
    }

    var summaryLabel: String {
        switch self {
        case .halfMonth: return AppLocalization.string("近半个月")
        case .oneMonth: return AppLocalization.string("近 1 个月")
        case .sixMonths: return AppLocalization.string("近 6 个月")
        case .oneYear: return AppLocalization.string("近 1 年")
        case .threeYears: return AppLocalization.string("近 3 年")
        case .all: return AppLocalization.string("全部记录")
        }
    }

    private var detailAggregationComponent: Calendar.Component {
        .day
    }

    var monthlyBucketLimit: Int? {
        switch self {
        case .halfMonth, .oneMonth:
            return 1
        case .sixMonths:
            return 6
        case .oneYear:
            return 12
        case .threeYears:
            return 36
        case .all:
            return nil
        }
    }

    private func startDate(from latestDate: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .halfMonth:
            return calendar.date(byAdding: .day, value: -15, to: latestDate)
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -1, to: latestDate)
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: latestDate)
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: latestDate)
        case .threeYears:
            return calendar.date(byAdding: .year, value: -3, to: latestDate)
        case .all:
            return nil
        }
    }

    func filter(_ points: [TimeMachineTrendPoint], calendar: Calendar = .current) -> [TimeMachineTrendPoint] {
        guard let latestDate = points.last?.date else { return [] }
        let startDate = startDate(from: latestDate, calendar: calendar)
        guard let startDate else { return points }
        return points.filter { $0.date >= startDate }
    }

    func filter(_ points: [TimeMachineSingleAxisPoint], calendar: Calendar = .current) -> [TimeMachineSingleAxisPoint] {
        guard let latestDate = points.last?.date else { return [] }
        let startDate = startDate(from: latestDate, calendar: calendar)
        guard let startDate else { return points }
        return points.filter { $0.date >= startDate }
    }

    func filter(_ points: [TimeMachineCandlestickPoint], calendar: Calendar = .current) -> [TimeMachineCandlestickPoint] {
        guard let latestDate = points.last?.date else { return [] }
        let startDate = startDate(from: latestDate, calendar: calendar)
        guard let startDate else { return points }
        return points.filter { $0.date >= startDate }
    }

    func aggregateDetailChartPoints(
        _ points: [TimeMachineDualAxisPoint],
        calendar: Calendar = .current
    ) -> [TimeMachineDualAxisPoint] {
        guard !points.isEmpty else { return [] }
        guard detailAggregationComponent != .day else {
            return points.sorted { $0.date < $1.date }
        }

        let grouped = Dictionary(grouping: points) { point in
            calendar.dateInterval(of: detailAggregationComponent, for: point.date)?.start ?? calendar.startOfDay(for: point.date)
        }

        return grouped
            .compactMap { _, values in
                let sortedValues = values.sorted { $0.date < $1.date }
                guard let representativePoint = sortedValues.last else { return nil }
                let count = Double(sortedValues.count)
                let leftAverage = sortedValues.reduce(0) { $0 + $1.leftValue } / count
                let rightAverage = sortedValues.reduce(0) { $0 + $1.rightValue } / count
                return TimeMachineDualAxisPoint(
                    date: representativePoint.date,
                    leftValue: leftAverage,
                    rightValue: rightAverage
                )
            }
            .sorted { $0.date < $1.date }
    }
}

private struct TimeMachineTrendPoint: Identifiable {
    let date: Date
    let mainAssets: Double
    let netAssets: Double
    let liabilities: Double
    let goldEquivalent: Double?
    let btcEquivalent: Double?
    let nasdaqEquivalent: Double?
    let goldAnchorPriceCNY: Double?
    let goldAnchorDate: Date?
    let btcAnchorPriceUSD: Double?
    let btcAnchorPriceCNY: Double?
    let btcAnchorDate: Date?
    let nasdaqAnchorPriceUSD: Double?
    let nasdaqAnchorPriceCNY: Double?
    let nasdaqAnchorDate: Date?

    var id: Date { date }
}

private struct TimeMachineMonthlySurplusPoint: Identifiable {
    let monthStart: Date
    let date: Date
    let surplus: Double
    let monthEndNetAssets: Double

    var id: Date { monthStart }
}

private struct TimeMachineAnnualSurplusPoint: Identifiable {
    let yearStart: Date
    let date: Date
    let surplus: Double
    let yearEndNetAssets: Double
    let isCurrentYear: Bool

    var id: Date { yearStart }
}

private struct TimeMachineHistoryDrilldown: Identifiable {
    let symbol: String
    let title: String
    let subtitle: String?
    let points: [TimeMachineSingleAxisPoint]
    let candlesticks: [TimeMachineCandlestickPoint]
    let color: Color
    let axisStyle: TimeMachineAxisValueStyle

    var id: String { symbol }
}

private struct TimeMachineCombinedTrendDescriptor: Identifiable {
    let title: String
    let subtitle: String?
    let leftTitle: String
    let rightTitle: String
    let points: [TimeMachineDualAxisPoint]
    let leftOnlyPoints: [TimeMachineSingleAxisPoint]
    let leftColor: Color
    let rightColor: Color
    let leftLatestLabel: String
    let rightLatestLabel: String
    let leftAxisStyle: TimeMachineAxisValueStyle
    let rightAxisStyle: TimeMachineAxisValueStyle
    let showsComparisonLine: Bool
    let historyDrilldown: TimeMachineHistoryDrilldown?

    var id: String { title }
}

private enum TimeMachineAxisValueStyle {
    case currency(code: String, suffix: String = "")
    case quantity(unit: String, maxFractionDigits: Int = 2)

    func compactLabel(for value: Double) -> String {
        switch self {
        case let .currency(code, suffix):
            return "\(currencySymbol(for: code))\(value.compactNumberString())\(suffix)"
        case let .quantity(unit, maxFractionDigits):
            return "\(value.compactNumberString(maxFractionDigits: maxFractionDigits))\(unit)"
        }
    }

    private func currencySymbol(for code: String) -> String {
        switch code.uppercased() {
        case "USD":
            return "$"
        case "HKD":
            return "HK$"
        case "JPY":
            return "¥"
        case "GBP":
            return "£"
        case "EUR":
            return "€"
        default:
            return "¥"
        }
    }
}

private struct TimeMachineDualAxisPoint: Identifiable {
    let date: Date
    let leftValue: Double
    let rightValue: Double

    var id: Date { date }
}

private struct TimeMachineSingleAxisPoint: Identifiable {
    let date: Date
    let value: Double

    var id: Date { date }
}

private struct TimeMachineCandlestickPoint: Identifiable {
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?

    var id: Date { date }
    var isRising: Bool { close >= open }
    var bodyLow: Double { min(open, close) }
    var bodyHigh: Double { max(open, close) }
}

private enum TimeMachineAssetSeries: CaseIterable, Identifiable {
    case mainAssets
    case netAssets
    case liabilities

    var id: String { title }

    var title: String {
        switch self {
        case .mainAssets: return AppLocalization.string("总资产")
        case .netAssets: return AppLocalization.string("净资产")
        case .liabilities: return AppLocalization.string("总负债")
        }
    }

    var color: Color {
        switch self {
        case .mainAssets: return AssetTheme.goldSoft
        case .netAssets: return AssetTheme.positive
        case .liabilities: return AssetTheme.negative
        }
    }

    var strokeStyle: StrokeStyle {
        switch self {
        case .liabilities:
            return StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5])
        default:
            return StrokeStyle(lineWidth: 2.5, lineCap: .round)
        }
    }

    func value(from point: TimeMachineTrendPoint) -> Double {
        switch self {
        case .mainAssets: return point.mainAssets
        case .netAssets: return point.netAssets
        case .liabilities: return point.liabilities
        }
    }
}

private struct DashboardAllocationDetail: Identifiable {
    let title: String
    let amount: Double

    var id: String { title }
}

private struct DashboardAllocationSlice: Identifiable {
    let title: String
    let amount: Double
    let color: Color
    let details: [DashboardAllocationDetail]

    var id: String { title }
}

private enum DashboardAllocationPalette {
    static let colors: [Color] = [
        AssetTheme.goldSoft,
        AssetTheme.accentBlue,
        AssetTheme.positive,
        AssetTheme.accentOrange,
        Color(red: 173 / 255, green: 132 / 255, blue: 255 / 255),
        Color(red: 105 / 255, green: 196 / 255, blue: 219 / 255)
    ]
}

private struct DashboardAllocationChart: View {
    let slices: [DashboardAllocationSlice]
    let totalAmount: Double

    @State private var selectedSliceID: DashboardAllocationSlice.ID?
    @State private var selectedAngleValue: Double?

    private let legendColumns = [
        GridItem(.flexible(), spacing: 16, alignment: .topLeading),
        GridItem(.flexible(), spacing: 16, alignment: .topLeading)
    ]

    private var displaySlice: DashboardAllocationSlice? {
        if let selectedSliceID,
           let selectedSlice = slices.first(where: { $0.id == selectedSliceID }) {
            return selectedSlice
        }
        return slices.first
    }

    private var totalSliceAmount: Double {
        slices.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value(AppLocalization.string("占比"), slice.amount),
                        innerRadius: .ratio(0.76),
                        angularInset: 1.6
                    )
                    .foregroundStyle(slice.color)
                    .opacity(isHighlighted(slice) ? 1 : 0.42)
                }
                .chartLegend(.hidden)
                .chartAngleSelection(value: $selectedAngleValue)
                .onChange(of: selectedAngleValue) { _, newValue in
                    guard let newValue,
                          let matchedSlice = slice(for: newValue) else { return }
                    selectedSliceID = matchedSlice.id
                }
                .frame(height: 278)

                VStack(spacing: 6) {
                    Text(AppLocalization.string("总资产"))
                        .font(AppTypography.eyebrow)
                        .foregroundStyle(AssetTheme.textSecondary)

                    Text(totalAmount.currencyString())
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                        .lineLimit(2)
                }
                .padding(.horizontal, 18)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)

            LazyVGrid(columns: legendColumns, alignment: .leading, spacing: 12) {
                ForEach(slices) { slice in
                    Button {
                        toggleSelection(for: slice)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(slice.color)
                                .frame(width: 8, height: 8)
                                .padding(.top, 5)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(AppLocalization.string(slice.title))
                                    .font(AppTypography.meta.weight(isHighlighted(slice) ? .semibold : .regular))
                                    .foregroundStyle(AssetTheme.textPrimary)
                                    .lineLimit(1)

                                Text(isHighlighted(slice) ? slice.amount.currencyString() : percentageText(for: slice))
                                    .font(AppTypography.eyebrow)
                                    .monospacedDigit()
                                    .foregroundStyle(isHighlighted(slice) ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                            }

                            Spacer(minLength: 0)
                        }
                        .opacity(isHighlighted(slice) ? 1 : 0.78)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let displaySlice, displaySlice.details.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    Text(displaySlice.title == AppLocalization.string("其他") ? AppLocalization.string("其他资产明细") : AppLocalization.string("资产明细"))
                        .font(AppTypography.eyebrow)
                        .foregroundStyle(AssetTheme.textSecondary)

                    ForEach(displaySlice.details) { detail in
                        HStack(spacing: 12) {
                            Text(AppLocalization.string(detail.title))
                                .font(AppTypography.meta)
                                .foregroundStyle(AssetTheme.textPrimary)
                                .lineLimit(1)

                            Spacer()

                            Text(detail.amount.currencyString())
                                .font(AppTypography.meta.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(AssetTheme.goldSoft)
                        }
                    }
                }
            }
        }
    }

    private func percentageText(for slice: DashboardAllocationSlice) -> String {
        guard totalAmount > 0 else { return "0%" }
        return (slice.amount / totalAmount).formatted(.percent.precision(.fractionLength(0)))
    }

    private func isHighlighted(_ slice: DashboardAllocationSlice) -> Bool {
        displaySlice?.id == slice.id
    }

    private func toggleSelection(for slice: DashboardAllocationSlice) {
        selectedSliceID = slice.id
        selectedAngleValue = midAngleValue(for: slice)
    }

    private func slice(for angleValue: Double) -> DashboardAllocationSlice? {
        guard totalSliceAmount > 0 else { return nil }

        var currentAngle = 0.0
        for slice in slices {
            let nextAngle = currentAngle + slice.amount
            if angleValue >= currentAngle && angleValue < nextAngle {
                return slice
            }
            currentAngle = nextAngle
        }

        return slices.last
    }

    private func midAngleValue(for slice: DashboardAllocationSlice) -> Double? {
        guard totalSliceAmount > 0 else { return nil }

        var currentAngle = 0.0
        for candidate in slices {
            let nextAngle = currentAngle + candidate.amount
            if candidate.id == slice.id {
                return (currentAngle + nextAngle) / 2
            }
            currentAngle = nextAngle
        }

        return nil
    }
}

private struct FinancialFreedomProjection {
    enum Status {
        case alreadyFree
        case projected(months: Int)
        case unreachable
    }

    let status: Status
    let monthlySalary: Double
    let annualReturnRate: Double
    let currentMonthlyExpense: Double
    let currentPassiveIncome: Double
    let maximumReachableMonthlyExpense: Double
    let requiredMonthlySalaryToReachFreedom: Double?
    let currentNetAssets: Double
    let currentTotalAssets: Double
    let projectedAnnualSurplus: Double
    let projectionPoints: [FinancialFreedomProjectionPoint]
}

private struct FinancialFreedomProjectionPoint: Identifiable {
    let monthOffset: Int
    let date: Date
    let projectedPassiveIncome: Double
    let projectedMonthlyExpense: Double
    let projectedTotalAssets: Double

    var id: Int { monthOffset }
}

private enum FinancialFreedomEstimator {
    private static let maxProjectionMonths = 100 * 12

    static func estimate(
        points: [TimeMachineTrendPoint],
        monthlySalary: Double,
        annualReturnRate: Double,
        monthlyExpense: Double,
        annualInflationRate: Double
    ) -> FinancialFreedomProjection? {
        guard let currentPoint = points.last,
              currentPoint.netAssets.isFinite,
              currentPoint.mainAssets.isFinite else { return nil }
        let currentNetAssets = currentPoint.netAssets
        let currentTotalAssets = currentPoint.mainAssets
        let currentLiabilities = max(currentPoint.liabilities, 0)
        let currentPassiveIncome = passiveMonthlyIncome(from: currentNetAssets, annualReturnRate: annualReturnRate)
        let monthlyReturnRate = monthlyReturnRate(from: annualReturnRate)
        let maximumReachableMonthlyExpense = maximumReachableMonthlyExpense(
            currentNetAssets: currentNetAssets,
            monthlySalary: monthlySalary,
            monthlyReturnRate: monthlyReturnRate,
            annualInflationRate: annualInflationRate
        )
        let requiredMonthlySalaryToReachFreedom = minimumRequiredMonthlySalaryToReachFreedom(
            currentNetAssets: currentNetAssets,
            monthlyExpense: monthlyExpense,
            monthlyReturnRate: monthlyReturnRate,
            annualInflationRate: annualInflationRate
        )

        let status: FinancialFreedomProjection.Status
        if currentPassiveIncome >= monthlyExpense {
            status = .alreadyFree
        } else {
            var projectedAssets = currentNetAssets
            var projectedMonths: Int?
            for month in 1...maxProjectionMonths {
                let projectedExpense = monthlyExpense * pow(1 + annualInflationRate, Double(month) / 12)
                projectedAssets = projectedAssets * (1 + monthlyReturnRate) + monthlySalary - projectedExpense
                if passiveMonthlyIncome(from: projectedAssets, annualReturnRate: annualReturnRate) >= projectedExpense {
                    projectedMonths = month
                    break
                }
            }
            status = projectedMonths.map { .projected(months: $0) } ?? .unreachable
        }

        let projectedAnnualSurplus = projectedAssetGrowth(
            currentNetAssets: currentNetAssets,
            months: 12,
            monthlySalary: monthlySalary,
            monthlyExpense: monthlyExpense,
            monthlyReturnRate: monthlyReturnRate,
            annualInflationRate: annualInflationRate
        )

        return FinancialFreedomProjection(
            status: status,
            monthlySalary: monthlySalary,
            annualReturnRate: annualReturnRate,
            currentMonthlyExpense: monthlyExpense,
            currentPassiveIncome: currentPassiveIncome,
            maximumReachableMonthlyExpense: maximumReachableMonthlyExpense,
            requiredMonthlySalaryToReachFreedom: requiredMonthlySalaryToReachFreedom,
            currentNetAssets: currentNetAssets,
            currentTotalAssets: currentTotalAssets,
            projectedAnnualSurplus: projectedAnnualSurplus,
            projectionPoints: projectionPoints(
                from: Calendar.current.startOfDay(for: max(currentPoint.date, Date())),
                currentNetAssets: currentNetAssets,
                currentLiabilities: currentLiabilities,
                monthlySalary: monthlySalary,
                monthlyReturnRate: monthlyReturnRate,
                monthlyExpense: monthlyExpense,
                annualInflationRate: annualInflationRate,
                status: status
            )
        )
    }

    private static func projectionPoints(
        from startDate: Date,
        currentNetAssets: Double,
        currentLiabilities: Double,
        monthlySalary: Double,
        monthlyReturnRate: Double,
        monthlyExpense: Double,
        annualInflationRate: Double,
        status: FinancialFreedomProjection.Status
    ) -> [FinancialFreedomProjectionPoint] {
        let horizonMonths = chartHorizonMonths(for: status, monthlySalary: monthlySalary, monthlyReturnRate: monthlyReturnRate)
        let calendar = Calendar.current
        var projectedAssets = currentNetAssets

        return (0...horizonMonths).compactMap { month in
            guard let date = calendar.date(byAdding: .month, value: month, to: startDate) else { return nil }
            let projectedMonthlyExpense = monthlyExpense * pow(1 + annualInflationRate, Double(month) / 12)
            if month > 0 {
                projectedAssets = projectedAssets * (1 + monthlyReturnRate) + monthlySalary - projectedMonthlyExpense
            }
            return FinancialFreedomProjectionPoint(
                monthOffset: month,
                date: date,
                projectedPassiveIncome: passiveMonthlyIncome(from: projectedAssets, annualReturnRate: monthlyReturnRateToAnnualRate(monthlyReturnRate)),
                projectedMonthlyExpense: projectedMonthlyExpense,
                projectedTotalAssets: projectedAssets + currentLiabilities
            )
        }
    }

    private static func chartHorizonMonths(
        for status: FinancialFreedomProjection.Status,
        monthlySalary: Double,
        monthlyReturnRate: Double
    ) -> Int {
        switch status {
        case .alreadyFree:
            return 36
        case let .projected(months):
            return min(max(months + 6, 18), 120)
        case .unreachable:
            return monthlySalary > 0 || monthlyReturnRate > 0 ? 60 : 36
        }
    }

    private static func maximumReachableMonthlyExpense(
        currentNetAssets: Double,
        monthlySalary: Double,
        monthlyReturnRate: Double,
        annualInflationRate: Double
    ) -> Double {
        let annualReturnRate = monthlyReturnRateToAnnualRate(monthlyReturnRate)

        func canReachFreedom(monthlyExpense: Double) -> Bool {
            if passiveMonthlyIncome(from: currentNetAssets, annualReturnRate: annualReturnRate) >= monthlyExpense {
                return true
            }

            var projectedAssets = currentNetAssets
            for month in 1...maxProjectionMonths {
                let projectedExpense = monthlyExpense * pow(1 + annualInflationRate, Double(month) / 12)
                projectedAssets = projectedAssets * (1 + monthlyReturnRate) + monthlySalary - projectedExpense
                guard projectedAssets.isFinite else { return false }
                if passiveMonthlyIncome(from: projectedAssets, annualReturnRate: annualReturnRate) >= projectedExpense {
                    return true
                }
            }
            return false
        }

        var lower = 0.0
        var upper = max(monthlySalary + passiveMonthlyIncome(from: currentNetAssets, annualReturnRate: annualReturnRate), 1)
        while canReachFreedom(monthlyExpense: upper), upper < 1_000_000_000 {
            lower = upper
            upper *= 2
        }

        for _ in 0..<40 {
            let middle = (lower + upper) / 2
            if canReachFreedom(monthlyExpense: middle) {
                lower = middle
            } else {
                upper = middle
            }
        }

        return max(0, lower)
    }

    private static func minimumRequiredMonthlySalaryToReachFreedom(
        currentNetAssets: Double,
        monthlyExpense: Double,
        monthlyReturnRate: Double,
        annualInflationRate: Double
    ) -> Double? {
        let annualReturnRate = monthlyReturnRateToAnnualRate(monthlyReturnRate)
        guard annualReturnRate > 0, monthlyExpense > 0 else { return nil }

        func canReachFreedom(monthlySalary: Double) -> Bool {
            if passiveMonthlyIncome(from: currentNetAssets, annualReturnRate: annualReturnRate) >= monthlyExpense {
                return true
            }

            var projectedAssets = currentNetAssets
            for month in 1...maxProjectionMonths {
                let projectedExpense = monthlyExpense * pow(1 + annualInflationRate, Double(month) / 12)
                projectedAssets = projectedAssets * (1 + monthlyReturnRate) + monthlySalary - projectedExpense
                guard projectedAssets.isFinite else { return false }
                if passiveMonthlyIncome(from: projectedAssets, annualReturnRate: annualReturnRate) >= projectedExpense {
                    return true
                }
            }
            return false
        }

        var lower = 0.0
        var upper = max(monthlyExpense, 1)
        while !canReachFreedom(monthlySalary: upper), upper < 1_000_000_000 {
            lower = upper
            upper *= 2
        }

        guard canReachFreedom(monthlySalary: upper) else { return nil }

        for _ in 0..<40 {
            let middle = (lower + upper) / 2
            if canReachFreedom(monthlySalary: middle) {
                upper = middle
            } else {
                lower = middle
            }
        }

        return max(0, upper)
    }

    private static func projectedAssetGrowth(
        currentNetAssets: Double,
        months: Int,
        monthlySalary: Double,
        monthlyExpense: Double,
        monthlyReturnRate: Double,
        annualInflationRate: Double
    ) -> Double {
        guard months > 0 else { return 0 }

        var projectedAssets = currentNetAssets
        for month in 1...months {
            let projectedExpense = monthlyExpense * pow(1 + annualInflationRate, Double(month) / 12)
            projectedAssets = projectedAssets * (1 + monthlyReturnRate) + monthlySalary - projectedExpense
        }
        return projectedAssets - currentNetAssets
    }

    private static func passiveMonthlyIncome(from assets: Double, annualReturnRate: Double) -> Double {
        assets * annualReturnRate / 12
    }

    private static func monthlyReturnRate(from annualReturnRate: Double) -> Double {
        let boundedAnnualReturnRate = min(max(annualReturnRate, -0.99), 1.0)
        return pow(1 + boundedAnnualReturnRate, 1.0 / 12.0) - 1
    }

    private static func monthlyReturnRateToAnnualRate(_ monthlyReturnRate: Double) -> Double {
        pow(1 + monthlyReturnRate, 12) - 1
    }
}

private struct DashboardFreedomSection: View {
    let projection: FinancialFreedomProjection?
    @Binding var monthlySalary: Double
    @Binding var annualReturnRate: Double
    @Binding var monthlyExpense: Double
    @Binding var inflationRate: Double

    @State private var isEditingMonthlyExpense = false
    @State private var isEditingInflationRate = false
    @State private var isEditingMonthlySalary = false
    @State private var isEditingAnnualReturnRate = false
    @State private var showsAlgorithmExplanation = false
    @State private var monthlyExpenseDraft = ""
    @State private var inflationRateDraft = ""
    @State private var monthlySalaryDraft = ""
    @State private var annualReturnRateDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Text(statusText)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 8)

                Button {
                    showsAlgorithmExplanation = true
                } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("查看财富自由算法说明"))
            }

            if let reasonText {
                Text(reasonText)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    parameterButton(title: AppLocalization.string("月开销"), value: monthlyExpense.currencyString(), action: openMonthlyExpenseEditor)
                    parameterButton(title: AppLocalization.string("月薪"), value: monthlySalary.currencyString(), action: openMonthlySalaryEditor)
                }

                HStack(spacing: 8) {
                    parameterButton(title: AppLocalization.string("通胀率"), value: inflationRate.formatted(.percent.precision(.fractionLength(1))), action: openInflationRateEditor)
                    parameterButton(title: AppLocalization.string("年化收益"), value: annualReturnRate.formatted(.percent.precision(.fractionLength(1))), action: openAnnualReturnRateEditor)
                }
            }

            Text(annualSurplusRequirementText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let projection, !projection.projectionPoints.isEmpty {
                DashboardFreedomProjectionChart(projection: projection)
                    .padding(.top, 2)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(AssetTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: AssetTheme.cardShadow.opacity(0.85), radius: 22, x: 0, y: 10)
        .alert(AppLocalization.string("修改月开销"), isPresented: $isEditingMonthlyExpense) {
            TextField(AppLocalization.string("例如 8000"), text: $monthlyExpenseDraft)
                .keyboardType(.decimalPad)
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("确定")) {
                applyMonthlyExpenseDraft()
            }
        } message: {
            Text(AppLocalization.string("用于设置财富自由测算的月开销。"))
        }
        .alert(AppLocalization.string("修改通胀率"), isPresented: $isEditingInflationRate) {
            TextField(AppLocalization.string("例如 3.0"), text: $inflationRateDraft)
                .keyboardType(.decimalPad)
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("确定")) {
                applyInflationRateDraft()
            }
        } message: {
            Text(AppLocalization.string("请输入百分比数值，例如 3 表示 3%。"))
        }
        .alert(AppLocalization.string("修改月薪"), isPresented: $isEditingMonthlySalary) {
            TextField(AppLocalization.string("例如 10000"), text: $monthlySalaryDraft)
                .keyboardType(.decimalPad)
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("确定")) {
                applyMonthlySalaryDraft()
            }
        } message: {
            Text(AppLocalization.string("每月收入会先扣除当月开销，剩余结余再与月复利一起影响净资产。"))
        }
        .alert(AppLocalization.string("修改年化收益"), isPresented: $isEditingAnnualReturnRate) {
            TextField(AppLocalization.string("例如 3.0"), text: $annualReturnRateDraft)
                .keyboardType(.decimalPad)
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("确定")) {
                applyAnnualReturnRateDraft()
            }
        } message: {
            Text(AppLocalization.string("请输入百分比数值，例如 3 表示 3%。"))
        }
        .alert(AppLocalization.string("财富自由算法"), isPresented: $showsAlgorithmExplanation) {
            Button(AppLocalization.string("知道了"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("当前净资产作为起始本金；每个月先按年化收益换算出的月复利增长，再加入当月结余（月薪 - 通胀后的月开销）；被动收入按你填写的年化收益折算为每月：净资产 × 年化收益 ÷ 12；目标是被动收入覆盖考虑通胀后的月开销。"))
        }
    }

    private func parameterButton(title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)

                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AssetTheme.overlaySubtle.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.24), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func openMonthlyExpenseEditor() {
        monthlyExpenseDraft = String(Int(monthlyExpense.rounded()))
        isEditingMonthlyExpense = true
    }

    private func openInflationRateEditor() {
        inflationRateDraft = String(format: "%.1f", inflationRate * 100)
        isEditingInflationRate = true
    }

    private func openMonthlySalaryEditor() {
        monthlySalaryDraft = String(Int(monthlySalary.rounded()))
        isEditingMonthlySalary = true
    }

    private func openAnnualReturnRateEditor() {
        annualReturnRateDraft = String(format: "%.1f", annualReturnRate * 100)
        isEditingAnnualReturnRate = true
    }

    private func applyMonthlyExpenseDraft() {
        let sanitized = monthlyExpenseDraft
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value = Double(sanitized), value.isFinite else { return }
        monthlyExpense = max(1000, value)
    }

    private func applyInflationRateDraft() {
        let sanitized = inflationRateDraft
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let percent = Double(sanitized), percent.isFinite else { return }
        inflationRate = min(max(percent / 100, 0), 0.2)
    }

    private func applyMonthlySalaryDraft() {
        let sanitized = monthlySalaryDraft
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value = Double(sanitized), value.isFinite else { return }
        monthlySalary = max(0, value)
    }

    private func applyAnnualReturnRateDraft() {
        let sanitized = annualReturnRateDraft
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let percent = Double(sanitized), percent.isFinite else { return }
        annualReturnRate = min(max(percent / 100, -0.99), 1.0)
    }

    private var annualSurplusRequirementText: String {
        guard let projection else {
            return AppLocalization.string("今年需要年结余：记录资产快照后可估算")
        }

        let averageMonthlySurplus = projection.projectedAnnualSurplus / 12
        return AppLocalization.format(
            AppLocalization.string("今年需要年结余 %@ · 平均月结余 %@"),
            projection.projectedAnnualSurplus.currencyString(),
            averageMonthlySurplus.currencyString()
        )
    }

    private var statusText: String {
        guard let projection else { return AppLocalization.string("财富自由时间估算") }

        switch projection.status {
        case .alreadyFree:
            return AppLocalization.string("已达到财富自由")
        case let .projected(months):
            let years = months / 12
            let remainingMonths = months % 12
            if years > 0, remainingMonths > 0 {
                return AppLocalization.format("预计还需 %d 年 %d 月", years, remainingMonths)
            } else if years > 0 {
                return AppLocalization.format("预计还需 %d 年", years)
            } else {
                return AppLocalization.format("预计还需 %d 月", remainingMonths)
            }
        case .unreachable:
            return AppLocalization.string("当前无法财富自由")
        }
    }

    private var reasonText: String? {
        guard let projection else {
            return AppLocalization.string("记录资产快照后可开始估算")
        }

        switch projection.status {
        case .alreadyFree, .projected:
            return nil
        case .unreachable:
            if let requiredSalary = projection.requiredMonthlySalaryToReachFreedom {
                return AppLocalization.format(
                    AppLocalization.string("按当前参数，需控制月开销在 %@ 以内，或收入涨到 %@/月。"),
                    projection.maximumReachableMonthlyExpense.currencyString(),
                    requiredSalary.currencyString()
                )
            } else {
                return AppLocalization.format(
                    AppLocalization.string("按当前参数，需控制月开销在 %@ 以内。"),
                    projection.maximumReachableMonthlyExpense.currencyString()
                )
            }
        }
    }

    private var statusColor: Color {
        guard let projection else { return AssetTheme.textPrimary }
        switch projection.status {
        case .alreadyFree:
            return AssetTheme.goldSoft
        case .projected:
            return AssetTheme.textPrimary
        case .unreachable:
            return AssetTheme.accentOrange
        }
    }
}

private struct DashboardFreedomProjectionChart: View {
    let projection: FinancialFreedomProjection

    private struct IncomeCoveragePoint: Identifiable {
        let id: String
        let monthOffset: Double
        let date: Date
        let passiveIncome: Double
    }

    private struct IncomeCoverageSegment: Identifiable {
        enum State {
            case aboveExpense
            case belowExpense
        }

        let id: String
        let state: State
        let points: [IncomeCoveragePoint]
    }

    private struct CrossingMarker {
        let monthOffset: Double
        let date: Date
        let passiveIncome: Double
    }

    private struct ChartAnalysis {
        let segments: [IncomeCoverageSegment]
        let crossingMarker: CrossingMarker?
    }

    private var points: [FinancialFreedomProjectionPoint] {
        projection.projectionPoints
    }

    private var chartAnalysis: ChartAnalysis {
        buildChartAnalysis()
    }

    private var valueDomain: ClosedRange<Double> {
        paddedDomain(values: points.flatMap { [$0.projectedPassiveIncome, $0.projectedMonthlyExpense] })
    }


    private var xDomain: ClosedRange<Date> {
        guard let first = points.first?.date,
              let last = points.last?.date else {
            let now = Date()
            return now...now
        }
        return first...last
    }

    private var xAxisDates: [Date] {
        chartAxisDates(points.map(\.date))
    }

    private var horizonText: String {
        let months = max(points.count - 1, 0)
        if months >= 12 {
            let years = months / 12
            let remainingMonths = months % 12
            if remainingMonths > 0 {
                return AppLocalization.format("未来 %d 年 %d 月", years, remainingMonths)
            }
            return AppLocalization.format("未来 %d 年", years)
        }
        return AppLocalization.format("未来 %d 月", months)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Spacer(minLength: 12)
                Text(horizonText)
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            HStack(spacing: 12) {
                projectionLegendChip(title: AppLocalization.string("被动收入"), color: AssetTheme.goldSoft)
                projectionLegendChip(title: AppLocalization.string("通胀开销"), color: AssetTheme.accentOrange, dashed: true)
            }

            HStack(alignment: .top, spacing: 8) {
                TimeMachineAxisStrip(
                    topLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: valueDomain.upperBound),
                    middleLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: (valueDomain.lowerBound + valueDomain.upperBound) / 2),
                    bottomLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: valueDomain.lowerBound),
                    alignment: .leading,
                    color: AssetTheme.goldSoft
                )
                .frame(width: 42, height: 154)
                .padding(.top, 10)

                VStack(alignment: .leading, spacing: 8) {
                    Chart {
                        ForEach(chartAnalysis.segments) { segment in
                            ForEach(segment.points) { point in
                                LineMark(
                                    x: .value(AppLocalization.string("日期"), point.date),
                                    y: .value(AppLocalization.string("预计被动收入"), point.passiveIncome),
                                    series: .value(AppLocalization.string("系列"), segment.id)
                                )
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(segment.state == .aboveExpense ? AssetTheme.positive : AssetTheme.negative)
                            }
                        }

                        ForEach(points) { point in
                            LineMark(
                                x: .value(AppLocalization.string("日期"), point.date),
                                y: .value(AppLocalization.string("通胀后月开销"), point.projectedMonthlyExpense),
                                series: .value(AppLocalization.string("系列"), AppLocalization.string("通胀后月开销"))
                            )
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [6, 4]))
                            .foregroundStyle(AssetTheme.accentOrange.opacity(0.9))
                        }


                        if let crossingMarker = chartAnalysis.crossingMarker {
                            RuleMark(x: .value(AppLocalization.string("追平时间"), crossingMarker.date))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                                .foregroundStyle(AssetTheme.positive.opacity(0.8))
                                .annotation(position: .top, spacing: 6) {
                                    crossingBadge(for: crossingMarker.monthOffset)
                                }

                            PointMark(
                                x: .value(AppLocalization.string("追平时间"), crossingMarker.date),
                                y: .value(AppLocalization.string("追平值"), crossingMarker.passiveIncome)
                            )
                            .foregroundStyle(AssetTheme.positive)
                            .symbolSize(40)
                        }

                        if let latestPoint = points.last {
                            PointMark(
                                x: .value(AppLocalization.string("日期"), latestPoint.date),
                                y: .value(AppLocalization.string("预计被动收入"), latestPoint.projectedPassiveIncome)
                            )
                            .foregroundStyle(latestPoint.projectedPassiveIncome >= latestPoint.projectedMonthlyExpense ? AssetTheme.positive : AssetTheme.negative)
                            .symbolSize(36)

                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 188)
                    .chartXScale(domain: xDomain)
                    .chartYScale(domain: valueDomain)
                    .chartXAxis {
                        AxisMarks(values: xAxisDates) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                                .foregroundStyle(AssetTheme.chartGrid.opacity(0.68))
                            AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                                .foregroundStyle(AssetTheme.chartTick.opacity(0.7))
                            AxisValueLabel {
                                EmptyView()
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                                .foregroundStyle(AssetTheme.chartGrid.opacity(0.68))
                            AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                                .foregroundStyle(.clear)
                            AxisValueLabel {
                                EmptyView()
                            }
                        }
                    }
                    .chartLegend(.hidden)
                    .chartPlotStyle { plotArea in
                        plotArea
                            .background(
                                LinearGradient(
                                    colors: [
                                        AssetTheme.overlayFaint.opacity(0.45),
                                        AssetTheme.overlaySubtle.opacity(0.10)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .overlay(alignment: .topLeading) {
                        Text(AppLocalization.string("收入覆盖趋势"))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }

                    freedomProjectionBottomLabels
                        .padding(.horizontal, 4)
                }
            }

            if let latestPoint = points.last {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        projectionMetric(title: AppLocalization.string("当前被动收入"), value: projection.currentPassiveIncome.currencyString())
                        projectionMetric(title: AppLocalization.string("当前月开销"), value: projection.currentMonthlyExpense.currencyString())
                        projectionMetric(title: AppLocalization.string("终点被动收入"), value: latestPoint.projectedPassiveIncome.currencyString())
                    }

                    Rectangle()
                        .fill(AssetTheme.border.opacity(0.28))
                        .frame(height: 1)
                        .padding(.vertical, 8)

                    HStack(spacing: 14) {
                        projectionMetric(title: AppLocalization.string("当前总资产"), value: projection.currentTotalAssets.currencyString())
                        projectionMetric(title: AppLocalization.string("终点总资产"), value: latestPoint.projectedTotalAssets.currencyString())
                    }
                }
            }
        }
    }

    private func axisLabelPosition(for date: Date, in axisDates: [Date]) -> TimeMachineAxisDateLabel.Position {
        guard let first = axisDates.first, let last = axisDates.last else { return .middle }
        if Calendar.current.isDate(date, inSameDayAs: first) {
            return .leading
        }
        if Calendar.current.isDate(date, inSameDayAs: last) {
            return .trailing
        }
        return .middle
    }

    @ViewBuilder
    private func freedomProjectionAxisLabel(for date: Date, position: TimeMachineAxisDateLabel.Position) -> some View {
        Text(date.dashboardAxisDateString)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(AssetTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 34, alignment: freedomProjectionAxisAlignment(for: position))
    }

    private var freedomProjectionBottomLabels: some View {
        HStack(alignment: .top, spacing: 0) {
            if let first = xAxisDates.first {
                freedomProjectionAxisLabel(for: first, position: .leading)
            }

            Spacer(minLength: 12)

            if xAxisDates.count > 2 {
                let middle = xAxisDates[xAxisDates.count / 2]
                freedomProjectionAxisLabel(for: middle, position: .middle)
                Spacer(minLength: 12)
            }

            if xAxisDates.count > 1, let last = xAxisDates.last {
                freedomProjectionAxisLabel(for: last, position: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func freedomProjectionAxisAlignment(for position: TimeMachineAxisDateLabel.Position) -> Alignment {
        switch position {
        case .leading:
            return .leading
        case .middle:
            return .center
        case .trailing:
            return .trailing
        }
    }

    private func buildChartAnalysis() -> ChartAnalysis {
        guard let firstPoint = points.first else {
            return ChartAnalysis(segments: [], crossingMarker: nil)
        }

        func coverageState(for point: FinancialFreedomProjectionPoint) -> IncomeCoverageSegment.State {
            point.projectedPassiveIncome >= point.projectedMonthlyExpense ? .aboveExpense : .belowExpense
        }

        func makeCoveragePoint(from point: FinancialFreedomProjectionPoint, suffix: String = "") -> IncomeCoveragePoint {
            IncomeCoveragePoint(
                id: "\(point.monthOffset)\(suffix)",
                monthOffset: Double(point.monthOffset),
                date: point.date,
                passiveIncome: point.projectedPassiveIncome
            )
        }

        var segments: [IncomeCoverageSegment] = []
        var currentSegmentState = coverageState(for: firstPoint)
        var currentPoints: [IncomeCoveragePoint] = [makeCoveragePoint(from: firstPoint)]
        var crossingMarker: CrossingMarker?
        var segmentIndex = 0

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let previousGap = previous.projectedPassiveIncome - previous.projectedMonthlyExpense
            let currentGap = current.projectedPassiveIncome - current.projectedMonthlyExpense

            let previousState = coverageState(for: previous)
            let currentState = coverageState(for: current)
            let hasCrossing = previousState != currentState && abs(previousGap - currentGap) > .ulpOfOne

            if hasCrossing {
                let progress = previousGap / (previousGap - currentGap)
                let clampedProgress = min(max(progress, 0), 1)
                let crossingMonthOffset = Double(previous.monthOffset) + (Double(current.monthOffset - previous.monthOffset) * clampedProgress)
                let crossingDate = previous.date.addingTimeInterval(current.date.timeIntervalSince(previous.date) * clampedProgress)
                let crossingIncome = previous.projectedPassiveIncome + ((current.projectedPassiveIncome - previous.projectedPassiveIncome) * clampedProgress)
                let crossingPoint = IncomeCoveragePoint(
                    id: "crossing-\(index)",
                    monthOffset: crossingMonthOffset,
                    date: crossingDate,
                    passiveIncome: crossingIncome
                )

                currentPoints.append(crossingPoint)
                segments.append(
                    IncomeCoverageSegment(
                        id: "income-segment-\(segmentIndex)",
                        state: currentSegmentState,
                        points: currentPoints
                    )
                )

                if crossingMarker == nil {
                    crossingMarker = CrossingMarker(
                        monthOffset: crossingMonthOffset,
                        date: crossingDate,
                        passiveIncome: crossingIncome
                    )
                }

                segmentIndex += 1
                currentSegmentState = currentState
                currentPoints = [crossingPoint, makeCoveragePoint(from: current)]
            } else {
                currentPoints.append(makeCoveragePoint(from: current))
            }
        }

        segments.append(
            IncomeCoverageSegment(
                id: "income-segment-\(segmentIndex)",
                state: currentSegmentState,
                points: currentPoints
            )
        )

        return ChartAnalysis(segments: segments, crossingMarker: crossingMarker)
    }

    private func crossingBadge(for monthOffset: Double) -> some View {
        Text(AppLocalization.format(AppLocalization.string("约 %@ 追平"), crossingLabel(for: monthOffset)))
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AssetTheme.surfaceRaised.opacity(0.96), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(AssetTheme.positive.opacity(0.35), lineWidth: 1)
            )
    }

    private func crossingLabel(for monthOffset: Double) -> String {
        let roundedMonths = max(Int(monthOffset.rounded()), 0)
        if roundedMonths >= 12 {
            let years = roundedMonths / 12
            let months = roundedMonths % 12
            if months > 0 {
                return AppLocalization.format(AppLocalization.string("%d 年 %d 月"), years, months)
            }
            return AppLocalization.format(AppLocalization.string("%d 年"), years)
        }
        return AppLocalization.format(AppLocalization.string("%d 月"), max(roundedMonths, 1))
    }


    private func paddedDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter { $0.isFinite }
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }

    private func projectionLegendChip(title: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 6) {
            Group {
                if dashed {
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule()
                                .fill(color)
                                .frame(width: 4, height: 3)
                        }
                    }
                    .frame(width: 16, alignment: .leading)
                } else {
                    Capsule()
                        .fill(color)
                        .frame(width: 16, height: 3)
                }
            }

            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 4)
    }

    private func projectionMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(value)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(AssetTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardTrendCard: View {
    let points: [TimeMachineTrendPoint]
    let latestPoint: TimeMachineTrendPoint
    @State private var selectedDate: Date?

    private var displayPoints: [TimeMachineTrendPoint] {
        evenlySampledItems(points, maxCount: 120)
    }

    private var selectedPoint: TimeMachineTrendPoint {
        guard let selectedDate else { return latestPoint }
        return nearestTrendPoint(to: selectedDate, in: displayPoints) ?? latestPoint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ForEach(TimeMachineAssetSeries.allCases) { series in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 999, style: .continuous)
                            .fill(series.color)
                            .frame(width: 16, height: 3)
                            .overlay {
                                if series == .liabilities {
                                    HStack(spacing: 3) {
                                        ForEach(0..<3, id: \.self) { _ in
                                            Capsule()
                                                .fill(series.color)
                                                .frame(width: 4, height: 3)
                                        }
                                    }
                                }
                            }

                        Text(series.title)
                            .font(AppTypography.meta)
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                }
            }

            Chart {
                ForEach(TimeMachineAssetSeries.allCases) { series in
                    ForEach(displayPoints) { point in
                        LineMark(
                            x: .value(AppLocalization.string("日期"), point.date),
                            y: .value(series.title, series.value(from: point))
                        )
                        .foregroundStyle(by: .value(AppLocalization.string("序列"), series.title))
                        .lineStyle(series.strokeStyle)
                        .interpolationMethod(.catmullRom)
                    }

                    PointMark(
                        x: .value(AppLocalization.string("日期"), selectedPoint.date),
                        y: .value(series.title, series.value(from: selectedPoint))
                    )
                    .foregroundStyle(series.color)
                    .symbolSize(44)
                }

                if selectedDate != nil {
                    RuleMark(x: .value(AppLocalization.string("选中日期"), selectedPoint.date))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .chartForegroundStyleScale([
                TimeMachineAssetSeries.mainAssets.title: TimeMachineAssetSeries.mainAssets.color,
                TimeMachineAssetSeries.netAssets.title: TimeMachineAssetSeries.netAssets.color,
                TimeMachineAssetSeries.liabilities.title: TimeMachineAssetSeries.liabilities.color,
            ])
            .frame(height: 236)
            .chartXAxis {
                let axisDates = chartAxisDates(displayPoints.map(\.date))
                AxisMarks(values: axisDates) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(AssetTheme.chartGrid)
                    AxisTick().foregroundStyle(AssetTheme.chartTick)
                    AxisValueLabel(anchor: axisLabelAnchor(for: value.as(Date.self), in: axisDates), verticalSpacing: 6) {
                        if let date = value.as(Date.self) {
                            Text(date.dashboardAxisDateString)
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(AssetTheme.chartGrid)
                    AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                TimeMachineDragOverlay(proxy: proxy) { date in
                    selectedDate = date
                } onEnded: {
                    selectedDate = nil
                }
            }
            .padding(.top, 2)

            Text(selectedDate == nil ? dateRangeLabel : selectedPoint.date.chartAxisDateString)
                .font(AppTypography.meta)
                .foregroundStyle(AssetTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 8)
    }

    private var dateRangeLabel: String {
        guard let first = points.first?.date else { return AppLocalization.string("暂无范围") }
        return "\(first.chartAxisDateString) - \(latestPoint.date.chartAxisDateString)"
    }

    private func axisLabelPosition(for date: Date, in axisDates: [Date]) -> TimeMachineAxisDateLabel.Position {
        guard let first = axisDates.first, let last = axisDates.last else { return .middle }
        if Calendar.current.isDate(date, inSameDayAs: first) {
            return .leading
        }
        if Calendar.current.isDate(date, inSameDayAs: last) {
            return .trailing
        }
        return .middle
    }

    private func axisLabelAnchor(for date: Date?, in axisDates: [Date]) -> UnitPoint {
        guard let date else { return .top }
        switch axisLabelPosition(for: date, in: axisDates) {
        case .leading:
            return .topLeading
        case .middle:
            return .top
        case .trailing:
            return .topTrailing
        }
    }
}

private struct TimeMachineRangeSelector: View {
    @Binding var selectedRange: TimeMachineRange

    var body: some View {
        Menu {
            ForEach(TimeMachineRange.allCases) { range in
                Button {
                    selectedRange = range
                } label: {
                    if selectedRange == range {
                        Label(range.summaryLabel, systemImage: "checkmark")
                    } else {
                        Text(range.summaryLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedRange.summaryLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(AssetTheme.overlayFaint.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct TimeMachineInlineMetric: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(accent.opacity(0.92))
                .frame(width: 7, height: 7)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string(title))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.82))
                    .lineLimit(1)

                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
    }
}

private struct TimeMachineCurrentAnchorItem: Identifiable {
    let title: String
    let value: String
    let detail: String
    let accent: Color

    var id: String { title }
}

private struct TimeMachineHeroTrendCard: View {
    let points: [TimeMachineTrendPoint]
    let latestPoint: TimeMachineTrendPoint
    @Binding var selectedRange: TimeMachineRange
    @State private var selectedDate: Date?
    private let cardCornerRadius: CGFloat = 26
    private let plotCornerRadius: CGFloat = 20

    private var displayPoints: [TimeMachineTrendPoint] {
        evenlySampledItems(points, maxCount: 160)
    }

    private var selectedPoint: TimeMachineTrendPoint {
        guard let selectedDate else { return latestPoint }
        return nearestTrendPoint(to: selectedDate, in: displayPoints) ?? latestPoint
    }

    private var valueDomain: ClosedRange<Double> {
        paddedDomain(values: displayPoints.flatMap { point in
            TimeMachineAssetSeries.allCases.map { $0.value(from: point) }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            heroHeader
            metricGrid
            legendRow

            Chart {
                ForEach(TimeMachineAssetSeries.allCases) { series in
                    ForEach(displayPoints) { point in
                        LineMark(
                            x: .value(AppLocalization.string("日期"), point.date),
                            y: .value(series.title, series.value(from: point))
                        )
                        .foregroundStyle(by: .value(AppLocalization.string("序列"), series.title))
                        .lineStyle(series.strokeStyle)
                        .interpolationMethod(.catmullRom)
                    }

                    PointMark(
                        x: .value(AppLocalization.string("日期"), selectedPoint.date),
                        y: .value(series.title, series.value(from: selectedPoint))
                    )
                    .foregroundStyle(series.color)
                    .symbolSize(selectedDate == nil ? 36 : 58)
                }

                if selectedDate != nil {
                    RuleMark(x: .value(AppLocalization.string("选中日期"), selectedPoint.date))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.38))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 5]))
                }
            }
            .chartForegroundStyleScale([
                TimeMachineAssetSeries.mainAssets.title: TimeMachineAssetSeries.mainAssets.color,
                TimeMachineAssetSeries.netAssets.title: TimeMachineAssetSeries.netAssets.color,
                TimeMachineAssetSeries.liabilities.title: TimeMachineAssetSeries.liabilities.color,
            ])
            .frame(height: 226)
            .chartYScale(domain: valueDomain)
            .chartXAxis {
                let axisDates = chartAxisDates(displayPoints.map(\.date))
                AxisMarks(values: axisDates) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                        .foregroundStyle(AssetTheme.chartGrid.opacity(0.78))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                        .foregroundStyle(AssetTheme.chartTick.opacity(0.7))
                    AxisValueLabel(anchor: .top, verticalSpacing: 7) {
                        if let date = value.as(Date.self) {
                            TimeMachineAxisDateLabel(date: date, position: axisLabelPosition(for: date, in: axisDates))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                        .foregroundStyle(AssetTheme.chartGrid.opacity(0.72))
                    AxisValueLabel {
                        if let y = value.as(Double.self) {
                            Text(y, format: .number.notation(.compactName))
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartPlotStyle { plotArea in
                plotArea
                    .background(AssetTheme.surface.opacity(0.42))
                    .clipShape(RoundedRectangle(cornerRadius: plotCornerRadius, style: .continuous))
            }
            .chartOverlay { proxy in
                TimeMachineDragOverlay(proxy: proxy) { date in
                    selectedDate = date
                } onEnded: {
                    selectedDate = nil
                }
            }
            .padding(.horizontal, 3)
            .padding(.top, 2)
            .padding(.bottom, 6)
            .onboardingAnchor(.timeMachineChart)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(AssetTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: AssetTheme.cardShadow.opacity(0.78), radius: 18, x: 0, y: 10)
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                Text(AppLocalization.string("总资产"))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 10)

                TimeMachineRangeSelector(selectedRange: $selectedRange)
            }
            .onboardingAnchor(.timeMachineRange)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(selectedPoint.mainAssets.currencyString())
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.goldSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)

                Spacer(minLength: 8)

                Text(selectedDate == nil ? dateRangeLabel : selectedPoint.date.chartAxisDateString)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(AssetTheme.surface.opacity(0.72), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AssetTheme.border.opacity(selectedDate == nil ? 0.28 : 0.58), lineWidth: 1)
                    )
            }
        }
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            TimeMachineInlineMetric(
                title: "净资产",
                value: selectedPoint.netAssets.currencyString(),
                accent: AssetTheme.positive
            )
            TimeMachineInlineMetric(
                title: "负债",
                value: selectedPoint.liabilities.currencyString(),
                accent: AssetTheme.negative
            )
            TimeMachineInlineMetric(
                title: "黄金折算",
                value: selectedPoint.goldEquivalent?.plainNumberString() ?? "--",
                accent: AssetTheme.gold
            )
            TimeMachineInlineMetric(
                title: "纳指折算",
                value: selectedPoint.nasdaqEquivalent?.plainNumberString() ?? "--",
                accent: AssetTheme.accentBlue
            )
        }
    }

    private var legendRow: some View {
        HStack(spacing: 7) {
            ForEach(TimeMachineAssetSeries.allCases) { series in
                TimeMachineHeroLegendItem(series: series)
            }
            Spacer(minLength: 0)
        }
    }

    private var dateRangeLabel: String {
        guard let first = points.first?.date, let last = points.last?.date else { return AppLocalization.string("暂无范围") }
        return "\(first.chartAxisDateString) - \(last.chartAxisDateString)"
    }

    private func axisLabelPosition(for date: Date, in axisDates: [Date]) -> TimeMachineAxisDateLabel.Position {
        guard let first = axisDates.first, let last = axisDates.last else { return .middle }
        if Calendar.current.isDate(date, inSameDayAs: first) {
            return .leading
        }
        if Calendar.current.isDate(date, inSameDayAs: last) {
            return .trailing
        }
        return .middle
    }

    private func paddedDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter { $0.isFinite }
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }
}

private struct TimeMachineHeroLegendItem: View {
    let series: TimeMachineAssetSeries

    var body: some View {
        HStack(spacing: 5) {
            legendMark

            Text(series.title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var legendMark: some View {
        if series == .liabilities {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(series.color)
                        .frame(width: 4, height: 3)
                }
            }
            .frame(width: 16, alignment: .leading)
        } else {
            Capsule()
                .fill(series.color)
                .frame(width: 16, height: 3)
        }
    }
}

private func nearestTrendPoint(to date: Date, in points: [TimeMachineTrendPoint]) -> TimeMachineTrendPoint? {
    points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
}

private func chartAxisDates(_ dates: [Date]) -> [Date] {
    let sortedDates = Array(Set(dates)).sorted()
    guard let first = sortedDates.first else { return [] }
    guard sortedDates.count > 2, let last = sortedDates.last else { return sortedDates }

    let middle = sortedDates[sortedDates.count / 2]
    return Array(Set([first, middle, last])).sorted()
}

private struct TimeMachineAxisDateLabel: View {
    enum Position {
        case leading
        case middle
        case trailing
    }

    let date: Date
    var position: Position = .middle

    private var anchor: UnitPoint {
        switch position {
        case .leading:
            return .topLeading
        case .middle:
            return .top
        case .trailing:
            return .topTrailing
        }
    }

    private var xOffset: CGFloat {
        switch position {
        case .leading:
            return 24
        case .middle:
            return 0
        case .trailing:
            return -24
        }
    }

    var body: some View {
        Text(date.chartAxisShortDateString)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(AssetTheme.textSecondary)
            .fixedSize()
            .rotationEffect(.degrees(-28), anchor: anchor)
            .offset(x: xOffset)
    }
}

private struct TimeMachineMonthlySurplusCard: View {
    let points: [TimeMachineMonthlySurplusPoint]
    let annualPoints: [TimeMachineAnnualSurplusPoint]
    @State private var selectedDate: Date?
    @State private var selectedGranularity: SurplusGranularity = .monthly
    private let cardCornerRadius: CGFloat = 22
    private let chartCornerRadius: CGFloat = 18

    private enum SurplusGranularity: String, CaseIterable, Identifiable {
        case monthly
        case annual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .monthly: return AppLocalization.string("月结余")
            case .annual: return AppLocalization.string("年结余")
            }
        }
    }

    private var activeGranularity: SurplusGranularity {
        switch selectedGranularity {
        case .monthly:
            return points.isEmpty && !annualPoints.isEmpty ? .annual : .monthly
        case .annual:
            return annualPoints.isEmpty && !points.isEmpty ? .monthly : .annual
        }
    }

    private var displayPoints: [TimeMachineMonthlySurplusPoint] {
        evenlySampledItems(points, maxCount: 48)
    }

    private var latestPoint: TimeMachineMonthlySurplusPoint? {
        displayPoints.last ?? points.last
    }

    private var selectedPoint: TimeMachineMonthlySurplusPoint? {
        guard let latestPoint else { return nil }
        guard let selectedDate else { return latestPoint }
        return nearestMonthlySurplusPoint(to: selectedDate, in: displayPoints) ?? latestPoint
    }

    private var latestAnnualPoint: TimeMachineAnnualSurplusPoint? {
        annualPoints.last
    }

    private var leftDomain: ClosedRange<Double> {
        paddedSurplusDomain(values: displayPoints.map(\.surplus))
    }

    private var averageSurplus: Double {
        guard !points.isEmpty else { return 0 }
        return points.reduce(0) { $0 + $1.surplus } / Double(points.count)
    }

    private var positiveMonthCount: Int {
        points.filter { $0.surplus >= 0 }.count
    }

    private var bestMonthPoint: TimeMachineMonthlySurplusPoint? {
        points.max { $0.surplus < $1.surplus }
    }

    private var currentDateLabel: String {
        switch activeGranularity {
        case .monthly:
            return selectedDate == nil ? dateRangeLabel : (selectedPoint?.monthStart.dashboardAxisDateString ?? dateRangeLabel)
        case .annual:
            guard let first = annualPoints.first?.yearStart, let last = annualPoints.last?.yearStart else {
                return AppLocalization.string("暂无范围")
            }
            return "\(first.yearAxisDateString) - \(last.yearAxisDateString)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if activeGranularity == .monthly, !displayPoints.isEmpty {
                chartSection
            } else if activeGranularity == .annual, !annualPoints.isEmpty {
                TimeMachineAnnualSurplusCard(points: annualPoints)
            }

            if activeGranularity == .monthly {
                summaryRow
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(AssetTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: AssetTheme.cardShadow.opacity(0.46), radius: 14, x: 0, y: 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(AppLocalization.string("结余"))
                    .font(.system(size: 16.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 8)

                Picker(AppLocalization.string("结余周期"), selection: $selectedGranularity) {
                    ForEach(SurplusGranularity.allCases) { granularity in
                        Text(granularity.title).tag(granularity)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
                .disabled(points.isEmpty || annualPoints.isEmpty)
            }

            if activeGranularity == .monthly {
                HStack(alignment: .center, spacing: 8) {
                    Text(currentDateLabel)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)

                    Spacer(minLength: 8)

                    if let selectedPoint {
                        TimeMachineCompactLegendMetric(
                            title: AppLocalization.string("结余"),
                            value: formattedSurplus(selectedPoint.surplus),
                            color: surplusColor(for: selectedPoint.surplus),
                            dashed: false
                        )
                    }
                }
            }
        }
    }

    private var chartSection: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = 46
            let chartWidth = max(geometry.size.width - leftWidth - 18, 120)

            HStack(spacing: 6) {
                TimeMachineAxisStrip(
                    topLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: leftDomain.upperBound),
                    middleLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: (leftDomain.lowerBound + leftDomain.upperBound) / 2),
                    bottomLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: leftDomain.lowerBound),
                    alignment: .leading,
                    color: AssetTheme.gold
                )
                .frame(width: leftWidth)

                Chart {
                    RuleMark(y: .value(AppLocalization.string("零线"), normalized(0, in: leftDomain)))
                        .foregroundStyle(AssetTheme.border.opacity(0.42))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    ForEach(displayPoints) { point in
                        BarMark(
                            x: .value(AppLocalization.string("月份"), point.monthStart),
                            yStart: .value(AppLocalization.string("零线"), normalized(0, in: leftDomain)),
                            yEnd: .value(AppLocalization.string("月结余"), normalized(point.surplus, in: leftDomain))
                        )
                        .foregroundStyle(surplusColor(for: point.surplus).opacity(selectedPoint?.id == point.id ? 0.96 : 0.82))
                    }

                    if selectedDate != nil, let selectedPoint {
                        RuleMark(x: .value(AppLocalization.string("选中月份"), selectedPoint.monthStart))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(width: chartWidth, height: 168)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis { bottomAxisMarks }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    TimeMachineDragOverlay(proxy: proxy) { date in
                        selectedDate = date
                    } onEnded: {
                        selectedDate = nil
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background(chartBackground)
        }
        .frame(height: 186)
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            TimeMachineLegendMetric(
                title: AppLocalization.string("月均结余"),
                value: formattedSurplus(averageSurplus),
                color: surplusColor(for: averageSurplus),
                dashed: false
            )

            TimeMachineLegendMetric(
                title: AppLocalization.string("正结余月份"),
                value: "\(positiveMonthCount)/\(points.count)",
                color: AssetTheme.positive,
                dashed: false
            )

            TimeMachineLegendMetric(
                title: AppLocalization.string("最好单月"),
                value: bestMonthPoint.map { formattedSurplus($0.surplus) } ?? "--",
                color: AssetTheme.goldSoft,
                dashed: true
            )
        }
    }

    private var bottomAxisMarks: some AxisContent {
        let axisDates = chartAxisDates(displayPoints.map(\.monthStart))
        return AxisMarks(values: axisDates) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                .foregroundStyle(AssetTheme.border.opacity(0.28))
            AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                .foregroundStyle(AssetTheme.border.opacity(0.5))
            AxisValueLabel(anchor: .top, verticalSpacing: 8) {
                if let date = value.as(Date.self) {
                    Text(date.dashboardAxisDateString)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
        }
    }

    private var chartBackground: some View {
        RoundedRectangle(cornerRadius: chartCornerRadius, style: .continuous)
            .fill(AssetTheme.surface.opacity(0.46))
    }

    private var dateRangeLabel: String {
        guard let first = points.first?.monthStart, let last = points.last?.monthStart else { return AppLocalization.string("暂无范围") }
        return "\(first.dashboardAxisDateString) - \(last.dashboardAxisDateString)"
    }

    private func normalized(_ value: Double, in domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span.isFinite, span > 0 else { return 0.5 }
        return (value - domain.lowerBound) / span
    }

    private func paddedSurplusDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter { $0.isFinite }
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return -1...1
        }

        let adjustedMin = min(minValue, 0)
        let adjustedMax = max(maxValue, 0)
        if abs(adjustedMax - adjustedMin) < .ulpOfOne {
            let padding = max(abs(adjustedMax) * 0.08, 1)
            return (adjustedMin - padding)...(adjustedMax + padding)
        }
        let padding = max((adjustedMax - adjustedMin) * 0.14, max(abs(adjustedMax), abs(adjustedMin)) * 0.03, 1)
        return (adjustedMin - padding)...(adjustedMax + padding)
    }

    private func surplusColor(for value: Double) -> Color {
        value >= 0 ? AssetTheme.positive : AssetTheme.negative
    }

    private func formattedSurplus(_ value: Double) -> String {
        let prefix = value > 0 ? "+" : ""
        return prefix + value.currencyString()
    }
}

private struct TimeMachineAnnualSurplusCard: View {
    let points: [TimeMachineAnnualSurplusPoint]
    @State private var selectedDate: Date?
    private let cardCornerRadius: CGFloat = 22
    private let chartCornerRadius: CGFloat = 18

    private var displayPoints: [TimeMachineAnnualSurplusPoint] {
        Array(points.suffix(12))
    }

    private var latestPoint: TimeMachineAnnualSurplusPoint? {
        points.last
    }

    private var selectedPoint: TimeMachineAnnualSurplusPoint? {
        guard let latestPoint else { return nil }
        guard let selectedDate else { return latestPoint }
        return nearestAnnualSurplusPoint(to: selectedDate, in: displayPoints) ?? latestPoint
    }

    private var averageSurplus: Double {
        guard !points.isEmpty else { return 0 }
        return points.reduce(0) { $0 + $1.surplus } / Double(points.count)
    }

    private var positiveYearCount: Int {
        points.filter { $0.surplus >= 0 }.count
    }

    private var bestYearPoint: TimeMachineAnnualSurplusPoint? {
        points.max { $0.surplus < $1.surplus }
    }

    private var domain: ClosedRange<Double> {
        paddedSurplusDomain(values: displayPoints.map(\.surplus))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(AppLocalization.string("按每年最后一条快照，和上一年年末净资产对比"))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 8)

                if let selectedPoint {
                    TimeMachineCompactLegendMetric(
                        title: selectedPoint.isCurrentYear ? AppLocalization.string("今年至今") : selectedPoint.yearStart.yearAxisDateString,
                        value: formattedSurplus(selectedPoint.surplus),
                        color: surplusColor(for: selectedPoint.surplus),
                        dashed: false
                    )
                }
            }

            if !displayPoints.isEmpty {
                chartSection
            }

            summaryRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("年结余"))
                    .font(.system(size: 15.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)

                Text(AppLocalization.string("按每年最后一条快照，和上一年年末净资产对比"))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 8)

            if let latestPoint {
                TimeMachineCompactLegendMetric(
                    title: latestPoint.isCurrentYear ? AppLocalization.string("今年至今") : AppLocalization.string("最近一年"),
                    value: formattedSurplus(latestPoint.surplus),
                    color: surplusColor(for: latestPoint.surplus),
                    dashed: false
                )
            }
        }
    }

    private var chartSection: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = 46
            let chartWidth = max(geometry.size.width - leftWidth - 18, 120)

            HStack(spacing: 6) {
                TimeMachineAxisStrip(
                    topLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: domain.upperBound),
                    middleLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: (domain.lowerBound + domain.upperBound) / 2),
                    bottomLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: domain.lowerBound),
                    alignment: .leading,
                    color: AssetTheme.gold
                )
                .frame(width: leftWidth)

                Chart {
                    RuleMark(y: .value(AppLocalization.string("零线"), normalized(0, in: domain)))
                        .foregroundStyle(AssetTheme.border.opacity(0.42))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    ForEach(displayPoints) { point in
                        BarMark(
                            x: .value(AppLocalization.string("年份"), point.yearStart),
                            yStart: .value(AppLocalization.string("零线"), normalized(0, in: domain)),
                            yEnd: .value(AppLocalization.string("年结余"), normalized(point.surplus, in: domain))
                        )
                        .foregroundStyle(surplusColor(for: point.surplus).opacity(selectedPoint?.id == point.id ? 0.96 : 0.82))
                    }

                    if selectedDate != nil, let selectedPoint {
                        RuleMark(x: .value(AppLocalization.string("选中年份"), selectedPoint.yearStart))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(width: chartWidth, height: 138)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: displayPoints.map(\.yearStart)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                            .foregroundStyle(AssetTheme.border.opacity(0.24))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                            .foregroundStyle(AssetTheme.border.opacity(0.44))
                        AxisValueLabel(anchor: .top, verticalSpacing: 8) {
                            if let date = value.as(Date.self) {
                                Text(date.yearAxisDateString)
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(AssetTheme.textSecondary)
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    TimeMachineDragOverlay(proxy: proxy) { date in
                        selectedDate = date
                    } onEnded: {
                        selectedDate = nil
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background(chartBackground)
        }
        .frame(height: 156)
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            TimeMachineLegendMetric(
                title: AppLocalization.string("年均结余"),
                value: formattedSurplus(averageSurplus),
                color: surplusColor(for: averageSurplus),
                dashed: false
            )

            TimeMachineLegendMetric(
                title: AppLocalization.string("正结余年份"),
                value: "\(positiveYearCount)/\(points.count)",
                color: AssetTheme.positive,
                dashed: false
            )

            TimeMachineLegendMetric(
                title: AppLocalization.string("最好年份"),
                value: bestYearPoint.map { formattedSurplus($0.surplus) } ?? "--",
                color: AssetTheme.goldSoft,
                dashed: true
            )
        }
    }

    private var chartBackground: some View {
        RoundedRectangle(cornerRadius: chartCornerRadius, style: .continuous)
            .fill(AssetTheme.surface.opacity(0.46))
    }

    private func normalized(_ value: Double, in domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span.isFinite, span > 0 else { return 0.5 }
        return (value - domain.lowerBound) / span
    }

    private func paddedSurplusDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter { $0.isFinite }
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return -1...1
        }

        let adjustedMin = min(minValue, 0)
        let adjustedMax = max(maxValue, 0)
        if abs(adjustedMax - adjustedMin) < .ulpOfOne {
            let padding = max(abs(adjustedMax) * 0.08, 1)
            return (adjustedMin - padding)...(adjustedMax + padding)
        }
        let padding = max((adjustedMax - adjustedMin) * 0.14, max(abs(adjustedMax), abs(adjustedMin)) * 0.03, 1)
        return (adjustedMin - padding)...(adjustedMax + padding)
    }

    private func surplusColor(for value: Double) -> Color {
        value >= 0 ? AssetTheme.positive : AssetTheme.negative
    }

    private func formattedSurplus(_ value: Double) -> String {
        let prefix = value > 0 ? "+" : ""
        return prefix + value.currencyString()
    }
}

private struct TimeMachineCurrentAnchorCard: View {
    let items: [TimeMachineCurrentAnchorItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.string("最新快照锚点"))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            ForEach(items) { item in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(item.accent)
                        .frame(width: 12, height: 3)

                    Text(AppLocalization.string(item.title))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AssetTheme.textSecondary)

                    Text(item.value)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(item.accent)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .atmCardStyle()
        .onboardingAnchor(.timeMachineAnchors)
    }
}

private struct TimeMachineDualAxisTrendCard: View {
    let descriptor: TimeMachineCombinedTrendDescriptor
    var onTapHistory: ((TimeMachineHistoryDrilldown) -> Void)?
    @State private var selectedDate: Date?
    private let cardCornerRadius: CGFloat = 22
    private let chartCornerRadius: CGFloat = 18

    private var displayPoints: [TimeMachineDualAxisPoint] {
        evenlySampledItems(descriptor.points, maxCount: 120)
    }

    private var displayLeftOnlyPoints: [TimeMachineSingleAxisPoint] {
        evenlySampledItems(descriptor.leftOnlyPoints, maxCount: 120)
    }

    private var rangeFilteredCandlesticks: [TimeMachineCandlestickPoint] {
        guard let candlesticks = descriptor.historyDrilldown?.candlesticks,
              !candlesticks.isEmpty,
              let firstDate = descriptor.leftOnlyPoints.first?.date,
              let lastDate = descriptor.leftOnlyPoints.last?.date else { return [] }
        return candlesticks.filter { $0.date >= firstDate && $0.date <= lastDate }
    }

    private var displayCandlesticks: [TimeMachineCandlestickPoint] {
        evenlySampledItems(rangeFilteredCandlesticks, maxCount: 96)
    }

    private var latestPoint: TimeMachineDualAxisPoint? {
        displayPoints.last ?? descriptor.points.last
    }

    private var selectedDualPoint: TimeMachineDualAxisPoint? {
        guard let selectedDate else { return latestPoint }
        return nearestDualAxisPoint(to: selectedDate, in: displayPoints) ?? latestPoint
    }

    private var latestLeftOnlyPoint: TimeMachineSingleAxisPoint? {
        displayLeftOnlyPoints.last ?? descriptor.leftOnlyPoints.last
    }

    private var selectedLeftOnlyPoint: TimeMachineSingleAxisPoint? {
        guard let selectedDate else { return latestLeftOnlyPoint }
        return nearestSingleAxisPoint(to: selectedDate, in: displayLeftOnlyPoints) ?? latestLeftOnlyPoint
    }

    private var latestCandlestick: TimeMachineCandlestickPoint? {
        displayCandlesticks.last ?? rangeFilteredCandlesticks.last
    }

    private var selectedCandlestick: TimeMachineCandlestickPoint? {
        guard let selectedDate else { return latestCandlestick }
        return nearestCandlestickPoint(to: selectedDate, in: displayCandlesticks) ?? latestCandlestick
    }

    private var canShowCandlestickChart: Bool {
        displayCandlesticks.count >= 2
    }

    private var leftDomain: ClosedRange<Double> {
        if canShowCandlestickChart {
            return paddedDomain(values: displayCandlesticks.flatMap { [$0.low, $0.high] })
        }
        let values = displayPoints.map(\.leftValue) + displayLeftOnlyPoints.map(\.value)
        return paddedDomain(values: values)
    }

    private var rightDomain: ClosedRange<Double> {
        paddedDomain(values: displayPoints.map(\.rightValue))
    }

    private var canShowDualAxisChart: Bool {
        descriptor.showsComparisonLine && displayPoints.count >= 2
    }

    private var canShowLeftOnlyChart: Bool {
        displayLeftOnlyPoints.count >= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if canShowDualAxisChart {
                dualAxisChart
            } else if canShowLeftOnlyChart {
                leftOnlyChart
            } else {
                Text(AppLocalization.string("记录不足"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
                    .background(chartBackground)
            }

            Text(selectedDate == nil ? dateRangeLabel : selectedAxisDateLabel)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(AssetTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.38), lineWidth: 1)
        )
        .shadow(color: AssetTheme.cardShadow.opacity(0.38), radius: 12, x: 0, y: 7)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 7) {
                Text(AppLocalization.string(descriptor.title))
                    .font(.system(size: 15.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                historyButton

                Spacer(minLength: 2)

                TimeMachineCompactLegendMetric(
                    title: descriptor.leftTitle,
                    value: selectedLeftLabel,
                    color: descriptor.leftColor,
                    dashed: false
                )

                if descriptor.showsComparisonLine {
                    TimeMachineCompactLegendMetric(
                        title: descriptor.rightTitle,
                        value: selectedRightLabel,
                        color: descriptor.rightColor,
                        dashed: true
                    )
                }
            }

            if let subtitle = descriptor.subtitle {
                Text(AppLocalization.string(subtitle))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
    }

    private var historyButton: some View {
        let historyDrilldown = descriptor.historyDrilldown
        let isEnabled = historyDrilldown != nil

        return Button {
            guard let historyDrilldown else { return }
            onTapHistory?(historyDrilldown)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(isEnabled ? AssetTheme.goldSoft : AssetTheme.textSecondary.opacity(0.5))
                Text(AppLocalization.string("历史"))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isEnabled ? AssetTheme.textPrimary : AssetTheme.textSecondary.opacity(0.68))
            }
            .frame(width: 58, height: 26)
            .background(
                LinearGradient(
                    colors: isEnabled
                        ? [AssetTheme.overlayMedium.opacity(0.92), AssetTheme.overlaySubtle.opacity(0.82)]
                        : [AssetTheme.overlaySoft.opacity(0.72), AssetTheme.overlayFaint.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isEnabled ? AssetTheme.border.opacity(0.66) : AssetTheme.border.opacity(0.32), lineWidth: 1)
            )
            .shadow(color: isEnabled ? AssetTheme.gold.opacity(0.08) : .clear, radius: 8, x: 0, y: 3)
            .opacity(isEnabled ? 1 : 0.78)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var dualAxisChart: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = descriptor.showsComparisonLine ? 42 : 36
            let rightWidth: CGFloat = descriptor.showsComparisonLine ? 46 : 0
            let chartWidth = max(geometry.size.width - leftWidth - rightWidth - 30, 120)

            HStack(spacing: 6) {
                TimeMachineAxisStrip(
                    topLabel: descriptor.leftAxisStyle.compactLabel(for: leftDomain.upperBound),
                    middleLabel: descriptor.leftAxisStyle.compactLabel(for: (leftDomain.lowerBound + leftDomain.upperBound) / 2),
                    bottomLabel: descriptor.leftAxisStyle.compactLabel(for: leftDomain.lowerBound),
                    alignment: .leading,
                    color: descriptor.leftColor
                )
                .frame(width: leftWidth)

                Chart {
                    leftSeriesMarks
                    if descriptor.showsComparisonLine {
                        rightSeriesMarksNormalized
                    }
                    latestPointMarksNormalized
                    if selectedDate != nil, let selectedDualPoint {
                        RuleMark(x: .value(AppLocalization.string("选中日期"), selectedDualPoint.date))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(width: chartWidth, height: 150)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis { bottomAxisMarks }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    TimeMachineDragOverlay(proxy: proxy) { date in
                        selectedDate = date
                    } onEnded: {
                        selectedDate = nil
                    }
                }

                if descriptor.showsComparisonLine {
                    TimeMachineAxisStrip(
                        topLabel: descriptor.rightAxisStyle.compactLabel(for: rightDomain.upperBound),
                        middleLabel: descriptor.rightAxisStyle.compactLabel(for: (rightDomain.lowerBound + rightDomain.upperBound) / 2),
                        bottomLabel: descriptor.rightAxisStyle.compactLabel(for: rightDomain.lowerBound),
                        alignment: .trailing,
                        color: descriptor.rightColor
                    )
                    .frame(width: rightWidth)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background(chartBackground)
        }
        .frame(height: 168)
    }

    private var leftOnlyChart: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = 36
            let chartWidth = max(geometry.size.width - leftWidth - 24, 120)

            HStack(spacing: 6) {
                TimeMachineAxisStrip(
                    topLabel: descriptor.leftAxisStyle.compactLabel(for: leftDomain.upperBound),
                    middleLabel: descriptor.leftAxisStyle.compactLabel(for: (leftDomain.lowerBound + leftDomain.upperBound) / 2),
                    bottomLabel: descriptor.leftAxisStyle.compactLabel(for: leftDomain.lowerBound),
                    alignment: .leading,
                    color: descriptor.leftColor
                )
                .frame(width: leftWidth)

                Chart {
                    leftOnlySeriesMarks
                    leftOnlyLatestPointMarks
                    if selectedDate != nil, let selectedLeftOnlyPoint {
                        RuleMark(x: .value(AppLocalization.string("选中日期"), selectedLeftOnlyPoint.date))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(width: chartWidth, height: 150)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis { bottomAxisMarks }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    TimeMachineDragOverlay(proxy: proxy) { date in
                        selectedDate = date
                    } onEnded: {
                        selectedDate = nil
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background(chartBackground)
        }
        .frame(height: 168)
    }

    @ChartContentBuilder
    private var leftSeriesMarks: some ChartContent {
        if canShowCandlestickChart {
            candlestickSeriesMarks
        } else {
            ForEach(displayLeftOnlyPoints) { point in
                LineMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    y: .value(descriptor.leftTitle, normalized(point.value, in: leftDomain)),
                    series: .value(AppLocalization.string("系列"), descriptor.leftTitle)
                )
                .foregroundStyle(descriptor.leftColor)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }
        }
    }

    @ChartContentBuilder
    private var candlestickSeriesMarks: some ChartContent {
        ForEach(displayCandlesticks) { bar in
            RuleMark(
                x: .value(AppLocalization.string("日期"), bar.date),
                yStart: .value(AppLocalization.string("最低"), normalized(bar.low, in: leftDomain)),
                yEnd: .value(AppLocalization.string("最高"), normalized(bar.high, in: leftDomain))
            )
            .foregroundStyle(candlestickColor(for: bar).opacity(0.82))
            .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round))

            RectangleMark(
                x: .value(AppLocalization.string("日期"), bar.date),
                yStart: .value(AppLocalization.string("实体低"), normalized(bar.bodyLow, in: leftDomain)),
                yEnd: .value(AppLocalization.string("实体高"), normalized(bar.bodyHigh, in: leftDomain)),
                width: .fixed(compactCandlestickBodyWidth)
            )
            .foregroundStyle(candlestickColor(for: bar).opacity(0.92))
        }
    }

    @ChartContentBuilder
    private var rightSeriesMarksNormalized: some ChartContent {
        ForEach(displayPoints) { point in
            LineMark(
                x: .value(AppLocalization.string("日期"), point.date),
                y: .value(descriptor.rightTitle, normalized(point.rightValue, in: rightDomain)),
                series: .value(AppLocalization.string("系列"), descriptor.rightTitle)
            )
            .foregroundStyle(descriptor.rightColor)
            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [6, 5]))
            .interpolationMethod(.linear)
        }
    }

    @ChartContentBuilder
    private var leftOnlySeriesMarks: some ChartContent {
        if canShowCandlestickChart {
            candlestickSeriesMarks
        } else {
            ForEach(displayLeftOnlyPoints) { point in
                LineMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    y: .value(descriptor.leftTitle, normalized(point.value, in: leftDomain)),
                    series: .value(AppLocalization.string("系列"), descriptor.leftTitle)
                )
                .foregroundStyle(descriptor.leftColor)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }
        }
    }

    @ChartContentBuilder
    private var latestPointMarksNormalized: some ChartContent {
        if canShowCandlestickChart, let selectedCandlestick {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedCandlestick.date),
                y: .value(descriptor.leftTitle, normalized(selectedCandlestick.close, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(34)
        } else if let selectedDualPoint {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedDualPoint.date),
                y: .value(descriptor.leftTitle, normalized(selectedDualPoint.leftValue, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(46)
        }

        if descriptor.showsComparisonLine, let selectedDualPoint {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedDualPoint.date),
                y: .value(descriptor.rightTitle, normalized(selectedDualPoint.rightValue, in: rightDomain))
            )
            .foregroundStyle(descriptor.rightColor)
            .symbolSize(40)
        }
    }

    @ChartContentBuilder
    private var leftOnlyLatestPointMarks: some ChartContent {
        if canShowCandlestickChart, let selectedCandlestick {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedCandlestick.date),
                y: .value(descriptor.leftTitle, normalized(selectedCandlestick.close, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(34)
        } else if let selectedLeftOnlyPoint {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedLeftOnlyPoint.date),
                y: .value(descriptor.leftTitle, normalized(selectedLeftOnlyPoint.value, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(46)
        }
    }

    private var bottomAxisMarks: some AxisContent {
        let axisDates = detailCardAxisDates(displayCandlesticks.map(\.date) + displayLeftOnlyPoints.map(\.date) + displayPoints.map(\.date))
        return AxisMarks(values: axisDates) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                .foregroundStyle(AssetTheme.border.opacity(0.28))
            AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                .foregroundStyle(AssetTheme.border.opacity(0.5))
        }
    }

    private var chartBackground: some View {
        RoundedRectangle(cornerRadius: chartCornerRadius, style: .continuous)
            .fill(AssetTheme.surface.opacity(0.46))
    }

    private var selectedAxisDateLabel: String {
        if canShowCandlestickChart, let selectedCandlestick {
            return selectedCandlestick.date.chartAxisDateString
        }
        if let selectedDualPoint {
            return selectedDualPoint.date.chartAxisDateString
        }
        if let selectedLeftOnlyPoint {
            return selectedLeftOnlyPoint.date.chartAxisDateString
        }
        return dateRangeLabel
    }

    private var dateRangeLabel: String {
        let dates = (displayCandlesticks.map(\.date) + descriptor.leftOnlyPoints.map(\.date) + descriptor.points.map(\.date)).sorted()
        guard let first = dates.first, let last = dates.last else { return AppLocalization.string("暂无范围") }
        return "\(first.chartAxisDateString) - \(last.chartAxisDateString)"
    }

    private func detailCardAxisDates(_ dates: [Date]) -> [Date] {
        let sortedDates = Array(Set(dates)).sorted()
        guard sortedDates.count > 2 else { return sortedDates }
        return [sortedDates[sortedDates.count / 2]]
    }

    private func normalized(_ value: Double, in domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span.isFinite, span > 0 else { return 0.5 }
        return (value - domain.lowerBound) / span
    }

    private var compactCandlestickBodyWidth: CGFloat {
        switch displayCandlesticks.count {
        case 0...48:
            return 5
        case 49...96:
            return 3.4
        default:
            return 2.4
        }
    }

    private func candlestickColor(for point: TimeMachineCandlestickPoint) -> Color {
        point.isRising ? AssetTheme.positive : AssetTheme.negative
    }

    private func paddedDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter { $0.isFinite }
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }

    private var selectedLeftLabel: String {
        if canShowCandlestickChart, let selectedCandlestick {
            return descriptor.leftAxisStyle.compactLabel(for: selectedCandlestick.close)
        }
        if let selectedDualPoint {
            return descriptor.leftAxisStyle.compactLabel(for: selectedDualPoint.leftValue)
        }
        if let selectedLeftOnlyPoint {
            return descriptor.leftAxisStyle.compactLabel(for: selectedLeftOnlyPoint.value)
        }
        return descriptor.leftLatestLabel
    }

    private var selectedRightLabel: String {
        if let selectedDualPoint {
            return descriptor.rightAxisStyle.compactLabel(for: selectedDualPoint.rightValue)
        }
        return descriptor.rightLatestLabel
    }

    private func axisTickValues(for domain: ClosedRange<Double>) -> [Double] {
        let step = (domain.upperBound - domain.lowerBound) / 2
        guard step.isFinite, step > 0 else { return [domain.lowerBound] }
        return [domain.lowerBound, domain.lowerBound + step, domain.upperBound]
    }
}

private struct TimeMachineHistoryDrilldownSheet: View {
    let descriptor: TimeMachineHistoryDrilldown
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRange: TimeMachineRange = .all
    @State private var selectedDate: Date?

    private var filteredPoints: [TimeMachineSingleAxisPoint] {
        selectedRange.filter(descriptor.points)
    }

    private var displayPoints: [TimeMachineSingleAxisPoint] {
        evenlySampledItems(filteredPoints, maxCount: 220)
    }

    private var filteredCandlesticks: [TimeMachineCandlestickPoint] {
        selectedRange.filter(descriptor.candlesticks)
    }

    private var displayCandlesticks: [TimeMachineCandlestickPoint] {
        evenlySampledItems(filteredCandlesticks, maxCount: 180)
    }

    private var canShowCandlestickChart: Bool {
        displayCandlesticks.count >= 2
    }

    private var latestCandlestick: TimeMachineCandlestickPoint? {
        filteredCandlesticks.last ?? descriptor.candlesticks.last
    }

    private var selectedCandlestick: TimeMachineCandlestickPoint? {
        guard let selectedDate else { return latestCandlestick }
        return nearestCandlestickPoint(to: selectedDate, in: displayCandlesticks) ?? latestCandlestick
    }

    private var latestPoint: TimeMachineSingleAxisPoint? {
        filteredPoints.last ?? descriptor.points.last
    }

    private var selectedPoint: TimeMachineSingleAxisPoint? {
        guard let latestPoint else { return nil }
        guard let selectedDate else { return latestPoint }
        return nearestSingleAxisPoint(to: selectedDate, in: displayPoints) ?? latestPoint
    }

    private var valueDomain: ClosedRange<Double> {
        if canShowCandlestickChart {
            return paddedDomain(values: displayCandlesticks.flatMap { [$0.low, $0.high] })
        }
        return paddedDomain(values: displayPoints.map(\.value))
    }

    private var selectedDisplayValue: Double? {
        if canShowCandlestickChart {
            return selectedCandlestick?.close
        }
        return selectedPoint?.value
    }

    private var selectedDisplayDate: Date? {
        if canShowCandlestickChart {
            return selectedCandlestick?.date
        }
        return selectedPoint?.date
    }

    private var chartModeLabel: String {
        canShowCandlestickChart ? AppLocalization.string("历史 K 线") : AppLocalization.string("历史走势")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(AppLocalization.string(descriptor.title))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(AssetTheme.textPrimary)

                                Text(chartModeLabel)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AssetTheme.goldSoft)

                                if let subtitle = descriptor.subtitle {
                                    Text(AppLocalization.string(subtitle))
                                        .font(.caption)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                            }

                            Spacer(minLength: 12)

                            if let selectedDisplayValue, let selectedDisplayDate {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(descriptor.axisStyle.compactLabel(for: selectedDisplayValue))
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(descriptor.color)
                                    Text(selectedDisplayDate.chartAxisDateString)
                                        .font(.caption)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                            }
                        }

                        TimeMachineRangeSelector(selectedRange: $selectedRange)

                        if displayPoints.count >= 2 {
                            historyChart
                        } else if let latestPoint {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(descriptor.axisStyle.compactLabel(for: latestPoint.value))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(descriptor.color)
                                Text(latestPoint.date.chartAxisDateString)
                                    .font(.caption)
                                    .foregroundStyle(AssetTheme.textSecondary)
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AssetTheme.overlayFaint, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
                            )
                        } else {
                            Text(AppLocalization.string("暂无历史数据"))
                                .font(.subheadline)
                                .foregroundStyle(AssetTheme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
                        }

                        Text(selectedDate == nil ? dateRangeLabel : (selectedDisplayDate?.chartAxisDateString ?? dateRangeLabel))
                            .font(AppTypography.meta)
                            .foregroundStyle(AssetTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(AppLocalization.string("指数走势"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("关闭")) {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historyChart: some View {
        if canShowCandlestickChart {
            candlestickHistoryChart
        } else {
            lineHistoryChart
        }
    }

    private var candlestickHistoryChart: some View {
        Chart {
            ForEach(displayCandlesticks) { bar in
                RuleMark(
                    x: .value(AppLocalization.string("日期"), bar.date),
                    yStart: .value(AppLocalization.string("最低"), bar.low),
                    yEnd: .value(AppLocalization.string("最高"), bar.high)
                )
                .foregroundStyle(candlestickColor(for: bar).opacity(0.82))
                .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round))

                RectangleMark(
                    x: .value(AppLocalization.string("日期"), bar.date),
                    yStart: .value(AppLocalization.string("实体低"), bar.bodyLow),
                    yEnd: .value(AppLocalization.string("实体高"), bar.bodyHigh),
                    width: .fixed(candlestickBodyWidth)
                )
                .foregroundStyle(candlestickColor(for: bar).opacity(0.92))
            }

            if let selectedCandlestick {
                PointMark(
                    x: .value(AppLocalization.string("日期"), selectedCandlestick.date),
                    y: .value(descriptor.title, selectedCandlestick.close)
                )
                .foregroundStyle(descriptor.color)
                .symbolSize(34)
            }

            if selectedDate != nil, let selectedCandlestick {
                RuleMark(x: .value(AppLocalization.string("选中日期"), selectedCandlestick.date))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .frame(height: 280)
        .chartYScale(domain: valueDomain)
        .chartXAxis { historyXAxisMarks(dates: displayCandlesticks.map(\.date)) }
        .chartYAxis { historyYAxisMarks }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            TimeMachineDragOverlay(proxy: proxy) { date in
                selectedDate = date
            } onEnded: {
                selectedDate = nil
            }
        }
        .padding(18)
        .background(AssetTheme.overlayFaint, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
        )
    }

    private var lineHistoryChart: some View {
        Chart {
            ForEach(displayPoints) { point in
                LineMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    y: .value(descriptor.title, point.value)
                )
                .foregroundStyle(descriptor.color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }

            if let selectedPoint {
                PointMark(
                    x: .value(AppLocalization.string("日期"), selectedPoint.date),
                    y: .value(descriptor.title, selectedPoint.value)
                )
                .foregroundStyle(descriptor.color)
                .symbolSize(42)
            }

            if selectedDate != nil, let selectedPoint {
                RuleMark(x: .value(AppLocalization.string("选中日期"), selectedPoint.date))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .frame(height: 280)
        .chartYScale(domain: valueDomain)
        .chartXAxis { historyXAxisMarks(dates: displayPoints.map(\.date)) }
        .chartYAxis { historyYAxisMarks }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            TimeMachineDragOverlay(proxy: proxy) { date in
                selectedDate = date
            } onEnded: {
                selectedDate = nil
            }
        }
        .padding(18)
        .background(AssetTheme.overlayFaint, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
        )
    }

    private func historyXAxisMarks(dates: [Date]) -> some AxisContent {
        let axisDates = chartAxisDates(dates)
        return AxisMarks(values: axisDates) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(AssetTheme.chartGrid)
            AxisTick().foregroundStyle(AssetTheme.chartTick)
            AxisValueLabel(anchor: .top, verticalSpacing: 8) {
                if let date = value.as(Date.self) {
                    TimeMachineAxisDateLabel(date: date, position: axisLabelPosition(for: date, in: axisDates))
                }
            }
        }
    }

    private var historyYAxisMarks: some AxisContent {
        AxisMarks(values: axisTickValues(for: valueDomain)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(AssetTheme.chartGrid)
            AxisValueLabel {
                if let y = value.as(Double.self) {
                    Text(descriptor.axisStyle.compactLabel(for: y))
                        .font(.caption2)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
        }
    }

    private var candlestickBodyWidth: CGFloat {
        switch displayCandlesticks.count {
        case 0...45:
            return 7
        case 46...90:
            return 5
        default:
            return 3
        }
    }

    private func candlestickColor(for point: TimeMachineCandlestickPoint) -> Color {
        point.isRising ? AssetTheme.positive : AssetTheme.negative
    }

    private var dateRangeLabel: String {
        if canShowCandlestickChart {
            guard let first = filteredCandlesticks.first?.date ?? descriptor.candlesticks.first?.date,
                  let last = filteredCandlesticks.last?.date ?? descriptor.candlesticks.last?.date else {
                return AppLocalization.string("暂无范围")
            }
            return "\(first.chartAxisDateString) - \(last.chartAxisDateString)"
        }
        guard let first = filteredPoints.first?.date ?? descriptor.points.first?.date,
              let last = filteredPoints.last?.date ?? descriptor.points.last?.date else {
            return AppLocalization.string("暂无范围")
        }
        return "\(first.chartAxisDateString) - \(last.chartAxisDateString)"
    }

    private func axisLabelPosition(for date: Date, in axisDates: [Date]) -> TimeMachineAxisDateLabel.Position {
        guard let first = axisDates.first, let last = axisDates.last else { return .middle }
        if Calendar.current.isDate(date, inSameDayAs: first) {
            return .leading
        }
        if Calendar.current.isDate(date, inSameDayAs: last) {
            return .trailing
        }
        return .middle
    }

    private func axisTickValues(for domain: ClosedRange<Double>) -> [Double] {
        let step = (domain.upperBound - domain.lowerBound) / 2
        guard step.isFinite, step > 0 else { return [domain.lowerBound] }
        return [domain.lowerBound, domain.lowerBound + step, domain.upperBound]
    }

    private func paddedDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter { $0.isFinite }
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }
}

private func nearestDualAxisPoint(to date: Date, in points: [TimeMachineDualAxisPoint]) -> TimeMachineDualAxisPoint? {
    points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
}

private func nearestMonthlySurplusPoint(to date: Date, in points: [TimeMachineMonthlySurplusPoint]) -> TimeMachineMonthlySurplusPoint? {
    points.min { abs($0.monthStart.timeIntervalSince(date)) < abs($1.monthStart.timeIntervalSince(date)) }
}

private func nearestAnnualSurplusPoint(to date: Date, in points: [TimeMachineAnnualSurplusPoint]) -> TimeMachineAnnualSurplusPoint? {
    points.min { abs($0.yearStart.timeIntervalSince(date)) < abs($1.yearStart.timeIntervalSince(date)) }
}

private func nearestSingleAxisPoint(to date: Date, in points: [TimeMachineSingleAxisPoint]) -> TimeMachineSingleAxisPoint? {
    points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
}

private func nearestCandlestickPoint(to date: Date, in points: [TimeMachineCandlestickPoint]) -> TimeMachineCandlestickPoint? {
    points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
}

private struct TimeMachineDragOverlay: View {
    let proxy: ChartProxy
    let onChanged: (Date) -> Void
    let onEnded: () -> Void

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            let locationX = min(max(value.location.x - frame.origin.x, 0), frame.size.width)
                            if let date: Date = proxy.value(atX: locationX) {
                                onChanged(date)
                            }
                        }
                        .onEnded { _ in
                            onEnded()
                        }
                )
        }
    }
}

private struct TimeMachineCompactLegendMetric: View {
    let title: String
    let value: String
    let color: Color
    let dashed: Bool

    var body: some View {
        HStack(spacing: 4.5) {
            legendMark

            Text(AppLocalization.string(title))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                .lineLimit(1)

            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.66)
        }
        .padding(.vertical, 4)
        .frame(minWidth: 68, alignment: .leading)
    }

    @ViewBuilder
    private var legendMark: some View {
        if dashed {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(color)
                        .frame(width: 3.2, height: 2.4)
                }
            }
            .frame(width: 12, alignment: .leading)
        } else {
            Capsule()
                .fill(color)
                .frame(width: 12, height: 2.4)
        }
    }
}

private struct TimeMachineLegendMetric: View {
    let title: String
    let value: String
    let color: Color
    let dashed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                legendMark

                Text(AppLocalization.string(title))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var legendMark: some View {
        if dashed {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(color)
                        .frame(width: 4, height: 2.5)
                }
            }
            .frame(width: 14, alignment: .leading)
        } else {
            Capsule()
                .fill(color)
                .frame(width: 14, height: 2.5)
        }
    }
}

private struct TimeMachineAxisStrip: View {
    let topLabel: String
    let middleLabel: String
    let bottomLabel: String
    let alignment: HorizontalAlignment
    let color: Color

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(topLabel)
                .font(.system(size: 8.8, weight: .semibold, design: .rounded))
                .foregroundStyle(color.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 10)
            Text(middleLabel)
                .font(.system(size: 8.8, weight: .medium, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 10)
            Text(bottomLabel)
                .font(.system(size: 8.8, weight: .semibold, design: .rounded))
                .foregroundStyle(color.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

private struct APIDocumentationView: View {
    @ObservedObject var marketStore: RemoteMarketStore

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        ATMHeader(title: AppLocalization.string("接口文档"), subtitle: AppLocalization.string("供应用与分析模块使用。")) {
                            Button {
                                Task { await marketStore.refresh() }
                            } label: {
                                GoldChip(text: AppLocalization.string("刷新"))
                            }
                            .buttonStyle(.plain)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text("Base URL")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AssetTheme.textSecondary)

                            Text(RemoteMarketClient.baseURL.absoluteString)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(AssetTheme.textPrimary)
                                .textSelection(.enabled)
                        }
                        .atmCardStyle()

                        ForEach(RemoteMarketClient.endpointDocs) { endpoint in
                            EndpointCard(endpoint: endpoint, market: endpoint.symbol.flatMap { marketStore.market(for: $0) })
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct ATMBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.bold))
                Text(AppLocalization.string("返回"))
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AssetTheme.overlaySubtle, in: Capsule())
            .overlay(Capsule().stroke(AssetTheme.border.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct ATMHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AssetTheme.overlaySubtle)
                            .frame(width: 40, height: 40)
                        Image(systemName: "hourglass")
                            .foregroundStyle(AssetTheme.gold)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AssetTheme.border, lineWidth: 1)
                    )

                    Text(AppLocalization.string(title))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(AppLocalization.string(subtitle))
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
            trailing
        }
    }
}

private enum AppTypography {
    static let eyebrow = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let meta = Font.system(size: 14, weight: .medium, design: .rounded)
    static let sectionTitle = Font.system(size: 20, weight: .bold, design: .rounded)
    static let heroValue = Font.system(size: 40, weight: .bold, design: .rounded)
    static let rowTitle = Font.system(size: 18, weight: .semibold, design: .rounded)
    static let rowValue = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let metricValue = Font.system(size: 18, weight: .semibold, design: .rounded)
}

private struct SectionTitle: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string(title))
                .font(AppTypography.sectionTitle)
                .foregroundStyle(AssetTheme.textPrimary)

            if let subtitle, !subtitle.isEmpty {
                Text(AppLocalization.string(subtitle))
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
            }
        }
    }
}

private struct GoldChip: View {
    let text: String

    var body: some View {
        Text(AppLocalization.string(text))
            .font(AppTypography.eyebrow)
            .foregroundStyle(AssetTheme.goldSoft)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AssetTheme.gold.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(AssetTheme.border, lineWidth: 1))
    }
}

private struct InlineStat: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(AppTypography.meta)
                .foregroundStyle(color)
        }
    }
}

private struct CompactStat: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string(title))
                .font(AppTypography.eyebrow)
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(AppTypography.metricValue)
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textPrimary)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
            RoundedRectangle(cornerRadius: 999)
                .fill(accent)
                .frame(width: 28, height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.8), lineWidth: 1)
        )
    }
}

private struct HeroSideMetric: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)

                Text(AppLocalization.string(title))
                    .font(AppTypography.eyebrow)
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textPrimary)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
    }
}

private struct MarketPriceRow: View {
    let market: PublicMarketPrice

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)

            Text(displayName)
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.textPrimary)

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(market.price.formatted(.number.precision(.fractionLength(2))))
                    .font(AppTypography.rowValue)
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textPrimary)
                Text(market.currency)
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.goldSoft)
            }
        }
        .padding(.vertical, 16)
    }

    private var displayName: String {
        switch market.symbol {
        case "gold": return AppLocalization.string("黄金")
        case "nasdaq": return AppLocalization.string("纳指锚点")
        default: return market.symbol.uppercased()
        }
    }

    private var color: Color {
        switch market.symbol {
        case "gold": return AssetTheme.gold
        case "nasdaq": return AssetTheme.accentBlue
        default: return AssetTheme.textSecondary
        }
    }
}

private struct EndpointCard: View {
    let endpoint: MarketEndpointDoc
    let market: PublicMarketPrice?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalization.string(endpoint.title))
                        .font(.headline)
                        .foregroundStyle(AssetTheme.textPrimary)

                    Text(endpoint.path)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(AssetTheme.goldSoft)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)
                GoldChip(text: "GET")
            }

            Text(AppLocalization.string(endpoint.description))
                .font(.subheadline)
                .foregroundStyle(AssetTheme.textSecondary)

            if let market {
                HStack(spacing: 12) {
                    Label(market.price.formatted(.number.precision(.fractionLength(2))), systemImage: "waveform.path.ecg")
                    Text(market.currency)
                    Spacer()
                    Text(market.fetchedAt.formatted(date: .omitted, time: .shortened))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AssetTheme.goldSoft)
                .padding(12)
                .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .atmCardStyle()
    }
}

private struct CapabilityRow: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(AppLocalization.string(title))
                .foregroundStyle(AssetTheme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary)
        }
        .padding(14)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
        )
    }
}

private struct EmptyStateCard: View {
    let title: String
    let message: String?
    let systemImage: String

    init(title: String, message: String? = nil, systemImage: String) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AssetTheme.gold)

            VStack(spacing: 8) {
                Text(AppLocalization.string(title))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                if let message, !message.isEmpty {
                    Text(AppLocalization.string(message))
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .atmCardStyle()
    }
}

private struct LoadingStateCard: View {
    let title: String
    let message: String?

    init(title: String, message: String? = nil) {
        self.title = title
        self.message = message
    }

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(AssetTheme.gold)

            VStack(spacing: 8) {
                Text(AppLocalization.string(title))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                if let message, !message.isEmpty {
                    Text(AppLocalization.string(message))
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
        .padding(.vertical, 26)
    }
}

private struct SkeletonLine: View {
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 999, style: .continuous)
            .fill(AssetTheme.overlayStrong)
            .frame(width: width, height: 14)
    }
}

private func evenlySampledItems<T>(_ items: [T], maxCount: Int) -> [T] {
    guard maxCount > 2, items.count > maxCount else { return items }

    let lastIndex = items.count - 1
    let step = Double(lastIndex) / Double(maxCount - 1)
    var sampled: [T] = []
    sampled.reserveCapacity(maxCount)

    var previousIndex = -1
    for position in 0..<maxCount {
        let index = min(lastIndex, Int((Double(position) * step).rounded()))
        guard index != previousIndex else { continue }
        sampled.append(items[index])
        previousIndex = index
    }

    if previousIndex != lastIndex {
        sampled.append(items[lastIndex])
    }

    return sampled
}

private enum AppFormatterCache {
    private static let keyPrefix = "AssetTimeMachine.Formatter."

    static func currencyFormatter(code: String) -> NumberFormatter {
        numberFormatter(key: "currency.\(code)") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
            formatter.locale = Locale(identifier: "zh_CN")
            return formatter
        }
    }

    static func plainNumberFormatter() -> NumberFormatter {
        numberFormatter(key: "decimal.plain") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 4
            formatter.minimumFractionDigits = 0
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }
    }

    static func compactNumberFormatter(maxFractionDigits: Int) -> NumberFormatter {
        numberFormatter(key: "decimal.compact.\(maxFractionDigits)") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = maxFractionDigits
            formatter.minimumFractionDigits = 0
            formatter.usesGroupingSeparator = false
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }
    }

    static func percentFormatter(maxFractionDigits: Int) -> NumberFormatter {
        numberFormatter(key: "percent.\(maxFractionDigits)") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .percent
            formatter.maximumFractionDigits = maxFractionDigits
            formatter.minimumFractionDigits = 0
            formatter.locale = Locale(identifier: "zh_CN")
            return formatter
        }
    }

    static func dateFormatter(format: String, localeIdentifier: String = "zh_CN") -> DateFormatter {
        dateFormatter(key: "date.\(localeIdentifier).\(format)") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: localeIdentifier)
            formatter.dateFormat = format
            return formatter
        }
    }

    private static func numberFormatter(key: String, make: () -> NumberFormatter) -> NumberFormatter {
        let cacheKey = keyPrefix + key
        if let formatter = Thread.current.threadDictionary[cacheKey] as? NumberFormatter {
            return formatter
        }
        let formatter = make()
        Thread.current.threadDictionary[cacheKey] = formatter
        return formatter
    }

    private static func dateFormatter(key: String, make: () -> DateFormatter) -> DateFormatter {
        let cacheKey = keyPrefix + key
        if let formatter = Thread.current.threadDictionary[cacheKey] as? DateFormatter {
            return formatter
        }
        let formatter = make()
        Thread.current.threadDictionary[cacheKey] = formatter
        return formatter
    }
}

private extension Double {
    func currencyString(code: String = "CNY") -> String {
        let formatter = AppFormatterCache.currencyFormatter(code: code)
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.2f", self)
    }

    func plainNumberString() -> String {
        let formatter = AppFormatterCache.plainNumberFormatter()
        return formatter.string(from: NSNumber(value: self)) ?? String(self)
    }

    func compactNumberString(maxFractionDigits: Int = 1) -> String {
        let formatter = AppFormatterCache.compactNumberFormatter(maxFractionDigits: maxFractionDigits)

        let absValue = abs(self)
        let sign = self < 0 ? "-" : ""

        switch absValue {
        case 1_000_000_000...:
            let value = absValue / 1_000_000_000
            return "\(sign)\((formatter.string(from: NSNumber(value: value)) ?? String(value)))B"
        case 1_000_000...:
            let value = absValue / 1_000_000
            return "\(sign)\((formatter.string(from: NSNumber(value: value)) ?? String(value)))M"
        case 1_000...:
            let value = absValue / 1_000
            return "\(sign)\((formatter.string(from: NSNumber(value: value)) ?? String(value)))K"
        default:
            return formatter.string(from: NSNumber(value: self)) ?? String(self)
        }
    }

    func percentString(maxFractionDigits: Int = 2) -> String {
        let formatter = AppFormatterCache.percentFormatter(maxFractionDigits: maxFractionDigits)
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.2f%%", self * 100)
    }
}

private extension AssetCategory {
    var activeSortedItems: [AssetItem] {
        items
            .filter(\.isActive)
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.sortOrder < rhs.sortOrder
            }
    }
}

private extension AssetItem {
    var latestEntry: AssetEntry? {
        entries.max { lhs, rhs in
            (lhs.snapshot?.date ?? .distantPast) < (rhs.snapshot?.date ?? .distantPast)
        }
    }

    var inferredAutoPricedAssetKind: AutoPricedAssetKind? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        if trimmedName == AppLocalization.string("黄金") || trimmedName.caseInsensitiveCompare("gold") == .orderedSame {
            return .gold
        }

        let uppercasedName = trimmedName.uppercased()
        let legacyMappings: [(AutoPricedAssetKind, [String])] = [
            (.btc, ["BTC", "BITCOIN"]),
            (.eth, ["ETH", "ETHEREUM"]),
            (.bnb, ["BNB"]),
            (.sol, ["SOL", "SOLANA"]),
            (.xrp, ["XRP"]),
            (.doge, ["DOGE", "DOGECOIN"]),
        ]

        for (kind, candidates) in legacyMappings {
            if candidates.contains(uppercasedName) {
                return kind
            }
        }

        for currencyCode in ["USD", "EUR", "GBP", "JPY", "HKD", "SGD", "AUD", "CAD", "KRW"] {
            if uppercasedName.hasSuffix(" \(currencyCode)") || uppercasedName == currencyCode {
                return AutoPricedAssetKind(rawValue: currencyCode.lowercased())
            }
        }

        return nil
    }

    var resolvedAutoPricedAssetKind: AutoPricedAssetKind? {
        autoPricedAssetKind ?? inferredAutoPricedAssetKind
    }

    var autoPricedMarketSymbol: String? {
        guard valuationMethod == .quantityAndUnitPrice else { return nil }
        return resolvedAutoPricedAssetKind?.marketSymbol
    }

    var autoExchangeRateCurrencyCode: String? {
        guard let kind = resolvedAutoPricedAssetKind, kind.isCurrency else {
            return nil
        }
        return kind.rawValue.uppercased()
    }

    var prefersCompactRecordInput: Bool {
        true
    }

    var compactRecordPlaceholder: String {
        if valuationMethod == .quantityAndUnitPrice {
            if let currencyCode = autoExchangeRateCurrencyCode {
                return AppLocalization.format("输入%@ 数量", currencyCode)
            }

            if let autoKind = resolvedAutoPricedAssetKind {
                return AppLocalization.format("输入%@ 数量", AppLocalization.string(autoKind.defaultName))
            }

            return AppLocalization.string("输入数量")
        }

        return AppLocalization.string("输入金额")
    }

    @MainActor
    func resolvedAutoUnitPrice(using marketStore: RemoteMarketStore) -> Double? {
        if let currencyCode = autoExchangeRateCurrencyCode,
           let rate = marketStore.exchangeRate(for: currencyCode),
           rate > 0 {
            return 1 / rate
        }

        if let symbol = autoPricedMarketSymbol {
            return marketStore.market(for: symbol)?.price
        }

        return nil
    }

    @MainActor
    func autoPriceDisplayText(using marketStore: RemoteMarketStore) -> String? {
        if let currencyCode = autoExchangeRateCurrencyCode,
           let rate = marketStore.exchangeRate(for: currencyCode),
           rate > 0 {
            return AppLocalization.format("现价 %@", (1 / rate).currencyString())
        }

        guard let symbol = autoPricedMarketSymbol,
              let market = marketStore.market(for: symbol) else {
            return nil
        }

        let currencyCode = market.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let priceText: String
        if currencyCode.count == 3 {
            priceText = market.price.currencyString(code: currencyCode)
        } else if currencyCode.isEmpty {
            priceText = market.price.plainNumberString()
        } else {
            priceText = "\(market.price.plainNumberString()) \(currencyCode)"
        }

        let unit = market.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let unitSuffix = unit.isEmpty ? "" : "/\(unit)"
        return AppLocalization.format("现价 %@%@", priceText, unitSuffix)
    }

    @MainActor
    func autoPriceFetchedAt(using marketStore: RemoteMarketStore) -> Date? {
        if autoExchangeRateCurrencyCode != nil {
            return marketStore.exchangeRatesFetchedAt
        }

        if let symbol = autoPricedMarketSymbol {
            return marketStore.market(for: symbol)?.fetchedAt
        }

        return nil
    }

}

private extension AssetGroup {
    var sortPriority: Int {
        switch self {
        case .financial: return 0
        case .physical: return 1
        case .liability: return 2
        }
    }
}

private extension AssetCategory {
    func liabilitySortPriority(titleMap: [String: String]) -> Int {
        let normalized = name.replacingOccurrences(of: " ", with: "")
        if normalized.contains(AppLocalization.string("长期")) { return 0 }
        if normalized.contains(AppLocalization.string("短期")) { return 1 }
        if titleMap[normalized] != nil { return 0 }
        return 2
    }
}

private extension Date {
    var shortDateString: String {
        AppFormatterCache.dateFormatter(format: AppLocalization.string("M月d日")).string(from: self)
    }

    var longDateString: String {
        AppFormatterCache.dateFormatter(format: AppLocalization.string("yyyy年M月d日")).string(from: self)
    }

    var chineseLongDateString: String {
        AppFormatterCache.dateFormatter(format: AppLocalization.string("yyyy年M月d日")).string(from: self)
    }

    var recordDateString: String {
        AppFormatterCache.dateFormatter(format: "yyyy.M.d").string(from: self)
    }

    var chartAxisDateString: String {
        AppFormatterCache.dateFormatter(format: "yyyy.MM.dd").string(from: self)
    }

    var chartAxisShortDateString: String {
        AppFormatterCache.dateFormatter(format: "yy.MM.dd").string(from: self)
    }

    var dashboardAxisDateString: String {
        AppFormatterCache.dateFormatter(format: "yy.MM").string(from: self)
    }

    var yearAxisDateString: String {
        AppFormatterCache.dateFormatter(format: "yyyy").string(from: self)
    }

    var recordTimeString: String {
        AppFormatterCache.dateFormatter(format: "HH:mm").string(from: self)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self], inMemory: true)
}
