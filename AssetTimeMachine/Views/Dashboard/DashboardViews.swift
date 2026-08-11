import SwiftUI
import SwiftData
import Charts
import UIKit
import Combine

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
    let marketStore: RemoteMarketStore
    let cloudStore: AssetTimeMachineCloudStore
    let strategyAdviceService: StrategyAdviceService
    let isActive: Bool
    @State private var cachedAllocationSlices: [DashboardAllocationSlice] = []
    @State private var cachedTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedTrendPointValues: [DashboardTrendPointValue] = []
    @State private var cachedFreedomProjection: FinancialFreedomProjection?
    @State private var cachedSnapshotSummary: DashboardSnapshotSummary?
    @State private var hasLoadedDashboardData = false
    @State private var pendingDashboardDataRefreshTask: Task<Void, Never>?
    @State private var pendingDashboardProjectionRefreshTask: Task<Void, Never>?
    @State private var dashboardDataGeneration = 0
    @State private var dashboardProjectionGeneration = 0
    @State private var lastLiveMarketCacheToken: Int?
    @State private var showsTodayStrategyModal = false
    @State private var strategySnapshot: AssetSnapshot?
    @State private var showsCloudSyncModal = false
    @State private var freedomKeyboardDismissSignal = 0

    init(
        marketStore: RemoteMarketStore,
        cloudStore: AssetTimeMachineCloudStore,
        strategyAdviceService: StrategyAdviceService,
        isActive: Bool
    ) {
        self.marketStore = marketStore
        self.cloudStore = cloudStore
        self.strategyAdviceService = strategyAdviceService
        self.isActive = isActive

    }

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

    private var freedomProjectionInput: DashboardFreedomProjectionInput {
        DashboardFreedomProjectionInput(
            monthlySalary: monthlySalary,
            annualReturnRate: annualReturnRate,
            monthlyExpense: monthlyExpense,
            annualInflationRate: inflationRate
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        Group {
                            if !hasLoadedDashboardData {
                                LoadingStateCard(title: AppLocalization.string("首页加载中"))
                            } else {
                                VStack(alignment: .leading, spacing: 22) {
                                    summaryStrip
                                    freedomSection
                                        .id("dashboard-freedom-section")

                                    Color.clear
                                        .frame(height: TabScrollLayout.keyboardDismissSpacer)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            freedomKeyboardDismissSignal += 1
                                        }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                        .padding(.bottom, TabScrollLayout.bottomPadding)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .task {
                        migrateDashboardDefaultsIfNeeded()
                        await cloudStore.refreshIfNeeded(from: modelContext)
                        await focusFreedomSectionIfNeeded(using: proxy)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: isActive) {
            if isActive {
                requestDashboardDataRefresh(
                    delayNanoseconds: hasLoadedDashboardData ? 120_000_000 : 0
                )
                scheduleCloudAutoSync()
            } else {
                cancelDashboardWork()
            }
        }
        .onChange(of: freedomProjectionInput) { _, newInput in
            guard isActive else { return }
            requestDashboardProjectionRefresh(
                input: newInput,
                trendPoints: cachedTrendPointValues,
                delayNanoseconds: 120_000_000
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { notification in
            guard PortfolioSaveNotificationFilter.affectsPortfolio(notification) else { return }
            guard isActive else { return }
            requestDashboardDataRefresh(delayNanoseconds: 80_000_000)
        }
        .onReceive(marketStore.$overview.combineLatest(marketStore.$exchangeRates)) { _ in
            guard isActive else { return }
            let token = marketStore.liveMarketCacheToken()
            guard token != lastLiveMarketCacheToken else { return }
            lastLiveMarketCacheToken = token
            guard hasLoadedDashboardData else { return }
            requestDashboardDataRefresh(delayNanoseconds: 80_000_000)
        }
        .sheet(isPresented: $showsTodayStrategyModal) {
            TodayStrategySheet(
                marketStore: marketStore,
                snapshot: strategySnapshot,
                adviceService: strategyAdviceService
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
        cloudStore.scheduleAutoSync(
            from: modelContext,
            quietly: true,
            delayNanoseconds: delayNanoseconds
        )
    }

    @MainActor
    private func requestDashboardDataRefresh(delayNanoseconds: UInt64) {
        dashboardDataGeneration &+= 1
        dashboardProjectionGeneration &+= 1
        let generation = dashboardDataGeneration

        pendingDashboardDataRefreshTask?.cancel()
        pendingDashboardProjectionRefreshTask?.cancel()
        pendingDashboardDataRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, dashboardDataGeneration == generation else { return }
            await refreshDashboardData(generation: generation)
        }
    }

    @MainActor
    private func refreshDashboardData(generation: Int) async {
        guard let input = await captureDashboardDataInput(generation: generation) else { return }
        guard !Task.isCancelled, dashboardDataGeneration == generation else { return }

        let worker = Task.detached(priority: .utility) {
            DashboardProjectionPipeline.buildData(from: input)
        }
        let output = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        guard !Task.isCancelled,
              dashboardDataGeneration == generation,
              let output else { return }

        cachedSnapshotSummary = output.summary.map {
            DashboardSnapshotSummary(
                totalAssets: $0.totalAssets,
                totalLiabilities: $0.totalLiabilities
            )
        }
        cachedAllocationSlices = makeAllocationSlices(from: output.allocationSlices)
        cachedTrendPointValues = output.trendPoints
        cachedTrendPoints = output.trendPoints.map(\.trendPoint)
        hasLoadedDashboardData = true
        pendingDashboardDataRefreshTask = nil

        requestDashboardProjectionRefresh(
            input: freedomProjectionInput,
            trendPoints: output.trendPoints,
            delayNanoseconds: 0
        )
    }

    @MainActor
    private func requestDashboardProjectionRefresh(
        input: DashboardFreedomProjectionInput,
        trendPoints: [DashboardTrendPointValue],
        delayNanoseconds: UInt64
    ) {
        dashboardProjectionGeneration &+= 1
        let generation = dashboardProjectionGeneration
        pendingDashboardProjectionRefreshTask?.cancel()

        guard !trendPoints.isEmpty else {
            cachedFreedomProjection = nil
            pendingDashboardProjectionRefreshTask = nil
            return
        }

        pendingDashboardProjectionRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, dashboardProjectionGeneration == generation else { return }

            let worker = Task.detached(priority: .utility) {
                DashboardProjectionPipeline.estimateFreedom(
                    trendPoints: trendPoints,
                    input: input
                )
            }
            let projection = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled, dashboardProjectionGeneration == generation else { return }
            cachedFreedomProjection = projection?.projection
            pendingDashboardProjectionRefreshTask = nil
        }
    }

    @MainActor
    private func captureDashboardDataInput(generation: Int) async -> DashboardDataProjectionInput? {
        let liveAnchors = TimeMachineLiveMarketAnchors.from(marketStore: marketStore)
        let liveMarketToken = marketStore.liveMarketCacheToken()
        if liveMarketToken != lastLiveMarketCacheToken {
            lastLiveMarketCacheToken = liveMarketToken
        }
        let container = modelContext.container
        let liveMarket = DashboardLiveMarketProjectionInput(
            goldPriceCNY: liveAnchors.goldPriceCNY,
            btcPriceUSD: liveAnchors.btcPriceUSD,
            btcPriceCNY: liveAnchors.btcPriceCNY,
            nasdaqPriceUSD: liveAnchors.nasdaqPriceUSD,
            nasdaqPriceCNY: liveAnchors.nasdaqPriceCNY
        )
        let otherAllocationTitle = AppLocalization.string("其他")
        let unnamedAllocationTitle = AppLocalization.string("未命名")

        do {
            // Construct the model actor inside the detached closure. Constructing it here on
            // MainActor would make its private ModelContext execute on the UI executor.
            let input = try await BackgroundTaskWork.run {
                let repository = DashboardProjectionRepository(modelContainer: container)
                return try await repository.captureDataInput(
                    liveMarket: liveMarket,
                    otherAllocationTitle: otherAllocationTitle,
                    unnamedAllocationTitle: unnamedAllocationTitle
                )
            }
            guard !Task.isCancelled, dashboardDataGeneration == generation else { return nil }
            return input
        } catch is CancellationError {
            return nil
        } catch {
            print("[AssetTimeMachine] dashboard projection fetch failed: \(error)")
            return nil
        }
    }

    @MainActor
    private func makeAllocationSlices(
        from values: [DashboardAllocationSliceValue]
    ) -> [DashboardAllocationSlice] {
        values.enumerated().map { index, value in
            DashboardAllocationSlice(
                title: AppLocalization.string(value.title),
                amount: value.amount,
                color: DashboardAllocationPalette.colors[index % DashboardAllocationPalette.colors.count],
                details: value.details.map {
                    DashboardAllocationDetail(title: AppLocalization.string($0.title), amount: $0.amount)
                }
            )
        }
    }

    @MainActor
    private func cancelDashboardWork() {
        dashboardDataGeneration &+= 1
        dashboardProjectionGeneration &+= 1
        pendingDashboardDataRefreshTask?.cancel()
        pendingDashboardProjectionRefreshTask?.cancel()
        pendingDashboardDataRefreshTask = nil
        pendingDashboardProjectionRefreshTask = nil
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
                    freedomKeyboardDismissSignal += 1
                    strategySnapshot = try? SnapshotService.latestSnapshot(in: modelContext)
                    showsTodayStrategyModal = true
                } label: {
                    DashboardTodayStrategyButton()
                }
                .buttonStyle(.plain)
                .disabled(StrategyNotificationDefaults.eligibleTemplates.isEmpty)

                Spacer(minLength: 0)

                Button {
                    freedomKeyboardDismissSignal += 1
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
                .contentShape(Rectangle())
                .onTapGesture {
                    freedomKeyboardDismissSignal += 1
                }
            } else {
                EmptyStateCard(
                    title: AppLocalization.string("暂无资产分布"),
                    systemImage: "chart.pie.fill"
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    freedomKeyboardDismissSignal += 1
                }
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
            inflationRate: $inflationRate,
            keyboardDismissSignal: $freedomKeyboardDismissSignal
        )
        .onboardingAnchor(.dashboardFreedom)
    }

}

struct DashboardTodayStrategyButton: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "scope")
                .font(AppTypography.metaStrong)

            Text(AppLocalization.string("今日策略"))
                .font(AppTypography.metaStrong)
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
    @StateObject private var adviceStore: StrategyAdviceProjectionStore
    @State private var hasAttemptedInitialHistoryRefresh = false

    init(
        marketStore: RemoteMarketStore,
        snapshot: AssetSnapshot?,
        adviceService: StrategyAdviceService
    ) {
        self.marketStore = marketStore
        self.snapshot = snapshot
        _adviceStore = StateObject(
            wrappedValue: StrategyAdviceProjectionStore(adviceService: adviceService)
        )
    }

    private var selectedTemplate: AdvancedBacktestStrategyTemplate? {
        StrategyNotificationDefaults.template(for: strategyNotificationTemplateID)
    }

    private var advice: StrategyRebalanceAdvice? { adviceStore.advice }
    private var actions: [StrategyRebalanceAction] { adviceStore.actions }
    private var isRefreshing: Bool { adviceStore.isRefreshing }
    private var statusMessage: String? { adviceStore.statusMessage }

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
            .onDisappear {
                cancelAdviceRefresh()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "scope")
                    .font(AppTypography.blockTitleBold)
                    .foregroundStyle(AssetTheme.goldSoft)
                    .frame(width: 34, height: 34)
                    .background(AssetTheme.gold.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedTemplate?.title ?? AppLocalization.string("未选择策略"))
                        .font(AppTypography.blockTitleBold)
                        .foregroundStyle(AssetTheme.textPrimary)

                    Text(AppLocalization.string("使用设置里的提醒策略生成"))
                        .font(AppTypography.caption)
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
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AssetTheme.textPrimary)

                    Spacer(minLength: 12)

                    Text(AppLocalization.format("信号截至 %@", advice.asOfDate.recordDateString))
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(1)
                }

                Text(todayStrategySummary(template: template, advice: advice))
                    .font(AppTypography.meta)
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
                .font(AppTypography.caption)
                .foregroundStyle(AssetTheme.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    private func todayStrategyStatusCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(AppTypography.sectionTitle)
                .foregroundStyle(AssetTheme.accentOrange)

            Text(message)
                .font(AppTypography.body)
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
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(action.detailText(lookbackSessions: lookbackSessions))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(action.kind.title)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(action.kind.accent)

                Text(action.amountText)
                    .font(AppTypography.rowTitle.monospacedDigit())
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
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(AppLocalization.string("未投入部分保留为防守仓位"))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(weight.percentString(maxFractionDigits: 1))
                .font(AppTypography.rowTitle.monospacedDigit())
                .foregroundStyle(AssetTheme.textSecondary)
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func refreshAdvice(force: Bool) async {
        await adviceStore.refresh(
            templateID: strategyNotificationTemplateID,
            marketStore: marketStore,
            snapshot: snapshot,
            force: force
        )
    }

    @MainActor
    private func cancelAdviceRefresh() {
        adviceStore.cancel()
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
