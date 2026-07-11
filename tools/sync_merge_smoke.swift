import Foundation
import SwiftData

@main
enum SyncMergeSmoke {
    @MainActor
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let categoryID = UUID()
        let itemID = UUID()
        let snapshotID = UUID()
        let entryID = UUID()

        let category = ExportPayload.CategoryPayload(
            id: categoryID,
            name: "金融资产",
            group: AssetGroup.financial.rawValue,
            createdAt: now
        )
        let item = ExportPayload.ItemPayload(
            id: itemID,
            name: "现金",
            note: "",
            iconName: nil,
            valuationMethod: ValuationMethod.directAmount.rawValue,
            autoPricedAssetKind: nil,
            sortOrder: 0,
            isActive: true,
            createdAt: now,
            updatedAt: now,
            categoryID: categoryID
        )
        let entry = ExportPayload.EntryPayload(
            id: entryID,
            amount: 10_000,
            quantity: nil,
            unitPrice: nil,
            note: "",
            createdAt: now,
            updatedAt: now,
            itemID: itemID
        )
        let snapshot = ExportPayload.SnapshotPayload(
            id: snapshotID,
            date: now,
            note: "",
            createdAt: now,
            updatedAt: now,
            goldAnchorPriceCNY: nil,
            goldAnchorPriceDate: nil,
            btcAnchorPriceUSD: nil,
            btcAnchorPriceDate: nil,
            nasdaqAnchorPriceUSD: nil,
            nasdaqAnchorPriceDate: nil,
            usdPerCNY: nil,
            usdPerCNYDate: nil,
            marketAnchorsUpdatedAt: nil,
            entries: [entry]
        )
        let remote = ExportPayload(
            exportedAt: now,
            categories: [category],
            items: [item],
            snapshots: [snapshot],
            deletions: nil
        )
        let localDeletion = ExportPayload.DeletionPayload(
            entityID: snapshotID,
            entityKind: SyncDeletedEntityKind.snapshot.rawValue,
            deletedAt: now.addingTimeInterval(60)
        )
        let local = ExportPayload(
            exportedAt: now.addingTimeInterval(60),
            categories: [category],
            items: [item],
            snapshots: [],
            deletions: [localDeletion]
        )

        let merged = SyncMergeService.mergedPayload(local: local, remote: remote)
        precondition(merged.snapshots.isEmpty, "A deleted snapshot must not be restored by an older remote payload")
        precondition(merged.deletionRecords.count == 1, "The deletion tombstone must survive merging")
        precondition(!SyncMergeService.looksLikeSeedOnly(local), "A payload with tombstones is not a first-run seed payload")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(remote)
        var legacyObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        legacyObject.removeValue(forKey: "deletions")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedLegacy = try decoder.decode(ExportPayload.self, from: legacyData)
        precondition(decodedLegacy.deletionRecords.isEmpty, "Backups created before tombstones must remain decodable")

        let schema = Schema([
            AssetCategory.self,
            AssetItem.self,
            AssetSnapshot.self,
            AssetEntry.self,
            BacktestRecord.self,
            SyncDeletionTombstone.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        context.insert(AssetCategory(name: "旧分类", group: .financial))
        try context.save()

        try ImportExportService.importPayload(remote, into: context, replaceExisting: true)
        let categoryCount = try context.fetchCount(FetchDescriptor<AssetCategory>())
        let snapshotCount = try context.fetchCount(FetchDescriptor<AssetSnapshot>())
        let entryCount = try context.fetchCount(FetchDescriptor<AssetEntry>())
        precondition(categoryCount == 1)
        precondition(snapshotCount == 1)
        precondition(entryCount == 1)

        print("SYNC_MERGE_SMOKE_OK")
    }
}
