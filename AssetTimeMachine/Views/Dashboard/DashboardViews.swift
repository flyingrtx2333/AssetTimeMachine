import SwiftUI
import SwiftData
import Combine

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appLanguageStore: AppLanguageStore
    @AppStorage("dashboard.monthlyExpense") private var monthlyExpense: Double = 3000
    @AppStorage("dashboard.monthlyExpenseSeedVersion") private var monthlyExpenseSeedVersion: Int = 0
    @AppStorage("dashboard.inflationRate") private var inflationRate: Double = 0.05
    @AppStorage("dashboard.inflationRateSeedVersion") private var inflationRateSeedVersion: Int = 0
    @AppStorage("dashboard.monthlySalary") private var monthlySalary: Double = 10000
    @AppStorage("dashboard.monthlySalarySeedVersion") private var monthlySalarySeedVersion: Int = 0
    @AppStorage("dashboard.annualReturnRate") private var annualReturnRate: Double = 0.03
    @AppStorage("dashboard.amountsVisible") private var amountsVisible = true
    let marketStore: RemoteMarketStore
    let cloudStore: AssetTimeMachineCloudStore
    let isActive: Bool
    let onOpenQuant: () -> Void
    let onOpenRecords: () -> Void
    @State private var cachedAllocationSlices: [DashboardAllocationSlice] = []
    @State private var cachedTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedRecentTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedThirtyDayChange: Double?
    @State private var cachedTrendPointValues: [DashboardTrendPointValue] = []
    @State private var cachedFreedomProjection: FinancialFreedomProjection?
    @State private var cachedTotalAssets: Double?
    @State private var hasLoadedDashboardData = false
    @State private var pendingDashboardDataRefreshTask: Task<Void, Never>?
    @State private var pendingDashboardProjectionRefreshTask: Task<Void, Never>?
    @State private var dashboardDataGeneration = 0
    @State private var dashboardProjectionGeneration = 0
    @State private var lastLiveMarketCacheToken: Int?
    @State private var showsCloudSyncModal = false
    @State private var freedomKeyboardDismissSignal = 0

    init(
        marketStore: RemoteMarketStore,
        cloudStore: AssetTimeMachineCloudStore,
        isActive: Bool,
        onOpenQuant: @escaping () -> Void,
        onOpenRecords: @escaping () -> Void
    ) {
        self.marketStore = marketStore
        self.cloudStore = cloudStore
        self.isActive = isActive
        self.onOpenQuant = onOpenQuant
        self.onOpenRecords = onOpenRecords
    }

    private var totalAssets: Double {
        cachedTotalAssets ?? 0
    }

    private var allocationSlices: [DashboardAllocationSlice] {
        cachedAllocationSlices
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
                                VStack(alignment: .leading, spacing: 0) {
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
                        .padding(.top, 16)
                        .padding(.bottom, TabScrollLayout.bottomPadding)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .task {
                        migrateDashboardDefaultsIfNeeded()
                        await cloudStore.refreshIfNeeded(from: modelContext)
                    }
                    .onChange(of: hasLoadedDashboardData) { _, hasLoaded in
                        guard hasLoaded else { return }
                        Task {
                            await focusFreedomSectionIfNeeded(using: proxy)
                        }
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
        .onChange(of: appLanguageStore.language) { _, _ in
            guard isActive else { return }
            requestDashboardDataRefresh(delayNanoseconds: 0)
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

        cachedTotalAssets = output.totalAssets
        cachedAllocationSlices = makeAllocationSlices(from: output.allocationSlices)
        cachedTrendPointValues = output.trendPoints
        cachedTrendPoints = output.trendPoints.map(\.trendPoint)
        updateRecentTrendCache(from: cachedTrendPoints)
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

    @MainActor
    private func updateRecentTrendCache(from points: [TimeMachineTrendPoint]) {
        guard let latest = points.last else {
            cachedRecentTrendPoints = []
            cachedThirtyDayChange = nil
            return
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: latest.date) ?? latest.date
        let recent = points.filter { $0.date >= cutoff }
        cachedRecentTrendPoints = evenlySampledItems(recent, maxCount: 48)

        guard let first = recent.first,
              first.mainAssets.isFinite,
              latest.mainAssets.isFinite,
              abs(first.mainAssets) > .ulpOfOne else {
            cachedThirtyDayChange = nil
            return
        }
        cachedThirtyDayChange = (latest.mainAssets / first.mainAssets) - 1
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
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo("dashboard-freedom-projection", anchor: .center)
        }
    }

    private var summaryStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            dashboardGreeting
                .padding(.bottom, 16)

            HStack(alignment: .center, spacing: 10) {
                Button {
                    freedomKeyboardDismissSignal += 1
                    onOpenQuant()
                } label: {
                    DashboardTodayStrategyButton()
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    freedomKeyboardDismissSignal += 1
                    onOpenRecords()
                } label: {
                    DashboardQuickRecordButton()
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 20)

            DashboardAssetHero(
                totalAmount: totalAssets,
                recentPoints: cachedRecentTrendPoints,
                thirtyDayChange: cachedThirtyDayChange,
                amountsVisible: $amountsVisible
            )
            .padding(.bottom, 20)

            if !allocationSlices.isEmpty {
                DashboardAllocationChart(
                    slices: allocationSlices,
                    totalAmount: totalAssets,
                    amountsVisible: amountsVisible
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
                .padding(.top, 20)
        }
        .onboardingAnchor(.dashboardAllocation)
    }

    private var dashboardGreeting: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(AppLocalization.string(greetingKey))
                .font(.system(size: 28, weight: .bold, design: .default))
                .foregroundStyle(AssetTheme.textPrimary)

            Spacer(minLength: 12)

            Button {
                freedomKeyboardDismissSignal += 1
                showsCloudSyncModal = true
            } label: {
                DashboardCloudStatusButton(store: cloudStore)
            }
            .buttonStyle(.plain)
        }
    }

    private var greetingKey: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:
            return "早上好"
        case 12..<18:
            return "下午好"
        default:
            return "晚上好"
        }
    }

    private var freedomSection: some View {
        DashboardFreedomSection(
            projection: freedomProjection,
            monthlySalary: $monthlySalary,
            annualReturnRate: $annualReturnRate,
            monthlyExpense: $monthlyExpense,
            inflationRate: $inflationRate,
            keyboardDismissSignal: $freedomKeyboardDismissSignal,
            amountsVisible: amountsVisible
        )
        .onboardingAnchor(.dashboardFreedom)
    }

}

struct DashboardTodayStrategyButton: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "scope")
                .font(.system(size: 14, weight: .semibold))

            Text(AppLocalization.string("今日策略"))
                .font(.system(size: 14, weight: .semibold))

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(AssetTheme.goldSoft)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(AssetTheme.overlaySubtle.opacity(0.34), in: Capsule())
        .overlay(
            Capsule()
                .stroke(AssetTheme.gold.opacity(0.3), lineWidth: 1)
        )
    }
}

struct DashboardCloudStatusButton: View {
    @ObservedObject var store: AssetTimeMachineCloudStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: store.indicatorState.cloudSymbolName)
                .font(.system(size: 14, weight: .semibold))

            Text(store.indicatorLabel)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundStyle(store.indicatorState.symbolColor)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct DashboardQuickRecordButton: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: 42, height: 42)
                .background(AssetTheme.gold, in: Circle())

            Text(AppLocalization.string("记一笔"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AssetTheme.goldSoft)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppLocalization.string("记一笔"))
    }
}
