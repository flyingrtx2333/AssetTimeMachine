#if targetEnvironment(macCatalyst)
import SwiftUI

extension ContentView {
    private var opensQuantFromNativeMac: Bool {
        if ProcessInfo.processInfo.arguments.contains("-openQuantTab") { return true }
        let requestedAt = UserDefaults(suiteName: "group.com.flyingrtx.AssetTimeMachine")?
            .double(forKey: "nativeMac.openFullQuantAt") ?? 0
        return requestedAt > 0 && Date().timeIntervalSince1970 - requestedAt < 90
    }

    var macWorkspace: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 9) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(AssetTheme.gold)
                        .frame(width: 32, height: 32)
                        .background(AssetTheme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Text(AppLocalization.string("资产时光机"))
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.vertical, 12)

                VStack(spacing: 3) {
                    macNavigationItem(.dashboard, title: "首页", icon: "house", key: "1")
                    macNavigationItem(.snapshots, title: "记录", icon: "square.and.pencil", key: "2")
                    macNavigationItem(.timeMachine, title: "时光机", icon: "clock.arrow.circlepath", key: "3")
                    macNavigationItem(.backtest, title: "量化", icon: "chart.xyaxis.line", key: "4")
                    macNavigationItem(.settings, title: "设置", icon: "gearshape", key: "5")
                }
                Spacer()
                Button { selectTab(.settings) } label: {
                    HStack {
                        DashboardCloudStatusButton(store: cloudStore)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .padding(10)
                    .background(AssetTheme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityHint(AppLocalization.string("设置"))
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 10)
            .frame(width: 168)
            .background(AssetTheme.backgroundSecondary)

            Rectangle().fill(AssetTheme.border).frame(width: 1)
            Group {
                switch selectedTab {
                case .dashboard:
                    DashboardView(marketStore: marketStore, cloudStore: cloudStore,
                                  isActive: workActiveTab == .dashboard,
                                  onRecord: { selectTab(.snapshots) },
                                  onHistory: { selectTab(.timeMachine) })
                case .snapshots:
                    SnapshotListView(marketStore: marketStore, isActive: workActiveTab == .snapshots,
                                     onboardingSessionID: onboardingSessionID,
                                     onOnboardingCompleted: finishOnboarding, onSkipOnboarding: finishOnboarding)
                case .timeMachine:
                    TimeMachineView(marketStore: marketStore, isActive: workActiveTab == .timeMachine)
                case .backtest:
                    BacktestView(marketStore: marketStore, strategyAdviceService: strategyAdviceService,
                                 isActive: workActiveTab == .backtest)
                case .settings:
                    SettingsView(cloudStore: cloudStore, isActive: workActiveTab == .settings,
                                 onSendStrategyTestNotification: { await sendStrategyTestNotification() }) {
                        presentOnboarding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .controlSize(.small)
        .foregroundStyle(AssetTheme.textPrimary)
        .overlay {
            if !AppPreviewSession.skipsAccountEntry && !hasCompletedOnboarding && cloudStore.currentUser == nil {
                MacAccountEntryView(
                    cloudStore: cloudStore,
                    onContinueLocally: {
                        finishOnboarding()
                        selectTab(opensQuantFromNativeMac ? .backtest : .dashboard)
                    },
                    onSignedIn: {
                        finishOnboarding()
                        selectTab(opensQuantFromNativeMac ? .backtest : .dashboard)
                    }
                )
            }
        }
        .onChange(of: cloudStore.currentUser?.id) { _, userID in
            if userID != nil && !hasCompletedOnboarding {
                finishOnboarding()
            }
        }
        .task {
            if opensQuantFromNativeMac { selectTab(.backtest) }
            if cloudStore.currentUser != nil && !hasCompletedOnboarding {
                finishOnboarding()
            }
        }
    }

    private func macNavigationItem(_ tab: AppTab, title: String, icon: String, key: KeyEquivalent) -> some View {
        Button {
            #if DEBUG
            NSLog("[MacNavigation] selected \(title)")
            #endif
            selectTab(tab)
        } label: {
            Label(AppLocalization.string(title), systemImage: icon)
                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
                .foregroundStyle(selectedTab == tab ? AssetTheme.gold : AssetTheme.textPrimary)
                .background(selectedTab == tab ? AssetTheme.gold.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
    }
}
#if DEBUG
extension ContentView {
    @MainActor
    func scheduleMacPreviewTourIfNeeded() {
        guard AppPreviewSession.isActive,
              let folder = launchArgumentValue(after: "-macPreviewTour") else { return }
        debugTabSwitchTask = Task { @MainActor in
            let sequence: [(AppTab, String)] = [
                (.dashboard, "dashboard"), (.snapshots, "records"),
                (.timeMachine, "time-machine"), (.backtest, "quant"),
                (.settings, "settings"), (.dashboard, "dashboard-return")
            ]
            for (tab, name) in sequence {
                guard !Task.isCancelled else { return }
                selectTab(tab)
                try? await Task.sleep(for: .seconds(4))
                MacWindowConfiguration.capture(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png").path)
                NSLog("[MacPreviewTour] mounted \(name)")
            }
            debugTabSwitchTask = nil
        }
    }
}
#endif

#endif
