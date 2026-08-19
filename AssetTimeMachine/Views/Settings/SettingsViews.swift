import SwiftUI
import SwiftData
import Charts
import UIKit
import UserNotifications
import Combine

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appLanguageStore: AppLanguageStore
    @AppStorage("app.appearanceMode") private var appearanceModeRawValue: String = AppAppearanceMode.system.rawValue
    @AppStorage("app.notifications.enabled") private var notificationEnabled = false
    @AppStorage("app.notifications.intervalHours") private var notificationIntervalHours: Double = 1
    @AppStorage("app.strategyNotifications.enabled") private var strategyNotificationEnabled = false
    @AppStorage("app.strategyNotifications.templateID") private var strategyNotificationTemplateID = StrategyRebalanceDefaults.defaultTemplateID
    @AppStorage("app.strategyNotifications.hour") private var strategyNotificationHour: Int = StrategyNotificationDefaults.defaultHour
    @ObservedObject var cloudStore: AssetTimeMachineCloudStore
    let isActive: Bool
    let onSendStrategyTestNotification: () async -> StrategyTestNotificationResult
    let onReplayOnboarding: () -> Void
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showsLogoutConfirmation = false
    @State private var isSendingStrategyTestNotification = false
    @State private var strategyTestNotificationMessage: String?
    @State private var cachedNotificationPreview = AppLocalization.string("暂无资产记录")
    @State private var showsLanguageSelection = false
    @State private var pendingAppLanguage: AppLanguage?

    init(
        cloudStore: AssetTimeMachineCloudStore,
        isActive: Bool,
        onSendStrategyTestNotification: @escaping () async -> StrategyTestNotificationResult,
        onReplayOnboarding: @escaping () -> Void
    ) {
        self.cloudStore = cloudStore
        self.isActive = isActive
        self.onSendStrategyTestNotification = onSendStrategyTestNotification
        self.onReplayOnboarding = onReplayOnboarding
    }

    private var notificationPreview: String {
        cachedNotificationPreview
    }

    private var selectedStrategyTemplate: AdvancedBacktestStrategyTemplate? {
        StrategyRebalanceDefaults.template(for: strategyNotificationTemplateID)
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
        AppLocalization.string("提醒将跟随量化页当前调仓策略。")
    }

    private var canLogout: Bool {
        cloudStore.currentUser != nil || cloudStore.hasToken
    }

    private var currentAppearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    private var currentAppLanguage: AppLanguage {
        appLanguageStore.language
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

    private var appStoreReviewURL: URL? {
        URL(string: "itms-apps://itunes.apple.com/app/id6764277773?action=write-review")
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

                        Button {
                            pendingAppLanguage = nil
                            showsLanguageSelection = true
                        } label: {
                            LabeledContent {
                                HStack(spacing: 6) {
                                    SettingsValueText(currentAppLanguage.title)

                                    Image(systemName: "chevron.right")
                                        .font(AppTypography.microLabel)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                            } label: {
                                SettingsRowLabel(
                                    title: AppLocalization.string("语言"),
                                    systemImage: "globe",
                                    color: AssetTheme.accentOrange
                                )
                            }
                        }
                        .buttonStyle(.plain)
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
                                    .font(AppTypography.metaStrong)
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
                        .disabled(StrategyRebalanceDefaults.eligibleTemplates.isEmpty)
                        .listRowBackground(AssetTheme.surface)

                        if !StrategyRebalanceDefaults.eligibleTemplates.isEmpty {
                            LabeledContent {
                                HStack(spacing: 6) {
                                    SettingsValueText(selectedStrategyTemplate?.title ?? AppLocalization.string("未选择"))
                                    if let selectedStrategyTemplate,
                                       BacktestProductStrategyCatalog.isCuratedTemplateID(selectedStrategyTemplate.id) {
                                        CuratedStrategyBadge(compact: true)
                                    }
                                }
                            } label: {
                                Text(AppLocalization.string("调仓策略"))
                                    .foregroundStyle(AssetTheme.textPrimary)
                            }
                            .listRowBackground(AssetTheme.surface)
                        } else {
                            LabeledContent {
                                SettingsValueText(AppLocalization.string("暂无策略"))
                            } label: {
                                Text(AppLocalization.string("调仓策略"))
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

                        if !StrategyRebalanceDefaults.eligibleTemplates.isEmpty {
                            Button {
                                sendStrategyTestNotification()
                            } label: {
                                HStack(spacing: 12) {
                                    SettingsRowLabel(
                                        title: AppLocalization.string("发送测试提醒"),
                                        systemImage: "paperplane.fill",
                                        color: AssetTheme.accentBlue
                                    )

                                    Spacer()

                                    if isSendingStrategyTestNotification {
                                        ProgressView()
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isSendingStrategyTestNotification)
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
                                        .font(AppTypography.metaStrong)
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

                            if let strategyTestNotificationMessage {
                                Text(strategyTestNotificationMessage)
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
                                        if cloudStore.hasCompletedInitialSync {
                                            if let email = currentUser.userEmail, !email.isEmpty {
                                                Text(email)
                                                    .font(AppTypography.caption)
                                                    .foregroundStyle(AssetTheme.textSecondary)
                                            } else {
                                                Text(AppLocalization.string("云同步已完成"))
                                                    .font(AppTypography.caption)
                                                    .foregroundStyle(AssetTheme.textSecondary)
                                            }
                                        } else {
                                            Text(AppLocalization.string("等待首次云同步"))
                                                .font(AppTypography.caption)
                                                .foregroundStyle(AssetTheme.goldSoft)
                                        }
                                    }
                                } else {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(cloudStore.isSessionPending ? AppLocalization.string("正在恢复登录") : AppLocalization.string("登录凭证已保存"))
                                            .foregroundStyle(AssetTheme.textPrimary)
                                        Text(AppLocalization.string("正在验证云同步状态"))
                                            .font(AppTypography.caption)
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
                            .disabled(cloudStore.isWorking)
                        } header: {
                            Text(AppLocalization.string("账户"))
                        }
                    }

                    Section {
                        Button {
                            guard let appStoreReviewURL else { return }
                            openURL(appStoreReviewURL)
                        } label: {
                            HStack(spacing: 12) {
                                SettingsRowLabel(
                                    title: AppLocalization.string("在 App Store 评分"),
                                    systemImage: "star.fill",
                                    color: AssetTheme.gold
                                )

                                Spacer()

                                Image(systemName: "arrow.up.right.square")
                                    .font(AppTypography.metaStrong)
                                    .foregroundStyle(AssetTheme.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(AssetTheme.surface)

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
                .id(appLanguageStore.language.rawValue)
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 54)
            }
            .navigationTitle(AppLocalization.string("设置"))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: isActive) {
                guard isActive else { return }
                normalizeStrategyNotificationTemplateIfNeeded()
                refreshNotificationPreview()
                await reloadNotificationStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { notification in
                guard isActive, PortfolioSaveNotificationFilter.affectsPortfolio(notification) else { return }
                refreshNotificationPreview()
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
            .sheet(isPresented: $showsLanguageSelection, onDismiss: applyPendingAppLanguage) {
                AppLanguageSelectionSheet(
                    currentLanguage: currentAppLanguage
                ) { language in
                    pendingAppLanguage = language
                    showsLanguageSelection = false
                }
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.visible)
            }
            .alert(AppLocalization.string("退出云同步"), isPresented: $showsLogoutConfirmation) {
                Button(AppLocalization.string("取消"), role: .cancel) {}
                Button(AppLocalization.string("退出"), role: .destructive) {
                    cloudStore.logout()
                }
            }
        }
    }

    @MainActor
    private func applyPendingAppLanguage() {
        guard let pendingAppLanguage else { return }
        self.pendingAppLanguage = nil
        guard pendingAppLanguage != appLanguageStore.language else { return }

        appLanguageStore.select(pendingAppLanguage)
        refreshNotificationPreview()
    }

    private func intervalLabel(_ hours: Double) -> String {
        let integer = Int(hours)
        if integer == 24 {
            return AppLocalization.string("每天一次")
        }

        return AppLocalization.format("每 %d 小时", integer)
    }

    @MainActor
    private func refreshNotificationPreview() {
        let latestSnapshot = try? SnapshotService.latestSnapshot(in: modelContext)
        guard let latestSnapshot else {
            cachedNotificationPreview = AppLocalization.string("暂无资产记录")
            return
        }
        let metrics = PortfolioCalculator.metrics(for: latestSnapshot)
        cachedNotificationPreview = AppLocalization.format(
            "总资产 %@ · 净资产 %@ · 负债 %@",
            metrics.totalAssets.currencyString(),
            metrics.netAssets.currencyString(),
            metrics.totalLiabilities.currencyString()
        )
    }

    private func strategyHourLabel(_ hour: Int) -> String {
        AppLocalization.format("%02d:00", min(max(hour, 0), 23))
    }

    private func normalizeStrategyNotificationTemplateIfNeeded() {
        guard StrategyRebalanceDefaults.template(for: strategyNotificationTemplateID)?.id != strategyNotificationTemplateID else { return }
        strategyNotificationTemplateID = StrategyRebalanceDefaults.defaultTemplateID
    }

    private func sendStrategyTestNotification() {
        guard !isSendingStrategyTestNotification else { return }
        isSendingStrategyTestNotification = true
        strategyTestNotificationMessage = nil

        Task {
            let result = await onSendStrategyTestNotification()
            await reloadNotificationStatus()
            isSendingStrategyTestNotification = false
            switch result {
            case .sent:
                strategyTestNotificationMessage = AppLocalization.string("测试提醒已发送")
            case .denied:
                strategyTestNotificationMessage = AppLocalization.string("通知权限未开启")
            case .failed(let message):
                strategyTestNotificationMessage = "\(AppLocalization.string("发送测试提醒"))：\(message)"
            }
        }
    }

    private func reloadNotificationStatus() async {
        notificationStatus = await AssetNotificationService.authorizationStatus()
    }
}

struct SettingsRowLabel: View {
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
                        .font(AppTypography.metaStrong)
                        .foregroundStyle(.white)
                )

            Text(title)
                .foregroundStyle(AssetTheme.textPrimary)
        }
    }
}

struct SettingsValueText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(AssetTheme.textSecondary)
    }
}

private struct AppLanguageSelectionSheet: View {
    let currentLanguage: AppLanguage
    let onSelect: (AppLanguage) -> Void

    var body: some View {
        NavigationStack {
            List(AppLanguage.allCases) { language in
                Button {
                    onSelect(language)
                } label: {
                    HStack(spacing: 12) {
                        Text(language.title)
                            .foregroundStyle(AssetTheme.textPrimary)

                        Spacer()

                        if language == currentLanguage {
                            Image(systemName: "checkmark")
                                .font(AppTypography.captionStrong)
                                .foregroundStyle(AssetTheme.gold)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(AssetTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(AssetTheme.background)
            .navigationTitle(AppLocalization.string("语言"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct SnapshotCategoryItems: Identifiable {
    let category: AssetCategory
    let items: [AssetItem]

    var id: UUID { category.id }
}
