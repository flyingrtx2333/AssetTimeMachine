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
    @Query private var snapshots: [AssetSnapshot]
    @AppStorage("app.onboarding.completed") private var hasCompletedOnboarding = false
    @AppStorage("app.notifications.enabled") private var notificationEnabled = false
    @AppStorage("app.notifications.intervalHours") private var notificationIntervalHours: Double = 1
    @AppStorage("app.strategyNotifications.enabled") private var strategyNotificationEnabled = false
    @AppStorage("app.strategyNotifications.templateID") private var strategyNotificationTemplateID = StrategyNotificationDefaults.defaultTemplateID
    @AppStorage("app.strategyNotifications.hour") private var strategyNotificationHour: Int = StrategyNotificationDefaults.defaultHour
    @StateObject private var marketStore = RemoteMarketStore()
    @StateObject private var cloudStore = AssetTimeMachineCloudStore()
    @State private var selectedTab: AppTab = .dashboard
    @State private var didRunStartup = false
    @State private var lastMarketRefreshAt: Date?
    @State private var showsOnboarding = false
    @State private var onboardingReturnTab: AppTab = .dashboard
    @State private var activeOnboardingAnchorID: OnboardingAnchorID?
    @State private var pendingSnapshotNotificationRefreshTask: Task<Void, Never>?
    #if DEBUG
    @State private var debugTabSwitchTask: Task<Void, Never>?
    #endif

    private static let foregroundMarketRefreshInterval: TimeInterval = 3600

    init() {
        var descriptor = FetchDescriptor<AssetSnapshot>(
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        _snapshots = Query(descriptor)
    }

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
                    DashboardView(
                        marketStore: marketStore,
                        cloudStore: cloudStore,
                        isActive: selectedTab == .dashboard
                    )
                }
                    .tabItem {
                        Label(AppLocalization.string("首页"), systemImage: "house")
                    }
                    .tag(AppTab.dashboard)

                deferredTabContent(for: .snapshots) {
                    SnapshotListView(
                        marketStore: marketStore,
                        isActive: selectedTab == .snapshots,
                        onboardingActiveAnchorID: activeOnboardingAnchorID
                    )
                }
                    .tabItem {
                        Label(AppLocalization.string("记录"), systemImage: "square.and.pencil")
                    }
                    .tag(AppTab.snapshots)

                deferredTabContent(for: .timeMachine) {
                    TimeMachineView(
                        marketStore: marketStore,
                        isVisible: selectedTab == .timeMachine,
                        isActive: selectedTab == .timeMachine
                    )
                }
                    .tabItem {
                        Label(AppLocalization.string("时光机"), systemImage: "clock.arrow.circlepath")
                    }
                    .tag(AppTab.timeMachine)

                deferredTabContent(for: .backtest) {
                    BacktestView(
                        marketStore: marketStore,
                        isVisible: selectedTab == .backtest,
                        isActive: selectedTab == .backtest
                    )
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
        .task {
            await runStartupIfNeeded()
            #if DEBUG
            scheduleDebugTabSwitchLoopIfNeeded()
            #endif
            await cloudStore.refreshIfNeeded(from: modelContext)
            await refreshAssetNotifications()
            Task {
                try? await Task.sleep(for: .seconds(2))
                await refreshStrategyNotifications()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }

            while !didRunStartup && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, scenePhase == .active else { return }

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
        if selectedTab == tab {
            content()
        } else {
            AssetTheme.pageGradient.ignoresSafeArea()
        }
    }

    @MainActor
    private func runStartupIfNeeded() async {
        guard !didRunStartup else { return }
        didRunStartup = true

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-openSnapshotsTab") {
            selectedTab = .snapshots
        }

        if ProcessInfo.processInfo.arguments.contains("-openTimeMachineTab") {
            selectedTab = .timeMachine
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

        await Task.yield()
        try? SeedDataService.ensureDefaultFinancialItems(in: modelContext)
        try? AssetItemService.migrateLegacyAutoPricedItemsIfNeeded(in: modelContext)

        if !hasCompletedOnboarding {
            presentOnboarding()
        }

    }

    @MainActor
    private func scheduleSnapshotNotificationRefresh() {
        pendingSnapshotNotificationRefreshTask?.cancel()
        pendingSnapshotNotificationRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
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
                    selectedTab = tab
                }
                try? await Task.sleep(for: .milliseconds(520))
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
        let didRefreshLiveData = await marketStore.refreshLiveData()
        if didRefreshLiveData {
            lastMarketRefreshAt = .now
            await syncTodaySnapshotWithLatestMarketData()
        }
        await refreshAssetNotifications()
        Task { await refreshStrategyNotifications() }
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
            return (template.title, AppLocalization.string("历史行情暂时不足，今日调仓将在数据补齐后更新。"))
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

#Preview {
    ContentView()
        .modelContainer(for: [AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self], inMemory: true)
}
