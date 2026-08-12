import SwiftUI
import SwiftData
import Charts
import UIKit
import Combine

private struct TrendVideoPreviewRequest: Identifiable {
    let id = UUID()
    let points: [TimeMachineTrendPoint]
    let rangeLabel: String
}

struct TimeMachineView: View {
    @Environment(\.modelContext) private var modelContext
    let marketStore: RemoteMarketStore
    let isActive: Bool
    @State private var selectedRange: TimeMachineRange = .sixMonths
    @State private var cachedTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedFilteredTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedMonthlySurplusPoints: [TimeMachineMonthlySurplusPoint] = []
    @State private var cachedAnnualSurplusPoints: [TimeMachineAnnualSurplusPoint] = []
    @State private var cachedHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]] = [:]
    @State private var cachedFullHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]] = [:]
    @State private var cachedFullHistoryCandlesticksBySymbol: [String: [TimeMachineCandlestickPoint]] = [:]
    @State private var cachedDetailTrendCards: [TimeMachineCombinedTrendDescriptor] = []
    @State private var cachedSnapshotProjections: [TimeMachineSnapshotProjection] = []
    @State private var cachedSnapshotIDByDay: [Date: UUID] = [:]
    @State private var lastSnapshotProjectionCacheToken: Int?

    @State private var lastFullHistoryPointsCacheToken: Int?
    @State private var lastVisualizationCacheToken: Int?
    @State private var lastLiveMarketVisualizationCacheToken: Int?
    @State private var pendingLiveMarketTrendRefreshTask: Task<Void, Never>?
    @State private var lastDetailTrendCardsCacheToken: Int?
    @State private var deferredDetailCardsTask: Task<Void, Never>?
    @State private var pendingVisualizationRefreshTask: Task<Void, Never>?
    @State private var isScrollInProgress = false
    @State private var modelSaveRevision = 0
    @State private var lastObservedStoreRevision: UInt64 = 0
    @State private var visibleDetailTrendSymbols: Set<String> = ["gold_cny"]
    @State private var selectedRecordSnapshot: AssetSnapshot?
    @State private var selectedHistoryDrilldown: TimeMachineHistoryDrilldown?
    @State private var trendVideoPreviewRequest: TrendVideoPreviewRequest?
    @State private var trendVideoExportErrorMessage: String?
    #if DEBUG
    @State private var didOpenDebugTrendVideoPreview = false
    #endif

    init(marketStore: RemoteMarketStore, isActive: Bool) {
        self.marketStore = marketStore
        self.isActive = isActive

    }

    private var trendPoints: [TimeMachineTrendPoint] {
        cachedTrendPoints
    }

    private var filteredTrendPoints: [TimeMachineTrendPoint] {
        cachedFilteredTrendPoints
    }

    private var latestPoint: TimeMachineTrendPoint? {
        cachedFilteredTrendPoints.last ?? cachedTrendPoints.last
    }

    private var monthlySurplusPoints: [TimeMachineMonthlySurplusPoint] {
        cachedMonthlySurplusPoints
    }

    private var annualSurplusPoints: [TimeMachineAnnualSurplusPoint] {
        cachedAnnualSurplusPoints
    }

    private var liveMarketAnchors: TimeMachineLiveMarketAnchors {
        TimeMachineLiveMarketAnchors.from(marketStore: marketStore)
    }

    private var detailTrendCards: [TimeMachineCombinedTrendDescriptor] {
        cachedDetailTrendCards
    }

    private static var publicIndexConfigs: [(symbol: String, title: String, color: Color)] { [
        ("sp500", AppLocalization.string("标普500"), AssetTheme.goldSoft),
        ("dowjones", AppLocalization.string("道指"), AssetTheme.accentOrange),
        ("hsi", AppLocalization.string("恒生"), AssetTheme.accentBlue),
        ("nikkei", AppLocalization.string("日经225"), AssetTheme.positive),
        ("csi300", AppLocalization.string("沪深300"), AssetTheme.textPrimary),
        ("shanghai_composite", AppLocalization.string("上证综指"), AssetTheme.textSecondary)
    ] }

    private static var detailComparisonOptions: [TimeMachineDetailComparisonOption] { [
        TimeMachineDetailComparisonOption(symbol: "gold_cny", title: AppLocalization.string("黄金"), color: AssetTheme.gold),
        TimeMachineDetailComparisonOption(symbol: "nasdaq", title: AppLocalization.string("纳指"), color: AssetTheme.accentBlue)
    ] + publicIndexConfigs.map { config in
        TimeMachineDetailComparisonOption(symbol: config.symbol, title: config.title, color: config.color)
    } }

    private var hiddenDetailComparisonOptions: [TimeMachineDetailComparisonOption] {
        Self.detailComparisonOptions.filter { !visibleDetailTrendSymbols.contains($0.symbol) }
    }

    private var historyCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(marketStore.historyRevision)
        let symbols = marketStore.historySeries.keys.sorted()
        hasher.combine(symbols.count)

        for symbol in symbols {
            guard let series = marketStore.historySeries[symbol] else { continue }
            hasher.combine(symbol)
            hasher.combine(series.dates.count)
            hasher.combine(series.dates.last)
            hasher.combine(series.prices.last)
            hasher.combine(series.currency)
            hasher.combine(series.hasOHLC)
            hasher.combine(series.ohlcSource)
            hasher.combine(series.ohlcCoverageRatio)
            hasher.combine(series.openPrices?.count ?? 0)
            hasher.combine(series.openPrices?.last ?? nil)
            hasher.combine(series.highPrices?.last ?? nil)
            hasher.combine(series.lowPrices?.last ?? nil)
            hasher.combine(series.closePrices?.last ?? nil)
        }

        return hasher.finalize()
    }

    private var detailHistoryPointsCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(historyCacheToken)
        for symbol in visibleDetailTrendSymbols.sorted() {
            hasher.combine(symbol)
        }
        return hasher.finalize()
    }

    private var overviewCacheToken: Int {
        marketStore.overviewCacheToken()
    }

    private var exchangeRateCacheToken: Int {
        marketStore.exchangeRateCacheToken()
    }

    private var snapshotProjectionCacheToken: Int {
        modelSaveRevision
    }

    private var snapshotVisualizationCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(selectedRange.rawValue)
        hasher.combine(modelSaveRevision)
        hasher.combine(historyCacheToken)
        return hasher.finalize()
    }

    private var liveMarketVisualizationCacheToken: Int {
        marketStore.liveMarketCacheToken()
    }

    @MainActor
    private func scheduleVisualizationRefresh(
        force: Bool = false,
        includeDetailCards: Bool = true,
        delayNanoseconds: UInt64 = 60_000_000
    ) {
        pendingVisualizationRefreshTask?.cancel()
        pendingVisualizationRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            guard isActive else { return }
            await refreshVisualizationCacheIfNeeded(force: force, includeDetailCards: includeDetailCards)
        }
    }

    @MainActor
    private func refreshVisualizationCacheIfNeeded(force: Bool = false, includeDetailCards: Bool = true) async {
        let token = snapshotVisualizationCacheToken
        if !force, token == lastVisualizationCacheToken {
            if includeDetailCards {
                await refreshDetailTrendCardsIfNeeded()
            } else if cachedDetailTrendCards.isEmpty {
                scheduleDeferredDetailCardsRefresh(for: token)
            }
            return
        }
        await refreshVisualizationCache(includeDetailCards: includeDetailCards, cacheToken: token)
        guard !Task.isCancelled, isActive, token == snapshotVisualizationCacheToken else { return }
        lastVisualizationCacheToken = token
        lastLiveMarketVisualizationCacheToken = liveMarketVisualizationCacheToken
    }

    @MainActor
    private func scheduleLiveMarketTrendRefresh(delayNanoseconds: UInt64 = 220_000_000) {
        pendingLiveMarketTrendRefreshTask?.cancel()
        pendingLiveMarketTrendRefreshTask = Task {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard await waitForScrollIdle() else { return }
            refreshCachedLiveMarketTrendPoint()
        }
    }

    @MainActor
    private func waitForScrollIdle() async -> Bool {
        while isScrollInProgress {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, isActive else { return false }
        }
        return !Task.isCancelled && isActive
    }

    @MainActor
    private func refreshCachedLiveMarketTrendPoint() {
        let token = liveMarketVisualizationCacheToken
        guard token != lastLiveMarketVisualizationCacheToken else { return }
        defer { lastLiveMarketVisualizationCacheToken = token }

        guard let todaySnapshot = cachedSnapshotProjections.last(where: { Calendar.current.isDateInToday($0.date) }) else {
            return
        }

        let updatedPoint = TimeMachineSnapshotProjectionProcessor.makeTrendPoint(
            from: todaySnapshot,
            liveAnchors: liveMarketAnchors
        )

        func replaceTodayPoint(in points: inout [TimeMachineTrendPoint]) {
            guard let index = points.lastIndex(where: { Calendar.current.isDateInToday($0.date) }) else { return }
            points[index] = updatedPoint
        }

        replaceTodayPoint(in: &cachedTrendPoints)
        replaceTodayPoint(in: &cachedFilteredTrendPoints)

        guard !cachedDetailTrendCards.isEmpty else { return }
        refreshDetailTrendCards(for: lastDetailTrendCardsCacheToken ?? snapshotVisualizationCacheToken)
    }

    @MainActor
    private func refreshVisualizationCache(includeDetailCards: Bool = true, cacheToken: Int? = nil) async {
        guard !Task.isCancelled, isActive else { return }
        let cacheToken = cacheToken ?? snapshotVisualizationCacheToken
        guard let projections = await snapshotProjectionsIfNeeded() else { return }
        let range = selectedRange
        let anchors = liveMarketAnchors
        let processingTask = Task.detached(priority: .userInitiated) {
            TimeMachineSnapshotProjectionProcessor.prepare(
                projections: projections,
                range: range,
                liveAnchors: anchors
            )
        }
        let prepared = await withTaskCancellationHandler {
            await processingTask.value
        } onCancel: {
            processingTask.cancel()
        }

        guard !Task.isCancelled, isActive, cacheToken == snapshotVisualizationCacheToken else { return }

        cachedTrendPoints = prepared.trendPoints
        cachedFilteredTrendPoints = prepared.filteredTrendPoints
        cachedMonthlySurplusPoints = prepared.monthlySurplusPoints
        cachedAnnualSurplusPoints = prepared.annualSurplusPoints
        cachedSnapshotIDByDay = prepared.snapshotIDByDay
        lastVisualizationCacheToken = cacheToken
        await Task.yield()

        guard !prepared.filteredTrendPoints.isEmpty else {
            cachedHistoryPointsBySymbol = [:]
            cachedDetailTrendCards = []
            lastDetailTrendCardsCacheToken = nil
            deferredDetailCardsTask?.cancel()
            return
        }

        let fullHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]]
        let fullHistoryToken = detailHistoryPointsCacheToken
        if fullHistoryToken == lastFullHistoryPointsCacheToken {
            fullHistoryPointsBySymbol = cachedFullHistoryPointsBySymbol
        } else {
            await Task.yield()
            let preparedHistory = await prepareFullHistorySeries()
            guard !Task.isCancelled, isActive, cacheToken == snapshotVisualizationCacheToken else { return }
            fullHistoryPointsBySymbol = preparedHistory.pointsBySymbol
            cachedFullHistoryPointsBySymbol = fullHistoryPointsBySymbol
            cachedFullHistoryCandlesticksBySymbol = preparedHistory.candlesticksBySymbol
            lastFullHistoryPointsCacheToken = fullHistoryToken
        }
        let historyPointsBySymbol = buildHistoryPointsBySymbol(
            fullHistoryPointsBySymbol: fullHistoryPointsBySymbol,
            trendPoints: prepared.filteredTrendPoints
        )

        cachedHistoryPointsBySymbol = historyPointsBySymbol

        if includeDetailCards {
            refreshDetailTrendCards(for: cacheToken)
        } else {
            cachedDetailTrendCards = []
            lastDetailTrendCardsCacheToken = nil
            scheduleDeferredDetailCardsRefresh(for: cacheToken)
        }
    }

    @MainActor
    private func snapshotProjectionsIfNeeded() async -> [TimeMachineSnapshotProjection]? {
        let token = snapshotProjectionCacheToken
        if token == lastSnapshotProjectionCacheToken {
            return cachedSnapshotProjections
        }

        let container = modelContext.container
        do {
            let projections = try await BackgroundTaskWork.run {
                let store = TimeMachineSnapshotProjectionStore(modelContainer: container)
                return try await store.fetchAll()
            }
            guard !Task.isCancelled, isActive, token == snapshotProjectionCacheToken else { return nil }
            cachedSnapshotProjections = projections
            lastSnapshotProjectionCacheToken = token
            return projections
        } catch is CancellationError {
            return nil
        } catch {
            print("[AssetTimeMachine] fetch snapshot projections failed: \(error)")
            return cachedSnapshotProjections.isEmpty ? nil : cachedSnapshotProjections
        }
    }

    @MainActor
    private func refreshDetailTrendCardsIfNeeded(force: Bool = false) async {
        let token = snapshotVisualizationCacheToken
        guard force || token != lastDetailTrendCardsCacheToken else { return }
        if token != lastVisualizationCacheToken {
            await refreshVisualizationCache(includeDetailCards: true, cacheToken: token)
            guard !Task.isCancelled, isActive, token == snapshotVisualizationCacheToken else { return }
            lastVisualizationCacheToken = token
            lastLiveMarketVisualizationCacheToken = liveMarketVisualizationCacheToken
        } else {
            refreshDetailTrendCards(for: token)
        }
    }

    @MainActor
    private func refreshDetailTrendCards(for token: Int) {
        cachedDetailTrendCards = buildDetailTrendCards(
            filteredTrendPoints: cachedFilteredTrendPoints,
            latestPoint: cachedFilteredTrendPoints.last ?? cachedTrendPoints.last,
            historyPointsBySymbol: cachedHistoryPointsBySymbol,
            fullHistoryPointsBySymbol: cachedFullHistoryPointsBySymbol
        )
        lastDetailTrendCardsCacheToken = token
    }

    @MainActor
    private func scheduleDeferredDetailCardsRefresh(for token: Int) {
        deferredDetailCardsTask?.cancel()
        deferredDetailCardsTask = Task {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard await waitForScrollIdle() else { return }
            guard isActive, token == snapshotVisualizationCacheToken else { return }
            await refreshDetailTrendCardsIfNeeded()
        }
    }

    @MainActor
    private func prepareFullHistorySeries() async -> TimeMachinePreparedHistory {
        let symbols = Self.detailComparisonOptions
            .map(\.symbol)
            .filter { visibleDetailTrendSymbols.contains($0) }
        let seriesBySymbol = Dictionary(uniqueKeysWithValues: symbols.compactMap { symbol in
            marketStore.history(for: symbol).map { (symbol, $0) }
        })
        let processingTask = Task.detached(priority: .utility) {
            TimeMachineHistoryProjectionProcessor.prepare(seriesBySymbol: seriesBySymbol)
        }
        return await withTaskCancellationHandler {
            await processingTask.value
        } onCancel: {
            processingTask.cancel()
        }
    }

    private func buildHistoryPointsBySymbol(
        fullHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]],
        trendPoints: [TimeMachineTrendPoint]
    ) -> [String: [TimeMachineSingleAxisPoint]] {
        guard let firstDate = trendPoints.first?.date,
              let lastDate = trendPoints.last?.date else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: fullHistoryPointsBySymbol.compactMap { symbol, points in
            let clippedPoints = points.filter { $0.date >= firstDate && $0.date <= lastDate }
            guard !clippedPoints.isEmpty else { return nil }
            return (symbol, clippedPoints)
        })
    }

    private func buildDetailTrendCards(
        filteredTrendPoints: [TimeMachineTrendPoint],
        latestPoint: TimeMachineTrendPoint?,
        historyPointsBySymbol: [String: [TimeMachineSingleAxisPoint]],
        fullHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]]
    ) -> [TimeMachineCombinedTrendDescriptor] {
        let goldLeftOnlyPoints = historyPointsBySymbol["gold_cny"] ?? singleAxisPoints(for: filteredTrendPoints, range: selectedRange, left: \.goldAnchorPriceCNY)
        let nasdaqLeftOnlyPoints = historyPointsBySymbol["nasdaq"] ?? singleAxisPoints(for: filteredTrendPoints, range: selectedRange, left: \.nasdaqAnchorPriceUSD)

        let primaryCards = [
            TimeMachineCombinedTrendDescriptor(
                symbol: "gold_cny",
                title: AppLocalization.string("黄金"),
                subtitle: nil,
                leftTitle: AppLocalization.string("价格"),
                rightTitle: AppLocalization.string("折算"),
                points: pairedPoints(for: filteredTrendPoints, range: selectedRange, left: \.goldAnchorPriceCNY, right: \.goldEquivalent),
                leftOnlyPoints: goldLeftOnlyPoints,
                leftColor: AssetTheme.gold,
                rightColor: AssetTheme.positive,
                leftLatestLabel: goldLeftOnlyPoints.last.map { "\($0.value.currencyString())/g" } ?? "--",
                rightLatestLabel: latestPoint?.goldEquivalent.map { "\($0.plainNumberString()) g" } ?? "--",
                leftAxisStyle: .currency(code: "CNY"),
                rightAxisStyle: .quantity(unit: "g", maxFractionDigits: 2),
                showsComparisonLine: true,
                historyDrilldown: historyDrilldown(
                    symbol: "gold_cny",
                    title: AppLocalization.string("黄金"),
                    subtitle: AppLocalization.string("人民币计价"),
                    color: AssetTheme.gold,
                    axisStyle: .currency(code: "CNY", suffix: "/g"),
                    fullHistoryPointsBySymbol: fullHistoryPointsBySymbol
                )
            ),
            TimeMachineCombinedTrendDescriptor(
                symbol: "nasdaq",
                title: AppLocalization.string("纳指"),
                subtitle: nil,
                leftTitle: AppLocalization.string("价格"),
                rightTitle: AppLocalization.string("折算"),
                points: pairedPoints(for: filteredTrendPoints, range: selectedRange, left: \.nasdaqAnchorPriceUSD, right: \.nasdaqEquivalent),
                leftOnlyPoints: nasdaqLeftOnlyPoints,
                leftColor: AssetTheme.accentBlue,
                rightColor: AssetTheme.positive,
                leftLatestLabel: nasdaqLeftOnlyPoints.last.map { $0.value.currencyString(code: "USD") } ?? "--",
                rightLatestLabel: latestPoint?.nasdaqEquivalent.map { AppLocalization.format("%@ 份", $0.plainNumberString()) } ?? "--",
                leftAxisStyle: .currency(code: "USD"),
                rightAxisStyle: .quantity(unit: AppLocalization.string("份"), maxFractionDigits: 2),
                showsComparisonLine: true,
                historyDrilldown: historyDrilldown(
                    symbol: "nasdaq",
                    title: AppLocalization.string("纳指"),
                    subtitle: AppLocalization.string("纳斯达克综合指数"),
                    color: AssetTheme.accentBlue,
                    axisStyle: .currency(code: "USD"),
                    fullHistoryPointsBySymbol: fullHistoryPointsBySymbol
                )
            )
        ]

        let publicIndexCards: [TimeMachineCombinedTrendDescriptor] = Self.publicIndexConfigs
            .filter { visibleDetailTrendSymbols.contains($0.symbol) }
            .compactMap { config -> TimeMachineCombinedTrendDescriptor? in
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
                symbol: config.symbol,
                title: config.title,
                subtitle: currency == "CNY" ? AppLocalization.string("按当前总资产折算") : AppLocalization.string("按当前总资产、当前汇率估算"),
                leftTitle: AppLocalization.string("指数现价"),
                rightTitle: AppLocalization.string("资产折算"),
                points: comparisonPoints,
                leftOnlyPoints: displayedLeftPoints,
                leftColor: config.color,
                rightColor: AssetTheme.positive,
                leftLatestLabel: latestLeftPoint.map { $0.value.currencyString(code: currency) } ?? "--",
                rightLatestLabel: latestComparisonPoint.map { AppLocalization.format("%@ 份", $0.rightValue.plainNumberString()) } ?? "--",
                leftAxisStyle: .currency(code: currency),
                rightAxisStyle: .quantity(unit: AppLocalization.string("份"), maxFractionDigits: 2),
                showsComparisonLine: comparisonPoints.count >= 2,
                historyDrilldown: historyDrilldown(
                    symbol: config.symbol,
                    title: config.title,
                    subtitle: nil,
                    color: config.color,
                    axisStyle: .currency(code: currency),
                    fullHistoryPointsBySymbol: fullHistoryPointsBySymbol
                )
            )
        }

        return primaryCards.filter { visibleDetailTrendSymbols.contains($0.symbol) } + publicIndexCards
    }

    private func historyDrilldown(
        symbol: String,
        title: String,
        subtitle: String?,
        color: Color,
        axisStyle: TimeMachineAxisValueStyle,
        fullHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]]
    ) -> TimeMachineHistoryDrilldown? {
        guard let points = fullHistoryPointsBySymbol[symbol], points.count >= 2 else { return nil }
        let candlesticks = cachedFullHistoryCandlesticksBySymbol[symbol] ?? []
        return TimeMachineHistoryDrilldown(
            symbol: symbol,
            title: title,
            subtitle: subtitle,
            points: points,
            candlesticks: candlesticks,
            color: color,
            axisStyle: axisStyle
        )
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
        guard !historyPoints.isEmpty, !trendPoints.isEmpty else { return [] }

        var cleanedPoints: [TimeMachineDualAxisPoint] = []
        cleanedPoints.reserveCapacity(historyPoints.count)

        var nearestTrendIndex = 0

        for point in historyPoints {
            while nearestTrendIndex + 1 < trendPoints.count {
                let currentDistance = abs(trendPoints[nearestTrendIndex].date.timeIntervalSince(point.date))
                let nextDistance = abs(trendPoints[nearestTrendIndex + 1].date.timeIntervalSince(point.date))
                guard nextDistance <= currentDistance else { break }
                nearestTrendIndex += 1
            }

            guard let priceInCNY = convertedPriceToCNY(point.value, currency: currency),
                  priceInCNY.isFinite,
                  priceInCNY > 0 else {
                continue
            }

            let equivalent = trendPoints[nearestTrendIndex].mainAssets / priceInCNY
            guard equivalent.isFinite, equivalent > 0 else { continue }

            cleanedPoints.append(
                TimeMachineDualAxisPoint(
                    date: point.date,
                    leftValue: point.value,
                    rightValue: equivalent
                )
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

    private func hasSnapshotRecord(on date: Date) -> Bool {
        cachedSnapshotIDByDay[Calendar.current.startOfDay(for: date)] != nil
    }

    @MainActor
    private func openRecord(for date: Date) {
        guard let snapshotID = cachedSnapshotIDByDay[Calendar.current.startOfDay(for: date)] else { return }
        var descriptor = FetchDescriptor<AssetSnapshot>(
            predicate: #Predicate<AssetSnapshot> { snapshot in
                snapshot.id == snapshotID
            }
        )
        descriptor.fetchLimit = 1
        selectedRecordSnapshot = try? modelContext.fetch(descriptor).first
    }

    @MainActor
    private func revealDetailComparison(_ option: TimeMachineDetailComparisonOption) {
        guard !visibleDetailTrendSymbols.contains(option.symbol) else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            _ = visibleDetailTrendSymbols.insert(option.symbol)
        }
        lastFullHistoryPointsCacheToken = nil
        scheduleVisualizationRefresh(
            force: true,
            includeDetailCards: true,
            delayNanoseconds: 0
        )
    }

    private var trendVideoExportBar: some View {
        Button {
            openTrendVideoPreview()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "video.badge.waveform")
                    .font(AppTypography.metaStrong)

                Text(AppLocalization.string("生成走势视频"))
                    .font(AppTypography.metaStrong)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(AppTypography.chipIcon)
            }
            .foregroundStyle(AssetTheme.goldSoft)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(trendVideoPreviewRequest != nil || filteredTrendPoints.count < 2)
        .opacity(trendVideoPreviewRequest != nil || filteredTrendPoints.count < 2 ? 0.48 : 1)
    }

    @MainActor
    private func openTrendVideoPreview() {
        let exportPoints = cachedFilteredTrendPoints
        guard exportPoints.count >= 2 else {
            trendVideoExportErrorMessage = AppLocalization.string("趋势数据不足，至少需要两条记录")
            return
        }

        trendVideoPreviewRequest = TrendVideoPreviewRequest(
            points: exportPoints,
            rangeLabel: selectedRange.summaryLabel
        )
    }

    private var heroTrendSection: some View {
        Group {
            if let latestPoint, !filteredTrendPoints.isEmpty {
                TimeMachineHeroTrendCard(
                    points: filteredTrendPoints,
                    latestPoint: latestPoint,
                    selectedRange: $selectedRange,
                    hasRecord: hasSnapshotRecord(on:),
                    onOpenRecord: openRecord(for:)
                )
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if lastVisualizationCacheToken == nil {
                                LoadingStateCard(title: AppLocalization.string("时光机加载中"))
                            } else if !filteredTrendPoints.isEmpty {
                                heroTrendSection

                                TimeMachineSectionDivider()
                                    .padding(.vertical, 14)

                                trendVideoExportBar

                                if !monthlySurplusPoints.isEmpty || !annualSurplusPoints.isEmpty {
                                    TimeMachineSectionDivider()
                                        .padding(.vertical, 14)

                                    TimeMachineMonthlySurplusCard(
                                        points: monthlySurplusPoints,
                                        annualPoints: annualSurplusPoints
                                    )
                                }

                                if !detailTrendCards.isEmpty || !hiddenDetailComparisonOptions.isEmpty {
                                    TimeMachineSectionDivider()
                                        .padding(.vertical, 14)
                                        .onboardingAnchor(.timeMachineAnchors)

                                    ForEach(detailTrendCards) { card in
                                        if card.id != detailTrendCards.first?.id {
                                            TimeMachineSectionDivider()
                                                .padding(.vertical, 16)
                                        }

                                        TimeMachineDualAxisTrendCard(descriptor: card) { history in
                                            selectedHistoryDrilldown = history
                                        }
                                    }

                                    if !hiddenDetailComparisonOptions.isEmpty {
                                        if !detailTrendCards.isEmpty {
                                            TimeMachineSectionDivider()
                                                .padding(.vertical, 12)
                                        }

                                        TimeMachineComparisonRevealButtons(options: hiddenDetailComparisonOptions) { option in
                                            revealDetailComparison(option)
                                        }
                                    }
                                }
                            } else {
                                EmptyStateCard(
                                    title: AppLocalization.string("暂无趋势数据"),
                                    message: AppLocalization.string("请先在记录页保存历史资产快照。"),
                                    systemImage: "chart.line.uptrend.xyaxis"
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, TabScrollLayout.bottomPadding)
                    }
                    .onScrollPhaseChange { _, newPhase in
                        isScrollInProgress = newPhase.isScrolling
                    }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedRecordSnapshot) { snapshot in
                SnapshotDetailView(snapshot: snapshot)
            }
        }
        .sheet(item: $selectedHistoryDrilldown) { descriptor in
            TimeMachineHistoryDrilldownSheet(descriptor: descriptor)
        }
        .sheet(item: $trendVideoPreviewRequest) { request in
            TrendVideoPreviewSheet(points: request.points, rangeLabel: request.rangeLabel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert(AppLocalization.string("视频生成失败"), isPresented: Binding(
            get: { trendVideoExportErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    trendVideoExportErrorMessage = nil
                }
            }
        )) {
            Button(AppLocalization.string("知道了"), role: .cancel) {}
        } message: {
            Text(trendVideoExportErrorMessage ?? AppLocalization.string("请稍后再试"))
        }
        .task(id: isActive) {
            if isActive {
                let storeRevision = ModelStoreRevisionClock.shared.currentRevision()
                if storeRevision != lastObservedStoreRevision {
                    lastObservedStoreRevision = storeRevision
                    modelSaveRevision &+= 1
                }
                scheduleVisualizationRefresh(
                    force: lastVisualizationCacheToken == nil,
                    includeDetailCards: false,
                    delayNanoseconds: 0
                )

                await marketStore.refreshHistoryIfNeeded()
                guard !Task.isCancelled else { return }
                await SnapshotAnchorService.backfillIfNeeded(in: modelContext)
                guard !Task.isCancelled else { return }
                scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 0)
            } else {
                pendingVisualizationRefreshTask?.cancel()
                pendingLiveMarketTrendRefreshTask?.cancel()
                deferredDetailCardsTask?.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { notification in
            guard isActive else { return }
            guard PortfolioSaveNotificationFilter.affectsPortfolio(notification) else { return }
            // Keep the last value projection mounted while the background actor builds
            // its replacement; the revision token still guarantees a fresh fetch.
            lastObservedStoreRevision = ModelStoreRevisionClock.shared.currentRevision()
            modelSaveRevision &+= 1
        }
        .onChange(of: isActive ? snapshotVisualizationCacheToken : (lastVisualizationCacheToken ?? 0)) { _, _ in
            guard isActive else { return }
            scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 120_000_000)
        }
        .onChange(of: isActive ? liveMarketVisualizationCacheToken : (lastLiveMarketVisualizationCacheToken ?? 0)) { _, _ in
            guard isActive else { return }
            scheduleLiveMarketTrendRefresh()
        }
        .onReceive(marketStore.$historySeries.dropFirst()) { _ in
            guard isActive else { return }
            scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 80_000_000)
        }
        .onReceive(marketStore.$overview.combineLatest(marketStore.$exchangeRates).dropFirst()) { _ in
            guard isActive else { return }
            scheduleLiveMarketTrendRefresh()
        }
        #if DEBUG
        .task(id: lastVisualizationCacheToken) {
            guard ProcessInfo.processInfo.arguments.contains("-openTrendVideoPreview"),
                  !didOpenDebugTrendVideoPreview,
                  filteredTrendPoints.count >= 2 else { return }
            didOpenDebugTrendVideoPreview = true
            try? await Task.sleep(for: .milliseconds(180))
            openTrendVideoPreview()
        }
        #endif
    }
}

nonisolated struct BacktestSeriesPoint: Identifiable, Sendable {
    let id: Int
    let date: Date
    let portfolioValue: Double

    init(date: Date, portfolioValue: Double, sequence: Int = 0) {
        self.id = sequence
        self.date = date
        self.portfolioValue = portfolioValue
    }
}
