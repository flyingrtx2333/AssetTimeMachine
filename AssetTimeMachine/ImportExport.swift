import Foundation
import SwiftData

struct ExportPayload: Codable {
    let exportedAt: Date
    let categories: [CategoryPayload]
    let items: [ItemPayload]
    let snapshots: [SnapshotPayload]
    let deletions: [DeletionPayload]?

    var deletionRecords: [DeletionPayload] {
        deletions ?? []
    }

    struct CategoryPayload: Codable {
        let id: UUID
        let name: String
        let group: String
        let createdAt: Date
    }

    struct ItemPayload: Codable {
        let id: UUID
        let name: String
        let note: String
        let iconName: String?
        let valuationMethod: String
        let autoPricedAssetKind: String?
        let sortOrder: Int
        let isActive: Bool
        let createdAt: Date
        let updatedAt: Date
        let categoryID: UUID?
    }

    struct SnapshotPayload: Codable {
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

    struct EntryPayload: Codable {
        let id: UUID
        let amount: Double?
        let quantity: Double?
        let unitPrice: Double?
        let note: String
        let createdAt: Date
        let updatedAt: Date
        let itemID: UUID?
    }

    struct DeletionPayload: Codable {
        let entityID: UUID
        let entityKind: String
        let deletedAt: Date
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
                    autoPricedAssetKind: $0.autoPricedAssetKind?.rawValue,
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
    static func importJSON(_ data: Data, into context: ModelContext, replaceExisting: Bool = false) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ExportPayload.self, from: data)
        try importPayload(payload, into: context, replaceExisting: replaceExisting)
    }

    @MainActor
    static func importPayload(_ payload: ExportPayload, into context: ModelContext, replaceExisting: Bool = false) throws {
        let payload = SyncMergeService.payloadApplyingDeletions(payload)
        try validate(payload)

        let existingCategories = try context.fetch(FetchDescriptor<AssetCategory>())
        if !existingCategories.isEmpty && !replaceExisting {
            return
        }

        if replaceExisting {
            try stageClearAll(in: context)
        }

        var categoryMap: [UUID: AssetCategory] = [:]
        for categoryPayload in payload.categories {
            let category = AssetCategory(
                id: categoryPayload.id,
                name: categoryPayload.name,
                group: AssetGroup(rawValue: categoryPayload.group) ?? .financial,
                createdAt: categoryPayload.createdAt
            )
            context.insert(category)
            categoryMap[category.id] = category
        }

        var itemMap: [UUID: AssetItem] = [:]
        for itemPayload in payload.items {
            let item = AssetItem(
                id: itemPayload.id,
                name: itemPayload.name,
                note: itemPayload.note,
                iconName: itemPayload.iconName ?? "",
                valuationMethod: ValuationMethod(rawValue: itemPayload.valuationMethod) ?? .directAmount,
                autoPricedAssetKind: itemPayload.autoPricedAssetKind.flatMap(AutoPricedAssetKind.init(rawValue:)),
                sortOrder: itemPayload.sortOrder,
                isActive: itemPayload.isActive,
                createdAt: itemPayload.createdAt,
                updatedAt: itemPayload.updatedAt,
                category: itemPayload.categoryID.flatMap { categoryMap[$0] }
            )
            context.insert(item)
            itemMap[item.id] = item
        }

        for snapshotPayload in payload.snapshots {
            let snapshot = AssetSnapshot(
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

            for entryPayload in snapshotPayload.entries {
                let entry = AssetEntry(
                    id: entryPayload.id,
                    amount: entryPayload.amount,
                    quantity: entryPayload.quantity,
                    unitPrice: entryPayload.unitPrice,
                    note: entryPayload.note,
                    createdAt: entryPayload.createdAt,
                    updatedAt: entryPayload.updatedAt,
                    snapshot: snapshot,
                    item: entryPayload.itemID.flatMap { itemMap[$0] }
                )
                context.insert(entry)
            }
        }

        for deletion in payload.deletionRecords {
            guard let kind = SyncDeletedEntityKind(rawValue: deletion.entityKind) else { continue }
            context.insert(SyncDeletionTombstone(
                entityID: deletion.entityID,
                entityKind: kind,
                deletedAt: deletion.deletedAt
            ))
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    @MainActor
    private static func stageClearAll(in context: ModelContext) throws {
        let entries = try context.fetch(FetchDescriptor<AssetEntry>())
        let snapshots = try context.fetch(FetchDescriptor<AssetSnapshot>())
        let items = try context.fetch(FetchDescriptor<AssetItem>())
        let categories = try context.fetch(FetchDescriptor<AssetCategory>())
        let tombstones = try context.fetch(FetchDescriptor<SyncDeletionTombstone>())

        for entry in entries {
            context.delete(entry)
        }
        for snapshot in snapshots {
            context.delete(snapshot)
        }
        for item in items {
            context.delete(item)
        }
        for category in categories {
            context.delete(category)
        }
        for tombstone in tombstones {
            context.delete(tombstone)
        }
    }

    private static func validate(_ payload: ExportPayload) throws {
        let categoryIDs = Set(payload.categories.map(\.id))
        let itemIDs = Set(payload.items.map(\.id))

        try requireUniqueIDs(payload.categories.map(\.id), entityName: AppLocalization.string("资产分类"))
        try requireUniqueIDs(payload.items.map(\.id), entityName: AppLocalization.string("资产项目"))
        try requireUniqueIDs(payload.snapshots.map(\.id), entityName: AppLocalization.string("资产记录"))

        for snapshot in payload.snapshots {
            try requireUniqueIDs(snapshot.entries.map(\.id), entityName: AppLocalization.string("资产条目"))
            try requireUniqueIDs(snapshot.entries.compactMap(\.itemID), entityName: AppLocalization.string("资产项目引用"))
        }

        for item in payload.items {
            if let categoryID = item.categoryID, !categoryIDs.contains(categoryID) {
                throw NSError(
                    domain: "ImportExportService",
                    code: 422,
                    userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("云端数据中存在无法识别的资产分类引用")]
                )
            }
        }

        for snapshot in payload.snapshots {
            for entry in snapshot.entries {
                if let itemID = entry.itemID, !itemIDs.contains(itemID) {
                    throw NSError(
                        domain: "ImportExportService",
                        code: 422,
                        userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("云端数据中存在无法识别的资产项目引用")]
                    )
                }
            }
        }
    }

    private static func requireUniqueIDs<ID: Hashable>(_ ids: [ID], entityName: String) throws {
        guard Set(ids).count == ids.count else {
            throw NSError(
                domain: "ImportExportService",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: AppLocalization.format("云端数据中存在重复的%@", entityName)]
            )
        }
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

enum SyncMergeService {
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
