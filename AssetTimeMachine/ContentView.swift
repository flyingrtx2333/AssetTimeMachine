import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers
import UIKit
import UserNotifications

private enum AppTab: Hashable {
    case dashboard
    case snapshots
    case timeMachine
    case backtest
    case settings
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @AppStorage("app.notifications.enabled") private var notificationEnabled = false
    @AppStorage("app.notifications.intervalHours") private var notificationIntervalHours: Double = 1
    @StateObject private var marketStore = RemoteMarketStore()
    @StateObject private var cloudStore = AssetTimeMachineCloudStore()
    @State private var selectedTab: AppTab = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-openTimeMachineTab") {
            return .timeMachine
        }
        if arguments.contains("-openSnapshotsTab") {
            return .snapshots
        }
        if arguments.contains("-openBacktestTab") {
            return .backtest
        }
        if arguments.contains("-openSettingsTab") {
            return .settings
        }
        return .dashboard
    }()
    @State private var didRunStartup = false

    private var notificationSnapshot: AssetSnapshot? {
        snapshots.first(where: { Calendar.current.isDateInToday($0.date) }) ?? snapshots.first
    }

    private var notificationRefreshToken: String {
        guard let notificationSnapshot else { return "empty" }
        return "\(notificationSnapshot.id.uuidString)-\(notificationSnapshot.updatedAt.timeIntervalSinceReferenceDate)"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(cloudStore: cloudStore)
                .tabItem {
                    Label("首页", systemImage: "house")
                }
                .tag(AppTab.dashboard)

            SnapshotListView(marketStore: marketStore)
                .tabItem {
                    Label("记录", systemImage: "square.and.pencil")
                }
                .tag(AppTab.snapshots)

            TimeMachineView(marketStore: marketStore, isActive: selectedTab == .timeMachine)
                .tabItem {
                    Label("时光机", systemImage: "clock.arrow.circlepath")
                }
                .tag(AppTab.timeMachine)

            BacktestView(marketStore: marketStore)
                .tabItem {
                    Label("回测", systemImage: "chart.xyaxis.line")
                }
                .tag(AppTab.backtest)

            SettingsView(cloudStore: cloudStore)
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        .tint(AssetTheme.gold)
        .task {
            await runStartupIfNeeded()
            await cloudStore.refreshIfNeeded(from: modelContext)
            await refreshAssetNotifications()
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

    @MainActor
    private func runStartupIfNeeded() async {
        guard !didRunStartup else { return }
        didRunStartup = true

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

        try? SeedDataService.ensureDefaultFinancialItems(in: modelContext)
        try? AssetItemService.migrateLegacyAutoPricedItemsIfNeeded(in: modelContext)
        await marketStore.refresh()
        await SnapshotAnchorService.backfillIfNeeded(in: modelContext)
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

    private func launchArgumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

private struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("dashboard.monthlyExpense") private var monthlyExpense: Double = 3000
    @AppStorage("dashboard.monthlyExpenseSeedVersion") private var monthlyExpenseSeedVersion: Int = 0
    @AppStorage("dashboard.inflationRate") private var inflationRate: Double = 0.05
    @AppStorage("dashboard.inflationRateSeedVersion") private var inflationRateSeedVersion: Int = 0
    @ObservedObject var cloudStore: AssetTimeMachineCloudStore
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @Query private var items: [AssetItem]
    @Query private var categories: [AssetCategory]

    private var latestSnapshot: AssetSnapshot? { snapshots.first }

    private var totalAssets: Double {
        latestSnapshot.map { PortfolioCalculator.totalAssets(for: $0) } ?? 0
    }

    private var totalLiabilities: Double {
        latestSnapshot.map { PortfolioCalculator.totalLiabilities(for: $0) } ?? 0
    }

    private var netAssets: Double {
        totalAssets - totalLiabilities
    }

    private var latestEntryCount: Int {
        latestSnapshot?.entries.count ?? 0
    }

    private var allocationSlices: [DashboardAllocationSlice] {
        guard let latestSnapshot else { return [] }

        let grouped = Dictionary(grouping: latestSnapshot.entries.filter {
            ($0.item?.category?.group ?? .financial) != .liability && $0.resolvedAmount > 0
        }) { entry in
            entry.item?.name ?? "未命名"
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
                        title: "其他",
                        amount: otherAmount,
                        color: DashboardAllocationPalette.colors[slices.count % DashboardAllocationPalette.colors.count],
                        details: otherDetails
                    )
                )
            }
        }

        return slices
    }

    private var trendPoints: [TimeMachineTrendPoint] {
        let basePoints = snapshots.reversed().map { snapshot in
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

        let filteredPoints = TimeMachineRange.oneYear.filter(basePoints)
        return filteredPoints.count >= 2 ? filteredPoints : basePoints
    }

    private var latestTrendPoint: TimeMachineTrendPoint? {
        trendPoints.last
    }

    private var freedomProjection: FinancialFreedomProjection? {
        FinancialFreedomEstimator.estimate(
            points: trendPoints,
            monthlyExpense: monthlyExpense,
            annualInflationRate: inflationRate
        )
    }

    private var autoSyncTrigger: String {
        let latestSnapshotUpdate = snapshots.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let latestItemUpdate = items.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        return [
            String(categories.count),
            String(items.count),
            String(snapshots.count),
            String(latestEntryCount),
            String(Int(latestSnapshotUpdate)),
            String(Int(latestItemUpdate))
        ].joined(separator: ":")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        summaryStrip
                        trendSection
                        freedomSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 172)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                migrateDashboardDefaultsIfNeeded()
                await cloudStore.refreshIfNeeded(from: modelContext)
            }
            .onChange(of: autoSyncTrigger) { _, _ in
                Task {
                    await cloudStore.autoSyncIfNeeded(from: modelContext, quietly: true)
                }
            }
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
    }

    private var summaryStrip: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                NavigationLink {
                    AssetTimeMachineCloudPage(store: cloudStore)
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
            }

            Rectangle()
                .fill(AssetTheme.border.opacity(0.55))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var trendSection: some View {
        if let latestTrendPoint, trendPoints.count >= 2 {
            DashboardTrendCard(
                points: trendPoints,
                latestPoint: latestTrendPoint
            )
        } else {
            EmptyStateCard(
                title: "还没有趋势数据",
                message: "至少需要两条资产快照，首页这里才会长出走势折线图。",
                systemImage: "chart.line.uptrend.xyaxis"
            )
        }
    }

    private var freedomSection: some View {
        DashboardFreedomSection(
            projection: freedomProjection,
            monthlyExpense: $monthlyExpense,
            inflationRate: $inflationRate
        )
    }

}

private struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("app.appearanceMode") private var appearanceModeRawValue: String = AppAppearanceMode.system.rawValue
    @AppStorage("app.notifications.enabled") private var notificationEnabled = false
    @AppStorage("app.notifications.intervalHours") private var notificationIntervalHours: Double = 1
    @ObservedObject var cloudStore: AssetTimeMachineCloudStore
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showsLogoutConfirmation = false

    private var latestSnapshot: AssetSnapshot? {
        snapshots.first(where: { Calendar.current.isDateInToday($0.date) }) ?? snapshots.first
    }

    private var notificationPreview: String {
        guard let latestSnapshot else { return "暂无资产记录" }

        return "总资产 \(PortfolioCalculator.totalAssets(for: latestSnapshot).currencyString()) · 净资产 \(PortfolioCalculator.netAssets(for: latestSnapshot).currencyString()) · 负债 \(PortfolioCalculator.totalLiabilities(for: latestSnapshot).currencyString())"
    }

    private var canLogout: Bool {
        cloudStore.currentUser != nil || cloudStore.hasToken
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
            return "未知版本"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("外观")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(AssetTheme.textPrimary)

                            Picker("外观", selection: $appearanceModeRawValue) {
                                ForEach(AppAppearanceMode.allCases) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .atmCardStyle()

                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .center, spacing: 12) {
                                Text("定时资产播报")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(AssetTheme.textPrimary)

                                Spacer(minLength: 12)

                                Toggle("定时资产播报", isOn: $notificationEnabled)
                                    .labelsHidden()
                                    .tint(AssetTheme.gold)
                            }

                            HStack {
                                Text("播报间隔")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AssetTheme.textPrimary)
                                Spacer()
                                Picker("播报间隔", selection: $notificationIntervalHours) {
                                    ForEach(AssetNotificationService.intervalOptions, id: \.self) { hours in
                                        Text(intervalLabel(hours)).tag(hours)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(AssetTheme.gold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("播报预览")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AssetTheme.textPrimary)
                                Text(notificationPreview)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(AssetTheme.textSecondary)
                                    .monospacedDigit()
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }

                            if notificationStatus == .denied {
                                Button("打开系统通知设置") {
                                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                    openURL(url)
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AssetTheme.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(AssetTheme.overlayMedium, in: Capsule())
                            }
                        }
                        .atmCardStyle()

                        if canLogout {
                            VStack(alignment: .leading, spacing: 0) {
                                Button(role: .destructive) {
                                    showsLogoutConfirmation = true
                                } label: {
                                    HStack {
                                        Text("退出登录")
                                            .font(.headline.weight(.bold))
                                        Spacer()
                                        Image(systemName: "rectangle.portrait.and.arrow.right")
                                            .font(.system(size: 16, weight: .semibold))
                                    }
                                    .foregroundStyle(AssetTheme.negative)
                                    .padding(.horizontal, 2)
                                }
                                .buttonStyle(.plain)
                            }
                            .atmCardStyle()
                        }

                        HStack(spacing: 12) {
                            Text("当前版本")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AssetTheme.textPrimary)

                            Spacer()

                            Text(appVersionText)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AssetTheme.textSecondary)
                                .monospacedDigit()
                        }
                        .atmCardStyle()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("设置")
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
            .alert("退出登录", isPresented: $showsLogoutConfirmation) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) {
                    cloudStore.logout()
                }
            } message: {
                Text("退出后将停止云同步。")
            }
        }
    }

    private func intervalLabel(_ hours: Double) -> String {
        let integer = Int(hours)
        return integer == 24 ? "每天一次" : "每 \(integer) 小时"
    }

    private func reloadNotificationStatus() async {
        notificationStatus = await AssetNotificationService.authorizationStatus()
    }
}

private struct SnapshotListView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var marketStore: RemoteMarketStore
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @Query private var categories: [AssetCategory]

    @State private var currentSnapshotID: UUID?
    @State private var amountInputs: [UUID: String] = [:]
    @State private var quantityInputs: [UUID: String] = [:]
    @State private var unitPriceInputs: [UUID: String] = [:]
    @State private var didPrepare = false
    @State private var showsAddAssetItemSheet = ProcessInfo.processInfo.arguments.contains("-openAddAssetItemSheet")
    @State private var editingAssetItem: AssetItem?
    @State private var quickEditingAssetItem: AssetItem?
    @State private var focusedField: RecordInputField?

    private let recordKeyboardSelfTestEnabled = ProcessInfo.processInfo.arguments.contains("-recordKeyboardSelfTest")
    private let recordEditPreviewEnabled = ProcessInfo.processInfo.arguments.contains("-openRecordEditPreview")
    private let recordQuickEditPreviewSelection = SnapshotListView.launchArgumentValue(after: "-openRecordQuickEditPreview")

    private let liabilitySectionTitleMap: [String: String] = [
        "长期负债": "长期负债",
        "短期负债": "短期负债"
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
        nonLiabilityCategories
            .flatMap(\.activeSortedItems)
            .reduce(0) { $0 + (displayEntry(for: $1)?.resolvedAmount ?? 0) }
    }

    private var displayedTotalLiabilities: Double {
        liabilityCategories
            .flatMap(\.activeSortedItems)
            .reduce(0) { $0 + (displayEntry(for: $1)?.resolvedAmount ?? 0) }
    }

    private var displayedNetAssets: Double {
        displayedTotalAssets - displayedTotalLiabilities
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        if let currentSnapshot {
                            RecordPageHero(
                                snapshot: currentSnapshot,
                                totalAssets: displayedTotalAssets,
                                netAssets: displayedNetAssets,
                                totalLiabilities: displayedTotalLiabilities,
                                onAddAsset: {
                                    dismissKeyboard()
                                    showsAddAssetItemSheet = true
                                }
                            )
                            .padding(.bottom, 2)

                            ForEach(nonLiabilityCategories) { category in
                                RecordCategoryCard(
                                    category: category,
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

                            ForEach(liabilityCategories) { category in
                                LiabilityCategorySection(
                                    category: category,
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

                            NavigationLink {
                                SnapshotArchiveView()
                            } label: {
                                HStack(spacing: 10) {
                                    Text("全部资产记录")
                                        .font(.headline)
                                        .foregroundStyle(AssetTheme.textPrimary)

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                                .padding(.vertical, 12)
                                .overlay(alignment: .top) {
                                    Rectangle()
                                        .fill(AssetTheme.border.opacity(0.55))
                                        .frame(height: 1)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            EmptyStateCard(
                                title: "暂无记录",
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
            if let item = quickEditingAssetItem {
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
                                hydrateInputs(from: snapshot)
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
            await syncAutoRatesIfPossible()
        }
        .onChange(of: marketStore.exchangeRates) { _, _ in
            Task { @MainActor in
                await syncAutoRatesIfPossible()
            }
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

        do {
            try SeedDataService.seedDefaultCategoriesIfNeeded(in: modelContext)
            let snapshot = try SnapshotService.createSnapshot(on: .now, inheritPrevious: true, createMissingEntries: true, in: modelContext)
            currentSnapshotID = snapshot.id
            hydrateInputs(from: snapshot)
            if recordKeyboardSelfTestEnabled, let selfTestField = recordKeyboardSelfTestField() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    focusedField = selfTestField
                    NSLog("[ATMKeyboardSelfTest] primed focus for %@", String(describing: selfTestField))
                }
            }
            if recordEditPreviewEnabled, let previewItem = recordEditPreviewItem() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    editingAssetItem = previewItem
                }
            }
            if let previewSelection = recordQuickEditPreviewSelection,
               let previewItem = recordQuickEditPreviewItem(selection: previewSelection) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                    quickEditingAssetItem = previewItem
                }
            }
            await SnapshotAnchorService.captureLiveAnchorsIfPossible(for: snapshot, marketStore: marketStore, in: modelContext)
        } catch {
            print("[AssetTimeMachine] prepare snapshot failed: \(error)")
        }
    }

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
    private func syncAutoRatesIfPossible() async {
        guard let snapshot = currentSnapshot else { return }

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
                do {
                    try SnapshotService.upsertEntry(
                        snapshot: snapshot,
                        item: item,
                        quantity: normalizedNumber(from: quantityInputs[item.id]),
                        unitPrice: rate,
                        in: modelContext
                    )
                } catch {
                    print("[AssetTimeMachine] sync auto rate failed: \(error)")
                }
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

    private func recordKeyboardSelfTestField() -> RecordInputField? {
        for category in nonLiabilityCategories {
            for item in category.activeSortedItems {
                switch item.valuationMethod {
                case .directAmount:
                    return .amount(item.id)
                case .quantityAndUnitPrice:
                    return .quantity(item.id)
                }
            }
        }

        for category in liabilityCategories {
            for item in category.activeSortedItems {
                switch item.valuationMethod {
                case .directAmount:
                    return .amount(item.id)
                case .quantityAndUnitPrice:
                    return .quantity(item.id)
                }
            }
        }

        return nil
    }

    private func recordEditPreviewItem() -> AssetItem? {
        nonLiabilityCategories
            .flatMap(\.activeSortedItems)
            .first(where: { $0.valuationMethod == .quantityAndUnitPrice })
        ?? nonLiabilityCategories.flatMap(\.activeSortedItems).first
        ?? liabilityCategories.flatMap(\.activeSortedItems).first
    }

    private func recordQuickEditPreviewItem(selection: String) -> AssetItem? {
        let normalized = selection.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let assetItems = nonLiabilityCategories.flatMap(\.activeSortedItems)
        let liabilityItems = liabilityCategories.flatMap(\.activeSortedItems)

        switch normalized {
        case "amount", "asset", "direct":
            return assetItems.first(where: { $0.valuationMethod == .directAmount })
        case "manual", "quantity", "manualprice":
            return assetItems.first(where: { $0.valuationMethod == .quantityAndUnitPrice && $0.resolvedAutoPricedAssetKind == nil })
        case "auto", "autopriced", "market":
            return assetItems.first(where: { $0.valuationMethod == .quantityAndUnitPrice && $0.resolvedAutoPricedAssetKind != nil })
        case "liability", "debt":
            return liabilityItems.first(where: { $0.valuationMethod == .directAmount })
                ?? liabilityItems.first
        default:
            return recordEditPreviewItem()
        }
    }

    private static func launchArgumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func displayEntry(for item: AssetItem) -> AssetEntry? {
        if let currentSnapshot,
           let snapshotEntry = currentSnapshot.entries.first(where: { $0.item?.id == item.id }),
           snapshotEntry.amount != nil || snapshotEntry.quantity != nil || snapshotEntry.unitPrice != nil {
            return snapshotEntry
        }

        return item.entries.sorted(by: { ($0.snapshot?.date ?? .distantPast) > ($1.snapshot?.date ?? .distantPast) }).first
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

private struct RecordPageHero: View {
    let snapshot: AssetSnapshot
    let totalAssets: Double
    let netAssets: Double
    let totalLiabilities: Double
    let onAddAsset: () -> Void

    private var netAssetColor: Color {
        netAssets < 0 ? AssetTheme.negative : AssetTheme.textPrimary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("总资产")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AssetTheme.textSecondary)

                    Text(totalAssets.currencyString())
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(AssetTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .monospacedDigit()
                }

                HStack(spacing: 8) {
                    heroSummaryText(title: "净资产", value: netAssets.currencyString(), valueColor: netAssetColor)

                    Circle()
                        .fill(AssetTheme.border.opacity(0.8))
                        .frame(width: 3, height: 3)

                    heroSummaryText(title: "负债", value: totalLiabilities.currencyString(), valueColor: AssetTheme.negative.opacity(0.9))
                }
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

                Text(snapshot.date.recordDateString)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AssetTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onAddAsset) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                    Text("资产类型")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(AssetTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AssetTheme.overlaySoft, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(AssetTheme.border.opacity(0.55), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func heroSummaryText(title: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .foregroundStyle(valueColor)
                .monospacedDigit()
        }
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

private struct RecordCategoryCard: View {
    private let inputWidth: CGFloat = 80

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
    @ObservedObject var marketStore: RemoteMarketStore
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    @Binding var unitPriceInputs: [UUID: String]
    @Binding var focusedField: RecordInputField?
    let onEdit: (AssetItem) -> Void
    let onEditValue: (AssetItem) -> Void
    @State private var draggedItemID: UUID?

    private let compactColumns = [
        GridItem(.flexible(), spacing: 8, alignment: .top),
        GridItem(.flexible(), spacing: 8, alignment: .top)
    ]

    private var items: [AssetItem] {
        category.activeSortedItems
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

    private var categoryTotal: Double {
        items.reduce(0) { partialResult, item in
            partialResult + item.entries.reduce(0) { $0 + $1.resolvedAmount }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(category.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                Spacer(minLength: 8)
                Text(categoryTotal.currencyString())
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            VStack(spacing: 10) {
                ForEach(inputBlocks) { block in
                    switch block {
                    case let .compact(compactItems):
                        LazyVGrid(columns: compactColumns, alignment: .leading, spacing: 8) {
                            ForEach(compactItems) { item in
                                ReorderableRecordCell(category: category, item: item, draggedItemID: $draggedItemID) {
                                    AssetEntryCompactCard(
                                        item: item,
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
                    case let .expanded(item):
                        ReorderableRecordCell(category: category, item: item, draggedItemID: $draggedItemID) {
                            AssetEntryInputRow(
                                item: item,
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

private struct LiabilityCategorySection: View {
    private let inputWidth: CGFloat = 80

    let category: AssetCategory
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    @Binding var focusedField: RecordInputField?
    let onEdit: (AssetItem) -> Void
    let onEditValue: (AssetItem) -> Void
    @State private var draggedItemID: UUID?

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    private var items: [AssetItem] {
        category.activeSortedItems
    }

    private var categoryTotal: Double {
        items.reduce(0) { partialResult, item in
            partialResult + item.entries.reduce(0) { $0 + $1.resolvedAmount }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(category.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                Spacer(minLength: 8)
                Text(categoryTotal.currencyString())
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.negative)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    ReorderableRecordCell(category: category, item: item, draggedItemID: $draggedItemID) {
                        LiabilityEntryCard(
                            item: item,
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
                }
            }
        }
    }
}

private struct LiabilityEntryCard: View {
    let item: AssetItem
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

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button {
                onEdit()
            } label: {
                HStack(alignment: .center, spacing: 6) {
                    AssetItemGlyph(item: item, accent: AssetTheme.negative, size: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AssetTheme.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.textPrimary)
                        .frame(width: inputWidth, alignment: .trailing)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private var displayValue: String {
        if item.valuationMethod == .directAmount {
            if !amountText.isEmpty { return amountText }
            if let latestAmount = item.entries.sorted(by: { ($0.snapshot?.date ?? .distantPast) > ($1.snapshot?.date ?? .distantPast) }).first?.amount {
                return latestAmount.plainNumberString()
            }
        } else {
            if !quantityText.isEmpty { return quantityText }
            if let latestQuantity = item.entries.sorted(by: { ($0.snapshot?.date ?? .distantPast) > ($1.snapshot?.date ?? .distantPast) }).first?.quantity {
                return latestQuantity.plainNumberString()
            }
        }
        return "--"
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
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    @ObservedObject var marketStore: RemoteMarketStore
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

    var body: some View {
        RecordInputCard {
            HStack(alignment: .center, spacing: 4) {
                Button {
                    onEdit()
                } label: {
                    HStack(alignment: .center, spacing: 4) {
                        AssetItemGlyph(item: item, size: 12)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AssetTheme.textPrimary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isEditing {
                    if item.valuationMethod == .directAmount {
                        ATMInputField(text: $amountText, placeholder: "0", width: inputWidth, focusedField: $focusedField, focusValue: .amount(item.id), centered: true, fontSize: 12, fontWeight: .medium, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                    } else {
                        ATMInputField(text: $quantityText, placeholder: "0", width: inputWidth, focusedField: $focusedField, focusValue: .quantity(item.id), centered: true, fontSize: 12, fontWeight: .medium, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                    }
                } else {
                    Button {
                        onEditValue()
                    } label: {
                        Text(displayValue)
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(AssetTheme.textPrimary)
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
            if let latestAmount = item.entries.sorted(by: { ($0.snapshot?.date ?? .distantPast) > ($1.snapshot?.date ?? .distantPast) }).first?.amount {
                return latestAmount.plainNumberString()
            }
        } else {
            if !quantityText.isEmpty { return quantityText }
            if let latestQuantity = item.entries.sorted(by: { ($0.snapshot?.date ?? .distantPast) > ($1.snapshot?.date ?? .distantPast) }).first?.quantity {
                return latestQuantity.plainNumberString()
            }
        }
        return "--"
    }
}

private struct AssetEntryInputRow: View {
    let item: AssetItem
    @ObservedObject var marketStore: RemoteMarketStore
    @Binding var amountText: String
    @Binding var quantityText: String
    @Binding var unitPriceText: String
    @Binding var focusedField: RecordInputField?
    let inputWidth: CGFloat
    let onEdit: () -> Void
    let onEditValue: () -> Void

    private var isEditing: Bool {
        focusedField == .quantity(item.id) || focusedField == .unitPrice(item.id)
    }

    var body: some View {
        RecordInputCard {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    onEdit()
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        AssetItemGlyph(item: item, size: 12)

                        HStack(alignment: .center, spacing: 6) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AssetTheme.textPrimary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {

                    if isEditing {
                        HStack(spacing: 6) {
                            ATMInputField(text: $quantityText, placeholder: item.autoPricedAssetKind == nil ? "数量" : "金额", width: inputWidth, focusedField: $focusedField, focusValue: .quantity(item.id), centered: true, fontSize: 12, fontWeight: .medium, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                        }
                    } else {
                        HStack(spacing: 12) {
                            Button {
                                onEditValue()
                            } label: {
                                recordValueLabel(title: item.autoPricedAssetKind == nil ? "数量" : "金额", value: quantityText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var latestEntry: AssetEntry? {
        item.entries.sorted(by: { ($0.snapshot?.date ?? .distantPast) > ($1.snapshot?.date ?? .distantPast) }).first
    }

    @ViewBuilder
    private func recordValueLabel(title: String, value: String) -> some View {
        let fallbackValue = (title == "数量" || title == "金额")
            ? (latestEntry?.quantity?.plainNumberString() ?? "--")
            : (latestEntry?.unitPrice?.plainNumberString() ?? "--")

        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value.isEmpty ? fallbackValue : value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textPrimary)
        }
        .frame(width: inputWidth, alignment: .trailing)
    }
}

private struct AutoPriceInlineLabel: View {
    let item: AssetItem
    @ObservedObject var marketStore: RemoteMarketStore

    private var priceText: String? {
        item.autoPriceDisplayText(using: marketStore)
    }

    var body: some View {
        if let priceText {
            Text(priceText)
                .font(.caption2.weight(.regular))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.goldSoft)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(AssetTheme.overlaySubtle, in: Capsule())
        }
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

    private static let recordKeyboardSelfTestEnabled = ProcessInfo.processInfo.arguments.contains("-recordKeyboardSelfTest")

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
            string: placeholder,
            attributes: [.foregroundColor: UIColor(AssetTheme.textSecondary)]
        )

        let shouldBeFirstResponder = focusedField == focusValue
        if shouldBeFirstResponder, !uiView.isFirstResponder {
            context.coordinator.isSyncingFirstResponder = true
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
                context.coordinator.moveCaretToEnd(in: uiView)
                context.coordinator.maybeRunSelfTest(on: uiView)
            }
        } else if shouldBeFirstResponder {
            context.coordinator.maybeRunSelfTest(on: uiView)
        } else if !shouldBeFirstResponder, uiView.isFirstResponder {
            context.coordinator.isSyncingFirstResponder = true
            DispatchQueue.main.async {
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
        var didRunSelfTestInsertion = false
        var didScheduleSelfTestInsertion = false

        init(parent: ATMUIKitInputField) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            parent.text = textField.text ?? ""
            moveCaretToEnd(in: textField)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isSyncingFirstResponder = false
            parent.focusedField = parent.focusValue
            moveCaretToEnd(in: textField)
            maybeRunSelfTest(on: textField)
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            moveCaretToEnd(in: textField)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            defer { isSyncingFirstResponder = false }

            guard !isBeingDismantled else { return }
            guard !isSyncingFirstResponder else { return }
            guard parent.focusedField == parent.focusValue else { return }

            parent.focusedField = nil
        }

        func maybeRunSelfTest(on textField: UITextField) {
            guard ATMUIKitInputField.recordKeyboardSelfTestEnabled, !didScheduleSelfTestInsertion, !didRunSelfTestInsertion else { return }
            didScheduleSelfTestInsertion = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard textField.window != nil else {
                    NSLog("[ATMKeyboardSelfTest] skipped insert because textField left window for %@", String(describing: self.parent.focusValue))
                    self.didScheduleSelfTestInsertion = false
                    return
                }
                if !textField.isFirstResponder {
                    textField.becomeFirstResponder()
                }
                self.didRunSelfTestInsertion = true
                textField.insertText("1")
                NSLog("[ATMKeyboardSelfTest] inserted digit into %@, text=%@", String(describing: self.parent.focusValue), textField.text ?? "")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSLog("[ATMKeyboardSelfTest] after first insert focus=%@ firstResponder=%@ text=%@ inWindow=%@", String(describing: self.parent.focusedField), textField.isFirstResponder ? "true" : "false", textField.text ?? "", textField.window != nil ? "true" : "false")
                    guard textField.window != nil, textField.isFirstResponder else { return }
                    textField.insertText("2")
                    NSLog("[ATMKeyboardSelfTest] inserted second digit into %@, text=%@", String(describing: self.parent.focusValue), textField.text ?? "")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        NSLog("[ATMKeyboardSelfTest] after second insert focus=%@ firstResponder=%@ text=%@ inWindow=%@", String(describing: self.parent.focusedField), textField.isFirstResponder ? "true" : "false", textField.text ?? "", textField.window != nil ? "true" : "false")
                    }
                }
            }
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
                        Text("名称")
                            .font(.headline)
                            .foregroundStyle(AssetTheme.textPrimary)

                        TextField("例如：银行卡、房产、车辆", text: $name)
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
                        Text("归类")
                            .font(.headline)
                            .foregroundStyle(AssetTheme.textPrimary)

                        Picker("归类", selection: Binding(
                            get: { selectedCategoryID ?? sortedCategories.first?.id },
                            set: { selectedCategoryID = $0 }
                        )) {
                            ForEach(sortedCategories) { category in
                                Text(category.name).tag(Optional.some(category.id))
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

                Text("图标")
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
                                    Text(option.label)
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
                Text("特殊资产")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)

                Text(isAutoPricedLocked ? "当前资产已绑定自动价格类型，如需变更可新建一个资产类型。" : "下列资产可填写数量，价格会自动更新。")
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
                            Text("普通资产")
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
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text("添加资产类型")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
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
            errorMessage = "保存失败，请稍后再试"
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
            return isLiability ? "负债数额" : "资产数额"
        case .quantityAndUnitPrice:
            return item.autoPricedAssetKind == nil ? "数量" : "金额"
        }
    }

    private var displayedUnitPriceText: String? {
        let trimmed = unitPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private var trailingUnitPriceTitle: String? {
        guard item.valuationMethod == .quantityAndUnitPrice else { return nil }
        return item.autoPricedAssetKind == nil ? "单价" : "参考单价"
    }

    private var trailingUnitPriceValue: String? {
        guard item.valuationMethod == .quantityAndUnitPrice else { return nil }
        if item.autoPricedAssetKind != nil,
           let rate = item.resolvedAutoUnitPrice(using: marketStore) {
            return rate.currencyString()
        }
        return displayedUnitPriceText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                chromeButton(title: "取消", tint: AssetTheme.textSecondary, action: onCancel)

                Spacer(minLength: 8)

                Text("修改本次记录")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                chromeButton(title: "保存", tint: AssetTheme.gold, action: save)
            }

            HStack(alignment: .center, spacing: 12) {
                AssetItemGlyph(item: item, accent: isLiability ? AssetTheme.negative : AssetTheme.gold, size: 18)

                Text(item.name)
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
                    }
                }
            }

            quickEditField(
                title: primaryFieldTitle,
                text: bindingForPrimaryField(),
                placeholder: "输入\(primaryFieldTitle)",
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
        .onTapGesture {
            dismissActiveKeyboard()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                focusedField = .primary
            }
        }
    }

    @ViewBuilder
    private func quickEditField(title: String, text: Binding<String>, placeholder: String, focus: QuickRecordValueField) -> some View {
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
        Button(title, action: action)
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
            errorMessage = "还没拿到今天这条记录，稍后再试"
            return
        }

        do {
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
                        ?? item.entries.sorted(by: { ($0.snapshot?.date ?? .distantPast) > ($1.snapshot?.date ?? .distantPast) }).first?.unitPrice
                }
                try SnapshotService.upsertEntry(snapshot: snapshot, item: item, quantity: quantity, unitPrice: unitPrice, in: modelContext)
            }

            onSaved()
        } catch let error as QuickRecordValueValidationError {
            errorMessage = error.message
        } catch {
            errorMessage = "保存失败，请稍后再试"
            print("[AssetTimeMachine] quick record save failed: \(error)")
        }
    }

    private func validatedNumber(from text: String, forcePositive: Bool = false, fieldName: String) throws -> Double? {
        let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let value = Double(raw) else {
            throw QuickRecordValueValidationError(message: "\(fieldName)请输入有效数字")
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
                                Text("本次记录")
                                    .font(.headline)
                                    .foregroundStyle(AssetTheme.textPrimary)

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("数量")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AssetTheme.textSecondary)
                                    TextField("输入数量", text: $recordQuantityText)
                                        .keyboardType(.decimalPad)
                                        .textFieldStyle(.plain)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(AssetTheme.textPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(AssetTheme.overlayMedium, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("单价")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AssetTheme.textSecondary)
                                    TextField("输入单价", text: $recordUnitPriceText)
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
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text("编辑资产类型")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
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
            errorMessage = "保存失败，请稍后再试"
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
            Text(title)
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
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(snapshots) { snapshot in
                        NavigationLink {
                            SnapshotDetailView(snapshot: snapshot)
                        } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text(snapshot.date.longDateString)
                                        .font(.headline)
                                        .foregroundStyle(AssetTheme.textPrimary)
                                    Spacer()
                                    GoldChip(text: "\(snapshot.entries.count) 项")
                                }

                                HStack(spacing: 12) {
                                    CompactStat(title: "净资产", value: PortfolioCalculator.netAssets(for: snapshot).currencyString(), accent: AssetTheme.gold)
                                    CompactStat(title: "负债", value: PortfolioCalculator.totalLiabilities(for: snapshot).currencyString(), accent: AssetTheme.negative)
                                }
                            }
                            .atmCardStyle()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
    }
}

private struct SnapshotDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: AssetSnapshot

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
                            CompactStat(title: "资产", value: PortfolioCalculator.totalAssets(for: snapshot).currencyString(), accent: AssetTheme.gold)
                            CompactStat(title: "负债", value: PortfolioCalculator.totalLiabilities(for: snapshot).currencyString(), accent: AssetTheme.negative)
                        }
                    }
                    .atmCardStyle()

                    ForEach(groupedEntries, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(section.group.displayName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(AssetTheme.textPrimary)

                            ForEach(section.entries) { entry in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.item?.name ?? "未命名")
                                            .font(.headline)
                                            .foregroundStyle(AssetTheme.textPrimary)

                                        if let quantity = entry.quantity, let unitPrice = entry.unitPrice {
                                            Text("\(quantity.plainNumberString()) × \(unitPrice.plainNumberString())")
                                                .font(.footnote)
                                                .foregroundStyle(AssetTheme.textSecondary)
                                        }
                                    }

                                    Spacer()

                                    Text(entry.resolvedAmount.currencyString())
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(section.group == .liability ? AssetTheme.negative : AssetTheme.goldSoft)
                                }
                                .padding(14)
                                .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
                                )
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
    }
}

private struct TimeMachineView: View {
    @ObservedObject var marketStore: RemoteMarketStore
    let isActive: Bool
    @Query(sort: \AssetSnapshot.date, order: .forward) private var snapshots: [AssetSnapshot]
    @State private var selectedRange: TimeMachineRange = .oneYear
    @State private var cachedTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedFilteredTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]] = [:]
    @State private var cachedDetailTrendCards: [TimeMachineCombinedTrendDescriptor] = []

    private let debugFocusedCardIndex: Int? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-timeMachineFocusCard"), index + 1 < arguments.count else {
            return nil
        }
        return Int(arguments[index + 1])
    }()

    private let debugHidesHeroCard = ProcessInfo.processInfo.arguments.contains("-timeMachineHideHero")

    private var trendPoints: [TimeMachineTrendPoint] {
        cachedTrendPoints
    }

    private var filteredTrendPoints: [TimeMachineTrendPoint] {
        cachedFilteredTrendPoints
    }

    private var latestPoint: TimeMachineTrendPoint? {
        cachedFilteredTrendPoints.last ?? cachedTrendPoints.last
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

    private var presentedDetailTrendCards: [TimeMachineCombinedTrendDescriptor] {
        guard let debugFocusedCardIndex else { return detailTrendCards }
        guard detailTrendCards.indices.contains(debugFocusedCardIndex) else { return detailTrendCards }
        return [detailTrendCards[debugFocusedCardIndex]]
    }

    private static let publicIndexConfigs: [(symbol: String, title: String, color: Color)] = [
        ("sp500", "标普500", AssetTheme.goldSoft),
        ("dowjones", "道指", AssetTheme.accentOrange),
        ("hsi", "恒生", AssetTheme.accentBlue),
        ("nikkei", "日经225", AssetTheme.positive),
        ("csi300", "沪深300", AssetTheme.textPrimary),
        ("shanghai_composite", "上证综指", AssetTheme.textSecondary)
    ]

    private func historySeriesPoints(_ series: PublicHistorySeries) -> [TimeMachineSingleAxisPoint] {
        let points: [TimeMachineSingleAxisPoint] = Array(zip(series.dates, series.prices)).compactMap { (dateText: String, price: Double) -> TimeMachineSingleAxisPoint? in
            guard let date = historicalSeriesDate(from: dateText), price.isFinite, price > 0 else { return nil }
            return TimeMachineSingleAxisPoint(date: date, value: price)
        }
        let sortedPoints = points.sorted { $0.date < $1.date }
        return selectedRange.filter(sortedPoints)
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

            for entry in snapshot.entries.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                hasher.combine(entry.id)
                hasher.combine(entry.updatedAt.timeIntervalSinceReferenceDate)
                hasher.combine(entry.amount)
                hasher.combine(entry.quantity)
                hasher.combine(entry.unitPrice)
                hasher.combine(entry.item?.id)
                hasher.combine(entry.item?.updatedAt.timeIntervalSinceReferenceDate)
                hasher.combine(entry.item?.category?.groupRawValue)
            }
        }

        return hasher.finalize()
    }

    @MainActor
    private func refreshVisualizationCache() {
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
        let historyPointsBySymbol = buildHistoryPointsBySymbol()

        cachedTrendPoints = trendPoints
        cachedFilteredTrendPoints = filteredTrendPoints
        cachedHistoryPointsBySymbol = historyPointsBySymbol
        cachedDetailTrendCards = buildDetailTrendCards(
            filteredTrendPoints: filteredTrendPoints,
            latestPoint: filteredTrendPoints.last ?? trendPoints.last,
            historyPointsBySymbol: historyPointsBySymbol
        )
    }

    private func buildHistoryPointsBySymbol() -> [String: [TimeMachineSingleAxisPoint]] {
        let symbols = ["gold_cny", "nasdaq"] + Self.publicIndexConfigs.map(\.symbol)
        return Dictionary(uniqueKeysWithValues: symbols.compactMap { symbol in
            guard let series = marketStore.history(for: symbol) else { return nil }
            let points = historySeriesPoints(series)
            guard !points.isEmpty else { return nil }
            return (symbol, points)
        })
    }

    private func buildDetailTrendCards(
        filteredTrendPoints: [TimeMachineTrendPoint],
        latestPoint: TimeMachineTrendPoint?,
        historyPointsBySymbol: [String: [TimeMachineSingleAxisPoint]]
    ) -> [TimeMachineCombinedTrendDescriptor] {
        let goldLeftOnlyPoints = historyPointsBySymbol["gold_cny"] ?? singleAxisPoints(for: filteredTrendPoints, range: selectedRange, left: \.goldAnchorPriceCNY)
        let nasdaqLeftOnlyPoints = historyPointsBySymbol["nasdaq"] ?? singleAxisPoints(for: filteredTrendPoints, range: selectedRange, left: \.nasdaqAnchorPriceUSD)

        let primaryCards = [
            TimeMachineCombinedTrendDescriptor(
                title: "黄金",
                subtitle: nil,
                leftTitle: "价格",
                rightTitle: "折算",
                points: pairedPoints(for: filteredTrendPoints, range: selectedRange, left: \.goldAnchorPriceCNY, right: \.goldEquivalent),
                leftOnlyPoints: goldLeftOnlyPoints,
                leftColor: AssetTheme.gold,
                rightColor: AssetTheme.positive,
                leftLatestLabel: goldLeftOnlyPoints.last.map { "\($0.value.currencyString())/g" } ?? "--",
                rightLatestLabel: latestPoint?.goldEquivalent.map { "\($0.plainNumberString()) g" } ?? "--",
                leftAxisStyle: .currency(code: "CNY"),
                rightAxisStyle: .quantity(unit: "g", maxFractionDigits: 2),
                showsComparisonLine: true
            ),
            TimeMachineCombinedTrendDescriptor(
                title: "纳指",
                subtitle: nil,
                leftTitle: "价格",
                rightTitle: "折算",
                points: pairedPoints(for: filteredTrendPoints, range: selectedRange, left: \.nasdaqAnchorPriceUSD, right: \.nasdaqEquivalent),
                leftOnlyPoints: nasdaqLeftOnlyPoints,
                leftColor: AssetTheme.accentBlue,
                rightColor: AssetTheme.positive,
                leftLatestLabel: nasdaqLeftOnlyPoints.last.map { $0.value.currencyString(code: "USD") } ?? "--",
                rightLatestLabel: latestPoint?.nasdaqEquivalent.map { "\($0.plainNumberString()) 份" } ?? "--",
                leftAxisStyle: .currency(code: "USD"),
                rightAxisStyle: .quantity(unit: "份", maxFractionDigits: 2),
                showsComparisonLine: true
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
                subtitle: currency == "CNY" ? "按当前总资产折算" : "按当前总资产、当前汇率估算",
                leftTitle: "指数现价",
                rightTitle: "资产折算",
                points: comparisonPoints,
                leftOnlyPoints: displayedLeftPoints,
                leftColor: config.color,
                rightColor: AssetTheme.positive,
                leftLatestLabel: latestLeftPoint.map { $0.value.currencyString(code: currency) } ?? "--",
                rightLatestLabel: latestComparisonPoint.map { "\($0.rightValue.plainNumberString()) 份" } ?? "--",
                leftAxisStyle: .currency(code: currency),
                rightAxisStyle: .quantity(unit: "份", maxFractionDigits: 2),
                showsComparisonLine: comparisonPoints.count >= 2
            )
        }

        return primaryCards + publicIndexCards
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
        let cleanedPoints = historyPoints.compactMap { point -> TimeMachineDualAxisPoint? in
            guard let nearestTrendPoint = nearestTrendPoint(to: point.date, in: trendPoints),
                  let priceInCNY = convertedPriceToCNY(point.value, currency: currency),
                  priceInCNY.isFinite,
                  priceInCNY > 0 else {
                return nil
            }

            let equivalent = nearestTrendPoint.mainAssets / priceInCNY
            guard equivalent.isFinite, equivalent > 0 else { return nil }

            return TimeMachineDualAxisPoint(
                date: point.date,
                leftValue: point.value,
                rightValue: equivalent
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
                    VStack(alignment: .leading, spacing: 10) {
                        if let latestPoint, !filteredTrendPoints.isEmpty {
                            if !debugHidesHeroCard {
                                TimeMachineHeroTrendCard(
                                    points: filteredTrendPoints,
                                    latestPoint: latestPoint,
                                    selectedRange: $selectedRange
                                )
                            }

                            LazyVStack(spacing: 12) {
                                ForEach(presentedDetailTrendCards) { card in
                                    TimeMachineDualAxisTrendCard(descriptor: card)
                                }
                            }
                        } else {
                            EmptyStateCard(
                                title: "还没有趋势数据",
                                message: "先去记录页留下一些历史资产快照，时光机这边就能长出完整趋势图。",
                                systemImage: "chart.line.uptrend.xyaxis"
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 136)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: isActive) {
            guard isActive else { return }
            refreshVisualizationCache()
        }
        .onChange(of: selectedRange) { _, _ in
            guard isActive else { return }
            refreshVisualizationCache()
        }
        .onChange(of: snapshotCacheToken) { _, _ in
            guard isActive else { return }
            refreshVisualizationCache()
        }
        .onReceive(marketStore.$historySeries) { _ in
            guard isActive else { return }
            refreshVisualizationCache()
        }
        .onReceive(marketStore.$overview) { _ in
            guard isActive else { return }
            refreshVisualizationCache()
        }
        .onReceive(marketStore.$exchangeRates) { _ in
            guard isActive else { return }
            refreshVisualizationCache()
        }
    }
}

private struct BacktestSeriesPoint: Identifiable {
    let date: Date
    let portfolioValue: Double

    var id: Date { date }
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

private struct BacktestIndexOption: Identifiable {
    let symbol: String
    let title: String
    let color: Color

    var id: String { symbol }
}

private enum BacktestDefaults {
    static let cashWeight: Double = 50
    static let goldWeight: Double = 25
    static let indexOptions: [BacktestIndexOption] = [
        .init(symbol: "sp500", title: "标普500", color: AssetTheme.goldSoft),
        .init(symbol: "nasdaq", title: "纳指", color: AssetTheme.accentBlue),
        .init(symbol: "dowjones", title: "道指", color: AssetTheme.accentOrange),
        .init(symbol: "hsi", title: "恒生", color: AssetTheme.accentRed),
        .init(symbol: "nikkei", title: "日经225", color: AssetTheme.positive),
        .init(symbol: "csi300", title: "沪深300", color: AssetTheme.textPrimary),
        .init(symbol: "shanghai_composite", title: "上证综指", color: AssetTheme.textSecondary),
    ]
    static let indexWeights: [String: Double] = {
        Dictionary(uniqueKeysWithValues: indexOptions.map { option in
            (option.symbol, option.symbol == "nasdaq" ? 25 : 0)
        })
    }()
}

private enum BacktestEngine {
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
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

private struct InteractiveBacktestChart: View {
    let points: [BacktestSeriesPoint]
    @State private var selectedDate: Date?

    private var selectedPoint: BacktestSeriesPoint? {
        guard let selectedDate else { return points.last }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("日期", point.date),
                    y: .value("组合净值", point.portfolioValue)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [AssetTheme.gold.opacity(0.32), AssetTheme.gold.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("日期", point.date),
                    y: .value("组合净值", point.portfolioValue)
                )
                .foregroundStyle(AssetTheme.gold)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }

            if let selectedPoint {
                PointMark(
                    x: .value("日期", selectedPoint.date),
                    y: .value("组合净值", selectedPoint.portfolioValue)
                )
                .foregroundStyle(AssetTheme.gold)
                .symbolSize(44)
            }

            if selectedDate != nil, let selectedPoint {
                RuleMark(x: .value("选中日期", selectedPoint.date))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .frame(height: 220)
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
                        Text(String(format: "%.2fx", doubleValue))
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
    @State private var cashWeight: Double = BacktestDefaults.cashWeight
    @State private var goldWeight: Double = BacktestDefaults.goldWeight
    @State private var indexWeights: [String: Double] = BacktestDefaults.indexWeights
    @State private var selectedStartDate: Date?
    @State private var selectedEndDate: Date?
    @State private var animationProgress: Double = 1
    @State private var showsAllocationSheet = false
    @State private var showsRangeSheet = false
    @State private var hasStartedBacktest = ProcessInfo.processInfo.arguments.contains("-autoStartBacktest")
    @State private var hasPlayedInitialBacktestAnimation = false
    @State private var isBacktestLoading = false
    @State private var backtestRefreshToken = 0
    @State private var report: BacktestReport?
    @State private var displayPoints: [BacktestSeriesPoint] = []

    private let indexOptions = BacktestDefaults.indexOptions

    private var filteredGoldSeries: PublicHistorySeries? {
        filteredHistorySeries(marketStore.history(for: "gold_cny"))
    }

    private var filteredIndexSeriesBySymbol: [String: PublicHistorySeries] {
        Dictionary(uniqueKeysWithValues: indexOptions.compactMap { option in
            guard let series = filteredHistorySeries(marketStore.history(for: option.symbol)) else { return nil }
            return (option.symbol, series)
        })
    }

    private var positiveIndexOptions: [BacktestIndexOption] {
        indexOptions.filter { indexWeights[$0.symbol, default: 0] > 0 }
    }

    private var animatedPoints: [BacktestSeriesPoint] {
        guard !displayPoints.isEmpty else { return [] }
        let count = max(Int(Double(displayPoints.count) * animationProgress), min(displayPoints.count, 2))
        return Array(displayPoints.prefix(count))
    }

    private var allocationSlices: [BacktestAllocationSlice] {
        [
            BacktestAllocationSlice(title: "现金", amount: cashWeight, color: AssetTheme.textSecondary),
            BacktestAllocationSlice(title: "黄金", amount: goldWeight, color: AssetTheme.gold)
        ] + positiveIndexOptions.map { option in
            BacktestAllocationSlice(title: option.title, amount: indexWeights[option.symbol, default: 0], color: option.color)
        }
        .filter { $0.amount > 0 }
    }

    private var activeAllocationSummary: String {
        let titles = allocationSlices.map(\.title)
        switch titles.count {
        case 0:
            return "未配置"
        case 1, 2:
            return titles.joined(separator: " + ")
        default:
            return "\(titles.count)类资产"
        }
    }

    private var activeBacktestSourceSeries: [PublicHistorySeries] {
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

    private var availableBacktestBounds: ClosedRange<Date>? {
        BacktestEngine.availableDateBounds(for: activeBacktestSourceSeries)
    }

    private var effectiveBacktestBounds: ClosedRange<Date>? {
        guard let availableBacktestBounds else { return nil }

        let start = max(selectedStartDate ?? availableBacktestBounds.lowerBound, availableBacktestBounds.lowerBound)
        let end = min(selectedEndDate ?? availableBacktestBounds.upperBound, availableBacktestBounds.upperBound)

        guard start <= end else {
            return availableBacktestBounds
        }

        return start...end
    }

    private var selectedDateRangeLabel: String {
        guard let effectiveBacktestBounds else { return "调整时间" }
        return "\(effectiveBacktestBounds.lowerBound.recordDateString) - \(effectiveBacktestBounds.upperBound.recordDateString)"
    }

    private var selectedDateFilterToken: String {
        let startToken = selectedStartDate?.recordDateString ?? "nil"
        let endToken = selectedEndDate?.recordDateString ?? "nil"
        return "\(startToken)|\(endToken)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(spacing: 20) {
                            BacktestAllocationCard(
                                slices: allocationSlices,
                                activeAllocationSummary: activeAllocationSummary,
                                selectedDateRangeLabel: selectedDateRangeLabel,
                                onTapRange: {
                                    showsRangeSheet = true
                                },
                                onTapAllocation: {
                                    showsAllocationSheet = true
                                }
                            )

                            if !isBacktestLoading {
                                HStack(spacing: 10) {
                                    if report != nil {
                                        BacktestActionChip(title: "重置回测", systemImage: "arrow.counterclockwise") {
                                            resetBacktest()
                                        }
                                    }

                                    Button {
                                        hasStartedBacktest = true
                                        scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: report == nil ? "play.fill" : "arrow.clockwise")
                                                .font(.footnote.weight(.bold))
                                            Text(report == nil ? "开始回测" : "重新回测")
                                                .font(.subheadline.weight(.bold))
                                        }
                                        .foregroundStyle(Color.black.opacity(0.88))
                                        .frame(maxWidth: .infinity)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 14)
                                        .background(
                                            LinearGradient(
                                                colors: [AssetTheme.goldSoft, AssetTheme.gold],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                .stroke(AssetTheme.gold.opacity(0.32), lineWidth: 1)
                                        )
                                        .shadow(color: AssetTheme.gold.opacity(0.18), radius: 12, y: 6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)

                        if isBacktestLoading {
                            BacktestLoadingView()
                                .padding(.top, 8)
                        }

                        if let report, !isBacktestLoading {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text("组合净值")
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
                                .frame(height: 220)
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
                                                Text(String(format: "%.2fx", doubleValue))
                                                    .foregroundStyle(AssetTheme.textSecondary)
                                            }
                                        }
                                    }
                                }
                                .chartLegend(.hidden)
                            }
                            .padding(.top, 8)

                            VStack(alignment: .leading, spacing: 12) {
                                Text("分析报告")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(AssetTheme.textPrimary)

                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                                    BacktestMetricCard(title: "总收益", value: report.totalReturn.percentString())
                                    BacktestMetricCard(title: "年化收益", value: report.annualizedReturn?.percentString() ?? "--")
                                    BacktestMetricCard(title: "最大回撤", value: report.maxDrawdown.percentString(), accent: AssetTheme.negative)
                                    BacktestMetricCard(title: "修复时间", value: recoveryTimeLabel(for: report))
                                    BacktestMetricCard(title: "年化波动", value: report.annualizedVolatility?.percentString() ?? "--")
                                    BacktestMetricCard(title: "夏普比率", value: report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                                    BacktestMetricCard(title: "区间", value: intervalLabel(for: report))
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, report == nil ? 10 : 136)
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
            .sheet(isPresented: $showsRangeSheet) {
                if let availableBacktestBounds, let effectiveBacktestBounds {
                    BacktestDateRangeSheet(
                        availableBounds: availableBacktestBounds,
                        selectedBounds: effectiveBacktestBounds
                    ) { startDate, endDate in
                        selectedStartDate = startDate
                        selectedEndDate = endDate
                    }
                    .presentationDetents([.fraction(0.48)])
                    .presentationDragIndicator(.visible)
                } else {
                    ContentUnavailableView("暂无可用历史数据", systemImage: "calendar.badge.exclamationmark")
                        .presentationDetents([.fraction(0.32)])
                        .presentationDragIndicator(.visible)
                }
            }
        }
        .onAppear {
            if hasStartedBacktest, report == nil {
                scheduleBacktestRefresh(animated: !hasPlayedInitialBacktestAnimation)
            }
        }
        .onChange(of: selectedDateFilterToken) { _, _ in
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true)
        }
        .onReceive(marketStore.$historySeries) { _ in
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: report == nil && !hasPlayedInitialBacktestAnimation)
        }
    }

    private func applyAllocation(cashWeight: Double, goldWeight: Double, indexWeights: [String: Double]) {
        self.cashWeight = cashWeight
        self.goldWeight = goldWeight
        self.indexWeights = indexWeights

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
        report = BacktestEngine.run(
            cashWeight: cashWeight,
            goldWeight: goldWeight,
            goldSeries: filteredGoldSeries,
            indexWeights: indexWeights,
            indexSeriesBySymbol: filteredIndexSeriesBySymbol
        )
        displayPoints = sampledChartPoints(from: report?.points ?? [])

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
        cashWeight = BacktestDefaults.cashWeight
        goldWeight = BacktestDefaults.goldWeight
        indexWeights = BacktestDefaults.indexWeights
        selectedStartDate = nil
        selectedEndDate = nil
        report = nil
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

    private func filteredHistorySeries(_ series: PublicHistorySeries?) -> PublicHistorySeries? {
        guard let series else { return nil }
        guard let effectiveBacktestBounds else { return series }

        let filteredPairs = zip(series.dates, series.prices).filter { dateText, _ in
            guard let date = BacktestEngine.historicalSeriesDateStatic(from: dateText) else { return false }
            return date >= effectiveBacktestBounds.lowerBound && date <= effectiveBacktestBounds.upperBound
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
        guard let days = report.maxDrawdownRecoveryDays else { return "未修复" }
        if days >= 365 {
            let years = Double(days) / 365.25
            return String(format: "%.1f年", years)
        }
        return "\(days)天"
    }

}

private struct BacktestAllocationCard: View {
    let slices: [BacktestAllocationSlice]
    let activeAllocationSummary: String
    let selectedDateRangeLabel: String
    let onTapRange: () -> Void
    let onTapAllocation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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

                Image(systemName: "slider.horizontal.3")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            Button(action: onTapAllocation) {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack {
                        Chart(slices) { slice in
                            SectorMark(
                                angle: .value("占比", slice.amount),
                                innerRadius: .ratio(0.72),
                                angularInset: 2
                            )
                            .foregroundStyle(slice.color)
                        }
                        .frame(width: 188, height: 188)
                        .chartLegend(.hidden)

                        VStack(spacing: 6) {
                            Text("当前配置")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AssetTheme.textSecondary)
                            Text(activeAllocationSummary)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(AssetTheme.textPrimary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.78)
                        }
                        .padding(.horizontal, 18)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 0) {
                        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                            BacktestAllocationRow(slice: slice, showsDivider: index < slices.count - 1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BacktestAllocationRow: View {
    let slice: BacktestAllocationSlice
    let showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .fill(slice.color)
                    .frame(width: 10, height: 10)

                Text(slice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer()

                Text("\(Int(slice.amount.rounded()))%")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AssetTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if showsDivider {
                Rectangle()
                    .fill(AssetTheme.border.opacity(0.45))
                    .frame(height: 1)
                    .padding(.leading, 38)
            }
        }
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
                    .foregroundStyle(AssetTheme.goldSoft)
                Text(title)
                    .font(.subheadline.weight(.semibold))
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

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("可回测区间")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AssetTheme.textSecondary)
                            Text("\(availableBounds.lowerBound.recordDateString) - \(availableBounds.upperBound.recordDateString)")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(AssetTheme.textPrimary)
                        }

                        VStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("开始日期")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AssetTheme.textPrimary)

                                DatePicker(
                                    "开始日期",
                                    selection: Binding(
                                        get: { startDate },
                                        set: { startDate = min($0, endDate) }
                                    ),
                                    in: availableBounds.lowerBound...endDate,
                                    displayedComponents: .date
                                )
                                .labelsHidden()
                                .datePickerStyle(.compact)
                            }
                            .padding(16)
                            .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
                            )

                            VStack(alignment: .leading, spacing: 10) {
                                Text("结束日期")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AssetTheme.textPrimary)

                                DatePicker(
                                    "结束日期",
                                    selection: Binding(
                                        get: { endDate },
                                        set: { endDate = max($0, startDate) }
                                    ),
                                    in: startDate...availableBounds.upperBound,
                                    displayedComponents: .date
                                )
                                .labelsHidden()
                                .datePickerStyle(.compact)
                            }
                            .padding(16)
                            .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
                            )
                        }

                        Button {
                            startDate = availableBounds.lowerBound
                            endDate = availableBounds.upperBound
                        } label: {
                            Text("使用全部历史区间")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AssetTheme.goldSoft)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text("调整时间")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onApply(startDate, endDate)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(AssetTheme.goldSoft)
                }
            }
        }
    }
}

private struct BacktestLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(AssetTheme.gold)
                .scaleEffect(1.15)
            Text("正在重新回测...")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)
            Text("点完成后再统一计算，这次不让它边拖边抖了。")
                .font(.caption)
                .foregroundStyle(AssetTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

private struct BacktestAllocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cashWeight: Double
    @State private var goldWeight: Double
    @State private var indexWeights: [String: Double]
    let indexOptions: [BacktestIndexOption]
    let onApply: (Double, Double, [String: Double]) -> Void

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

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("先在这里调整，点完成后再统一回测。")
                            .font(.caption)
                            .foregroundStyle(AssetTheme.textSecondary)

                        BacktestWeightRow(title: "现金", value: $cashWeight, tint: AssetTheme.textSecondary)
                        BacktestWeightRow(title: "黄金", value: $goldWeight, tint: AssetTheme.gold)

                        ForEach(indexOptions) { option in
                            BacktestWeightRow(
                                title: option.title,
                                value: binding(for: option.symbol),
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
                    Button("重置") {
                        resetDraft()
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("调整配置")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        normalizeWeights()
                        onApply(cashWeight, goldWeight, indexWeights)
                        dismiss()
                    }
                    .tint(AssetTheme.gold)
                }
            }
        }
    }

    private func binding(for symbol: String) -> Binding<Double> {
        Binding(
            get: { indexWeights[symbol, default: 0] },
            set: { indexWeights[symbol] = $0 }
        )
    }

    private func resetDraft() {
        cashWeight = BacktestDefaults.cashWeight
        goldWeight = BacktestDefaults.goldWeight
        indexWeights = BacktestDefaults.indexWeights
    }

    private func normalizeWeights() {
        cashWeight = max(cashWeight, 0)
        goldWeight = max(goldWeight, 0)

        let clampedIndexWeights = Dictionary(uniqueKeysWithValues: indexOptions.map { option in
            (option.symbol, max(indexWeights[option.symbol, default: 0], 0))
        })
        let total = cashWeight + goldWeight + clampedIndexWeights.values.reduce(0, +)
        guard total > 0 else {
            resetDraft()
            return
        }

        cashWeight = (cashWeight / total) * 100
        goldWeight = (goldWeight / total) * 100

        let indexBudget = max(0, 100 - cashWeight - goldWeight)
        let totalIndexWeight = clampedIndexWeights.values.reduce(0, +)
        guard totalIndexWeight > 0 else {
            indexWeights = Dictionary(uniqueKeysWithValues: indexOptions.map { ($0.symbol, 0) })
            return
        }

        var normalizedIndexWeights: [String: Double] = [:]
        var allocated: Double = 0
        for option in indexOptions.dropLast() {
            let base = clampedIndexWeights[option.symbol, default: 0]
            let normalized = (base / totalIndexWeight) * indexBudget
            normalizedIndexWeights[option.symbol] = normalized
            allocated += normalized
        }
        if let lastOption = indexOptions.last {
            normalizedIndexWeights[lastOption.symbol] = max(0, indexBudget - allocated)
        }
        indexWeights = normalizedIndexWeights
    }
}

private struct BacktestWeightRow: View {
    let title: String
    @Binding var value: Double
    var tint: Color = AssetTheme.gold

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
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
            Text(title)
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
    case sixMonths
    case oneYear
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sixMonths: return "6个月"
        case .oneYear: return "1年"
        case .all: return "全部"
        }
    }

    var summaryLabel: String {
        switch self {
        case .sixMonths: return "近 6 个月"
        case .oneYear: return "近 1 年"
        case .all: return "全部记录"
        }
    }

    private var detailAggregationComponent: Calendar.Component {
        .day
    }

    private func startDate(from latestDate: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: latestDate)
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: latestDate)
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
        case .mainAssets: return "总资产"
        case .netAssets: return "净资产"
        case .liabilities: return "总负债"
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
                        angle: .value("占比", slice.amount),
                        innerRadius: .ratio(0.62),
                        angularInset: 2
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
                .frame(height: 250)

                VStack(spacing: 6) {
                    Text("总资产")
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
                                Text(slice.title)
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
                    Text(displaySlice.title == "其他" ? "其他资产明细" : "资产明细")
                        .font(AppTypography.eyebrow)
                        .foregroundStyle(AssetTheme.textSecondary)

                    ForEach(displaySlice.details) { detail in
                        HStack(spacing: 12) {
                            Text(detail.title)
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
    let monthlyGrowth: Double
    let currentTarget: Double
    let maximumReachableMonthlyExpense: Double
}

private enum FinancialFreedomEstimator {
    private static let safeWithdrawalMultiple = 25.0
    private static let maxProjectionMonths = 100 * 12

    static func estimate(
        points: [TimeMachineTrendPoint],
        monthlyExpense: Double,
        annualInflationRate: Double
    ) -> FinancialFreedomProjection? {
        guard points.count >= 2 else { return nil }

        let regressionPoints = points.enumerated().compactMap { _, point -> (x: Double, y: Double)? in
            guard point.netAssets.isFinite else { return nil }
            return (0, point.netAssets)
        }
        guard !regressionPoints.isEmpty else { return nil }

        let origin = points[0].date
        let series = points.compactMap { point -> (x: Double, y: Double)? in
            guard point.netAssets.isFinite else { return nil }
            let days = point.date.timeIntervalSince(origin) / 86_400
            return (days / 30.4375, point.netAssets)
        }
        guard series.count >= 2 else { return nil }

        let slope = linearRegressionSlope(for: series)
        let currentNetAssets = points.last?.netAssets ?? 0
        let currentTarget = monthlyExpense * 12 * safeWithdrawalMultiple
        let maximumReachableMonthlyExpense = maximumReachableMonthlyExpense(
            currentNetAssets: currentNetAssets,
            monthlyGrowth: slope,
            annualInflationRate: annualInflationRate
        )

        if currentNetAssets >= currentTarget {
            return FinancialFreedomProjection(
                status: .alreadyFree,
                monthlyGrowth: slope,
                currentTarget: currentTarget,
                maximumReachableMonthlyExpense: maximumReachableMonthlyExpense
            )
        }

        guard slope > 0, monthlyExpense > 0 else {
            return FinancialFreedomProjection(
                status: .unreachable,
                monthlyGrowth: slope,
                currentTarget: currentTarget,
                maximumReachableMonthlyExpense: maximumReachableMonthlyExpense
            )
        }

        for month in 1...maxProjectionMonths {
            let projectedAssets = currentNetAssets + slope * Double(month)
            let projectedTarget = currentTarget * pow(1 + annualInflationRate, Double(month) / 12)
            if projectedAssets >= projectedTarget {
                return FinancialFreedomProjection(
                    status: .projected(months: month),
                    monthlyGrowth: slope,
                    currentTarget: currentTarget,
                    maximumReachableMonthlyExpense: maximumReachableMonthlyExpense
                )
            }
        }

        return FinancialFreedomProjection(
            status: .unreachable,
            monthlyGrowth: slope,
            currentTarget: currentTarget,
            maximumReachableMonthlyExpense: maximumReachableMonthlyExpense
        )
    }

    private static func maximumReachableMonthlyExpense(
        currentNetAssets: Double,
        monthlyGrowth: Double,
        annualInflationRate: Double
    ) -> Double {
        var bestExpense = max(0, currentNetAssets / (safeWithdrawalMultiple * 12))

        for month in 1...maxProjectionMonths {
            let projectedAssets = currentNetAssets + monthlyGrowth * Double(month)
            guard projectedAssets > 0 else { continue }

            let inflationFactor = pow(1 + annualInflationRate, Double(month) / 12)
            let allowedExpense = projectedAssets / (safeWithdrawalMultiple * 12 * inflationFactor)
            bestExpense = max(bestExpense, allowedExpense)
        }

        return max(0, bestExpense)
    }

    private static func linearRegressionSlope(for points: [(x: Double, y: Double)]) -> Double {
        let count = Double(points.count)
        let sumX = points.reduce(0) { $0 + $1.x }
        let sumY = points.reduce(0) { $0 + $1.y }
        let sumXY = points.reduce(0) { $0 + $1.x * $1.y }
        let sumX2 = points.reduce(0) { $0 + $1.x * $1.x }
        let denominator = count * sumX2 - sumX * sumX

        guard abs(denominator) > .ulpOfOne else { return 0 }
        return (count * sumXY - sumX * sumY) / denominator
    }
}

private struct DashboardFreedomSection: View {
    let projection: FinancialFreedomProjection?
    @Binding var monthlyExpense: Double
    @Binding var inflationRate: Double

    @State private var isEditingMonthlyExpense = false
    @State private var isEditingInflationRate = false
    @State private var monthlyExpenseDraft = ""
    @State private var inflationRateDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(AssetTheme.border.opacity(0.55))
                .frame(height: 1)

            Text(statusText)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(statusColor)

            if let reasonText {
                Text(reasonText)
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text("月开销")
                    valueButton(title: monthlyExpense.currencyString(), action: openMonthlyExpenseEditor)
                    Text("，通胀率")
                    valueButton(title: inflationRate.formatted(.percent.precision(.fractionLength(1))), action: openInflationRateEditor)
                }
                .font(AppTypography.meta)
                .foregroundStyle(AssetTheme.textSecondary)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("月开销")
                        valueButton(title: monthlyExpense.currencyString(), action: openMonthlyExpenseEditor)
                    }

                    HStack(spacing: 6) {
                        Text("通胀率")
                        valueButton(title: inflationRate.formatted(.percent.precision(.fractionLength(1))), action: openInflationRateEditor)
                    }
                }
                .font(AppTypography.meta)
                .foregroundStyle(AssetTheme.textSecondary)
            }
        }
        .alert("修改月开销", isPresented: $isEditingMonthlyExpense) {
            TextField("例如 8000", text: $monthlyExpenseDraft)
                .keyboardType(.decimalPad)
            Button("取消", role: .cancel) {}
            Button("确定") {
                applyMonthlyExpenseDraft()
            }
        } message: {
            Text("输入每月开销金额，用来计算财富自由目标。")
        }
        .alert("修改通胀率", isPresented: $isEditingInflationRate) {
            TextField("例如 3.0", text: $inflationRateDraft)
                .keyboardType(.decimalPad)
            Button("取消", role: .cancel) {}
            Button("确定") {
                applyInflationRateDraft()
            }
        } message: {
            Text("输入百分比数值，例如 3 代表 3%。")
        }
    }

    private func valueButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AssetTheme.overlaySubtle, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
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

    private var statusText: String {
        guard let projection else { return "还不能估算财富自由时间，至少两条才能开始估算财富自由时间" }

        switch projection.status {
        case .alreadyFree:
            return "已经财富自由"
        case let .projected(months):
            let years = months / 12
            let remainingMonths = months % 12
            if years > 0, remainingMonths > 0 {
                return "剩余 \(years) 年 \(remainingMonths) 月"
            } else if years > 0 {
                return "剩余 \(years) 年"
            } else {
                return "剩余 \(remainingMonths) 月"
            }
        case .unreachable:
            return "永远无法财富自由"
        }
    }

    private var reasonText: String? {
        guard let projection else {
            return "至少要有两条快照，才能开始估算。"
        }

        switch projection.status {
        case .alreadyFree, .projected:
            return nil
        case .unreachable:
            let inflationText = inflationRate.formatted(.percent.precision(.fractionLength(1)))
            if projection.maximumReachableMonthlyExpense > 0 {
                return "按当前月均净资产增长 \(projection.monthlyGrowth.currencyString()) 估算，若通胀率维持 \(inflationText)，月开销需降到 \(projection.maximumReachableMonthlyExpense.currencyString()) 以内。"
            } else {
                return "按当前趋势估算，若通胀率维持 \(inflationText)，就算把月开销降到 0 也追不上目标线。"
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

private struct DashboardTrendCard: View {
    let points: [TimeMachineTrendPoint]
    let latestPoint: TimeMachineTrendPoint
    @State private var selectedDate: Date?

    private var selectedPoint: TimeMachineTrendPoint {
        guard let selectedDate else { return latestPoint }
        return nearestTrendPoint(to: selectedDate, in: points) ?? latestPoint
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
                    ForEach(points) { point in
                        LineMark(
                            x: .value("日期", point.date),
                            y: .value(series.title, series.value(from: point))
                        )
                        .foregroundStyle(by: .value("序列", series.title))
                        .lineStyle(series.strokeStyle)
                        .interpolationMethod(.catmullRom)
                    }

                    PointMark(
                        x: .value("日期", selectedPoint.date),
                        y: .value(series.title, series.value(from: selectedPoint))
                    )
                    .foregroundStyle(series.color)
                    .symbolSize(44)
                }

                if selectedDate != nil {
                    RuleMark(x: .value("选中日期", selectedPoint.date))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .chartForegroundStyleScale([
                TimeMachineAssetSeries.mainAssets.title: TimeMachineAssetSeries.mainAssets.color,
                TimeMachineAssetSeries.netAssets.title: TimeMachineAssetSeries.netAssets.color,
                TimeMachineAssetSeries.liabilities.title: TimeMachineAssetSeries.liabilities.color,
            ])
            .frame(height: 290)
            .chartXAxis {
                let axisDates = chartAxisDates(points.map(\.date))
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
        guard let first = points.first?.date else { return "暂无范围" }
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
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AssetTheme.overlaySoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.72), lineWidth: 1)
            )
        }
    }
}

private struct TimeMachineInlineMetric: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var selectedPoint: TimeMachineTrendPoint {
        guard let selectedDate else { return latestPoint }
        return nearestTrendPoint(to: selectedDate, in: points) ?? latestPoint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    TimeMachineRangeSelector(selectedRange: $selectedRange)

                    Spacer()

                    Text(selectedDate == nil ? dateRangeLabel : selectedPoint.date.chartAxisDateString)
                        .font(.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(1)
                }

                Text(selectedPoint.mainAssets.currencyString())
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AssetTheme.goldSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 8
                ) {
                    TimeMachineInlineMetric(
                        title: "净资产",
                        value: selectedPoint.netAssets.currencyString(),
                        accent: AssetTheme.textPrimary
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

                HStack(spacing: 12) {
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
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                }
            }

            Chart {
                ForEach(TimeMachineAssetSeries.allCases) { series in
                    ForEach(points) { point in
                        LineMark(
                            x: .value("日期", point.date),
                            y: .value(series.title, series.value(from: point))
                        )
                        .foregroundStyle(by: .value("序列", series.title))
                        .lineStyle(series.strokeStyle)
                        .interpolationMethod(.catmullRom)
                    }

                    PointMark(
                        x: .value("日期", selectedPoint.date),
                        y: .value(series.title, series.value(from: selectedPoint))
                    )
                    .foregroundStyle(series.color)
                    .symbolSize(46)
                }

                if selectedDate != nil {
                    RuleMark(x: .value("选中日期", selectedPoint.date))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .chartForegroundStyleScale([
                TimeMachineAssetSeries.mainAssets.title: TimeMachineAssetSeries.mainAssets.color,
                TimeMachineAssetSeries.netAssets.title: TimeMachineAssetSeries.netAssets.color,
                TimeMachineAssetSeries.liabilities.title: TimeMachineAssetSeries.liabilities.color,
            ])
            .frame(height: 272)
            .chartXAxis {
                let axisDates = chartAxisDates(points.map(\.date))
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
            .padding(.bottom, 10)
        }
        .atmCardStyle()
    }

    private var dateRangeLabel: String {
        guard let first = points.first?.date, let last = points.last?.date else { return "暂无范围" }
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

private struct TimeMachineCurrentAnchorCard: View {
    let items: [TimeMachineCurrentAnchorItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最新快照锚点")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            ForEach(items) { item in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(item.accent)
                        .frame(width: 12, height: 3)

                    Text(item.title)
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
    }
}

private struct TimeMachineDualAxisTrendCard: View {
    let descriptor: TimeMachineCombinedTrendDescriptor
    @State private var selectedDate: Date?

    private var latestPoint: TimeMachineDualAxisPoint? {
        descriptor.points.last
    }

    private var selectedDualPoint: TimeMachineDualAxisPoint? {
        guard let selectedDate else { return latestPoint }
        return nearestDualAxisPoint(to: selectedDate, in: descriptor.points) ?? latestPoint
    }

    private var latestLeftOnlyPoint: TimeMachineSingleAxisPoint? {
        descriptor.leftOnlyPoints.last
    }

    private var selectedLeftOnlyPoint: TimeMachineSingleAxisPoint? {
        guard let selectedDate else { return latestLeftOnlyPoint }
        return nearestSingleAxisPoint(to: selectedDate, in: descriptor.leftOnlyPoints) ?? latestLeftOnlyPoint
    }

    private var leftDomain: ClosedRange<Double> {
        let values = descriptor.points.map(\.leftValue) + descriptor.leftOnlyPoints.map(\.value)
        return paddedDomain(values: values)
    }

    private var rightDomain: ClosedRange<Double> {
        paddedDomain(values: descriptor.points.map(\.rightValue))
    }

    private var canShowDualAxisChart: Bool {
        descriptor.showsComparisonLine && descriptor.points.count >= 2
    }

    private var canShowLeftOnlyChart: Bool {
        descriptor.leftOnlyPoints.count >= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if canShowDualAxisChart {
                dualAxisChart
                    .padding(.bottom, 6)
            } else if canShowLeftOnlyChart {
                leftOnlyChart
                    .padding(.bottom, 6)
            } else {
                Text("记录不足")
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            }

            Text(selectedDate == nil ? dateRangeLabel : selectedAxisDateLabel)
                .font(AppTypography.meta)
                .foregroundStyle(AssetTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AssetTheme.overlayFaint, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(descriptor.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                if let subtitle = descriptor.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                TimeMachineLegendMetric(
                    title: descriptor.leftTitle,
                    value: selectedLeftLabel,
                    color: descriptor.leftColor,
                    dashed: false
                )
                if descriptor.showsComparisonLine {
                    TimeMachineLegendMetric(
                        title: descriptor.rightTitle,
                        value: selectedRightLabel,
                        color: descriptor.rightColor,
                        dashed: true
                    )
                }
            }
        }
    }

    private var dualAxisChart: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = descriptor.showsComparisonLine ? 56 : 44
            let rightWidth: CGFloat = descriptor.showsComparisonLine ? 60 : 0
            let chartWidth = max(geometry.size.width - leftWidth - rightWidth - 8, 120)

            HStack(spacing: 4) {
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
                        RuleMark(x: .value("选中日期", selectedDualPoint.date))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(width: chartWidth, height: 210)
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
        }
        .frame(height: 210)
    }

    private var leftOnlyChart: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = 44
            let chartWidth = max(geometry.size.width - leftWidth - 4, 120)

            HStack(spacing: 4) {
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
                        RuleMark(x: .value("选中日期", selectedLeftOnlyPoint.date))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(width: chartWidth, height: 210)
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
        }
        .frame(height: 210)
    }

    @ChartContentBuilder
    private var leftSeriesMarks: some ChartContent {
        ForEach(descriptor.leftOnlyPoints) { point in
            LineMark(
                x: .value("日期", point.date),
                y: .value(descriptor.leftTitle, normalized(point.value, in: leftDomain)),
                series: .value("系列", descriptor.leftTitle)
            )
            .foregroundStyle(descriptor.leftColor)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.linear)
        }
    }

    @ChartContentBuilder
    private var rightSeriesMarksNormalized: some ChartContent {
        ForEach(descriptor.points) { point in
            LineMark(
                x: .value("日期", point.date),
                y: .value(descriptor.rightTitle, normalized(point.rightValue, in: rightDomain)),
                series: .value("系列", descriptor.rightTitle)
            )
            .foregroundStyle(descriptor.rightColor)
            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [6, 5]))
            .interpolationMethod(.linear)
        }
    }

    @ChartContentBuilder
    private var leftOnlySeriesMarks: some ChartContent {
        ForEach(descriptor.leftOnlyPoints) { point in
            LineMark(
                x: .value("日期", point.date),
                y: .value(descriptor.leftTitle, normalized(point.value, in: leftDomain)),
                series: .value("系列", descriptor.leftTitle)
            )
            .foregroundStyle(descriptor.leftColor)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.linear)
        }
    }

    @ChartContentBuilder
    private var latestPointMarksNormalized: some ChartContent {
        if let selectedDualPoint {
            PointMark(
                x: .value("日期", selectedDualPoint.date),
                y: .value(descriptor.leftTitle, normalized(selectedDualPoint.leftValue, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(42)

            if descriptor.showsComparisonLine {
                PointMark(
                    x: .value("日期", selectedDualPoint.date),
                    y: .value(descriptor.rightTitle, normalized(selectedDualPoint.rightValue, in: rightDomain))
                )
                .foregroundStyle(descriptor.rightColor)
                .symbolSize(36)
            }
        }
    }

    @ChartContentBuilder
    private var leftOnlyLatestPointMarks: some ChartContent {
        if let selectedLeftOnlyPoint {
            PointMark(
                x: .value("日期", selectedLeftOnlyPoint.date),
                y: .value(descriptor.leftTitle, normalized(selectedLeftOnlyPoint.value, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(42)
        }
    }

    private var bottomAxisMarks: some AxisContent {
        let axisDates = detailCardAxisDates(descriptor.leftOnlyPoints.map(\.date) + descriptor.points.map(\.date))
        return AxisMarks(values: axisDates) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                .foregroundStyle(AssetTheme.border.opacity(0.35))
            AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                .foregroundStyle(AssetTheme.border.opacity(0.7))
        }
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
        guard let first = dates.first, let last = dates.last else { return "暂无范围" }
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

private func nearestDualAxisPoint(to date: Date, in points: [TimeMachineDualAxisPoint]) -> TimeMachineDualAxisPoint? {
    points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
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

private struct TimeMachineLegendMetric: View {
    let title: String
    let value: String
    let color: Color
    let dashed: Bool

    var body: some View {
        HStack(spacing: 8) {
            if dashed {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(color)
                            .frame(width: 5, height: 3)
                    }
                }
                .frame(width: 17, alignment: .leading)
            } else {
                Capsule()
                    .fill(color)
                    .frame(width: 17, height: 3)
            }

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
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
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            Spacer(minLength: 6)
            Text(middleLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary)
            Spacer(minLength: 6)
            Text(bottomLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(width: 48)
        .frame(maxHeight: 164)
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
                        ATMHeader(title: "接口文档", subtitle: "给 App 自己看的，也给未来的分析逻辑备用。") {
                            Button {
                                Task { await marketStore.refresh() }
                            } label: {
                                GoldChip(text: "刷新")
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
                Text("返回")
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

                    Text(title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
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
            Text(title)
                .font(AppTypography.sectionTitle)
                .foregroundStyle(AssetTheme.textPrimary)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
            }
        }
    }
}

private struct GoldChip: View {
    let text: String

    var body: some View {
        Text(text)
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
            Text(title)
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

                Text(title)
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
        case "gold": return "黄金"
        case "nasdaq": return "纳指锚点"
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
                    Text(endpoint.title)
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

            Text(endpoint.description)
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
            Text(title)
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
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                if let message, !message.isEmpty {
                    Text(message)
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

private struct SkeletonLine: View {
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 999, style: .continuous)
            .fill(AssetTheme.overlayStrong)
            .frame(width: width, height: 14)
    }
}

private extension Double {
    func currencyString(code: String = "CNY") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.2f", self)
    }

    func plainNumberString() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        formatter.minimumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: self)) ?? String(self)
    }

    func compactNumberString(maxFractionDigits: Int = 1) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = maxFractionDigits
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        formatter.locale = Locale(identifier: "en_US_POSIX")

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
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = maxFractionDigits
        formatter.minimumFractionDigits = 0
        formatter.locale = Locale(identifier: "zh_CN")
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
    var inferredAutoPricedAssetKind: AutoPricedAssetKind? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        if trimmedName == "黄金" || trimmedName.caseInsensitiveCompare("gold") == .orderedSame {
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
                return "输入\(currencyCode) 数量"
            }

            if let autoKind = resolvedAutoPricedAssetKind {
                return "输入\(autoKind.defaultName) 数量"
            }

            return "输入数量"
        }

        return "输入金额"
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
            return "现价 \((1 / rate).currencyString())"
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
        return "现价 \(priceText)\(unitSuffix)"
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
        if normalized.contains("长期") { return 0 }
        if normalized.contains("短期") { return 1 }
        if titleMap[normalized] != nil { return 0 }
        return 2
    }
}

private extension Date {
    var shortDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: self)
    }

    var longDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: self)
    }

    var chineseLongDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: self)
    }

    var recordDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.M.d"
        return formatter.string(from: self)
    }

    var chartAxisDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: self)
    }

    var chartAxisShortDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yy.MM.dd"
        return formatter.string(from: self)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self], inMemory: true)
}
