import SwiftUI
import SwiftData

enum AppTab: Hashable {
    case dashboard
    case snapshots
    case timeMachine
    case backtest
    case settings
}

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.scenePhase) var scenePhase
    @Query var snapshots: [AssetSnapshot]
    @AppStorage("app.onboarding.completed") var hasCompletedOnboarding = false
    @AppStorage("app.notifications.enabled") var notificationEnabled = false
    @AppStorage("app.notifications.intervalHours") var notificationIntervalHours: Double = 1
    @AppStorage("app.strategyNotifications.enabled") var strategyNotificationEnabled = false
    @AppStorage("app.strategyNotifications.templateID") var strategyNotificationTemplateID = StrategyNotificationDefaults.defaultTemplateID
    @AppStorage("app.strategyNotifications.hour") var strategyNotificationHour: Int = StrategyNotificationDefaults.defaultHour
    @StateObject var marketStore = RemoteMarketStore()
    @StateObject var cloudStore = AssetTimeMachineCloudStore()
    @State var mountedTabs: Set<AppTab> = [.dashboard]
    @State var lastSelectedTab: AppTab = .dashboard
    @State var selectedTab: AppTab = .dashboard
    @State var workActiveTab: AppTab? = .dashboard
    @State var workActivationTask: Task<Void, Never>?
    @State var didRunStartup = false
    @State var lastMarketRefreshAt: Date?
    @State var showsOnboarding = false
    @State var onboardingReturnTab: AppTab = .dashboard
    @State var activeOnboardingAnchorID: OnboardingAnchorID?
    @State var pendingSnapshotNotificationRefreshTask: Task<Void, Never>?
    #if DEBUG
    @State var debugTabSwitchTask: Task<Void, Never>?
    #endif

    static let foregroundMarketRefreshInterval: TimeInterval = 3600

    init() {
        var descriptor = FetchDescriptor<AssetSnapshot>(
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        _snapshots = Query(descriptor)
    }

    var body: some View {
        TabView(selection: tabSelection) {
            deferredTabContent(for: .dashboard) {
                TabSurface(isSelected: selectedTab == .dashboard) {
                    DashboardView(
                        marketStore: marketStore,
                        cloudStore: cloudStore,
                        isActive: workActiveTab == .dashboard
                    )
                }
            }
                .tabItem {
                    Label(AppLocalization.string("首页"), systemImage: "house")
                }
                .tag(AppTab.dashboard)

            deferredTabContent(for: .snapshots) {
                TabSurface(isSelected: selectedTab == .snapshots) {
                    SnapshotListView(
                        marketStore: marketStore,
                        isActive: workActiveTab == .snapshots,
                        onboardingActiveAnchorID: activeOnboardingAnchorID
                    )
                }
            }
                .tabItem {
                    Label(AppLocalization.string("记录"), systemImage: "square.and.pencil")
                }
                .tag(AppTab.snapshots)

            deferredTabContent(for: .timeMachine) {
                TabSurface(isSelected: selectedTab == .timeMachine) {
                    TimeMachineView(
                        marketStore: marketStore,
                        isActive: workActiveTab == .timeMachine
                    )
                }
            }
                .tabItem {
                    Label(AppLocalization.string("时光机"), systemImage: "clock.arrow.circlepath")
                }
                .tag(AppTab.timeMachine)

            deferredTabContent(for: .backtest) {
                TabSurface(isSelected: selectedTab == .backtest) {
                    BacktestView(
                        marketStore: marketStore,
                        isActive: workActiveTab == .backtest
                    )
                }
            }
                .tabItem {
                    Label(AppLocalization.string("量化"), systemImage: "chart.xyaxis.line")
                }
                .tag(AppTab.backtest)

            deferredTabContent(for: .settings) {
                TabSurface(isSelected: selectedTab == .settings) {
                    SettingsView(
                        cloudStore: cloudStore,
                        onSendStrategyTestNotification: {
                            await sendStrategyTestNotification()
                        }
                    ) {
                        presentOnboarding()
                    }
                }
            }
                .tabItem {
                    Label(AppLocalization.string("设置"), systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        .animation(nil, value: selectedTab)
        .overlayPreferenceValue(OnboardingAnchorPreferenceKey.self) { anchors in
            if showsOnboarding {
                OnboardingTutorialView(
                    selectedTab: tabSelection,
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
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                await cloudStore.refreshIfNeeded(from: modelContext)
            }
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
}

#Preview {
    ContentView()
        .modelContainer(for: [AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self], inMemory: true)
}
