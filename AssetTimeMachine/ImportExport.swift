#if !os(macOS) || targetEnvironment(macCatalyst)
import AssetTimeMachineBacktestCore
#endif
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
        var inheritedFromEntryID: UUID? = nil
    }

    nonisolated struct DeletionPayload: Codable, Sendable {
        let entityID: UUID
        let entityKind: String
        let deletedAt: Date
        var snapshotDate: Date? = nil
        var itemID: UUID? = nil
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
    private static let fetchBatchSize = 128

    func exportPayload() throws -> ExportPayload {
        var result: ExportPayload?

        // The caller compares a synchronous global save revision before and after
        // this materialization, discarding the payload if another context commits.
        do {
            try Task.checkCancellation()
            let categories = try modelContext.fetch(FetchDescriptor<AssetCategory>())
            let items = try modelContext.fetch(FetchDescriptor<AssetItem>())
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
            var entryOffset = 0
            while true {
                try Task.checkCancellation()
                var descriptor = FetchDescriptor<AssetEntry>(sortBy: [SortDescriptor(\AssetEntry.id)])
                descriptor.fetchLimit = Self.fetchBatchSize
                descriptor.fetchOffset = entryOffset
                let batch = try autoreleasepool { () throws -> (Int, [(UUID, ExportPayload.EntryPayload)]) in
                    let context = ModelContext(modelContainer)
                    let entries = try context.fetch(descriptor)
                    return (entries.count, entries.compactMap { entry in
                        guard let snapshotID = entry.snapshot?.id else { return nil }
                        return (snapshotID, .init(
                            id: entry.id,
                            amount: entry.amount,
                            quantity: entry.quantity,
                            unitPrice: entry.unitPrice,
                            note: entry.note,
                            createdAt: entry.createdAt,
                            updatedAt: entry.updatedAt,
                            itemID: entry.item?.id,
                            inheritedFromEntryID: entry.inheritedFromEntryID
                        ))
                    })
                }
                for (snapshotID, entry) in batch.1 {
                    entryPayloadsBySnapshotID[snapshotID, default: []].append(entry)
                }
                entryOffset += Self.fetchBatchSize
                if batch.0 < Self.fetchBatchSize { break }
            }

            var snapshotPayloads: [ExportPayload.SnapshotPayload] = []
            var snapshotOffset = 0
            while true {
                try Task.checkCancellation()
                var descriptor = FetchDescriptor<AssetSnapshot>(sortBy: [SortDescriptor(\AssetSnapshot.id)])
                descriptor.fetchLimit = Self.fetchBatchSize
                descriptor.fetchOffset = snapshotOffset
                let batch = try autoreleasepool { () throws -> [ExportPayload.SnapshotPayload] in
                    let context = ModelContext(modelContainer)
                    return try context.fetch(descriptor).map { snapshot in
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
                            entries: entryPayloadsBySnapshotID.removeValue(forKey: snapshot.id) ?? []
                        )
                    }
                }
                snapshotPayloads.append(contentsOf: batch)
                snapshotOffset += Self.fetchBatchSize
                if batch.count < Self.fetchBatchSize { break }
            }

            var deletionPayloads: [ExportPayload.DeletionPayload] = []
            deletionPayloads.reserveCapacity(tombstones.count)
            for (index, tombstone) in tombstones.enumerated() {
                if let entityKind = tombstone.entityKind {
                    deletionPayloads.append(.init(
                        entityID: tombstone.entityID,
                        entityKind: entityKind.rawValue,
                        deletedAt: tombstone.deletedAt,
                        snapshotDate: tombstone.snapshotDate, itemID: tombstone.itemID
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
                            itemID: $0.item?.id,
                            inheritedFromEntryID: $0.inheritedFromEntryID
                        )
                    }
                )
            },
            deletions: tombstones.compactMap { tombstone in
                guard let entityKind = tombstone.entityKind else { return nil }
                return .init(
                    entityID: tombstone.entityID,
                    entityKind: entityKind.rawValue,
                    deletedAt: tombstone.deletedAt,
                        snapshotDate: tombstone.snapshotDate, itemID: tombstone.itemID
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
        MacMemoryRelief.scheduleAfterHeavyOperation()
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
                        if entry.inheritedFromEntryID != entryPayload.inheritedFromEntryID {
                            entry.inheritedFromEntryID = entryPayload.inheritedFromEntryID
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
                            item: item,
                            inheritedFromEntryID: entryPayload.inheritedFromEntryID
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
                    tombstone.snapshotDate = deletion.snapshotDate ?? tombstone.snapshotDate
                    tombstone.itemID = deletion.itemID ?? tombstone.itemID
                } else {
                    context.insert(SyncDeletionTombstone(
                        entityID: deletion.entityID,
                        entityKind: kind,
                        deletedAt: deletion.deletedAt,
                        snapshotDate: deletion.snapshotDate, itemID: deletion.itemID
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
        var snapshotDate: Date?
        var itemID: UUID?
        if kind == .snapshot {
            var request = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == entityID })
            request.fetchLimit = 1
            snapshotDate = try context.fetch(request).first?.date
        } else if kind == .entry {
            var request = FetchDescriptor<AssetEntry>(predicate: #Predicate { $0.id == entityID })
            request.fetchLimit = 1
            if let entry = try context.fetch(request).first {
                snapshotDate = entry.snapshot?.date
                itemID = entry.item?.id
            }
        }
        let kindRawValue = kind.rawValue
        let predicate = #Predicate<SyncDeletionTombstone> { tombstone in
            tombstone.entityID == entityID && tombstone.entityKindRawValue == kindRawValue
        }
        var descriptor = FetchDescriptor<SyncDeletionTombstone>(predicate: predicate)
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            existing.deletedAt = max(existing.deletedAt, deletedAt)
            existing.snapshotDate = existing.snapshotDate ?? snapshotDate
            existing.itemID = existing.itemID ?? itemID
        } else {
            context.insert(SyncDeletionTombstone(
                entityID: entityID,
                entityKind: kind,
                deletedAt: deletedAt,
                snapshotDate: snapshotDate,
                itemID: itemID
            ))
        }
    }
}

nonisolated enum SyncMergeService {
    static func mergedPayload(local: ExportPayload, remote: ExportPayload, baseline: ExportPayload? = nil) -> ExportPayload {
        let localNormalized = normalized(local)
        let remoteNormalized = normalized(remote)
        let deletions = mergeDeletions(
            local: localNormalized.deletionRecords,
            remote: remoteNormalized.deletionRecords
        )

        let categories = mergeCategories(local: localNormalized.categories, remote: remoteNormalized.categories, baseline: baseline?.categories)
        let items = mergeByUpdatedAt(local: localNormalized.items, remote: remoteNormalized.items, baseline: baseline?.items, id: \.id, updatedAt: \.updatedAt)
        let snapshots = mergeSnapshots(local: localNormalized.snapshots, remote: remoteNormalized.snapshots, baseline: baseline?.snapshots)

        return normalized(payloadApplyingDeletions(ExportPayload(
            exportedAt: max(local.exportedAt, remote.exportedAt, Date()),
            categories: categories,
            items: items,
            snapshots: snapshots,
            deletions: deletions
        )))
    }

    enum Conflict: LocalizedError {
        case divergentEdits
        var errorDescription: String? {
            "同一条数据在两端都有不同修改，已暂停同步以保留两端数据。请核对后选择恢复云端，或导出本机数据。"
        }
    }

    enum EntryField: String, Codable, Sendable { case amount, quantity, unitPrice, note }
    enum EntryChoice: String, Codable, Sendable { case local, remote }

    nonisolated struct EntryConflict: Identifiable, Sendable {
        let entryID: UUID
        let itemID: UUID?
        let date: Date
        let field: EntryField
        let localValue: Data
        let remoteValue: Data
        var id: String { entryID.uuidString + ":" + field.rawValue }
    }

    nonisolated struct EntryConflicts: LocalizedError, Sendable {
        let conflicts: [EntryConflict]
        var errorDescription: String? { Conflict.divergentEdits.errorDescription }
    }

    nonisolated struct EntryReviewResult: Sendable {
        // A diagnostic traversal can contain provisional values. Never expose a
        // candidate until every conflicting field has an explicit choice.
        let payload: ExportPayload?
        let conflicts: [EntryConflict]
    }

    nonisolated private final class EntryReviewContext {
        let choices: [String: EntryChoice]
        var conflicts: [EntryConflict] = []
        var unresolved = false
        init(choices: [String: EntryChoice]) { self.choices = choices }

        func value<T: Equatable & Encodable>(_ local: T, _ remote: T, _ baseline: T?,
            entry: ExportPayload.EntryPayload, date: Date, field: EntryField) throws -> T {
            do { return try mergeValue(local, remote, baseline) }
            catch Conflict.divergentEdits {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let conflict = EntryConflict(entryID: entry.id, itemID: entry.itemID, date: date,
                    field: field, localValue: try encoder.encode(local), remoteValue: try encoder.encode(remote))
                conflicts.append(conflict)
                switch choices[conflict.id] {
                case .local: return local
                case .remote: return remote
                case nil: unresolved = true; return local
                }
            }
        }
    }

    static func reviewedPayload(local: ExportPayload, remote: ExportPayload, baseline: ExportPayload,
        choices: [String: EntryChoice] = [:]) throws -> EntryReviewResult {
        let review = EntryReviewContext(choices: choices)
        let payload = try reconciledPayload(local: local, remote: remote, baseline: baseline, entryReview: review)
        guard Set(choices.keys).isSubset(of: Set(review.conflicts.map(\.id))) else { throw Conflict.divergentEdits }
        let conflicts = review.conflicts.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
        return EntryReviewResult(payload: review.unresolved ? nil : payload, conflicts: conflicts)
    }

    static func reconciledPayload(local: ExportPayload, remote: ExportPayload, baseline: ExportPayload) throws -> ExportPayload {
        try reconciledPayload(local: local, remote: remote, baseline: baseline, entryReview: nil)
    }

    private static func reconciledPayload(local: ExportPayload, remote: ExportPayload, baseline: ExportPayload,
        entryReview: EntryReviewContext?) throws -> ExportPayload {
        // Snapshot/day and account/day are logical records. Independently created
        // UUIDs must not double balances; preserve existing intra-device duplicates.
        let (local, remote, baseline) = alignedRecords(local: local, remote: remote, baseline: baseline)
        guard unresolvedDeletionIdentities(in: local, knownBy: [baseline]).isEmpty,
              unresolvedDeletionIdentities(in: remote, knownBy: [baseline]).isEmpty else { throw Conflict.divergentEdits }
        // Agreement is already a common ancestor, including legacy duplicate rows.
        // An older baseline must not turn identical replicas into a false conflict.
        if isSameContent(local, remote) { return normalized(payloadApplyingDeletions(remote)) }
        let automaticItems = automaticPriceItemIDs(local: local, remote: remote, baseline: baseline)
        let localInheritance = inheritedEntries(in: local, automaticItems: automaticItems)
        let remoteInheritance = inheritedEntries(in: remote, automaticItems: automaticItems)
        let baselineEntries = keyedByID(baseline.snapshots.flatMap(\.entries), id: \.id)
        let categories = try reconcileRecords(local.categories, remote.categories, baseline.categories, id: \.id) { l, r, b in
            ExportPayload.CategoryPayload(id: l.id,
                name: try mergeValue(l.name, r.name, b.map { $0.name }),
                group: try mergeValue(l.group, r.group, b.map { $0.group }),
                createdAt: min(l.createdAt, r.createdAt))
        }
        let items = try reconcileRecords(local.items, remote.items, baseline.items, id: \.id, merge: reconcileItem)
        let snapshots = try reconcileRecords(local.snapshots, remote.snapshots, baseline.snapshots, id: \.id,
            excluding: ["marketAnchorsUpdatedAt"]) { l, r, b in
            try reconcileSnapshot(l, r, b, automaticItems: automaticItems,
                localInheritance: localInheritance, remoteInheritance: remoteInheritance, baselineEntries: baselineEntries,
                entryReview: entryReview)
        }
        let remotes = keyedByID(remote.snapshots, id: \.id), bases = keyedByID(baseline.snapshots, id: \.id)
        // Different UUIDs do not make two entries for the same account/day safe
        // to add together. Preserve legacy duplicates but stop newly introduced ones.
        let calendar = Calendar.current
        let baselineDays = Dictionary(grouping: baseline.snapshots, by: { calendar.startOfDay(for: $0.date) })
        let combinedSnapshots = keyedByID(local.snapshots + remote.snapshots, id: \.id)
        for (day, snapshots) in Dictionary(grouping: Array(combinedSnapshots.values), by: { calendar.startOfDay(for: $0.date) }) {
            if snapshots.count > max(baselineDays[day]?.count ?? 0, 1) { throw Conflict.divergentEdits }
        }
        for snapshot in local.snapshots {
            guard let other = remotes[snapshot.id] else { continue }
            let priorEntries = bases[snapshot.id]?.entries ?? []
            let priorCounts = Dictionary(grouping: priorEntries.filter { $0.itemID != nil }, by: { $0.itemID! })
            let union = keyedByID(snapshot.entries + other.entries, id: \.id)
            for (itemID, entries) in Dictionary(grouping: Array(union.values).filter { $0.itemID != nil }, by: { $0.itemID! }) {
                if entries.count > max(priorCounts[itemID]?.count ?? 0, 1) { throw Conflict.divergentEdits }
            }
        }
        func checkDeletedEdits(deleting: ExportPayload, other: ExportPayload) throws {
            let priorItems = keyedByID(baseline.items, id: \.id)
            let priorEntries = keyedByID(baseline.snapshots.flatMap(\.entries), id: \.id)
            for deletion in deleting.deletionRecords {
                switch SyncDeletedEntityKind(rawValue: deletion.entityKind) {
                case .category:
                    if let value = other.categories.first(where: { $0.id == deletion.entityID }) {
                        guard let prior = baseline.categories.first(where: { $0.id == deletion.entityID }),
                              sameSemanticContent(prior, value) else { throw Conflict.divergentEdits }
                    }
                    for item in other.items where item.categoryID == deletion.entityID {
                        guard let prior = priorItems[item.id], sameSemanticContent(prior, item) else { throw Conflict.divergentEdits }
                        for entry in other.snapshots.flatMap(\.entries) where entry.itemID == item.id {
                            guard let prior = priorEntries[entry.id], sameUserEntry(prior, entry, automaticItems: automaticItems) else { throw Conflict.divergentEdits }
                        }
                    }
                case .item:
                    if let value = other.items.first(where: { $0.id == deletion.entityID }) {
                        guard let prior = priorItems[value.id], sameSemanticContent(prior, value) else { throw Conflict.divergentEdits }
                    }
                    for entry in other.snapshots.flatMap(\.entries) where entry.itemID == deletion.entityID {
                        guard let prior = priorEntries[entry.id], sameUserEntry(prior, entry, automaticItems: automaticItems) else { throw Conflict.divergentEdits }
                    }
                case .snapshot:
                    if let value = other.snapshots.first(where: { $0.id == deletion.entityID }) {
                        guard let prior = bases[value.id], sameUserSnapshot(prior, value, automaticItems: automaticItems) else { throw Conflict.divergentEdits }
                    }
                case .entry:
                    if let value = other.snapshots.flatMap(\.entries).first(where: { $0.id == deletion.entityID }) {
                        guard let prior = priorEntries[value.id], sameUserEntry(prior, value, automaticItems: automaticItems) else { throw Conflict.divergentEdits }
                    }
                case nil: break
                }
            }
        }
        try checkDeletedEdits(deleting: local, other: remote)
        try checkDeletedEdits(deleting: remote, other: local)
        return normalized(payloadApplyingDeletions(ExportPayload(
            exportedAt: max(local.exportedAt, remote.exportedAt), categories: categories,
            items: items, snapshots: snapshots,
            deletions: mergeDeletions(local: local.deletionRecords, remote: remote.deletionRecords))))
    }

    /// A common ancestor allows independent fields to merge without a device-clock
    /// winner. A divergent user value still requires a choice; never discard it.
    private static func mergeValue<T: Equatable>(_ local: T, _ remote: T, _ baseline: T?) throws -> T {
        if local == remote { return local }
        if let baseline {
            if local == baseline { return remote }
            if remote == baseline { return local }
        }
        throw Conflict.divergentEdits
    }

    private static func reconcileRecords<T: Encodable, ID: Hashable>(_ local: [T], _ remote: [T], _ baseline: [T],
        id: KeyPath<T, ID>, excluding: Set<String> = [], merge: (T, T, T?) throws -> T) throws -> [T] {
        let locals = keyedByID(local, id: id), remotes = keyedByID(remote, id: id), bases = keyedByID(baseline, id: id)
        return try Set(locals.keys).union(remotes.keys).map { key in
            if let left = locals[key], let right = remotes[key] {
                let result = try merge(left, right, bases[key])
                // Reuse the matching side's metadata. A stale device's later clock
                // must not turn a pure pull into an otherwise unnecessary upload.
                if sameSemanticContent(result, right, excluding: excluding) { return right }
                if sameSemanticContent(result, left, excluding: excluding) { return left }
                return result
            }
            return locals[key] ?? remotes[key]!
        }
    }

    private static func reconcileItem(_ l: ExportPayload.ItemPayload, _ r: ExportPayload.ItemPayload,
        _ b: ExportPayload.ItemPayload?) throws -> ExportPayload.ItemPayload {
        // The valuation mode and market binding form one setting, not two independent fields.
        let valuation = try mergeValue([l.valuationMethod, l.autoPricedAssetKind],
            [r.valuationMethod, r.autoPricedAssetKind], b.map { [$0.valuationMethod, $0.autoPricedAssetKind] })
        return .init(id: l.id,
            name: try mergeValue(l.name, r.name, b.map { $0.name }),
            note: try mergeValue(l.note, r.note, b.map { $0.note }),
            iconName: try mergeValue(l.iconName, r.iconName, b.map { $0.iconName }),
            valuationMethod: valuation[0]!, autoPricedAssetKind: valuation[1],
            quantStrategyProxySymbol: try mergeValue(l.quantStrategyProxySymbol, r.quantStrategyProxySymbol, b.map { $0.quantStrategyProxySymbol }),
            sortOrder: try mergeValue(l.sortOrder, r.sortOrder, b.map { $0.sortOrder }),
            isActive: try mergeValue(l.isActive, r.isActive, b.map { $0.isActive }),
            createdAt: min(l.createdAt, r.createdAt), updatedAt: max(l.updatedAt, r.updatedAt),
            categoryID: try mergeValue(l.categoryID, r.categoryID, b.map { $0.categoryID }))
    }

    private static func automaticPriceItemIDs(local: ExportPayload, remote: ExportPayload, baseline: ExportPayload) -> Set<UUID> {
        let groups = Dictionary(grouping: local.items + remote.items + baseline.items, by: \.id)
        return Set(groups.compactMap { id, versions in
            guard let first = versions.first, first.valuationMethod == "quantityAndUnitPrice",
                  let symbol = first.autoPricedAssetKind, !symbol.isEmpty,
                  versions.allSatisfy({ $0.valuationMethod == first.valuationMethod && $0.autoPricedAssetKind == symbol }) else { return nil }
            return id
        })
    }

    private static let anchorFields: Set<String> = ["goldAnchorPriceCNY", "goldAnchorPriceDate",
        "btcAnchorPriceUSD", "btcAnchorPriceDate", "nasdaqAnchorPriceUSD", "nasdaqAnchorPriceDate",
        "usdPerCNY", "usdPerCNYDate", "marketAnchorsUpdatedAt"]

    private static func sameUserEntry(_ l: ExportPayload.EntryPayload, _ r: ExportPayload.EntryPayload,
        automaticItems: Set<UUID>) -> Bool {
        let derivedPrice = l.itemID == r.itemID && l.itemID.map { automaticItems.contains($0) } == true
        return sameSemanticContent(l, r, excluding: derivedPrice ? ["unitPrice", "inheritedFromEntryID"] : ["inheritedFromEntryID"])
    }

    private static func sameUserSnapshot(_ l: ExportPayload.SnapshotPayload, _ r: ExportPayload.SnapshotPayload,
        automaticItems: Set<UUID>) -> Bool {
        guard sameSemanticContent(l, r, excluding: anchorFields.union(["entries"])) else { return false }
        let right = keyedByID(r.entries, id: \.id)
        return l.entries.count == r.entries.count && l.entries.allSatisfy { entry in
            right[entry.id].map { sameUserEntry(entry, $0, automaticItems: automaticItems) } == true
        }
    }

    /// A marker alone is not permission to overwrite a balance. Verify the copied
    /// user values against its actual earlier source; legacy rows remain unknown.
    private struct InheritedEntrySource {
        let date: Date
        let entryID: UUID
    }

    private static func inheritedEntries(in payload: ExportPayload, automaticItems: Set<UUID>) -> [UUID: InheritedEntrySource] {
        var sources: [UUID: (Date, ExportPayload.EntryPayload)] = [:]
        for snapshot in payload.snapshots {
            for entry in snapshot.entries { sources[entry.id] = (snapshot.date, entry) }
        }
        var inherited: [UUID: InheritedEntrySource] = [:]
        for snapshot in payload.snapshots {
            for entry in snapshot.entries {
                guard let sourceID = entry.inheritedFromEntryID, let (day, source) = sources[sourceID],
                      day < snapshot.date, entry.itemID == source.itemID else { continue }
                var excluded: Set<String> = ["id", "inheritedFromEntryID"]
                if entry.itemID.map({ automaticItems.contains($0) }) == true { excluded.insert("unitPrice") }
                if sameSemanticContent(entry, source, excluding: excluded) {
                    inherited[entry.id] = .init(date: day, entryID: sourceID)
                }
            }
        }
        return inherited
    }

    private static func inheritedBaselineEntry(
        left: ExportPayload.EntryPayload, right: ExportPayload.EntryPayload,
        localInheritance: [UUID: InheritedEntrySource], remoteInheritance: [UUID: InheritedEntrySource],
        baselineEntries: [UUID: ExportPayload.EntryPayload]
    ) -> ExportPayload.EntryPayload? {
        guard left.itemID == right.itemID,
              localInheritance[left.id] != nil, remoteInheritance[right.id] != nil else { return nil }
        // Follow only verified copy edges. Intermediate offline days need not have
        // reached the cloud, but their common acknowledged source must exist.
        var localAncestors: Set<UUID> = []
        var cursor = localInheritance[left.id]?.entryID
        while let id = cursor, localAncestors.insert(id).inserted {
            cursor = localInheritance[id]?.entryID
        }
        var visited: Set<UUID> = []
        cursor = remoteInheritance[right.id]?.entryID
        while let id = cursor, visited.insert(id).inserted {
            if localAncestors.contains(id), let baseline = baselineEntries[id], baseline.itemID == left.itemID {
                return baseline
            }
            cursor = remoteInheritance[id]?.entryID
        }
        return nil
    }

    private static func reconcileSnapshot(_ l: ExportPayload.SnapshotPayload, _ r: ExportPayload.SnapshotPayload,
        _ b: ExportPayload.SnapshotPayload?, automaticItems: Set<UUID>,
        localInheritance: [UUID: InheritedEntrySource], remoteInheritance: [UUID: InheritedEntrySource],
        baselineEntries: [UUID: ExportPayload.EntryPayload], entryReview: EntryReviewContext?) throws -> ExportPayload.SnapshotPayload {
        let lSnapshotDate = l.date
        let entries = try reconcileRecords(l.entries, r.entries, b?.entries ?? [], id: \.id) { left, right, prior in
            func value<T: Equatable & Encodable>(_ field: EntryField, _ l: T, _ r: T, _ base: T?) throws -> T {
                if let entryReview {
                    return try entryReview.value(l, r, base, entry: left, date: lSnapshotDate, field: field)
                }
                return try mergeValue(l, r, base)
            }
            let automatic = left.itemID == right.itemID && left.itemID.map { automaticItems.contains($0) } == true
            let leftSource = localInheritance[left.id], rightSource = remoteInheritance[right.id]
            let userBase = prior ?? inheritedBaselineEntry(left: left, right: right,
                localInheritance: localInheritance, remoteInheritance: remoteInheritance, baselineEntries: baselineEntries)
            let userValues: ExportPayload.EntryPayload?
            switch (leftSource, rightSource) {
            case (.some, .none): userValues = right
            case (.none, .some): userValues = left
            case (.some, .some) where userBase != nil: userValues = nil
            case let (a?, b?) where a.date != b.date: userValues = a.date > b.date ? left : right
            default: userValues = nil
            }
            let price: Double?
            if automatic {
                if let prior, left.unitPrice == prior.unitPrice { price = right.unitPrice ?? left.unitPrice }
                else if let prior, right.unitPrice == prior.unitPrice { price = left.unitPrice ?? right.unitPrice }
                else { price = isStrictlyNewer(left.updatedAt, than: right.updatedAt)
                    ? (left.unitPrice ?? right.unitPrice) : (right.unitPrice ?? left.unitPrice) }
            } else if let userValues { price = userValues.unitPrice }
            else { price = try value(.unitPrice, left.unitPrice, right.unitPrice, userBase.map { $0.unitPrice }) }
            let inheritedSource = userValues?.inheritedFromEntryID
                ?? (leftSource != nil && rightSource != nil ? left.inheritedFromEntryID : nil)
            return ExportPayload.EntryPayload(id: left.id,
                amount: try userValues.map { $0.amount } ?? value(.amount, left.amount, right.amount, userBase.map { $0.amount }),
                quantity: try userValues.map { $0.quantity } ?? value(.quantity, left.quantity, right.quantity, userBase.map { $0.quantity }),
                unitPrice: price, note: try userValues?.note ?? value(.note, left.note, right.note, userBase.map { $0.note }),
                createdAt: min(left.createdAt, right.createdAt), updatedAt: max(left.updatedAt, right.updatedAt),
                itemID: try mergeValue(left.itemID, right.itemID, prior.map { $0.itemID }),
                inheritedFromEntryID: inheritedSource)
        }
        // Keep each quote and its date together. Prefer source-date freshness, then
        // refresh time; a partial cache must not erase a populated anchor.
        func quote(_ value: KeyPath<ExportPayload.SnapshotPayload, Double?>,
                   _ date: KeyPath<ExportPayload.SnapshotPayload, Date?>) -> (Double?, Date?) {
            if l[keyPath: value] == nil { return (r[keyPath: value], r[keyPath: date]) }
            if r[keyPath: value] == nil { return (l[keyPath: value], l[keyPath: date]) }
            let ld = l[keyPath: date] ?? .distantPast, rd = r[keyPath: date] ?? .distantPast
            let source = ld == rd
                ? (isStrictlyNewer(l.marketAnchorsUpdatedAt ?? l.updatedAt, than: r.marketAnchorsUpdatedAt ?? r.updatedAt) ? l : r)
                : (ld > rd ? l : r)
            return (source[keyPath: value], source[keyPath: date])
        }
        let gold = quote(\.goldAnchorPriceCNY, \.goldAnchorPriceDate)
        let btc = quote(\.btcAnchorPriceUSD, \.btcAnchorPriceDate)
        let nasdaq = quote(\.nasdaqAnchorPriceUSD, \.nasdaqAnchorPriceDate)
        let fx = quote(\.usdPerCNY, \.usdPerCNYDate)
        return .init(id: l.id,
            date: try mergeValue(l.date, r.date, b.map { $0.date }),
            note: try mergeValue(l.note, r.note, b.map { $0.note }),
            createdAt: min(l.createdAt, r.createdAt), updatedAt: max(l.updatedAt, r.updatedAt),
            goldAnchorPriceCNY: gold.0, goldAnchorPriceDate: gold.1,
            btcAnchorPriceUSD: btc.0, btcAnchorPriceDate: btc.1,
            nasdaqAnchorPriceUSD: nasdaq.0, nasdaqAnchorPriceDate: nasdaq.1,
            usdPerCNY: fx.0, usdPerCNYDate: fx.1,
            marketAnchorsUpdatedAt: maxOptional(l.marketAnchorsUpdatedAt, r.marketAnchorsUpdatedAt), entries: entries)
    }

    static func enrichingDeletionIdentities(in payload: ExportPayload, using contexts: [ExportPayload]) -> ExportPayload {
        var days: [UUID: Date] = [:], rows: [UUID: (Date, UUID?)] = [:]
        var identities: [String: ExportPayload.DeletionPayload] = [:]
        for context in contexts + [payload] {
            for deletion in context.deletionRecords where deletion.snapshotDate != nil {
                identities[deletion.entityKind + ":" + deletion.entityID.uuidString] = deletion
            }
            for snapshot in context.snapshots {
                days[snapshot.id] = snapshot.date
                for entry in snapshot.entries { rows[entry.id] = (snapshot.date, entry.itemID) }
            }
        }
        let deletions = payload.deletionRecords.map { original in
            var value = original
            if let known = identities[value.entityKind + ":" + value.entityID.uuidString] {
                value.snapshotDate = value.snapshotDate ?? known.snapshotDate
                value.itemID = value.itemID ?? known.itemID
            }
            if value.entityKind == "snapshot" { value.snapshotDate = value.snapshotDate ?? days[value.entityID] }
            if value.entityKind == "entry", let row = rows[value.entityID] {
                value.snapshotDate = value.snapshotDate ?? row.0
                value.itemID = value.itemID ?? row.1
            }
            return value
        }
        return .init(exportedAt: payload.exportedAt, categories: payload.categories, items: payload.items,
                     snapshots: payload.snapshots, deletions: deletions)
    }

    /// Previously acknowledged opaque tombstones are harmless to leave untouched.
    /// A new unknown deletion must be hydrated from history before alias merging.
    static func unresolvedDeletionIdentities(in payload: ExportPayload, knownBy contexts: [ExportPayload]) -> Set<UUID> {
        let known = Set(contexts.flatMap(\.deletionRecords).map { $0.entityKind + ":" + $0.entityID.uuidString })
        return Set(payload.deletionRecords.filter {
            ($0.entityKind == "snapshot" || $0.entityKind == "entry") && $0.snapshotDate == nil
                && !known.contains($0.entityKind + ":" + $0.entityID.uuidString)
        }.map(\.entityID))
    }

    private static func alignedRecords(local: ExportPayload, remote: ExportPayload, baseline: ExportPayload)
        -> (ExportPayload, ExportPayload, ExportPayload) {
        let originals = [local, remote, baseline]
        let payloads = originals.map { enrichingDeletionIdentities(in: $0, using: originals) }
        let tombstones = payloads.flatMap(\.deletionRecords)
        let days = payloads.map { Dictionary(grouping: $0.snapshots, by: { Calendar.current.startOfDay(for: $0.date) }) }
        func canAlign(_ versions: [[UUID]], kind: String, deletedIDs: Set<UUID>) -> Bool {
            let ids = Set(versions.flatMap { $0 }).union(deletedIDs)
            for index in payloads.indices {
                let deleted = Set(payloads[index].deletionRecords.filter { $0.entityKind == kind }.map(\.entityID)).intersection(ids)
                if !deleted.isEmpty && versions[index].contains(where: { !deleted.contains($0) }) { return false }
            }
            return true
        }
        var snapshotAliases: [UUID: UUID] = [:], entryAliases: [UUID: UUID] = [:]
        let deletionDays = tombstones.compactMap { $0.snapshotDate.map { Calendar.current.startOfDay(for: $0) } }
        for day in Set(days.flatMap { $0.keys }).union(deletionDays) {
            let dayDeletions = tombstones.filter { $0.snapshotDate.map { Calendar.current.startOfDay(for: $0) } == day }
            let deletedDays = Set(dayDeletions.filter { $0.entityKind == "snapshot" }.map(\.entityID))
            let versions = days.map { $0[day] ?? [] }
            guard versions.allSatisfy({ $0.count <= 1 }) else { continue }
            let snapshots = versions.flatMap { $0 }
            // A delete followed by a new live record on the same side is a new
            // user intent, not an alias. Never apply its old tombstone to the new value.
            // One total order across all replicas prevents identity-only upload loops.
            guard canAlign(versions.map { $0.map(\.id) }, kind: "snapshot", deletedIDs: deletedDays),
                  let canonical = Set(snapshots.map(\.id)).union(deletedDays).min(by: { $0.uuidString < $1.uuidString }) else { continue }
            for id in Set(snapshots.map(\.id)).union(deletedDays) { snapshotAliases[id] = canonical }
            let entries = versions.map { Dictionary(grouping: $0.flatMap(\.entries).filter { $0.itemID != nil }, by: { $0.itemID! }) }
            let deletedItemIDs = dayDeletions.filter { $0.entityKind == "entry" }.compactMap(\.itemID)
            for itemID in Set(entries.flatMap { $0.keys }).union(deletedItemIDs) {
                let deletedRows = Set(dayDeletions.filter { $0.entityKind == "entry" && $0.itemID == itemID }.map(\.entityID))
                let rows = entries.map { $0[itemID] ?? [] }
                guard rows.allSatisfy({ $0.count <= 1 }),
                      canAlign(rows.map { $0.map(\.id) }, kind: "entry", deletedIDs: deletedRows),
                      let canonicalRow = Set(rows.flatMap({ $0 }).map(\.id)).union(deletedRows).min(by: { $0.uuidString < $1.uuidString }) else { continue }
                for id in Set(rows.flatMap({ $0 }).map(\.id)).union(deletedRows) { entryAliases[id] = canonicalRow }
            }
        }
        func aligned(_ payload: ExportPayload) -> ExportPayload {
            let snapshots = payload.snapshots.map { s in
                ExportPayload.SnapshotPayload(id: snapshotAliases[s.id] ?? s.id, date: s.date, note: s.note,
                    createdAt: s.createdAt, updatedAt: s.updatedAt,
                    goldAnchorPriceCNY: s.goldAnchorPriceCNY, goldAnchorPriceDate: s.goldAnchorPriceDate,
                    btcAnchorPriceUSD: s.btcAnchorPriceUSD, btcAnchorPriceDate: s.btcAnchorPriceDate,
                    nasdaqAnchorPriceUSD: s.nasdaqAnchorPriceUSD, nasdaqAnchorPriceDate: s.nasdaqAnchorPriceDate,
                    usdPerCNY: s.usdPerCNY, usdPerCNYDate: s.usdPerCNYDate, marketAnchorsUpdatedAt: s.marketAnchorsUpdatedAt,
                    entries: s.entries.map { e in
                        .init(id: entryAliases[e.id] ?? e.id, amount: e.amount, quantity: e.quantity,
                              unitPrice: e.unitPrice, note: e.note, createdAt: e.createdAt, updatedAt: e.updatedAt, itemID: e.itemID,
                              inheritedFromEntryID: e.inheritedFromEntryID.map { entryAliases[$0] ?? $0 })
                    })
            }
            let deletions = payload.deletionRecords.map { d in
                ExportPayload.DeletionPayload(entityID: (d.entityKind == "snapshot" ? snapshotAliases[d.entityID]
                    : (d.entityKind == "entry" ? entryAliases[d.entityID] : nil)) ?? d.entityID,
                    entityKind: d.entityKind, deletedAt: d.deletedAt, snapshotDate: d.snapshotDate, itemID: d.itemID)
            }
            return .init(exportedAt: payload.exportedAt, categories: payload.categories, items: payload.items,
                         snapshots: snapshots, deletions: deletions)
        }
        return (aligned(payloads[0]), aligned(payloads[1]), aligned(payloads[2]))
    }

    private static func sameSemanticContent<T: Encodable>(_ lhs: T, _ rhs: T, excluding: Set<String> = []) -> Bool {
        func content(_ value: T) -> Data? {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(value),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            for key in excluding.union(["updatedAt", "createdAt"]) { object.removeValue(forKey: key) }
            if let entries = object["entries"] as? [[String: Any]] {
                object["entries"] = entries.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            }
            return try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        }
        guard let left = content(lhs), let right = content(rhs) else { return false }
        return left == right
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

    /// Binds an explicit choice to user intent, while allowing an automatic quote
    /// refresh during review. Provenance is retained: confirming an unchanged
    /// inherited value is a user action and must invalidate an older review.
    static func userContentData(for payload: ExportPayload) throws -> Data {
        let data = try canonicalData(for: payload)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let automatic = Set(automaticPriceItemIDs(local: payload, remote: payload, baseline: payload).map(\.uuidString))
        object.removeValue(forKey: "exportedAt")
        func stripDates(_ row: [String: Any]) -> [String: Any] {
            var row = row; row.removeValue(forKey: "createdAt"); row.removeValue(forKey: "updatedAt"); return row
        }
        for collection in ["categories", "items"] {
            object[collection] = (object[collection] as? [[String: Any]] ?? []).map(stripDates)
        }
        object["snapshots"] = (object["snapshots"] as? [[String: Any]] ?? []).map { original in
            var snapshot = stripDates(original)
            for key in anchorFields { snapshot.removeValue(forKey: key) }
            snapshot["entries"] = (snapshot["entries"] as? [[String: Any]] ?? []).map { original in
                var entry = stripDates(original)
                if let itemID = entry["itemID"] as? String, automatic.contains(itemID) { entry.removeValue(forKey: "unitPrice") }
                return entry
            }
            return snapshot
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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
        let seedNotes: Set<String> = ["", "默认资金项目，可编辑或删除", "示例项目，可编辑或删除", "默认负债项目，可编辑或删除"]
        return itemNames.isSubset(of: seedItemNames) && payload.categories.count <= 3 && payload.items.count <= seedItemNames.count
            && payload.items.allSatisfy { seedNotes.contains($0.note) && $0.valuationMethod == "directAmount"
                && $0.autoPricedAssetKind == nil && $0.quantStrategyProxySymbol == nil && $0.isActive }
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

    private static func mergeCategories(local: [ExportPayload.CategoryPayload], remote: [ExportPayload.CategoryPayload], baseline: [ExportPayload.CategoryPayload]?) -> [ExportPayload.CategoryPayload] {
        var merged: [UUID: ExportPayload.CategoryPayload] = [:]
        for category in remote {
            merged[category.id] = category
        }
        let bases = keyedByID(baseline ?? [], id: \.id)
        for category in local {
            if let remoteValue = merged[category.id], let base = bases[category.id],
               sameSemanticContent(category, base) {
                merged[category.id] = remoteValue
            } else { merged[category.id] = category }
        }
        return Array(merged.values)
    }

    private static func mergeSnapshots(local: [ExportPayload.SnapshotPayload], remote: [ExportPayload.SnapshotPayload], baseline: [ExportPayload.SnapshotPayload]?) -> [ExportPayload.SnapshotPayload] {
        let remoteByID = keyedByID(remote, id: \.id)
        let localByID = keyedByID(local, id: \.id)
        let allIDs = Set(remoteByID.keys).union(localByID.keys)
        let baselineByID = keyedByID(baseline ?? [], id: \.id)

        return allIDs.compactMap { id in
            switch (localByID[id], remoteByID[id]) {
            case let (local?, remote?):
                let prior = baselineByID[id]
                let localHeaderUnchanged = prior.map { sameSemanticContent(local, $0, excluding: ["entries"]) } ?? false
                let remoteHeaderUnchanged = prior.map { sameSemanticContent(remote, $0, excluding: ["entries"]) } ?? false
                let base = localHeaderUnchanged ? remote : (remoteHeaderUnchanged ? local
                    : (isStrictlyNewer(local.updatedAt, than: remote.updatedAt) ? local : remote))
                let entries = mergeEntries(local: local.entries, remote: remote.entries, baseline: prior?.entries)
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

    private static func mergeEntries(local: [ExportPayload.EntryPayload], remote: [ExportPayload.EntryPayload], baseline: [ExportPayload.EntryPayload]?) -> [ExportPayload.EntryPayload] {
        mergeByUpdatedAt(local: local, remote: remote, baseline: baseline, id: \.id, updatedAt: \.updatedAt)
    }

    private static func mergeByUpdatedAt<T: Encodable, ID: Hashable>(local: [T], remote: [T], baseline: [T]?, id: KeyPath<T, ID>, updatedAt: KeyPath<T, Date>) -> [T] {
        var merged: [ID: T] = [:]
        for value in remote {
            let key = value[keyPath: id]
            if let existing = merged[key] {
                merged[key] = isStrictlyNewer(value[keyPath: updatedAt], than: existing[keyPath: updatedAt]) ? value : existing
            } else {
                merged[key] = value
            }
        }
        let bases = keyedByID(baseline ?? [], id: id)
        for value in local {
            let key = value[keyPath: id]
            if let existing = merged[key] {
                if let base = bases[key], sameSemanticContent(value, base) {
                    merged[key] = existing
                } else if let base = bases[key], sameSemanticContent(existing, base) {
                    merged[key] = value
                } else {
                    merged[key] = isStrictlyNewer(value[keyPath: updatedAt], than: existing[keyPath: updatedAt]) ? value : existing
                }
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
            if let existing = merged[key] {
                merged[key] = .init(entityID: deletion.entityID, entityKind: deletion.entityKind,
                    deletedAt: max(existing.deletedAt, deletion.deletedAt),
                    snapshotDate: deletion.snapshotDate ?? existing.snapshotDate,
                    itemID: deletion.itemID ?? existing.itemID)
            } else { merged[key] = deletion }
        }
        return Array(merged.values)
    }

    private static func isStrictlyNewer(_ local: Date, than remote: Date) -> Bool {
        // Cloud JSON encodes ISO 8601 timestamps to seconds. A local fractional
        // timestamp must not make an otherwise tied old value win against the cloud.
        local.timeIntervalSince1970.rounded(.down) > remote.timeIntervalSince1970.rounded(.down)
    }

    private static func newerOptional<T>(localValue: T?, localUpdatedAt: Date, remoteValue: T?, remoteUpdatedAt: Date) -> T? {
        isStrictlyNewer(localUpdatedAt, than: remoteUpdatedAt) ? localValue : remoteValue
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
