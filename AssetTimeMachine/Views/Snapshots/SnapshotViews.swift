import SwiftUI
import SwiftData
import Charts
import UIKit

import UniformTypeIdentifiers

struct SnapshotListView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var marketStore: RemoteMarketStore
    let isActive: Bool
    let onboardingActiveAnchorID: OnboardingAnchorID?
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @Query private var categories: [AssetCategory]

    @State private var currentSnapshotID: UUID?
    @State private var amountInputs: [UUID: String] = [:]
    @State private var quantityInputs: [UUID: String] = [:]
    @State private var unitPriceInputs: [UUID: String] = [:]
    @State private var didPrepare = false
    @State private var isPreparingInitialSnapshot = false
    @State private var showsAddAssetItemSheet = false
    @State private var editingAssetItem: AssetItem?
    @State private var quickEditingAssetItem: AssetItem?
    @State private var focusedField: RecordInputField?
    @State private var pendingAutoRateSyncTask: Task<Void, Never>?

    private let liabilitySectionTitleMap: [String: String] = [
        AppLocalization.string("长期负债"): AppLocalization.string("长期负债"),
        AppLocalization.string("短期负债"): AppLocalization.string("短期负债")
    ]

    private var currentSnapshot: AssetSnapshot? {
        if let currentSnapshotID,
           let snapshot = snapshots.first(where: { $0.id == currentSnapshotID }) {
            return snapshot
        }
        return snapshots.first(where: { Calendar.current.isDateInToday($0.date) }) ?? snapshots.first
    }

    private var categoryItemGroups: (nonLiability: [SnapshotCategoryItems], liability: [SnapshotCategoryItems]) {
        let activeCategoryItems = categories.compactMap { category -> SnapshotCategoryItems? in
            let items = category.activeSortedItems
            guard !items.isEmpty else { return nil }
            return SnapshotCategoryItems(category: category, items: items)
        }

        let nonLiability = activeCategoryItems
            .filter { $0.category.group != .liability }
            .sorted {
                if $0.category.group.sortPriority == $1.category.group.sortPriority {
                    return $0.category.createdAt < $1.category.createdAt
                }
                return $0.category.group.sortPriority < $1.category.group.sortPriority
            }

        let liability = activeCategoryItems
            .filter { $0.category.group == .liability }
            .sorted {
                let lhsPriority = $0.category.liabilitySortPriority(titleMap: liabilitySectionTitleMap)
                let rhsPriority = $1.category.liabilitySortPriority(titleMap: liabilitySectionTitleMap)
                if lhsPriority == rhsPriority {
                    return $0.category.createdAt < $1.category.createdAt
                }
                return lhsPriority < rhsPriority
            }

        return (nonLiability, liability)
    }

    #if DEBUG
    private var debugAutoPricedItem: AssetItem? {
        let groups = categoryItemGroups
        return groups.nonLiability
            .flatMap(\.items)
            .first(where: { $0.autoPricedAssetKind != nil })
        ?? groups.liability
            .flatMap(\.items)
            .first(where: { $0.autoPricedAssetKind != nil })
    }

    private var forcedDebugQuickEditItem: AssetItem? {
        guard ProcessInfo.processInfo.arguments.contains("-showDebugQuickEditPreview") else { return nil }
        return debugAutoPricedItem
    }
    #endif

    private var currentSnapshotEntriesByItemID: [UUID: AssetEntry] {
        guard let currentSnapshot else { return [:] }
        return Dictionary(uniqueKeysWithValues: currentSnapshot.entries.compactMap { entry in
            guard let itemID = entry.item?.id else { return nil }
            return (itemID, entry)
        })
    }

    @ViewBuilder
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-openSnapshotArchive") {
            SnapshotArchiveView()
        } else {
            snapshotListBody
        }
        #else
        snapshotListBody
        #endif
    }

    private var snapshotListBody: some View {
        let currentSnapshotValue = currentSnapshot
        let categoryGroups = categoryItemGroups
        let nonLiabilityCategoryItems = categoryGroups.nonLiability
        let liabilityCategoryItems = categoryGroups.liability
        let snapshotEntriesByItemIDValue = snapshotEntriesByItemID(for: currentSnapshotValue)
        let displayedTotalAssetsValue = displayedTotalAmount(for: nonLiabilityCategoryItems.map(\.items), entriesByItemID: snapshotEntriesByItemIDValue)
        let displayedTotalLiabilitiesValue = displayedTotalAmount(for: liabilityCategoryItems.map(\.items), entriesByItemID: snapshotEntriesByItemIDValue)
        let displayedNetAssetsValue = displayedTotalAssetsValue - displayedTotalLiabilitiesValue
        let onboardingInputTargetCategoryID = nonLiabilityCategoryItems.first?.id

        return NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let currentSnapshot = currentSnapshotValue {
                            RecordPageHero(
                                snapshot: currentSnapshot,
                                totalAssets: displayedTotalAssetsValue,
                                netAssets: displayedNetAssetsValue,
                                totalLiabilities: displayedTotalLiabilitiesValue,
                                onAddAsset: {
                                    dismissKeyboard()
                                    showsAddAssetItemSheet = true
                                }
                            )
                            .padding(.bottom, 2)

                            ForEach(nonLiabilityCategoryItems) { categoryItems in
                                RecordCategoryCard(
                                    category: categoryItems.category,
                                    items: categoryItems.items,
                                    snapshotEntriesByItemID: snapshotEntriesByItemIDValue,
                                    onboardingInputItemID: categoryItems.id == onboardingInputTargetCategoryID ? categoryItems.items.first?.id : nil,
                                    onboardingActiveAnchorID: onboardingActiveAnchorID,
                                    marketStore: marketStore,
                                    amountInputs: $amountInputs,
                                    quantityInputs: $quantityInputs,
                                    unitPriceInputs: $unitPriceInputs,
                                    focusedField: $focusedField,
                                    onEdit: { item in
                                        dismissKeyboard()
                                        editingAssetItem = item
                                    },
                                    onEditValue: { item in
                                        dismissKeyboard()
                                        quickEditingAssetItem = item
                                    }
                                )
                            }

                            ForEach(liabilityCategoryItems) { categoryItems in
                                LiabilityCategorySection(
                                    category: categoryItems.category,
                                    items: categoryItems.items,
                                    snapshotEntriesByItemID: snapshotEntriesByItemIDValue,
                                    amountInputs: $amountInputs,
                                    quantityInputs: $quantityInputs,
                                    focusedField: $focusedField,
                                    onEdit: { item in
                                        dismissKeyboard()
                                        editingAssetItem = item
                                    },
                                    onEditValue: { item in
                                        dismissKeyboard()
                                        quickEditingAssetItem = item
                                    }
                                )
                            }

                        } else if isPreparingInitialSnapshot || !didPrepare {
                            LoadingStateCard(title: AppLocalization.string("记录加载中"))
                        } else {
                            EmptyStateCard(
                                title: AppLocalization.string("暂无记录"),
                                systemImage: "calendar.badge.plus"
                            )
                        }

                        Color.clear
                            .frame(height: 180)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissKeyboard()
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 104)
                }
                .scrollDismissesKeyboard(.never)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showsAddAssetItemSheet) {
            AddAssetItemSheet()
        }
        .sheet(item: $editingAssetItem) { item in
            EditAssetItemSheet(item: item, snapshot: currentSnapshot)
        }
        .overlay {
            #if DEBUG
            let presentedItem = quickEditingAssetItem ?? forcedDebugQuickEditItem
            #else
            let presentedItem = quickEditingAssetItem
            #endif

            if let item = presentedItem {
                ZStack {
                    Rectangle()
                        .fill(.black.opacity(0.42))
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismissKeyboard()
                            quickEditingAssetItem = nil
                        }

                    QuickRecordValueSheet(
                        item: item,
                        snapshot: currentSnapshot,
                        marketStore: marketStore,
                        onCancel: {
                            dismissKeyboard()
                            quickEditingAssetItem = nil
                        },
                        onSaved: {
                            if let snapshot = currentSnapshot {
                                hydrateInputs(for: item, from: snapshot)
                            }
                            dismissKeyboard()
                            quickEditingAssetItem = nil
                        }
                    )
                    .padding(.horizontal, 24)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: quickEditingAssetItem?.id)
        .task {
            await prepareSnapshotIfNeeded()
            #if DEBUG
            await ensureDebugAutoPricedItemIfNeeded()
            if ProcessInfo.processInfo.arguments.contains("-openFirstAutoPricedQuickEdit"),
               let debugAutoPricedItem,
               quickEditingAssetItem == nil {
                try? await Task.sleep(for: .milliseconds(250))
                quickEditingAssetItem = debugAutoPricedItem
            }
            #endif
            if isActive {
                scheduleAutoRateSync(delayNanoseconds: 650_000_000)
            }
        }
        .task(id: isActive) {
            if isActive {
                scheduleAutoRateSync(delayNanoseconds: 650_000_000)
            } else {
                pendingAutoRateSyncTask?.cancel()
            }
        }
        #if DEBUG
        .task(id: debugAutoPricedItem?.id) {
            await ensureDebugAutoPricedItemIfNeeded()
            guard ProcessInfo.processInfo.arguments.contains("-openFirstAutoPricedQuickEdit"),
                  quickEditingAssetItem == nil,
                  let debugAutoPricedItem else { return }
            try? await Task.sleep(for: .milliseconds(250))
            quickEditingAssetItem = debugAutoPricedItem
        }
        #endif
        .onChange(of: marketStore.exchangeRates) { _, _ in
            guard isActive else { return }
            scheduleAutoRateSync(delayNanoseconds: 300_000_000)
        }
        .onReceive(marketStore.$overview) { _ in
            guard isActive else { return }
            scheduleAutoRateSync(delayNanoseconds: 300_000_000)
        }
        .onChange(of: focusedField) { previousField, newField in
            guard let previousField, previousField != newField,
                  let item = item(for: previousField) else { return }
            persist(item: item)
        }
    }

    @MainActor
    private func dismissKeyboard() {
        focusedField = nil
        dismissActiveKeyboard()
    }

    private func item(for field: RecordInputField) -> AssetItem? {
        let itemID: UUID
        switch field {
        case let .amount(id), let .quantity(id), let .unitPrice(id):
            itemID = id
        }
        return categories.flatMap(\.items).first(where: { $0.id == itemID })
    }

    @MainActor
    private func prepareSnapshotIfNeeded() async {
        guard !didPrepare else { return }
        didPrepare = true
        isPreparingInitialSnapshot = true
        defer { isPreparingInitialSnapshot = false }

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

    #if DEBUG
    @MainActor
    private func ensureDebugAutoPricedItemIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-ensureDebugAutoPricedAsset"),
              let snapshot = currentSnapshot else { return }

        let shouldOpenQuickEdit = ProcessInfo.processInfo.arguments.contains("-openFirstAutoPricedQuickEdit")

        if let debugAutoPricedItem {
            if snapshot.entries.first(where: { $0.item?.id == debugAutoPricedItem.id }) == nil {
                let unitPrice = debugAutoPricedItem.resolvedAutoUnitPrice(using: marketStore)
                try? SnapshotService.upsertEntry(
                    snapshot: snapshot,
                    item: debugAutoPricedItem,
                    quantity: 1,
                    unitPrice: unitPrice,
                    in: modelContext
                )
                hydrateInputs(for: debugAutoPricedItem, from: snapshot)
            }
            if shouldOpenQuickEdit {
                quickEditingAssetItem = debugAutoPricedItem
            }
            return
        }

        guard let targetCategory = categories.first(where: { $0.group == .financial }) ?? categories.first else { return }

        do {
            let item = try AssetItemService.createItem(
                name: AppLocalization.string("黄金"),
                category: targetCategory,
                valuationMethod: .quantityAndUnitPrice,
                autoPricedAssetKind: .gold,
                note: "DEBUG",
                in: modelContext
            )
            let unitPrice = item.resolvedAutoUnitPrice(using: marketStore)
            try SnapshotService.upsertEntry(
                snapshot: snapshot,
                item: item,
                quantity: 1,
                unitPrice: unitPrice,
                in: modelContext
            )
            hydrateInputs(for: item, from: snapshot)
            if shouldOpenQuickEdit {
                quickEditingAssetItem = item
            }
        } catch {
            print("[AssetTimeMachine] debug auto-priced asset setup failed: \(error)")
        }
    }
    #endif

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
    private func hydrateInputs(for item: AssetItem, from snapshot: AssetSnapshot) {
        guard let entry = snapshot.entries.first(where: { $0.item?.id == item.id }) else { return }
        amountInputs[item.id] = item.valuationMethod == .directAmount ? (entry.amount?.plainNumberString() ?? "") : ""
        quantityInputs[item.id] = item.valuationMethod == .quantityAndUnitPrice ? (entry.quantity?.plainNumberString() ?? "") : ""
        unitPriceInputs[item.id] = item.valuationMethod == .quantityAndUnitPrice ? (entry.unitPrice?.plainNumberString() ?? "") : ""
    }

    @MainActor
    private func scheduleAutoRateSync(delayNanoseconds: UInt64) {
        pendingAutoRateSyncTask?.cancel()
        pendingAutoRateSyncTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await syncAutoRatesIfPossible()
        }
    }

    @MainActor
    private func syncAutoRatesIfPossible() async {
        guard let snapshot = currentSnapshot else { return }
        guard snapshot.entries.contains(where: { entry in
            entry.item?.resolvedAutoPricedAssetKind != nil
        }) else { return }

        var didMutateEntries = false

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
                let resolvedQuantity = normalizedNumber(from: quantityInputs[item.id]) ?? entry.quantity
                entry.quantity = resolvedQuantity
                entry.unitPrice = rate
                entry.updatedAt = .now
                item.updatedAt = .now
                didMutateEntries = true
            }
        }

        if didMutateEntries {
            snapshot.updatedAt = .now
            do {
                try modelContext.save()
                await SnapshotAnchorService.captureLiveAnchorsIfPossible(for: snapshot, marketStore: marketStore, in: modelContext)
            } catch {
                print("[AssetTimeMachine] sync auto rate failed: \(error)")
            }
        }
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

    private func snapshotEntriesByItemID(for snapshot: AssetSnapshot?) -> [UUID: AssetEntry] {
        guard let snapshot else { return [:] }
        return Dictionary(uniqueKeysWithValues: snapshot.entries.compactMap { entry in
            guard let itemID = entry.item?.id else { return nil }
            return (itemID, entry)
        })
    }

    private func displayedTotalAmount(for itemGroups: [[AssetItem]], entriesByItemID: [UUID: AssetEntry]) -> Double {
        itemGroups
            .flatMap { $0 }
            .reduce(0) { partialResult, item in
                partialResult + (displayEntry(for: item, entriesByItemID: entriesByItemID)?.resolvedAmount ?? 0)
            }
    }

    private func displayEntry(for item: AssetItem, entriesByItemID: [UUID: AssetEntry]) -> AssetEntry? {
        if let snapshotEntry = entriesByItemID[item.id],
           snapshotEntry.amount != nil || snapshotEntry.quantity != nil || snapshotEntry.unitPrice != nil {
            return snapshotEntry
        }

        return item.latestEntry
    }
}

enum RecordInputField: Hashable {
    case amount(UUID)
    case quantity(UUID)
    case unitPrice(UUID)
}

@MainActor
func dismissActiveKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct RecordHeroMetric: View {
    let title: String
    let value: String
    let valueColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppLocalization.string(title))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

struct RecordHeroActionChip: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .bold))
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(AssetTheme.textPrimary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6.5)
        .background(AssetTheme.overlaySoft.opacity(0.62), in: Capsule())
        .overlay(
            Capsule()
                .stroke(AssetTheme.border.opacity(0.34), lineWidth: 1)
        )
    }
}

struct RecordPageHero: View {
    let snapshot: AssetSnapshot
    let totalAssets: Double
    let netAssets: Double
    let totalLiabilities: Double
    let onAddAsset: () -> Void

    private var netAssetColor: Color {
        netAssets < 0 ? AssetTheme.negative : AssetTheme.textPrimary
    }

    private var totalAssetText: Text {
        let amount = totalAssets.currencyString()
        guard let dotIndex = amount.lastIndex(of: ".") else {
            return Text(amount)
                .font(.system(size: 32, weight: .semibold))
        }

        let major = String(amount[..<dotIndex])
        let minor = String(amount[dotIndex...])
        return Text(major)
            .font(.system(size: 32, weight: .semibold))
        + Text(minor)
            .font(.system(size: 19, weight: .semibold))
            .baselineOffset(1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    Text(AppLocalization.string("总资产"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.94))

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [AssetTheme.goldSoft.opacity(0.52), AssetTheme.border.opacity(0.08)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 28, height: 1)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    NavigationLink {
                        SnapshotArchiveView()
                    } label: {
                        RecordHeroActionChip(
                            systemImage: "clock.arrow.circlepath",
                            title: AppLocalization.string("历史记录")
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: onAddAsset) {
                        RecordHeroActionChip(
                            systemImage: "plus",
                            title: AppLocalization.string("新增资产")
                        )
                    }
                    .buttonStyle(.plain)
                    .onboardingAnchor(.recordsAddAsset)
                }
            }

            totalAssetText
                .foregroundStyle(
                    LinearGradient(
                        colors: [AssetTheme.textPrimary, AssetTheme.goldSoft.opacity(0.84)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .lineLimit(1)
                .minimumScaleFactor(0.74)
                .monospacedDigit()
                .onboardingAnchor(.recordsTotal)

            HStack(alignment: .bottom, spacing: 12) {
                Text(snapshot.date.recordDateString)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.9))

                Spacer(minLength: 12)

                HStack(spacing: 14) {
                    RecordHeroMetric(title: AppLocalization.string("净资产"), value: netAssets.currencyString(), valueColor: netAssetColor)

                    Rectangle()
                        .fill(AssetTheme.border.opacity(0.18))
                        .frame(width: 1, height: 24)

                    RecordHeroMetric(title: AppLocalization.string("负债"), value: totalLiabilities.currencyString(), valueColor: AssetTheme.negative.opacity(0.92))
                }
            }

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), AssetTheme.border.opacity(0.08)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.top, 4)
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

struct AssetItemGlyph: View {
    let item: AssetItem
    var accent: Color = AssetTheme.goldSoft
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: AssetItemService.displaySymbolName(for: item))
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(accent)
            .frame(width: size + 3, height: size + 3)
    }
}

struct RecordEntryGlyph: View {
    let item: AssetItem
    let tint: Color
    var glyphSize: CGFloat = 10

    var body: some View {
        AssetItemGlyph(item: item, accent: tint, size: glyphSize)
            .frame(width: 16, height: 18, alignment: .center)
    }
}

struct RecordSectionHeader: View {
    let title: String
    let amount: String
    var amountColor: Color = AssetTheme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(AppLocalization.string(title))
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.94))
                .lineLimit(1)

            Spacer(minLength: 10)

            Text(amount)
                .font(.system(size: 15.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(amountColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }
}

struct RecordCategoryCard: View {
    private let inputWidth: CGFloat = 74

    private enum InputBlock: Identifiable {
        case compact([AssetItem])
        case expanded(AssetItem)

        var id: String {
            switch self {
            case let .compact(items):
                return "compact-\(items.map(\.id.uuidString).joined(separator: "-"))"
            case let .expanded(item):
                return "expanded-\(item.id.uuidString)"
            }
        }
    }

    let category: AssetCategory
    let items: [AssetItem]
    let snapshotEntriesByItemID: [UUID: AssetEntry]
    let onboardingInputItemID: UUID?
    let onboardingActiveAnchorID: OnboardingAnchorID?
    @ObservedObject var marketStore: RemoteMarketStore
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    @Binding var unitPriceInputs: [UUID: String]
    @Binding var focusedField: RecordInputField?
    let onEdit: (AssetItem) -> Void
    let onEditValue: (AssetItem) -> Void
    @State private var draggedItemID: UUID?

    private let compactColumns = [
        GridItem(.flexible(), spacing: 0, alignment: .top),
        GridItem(.flexible(), spacing: 0, alignment: .top)
    ]


    private var categoryTotal: Double {
        items.reduce(0) { partialResult, item in
            partialResult + (snapshotEntry(for: item)?.resolvedAmount ?? 0)
        }
    }

    private func snapshotEntry(for item: AssetItem) -> AssetEntry? {
        snapshotEntriesByItemID[item.id] ?? item.latestEntry
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

    private func showsRightDivider(at index: Int, total: Int) -> Bool {
        index % 2 == 0 && index + 1 < total
    }

    private func showsBottomDivider(at index: Int, total: Int) -> Bool {
        let rowCount = Int(ceil(Double(total) / 2.0))
        return index / 2 < rowCount - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordSectionHeader(
                title: category.name,
                amount: categoryTotal.currencyString(),
                amountColor: AssetTheme.textPrimary
            )

            VStack(spacing: 10) {
                ForEach(inputBlocks) { block in
                    switch block {
                    case let .compact(compactItems):
                        RecordMatrixSurface {
                            LazyVGrid(columns: compactColumns, alignment: .leading, spacing: 0) {
                                ForEach(Array(compactItems.enumerated()), id: \.element.id) { index, item in
                                    ReorderableRecordCell(category: category, item: item, draggedItemID: $draggedItemID) {
                                        AssetEntryCompactCard(
                                            item: item,
                                            snapshotEntry: snapshotEntry(for: item),
                                            marketStore: marketStore,
                                            amountText: Binding(
                                                get: { amountInputs[item.id] ?? "" },
                                                set: { newValue in
                                                    amountInputs[item.id] = newValue
                                                }
                                            ),
                                            quantityText: Binding(
                                                get: { quantityInputs[item.id] ?? "" },
                                                set: { newValue in
                                                    quantityInputs[item.id] = newValue
                                                }
                                            ),
                                            focusedField: $focusedField,
                                            inputWidth: inputWidth,
                                            isOnboardingTarget: item.id == onboardingInputItemID,
                                            showsOnboardingInputPreview: onboardingActiveAnchorID == .recordsFirstInput && item.id == onboardingInputItemID,
                                            onEdit: {
                                                onEdit(item)
                                            },
                                            onEditValue: {
                                                onEditValue(item)
                                            }
                                        )
                                    }
                                    .overlay(alignment: .trailing) {
                                        if showsRightDivider(at: index, total: compactItems.count) {
                                            Rectangle()
                                                .fill(AssetTheme.border.opacity(0.34))
                                                .frame(width: 1)
                                        }
                                    }
                                    .overlay(alignment: .bottom) {
                                        if showsBottomDivider(at: index, total: compactItems.count) {
                                            Rectangle()
                                                .fill(AssetTheme.border.opacity(0.34))
                                                .frame(height: 1)
                                        }
                                    }
                                }
                            }
                        }
                    case let .expanded(item):
                        RecordMatrixSurface {
                            ReorderableRecordCell(category: category, item: item, draggedItemID: $draggedItemID) {
                                AssetEntryInputRow(
                                    item: item,
                                    snapshotEntry: snapshotEntry(for: item),
                                    marketStore: marketStore,
                                    amountText: Binding(
                                        get: { amountInputs[item.id] ?? "" },
                                        set: { newValue in
                                            amountInputs[item.id] = newValue
                                        }
                                    ),
                                    quantityText: Binding(
                                        get: { quantityInputs[item.id] ?? "" },
                                        set: { newValue in
                                            quantityInputs[item.id] = newValue
                                        }
                                    ),
                                    unitPriceText: Binding(
                                        get: { unitPriceInputs[item.id] ?? "" },
                                        set: { newValue in
                                            unitPriceInputs[item.id] = newValue
                                        }
                                    ),
                                    focusedField: $focusedField,
                                    inputWidth: inputWidth,
                                    isOnboardingTarget: item.id == onboardingInputItemID,
                                    showsOnboardingInputPreview: onboardingActiveAnchorID == .recordsFirstInput && item.id == onboardingInputItemID,
                                    onEdit: {
                                        onEdit(item)
                                    },
                                    onEditValue: {
                                        onEditValue(item)
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

struct LiabilityCategorySection: View {
    private let inputWidth: CGFloat = 74

    let category: AssetCategory
    let items: [AssetItem]
    let snapshotEntriesByItemID: [UUID: AssetEntry]
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    @Binding var focusedField: RecordInputField?
    let onEdit: (AssetItem) -> Void
    let onEditValue: (AssetItem) -> Void
    @State private var draggedItemID: UUID?

    private let columns = [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)]


    private var categoryTotal: Double {
        items.reduce(0) { partialResult, item in
            partialResult + (snapshotEntry(for: item)?.resolvedAmount ?? 0)
        }
    }

    private func snapshotEntry(for item: AssetItem) -> AssetEntry? {
        snapshotEntriesByItemID[item.id] ?? item.latestEntry
    }

    private func showsRightDivider(at index: Int, total: Int) -> Bool {
        index % 2 == 0 && index + 1 < total
    }

    private func showsBottomDivider(at index: Int, total: Int) -> Bool {
        let rowCount = Int(ceil(Double(total) / 2.0))
        return index / 2 < rowCount - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordSectionHeader(
                title: category.name,
                amount: categoryTotal.currencyString(),
                amountColor: AssetTheme.negative.opacity(0.94)
            )

            RecordMatrixSurface {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ReorderableRecordCell(category: category, item: item, draggedItemID: $draggedItemID) {
                            LiabilityEntryCard(
                                item: item,
                                snapshotEntry: snapshotEntry(for: item),
                                amountText: Binding(
                                    get: { amountInputs[item.id] ?? "" },
                                    set: { newValue in
                                        amountInputs[item.id] = newValue
                                    }
                                ),
                                quantityText: Binding(
                                    get: { quantityInputs[item.id] ?? "" },
                                    set: { newValue in
                                        quantityInputs[item.id] = newValue
                                    }
                                ),
                                focusedField: $focusedField,
                                inputWidth: inputWidth,
                                onEdit: {
                                    onEdit(item)
                                },
                                onEditValue: {
                                    onEditValue(item)
                                }
                            )
                        }
                        .overlay(alignment: .trailing) {
                            if showsRightDivider(at: index, total: items.count) {
                                Rectangle()
                                    .fill(AssetTheme.border.opacity(0.34))
                                    .frame(width: 1)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if showsBottomDivider(at: index, total: items.count) {
                                Rectangle()
                                    .fill(AssetTheme.border.opacity(0.34))
                                    .frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct LiabilityEntryCard: View {
    let item: AssetItem
    let snapshotEntry: AssetEntry?
    @Binding var amountText: String
    @Binding var quantityText: String
    @Binding var focusedField: RecordInputField?
    let inputWidth: CGFloat
    let onEdit: () -> Void
    let onEditValue: () -> Void

    private var activeField: RecordInputField {
        item.valuationMethod == .directAmount ? .amount(item.id) : .quantity(item.id)
    }

    private var isEditing: Bool {
        focusedField == activeField
    }

    private var hasDisplayValue: Bool {
        displayValue != "--"
    }

    var body: some View {
        RecordInputCard {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    onEdit()
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        RecordEntryGlyph(item: item, tint: hasDisplayValue ? AssetTheme.negative : AssetTheme.negative.opacity(0.72))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalization.string(item.name))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(hasDisplayValue ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .allowsTightening(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isEditing {
                    if item.valuationMethod == .directAmount {
                        ATMInputField(
                            text: $amountText,
                            placeholder: "0",
                            width: inputWidth,
                            focusedField: $focusedField,
                            focusValue: .amount(item.id),
                            centered: true,
                            fontSize: 12,
                            fontWeight: .medium,
                            height: 32,
                            backgroundOpacity: 0.54,
                            strokeOpacity: 0.18
                        )
                    } else {
                        ATMInputField(
                            text: $quantityText,
                            placeholder: item.compactRecordPlaceholder,
                            width: inputWidth,
                            focusedField: $focusedField,
                            focusValue: .quantity(item.id),
                            centered: true,
                            fontSize: 12,
                            fontWeight: .medium,
                            height: 32,
                            backgroundOpacity: 0.54,
                            strokeOpacity: 0.18
                        )
                    }
                } else {
                    Button {
                        onEditValue()
                    } label: {
                        Text(displayValue)
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .foregroundStyle(hasDisplayValue ? AssetTheme.textPrimary : AssetTheme.textSecondary.opacity(0.78))
                            .frame(width: inputWidth, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var displayValue: String {
        if item.valuationMethod == .directAmount {
            if !amountText.isEmpty { return amountText }
            if let latestAmount = snapshotEntry?.amount {
                return latestAmount.plainNumberString()
            }
        } else {
            if !quantityText.isEmpty { return quantityText }
            if let latestQuantity = snapshotEntry?.quantity {
                return latestQuantity.plainNumberString()
            }
        }
        return "--"
    }
}

struct RecordMatrixSurface<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape
                .fill(
                    LinearGradient(
                        colors: [AssetTheme.surface.opacity(0.24), AssetTheme.background.opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            shape
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), AssetTheme.goldSoft.opacity(0.08), AssetTheme.border.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .clipShape(shape)
    }
}

struct RecordInputCard<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
    }
}

struct ReorderableRecordCell<Content: View>: View {
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
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

struct RecordItemDropDelegate: DropDelegate {
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

struct AssetEntryCompactCard: View {
    let item: AssetItem
    let snapshotEntry: AssetEntry?
    @ObservedObject var marketStore: RemoteMarketStore
    @Binding var amountText: String
    @Binding var quantityText: String
    @Binding var focusedField: RecordInputField?
    let inputWidth: CGFloat
    let isOnboardingTarget: Bool
    let showsOnboardingInputPreview: Bool
    let onEdit: () -> Void
    let onEditValue: () -> Void

    private var activeField: RecordInputField {
        item.valuationMethod == .directAmount ? .amount(item.id) : .quantity(item.id)
    }

    private var isEditing: Bool {
        focusedField == activeField
    }

    private var hasDisplayValue: Bool {
        displayValue != "--"
    }

    private var showsEditableField: Bool {
        isEditing || showsOnboardingInputPreview
    }

    var body: some View {
        RecordInputCard {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    onEdit()
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        RecordEntryGlyph(item: item, tint: hasDisplayValue ? AssetTheme.goldSoft : AssetTheme.goldSoft.opacity(0.74))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLocalization.string(item.name))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(hasDisplayValue ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .allowsTightening(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showsEditableField {
                    if item.valuationMethod == .directAmount {
                        ATMInputField(text: $amountText, placeholder: "0", width: inputWidth, focusedField: $focusedField, focusValue: .amount(item.id), centered: true, fontSize: 12, fontWeight: .medium, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                            .onboardingAnchorIf(isOnboardingTarget, .recordsFirstInput)
                    } else {
                        ATMInputField(text: $quantityText, placeholder: "0", width: inputWidth, focusedField: $focusedField, focusValue: .quantity(item.id), centered: true, fontSize: 12, fontWeight: .medium, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                            .onboardingAnchorIf(isOnboardingTarget, .recordsFirstInput)
                    }
                } else {
                    Button {
                        onEditValue()
                    } label: {
                        Text(displayValue)
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .foregroundStyle(hasDisplayValue ? AssetTheme.textPrimary : AssetTheme.textSecondary.opacity(0.78))
                            .frame(width: inputWidth, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .onboardingAnchorIf(isOnboardingTarget, .recordsFirstInput)
                }
            }
        }
    }

    private var displayValue: String {
        if item.valuationMethod == .directAmount {
            if !amountText.isEmpty { return amountText }
            if let latestAmount = snapshotEntry?.amount {
                return latestAmount.plainNumberString()
            }
        } else {
            if !quantityText.isEmpty { return quantityText }
            if let latestQuantity = snapshotEntry?.quantity {
                return latestQuantity.plainNumberString()
            }
        }
        return "--"
    }
}

struct AssetEntryInputRow: View {
    let item: AssetItem
    let snapshotEntry: AssetEntry?
    @ObservedObject var marketStore: RemoteMarketStore
    @Binding var amountText: String
    @Binding var quantityText: String
    @Binding var unitPriceText: String
    @Binding var focusedField: RecordInputField?
    let inputWidth: CGFloat
    let isOnboardingTarget: Bool
    let showsOnboardingInputPreview: Bool
    let onEdit: () -> Void
    let onEditValue: () -> Void

    private var isEditing: Bool {
        focusedField == .quantity(item.id) || focusedField == .unitPrice(item.id)
    }

    private var resolvedValueText: String {
        if !quantityText.isEmpty { return quantityText }
        return snapshotEntry?.quantity?.plainNumberString() ?? "--"
    }

    private var hasResolvedValue: Bool {
        resolvedValueText != "--"
    }

    private var showsEditableField: Bool {
        isEditing || showsOnboardingInputPreview
    }

    var body: some View {
        RecordInputCard {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    onEdit()
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        RecordEntryGlyph(item: item, tint: hasResolvedValue ? AssetTheme.goldSoft : AssetTheme.goldSoft.opacity(0.74))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLocalization.string(item.name))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(hasResolvedValue ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .allowsTightening(true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .layoutPriority(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {

                    if showsEditableField {
                        HStack(spacing: 6) {
                            ATMInputField(text: $quantityText, placeholder: AppLocalization.string("数量"), width: inputWidth, focusedField: $focusedField, focusValue: .quantity(item.id), centered: true, fontSize: 12, fontWeight: .medium, height: 30, backgroundOpacity: 0.05, strokeOpacity: 0.16)
                                .onboardingAnchorIf(isOnboardingTarget, .recordsFirstInput)
                        }
                    } else {
                        HStack(spacing: 12) {
                            Button {
                                onEditValue()
                            } label: {
                                recordValueLabel(title: AppLocalization.string("数量"), value: quantityText)
                            }
                            .buttonStyle(.plain)
                            .onboardingAnchorIf(isOnboardingTarget, .recordsFirstInput)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recordValueLabel(title: String, value: String) -> some View {
        let fallbackValue = (title == AppLocalization.string("数量"))
            ? (snapshotEntry?.quantity?.plainNumberString() ?? "--")
            : (snapshotEntry?.unitPrice?.plainNumberString() ?? "--")
        let resolvedValue = value.isEmpty ? fallbackValue : value

        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AssetTheme.textSecondary)
            Text(resolvedValue)
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(resolvedValue == "--" ? AssetTheme.textSecondary.opacity(0.78) : AssetTheme.textPrimary)
        }
        .frame(width: inputWidth, alignment: .trailing)
    }
}

struct ATMInputField: View {
    @Binding var text: String
    let placeholder: String
    var width: CGFloat? = nil
    @Binding var focusedField: RecordInputField?
    let focusValue: RecordInputField
    var centered: Bool = false
    var fontSize: CGFloat = 17
    var fontWeight: Font.Weight = .medium
    var height: CGFloat = 42
    var backgroundOpacity: Double = 0.66
    var strokeOpacity: Double = 0.52

    var body: some View {
        ATMUIKitInputField(
            text: $text,
            placeholder: placeholder,
            focusedField: $focusedField,
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

struct ATMUIKitInputField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var focusedField: RecordInputField?
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
        context.coordinator.isBeingDismantled = false

        if uiView.text != text {
            uiView.text = text
        }

        uiView.textAlignment = centered ? .center : .right
        uiView.font = .systemFont(ofSize: fontSize, weight: fontWeight.uiFontWeight)
        uiView.textColor = UIColor(AssetTheme.textPrimary)
        uiView.attributedPlaceholder = NSAttributedString(
            string: AppLocalization.string(placeholder),
            attributes: [.foregroundColor: UIColor(AssetTheme.textSecondary)]
        )

        let shouldBeFirstResponder = focusedField == focusValue
        if shouldBeFirstResponder, !uiView.isFirstResponder {
            context.coordinator.isSyncingFirstResponder = true
            DispatchQueue.main.async {
                guard context.coordinator.parent.focusedField == context.coordinator.parent.focusValue,
                      !uiView.isFirstResponder else { return }
                uiView.becomeFirstResponder()
                context.coordinator.moveCaretToEnd(in: uiView)
            }
        } else if !shouldBeFirstResponder, uiView.isFirstResponder {
            context.coordinator.isSyncingFirstResponder = true
            DispatchQueue.main.async {
                guard context.coordinator.parent.focusedField != context.coordinator.parent.focusValue,
                      uiView.isFirstResponder else { return }
                uiView.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: UITextField, coordinator: Coordinator) {
        coordinator.isBeingDismantled = true
        uiView.delegate = nil
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ATMUIKitInputField
        var isSyncingFirstResponder = false
        var isBeingDismantled = false

        init(parent: ATMUIKitInputField) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isSyncingFirstResponder = false
            parent.focusedField = parent.focusValue
            moveCaretToEnd(in: textField)
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            // Keep user typing fluid. Forcing the caret on every selection update
            // can fight UIKit's own text editing cycle and makes record inputs feel sticky.
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            defer { isSyncingFirstResponder = false }

            guard !isBeingDismantled else { return }
            guard !isSyncingFirstResponder else { return }
            guard parent.focusedField == parent.focusValue else { return }

            parent.focusedField = nil
        }

        func moveCaretToEnd(in textField: UITextField) {
            let end = textField.endOfDocument
            guard let range = textField.textRange(from: end, to: end) else { return }
            textField.selectedTextRange = range
        }
    }
}

extension Font.Weight {
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

let assetIconOptions = AssetIconRegistry.definitions

let autoAssetGridColumns = [
    GridItem(.flexible(), spacing: 6),
    GridItem(.flexible(), spacing: 6),
    GridItem(.flexible(), spacing: 6),
    GridItem(.flexible(), spacing: 6)
]

func autoAssetSymbolName(for kind: AutoPricedAssetKind) -> String {
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

struct AssetIconView: View {
    let iconKey: String
    var fallbackSymbolName: String
    var accent: Color = AssetTheme.goldSoft
    var iconSize: CGFloat = 14
    var frameSize: CGFloat? = nil

    private var definition: AssetIconDefinition? {
        AssetIconRegistry.definition(for: iconKey)
    }

    var body: some View {
        Image(systemName: definition?.symbolName ?? fallbackSymbolName)
            .font(.system(size: iconSize, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(accent)
            .frame(width: iconSize, height: iconSize)
            .frame(width: frameSize ?? iconSize, height: frameSize ?? iconSize)
    }
}

struct AssetEditorForm: View {
    @Binding var name: String
    @Binding var selectedCategoryID: UUID?
    @Binding var selectedAutoPricedAssetKind: AutoPricedAssetKind?
    @Binding var selectedIconName: String
    let sortedCategories: [AssetCategory]
    let isAutoPricedLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLocalization.string("名称"))
                            .font(.headline)
                            .foregroundStyle(AssetTheme.textPrimary)

                        TextField(AppLocalization.string("示例：银行卡、房产、车辆"), text: $name)
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
                        Text(AppLocalization.string("归类"))
                            .font(.headline)
                            .foregroundStyle(AssetTheme.textPrimary)

                        Picker(AppLocalization.string("归类"), selection: Binding(
                            get: { selectedCategoryID ?? sortedCategories.first?.id },
                            set: { selectedCategoryID = $0 }
                        )) {
                            ForEach(sortedCategories) { category in
                                Text(AppLocalization.string(category.name)).tag(Optional.some(category.id))
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

                Text(AppLocalization.string("图标"))
                    .font(.headline)
                    .foregroundStyle(AssetTheme.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(assetIconOptions) { option in
                            Button {
                                selectedIconName = option.key
                            } label: {
                                VStack(spacing: 6) {
                                    AssetIconView(
                                        iconKey: option.key,
                                        fallbackSymbolName: option.symbolName,
                                        accent: selectedIconName == option.key ? AssetTheme.gold : AssetTheme.textPrimary,
                                        iconSize: 22,
                                        frameSize: 34
                                    )
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(selectedIconName == option.key ? AssetTheme.overlayStrong : AssetTheme.overlaySubtle)
                                        )
                                    Text(AppLocalization.string(option.label))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(selectedIconName == option.key ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                                }
                                .padding(.vertical, 3)
                                .frame(width: 56)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.string("特殊资产"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)

                Text(AppLocalization.string(isAutoPricedLocked ? "该资产已绑定自动定价类型。如需调整，请新建资产类型。" : "以下资产支持数量录入，价格将自动更新。"))
                    .font(.footnote)
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.8))

                LazyVGrid(columns: autoAssetGridColumns, alignment: .leading, spacing: 10) {
                    Button {
                        guard !isAutoPricedLocked else { return }
                        selectedAutoPricedAssetKind = nil
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "square.grid.2x2")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(selectedAutoPricedAssetKind == nil ? AssetTheme.gold : AssetTheme.textPrimary)
                                .shadow(color: selectedAutoPricedAssetKind == nil ? AssetTheme.gold.opacity(0.45) : .clear, radius: 10)
                            Text(AppLocalization.string("普通资产"))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(selectedAutoPricedAssetKind == nil ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .shadow(color: selectedAutoPricedAssetKind == nil ? AssetTheme.gold.opacity(0.3) : .clear, radius: 8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .opacity(isAutoPricedLocked ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isAutoPricedLocked)

                    ForEach(AutoPricedAssetKind.allCases) { kind in
                        Button {
                            guard !isAutoPricedLocked else { return }
                            selectedAutoPricedAssetKind = kind
                            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                name = kind.defaultName
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: autoAssetSymbolName(for: kind))
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(selectedAutoPricedAssetKind == kind ? AssetTheme.gold : AssetTheme.textPrimary)
                                    .shadow(color: selectedAutoPricedAssetKind == kind ? AssetTheme.gold.opacity(0.45) : .clear, radius: 10)
                                Text(kind.defaultName)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(selectedAutoPricedAssetKind == kind ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .shadow(color: selectedAutoPricedAssetKind == kind ? AssetTheme.gold.opacity(0.3) : .clear, radius: 8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .opacity(isAutoPricedLocked && selectedAutoPricedAssetKind != kind ? 0.5 : 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(isAutoPricedLocked)
                    }
                }
            }
        }
    }
}

struct AddAssetItemSheet: View {
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
                        AssetEditorForm(
                            name: $name,
                            selectedCategoryID: $selectedCategoryID,
                            selectedAutoPricedAssetKind: $selectedAutoPricedAssetKind,
                            selectedIconName: $selectedIconName,
                            sortedCategories: sortedCategories,
                            isAutoPricedLocked: false
                        )

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(AssetTheme.negative)
                                .padding(.horizontal, 4)
                        }

                        Color.clear
                            .frame(height: 180)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissActiveKeyboard()
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissActiveKeyboard()
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("添加资产类型"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("保存")) {
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
            errorMessage = AppLocalization.string("保存失败，请稍后再试")
            print("[AssetTimeMachine] create item failed: \(error)")
        }
    }
}

struct QuickRecordValueSheet: View {
    @Environment(\.modelContext) private var modelContext

    private enum QuickRecordValueField: Hashable {
        case primary
        case unitPrice
    }

    let item: AssetItem
    let snapshot: AssetSnapshot?
    @ObservedObject var marketStore: RemoteMarketStore
    let onCancel: () -> Void
    let onSaved: () -> Void

    @State private var amountText: String
    @State private var quantityText: String
    @State private var unitPriceText: String
    @State private var errorMessage: String?
    @State private var isRefreshingAutoPrice = false
    @FocusState private var focusedField: QuickRecordValueField?

    init(item: AssetItem, snapshot: AssetSnapshot?, marketStore: RemoteMarketStore, onCancel: @escaping () -> Void, onSaved: @escaping () -> Void) {
        self.item = item
        self.snapshot = snapshot
        self.marketStore = marketStore
        self.onCancel = onCancel
        self.onSaved = onSaved

        let currentEntry = snapshot?.entries.first(where: { $0.item?.id == item.id })
        _amountText = State(initialValue: currentEntry?.amount?.plainNumberString() ?? "")
        _quantityText = State(initialValue: currentEntry?.quantity?.plainNumberString() ?? "")
        _unitPriceText = State(initialValue: currentEntry?.unitPrice?.plainNumberString() ?? item.resolvedAutoUnitPrice(using: marketStore)?.plainNumberString() ?? "")
    }

    private var isLiability: Bool {
        item.category?.group == .liability
    }

    private var primaryFieldTitle: String {
        switch item.valuationMethod {
        case .directAmount:
            return AppLocalization.string(isLiability ? "负债数额" : "资产数额")
        case .quantityAndUnitPrice:
            return AppLocalization.string("数量")
        }
    }

    private var displayedUnitPriceText: String? {
        let trimmed = unitPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private var trailingUnitPriceTitle: String? {
        guard item.valuationMethod == .quantityAndUnitPrice else { return nil }
        return AppLocalization.string(item.autoPricedAssetKind == nil ? "单价" : "参考单价")
    }

    private var trailingUnitPriceValue: String? {
        guard item.valuationMethod == .quantityAndUnitPrice else { return nil }
        if item.autoPricedAssetKind != nil,
           let rate = item.resolvedAutoUnitPrice(using: marketStore) {
            return rate.currencyString()
        }
        return displayedUnitPriceText
    }

    private var trailingUnitPriceTimestamp: String? {
        guard item.valuationMethod == .quantityAndUnitPrice,
              item.autoPricedAssetKind != nil,
              let fetchedAt = item.autoPriceFetchedAt(using: marketStore) else {
            return nil
        }
        return AppLocalization.format("%@更新", fetchedAt.recordTimeString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                chromeButton(title: AppLocalization.string("取消"), tint: AssetTheme.textSecondary, action: onCancel)

                Spacer(minLength: 8)

                Text(AppLocalization.string("修改本次记录"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                chromeButton(title: AppLocalization.string("保存"), tint: AssetTheme.gold, action: save)
            }

            HStack(alignment: .center, spacing: 12) {
                AssetItemGlyph(item: item, accent: isLiability ? AssetTheme.negative : AssetTheme.gold, size: 18)

                Text(AppLocalization.string(item.name))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 8)

                if let trailingUnitPriceTitle,
                   let trailingUnitPriceValue {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(trailingUnitPriceTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AssetTheme.textSecondary)
                        Text(trailingUnitPriceValue)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(AssetTheme.textPrimary)
                        if let trailingUnitPriceTimestamp {
                            Text(trailingUnitPriceTimestamp)
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                }
            }

            if item.autoPricedAssetKind != nil {
                HStack(spacing: 8) {
                    Button {
                        Task { await refreshAutoPriceManually() }
                    } label: {
                        HStack(spacing: 6) {
                            if isRefreshingAutoPrice {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(AssetTheme.gold)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption.weight(.bold))
                            }
                            Text(AppLocalization.string(isRefreshingAutoPrice ? "刷新中" : "手动刷新最新价格"))
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(AssetTheme.goldSoft)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AssetTheme.overlayMedium.opacity(0.85), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshingAutoPrice)

                    Spacer(minLength: 0)
                }
            }

            quickEditField(
                title: primaryFieldTitle,
                text: bindingForPrimaryField(),
                placeholder: AppLocalization.format("输入%@", primaryFieldTitle),
                focus: .primary
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(AssetTheme.negative)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), AssetTheme.gold.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.28), radius: 30, x: 0, y: 18)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-disableQuickEditAutoFocus") {
                return
            }
            #endif
            await Task.yield()
            focusedField = .primary
        }
    }

    @ViewBuilder
    private func quickEditField(title: String, text: Binding<String>, placeholder: String, focus: QuickRecordValueField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string(title))
                .font(.caption.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                .foregroundStyle(AssetTheme.textPrimary)
                .focused($focusedField, equals: focus)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AssetTheme.overlayMedium.opacity(0.9))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                }
        }
    }

    private func chromeButton(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(AppLocalization.string(title), action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func bindingForPrimaryField() -> Binding<String> {
        switch item.valuationMethod {
        case .directAmount:
            return $amountText
        case .quantityAndUnitPrice:
            return $quantityText
        }
    }

    @MainActor
    private func save() {
        guard let snapshot else {
            errorMessage = AppLocalization.string("今日记录尚未加载，请稍后再试")
            return
        }

        do {
            try saveCurrentValues(into: snapshot)
            onSaved()
        } catch let error as QuickRecordValueValidationError {
            errorMessage = error.message
        } catch {
            errorMessage = AppLocalization.string("保存失败，请稍后再试")
            print("[AssetTimeMachine] quick record save failed: \(error)")
        }
    }

    @MainActor
    private func saveCurrentValues(into snapshot: AssetSnapshot) throws {
        switch item.valuationMethod {
        case .directAmount:
            let amount = try validatedNumber(from: amountText, forcePositive: isLiability, fieldName: primaryFieldTitle)
            try SnapshotService.upsertEntry(snapshot: snapshot, item: item, amount: amount, in: modelContext)
        case .quantityAndUnitPrice:
            let quantity = try validatedNumber(from: quantityText, fieldName: primaryFieldTitle)
            let unitPrice: Double?
            if let autoRate = item.resolvedAutoUnitPrice(using: marketStore), item.autoPricedAssetKind != nil {
                unitPrice = autoRate
                unitPriceText = autoRate.plainNumberString()
            } else {
                unitPrice = normalizedReadonlyNumber(from: unitPriceText)
                    ?? snapshot.entries.first(where: { $0.item?.id == item.id })?.unitPrice
                    ?? item.latestEntry?.unitPrice
            }
            try SnapshotService.upsertEntry(snapshot: snapshot, item: item, quantity: quantity, unitPrice: unitPrice, in: modelContext)
        }
    }

    @MainActor
    private func refreshAutoPriceManually() async {
        guard item.autoPricedAssetKind != nil else { return }
        isRefreshingAutoPrice = true
        errorMessage = nil
        defer { isRefreshingAutoPrice = false }

        let didRefreshLiveData = await marketStore.refreshLiveData()
        guard didRefreshLiveData else {
            errorMessage = marketStore.errorMessage ?? AppLocalization.string("暂时没拿到最新价格，稍后再试")
            return
        }

        guard let latestRate = item.resolvedAutoUnitPrice(using: marketStore) else {
            errorMessage = AppLocalization.string("暂时没拿到最新价格，稍后再试")
            return
        }

        unitPriceText = latestRate.plainNumberString()

        guard let snapshot else { return }
        do {
            try saveCurrentValues(into: snapshot)
        } catch let error as QuickRecordValueValidationError {
            errorMessage = error.message
        } catch {
            errorMessage = AppLocalization.string("刷新后写入记录失败，请稍后再试")
            print("[AssetTimeMachine] manual auto price refresh failed: \(error)")
        }
    }

    private func validatedNumber(from text: String, forcePositive: Bool = false, fieldName: String) throws -> Double? {
        try validatedQuickRecordNumber(from: text, forcePositive: forcePositive, fieldName: fieldName)
    }

    private func normalizedReadonlyNumber(from text: String) -> Double? {
        let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return Double(raw)
    }
}

struct QuickRecordValueValidationError: Error {
    let message: String
}

private func validatedQuickRecordNumber(from text: String, forcePositive: Bool = false, fieldName: String) throws -> Double? {
    let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    guard let value = Double(raw) else {
        throw QuickRecordValueValidationError(message: AppLocalization.format("%@请输入有效数字", fieldName))
    }
    return forcePositive ? abs(value) : value
}

struct EditAssetItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var categories: [AssetCategory]

    let item: AssetItem
    let snapshot: AssetSnapshot?
    @State private var name: String
    @State private var selectedCategoryID: UUID?
    @State private var selectedAutoPricedAssetKind: AutoPricedAssetKind?
    @State private var selectedIconName: String
    @State private var recordQuantityText: String
    @State private var recordUnitPriceText: String
    @State private var errorMessage: String?

    init(item: AssetItem, snapshot: AssetSnapshot?) {
        self.item = item
        self.snapshot = snapshot
        _name = State(initialValue: item.name)
        _selectedCategoryID = State(initialValue: item.category?.id)
        _selectedAutoPricedAssetKind = State(initialValue: item.autoPricedAssetKind)
        let storedIconName = (item.iconName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let initialIcon = storedIconName.isEmpty
            ? AssetItemService.suggestedIconName(for: item.name, autoPricedAssetKind: item.autoPricedAssetKind)
            : storedIconName
        _selectedIconName = State(initialValue: initialIcon)
        let currentEntry = snapshot?.entries.first(where: { $0.item?.id == item.id })
        _recordQuantityText = State(initialValue: currentEntry?.quantity?.plainNumberString() ?? "")
        _recordUnitPriceText = State(initialValue: currentEntry?.unitPrice?.plainNumberString() ?? "")
    }

    private var sortedCategories: [AssetCategory] {
        categories.sorted {
            if $0.group.sortPriority == $1.group.sortPriority {
                return $0.createdAt < $1.createdAt
            }
            return $0.group.sortPriority < $1.group.sortPriority
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategory != nil
    }

    private var selectedCategory: AssetCategory? {
        guard let selectedCategoryID else { return sortedCategories.first }
        return sortedCategories.first(where: { $0.id == selectedCategoryID })
    }

    private var resolvedIconName: String {
        let trimmed = selectedIconName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return AssetItemService.suggestedIconName(for: name, autoPricedAssetKind: selectedAutoPricedAssetKind)
    }

    private var showsRecordPricingEditor: Bool {
        item.valuationMethod == .quantityAndUnitPrice
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        AssetEditorForm(
                            name: $name,
                            selectedCategoryID: $selectedCategoryID,
                            selectedAutoPricedAssetKind: $selectedAutoPricedAssetKind,
                            selectedIconName: $selectedIconName,
                            sortedCategories: sortedCategories,
                            isAutoPricedLocked: item.autoPricedAssetKind != nil
                        )

                        if showsRecordPricingEditor {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(AppLocalization.string("本次记录"))
                                    .font(.headline)
                                    .foregroundStyle(AssetTheme.textPrimary)

                                VStack(alignment: .leading, spacing: 8) {
                                    Text(AppLocalization.string("数量"))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AssetTheme.textSecondary)
                                    TextField(AppLocalization.string("输入数量"), text: $recordQuantityText)
                                        .keyboardType(.decimalPad)
                                        .textFieldStyle(.plain)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(AssetTheme.textPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(AssetTheme.overlayMedium, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    Text(AppLocalization.string("单价"))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AssetTheme.textSecondary)
                                    TextField(AppLocalization.string("输入单价"), text: $recordUnitPriceText)
                                        .keyboardType(.decimalPad)
                                        .textFieldStyle(.plain)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(AssetTheme.textPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(AssetTheme.overlayMedium, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(AssetTheme.negative)
                                .padding(.horizontal, 4)
                        }

                        Color.clear
                            .frame(height: 180)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissActiveKeyboard()
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissActiveKeyboard()
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("编辑资产类型"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("保存")) {
                        save()
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? AssetTheme.gold : AssetTheme.textSecondary)
                }
            }
            .task {
                if selectedCategoryID == nil {
                    selectedCategoryID = item.category?.id ?? sortedCategories.first?.id
                }
            }
        }
    }

    @MainActor
    private func save() {
        guard let selectedCategory else { return }

        do {
            try AssetItemService.updateItem(
                item,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                iconName: resolvedIconName,
                category: selectedCategory,
                in: modelContext
            )

            if showsRecordPricingEditor, let snapshot {
                try SnapshotService.upsertEntry(
                    snapshot: snapshot,
                    item: item,
                    quantity: normalizedNumber(from: recordQuantityText),
                    unitPrice: normalizedNumber(from: recordUnitPriceText),
                    in: modelContext
                )
            }

            dismiss()
        } catch {
            errorMessage = AppLocalization.string("保存失败，请稍后再试")
            print("[AssetTimeMachine] update item failed: \(error)")
        }
    }

    private func normalizedNumber(from text: String) -> Double? {
        let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let value = Double(raw) else { return nil }
        return value
    }
}

struct SummaryColumnMetric: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string(title))
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

struct SnapshotArchiveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @State private var pendingDeletionSnapshot: AssetSnapshot?

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            if snapshots.isEmpty {
                EmptyStateCard(
                    title: AppLocalization.string("暂无记录"),
                    systemImage: "calendar.badge.plus"
                )
                .padding(.horizontal, 20)
            } else {
                List {
                    ForEach(snapshots) { snapshot in
                        NavigationLink {
                            SnapshotDetailView(snapshot: snapshot)
                        } label: {
                            SnapshotArchiveRow(snapshot: snapshot)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                pendingDeletionSnapshot = snapshot
                            } label: {
                                Label(AppLocalization.string("删除"), systemImage: "trash")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(AssetTheme.surface.opacity(0.94))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .alert(
            AppLocalization.string("确认删除这条记录？"),
            isPresented: Binding(
                get: { pendingDeletionSnapshot != nil },
                set: { if !$0 { pendingDeletionSnapshot = nil } }
            ),
            presenting: pendingDeletionSnapshot
        ) { snapshot in
            Button(AppLocalization.string("取消"), role: .cancel) {
                pendingDeletionSnapshot = nil
            }
            Button(AppLocalization.string("删除"), role: .destructive) {
                delete(snapshot: snapshot)
                pendingDeletionSnapshot = nil
            }
        } message: { snapshot in
            Text(AppLocalization.format(
                AppLocalization.string("将删除 %@ 的资产记录，删除后无法恢复。"),
                snapshot.date.longDateString
            ))
        }
    }

    @MainActor
    private func delete(snapshot: AssetSnapshot) {
        do {
            modelContext.delete(snapshot)
            try modelContext.save()
        } catch {
            print("[AssetTimeMachine] delete snapshot failed: \(error)")
        }
    }
}

struct SnapshotArchiveRow: View {
    let snapshot: AssetSnapshot

    var body: some View {
        let metrics = PortfolioCalculator.metrics(for: snapshot)

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.date.longDateString)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)

                Text(AppLocalization.format("%d 项 · 负债 %@", snapshot.entries.count, metrics.totalLiabilities.currencyString()))
                    .font(.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(metrics.netAssets.currencyString())
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AssetTheme.goldSoft)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.vertical, 2)
    }
}

struct SnapshotDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: AssetSnapshot
    @State private var editingEntry: AssetEntry?

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
                            CompactStat(title: AppLocalization.string("资产"), value: PortfolioCalculator.totalAssets(for: snapshot).currencyString(), accent: AssetTheme.gold)
                            CompactStat(title: AppLocalization.string("负债"), value: PortfolioCalculator.totalLiabilities(for: snapshot).currencyString(), accent: AssetTheme.negative)
                        }
                    }
                    .atmCardStyle()

                    ForEach(groupedEntries, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(section.group.displayName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(AssetTheme.textPrimary)

                            ForEach(section.entries) { entry in
                                Button {
                                    editingEntry = entry
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(AppLocalization.string(entry.item?.name ?? "未命名"))
                                                .font(.headline)
                                                .foregroundStyle(AssetTheme.textPrimary)

                                            if let quantity = entry.quantity, let unitPrice = entry.unitPrice {
                                                Text("\(quantity.plainNumberString()) × \(unitPrice.plainNumberString())")
                                                    .font(.footnote)
                                                    .foregroundStyle(AssetTheme.textSecondary)
                                            } else {
                                                Text(AppLocalization.string("点按编辑这条历史记录"))
                                                    .font(.footnote)
                                                    .foregroundStyle(AssetTheme.textSecondary)
                                            }
                                        }

                                        Spacer()

                                        VStack(alignment: .trailing, spacing: 6) {
                                            Text(entry.resolvedAmount.currencyString())
                                                .font(.headline.weight(.semibold))
                                                .foregroundStyle(section.group == .liability ? AssetTheme.negative : AssetTheme.goldSoft)
                                            Image(systemName: "pencil")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(AssetTheme.textSecondary)
                                        }
                                        .monospacedDigit()
                                        .lineLimit(1)
                                    }
                                    .padding(14)
                                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
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
        .sheet(item: $editingEntry) { entry in
            SnapshotEntryEditSheet(entry: entry)
        }
    }
}

enum SnapshotEntryEditField: Hashable {
    case amount
    case quantity
    case unitPrice
}

struct SnapshotEntryEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let entry: AssetEntry

    @State private var amountText: String
    @State private var quantityText: String
    @State private var unitPriceText: String
    @State private var errorMessage: String?
    @FocusState private var focusedField: SnapshotEntryEditField?

    init(entry: AssetEntry) {
        self.entry = entry
        _amountText = State(initialValue: entry.amount?.plainNumberString() ?? "")
        _quantityText = State(initialValue: entry.quantity?.plainNumberString() ?? "")
        _unitPriceText = State(initialValue: entry.unitPrice?.plainNumberString() ?? "")
    }

    private var item: AssetItem? {
        entry.item
    }

    private var itemName: String {
        AppLocalization.string(item?.name ?? "未命名")
    }

    private var isLiability: Bool {
        item?.category?.group == .liability
    }

    private var usesQuantityAndUnitPrice: Bool {
        item?.valuationMethod == .quantityAndUnitPrice
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            if let item {
                                AssetItemGlyph(item: item, accent: isLiability ? AssetTheme.negative : AssetTheme.gold, size: 20)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(itemName)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(AssetTheme.textPrimary)
                                if let snapshotDate = entry.snapshot?.date {
                                    Text(snapshotDate.longDateString)
                                        .font(.footnote)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                            }
                        }
                        .atmCardStyle()

                        VStack(alignment: .leading, spacing: 14) {
                            if usesQuantityAndUnitPrice {
                                editField(
                                    title: AppLocalization.string("数量"),
                                    text: $quantityText,
                                    placeholder: AppLocalization.string("输入数量"),
                                    focus: .quantity
                                )
                                editField(
                                    title: AppLocalization.string("单价"),
                                    text: $unitPriceText,
                                    placeholder: AppLocalization.string("输入单价"),
                                    focus: .unitPrice
                                )
                            } else {
                                editField(
                                    title: AppLocalization.string(isLiability ? "负债数额" : "资产数额"),
                                    text: $amountText,
                                    placeholder: AppLocalization.string("输入金额"),
                                    focus: .amount
                                )
                            }

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(AssetTheme.negative)
                            }
                        }
                        .atmCardStyle()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 48)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("编辑历史记录"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("保存")) {
                        save()
                    }
                    .foregroundStyle(AssetTheme.gold)
                }
            }
            .task {
                await Task.yield()
                focusedField = usesQuantityAndUnitPrice ? .quantity : .amount
            }
        }
    }

    private func editField(title: String, text: Binding<String>, placeholder: String, focus: SnapshotEntryEditField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                .foregroundStyle(AssetTheme.textPrimary)
                .focused($focusedField, equals: focus)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(AssetTheme.overlayMedium, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @MainActor
    private func save() {
        guard let item = entry.item,
              let snapshot = entry.snapshot else {
            errorMessage = AppLocalization.string("记录数据不完整，暂时无法保存")
            return
        }

        do {
            if usesQuantityAndUnitPrice {
                try SnapshotService.upsertEntry(
                    snapshot: snapshot,
                    item: item,
                    quantity: try validatedNumber(from: quantityText, fieldName: AppLocalization.string("数量")),
                    unitPrice: try validatedNumber(from: unitPriceText, fieldName: AppLocalization.string("单价")),
                    in: modelContext
                )
            } else {
                let amount = try validatedNumber(
                    from: amountText,
                    forcePositive: isLiability,
                    fieldName: AppLocalization.string(isLiability ? "负债数额" : "资产数额")
                )
                try SnapshotService.upsertEntry(snapshot: snapshot, item: item, amount: amount, in: modelContext)
            }
            dismiss()
        } catch let error as QuickRecordValueValidationError {
            errorMessage = error.message
        } catch {
            errorMessage = AppLocalization.string("保存失败，请稍后再试")
            print("[AssetTimeMachine] update historical entry failed: \(error)")
        }
    }

    private func validatedNumber(from text: String, forcePositive: Bool = false, fieldName: String) throws -> Double? {
        try validatedQuickRecordNumber(from: text, forcePositive: forcePositive, fieldName: fieldName)
    }
}
