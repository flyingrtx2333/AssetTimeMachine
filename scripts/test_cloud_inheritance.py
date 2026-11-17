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
    // Two offline carry-forward days must trace back to the acknowledged source,
    // even though neither intermediate day exists in the common baseline.
    func carryChain(_ amount: Double) -> ExportPayload {
        var snapshots: [ExportPayload.SnapshotPayload] = []
        var sourceID: UUID? = nil
        for offset in 0..<3 {
            let date = yesterday.addingTimeInterval(Double(offset) * 86_400)
            let rowID = offset == 0 ? sourceEntryID : UUID()
            var row = ExportPayload.EntryPayload(id: rowID, amount: amount,
                quantity: nil, unitPrice: nil, note: "", createdAt: date, updatedAt: date, itemID: itemID)
            row.inheritedFromEntryID = sourceID
            snapshots.append(.init(id: offset == 0 ? yesterdayID : UUID(), date: date, note: "",
                createdAt: date, updatedAt: date, goldAnchorPriceCNY: nil, goldAnchorPriceDate: nil,
                btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil, nasdaqAnchorPriceUSD: nil,
                nasdaqAnchorPriceDate: nil, usdPerCNY: nil, usdPerCNYDate: nil,
                marketAnchorsUpdatedAt: nil, entries: [row]))
            sourceID = rowID
        }
        return .init(exportedAt: snapshots.last!.date, categories: [], items: cashBase.items,
            snapshots: snapshots, deletions: [])
    }
    let offlineChain = try SyncMergeService.reconciledPayload(
        local: carryChain(100), remote: carryChain(200), baseline: cashBase)
    precondition(offlineChain.snapshots.count == 3
        && offlineChain.snapshots.allSatisfy { $0.entries[0].amount == 200 },
        "multiple unacknowledged inherited days must accept the edited common source without false conflict")

    func row(_ id: UUID, amount: Double? = 100, quantity: Double? = nil, price: Double? = nil,
             note: String = "", source: UUID? = nil, amountEdit: Double? = nil,
             quantityEdit: Double? = nil, priceEdit: Double? = nil, noteEdit: Double? = nil,
             item: UUID = itemID, stamp: Double = 0) -> ExportPayload.EntryPayload {
        .init(id: id, amount: amount, quantity: quantity, unitPrice: price, note: note,
            createdAt: yesterday, updatedAt: yesterday.addingTimeInterval(stamp), itemID: item,
            inheritedFromEntryID: source, amountEditedAt: amountEdit, quantityEditedAt: quantityEdit,
            unitPriceEditedAt: priceEdit, noteEditedAt: noteEdit)
    }
    let copyDayID = UUID(), copyID = UUID(), tailDayID = UUID(), tailID = UUID()
    func day(_ offset: Int, _ row: ExportPayload.EntryPayload) -> ExportPayload.SnapshotPayload {
        let date = yesterday.addingTimeInterval(Double(offset) * 86_400)
        return .init(id: offset == 0 ? yesterdayID : (offset == 1 ? copyDayID : tailDayID), date: date,
            note: "day metadata", createdAt: date, updatedAt: date, goldAnchorPriceCNY: nil,
            goldAnchorPriceDate: nil, btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil,
            nasdaqAnchorPriceUSD: nil, nasdaqAnchorPriceDate: nil, usdPerCNY: nil,
            usdPerCNYDate: nil, marketAnchorsUpdatedAt: nil, entries: [row])
    }
    func bundle(_ days: [ExportPayload.SnapshotPayload], items: [ExportPayload.ItemPayload]? = nil,
                deletions: [ExportPayload.DeletionPayload] = []) -> ExportPayload {
        .init(exportedAt: today, categories: [], items: items ?? cashBase.items,
            snapshots: days, deletions: deletions)
    }
    let oldSource = row(sourceEntryID, amountEdit: 123.456)
    let newSource = row(sourceEntryID, amount: 455, amountEdit: 456.789, stamp: 500)
    let oldBase = bundle([day(0, oldSource)])
    let staleCopy = row(copyID, source: sourceEntryID, amountEdit: oldSource.amountEditedAt)
    let localOnlyToday = bundle([day(0, oldSource), day(1, staleCopy)])
    let updatedYesterday = bundle([day(0, newSource)])
    let oneSided = try SyncMergeService.reconciledPayload(
        local: localOnlyToday, remote: updatedYesterday, baseline: oldBase)
    precondition(current(oneSided).amount == 455,
        "a local-only inherited today must follow yesterday's remotely edited 455")

    var checks: [String: Bool] = [:]
    let staleResult = bundle([day(0, newSource), day(1, staleCopy)])
    let repaired = SyncMergeService.rebasedInheritance(in: staleResult, provenBy: [oldBase])
    let repairedEntry = current(repaired.payload)
    checks["baselineProvesAlreadyStaleCopy"] = repairedEntry.amount == 455
        && repairedEntry.amountEditedAt == newSource.amountEditedAt
        && repaired.changedSnapshotIDs == [copyDayID]
    checks["identitiesDatesAndProvenanceSurviveRebase"] = repairedEntry.id == staleCopy.id
        && repairedEntry.createdAt == staleCopy.createdAt && repairedEntry.inheritedFromEntryID == sourceEntryID
        && repaired.payload.snapshots[1].date == staleResult.snapshots[1].date
        && repaired.payload.snapshots[1].createdAt == staleResult.snapshots[1].createdAt
    let laterExport = ExportPayload(exportedAt: today.addingTimeInterval(5_000), categories: staleResult.categories,
        items: staleResult.items, snapshots: staleResult.snapshots, deletions: [])
    let stamped = SyncMergeService.rebasedInheritance(in: laterExport, provenBy: [oldBase])
    checks["repairAdvancesMetadataWithoutMintingUserClock"] = current(stamped.payload).updatedAt == laterExport.exportedAt
        && stamped.payload.snapshots[1].updatedAt == laterExport.exportedAt
        && current(stamped.payload).amountEditedAt == newSource.amountEditedAt
    let again = SyncMergeService.rebasedInheritance(in: repaired.payload, provenBy: [oldBase])
    checks["repeatedRebaseIsStable"] = again.changedSnapshotIDs.isEmpty
        && SyncMergeService.isSameContent(repaired.payload, again.payload)
    let agreement = try SyncMergeService.reconciledPayload(local: staleResult, remote: staleResult, baseline: oldBase)
    checks["identicalReplicasStillRepairProvenStaleCopies"] = current(agreement).amount == 455

    let tail = row(tailID, source: copyID, amountEdit: oldSource.amountEditedAt)
    let staleChain = bundle([day(2, tail), day(1, staleCopy), day(0, oldSource)])
    let mergedChain = try SyncMergeService.reconciledPayload(local: staleChain, remote: updatedYesterday, baseline: oldBase)
    checks["localOnlyOfflineChainFollowsUpdatedAncestor"] = mergedChain.snapshots.count == 3
        && mergedChain.snapshots.allSatisfy { $0.entries[0].amount == 455 }
    let unordered = bundle([day(2, tail), day(1, staleCopy), day(0, newSource)])
    let chain = SyncMergeService.rebasedInheritance(in: unordered, provenBy: [staleChain])
    checks["allCopyEdgesAreCapturedBeforeAscendingChainUpdates"] = chain.changedSnapshotIDs == [copyDayID, tailDayID]
        && chain.payload.snapshots.map(\.id) == unordered.snapshots.map(\.id)
        && chain.payload.snapshots.allSatisfy { $0.entries[0].amount == 455 }
        && chain.payload.snapshots[0].entries[0].inheritedFromEntryID == copyID

    let manual = bundle([day(0, newSource), day(1, row(copyID, amount: 0, amountEdit: 999)),
                         day(2, row(tailID, amountEdit: 1_000))])
    let manualResult = SyncMergeService.rebasedInheritance(in: manual, provenBy: [oldBase])
    checks["explicitZeroAndUnchangedConfirmationAreNotCopies"] = manualResult.changedSnapshotIDs.isEmpty
        && SyncMergeService.isSameContent(manualResult.payload, manual)
    for (name, entry) in [
        ("markerDoesNotProveDifferentAmount", row(copyID, amount: 123, source: sourceEntryID, amountEdit: 123.456)),
        ("markerDoesNotProveDifferentClock", row(copyID, source: sourceEntryID, amountEdit: 999)),
        ("markerDoesNotProveUserNote", row(copyID, note: "User note", source: sourceEntryID, amountEdit: 123.456)),
        ("missingSourceMarkerDoesNotProveCopy", row(copyID, source: UUID(), amountEdit: 123.456)),
    ] {
        let value = bundle([day(0, newSource), day(1, entry)])
        let result = SyncMergeService.rebasedInheritance(in: value, provenBy: [oldBase])
        checks[name] = result.changedSnapshotIDs.isEmpty && SyncMergeService.isSameContent(result.payload, value)
    }
    let nilZero: [(ExportPayload.EntryPayload, Double?)] = [(row(sourceEntryID, amount: nil), 0), (row(sourceEntryID, amount: 0), nil)]
    for (index, sample) in nilZero.enumerated() {
        let value = bundle([day(0, newSource), day(1, row(copyID, amount: sample.1, source: sourceEntryID))])
        checks["nilAndZeroAreDistinct-\(index)"] = SyncMergeService.rebasedInheritance(
            in: value, provenBy: [bundle([day(0, sample.0)])]).changedSnapshotIDs.isEmpty
    }

    let automaticItems = fixture(automatic: true, includeToday: false).items
    let previousQuantity = row(sourceEntryID, amount: nil, quantity: 12, price: 800, quantityEdit: 100, priceEdit: 200)
    let editedQuantity = row(sourceEntryID, amount: nil, quantity: 15, price: 850, quantityEdit: 300, priceEdit: 400)
    let copiedQuantity = row(copyID, amount: nil, quantity: 12, price: 900, source: sourceEntryID,
        quantityEdit: 100, priceEdit: 999)
    let quantityProof = bundle([day(0, previousQuantity)], items: automaticItems)
    let quantityResult = SyncMergeService.rebasedInheritance(in: bundle(
        [day(0, editedQuantity), day(1, copiedQuantity)], items: automaticItems), provenBy: [quantityProof])
    let quantityEntry = current(quantityResult.payload)
    checks["automaticHoldingFollowsQuantityButPreservesOwnQuoteAndClock"] = quantityEntry.quantity == 15
        && quantityEntry.quantityEditedAt == 300 && quantityEntry.unitPrice == 900 && quantityEntry.unitPriceEditedAt == 999
    let editedCopyClock = row(copyID, amount: nil, quantity: 12, price: 900, source: sourceEntryID,
        quantityEdit: 101, priceEdit: 999)
    checks["differentQuantityEditClockInvalidatesCopyProof"] = SyncMergeService.rebasedInheritance(in: bundle(
        [day(0, editedQuantity), day(1, editedCopyClock)], items: automaticItems),
        provenBy: [quantityProof]).changedSnapshotIDs.isEmpty
    func binding(_ symbol: String?) -> ExportPayload.ItemPayload {
        let item = automaticItems[0]
        return .init(id: item.id, name: item.name, note: item.note, iconName: item.iconName,
            valuationMethod: item.valuationMethod, autoPricedAssetKind: symbol,
            quantStrategyProxySymbol: item.quantStrategyProxySymbol, sortOrder: item.sortOrder,
            isActive: item.isActive, createdAt: item.createdAt, updatedAt: item.updatedAt, categoryID: item.categoryID)
    }
    let manualPrice = row(copyID, amount: nil, quantity: 12, price: 800, source: sourceEntryID,
        quantityEdit: 100, priceEdit: 200)
    let manualPriceResult = SyncMergeService.rebasedInheritance(in: bundle(
        [day(0, editedQuantity), day(1, manualPrice)], items: [binding(nil)]),
        provenBy: [bundle([day(0, previousQuantity)], items: [binding(nil)])])
    checks["manualPriceAndCopiedClocksFollowSource"] = current(manualPriceResult.payload).quantity == 15
        && current(manualPriceResult.payload).unitPrice == 850 && current(manualPriceResult.payload).unitPriceEditedAt == 400
    checks["changedMarketBindingCannotExemptPriceFromProof"] = SyncMergeService.rebasedInheritance(in: bundle(
        [day(0, editedQuantity), day(1, copiedQuantity)], items: automaticItems),
        provenBy: [bundle([day(0, previousQuantity)], items: [binding("silver")])]).changedSnapshotIDs.isEmpty

    let missingSource = bundle([day(1, staleCopy)])
    checks["sourceMustStillExistInResult"] = SyncMergeService.rebasedInheritance(
        in: missingSource, provenBy: [oldBase]).changedSnapshotIDs.isEmpty
    let deletedSource = bundle([day(0, newSource), day(1, staleCopy)], deletions: [
        .init(entityID: sourceEntryID, entityKind: "entry", deletedAt: today)])
    checks["deletedSourceCannotRebaseDescendant"] = SyncMergeService.rebasedInheritance(
        in: deletedSource, provenBy: [oldBase]).changedSnapshotIDs.isEmpty
    checks["sourceMustBeEarlierThanDescendant"] = SyncMergeService.rebasedInheritance(in: bundle(
        [day(2, newSource), day(1, staleCopy)]), provenBy: [oldBase]).changedSnapshotIDs.isEmpty
    let cyclicSource = row(sourceEntryID, amount: 455, source: copyID, amountEdit: 456.789)
    checks["malformedCyclesAndTheirImmediateDescendantsAreSkipped"] = SyncMergeService.rebasedInheritance(in: bundle(
        [day(0, cyclicSource), day(1, staleCopy), day(2, tail)]), provenBy: [staleChain]).changedSnapshotIDs.isEmpty
    checks["ambiguousCurrentSourceIDsAreSkipped"] = SyncMergeService.rebasedInheritance(in: bundle(
        [day(0, newSource), day(1, staleCopy), day(2, oldSource)]), provenBy: [oldBase]).changedSnapshotIDs.isEmpty
    let failures = checks.filter { !$0.value }.map(\.key).sorted()
    precondition(failures.isEmpty, "Inheritance regression failures: \(failures)")
    print("PASS: \(6 + checks.count) inherited-balance reconciliation checks")
    """
    with tempfile.TemporaryDirectory(prefix="atm-cloud-inheritance-") as folder:
        main = Path(folder) / "main.swift"
        executable = Path(folder) / "probe"
        main.write_text(support + payload + merge + scenarios)
        subprocess.run(["swiftc", str(main), "-o", str(executable)], check=True, cwd=root)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    test_cloud_inheritance()
