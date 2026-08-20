import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
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
    @State private var showsCloudSyncModal = false
    @State private var isSendingStrategyTestNotification = false
    @State private var strategyTestNotificationMessage: String?
    @State private var showsLanguageSelection = false
    @State private var showsStrategyLibrary = false
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

    private var selectedStrategyTemplate: AdvancedBacktestStrategyTemplate? {
        StrategyRebalanceDefaults.template(for: strategyNotificationTemplateID)
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

    private var cloudOverviewKey: String {
        SettingsOverviewStatus.cloudKey(
            hasAccount: canLogout,
            isWorking: cloudStore.isWorking || cloudStore.isSessionPending,
            completedInitialSync: cloudStore.hasCompletedInitialSync,
            hasError: !(cloudStore.errorMessage?.isEmpty ?? true)
        )
    }

    private var notificationOverviewKey: String {
        SettingsOverviewStatus.notificationKey(
            assetBriefingEnabled: notificationEnabled,
            rebalanceReminderEnabled: strategyNotificationEnabled,
            authorizationDenied: notificationStatus == .denied
        )
    }

    private var cloudOverviewColor: Color {
        switch cloudStore.indicatorState {
        case .healthy:
            return AssetTheme.positive
        case .warning:
            return AssetTheme.negative
        case .idle, .checking:
            return AssetTheme.gold
        }
    }

    private var notificationOverviewColor: Color {
        if notificationStatus == .denied {
            return AssetTheme.negative
        }
        return notificationEnabled || strategyNotificationEnabled ? AssetTheme.gold : AssetTheme.textSecondary
    }

    private var cloudAccountSubtitle: String? {
        if let currentUser = cloudStore.currentUser {
            return currentUser.displayName
        }
        if cloudStore.isSessionPending {
            return AppLocalization.string("正在恢复登录")
        }
        return nil
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
                    pageOverviewSection
                    preferencesSection
                    automationSection
                    dataSection
                    supportSection
                }
                .id(appLanguageStore.language.rawValue)
                .listStyle(.plain)
                .listSectionSpacing(.custom(18))
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
                .contentMargins(.bottom, 88, for: .scrollContent)
                .environment(\.defaultMinListRowHeight, 58)
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: isActive) {
                guard isActive else { return }
                normalizeStrategyNotificationTemplateIfNeeded()
                await reloadNotificationStatus()
            }
            .onChange(of: notificationEnabled) { _, _ in
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    await reloadNotificationStatus()
                }
            }
            .onChange(of: strategyNotificationEnabled) { _, _ in
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    await reloadNotificationStatus()
                }
            }
            .sheet(isPresented: $showsLanguageSelection, onDismiss: applyPendingAppLanguage) {
                AppLanguageSelectionSheet(currentLanguage: currentAppLanguage) { language in
                    pendingAppLanguage = language
                    showsLanguageSelection = false
                }
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsCloudSyncModal) {
                NavigationStack {
                    AssetTimeMachineCloudPage(store: cloudStore)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsStrategyLibrary) {
                AdvancedStrategyLibrarySheet(
                    templates: StrategyRebalanceDefaults.eligibleTemplates,
                    activeTemplateID: selectedStrategyTemplate?.id,
                    titleLocalizationKey: "选择调仓策略"
                ) { template in
                    strategyNotificationTemplateID = template.id
                    showsStrategyLibrary = false
                }
                .presentationDetents([.fraction(0.72), .large])
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

    private var pageOverviewSection: some View {
        Section {
            SettingsPageHeader(
                cloudState: cloudStore.indicatorState,
                cloudAccessibilityLabel: AppLocalization.format(
                    "%@ · %@",
                    AppLocalization.string("云同步"),
                    AppLocalization.string(cloudOverviewKey)
                ),
                onOpenCloud: { showsCloudSyncModal = true }
            )
            .settingsHeaderRow()

            SettingsOverviewRail(
                cloudValue: AppLocalization.string(cloudOverviewKey),
                cloudColor: cloudOverviewColor,
                notificationValue: AppLocalization.string(notificationOverviewKey),
                notificationColor: notificationOverviewColor,
                strategyValue: selectedStrategyTemplate?.title ?? AppLocalization.string("未选择"),
                strategyAccessibilityValue: selectedStrategyTemplate.map(StrategyRebalanceDefaults.pickerTitle)
                    ?? AppLocalization.string("未选择策略"),
                onSelectStrategy: { showsStrategyLibrary = true }
            )
            .settingsHeaderRow()
        }
    }

    private var preferencesSection: some View {
        Section {
            Menu {
                Picker(AppLocalization.string("外观"), selection: $appearanceModeRawValue) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            } label: {
                SettingsNavigationRow(
                    title: AppLocalization.string("外观"),
                    systemImage: "circle.lefthalf.filled",
                    value: currentAppearanceMode.title
                )
            }
            .foregroundStyle(AssetTheme.textPrimary)
            .settingsSurfaceRow()
            .onboardingAnchor(.settingsAppearance)

            Button {
                pendingAppLanguage = nil
                showsLanguageSelection = true
            } label: {
                SettingsNavigationRow(
                    title: AppLocalization.string("语言"),
                    systemImage: "globe",
                    value: currentAppLanguage.title
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(AssetTheme.textPrimary)
            .settingsSurfaceRow()

            Button(action: onReplayOnboarding) {
                SettingsNavigationRow(
                    title: AppLocalization.string("新手引导"),
                    systemImage: "book.closed"
                )
            }
            .buttonStyle(.plain)
            .settingsSurfaceRow()
            .onboardingAnchor(.settingsReplay)
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("偏好"))
        }
    }

    private var automationSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsRowLabel(
                    title: AppLocalization.string("资产播报"),
                    systemImage: "megaphone",
                    subtitle: notificationEnabled ? intervalLabel(notificationIntervalHours) : nil
                )

                Spacer(minLength: 8)

                Toggle("", isOn: $notificationEnabled)
                    .labelsHidden()
                    .tint(AssetTheme.gold)
                    .accessibilityLabel(AppLocalization.string("资产播报"))

                Menu {
                    Picker(AppLocalization.string("播报频率"), selection: $notificationIntervalHours) {
                        ForEach(AssetNotificationService.intervalOptions, id: \.self) { hours in
                            Text(intervalLabel(hours)).tag(hours)
                        }
                    }
                } label: {
                    SettingsDisclosureIcon()
                        .accessibilityLabel(AppLocalization.string("播报频率"))
                        .accessibilityValue(intervalLabel(notificationIntervalHours))
                }
            }
            .settingsSurfaceRow()
            .onboardingAnchor(.settingsNotifications)

            HStack(spacing: 12) {
                SettingsRowLabel(
                    title: AppLocalization.string("每日调仓提醒"),
                    systemImage: "clock",
                    subtitle: strategyNotificationEnabled ? strategyHourLabel(strategyNotificationHour) : nil
                )

                Spacer(minLength: 8)

                Toggle("", isOn: $strategyNotificationEnabled)
                    .labelsHidden()
                    .tint(AssetTheme.gold)
                    .disabled(StrategyRebalanceDefaults.eligibleTemplates.isEmpty)
                    .accessibilityLabel(AppLocalization.string("每日调仓提醒"))

                Menu {
                    Picker(AppLocalization.string("提醒时间"), selection: $strategyNotificationHour) {
                        ForEach(AssetNotificationService.strategyHourOptions, id: \.self) { hour in
                            Text(strategyHourLabel(hour)).tag(hour)
                        }
                    }
                } label: {
                    SettingsDisclosureIcon()
                        .accessibilityLabel(AppLocalization.string("提醒时间"))
                        .accessibilityValue(strategyHourLabel(strategyNotificationHour))
                }
            }
            .settingsSurfaceRow()

            SettingsStrategySummaryRow(template: selectedStrategyTemplate)
                .settingsSurfaceRow()

            if !StrategyRebalanceDefaults.eligibleTemplates.isEmpty {
                Button {
                    sendStrategyTestNotification()
                } label: {
                    SettingsNavigationRow(
                        title: AppLocalization.string("发送测试提醒"),
                        systemImage: "paperplane",
                        showsChevron: false,
                        isLoading: isSendingStrategyTestNotification
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSendingStrategyTestNotification)
                .settingsSurfaceRow()
            }

            if notificationStatus == .denied {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                } label: {
                    SettingsNavigationRow(
                        title: AppLocalization.string("打开系统通知设置"),
                        systemImage: "gearshape",
                        trailingSystemImage: "arrow.up.right.square"
                    )
                }
                .buttonStyle(.plain)
                .settingsSurfaceRow()
            }

            if let strategyTestNotificationMessage {
                SettingsInlineMessage(text: strategyTestNotificationMessage)
                    .settingsSurfaceRow()
            }
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("自动化"))
        }
    }

    private var dataSection: some View {
        Section {
            Button {
                showsCloudSyncModal = true
            } label: {
                SettingsNavigationRow(
                    title: AppLocalization.string("云同步"),
                    systemImage: "icloud",
                    subtitle: cloudAccountSubtitle,
                    value: AppLocalization.string(cloudOverviewKey)
                )
            }
            .buttonStyle(.plain)
            .settingsSurfaceRow()

            if canLogout {
                Button(role: .destructive) {
                    showsLogoutConfirmation = true
                } label: {
                    SettingsNavigationRow(
                        title: AppLocalization.string("退出云同步"),
                        systemImage: "rectangle.portrait.and.arrow.right",
                        tint: AssetTheme.negative,
                        showsChevron: false
                    )
                }
                .foregroundStyle(AssetTheme.negative)
                .disabled(cloudStore.isWorking)
                .settingsSurfaceRow()
            }
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("数据"))
        }
    }

    private var supportSection: some View {
        Section {
            Button {
                guard let appStoreReviewURL else { return }
                openURL(appStoreReviewURL)
            } label: {
                SettingsNavigationRow(
                    title: AppLocalization.string("在 App Store 评分"),
                    systemImage: "star",
                    trailingSystemImage: "arrow.up.right.square"
                )
            }
            .buttonStyle(.plain)
            .settingsSurfaceRow()

            SettingsNavigationRow(
                title: AppLocalization.string("版本"),
                systemImage: "info.circle",
                value: appVersionText,
                showsChevron: false
            )
            .settingsSurfaceRow()
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("支持"))
        }
    }

    @MainActor
    private func applyPendingAppLanguage() {
        guard let pendingAppLanguage else { return }
        self.pendingAppLanguage = nil
        guard pendingAppLanguage != appLanguageStore.language else { return }
        appLanguageStore.select(pendingAppLanguage)
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

private struct SettingsPageHeader: View {
    let cloudState: AssetTimeMachineCloudIndicatorState
    let cloudAccessibilityLabel: String
    let onOpenCloud: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(AppLocalization.string("设置"))
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)

            Spacer(minLength: 12)

            Button(action: onOpenCloud) {
                ZStack {
                    Circle()
                        .fill(AssetTheme.surfaceRaised.opacity(0.62))
                        .overlay(
                            Circle()
                                .stroke(AssetTheme.gold.opacity(0.28), lineWidth: 1)
                        )

                    Image(systemName: cloudState.cloudSymbolName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(cloudState.symbolColor)
                }
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(cloudState.symbolColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(AssetTheme.background, lineWidth: 1.5))
                        .offset(x: -1, y: 1)
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(cloudAccessibilityLabel)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

private struct SettingsOverviewRail: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let cloudValue: String
    let cloudColor: Color
    let notificationValue: String
    let notificationColor: Color
    let strategyValue: String
    let strategyAccessibilityValue: String
    let onSelectStrategy: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    cloudItem
                    SettingsOverviewHorizontalDivider()
                    notificationItem
                    SettingsOverviewHorizontalDivider()
                    strategyItem
                }
            } else {
                HStack(spacing: 0) {
                    cloudItem
                    SettingsOverviewDivider()
                    notificationItem
                    SettingsOverviewDivider()
                    strategyItem
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(AssetTheme.border.opacity(0.78)).frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(AssetTheme.border.opacity(0.78)).frame(height: 0.5)
        }
    }

    private var cloudItem: some View {
        SettingsOverviewItem(
            title: AppLocalization.string("云同步"),
            value: cloudValue,
            systemImage: "icloud",
            tint: cloudColor
        )
    }

    private var notificationItem: some View {
        SettingsOverviewItem(
            title: AppLocalization.string("通知"),
            value: notificationValue,
            systemImage: "bell",
            tint: notificationColor
        )
    }

    private var strategyItem: some View {
        Button(action: onSelectStrategy) {
            SettingsOverviewItem(
                title: AppLocalization.string("策略"),
                value: strategyValue,
                systemImage: "waveform.path.ecg",
                tint: AssetTheme.gold,
                accessorySystemImage: "chevron.down"
            )
        }
        .buttonStyle(.plain)
        .disabled(StrategyRebalanceDefaults.eligibleTemplates.isEmpty)
        .accessibilityLabel(AppLocalization.string("调仓策略"))
        .accessibilityValue(strategyAccessibilityValue)
    }
}

private struct SettingsOverviewItem: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    var accessorySystemImage: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(AssetTheme.textPrimary)
                .frame(width: 24, height: 38, alignment: .top)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }

            if let accessorySystemImage {
                Image(systemName: accessorySystemImage)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                    .frame(height: 38, alignment: .center)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(minHeight: 36, alignment: .top)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsOverviewDivider: View {
    var body: some View {
        Rectangle()
            .fill(AssetTheme.border.opacity(0.8))
            .frame(width: 0.5, height: 44)
    }
}

private struct SettingsOverviewHorizontalDivider: View {
    var body: some View {
        Rectangle()
            .fill(AssetTheme.border.opacity(0.8))
            .frame(height: 0.5)
            .padding(.horizontal, 6)
    }
}

private struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AssetTheme.textSecondary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.bottom, 5)
    }
}

private struct SettingsNavigationRow: View {
    let title: String
    let systemImage: String
    var subtitle: String? = nil
    var value: String? = nil
    var tint: Color = AssetTheme.textPrimary
    var showsChevron = true
    var trailingSystemImage: String? = nil
    var isLoading = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowLabel(
                title: title,
                systemImage: systemImage,
                tint: tint,
                subtitle: subtitle
            )

            Spacer(minLength: 10)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(AssetTheme.gold)
            } else if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(AppTypography.metaStrong)
                    .foregroundStyle(AssetTheme.textSecondary)
            } else if showsChevron {
                SettingsDisclosureIcon()
            }
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

private struct SettingsStrategySummaryRow: View {
    let template: AdvancedBacktestStrategyTemplate?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AssetTheme.textPrimary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.string("当前策略"))
                    .font(.body.weight(.medium))
                    .foregroundStyle(AssetTheme.textPrimary)

                HStack(spacing: 6) {
                    Text(template?.title ?? AppLocalization.string("暂无策略"))
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(2)

                    if let template,
                       BacktestProductStrategyCatalog.isCuratedTemplateID(template.id) {
                        CuratedStrategyBadge(compact: true)
                    }
                }
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 68)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    var tint: Color = AssetTheme.textPrimary
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(tint)
                    .lineLimit(2)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct SettingsDisclosureIcon: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AssetTheme.textSecondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private struct SettingsInlineMessage: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle")
                .font(AppTypography.metaStrong)
                .foregroundStyle(AssetTheme.gold)

            Text(text)
                .font(AppTypography.caption)
                .foregroundStyle(AssetTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}

private extension View {
    func settingsHeaderRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func settingsSurfaceRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
            .listRowBackground(AssetTheme.surface.opacity(0.48))
            .listRowSeparatorTint(AssetTheme.border.opacity(0.82))
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
