import SwiftUI
import SwiftData
import Charts

private enum AppTab: Hashable {
    case dashboard
    case snapshots
    case timeMachine
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
        return .dashboard
    }()
    @State private var didRunStartup = false

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(marketStore: marketStore)
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
    @ObservedObject var marketStore: RemoteMarketStore
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @Query private var entries: [AssetEntry]

    private var latestSnapshot: AssetSnapshot? { snapshots.first }

    private var totalAssets: Double {
        entries
            .filter { ($0.item?.category?.group ?? .financial) != .liability }
            .reduce(0) { $0 + $1.resolvedAmount }
    }

    private var totalLiabilities: Double {
        entries
            .filter { ($0.item?.category?.group ?? .financial) == .liability }
            .reduce(0) { $0 + $1.resolvedAmount }
    }

    private var netAssets: Double {
        totalAssets - totalLiabilities
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        ATMHeader(title: "资产时光机") {
                            Button {
                                Task { await marketStore.refresh() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(AssetTheme.gold)
                                    .frame(width: 44, height: 44)
                                    .background(.white.opacity(0.04), in: Circle())
                                    .overlay(Circle().stroke(AssetTheme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        heroCard

                        HStack(spacing: 12) {
                            MetricTile(
                                title: "总资产",
                                value: totalAssets.currencyString(),
                                accent: AssetTheme.gold
                            )

                            MetricTile(
                                title: "总负债",
                                value: totalLiabilities.currencyString(),
                                accent: AssetTheme.negative
                            )
                        }

                        marketSection
                        recentSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    GoldChip(text: "净资产（元）")

                    Text(netAssets.currencyString())
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(AssetTheme.textPrimary)

                    HStack(spacing: 10) {
                        InlineStat(text: "记录天数 \(snapshots.count)", color: AssetTheme.textSecondary)
                        InlineStat(text: latestSnapshot.map { "最近 \($0.date.shortDateString)" } ?? "还没有快照", color: AssetTheme.goldSoft)
                    }
                }

                Spacer(minLength: 16)

                SparklineCard(points: [0.14, 0.18, 0.22, 0.21, 0.28, 0.32, 0.30, 0.38, 0.43])
                    .frame(width: 132, height: 84)
            }

            Divider().overlay(AssetTheme.border)

            HStack(spacing: 12) {
                CompactStat(title: "资产", value: totalAssets.currencyString(), accent: AssetTheme.gold)
                CompactStat(title: "负债", value: totalLiabilities.currencyString(), accent: AssetTheme.negative)
                CompactStat(title: "条目", value: "\(entries.count)", accent: AssetTheme.accentBlue)
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(AssetTheme.heroGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AssetTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 16)
    }

    private var marketSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "市场锚点")

            Group {
                if let overview = marketStore.overview {
                    VStack(spacing: 0) {
                        ForEach(Array(overview.markets.enumerated()), id: \.element.id) { index, market in
                            MarketPriceRow(market: market)

                            if index < overview.markets.count - 1 {
                                Divider().overlay(AssetTheme.border.opacity(0.6))
                            }
                        }

                    }
                    .atmCardStyle()
                } else if marketStore.isLoading {
                    VStack(spacing: 14) {
                        SkeletonLine(width: 130)
                        SkeletonLine(width: 240)
                        SkeletonLine(width: 210)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .atmCardStyle()
                } else {
                    EmptyStateCard(
                        title: marketStore.errorMessage ?? "行情暂不可用",
                        systemImage: "wifi.exclamationmark"
                    )
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "最近记录")

            if let latestSnapshot {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(latestSnapshot.date.longDateString)
                            .font(.headline)
                            .foregroundStyle(AssetTheme.textPrimary)
                        Spacer()
                        GoldChip(text: "\(latestSnapshot.entries.count) 项")
                    }

                    Text("\(latestSnapshot.entries.count) 项")
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .atmCardStyle()
            } else {
                EmptyStateCard(
                    title: "暂无记录",
                    systemImage: "tray"
                )
            }
        }
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
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
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
                leftTitle: "价格",
                rightTitle: "折算",
                points: pairedPoints(for: filteredTrendPoints, left: \.goldAnchorPriceCNY, right: \.goldEquivalent),
                leftColor: AssetTheme.gold,
                rightColor: AssetTheme.positive,
                leftLatestLabel: latestPoint?.goldAnchorPriceCNY.map { "\($0.currencyString())/g" } ?? "--",
                rightLatestLabel: latestPoint?.goldEquivalent.map { "\($0.plainNumberString()) g" } ?? "--",
                leftAxisStyle: .currency(code: "CNY"),
                rightAxisStyle: .quantity(unit: "g", maxFractionDigits: 2)
            ),
            TimeMachineCombinedTrendDescriptor(
                title: "纳指",
                leftTitle: "价格",
                rightTitle: "折算",
                points: pairedPoints(for: filteredTrendPoints, left: \.nasdaqAnchorPriceUSD, right: \.nasdaqEquivalent),
                leftColor: AssetTheme.accentBlue,
                rightColor: AssetTheme.positive,
                leftLatestLabel: latestPoint?.nasdaqAnchorPriceUSD.map { $0.currencyString(code: "USD") } ?? "--",
                rightLatestLabel: latestPoint?.nasdaqEquivalent.map { "\($0.plainNumberString()) 份" } ?? "--",
                leftAxisStyle: .currency(code: "USD"),
                rightAxisStyle: .quantity(unit: "份", maxFractionDigits: 2)
            ),
            TimeMachineCombinedTrendDescriptor(
                title: "BTC",
                leftTitle: "价格",
                rightTitle: "折算",
                points: pairedPoints(for: filteredTrendPoints, left: \.btcAnchorPriceUSD, right: \.btcEquivalent),
                leftColor: AssetTheme.accentOrange,
                rightColor: AssetTheme.positive,
                leftLatestLabel: latestPoint?.btcAnchorPriceUSD.map { $0.currencyString(code: "USD") } ?? "--",
                rightLatestLabel: latestPoint?.btcEquivalent.map { "\($0.plainNumberString()) BTC" } ?? "--",
                leftAxisStyle: .currency(code: "USD"),
                rightAxisStyle: .quantity(unit: "BTC", maxFractionDigits: 4)
            ),
        ]
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
        left leftKeyPath: KeyPath<TimeMachineTrendPoint, Double?>,
        right rightKeyPath: KeyPath<TimeMachineTrendPoint, Double?>
    ) -> [TimeMachineDualAxisPoint] {
        source.compactMap { point in
            guard let leftValue = point[keyPath: leftKeyPath],
                  let rightValue = point[keyPath: rightKeyPath] else {
                return nil
            }
            return TimeMachineDualAxisPoint(date: point.date, leftValue: leftValue, rightValue: rightValue)
        }
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
    let leftTitle: String
    let rightTitle: String
    let points: [TimeMachineDualAxisPoint]
    let leftColor: Color
    let rightColor: Color
    let leftLatestLabel: String
    let rightLatestLabel: String
    let leftAxisStyle: TimeMachineAxisValueStyle
    let rightAxisStyle: TimeMachineAxisValueStyle

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
        case .mainAssets: return "主资产"
        case .netAssets: return "净资产"
        case .liabilities: return "负债"
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

    private var leftRange: ClosedRange<Double> {
        paddedRange(for: descriptor.points.map(\.leftValue))
    }

    private var rightRange: ClosedRange<Double> {
        paddedRange(for: descriptor.points.map(\.rightValue))
    }

    private var normalizedPoints: [TimeMachineDualAxisNormalizedPoint] {
        descriptor.points.map { point in
            .init(
                date: point.date,
                leftNormalized: normalize(point.leftValue, in: leftRange),
                rightNormalized: normalize(point.rightValue, in: rightRange)
            )
        }
    }

    private var latestNormalizedPoint: TimeMachineDualAxisNormalizedPoint? {
        normalizedPoints.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(descriptor.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    TimeMachineLegendMetric(
                        title: descriptor.leftTitle,
                        value: descriptor.leftLatestLabel,
                        color: descriptor.leftColor,
                        dashed: false
                    )
                    TimeMachineLegendMetric(
                        title: descriptor.rightTitle,
                        value: descriptor.rightLatestLabel,
                        color: descriptor.rightColor,
                        dashed: true
                    )
                }
            }

            if normalizedPoints.count >= 2 {
                HStack(spacing: 10) {
                    TimeMachineAxisStrip(
                        topLabel: descriptor.leftAxisStyle.compactLabel(for: leftRange.upperBound),
                        middleLabel: descriptor.leftAxisStyle.compactLabel(for: (leftRange.upperBound + leftRange.lowerBound) / 2),
                        bottomLabel: descriptor.leftAxisStyle.compactLabel(for: leftRange.lowerBound),
                        alignment: .leading,
                        color: descriptor.leftColor
                    )

                    Chart(normalizedPoints) { point in
                        LineMark(
                            x: .value("日期", point.date),
                            y: .value("价格", point.leftNormalized)
                        )
                        .foregroundStyle(descriptor.leftColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)

                        LineMark(
                            x: .value("日期", point.date),
                            y: .value("折算", point.rightNormalized)
                        )
                        .foregroundStyle(descriptor.rightColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round, dash: [8, 5]))
                        .interpolationMethod(.linear)

                        if let latest = latestNormalizedPoint,
                           latest.date == point.date {
                            PointMark(
                                x: .value("日期", latest.date),
                                y: .value("价格", latest.leftNormalized)
                            )
                            .foregroundStyle(descriptor.leftColor)
                            .symbolSize(42)

                            PointMark(
                                x: .value("日期", latest.date),
                                y: .value("折算", latest.rightNormalized)
                            )
                            .foregroundStyle(descriptor.rightColor)
                            .symbolSize(38)
                        }
                    }
                    .frame(height: 164)
                    .chartYScale(domain: 0 ... 1)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                                .foregroundStyle(.white.opacity(0.06))
                            AxisTick().foregroundStyle(.white.opacity(0.12))
                            AxisValueLabel(format: .dateTime.month(.defaultDigits), centered: true)
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: [0, 0.5, 1.0]) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                                .foregroundStyle(.white.opacity(0.05))
                            AxisTick().foregroundStyle(.clear)
                            AxisValueLabel("")
                        }
                    }
                    .chartLegend(.hidden)

                    TimeMachineAxisStrip(
                        topLabel: descriptor.rightAxisStyle.compactLabel(for: rightRange.upperBound),
                        middleLabel: descriptor.rightAxisStyle.compactLabel(for: (rightRange.upperBound + rightRange.lowerBound) / 2),
                        bottomLabel: descriptor.rightAxisStyle.compactLabel(for: rightRange.lowerBound),
                        alignment: .trailing,
                        color: descriptor.rightColor
                    )
                }
            } else {
                Text("记录不足")
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            }
        }
        .atmCardStyle()
    }

    private func paddedRange(for values: [Double]) -> ClosedRange<Double> {
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        if abs(maxValue - minValue) < 0.0001 {
            return (minValue - 1) ... (maxValue + 1)
        }
        let padding = (maxValue - minValue) * 0.08
        return (minValue - padding) ... (maxValue + padding)
    }

    private func normalize(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        return (value - range.lowerBound) / span
    }
}

private struct TimeMachineDualAxisNormalizedPoint: Identifiable {
    let date: Date
    let leftNormalized: Double
    let rightNormalized: Double

    var id: Date { date }
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
                .font(.title3.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AssetTheme.textSecondary)
            }
        }
    }
}

private struct GoldChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
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
                .font(.footnote)
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
                .font(.caption)
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)
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

private struct MetricTile: View {
    let title: String
    let value: String
    let detail: String?
    let accent: Color

    init(title: String, value: String, detail: String? = nil, accent: Color) {
        self.title = title
        self.value = value
        self.detail = detail
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)
                .minimumScaleFactor(0.72)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .atmCardStyle()
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
                .font(.title3.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(market.price.formatted(.number.precision(.fractionLength(2))))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Text(market.currency)
                    .font(.subheadline.weight(.semibold))
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

private struct SparklineCard: View {
    let points: [CGFloat]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(AssetTheme.border.opacity(0.8), lineWidth: 1)
                )

            ChartLine(points: points)
                .stroke(AssetTheme.goldSoft, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .padding(14)

            ChartLine(points: points)
                .fill(
                    LinearGradient(
                        colors: [AssetTheme.gold.opacity(0.24), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .padding(14)
                .mask(
                    VStack(spacing: 0) {
                        Spacer()
                        Rectangle().frame(height: 40)
                    }
                )
        }
    }
}

private struct ChartLine: Shape {
    let points: [CGFloat]

    func path(in rect: CGRect) -> Path {
        guard points.count > 1 else { return Path() }

        let stepX = rect.width / CGFloat(points.count - 1)
        let minY = points.min() ?? 0
        let maxY = points.max() ?? 1
        let range = max(maxY - minY, 0.001)

        var path = Path()
        for (index, point) in points.enumerated() {
            let x = CGFloat(index) * stepX
            let normalizedY = (point - minY) / range
            let y = rect.height - normalizedY * rect.height

            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
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
        formatted(date: .abbreviated, time: .omitted)
    }

    var longDateString: String {
        formatted(date: .long, time: .omitted)
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
