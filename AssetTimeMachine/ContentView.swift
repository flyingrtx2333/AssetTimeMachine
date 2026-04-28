import SwiftUI
import SwiftData
import Charts

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

            TimeMachineView(marketStore: marketStore)
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
    @AppStorage("dashboard.monthlyExpense") private var monthlyExpense: Double = 3000
    @AppStorage("dashboard.monthlyExpenseSeedVersion") private var monthlyExpenseSeedVersion: Int = 0
    @AppStorage("dashboard.inflationRate") private var inflationRate: Double = 0.05
    @AppStorage("dashboard.inflationRateSeedVersion") private var inflationRateSeedVersion: Int = 0
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]

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

                Text(totalAssets.currencyString())
                    .font(AppTypography.heroValue)
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textPrimary)
                    .minimumScaleFactor(0.72)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    InlineStat(text: "已记录 \(snapshots.count.formatted()) 天", color: AssetTheme.textSecondary)
                    InlineStat(text: latestSnapshot.map { "最近更新 \($0.date.shortDateString)" } ?? "还没有快照", color: AssetTheme.goldSoft)
                }
            }

            HStack(alignment: .top, spacing: 18) {
                SummaryColumnMetric(
                    title: "净资产",
                    value: netAssets.currencyString(),
                    accent: AssetTheme.positive
                )

                SummaryColumnMetric(
                    title: "总负债",
                    value: totalLiabilities.currencyString(),
                    accent: AssetTheme.negative
                )

                SummaryColumnMetric(
                    title: "条目",
                    value: latestEntryCount.formatted(),
                    accent: AssetTheme.accentBlue
                )
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

    private var currentSnapshot: AssetSnapshot? {
        if let currentSnapshotID,
           let snapshot = snapshots.first(where: { $0.id == currentSnapshotID }) {
            return snapshot
        }
        return snapshots.first(where: { Calendar.current.isDateInToday($0.date) }) ?? snapshots.first
    }

    private var visibleCategories: [AssetCategory] {
        categories
            .filter { !$0.activeSortedItems.isEmpty }
            .sorted {
                if $0.group.sortPriority == $1.group.sortPriority {
                    return $0.createdAt < $1.createdAt
                }
                return $0.group.sortPriority < $1.group.sortPriority
            }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        if let currentSnapshot {
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("主资产")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AssetTheme.textSecondary)

                                    Text(PortfolioCalculator.totalAssets(for: currentSnapshot).currencyString())
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                        .foregroundStyle(AssetTheme.goldSoft)
                                        .minimumScaleFactor(0.58)
                                        .lineLimit(1)

                                    Text(currentSnapshot.date.recordDateString)
                                        .font(.subheadline.weight(.semibold))
                                        .tracking(0.3)
                                        .foregroundStyle(AssetTheme.gold.opacity(0.72))
                                        .padding(.top, 2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .layoutPriority(1)

                                VStack(alignment: .leading, spacing: 12) {
                                    SummaryColumnMetric(
                                        title: "负债",
                                        value: PortfolioCalculator.totalLiabilities(for: currentSnapshot).currencyString(),
                                        accent: AssetTheme.negative
                                    )
                                    SummaryColumnMetric(
                                        title: "净资产",
                                        value: PortfolioCalculator.netAssets(for: currentSnapshot).currencyString(),
                                        accent: AssetTheme.gold
                                    )
                                }
                                .frame(width: 128, alignment: .leading)
                            }

                            ForEach(visibleCategories) { category in
                                RecordCategoryCard(
                                    category: category,
                                    amountInputs: $amountInputs,
                                    quantityInputs: $quantityInputs,
                                    unitPriceInputs: $unitPriceInputs,
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
                    .padding(.horizontal, 14)
                    .padding(.top, 28)
                    .padding(.bottom, 120)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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
            guard let item = entry.item,
                  let currencyCode = item.autoExchangeRateCurrencyCode,
                  let rate = marketStore.exchangeRate(for: currencyCode) else {
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
                let autoRate = item.autoExchangeRateCurrencyCode.flatMap { marketStore.exchangeRate(for: $0) }
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

private struct RecordCategoryCard: View {
    let category: AssetCategory
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    @Binding var unitPriceInputs: [UUID: String]
    let onChanged: (AssetItem) -> Void

    private var items: [AssetItem] {
        category.activeSortedItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(category.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Spacer()
                Text("\(items.count) 项")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            Rectangle()
                .fill(AssetTheme.border.opacity(0.55))
                .frame(height: 1)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
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
                        )
                    )

                    if index < items.count - 1 {
                        Rectangle()
                            .fill(AssetTheme.border.opacity(0.32))
                            .frame(height: 1)
                            .padding(.leading, 2)
                    }
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

    private let labelWidth: CGFloat = 116

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(item.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)
                .lineLimit(2)
                .frame(width: labelWidth, alignment: .leading)

            if item.valuationMethod == .directAmount {
                ATMInputField(text: $amountText, placeholder: "0")
            } else if let currencyCode = item.autoExchangeRateCurrencyCode {
                ATMInputField(text: $quantityText, placeholder: currencyCode)
            } else {
                HStack(spacing: 8) {
                    ATMInputField(text: $quantityText, placeholder: "数量", width: 82)
                    ATMInputField(text: $unitPriceText, placeholder: "单价")
                }
            }
        }
        .padding(.vertical, 12)
    }
}

private struct ATMInputField: View {
    @Binding var text: String
    let placeholder: String
    var width: CGFloat? = nil

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(AssetTheme.textSecondary))
            .keyboardType(.decimalPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 14)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .trailing)
            .frame(width: width, height: 44)
            .background(AssetTheme.background.opacity(0.66), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.52), lineWidth: 1)
            )
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
                    ATMHeader(title: "全部记录")

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
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct SnapshotDetailView: View {
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
                    ATMHeader(title: snapshot.date.longDateString)

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
    @Query(sort: \AssetSnapshot.date, order: .forward) private var snapshots: [AssetSnapshot]
    @State private var selectedRange: TimeMachineRange = .oneYear

    private var trendPoints: [TimeMachineTrendPoint] {
        snapshots.map { snapshot in
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
    }

    private var filteredTrendPoints: [TimeMachineTrendPoint] {
        selectedRange.filter(trendPoints)
    }

    private var latestPoint: TimeMachineTrendPoint? {
        filteredTrendPoints.last ?? trendPoints.last
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
        [
            TimeMachineCombinedTrendDescriptor(
                title: "黄金",
                subtitle: "用你的总资产回看黄金购买力",
                leftTitle: "价格",
                rightTitle: "折算",
                points: pairedPoints(for: filteredTrendPoints, range: selectedRange, left: \.goldAnchorPriceCNY, right: \.goldEquivalent),
                leftColor: AssetTheme.gold,
                rightColor: AssetTheme.positive,
                leftLatestLabel: latestPoint?.goldAnchorPriceCNY.map { "\($0.currencyString())/g" } ?? "--",
                rightLatestLabel: latestPoint?.goldEquivalent.map { "\($0.plainNumberString()) g" } ?? "--",
                leftAxisStyle: .currency(code: "CNY"),
                rightAxisStyle: .quantity(unit: "g", maxFractionDigits: 2),
                showsComparisonLine: true
            ),
            TimeMachineCombinedTrendDescriptor(
                title: "纳指",
                subtitle: "当前按 QQQ 代理纳指锚点",
                leftTitle: "价格",
                rightTitle: "折算",
                points: pairedPoints(for: filteredTrendPoints, range: selectedRange, left: \.nasdaqAnchorPriceUSD, right: \.nasdaqEquivalent),
                leftColor: AssetTheme.accentBlue,
                rightColor: AssetTheme.positive,
                leftLatestLabel: latestPoint?.nasdaqAnchorPriceUSD.map { $0.currencyString(code: "USD") } ?? "--",
                rightLatestLabel: latestPoint?.nasdaqEquivalent.map { "\($0.plainNumberString()) 份" } ?? "--",
                leftAxisStyle: .currency(code: "USD"),
                rightAxisStyle: .quantity(unit: "份", maxFractionDigits: 2),
                showsComparisonLine: true
            ),
            TimeMachineCombinedTrendDescriptor(
                title: "BTC",
                subtitle: "看波动，也看你的资产能换多少 BTC",
                leftTitle: "价格",
                rightTitle: "折算",
                points: pairedPoints(for: filteredTrendPoints, range: selectedRange, left: \.btcAnchorPriceUSD, right: \.btcEquivalent),
                leftColor: AssetTheme.accentOrange,
                rightColor: AssetTheme.positive,
                leftLatestLabel: latestPoint?.btcAnchorPriceUSD.map { $0.currencyString(code: "USD") } ?? "--",
                rightLatestLabel: latestPoint?.btcEquivalent.map { "\($0.plainNumberString()) BTC" } ?? "--",
                leftAxisStyle: .currency(code: "USD"),
                rightAxisStyle: .quantity(unit: "BTC", maxFractionDigits: 4),
                showsComparisonLine: true
            ),
        ] + publicIndexTrendCards
    }

    private var publicIndexTrendCards: [TimeMachineCombinedTrendDescriptor] {
        let configs: [(symbol: String, title: String, color: Color)] = [
            ("sp500", "标普500", AssetTheme.goldSoft),
            ("dowjones", "道指", AssetTheme.accentOrange),
            ("hsi", "恒生", AssetTheme.accentBlue),
            ("nikkei", "日经225", AssetTheme.positive),
            ("csi300", "沪深300", AssetTheme.textPrimary),
            ("shanghai_composite", "上证综指", AssetTheme.textSecondary)
        ]

        return configs.compactMap { config in
            guard let series = marketStore.history(for: config.symbol) else { return nil }
            let points = historySeriesPoints(series)
            guard points.count >= 2 else { return nil }
            let latest = points.last
            return TimeMachineCombinedTrendDescriptor(
                title: config.title,
                subtitle: "先看指数趋势，后面再决定要不要接购买力折算",
                leftTitle: "指数",
                rightTitle: "趋势镜像",
                points: points,
                leftColor: config.color,
                rightColor: config.color.opacity(0.45),
                leftLatestLabel: latest.map { $0.leftValue.currencyString(code: series.currency) } ?? "--",
                rightLatestLabel: latest.map { $0.rightValue.plainNumberString() } ?? "--",
                leftAxisStyle: .currency(code: series.currency),
                rightAxisStyle: .quantity(unit: "", maxFractionDigits: 2),
                showsComparisonLine: false
            )
        }
    }

    private func historySeriesPoints(_ series: PublicHistorySeries) -> [TimeMachineDualAxisPoint] {
        zip(series.dates, series.prices).compactMap { dateText, price in
            guard let date = historicalSeriesDate(from: dateText), price.isFinite, price > 0 else { return nil }
            return TimeMachineDualAxisPoint(date: date, leftValue: price, rightValue: price)
        }
    }

    private func historicalSeriesDate(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

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

                            VStack(spacing: 12) {
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
    let annualizedVolatility: Double?
    let sharpeRatio: Double?
}

private enum BacktestEngine {
    static func run(cashWeight: Double, goldWeight: Double, indexWeight: Double, goldSeries: PublicHistorySeries?, indexSeries: PublicHistorySeries?) -> BacktestReport? {
        let normalizedCash = max(cashWeight, 0)
        let normalizedGold = max(goldWeight, 0)
        let normalizedIndex = max(indexWeight, 0)
        let totalWeight = normalizedCash + normalizedGold + normalizedIndex
        guard totalWeight > 0 else { return nil }

        let cw = normalizedCash / totalWeight
        let gw = normalizedGold / totalWeight
        let iw = normalizedIndex / totalWeight

        if gw > 0, goldSeries == nil { return nil }
        if iw > 0, indexSeries == nil { return nil }

        let goldMap = goldSeries.map { Dictionary(uniqueKeysWithValues: zip($0.dates, $0.prices)) } ?? [:]
        let indexMap = indexSeries.map { Dictionary(uniqueKeysWithValues: zip($0.dates, $0.prices)) } ?? [:]

        let sharedDates: [String]
        if gw > 0, iw > 0 {
            sharedDates = Array(Set(goldMap.keys).intersection(indexMap.keys)).sorted()
        } else if gw > 0 {
            sharedDates = goldMap.keys.sorted()
        } else if iw > 0 {
            sharedDates = indexMap.keys.sorted()
        } else if !goldMap.isEmpty {
            sharedDates = goldMap.keys.sorted()
        } else {
            sharedDates = indexMap.keys.sorted()
        }
        guard sharedDates.count >= 2 else { return nil }

        let firstGold = gw > 0 ? goldMap[sharedDates[0]] : 1
        let firstIndex = iw > 0 ? indexMap[sharedDates[0]] : 1
        if gw > 0, firstGold == nil || firstGold ?? 0 <= 0 { return nil }
        if iw > 0, firstIndex == nil || firstIndex ?? 0 <= 0 { return nil }

        var points: [BacktestSeriesPoint] = []
        var returns: [Double] = []
        var previousValue: Double?
        var peakValue: Double = 1
        var maxDrawdown: Double = 0

        for dateText in sharedDates {
            guard let date = historicalSeriesDateStatic(from: dateText) else { continue }

            let goldComponent: Double
            if gw > 0 {
                guard let goldPrice = goldMap[dateText], let firstGold, firstGold > 0 else { continue }
                goldComponent = gw * (goldPrice / firstGold)
            } else {
                goldComponent = 0
            }

            let indexComponent: Double
            if iw > 0 {
                guard let indexPrice = indexMap[dateText], let firstIndex, firstIndex > 0 else { continue }
                indexComponent = iw * (indexPrice / firstIndex)
            } else {
                indexComponent = 0
            }

            let portfolioValue = cw + goldComponent + indexComponent
            points.append(.init(date: date, portfolioValue: portfolioValue))

            if let previousValue, previousValue > 0 {
                returns.append((portfolioValue / previousValue) - 1)
            }
            previousValue = portfolioValue
            peakValue = max(peakValue, portfolioValue)
            if peakValue > 0 {
                maxDrawdown = max(maxDrawdown, (peakValue - portfolioValue) / peakValue)
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

        return BacktestReport(
            points: points,
            totalReturn: totalReturn,
            annualizedReturn: annualizedReturn,
            maxDrawdown: maxDrawdown,
            annualizedVolatility: annualizedVolatility,
            sharpeRatio: sharpeRatio
        )
    }

    private static func historicalSeriesDateStatic(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
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
    @State private var cashWeight: Double = 100
    @State private var goldWeight: Double = 0
    @State private var indexWeight: Double = 0
    @State private var selectedIndexSymbol: String = "sp500"
    @State private var animationProgress: Double = 0
    @State private var showsAllocationSheet = false
    @State private var hasStartedBacktest = ProcessInfo.processInfo.arguments.contains("-autoStartBacktest")

    private let indexOptions: [(symbol: String, title: String)] = [
        ("sp500", "标普500"),
        ("nasdaq", "纳指"),
        ("dowjones", "道指"),
        ("hsi", "恒生"),
        ("nikkei", "日经225"),
        ("csi300", "沪深300"),
        ("shanghai_composite", "上证综指")
    ]

    private var report: BacktestReport? {
        guard hasStartedBacktest else { return nil }
        return BacktestEngine.run(
            cashWeight: cashWeight,
            goldWeight: goldWeight,
            indexWeight: indexWeight,
            goldSeries: marketStore.history(for: "gold_cny"),
            indexSeries: marketStore.history(for: selectedIndexSymbol)
        )
    }

    private var animatedPoints: [BacktestSeriesPoint] {
        guard let report else { return [] }
        let count = max(Int(Double(report.points.count) * animationProgress), min(report.points.count, 2))
        return Array(report.points.prefix(count))
    }

    private var allocationSlices: [BacktestAllocationSlice] {
        [
            BacktestAllocationSlice(title: "现金", amount: cashWeight, color: AssetTheme.textSecondary),
            BacktestAllocationSlice(title: "黄金", amount: goldWeight, color: AssetTheme.gold),
            BacktestAllocationSlice(title: indexOptions.first(where: { $0.symbol == selectedIndexSymbol })?.title ?? "指数", amount: indexWeight, color: AssetTheme.accentBlue)
        ].filter { $0.amount > 0 }
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
                                        backtestLegendColumn(Array(allocationSlices.prefix(2)), alignment: .trailing)

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

                                        backtestLegendColumn(Array(allocationSlices.dropFirst(2)), alignment: .leading)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 200)
                                }
                                .buttonStyle(.plain)

                                if report == nil {
                                    Button {
                                        hasStartedBacktest = true
                                        restartAnimation()
                                    } label: {
                                        Text("开始回测")
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 22)
                                            .padding(.vertical, 12)
                                            .background(AssetTheme.gold, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(maxWidth: .infinity)

                            if report == nil {
                                Spacer(minLength: 0)
                            }

                            if let report {
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack {
                                        Text("组合净值")
                                            .font(.headline.weight(.bold))
                                            .foregroundStyle(AssetTheme.textPrimary)
                                        Spacer()
                                        Text(indexOptions.first(where: { $0.symbol == selectedIndexSymbol })?.title ?? selectedIndexSymbol)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AssetTheme.goldSoft)
                                    }

                                    Chart(animatedPoints) { point in
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
                                .atmCardStyle()
                                .onAppear { restartAnimation() }
                                .onChange(of: selectedIndexSymbol) { _, _ in restartAnimation() }
                                .onChange(of: cashWeight) { _, _ in restartAnimation() }
                                .onChange(of: goldWeight) { _, _ in restartAnimation() }
                                .onChange(of: indexWeight) { _, _ in restartAnimation() }

                                VStack(alignment: .leading, spacing: 12) {
                                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                        BacktestMetricCard(title: "总收益", value: report.totalReturn.percentString())
                                        BacktestMetricCard(title: "年化收益", value: report.annualizedReturn?.percentString() ?? "--")
                                        BacktestMetricCard(title: "最大回撤", value: report.maxDrawdown.percentString(), accent: AssetTheme.negative)
                                        BacktestMetricCard(title: "年化波动", value: report.annualizedVolatility?.percentString() ?? "--")
                                        BacktestMetricCard(title: "夏普比率", value: report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                                        BacktestMetricCard(title: "区间", value: intervalLabel(for: report))
                                    }
                                }
                                .atmCardStyle()
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
                    cashWeight: $cashWeight,
                    goldWeight: $goldWeight,
                    indexWeight: $indexWeight,
                    selectedIndexSymbol: $selectedIndexSymbol,
                    indexOptions: indexOptions
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
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

private struct BacktestAllocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var cashWeight: Double
    @Binding var goldWeight: Double
    @Binding var indexWeight: Double
    @Binding var selectedIndexSymbol: String
    let indexOptions: [(symbol: String, title: String)]

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        BacktestWeightRow(title: "现金", value: $cashWeight)
                        BacktestWeightRow(title: "黄金", value: $goldWeight)
                        BacktestWeightRow(title: "指数", value: $indexWeight)

                        Picker("指数", selection: $selectedIndexSymbol) {
                            ForEach(indexOptions, id: \.symbol) { option in
                                Text(option.title).tag(option.symbol)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("重置") {
                        cashWeight = 100
                        goldWeight = 0
                        indexWeight = 0
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
                        dismiss()
                    }
                    .tint(AssetTheme.gold)
                }
            }
        }
    }

    private func normalizeWeights() {
        let total = max(cashWeight + goldWeight + indexWeight, 0)
        guard total > 0 else {
            cashWeight = 100
            goldWeight = 0
            indexWeight = 0
            return
        }
        cashWeight = (cashWeight / total) * 100
        goldWeight = (goldWeight / total) * 100
        indexWeight = 100 - cashWeight - goldWeight
    }
}

private struct BacktestWeightRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Spacer()
                Text("\(Int(value.rounded()))%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AssetTheme.goldSoft)
            }

            Slider(value: $value, in: 0...100, step: 1)
                .tint(AssetTheme.gold)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(accent)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
        )
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

    func filter(_ points: [TimeMachineTrendPoint], calendar: Calendar = .current) -> [TimeMachineTrendPoint] {
        guard let latestDate = points.last?.date else { return [] }

        let startDate: Date?
        switch self {
        case .sixMonths:
            startDate = calendar.date(byAdding: .month, value: -6, to: latestDate)
        case .oneYear:
            startDate = calendar.date(byAdding: .year, value: -1, to: latestDate)
        case .all:
            startDate = nil
        }

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
        guard let projection else { return "还不能估算" }

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
                        x: .value("日期", latestPoint.date),
                        y: .value(series.title, series.value(from: latestPoint))
                    )
                    .foregroundStyle(series.color)
                    .symbolSize(44)
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
            .padding(.top, 2)

            Text(dateRangeLabel)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("资产走势")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)

                    Spacer()

                    Text(dateRangeLabel)
                        .font(.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(1)
                }

                Text(latestPoint.mainAssets.currencyString())
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
                        value: latestPoint.netAssets.currencyString(),
                        accent: AssetTheme.textPrimary
                    )
                    TimeMachineInlineMetric(
                        title: "负债",
                        value: latestPoint.liabilities.currencyString(),
                        accent: AssetTheme.negative
                    )
                    TimeMachineInlineMetric(
                        title: "BTC 折算",
                        value: latestPoint.btcEquivalent?.plainNumberString() ?? "--",
                        accent: AssetTheme.accentOrange
                    )
                    TimeMachineInlineMetric(
                        title: "纳指折算",
                        value: latestPoint.nasdaqEquivalent?.plainNumberString() ?? "--",
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

                    if let lastPoint = points.last {
                        PointMark(
                            x: .value("日期", lastPoint.date),
                            y: .value(series.title, series.value(from: lastPoint))
                        )
                        .foregroundStyle(series.color)
                        .symbolSize(46)
                    }
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
        }
        .atmCardStyle()
    }

    private var dateRangeLabel: String {
        guard let first = points.first?.date, let last = points.last?.date else { return "暂无范围" }
        return "\(first.recordDateString) - \(last.recordDateString)"
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

    private var latestPoint: TimeMachineDualAxisPoint? {
        descriptor.points.last
    }

    private var leftDomain: ClosedRange<Double> {
        paddedDomain(values: descriptor.points.map(\.leftValue))
    }

    private var rightDomain: ClosedRange<Double> {
        paddedDomain(values: descriptor.points.map(\.rightValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if descriptor.points.count >= 2 {
                dualAxisChart
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
                    value: descriptor.leftLatestLabel,
                    color: descriptor.leftColor,
                    dashed: false
                )
                if descriptor.showsComparisonLine {
                    TimeMachineLegendMetric(
                        title: descriptor.rightTitle,
                        value: descriptor.rightLatestLabel,
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
                }
                .frame(width: chartWidth, height: 180)
                .clipped()
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis { bottomAxisMarks }
                .chartLegend(.hidden)

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

    @ChartContentBuilder
    private var leftSeriesMarks: some ChartContent {
        ForEach(descriptor.points) { point in
            LineMark(
                x: .value("日期", point.date),
                y: .value(descriptor.leftTitle, point.leftValue)
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
                y: .value(descriptor.rightTitle, normalized(point.rightValue, in: rightDomain))
            )
            .foregroundStyle(descriptor.rightColor)
            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [6, 5]))
            .interpolationMethod(.linear)
        }
    }

    @ChartContentBuilder
    private var latestPointMarksNormalized: some ChartContent {
        if let latestPoint {
            PointMark(
                x: .value("日期", latestPoint.date),
                y: .value(descriptor.leftTitle, normalized(latestPoint.leftValue, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(42)

            if descriptor.showsComparisonLine {
                PointMark(
                    x: .value("日期", latestPoint.date),
                    y: .value(descriptor.rightTitle, normalized(latestPoint.rightValue, in: rightDomain))
                )
                .foregroundStyle(descriptor.rightColor)
                .symbolSize(36)
            }
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

    private func axisTickValues(for domain: ClosedRange<Double>) -> [Double] {
        let step = (domain.upperBound - domain.lowerBound) / 2
        guard step.isFinite, step > 0 else { return [domain.lowerBound] }
        return [domain.lowerBound, domain.lowerBound + step, domain.upperBound]
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
        case "btc": return "BTC"
        case "nasdaq": return "纳指锚点"
        default: return market.symbol.uppercased()
        }
    }

    private var color: Color {
        switch market.symbol {
        case "gold": return AssetTheme.gold
        case "btc": return AssetTheme.accentOrange
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
    var autoExchangeRateCurrencyCode: String? {
        guard valuationMethod == .quantityAndUnitPrice else { return nil }
        let uppercasedName = name.uppercased()
        for currencyCode in ["USD", "EUR", "GBP", "JPY", "HKD", "SGD", "AUD", "CAD", "KRW"] {
            if uppercasedName.hasSuffix(" \(currencyCode)") || uppercasedName == currencyCode {
                return currencyCode
            }
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
