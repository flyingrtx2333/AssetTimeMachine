import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers
import UIKit

private enum AppTab: Hashable {
    case dashboard
    case snapshots
    case timeMachine
    case backtest
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var marketStore = RemoteMarketStore()
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
        return .dashboard
    }()
    @State private var didRunStartup = false

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
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
        }
        .tint(AssetTheme.gold)
        .task {
            await runStartupIfNeeded()
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
    @StateObject private var cloudStore = AssetTimeMachineCloudStore()
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

        let sorted = grouped
            .map { name, entries in
                (name: name, amount: entries.reduce(0) { $0 + $1.resolvedAmount })
            }
            .sorted { $0.amount > $1.amount }

        let topLimit = 5
        var slices = Array(sorted.prefix(topLimit))

        if sorted.count > topLimit {
            let otherAmount = sorted.dropFirst(topLimit).reduce(0) { $0 + $1.amount }
            if otherAmount > 0 {
                slices.append((name: "其他", amount: otherAmount))
            }
        }

        return slices.enumerated().map { index, element in
            DashboardAllocationSlice(
                title: element.name,
                amount: element.amount,
                color: DashboardAllocationPalette.colors[index % DashboardAllocationPalette.colors.count]
            )
        }
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
            VStack(alignment: .leading, spacing: 10) {
                Text("总资产")
                    .font(AppTypography.eyebrow)
                    .foregroundStyle(AssetTheme.textSecondary)

                HStack(alignment: .top, spacing: 16) {
                    Text(totalAssets.currencyString())
                        .font(AppTypography.heroValue)
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.textPrimary)
                        .minimumScaleFactor(0.72)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        HeroSideMetric(
                            title: "净资产",
                            value: netAssets.currencyString(),
                            accent: AssetTheme.positive
                        )

                        HeroSideMetric(
                            title: "负债",
                            value: totalLiabilities.currencyString(),
                            accent: AssetTheme.negative
                        )
                    }
                    .frame(width: 132, alignment: .leading)
                }

                HStack(spacing: 10) {
                    InlineStat(text: "已记录 \(snapshots.count.formatted()) 天", color: AssetTheme.textSecondary)
                    InlineStat(text: latestSnapshot.map { "最近更新 \($0.date.shortDateString)" } ?? "还没有快照", color: AssetTheme.goldSoft)
                    InlineStat(text: "条目 \(latestEntryCount.formatted())", color: AssetTheme.accentBlue)
                }
            }
            .padding(.trailing, 64)
            .overlay(alignment: .topTrailing) {
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
    @FocusState private var focusedField: RecordInputField?

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

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        if let currentSnapshot {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(currentSnapshot.date.recordDateString)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AssetTheme.textSecondary)

                                        Text(PortfolioCalculator.totalAssets(for: currentSnapshot).currencyString())
                                            .font(.system(size: 34, weight: .bold, design: .rounded))
                                            .foregroundStyle(AssetTheme.textPrimary)
                                            .minimumScaleFactor(0.6)
                                            .lineLimit(1)

                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Button {
                                        focusedField = nil
                                        showsAddAssetItemSheet = true
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus")
                                                .font(.subheadline.weight(.bold))
                                            Text("资产类型")
                                                .font(.subheadline.weight(.semibold))
                                        }
                                        .foregroundStyle(AssetTheme.textPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(.white.opacity(0.05), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }

                                HStack(spacing: 8) {
                                    SummaryInlineMetric(
                                        title: "负债",
                                        value: PortfolioCalculator.totalLiabilities(for: currentSnapshot).currencyString(),
                                        accent: AssetTheme.negative
                                    )
                                    SummaryInlineMetric(
                                        title: "净资产",
                                        value: PortfolioCalculator.netAssets(for: currentSnapshot).currencyString(),
                                        accent: AssetTheme.gold
                                    )
                                }
                            }
                            .padding(.bottom, 0)

                            ForEach(nonLiabilityCategories) { category in
                                RecordCategoryCard(
                                    category: category,
                                    amountInputs: $amountInputs,
                                    quantityInputs: $quantityInputs,
                                    unitPriceInputs: $unitPriceInputs,
                                    focusedField: $focusedField,
                                    onChanged: { item in
                                        persist(item: item)
                                    }
                                )
                            }

                            ForEach(liabilityCategories) { category in
                                LiabilityCategorySection(
                                    category: category,
                                    amountInputs: $amountInputs,
                                    quantityInputs: $quantityInputs,
                                    focusedField: $focusedField,
                                    onChanged: { item in
                                        persist(item: item)
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
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 104)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedField = nil
                    }
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showsAddAssetItemSheet) {
            AddAssetItemSheet()
        }
        .task {
            await prepareSnapshotIfNeeded()
            await syncAutoRatesIfPossible()
        }
        .onChange(of: marketStore.exchangeRates) { _, _ in
            Task { @MainActor in
                await syncAutoRatesIfPossible()
            }
        }
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
}

private enum RecordInputField: Hashable {
    case amount(UUID)
    case quantity(UUID)
    case unitPrice(UUID)
}

private struct SummaryInlineMetric: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AssetItemGlyph: View {
    let item: AssetItem
    var accent: Color = AssetTheme.goldSoft
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: AssetItemService.displaySymbolName(for: item))
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(accent)
            .frame(width: size + 2, height: size + 2)
    }
}

private struct RecordCategoryCard: View {
    private enum InputBlock {
        case compact([AssetItem])
        case expanded(AssetItem)
    }

    let category: AssetCategory
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    @Binding var unitPriceInputs: [UUID: String]
    var focusedField: FocusState<RecordInputField?>.Binding
    let onChanged: (AssetItem) -> Void
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Rectangle()
                    .fill(AssetTheme.border.opacity(0.35))
                    .frame(height: 1)
                Text("\(items.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            VStack(spacing: 10) {
                ForEach(Array(inputBlocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case let .compact(compactItems):
                        LazyVGrid(columns: compactColumns, alignment: .leading, spacing: 8) {
                            ForEach(compactItems) { item in
                                ReorderableRecordCell(category: category, item: item, draggedItemID: $draggedItemID) {
                                    AssetEntryCompactCard(
                                        item: item,
                                        amountText: Binding(
                                            get: { amountInputs[item.id] ?? "" },
                                            set: { newValue in
                                                amountInputs[item.id] = newValue
                                                onChanged(item)
                                            }
                                        ),
                                        quantityText: Binding(
                                            get: { quantityInputs[item.id] ?? "" },
                                            set: { newValue in
                                                quantityInputs[item.id] = newValue
                                                onChanged(item)
                                            }
                                        ),
                                        focusedField: focusedField
                                    )
                                }
                            }
                        }
                    case let .expanded(item):
                        ReorderableRecordCell(category: category, item: item, draggedItemID: $draggedItemID) {
                            AssetEntryInputRow(
                                item: item,
                                amountText: Binding(
                                    get: { amountInputs[item.id] ?? "" },
                                    set: { newValue in
                                        amountInputs[item.id] = newValue
                                        onChanged(item)
                                    }
                                ),
                                quantityText: Binding(
                                    get: { quantityInputs[item.id] ?? "" },
                                    set: { newValue in
                                        quantityInputs[item.id] = newValue
                                        onChanged(item)
                                    }
                                ),
                                unitPriceText: Binding(
                                    get: { unitPriceInputs[item.id] ?? "" },
                                    set: { newValue in
                                        unitPriceInputs[item.id] = newValue
                                        onChanged(item)
                                    }
                                ),
                                focusedField: focusedField
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct LiabilityCategorySection: View {
    let category: AssetCategory
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    var focusedField: FocusState<RecordInputField?>.Binding
    let onChanged: (AssetItem) -> Void
    @State private var draggedItemID: UUID?

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    private var items: [AssetItem] {
        category.activeSortedItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                Spacer()
                Text("\(items.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
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
                                    onChanged(item)
                                }
                            ),
                            quantityText: Binding(
                                get: { quantityInputs[item.id] ?? "" },
                                set: { newValue in
                                    quantityInputs[item.id] = newValue
                                    onChanged(item)
                                }
                            ),
                            focusedField: focusedField
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
    var focusedField: FocusState<RecordInputField?>.Binding

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            AssetItemGlyph(item: item, accent: AssetTheme.negative, size: 12)

            Text(item.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.valuationMethod == .directAmount {
                ATMInputField(
                    text: $amountText,
                    placeholder: "0",
                    width: 72,
                    focusedField: focusedField,
                    focusValue: .amount(item.id),
                    centered: false,
                    fontSize: 12,
                    fontWeight: .semibold,
                    height: 30,
                    backgroundOpacity: 0.54,
                    strokeOpacity: 0.18
                )
            } else {
                ATMInputField(
                    text: $quantityText,
                    placeholder: item.compactRecordPlaceholder,
                    width: 72,
                    focusedField: focusedField,
                    focusValue: .quantity(item.id),
                    centered: false,
                    fontSize: 12,
                    fontWeight: .semibold,
                    height: 30,
                    backgroundOpacity: 0.54,
                    strokeOpacity: 0.18
                )
            }
        }
        .padding(.vertical, 1)
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
    @Binding var amountText: String
    @Binding var quantityText: String
    var focusedField: FocusState<RecordInputField?>.Binding

    var body: some View {
        RecordInputCard {
            HStack(alignment: .center, spacing: 4) {
                AssetItemGlyph(item: item, size: 12)
                Text(item.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if item.valuationMethod == .directAmount {
                    ATMInputField(text: $amountText, placeholder: "0", width: 72, focusedField: focusedField, focusValue: .amount(item.id), centered: false, fontSize: 12, fontWeight: .semibold, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                } else {
                    ATMInputField(text: $quantityText, placeholder: "0", width: 72, focusedField: focusedField, focusValue: .quantity(item.id), centered: false, fontSize: 12, fontWeight: .semibold, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                }
            }
        }
    }
}

private struct AssetEntryInputRow: View {
    let item: AssetItem
    @Binding var amountText: String
    @Binding var quantityText: String
    @Binding var unitPriceText: String
    var focusedField: FocusState<RecordInputField?>.Binding

    var body: some View {
        RecordInputCard {
            HStack(alignment: .top, spacing: 6) {
                AssetItemGlyph(item: item, size: 12)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AssetTheme.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        ATMInputField(text: $quantityText, placeholder: "数量", focusedField: focusedField, focusValue: .quantity(item.id), centered: false, fontSize: 12, fontWeight: .semibold, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                        ATMInputField(text: $unitPriceText, placeholder: "单价", focusedField: focusedField, focusValue: .unitPrice(item.id), centered: false, fontSize: 12, fontWeight: .semibold, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                    }
                }
            }
        }
    }
}

private struct ATMInputField: View {
    @Binding var text: String
    let placeholder: String
    var width: CGFloat? = nil
    var focusedField: FocusState<RecordInputField?>.Binding
    let focusValue: RecordInputField
    var centered: Bool = false
    var fontSize: CGFloat = 17
    var fontWeight: Font.Weight = .semibold
    var height: CGFloat = 42
    var backgroundOpacity: Double = 0.66
    var strokeOpacity: Double = 0.52

    var body: some View {
        ATMUIKitInputField(
            text: $text,
            placeholder: placeholder,
            focusedField: focusedField,
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
    var focusedField: FocusState<RecordInputField?>.Binding
    let focusValue: RecordInputField
    var centered: Bool = false
    var fontSize: CGFloat = 17
    var fontWeight: Font.Weight = .semibold

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

        let shouldBeFirstResponder = focusedField.wrappedValue == focusValue
        if shouldBeFirstResponder, !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
                context.coordinator.moveCaretToEnd(in: uiView)
            }
        } else if !shouldBeFirstResponder, uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ATMUIKitInputField

        init(parent: ATMUIKitInputField) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.focusedField.wrappedValue = parent.focusValue
            moveCaretToEnd(in: textField)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.focusedField.wrappedValue == parent.focusValue {
                parent.focusedField.wrappedValue = nil
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

    private let iconOptions: [(name: String, label: String, symbol: String)] = [
        ("icon_wechat", "微信", "message.circle.fill"),
        ("icon_alipay", "支付宝", "yensign.circle.fill"),
        ("icon_bank_card", "银行卡", "creditcard.fill"),
        ("icon_cash", "现金", "banknote.fill"),
        ("icon_btc", "BTC", "bitcoinsign.circle.fill"),
        ("icon_gold", "黄金", "seal.fill"),
        ("icon_mortgage", "房贷", "house.fill"),
        ("icon_car_loan", "车贷", "car.fill"),
        ("icon_credit_card", "信用卡", "creditcard.and.123"),
        ("icon_huabei", "花呗", "sparkles")
    ]

    private let autoAssetGridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var autoPricedOptions: [AutoPricedAssetKind] {
        AutoPricedAssetKind.allCases
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
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("名称")
                                        .font(.headline)
                                        .foregroundStyle(AssetTheme.textPrimary)

                                    TextField("例如：银行卡、房产、消费贷", text: $name)
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
                                HStack(spacing: 10) {
                                    ForEach(iconOptions, id: \.name) { option in
                                        Button {
                                            selectedIconName = option.name
                                        } label: {
                                            VStack(spacing: 8) {
                                                Image(systemName: option.symbol)
                                                    .font(.title3.weight(.semibold))
                                                    .foregroundStyle(selectedIconName == option.name ? AssetTheme.gold : AssetTheme.textPrimary)
                                                    .frame(width: 44, height: 44)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                            .fill(.white.opacity(selectedIconName == option.name ? 0.08 : 0.04))
                                                    )
                                                Text(option.label)
                                                    .font(.caption2.weight(.medium))
                                                    .foregroundStyle(AssetTheme.textSecondary)
                                            }
                                            .padding(.vertical, 4)
                                            .frame(width: 68)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .atmCardStyle()

                        VStack(alignment: .leading, spacing: 12) {
                            Text("自动更新资产")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AssetTheme.textSecondary)

                            Text("点一个就按实时价格创建，不选就是普通资产。")
                                .font(.footnote)
                                .foregroundStyle(AssetTheme.textSecondary.opacity(0.8))

                            LazyVGrid(columns: autoAssetGridColumns, alignment: .leading, spacing: 10) {
                                Button {
                                    selectedAutoPricedAssetKind = nil
                                } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: "square.grid.2x2")
                                            .font(.headline.weight(.semibold))
                                            .foregroundStyle(selectedAutoPricedAssetKind == nil ? AssetTheme.gold : AssetTheme.textPrimary)
                                            .frame(width: 38, height: 38)
                                            .background(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .fill(.white.opacity(selectedAutoPricedAssetKind == nil ? 0.1 : 0.04))
                                            )
                                        Text("普通资产")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(selectedAutoPricedAssetKind == nil ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(selectedAutoPricedAssetKind == nil ? AssetTheme.gold.opacity(0.75) : AssetTheme.border.opacity(0.38), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)

                                ForEach(autoPricedOptions) { kind in
                                    Button {
                                        selectedAutoPricedAssetKind = kind
                                        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            name = kind.defaultName
                                        }
                                    } label: {
                                        VStack(spacing: 8) {
                                            Image(systemName: symbolName(for: kind))
                                                .font(.headline.weight(.semibold))
                                                .foregroundStyle(selectedAutoPricedAssetKind == kind ? AssetTheme.gold : AssetTheme.textPrimary)
                                                .frame(width: 38, height: 38)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                        .fill(.white.opacity(selectedAutoPricedAssetKind == kind ? 0.1 : 0.04))
                                                )
                                            Text(kind.defaultName)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(selectedAutoPricedAssetKind == kind ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                                                .multilineTextAlignment(.center)
                                                .lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(selectedAutoPricedAssetKind == kind ? AssetTheme.gold.opacity(0.75) : AssetTheme.border.opacity(0.38), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .atmCardStyle()

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(AssetTheme.negative)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 36)
                }
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

    private func symbolName(for kind: AutoPricedAssetKind) -> String {
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
                                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            let latest = leftOnlyPoints.last
            let currency = marketStore.history(for: config.symbol)?.currency ?? "CNY"
            return TimeMachineCombinedTrendDescriptor(
                title: config.title,
                subtitle: nil,
                leftTitle: "指数",
                rightTitle: "趋势镜像",
                points: [],
                leftOnlyPoints: leftOnlyPoints,
                leftColor: config.color,
                rightColor: config.color.opacity(0.45),
                leftLatestLabel: latest.map { $0.value.currencyString(code: currency) } ?? "--",
                rightLatestLabel: "--",
                leftAxisStyle: .currency(code: currency),
                rightAxisStyle: .quantity(unit: "", maxFractionDigits: 2),
                showsComparisonLine: false
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
                        TimeMachineRangePicker(selectedRange: $selectedRange)

                        if let latestPoint, !filteredTrendPoints.isEmpty {
                            TimeMachineHeroTrendCard(
                                points: filteredTrendPoints,
                                latestPoint: latestPoint
                            )

                            LazyVStack(spacing: 12) {
                                ForEach(detailTrendCards) { card in
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

private enum BacktestRange: String, CaseIterable, Identifiable {
    case sixMonths
    case oneYear
    case threeYears
    case fiveYears
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sixMonths: return "6个月"
        case .oneYear: return "1年"
        case .threeYears: return "3年"
        case .fiveYears: return "5年"
        case .all: return "全部"
        }
    }

    func startDate(from latestDate: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: latestDate)
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: latestDate)
        case .threeYears:
            return calendar.date(byAdding: .year, value: -3, to: latestDate)
        case .fiveYears:
            return calendar.date(byAdding: .year, value: -5, to: latestDate)
        case .all:
            return nil
        }
    }
}

private struct BacktestView: View {
    @ObservedObject var marketStore: RemoteMarketStore
    @State private var cashWeight: Double = BacktestDefaults.cashWeight
    @State private var goldWeight: Double = BacktestDefaults.goldWeight
    @State private var indexWeights: [String: Double] = BacktestDefaults.indexWeights
    @State private var selectedRange: BacktestRange = .all
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

    private var allocationSplitIndex: Int {
        max(1, Int(ceil(Double(allocationSlices.count) / 2)))
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

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                GeometryReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            if report == nil {
                                Spacer(minLength: 0)
                            }

                            VStack(spacing: 20) {
                                Button {
                                    showsAllocationSheet = true
                                } label: {
                                    HStack(alignment: .center, spacing: 18) {
                                        backtestLegendColumn(Array(allocationSlices.prefix(allocationSplitIndex)), alignment: .trailing)

                                        Chart(allocationSlices) { slice in
                                            SectorMark(
                                                angle: .value("占比", slice.amount),
                                                innerRadius: .ratio(0.58),
                                                angularInset: 2
                                            )
                                            .foregroundStyle(slice.color)
                                        }
                                        .frame(width: 176, height: 176)
                                        .chartLegend(.hidden)

                                        backtestLegendColumn(Array(allocationSlices.dropFirst(allocationSplitIndex)), alignment: .leading)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 200)
                                }
                                .buttonStyle(.plain)

                                if !isBacktestLoading {
                                    HStack(spacing: 10) {
                                        BacktestActionChip(title: "重置回测", systemImage: "arrow.counterclockwise") {
                                            resetBacktest()
                                        }

                                        BacktestActionChip(title: "调整时间 · \(selectedRange.label)", systemImage: "calendar") {
                                            showsRangeSheet = true
                                        }

                                        Button {
                                            hasStartedBacktest = true
                                            scheduleBacktestRefresh(animated: true, forceAnimation: true, showLoading: true)
                                        } label: {
                                            Text(report == nil ? "开始回测" : "重新回测")
                                                .font(.subheadline.weight(.bold))
                                                .foregroundStyle(.black)
                                                .frame(maxWidth: .infinity)
                                                .padding(.horizontal, 22)
                                                .padding(.vertical, 12)
                                                .background(AssetTheme.gold, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)

                            if report == nil {
                                Spacer(minLength: 0)
                            }

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
                                        Text(selectedRange.label)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AssetTheme.textSecondary)
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
                        .frame(minHeight: proxy.size.height)
                    }
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
                BacktestRangeSheet(selectedRange: $selectedRange)
                    .presentationDetents([.fraction(0.42)])
                    .presentationDragIndicator(.visible)
            }
        }
        .onAppear {
            if hasStartedBacktest, report == nil {
                scheduleBacktestRefresh(animated: !hasPlayedInitialBacktestAnimation)
            }
        }
        .onChange(of: selectedRange) { _, _ in
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
        selectedRange = .all
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
        guard let series, selectedRange != .all else { return series }
        guard let latestText = series.dates.last,
              let latestDate = BacktestEngine.historicalSeriesDateStatic(from: latestText),
              let startDate = selectedRange.startDate(from: latestDate) else {
            return series
        }

        let filteredPairs = zip(series.dates, series.prices).filter { dateText, _ in
            guard let date = BacktestEngine.historicalSeriesDateStatic(from: dateText) else { return false }
            return date >= startDate
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

    @ViewBuilder
    private func backtestLegendColumn(_ slices: [BacktestAllocationSlice], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 12) {
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    if alignment == .trailing {
                        Text("\(slice.title) \(Int(slice.amount.rounded()))%")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AssetTheme.textPrimary)
                            .multilineTextAlignment(.trailing)
                        Circle()
                            .fill(slice.color)
                            .frame(width: 8, height: 8)
                    } else {
                        Circle()
                            .fill(slice.color)
                            .frame(width: 8, height: 8)
                        Text("\(slice.title) \(Int(slice.amount.rounded()))%")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AssetTheme.textPrimary)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
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
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().stroke(AssetTheme.border.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct BacktestRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedRange: BacktestRange

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(BacktestRange.allCases) { range in
                            Button {
                                selectedRange = range
                                dismiss()
                            } label: {
                                HStack {
                                    Text(range.label)
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(AssetTheme.textPrimary)
                                    Spacer()
                                    if selectedRange == range {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(AssetTheme.gold)
                                    }
                                }
                                .padding(16)
                                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(selectedRange == range ? AssetTheme.gold.opacity(0.75) : AssetTheme.border.opacity(0.7), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("调整时间")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
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
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
            let symbol = code == "USD" ? "$" : "¥"
            return "\(symbol)\(value.compactNumberString())\(suffix)"
        case let .quantity(unit, maxFractionDigits):
            return "\(value.compactNumberString(maxFractionDigits: maxFractionDigits))\(unit)"
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

private struct DashboardAllocationSlice: Identifiable {
    let title: String
    let amount: Double
    let color: Color

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

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("金额", slice.amount),
                        innerRadius: .ratio(0.62),
                        angularInset: 2.5
                    )
                    .cornerRadius(6)
                    .foregroundStyle(slice.color)
                }
                .chartLegend(.hidden)
                .frame(height: 176)

                VStack(spacing: 4) {
                    Text("资产构成")
                        .font(AppTypography.eyebrow)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .padding(.horizontal, 24)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(slices) { slice in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(slice.color)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(slice.title)
                                .font(AppTypography.meta)
                                .foregroundStyle(AssetTheme.textPrimary)
                                .lineLimit(1)

                            Text(percentageText(for: slice))
                                .font(AppTypography.eyebrow)
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func percentageText(for slice: DashboardAllocationSlice) -> String {
        guard totalAmount > 0 else { return "0%" }
        return (slice.amount / totalAmount).formatted(.percent.precision(.fractionLength(0)))
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
                .background(.white.opacity(0.04), in: Capsule())
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
            .frame(height: 256)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(.white.opacity(0.08))
                    AxisTick().foregroundStyle(.white.opacity(0.15))
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(.white.opacity(0.08))
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

            Text(selectedDate == nil ? dateRangeLabel : selectedPoint.date.recordDateString)
                .font(AppTypography.meta)
                .foregroundStyle(AssetTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 8)
    }

    private var dateRangeLabel: String {
        guard let first = points.first?.date else { return "暂无范围" }
        return "\(first.recordDateString) - \(latestPoint.date.recordDateString)"
    }
}

private struct TimeMachineRangePicker: View {
    @Binding var selectedRange: TimeMachineRange

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TimeMachineRange.allCases) { range in
                Button {
                    selectedRange = range
                } label: {
                    Text(range.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(selectedRange == range ? AssetTheme.background : AssetTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedRange == range ? AssetTheme.goldSoft : .white.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AssetTheme.border.opacity(selectedRange == range ? 0 : 0.72), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
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
    @State private var selectedDate: Date?

    private var selectedPoint: TimeMachineTrendPoint {
        guard let selectedDate else { return latestPoint }
        return nearestTrendPoint(to: selectedDate, in: points) ?? latestPoint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("资产走势")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)

                    Spacer()

                    Text(selectedDate == nil ? dateRangeLabel : selectedPoint.date.recordDateString)
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
            .frame(height: 238)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(.white.opacity(0.08))
                    AxisTick().foregroundStyle(.white.opacity(0.15))
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(.white.opacity(0.08))
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
        }
        .atmCardStyle()
    }

    private var dateRangeLabel: String {
        guard let first = points.first?.date, let last = points.last?.date else { return "暂无范围" }
        return "\(first.recordDateString) - \(last.recordDateString)"
    }
}

private func nearestTrendPoint(to date: Date, in points: [TimeMachineTrendPoint]) -> TimeMachineTrendPoint? {
    points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
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
            } else if canShowLeftOnlyChart {
                leftOnlyChart
            } else {
                Text("记录不足")
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
            let leftWidth: CGFloat = descriptor.showsComparisonLine ? 44 : 36
            let rightWidth: CGFloat = descriptor.showsComparisonLine ? 44 : 0
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
                .frame(width: chartWidth, height: 180)
                .clipped()
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
        .frame(height: 180)
    }

    private var leftOnlyChart: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = 36
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
                .frame(width: chartWidth, height: 180)
                .clipped()
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
        .frame(height: 180)
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
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                .foregroundStyle(AssetTheme.border.opacity(0.35))
            AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                .foregroundStyle(AssetTheme.border.opacity(0.7))
            AxisValueLabel(format: .dateTime.month().day())
                .foregroundStyle(AssetTheme.textSecondary)
        }
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
            .background(.white.opacity(0.04), in: Capsule())
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
                            .fill(.white.opacity(0.04))
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
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            .fill(.white.opacity(0.08))
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
        valuationMethod == .directAmount || resolvedAutoPricedAssetKind != nil || autoExchangeRateCurrencyCode != nil
    }

    var compactRecordPlaceholder: String {
        if let currencyCode = autoExchangeRateCurrencyCode {
            return "输入\(currencyCode) 数量"
        }

        if let autoKind = resolvedAutoPricedAssetKind {
            return "输入\(autoKind.defaultName) 数量"
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
}

#Preview {
    ContentView()
        .modelContainer(for: [AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self], inMemory: true)
}
