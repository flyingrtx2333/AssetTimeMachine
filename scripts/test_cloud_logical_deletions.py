"""Actual shared merge: deleted canonical IDs must not revive offline aliases."""
from pathlib import Path
import subprocess
import tempfile


def test_cloud_logical_deletions():
    root = Path(__file__).resolve().parents[1]
    source = (root / "AssetTimeMachine/ImportExport.swift").read_text()
    payload = source[source.index("nonisolated struct ExportPayload:"):source.index("nonisolated struct VersionedExportPayload:")]
    merge = source[source.index("nonisolated enum SyncMergeService {"):]
    support = """import Foundation
    enum AssetGroup: String { case financial, physical, liability }
    enum SyncDeletedEntityKind: String { case category, item, snapshot, entry }
    """
    scenarios = r"""
    let dayA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let dayB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let dayC = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let rowA = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    let rowB = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    let rowC = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
    let itemID = UUID(), day = Date(timeIntervalSince1970: 1000)
    let deletionTime = Date(timeIntervalSince1970: 2000)
    let item = ExportPayload.ItemPayload(id: itemID, name: "Synthetic account", note: "", iconName: nil,
        valuationMethod: "directAmount", autoPricedAssetKind: nil, quantStrategyProxySymbol: nil,
        sortOrder: 0, isActive: true, createdAt: day, updatedAt: day, categoryID: nil)
    func bundle(_ days: [ExportPayload.SnapshotPayload], _ deletions: [ExportPayload.DeletionPayload] = []) -> ExportPayload {
        ExportPayload(exportedAt: deletionTime, categories: [], items: [item], snapshots: days, deletions: deletions)
    }
    func copy(_ dayID: UUID, _ rowID: UUID, amount: Double = 100) -> ExportPayload {
        let entry = ExportPayload.EntryPayload(id: rowID, amount: amount, quantity: nil, unitPrice: nil,
            note: "", createdAt: day, updatedAt: day, itemID: itemID)
        let snapshot = ExportPayload.SnapshotPayload(id: dayID, date: day, note: "", createdAt: day,
            updatedAt: day, goldAnchorPriceCNY: nil, goldAnchorPriceDate: nil,
            btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil, nasdaqAnchorPriceUSD: nil,
            nasdaqAnchorPriceDate: nil, usdPerCNY: nil, usdPerCNYDate: nil,
            marketAnchorsUpdatedAt: nil, entries: [entry])
        return bundle([snapshot])
    }
    func delete(_ id: UUID, kind: String) -> ExportPayload.DeletionPayload {
        .init(entityID: id, entityKind: kind, deletedAt: deletionTime,
            snapshotDate: day, itemID: kind == "entry" ? itemID : nil)
    }
    let empty = bundle([])

    // B was once the cloud identity. A second replica canonicalizes the equal
    // logical record to A, while the first replica remains offline with base B.
    let oldB = copy(dayB, rowB)
    let canonicalDay = try SyncMergeService.reconciledPayload(
        local: copy(dayA, rowA), remote: oldB, baseline: empty)
    precondition(canonicalDay.snapshots[0].id == dayA)
    let deletedDay = bundle([], [delete(dayA, kind: "snapshot")])
    let pulledDayDeletion = try SyncMergeService.reconciledPayload(
        local: oldB, remote: deletedDay, baseline: oldB)
    precondition(pulledDayDeletion.snapshots.isEmpty,
        "deleting a canonical day must remove an unchanged offline alias instead of resurrecting it")

    let oldEntryB = copy(dayA, rowB)
    let canonicalEntry = try SyncMergeService.reconciledPayload(
        local: copy(dayA, rowA), remote: oldEntryB, baseline: empty)
    precondition(canonicalEntry.snapshots[0].entries[0].id == rowA)
    let prior = canonicalEntry.snapshots[0]
    let clearedDay = ExportPayload.SnapshotPayload(id: prior.id, date: prior.date, note: prior.note,
        createdAt: prior.createdAt, updatedAt: prior.updatedAt, goldAnchorPriceCNY: nil,
        goldAnchorPriceDate: nil, btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil,
        nasdaqAnchorPriceUSD: nil, nasdaqAnchorPriceDate: nil, usdPerCNY: nil,
        usdPerCNYDate: nil, marketAnchorsUpdatedAt: nil, entries: [])
    let deletedEntry = bundle([clearedDay], [delete(rowA, kind: "entry")])
    let pulledEntryDeletion = try SyncMergeService.reconciledPayload(
        local: oldEntryB, remote: deletedEntry, baseline: oldEntryB)
    precondition(pulledEntryDeletion.snapshots[0].entries.isEmpty,
        "deleting a canonical entry must remove an unchanged offline alias instead of resurrecting it")

    // An old UUID-only cloud tombstone must stop before the previous canonical
    // object has been recovered from this account's history. History hydration
    // supplies identity, not permission to overwrite independent user edits.
    let legacyDeletion = ExportPayload.DeletionPayload(entityID: dayA, entityKind: "snapshot",
        deletedAt: deletionTime)
    let opaqueDeletedDay = bundle([], [legacyDeletion])
    do {
        _ = try SyncMergeService.reconciledPayload(local: oldB, remote: opaqueDeletedDay, baseline: oldB)
        preconditionFailure("an unresolved old tombstone must not revive or erase an offline alias")
    } catch SyncMergeService.Conflict.divergentEdits {}
    let historyResolved = SyncMergeService.enrichingDeletionIdentities(in: opaqueDeletedDay, using: [canonicalDay])
    let recoveredDeletion = try SyncMergeService.reconciledPayload(
        local: oldB, remote: historyResolved, baseline: oldB)
    precondition(recoveredDeletion.snapshots.isEmpty,
        "the historical canonical record must hydrate an opaque tombstone and remove its unchanged offline alias")

    // Logical identity cannot turn an old tombstone into permission to erase a
    // newly recreated user value. Explicit conflict remains a safe outcome.
    func preservesRecreation(_ replacement: ExportPayload, tombstone: ExportPayload.DeletionPayload,
                             remote: ExportPayload, baseline: ExportPayload) throws {
        let local = bundle(replacement.snapshots, [tombstone])
        do {
            let merged = try SyncMergeService.reconciledPayload(local: local, remote: remote, baseline: baseline)
            precondition(merged.snapshots.flatMap(\.entries).contains { $0.amount == 130 },
                "an old logical tombstone must not erase a newly recreated user value")
        } catch SyncMergeService.Conflict.divergentEdits {
            // Keep both copies rather than guess whether a new ID is stale or intentional.
        }
    }
    try preservesRecreation(copy(dayC, rowC, amount: 130), tombstone: delete(dayB, kind: "snapshot"),
        remote: canonicalDay, baseline: oldB)
    try preservesRecreation(copy(dayA, rowC, amount: 130), tombstone: delete(rowB, kind: "entry"),
        remote: canonicalEntry, baseline: oldEntryB)
    print("PASS: 5 logical deletion regression checks")
    """
    with tempfile.TemporaryDirectory(prefix="atm-logical-deletions-") as folder:
        main = Path(folder) / "main.swift"
        executable = Path(folder) / "probe"
        main.write_text(support + payload + merge + scenarios)
        subprocess.run(["swiftc", str(main), "-o", str(executable)], check=True, cwd=root)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    test_cloud_logical_deletions()
