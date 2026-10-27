"""Focused legacy-value review checks against the actual shared reconciler."""
from pathlib import Path
import subprocess
import tempfile


def test_cloud_conflict_review():
    root = Path(__file__).resolve().parents[1]
    source = (root / "AssetTimeMachine/ImportExport.swift").read_text()
    payload = source[source.index("nonisolated struct ExportPayload:"):source.index("nonisolated struct VersionedExportPayload:")]
    merge = source[source.index("nonisolated enum SyncMergeService {"):]
    support = """import Foundation
    enum AssetGroup: String { case financial, physical, liability }
    enum SyncDeletedEntityKind: String { case category, item, snapshot, entry }
    """
    scenarios = r'''
    let account = UUID(), extraAccount = UUID(), firstDay = UUID(), secondDay = UUID(), thirdDay = UUID()
    let firstRow = UUID(), secondRow = UUID(), thirdRow = UUID(), extraRow = UUID()
    let origin = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
    func item(_ id: UUID) -> ExportPayload.ItemPayload {
        .init(id: id, name: "Synthetic account", note: "", iconName: nil,
            valuationMethod: "directAmount", autoPricedAssetKind: nil, quantStrategyProxySymbol: nil,
            sortOrder: 0, isActive: true, createdAt: origin, updatedAt: origin, categoryID: nil)
    }
    func row(_ id: UUID, _ value: Double, note: String = "", itemID: UUID? = nil) -> ExportPayload.EntryPayload {
        .init(id: id, amount: value, quantity: nil, unitPrice: nil, note: note,
            createdAt: origin, updatedAt: origin, itemID: itemID ?? account)
    }
    func day(_ id: UUID, offset: Int, entries: [ExportPayload.EntryPayload]) -> ExportPayload.SnapshotPayload {
        .init(id: id, date: origin.addingTimeInterval(Double(offset) * 86_400), note: "",
            createdAt: origin, updatedAt: origin, goldAnchorPriceCNY: nil, goldAnchorPriceDate: nil,
            btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil, nasdaqAnchorPriceUSD: nil,
            nasdaqAnchorPriceDate: nil, usdPerCNY: nil, usdPerCNYDate: nil,
            marketAnchorsUpdatedAt: nil, entries: entries)
    }
    func bundle(_ snapshots: [ExportPayload.SnapshotPayload], extra: Bool = false) -> ExportPayload {
        .init(exportedAt: origin, categories: [], items: extra ? [item(account), item(extraAccount)] : [item(account)],
            snapshots: snapshots, deletions: [])
    }
    let base = bundle([day(firstDay, offset: 0, entries: [row(firstRow, 10)])])
    let phone = bundle(base.snapshots + [day(secondDay, offset: 1, entries: [row(secondRow, 20)]),
        day(thirdDay, offset: 2, entries: [row(thirdRow, 40)])])
    let cloud = bundle(base.snapshots + [day(secondDay, offset: 1,
        entries: [row(secondRow, 30), row(extraRow, 7, itemID: extraAccount)])], extra: true)
    do {
        _ = try SyncMergeService.reconciledPayload(local: phone, remote: cloud, baseline: base)
        preconditionFailure("Legacy disagreement must not be silently inferred as inheritance")
    } catch SyncMergeService.Conflict.divergentEdits {}
    let review = try SyncMergeService.reviewedPayload(local: phone, remote: cloud, baseline: base)
    precondition(review.payload == nil && review.conflicts.count == 1,
        "A review must expose no partial candidate")
    let conflict = review.conflicts[0]
    precondition(conflict.field == .amount && conflict.itemID == account
        && conflict.date == origin.addingTimeInterval(86_400), "Conflict must identify the exact day/account/field")
    for side in [SyncMergeService.EntryChoice.local, .remote] {
        let resolved = try SyncMergeService.reviewedPayload(local: phone, remote: cloud, baseline: base,
            choices: [conflict.id: side]).payload!
        precondition(resolved.snapshots.first { $0.id == secondDay }!.entries.first { $0.itemID == account }!.amount
            == (side == .local ? 20 : 30))
        precondition(resolved.snapshots.first { $0.id == thirdDay }!.entries[0].amount == 40,
            "Resolving a historical field must preserve later local days")
        precondition(resolved.items.contains { $0.id == extraAccount }
            && resolved.snapshots.flatMap(\.entries).contains { $0.itemID == extraAccount && $0.amount == 7 },
            "Resolving a field must retain independent cloud additions")
    }
    do {
        _ = try SyncMergeService.reviewedPayload(local: phone, remote: cloud, baseline: base,
            choices: ["obsolete-field": .local])
        preconditionFailure("Unknown choice keys must be rejected")
    } catch SyncMergeService.Conflict.divergentEdits {}
    let notePhone = bundle(base.snapshots + [day(secondDay, offset: 1, entries: [row(secondRow, 20, note: "local")])])
    let noteCloud = bundle(base.snapshots + [day(secondDay, offset: 1, entries: [row(secondRow, 30, note: "remote")])])
    let partial = try SyncMergeService.reviewedPayload(local: notePhone, remote: noteCloud, baseline: base,
        choices: [conflict.id: .local])
    precondition(partial.payload == nil && partial.conflicts.count == 2,
        "Every conflicting field needs its own explicit choice")
    let duplicate = bundle(base.snapshots + [day(UUID(), offset: 0, entries: [row(UUID(), 99)])])
    let empty = ExportPayload(exportedAt: origin, categories: [], items: [], snapshots: [], deletions: [])
    let agreement = try SyncMergeService.reconciledPayload(local: duplicate, remote: duplicate, baseline: empty)
    precondition(SyncMergeService.isSameContent(agreement, duplicate),
        "Matching historical duplicates must heal an obsolete baseline without duplicating or deleting data")
    let deletion = ExportPayload(exportedAt: origin, categories: [], items: [item(account)], snapshots: [],
        deletions: [.init(entityID: firstRow, entityKind: "entry", deletedAt: origin,
                         snapshotDate: origin, itemID: account)])
    let edited = bundle([day(firstDay, offset: 0, entries: [row(firstRow, 50)])])
    do {
        _ = try SyncMergeService.reviewedPayload(local: deletion, remote: edited, baseline: base)
        preconditionFailure("Value review cannot bypass delete-versus-edit protection")
    } catch SyncMergeService.Conflict.divergentEdits {}

    func automatic(_ price: Double, marker: UUID?) -> ExportPayload {
        let asset = ExportPayload.ItemPayload(id: account, name: "Synthetic auto", note: "", iconName: nil,
            valuationMethod: "quantityAndUnitPrice", autoPricedAssetKind: "gold", quantStrategyProxySymbol: nil,
            sortOrder: 0, isActive: true, createdAt: origin, updatedAt: origin, categoryID: nil)
        var entry = ExportPayload.EntryPayload(id: firstRow, amount: nil, quantity: 2, unitPrice: price,
            note: "", createdAt: origin, updatedAt: origin.addingTimeInterval(price), itemID: account)
        entry.inheritedFromEntryID = marker
        return .init(exportedAt: Date(), categories: [], items: [asset],
            snapshots: [day(firstDay, offset: 0, entries: [entry])], deletions: [])
    }
    let quoteBefore = try SyncMergeService.userContentData(for: automatic(10, marker: secondRow))
    let quoteAfter = try SyncMergeService.userContentData(for: automatic(11, marker: secondRow))
    let confirmed = try SyncMergeService.userContentData(for: automatic(10, marker: nil))
    let phoneIntent = try SyncMergeService.userContentData(for: phone)
    let changedIntent = try SyncMergeService.userContentData(for: notePhone)
    precondition(quoteBefore == quoteAfter,
        "Automatic quotes and timestamps must not expire user choices")
    precondition(quoteBefore != confirmed,
        "Manual confirmation of an inherited value must expire older choices")
    precondition(phoneIntent != changedIntent, "User changes must expire a review")
    print("PASS: legacy field review, both choices, future days, cloud additions, stale keys, partial choices, consensus, deletion guard and intent fingerprints")
    '''
    with tempfile.TemporaryDirectory(prefix="atm-cloud-review-") as directory:
        main = Path(directory) / "main.swift"
        executable = Path(directory) / "probe"
        main.write_text(support + payload + merge + scenarios)
        subprocess.run(["swiftc", str(main), "-o", str(executable)], check=True, cwd=root)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    test_cloud_conflict_review()
