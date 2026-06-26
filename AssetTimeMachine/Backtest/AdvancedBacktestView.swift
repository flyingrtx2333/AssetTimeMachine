import SwiftUI
import SwiftData
import Charts
import UIKit

struct AdvancedBacktestView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var marketStore: RemoteMarketStore
    let isActive: Bool
    let restoreRequest: AdvancedBacktestRestoreRequest?
    @Binding var showsStrategyLibrary: Bool
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @State private var selectedAssetSymbols: Set<String> = [BacktestDefaults.dcaAssetSymbol]
    @State private var initialCash: Double = 100_000
    @State private var tradeAmount: Double = 10_000
    @State private var feeRate: Double = 1.0
    @State private var slippageRate: Double = 0.05
    @State private var maxPositionRatio: Double = 70
    @State private var cooldownDays: Double = 3
    @State private var stopLossRatio: Double = 0
    @State private var takeProfitRatio: Double = 0
    @State private var strategyMode: AdvancedBacktestStrategyMode = .ruleBased
    @State private var buyDirection: AdvancedBacktestSignalDirection = .consecutiveDown
    @State private var buyDays: Int = 3
    @State private var sellDirection: AdvancedBacktestSignalDirection = .consecutiveUp
    @State private var sellDays: Int = 3
    @State private var selectedStartDate: Date?
    @State private var selectedEndDate: Date?
    @State private var showsRangeSheet = false
    @State private var showsAssetSheet = false
    @State private var showsCashYieldSheet = false
    @State private var showsRiskSignalSheet = false
    @State private var hasStartedBacktest = false
    @State private var report: AdvancedBacktestReport?
    @State private var cachedComparisonSeries: [BacktestChartComparisonSeries] = []
    @State private var rebalanceAdvice: StrategyRebalanceAdvice?
    @State private var bestCandidates: [AdvancedBacktestCandidate] = []
    @State private var hasOptimizedStrategies = false
    @State private var isRefreshingReport = false
    @State private var isOptimizingStrategies = false
    @State private var isLoadingRequiredHistory = false
    @State private var pendingRefreshTask: Task<Void, Never>?
    @State private var pendingReportComputationTask: Task<AdvancedBacktestComputationResult, Never>?
    @State private var pendingOptimizationComputationTask: Task<[AdvancedBacktestCandidate], Never>?
    @State private var lastSavedAdvancedBacktestSignature: String?
    @State private var cachedSelectedAssetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)] = []
    @State private var cachedAvailableDateBounds: ClosedRange<Date>?
    @State private var lastAdvancedDataCacheToken: Int?
    @State private var lastObservedRelevantHistoryToken: String = ""

    private var assetOptions: [BacktestAssetOption] {
        BacktestDefaults.dcaAssetOptions
    }

    private var latestSnapshot: AssetSnapshot? {
        snapshots.first
    }

    private var strategyTemplates: [AdvancedBacktestStrategyTemplate] {
        AdvancedBacktestStrategyTemplate.all
    }

    private var activeStrategyTemplateID: String? {
        strategyTemplates.first(where: isStrategyTemplateActive)?.id
    }

    private var buySignalOptions: [AdvancedBacktestSignalDirection] {
        AdvancedBacktestSignalDirection.allCases.filter(\.isBuySignalOption)
    }

    private var sellSignalOptions: [AdvancedBacktestSignalDirection] {
        AdvancedBacktestSignalDirection.allCases.filter(\.isSellSignalOption)
    }

    private var selectedAssetOptions: [BacktestAssetOption] {
        let selected = assetOptions.filter { selectedAssetSymbols.contains($0.symbol) }
        return selected.isEmpty ? Array(assetOptions.prefix(1)) : selected
    }

    private var calculationAssetOptions: [BacktestAssetOption] {
        var options = selectedAssetOptions
        var symbols = Set(options.map(\.symbol))
        for signalSymbol in strategyMode.requiredSignalAssetSymbols where !symbols.contains(signalSymbol) {
            if let option = assetOptions.first(where: { $0.symbol == signalSymbol }) {
                options.append(option)
                symbols.insert(signalSymbol)
            }
        }
        return options
    }

    private var relevantHistorySymbols: Set<String> {
        var symbols = Set(calculationAssetOptions.map(\.symbol))
        for option in calculationAssetOptions {
            if let fxSymbol = option.historicalFXSymbol {
                symbols.insert(fxSymbol)
            }
        }
        return symbols
    }

    private var relevantHistoryToken: String {
        marketStore.historyRelevanceToken(for: relevantHistorySymbols)
    }

    private var advancedDataCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(strategyMode.rawValue)
        hasher.combine(selectedAssetSymbols)
        for symbol in relevantHistorySymbols.sorted() {
            guard let series = marketStore.history(for: symbol) else {
                hasher.combine(symbol)
                hasher.combine("nil")
                continue
            }
            hasher.combine(symbol)
            hasher.combine(series.dates.count)
            hasher.combine(series.dates.last)
        }
        return hasher.finalize()
    }

    private var selectedAssetSummary: String {
        let titles = selectedAssetOptions.map { AppLocalization.string($0.title) }
        switch titles.count {
        case 0:
            return AppLocalization.string("未选择资产")
        case 1, 2:
            return titles.joined(separator: " + ")
        default:
            return AppLocalization.format("%d种资产", titles.count)
        }
    }

    private var selectedAssetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)] {
        cachedSelectedAssetInputs
    }

    private var isMissingSelectedHistoryData: Bool {
        selectedAssetInputs.contains { input in
            input.assetSeries == nil || (input.assetOption.requiresHistoricalFX && input.fxSeries == nil)
        }
    }

    private var availableDateBounds: ClosedRange<Date>? {
        cachedAvailableDateBounds
    }

    private var displayDateBounds: ClosedRange<Date>? {
        if let effectiveDateBounds {
            return effectiveDateBounds
        }

        if let start = selectedStartDate, let end = selectedEndDate {
            return min(start, end)...max(start, end)
        }

        if let firstSeries = selectedAssetInputs.compactMap(\.assetSeries).first,
           let assetBounds = BacktestEngine.availableDateBounds(for: [firstSeries]) {
            return assetBounds
        }

        return availableDateBounds
    }

    private var effectiveDateBounds: ClosedRange<Date>? {
        guard let bounds = availableDateBounds else { return nil }
        let start = max(selectedStartDate ?? bounds.lowerBound, bounds.lowerBound)
        let end = min(selectedEndDate ?? bounds.upperBound, bounds.upperBound)
        return start <= end ? (start...end) : bounds
    }

    private var selectedDateRangeLabel: String {
        guard let displayDateBounds else { return "--" }
        return "\(displayDateBounds.lowerBound.recordDateString) - \(displayDateBounds.upperBound.recordDateString)"
    }

    private var riskSettings: AdvancedBacktestRiskSettings {
        AdvancedBacktestRiskSettings(
            feeRate: feeRate,
            slippageRate: slippageRate,
            maxPositionRatio: maxPositionRatio,
            cooldownDays: Int(cooldownDays.rounded()),
            stopLossRatio: stopLossRatio,
            takeProfitRatio: takeProfitRatio
        )
    }

    private var refreshToken: String {
        [
            selectedAssetOptions.map(\.symbol).joined(separator: ","),
            String(initialCash),
            String(tradeAmount),
            String(feeRate),
            String(slippageRate),
            String(maxPositionRatio),
            String(cooldownDays),
            String(stopLossRatio),
            String(takeProfitRatio),
            strategyMode.rawValue,
            buyDirection.rawValue,
            String(buyDays),
            sellDirection.rawValue,
            String(sellDays),
            selectedStartDate?.recordDateString ?? "nil",
            selectedEndDate?.recordDateString ?? "nil"
        ].joined(separator: ":")
    }

    private var unavailableResultState: (message: String, isLoading: Bool) {
        if isRefreshingReport {
            return (AppLocalization.string("正在计算回测…"), true)
        }

        if selectedAssetInputs.contains(where: { $0.assetSeries == nil }) {
            if marketStore.isLoading || isLoadingRequiredHistory {
                return (AppLocalization.string("正在加载历史数据…"), true)
            }
            return (AppLocalization.string("部分资产历史数据暂时不可用，请稍后再试"), false)
        }

        if selectedAssetInputs.contains(where: { $0.assetOption.requiresHistoricalFX && $0.fxSeries == nil }) {
            if marketStore.isLoading || isLoadingRequiredHistory {
                return (AppLocalization.string("正在加载汇率数据…"), true)
            }
            return (AppLocalization.string("部分资产汇率数据暂时不可用，请稍后再试"), false)
        }

        let filteredInputs = selectedAssetInputs.map { input in
            (
                assetSeries: filteredHistorySeries(input.assetSeries, within: effectiveDateBounds),
                assetOption: input.assetOption,
                fxSeries: filteredHistorySeries(input.fxSeries, within: effectiveDateBounds)
            )
        }
        if filteredInputs.contains(where: { $0.assetSeries == nil }) {
            return (AppLocalization.string("当前回测区间内部分资产历史数据不足"), false)
        }

        if filteredInputs.contains(where: { $0.assetOption.requiresHistoricalFX && $0.fxSeries == nil }) {
            return (AppLocalization.string("当前回测区间内部分汇率数据不足"), false)
        }

        return (AppLocalization.string("当前数据暂时无法完成回测"), false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            configSection

            if hasStartedBacktest {
                advancedStartedContent
            }
        }
        .sheet(isPresented: $showsAssetSheet) {
            AdvancedBacktestAssetPickerSheet(
                selectedSymbols: selectedAssetSymbols,
                assetOptions: assetOptions
            ) { updatedSymbols in
                selectedAssetSymbols = updatedSymbols.isEmpty ? [BacktestDefaults.dcaAssetSymbol] : updatedSymbols
            }
            .presentationDetents([.fraction(0.62), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsRangeSheet) {
            if let availableDateBounds, let effectiveDateBounds {
                BacktestDateRangeSheet(
                    availableBounds: availableDateBounds,
                    selectedBounds: effectiveDateBounds
                ) { startDate, endDate in
                    selectedStartDate = startDate
                    selectedEndDate = endDate
                }
            }
        }
        .sheet(isPresented: $showsStrategyLibrary) {
            AdvancedStrategyLibrarySheet(
                templates: strategyTemplates,
                activeTemplateID: activeStrategyTemplateID
            ) { template in
                applyStrategyTemplate(template)
                showsStrategyLibrary = false
            }
            .presentationDetents([.fraction(0.72), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsCashYieldSheet) {
            if let report {
                CashYieldDetailSheet(summary: report.cashYieldSummary)
                    .presentationDetents([.fraction(0.58), .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showsRiskSignalSheet) {
            if let report, let riskSignalSummary = report.riskSignalSummary {
                MarketRiskSignalDetailSheet(summary: riskSignalSummary)
                    .presentationDetents([.fraction(0.62), .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: refreshToken) { _, _ in
            guard isActive, hasStartedBacktest else { return }
            scheduleRefresh(delayNanoseconds: 120_000_000, saveRecord: false)
        }
        .onChange(of: isActive ? advancedDataCacheToken : 0) { _, _ in
            guard isActive else { return }
            refreshAdvancedDataCacheIfNeeded()
        }
        .onChange(of: isActive ? relevantHistoryToken : "") { _, newToken in
            guard isActive, hasStartedBacktest else { return }
            guard newToken != lastObservedRelevantHistoryToken else { return }
            lastObservedRelevantHistoryToken = newToken
            refreshAdvancedDataCacheIfNeeded(force: true)
            scheduleRefresh(delayNanoseconds: 80_000_000, saveRecord: false)
        }
        .task(id: isActive) {
            if isActive {
                refreshAdvancedDataCacheIfNeeded(force: true)
                lastObservedRelevantHistoryToken = relevantHistoryToken
                let shouldForceHistoryRefresh = isMissingSelectedHistoryData
                if shouldForceHistoryRefresh {
                    await MainActor.run { isLoadingRequiredHistory = true }
                }
                await marketStore.refreshHistoryIfNeeded(force: shouldForceHistoryRefresh)
                guard !Task.isCancelled else { return }
                if shouldForceHistoryRefresh {
                    await MainActor.run { isLoadingRequiredHistory = false }
                }
                await MainActor.run {
                    refreshAdvancedDataCacheIfNeeded(force: true)
                    lastObservedRelevantHistoryToken = relevantHistoryToken
                }
                guard hasStartedBacktest, report == nil, !isRefreshingReport else { return }
                scheduleRefresh(delayNanoseconds: 120_000_000, saveRecord: false)
            } else {
                saveAdvancedBacktestRecordIfNeeded(report)
                cancelPendingAdvancedBacktestTasks()
                isLoadingRequiredHistory = false
            }
        }
        .onDisappear {
            saveAdvancedBacktestRecordIfNeeded(report)
            cancelPendingAdvancedBacktestTasks()
        }
        .task(id: restoreRequest?.id) {
            guard let restoreRequest else { return }
            await MainActor.run {
                applyRestoreRequest(restoreRequest)
            }
        }
    }

    @ViewBuilder
    private var advancedStartedContent: some View {
        if let report {
            AdvancedBacktestResultContent(
                report: report,
                comparisonSeries: cachedComparisonSeries,
                executionAssumptionText: advancedBacktestExecutionAssumptionText,
                strategyMode: strategyMode,
                rebalanceAdvice: rebalanceAdvice,
                latestSnapshot: latestSnapshot,
                selectedAssetOptions: selectedAssetOptions,
                showsRebalanceAdvice: true,
                showsSupplementalRows: true,
                onShowCashYield: { showsCashYieldSheet = true },
                onShowRiskSignal: { showsRiskSignalSheet = true }
            ) {
                if strategyMode == .ruleBased {
                    bestStrategySection()
                }
            }
        } else {
            let state = unavailableResultState
            advancedPanel {
                if state.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AssetTheme.gold)

                        Text(state.message)
                            .font(.subheadline)
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(state.message)
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(AppLocalization.string("策略设置"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 12)

                Button {
                    showsStrategyLibrary = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.bold))
                        Text(AppLocalization.string("策略大全"))
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AssetTheme.gold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(AssetTheme.overlaySoft, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AssetTheme.gold.opacity(0.36), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            advancedPanel {
                advancedButtonRow(
                    title: AppLocalization.string("回测资产"),
                    value: selectedAssetSummary,
                    showsDivider: true
                ) {
                    showsAssetSheet = true
                }

                advancedButtonRow(
                    title: AppLocalization.string("回测区间"),
                    value: selectedDateRangeLabel,
                    showsDivider: true
                ) {
                    guard availableDateBounds != nil else { return }
                    showsRangeSheet = true
                }

                advancedNumericInputRow(
                    title: AppLocalization.string("初始资金"),
                    value: $initialCash,
                    placeholder: AppLocalization.string("例如 100000"),
                    showsDivider: true
                )

                advancedPairedNumericInputRow(
                    leadingTitle: AppLocalization.string("交易费率"),
                    leadingValue: $feeRate,
                    leadingPlaceholder: AppLocalization.string("例如 1"),
                    leadingUnit: "%",
                    trailingTitle: AppLocalization.string("滑点"),
                    trailingValue: $slippageRate,
                    trailingPlaceholder: AppLocalization.string("例如 0.05"),
                    trailingUnit: "%",
                    showsDivider: true
                )

                if strategyMode.isRotation {
                    advancedStaticRow(
                        title: AppLocalization.string("策略模式"),
                        value: strategyMode.title,
                        showsDivider: true
                    )

                    advancedStaticRow(
                        title: AppLocalization.string("轮动规则"),
                        value: strategyMode.ruleSummary,
                        showsDivider: false
                    )
                } else {
                    advancedNumericInputRow(
                        title: AppLocalization.string("单次买入金额"),
                        value: $tradeAmount,
                        placeholder: AppLocalization.string("例如 10000"),
                        showsDivider: true
                    )

                    advancedPairedNumericInputRow(
                        leadingTitle: AppLocalization.string("最大仓位"),
                        leadingValue: $maxPositionRatio,
                        leadingPlaceholder: AppLocalization.string("例如 70"),
                        leadingUnit: "%",
                        trailingTitle: AppLocalization.string("冷却天数"),
                        trailingValue: $cooldownDays,
                        trailingPlaceholder: AppLocalization.string("例如 3"),
                        trailingUnit: AppLocalization.string("天"),
                        showsDivider: true
                    )

                    advancedPairedNumericInputRow(
                        leadingTitle: AppLocalization.string("止损线"),
                        leadingValue: $stopLossRatio,
                        leadingPlaceholder: AppLocalization.string("0为关闭"),
                        leadingUnit: "%",
                        trailingTitle: AppLocalization.string("止盈线"),
                        trailingValue: $takeProfitRatio,
                        trailingPlaceholder: AppLocalization.string("0为关闭"),
                        trailingUnit: "%",
                        showsDivider: true
                    )

                    advancedRuleRow(
                        title: AppLocalization.string("买入条件"),
                        direction: $buyDirection,
                        days: $buyDays,
                        options: buySignalOptions,
                        accent: AssetTheme.positive,
                        showsDivider: false
                    )

                    advancedRuleSwapRow()

                    advancedRuleRow(
                        title: AppLocalization.string("卖出条件"),
                        direction: $sellDirection,
                        days: $sellDays,
                        options: sellSignalOptions,
                        accent: AssetTheme.accentOrange,
                        showsDivider: false
                    )
                }
            }

            BacktestPrimaryActionButton(
                title: hasStartedBacktest ? AppLocalization.string("重新回测") : AppLocalization.string("开始回测"),
                systemImage: hasStartedBacktest ? "arrow.clockwise" : "play.fill"
            ) {
                startAdvancedBacktest()
            }
        }
    }

    @MainActor
    private func startAdvancedBacktest() {
        hasStartedBacktest = true

        guard isMissingSelectedHistoryData else {
            refreshAdvancedDataCacheIfNeeded(force: true)
            scheduleRefresh(delayNanoseconds: 0, saveRecord: true)
            return
        }

        isRefreshingReport = false
        Task {
            await MainActor.run { isLoadingRequiredHistory = true }
            await marketStore.refreshHistoryIfNeeded(force: true)
            await MainActor.run { isLoadingRequiredHistory = false }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isActive, hasStartedBacktest else { return }
                refreshAdvancedDataCacheIfNeeded(force: true)
                scheduleRefresh(delayNanoseconds: 0, saveRecord: true)
            }
        }
    }

    private func isStrategyTemplateActive(_ template: AdvancedBacktestStrategyTemplate) -> Bool {
        if strategyMode != template.mode { return false }
        if let selectedSymbols = template.selectedAssetSymbols,
           selectedAssetSymbols != Set(selectedSymbols) {
            return false
        }

        if template.mode.isRotation {
            return abs(feeRate - 1.0) < 0.01
                && abs(slippageRate - 0.05) < 0.01
        }

        let expectedTradeAmount = max(initialCash * template.tradeAmountRatio, 1)
        let tradeTolerance = max(expectedTradeAmount * 0.005, 1)

        return buyDirection == template.buyRule.direction
            && buyDays == template.buyRule.days
            && sellDirection == template.sellRule.direction
            && sellDays == template.sellRule.days
            && abs(tradeAmount - expectedTradeAmount) <= tradeTolerance
            && abs(maxPositionRatio - template.maxPositionRatio) < 0.01
            && abs(feeRate - 1.0) < 0.01
            && abs(slippageRate - 0.05) < 0.01
            && abs(cooldownDays - Double(template.cooldownDays)) < 0.01
            && abs(stopLossRatio - template.stopLossRatio) < 0.01
            && abs(takeProfitRatio - template.takeProfitRatio) < 0.01
    }

    private func applyStrategyTemplate(_ template: AdvancedBacktestStrategyTemplate) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            strategyMode = template.mode
            if let selectedSymbols = template.selectedAssetSymbols {
                selectedAssetSymbols = Set(selectedSymbols)
            }
            buyDirection = template.buyRule.direction
            buyDays = template.buyRule.days
            sellDirection = template.sellRule.direction
            sellDays = template.sellRule.days
            tradeAmount = max(initialCash * template.tradeAmountRatio, 1)
            feeRate = 1.0
            slippageRate = 0.05
            maxPositionRatio = template.maxPositionRatio
            cooldownDays = Double(template.cooldownDays)
            stopLossRatio = template.stopLossRatio
            takeProfitRatio = template.takeProfitRatio
        }
    }

    private var advancedBacktestExecutionAssumptionText: String {
        let timingText = strategyMode.isRotation
            ? AppLocalization.string("轮动策略使用上一交易日信号、下一调仓日收盘价成交")
            : AppLocalization.string("条件信号使用上一交易日收盘确认、下一交易日收盘价成交")
        return AppLocalization.format(
            "%@；已计入%.2f%%交易费和%.2f%%滑点。",
            timingText,
            feeRate,
            slippageRate
        )
    }

    @MainActor
    private func cancelPendingAdvancedBacktestTasks() {
        pendingRefreshTask?.cancel()
        pendingReportComputationTask?.cancel()
        pendingOptimizationComputationTask?.cancel()
        pendingRefreshTask = nil
        pendingReportComputationTask = nil
        pendingOptimizationComputationTask = nil
        isRefreshingReport = false
        isOptimizingStrategies = false
    }

    @MainActor
    private func refreshAdvancedDataCacheIfNeeded(force: Bool = false) {
        let token = advancedDataCacheToken
        guard force || token != lastAdvancedDataCacheToken else { return }

        cachedSelectedAssetInputs = calculationAssetOptions.map { option in
            BacktestEngine.advancedAssetInput(for: option) { symbol in
                marketStore.history(for: symbol)
            }
        }

        let boundarySymbols = strategyMode.dateBoundaryAssetSymbols
        let boundaryOptions = calculationAssetOptions.filter { option in
            boundarySymbols?.contains(option.symbol) ?? true
        }
        let sourceSeries = boundaryOptions.flatMap { option -> [PublicHistorySeries] in
            var series: [PublicHistorySeries] = []
            let input = BacktestEngine.advancedAssetInput(for: option) { symbol in
                marketStore.history(for: symbol)
            }
            if let assetSeries = input.assetSeries {
                series.append(assetSeries)
            }
            if let fxSeries = input.fxSeries {
                series.append(fxSeries)
            }
            return series
        }
        cachedAvailableDateBounds = BacktestEngine.availableDateBounds(for: sourceSeries)
        lastAdvancedDataCacheToken = token
    }

    @MainActor
    private func scheduleRefresh(delayNanoseconds: UInt64, saveRecord: Bool = false) {
        guard isActive else { return }
        pendingRefreshTask?.cancel()
        pendingReportComputationTask?.cancel()
        pendingOptimizationComputationTask?.cancel()
        pendingReportComputationTask = nil
        pendingOptimizationComputationTask = nil

        let capturedAssetInputs = selectedAssetInputs
        guard !capturedAssetInputs.isEmpty,
              capturedAssetInputs.allSatisfy({ $0.assetSeries != nil && (!$0.assetOption.requiresHistoricalFX || $0.fxSeries != nil) }) else {
            report = nil
            cachedComparisonSeries = []
            rebalanceAdvice = nil
            bestCandidates = []
            hasOptimizedStrategies = false
            isRefreshingReport = false
            isOptimizingStrategies = false
            pendingRefreshTask = nil
            return
        }

        let capturedDateBounds = effectiveDateBounds
        let capturedInitialCash = self.initialCash
        let capturedTradeAmount = self.tradeAmount
        let capturedStrategyMode = self.strategyMode
        let buyRule = AdvancedBacktestRule(direction: buyDirection, days: buyDays)
        let sellRule = AdvancedBacktestRule(direction: sellDirection, days: sellDays)
        let capturedRiskSettings = self.riskSettings

        isRefreshingReport = true
        bestCandidates = []
        hasOptimizedStrategies = false
        isOptimizingStrategies = false
        pendingRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            let computationTask = Task.detached(priority: .userInitiated) { () -> AdvancedBacktestComputationResult in
                let filteredAssetInputs = BacktestEngine.filteredAdvancedAssetInputs(capturedAssetInputs, within: capturedDateBounds)
                guard !Task.isCancelled,
                      !filteredAssetInputs.isEmpty,
                      filteredAssetInputs.allSatisfy({ $0.assetSeries != nil && (!$0.assetOption.requiresHistoricalFX || $0.fxSeries != nil) }) else {
                    return AdvancedBacktestComputationResult(report: nil, rebalanceAdvice: nil)
                }

                let advice = capturedStrategyMode.isRotation
                    ? BacktestEngine.advancedRotationRebalanceAdvice(
                        assetInputs: filteredAssetInputs,
                        mode: capturedStrategyMode,
                        initialCash: capturedInitialCash,
                        settings: capturedRiskSettings
                    )
                    : nil

                let report: AdvancedBacktestReport?
                if capturedStrategyMode.isRotation {
                    report = BacktestEngine.runAdvancedRotationStrategy(
                        assetInputs: filteredAssetInputs,
                        initialCash: capturedInitialCash,
                        settings: capturedRiskSettings,
                        mode: capturedStrategyMode
                    )
                } else {
                    report = BacktestEngine.runAdvancedStrategies(
                        assetInputs: filteredAssetInputs,
                        initialCash: capturedInitialCash,
                        tradeAmount: capturedTradeAmount,
                        buyRule: buyRule,
                        sellRule: sellRule,
                        settings: capturedRiskSettings
                    )
                }

                return AdvancedBacktestComputationResult(report: report, rebalanceAdvice: advice)
            }
            await MainActor.run {
                pendingReportComputationTask = computationTask
            }

            let refreshedResult = await withTaskCancellationHandler {
                await computationTask.value
            } onCancel: {
                computationTask.cancel()
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                pendingReportComputationTask = nil
                report = refreshedResult.report
                cachedComparisonSeries = refreshedResult.report.map { AdvancedBacktestPresentation.comparisonSeries(from: $0) } ?? []
                rebalanceAdvice = refreshedResult.rebalanceAdvice
                if saveRecord {
                    saveAdvancedBacktestRecordIfNeeded(refreshedResult.report)
                }
                bestCandidates = []
                hasOptimizedStrategies = false
                isRefreshingReport = false
                isOptimizingStrategies = false
                pendingRefreshTask = nil
            }
        }
    }

    private func bestStrategySection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                AppLocalization.string("智能优选策略"),
                trailing: AppLocalization.string("手动扫描 · 综合排序"),
                trailingColor: AssetTheme.gold
            )

            advancedPanel {
                if isOptimizingStrategies {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AssetTheme.gold)
                        Text(AppLocalization.string("正在寻找候选策略…"))
                            .font(.subheadline)
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if bestCandidates.isEmpty {
                        Text(AppLocalization.string(hasOptimizedStrategies ? "暂无可用候选策略，请调整资产或区间后重试" : "需要时可扫描候选策略"))
                            .font(.subheadline)
                            .foregroundStyle(AssetTheme.textSecondary)
                    } else {
                        ForEach(Array(bestCandidates.enumerated()), id: \.element.id) { index, candidate in
                            Button {
                                applyCandidate(candidate)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("#\(index + 1)")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(AssetTheme.gold)
                                        Spacer()
                                        Text(candidate.report.totalReturn.percentString())
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(candidate.report.totalReturn >= 0 ? AssetTheme.positive : AssetTheme.negative)
                                    }

                                    Text(AppLocalization.format(
                                        "单次%@ · 仓位%.0f%% · 费率%.2f%% · 滑点%.2f%% · 年化%@ · 回撤%@ · 夏普%@",
                                        candidate.tradeAmount.currencyString(),
                                        candidate.settings.maxPositionRatio,
                                        candidate.settings.feeRate,
                                        candidate.settings.slippageRate,
                                        candidate.report.annualizedReturn?.percentString() ?? "--",
                                        candidate.report.maxDrawdown.percentString(),
                                        candidate.report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--"
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(AssetTheme.textSecondary)
                                    .lineLimit(2)

                                    HStack(spacing: 6) {
                                        ForEach(candidateTags(for: candidate), id: \.self) { tag in
                                            candidateTagPill(tag)
                                        }
                                    }
                                    .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .overlay(AssetTheme.border.opacity(0.6))
                        }
                    }

                    BacktestActionChip(
                        title: bestCandidates.isEmpty ? "扫描候选策略" : "重新扫描",
                        systemImage: bestCandidates.isEmpty ? "sparkles" : "arrow.clockwise"
                    ) {
                        optimizeStrategies()
                    }
                    .disabled(isRefreshingReport)
                    .opacity(isRefreshingReport ? 0.55 : 1)
                }
            }
        }
    }

    private func candidateTags(for candidate: AdvancedBacktestCandidate) -> [String] {
        var tags: [String] = []
        if candidate.report.excessReturn ?? 0 > 0 {
            tags.append(AppLocalization.string("跑赢持有"))
        }
        if candidate.report.maxDrawdown <= 0.18 {
            tags.append(AppLocalization.string("低回撤"))
        }
        if (candidate.report.sharpeRatio ?? 0) >= 1 {
            tags.append(AppLocalization.string("高夏普"))
        }
        if candidate.report.trades.count <= 8 {
            tags.append(AppLocalization.string("低频"))
        }
        if tags.isEmpty {
            tags.append(AppLocalization.string("候选"))
        }
        return Array(tags.prefix(3))
    }

    private func candidateTagPill(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AssetTheme.gold)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(AssetTheme.gold.opacity(0.1), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(AssetTheme.gold.opacity(0.18), lineWidth: 1)
            )
    }

    @MainActor
    private func optimizeStrategies() {
        guard !isRefreshingReport, !isOptimizingStrategies else { return }
        pendingRefreshTask?.cancel()
        pendingReportComputationTask?.cancel()
        pendingOptimizationComputationTask?.cancel()
        pendingReportComputationTask = nil
        pendingOptimizationComputationTask = nil

        let capturedAssetInputs = selectedAssetInputs
        guard !capturedAssetInputs.isEmpty,
              capturedAssetInputs.allSatisfy({ $0.assetSeries != nil && (!$0.assetOption.requiresHistoricalFX || $0.fxSeries != nil) }) else {
            bestCandidates = []
            hasOptimizedStrategies = true
            isOptimizingStrategies = false
            pendingRefreshTask = nil
            return
        }

        let capturedDateBounds = effectiveDateBounds
        let capturedInitialCash = self.initialCash
        let capturedRiskSettings = self.riskSettings

        bestCandidates = []
        hasOptimizedStrategies = false
        isOptimizingStrategies = true
        pendingRefreshTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }

            let computationTask = Task.detached(priority: .utility) { () -> [AdvancedBacktestCandidate] in
                let filteredAssetInputs = BacktestEngine.filteredAdvancedAssetInputs(capturedAssetInputs, within: capturedDateBounds)
                guard !Task.isCancelled,
                      !filteredAssetInputs.isEmpty,
                      filteredAssetInputs.allSatisfy({ $0.assetSeries != nil && (!$0.assetOption.requiresHistoricalFX || $0.fxSeries != nil) }) else {
                    return []
                }

                return BacktestEngine.optimizeAdvancedStrategies(
                    assetInputs: filteredAssetInputs,
                    initialCash: capturedInitialCash,
                    baseSettings: capturedRiskSettings,
                    limit: 3
                )
            }
            await MainActor.run {
                pendingOptimizationComputationTask = computationTask
            }

            let optimizedCandidates = await withTaskCancellationHandler {
                await computationTask.value
            } onCancel: {
                computationTask.cancel()
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                pendingOptimizationComputationTask = nil
                bestCandidates = optimizedCandidates
                hasOptimizedStrategies = true
                isOptimizingStrategies = false
                pendingRefreshTask = nil
            }
        }
    }

    @MainActor
    private func saveAdvancedBacktestRecordIfNeeded(_ report: AdvancedBacktestReport?) {
        guard let report, !report.points.isEmpty else { return }
        let config = BacktestRecordConfigPayload(
            kind: .advanced,
            selectedAssetSymbol: selectedAssetOptions.first?.symbol,
            selectedAssetSymbols: selectedAssetOptions.map(\.symbol),
            initialCash: initialCash,
            tradeAmount: tradeAmount,
            feeRate: feeRate,
            slippageRate: slippageRate,
            maxPositionRatio: maxPositionRatio,
            cooldownDays: Int(cooldownDays.rounded()),
            stopLossRatio: stopLossRatio,
            takeProfitRatio: takeProfitRatio,
            strategyModeRawValue: strategyMode.rawValue,
            buyDirectionRawValue: buyDirection.rawValue,
            buyDays: buyDays,
            sellDirectionRawValue: sellDirection.rawValue,
            sellDays: sellDays,
            advancedTrades: BacktestRecordCodec.advancedTradePayloads(from: report.trades),
            advancedAssetCharts: BacktestRecordCodec.advancedAssetChartPayloads(from: report.assetReports),
            advancedBenchmarkSeries: BacktestRecordCodec.advancedBenchmarkSeriesPayloads(from: report.benchmarkSeries),
            finalCash: report.finalCash,
            finalUnits: report.finalUnits,
            cashYieldSummary: BacktestRecordCodec.cashYieldSummaryPayload(from: report.cashYieldSummary),
            riskSignalSummary: report.riskSignalSummary.map { BacktestRecordCodec.riskSignalSummaryPayload(from: $0) }
        )
        let configSummary = advancedConfigSummary()
        let record = BacktestRecord(
            kindRawValue: BacktestRecordKind.advanced.rawValue,
            title: BacktestRecordKind.advanced.title,
            subtitle: strategyMode.title,
            configSummary: configSummary,
            startDate: report.points.first?.date,
            endDate: report.points.last?.date,
            totalReturn: report.totalReturn,
            annualizedReturn: report.annualizedReturn,
            maxDrawdown: report.maxDrawdown,
            annualizedVolatility: report.annualizedVolatility,
            sharpeRatio: report.sharpeRatio,
            finalValue: report.finalPortfolioValue,
            totalInvested: initialCash,
            profitLoss: report.finalPortfolioValue - initialCash,
            tradeCount: report.buyCount + report.sellCount,
            pointsJSON: BacktestRecordCodec.pointsData(from: report.points),
            configJSON: BacktestRecordCodec.configData(from: config)
        )
        insertAdvancedBacktestRecord(record)
    }

    @MainActor
    private func insertAdvancedBacktestRecord(_ record: BacktestRecord) {
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

        guard signature != lastSavedAdvancedBacktestSignature else { return }
        lastSavedAdvancedBacktestSignature = signature

        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            print("[AssetTimeMachine] save advanced backtest record failed: \(error)")
        }
    }

    private func advancedConfigSummary() -> String {
        if strategyMode.isRotation {
            return AppLocalization.format(
                "%@ · %@ · 费率%.2f%% · 滑点%.2f%%",
                strategyMode.title,
                strategyMode.ruleSummary,
                feeRate,
                slippageRate
            )
        }

        return AppLocalization.format(
            "%@ · %@ · 单次%@ · 仓位%.0f%% · 费率%.2f%% · 滑点%.2f%%",
            advancedRuleSummary(direction: buyDirection, days: buyDays),
            advancedRuleSummary(direction: sellDirection, days: sellDays),
            tradeAmount.currencyString(),
            maxPositionRatio,
            feeRate,
            slippageRate
        )
    }

    @MainActor
    private func applyRestoreRequest(_ request: AdvancedBacktestRestoreRequest) {
        let config = request.config
        let restoredSymbols = config.selectedAssetSymbols ?? config.selectedAssetSymbol.map { [$0] } ?? [BacktestDefaults.dcaAssetSymbol]
        selectedAssetSymbols = Set(restoredSymbols).isEmpty ? [BacktestDefaults.dcaAssetSymbol] : Set(restoredSymbols)
        initialCash = config.initialCash ?? 100_000
        tradeAmount = config.tradeAmount ?? 10_000
        feeRate = config.feeRate ?? 1.0
        slippageRate = config.slippageRate ?? 0.05
        maxPositionRatio = config.maxPositionRatio ?? 70
        cooldownDays = Double(config.cooldownDays ?? 3)
        stopLossRatio = config.stopLossRatio ?? 0
        takeProfitRatio = config.takeProfitRatio ?? 0
        strategyMode = config.strategyModeRawValue.flatMap(AdvancedBacktestStrategyMode.init(rawValue:)) ?? .ruleBased
        buyDirection = config.buyDirectionRawValue.flatMap(AdvancedBacktestSignalDirection.init(rawValue:)) ?? .consecutiveDown
        buyDays = config.buyDays ?? 3
        sellDirection = config.sellDirectionRawValue.flatMap(AdvancedBacktestSignalDirection.init(rawValue:)) ?? .consecutiveUp
        sellDays = config.sellDays ?? 3
        selectedStartDate = request.startDate
        selectedEndDate = request.endDate
        hasStartedBacktest = true
        bestCandidates = []
        hasOptimizedStrategies = false
        isOptimizingStrategies = false
        scheduleRefresh(delayNanoseconds: 0, saveRecord: false)
    }

    private func filteredHistorySeries(_ series: PublicHistorySeries?, within bounds: ClosedRange<Date>?) -> PublicHistorySeries? {
        BacktestEngine.filteredHistorySeries(series, within: bounds)
    }

    private func sectionHeader(_ title: String, trailing: String? = nil, trailingColor: Color = AssetTheme.textSecondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)
            Spacer()
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(trailingColor)
                    .lineLimit(1)
            }
        }
    }

    private func advancedPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AssetTheme.surface.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
        )
    }

    private func advancedMenuRow<Content: View>(title: String, value: String, accent: Color = AssetTheme.textPrimary, showsDivider: Bool, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AssetTheme.textSecondary)
                    Spacer()
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .padding(.vertical, 2)

                if showsDivider {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.6))
                        .padding(.top, 14)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func advancedNumericInputRow(
        title: String,
        value: Binding<Double>,
        placeholder: String,
        unit: String = AppLocalization.string("元"),
        showsDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AssetTheme.textSecondary)

                Spacer(minLength: 12)

                TextField(
                    placeholder,
                    value: Binding(
                        get: { value.wrappedValue },
                        set: { value.wrappedValue = max($0, 0) }
                    ),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(minWidth: 110, maxWidth: 160)

                Text(unit)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
            }
            .padding(.vertical, 2)

            if showsDivider {
                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))
                    .padding(.top, 14)
            }
        }
    }

    private func advancedPairedNumericInputRow(
        leadingTitle: String,
        leadingValue: Binding<Double>,
        leadingPlaceholder: String,
        leadingUnit: String,
        trailingTitle: String,
        trailingValue: Binding<Double>,
        trailingPlaceholder: String,
        trailingUnit: String,
        showsDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                advancedCompactNumericInput(
                    title: leadingTitle,
                    value: leadingValue,
                    placeholder: leadingPlaceholder,
                    unit: leadingUnit
                )

                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))
                    .frame(height: 24)

                advancedCompactNumericInput(
                    title: trailingTitle,
                    value: trailingValue,
                    placeholder: trailingPlaceholder,
                    unit: trailingUnit
                )
            }
            .padding(.vertical, 2)

            if showsDivider {
                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))
                    .padding(.top, 14)
            }
        }
    }

    private func advancedCompactNumericInput(
        title: String,
        value: Binding<Double>,
        placeholder: String,
        unit: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)

            Spacer(minLength: 6)

            TextField(
                placeholder,
                value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = max($0, 0) }
                ),
                format: .number.precision(.fractionLength(0...2))
            )
            .keyboardType(.decimalPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AssetTheme.textPrimary)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(minWidth: 44, maxWidth: 72)

            Text(unit)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func advancedStaticRow(title: String, value: String, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AssetTheme.textSecondary)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 2)

            if showsDivider {
                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))
                    .padding(.top, 14)
            }
        }
    }

    private func advancedButtonRow(title: String, value: String, showsDivider: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AssetTheme.textSecondary)
                    Spacer()
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AssetTheme.textPrimary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .padding(.vertical, 2)

                if showsDivider {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.6))
                        .padding(.top, 14)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func advancedRuleRow(title: String, direction: Binding<AdvancedBacktestSignalDirection>, days: Binding<Int>, options: [AdvancedBacktestSignalDirection], accent: Color, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Menu {
                        Picker("", selection: direction) {
                            ForEach(options) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .labelsHidden()
                    } label: {
                        HStack(spacing: 8) {
                            Text(direction.wrappedValue.title)
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(AssetTheme.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if direction.wrappedValue.usesDayThreshold {
                        Stepper(value: days, in: 1...10) {
                            Text(AppLocalization.format("%d天", days.wrappedValue))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AssetTheme.textPrimary)
                        }
                        .tint(accent)
                    } else {
                        Text(AppLocalization.string("固定参数"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                }
            }
            .accessibilityLabel(title)

            if showsDivider {
                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))
                    .padding(.top, 14)
            }
        }
    }

    private func advancedRuleSwapRow() -> some View {
        VStack(spacing: 12) {
            Divider()
                .overlay(AssetTheme.border.opacity(0.6))

            HStack {
                Spacer()

                Button(action: swapAdvancedRules) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption.weight(.bold))
                        Text(AppLocalization.string("互换条件"))
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AssetTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AssetTheme.overlaySubtle, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()
            }

            Divider()
                .overlay(AssetTheme.border.opacity(0.6))
        }
    }

    private func swapAdvancedRules() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            let originalBuyDirection = buyDirection
            let originalBuyDays = buyDays
            let originalSellDirection = sellDirection
            let originalSellDays = sellDays
            buyDirection = originalSellDirection.isBuySignalOption ? originalSellDirection : .alwaysBuy
            buyDays = originalSellDirection.isBuySignalOption ? originalSellDays : 1
            sellDirection = originalBuyDirection.isSellSignalOption ? originalBuyDirection : .neverSell
            sellDays = originalBuyDirection.isSellSignalOption ? originalBuyDays : 1
        }
    }

    private func applyCandidate(_ candidate: AdvancedBacktestCandidate) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            strategyMode = .ruleBased
            buyDirection = candidate.buyRule.direction
            buyDays = candidate.buyRule.days
            sellDirection = candidate.sellRule.direction
            sellDays = candidate.sellRule.days
            tradeAmount = candidate.tradeAmount
            feeRate = candidate.settings.feeRate
            slippageRate = candidate.settings.slippageRate
            maxPositionRatio = candidate.settings.maxPositionRatio
            cooldownDays = Double(candidate.settings.cooldownDays)
            stopLossRatio = candidate.settings.stopLossRatio
            takeProfitRatio = candidate.settings.takeProfitRatio
            report = candidate.report
            cachedComparisonSeries = AdvancedBacktestPresentation.comparisonSeries(from: candidate.report)
            saveAdvancedBacktestRecordIfNeeded(candidate.report)
        }
    }

    private func advancedRuleSummary(direction: AdvancedBacktestSignalDirection, days: Int) -> String {
        if direction.usesDayThreshold {
            return AppLocalization.format("%@ %d天", direction.title, days)
        }

        return direction.title
    }
}
