import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers
import UIKit
import UserNotifications

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
    @State private var backgroundTabPrewarmTask: Task<Void, Never>?
    @State private var pendingActiveTabActivationTask: Task<Void, Never>?
    #if DEBUG
    @State private var debugTabSwitchTask: Task<Void, Never>?
    #endif

    private static let foregroundMarketRefreshInterval: TimeInterval = 3600
    private static let activeTabWorkActivationDelayNanoseconds: UInt64 = 260_000_000
    private static let backgroundPrewarmTabs: [AppTab] = []

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
                        Label(AppLocalization.string("回测"), systemImage: "chart.xyaxis.line")
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
            if newValue != .dashboard {
                backgroundTabPrewarmTask?.cancel()
                backgroundTabPrewarmTask = nil
            } else {
                scheduleBackgroundTabPrewarmIfNeeded()
            }
        }
        .onChange(of: showsOnboarding) { _, isShowing in
            if isShowing {
                backgroundTabPrewarmTask?.cancel()
                backgroundTabPrewarmTask = nil
            } else {
                scheduleBackgroundTabPrewarmIfNeeded()
            }
        }
        .task {
            await runStartupIfNeeded()
            #if DEBUG
            scheduleDebugTabSwitchLoopIfNeeded()
            #endif
            await cloudStore.refreshIfNeeded(from: modelContext)
            await refreshAssetNotifications()
            scheduleBackgroundTabPrewarmIfNeeded()
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
            Task { await refreshAssetNotifications() }
        }
    }

    @ViewBuilder
    private func deferredTabContent<Content: View>(for tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        if loadedTabs.contains(tab) {
            content()
        } else if selectedTab == tab {
            DeferredTabActivationPlaceholder(tab: tab)
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

        await marketStore.refresh()
        lastMarketRefreshAt = .now
        await SnapshotAnchorService.backfillIfNeeded(in: modelContext)
        await syncTodaySnapshotWithLatestMarketData()
    }

    @MainActor
    private func scheduleBackgroundTabPrewarmIfNeeded() {
        guard hasCompletedOnboarding,
              !showsOnboarding,
              selectedTab == .dashboard,
              backgroundTabPrewarmTask == nil else { return }
        let tabsToPrewarm = Self.backgroundPrewarmTabs.filter { !loadedTabs.contains($0) }
        guard !tabsToPrewarm.isEmpty else { return }
        #if DEBUG
        guard !ProcessInfo.processInfo.arguments.contains("-profileTabSwitchLoop") else { return }
        #endif

        backgroundTabPrewarmTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }

            for tab in tabsToPrewarm {
                let shouldContinue = await MainActor.run { () -> Bool in
                    guard selectedTab == .dashboard else { return false }
                    loadedTabs.insert(tab)
                    return true
                }
                guard shouldContinue, !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 280_000_000)
            }

            await MainActor.run {
                backgroundTabPrewarmTask = nil
            }
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
        await marketStore.refresh()
        lastMarketRefreshAt = .now
        await syncTodaySnapshotWithLatestMarketData()
        await refreshAssetNotifications()
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

private struct DeferredTabActivationPlaceholder: View {
    let tab: AppTab

    private var title: String {
        switch tab {
        case .dashboard:
            return AppLocalization.string("首页加载中")
        case .snapshots:
            return AppLocalization.string("记录加载中")
        case .timeMachine:
            return AppLocalization.string("时光机加载中")
        case .backtest:
            return AppLocalization.string("回测加载中")
        case .settings:
            return AppLocalization.string("设置加载中")
        }
    }

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            LoadingStateCard(
                title: title,
                message: AppLocalization.string("马上就好…")
            )
            .padding(.horizontal, 16)
        }
    }
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
    @ObservedObject var cloudStore: AssetTimeMachineCloudStore
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
        hasher.combine(items.map(\.updatedAt).max()?.timeIntervalSinceReferenceDate ?? 0)
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
        let latestItemUpdate = items.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
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
                        await cloudStore.refreshIfNeeded(from: modelContext)
                        await focusFreedomSectionIfNeeded(using: proxy)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: autoSyncTrigger) { _, _ in
                guard isActive else { return }
                Task {
                    await cloudStore.autoSyncIfNeeded(from: modelContext, quietly: true)
                }
            }
        }
        .task(id: isActive) {
            if isActive {
                scheduleDashboardRefresh(delayNanoseconds: 0, force: true)
            } else {
                pendingDashboardRefreshTask?.cancel()
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
        return DashboardSnapshotSummary(
            totalAssets: PortfolioCalculator.totalAssets(for: latestSnapshot),
            totalLiabilities: PortfolioCalculator.totalLiabilities(for: latestSnapshot)
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
            let mainAssets = PortfolioCalculator.totalAssets(for: snapshot)
            let liabilities = PortfolioCalculator.totalLiabilities(for: snapshot)
            let netAssets = mainAssets - liabilities

            return TimeMachineTrendPoint(
                date: snapshot.date,
                mainAssets: mainAssets,
                netAssets: netAssets,
                liabilities: liabilities,
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
                        if notificationEnabled {
                            Text(notificationPreview)
                                .foregroundStyle(AssetTheme.textSecondary)
                                .monospacedDigit()
                        } else if notificationStatus == .denied {
                            Text(AppLocalization.string("通知权限已关闭，请前往系统设置开启。"))
                                .foregroundStyle(AssetTheme.textSecondary)
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
                await reloadNotificationStatus()
            }
            .onChange(of: notificationEnabled) { _, _ in
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
        displayedTotalAmount(for: nonLiabilityCategories, entriesByItemID: currentSnapshotEntriesByItemID)
    }

    private var displayedTotalLiabilities: Double {
        displayedTotalAmount(for: liabilityCategories, entriesByItemID: currentSnapshotEntriesByItemID)
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
        let snapshotEntriesByItemIDValue = snapshotEntriesByItemID(for: currentSnapshotValue)
        let displayedTotalAssetsValue = displayedTotalAmount(for: nonLiabilityCategoriesValue, entriesByItemID: snapshotEntriesByItemIDValue)
        let displayedTotalLiabilitiesValue = displayedTotalAmount(for: liabilityCategoriesValue, entriesByItemID: snapshotEntriesByItemIDValue)
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
                                    snapshotEntriesByItemID: snapshotEntriesByItemIDValue,
                                    onboardingInputItemID: category.id == onboardingInputTargetCategoryID ? category.activeSortedItems.first?.id : nil,
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
                scheduleAutoRateSync(delayNanoseconds: 120_000_000)
            }
        }
        .task(id: isActive) {
            if isActive {
                scheduleAutoRateSync(delayNanoseconds: 80_000_000)
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
            scheduleAutoRateSync(delayNanoseconds: 80_000_000)
        }
        .onReceive(marketStore.$overview) { _ in
            guard isActive else { return }
            scheduleAutoRateSync(delayNanoseconds: 80_000_000)
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
            } catch {
                print("[AssetTimeMachine] sync auto rate failed: \(error)")
            }
        }

        await SnapshotAnchorService.captureLiveAnchorsIfPossible(for: snapshot, marketStore: marketStore, in: modelContext)
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

    private func displayedTotalAmount(for categories: [AssetCategory], entriesByItemID: [UUID: AssetEntry]) -> Double {
        categories
            .flatMap(\.activeSortedItems)
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
                return "compact:" + items.map(\.id.uuidString).joined(separator: ",")
            case let .expanded(item):
                return "expanded:" + item.id.uuidString
            }
        }
    }

    let category: AssetCategory
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

    private var items: [AssetItem] {
        category.activeSortedItems
    }

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
    let snapshotEntriesByItemID: [UUID: AssetEntry]
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    @Binding var focusedField: RecordInputField?
    let onEdit: (AssetItem) -> Void
    let onEditValue: (AssetItem) -> Void
    @State private var draggedItemID: UUID?

    private let columns = [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)]

    private var items: [AssetItem] {
        category.activeSortedItems
    }

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

        await marketStore.refresh()

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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.date.longDateString)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)

                Text(AppLocalization.format("%d 项 · 负债 %@", snapshot.entries.count, PortfolioCalculator.totalLiabilities(for: snapshot).currencyString()))
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(PortfolioCalculator.netAssets(for: snapshot).currencyString())
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
        return TimeMachineHistoryDrilldown(
            symbol: symbol,
            title: title,
            subtitle: subtitle,
            points: points,
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
                        TimeMachinePageHeader()

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

private struct BacktestSeriesPoint: Identifiable {
    let date: Date
    let portfolioValue: Double

    var id: Date { date }
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            return AppLocalization.string("基础回测")
        case .advanced:
            return AppLocalization.string("高级回测")
        }
    }
}

private enum BacktestTopTab: String, CaseIterable, Identifiable {
    case allocation
    case dca
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allocation:
            return AppLocalization.string("配置")
        case .dca:
            return AppLocalization.string("定投")
        case .advanced:
            return AppLocalization.string("高级")
        }
    }
}

private enum AdvancedBacktestSignalDirection: String, CaseIterable, Identifiable {
    case consecutiveDown
    case consecutiveUp
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
        case .consecutiveDown:
            return AppLocalization.string("连续下跌")
        case .consecutiveUp:
            return AppLocalization.string("连续上涨")
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
        case .consecutiveDown:
            return AppLocalization.string("跌")
        case .consecutiveUp:
            return AppLocalization.string("涨")
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

    var usesDayThreshold: Bool {
        switch self {
        case .consecutiveDown, .consecutiveUp:
            return true
        case .priceCrossesAboveMA20,
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
            return AssetTheme.positive
        case .sell:
            return AssetTheme.accentOrange
        }
    }
}

private struct AdvancedBacktestRule {
    var direction: AdvancedBacktestSignalDirection
    var days: Int
}

private struct AdvancedBacktestTrade: Identifiable {
    let id = UUID()
    let date: Date
    let action: AdvancedBacktestTradeAction
    let price: Double
    let cashAmount: Double
    let units: Double
}

private struct AdvancedBacktestReport {
    let points: [BacktestSeriesPoint]
    let trades: [AdvancedBacktestTrade]
    let finalPortfolioValue: Double
    let finalCash: Double
    let finalUnits: Double
    let totalReturn: Double
    let annualizedReturn: Double?
    let maxDrawdown: Double
    let annualizedVolatility: Double?
    let sharpeRatio: Double?

    var buyCount: Int {
        trades.filter { $0.action == .buy }.count
    }

    var sellCount: Int {
        trades.filter { $0.action == .sell }.count
    }
}

private struct AdvancedBacktestRiskSettings {
    var feeRate: Double
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

private enum BacktestEngine {
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

        let goldMap = goldSeries.map { Dictionary(uniqueKeysWithValues: zip($0.dates, $0.prices)) } ?? [:]
        let indexMaps: [String: [String: Double]] = Dictionary(uniqueKeysWithValues: indexRatios.keys.compactMap { symbol in
            guard let series = indexSeriesBySymbol[symbol] else { return nil }
            return (symbol, Dictionary(uniqueKeysWithValues: zip(series.dates, series.prices)))
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
            points.append(.init(date: date, portfolioValue: portfolioValue))

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

        let assetPricePoints = zip(assetSeries.dates, assetSeries.prices).compactMap { dateText, price -> HistoricalPricePoint? in
            guard let date = historicalSeriesDateStatic(from: dateText), price.isFinite, price > 0 else { return nil }
            return HistoricalPricePoint(date: date, price: price)
        }
        .sorted { $0.date < $1.date }

        let pricePoints: [(date: Date, cnyPrice: Double)] = assetPricePoints.compactMap { point in
            guard let cnyPrice = cnyPrice(for: point, assetOption: assetOption, fxLookup: fxLookup) else { return nil }
            return (date: point.date, cnyPrice: cnyPrice)
        }

        guard let firstPoint = pricePoints.first, let lastPoint = pricePoints.last else { return nil }

        let calendar = Calendar(identifier: .gregorian)
        var scheduledDate = firstPoint.date
        var nextContributionIndex = pricePoints.firstIndex(where: { $0.date >= scheduledDate })
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
                    if index + 1 < pricePoints.count {
                        nextContributionIndex = pricePoints[(index + 1)...].firstIndex(where: { $0.date >= scheduledDate })
                    } else {
                        nextContributionIndex = nil
                    }
                } else {
                    nextContributionIndex = nil
                }
            }

            guard unitsHeld > 0 else { continue }
            points.append(.init(date: point.date, portfolioValue: unitsHeld * point.cnyPrice))
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
        guard let assetSeries else { return nil }

        let normalizedInitialCash = max(initialCash, 0)
        let normalizedTradeAmount = max(tradeAmount, 0)
        let normalizedFeeRate = max(settings.feeRate, 0) / 100
        let normalizedMaxPositionRatio = min(max(settings.maxPositionRatio, 0), 100) / 100
        let normalizedCooldownDays = max(settings.cooldownDays, 0)
        let normalizedStopLossRatio = max(settings.stopLossRatio, 0) / 100
        let normalizedTakeProfitRatio = max(settings.takeProfitRatio, 0) / 100
        guard normalizedInitialCash > 0, normalizedTradeAmount > 0, normalizedMaxPositionRatio > 0 else { return nil }

        let fxLookup: HistoricalLookup?
        if assetOption.requiresHistoricalFX {
            guard let lookup = makeHistoricalLookup(from: fxSeries), !lookup.points.isEmpty else { return nil }
            fxLookup = lookup
        } else {
            fxLookup = nil
        }

        let assetPricePoints = zip(assetSeries.dates, assetSeries.prices).compactMap { dateText, price -> HistoricalPricePoint? in
            guard let date = historicalSeriesDateStatic(from: dateText), price.isFinite, price > 0 else { return nil }
            return HistoricalPricePoint(date: date, price: price)
        }
        .sorted { $0.date < $1.date }

        let pricePoints: [(date: Date, cnyPrice: Double)] = assetPricePoints.compactMap { point in
            guard let cnyPrice = cnyPrice(for: point, assetOption: assetOption, fxLookup: fxLookup) else { return nil }
            return (date: point.date, cnyPrice: cnyPrice)
        }

        guard pricePoints.count >= 2 else { return nil }

        let buyThreshold = max(buyRule.days, 1)
        let sellThreshold = max(sellRule.days, 1)
        let prices = pricePoints.map { $0.cnyPrice }
        let ma20 = movingAverage(values: prices, period: 20)
        let ma60 = movingAverage(values: prices, period: 60)
        let boll20 = bollingerBands(values: prices, period: 20, multiplier: 2)

        var cash = normalizedInitialCash
        var unitsHeld = 0.0
        var averageEntryPrice: Double?
        var lastTradeDate: Date?
        var previousPrice: Double?
        var upStreak = 0
        var downStreak = 0
        var points: [BacktestSeriesPoint] = []
        var trades: [AdvancedBacktestTrade] = []
        var peakValue = normalizedInitialCash
        var maxDrawdown = 0.0

        for (index, point) in pricePoints.enumerated() {
            if let previousPrice {
                if point.cnyPrice > previousPrice {
                    upStreak += 1
                    downStreak = 0
                } else if point.cnyPrice < previousPrice {
                    downStreak += 1
                    upStreak = 0
                } else {
                    upStreak = 0
                    downStreak = 0
                }

                let shouldBuy = advancedRuleTriggered(
                    buyRule,
                    at: index,
                    pricePoints: pricePoints,
                    ma20: ma20,
                    ma60: ma60,
                    boll20: boll20,
                    upStreak: upStreak,
                    downStreak: downStreak,
                    threshold: buyThreshold
                )
                let shouldSell = advancedRuleTriggered(
                    sellRule,
                    at: index,
                    pricePoints: pricePoints,
                    ma20: ma20,
                    ma60: ma60,
                    boll20: boll20,
                    upStreak: upStreak,
                    downStreak: downStreak,
                    threshold: sellThreshold
                )

                let daysSinceLastTrade = lastTradeDate.map { Calendar.current.dateComponents([.day], from: $0, to: point.date).day ?? 0 } ?? Int.max
                let cooldownAllowsTrade = daysSinceLastTrade >= normalizedCooldownDays
                let positionMarketValue = unitsHeld * point.cnyPrice
                let portfolioBeforeTrade = cash + positionMarketValue
                let stopLossTriggered = normalizedStopLossRatio > 0
                    && unitsHeld > 0
                    && averageEntryPrice.map { point.cnyPrice <= $0 * (1 - normalizedStopLossRatio) } == true
                let takeProfitTriggered = normalizedTakeProfitRatio > 0
                    && unitsHeld > 0
                    && averageEntryPrice.map { point.cnyPrice >= $0 * (1 + normalizedTakeProfitRatio) } == true

                if (shouldSell || stopLossTriggered || takeProfitTriggered), unitsHeld > 0, cooldownAllowsTrade {
                    let grossProceeds = unitsHeld * point.cnyPrice
                    let fee = grossProceeds * normalizedFeeRate
                    let proceeds = max(grossProceeds - fee, 0)
                    trades.append(
                        AdvancedBacktestTrade(
                            date: point.date,
                            action: .sell,
                            price: point.cnyPrice,
                            cashAmount: proceeds,
                            units: unitsHeld
                        )
                    )
                    cash += proceeds
                    unitsHeld = 0
                    averageEntryPrice = nil
                    lastTradeDate = point.date
                } else if shouldBuy, cash > 0, cooldownAllowsTrade {
                    let maxPositionValue = portfolioBeforeTrade * normalizedMaxPositionRatio
                    let remainingPositionCapacity = max(maxPositionValue - positionMarketValue, 0)
                    let amountToSpend = min(cash, normalizedTradeAmount, remainingPositionCapacity)
                    if amountToSpend > 0 {
                        let fee = amountToSpend * normalizedFeeRate
                        let amountToInvest = max(amountToSpend - fee, 0)
                        let boughtUnits = amountToInvest / point.cnyPrice
                        if boughtUnits > 0 {
                            let previousCost = (averageEntryPrice ?? 0) * unitsHeld
                            let newCost = previousCost + amountToInvest
                            trades.append(
                                AdvancedBacktestTrade(
                                    date: point.date,
                                    action: .buy,
                                    price: point.cnyPrice,
                                    cashAmount: amountToSpend,
                                    units: boughtUnits
                                )
                            )
                            cash -= amountToSpend
                            unitsHeld += boughtUnits
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
            points.append(.init(date: point.date, portfolioValue: portfolioValue))
            previousPrice = point.cnyPrice
        }

        guard let last = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

        return AdvancedBacktestReport(
            points: points,
            trades: trades,
            finalPortfolioValue: last.portfolioValue,
            finalCash: cash,
            finalUnits: unitsHeld,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio
        )
    }

    private static func scoreAdvancedReport(_ report: AdvancedBacktestReport) -> Double {
        let annualized = report.annualizedReturn ?? report.totalReturn
        let sharpe = report.sharpeRatio ?? 0
        let tradePenalty = report.trades.count < 2 ? 0.35 : 0
        return annualized * 1.35 + sharpe * 0.18 - report.maxDrawdown * 1.2 - tradePenalty
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

        let buyDirections: [AdvancedBacktestSignalDirection] = [
            .consecutiveDown,
            .priceCrossesAboveMA20,
            .priceCrossesAboveBollMiddle,
            .touchesBollLower,
            .ma20CrossesAboveMA60
        ]
        let sellDirections: [AdvancedBacktestSignalDirection] = [
            .consecutiveUp,
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

        var candidates: [AdvancedBacktestCandidate] = []
        for buyDirection in buyDirections {
            for sellDirection in sellDirections {
                for buyDays in dayThresholds {
                    for sellDays in dayThresholds {
                        for tradeAmount in tradeAmounts {
                            for maxPositionRatio in maxPositionRatios {
                                var settings = baseSettings
                                settings.maxPositionRatio = maxPositionRatio
                                let buyRule = AdvancedBacktestRule(direction: buyDirection, days: buyDirection.usesDayThreshold ? buyDays : 1)
                                let sellRule = AdvancedBacktestRule(direction: sellDirection, days: sellDirection.usesDayThreshold ? sellDays : 1)
                                guard let report = runAdvancedStrategy(
                                    assetSeries: assetSeries,
                                    assetOption: assetOption,
                                    fxSeries: fxSeries,
                                    initialCash: normalizedInitialCash,
                                    tradeAmount: tradeAmount,
                                    buyRule: buyRule,
                                    sellRule: sellRule,
                                    settings: settings
                                ), report.points.count > 20 else { continue }
                                candidates.append(
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

        return Array(candidates.sorted { $0.score > $1.score }.prefix(max(limit, 1)))
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
        case .consecutiveDown:
            return downStreak == threshold
        case .consecutiveUp:
            return upStreak == threshold
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
        historicalSeriesDateFormatter.date(from: text)
    }

    private static let historicalSeriesDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func makeHistoricalLookup(from series: PublicHistorySeries?) -> HistoricalLookup? {
        guard let series else { return nil }
        let points = zip(series.dates, series.prices).compactMap { dateText, price -> HistoricalPricePoint? in
            guard let date = historicalSeriesDateStatic(from: dateText), price.isFinite, price > 0 else { return nil }
            return HistoricalPricePoint(date: date, price: price)
        }
        .sorted { $0.date < $1.date }
        return HistoricalLookup(points: points)
    }

    private static func cnyPrice(
        for point: HistoricalPricePoint,
        assetOption: BacktestAssetOption,
        fxLookup: HistoricalLookup?
    ) -> Double? {
        guard assetOption.requiresHistoricalFX else { return point.price }
        guard let usdPerCNY = fxLookup?.price(onOrBefore: point.date), usdPerCNY.isFinite, usdPerCNY > 0 else { return nil }
        return point.price / usdPerCNY
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

private struct InteractiveBacktestChart: View {
    let points: [BacktestSeriesPoint]
    var valueStyle: BacktestChartValueStyle = .multiple
    @State private var selectedDate: Date?

    private var selectedPoint: BacktestSeriesPoint? {
        guard let selectedDate else { return points.last }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private var valueDomain: ClosedRange<Double> {
        let values = points.map(\.portfolioValue).filter { $0.isFinite }
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }

    var body: some View {
        let domain = valueDomain

        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    yStart: .value(AppLocalization.string("组合净值下沿"), domain.lowerBound),
                    yEnd: .value(AppLocalization.string("组合净值"), point.portfolioValue)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [AssetTheme.gold.opacity(0.32), AssetTheme.gold.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    y: .value(AppLocalization.string("组合净值"), point.portfolioValue)
                )
                .foregroundStyle(AssetTheme.gold)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }

            if let selectedPoint {
                PointMark(
                    x: .value(AppLocalization.string("日期"), selectedPoint.date),
                    y: .value(AppLocalization.string("组合净值"), selectedPoint.portfolioValue)
                )
                .foregroundStyle(AssetTheme.gold)
                .symbolSize(44)
            }

            if selectedDate != nil, let selectedPoint {
                RuleMark(x: .value(AppLocalization.string("选中日期"), selectedPoint.date))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .frame(height: 220)
        .clipped()
        .chartYScale(domain: domain)
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
    }
}

private struct BacktestAllocationSlice: Identifiable {
    let title: String
    let amount: Double
    let color: Color

    var id: String { title }
}

private struct BacktestView: View {
    @ObservedObject var marketStore: RemoteMarketStore
    let isActive: Bool
    @State private var selectedPage: BacktestPage = .standard
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

    private enum DCAConfigSheet: String, Identifiable {
        case asset
        case amount
        case interval

        var id: String { rawValue }
    }

    @State private var activeDCAConfigSheet: DCAConfigSheet?

    private let indexOptions = BacktestDefaults.indexOptions
    private let dcaAssetOptions = BacktestDefaults.dcaAssetOptions

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

    private var activeReportPoints: [BacktestSeriesPoint] {
        switch backtestMode {
        case .allocation:
            return allocationReport?.points ?? []
        case .dca:
            return dcaReport?.points ?? []
        }
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
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        BacktestTopTabPicker(selectedTab: topTabBinding)

                        if selectedTopTab != .advanced {
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
                                            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true)
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
                                            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true)
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
                        } else {
                            AdvancedBacktestView(marketStore: marketStore)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, selectedTopTab == .advanced || hasActiveReport ? 136 : 24)
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
        }
        .task(id: isActive) {
            if isActive {
                scheduleBacktestDataRefresh(delayNanoseconds: 0)
                if hasStartedBacktest, !hasActiveReport {
                    scheduleBacktestRefresh(animated: !hasPlayedInitialBacktestAnimation)
                }
            } else {
                pendingBacktestDataRefreshTask?.cancel()
            }
        }
        .onChange(of: selectedPage) { _, newValue in
            guard isActive, newValue == .standard else { return }
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true)
        }
        .onChange(of: backtestMode) { _, _ in
            guard isActive, selectedPage == .standard else { return }
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true)
        }
        .onChange(of: selectedDateFilterToken) { _, _ in
            guard isActive else { return }
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true)
        }
        .onReceive(marketStore.$historySeries) { _ in
            guard isActive else { return }
            scheduleBacktestDataRefresh(delayNanoseconds: 40_000_000, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: !hasActiveReport && !hasPlayedInitialBacktestAnimation)
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

    private func applyAllocation(cashWeight: Double, goldWeight: Double, indexWeights: [String: Double]) {
        self.cashWeight = cashWeight
        self.goldWeight = goldWeight
        self.indexWeights = indexWeights

        if isActive {
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
        }
        guard hasStartedBacktest else { return }
        scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true)
    }

    private func applyDCAConfiguration(assetSymbol: String, contributionAmount: Double, intervalDays: Int) {
        dcaAssetSymbol = assetSymbol
        dcaContributionAmount = contributionAmount
        dcaIntervalDays = intervalDays

        if isActive {
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
        }
        guard hasStartedBacktest else { return }
        scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true)
    }

    private func scheduleBacktestRefresh(
        animated: Bool,
        forceAnimation: Bool = false,
        showLoading: Bool = false
    ) {
        backtestRefreshToken += 1
        let currentToken = backtestRefreshToken

        if showLoading {
            isBacktestLoading = true
        }

        let performRefresh = {
            guard currentToken == backtestRefreshToken else { return }
            refreshBacktestDataCacheIfNeeded()
            recomputeReport(animated: animated, forceAnimation: forceAnimation)
            isBacktestLoading = false
        }

        if showLoading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: performRefresh)
        } else {
            performRefresh()
        }
    }

    @MainActor
    private func recomputeReport(animated: Bool, forceAnimation: Bool = false) {
        switch backtestMode {
        case .allocation:
            allocationReport = BacktestEngine.run(
                cashWeight: cashWeight,
                goldWeight: goldWeight,
                goldSeries: filteredGoldSeries,
                indexWeights: indexWeights,
                indexSeriesBySymbol: filteredIndexSeriesBySymbol
            )
            dcaReport = nil
        case .dca:
            dcaReport = BacktestEngine.runDCA(
                assetSeries: filteredDCASeries,
                assetOption: selectedDCAAssetOption ?? BacktestDefaults.dcaAssetOptions[0],
                fxSeries: filteredDCAFXSeries,
                contributionAmount: dcaContributionAmount,
                intervalDays: dcaIntervalDays
            )
            allocationReport = nil
        }
        displayPoints = sampledChartPoints(from: activeReportPoints)

        let shouldAnimate = animated && !displayPoints.isEmpty && (forceAnimation || !hasPlayedInitialBacktestAnimation)
        guard shouldAnimate else {
            animationProgress = 1
            return
        }

        hasPlayedInitialBacktestAnimation = true
        restartAnimation()
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
        guard let series else { return nil }
        guard let effectiveBounds = bounds ?? effectiveBacktestBounds else { return series }

        let filteredPairs = zip(series.dates, series.prices).filter { dateText, _ in
            guard let date = BacktestEngine.historicalSeriesDateStatic(from: dateText) else { return false }
            return date >= effectiveBounds.lowerBound && date <= effectiveBounds.upperBound
        }
        let filteredDates = filteredPairs.map { $0.0 }
        let filteredPrices = filteredPairs.map { $0.1 }
        guard filteredDates.count >= 2 else { return nil }

        return PublicHistorySeries(
            symbol: series.symbol,
            category: series.category,
            label: series.label,
            currency: series.currency,
            unit: series.unit,
            source: series.source,
            dates: filteredDates,
            prices: filteredPrices
        )
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

        return sampled
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
                Text(selectedDateRangeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(activeAllocationSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AssetTheme.goldSoft)
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
                Text(selectedDateRangeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(AppLocalization.string(selectedDCAAssetOption?.title ?? "单资产"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selectedDCAAssetOption?.color ?? AssetTheme.goldSoft)
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
                            Text(AppLocalization.string("当前配置"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AssetTheme.textSecondary)
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

private struct AdvancedBacktestView: View {
    @ObservedObject var marketStore: RemoteMarketStore
    @State private var selectedAssetSymbol: String = BacktestDefaults.dcaAssetSymbol
    @State private var initialCash: Double = 100_000
    @State private var tradeAmount: Double = 10_000
    @State private var feeRate: Double = 0.1
    @State private var maxPositionRatio: Double = 70
    @State private var cooldownDays: Double = 3
    @State private var stopLossRatio: Double = 0
    @State private var takeProfitRatio: Double = 0
    @State private var buyDirection: AdvancedBacktestSignalDirection = .consecutiveDown
    @State private var buyDays: Int = 3
    @State private var sellDirection: AdvancedBacktestSignalDirection = .consecutiveUp
    @State private var sellDays: Int = 3
    @State private var selectedStartDate: Date?
    @State private var selectedEndDate: Date?
    @State private var showsRangeSheet = false
    @State private var hasStartedBacktest = false
    @State private var report: AdvancedBacktestReport?
    @State private var bestCandidates: [AdvancedBacktestCandidate] = []
    @State private var pendingRefreshTask: Task<Void, Never>?

    private var assetOptions: [BacktestAssetOption] {
        BacktestDefaults.dcaAssetOptions
    }

    private var selectedAssetOption: BacktestAssetOption? {
        assetOptions.first(where: { $0.symbol == selectedAssetSymbol })
    }

    private var selectedAssetSeries: PublicHistorySeries? {
        guard let selectedAssetOption else { return nil }
        return marketStore.history(for: selectedAssetOption.symbol)
    }

    private var selectedFXSeries: PublicHistorySeries? {
        guard let fxSymbol = selectedAssetOption?.historicalFXSymbol else { return nil }
        return marketStore.history(for: fxSymbol)
    }

    private var availableDateBounds: ClosedRange<Date>? {
        let seriesList = [selectedAssetSeries, selectedFXSeries].compactMap { $0 }
        return BacktestEngine.availableDateBounds(for: seriesList)
    }

    private var displayDateBounds: ClosedRange<Date>? {
        if let effectiveDateBounds {
            return effectiveDateBounds
        }

        if let start = selectedStartDate, let end = selectedEndDate {
            return min(start, end)...max(start, end)
        }

        if let assetSeries = selectedAssetSeries,
           let assetBounds = BacktestEngine.availableDateBounds(for: [assetSeries]) {
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
            maxPositionRatio: maxPositionRatio,
            cooldownDays: Int(cooldownDays.rounded()),
            stopLossRatio: stopLossRatio,
            takeProfitRatio: takeProfitRatio
        )
    }

    private var refreshToken: String {
        [
            selectedAssetSymbol,
            String(initialCash),
            String(tradeAmount),
            String(feeRate),
            String(maxPositionRatio),
            String(cooldownDays),
            String(stopLossRatio),
            String(takeProfitRatio),
            buyDirection.rawValue,
            String(buyDays),
            sellDirection.rawValue,
            String(sellDays),
            selectedStartDate?.recordDateString ?? "nil",
            selectedEndDate?.recordDateString ?? "nil"
        ].joined(separator: ":")
    }

    private var unavailableResultState: (message: String, isLoading: Bool) {
        if selectedAssetSeries == nil {
            if marketStore.isLoading {
                return (AppLocalization.string("正在加载历史数据…"), true)
            }
            return (AppLocalization.string("历史数据暂时不可用，请稍后再试"), false)
        }

        if selectedAssetOption?.requiresHistoricalFX == true, selectedFXSeries == nil {
            if marketStore.isLoading {
                return (AppLocalization.string("正在加载汇率数据…"), true)
            }
            return (AppLocalization.string("汇率数据暂时不可用，请稍后再试"), false)
        }

        if filteredHistorySeries(selectedAssetSeries, within: effectiveDateBounds) == nil {
            return (AppLocalization.string("当前回测区间内历史数据不足"), false)
        }

        if selectedAssetOption?.requiresHistoricalFX == true,
           filteredHistorySeries(selectedFXSeries, within: effectiveDateBounds) == nil {
            return (AppLocalization.string("当前回测区间内汇率数据不足"), false)
        }

        return (AppLocalization.string("当前数据暂时无法完成回测"), false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            configSection

            if hasStartedBacktest {
                if let report {
                    resultSection(report)
                    bestStrategySection()
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
        .onChange(of: refreshToken) { _, _ in
            guard hasStartedBacktest else { return }
            scheduleRefresh(delayNanoseconds: 120_000_000)
        }
        .onReceive(marketStore.$historySeries) { _ in
            guard hasStartedBacktest else { return }
            scheduleRefresh(delayNanoseconds: 80_000_000)
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(AppLocalization.string("策略设置"))

            advancedPanel {
                advancedMenuRow(
                    title: AppLocalization.string("回测资产"),
                    value: AppLocalization.string(selectedAssetOption?.title ?? "黄金"),
                    accent: selectedAssetOption?.color ?? AssetTheme.gold,
                    showsDivider: true
                ) {
                    Picker(AppLocalization.string("回测资产"), selection: $selectedAssetSymbol) {
                        ForEach(assetOptions) { option in
                            Text(option.title).tag(option.symbol)
                        }
                    }
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

                advancedNumericInputRow(
                    title: AppLocalization.string("单次买入金额"),
                    value: $tradeAmount,
                    placeholder: AppLocalization.string("例如 10000"),
                    showsDivider: true
                )

                advancedNumericInputRow(
                    title: AppLocalization.string("交易费率"),
                    value: $feeRate,
                    placeholder: AppLocalization.string("例如 0.1"),
                    unit: "%",
                    showsDivider: true
                )

                advancedNumericInputRow(
                    title: AppLocalization.string("最大仓位"),
                    value: $maxPositionRatio,
                    placeholder: AppLocalization.string("例如 70"),
                    unit: "%",
                    showsDivider: true
                )

                advancedNumericInputRow(
                    title: AppLocalization.string("冷却天数"),
                    value: $cooldownDays,
                    placeholder: AppLocalization.string("例如 3"),
                    unit: AppLocalization.string("天"),
                    showsDivider: true
                )

                advancedNumericInputRow(
                    title: AppLocalization.string("止损线"),
                    value: $stopLossRatio,
                    placeholder: AppLocalization.string("0为关闭"),
                    unit: "%",
                    showsDivider: true
                )

                advancedNumericInputRow(
                    title: AppLocalization.string("止盈线"),
                    value: $takeProfitRatio,
                    placeholder: AppLocalization.string("0为关闭"),
                    unit: "%",
                    showsDivider: true
                )

                advancedRuleRow(
                    title: AppLocalization.string("买入条件"),
                    direction: $buyDirection,
                    days: $buyDays,
                    accent: AssetTheme.positive,
                    showsDivider: false
                )

                advancedRuleSwapRow()

                advancedRuleRow(
                    title: AppLocalization.string("卖出条件"),
                    direction: $sellDirection,
                    days: $sellDays,
                    accent: AssetTheme.accentOrange,
                    showsDivider: false
                )
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

    private func resultSection(_ report: AdvancedBacktestReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                AppLocalization.string("回测结果"),
                trailing: AppLocalization.string(selectedAssetOption?.title ?? "单资产"),
                trailingColor: selectedAssetOption?.color ?? AssetTheme.goldSoft
            )

            advancedPanel {
                InteractiveBacktestChart(points: report.points, valueStyle: .currency(code: "CNY"))

                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    BacktestMetricCard(title: AppLocalization.string("期末资产"), value: report.finalPortfolioValue.currencyString())
                    BacktestMetricCard(title: AppLocalization.string("总收益"), value: report.totalReturn.percentString(), accent: report.totalReturn >= 0 ? AssetTheme.positive : AssetTheme.negative)
                    BacktestMetricCard(title: AppLocalization.string("年化收益"), value: report.annualizedReturn?.percentString() ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("最大回撤"), value: report.maxDrawdown.percentString(), accent: AssetTheme.negative)
                    BacktestMetricCard(title: AppLocalization.string("年化波动"), value: report.annualizedVolatility?.percentString() ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("夏普比率"), value: report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("买入次数"), value: AppLocalization.format("%d次", report.buyCount))
                    BacktestMetricCard(title: AppLocalization.string("卖出次数"), value: AppLocalization.format("%d次", report.sellCount))
                    BacktestMetricCard(title: AppLocalization.string("剩余现金"), value: report.finalCash.currencyString())
                    BacktestMetricCard(title: AppLocalization.string("持有份额"), value: report.finalUnits.plainNumberString())
                }
            }
        }
    }

    private func bestStrategySection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                AppLocalization.string("智能优选策略"),
                trailing: AppLocalization.string("按收益/回撤/夏普综合排序"),
                trailingColor: AssetTheme.gold
            )

            advancedPanel {
                if bestCandidates.isEmpty {
                    Text(AppLocalization.string("暂无可用候选策略，请调整资产或区间后重试"))
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
                                    Text(candidate.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AssetTheme.textPrimary)
                                    Spacer()
                                    Text(candidate.report.totalReturn.percentString())
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(candidate.report.totalReturn >= 0 ? AssetTheme.positive : AssetTheme.negative)
                                }

                                Text(AppLocalization.format(
                                    "单次%@ · 仓位%.0f%% · 年化%@ · 回撤%@ · 夏普%@",
                                    candidate.tradeAmount.currencyString(),
                                    candidate.settings.maxPositionRatio,
                                    candidate.report.annualizedReturn?.percentString() ?? "--",
                                    candidate.report.maxDrawdown.percentString(),
                                    candidate.report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--"
                                ))
                                .font(.caption)
                                .foregroundStyle(AssetTheme.textSecondary)
                                .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        if index < bestCandidates.count - 1 {
                            Divider()
                                .overlay(AssetTheme.border.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    private func tradeSection(_ report: AdvancedBacktestReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(AppLocalization.string("最近交易"))

            advancedPanel {
                if report.trades.isEmpty {
                    Text(AppLocalization.string("暂无成交"))
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(report.trades.suffix(6).reversed()).indices, id: \.self) { index in
                        let trade = Array(report.trades.suffix(6).reversed())[index]
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(trade.action.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(trade.action.accent)
                                Text("\(trade.date.shortDateString) · \(trade.price.currencyString())")
                                    .font(.footnote)
                                    .foregroundStyle(AssetTheme.textSecondary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text((trade.action == .buy ? "-" : "+") + trade.cashAmount.currencyString())
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AssetTheme.textPrimary)
                                Text(AppLocalization.format("%@份", trade.units.plainNumberString()))
                                    .font(.footnote)
                                    .foregroundStyle(AssetTheme.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if index < min(report.trades.count, 6) - 1 {
                            Divider()
                                .overlay(AssetTheme.border.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func scheduleRefresh(delayNanoseconds: UInt64) {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                refreshReport()
            }
        }
    }

    @MainActor
    private func refreshReport() {
        guard let selectedAssetOption else {
            report = nil
            bestCandidates = []
            return
        }

        let filteredAssetSeries = filteredHistorySeries(selectedAssetSeries, within: effectiveDateBounds)
        let filteredFXSeries = filteredHistorySeries(selectedFXSeries, within: effectiveDateBounds)

        guard filteredAssetSeries != nil,
              selectedAssetOption.requiresHistoricalFX == false || filteredFXSeries != nil else {
            report = nil
            bestCandidates = []
            return
        }

        let refreshedReport = BacktestEngine.runAdvancedStrategy(
            assetSeries: filteredAssetSeries,
            assetOption: selectedAssetOption,
            fxSeries: filteredFXSeries,
            initialCash: initialCash,
            tradeAmount: tradeAmount,
            buyRule: AdvancedBacktestRule(direction: buyDirection, days: buyDays),
            sellRule: AdvancedBacktestRule(direction: sellDirection, days: sellDays),
            settings: riskSettings
        )

        guard let refreshedReport else {
            report = nil
            bestCandidates = []
            return
        }

        report = refreshedReport
        bestCandidates = BacktestEngine.optimizeAdvancedStrategy(
            assetSeries: filteredAssetSeries,
            assetOption: selectedAssetOption,
            fxSeries: filteredFXSeries,
            initialCash: initialCash,
            baseSettings: riskSettings,
            limit: 3
        )
    }

    private func filteredHistorySeries(_ series: PublicHistorySeries?, within bounds: ClosedRange<Date>?) -> PublicHistorySeries? {
        guard let series else { return nil }
        guard let bounds else { return series }

        let filteredPairs = zip(series.dates, series.prices).filter { dateText, _ in
            guard let date = BacktestEngine.historicalSeriesDateStatic(from: dateText) else { return false }
            return date >= bounds.lowerBound && date <= bounds.upperBound
        }
        let filteredDates = filteredPairs.map { $0.0 }
        let filteredPrices = filteredPairs.map { $0.1 }
        guard filteredDates.count >= 2 else { return nil }

        return PublicHistorySeries(
            symbol: series.symbol,
            category: series.category,
            label: series.label,
            currency: series.currency,
            unit: series.unit,
            source: series.source,
            dates: filteredDates,
            prices: filteredPrices
        )
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

    private func advancedRuleRow(title: String, direction: Binding<AdvancedBacktestSignalDirection>, days: Binding<Int>, accent: Color, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AssetTheme.textSecondary)
                    Spacer()
                    Text(advancedRuleSummary(direction: direction.wrappedValue, days: days.wrappedValue))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(accent)
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: 12) {
                    Menu {
                        Picker(title, selection: direction) {
                            ForEach(AdvancedBacktestSignalDirection.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
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
            buyDirection = sellDirection
            buyDays = sellDays
            sellDirection = originalBuyDirection
            sellDays = originalBuyDays
        }
    }

    private func applyCandidate(_ candidate: AdvancedBacktestCandidate) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            buyDirection = candidate.buyRule.direction
            buyDays = candidate.buyRule.days
            sellDirection = candidate.sellRule.direction
            sellDays = candidate.sellRule.days
            tradeAmount = candidate.tradeAmount
            feeRate = candidate.settings.feeRate
            maxPositionRatio = candidate.settings.maxPositionRatio
            cooldownDays = Double(candidate.settings.cooldownDays)
            stopLossRatio = candidate.settings.stopLossRatio
            takeProfitRatio = candidate.settings.takeProfitRatio
            report = candidate.report
        }
    }

    private func advancedRuleSummary(direction: AdvancedBacktestSignalDirection, days: Int) -> String {
        if direction.usesDayThreshold {
            return AppLocalization.format("%@ %d天", direction.title, days)
        }

        return direction.title
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
    let value: String
    var accent: Color = AssetTheme.gold

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary)
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

        return AppLocalization.format(
            AppLocalization.string("今年需要年结余 %@"),
            projection.projectedAnnualSurplus.currencyString()
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

private struct TimeMachinePageHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string("时光机"))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AssetTheme.textPrimary)
                .lineLimit(1)

            Text(AppLocalization.string("看资产曲线、月结余和长期对照。"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.86))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
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

    private var leftDomain: ClosedRange<Double> {
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

    @ChartContentBuilder
    private var latestPointMarksNormalized: some ChartContent {
        if let selectedDualPoint {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedDualPoint.date),
                y: .value(descriptor.leftTitle, normalized(selectedDualPoint.leftValue, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(46)

            if descriptor.showsComparisonLine {
                PointMark(
                    x: .value(AppLocalization.string("日期"), selectedDualPoint.date),
                    y: .value(descriptor.rightTitle, normalized(selectedDualPoint.rightValue, in: rightDomain))
                )
                .foregroundStyle(descriptor.rightColor)
                .symbolSize(40)
            }
        }
    }

    @ChartContentBuilder
    private var leftOnlyLatestPointMarks: some ChartContent {
        if let selectedLeftOnlyPoint {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedLeftOnlyPoint.date),
                y: .value(descriptor.leftTitle, normalized(selectedLeftOnlyPoint.value, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(46)
        }
    }

    private var bottomAxisMarks: some AxisContent {
        let axisDates = detailCardAxisDates(displayLeftOnlyPoints.map(\.date) + displayPoints.map(\.date))
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
        if let selectedDualPoint {
            return selectedDualPoint.date.chartAxisDateString
        }
        if let selectedLeftOnlyPoint {
            return selectedLeftOnlyPoint.date.chartAxisDateString
        }
        return dateRangeLabel
    }

    private var dateRangeLabel: String {
        let dates = (descriptor.leftOnlyPoints.map(\.date) + descriptor.points.map(\.date)).sorted()
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

    private var latestPoint: TimeMachineSingleAxisPoint? {
        filteredPoints.last ?? descriptor.points.last
    }

    private var selectedPoint: TimeMachineSingleAxisPoint? {
        guard let latestPoint else { return nil }
        guard let selectedDate else { return latestPoint }
        return nearestSingleAxisPoint(to: selectedDate, in: displayPoints) ?? latestPoint
    }

    private var valueDomain: ClosedRange<Double> {
        paddedDomain(values: displayPoints.map(\.value))
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

                                Text(AppLocalization.string("历史走势"))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AssetTheme.goldSoft)

                                if let subtitle = descriptor.subtitle {
                                    Text(AppLocalization.string(subtitle))
                                        .font(.caption)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                            }

                            Spacer(minLength: 12)

                            if let selectedPoint {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(descriptor.axisStyle.compactLabel(for: selectedPoint.value))
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(descriptor.color)
                                    Text(selectedPoint.date.chartAxisDateString)
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

                        Text(selectedDate == nil ? dateRangeLabel : (selectedPoint?.date.chartAxisDateString ?? dateRangeLabel))
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

    private var historyChart: some View {
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
        .chartXAxis {
            let axisDates = chartAxisDates(displayPoints.map(\.date))
            AxisMarks(values: axisDates) { value in
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
        .chartYAxis {
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

    private var dateRangeLabel: String {
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
