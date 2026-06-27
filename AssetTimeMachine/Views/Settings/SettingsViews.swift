import SwiftUI
import SwiftData
import Charts
import UIKit

struct SettingsView: View {
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
    @Query private var snapshots: [AssetSnapshot]
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showsLogoutConfirmation = false

    init(cloudStore: AssetTimeMachineCloudStore, onReplayOnboarding: @escaping () -> Void) {
        self.cloudStore = cloudStore
        self.onReplayOnboarding = onReplayOnboarding

        var descriptor = FetchDescriptor<AssetSnapshot>(
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        _snapshots = Query(descriptor)
    }

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
            return AppLocalization.string("根据最新行情和资产记录生成调仓提醒。")
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
                                        if cloudStore.hasCompletedInitialSync {
                                            if let email = currentUser.userEmail, !email.isEmpty {
                                                Text(email)
                                                    .font(.caption)
                                                    .foregroundStyle(AssetTheme.textSecondary)
                                            } else {
                                                Text(AppLocalization.string("云同步已完成"))
                                                    .font(.caption)
                                                    .foregroundStyle(AssetTheme.textSecondary)
                                            }
                                        } else {
                                            Text(AppLocalization.string("等待首次云同步"))
                                                .font(.caption)
                                                .foregroundStyle(AssetTheme.goldSoft)
                                        }
                                    }
                                } else {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(cloudStore.isSessionPending ? AppLocalization.string("正在恢复登录") : AppLocalization.string("登录凭证已保存"))
                                            .foregroundStyle(AssetTheme.textPrimary)
                                        Text(AppLocalization.string("正在验证云同步状态"))
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                )

            Text(AppLocalization.string(title))
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

struct SnapshotCategoryItems: Identifiable {
    let category: AssetCategory
    let items: [AssetItem]

    var id: UUID { category.id }
}
