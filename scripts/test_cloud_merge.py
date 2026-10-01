"""Exercise the actual shared merge implementation with isolated payloads."""
import pathlib
import subprocess
import tempfile


def test_cloud_merge():
    root = pathlib.Path(__file__).resolve().parents[1]
    source = (root / "AssetTimeMachine/ImportExport.swift").read_text()
    payload = source[source.index("nonisolated struct ExportPayload:"):source.index("nonisolated struct VersionedExportPayload:")]
    merge = source[source.index("nonisolated enum SyncMergeService {"):]
    support = """import Foundation
    enum AssetGroup: String { case financial, physical, liability }
    enum SyncDeletedEntityKind: String { case category, item, snapshot, entry }
    """
    scenarios = r"""
    let entryID = UUID(), snapshotID = UUID()
    func payload(_ amount: Double, _ time: Double, _ note: String = "", _ extra: Bool = false) -> ExportPayload {
        let date = Date(timeIntervalSince1970: time)
        var entries = [ExportPayload.EntryPayload(id: entryID, amount: amount, quantity: nil,
            unitPrice: nil, note: note, createdAt: Date(timeIntervalSince1970: 100), updatedAt: date, itemID: nil)]
        if extra { entries.append(ExportPayload.EntryPayload(id: UUID(), amount: 50,
            quantity: 2, unitPrice: 25, note: "additional", createdAt: Date(timeIntervalSince1970: 100), updatedAt: date, itemID: nil)) }
        let snapshot = ExportPayload.SnapshotPayload(id: snapshotID, date: Date(timeIntervalSince1970: 1000),
            note: note, createdAt: Date(timeIntervalSince1970: 100), updatedAt: date, goldAnchorPriceCNY: nil,
            goldAnchorPriceDate: nil, btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil,
            nasdaqAnchorPriceUSD: nil, nasdaqAnchorPriceDate: nil, usdPerCNY: nil,
            usdPerCNYDate: nil, marketAnchorsUpdatedAt: nil, entries: entries)
        return ExportPayload(exportedAt: date, categories: [], items: [], snapshots: [snapshot], deletions: [])
    }
    func amount(_ p: ExportPayload) -> Double? { p.snapshots[0].entries.first { $0.id == entryID }?.amount }
    let old = payload(100, 1000, "old Mac")
    let phone = payload(200, 2000, "phone")
    let restored = SyncMergeService.mergedPayload(local: old, remote: phone)
    precondition(amount(restored) == 200, "older Mac must not overwrite newer phone")
    precondition(SyncMergeService.isSameContent(restored, phone), "remote-only change should not require upload")
    let equalTimeMac = payload(100, 2000, "Mac")
    let equalResult = SyncMergeService.mergedPayload(local: equalTimeMac, remote: phone)
    precondition(amount(equalResult) == 200, "equal timestamps preserve remote value")
    precondition(equalResult.snapshots[0].note == "phone", "equal timestamps preserve remote metadata")
    precondition(amount(SyncMergeService.mergedPayload(local: payload(100, 2000.9), remote: phone)) == 200,
        "local subsecond precision must not defeat a cloud timestamp tie")
    let editedMac = payload(300, 3000, "new edit")
    let newResult = SyncMergeService.mergedPayload(local: editedMac, remote: phone)
    precondition(amount(newResult) == 300, "genuinely newer local edit must sync")
    let distinct = SyncMergeService.mergedPayload(local: old, remote: payload(200, 2000, "", true))
    precondition(distinct.snapshots[0].entries.count == 2, "remote-only entries must survive")
    let tombstone = ExportPayload.DeletionPayload(entityID: entryID, entityKind: "entry",
        deletedAt: Date(timeIntervalSince1970: 4000))
    let deleted = ExportPayload(exportedAt: phone.exportedAt, categories: [], items: [],
        snapshots: phone.snapshots, deletions: [tombstone])
    let deletedResult = SyncMergeService.mergedPayload(local: old, remote: deleted)
    precondition(deletedResult.snapshots[0].entries.isEmpty, "old local entries must not resurrect deletions")
    precondition(SyncMergeService.isSameContent(
        SyncMergeService.mergedPayload(local: phone, remote: phone), phone), "unchanged data must not upload")
    let baseline = payload(100, 1000)
    let skewedStaleMac = payload(100, 5000)
    let changedPhone = payload(200, 2000)
    let safeRemote = try SyncMergeService.reconciledPayload(local: skewedStaleMac, remote: changedPhone, baseline: baseline)
    precondition(amount(safeRemote) == 200, "unchanged stale local value must not win through clock skew")
    let slowClockEdit = try SyncMergeService.reconciledPayload(local: payload(300, 900), remote: baseline, baseline: baseline)
    precondition(amount(slowClockEdit) == 300, "genuine local edit survives a slow device clock")
    let sameSecondBase = payload(100, 2000)
    let sameSecondEdit = try SyncMergeService.reconciledPayload(local: payload(200, 2000.9), remote: sameSecondBase, baseline: sameSecondBase)
    precondition(amount(sameSecondEdit) == 200, "genuine same-second local edit must survive")
    func expectConflict(_ left: ExportPayload, _ right: ExportPayload, _ base: ExportPayload) {
        do { _ = try SyncMergeService.reconciledPayload(local: left, remote: right, baseline: base); preconditionFailure("conflicting edits were accepted") }
        catch SyncMergeService.Conflict.divergentEdits {}
        catch { preconditionFailure("unexpected conflict error") }
    }
    expectConflict(payload(300, 3000), changedPhone, baseline)
    expectConflict(payload(300, 900), changedPhone, baseline)
    // Delete versus a new edit requires a choice; a plain stale copy still respects deletion.
    expectConflict(payload(300, 3000), deleted, baseline)
    let cleanDelete = try SyncMergeService.reconciledPayload(local: baseline, remote: deleted, baseline: baseline)
    precondition(cleanDelete.snapshots[0].entries.isEmpty)
    let categoryID = UUID()
    func categoryPayload(_ group: String) -> ExportPayload {
        let category = ExportPayload.CategoryPayload(id: categoryID, name: "bank", group: group, createdAt: Date(timeIntervalSince1970: 100))
        return ExportPayload(exportedAt: Date(), categories: [category], items: [], snapshots: [], deletions: [])
    }
    let baseCategory = categoryPayload("financial"), remoteCategory = categoryPayload("liability")
    let categoryMerged = try SyncMergeService.reconciledPayload(local: baseCategory, remote: remoteCategory, baseline: baseCategory)
    precondition(categoryMerged.categories[0].group == "liability", "unversioned category must follow the changed side")
    let localCategoryMerged = try SyncMergeService.reconciledPayload(local: remoteCategory, remote: baseCategory, baseline: baseCategory)
    precondition(localCategoryMerged.categories[0].group == "liability")
    expectConflict(categoryPayload("physical"), remoteCategory, baseCategory)
    let extraItemID = UUID()
    func withEntry(_ original: ExportPayload, _ id: UUID, _ value: Double) -> ExportPayload {
        let prior = original.snapshots[0]
        let extra = ExportPayload.EntryPayload(id: id, amount: value, quantity: nil, unitPrice: nil,
            note: "", createdAt: Date(), updatedAt: Date(), itemID: extraItemID)
        let day = ExportPayload.SnapshotPayload(id: prior.id, date: prior.date, note: prior.note,
            createdAt: prior.createdAt, updatedAt: prior.updatedAt, goldAnchorPriceCNY: nil,
            goldAnchorPriceDate: nil, btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil,
            nasdaqAnchorPriceUSD: nil, nasdaqAnchorPriceDate: nil, usdPerCNY: nil,
            usdPerCNYDate: nil, marketAnchorsUpdatedAt: nil, entries: prior.entries + [extra])
        let item = ExportPayload.ItemPayload(id: extraItemID, name: "account", note: "", iconName: nil,
            valuationMethod: "directAmount", autoPricedAssetKind: nil, quantStrategyProxySymbol: nil,
            sortOrder: 0, isActive: true, createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100), categoryID: nil)
        return ExportPayload(exportedAt: Date(), categories: [], items: [item], snapshots: [day], deletions: [])
    }
    // Independently created entry UUIDs for one item must not double the balance.
    expectConflict(withEntry(baseline, UUID(), 50), withEntry(baseline, UUID(), 50), baseline)
    let otherSnapshot = ExportPayload.SnapshotPayload(id: UUID(), date: baseline.snapshots[0].date,
        note: "", createdAt: Date(), updatedAt: Date(), goldAnchorPriceCNY: nil, goldAnchorPriceDate: nil,
        btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil, nasdaqAnchorPriceUSD: nil, nasdaqAnchorPriceDate: nil,
        usdPerCNY: nil, usdPerCNYDate: nil, marketAnchorsUpdatedAt: nil, entries: [])
    let duplicateDay = ExportPayload(exportedAt: Date(), categories: [], items: [], snapshots: [otherSnapshot], deletions: [])
    let emptyBase = ExportPayload(exportedAt: Date(), categories: [], items: [], snapshots: [], deletions: [])
    expectConflict(baseline, duplicateDay, emptyBase)
    print("PASS: 21 cloud merge regression checks")
    """
    with tempfile.TemporaryDirectory(prefix="atm-cloud-merge-") as folder:
        main = pathlib.Path(folder) / "main.swift"
        executable = pathlib.Path(folder) / "probe"
        main.write_text(support + payload + merge + scenarios)
        subprocess.run(["swiftc", str(main), "-o", str(executable)], check=True, cwd=root)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    test_cloud_merge()
