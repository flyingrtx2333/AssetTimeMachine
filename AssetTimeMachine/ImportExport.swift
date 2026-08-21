import Foundation
import SwiftData

nonisolated struct ExportPayload: Codable, Sendable {
    let exportedAt: Date
    let categories: [CategoryPayload]
    let items: [ItemPayload]
    let snapshots: [SnapshotPayload]
    let deletions: [DeletionPayload]?

    var deletionRecords: [DeletionPayload] {
        deletions ?? []
    }

    nonisolated struct CategoryPayload: Codable, Sendable {
        let id: UUID
        let name: String
        let group: String
        let createdAt: Date
    }

    nonisolated struct ItemPayload: Codable, Sendable {
        let id: UUID
        let name: String
        let note: String
        let iconName: String?
        let valuationMethod: String
        let autoPricedAssetKind: String?
        let quantStrategyProxySymbol: String?
        let sortOrder: Int
        let isActive: Bool
        let createdAt: Date
        let updatedAt: Date
        let categoryID: UUID?
    }

    nonisolated struct SnapshotPayload: Codable, Sendable {
        let id: UUID
        let date: Date
        let note: String
        let createdAt: Date
        let updatedAt: Date
        let goldAnchorPriceCNY: Double?
        let goldAnchorPriceDate: Date?
        let btcAnchorPriceUSD: Double?
        let btcAnchorPriceDate: Date?
        let nasdaqAnchorPriceUSD: Double?
        let nasdaqAnchorPriceDate: Date?
        let usdPerCNY: Double?
        let usdPerCNYDate: Date?
        let marketAnchorsUpdatedAt: Date?
        let entries: [EntryPayload]
    }

    nonisolated struct EntryPayload: Codable, Sendable {
        let id: UUID
        let amount: Double?
        let quantity: Double?
        let unitPrice: Double?
        let note: String
        let createdAt: Date
        let updatedAt: Date
        let itemID: UUID?
    }

    nonisolated struct DeletionPayload: Codable, Sendable {
        let entityID: UUID
        let entityKind: String
        let deletedAt: Date
    }
}

nonisolated struct VersionedExportPayload: Sendable {
    let payload: ExportPayload
    let storeRevision: UInt64
}

nonisolated enum ImportExportConsistencyError: Error, Sendable {
    case storeChanged
}

nonisolated enum SyncPayloadWork {
    static func detached<Value: Sendable>(
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()

        let task = Task.detached(priority: priority) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

@ModelActor
private actor CloudExportProjectionStore {
    private static let cancellationCheckInterval = 128

    func exportPayload() throws -> ExportPayload {
        var result: ExportPayload?

        // The caller compares a synchronous global save revision before and after
        // this materialization, discarding the payload if another context commits.
        do {
            try Task.checkCancellation()
            let categories = try modelContext.fetch(FetchDescriptor<AssetCategory>())
            let items = try modelContext.fetch(FetchDescriptor<AssetItem>())
            let snapshots = try modelContext.fetch(FetchDescriptor<AssetSnapshot>())
            let entries = try modelContext.fetch(FetchDescriptor<AssetEntry>())
            let tombstones = try modelContext.fetch(FetchDescriptor<SyncDeletionTombstone>())

            var categoryPayloads: [ExportPayload.CategoryPayload] = []
            categoryPayloads.reserveCapacity(categories.count)
            for (index, category) in categories.enumerated() {
                categoryPayloads.append(.init(
                    id: category.id,
                    name: category.name,
                    group: category.group.rawValue,
                    createdAt: category.createdAt
                ))
                try checkCancellation(afterProcessing: index + 1)
            }

            var itemPayloads: [ExportPayload.ItemPayload] = []
            itemPayloads.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                itemPayloads.append(.init(
                    id: item.id,
                    name: item.name,
                    note: item.note,
                    iconName: ((item.iconName ?? "").isEmpty ? nil : item.iconName),
                    valuationMethod: item.valuationMethod.rawValue,
                    autoPricedAssetKind: item.marketAssetSymbol,
                    quantStrategyProxySymbol: item.quantStrategyProxySymbol,
                    sortOrder: item.sortOrder,
                    isActive: item.isActive,
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt,
                    categoryID: item.category?.id
                ))
                try checkCancellation(afterProcessing: index + 1)
            }

            var entryPayloadsBySnapshotID: [UUID: [ExportPayload.EntryPayload]] = [:]
            entryPayloadsBySnapshotID.reserveCapacity(snapshots.count)
            for (index, entry) in entries.enumerated() {
                if let snapshotID = entry.snapshot?.id {
                    entryPayloadsBySnapshotID[snapshotID, default: []].append(.init(
                        id: entry.id,
                        amount: entry.amount,
                        quantity: entry.quantity,
                        unitPrice: entry.unitPrice,
                        note: entry.note,
                        createdAt: entry.createdAt,
                        updatedAt: entry.updatedAt,
                        itemID: entry.item?.id
                    ))
                }
                try checkCancellation(afterProcessing: index + 1)
            }

            var snapshotPayloads: [ExportPayload.SnapshotPayload] = []
            snapshotPayloads.reserveCapacity(snapshots.count)
            for (index, snapshot) in snapshots.enumerated() {
                snapshotPayloads.append(.init(
                    id: snapshot.id,
                    date: snapshot.date,
                    note: snapshot.note,
                    createdAt: snapshot.createdAt,
                    updatedAt: snapshot.updatedAt,
                    goldAnchorPriceCNY: snapshot.goldAnchorPriceCNY,
                    goldAnchorPriceDate: snapshot.goldAnchorPriceDate,
                    btcAnchorPriceUSD: snapshot.btcAnchorPriceUSD,
                    btcAnchorPriceDate: snapshot.btcAnchorPriceDate,
                    nasdaqAnchorPriceUSD: snapshot.nasdaqAnchorPriceUSD,
                    nasdaqAnchorPriceDate: snapshot.nasdaqAnchorPriceDate,
                    usdPerCNY: snapshot.usdPerCNY,
                    usdPerCNYDate: snapshot.usdPerCNYDate,
                    marketAnchorsUpdatedAt: snapshot.marketAnchorsUpdatedAt,
                    entries: entryPayloadsBySnapshotID.removeValue(forKey: snapshot.id) ?? []
                ))
                try checkCancellation(afterProcessing: index + 1)
            }

            var deletionPayloads: [ExportPayload.DeletionPayload] = []
            deletionPayloads.reserveCapacity(tombstones.count)
            for (index, tombstone) in tombstones.enumerated() {
                if let entityKind = tombstone.entityKind {
                    deletionPayloads.append(.init(
                        entityID: tombstone.entityID,
                        entityKind: entityKind.rawValue,
                        deletedAt: tombstone.deletedAt
                    ))
                }
                try checkCancellation(afterProcessing: index + 1)
            }

            try Task.checkCancellation()
            result = ExportPayload(
                exportedAt: .now,
                categories: categoryPayloads,
                items: itemPayloads,
                snapshots: snapshotPayloads,
                deletions: deletionPayloads
            )
        }

        guard let result else { throw CancellationError() }
        return result
    }

    private func checkCancellation(afterProcessing count: Int) throws {
        if count.isMultiple(of: Self.cancellationCheckInterval) {
            try Task.checkCancellation()
        }
    }
}

nonisolated private enum ImportPayloadValidationError: Error, Sendable {
    case duplicateCategory
    case duplicateItem
    case duplicateSnapshot
    case duplicateEntry
    case duplicateItemReference
    case unknownCategoryReference
    case unknownItemReference
}

nonisolated private enum ImportPayloadPreparer {
    private static let cancellationCheckInterval = 256

    static func prepare(_ rawPayload: ExportPayload, checksCancellation: Bool) throws -> ExportPayload {
        try checkCancellation(if: checksCancellation)
        let payload = SyncMergeService.payloadApplyingDeletions(rawPayload)
        try checkCancellation(if: checksCancellation)
        try validate(payload, checksCancellation: checksCancellation)
        try checkCancellation(if: checksCancellation)
        return payload
    }

    private static func validate(_ payload: ExportPayload, checksCancellation: Bool) throws {
        var categoryIDs: Set<UUID> = []
        categoryIDs.reserveCapacity(payload.categories.count)
        for (index, category) in payload.categories.enumerated() {
            guard categoryIDs.insert(category.id).inserted else {
                throw ImportPayloadValidationError.duplicateCategory
            }
            try checkCancellation(afterProcessing: index + 1, if: checksCancellation)
        }

        var itemIDs: Set<UUID> = []
        itemIDs.reserveCapacity(payload.items.count)
        for (index, item) in payload.items.enumerated() {
            guard itemIDs.insert(item.id).inserted else {
                throw ImportPayloadValidationError.duplicateItem
            }
            if let categoryID = item.categoryID, !categoryIDs.contains(categoryID) {
                throw ImportPayloadValidationError.unknownCategoryReference
            }
            try checkCancellation(afterProcessing: index + 1, if: checksCancellation)
        }

        var snapshotIDs: Set<UUID> = []
        snapshotIDs.reserveCapacity(payload.snapshots.count)
        var entryIDs: Set<UUID> = []
        entryIDs.reserveCapacity(payload.snapshots.reduce(into: 0) { $0 += $1.entries.count })
        var processedEntryCount = 0

        for (snapshotIndex, snapshot) in payload.snapshots.enumerated() {
            guard snapshotIDs.insert(snapshot.id).inserted else {
                throw ImportPayloadValidationError.duplicateSnapshot
            }

            var referencedItemIDs: Set<UUID> = []
            referencedItemIDs.reserveCapacity(snapshot.entries.count)
            for entry in snapshot.entries {
                guard entryIDs.insert(entry.id).inserted else {
                    throw ImportPayloadValidationError.duplicateEntry
                }
                if let itemID = entry.itemID {
                    guard itemIDs.contains(itemID) else {
                        throw ImportPayloadValidationError.unknownItemReference
                    }
                    guard referencedItemIDs.insert(itemID).inserted else {
                        throw ImportPayloadValidationError.duplicateItemReference
                    }
                }
                processedEntryCount += 1
                try checkCancellation(afterProcessing: processedEntryCount, if: checksCancellation)
            }
            try checkCancellation(afterProcessing: snapshotIndex + 1, if: checksCancellation)
        }
    }

    private static func checkCancellation(afterProcessing count: Int? = nil, if enabled: Bool) throws {
        guard enabled else { return }
        if let count, !count.isMultiple(of: cancellationCheckInterval) {
            return
        }
        try Task.checkCancellation()
    }
}

enum ImportExportService {
    @MainActor
    static func exportPayload(from context: ModelContext) throws -> ExportPayload {
        let categories = try context.fetch(FetchDescriptor<AssetCategory>())
        let items = try context.fetch(FetchDescriptor<AssetItem>())
        let snapshots = try context.fetch(FetchDescriptor<AssetSnapshot>())
        let tombstones = try context.fetch(FetchDescriptor<SyncDeletionTombstone>())

        return ExportPayload(
            exportedAt: .now,
            categories: categories.map {
                .init(
                    id: $0.id,
                    name: $0.name,
                    group: $0.group.rawValue,
                    createdAt: $0.createdAt
                )
            },
            items: items.map {
                .init(
                    id: $0.id,
                    name: $0.name,
                    note: $0.note,
                    iconName: (($0.iconName ?? "").isEmpty ? nil : $0.iconName),
                    valuationMethod: $0.valuationMethod.rawValue,
                    autoPricedAssetKind: $0.marketAssetSymbol,
                    quantStrategyProxySymbol: $0.quantStrategyProxySymbol,
                    sortOrder: $0.sortOrder,
                    isActive: $0.isActive,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    categoryID: $0.category?.id
                )
            },
            snapshots: snapshots.map { snapshot in
                .init(
                    id: snapshot.id,
                    date: snapshot.date,
                    note: snapshot.note,
                    createdAt: snapshot.createdAt,
                    updatedAt: snapshot.updatedAt,
                    goldAnchorPriceCNY: snapshot.goldAnchorPriceCNY,
                    goldAnchorPriceDate: snapshot.goldAnchorPriceDate,
                    btcAnchorPriceUSD: snapshot.btcAnchorPriceUSD,
                    btcAnchorPriceDate: snapshot.btcAnchorPriceDate,
                    nasdaqAnchorPriceUSD: snapshot.nasdaqAnchorPriceUSD,
                    nasdaqAnchorPriceDate: snapshot.nasdaqAnchorPriceDate,
                    usdPerCNY: snapshot.usdPerCNY,
                    usdPerCNYDate: snapshot.usdPerCNYDate,
                    marketAnchorsUpdatedAt: snapshot.marketAnchorsUpdatedAt,
                    entries: snapshot.entries.map {
                        .init(
                            id: $0.id,
                            amount: $0.amount,
                            quantity: $0.quantity,
                            unitPrice: $0.unitPrice,
                            note: $0.note,
                            createdAt: $0.createdAt,
                            updatedAt: $0.updatedAt,
                            itemID: $0.item?.id
                        )
                    }
                )
            },
            deletions: tombstones.compactMap { tombstone in
                guard let entityKind = tombstone.entityKind else { return nil }
                return .init(
                    entityID: tombstone.entityID,
                    entityKind: entityKind.rawValue,
                    deletedAt: tombstone.deletedAt
                )
            }
        )
    }

    /// Reads SwiftData on a dedicated model actor and returns a value-only payload.
    /// The main actor only supplies the container, so a large automatic export cannot block UI work.
    @MainActor
    static func exportPayloadCooperatively(from context: ModelContext) async throws -> VersionedExportPayload {
        let container = context.container
        let revisionClock = ModelStoreRevisionClock.shared

        for attempt in 0..<4 {
            try Task.checkCancellation()
            guard !context.hasChanges else {
                throw ImportExportConsistencyError.storeChanged
            }
            let startingRevision = revisionClock.currentRevision()
            let payload = try await BackgroundTaskWork.run {
                let store = CloudExportProjectionStore(modelContainer: container)
                return try await store.exportPayload()
            }
            let endingRevision = revisionClock.currentRevision()

            guard !context.hasChanges, startingRevision == endingRevision else {
                if attempt < 3 { await Task.yield() }
                continue
            }

            do {
                _ = try await SyncPayloadWork.detached {
                    try ImportPayloadPreparer.prepare(payload, checksCancellation: true)
                }
            } catch let validationError as ImportPayloadValidationError {
                throw localizedValidationError(validationError)
            }
            return VersionedExportPayload(
                payload: payload,
                storeRevision: endingRevision
            )
        }

        throw NSError(
            domain: "ImportExportService",
            code: 409,
            userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("请稍后再试")]
        )
    }

    @MainActor
    static func exportJSON(from context: ModelContext, prettyPrinted: Bool = true) throws -> Data {
        let payload = try exportPayload(from: context)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(payload)
    }

    @MainActor
    static func importJSON(
        _ data: Data,
        into context: ModelContext,
        replaceExisting: Bool = false
    ) async throws {
        let payload = try await SyncPayloadWork.detached {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ExportPayload.self, from: data)
        }
        _ = try await importPayloadCooperatively(
            payload,
            into: context,
            replaceExisting: replaceExisting
        )
    }

    /// Validates and normalizes value-only data off the UI actor, then performs an in-place,
    /// single-save graph reconciliation on the view's ModelContext. Keeping existing models with
    /// matching IDs avoids leaving SwiftUI with stale objects after a background-context replace.
    @MainActor
    @discardableResult
    static func importPayloadCooperatively(
        _ payload: ExportPayload,
        into context: ModelContext,
        replaceExisting: Bool = false,
        expectedStoreRevision: UInt64? = nil
    ) async throws -> UInt64 {
        let preparedPayload: ExportPayload
        do {
            preparedPayload = try await SyncPayloadWork.detached {
                try ImportPayloadPreparer.prepare(payload, checksCancellation: true)
            }
        } catch let validationError as ImportPayloadValidationError {
            throw localizedValidationError(validationError)
        }

        try Task.checkCancellation()
        // Let a caller publish its loading barrier before this atomic MainActor mutation begins.
        await Task.yield()
        try Task.checkCancellation()
        guard !context.hasChanges else {
            throw ImportExportConsistencyError.storeChanged
        }
        let validatedStoreRevision = ModelStoreRevisionClock.shared.currentRevision()
        if let expectedStoreRevision,
           validatedStoreRevision != expectedStoreRevision {
            throw ImportExportConsistencyError.storeChanged
        }
        try await applyPreparedPayload(
            preparedPayload,
            into: context,
            replaceExisting: replaceExisting,
            expectedStoreRevision: validatedStoreRevision
        )
        // Capture the exact revision synchronously after the atomic save. Callers must
        // not sample the global clock after another actor suspension, because a newer
        // local save would then be mistaken for data included in this payload.
        return ModelStoreRevisionClock.shared.currentRevision()
    }

    @MainActor
    private static func applyPreparedPayload(
        _ payload: ExportPayload,
        into context: ModelContext,
        replaceExisting: Bool,
        expectedStoreRevision: UInt64
    ) async throws {
        let previousAutosaveSetting = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosaveSetting }

        do {
            var processedObjectCount = 0
            try Task.checkCancellation()
            let existingCategories = try context.fetch(FetchDescriptor<AssetCategory>())
            if !existingCategories.isEmpty && !replaceExisting {
                return
            }
            let existingItems = try context.fetch(FetchDescriptor<AssetItem>())
            let existingSnapshots = try context.fetch(FetchDescriptor<AssetSnapshot>())
            let existingEntries = try context.fetch(FetchDescriptor<AssetEntry>())
            let existingTombstones = try context.fetch(FetchDescriptor<SyncDeletionTombstone>())
            try Task.checkCancellation()

            var categoryMap: [UUID: AssetCategory] = [:]
            for category in existingCategories {
                processedObjectCount &+= 1
                try await cooperativeImportCheckpoint(
                    after: processedObjectCount,
                    expectedStoreRevision: expectedStoreRevision
                )
                if let current = categoryMap[category.id], current.createdAt >= category.createdAt {
                    continue
                }
                categoryMap[category.id] = category
            }
            var itemMap: [UUID: AssetItem] = [:]
            for item in existingItems {
                processedObjectCount &+= 1
                try await cooperativeImportCheckpoint(
                    after: processedObjectCount,
                    expectedStoreRevision: expectedStoreRevision
                )
                if let current = itemMap[item.id], current.updatedAt >= item.updatedAt {
                    continue
                }
                itemMap[item.id] = item
            }
            var snapshotMap: [UUID: AssetSnapshot] = [:]
            for snapshot in existingSnapshots {
                processedObjectCount &+= 1
                try await cooperativeImportCheckpoint(
                    after: processedObjectCount,
                    expectedStoreRevision: expectedStoreRevision
                )
                if let current = snapshotMap[snapshot.id], current.updatedAt >= snapshot.updatedAt {
                    continue
                }
                snapshotMap[snapshot.id] = snapshot
            }
            var entryMap: [UUID: AssetEntry] = [:]
            for entry in existingEntries {
                processedObjectCount &+= 1
                try await cooperativeImportCheckpoint(
                    after: processedObjectCount,
                    expectedStoreRevision: expectedStoreRevision
                )
                if let current = entryMap[entry.id], current.updatedAt >= entry.updatedAt {
                    continue
                }
                entryMap[entry.id] = entry
            }

            for categoryPayload in payload.categories {
                processedObjectCount &+= 1
                try await cooperativeImportCheckpoint(
                    after: processedObjectCount,
                    expectedStoreRevision: expectedStoreRevision
                )
                let category: AssetCategory
                if let existing = categoryMap[categoryPayload.id] {
                    category = existing
                    let targetGroupRawValue = (AssetGroup(rawValue: categoryPayload.group) ?? .financial).rawValue
                    if category.name != categoryPayload.name {
                        category.name = categoryPayload.name
                    }
                    if category.groupRawValue != targetGroupRawValue {
                        category.groupRawValue = targetGroupRawValue
                    }
                    if category.createdAt != categoryPayload.createdAt {
                        category.createdAt = categoryPayload.createdAt
                    }
                } else {
                    category = AssetCategory(
                        id: categoryPayload.id,
                        name: categoryPayload.name,
                        group: AssetGroup(rawValue: categoryPayload.group) ?? .financial,
                        createdAt: categoryPayload.createdAt
                    )
                    context.insert(category)
                    categoryMap[category.id] = category
                }
            }

            for itemPayload in payload.items {
                processedObjectCount &+= 1
                try await cooperativeImportCheckpoint(
                    after: processedObjectCount,
                    expectedStoreRevision: expectedStoreRevision
                )
                let item: AssetItem
                if let existing = itemMap[itemPayload.id] {
                    item = existing
                    let targetIconName = itemPayload.iconName ?? ""
                    let targetValuationMethodRawValue = (
                        ValuationMethod(rawValue: itemPayload.valuationMethod) ?? .directAmount
                    ).rawValue
                    let targetAutoPricedAssetKindRawValue = itemPayload.autoPricedAssetKind
                        .map(BacktestAssetSymbol.normalized)
                    let targetQuantStrategyProxySymbolRawValue = itemPayload.quantStrategyProxySymbol
                        .map(BacktestAssetSymbol.normalized)
                    let targetCategory = itemPayload.categoryID.flatMap { categoryMap[$0] }

                    if item.name != itemPayload.name {
                        item.name = itemPayload.name
                    }
                    if item.note != itemPayload.note {
                        item.note = itemPayload.note
                    }
                    // Nil and an empty icon name serialize identically. Preserve nil when both
                    // represent "no custom icon" so a no-op restore does not dirty the item.
                    if (item.iconName ?? "") != targetIconName {
                        item.iconName = targetIconName
                    }
                    if item.valuationMethodRawValue != targetValuationMethodRawValue {
                        item.valuationMethodRawValue = targetValuationMethodRawValue
                    }
                    if item.autoPricedAssetKindRawValue != targetAutoPricedAssetKindRawValue {
                        item.autoPricedAssetKindRawValue = targetAutoPricedAssetKindRawValue
                    }
                    if item.quantStrategyProxySymbolRawValue != targetQuantStrategyProxySymbolRawValue {
                        item.quantStrategyProxySymbolRawValue = targetQuantStrategyProxySymbolRawValue
                    }
                    if item.sortOrder != itemPayload.sortOrder {
                        item.sortOrder = itemPayload.sortOrder
                    }
                    if item.isActive != itemPayload.isActive {
                        item.isActive = itemPayload.isActive
                    }
                    if item.createdAt != itemPayload.createdAt {
                        item.createdAt = itemPayload.createdAt
                    }
                    if item.updatedAt != itemPayload.updatedAt {
                        item.updatedAt = itemPayload.updatedAt
                    }
                    if item.category !== targetCategory {
                        item.category = targetCategory
                    }
                } else {
                    item = AssetItem(
                        id: itemPayload.id,
                        name: itemPayload.name,
                        note: itemPayload.note,
                        iconName: itemPayload.iconName ?? "",
                        valuationMethod: ValuationMethod(rawValue: itemPayload.valuationMethod) ?? .directAmount,
                        autoPricedAssetKind: itemPayload.autoPricedAssetKind.flatMap(AutoPricedAssetKind.init(rawValue:)),
                        quantStrategyProxySymbol: itemPayload.quantStrategyProxySymbol,
                        sortOrder: itemPayload.sortOrder,
                        isActive: itemPayload.isActive,
                        createdAt: itemPayload.createdAt,
                        updatedAt: itemPayload.updatedAt,
                        category: itemPayload.categoryID.flatMap { categoryMap[$0] }
                    )
                    item.marketAssetSymbol = itemPayload.autoPricedAssetKind
                    context.insert(item)
                    itemMap[item.id] = item
                }
            }

            for snapshotPayload in payload.snapshots {
                processedObjectCount &+= 1
                try await cooperativeImportCheckpoint(
                    after: processedObjectCount,
                    expectedStoreRevision: expectedStoreRevision
                )
                let snapshot: AssetSnapshot
                if let existing = snapshotMap[snapshotPayload.id] {
                    snapshot = existing
                    if snapshot.date != snapshotPayload.date {
                        snapshot.date = snapshotPayload.date
                    }
                    if snapshot.note != snapshotPayload.note {
                        snapshot.note = snapshotPayload.note
                    }
                    if snapshot.createdAt != snapshotPayload.createdAt {
                        snapshot.createdAt = snapshotPayload.createdAt
                    }
                    if snapshot.updatedAt != snapshotPayload.updatedAt {
                        snapshot.updatedAt = snapshotPayload.updatedAt
                    }
                    if snapshot.goldAnchorPriceCNY != snapshotPayload.goldAnchorPriceCNY {
                        snapshot.goldAnchorPriceCNY = snapshotPayload.goldAnchorPriceCNY
                    }
                    if snapshot.goldAnchorPriceDate != snapshotPayload.goldAnchorPriceDate {
                        snapshot.goldAnchorPriceDate = snapshotPayload.goldAnchorPriceDate
                    }
                    if snapshot.btcAnchorPriceUSD != snapshotPayload.btcAnchorPriceUSD {
                        snapshot.btcAnchorPriceUSD = snapshotPayload.btcAnchorPriceUSD
                    }
                    if snapshot.btcAnchorPriceDate != snapshotPayload.btcAnchorPriceDate {
                        snapshot.btcAnchorPriceDate = snapshotPayload.btcAnchorPriceDate
                    }
                    if snapshot.nasdaqAnchorPriceUSD != snapshotPayload.nasdaqAnchorPriceUSD {
                        snapshot.nasdaqAnchorPriceUSD = snapshotPayload.nasdaqAnchorPriceUSD
                    }
                    if snapshot.nasdaqAnchorPriceDate != snapshotPayload.nasdaqAnchorPriceDate {
                        snapshot.nasdaqAnchorPriceDate = snapshotPayload.nasdaqAnchorPriceDate
                    }
                    if snapshot.usdPerCNY != snapshotPayload.usdPerCNY {
                        snapshot.usdPerCNY = snapshotPayload.usdPerCNY
                    }
                    if snapshot.usdPerCNYDate != snapshotPayload.usdPerCNYDate {
                        snapshot.usdPerCNYDate = snapshotPayload.usdPerCNYDate
                    }
                    if snapshot.marketAnchorsUpdatedAt != snapshotPayload.marketAnchorsUpdatedAt {
                        snapshot.marketAnchorsUpdatedAt = snapshotPayload.marketAnchorsUpdatedAt
                    }
                } else {
                    snapshot = AssetSnapshot(
                        id: snapshotPayload.id,
                        date: snapshotPayload.date,
                        note: snapshotPayload.note,
                        createdAt: snapshotPayload.createdAt,
                        updatedAt: snapshotPayload.updatedAt,
                        goldAnchorPriceCNY: snapshotPayload.goldAnchorPriceCNY,
                        goldAnchorPriceDate: snapshotPayload.goldAnchorPriceDate,
                        btcAnchorPriceUSD: snapshotPayload.btcAnchorPriceUSD,
                        btcAnchorPriceDate: snapshotPayload.btcAnchorPriceDate,
                        nasdaqAnchorPriceUSD: snapshotPayload.nasdaqAnchorPriceUSD,
                        nasdaqAnchorPriceDate: snapshotPayload.nasdaqAnchorPriceDate,
                        usdPerCNY: snapshotPayload.usdPerCNY,
                        usdPerCNYDate: snapshotPayload.usdPerCNYDate,
                        marketAnchorsUpdatedAt: snapshotPayload.marketAnchorsUpdatedAt
                    )
                    context.insert(snapshot)
                    snapshotMap[snapshot.id] = snapshot
                }

                for entryPayload in snapshotPayload.entries {
                    processedObjectCount &+= 1
                    try await cooperativeImportCheckpoint(
                        after: processedObjectCount,
                        expectedStoreRevision: expectedStoreRevision
                    )
                    let item = entryPayload.itemID.flatMap { itemMap[$0] }
                    if let entry = entryMap[entryPayload.id] {
                        if entry.amount != entryPayload.amount {
                            entry.amount = entryPayload.amount
                        }
                        if entry.quantity != entryPayload.quantity {
                            entry.quantity = entryPayload.quantity
                        }
                        if entry.unitPrice != entryPayload.unitPrice {
                            entry.unitPrice = entryPayload.unitPrice
                        }
                        if entry.note != entryPayload.note {
                            entry.note = entryPayload.note
                        }
                        if entry.createdAt != entryPayload.createdAt {
                            entry.createdAt = entryPayload.createdAt
                        }
                        if entry.updatedAt != entryPayload.updatedAt {
                            entry.updatedAt = entryPayload.updatedAt
                        }
                        // Identity comparison is intentional: duplicate-ID cleanup below keeps
                        // only the canonical model object, so relationships must point to that
                        // exact instance even when the old related object's domain ID matches.
                        if entry.snapshot !== snapshot {
                            entry.snapshot = snapshot
                        }
                        if entry.item !== item {
                            entry.item = item
                        }
                    } else {
                        let entry = AssetEntry(
                            id: entryPayload.id,
                            amount: entryPayload.amount,
                            quantity: entryPayload.quantity,
                            unitPrice: entryPayload.unitPrice,
                            note: entryPayload.note,
                            createdAt: entryPayload.createdAt,
                            updatedAt: entryPayload.updatedAt,
                            snapshot: snapshot,
                            item: item
                        )
                        context.insert(entry)
                        entryMap[entry.id] = entry
                    }
                }
            }

            var tombstoneMap: [String: SyncDeletionTombstone] = [:]
            for tombstone in existingTombstones {
                processedObjectCount &+= 1
                try await cooperativeImportCheckpoint(
                    after: processedObjectCount,
                    expectedStoreRevision: expectedStoreRevision
                )
                tombstoneMap[tombstoneKey(entityID: tombstone.entityID, kind: tombstone.entityKindRawValue)] = tombstone
            }
            var payloadTombstoneKeys: Set<String> = []
            for deletion in payload.deletionRecords {
                processedObjectCount &+= 1
                try await cooperativeImportCheckpoint(
                    after: processedObjectCount,
                    expectedStoreRevision: expectedStoreRevision
                )
                guard let kind = SyncDeletedEntityKind(rawValue: deletion.entityKind) else { continue }
                let key = tombstoneKey(entityID: deletion.entityID, kind: deletion.entityKind)
                payloadTombstoneKeys.insert(key)
                if let tombstone = tombstoneMap[key] {
                    if tombstone.deletedAt != deletion.deletedAt {
                        tombstone.deletedAt = deletion.deletedAt
                    }
                } else {
                    context.insert(SyncDeletionTombstone(
                        entityID: deletion.entityID,
                        entityKind: kind,
                        deletedAt: deletion.deletedAt
                    ))
                }
            }

            if replaceExisting {
                var categoryIDs = Set<UUID>()
                categoryIDs.reserveCapacity(payload.categories.count)
                for category in payload.categories {
                    processedObjectCount &+= 1
                    try await cooperativeImportCheckpoint(
                        after: processedObjectCount,
                        expectedStoreRevision: expectedStoreRevision
                    )
                    categoryIDs.insert(category.id)
                }

                var itemIDs = Set<UUID>()
                itemIDs.reserveCapacity(payload.items.count)
                for item in payload.items {
                    processedObjectCount &+= 1
                    try await cooperativeImportCheckpoint(
                        after: processedObjectCount,
                        expectedStoreRevision: expectedStoreRevision
                    )
                    itemIDs.insert(item.id)
                }

                var snapshotIDs = Set<UUID>()
                snapshotIDs.reserveCapacity(payload.snapshots.count)
                var entryIDs = Set<UUID>()
                entryIDs.reserveCapacity(existingEntries.count)
                for snapshot in payload.snapshots {
                    processedObjectCount &+= 1
                    try await cooperativeImportCheckpoint(
                        after: processedObjectCount,
                        expectedStoreRevision: expectedStoreRevision
                    )
                    snapshotIDs.insert(snapshot.id)
                    for entry in snapshot.entries {
                        processedObjectCount &+= 1
                        try await cooperativeImportCheckpoint(
                            after: processedObjectCount,
                            expectedStoreRevision: expectedStoreRevision
                        )
                        entryIDs.insert(entry.id)
                    }
                }

                for entry in existingEntries {
                    processedObjectCount &+= 1
                    try await cooperativeImportCheckpoint(
                        after: processedObjectCount,
                        expectedStoreRevision: expectedStoreRevision
                    )
                    if !entryIDs.contains(entry.id) || entryMap[entry.id] !== entry {
                        context.delete(entry)
                    }
                }
                for snapshot in existingSnapshots {
                    processedObjectCount &+= 1
                    try await cooperativeImportCheckpoint(
                        after: processedObjectCount,
                        expectedStoreRevision: expectedStoreRevision
                    )
                    if !snapshotIDs.contains(snapshot.id) || snapshotMap[snapshot.id] !== snapshot {
                        context.delete(snapshot)
                    }
                }
                for item in existingItems {
                    processedObjectCount &+= 1
                    try await cooperativeImportCheckpoint(
                        after: processedObjectCount,
                        expectedStoreRevision: expectedStoreRevision
                    )
                    if !itemIDs.contains(item.id) || itemMap[item.id] !== item {
                        context.delete(item)
                    }
                }
                for category in existingCategories {
                    processedObjectCount &+= 1
                    try await cooperativeImportCheckpoint(
                        after: processedObjectCount,
                        expectedStoreRevision: expectedStoreRevision
                    )
                    if !categoryIDs.contains(category.id) || categoryMap[category.id] !== category {
                        context.delete(category)
                    }
                }
                for tombstone in existingTombstones {
                    processedObjectCount &+= 1
                    try await cooperativeImportCheckpoint(
                        after: processedObjectCount,
                        expectedStoreRevision: expectedStoreRevision
                    )
                    let key = tombstoneKey(entityID: tombstone.entityID, kind: tombstone.entityKindRawValue)
                    if !payloadTombstoneKeys.contains(key) {
                        context.delete(tombstone)
                    }
                }
            }

            try Task.checkCancellation()
            guard ModelStoreRevisionClock.shared.currentRevision() == expectedStoreRevision else {
                throw ImportExportConsistencyError.storeChanged
            }
            if context.hasChanges {
                try context.save()
            }
        } catch {
            context.rollback()
            throw error
        }
    }

    @MainActor
    private static func cooperativeImportCheckpoint(
        after processedObjectCount: Int,
        expectedStoreRevision: UInt64
    ) async throws {
        guard processedObjectCount.isMultiple(of: 128) else { return }
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        guard ModelStoreRevisionClock.shared.currentRevision() == expectedStoreRevision else {
            throw ImportExportConsistencyError.storeChanged
        }
    }

    nonisolated private static func tombstoneKey(entityID: UUID, kind: String) -> String {
        "\(kind):\(entityID.uuidString)"
    }

    @MainActor
    private static func localizedValidationError(_ error: ImportPayloadValidationError) -> NSError {
        let description: String
        switch error {
        case .duplicateCategory:
            description = AppLocalization.format("云端数据中存在重复的%@", AppLocalization.string("资产分类"))
        case .duplicateItem:
            description = AppLocalization.format("云端数据中存在重复的%@", AppLocalization.string("资产项目"))
        case .duplicateSnapshot:
            description = AppLocalization.format("云端数据中存在重复的%@", AppLocalization.string("资产记录"))
        case .duplicateEntry:
            description = AppLocalization.format("云端数据中存在重复的%@", AppLocalization.string("资产条目"))
        case .duplicateItemReference:
            description = AppLocalization.format("云端数据中存在重复的%@", AppLocalization.string("资产项目引用"))
        case .unknownCategoryReference:
            description = AppLocalization.string("云端数据中存在无法识别的资产分类引用")
        case .unknownItemReference:
            description = AppLocalization.string("云端数据中存在无法识别的资产项目引用")
        }

        return NSError(
            domain: "ImportExportService",
            code: 422,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

enum SyncDeletionService {
    @MainActor
    static func record(
        entityID: UUID,
        kind: SyncDeletedEntityKind,
        deletedAt: Date = .now,
        in context: ModelContext
    ) throws {
        let kindRawValue = kind.rawValue
        let predicate = #Predicate<SyncDeletionTombstone> { tombstone in
            tombstone.entityID == entityID && tombstone.entityKindRawValue == kindRawValue
        }
        var descriptor = FetchDescriptor<SyncDeletionTombstone>(predicate: predicate)
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            existing.deletedAt = max(existing.deletedAt, deletedAt)
        } else {
            context.insert(SyncDeletionTombstone(
                entityID: entityID,
                entityKind: kind,
                deletedAt: deletedAt
            ))
        }
    }
}

nonisolated enum SyncMergeService {
    static func mergedPayload(local: ExportPayload, remote: ExportPayload) -> ExportPayload {
        let localNormalized = normalized(local)
        let remoteNormalized = normalized(remote)
        let deletions = mergeDeletions(
            local: localNormalized.deletionRecords,
            remote: remoteNormalized.deletionRecords
        )

        let categories = mergeCategories(local: localNormalized.categories, remote: remoteNormalized.categories)
        let items = mergeByUpdatedAt(local: localNormalized.items, remote: remoteNormalized.items, id: \.id, updatedAt: \.updatedAt)
        let snapshots = mergeSnapshots(local: localNormalized.snapshots, remote: remoteNormalized.snapshots)

        return normalized(payloadApplyingDeletions(ExportPayload(
            exportedAt: max(local.exportedAt, remote.exportedAt, Date()),
            categories: categories,
            items: items,
            snapshots: snapshots,
            deletions: deletions
        )))
    }

    static func canonicalData(for payload: ExportPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let contentPayload = ExportPayload(
            exportedAt: Date(timeIntervalSince1970: 0),
            categories: payload.categories,
            items: payload.items,
            snapshots: payload.snapshots,
            deletions: payload.deletionRecords
        )
        return try encoder.encode(normalized(contentPayload))
    }

    static func isSameContent(_ lhs: ExportPayload, _ rhs: ExportPayload) -> Bool {
        (try? canonicalData(for: lhs)) == (try? canonicalData(for: rhs))
    }

    static func looksLikeSeedOnly(_ payload: ExportPayload) -> Bool {
        guard payload.snapshots.isEmpty, payload.deletionRecords.isEmpty else { return false }
        let categoryGroups = Set(payload.categories.map(\.group))
        guard categoryGroups.isSubset(of: [AssetGroup.financial.rawValue, AssetGroup.physical.rawValue, AssetGroup.liability.rawValue]) else {
            return false
        }
        let seedItemNames: Set<String> = [
            "微信", "支付宝", "银行卡", "现金",
            "房产", "车辆", "车位",
            "花呗", "白条", "房贷",
        ]
        let itemNames = Set(payload.items.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        return itemNames.isSubset(of: seedItemNames) && payload.categories.count <= 3 && payload.items.count <= seedItemNames.count
    }

    static func isEmptyUserData(_ payload: ExportPayload) -> Bool {
        payload.snapshots.isEmpty
            && payload.items.isEmpty
            && payload.categories.isEmpty
            && payload.deletionRecords.isEmpty
    }

    static func payloadApplyingDeletions(_ payload: ExportPayload) -> ExportPayload {
        let deletions = mergeDeletions(local: payload.deletionRecords, remote: [])
        let deletionKeys = Set(deletions.compactMap { deletion -> DeletionKey? in
            guard let kind = SyncDeletedEntityKind(rawValue: deletion.entityKind) else { return nil }
            return DeletionKey(kind: kind, entityID: deletion.entityID)
        })

        let categories = payload.categories.filter {
            !deletionKeys.contains(DeletionKey(kind: .category, entityID: $0.id))
        }
        let categoryIDs = Set(categories.map(\.id))
        let items = payload.items.filter { item in
            !deletionKeys.contains(DeletionKey(kind: .item, entityID: item.id))
                && item.categoryID.map { categoryIDs.contains($0) } != false
        }
        let itemIDs = Set(items.map(\.id))
        let snapshots = payload.snapshots.compactMap { snapshot -> ExportPayload.SnapshotPayload? in
            guard !deletionKeys.contains(DeletionKey(kind: .snapshot, entityID: snapshot.id)) else {
                return nil
            }
            let entries = snapshot.entries.filter { entry in
                !deletionKeys.contains(DeletionKey(kind: .entry, entityID: entry.id))
                    && entry.itemID.map { itemIDs.contains($0) } != false
            }
            return ExportPayload.SnapshotPayload(
                id: snapshot.id,
                date: snapshot.date,
                note: snapshot.note,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt,
                goldAnchorPriceCNY: snapshot.goldAnchorPriceCNY,
                goldAnchorPriceDate: snapshot.goldAnchorPriceDate,
                btcAnchorPriceUSD: snapshot.btcAnchorPriceUSD,
                btcAnchorPriceDate: snapshot.btcAnchorPriceDate,
                nasdaqAnchorPriceUSD: snapshot.nasdaqAnchorPriceUSD,
                nasdaqAnchorPriceDate: snapshot.nasdaqAnchorPriceDate,
                usdPerCNY: snapshot.usdPerCNY,
                usdPerCNYDate: snapshot.usdPerCNYDate,
                marketAnchorsUpdatedAt: snapshot.marketAnchorsUpdatedAt,
                entries: entries
            )
        }

        return ExportPayload(
            exportedAt: payload.exportedAt,
            categories: categories,
            items: items,
            snapshots: snapshots,
            deletions: deletions
        )
    }

    private static func mergeCategories(local: [ExportPayload.CategoryPayload], remote: [ExportPayload.CategoryPayload]) -> [ExportPayload.CategoryPayload] {
        var merged: [UUID: ExportPayload.CategoryPayload] = [:]
        for category in remote {
            merged[category.id] = category
        }
        for category in local {
            // Category currently has no updatedAt in the persisted model. Prefer the local copy for same UUID,
            // while still preserving remote-only categories. This avoids destructive category loss during sync.
            merged[category.id] = category
        }
        return Array(merged.values)
    }

    private static func mergeSnapshots(local: [ExportPayload.SnapshotPayload], remote: [ExportPayload.SnapshotPayload]) -> [ExportPayload.SnapshotPayload] {
        let remoteByID = keyedByID(remote, id: \.id)
        let localByID = keyedByID(local, id: \.id)
        let allIDs = Set(remoteByID.keys).union(localByID.keys)

        return allIDs.compactMap { id in
            switch (localByID[id], remoteByID[id]) {
            case let (local?, remote?):
                let base = local.updatedAt >= remote.updatedAt ? local : remote
                let entries = mergeEntries(local: local.entries, remote: remote.entries)
                return ExportPayload.SnapshotPayload(
                    id: base.id,
                    date: base.date,
                    note: base.note,
                    createdAt: min(local.createdAt, remote.createdAt),
                    updatedAt: max(local.updatedAt, remote.updatedAt),
                    goldAnchorPriceCNY: newerOptional(localValue: local.goldAnchorPriceCNY, localUpdatedAt: local.marketAnchorsUpdatedAt ?? local.updatedAt, remoteValue: remote.goldAnchorPriceCNY, remoteUpdatedAt: remote.marketAnchorsUpdatedAt ?? remote.updatedAt),
                    goldAnchorPriceDate: newerOptional(localValue: local.goldAnchorPriceDate, localUpdatedAt: local.marketAnchorsUpdatedAt ?? local.updatedAt, remoteValue: remote.goldAnchorPriceDate, remoteUpdatedAt: remote.marketAnchorsUpdatedAt ?? remote.updatedAt),
                    btcAnchorPriceUSD: newerOptional(localValue: local.btcAnchorPriceUSD, localUpdatedAt: local.marketAnchorsUpdatedAt ?? local.updatedAt, remoteValue: remote.btcAnchorPriceUSD, remoteUpdatedAt: remote.marketAnchorsUpdatedAt ?? remote.updatedAt),
                    btcAnchorPriceDate: newerOptional(localValue: local.btcAnchorPriceDate, localUpdatedAt: local.marketAnchorsUpdatedAt ?? local.updatedAt, remoteValue: remote.btcAnchorPriceDate, remoteUpdatedAt: remote.marketAnchorsUpdatedAt ?? remote.updatedAt),
                    nasdaqAnchorPriceUSD: newerOptional(localValue: local.nasdaqAnchorPriceUSD, localUpdatedAt: local.marketAnchorsUpdatedAt ?? local.updatedAt, remoteValue: remote.nasdaqAnchorPriceUSD, remoteUpdatedAt: remote.marketAnchorsUpdatedAt ?? remote.updatedAt),
                    nasdaqAnchorPriceDate: newerOptional(localValue: local.nasdaqAnchorPriceDate, localUpdatedAt: local.marketAnchorsUpdatedAt ?? local.updatedAt, remoteValue: remote.nasdaqAnchorPriceDate, remoteUpdatedAt: remote.marketAnchorsUpdatedAt ?? remote.updatedAt),
                    usdPerCNY: newerOptional(localValue: local.usdPerCNY, localUpdatedAt: local.marketAnchorsUpdatedAt ?? local.updatedAt, remoteValue: remote.usdPerCNY, remoteUpdatedAt: remote.marketAnchorsUpdatedAt ?? remote.updatedAt),
                    usdPerCNYDate: newerOptional(localValue: local.usdPerCNYDate, localUpdatedAt: local.marketAnchorsUpdatedAt ?? local.updatedAt, remoteValue: remote.usdPerCNYDate, remoteUpdatedAt: remote.marketAnchorsUpdatedAt ?? remote.updatedAt),
                    marketAnchorsUpdatedAt: maxOptional(local.marketAnchorsUpdatedAt, remote.marketAnchorsUpdatedAt),
                    entries: entries
                )
            case let (local?, nil):
                return local
            case let (nil, remote?):
                return remote
            default:
                return nil
            }
        }
    }

    private static func mergeEntries(local: [ExportPayload.EntryPayload], remote: [ExportPayload.EntryPayload]) -> [ExportPayload.EntryPayload] {
        mergeByUpdatedAt(local: local, remote: remote, id: \.id, updatedAt: \.updatedAt)
    }

    private static func mergeByUpdatedAt<T, ID: Hashable>(local: [T], remote: [T], id: KeyPath<T, ID>, updatedAt: KeyPath<T, Date>) -> [T] {
        var merged: [ID: T] = [:]
        for value in remote {
            let key = value[keyPath: id]
            if let existing = merged[key] {
                merged[key] = value[keyPath: updatedAt] >= existing[keyPath: updatedAt] ? value : existing
            } else {
                merged[key] = value
            }
        }
        for value in local {
            let key = value[keyPath: id]
            if let existing = merged[key] {
                merged[key] = value[keyPath: updatedAt] >= existing[keyPath: updatedAt] ? value : existing
            } else {
                merged[key] = value
            }
        }
        return Array(merged.values)
    }

    private static func keyedByID<T, ID: Hashable>(_ values: [T], id: KeyPath<T, ID>) -> [ID: T] {
        values.reduce(into: [:]) { result, value in
            result[value[keyPath: id]] = value
        }
    }

    private static func mergeDeletions(
        local: [ExportPayload.DeletionPayload],
        remote: [ExportPayload.DeletionPayload]
    ) -> [ExportPayload.DeletionPayload] {
        var merged: [DeletionKey: ExportPayload.DeletionPayload] = [:]
        for deletion in remote + local {
            guard let kind = SyncDeletedEntityKind(rawValue: deletion.entityKind) else { continue }
            let key = DeletionKey(kind: kind, entityID: deletion.entityID)
            if let existing = merged[key], existing.deletedAt > deletion.deletedAt {
                continue
            }
            merged[key] = deletion
        }
        return Array(merged.values)
    }

    private static func newerOptional<T>(localValue: T?, localUpdatedAt: Date, remoteValue: T?, remoteUpdatedAt: Date) -> T? {
        localUpdatedAt >= remoteUpdatedAt ? localValue : remoteValue
    }

    private static func maxOptional(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        default: return nil
        }
    }

    private static func normalized(_ payload: ExportPayload) -> ExportPayload {
        ExportPayload(
            exportedAt: payload.exportedAt,
            categories: payload.categories.sorted { $0.id.uuidString < $1.id.uuidString },
            items: payload.items.sorted { $0.id.uuidString < $1.id.uuidString },
            snapshots: payload.snapshots
                .map { snapshot in
                    ExportPayload.SnapshotPayload(
                        id: snapshot.id,
                        date: snapshot.date,
                        note: snapshot.note,
                        createdAt: snapshot.createdAt,
                        updatedAt: snapshot.updatedAt,
                        goldAnchorPriceCNY: snapshot.goldAnchorPriceCNY,
                        goldAnchorPriceDate: snapshot.goldAnchorPriceDate,
                        btcAnchorPriceUSD: snapshot.btcAnchorPriceUSD,
                        btcAnchorPriceDate: snapshot.btcAnchorPriceDate,
                        nasdaqAnchorPriceUSD: snapshot.nasdaqAnchorPriceUSD,
                        nasdaqAnchorPriceDate: snapshot.nasdaqAnchorPriceDate,
                        usdPerCNY: snapshot.usdPerCNY,
                        usdPerCNYDate: snapshot.usdPerCNYDate,
                        marketAnchorsUpdatedAt: snapshot.marketAnchorsUpdatedAt,
                        entries: snapshot.entries.sorted { $0.id.uuidString < $1.id.uuidString }
                    )
                }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            deletions: payload.deletionRecords.sorted {
                if $0.entityKind == $1.entityKind {
                    return $0.entityID.uuidString < $1.entityID.uuidString
                }
                return $0.entityKind < $1.entityKind
            }
        )
    }

    private struct DeletionKey: Hashable {
        let kind: SyncDeletedEntityKind
        let entityID: UUID
    }
}
