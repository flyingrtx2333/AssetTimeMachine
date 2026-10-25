"""Exercise inherited-balance reconciliation using the actual shared merge code."""
from pathlib import Path
import subprocess
import tempfile


def test_cloud_inheritance():
    root = Path(__file__).resolve().parents[1]
    source = (root / "AssetTimeMachine/ImportExport.swift").read_text()
    payload = source[source.index("nonisolated struct ExportPayload:"):source.index("nonisolated struct VersionedExportPayload:")]
    merge = source[source.index("nonisolated enum SyncMergeService {"):]
    support = """import Foundation
    enum AssetGroup: String { case financial, physical, liability }
    enum SyncDeletedEntityKind: String { case category, item, snapshot, entry }
    """
    scenarios = r"""
    let itemID = UUID(), yesterdayID = UUID(), sourceEntryID = UUID()
    let yesterday = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    let today = yesterday.addingTimeInterval(86_400)
    func fixture(automatic: Bool = false, amount: Double = 100, quantity: Double = 12,
                 price: Double = 800, stamp: Double = 100, inherited: Bool = false,
                 includeToday: Bool = true) -> ExportPayload {
        let item = ExportPayload.ItemPayload(id: itemID, name: "Synthetic account", note: "",
            iconName: nil, valuationMethod: automatic ? "quantityAndUnitPrice" : "directAmount",
            autoPricedAssetKind: automatic ? "gold" : nil, quantStrategyProxySymbol: nil,
            sortOrder: 0, isActive: true, createdAt: yesterday, updatedAt: yesterday, categoryID: nil)
        let source = ExportPayload.EntryPayload(id: sourceEntryID, amount: automatic ? nil : 100,
            quantity: automatic ? 12 : nil, unitPrice: automatic ? 800 : nil, note: "",
            createdAt: yesterday, updatedAt: yesterday, itemID: itemID)
        func day(_ date: Date, id: UUID, row: ExportPayload.EntryPayload) -> ExportPayload.SnapshotPayload {
            .init(id: id, date: date, note: "", createdAt: date,
                updatedAt: date.addingTimeInterval(stamp), goldAnchorPriceCNY: nil,
                goldAnchorPriceDate: nil, btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil,
                nasdaqAnchorPriceUSD: nil, nasdaqAnchorPriceDate: nil,
                usdPerCNY: nil, usdPerCNYDate: nil, marketAnchorsUpdatedAt: nil, entries: [row])
        }
        let previous = day(yesterday, id: yesterdayID, row: source)
        var current = ExportPayload.EntryPayload(id: UUID(), amount: automatic ? nil : amount,
            quantity: automatic ? quantity : nil, unitPrice: automatic ? price : nil, note: "",
            createdAt: today, updatedAt: today.addingTimeInterval(stamp), itemID: itemID)
        current.inheritedFromEntryID = inherited ? sourceEntryID : nil
        return .init(exportedAt: today, categories: [], items: [item],
            snapshots: includeToday ? [previous, day(today, id: UUID(), row: current)] : [previous], deletions: [])
    }
    func current(_ payload: ExportPayload) -> ExportPayload.EntryPayload {
        payload.snapshots.first { $0.date == today }!.entries[0]
    }
    func expectConflict(_ local: ExportPayload, _ remote: ExportPayload, baseline: ExportPayload) {
        do {
            _ = try SyncMergeService.reconciledPayload(local: local, remote: remote, baseline: baseline)
            preconditionFailure("unproven or genuine user edits were overwritten")
        } catch SyncMergeService.Conflict.divergentEdits {}
        catch { preconditionFailure("unexpected reconciliation error: \(error)") }
    }

    let cashBase = fixture(includeToday: false)
    let copiedCash = try SyncMergeService.reconciledPayload(
        local: fixture(inherited: true), remote: fixture(amount: 200), baseline: cashBase)
    precondition(current(copiedCash).amount == 200 && current(copiedCash).inheritedFromEntryID == nil,
        "a proven automatic copy must accept the phone's confirmed same-day balance")

    expectConflict(fixture(amount: 120, inherited: true), fixture(amount: 200), baseline: cashBase)

    let quantityAndQuote = try SyncMergeService.reconciledPayload(
        local: fixture(automatic: true, price: 810, stamp: 300, inherited: true),
        remote: fixture(automatic: true, quantity: 13, price: 805, stamp: 200),
        baseline: fixture(automatic: true, includeToday: false))
    precondition(current(quantityAndQuote).quantity == 13
        && current(quantityAndQuote).unitPrice == 810
        && current(quantityAndQuote).inheritedFromEntryID == nil,
        "automatic quotes must preserve inheritance proof and combine with a confirmed quantity edit")

    expectConflict(fixture(), fixture(amount: 200), baseline: cashBase)
    print("PASS: 4 inherited-balance reconciliation checks")
    """
    with tempfile.TemporaryDirectory(prefix="atm-cloud-inheritance-") as folder:
        main = Path(folder) / "main.swift"
        executable = Path(folder) / "probe"
        main.write_text(support + payload + merge + scenarios)
        subprocess.run(["swiftc", str(main), "-o", str(executable)], check=True, cwd=root)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    test_cloud_inheritance()
