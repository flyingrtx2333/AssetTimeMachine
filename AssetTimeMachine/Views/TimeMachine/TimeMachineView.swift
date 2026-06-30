import SwiftUI
import SwiftData
import Charts
import UIKit

private struct TrendVideoPreviewRequest: Identifiable {
    let id = UUID()
    let points: [TimeMachineTrendPoint]
    let rangeLabel: String
}

struct TimeMachineView: View {
    @Environment(\.modelContext) private var modelContext
    let marketStore: RemoteMarketStore
    let isActive: Bool
    let onOpenRecordSnapshot: (UUID) -> Void
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @State private var selectedRange: TimeMachineRange = .sixMonths
    @State private var cachedTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedFilteredTrendPoints: [TimeMachineTrendPoint] = []
    @State private var cachedMonthlySurplusPoints: [TimeMachineMonthlySurplusPoint] = []
    @State private var cachedAnnualSurplusPoints: [TimeMachineAnnualSurplusPoint] = []
    @State private var cachedHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]] = [:]
    @State private var cachedFullHistoryPointsBySymbol: [String: [TimeMachineSingleAxisPoint]] = [:]
    @State private var cachedDetailTrendCards: [TimeMachineCombinedTrendDescriptor] = []
    @State private var cachedTrendPointBySnapshotID: [UUID: TimeMachineTrendPointCacheEntry] = [:]
    @State private var cachedAllRangeSnapshots: [AssetSnapshot]?
    @State private var lastFullHistoryPointsCacheToken: Int?
    @State private var lastVisualizationCacheToken: Int?
    @State private var lastDetailTrendCardsCacheToken: Int?
    @State private var deferredDetailCardsTask: Task<Void, Never>?
    @State private var deferredFullTrendTask: Task<Void, Never>?
    @State private var pendingVisualizationRefreshTask: Task<Void, Never>?
    @State private var activeGeneration = 0
    @State private var visibleDetailTrendSymbols: Set<String> = ["gold_cny"]
    @State private var selectedHistoryDrilldown: TimeMachineHistoryDrilldown?
    @State private var trendVideoPreviewRequest: TrendVideoPreviewRequest?
    @State private var trendVideoExportErrorMessage: String?
    #if DEBUG
    @State private var didOpenDebugTrendVideoPreview = false
    #endif

    init(marketStore: RemoteMarketStore, isActive: Bool, onOpenRecordSnapshot: @escaping (UUID) -> Void) {
        self.marketStore = marketStore
        self.isActive = isActive
        self.onOpenRecordSnapshot = onOpenRecordSnapshot

        var snapshotDescriptor = FetchDescriptor<AssetSnapshot>(
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .reverse)]
        )
        snapshotDescriptor.fetchLimit = 400
        _snapshots = Query(snapshotDescriptor)
    }

    private var chronologicalSnapshots: [AssetSnapshot] {
        snapshots.reversed()
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

    private static let publicIndexConfigs: [(symbol: String, title: String, color: Color)] = [
        ("sp500", AppLocalization.string("标普500"), AssetTheme.goldSoft),
        ("dowjones", AppLocalization.string("道指"), AssetTheme.accentOrange),
        ("hsi", AppLocalization.string("恒生"), AssetTheme.accentBlue),
        ("nikkei", AppLocalization.string("日经225"), AssetTheme.positive),
        ("csi300", AppLocalization.string("沪深300"), AssetTheme.textPrimary),
        ("shanghai_composite", AppLocalization.string("上证综指"), AssetTheme.textSecondary)
    ]

    private static let detailComparisonOptions: [TimeMachineDetailComparisonOption] = [
        TimeMachineDetailComparisonOption(symbol: "gold_cny", title: AppLocalization.string("黄金"), color: AssetTheme.gold),
        TimeMachineDetailComparisonOption(symbol: "nasdaq", title: AppLocalization.string("纳指"), color: AssetTheme.accentBlue)
    ] + publicIndexConfigs.map { config in
        TimeMachineDetailComparisonOption(symbol: config.symbol, title: config.title, color: config.color)
    }

    private var hiddenDetailComparisonOptions: [TimeMachineDetailComparisonOption] {
        Self.detailComparisonOptions.filter { !visibleDetailTrendSymbols.contains($0.symbol) }
    }

    private func historySeriesPoints(_ series: PublicHistorySeries, range: TimeMachineRange? = nil) -> [TimeMachineSingleAxisPoint] {
        let points: [TimeMachineSingleAxisPoint] = Array(zip(series.dates, series.prices)).compactMap { (dateText: String, price: Double) -> TimeMachineSingleAxisPoint? in
            guard let date = historicalSeriesDate(from: dateText), price.isFinite, price > 0 else { return nil }
            return TimeMachineSingleAxisPoint(date: date, value: price)
        }
        let sortedPoints = points.sorted { $0.date < $1.date }
        guard let range else { return sortedPoints }
        return range.filter(sortedPoints)
    }

    private func historySeriesCandlesticks(_ series: PublicHistorySeries, range: TimeMachineRange? = nil) -> [TimeMachineCandlestickPoint] {
        let candlesticks = series.dailyBars.compactMap { bar -> TimeMachineCandlestickPoint? in
            guard
                bar.open.isFinite,
                bar.high.isFinite,
                bar.low.isFinite,
                bar.close.isFinite,
                bar.open > 0,
                bar.high >= max(bar.open, bar.close, bar.low),
                bar.low <= min(bar.open, bar.close, bar.high)
            else { return nil }

            return TimeMachineCandlestickPoint(
                date: bar.date,
                open: bar.open,
                high: bar.high,
                low: bar.low,
                close: bar.close,
                volume: bar.volume
            )
        }
        .sorted { $0.date < $1.date }

        guard let range else { return candlesticks }
        return range.filter(candlesticks)
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

    @MainActor
    private func trendPoint(for snapshot: AssetSnapshot) -> TimeMachineTrendPoint {
        let liveAnchors = liveMarketAnchors
        let token = TimeMachineTrendPointBuilder.cacheToken(for: snapshot, liveAnchors: liveAnchors)
        if let cached = cachedTrendPointBySnapshotID[snapshot.id], cached.token == token {
            return cached.point
        }

        let point = TimeMachineTrendPointBuilder.make(from: snapshot, liveAnchors: liveAnchors)
        cachedTrendPointBySnapshotID[snapshot.id] = TimeMachineTrendPointCacheEntry(token: token, point: point)
        return point
    }

    private var snapshotCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(snapshots.count)
        if let latest = snapshots.first {
            hasher.combine(latest.id)
            hasher.combine(latest.updatedAt.timeIntervalSinceReferenceDate)
            hasher.combine(latest.marketAnchorsUpdatedAt?.timeIntervalSinceReferenceDate)
            hasher.combine(latest.entries.count)
        }
        if let oldest = snapshots.last, oldest.id != snapshots.first?.id {
            hasher.combine(oldest.id)
            hasher.combine(oldest.updatedAt.timeIntervalSinceReferenceDate)
        }
        return hasher.finalize()
    }

    private var historyCacheToken: Int {
        var hasher = Hasher()
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
        var hasher = Hasher()
        let markets = (marketStore.overview?.markets ?? []).sorted { $0.symbol < $1.symbol }
        hasher.combine(markets.count)

        for market in markets {
            hasher.combine(market.symbol)
            hasher.combine(market.price)
            hasher.combine(market.currency)
            hasher.combine(market.fetchedAt.timeIntervalSinceReferenceDate)
        }

        return hasher.finalize()
    }

    private var exchangeRateCacheToken: Int {
        var hasher = Hasher()
        let rates = marketStore.exchangeRates.sorted { $0.key < $1.key }
        hasher.combine(rates.count)

        for (currency, rate) in rates {
            hasher.combine(currency)
            hasher.combine(rate)
        }

        return hasher.finalize()
    }

    private var visualizationCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(selectedRange.rawValue)
        hasher.combine(snapshotCacheToken)
        hasher.combine(historyCacheToken)
        hasher.combine(overviewCacheToken)
        hasher.combine(exchangeRateCacheToken)
        return hasher.finalize()
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
        let token = visualizationCacheToken
        if !force, token == lastVisualizationCacheToken {
            if includeDetailCards {
                await refreshDetailTrendCardsIfNeeded()
            } else if cachedDetailTrendCards.isEmpty {
                scheduleDeferredDetailCardsRefresh(for: token)
            }
            return
        }
        await refreshVisualizationCache(includeDetailCards: includeDetailCards, cacheToken: token)
        lastVisualizationCacheToken = token
    }

    @MainActor
    private func refreshVisualizationCache(includeDetailCards: Bool = true, cacheToken: Int? = nil) async {
        guard !Task.isCancelled, isActive else { return }
        let cacheToken = cacheToken ?? visualizationCacheToken
        deferredFullTrendTask?.cancel()

        let visibleSnapshots = await resolvedSnapshotsForVisualization()
        var trendPoints: [TimeMachineTrendPoint] = []
        trendPoints.reserveCapacity(visibleSnapshots.count)
        for (index, snapshot) in visibleSnapshots.enumerated() {
            guard !Task.isCancelled, isActive else { return }
            trendPoints.append(trendPoint(for: snapshot))
            if index.isMultiple(of: 6) {
                await Task.yield()
            }
        }

        let validSnapshotIDs = Set(snapshots.map(\.id))
        cachedTrendPointBySnapshotID = cachedTrendPointBySnapshotID.filter { validSnapshotIDs.contains($0.key) }

        let filteredTrendPoints = trendPoints

        cachedTrendPoints = trendPoints
        cachedFilteredTrendPoints = filteredTrendPoints

        if selectedRange == .all {
            cachedMonthlySurplusPoints = buildMonthlySurplusPoints(from: trendPoints)
            cachedAnnualSurplusPoints = buildAnnualSurplusPoints(from: trendPoints)
        } else {
            cachedMonthlySurplusPoints = []
            cachedAnnualSurplusPoints = []
            scheduleDeferredFullTrendRefresh(for: cacheToken)
        }

        guard !filteredTrendPoints.isEmpty else {
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
            fullHistoryPointsBySymbol = buildFullHistoryPointsBySymbol()
            cachedFullHistoryPointsBySymbol = fullHistoryPointsBySymbol
            lastFullHistoryPointsCacheToken = fullHistoryToken
        }
        let historyPointsBySymbol = buildHistoryPointsBySymbol(
            fullHistoryPointsBySymbol: fullHistoryPointsBySymbol,
            trendPoints: filteredTrendPoints
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

    private func snapshotsForSelectedRange(calendar: Calendar = .current) -> [AssetSnapshot] {
        if selectedRange == .all {
            if let cachedAllRangeSnapshots, !cachedAllRangeSnapshots.isEmpty {
                return cachedAllRangeSnapshots
            }
            return chronologicalSnapshots
        }

        let orderedSnapshots = chronologicalSnapshots
        guard let latestDate = orderedSnapshots.last?.date,
              let startDate = selectedRangeStartDate(from: latestDate, calendar: calendar) else {
            return orderedSnapshots
        }

        return orderedSnapshots.filter { $0.date >= startDate }
    }

    @MainActor
    private func resolvedSnapshotsForVisualization() async -> [AssetSnapshot] {
        guard selectedRange == .all else {
            cachedAllRangeSnapshots = nil
            return snapshotsForSelectedRange()
        }

        if let cachedAllRangeSnapshots, !cachedAllRangeSnapshots.isEmpty {
            return cachedAllRangeSnapshots
        }

        let descriptor = FetchDescriptor<AssetSnapshot>(
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .forward)]
        )
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        if fetched.count > chronologicalSnapshots.count {
            cachedAllRangeSnapshots = fetched
            return fetched
        }
        return chronologicalSnapshots
    }

    private func selectedRangeStartDate(from latestDate: Date, calendar: Calendar = .current) -> Date? {
        switch selectedRange {
        case .halfMonth:
            return calendar.date(byAdding: .day, value: -15, to: latestDate)
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -1, to: latestDate)
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: latestDate)
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: latestDate)
        case .threeYears:
            return calendar.date(byAdding: .year, value: -3, to: latestDate)
        case .all:
            return nil
        }
    }

    @MainActor
    private func scheduleDeferredFullTrendRefresh(for token: Int) {
        deferredFullTrendTask?.cancel()
        let generation = activeGeneration
        deferredFullTrendTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled,
                  isActive,
                  generation == activeGeneration,
                  token == lastVisualizationCacheToken else { return }

            var fullTrendPoints: [TimeMachineTrendPoint] = []
            let orderedSnapshots = chronologicalSnapshots
            fullTrendPoints.reserveCapacity(orderedSnapshots.count)

            for (index, snapshot) in orderedSnapshots.enumerated() {
                guard !Task.isCancelled,
                      isActive,
                      generation == activeGeneration,
                      token == lastVisualizationCacheToken else { return }
                fullTrendPoints.append(trendPoint(for: snapshot))

                if index.isMultiple(of: 2) {
                    await Task.yield()
                }
            }

            guard !Task.isCancelled,
                  isActive,
                  generation == activeGeneration,
                  token == lastVisualizationCacheToken else { return }
            cachedTrendPoints = fullTrendPoints
            cachedMonthlySurplusPoints = buildMonthlySurplusPoints(from: fullTrendPoints)
            cachedAnnualSurplusPoints = buildAnnualSurplusPoints(from: fullTrendPoints)
        }
    }

    @MainActor
    private func refreshDetailTrendCardsIfNeeded(force: Bool = false) async {
        let token = visualizationCacheToken
        guard force || token != lastDetailTrendCardsCacheToken else { return }
        if token != lastVisualizationCacheToken {
            await refreshVisualizationCache(includeDetailCards: true, cacheToken: token)
            lastVisualizationCacheToken = token
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
            guard !Task.isCancelled else { return }
            guard isActive, token == visualizationCacheToken else { return }
            await refreshDetailTrendCardsIfNeeded()
        }
    }

    private func buildFullHistoryPointsBySymbol() -> [String: [TimeMachineSingleAxisPoint]] {
        let symbols = Self.detailComparisonOptions
            .map(\.symbol)
            .filter { visibleDetailTrendSymbols.contains($0) }
        return Dictionary(uniqueKeysWithValues: symbols.compactMap { symbol in
            guard let series = marketStore.history(for: symbol) else { return nil }
            let points = historySeriesPoints(series)
            guard !points.isEmpty else { return nil }
            return (symbol, points)
        })
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

    private func buildMonthlySurplusPoints(
        from source: [TimeMachineTrendPoint],
        calendar: Calendar = .current
    ) -> [TimeMachineMonthlySurplusPoint] {
        guard !source.isEmpty else { return [] }

        let grouped = Dictionary(grouping: source) { point in
            calendar.dateInterval(of: .month, for: point.date)?.start ?? calendar.startOfDay(for: point.date)
        }

        let sortedMonthStarts = grouped.keys.sorted()
        var points: [TimeMachineMonthlySurplusPoint] = []
        points.reserveCapacity(sortedMonthStarts.count)
        var previousMonthEndNetAssets: Double?

        for monthStart in sortedMonthStarts {
            guard let monthPoints = grouped[monthStart]?.sorted(by: { $0.date < $1.date }),
                  let firstPoint = monthPoints.first,
                  let lastPoint = monthPoints.last else {
                continue
            }

            let baseline = previousMonthEndNetAssets ?? firstPoint.netAssets
            let surplus = lastPoint.netAssets - baseline
            points.append(
                TimeMachineMonthlySurplusPoint(
                    monthStart: monthStart,
                    date: lastPoint.date,
                    surplus: surplus,
                    monthEndNetAssets: lastPoint.netAssets
                )
            )
            previousMonthEndNetAssets = lastPoint.netAssets
        }

        return filterMonthlySurplusPoints(points, calendar: calendar)
    }

    private func filterMonthlySurplusPoints(
        _ points: [TimeMachineMonthlySurplusPoint],
        calendar: Calendar = .current
    ) -> [TimeMachineMonthlySurplusPoint] {
        guard let latestDate = points.last?.date else { return [] }

        let startDate: Date?
        switch selectedRange {
        case .halfMonth:
            startDate = calendar.date(byAdding: .day, value: -15, to: latestDate)
        case .oneMonth:
            startDate = calendar.date(byAdding: .month, value: -1, to: latestDate)
        case .sixMonths:
            startDate = calendar.date(byAdding: .month, value: -6, to: latestDate)
        case .oneYear:
            startDate = calendar.date(byAdding: .year, value: -1, to: latestDate)
        case .threeYears:
            startDate = calendar.date(byAdding: .year, value: -3, to: latestDate)
        case .all:
            startDate = nil
        }

        guard let startDate else { return points }
        let filteredPoints = points.filter { $0.date >= startDate }
        guard let monthlyBucketLimit = selectedRange.monthlyBucketLimit else { return filteredPoints }
        return Array(filteredPoints.suffix(monthlyBucketLimit))
    }

    private func buildAnnualSurplusPoints(
        from source: [TimeMachineTrendPoint],
        calendar: Calendar = .current
    ) -> [TimeMachineAnnualSurplusPoint] {
        guard !source.isEmpty else { return [] }

        let grouped = Dictionary(grouping: source) { point in
            calendar.dateInterval(of: .year, for: point.date)?.start ?? calendar.startOfDay(for: point.date)
        }

        let sortedYearStarts = grouped.keys.sorted()
        var points: [TimeMachineAnnualSurplusPoint] = []
        points.reserveCapacity(sortedYearStarts.count)
        var previousYearEndNetAssets: Double?

        for yearStart in sortedYearStarts {
            guard let yearPoints = grouped[yearStart]?.sorted(by: { $0.date < $1.date }),
                  let firstPoint = yearPoints.first,
                  let lastPoint = yearPoints.last else {
                continue
            }

            let baseline = previousYearEndNetAssets ?? firstPoint.netAssets
            let surplus = lastPoint.netAssets - baseline
            points.append(
                TimeMachineAnnualSurplusPoint(
                    yearStart: yearStart,
                    date: lastPoint.date,
                    surplus: surplus,
                    yearEndNetAssets: lastPoint.netAssets,
                    isCurrentYear: calendar.isDate(lastPoint.date, equalTo: .now, toGranularity: .year)
                )
            )
            previousYearEndNetAssets = lastPoint.netAssets
        }

        return points
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
        let candlesticks = marketStore.history(for: symbol).map { historySeriesCandlesticks($0) } ?? []
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
        (try? SnapshotService.snapshot(on: date, in: modelContext)) != nil
    }

    @MainActor
    private func openRecord(for date: Date) {
        guard let snapshot = try? SnapshotService.snapshot(on: date, in: modelContext) else { return }
        onOpenRecordSnapshot(snapshot.id)
    }

    @MainActor
    private func revealDetailComparison(_ option: TimeMachineDetailComparisonOption) {
        guard !visibleDetailTrendSymbols.contains(option.symbol) else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            _ = visibleDetailTrendSymbols.insert(option.symbol)
        }
        lastFullHistoryPointsCacheToken = nil
        Task {
            await refreshVisualizationCacheIfNeeded(force: true, includeDetailCards: true)
        }
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
        .disabled(trendVideoPreviewRequest != nil || snapshots.count < 2)
        .opacity(trendVideoPreviewRequest != nil || snapshots.count < 2 ? 0.48 : 1)
    }

    @MainActor
    private func openTrendVideoPreview() {
        Task {
            let sourceSnapshots = await resolvedSnapshotsForVisualization()
            var exportPoints: [TimeMachineTrendPoint] = []
            exportPoints.reserveCapacity(sourceSnapshots.count)
            for (index, snapshot) in sourceSnapshots.enumerated() {
                guard !Task.isCancelled else { return }
                exportPoints.append(trendPoint(for: snapshot))
                if index.isMultiple(of: 8) {
                    await Task.yield()
                }
            }

            guard exportPoints.count >= 2 else {
                trendVideoExportErrorMessage = AppLocalization.string("趋势数据不足，至少需要两条记录")
                return
            }

            trendVideoPreviewRequest = TrendVideoPreviewRequest(
                points: exportPoints,
                rangeLabel: TimeMachineRange.all.summaryLabel
            )
        }
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
                                    .padding(.vertical, 22)

                                trendVideoExportBar

                                if !monthlySurplusPoints.isEmpty || !annualSurplusPoints.isEmpty {
                                    TimeMachineSectionDivider()
                                        .padding(.vertical, 22)

                                    TimeMachineMonthlySurplusCard(
                                        points: monthlySurplusPoints,
                                        annualPoints: annualSurplusPoints
                                    )
                                }

                                if !detailTrendCards.isEmpty || !hiddenDetailComparisonOptions.isEmpty {
                                    TimeMachineSectionDivider()
                                        .padding(.vertical, 22)

                                    VStack(spacing: 0) {
                                        ForEach(Array(detailTrendCards.enumerated()), id: \.element.id) { index, card in
                                            if index > 0 {
                                                TimeMachineSectionDivider()
                                                    .padding(.vertical, 26)
                                            }

                                            TimeMachineDualAxisTrendCard(descriptor: card) { history in
                                                selectedHistoryDrilldown = history
                                            }
                                        }

                                        if !hiddenDetailComparisonOptions.isEmpty {
                                            if !detailTrendCards.isEmpty {
                                                TimeMachineSectionDivider()
                                                    .padding(.vertical, 20)
                                            }

                                            TimeMachineComparisonRevealButtons(options: hiddenDetailComparisonOptions) { option in
                                                revealDetailComparison(option)
                                            }
                                        }
                                    }
                                    .onboardingAnchor(.timeMachineAnchors)
                                }
                            } else {
                                EmptyStateCard(
                                    title: AppLocalization.string("暂无趋势数据"),
                                    message: AppLocalization.string("请先在记录页保存历史资产快照。"),
                                    systemImage: "chart.line.uptrend.xyaxis"
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 136)
                    }
            }
            .toolbar(.hidden, for: .navigationBar)
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
            activeGeneration += 1
            if isActive {
                await marketStore.refreshHistoryIfNeeded()
                guard !Task.isCancelled else { return }
                scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 0)
                Task {
                    guard !Task.isCancelled, isActive else { return }
                    await SnapshotAnchorService.backfillIfNeeded(in: modelContext)
                    guard !Task.isCancelled, isActive else { return }
                    scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 0)
                }
            } else {
                pendingVisualizationRefreshTask?.cancel()
                deferredDetailCardsTask?.cancel()
                deferredFullTrendTask?.cancel()
            }
        }
        .onChange(of: isActive ? visualizationCacheToken : (lastVisualizationCacheToken ?? 0)) { _, _ in
            guard isActive else { return }
            scheduleVisualizationRefresh(includeDetailCards: false, delayNanoseconds: 80_000_000)
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

nonisolated struct BacktestSeriesPoint: Identifiable {
    let id: Int
    let date: Date
    let portfolioValue: Double

    init(date: Date, portfolioValue: Double, sequence: Int = 0) {
        self.id = sequence
        self.date = date
        self.portfolioValue = portfolioValue
    }
}
