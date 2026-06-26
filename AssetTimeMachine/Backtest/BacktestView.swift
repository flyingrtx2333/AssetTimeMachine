import SwiftUI
import SwiftData
import Charts
import UIKit

struct BacktestView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var marketStore: RemoteMarketStore
    let isVisible: Bool
    let isActive: Bool
    @Query(sort: \BacktestRecord.createdAt, order: .reverse) private var backtestRecords: [BacktestRecord]
    @State private var selectedPage: BacktestPage = .home
    @State private var backtestMode: BacktestMode = .allocation
    @State private var cashWeight: Double = BacktestDefaults.cashWeight
    @State private var goldWeight: Double = BacktestDefaults.goldWeight
    @State private var indexWeights: [String: Double] = BacktestDefaults.indexWeights
    @State private var dcaAssetSymbol: String = BacktestDefaults.dcaAssetSymbol
    @State private var dcaContributionAmount: Double = BacktestDefaults.dcaContributionAmount
    @State private var dcaIntervalDays: Int = BacktestDefaults.dcaIntervalDays
    @State private var selectedStartDate: Date?
    @State private var selectedEndDate: Date?
    @State private var animationProgress: Double = 1
    @State private var showsAllocationSheet = false
    @State private var showsRangeSheet = false
    @State private var hasStartedBacktest = false
    @State private var hasPlayedInitialBacktestAnimation = false
    @State private var isBacktestLoading = false
    @State private var backtestRefreshToken = 0
    @State private var allocationReport: BacktestReport?
    @State private var dcaReport: DCABacktestReport?
    @State private var displayPoints: [BacktestSeriesPoint] = []
    @State private var cachedSelectedDCAAssetOption: BacktestAssetOption?
    @State private var cachedFilteredGoldSeries: PublicHistorySeries?
    @State private var cachedFilteredIndexSeriesBySymbol: [String: PublicHistorySeries] = [:]
    @State private var cachedFilteredDCASeries: PublicHistorySeries?
    @State private var cachedFilteredDCAFXSeries: PublicHistorySeries?
    @State private var cachedAvailableBacktestBounds: ClosedRange<Date>?
    @State private var cachedEffectiveBacktestBounds: ClosedRange<Date>?
    @State private var lastBacktestDataCacheToken: Int?
    @State private var pendingBacktestDataRefreshTask: Task<Void, Never>?
    @State private var pendingBacktestComputationTask: Task<Void, Never>?
    @State private var selectedBacktestRecord: BacktestRecord?
    @State private var pendingAdvancedRestoreRequest: AdvancedBacktestRestoreRequest?
    @State private var showsAdvancedStrategyLibrary = false
    @State private var showsAllBacktestRecords = false
    @State private var lastSavedBacktestSignature: String?
    @State private var isRestoringBacktestRecord = false
    @State private var lastObservedRelevantHistoryToken: String = ""

    private let recentRecordDisplayLimit = 5

    private enum DCAConfigSheet: String, Identifiable {
        case asset
        case amount
        case interval

        var id: String { rawValue }
    }

    private enum StandardBacktestComputationResult {
        case allocation(BacktestReport?)
        case dca(DCABacktestReport?)

        var points: [BacktestSeriesPoint] {
            switch self {
            case .allocation(let report):
                return report?.points ?? []
            case .dca(let report):
                return report?.points ?? []
            }
        }
    }

    @State private var activeDCAConfigSheet: DCAConfigSheet?

    private let indexOptions = BacktestDefaults.indexOptions
    private let dcaAssetOptions = BacktestDefaults.dcaAssetOptions
    private let strategyTemplates = AdvancedBacktestStrategyTemplate.all

    private var filteredGoldSeries: PublicHistorySeries? {
        cachedFilteredGoldSeries
    }

    private var filteredIndexSeriesBySymbol: [String: PublicHistorySeries] {
        cachedFilteredIndexSeriesBySymbol
    }

    private var positiveIndexOptions: [BacktestIndexOption] {
        indexOptions.filter { indexWeights[$0.symbol, default: 0] > 0 }
    }

    private var selectedDCAAssetOption: BacktestAssetOption? {
        cachedSelectedDCAAssetOption
    }

    private var filteredDCASeries: PublicHistorySeries? {
        cachedFilteredDCASeries
    }

    private var filteredDCAFXSeries: PublicHistorySeries? {
        cachedFilteredDCAFXSeries
    }

    private var animatedPoints: [BacktestSeriesPoint] {
        guard !displayPoints.isEmpty else { return [] }
        let count = max(Int(Double(displayPoints.count) * animationProgress), min(displayPoints.count, 2))
        return Array(displayPoints.prefix(count))
    }

    private var allocationSlices: [BacktestAllocationSlice] {
        [
            BacktestAllocationSlice(title: AppLocalization.string("现金"), amount: cashWeight, color: AssetTheme.textSecondary),
            BacktestAllocationSlice(title: AppLocalization.string("黄金"), amount: goldWeight, color: AssetTheme.gold)
        ] + positiveIndexOptions.map { option in
            BacktestAllocationSlice(title: option.title, amount: indexWeights[option.symbol, default: 0], color: option.color)
        }
        .filter { $0.amount > 0 }
    }

    private var activeAllocationSummary: String {
        let titles = allocationSlices.map(\.title)
        switch titles.count {
        case 0:
            return AppLocalization.string("未配置")
        case 1, 2:
            return titles.joined(separator: " + ")
        default:
            return AppLocalization.format("%d类资产", titles.count)
        }
    }

    private var availableBacktestBounds: ClosedRange<Date>? {
        cachedAvailableBacktestBounds
    }

    private var effectiveBacktestBounds: ClosedRange<Date>? {
        cachedEffectiveBacktestBounds
    }

    private var relevantBacktestHistorySymbols: Set<String> {
        switch backtestMode {
        case .allocation:
            var symbols: Set<String> = ["gold_cny"]
            for (symbol, weight) in indexWeights where weight > 0 {
                symbols.insert(symbol)
            }
            return symbols
        case .dca:
            var symbols: Set<String> = [dcaAssetSymbol]
            if let fxSymbol = cachedSelectedDCAAssetOption?.historicalFXSymbol ?? selectedDCAAssetOption?.historicalFXSymbol {
                symbols.insert(fxSymbol)
            }
            return symbols
        }
    }

    private var relevantHistoryToken: String {
        marketStore.historyRelevanceToken(for: relevantBacktestHistorySymbols)
    }

    private var backtestDataCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(backtestMode.rawValue)
        hasher.combine(cashWeight)
        hasher.combine(goldWeight)
        hasher.combine(dcaAssetSymbol)
        hasher.combine(dcaContributionAmount)
        hasher.combine(dcaIntervalDays)
        hasher.combine(selectedStartDate?.timeIntervalSinceReferenceDate)
        hasher.combine(selectedEndDate?.timeIntervalSinceReferenceDate)

        for symbol in relevantBacktestHistorySymbols.sorted() {
            guard let series = marketStore.history(for: symbol) else {
                hasher.combine(symbol)
                hasher.combine("nil")
                continue
            }
            hasher.combine(symbol)
            hasher.combine(series.dates.count)
            hasher.combine(series.dates.last)
            hasher.combine(series.currency)
        }
        return hasher.finalize()
    }

    private var selectedDateRangeLabel: String {
        guard let effectiveBacktestBounds else { return AppLocalization.string("调整时间") }
        return "\(effectiveBacktestBounds.lowerBound.recordDateString) - \(effectiveBacktestBounds.upperBound.recordDateString)"
    }

    private var selectedDateFilterToken: String {
        let startToken = selectedStartDate?.recordDateString ?? "nil"
        let endToken = selectedEndDate?.recordDateString ?? "nil"
        return "\(backtestMode.rawValue)|\(startToken)|\(endToken)"
    }

    private var hasActiveReport: Bool {
        switch backtestMode {
        case .allocation:
            return allocationReport != nil
        case .dca:
            return dcaReport != nil
        }
    }

    private var selectedTopTab: BacktestTopTab {
        switch selectedPage {
        case .advanced:
            return .advanced
        case .home, .standard:
            switch backtestMode {
            case .allocation:
                return .allocation
            case .dca:
                return .dca
            }
        }
    }

    private var topTabBinding: Binding<BacktestTopTab> {
        Binding(
            get: { selectedTopTab },
            set: { newValue in
                switch newValue {
                case .allocation:
                    selectedPage = .standard
                    backtestMode = .allocation
                case .dca:
                    selectedPage = .standard
                    backtestMode = .dca
                case .advanced:
                    selectedPage = .advanced
                }
            }
        )
    }

    private var activeBacktestPageTitle: String {
        switch selectedPage {
        case .home:
            return BacktestPage.home.title
        case .standard:
            return backtestMode.title
        case .advanced:
            return BacktestRecordKind.advanced.title
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                if isVisible {
                    if !isActive {
                        BacktestEntryLoadingView()
                            .padding(.horizontal, 20)
                    } else {
                        GeometryReader { geometry in
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 14) {
                                    if selectedPage == .home {
                                        BacktestHomeView(
                                            records: Array(backtestRecords.prefix(recentRecordDisplayLimit)),
                                            totalRecordCount: backtestRecords.count,
                                            onStart: { kind in
                                                openBacktestPage(kind)
                                            },
                                            onShowAllRecords: {
                                                showsAllBacktestRecords = true
                                            },
                                            onSelect: { record in
                                                selectedBacktestRecord = record
                                            },
                                            onRestore: { record in
                                                restoreBacktestRecord(record)
                                            },
                                            onDelete: { record in
                                                deleteBacktestRecord(record)
                                            }
                                        )
                                    } else {
                                        BacktestReturnHeader(title: activeBacktestPageTitle) {
                                            selectedPage = .home
                                        }

                                        if selectedPage == .advanced {
                                            AdvancedBacktestView(
                                                marketStore: marketStore,
                                                isActive: isActive,
                                                restoreRequest: pendingAdvancedRestoreRequest,
                                                showsStrategyLibrary: $showsAdvancedStrategyLibrary
                                            )
                                        } else {
                                            VStack(spacing: 18) {
                                                if backtestMode == .allocation {
                                                    BacktestAllocationCard(
                                                        slices: allocationSlices,
                                                        activeAllocationSummary: activeAllocationSummary,
                                                        selectedDateRangeLabel: selectedDateRangeLabel,
                                                        onTapRange: {
                                                            showsRangeSheet = true
                                                        },
                                                        onTapAllocation: {
                                                            showsAllocationSheet = true
                                                        },
                                                        onTapPrimaryAction: hasActiveReport ? nil : {
                                                            hasStartedBacktest = true
                                                            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: true)
                                                        }
                                                    )
                                                    .onboardingAnchor(.backtestConfiguration)
                                                } else {
                                                    BacktestDCACard(
                                                        assetTitle: AppLocalization.string(selectedDCAAssetOption?.title ?? "未选择资产"),
                                                        amount: dcaContributionAmount,
                                                        intervalDays: dcaIntervalDays,
                                                        selectedDateRangeLabel: selectedDateRangeLabel,
                                                        accent: selectedDCAAssetOption?.color ?? AssetTheme.gold,
                                                        onTapRange: {
                                                            showsRangeSheet = true
                                                        },
                                                        onTapAsset: {
                                                            activeDCAConfigSheet = .asset
                                                        },
                                                        onTapAmount: {
                                                            activeDCAConfigSheet = .amount
                                                        },
                                                        onTapInterval: {
                                                            activeDCAConfigSheet = .interval
                                                        },
                                                        onTapPrimaryAction: hasActiveReport ? nil : {
                                                            hasStartedBacktest = true
                                                            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: true)
                                                        }
                                                    )
                                                    .onboardingAnchor(.backtestConfiguration)
                                                }

                                                if !isBacktestLoading, hasActiveReport {
                                                    HStack(spacing: 10) {
                                                        BacktestActionChip(title: AppLocalization.string("重置回测"), systemImage: "arrow.counterclockwise") {
                                                            resetBacktest()
                                                        }
                                                    }
                                                }
                                            }
                                            .frame(maxWidth: .infinity)

                                            if isBacktestLoading {
                                                BacktestLoadingView()
                                                    .padding(.top, 8)
                                            }

                                            if !isBacktestLoading {
                                                switch backtestMode {
                                                case .allocation:
                                                    if let allocationReport {
                                                        allocationReportSection(report: allocationReport)
                                                    }
                                                case .dca:
                                                    if let dcaReport {
                                                        dcaReportSection(report: dcaReport)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                .frame(width: max(0, geometry.size.width - 40), alignment: .topLeading)
                                .padding(.horizontal, 20)
                                .padding(.top, 14)
                                .padding(.bottom, selectedPage == .advanced || hasActiveReport ? 136 : 24)
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                        }
                    }
                } else {
                    Color.clear
                }
            }
            .navigationDestination(isPresented: $showsAllBacktestRecords) {
                BacktestAllRecordsView(
                    records: backtestRecords,
                    onSelect: { record in
                        selectedBacktestRecord = record
                    },
                    onRestore: { record in
                        restoreBacktestRecord(record)
                    },
                    onDelete: { record in
                        deleteBacktestRecord(record)
                    }
                )
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
            .sheet(item: $activeDCAConfigSheet) { sheet in
                switch sheet {
                case .asset:
                    BacktestDCAAssetSheet(
                        selectedSymbol: dcaAssetSymbol,
                        assetOptions: dcaAssetOptions
                    ) { updatedSymbol in
                        applyDCAConfiguration(
                            assetSymbol: updatedSymbol,
                            contributionAmount: dcaContributionAmount,
                            intervalDays: dcaIntervalDays
                        )
                    }
                    .presentationDetents([.fraction(0.52), .large])
                    .presentationDragIndicator(.visible)
                case .amount:
                    BacktestDCAAmountSheet(amount: dcaContributionAmount) { updatedAmount in
                        applyDCAConfiguration(
                            assetSymbol: dcaAssetSymbol,
                            contributionAmount: updatedAmount,
                            intervalDays: dcaIntervalDays
                        )
                    }
                    .presentationDetents([.fraction(0.48), .large])
                    .presentationDragIndicator(.visible)
                case .interval:
                    BacktestDCAIntervalSheet(intervalDays: dcaIntervalDays) { updatedIntervalDays in
                        applyDCAConfiguration(
                            assetSymbol: dcaAssetSymbol,
                            contributionAmount: dcaContributionAmount,
                            intervalDays: updatedIntervalDays
                        )
                    }
                    .presentationDetents([.fraction(0.46), .large])
                    .presentationDragIndicator(.visible)
                }
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
                    .presentationDetents([.fraction(0.82), .large])
                    .presentationDragIndicator(.visible)
                } else {
                    ContentUnavailableView(AppLocalization.string("暂无可用历史数据"), systemImage: "calendar.badge.exclamationmark")
                        .presentationDetents([.fraction(0.32)])
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(item: $selectedBacktestRecord) { record in
                BacktestRecordDetailView(
                    record: record,
                    onRestore: { restoredRecord in
                        restoreBacktestRecord(restoredRecord)
                        selectedBacktestRecord = nil
                    },
                    onDelete: { deletedRecord in
                        deleteBacktestRecord(deletedRecord)
                        selectedBacktestRecord = nil
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .task(id: isActive) {
            if isActive {
                lastObservedRelevantHistoryToken = relevantHistoryToken
                await marketStore.refreshHistoryIfNeeded()
                guard !Task.isCancelled else { return }
                scheduleBacktestDataRefresh(delayNanoseconds: 0)
                if hasStartedBacktest, !hasActiveReport {
                    scheduleBacktestRefresh(animated: !hasPlayedInitialBacktestAnimation, saveRecord: false)
                }
            } else {
                saveCurrentBacktestRecordIfNeeded()
                pendingBacktestDataRefreshTask?.cancel()
                pendingBacktestComputationTask?.cancel()
                pendingBacktestComputationTask = nil
                isBacktestLoading = false
            }
        }
        .onChange(of: selectedPage) { _, newValue in
            guard isActive, !isRestoringBacktestRecord else { return }
            if newValue == .standard || newValue == .advanced {
                Task { await marketStore.refreshHistoryIfNeeded() }
            }
            guard newValue == .standard else { return }
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: false)
        }
        .onChange(of: backtestMode) { _, _ in
            guard isActive, !isRestoringBacktestRecord, selectedPage == .standard else { return }
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: false)
        }
        .onChange(of: selectedDateFilterToken) { _, _ in
            guard isActive, !isRestoringBacktestRecord else { return }
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: false)
        }
        .onChange(of: isActive ? relevantHistoryToken : "") { _, newToken in
            guard isActive, !isRestoringBacktestRecord else { return }
            guard newToken != lastObservedRelevantHistoryToken else { return }
            lastObservedRelevantHistoryToken = newToken
            scheduleBacktestDataRefresh(delayNanoseconds: 40_000_000, force: true)
            guard hasStartedBacktest else { return }
            scheduleBacktestRefresh(animated: !hasActiveReport && !hasPlayedInitialBacktestAnimation, saveRecord: false)
        }
    }

    @MainActor
    private func scheduleBacktestDataRefresh(delayNanoseconds: UInt64, force: Bool = false) {
        pendingBacktestDataRefreshTask?.cancel()
        pendingBacktestDataRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isActive else { return }
                refreshBacktestDataCacheIfNeeded(force: force)
            }
        }
    }

    @MainActor
    private func refreshBacktestDataCacheIfNeeded(force: Bool = false) {
        let token = backtestDataCacheToken
        guard force || token != lastBacktestDataCacheToken else { return }
        refreshBacktestDataCache()
        lastBacktestDataCacheToken = token
    }

    @MainActor
    private func refreshBacktestDataCache() {
        let selectedOption = dcaAssetOptions.first(where: { $0.symbol == dcaAssetSymbol })
        cachedSelectedDCAAssetOption = selectedOption

        let sourceSeries = resolveActiveBacktestSourceSeries(selectedOption: selectedOption)
        let bounds = BacktestEngine.availableDateBounds(for: sourceSeries)
        cachedAvailableBacktestBounds = bounds

        let effectiveBounds: ClosedRange<Date>?
        if let bounds {
            let start = max(selectedStartDate ?? bounds.lowerBound, bounds.lowerBound)
            let end = min(selectedEndDate ?? bounds.upperBound, bounds.upperBound)
            effectiveBounds = start <= end ? (start...end) : bounds
        } else {
            effectiveBounds = nil
        }
        cachedEffectiveBacktestBounds = effectiveBounds

        cachedFilteredGoldSeries = filteredHistorySeries(marketStore.history(for: "gold_cny"), within: effectiveBounds)
        cachedFilteredIndexSeriesBySymbol = Dictionary(uniqueKeysWithValues: indexOptions.compactMap { option in
            guard let series = filteredHistorySeries(marketStore.history(for: option.symbol), within: effectiveBounds) else { return nil }
            return (option.symbol, series)
        })
        cachedFilteredDCASeries = filteredHistorySeries(marketStore.history(for: dcaAssetSymbol), within: effectiveBounds)
        if let fxSymbol = selectedOption?.historicalFXSymbol {
            cachedFilteredDCAFXSeries = filteredHistorySeries(marketStore.history(for: fxSymbol), within: effectiveBounds)
        } else {
            cachedFilteredDCAFXSeries = nil
        }
    }

    private func resolveActiveBacktestSourceSeries(selectedOption: BacktestAssetOption?) -> [PublicHistorySeries] {
        if backtestMode == .dca {
            guard let assetSeries = marketStore.history(for: dcaAssetSymbol) else { return [] }
            guard let selectedOption else { return [assetSeries] }

            if let fxSymbol = selectedOption.historicalFXSymbol {
                guard let fxSeries = marketStore.history(for: fxSymbol) else { return [] }
                return [assetSeries, fxSeries]
            }

            return [assetSeries]
        }

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

    @MainActor
    private func openBacktestPage(_ kind: BacktestRecordKind) {
        switch kind {
        case .allocation:
            selectedPage = .standard
            backtestMode = .allocation
        case .dca:
            selectedPage = .standard
            backtestMode = .dca
        case .advanced:
            selectedPage = .advanced
        }
    }

    private func applyAllocation(cashWeight: Double, goldWeight: Double, indexWeights: [String: Double]) {
        self.cashWeight = cashWeight
        self.goldWeight = goldWeight
        self.indexWeights = indexWeights

        if isActive {
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
        }
        guard hasStartedBacktest else { return }
        scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: false)
    }

    private func applyDCAConfiguration(assetSymbol: String, contributionAmount: Double, intervalDays: Int) {
        dcaAssetSymbol = assetSymbol
        dcaContributionAmount = contributionAmount
        dcaIntervalDays = intervalDays

        if isActive {
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
        }
        guard hasStartedBacktest else { return }
        scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: false)
    }

    @MainActor
    private func scheduleBacktestRefresh(
        animated: Bool,
        forceAnimation: Bool = false,
        showLoading: Bool = false,
        saveRecord: Bool = false
    ) {
        backtestRefreshToken += 1
        let currentToken = backtestRefreshToken
        pendingBacktestComputationTask?.cancel()
        pendingBacktestComputationTask = nil

        if showLoading {
            isBacktestLoading = true
        }

        let delayNanoseconds: UInt64 = showLoading ? 350_000_000 : 0
        pendingBacktestComputationTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            refreshBacktestDataCacheIfNeeded()
            let mode = backtestMode
            let capturedCashWeight = cashWeight
            let capturedGoldWeight = goldWeight
            let capturedGoldSeries = filteredGoldSeries
            let capturedIndexWeights = indexWeights
            let capturedIndexSeriesBySymbol = filteredIndexSeriesBySymbol
            let capturedDCASeries = filteredDCASeries
            let capturedDCAAssetOption = selectedDCAAssetOption ?? BacktestDefaults.dcaAssetOptions[0]
            let capturedDCAFXSeries = filteredDCAFXSeries
            let capturedDCAContributionAmount = dcaContributionAmount
            let capturedDCAIntervalDays = dcaIntervalDays

            let computationTask = Task.detached(priority: .userInitiated) { () -> StandardBacktestComputationResult in
                switch mode {
                case .allocation:
                    return .allocation(BacktestEngine.run(
                        cashWeight: capturedCashWeight,
                        goldWeight: capturedGoldWeight,
                        goldSeries: capturedGoldSeries,
                        indexWeights: capturedIndexWeights,
                        indexSeriesBySymbol: capturedIndexSeriesBySymbol
                    ))
                case .dca:
                    return .dca(BacktestEngine.runDCA(
                        assetSeries: capturedDCASeries,
                        assetOption: capturedDCAAssetOption,
                        fxSeries: capturedDCAFXSeries,
                        contributionAmount: capturedDCAContributionAmount,
                        intervalDays: capturedDCAIntervalDays
                    ))
                }
            }

            let result = await withTaskCancellationHandler {
                await computationTask.value
            } onCancel: {
                computationTask.cancel()
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard currentToken == backtestRefreshToken else { return }
                applyBacktestResult(result, animated: animated, forceAnimation: forceAnimation, saveRecord: saveRecord)
                isBacktestLoading = false
                pendingBacktestComputationTask = nil
            }
        }
    }

    @MainActor
    private func applyBacktestResult(_ result: StandardBacktestComputationResult, animated: Bool, forceAnimation: Bool = false, saveRecord: Bool = false) {
        switch result {
        case .allocation(let report):
            allocationReport = report
            dcaReport = nil
        case .dca(let report):
            dcaReport = report
            allocationReport = nil
        }

        displayPoints = sampledChartPoints(from: result.points)
        if saveRecord {
            saveCurrentBacktestRecordIfNeeded()
        }

        let shouldAnimate = animated && !displayPoints.isEmpty && (forceAnimation || !hasPlayedInitialBacktestAnimation)
        guard shouldAnimate else {
            animationProgress = 1
            return
        }

        hasPlayedInitialBacktestAnimation = true
        restartAnimation()
    }

    @MainActor
    private func saveCurrentBacktestRecordIfNeeded() {
        switch backtestMode {
        case .allocation:
            guard let report = allocationReport, !report.points.isEmpty else { return }
            let configSummary = allocationConfigSummary()
            let config = BacktestRecordConfigPayload(
                kind: .allocation,
                cashWeight: cashWeight,
                goldWeight: goldWeight,
                indexWeights: indexWeights
            )
            let record = BacktestRecord(
                kindRawValue: BacktestRecordKind.allocation.rawValue,
                title: BacktestRecordKind.allocation.title,
                subtitle: AppLocalization.format("%@ · %@", selectedDateRangeLabel, activeAllocationSummary),
                configSummary: configSummary,
                startDate: report.points.first?.date,
                endDate: report.points.last?.date,
                totalReturn: report.totalReturn,
                annualizedReturn: report.annualizedReturn,
                maxDrawdown: report.maxDrawdown,
                annualizedVolatility: report.annualizedVolatility,
                sharpeRatio: report.sharpeRatio,
                finalValue: report.points.last?.portfolioValue,
                tradeCount: 0,
                pointsJSON: BacktestRecordCodec.pointsData(from: report.points),
                configJSON: BacktestRecordCodec.configData(from: config)
            )
            insertBacktestRecord(record)
        case .dca:
            guard let report = dcaReport, !report.points.isEmpty else { return }
            let assetTitle = AppLocalization.string(selectedDCAAssetOption?.title ?? "单资产")
            let config = BacktestRecordConfigPayload(
                kind: .dca,
                dcaAssetSymbol: dcaAssetSymbol,
                dcaContributionAmount: dcaContributionAmount,
                dcaIntervalDays: dcaIntervalDays
            )
            let record = BacktestRecord(
                kindRawValue: BacktestRecordKind.dca.rawValue,
                title: BacktestRecordKind.dca.title,
                subtitle: AppLocalization.format("%@ · %@", selectedDateRangeLabel, assetTitle),
                configSummary: AppLocalization.format("%@ · 每%d天投入%@", assetTitle, dcaIntervalDays, dcaContributionAmount.currencyString()),
                startDate: report.points.first?.date,
                endDate: report.points.last?.date,
                totalReturn: report.totalReturn,
                annualizedReturn: report.annualizedReturn,
                maxDrawdown: report.maxDrawdown,
                annualizedVolatility: report.annualizedVolatility,
                sharpeRatio: report.sharpeRatio,
                finalValue: report.finalPortfolioValue,
                totalInvested: report.totalInvested,
                profitLoss: report.profitLoss,
                tradeCount: report.contributionCount,
                pointsJSON: BacktestRecordCodec.pointsData(from: report.points),
                configJSON: BacktestRecordCodec.configData(from: config)
            )
            insertBacktestRecord(record)
        }
    }

    @MainActor
    private func insertBacktestRecord(_ record: BacktestRecord) {
        let signature = [
            record.kindRawValue,
            record.subtitle,
            record.configSummary,
            record.startDate?.recordDateString ?? "nil",
            record.endDate?.recordDateString ?? "nil",
            String(format: "%.8f", record.totalReturn),
            String(format: "%.8f", record.maxDrawdown),
            String(format: "%.4f", record.finalValue ?? 0),
            String(record.tradeCount)
        ].joined(separator: "|")

        guard signature != lastSavedBacktestSignature else { return }
        lastSavedBacktestSignature = signature

        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            print("[AssetTimeMachine] save backtest record failed: \(error)")
        }
    }

    private func allocationConfigSummary() -> String {
        let parts = allocationSlices.map { slice in
            AppLocalization.format("%@ %.0f%%", slice.title, slice.amount)
        }
        return parts.isEmpty ? AppLocalization.string("未配置资产") : parts.joined(separator: " · ")
    }

    @MainActor
    private func deleteBacktestRecord(_ record: BacktestRecord) {
        modelContext.delete(record)
        do {
            try modelContext.save()
        } catch {
            print("[AssetTimeMachine] delete backtest record failed: \(error)")
        }
    }

    @MainActor
    private func restoreBacktestRecord(_ record: BacktestRecord) {
        guard let config = BacktestRecordCodec.decodeConfig(from: record) else { return }
        isRestoringBacktestRecord = true
        defer {
            Task { @MainActor in
                await Task.yield()
                isRestoringBacktestRecord = false
            }
        }

        switch config.kind {
        case .allocation:
            selectedPage = .standard
            backtestMode = .allocation
            cashWeight = config.cashWeight ?? BacktestDefaults.cashWeight
            goldWeight = config.goldWeight ?? BacktestDefaults.goldWeight
            indexWeights = config.indexWeights ?? BacktestDefaults.indexWeights
            selectedStartDate = record.startDate
            selectedEndDate = record.endDate
            hasStartedBacktest = true
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: false)
        case .dca:
            selectedPage = .standard
            backtestMode = .dca
            dcaAssetSymbol = config.dcaAssetSymbol ?? BacktestDefaults.dcaAssetSymbol
            dcaContributionAmount = config.dcaContributionAmount ?? BacktestDefaults.dcaContributionAmount
            dcaIntervalDays = config.dcaIntervalDays ?? BacktestDefaults.dcaIntervalDays
            selectedStartDate = record.startDate
            selectedEndDate = record.endDate
            hasStartedBacktest = true
            scheduleBacktestDataRefresh(delayNanoseconds: 0, force: true)
            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true, saveRecord: false)
        case .advanced:
            selectedPage = .advanced
            pendingAdvancedRestoreRequest = AdvancedBacktestRestoreRequest(
                id: UUID(),
                config: config,
                startDate: record.startDate,
                endDate: record.endDate
            )
        }
    }

    private func resetBacktest() {
        backtestRefreshToken += 1
        hasStartedBacktest = false
        hasPlayedInitialBacktestAnimation = false
        isBacktestLoading = false
        backtestMode = .allocation
        cashWeight = BacktestDefaults.cashWeight
        goldWeight = BacktestDefaults.goldWeight
        indexWeights = BacktestDefaults.indexWeights
        dcaAssetSymbol = BacktestDefaults.dcaAssetSymbol
        dcaContributionAmount = BacktestDefaults.dcaContributionAmount
        dcaIntervalDays = BacktestDefaults.dcaIntervalDays
        selectedStartDate = nil
        selectedEndDate = nil
        allocationReport = nil
        dcaReport = nil
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

    private func filteredHistorySeries(_ series: PublicHistorySeries?, within bounds: ClosedRange<Date>? = nil) -> PublicHistorySeries? {
        BacktestEngine.filteredHistorySeries(series, within: bounds ?? effectiveBacktestBounds)
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

        return sampled.enumerated().map { index, point in
            BacktestSeriesPoint(date: point.date, portfolioValue: point.portfolioValue, sequence: index)
        }
    }

    private func recoveryTimeLabel(for report: BacktestReport) -> String {
        guard report.maxDrawdown > 0 else { return "--" }
        guard let days = report.maxDrawdownRecoveryDays else { return AppLocalization.string("未修复") }
        if days >= 365 {
            let years = Double(days) / 365.25
            return AppLocalization.format("%.1f年", years)
        }
        return AppLocalization.format("%d天", days)
    }

    @ViewBuilder
    private func allocationReportSection(report: BacktestReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppLocalization.string("组合净值"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Spacer()
            }

            InteractiveBacktestChart(points: animatedPoints)
        }
        .padding(.top, 8)

        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalization.string("分析报告"))
                .font(.headline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                BacktestMetricCard(title: AppLocalization.string("总收益"), value: report.totalReturn.percentString())
                BacktestMetricCard(title: AppLocalization.string("年化收益"), value: report.annualizedReturn?.percentString() ?? "--")
                BacktestMetricCard(title: AppLocalization.string("最大回撤"), value: report.maxDrawdown.percentString(), accent: AssetTheme.negative)
                BacktestMetricCard(title: AppLocalization.string("修复时间"), value: recoveryTimeLabel(for: report))
                BacktestMetricCard(title: AppLocalization.string("年化波动"), value: report.annualizedVolatility?.percentString() ?? "--")
                BacktestMetricCard(title: AppLocalization.string("夏普比率"), value: report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                BacktestMetricCard(title: AppLocalization.string("区间"), value: intervalLabel(for: report))
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func dcaReportSection(report: DCABacktestReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppLocalization.string("定投市值"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Spacer()
            }

            InteractiveBacktestChart(points: animatedPoints, valueStyle: .currency(code: "CNY"))
        }
        .padding(.top, 8)

        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalization.string("分析报告"))
                .font(.headline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                BacktestMetricCard(title: AppLocalization.string("累计投入"), value: report.totalInvested.currencyString())
                BacktestMetricCard(title: AppLocalization.string("期末市值"), value: report.finalPortfolioValue.currencyString())
                BacktestMetricCard(
                    title: AppLocalization.string("累计盈亏"),
                    value: report.profitLoss.currencyString(),
                    accent: report.profitLoss >= 0 ? AssetTheme.positive : AssetTheme.negative
                )
                BacktestMetricCard(
                    title: AppLocalization.string("收益率"),
                    value: report.totalReturn.percentString(),
                    accent: report.totalReturn >= 0 ? AssetTheme.positive : AssetTheme.negative
                )
                BacktestMetricCard(title: AppLocalization.string("年化收益"), value: report.annualizedReturn?.percentString() ?? "--")
                BacktestMetricCard(title: AppLocalization.string("最大回撤"), value: report.maxDrawdown.percentString(), accent: AssetTheme.negative)
                BacktestMetricCard(title: AppLocalization.string("年化波动"), value: report.annualizedVolatility?.percentString() ?? "--")
                BacktestMetricCard(title: AppLocalization.string("夏普比率"), value: report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                BacktestMetricCard(title: AppLocalization.string("定投次数"), value: AppLocalization.format("%d次", report.contributionCount))
                BacktestMetricCard(title: AppLocalization.string("持有份额"), value: report.totalUnits.plainNumberString())
                BacktestMetricCard(title: AppLocalization.string("区间"), value: intervalLabel(points: report.points))
                BacktestMetricCard(title: AppLocalization.string("定投频率"), value: AppLocalization.format("每%d天", dcaIntervalDays))
            }
        }
        .padding(.top, 8)
    }

    private func intervalLabel(points: [BacktestSeriesPoint]) -> String {
        guard let first = points.first?.date, let last = points.last?.date else { return "--" }
        return "\(first.shortDateString) - \(last.shortDateString)"
    }

}

struct BacktestAllocationCard: View {
    let slices: [BacktestAllocationSlice]
    let activeAllocationSummary: String
    let selectedDateRangeLabel: String
    let onTapRange: () -> Void
    let onTapAllocation: () -> Void
    let onTapPrimaryAction: (() -> Void)?

    private let chartSize: CGFloat = 148
    private let summaryCardWidth: CGFloat = 168

    var body: some View {
        VStack(spacing: 0) {
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

                Button(action: onTapAllocation) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Button(action: onTapAllocation) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        Chart(slices) { slice in
                            SectorMark(
                                angle: .value(AppLocalization.string("占比"), slice.amount),
                                innerRadius: .ratio(0.72),
                                angularInset: 2
                            )
                            .foregroundStyle(slice.color)
                        }
                        .frame(width: chartSize, height: chartSize)
                        .chartLegend(.hidden)

                        VStack(spacing: 4) {
                            Text(activeAllocationSummary)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AssetTheme.textPrimary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.72)
                        }
                        .padding(.horizontal, 14)
                    }
                    .frame(width: chartSize, height: chartSize)

                    VStack(spacing: 0) {
                        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                            BacktestAllocationRow(slice: slice, showsDivider: index < slices.count - 1)
                        }
                    }
                    .frame(width: summaryCardWidth, height: chartSize, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .buttonStyle(.plain)

            if let onTapPrimaryAction {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(AssetTheme.border.opacity(0.34))
                        .frame(height: 1)
                        .padding(.horizontal, 18)

                    HStack {
                        BacktestPrimaryActionButton(title: AppLocalization.string("开始回测"), systemImage: "play.fill", action: onTapPrimaryAction)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .onboardingAnchor(.backtestStart)
            }
        }
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.04), AssetTheme.overlaySoft.opacity(0.3), Color.black.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.1), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.1), radius: 16, y: 8)
        .frame(maxWidth: .infinity)
    }
}

struct BacktestAllocationRow: View {
    let slice: BacktestAllocationSlice
    let showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(slice.color)
                    .frame(width: 9, height: 9)

                Text(AppLocalization.string(slice.title))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(Int(slice.amount.rounded()))%")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if showsDivider {
                Rectangle()
                    .fill(AssetTheme.border.opacity(0.45))
                    .frame(height: 1)
                    .padding(.leading, 33)
            }
        }
    }
}

struct BacktestTopTabPicker: View {
    @Binding var selectedTab: BacktestTopTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(BacktestTopTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.title)
                        .font(selectedTab == tab ? .subheadline.weight(.semibold) : .subheadline.weight(.medium))
                        .foregroundStyle(selectedTab == tab ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selectedTab == tab
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.1), AssetTheme.overlayMedium.opacity(0.96)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(selectedTab == tab ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1)
                        )
                        .shadow(color: selectedTab == tab ? Color.black.opacity(0.16) : .clear, radius: 8, y: 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.025), AssetTheme.overlaySoft.opacity(0.52)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

struct CashYieldDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let summary: CashYieldSummary

    private var periodText: String {
        guard let startDate = summary.startDate, let endDate = summary.endDate else {
            return AppLocalization.string("全部可用区间")
        }
        return "\(startDate.recordDateString) - \(endDate.recordDateString)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                        Text(summary.sourceDetail)
                            .font(.footnote)
                            .foregroundStyle(AssetTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        CashYieldMetricTile(
                            title: AppLocalization.string("现金利息"),
                            value: summary.totalCashInterest.currencyString(),
                            accent: AssetTheme.positive
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("平均现金仓"),
                            value: summary.averageCashRatio.percentString(maxFractionDigits: 1)
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("区间平均年利率"),
                            value: summary.averageAnnualRate.percentString(maxFractionDigits: 2)
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("最新年利率"),
                            value: summary.latestAnnualRate.percentString(maxFractionDigits: 2),
                            subtitle: summary.latestRateDate?.recordDateString
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLocalization.string("数据来源"))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                        Text(summary.source)
                            .font(.footnote)
                            .foregroundStyle(AssetTheme.textSecondary)
                        Text(AppLocalization.format("适用区间 %@", periodText))
                            .font(.caption)
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.9))
                    }
                    .padding(14)
                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AssetTheme.border.opacity(0.5), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text(AppLocalization.string("历史活期利率"))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)

                        VStack(spacing: 0) {
                            ForEach(summary.ratePoints.indices, id: \.self) { index in
                                let point = summary.ratePoints[index]
                                HStack(spacing: 12) {
                                    Text(point.date.recordDateString)
                                        .font(.footnote.weight(.medium).monospacedDigit())
                                        .foregroundStyle(AssetTheme.textPrimary)
                                    Spacer(minLength: 12)
                                    Text(point.annualRate.percentString(maxFractionDigits: 2))
                                        .font(.footnote.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(AssetTheme.gold)
                                }
                                .padding(.vertical, 10)

                                if index < summary.ratePoints.count - 1 {
                                    Divider()
                                        .overlay(AssetTheme.border.opacity(0.45))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(AssetTheme.border.opacity(0.5), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(AssetTheme.background.ignoresSafeArea())
            .navigationTitle(AppLocalization.string("现金利率明细"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct MarketRiskSignalDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let summary: MarketRiskSignalSummary

    private var latestLevel: MarketRiskSignalLevel {
        summary.latestPoint?.level ?? .calm
    }

    private var periodText: String {
        guard let startDate = summary.startDate, let endDate = summary.endDate else {
            return AppLocalization.string("全部可用区间")
        }
        return "\(startDate.recordDateString) - \(endDate.recordDateString)"
    }

    private var displayPoints: [MarketRiskSignalPoint] {
        Array(summary.signalPoints.reversed())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                        Text(summary.sourceDetail)
                            .font(.footnote)
                            .foregroundStyle(AssetTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        CashYieldMetricTile(
                            title: AppLocalization.string("当前状态"),
                            value: latestLevel.title,
                            subtitle: summary.latestPoint?.date.recordDateString,
                            accent: latestLevel.accent
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("当前分数"),
                            value: summary.latestPoint.map { String(format: "%.0f", $0.score) } ?? "--",
                            accent: latestLevel.accent
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("压力日占比"),
                            value: summary.stressSessionRatio.percentString(maxFractionDigits: 1)
                        )
                        CashYieldMetricTile(
                            title: AppLocalization.string("区间平均分"),
                            value: String(format: "%.0f", summary.averageScore)
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLocalization.string("数据来源"))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                        Text(summary.source)
                            .font(.footnote)
                            .foregroundStyle(AssetTheme.textSecondary)
                        Text(AppLocalization.format("适用区间 %@", periodText))
                            .font(.caption)
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.9))
                    }
                    .padding(14)
                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AssetTheme.border.opacity(0.5), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text(AppLocalization.string("历史风险信号"))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)

                        VStack(spacing: 0) {
                            ForEach(displayPoints.indices, id: \.self) { index in
                                let point = displayPoints[index]
                                marketRiskSignalPointRow(point)

                                if index < displayPoints.count - 1 {
                                    Divider()
                                        .overlay(AssetTheme.border.opacity(0.45))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(AssetTheme.border.opacity(0.5), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(AssetTheme.background.ignoresSafeArea())
            .navigationTitle(AppLocalization.string("风险信号明细"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func marketRiskSignalPointRow(_ point: MarketRiskSignalPoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(point.date.recordDateString)
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(point.level.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(point.level.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(point.level.accent.opacity(0.12), in: Capsule())

                Spacer(minLength: 10)

                Text(String(format: "%.0f", point.score))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(point.level.accent)
            }

            Text(AppLocalization.format(
                "5日%@ · 21日%@ · 回撤%@ · 波动%@",
                point.shortReturn?.percentString(maxFractionDigits: 1) ?? "--",
                point.monthlyReturn?.percentString(maxFractionDigits: 1) ?? "--",
                point.drawdownFromHigh?.percentString(maxFractionDigits: 1) ?? "--",
                point.annualizedVolatility?.percentString(maxFractionDigits: 1) ?? "--"
            ))
            .font(.caption)
            .foregroundStyle(AssetTheme.textSecondary)
            .lineLimit(1)
        }
        .padding(.vertical, 10)
    }
}

struct CashYieldMetricTile: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var accent: Color = AssetTheme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(accent)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AssetTheme.overlaySoft.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.42), lineWidth: 1)
        )
    }
}
