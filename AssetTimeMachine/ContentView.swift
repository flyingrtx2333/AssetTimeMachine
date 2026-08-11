import SwiftUI
import SwiftData
import Combine

enum AppTab: Hashable {
    case dashboard
    case snapshots
    case timeMachine
    case backtest
    case settings
}

@MainActor
final class AppRuntimeStore: ObservableObject {
    let marketStore = RemoteMarketStore()
    let cloudStore = AssetTimeMachineCloudStore()
    let strategyAdviceService = StrategyAdviceService()
}

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.scenePhase) var scenePhase
    @AppStorage("app.onboarding.completed") var hasCompletedOnboarding = false
    @AppStorage("app.notifications.enabled") var notificationEnabled = false
    @AppStorage("app.notifications.intervalHours") var notificationIntervalHours: Double = 1
    @AppStorage("app.strategyNotifications.enabled") var strategyNotificationEnabled = false
    @AppStorage("app.strategyNotifications.templateID") var strategyNotificationTemplateID = StrategyNotificationDefaults.defaultTemplateID
    @AppStorage("app.strategyNotifications.hour") var strategyNotificationHour: Int = StrategyNotificationDefaults.defaultHour
    @StateObject var runtimeStore = AppRuntimeStore()
    @State var mountedTabs: Set<AppTab> = [.dashboard]
    @State var lastSelectedTab: AppTab = .dashboard
    @State var selectedTab: AppTab = .dashboard
    @State var workActiveTab: AppTab?
    @State var workActivationTask: Task<Void, Never>?
    @State var didRunStartup = false
    @State var lastMarketRefreshAt: Date?
    @State var showsOnboarding = false
    @State var onboardingReturnTab: AppTab = .dashboard
    @State var activeOnboardingAnchorID: OnboardingAnchorID?
    @State var pendingSnapshotNotificationRefreshTask: Task<Void, Never>?
    @State var notificationRefreshTaskID: UUID?
    @State var notificationRefreshGeneration = 0
    @State var notificationRefreshRequestedDelayNanoseconds: UInt64 = 0
    @State var startupMaintenanceTask: Task<Void, Never>?
    @State var isApplyingCloudData = false
    @State var cloudDataRevision = 0
    #if DEBUG
    @State var debugTabSwitchTask: Task<Void, Never>?
    #endif

    static let foregroundMarketRefreshInterval: TimeInterval = 3600

    var marketStore: RemoteMarketStore { runtimeStore.marketStore }
    var cloudStore: AssetTimeMachineCloudStore { runtimeStore.cloudStore }
    var strategyAdviceService: StrategyAdviceService { runtimeStore.strategyAdviceService }

    var body: some View {
        Group {
            if isApplyingCloudData {
                ZStack {
                    AssetTheme.pageGradient.ignoresSafeArea()

                    ProgressView()
                        .controlSize(.large)
                        .tint(AssetTheme.gold)
                        .padding(24)
                        .background(AssetTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            } else {
                TabView(selection: tabSelection) {
            deferredTabContent(for: .dashboard) {
                TabSurface(isSelected: selectedTab == .dashboard) {
                    DashboardView(
                        marketStore: marketStore,
                        cloudStore: cloudStore,
                        strategyAdviceService: strategyAdviceService,
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
                        strategyAdviceService: strategyAdviceService,
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
                        isActive: workActiveTab == .settings,
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
                .id(cloudDataRevision)
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
            }
        }
        .tint(AssetTheme.gold)
        .task {
            let migratedStrategyID = StrategyNotificationDefaults.migratedTemplateID(strategyNotificationTemplateID)
            if migratedStrategyID != strategyNotificationTemplateID {
                strategyNotificationTemplateID = migratedStrategyID
            }
            await runStartupIfNeeded()
            if workActiveTab == nil {
                scheduleWorkActivation(for: selectedTab)
            }
            #if DEBUG
            scheduleDebugTabSwitchLoopIfNeeded()
            #endif
            scheduleSnapshotNotificationRefresh(delayNanoseconds: 0)

            startupMaintenanceTask?.cancel()
            startupMaintenanceTask = Task(priority: .utility) {
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled else { return }
                await cloudStore.refreshIfNeeded(from: modelContext)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                scheduleSnapshotNotificationRefresh(delayNanoseconds: 0)
                startupMaintenanceTask = nil
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
            scheduleSnapshotNotificationRefresh(delayNanoseconds: 0)
        }
        .onChange(of: notificationIntervalHours) { _, _ in
            scheduleSnapshotNotificationRefresh(delayNanoseconds: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { notification in
            guard PortfolioSaveNotificationFilter.affectsPortfolio(notification) else { return }
            if !cloudStore.isApplyingLocalData {
                cloudStore.scheduleAutoSync(from: modelContext, quietly: true)
            }
            guard notificationEnabled || strategyNotificationEnabled else { return }
            scheduleSnapshotNotificationRefresh()
        }
        .onReceive(cloudStore.$isApplyingLocalData.removeDuplicates()) { isApplying in
            isApplyingCloudData = isApplying
            if isApplying {
                workActivationTask?.cancel()
                workActiveTab = nil
                // Keep a single notification coordinator alive. System notification
                // calls are not reliably cancellable; changing the generation makes
                // the existing serial loop reapply the newest state after import.
                notificationRefreshGeneration &+= 1
            } else {
                scheduleWorkActivation(for: selectedTab)
                scheduleSnapshotNotificationRefresh()
            }
        }
        .onReceive(cloudStore.$localDataRevision.removeDuplicates()) { revision in
            guard revision != cloudDataRevision else { return }
            cloudDataRevision = revision
        }
        .onChange(of: strategyNotificationEnabled) { _, _ in
            scheduleSnapshotNotificationRefresh(delayNanoseconds: 0)
        }
        .onChange(of: strategyNotificationTemplateID) { _, _ in
            scheduleSnapshotNotificationRefresh(delayNanoseconds: 0)
        }
        .onChange(of: strategyNotificationHour) { _, _ in
            scheduleSnapshotNotificationRefresh(delayNanoseconds: 0)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self, BacktestRecord.self, SyncDeletionTombstone.self],
            inMemory: true
        )
}
