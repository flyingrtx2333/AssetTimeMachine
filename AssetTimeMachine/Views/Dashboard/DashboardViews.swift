import SwiftUI
import SwiftData
import Charts
import UIKit

struct DashboardSnapshotSummary {
    let totalAssets: Double
    let totalLiabilities: Double
}

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("dashboard.monthlyExpense") private var monthlyExpense: Double = 3000
    @AppStorage("dashboard.monthlyExpenseSeedVersion") private var monthlyExpenseSeedVersion: Int = 0
    @AppStorage("dashboard.inflationRate") private var inflationRate: Double = 0.05
    @AppStorage("dashboard.inflationRateSeedVersion") private var inflationRateSeedVersion: Int = 0
    @AppStorage("dashboard.monthlySalary") private var monthlySalary: Double = 10000
    @AppStorage("dashboard.monthlySalarySeedVersion") private var monthlySalarySeedVersion: Int = 0
    @AppStorage("dashboard.annualReturnRate") private var annualReturnRate: Double = 0.03
    @ObservedObject var marketStore: RemoteMarketStore
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
    @State private var lastDashboardProjectionCacheToken: Int?
    @State private var pendingDashboardRefreshTask: Task<Void, Never>?
    @State private var pendingDashboardProjectionRefreshTask: Task<Void, Never>?
    @State private var pendingAutoSyncTask: Task<Void, Never>?
    @State private var dashboardRefreshGeneration = 0
    @State private var showsTodayStrategyModal = false
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
                                LoadingStateCard(title: AppLocalization.string("首页加载中"))
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
            .onChange(of: isActive ? autoSyncTrigger : "inactive") { _, _ in
                guard isActive else { return }
                scheduleCloudAutoSync()
            }
        }
        .task(id: isActive) {
            dashboardRefreshGeneration += 1
            let generation = dashboardRefreshGeneration
            if isActive {
                scheduleDashboardRefresh(
                    delayNanoseconds: 0,
                    projectionDelayNanoseconds: 520_000_000,
                    generation: generation
                )
            } else {
                pendingDashboardRefreshTask?.cancel()
                pendingDashboardProjectionRefreshTask?.cancel()
                pendingAutoSyncTask?.cancel()
            }
        }
        .onChange(of: isActive ? dashboardCacheToken : (lastDashboardCacheToken ?? 0)) { _, _ in
            guard isActive else { return }
            scheduleDashboardRefresh(
                delayNanoseconds: 40_000_000,
                projectionDelayNanoseconds: 120_000_000,
                generation: dashboardRefreshGeneration
            )
        }
        .sheet(isPresented: $showsTodayStrategyModal) {
            TodayStrategySheet(
                marketStore: marketStore,
                snapshot: latestSnapshot
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
    private func scheduleDashboardRefresh(
        delayNanoseconds: UInt64,
        projectionDelayNanoseconds: UInt64,
        force: Bool = false,
        generation: Int
    ) {
        pendingDashboardRefreshTask?.cancel()
        pendingDashboardRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard dashboardRefreshGeneration == generation else { return }
                refreshDashboardCacheIfNeeded(
                    force: force,
                    generation: generation,
                    projectionDelayNanoseconds: projectionDelayNanoseconds
                )
            }
        }
    }

    @MainActor
    private func refreshDashboardCacheIfNeeded(
        force: Bool = false,
        generation: Int,
        projectionDelayNanoseconds: UInt64
    ) {
        let token = dashboardCacheToken
        if force || token != lastDashboardCacheToken {
            refreshDashboardSnapshotCache()
            lastDashboardCacheToken = token
        }

        if force || token != lastDashboardProjectionCacheToken {
            scheduleDashboardProjectionRefresh(
                for: token,
                generation: generation,
                delayNanoseconds: projectionDelayNanoseconds
            )
        }
    }

    @MainActor
    private func refreshDashboardSnapshotCache() {
        cachedSnapshotSummary = buildLatestSnapshotSummary()
        cachedAllocationSlices = buildAllocationSlices()
    }

    @MainActor
    private func scheduleDashboardProjectionRefresh(
        for token: Int,
        generation: Int,
        delayNanoseconds: UInt64
    ) {
        pendingDashboardProjectionRefreshTask?.cancel()
        pendingDashboardProjectionRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard dashboardRefreshGeneration == generation else { return }
                refreshDashboardProjectionCache()
                lastDashboardProjectionCacheToken = token
                pendingDashboardProjectionRefreshTask = nil
            }
        }
    }

    @MainActor
    private func refreshDashboardProjectionCache() {
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
            HStack(spacing: 12) {
                Button {
                    showsTodayStrategyModal = true
                } label: {
                    DashboardTodayStrategyButton()
                }
                .buttonStyle(.plain)
                .disabled(StrategyNotificationDefaults.eligibleTemplates.isEmpty)

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

struct DashboardTodayStrategyButton: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "scope")
                .font(.footnote.weight(.bold))

            Text(AppLocalization.string("今日策略"))
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(AssetTheme.goldSoft)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(AssetTheme.overlaySoft.opacity(0.86), in: Capsule())
        .overlay(
            Capsule()
                .stroke(AssetTheme.gold.opacity(0.22), lineWidth: 1)
        )
    }
}

struct TodayStrategySheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app.strategyNotifications.templateID") private var strategyNotificationTemplateID = StrategyNotificationDefaults.defaultTemplateID
    @ObservedObject var marketStore: RemoteMarketStore
    let snapshot: AssetSnapshot?
    @State private var advice: StrategyRebalanceAdvice?
    @State private var actions: [StrategyRebalanceAction] = []
    @State private var isRefreshing = false
    @State private var statusMessage: String?
    @State private var hasAttemptedInitialHistoryRefresh = false

    private var selectedTemplate: AdvancedBacktestStrategyTemplate? {
        StrategyNotificationDefaults.template(for: strategyNotificationTemplateID)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        if isRefreshing && advice == nil && statusMessage == nil {
                            LoadingStateCard(title: AppLocalization.string("正在生成今日攻略"))
                        } else if let statusMessage {
                            todayStrategyStatusCard(message: statusMessage)
                        } else if let template = selectedTemplate, let advice {
                            todayStrategyContent(template: template, advice: advice)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 34)
                }
            }
            .navigationTitle(AppLocalization.string("今日调仓攻略"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await refreshAdvice(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                }
            }
            .task(id: strategyNotificationTemplateID) {
                let shouldForceRefresh = !hasAttemptedInitialHistoryRefresh
                hasAttemptedInitialHistoryRefresh = true
                await refreshAdvice(force: shouldForceRefresh)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "scope")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.goldSoft)
                    .frame(width: 34, height: 34)
                    .background(AssetTheme.gold.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedTemplate?.title ?? AppLocalization.string("未选择策略"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)

                    Text(AppLocalization.string("使用设置里的提醒策略生成"))
                        .font(.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                }

                Spacer(minLength: 0)
            }

        }
        .padding(16)
        .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.45), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func todayStrategyContent(template: AdvancedBacktestStrategyTemplate, advice: StrategyRebalanceAdvice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(AppLocalization.string("今日建议"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)

                    Spacer(minLength: 12)

                    Text(AppLocalization.format("信号截至 %@", advice.asOfDate.recordDateString))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(1)
                }

                Text(todayStrategySummary(template: template, advice: advice))
                    .font(.footnote)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    if actions.isEmpty {
                        todayStrategyCashRow(weight: advice.cashWeight > 0 ? advice.cashWeight : 1)
                    } else {
                        ForEach(actions) { action in
                            todayStrategyActionRow(action, lookbackSessions: advice.lookbackSessions)
                        }

                        if advice.cashWeight > 0.005 {
                            todayStrategyCashRow(weight: advice.cashWeight)
                        }
                    }
                }
            }
            .padding(16)
            .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.45), lineWidth: 1)
            )

            Text(AppLocalization.string("攻略仅用于历史回测口径下的调仓参考，不构成投资建议。"))
                .font(.caption)
                .foregroundStyle(AssetTheme.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    private func todayStrategyStatusCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(AssetTheme.accentOrange)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(AssetTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.45), lineWidth: 1)
        )
    }

    private func todayStrategyActionRow(_ action: StrategyRebalanceAction, lookbackSessions: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(BacktestDefaults.strategyColor(for: action.symbol))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(action.detailText(lookbackSessions: lookbackSessions))
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(action.kind.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(action.kind.accent)

                Text(action.amountText)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(action.kind.accent)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func todayStrategyCashRow(weight: Double) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(AssetTheme.textSecondary.opacity(0.7))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.string("现金/其他"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(AppLocalization.string("未投入部分保留为防守仓位"))
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

    @MainActor
    private func refreshAdvice(force: Bool) async {
        guard let template = selectedTemplate else {
            advice = nil
            actions = []
            statusMessage = AppLocalization.string("设置里还没有可用的提醒策略。")
            return
        }

        isRefreshing = true
        statusMessage = nil
        defer { isRefreshing = false }

        let assetOptions = StrategyNotificationDefaults.assetOptions(for: template)
        let shouldForceHistoryRefresh = force || isMissingRequiredHistory(for: assetOptions)
        await marketStore.refreshHistoryIfNeeded(force: shouldForceHistoryRefresh)
        if isMissingRequiredHistory(for: assetOptions) {
            await waitForRequiredHistory(assetOptions)
        }

        let assetInputs = assetOptions.map { option in
            BacktestEngine.advancedAssetInput(for: option) { symbol in
                marketStore.history(for: symbol)
            }
        }

        guard let nextAdvice = BacktestEngine.advancedRotationRebalanceAdvice(assetInputs: assetInputs, mode: template.mode) else {
            advice = nil
            actions = []
            statusMessage = AppLocalization.string("历史行情暂时不足，今日调仓将在数据补齐后更新。")
            return
        }

        let nextActions = StrategyRebalanceActionBuilder.actions(
            for: nextAdvice,
            snapshot: snapshot,
            selectedAssetOptions: assetOptions,
            allAssetOptions: BacktestDefaults.dcaAssetOptions
        )
        advice = nextAdvice
        actions = nextActions
    }

    private func waitForRequiredHistory(_ assetOptions: [BacktestAssetOption]) async {
        for _ in 0..<6 {
            guard isMissingRequiredHistory(for: assetOptions) else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard isMissingRequiredHistory(for: assetOptions) else { return }
            await marketStore.refreshHistoryIfNeeded(force: true)
        }
    }

    private func isMissingRequiredHistory(for assetOptions: [BacktestAssetOption]) -> Bool {
        assetOptions.contains { option in
            guard hasUsableHistory(for: option.symbol) else { return true }
            if let fxSymbol = option.historicalFXSymbol {
                return !hasUsableHistory(for: fxSymbol)
            }
            return false
        }
    }

    private func hasUsableHistory(for symbol: String) -> Bool {
        let lookupSymbol = symbol == "usd_cash" ? "usd_per_cny" : symbol
        guard let series = marketStore.history(for: lookupSymbol) else { return false }
        return series.dates.count >= 2 && series.prices.count >= 2
    }

    private func todayStrategySummary(template: AdvancedBacktestStrategyTemplate, advice: StrategyRebalanceAdvice) -> String {
        let preview = StrategyNotificationContentBuilder.preview(template: template, advice: advice, actions: actions)
        if let investmentBase = actions.compactMap(\.investmentBase).first, investmentBase > 0 {
            return AppLocalization.format("按最新记录%@估算；%@", investmentBase.currencyString(), preview)
        }
        if snapshot == nil {
            return AppLocalization.format("暂无资产记录；%@", preview)
        }
        return preview
    }
}
