import SwiftUI
import SwiftData
import Charts
import UIKit
import Combine

import UniformTypeIdentifiers

struct SnapshotListLayout {
    let nonLiabilityCategoryItems: [SnapshotCategoryItems]
    let liabilityCategoryItems: [SnapshotCategoryItems]
    let displayEntriesByItemID: [UUID: AssetEntry]
    let displayedTotalAssets: Double
    let displayedTotalLiabilities: Double
    let displayedNetAssets: Double
    let onboardingInputTargetCategoryID: UUID?
}

enum SnapshotRecordLayoutBuilder {
    private static var liabilitySectionTitleMap: [String: String] { [
        AppLocalization.string("长期负债"): AppLocalization.string("长期负债"),
        AppLocalization.string("短期负债"): AppLocalization.string("短期负债")
    ] }

    static func categoryItemGroups(
        from categories: [AssetCategory],
        includingSnapshotItems snapshotItems: [AssetItem] = []
    ) -> (nonLiability: [SnapshotCategoryItems], liability: [SnapshotCategoryItems]) {
        let snapshotItemIDs = Set(snapshotItems.map(\.id))
        let categoryItems = categories.compactMap { category -> SnapshotCategoryItems? in
            let items = sortedRecordItems(in: category, includingSnapshotItemIDs: snapshotItemIDs)
            guard !items.isEmpty else { return nil }
            return SnapshotCategoryItems(category: category, items: items)
        }

        let nonLiability = categoryItems
            .filter { $0.category.group != .liability }
            .sorted {
                if $0.category.group.sortPriority == $1.category.group.sortPriority {
                    return $0.category.createdAt < $1.category.createdAt
                }
                return $0.category.group.sortPriority < $1.category.group.sortPriority
            }

        let liability = categoryItems
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

    private static func sortedRecordItems(
        in category: AssetCategory,
        includingSnapshotItemIDs snapshotItemIDs: Set<UUID>
    ) -> [AssetItem] {
        category.items
            .filter { item in item.isActive || snapshotItemIDs.contains(item.id) }
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.sortOrder < rhs.sortOrder
            }
    }

    static func make(
        snapshot: AssetSnapshot,
        categories: [AssetCategory],
        includeInactiveSnapshotItems: Bool = false
    ) -> SnapshotListLayout {
        let snapshotEntriesByItemID: [UUID: AssetEntry] = snapshot.entries.reduce(into: [:]) { result, entry in
            guard let itemID = entry.item?.id else { return }
            if let existing = result[itemID], existing.updatedAt > entry.updatedAt {
                return
            }
            result[itemID] = entry
        }
        let snapshotItems = includeInactiveSnapshotItems
            ? snapshot.entries.compactMap(\.item)
            : []
        let categoryGroups = categoryItemGroups(from: categories, includingSnapshotItems: snapshotItems)
        let nonLiabilityCategoryItems = categoryGroups.nonLiability
        let liabilityCategoryItems = categoryGroups.liability
        let nonLiabilityItemGroups = nonLiabilityCategoryItems.map(\.items)
        let liabilityItemGroups = liabilityCategoryItems.map(\.items)
        let displayEntriesByItemID = snapshotEntriesByItemID
        let displayedTotalAssets = displayedTotalAmount(
            for: nonLiabilityItemGroups,
            entriesByItemID: displayEntriesByItemID
        )
        let displayedTotalLiabilities = displayedTotalAmount(
            for: liabilityItemGroups,
            entriesByItemID: displayEntriesByItemID
        )

        return SnapshotListLayout(
            nonLiabilityCategoryItems: nonLiabilityCategoryItems,
            liabilityCategoryItems: liabilityCategoryItems,
            displayEntriesByItemID: displayEntriesByItemID,
            displayedTotalAssets: displayedTotalAssets,
            displayedTotalLiabilities: displayedTotalLiabilities,
            displayedNetAssets: displayedTotalAssets - displayedTotalLiabilities,
            onboardingInputTargetCategoryID: nonLiabilityCategoryItems.first?.id
        )
    }

    private static func displayedTotalAmount(for itemGroups: [[AssetItem]], entriesByItemID: [UUID: AssetEntry]) -> Double {
        itemGroups
            .flatMap { $0 }
            .reduce(0) { partialResult, item in
                partialResult + (entriesByItemID[item.id]?.resolvedAmount ?? 0)
            }
    }

}

struct SnapshotListView: View {
    private struct PendingPersistDraft {
        let snapshotID: UUID
        let itemID: UUID
        let amountInput: String?
        let quantityInput: String?
        let unitPriceInput: String?
    }

    @Environment(\.modelContext) private var modelContext
    let marketStore: RemoteMarketStore
    let isActive: Bool
    let onboardingActiveAnchorID: OnboardingAnchorID?

    init(
        marketStore: RemoteMarketStore,
        isActive: Bool,
        onboardingActiveAnchorID: OnboardingAnchorID?
    ) {
        self.marketStore = marketStore
        self.isActive = isActive
        self.onboardingActiveAnchorID = onboardingActiveAnchorID

        var snapshotDescriptor = FetchDescriptor<AssetSnapshot>(
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .reverse)]
        )
        snapshotDescriptor.fetchLimit = 8
        _snapshots = Query(snapshotDescriptor)
    }

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
    @State private var pendingDeletionAssetItem: AssetItem?
    @State private var assetEditorDraftID: UUID?
    @State private var quickEditingAssetItem: AssetItem?
    @State private var quickEditDraftID: UUID?
    @FocusState private var focusedField: RecordInputField?
    @State private var inlineEditingField: RecordInputField?
    @State private var inlineEditorDraftID: UUID?
    @State private var pendingAutoRateSyncTask: Task<Void, Never>?
    @State private var pendingPersistTasks: [UUID: Task<Void, Never>] = [:]
    @State private var pendingPersistDrafts: [UUID: PendingPersistDraft] = [:]
    @State private var persistGenerationByItemID: [UUID: Int] = [:]
    @State private var didDeferPersistsForCurrentTransition = false
    @State private var cachedListLayout: SnapshotListLayout?
    @State private var cachedItemsByID: [UUID: AssetItem] = [:]
    @State private var itemsByIDCacheToken: String = ""
    @State private var persistenceErrorMessage: String?
    @State private var assetDeletionErrorMessage: String?
    @State private var marketLogoRevision = 0
    @AppStorage("app.records.showsZeroBalanceAssets") private var showsZeroBalanceAssets = true

    private var currentSnapshot: AssetSnapshot? {
        if let currentSnapshotID,
           let snapshot = snapshots.first(where: { $0.id == currentSnapshotID }) {
            return snapshot
        }
        return snapshots.first(where: { Calendar.current.isDateInToday($0.date) }) ?? snapshots.first
    }

    #if DEBUG
    private var debugAutoPricedItem: AssetItem? {
        let groups = SnapshotRecordLayoutBuilder.categoryItemGroups(from: categories)
        return groups.nonLiability
            .flatMap(\.items)
            .first(where: { $0.marketAssetSymbol != nil })
        ?? groups.liability
            .flatMap(\.items)
            .first(where: { $0.marketAssetSymbol != nil })
    }

    private var forcedDebugQuickEditItem: AssetItem? {
        guard ProcessInfo.processInfo.arguments.contains("-showDebugQuickEditPreview") else { return nil }
        return debugAutoPricedItem
    }
    #endif

    private var listLayoutCacheToken: String {
        let snapshotID = currentSnapshotID?.uuidString ?? "none"
        let snapshotUpdate = currentSnapshot?.updatedAt.timeIntervalSince1970 ?? 0
        return [
            snapshotID,
            String(snapshotUpdate.bitPattern),
            String(categories.count),
            String(cachedItemsByID.count),
            String(snapshots.count)
        ].joined(separator: ":")
    }

    private var marketRefreshToken: Int {
        marketStore.liveMarketCacheToken()
    }

    private var canAutoSyncMarketRates: Bool {
        isActive && focusedField == nil && inlineEditingField == nil && quickEditingAssetItem == nil && editingAssetItem == nil
    }

    @ViewBuilder
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-previewAddAssetEditor") {
            AssetItemEditorSheet(marketStore: marketStore)
        } else if ProcessInfo.processInfo.arguments.contains("-openSnapshotArchive") {
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
        let layout = cachedListLayout

        return NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                List {
                    if let currentSnapshot = currentSnapshotValue, let layout {
                        RecordPageHero(
                            snapshot: currentSnapshot,
                            totalAssets: layout.displayedTotalAssets,
                            netAssets: layout.displayedNetAssets,
                            totalLiabilities: layout.displayedTotalLiabilities,
                            showsZeroBalanceAssets: showsZeroBalanceAssets,
                            onToggleZeroBalanceAssets: {
                                dismissKeyboard()
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    showsZeroBalanceAssets.toggle()
                                }
                            },
                            onAddAsset: {
                                dismissKeyboard()
                                presentAddAssetItemEditor()
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                        RecordSnapshotSections(
                            layout: layout,
                            onboardingActiveAnchorID: onboardingActiveAnchorID,
                            amountInputs: $amountInputs,
                            quantityInputs: $quantityInputs,
                            unitPriceInputs: $unitPriceInputs,
                            focusedField: $focusedField,
                            inlineEditingField: inlineEditingField,
                            onBeginInlineEdit: beginInlineEditing,
                            onEdit: { item in
                                dismissKeyboard()
                                presentAssetItemEditor(item)
                            },
                            onEditValue: { item in
                                presentQuickEdit(for: item)
                            },
                            onDelete: requestAssetItemDeletion,
                            showsZeroBalanceAssets: showsZeroBalanceAssets,
                            marketLogoRevision: marketLogoRevision
                        )
                    } else if isPreparingInitialSnapshot || !didPrepare || currentSnapshotValue != nil {
                        LoadingStateCard(title: AppLocalization.string("记录加载中"))
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        EmptyStateCard(
                            title: AppLocalization.string("暂无记录"),
                            systemImage: "calendar.badge.plus"
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    Color.clear
                        .frame(height: TabScrollLayout.keyboardDismissSpacer)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismissKeyboard()
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.never)
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(AppLocalization.string("完成")) {
                        dismissKeyboard()
                    }
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.gold)
                }
            }
        }
        .toolbar(quickEditingAssetItem == nil ? .visible : .hidden, for: .tabBar)
        .sheet(isPresented: $showsAddAssetItemSheet, onDismiss: finishAssetEditorDraft) {
            AssetItemEditorSheet(snapshot: currentSnapshot, marketStore: marketStore)
        }
        .sheet(item: $editingAssetItem, onDismiss: finishAssetEditorDraft) { item in
            AssetItemEditorSheet(snapshot: currentSnapshot, marketStore: marketStore, editingItem: item)
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
                            finishQuickEditDraft()
                            quickEditingAssetItem = nil
                        }

                    VStack(spacing: 0) {
                        Spacer(minLength: 0)

                        QuickRecordValueSheet(
                            item: item,
                            snapshot: currentSnapshot,
                            marketStore: marketStore,
                            onCancel: {
                                dismissKeyboard()
                                finishQuickEditDraft()
                                quickEditingAssetItem = nil
                            },
                            onSaved: {
                                if let snapshot = currentSnapshot {
                                    hydrateInputs(for: item, from: snapshot)
                                }
                                dismissKeyboard()
                                finishQuickEditDraft()
                                quickEditingAssetItem = nil
                            }
                        )
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.92), value: quickEditingAssetItem?.id)
        .onChange(of: listLayoutCacheToken) { _, _ in
            refreshCachedListLayout()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { notification in
            guard isActive, PortfolioSaveNotificationFilter.affectsPortfolio(notification) else { return }
            Task { @MainActor in
                await Task.yield()
                guard isActive else { return }
                refreshCachedListLayout()
            }
        }
        .task(id: isActive) {
            guard isActive else {
                pendingAutoRateSyncTask?.cancel()
                pendingAutoRateSyncTask = nil
                deferPendingPersistsForTransition()
                return
            }

            didDeferPersistsForCurrentTransition = false
            // ContentView activates feature work after the tab transition completes.
            // Keep SwiftData normalization and layout hydration outside that transition.
            await Task.yield()
            guard !Task.isCancelled, isActive else { return }
            await prepareSnapshotIfNeeded()
            guard !Task.isCancelled, isActive else { return }
            refreshCachedListLayout()
            await marketStore.refreshAssetCatalogIfNeeded()
            guard !Task.isCancelled, isActive else { return }
            marketLogoRevision &+= 1
            #if DEBUG
            await ensureDebugAutoPricedItemIfNeeded()
            if ProcessInfo.processInfo.arguments.contains("-openFirstAutoPricedQuickEdit"),
               let debugAutoPricedItem,
               quickEditingAssetItem == nil {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, isActive else { return }
                presentQuickEdit(for: debugAutoPricedItem)
            }
            #endif
            scheduleAutoRateSync(delayNanoseconds: 180_000_000)
        }
        .onDisappear {
            pendingAutoRateSyncTask?.cancel()
            pendingAutoRateSyncTask = nil
            deferPendingPersistsForTransition()
            finishInlineEditorDraft()
            finishAssetEditorDraft()
            finishQuickEditDraft()
        }
        #if DEBUG
        .task(id: debugAutoPricedItem?.id) {
            guard isActive else { return }
            await ensureDebugAutoPricedItemIfNeeded()
            guard ProcessInfo.processInfo.arguments.contains("-openFirstAutoPricedQuickEdit"),
                  quickEditingAssetItem == nil,
                  let debugAutoPricedItem else { return }
            try? await Task.sleep(for: .milliseconds(250))
            presentQuickEdit(for: debugAutoPricedItem)
        }
        #endif
        .onChange(of: isActive ? marketRefreshToken : 0) { _, _ in
            guard canAutoSyncMarketRates else { return }
            scheduleAutoRateSync(delayNanoseconds: 300_000_000)
        }
        .onReceive(marketStore.$overview.combineLatest(marketStore.$exchangeRates).dropFirst()) { _ in
            guard canAutoSyncMarketRates else { return }
            scheduleAutoRateSync(delayNanoseconds: 300_000_000)
        }
        .onChange(of: focusedField) { previousField, newField in
            if let newField {
                _ = beginInlineEditorDraft()
                inlineEditingField = newField
            }
            if newField != nil {
                pendingAutoRateSyncTask?.cancel()
            }
            if let previousField, previousField != newField,
               let item = item(for: previousField) {
                schedulePersist(item: item)
            }
            if newField == nil {
                finishInlineEditorDraft()
            }
        }
        .alert(AppLocalization.string("保存失败"), isPresented: Binding(
            get: { persistenceErrorMessage != nil },
            set: { if !$0 { persistenceErrorMessage = nil } }
        )) {
            Button(AppLocalization.string("知道了"), role: .cancel) {}
        } message: {
            Text(persistenceErrorMessage ?? AppLocalization.string("请稍后再试"))
        }
        .alert(
            AppLocalization.string("确认删除资产？"),
            isPresented: Binding(
                get: { pendingDeletionAssetItem != nil },
                set: { if !$0 { pendingDeletionAssetItem = nil } }
            ),
            presenting: pendingDeletionAssetItem
        ) { item in
            Button(AppLocalization.string("取消"), role: .cancel) {
                pendingDeletionAssetItem = nil
            }
            Button(AppLocalization.string("删除"), role: .destructive) {
                deleteAssetItem(item)
            }
        } message: { item in
            Text(AppLocalization.format(
                "将删除“%@”及其所有历史记录，此操作无法撤销。",
                item.name
            ))
        }
        .alert(AppLocalization.string("删除失败"), isPresented: Binding(
            get: { assetDeletionErrorMessage != nil },
            set: { if !$0 { assetDeletionErrorMessage = nil } }
        )) {
            Button(AppLocalization.string("知道了"), role: .cancel) {}
        } message: {
            Text(assetDeletionErrorMessage ?? AppLocalization.string("请稍后再试"))
        }
    }

    @MainActor
    private func schedulePersist(item: AssetItem, delayNanoseconds: UInt64 = 80_000_000) {
        guard let draft = pendingPersistDraft(for: item) else { return }
        let effectiveDelay = isActive
            ? delayNanoseconds
            : max(delayNanoseconds, 360_000_000)
        schedulePersist(draft: draft, delayNanoseconds: effectiveDelay)
    }

    @MainActor
    private func schedulePersist(draft: PendingPersistDraft, delayNanoseconds: UInt64) {
        let itemID = draft.itemID
        pendingPersistTasks[itemID]?.cancel()
        let generation = (persistGenerationByItemID[itemID] ?? 0) &+ 1
        persistGenerationByItemID[itemID] = generation
        pendingPersistDrafts[itemID] = draft
        let writeID = ModelContextMutationBarrier.shared.beginDeferredWrite()

        pendingPersistTasks[itemID] = Task {
            defer { ModelContextMutationBarrier.shared.finishDeferredWrite(writeID) }
            do {
                try await ModelContextMutationBarrier.shared.waitUntilWriteIsAllowed(writeID)
            } catch {
                return
            }
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            persist(draft: draft)
            if persistGenerationByItemID[itemID] == generation {
                pendingPersistTasks[itemID] = nil
                pendingPersistDrafts[itemID] = nil
                persistGenerationByItemID[itemID] = nil
            }
        }
    }

    @MainActor
    private func deferPendingPersistsForTransition() {
        guard !didDeferPersistsForCurrentTransition else { return }
        didDeferPersistsForCurrentTransition = true

        var drafts = pendingPersistDrafts
        if let editingField = focusedField ?? inlineEditingField,
           let item = item(for: editingField),
           let draft = pendingPersistDraft(for: item) {
            drafts[item.id] = draft
        }

        pendingPersistTasks.values.forEach { $0.cancel() }
        pendingPersistTasks.removeAll()
        pendingPersistDrafts.removeAll()

        for draft in drafts.values {
            schedulePersist(draft: draft, delayNanoseconds: 360_000_000)
        }
    }

    @MainActor
    private func pendingPersistDraft(for item: AssetItem) -> PendingPersistDraft? {
        guard let snapshot = currentSnapshot else { return nil }
        return PendingPersistDraft(
            snapshotID: snapshot.id,
            itemID: item.id,
            amountInput: amountInputs[item.id],
            quantityInput: quantityInputs[item.id],
            unitPriceInput: unitPriceInputs[item.id]
        )
    }

    @MainActor
    private func presentAddAssetItemEditor() {
        guard beginAssetEditorDraft() else { return }
        showsAddAssetItemSheet = true
    }

    @MainActor
    private func presentAssetItemEditor(_ item: AssetItem) {
        guard beginAssetEditorDraft() else { return }
        editingAssetItem = item
    }

    @MainActor
    private func requestAssetItemDeletion(_ item: AssetItem) {
        dismissKeyboard()
        pendingDeletionAssetItem = item
    }

    @MainActor
    private func deleteAssetItem(_ item: AssetItem) {
        let itemID = item.id
        pendingDeletionAssetItem = nil
        pendingPersistTasks[itemID]?.cancel()
        pendingPersistTasks[itemID] = nil
        pendingPersistDrafts[itemID] = nil
        persistGenerationByItemID[itemID] = nil

        let writeID = ModelContextMutationBarrier.shared.beginDeferredWrite()
        Task { @MainActor in
            defer { ModelContextMutationBarrier.shared.finishDeferredWrite(writeID) }
            do {
                try await ModelContextMutationBarrier.shared.waitUntilWriteIsAllowed(writeID)

                var descriptor = FetchDescriptor<AssetItem>(
                    predicate: #Predicate<AssetItem> { candidate in
                        candidate.id == itemID
                    }
                )
                descriptor.fetchLimit = 1
                guard let storedItem = try modelContext.fetch(descriptor).first else { return }

                try AssetItemService.deleteItem(storedItem, in: modelContext)

                amountInputs[itemID] = nil
                quantityInputs[itemID] = nil
                unitPriceInputs[itemID] = nil
                cachedItemsByID[itemID] = nil
                itemsByIDCacheToken = ""
                refreshCachedListLayout()
            } catch is CancellationError {
                return
            } catch {
                modelContext.rollback()
                assetDeletionErrorMessage = AppLocalization.string("请稍后再试")
                print("[AssetTimeMachine] delete item from record row failed: \(error)")
            }
        }
    }

    @MainActor
    private func beginAssetEditorDraft() -> Bool {
        guard assetEditorDraftID == nil else { return true }
        guard let draftID = ModelContextMutationBarrier.shared.beginEditorDraft() else { return false }
        assetEditorDraftID = draftID
        return true
    }

    @MainActor
    private func finishAssetEditorDraft() {
        guard let assetEditorDraftID else { return }
        ModelContextMutationBarrier.shared.finishEditorDraft(assetEditorDraftID)
        self.assetEditorDraftID = nil
    }

    @MainActor
    private func presentQuickEdit(for item: AssetItem) {
        guard quickEditDraftID != nil || beginQuickEditDraft() else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dismissKeyboard()
            quickEditingAssetItem = item
        }
    }

    @MainActor
    @discardableResult
    private func beginQuickEditDraft() -> Bool {
        guard quickEditDraftID == nil else { return true }
        guard let draftID = ModelContextMutationBarrier.shared.beginEditorDraft() else { return false }
        quickEditDraftID = draftID
        return true
    }

    @MainActor
    private func finishQuickEditDraft() {
        guard let quickEditDraftID else { return }
        ModelContextMutationBarrier.shared.finishEditorDraft(quickEditDraftID)
        self.quickEditDraftID = nil
    }

    @MainActor
    private func refreshCachedListLayout() {
        refreshItemsByIDCache()
        cachedListLayout = buildListLayout(for: currentSnapshot)
    }

    @MainActor
    private func refreshItemsByIDCache() {
        var hasher = Hasher()
        hasher.combine(categories.count)
        for category in categories {
            hasher.combine(category.id)
            hasher.combine(category.items.count)
            if let latestItem = category.items.max(by: { $0.updatedAt < $1.updatedAt }) {
                hasher.combine(latestItem.updatedAt.timeIntervalSince1970)
            }
        }
        let token = String(hasher.finalize())
        guard token != itemsByIDCacheToken else { return }
        cachedItemsByID = categories.flatMap(\.items).reduce(into: [:]) { result, item in
            if let existing = result[item.id], existing.updatedAt > item.updatedAt {
                return
            }
            result[item.id] = item
        }
        itemsByIDCacheToken = token
    }

    private func buildListLayout(for snapshot: AssetSnapshot?) -> SnapshotListLayout? {
        guard let snapshot else { return nil }
        // Today's snapshot is created with all missing entries populated. Avoid walking
        // every item's full inverse-entry history while rendering the editable record page.
        return SnapshotRecordLayoutBuilder.make(
            snapshot: snapshot,
            categories: categories
        )
    }

    @MainActor
    private func beginInlineEditing(_ field: RecordInputField) {
        guard beginInlineEditorDraft() else { return }
        inlineEditingField = field
        Task { @MainActor in
            guard inlineEditingField == field else { return }
            focusedField = field
        }
    }

    @MainActor
    private func beginInlineEditorDraft() -> Bool {
        guard inlineEditorDraftID == nil else { return true }
        guard let draftID = ModelContextMutationBarrier.shared.beginEditorDraft() else { return false }
        inlineEditorDraftID = draftID
        return true
    }

    @MainActor
    private func finishInlineEditorDraft() {
        guard let inlineEditorDraftID else { return }
        ModelContextMutationBarrier.shared.finishEditorDraft(inlineEditorDraftID)
        self.inlineEditorDraftID = nil
    }

    @MainActor
    private func dismissKeyboard() {
        inlineEditingField = nil
        focusedField = nil
    }

    private func item(for field: RecordInputField) -> AssetItem? {
        let itemID: UUID
        switch field {
        case let .amount(id), let .quantity(id), let .unitPrice(id):
            itemID = id
        }
        return cachedItemsByID[itemID]
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
            if currentSnapshotID == nil {
                currentSnapshotID = snapshot.id
                hydrateInputs(from: snapshot)
            }
            refreshCachedListLayout()
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
                presentQuickEdit(for: debugAutoPricedItem)
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
                presentQuickEdit(for: item)
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
        let writeID = ModelContextMutationBarrier.shared.beginDeferredWrite()
        pendingAutoRateSyncTask = Task {
            defer { ModelContextMutationBarrier.shared.finishDeferredWrite(writeID) }
            do {
                try await ModelContextMutationBarrier.shared.waitUntilWriteIsAllowed(writeID)
            } catch {
                return
            }
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
            entry.item?.autoPricedMarketSymbol != nil
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
                refreshCachedListLayout()
                await SnapshotAnchorService.captureLiveAnchorsIfPossible(for: snapshot, marketStore: marketStore, in: modelContext)
            } catch {
                print("[AssetTimeMachine] sync auto rate failed: \(error)")
            }
        }
    }

    @MainActor
    private func persist(draft: PendingPersistDraft) {
        do {
            let snapshotID = draft.snapshotID
            var snapshotDescriptor = FetchDescriptor<AssetSnapshot>(
                predicate: #Predicate<AssetSnapshot> { snapshot in
                    snapshot.id == snapshotID
                }
            )
            snapshotDescriptor.fetchLimit = 1

            let itemID = draft.itemID
            var itemDescriptor = FetchDescriptor<AssetItem>(
                predicate: #Predicate<AssetItem> { item in
                    item.id == itemID
                }
            )
            itemDescriptor.fetchLimit = 1

            guard let snapshot = try modelContext.fetch(snapshotDescriptor).first,
                  let item = try modelContext.fetch(itemDescriptor).first else {
                print("[AssetTimeMachine] skip deferred entry persist because its snapshot or item no longer exists")
                return
            }

            switch item.valuationMethod {
            case .directAmount:
                let amount = normalizedNumber(from: draft.amountInput, forcePositive: item.category?.group == .liability)
                try SnapshotService.upsertEntry(snapshot: snapshot, item: item, amount: amount, in: modelContext)
            case .quantityAndUnitPrice:
                let quantity = normalizedNumber(from: draft.quantityInput)
                let autoRate = item.resolvedAutoUnitPrice(using: marketStore)
                let unitPrice = autoRate ?? normalizedNumber(from: draft.unitPriceInput)
                if let autoRate {
                    unitPriceInputs[item.id] = autoRate.plainNumberString()
                }
                try SnapshotService.upsertEntry(snapshot: snapshot, item: item, quantity: quantity, unitPrice: unitPrice, in: modelContext)
            }
            if isActive {
                refreshCachedListLayout()
            }
        } catch {
            persistenceErrorMessage = AppLocalization.string("记录未能保存，请检查后重试。")
            print("[AssetTimeMachine] persist entry failed: \(error)")
        }
    }

    private func normalizedNumber(from text: String?, forcePositive: Bool = false) -> Double? {
        guard let raw = text?.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Double(raw),
              value.isFinite else {
            return nil
        }
        return forcePositive ? abs(value) : value
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
                .font(AppTypography.microLabel)
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))

            Text(value)
                .font(AppTypography.microValue)
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

struct RecordSnapshotSections: View {
    let layout: SnapshotListLayout
    let onboardingActiveAnchorID: OnboardingAnchorID?
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    @Binding var unitPriceInputs: [UUID: String]
    @FocusState.Binding var focusedField: RecordInputField?
    let inlineEditingField: RecordInputField?
    let onBeginInlineEdit: (RecordInputField) -> Void
    let onEdit: (AssetItem) -> Void
    let onEditValue: (AssetItem) -> Void
    var onDelete: ((AssetItem) -> Void)? = nil
    var showsZeroBalanceAssets: Bool = true
    var marketLogoRevision: Int = 0
    var isReadOnly: Bool = false
    var onReadOnlyEdit: ((AssetEntry) -> Void)? = nil

    private func visibleItems(in items: [AssetItem]) -> [AssetItem] {
        guard !showsZeroBalanceAssets else { return items }
        return items.filter { item in
            abs(layout.displayEntriesByItemID[item.id]?.resolvedAmount ?? 0) > 0.000_001
        }
    }

    var body: some View {
        let _ = marketLogoRevision
        ForEach(layout.nonLiabilityCategoryItems) { categoryItems in
            let items = visibleItems(in: categoryItems.items)
            if !items.isEmpty {
                RecordLedgerSection(
                    category: categoryItems.category,
                    items: items,
                    snapshotEntriesByItemID: layout.displayEntriesByItemID,
                    onboardingInputItemID: categoryItems.id == layout.onboardingInputTargetCategoryID ? items.first?.id : nil,
                    onboardingActiveAnchorID: onboardingActiveAnchorID,
                    amountInputs: $amountInputs,
                    quantityInputs: $quantityInputs,
                    unitPriceInputs: $unitPriceInputs,
                    focusedField: $focusedField,
                    inlineEditingField: inlineEditingField,
                    onBeginInlineEdit: onBeginInlineEdit,
                    onEdit: onEdit,
                    onEditValue: onEditValue,
                    onDelete: onDelete,
                    isReadOnly: isReadOnly,
                    onReadOnlyEdit: onReadOnlyEdit
                )
            }
        }

        ForEach(layout.liabilityCategoryItems) { categoryItems in
            let items = visibleItems(in: categoryItems.items)
            if !items.isEmpty {
                RecordLedgerSection(
                    category: categoryItems.category,
                    items: items,
                    snapshotEntriesByItemID: layout.displayEntriesByItemID,
                    onboardingInputItemID: nil,
                    onboardingActiveAnchorID: onboardingActiveAnchorID,
                    amountInputs: $amountInputs,
                    quantityInputs: $quantityInputs,
                    unitPriceInputs: $unitPriceInputs,
                    focusedField: $focusedField,
                    inlineEditingField: inlineEditingField,
                    onBeginInlineEdit: onBeginInlineEdit,
                    onEdit: onEdit,
                    onEditValue: onEditValue,
                    onDelete: onDelete,
                    isReadOnly: isReadOnly,
                    onReadOnlyEdit: onReadOnlyEdit
                )
            }
        }
    }
}

struct RecordPageHero: View {
    let snapshot: AssetSnapshot
    let totalAssets: Double
    let netAssets: Double
    let totalLiabilities: Double
    var showsActionChips: Bool = true
    var showsZeroBalanceAssets: Bool = true
    var onToggleZeroBalanceAssets: () -> Void = {}
    let onAddAsset: () -> Void

    private var netAssetColor: Color {
        netAssets < 0 ? AssetTheme.negative : AssetTheme.textPrimary
    }

    private var totalAssetText: Text {
        let amount = totalAssets.currencyString()
        guard let dotIndex = amount.lastIndex(of: ".") else {
            return Text(amount)
                .font(AppTypography.pageHero)
        }

        let major = String(amount[..<dotIndex])
        let minor = String(amount[dotIndex...])
        return Text(major)
            .font(AppTypography.pageHero)
        + Text(minor)
            .font(AppTypography.pageHeroMinor)
            .baselineOffset(1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Text(AppLocalization.string("记录"))
                    .font(.system(size: 22, weight: .semibold, design: .default))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 12)

                if showsActionChips {
                    HStack(spacing: 4) {
                        Button(action: onToggleZeroBalanceAssets) {
                            Image(systemName: showsZeroBalanceAssets ? "eye" : "eye.slash")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(showsZeroBalanceAssets ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                                .frame(width: 36, height: 36)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLocalization.string(
                            showsZeroBalanceAssets ? "隐藏零资产" : "显示零资产"
                        ))

                        NavigationLink {
                            SnapshotArchiveView()
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(AssetTheme.goldSoft)
                                .frame(width: 36, height: 36)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLocalization.string("历史记录"))

                        Button(action: onAddAsset) {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(AssetTheme.goldSoft)
                                .frame(width: 36, height: 36)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLocalization.string("新增资产"))
                        .onboardingAnchor(.recordsAddAsset)
                    }
                }
            }

            Text(AppLocalization.string("总资产"))
                .font(AppTypography.fieldLabel)
                .tracking(0.2)
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.92))

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

            HStack(alignment: .top, spacing: 12) {
                RecordHeroMetric(
                    title: AppLocalization.string("净资产"),
                    value: netAssets.currencyString(),
                    valueColor: netAssetColor
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                RecordHeroMetric(
                    title: AppLocalization.string("负债"),
                    value: totalLiabilities.currencyString(),
                    valueColor: AssetTheme.negative.opacity(0.94)
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                RecordHeroMetric(
                    title: AppLocalization.string("日期"),
                    value: snapshot.date.recordDateString,
                    valueColor: AssetTheme.textPrimary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .padding(.top, 6)
        }
        .padding(.bottom, 2)
    }
}

struct AssetItemGlyph: View {
    let item: AssetItem
    var accent: Color = AssetTheme.goldSoft
    var size: CGFloat = 11

    private var resolvedIconKey: String {
        AssetItemService.resolvedIconKey(for: item)
    }

    private var marketAssetSectionID: String {
        let parts = resolvedIconKey.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 3 ? parts[1] : "other"
    }

    var body: some View {
        if let symbol = item.marketAssetSymbol, resolvedIconKey.hasPrefix("market_asset|") {
            MarketAssetLogoView(
                symbol: symbol,
                sectionID: marketAssetSectionID,
                title: item.name,
                size: size + 7
            )
        } else {
            Image(systemName: AssetItemService.displaySymbolName(for: item))
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: size + 3, height: size + 3)
        }
    }
}

struct RecordEntryGlyph: View {
    let item: AssetItem
    let tint: Color
    var glyphSize: CGFloat = 10

    var body: some View {
        if item.marketAssetSymbol != nil {
            AssetItemGlyph(item: item, accent: tint, size: 16)
                .frame(width: 32, height: 32)
        } else {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                AssetItemGlyph(item: item, accent: tint, size: 13)
            }
            .frame(width: 32, height: 32)
        }
    }
}

struct RecordSectionHeader: View {
    let title: String
    let amount: String
    var amountColor: Color = AssetTheme.textPrimary
    var accent: Color = AssetTheme.goldSoft

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(AppLocalization.string(title))
                .font(AppTypography.blockTitle)
                .foregroundStyle(accent)
                .lineLimit(2)

            Rectangle()
                .fill(accent.opacity(0.34))
                .frame(maxWidth: .infinity)
                .frame(height: 1)

            Text(amount)
                .font(AppTypography.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(amountColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }
}

struct RecordLedgerSection: View {
    let category: AssetCategory
    let items: [AssetItem]
    let snapshotEntriesByItemID: [UUID: AssetEntry]
    let onboardingInputItemID: UUID?
    let onboardingActiveAnchorID: OnboardingAnchorID?
    @Binding var amountInputs: [UUID: String]
    @Binding var quantityInputs: [UUID: String]
    @Binding var unitPriceInputs: [UUID: String]
    @FocusState.Binding var focusedField: RecordInputField?
    let inlineEditingField: RecordInputField?
    let onBeginInlineEdit: (RecordInputField) -> Void
    let onEdit: (AssetItem) -> Void
    let onEditValue: (AssetItem) -> Void
    var onDelete: ((AssetItem) -> Void)? = nil
    var isReadOnly: Bool = false
    var onReadOnlyEdit: ((AssetEntry) -> Void)? = nil
    @State private var draggedItemID: UUID?

    private var accent: Color {
        switch category.group {
        case .financial: AssetTheme.positive
        case .physical: AssetTheme.accentBlue
        case .liability: AssetTheme.negative
        }
    }

    private var categoryTotal: Double {
        items.reduce(0) { result, item in
            result + (snapshotEntriesByItemID[item.id]?.resolvedAmount ?? 0)
        }
    }

    var body: some View {
        Section {
            ForEach(items) { item in
                ReorderableRecordCell(
                    category: category,
                    item: item,
                    draggedItemID: $draggedItemID,
                    allowsReorder: !isReadOnly
                ) {
                    RecordLedgerRow(
                        item: item,
                        snapshotEntry: snapshotEntriesByItemID[item.id],
                        amountText: Binding(
                            get: { amountInputs[item.id] ?? "" },
                            set: { amountInputs[item.id] = $0 }
                        ),
                        quantityText: Binding(
                            get: { quantityInputs[item.id] ?? "" },
                            set: { quantityInputs[item.id] = $0 }
                        ),
                        unitPriceText: Binding(
                            get: { unitPriceInputs[item.id] ?? "" },
                            set: { unitPriceInputs[item.id] = $0 }
                        ),
                        focusedField: $focusedField,
                        inlineEditingField: inlineEditingField,
                        onBeginInlineEdit: onBeginInlineEdit,
                        accent: accent,
                        isOnboardingTarget: item.id == onboardingInputItemID,
                        showsOnboardingInputPreview: onboardingActiveAnchorID == .recordsFirstInput
                            && item.id == onboardingInputItemID,
                        onEdit: { onEdit(item) },
                        onEditValue: { onEditValue(item) },
                        isReadOnly: isReadOnly,
                        onReadOnlyEdit: onReadOnlyEdit
                    )
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(AssetTheme.border.opacity(0.38))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !isReadOnly, let onDelete {
                        Button(role: .destructive) {
                            onDelete(item)
                        } label: {
                            Label(AppLocalization.string("删除"), systemImage: "trash")
                        }

                        Button {
                            onEdit(item)
                        } label: {
                            Label(AppLocalization.string("编辑"), systemImage: "pencil")
                        }
                        .tint(AssetTheme.accentBlue)
                    }
                }
            }
        } header: {
            RecordSectionHeader(
                title: category.name,
                amount: categoryTotal.currencyString(),
                amountColor: category.group == .liability ? AssetTheme.negative : AssetTheme.textPrimary,
                accent: accent
            )
            .textCase(nil)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .listSectionSpacing(8)
    }
}

struct RecordLedgerRow: View {
    let item: AssetItem
    let snapshotEntry: AssetEntry?
    @Binding var amountText: String
    @Binding var quantityText: String
    @Binding var unitPriceText: String
    @FocusState.Binding var focusedField: RecordInputField?
    let inlineEditingField: RecordInputField?
    let onBeginInlineEdit: (RecordInputField) -> Void
    let accent: Color
    let isOnboardingTarget: Bool
    let showsOnboardingInputPreview: Bool
    let onEdit: () -> Void
    let onEditValue: () -> Void
    var isReadOnly: Bool = false
    var onReadOnlyEdit: ((AssetEntry) -> Void)? = nil

    private var activeField: RecordInputField {
        item.valuationMethod == .directAmount ? .amount(item.id) : .quantity(item.id)
    }

    private var isEditing: Bool {
        !isReadOnly && inlineEditingField == activeField
    }

    private var resolvedAmount: Double? {
        switch item.valuationMethod {
        case .directAmount:
            return normalizedNumber(from: amountText) ?? snapshotEntry?.amount
        case .quantityAndUnitPrice:
            guard let quantity = normalizedNumber(from: quantityText) ?? snapshotEntry?.quantity,
                  let unitPrice = normalizedNumber(from: unitPriceText) ?? snapshotEntry?.unitPrice else {
                return nil
            }
            return quantity * unitPrice
        }
    }

    private var quantityDisplayText: String? {
        guard item.valuationMethod == .quantityAndUnitPrice else { return nil }
        let value = normalizedNumber(from: quantityText) ?? snapshotEntry?.quantity
        let number = value?.plainNumberString() ?? "—"
        guard let unit = item.persistedQuantityUnitTitle, !unit.isEmpty else { return number }
        return "\(number) \(unit)"
    }

    private var hasDisplayValue: Bool {
        switch item.valuationMethod {
        case .directAmount:
            resolvedAmount != nil
        case .quantityAndUnitPrice:
            (normalizedNumber(from: quantityText) ?? snapshotEntry?.quantity) != nil
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: handleNameTap) {
                HStack(alignment: .center, spacing: 10) {
                    RecordEntryGlyph(
                        item: item,
                        tint: hasDisplayValue ? accent : AssetTheme.textSecondary,
                        glyphSize: 13
                    )

                    Text(AppLocalization.string(item.name))
                        .font(AppTypography.body)
                        .foregroundStyle(hasDisplayValue ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)

            valueControl
                .onboardingAnchorIf(isOnboardingTarget, .recordsFirstInput)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .animation(nil, value: isEditing)
    }

    @ViewBuilder
    private var valueControl: some View {
        if isEditing || showsOnboardingInputPreview {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ATMInputField(
                    text: item.valuationMethod == .directAmount ? $amountText : $quantityText,
                    placeholder: "0",
                    width: 116,
                    focusedField: $focusedField,
                    focusValue: activeField,
                    centered: false,
                    fontSize: 15.5,
                    fontWeight: .semibold,
                    height: 34,
                    backgroundOpacity: 0.035,
                    strokeOpacity: 0.12
                )
                .allowsHitTesting(isEditing)

                if item.valuationMethod == .quantityAndUnitPrice,
                   let unit = item.persistedQuantityUnitTitle,
                   !unit.isEmpty {
                    Text(unit)
                        .font(AppTypography.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
        } else {
            Button(action: handleValueTap) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(resolvedAmount?.currencyString() ?? "—")
                        .font(AppTypography.bodyStrong)
                        .monospacedDigit()
                        .foregroundStyle(item.category?.group == .liability ? AssetTheme.negative : AssetTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    if let quantityDisplayText {
                        Text(quantityDisplayText)
                            .font(AppTypography.caption)
                            .monospacedDigit()
                            .foregroundStyle(AssetTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 112, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func handleNameTap() {
        if isReadOnly, let snapshotEntry {
            onReadOnlyEdit?(snapshotEntry)
        } else {
            onEdit()
        }
    }

    private func handleValueTap() {
        if isReadOnly, let snapshotEntry {
            onReadOnlyEdit?(snapshotEntry)
        } else if item.valuationMethod == .directAmount || item.marketAssetSymbol == nil {
            onBeginInlineEdit(activeField)
        } else {
            onEditValue()
        }
    }

    private func normalizedNumber(from text: String) -> Double? {
        let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let value = Double(raw), value.isFinite else { return nil }
        return value
    }
}

struct ReorderableRecordCell<Content: View>: View {
    @Environment(\.modelContext) private var modelContext

    let category: AssetCategory
    let item: AssetItem
    @Binding var draggedItemID: UUID?
    var allowsReorder: Bool = true
    @ViewBuilder var content: Content

    init(
        category: AssetCategory,
        item: AssetItem,
        draggedItemID: Binding<UUID?>,
        allowsReorder: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.category = category
        self.item = item
        self._draggedItemID = draggedItemID
        self.allowsReorder = allowsReorder
        self.content = content()
    }

    var body: some View {
        if allowsReorder {
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
        } else {
            content
        }
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

struct ATMInputField: View {
    @Binding var text: String
    let placeholder: String
    var width: CGFloat? = nil
    @FocusState.Binding var focusedField: RecordInputField?
    let focusValue: RecordInputField
    var centered: Bool = false
    var fontSize: CGFloat = 17
    var fontWeight: Font.Weight = .medium
    var height: CGFloat = 42
    var backgroundOpacity: Double = 0.66
    var strokeOpacity: Double = 0.52

    private var resolvedFont: Font {
        if fontSize == 17, fontWeight == .medium {
            return AppTypography.inputValue
        }
        if fontSize == 15.5, fontWeight == .semibold {
            return AppTypography.bodyStrong
        }
        return .system(size: fontSize, weight: fontWeight, design: .default)
    }

    var body: some View {
        TextField(AppLocalization.string(placeholder), text: $text)
            .keyboardType(.decimalPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .multilineTextAlignment(centered ? .center : .trailing)
            .font(resolvedFont)
            .foregroundStyle(AssetTheme.textPrimary)
            .focused($focusedField, equals: focusValue)
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

private enum AddAssetItemStep: Int {
    case asset
    case details
}

private struct RecordSecurityCatalogPagingState {
    private(set) var nextPageBySection = ["etf": 2, "a_share": 2]
    private(set) var hasMoreBySection = ["etf": false, "a_share": false]

    func canLoadMore(_ sectionID: String) -> Bool {
        hasMoreBySection[sectionID] == true
    }

    func nextPage(_ sectionID: String) -> Int {
        nextPageBySection[sectionID] ?? 2
    }

    mutating func reset(hasMore: [String: Bool]) {
        nextPageBySection = ["etf": 2, "a_share": 2]
        hasMoreBySection = [
            "etf": hasMore["etf"] == true,
            "a_share": hasMore["a_share"] == true
        ]
    }

    mutating func completePage(sectionID: String, hasMore: Bool) {
        nextPageBySection[sectionID] = nextPage(sectionID) + 1
        hasMoreBySection[sectionID] = hasMore
    }
}

private struct AddAssetStepIndicator: View {
    let step: AddAssetItemStep
    let onSelectAssetStep: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelectAssetStep) {
                stepLabel(
                    number: 1,
                    title: AppLocalization.string("选择资产"),
                    isActive: step == .asset,
                    isCompleted: step == .details
                )
            }
            .buttonStyle(.plain)
            .disabled(step == .asset)

            Rectangle()
                .fill(step == .details ? AssetTheme.gold.opacity(0.72) : AssetTheme.border.opacity(0.48))
                .frame(maxWidth: 46, maxHeight: 1)

            stepLabel(
                number: 2,
                title: AppLocalization.string("资产详情"),
                isActive: step == .details,
                isCompleted: false
            )
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func stepLabel(number: Int, title: String, isActive: Bool, isCompleted: Bool) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(isActive || isCompleted ? AssetTheme.gold : AssetTheme.overlaySubtle)
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.76))
                } else {
                    Text(String(number))
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(isActive ? Color.black.opacity(0.76) : AssetTheme.textSecondary)
                }
            }
            .frame(width: 24, height: 24)

            Text(title)
                .font(AppTypography.captionStrong)
                .foregroundStyle(isActive || isCompleted ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.format("步骤 %d：%@", number, title))
    }
}

struct AssetItemEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var categories: [AssetCategory]
    let snapshot: AssetSnapshot?
    @ObservedObject var marketStore: RemoteMarketStore
    let editingItem: AssetItem?

    @State private var name = ""
    @State private var selectedCategoryID: UUID?
    @State private var selectedMarketAssetSymbol: String?
    @State private var valuationMethod: ValuationMethod = .directAmount
    @State private var selectedIconName = ""
    @State private var marketAssetSearchText = ""
    @State private var isSearchingMarketAssets = false
    @State private var marketAssetSearchMessage: String?
    @State private var recordSecurityPaging = RecordSecurityCatalogPagingState()
    @State private var loadingMoreSecuritySectionID: String?
    @State private var errorMessage: String?
    @State private var step: AddAssetItemStep = .asset
    @State private var nameWasAutofilled = false
    @State private var hasCustomizedIcon = false
    @State private var recordQuantityText = ""
    @State private var recordUnitPriceText = ""
    @State private var showsDeleteConfirmation = false
    @State private var showsMarketChangeConfirmation = false

    init(
        snapshot: AssetSnapshot? = nil,
        marketStore: RemoteMarketStore,
        editingItem: AssetItem? = nil
    ) {
        self.snapshot = snapshot
        self.marketStore = marketStore
        self.editingItem = editingItem

        guard let editingItem else { return }
        let storedIconName = (editingItem.iconName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentEntry = snapshot?.entries.first(where: { $0.item?.id == editingItem.id })
        _name = State(initialValue: editingItem.name)
        _selectedCategoryID = State(initialValue: editingItem.category?.id)
        _selectedMarketAssetSymbol = State(initialValue: editingItem.marketAssetSymbol)
        _valuationMethod = State(initialValue: editingItem.valuationMethod)
        _selectedIconName = State(initialValue: storedIconName)
        _step = State(initialValue: .details)
        _hasCustomizedIcon = State(initialValue: !storedIconName.isEmpty && !storedIconName.hasPrefix("market_asset|"))
        _recordQuantityText = State(initialValue: currentEntry?.quantity?.plainNumberString() ?? "")
        _recordUnitPriceText = State(initialValue: currentEntry?.unitPrice?.plainNumberString() ?? "")
    }

    private var isEditing: Bool { editingItem != nil }

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

    private var selectedMarketAsset: MarketAssetDescriptor? {
        selectedMarketAssetSymbol.flatMap(marketStore.assetDescriptor(for:))
    }

    private var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return selectedMarketAssetSymbol
            .flatMap(marketStore.assetDescriptor(for:))?
            .displayTitle ?? ""
    }

    private var resolvedIconName: String {
        let trimmed = selectedIconName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return AssetItemService.suggestedIconName(
            for: resolvedName,
            marketAsset: selectedMarketAssetSymbol.flatMap(marketStore.assetDescriptor(for:))
        )
    }

    private var editableName: Binding<String> {
        Binding(
            get: { name },
            set: { newValue in
                name = newValue
                nameWasAutofilled = false
            }
        )
    }

    private var displayedIconSymbolName: String {
        if let definition = AssetIconRegistry.definition(for: selectedIconName) {
            return definition.symbolName
        }
        if let selectedMarketAsset,
           selectedIconName.isEmpty || selectedIconName.hasPrefix("market_asset|") {
            return selectedMarketAsset.assetIconName
        }
        return AssetIconRegistry.symbolName(for: resolvedIconName, categoryGroup: selectedCategory?.group)
    }

    private var displayedIconColor: Color {
        if let selectedMarketAsset,
           selectedIconName.isEmpty || selectedIconName.hasPrefix("market_asset|") {
            return selectedMarketAsset.color
        }
        return AssetTheme.goldSoft
    }

    private var usesAutomaticMarketLogo: Bool {
        selectedMarketAsset != nil
            && (selectedIconName.isEmpty || selectedIconName.hasPrefix("market_asset|"))
    }

    private var selectedUnitTitle: String? {
        guard let selectedMarketAsset else { return nil }
        let unit = selectedMarketAsset.recordUnitTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !unit.isEmpty { return unit }
        let currency = selectedMarketAsset.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return currency.isEmpty ? nil : currency
    }

    private var selectedUnitPrice: Double? {
        if let selectedMarketAssetSymbol {
            return marketStore.recordUnitPriceInCNY(for: selectedMarketAssetSymbol)
        }
        return normalizedNumber(from: recordUnitPriceText)
    }

    private var currentMarketValue: Double? {
        guard let quantity = normalizedNumber(from: recordQuantityText),
              let selectedUnitPrice,
              quantity.isFinite,
              selectedUnitPrice.isFinite else {
            return nil
        }
        return quantity * selectedUnitPrice
    }

    private var primaryActionEnabled: Bool {
        step == .asset || canSave
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        AddAssetStepIndicator(step: step) {
                            guard step != .asset else { return }
                            dismissActiveKeyboard()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                step = .asset
                            }
                        }

                        if step == .asset {
                            assetSelectionStep
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        } else {
                            assetDetailsStep
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(AppTypography.meta)
                                .foregroundStyle(AssetTheme.negative)
                                .padding(.horizontal, 4)
                        }

                        Color.clear
                            .frame(height: TabScrollLayout.formKeyboardDismissSpacer)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissActiveKeyboard()
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 0)
                    .padding(.bottom, TabScrollLayout.sheetBottomPadding)
                    .id(step)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissActiveKeyboard()
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(AppLocalization.string(isEditing ? "编辑资产类型" : "添加资产类型"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(AppLocalization.string("完成")) {
                        dismissActiveKeyboard()
                    }
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.gold)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                primaryActionBar
            }
            .task {
                if selectedCategoryID == nil {
                    selectedCategoryID = sortedCategories.first?.id
                }
                await marketStore.refreshAssetCatalogIfNeeded()
                await marketStore.loadRecordETFAssetCatalogIfNeeded()
                await marketStore.loadRecordAShareAssetCatalogIfNeeded()
                await searchETFs(keyword: nil)
            }
            .task(id: marketAssetSearchText) {
                let keyword = marketAssetSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !keyword.isEmpty else {
                    marketAssetSearchMessage = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                await searchETFs(keyword: keyword)
            }
            .task(id: "\(selectedMarketAssetSymbol ?? "")|\(valuationMethod.rawValue)") {
                guard valuationMethod == .quantityAndUnitPrice,
                      let selectedMarketAssetSymbol else { return }
                await refreshSelectedMarketAsset(selectedMarketAssetSymbol)
            }
            .alert(
                AppLocalization.string("确认删除资产？"),
                isPresented: $showsDeleteConfirmation
            ) {
                Button(AppLocalization.string("取消"), role: .cancel) {}
                Button(AppLocalization.string("删除"), role: .destructive) {
                    deleteEditingItem()
                }
            } message: {
                Text(AppLocalization.format(
                    "将删除“%@”及其所有历史记录，此操作无法撤销。",
                    editingItem?.name ?? resolvedName
                ))
            }
            .alert(
                AppLocalization.string("更换市场标的？"),
                isPresented: $showsMarketChangeConfirmation
            ) {
                Button(AppLocalization.string("取消"), role: .cancel) {}
                Button(AppLocalization.string("继续保存")) {
                    save()
                }
            } message: {
                Text(AppLocalization.string("已有历史记录会保留原金额，但今后将按新的市场标的更新。"))
            }
        }
    }

    private var assetSelectionStep: some View {
        MarketAssetCatalogSelector(
            assets: marketStore.recordSelectableAssetCatalog,
            selectedSymbol: $selectedMarketAssetSymbol,
            searchText: $marketAssetSearchText,
            isLocked: false,
            isSearching: isSearchingMarketAssets,
            searchMessage: marketAssetSearchMessage,
            presentationStyle: .flat,
            canLoadMore: { recordSecurityPaging.canLoadMore($0) },
            isLoadingMore: { loadingMoreSecuritySectionID == $0 },
            onLoadMore: { sectionID in
                Task { await loadMoreRecordSecurities(sectionID: sectionID) }
            },
            onSelect: handleMarketAssetSelection
        )
    }

    private var assetDetailsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            selectedAssetSummary

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(AppLocalization.string("名称"))
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AssetTheme.textSecondary)

                    TextField(AppLocalization.string("自定义名称"), text: editableName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AssetTheme.textPrimary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 14)

                Divider().overlay(AssetTheme.border.opacity(0.32))

                Menu {
                    ForEach(sortedCategories) { category in
                        Button {
                            selectedCategoryID = category.id
                        } label: {
                            if selectedCategoryID == category.id || (selectedCategoryID == nil && category.id == sortedCategories.first?.id) {
                                Label(AppLocalization.string(category.name), systemImage: "checkmark")
                            } else {
                                Text(AppLocalization.string(category.name))
                            }
                        }
                    }
                } label: {
                    detailValueRow(
                        title: AppLocalization.string("归类"),
                        value: selectedCategory.map { AppLocalization.string($0.name) } ?? "—",
                        systemImage: "chevron.up.chevron.down"
                    )
                }

                if let selectedUnitTitle {
                    Divider().overlay(AssetTheme.border.opacity(0.32))
                    detailValueRow(
                        title: AppLocalization.string("单位"),
                        value: selectedUnitTitle,
                        systemImage: nil
                    )
                }

                if valuationMethod == .quantityAndUnitPrice {
                    Divider().overlay(AssetTheme.border.opacity(0.32))

                    if selectedMarketAsset != nil {
                        detailValueRow(
                            title: AppLocalization.string("当前市场价"),
                            value: selectedUnitPrice?.currencyString() ?? "—",
                            systemImage: nil
                        )

                        Divider().overlay(AssetTheme.border.opacity(0.32))
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(
                            selectedUnitTitle.map { AppLocalization.format("数量（%@）", $0) }
                                ?? AppLocalization.string("数量")
                        )
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AssetTheme.textSecondary)

                        Spacer(minLength: 10)

                        TextField("0", text: $recordQuantityText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.plain)
                            .font(AppTypography.rowTitle)
                            .monospacedDigit()
                            .foregroundStyle(AssetTheme.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 160)
                    }
                    .padding(.vertical, 14)

                    if selectedMarketAsset == nil {
                        Divider().overlay(AssetTheme.border.opacity(0.32))

                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(AppLocalization.string("单价"))
                                .font(AppTypography.rowTitle)
                                .foregroundStyle(AssetTheme.textSecondary)

                            Spacer(minLength: 10)

                            TextField(AppLocalization.string("输入单价"), text: $recordUnitPriceText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.plain)
                                .font(AppTypography.rowTitle)
                                .monospacedDigit()
                                .foregroundStyle(AssetTheme.textPrimary)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 160)
                        }
                        .padding(.vertical, 14)
                    }

                    if let currentMarketValue {
                        Divider().overlay(AssetTheme.border.opacity(0.32))
                        detailValueRow(
                            title: AppLocalization.string("当前市值"),
                            value: currentMarketValue.currencyString(),
                            systemImage: nil
                        )
                    }
                }

                Divider().overlay(AssetTheme.border.opacity(0.32))

                iconMenu
            }

            if selectedMarketAsset == nil {
                VStack(alignment: .leading, spacing: 9) {
                    Text(AppLocalization.string("记录方式"))
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(AssetTheme.textSecondary)

                    Picker(AppLocalization.string("记录方式"), selection: $valuationMethod) {
                        ForEach(ValuationMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if isEditing {
                Button(role: .destructive) {
                    dismissActiveKeyboard()
                    showsDeleteConfirmation = true
                } label: {
                    Label(AppLocalization.string("删除资产"), systemImage: "trash")
                        .font(AppTypography.rowTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AssetTheme.negative)
            }
        }
    }

    private var selectedAssetSummary: some View {
        HStack(spacing: 13) {
            if let selectedMarketAsset, usesAutomaticMarketLogo {
                MarketAssetLogoView(asset: selectedMarketAsset, size: 42)
            } else {
                Image(systemName: displayedIconSymbolName)
                    .font(.system(size: 21, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(displayedIconColor)
                    .frame(width: 42, height: 42)
                    .background(displayedIconColor.opacity(0.12), in: Circle())
            }

            Text(selectedMarketAsset?.displayTitle ?? AppLocalization.string("不关联市场标的"))
                .font(AppTypography.blockTitleBold)
                .foregroundStyle(AssetTheme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                dismissActiveKeyboard()
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .asset
                }
            } label: {
                HStack(spacing: 4) {
                    Text(AppLocalization.string("更换"))
                    Image(systemName: "chevron.right")
                        .font(AppTypography.chartCaption)
                }
                .font(AppTypography.captionStrong)
                .foregroundStyle(AssetTheme.goldSoft)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Divider().overlay(AssetTheme.border.opacity(0.32))
        }
    }

    private var iconMenu: some View {
        Menu {
            Button {
                hasCustomizedIcon = false
                selectedIconName = selectedMarketAsset?.suggestedIconKey ?? ""
            } label: {
                Label(AppLocalization.string("自动"), systemImage: selectedMarketAsset?.assetIconName ?? "wand.and.stars")
            }

            Divider()

            ForEach(assetIconOptions) { option in
                Button {
                    hasCustomizedIcon = true
                    selectedIconName = option.key
                } label: {
                    Label(AppLocalization.string(option.label), systemImage: option.symbolName)
                }
            }
        } label: {
            HStack(spacing: 16) {
                Text(AppLocalization.string("图标"))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textSecondary)

                Spacer(minLength: 10)

                if let selectedMarketAsset, usesAutomaticMarketLogo {
                    MarketAssetLogoView(asset: selectedMarketAsset, size: 24)
                } else {
                    Image(systemName: displayedIconSymbolName)
                        .font(AppTypography.rowTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(displayedIconColor)
                        .frame(width: 24, height: 24)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(AppTypography.chartCaption)
                    .foregroundStyle(AssetTheme.textSecondary)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    private func detailValueRow(title: String, value: String, systemImage: String?) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.textSecondary)

            Spacer(minLength: 10)

            Text(value)
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)

            if let systemImage {
                Image(systemName: systemImage)
                    .font(AppTypography.chartCaption)
                    .foregroundStyle(AssetTheme.textSecondary)
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var primaryActionBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(AssetTheme.border.opacity(0.32))

            Button {
                dismissActiveKeyboard()
                if step == .asset {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .details
                    }
                } else {
                    attemptSave()
                }
            } label: {
                Text(AppLocalization.string(step == .asset ? "下一步" : "保存"))
                    .font(AppTypography.rowTitle)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .foregroundStyle(primaryActionEnabled ? Color.black.opacity(0.82) : AssetTheme.textSecondary)
                    .background(
                        primaryActionEnabled ? AssetTheme.gold : AssetTheme.overlayStrong,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!primaryActionEnabled)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(AssetTheme.background.opacity(0.96))
    }

    private func handleMarketAssetSelection(_ asset: MarketAssetDescriptor?) {
        if let asset {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nameWasAutofilled {
                name = asset.displayTitle
                nameWasAutofilled = true
            }
            if !hasCustomizedIcon {
                selectedIconName = asset.suggestedIconKey
            }
            valuationMethod = .quantityAndUnitPrice
        } else {
            if nameWasAutofilled {
                name = ""
                nameWasAutofilled = false
            }
            if !hasCustomizedIcon {
                selectedIconName = ""
            }
            valuationMethod = .directAmount
        }
    }

    @MainActor
    private func attemptSave() {
        guard let editingItem else {
            save()
            return
        }
        let oldSymbol = editingItem.marketAssetSymbol.map(BacktestAssetSymbol.normalized)
        let newSymbol = selectedMarketAssetSymbol.map(BacktestAssetSymbol.normalized)
        if !editingItem.entries.isEmpty, oldSymbol != newSymbol {
            showsMarketChangeConfirmation = true
        } else {
            save()
        }
    }

    @MainActor
    private func save() {
        guard let selectedCategory else { return }

        do {
            let item: AssetItem
            if let editingItem {
                try AssetItemService.updateItem(
                    editingItem,
                    name: resolvedName,
                    iconName: resolvedIconName,
                    valuationMethod: valuationMethod,
                    marketAssetSymbol: .some(selectedMarketAssetSymbol),
                    category: selectedCategory,
                    in: modelContext
                )
                item = editingItem
            } else {
                item = try AssetItemService.createItem(
                    name: resolvedName,
                    category: selectedCategory,
                    valuationMethod: valuationMethod,
                    marketAssetSymbol: selectedMarketAssetSymbol,
                    iconName: resolvedIconName,
                    in: modelContext
                )
            }
            if valuationMethod == .quantityAndUnitPrice,
               let snapshot,
               let quantity = normalizedNumber(from: recordQuantityText) {
                try SnapshotService.upsertEntry(
                    snapshot: snapshot,
                    item: item,
                    quantity: quantity,
                    unitPrice: selectedUnitPrice,
                    in: modelContext
                )
            }
            dismiss()
        } catch {
            errorMessage = AppLocalization.string("保存失败，请稍后再试")
            print("[AssetTimeMachine] save item failed: \(error)")
        }
    }

    @MainActor
    private func deleteEditingItem() {
        guard let editingItem else { return }
        do {
            try AssetItemService.deleteItem(editingItem, in: modelContext)
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = AppLocalization.string("删除失败")
            print("[AssetTimeMachine] delete item failed: \(error)")
        }
    }

    private func normalizedNumber(from text: String) -> Double? {
        let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    @MainActor
    private func searchETFs(keyword: String?) async {
        isSearchingMarketAssets = true
        marketAssetSearchMessage = nil
        defer { isSearchingMarketAssets = false }
        do {
            let hasMore = try await marketStore.refreshRecordSecurityCatalog(
                keyword: keyword,
                pageSize: keyword?.isEmpty == false ? 100 : 60
            )
            guard !Task.isCancelled else { return }
            if keyword?.isEmpty != false {
                recordSecurityPaging.reset(hasMore: hasMore)
            }
        } catch {
            guard !Task.isCancelled else { return }
            let hasCachedSecurities = !marketStore.recordETFAssetCatalog.isEmpty
                || !marketStore.recordAShareAssetCatalog.isEmpty
            if keyword?.isEmpty == false || !hasCachedSecurities {
                marketAssetSearchMessage = AppLocalization.string("股票或 ETF 行情暂时不可用")
            }
        }
    }

    @MainActor
    private func loadMoreRecordSecurities(sectionID: String) async {
        guard loadingMoreSecuritySectionID == nil,
              recordSecurityPaging.canLoadMore(sectionID) else { return }
        loadingMoreSecuritySectionID = sectionID
        defer { loadingMoreSecuritySectionID = nil }

        do {
            let page = recordSecurityPaging.nextPage(sectionID)
            let hasMore = try await marketStore.loadRecordSecurityCatalogPage(
                sectionID: sectionID,
                page: page,
                pageSize: 60
            )
            guard !Task.isCancelled else { return }
            recordSecurityPaging.completePage(sectionID: sectionID, hasMore: hasMore)
        } catch {
            guard !Task.isCancelled else { return }
            marketAssetSearchMessage = AppLocalization.string("股票或 ETF 行情暂时不可用")
        }
    }

    @MainActor
    private func refreshSelectedMarketAsset(_ symbol: String) async {
        if symbol.hasPrefix(MarketAssetDescriptor.recordETFPrefix)
            || symbol.hasPrefix(MarketAssetDescriptor.recordASharePrefix) {
            do {
                try await marketStore.refreshRecordSecurityHistory(symbol: symbol)
                guard !Task.isCancelled else { return }
            } catch {
                errorMessage = AppLocalization.string("股票或 ETF 行情暂时不可用")
            }
            return
        }
        async let liveRefresh: Bool = marketStore.refreshLiveData()
        async let historyRefresh: Bool = marketStore.refreshHistory(for: Set([symbol]))
        _ = await (liveRefresh, historyRefresh)
    }
}

struct QuickRecordValueSheet: View {
    @Environment(\.modelContext) private var modelContext

    private enum QuickRecordValueField: Hashable {
        case primary
        case unitPrice
    }

    private struct QuickRecordAutoFocusModifier: ViewModifier {
        @FocusState.Binding var focusedField: QuickRecordValueField?

        func body(content: Content) -> some View {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-disableQuickEditAutoFocus") {
                content
            } else {
                content.defaultFocus($focusedField, .primary)
            }
            #else
            content.defaultFocus($focusedField, .primary)
            #endif
        }
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
    @State private var lastManualPriceRefreshAt: Date?
    @State private var manualAutoPriceRefreshTask: Task<Void, Never>?
    @FocusState private var focusedField: QuickRecordValueField?

    init(
        item: AssetItem,
        snapshot: AssetSnapshot?,
        marketStore: RemoteMarketStore,
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
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
            return item.quantityFieldTitle(using: marketStore)
        }
    }

    private var displayedUnitPriceText: String? {
        let trimmed = unitPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private var trailingUnitPriceTitle: String? {
        guard item.valuationMethod == .quantityAndUnitPrice else { return nil }
        return AppLocalization.string(item.marketAssetSymbol == nil ? "单价" : "参考单价")
    }

    private var trailingUnitPriceValue: String? {
        guard item.valuationMethod == .quantityAndUnitPrice else { return nil }
        if item.marketAssetSymbol != nil,
           let rate = item.resolvedAutoUnitPrice(using: marketStore) {
            return rate.currencyString()
        }
        return displayedUnitPriceText
    }

    private var trailingUnitPriceTimestamp: String? {
        guard item.valuationMethod == .quantityAndUnitPrice,
              item.marketAssetSymbol != nil else {
            return nil
        }
        let fetchedAt = lastManualPriceRefreshAt
            ?? item.autoPriceFetchedAt(using: marketStore)
        guard let fetchedAt else { return nil }
        return AppLocalization.format("%@更新", fetchedAt.recordTimeString)
    }

    private var quantityUnitTitle: String? {
        guard item.valuationMethod == .quantityAndUnitPrice else { return nil }
        return item.quantityUnitTitle(using: marketStore)
    }

    private var inlinePrimaryTextFieldWidth: CGFloat {
        let text: String
        switch item.valuationMethod {
        case .directAmount:
            text = amountText
        case .quantityAndUnitPrice:
            text = quantityText
        }
        return min(170, max(34, CGFloat(max(text.count, 1)) * 21))
    }

    private var currentMarketValue: Double? {
        switch item.valuationMethod {
        case .directAmount:
            guard let amount = normalizedReadonlyNumber(from: amountText), amount.isFinite else {
                return nil
            }
            return isLiability ? abs(amount) : amount
        case .quantityAndUnitPrice:
            guard let quantity = normalizedReadonlyNumber(from: quantityText),
                  let unitPrice = item.marketAssetSymbol == nil
                    ? normalizedReadonlyNumber(from: unitPriceText)
                    : item.resolvedAutoUnitPrice(using: marketStore),
                  quantity.isFinite,
                  unitPrice.isFinite else {
                return nil
            }
            return quantity * unitPrice
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            editorRow
                .padding(.horizontal, 26)
                .padding(.top, 63)
                .padding(.bottom, errorMessage == nil ? 44 : 16)

            if let errorMessage {
                Text(errorMessage)
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 14)
            }

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 20)

            marketValueRow
                .padding(.horizontal, 26)
                .padding(.top, 24)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: 540, minHeight: 435, alignment: .top)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 28,
                style: .continuous
            )
                .fill(.ultraThinMaterial)
        )
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 28,
                style: .continuous
            )
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), AssetTheme.gold.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.36), radius: 34, x: 0, y: -8)
        .contentShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 28,
                style: .continuous
            )
        )
        .modifier(QuickRecordAutoFocusModifier(focusedField: $focusedField))
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(AppLocalization.string("完成")) {
                    focusedField = nil
                }
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.gold)
            }
        }
        .onDisappear {
            manualAutoPriceRefreshTask?.cancel()
            manualAutoPriceRefreshTask = nil
            isRefreshingAutoPrice = false
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("取消"))

            Spacer(minLength: 4)

            Text(AppLocalization.string(item.name))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AssetTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 4)

            Button(AppLocalization.string("完成"), action: save)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AssetTheme.goldSoft)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var editorRow: some View {
        HStack(alignment: .center, spacing: 16) {
            AssetItemGlyph(
                item: item,
                accent: isLiability ? AssetTheme.negative : AssetTheme.goldSoft,
                size: 34
            )
            .frame(width: 46, height: 46)

            inlinePrimaryField

            if item.valuationMethod == .quantityAndUnitPrice {
                inlineUnitPrice
                    .frame(minWidth: 116, alignment: .trailing)
            }
        }
    }

    private var inlinePrimaryField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if item.valuationMethod == .directAmount {
                Text("¥")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            TextField(
                AppLocalization.format("输入%@", primaryFieldTitle),
                text: bindingForPrimaryField()
            )
            .keyboardType(.decimalPad)
            .textFieldStyle(.plain)
            .font(.system(size: 34, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(AssetTheme.textPrimary)
            .focused($focusedField, equals: .primary)
            .minimumScaleFactor(0.65)
            .frame(width: inlinePrimaryTextFieldWidth, alignment: .leading)

            if let quantityUnitTitle {
                Text(quantityUnitTitle)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AssetTheme.goldSoft)
                .frame(height: 1)
        }
        .accessibilityLabel(primaryFieldTitle)
    }

    @ViewBuilder
    private var inlineUnitPrice: some View {
        if item.marketAssetSymbol != nil {
            VStack(alignment: .trailing, spacing: 8) {
                if let trailingUnitPriceValue {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(trailingUnitPriceValue)
                            .font(.system(size: 16, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(AssetTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)

                        if let quantityUnitTitle {
                            Text("/ \(quantityUnitTitle)")
                                .font(AppTypography.meta)
                                .foregroundStyle(AssetTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text(isRefreshingAutoPrice
                        ? AppLocalization.string("刷新中")
                        : trailingUnitPriceTimestamp ?? "—")
                        .font(AppTypography.caption)
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(1)

                    refreshPriceButton
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 7) {
                Text(trailingUnitPriceTitle ?? AppLocalization.string("单价"))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("¥")
                        .font(AppTypography.meta)
                        .foregroundStyle(AssetTheme.textSecondary)
                    TextField(AppLocalization.string("单价"), text: $unitPriceText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(AssetTheme.textPrimary)
                        .focused($focusedField, equals: .unitPrice)
                        .frame(maxWidth: 82)
                    if let quantityUnitTitle {
                        Text("/ \(quantityUnitTitle)")
                            .font(AppTypography.meta)
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                }
                .padding(.bottom, 5)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(height: 1)
                }
            }
        }
    }

    private var marketValueRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(AppLocalization.string("本次市值"))
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(AssetTheme.textSecondary)

            Spacer(minLength: 16)

            Text(currentMarketValue?.currencyString() ?? "—")
                .font(.system(size: 27, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.goldSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var refreshPriceButton: some View {
        Button(action: beginManualPriceRefresh) {
            Group {
                if isRefreshingAutoPrice {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AssetTheme.goldSoft)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(AssetTheme.textSecondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRefreshingAutoPrice)
        .accessibilityLabel(AppLocalization.string("手动刷新最新价格"))
    }

    private func beginManualPriceRefresh() {
        manualAutoPriceRefreshTask?.cancel()
        let writeID = ModelContextMutationBarrier.shared.beginDeferredWrite()
        manualAutoPriceRefreshTask = Task {
            defer { ModelContextMutationBarrier.shared.finishDeferredWrite(writeID) }
            do {
                try await ModelContextMutationBarrier.shared.waitUntilWriteIsAllowed(writeID)
            } catch {
                return
            }
            await refreshAutoPriceManually()
            guard !Task.isCancelled else { return }
            manualAutoPriceRefreshTask = nil
        }
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
            if let autoRate = item.resolvedAutoUnitPrice(using: marketStore), item.marketAssetSymbol != nil {
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
        guard item.marketAssetSymbol != nil, !Task.isCancelled else { return }
        isRefreshingAutoPrice = true
        errorMessage = nil
        defer {
            if !Task.isCancelled {
                isRefreshingAutoPrice = false
            }
        }

        guard let symbol = item.marketAssetSymbol else { return }
        let didRefreshLiveData = await marketStore.refreshRecordPrice(for: symbol)
        guard !Task.isCancelled else { return }
        guard didRefreshLiveData else {
            errorMessage = marketStore.errorMessage ?? AppLocalization.string("暂时没拿到最新价格，稍后再试")
            return
        }

        guard let latestRate = item.resolvedAutoUnitPrice(using: marketStore) else {
            errorMessage = AppLocalization.string("暂时没拿到最新价格，稍后再试")
            return
        }

        unitPriceText = latestRate.plainNumberString()
        lastManualPriceRefreshAt = .now

        guard let snapshot else { return }
        guard !Task.isCancelled else { return }
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
        guard let value = Double(raw), value.isFinite else { return nil }
        return value
    }
}

struct QuickRecordValueValidationError: Error {
    let message: String
}

private func validatedQuickRecordNumber(from text: String, forcePositive: Bool = false, fieldName: String) throws -> Double? {
    let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    guard let value = Double(raw), value.isFinite else {
        throw QuickRecordValueValidationError(message: AppLocalization.format("%@请输入有效数字", fieldName))
    }
    return forcePositive ? abs(value) : value
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
    @State private var archiveProjections: [SnapshotArchiveProjection] = []
    @State private var isLoadingArchive = true
    @State private var pendingDeletionProjection: SnapshotArchiveProjection?
    @State private var deletionErrorMessage: String?
    @State private var projectionRevision = 0

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            if isLoadingArchive && archiveProjections.isEmpty {
                LoadingStateCard(title: AppLocalization.string("记录加载中"))
                    .padding(.horizontal, 20)
            } else if archiveProjections.isEmpty {
                EmptyStateCard(
                    title: AppLocalization.string("暂无记录"),
                    systemImage: "calendar.badge.plus"
                )
                .padding(.horizontal, 20)
            } else {
                List {
                    ForEach(archiveProjections) { projection in
                        NavigationLink(value: projection.id) {
                            SnapshotArchiveRow(projection: projection)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                pendingDeletionProjection = projection
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
        .navigationDestination(for: UUID.self) { snapshotID in
            SnapshotArchiveDetailDestination(snapshotID: snapshotID)
        }
        .task(id: projectionRevision) {
            let container = modelContext.container
            do {
                let projections = try await BackgroundTaskWork.run {
                    let store = TimeMachineSnapshotProjectionStore(modelContainer: container)
                    return try await store.fetchArchiveProjections()
                }
                guard !Task.isCancelled else { return }
                archiveProjections = projections
                isLoadingArchive = false
            } catch is CancellationError {
                return
            } catch {
                isLoadingArchive = false
                print("[AssetTimeMachine] fetch archive projections failed: \(error)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { notification in
            guard PortfolioSaveNotificationFilter.affectsPortfolio(notification) else { return }
            projectionRevision &+= 1
        }
        .alert(
            AppLocalization.string("确认删除这条记录？"),
            isPresented: Binding(
                get: { pendingDeletionProjection != nil },
                set: { if !$0 { pendingDeletionProjection = nil } }
            ),
            presenting: pendingDeletionProjection
        ) { projection in
            Button(AppLocalization.string("取消"), role: .cancel) {
                pendingDeletionProjection = nil
            }
            Button(AppLocalization.string("删除"), role: .destructive) {
                delete(projection: projection)
                pendingDeletionProjection = nil
            }
        } message: { projection in
            Text(AppLocalization.format(
                "将删除 %@ 的资产记录，删除后无法恢复。",
                projection.date.longDateString
            ))
        }
        .alert(AppLocalization.string("删除失败"), isPresented: Binding(
            get: { deletionErrorMessage != nil },
            set: { if !$0 { deletionErrorMessage = nil } }
        )) {
            Button(AppLocalization.string("知道了"), role: .cancel) {}
        } message: {
            Text(deletionErrorMessage ?? AppLocalization.string("请稍后再试"))
        }
    }

    @MainActor
    private func delete(projection: SnapshotArchiveProjection) {
        do {
            let snapshotID = projection.id
            var descriptor = FetchDescriptor<AssetSnapshot>(
                predicate: #Predicate<AssetSnapshot> { snapshot in
                    snapshot.id == snapshotID
                }
            )
            descriptor.fetchLimit = 1
            guard let snapshot = try modelContext.fetch(descriptor).first else { return }
            try SyncDeletionService.record(entityID: snapshotID, kind: .snapshot, in: modelContext)
            modelContext.delete(snapshot)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            deletionErrorMessage = AppLocalization.string("这条记录未被删除，请稍后重试。")
            print("[AssetTimeMachine] delete snapshot failed: \(error)")
        }
    }
}

struct SnapshotArchiveRow: View {
    let projection: SnapshotArchiveProjection

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(projection.date.longDateString)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)

                Text(AppLocalization.format(
                    "%d 项 · 负债 %@",
                    projection.entryCount,
                    projection.totalLiabilities.currencyString()
                ))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(projection.netAssets.currencyString())
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.goldSoft)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.vertical, 2)
    }
}

private struct SnapshotArchiveDetailDestination: View {
    @Environment(\.modelContext) private var modelContext
    let snapshotID: UUID
    @State private var snapshot: AssetSnapshot?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let snapshot {
                SnapshotDetailView(snapshot: snapshot)
            } else if didLoad {
                ContentUnavailableView(
                    AppLocalization.string("记录不存在"),
                    systemImage: "calendar.badge.exclamationmark"
                )
            } else {
                ZStack {
                    AssetTheme.pageGradient.ignoresSafeArea()
                    ProgressView()
                        .tint(AssetTheme.gold)
                }
            }
        }
        .task(id: snapshotID) {
            var descriptor = FetchDescriptor<AssetSnapshot>(
                predicate: #Predicate<AssetSnapshot> { snapshot in
                    snapshot.id == snapshotID
                }
            )
            descriptor.fetchLimit = 1
            snapshot = try? modelContext.fetch(descriptor).first
            didLoad = true
        }
    }
}

struct SnapshotDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var categories: [AssetCategory]
    let snapshot: AssetSnapshot
    @State private var editingEntry: AssetEntry?
    @State private var entryEditorDraftID: UUID?
    @State private var amountInputs: [UUID: String] = [:]
    @State private var quantityInputs: [UUID: String] = [:]
    @State private var unitPriceInputs: [UUID: String] = [:]
    @FocusState private var focusedField: RecordInputField?

    private var layout: SnapshotListLayout {
        SnapshotRecordLayoutBuilder.make(
            snapshot: snapshot,
            categories: categories,
            includeInactiveSnapshotItems: true
        )
    }

    var body: some View {
        let layout = layout

        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        ATMBackButton {
                            dismiss()
                        }
                        Spacer(minLength: 0)
                    }

                    RecordPageHero(
                        snapshot: snapshot,
                        totalAssets: layout.displayedTotalAssets,
                        netAssets: layout.displayedNetAssets,
                        totalLiabilities: layout.displayedTotalLiabilities,
                        showsActionChips: false,
                        onAddAsset: {}
                    )
                    .padding(.bottom, 2)

                    RecordSnapshotSections(
                        layout: layout,
                        onboardingActiveAnchorID: nil,
                        amountInputs: $amountInputs,
                        quantityInputs: $quantityInputs,
                        unitPriceInputs: $unitPriceInputs,
                        focusedField: $focusedField,
                        inlineEditingField: nil,
                        onBeginInlineEdit: { _ in },
                        onEdit: { _ in },
                        onEditValue: { _ in },
                        isReadOnly: true,
                        onReadOnlyEdit: { entry in
                            presentEntryEditor(entry)
                        }
                    )

                    Color.clear.frame(height: 32)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, TabScrollLayout.bottomPadding)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            hydrateDisplayInputs(from: snapshot)
        }
        .sheet(item: $editingEntry, onDismiss: {
            finishEntryEditorDraft()
        }) { entry in
            SnapshotEntryEditSheet(entry: entry)
        }
        .onDisappear {
            finishEntryEditorDraft()
        }
    }

    @MainActor
    private func presentEntryEditor(_ entry: AssetEntry) {
        guard entryEditorDraftID == nil else {
            editingEntry = entry
            return
        }
        guard let draftID = ModelContextMutationBarrier.shared.beginEditorDraft() else { return }
        entryEditorDraftID = draftID
        editingEntry = entry
    }

    @MainActor
    private func finishEntryEditorDraft() {
        guard let entryEditorDraftID else { return }
        ModelContextMutationBarrier.shared.finishEditorDraft(entryEditorDraftID)
        self.entryEditorDraftID = nil
    }

    private func hydrateDisplayInputs(from snapshot: AssetSnapshot) {
        for entry in snapshot.entries {
            guard let item = entry.item else { continue }
            amountInputs[item.id] = item.valuationMethod == .directAmount ? (entry.amount?.plainNumberString() ?? "") : ""
            quantityInputs[item.id] = item.valuationMethod == .quantityAndUnitPrice ? (entry.quantity?.plainNumberString() ?? "") : ""
            unitPriceInputs[item.id] = item.valuationMethod == .quantityAndUnitPrice ? (entry.unitPrice?.plainNumberString() ?? "") : ""
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
                                    .font(AppTypography.blockTitleBold)
                                    .foregroundStyle(AssetTheme.textPrimary)
                                if let snapshotDate = entry.snapshot?.date {
                                    Text(snapshotDate.longDateString)
                                        .font(AppTypography.meta)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                            }
                        }
                        .atmCardStyle()

                        VStack(alignment: .leading, spacing: 14) {
                            if usesQuantityAndUnitPrice {
                                editField(
                                    title: quantityFieldTitle,
                                    text: $quantityText,
                                    placeholder: quantityFieldPlaceholder,
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
                                    .font(AppTypography.meta)
                                    .foregroundStyle(AssetTheme.negative)
                            }
                        }
                        .atmCardStyle()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, TabScrollLayout.sheetBottomPadding)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .font(AppTypography.body)
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("编辑历史记录"))
                        .font(AppTypography.blockTitleBold)
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("保存")) {
                        save()
                    }
                    .font(AppTypography.bodyStrong)
                    .foregroundStyle(AssetTheme.gold)
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(AppLocalization.string("完成")) {
                        focusedField = nil
                    }
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.gold)
                }
            }
            .defaultFocus($focusedField, usesQuantityAndUnitPrice ? .quantity : .amount)
        }
    }

    private var quantityFieldTitle: String {
        guard let unit = item?.persistedQuantityUnitTitle, !unit.isEmpty else {
            return AppLocalization.string("数量")
        }
        return AppLocalization.format("数量（%@）", unit)
    }

    private var quantityFieldPlaceholder: String {
        guard let unit = item?.persistedQuantityUnitTitle, !unit.isEmpty else {
            return AppLocalization.string("输入数量")
        }
        return AppLocalization.format("输入数量（%@）", unit)
    }

    private func editField(title: String, text: Binding<String>, placeholder: String, focus: SnapshotEntryEditField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppTypography.caption)
                .foregroundStyle(AssetTheme.textSecondary)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.plain)
                .font(AppTypography.inputValue)
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
