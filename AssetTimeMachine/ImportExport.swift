import Foundation
import SwiftData

struct ExportPayload: Codable {
    let exportedAt: Date
    let categories: [CategoryPayload]
    let items: [ItemPayload]
    let snapshots: [SnapshotPayload]

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
}

enum ImportExportService {
    @MainActor
    static func exportPayload(from context: ModelContext) throws -> ExportPayload {
        let categories = try context.fetch(FetchDescriptor<AssetCategory>())
        let items = try context.fetch(FetchDescriptor<AssetItem>())
        let snapshots = try context.fetch(FetchDescriptor<AssetSnapshot>())

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
        if replaceExisting {
            try clearAll(in: context)
        }

        let existingCategories = try context.fetch(FetchDescriptor<AssetCategory>())
        if !existingCategories.isEmpty && !replaceExisting {
            return
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

        try context.save()
    }

    @MainActor
    private static func clearAll(in context: ModelContext) throws {
        for entry in try context.fetch(FetchDescriptor<AssetEntry>()) {
            context.delete(entry)
        }
        for snapshot in try context.fetch(FetchDescriptor<AssetSnapshot>()) {
            context.delete(snapshot)
        }
        for item in try context.fetch(FetchDescriptor<AssetItem>()) {
            context.delete(item)
        }
        for category in try context.fetch(FetchDescriptor<AssetCategory>()) {
            context.delete(category)
        }
        try context.save()
    }
}
