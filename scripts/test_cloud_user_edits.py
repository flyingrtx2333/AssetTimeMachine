"""Exercise user edits versus automatic copies/quotes with the shipped reconciler."""
from pathlib import Path
import subprocess
import tempfile


def test_cloud_user_edits():
    root = Path(__file__).resolve().parents[1]
    source = (root / "AssetTimeMachine/ImportExport.swift").read_text()
    payload = source[source.index("nonisolated struct ExportPayload:"):source.index("nonisolated struct VersionedExportPayload:")]
    merge = source[source.index("nonisolated enum SyncMergeService {"):]
    support = """import Foundation
    enum AssetGroup: String { case financial, physical, liability }
    enum SyncDeletedEntityKind: String { case category, item, snapshot, entry }
    """
    scenarios = r'''
    let itemID = UUID(), originID = UUID(), originRow = UUID()
    let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
    let item = ExportPayload.ItemPayload(id: itemID, name: "Synthetic holding", note: "", iconName: nil,
        valuationMethod: "quantityAndUnitPrice", autoPricedAssetKind: "gold", quantStrategyProxySymbol: nil,
        sortOrder: 0, isActive: true, createdAt: start, updatedAt: start, categoryID: nil)
    func row(_ id: UUID, _ quantity: Double, source: UUID? = nil,
             edit: Double? = nil, quote: Double = 100, quoteTime: Double = 0, note: String = "", noteEdit: Double? = nil) -> ExportPayload.EntryPayload {
        .init(id: id, amount: nil, quantity: quantity, unitPrice: quote, note: note,
            createdAt: start, updatedAt: start.addingTimeInterval(quoteTime), itemID: itemID,
            inheritedFromEntryID: source, quantityEditedAt: edit, noteEditedAt: noteEdit)
    }
    func day(_ id: UUID, _ offset: Int, _ entry: ExportPayload.EntryPayload) -> ExportPayload.SnapshotPayload {
        .init(id: id, date: start.addingTimeInterval(Double(offset) * 86400), note: "",
            createdAt: start, updatedAt: start, goldAnchorPriceCNY: nil, goldAnchorPriceDate: nil,
            btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil, nasdaqAnchorPriceUSD: nil,
            nasdaqAnchorPriceDate: nil, usdPerCNY: nil, usdPerCNYDate: nil,
            marketAnchorsUpdatedAt: nil, entries: [entry])
    }
    let deletion = ExportPayload.DeletionPayload(entityID: UUID(), entityKind: "entry", deletedAt: start)
    func bundle(_ days: [ExportPayload.SnapshotPayload]) -> ExportPayload {
        .init(exportedAt: start, categories: [], items: [item], snapshots: days, deletions: [deletion])
    }
    let first = day(originID, 0, row(originRow, 10))
    let phoneSecond = UUID(), macSecond = UUID()
    let phone = bundle([first, day(UUID(), 1, row(phoneSecond, 10, source: originRow)),
        day(UUID(), 2, row(UUID(), 10, source: phoneSecond, quote: 300, quoteTime: 999999))])
    let mac = bundle([first, day(UUID(), 1, row(macSecond, 20)),
        day(UUID(), 2, row(UUID(), 20, source: macSecond, quote: 200, quoteTime: 500000))])
    let recovered = SyncMergeService.sharedHistoryBaseline(local: phone, remote: mac)!
    precondition(recovered.snapshots.count == 1 && recovered.deletionRecords.count == 1)
    let merged = try SyncMergeService.reconciledPayload(local: phone, remote: mac, baseline: recovered)
    precondition(merged.snapshots.count == 3 && merged.snapshots.filter { $0.date > start }
        .allSatisfy { $0.entries.count == 1 && $0.entries[0].quantity == 20 },
        "Today's automatic copies must follow the latest confirmed ancestor, not today's quote timestamp")

    let laterQuote = bundle([day(originID, 0, row(originRow, 11, edit: 100.123456, quote: 300, quoteTime: 300))])
    let laterEdit = bundle([day(originID, 0, row(originRow, 12, edit: 200.123456, quote: 200, quoteTime: 200))])
    let base = bundle([first])
    for (left, right) in [(laterQuote, laterEdit), (laterEdit, laterQuote)] {
        let result = try SyncMergeService.reconciledPayload(local: left, remote: right, baseline: base).snapshots[0].entries[0]
        precondition(result.quantity == 12 && result.unitPrice == 300 && result.quantityEditedAt == 200.123456,
            "The latest user edit and the latest automatic quote must be selected independently")
    }
    let changedNote = bundle([day(originID, 0, row(originRow, 11, edit: 100, note: "User note", noteEdit: 300))])
    let independent = try SyncMergeService.reconciledPayload(local: changedNote, remote: laterEdit, baseline: base)
        .snapshots[0].entries[0]
    precondition(independent.quantity == 12 && independent.note == "User note",
        "A newer quantity edit must not erase an independent note edit")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let roundTrip = try decoder.decode(ExportPayload.self, from: encoder.encode(laterEdit))
    precondition(roundTrip.snapshots[0].entries[0].quantityEditedAt == 200.123456)
    precondition(SyncMergeService.sharedHistoryBaseline(local: base,
        remote: bundle([day(originID, 0, row(originRow, 10, edit: 100, quote: 500))])) != nil,
        "Quote refreshes and edit-clock metadata alone must not hide shared user history")
    precondition(SyncMergeService.sharedHistoryBaseline(local: phone,
        remote: bundle([day(UUID(), 0, row(UUID(), 10))])) == nil,
        "An unrelated account must not be associated without evidence of common history")
    print("PASS: automatic copy ancestry, independent user/quote clocks, timestamp round-trip, unrelated account")
    '''
    with tempfile.TemporaryDirectory(prefix="atm-user-edits-") as folder:
        main = Path(folder) / "main.swift"
        executable = Path(folder) / "probe"
        main.write_text(support + payload + merge + scenarios)
        subprocess.run(["swiftc", str(main), "-o", str(executable)], check=True, cwd=root)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    test_cloud_user_edits()
