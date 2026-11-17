import Foundation
import SwiftData

enum SnapshotService {
    @MainActor
    static func latestSnapshot(in context: ModelContext) throws -> AssetSnapshot? {
        var descriptor = FetchDescriptor<AssetSnapshot>(
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @MainActor
    static func snapshot(on date: Date, in context: ModelContext) throws -> AssetSnapshot? {
        let dayStart = Calendar.current.startOfDay(for: date)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let predicate = #Predicate<AssetSnapshot> { snapshot in
            snapshot.date >= dayStart && snapshot.date < nextDay
        }
        var descriptor = FetchDescriptor<AssetSnapshot>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @MainActor
    static func createSnapshot(
        on date: Date,
        note: String = "",
        inheritPrevious: Bool = true,
        createMissingEntries: Bool = true,
        in context: ModelContext
    ) throws -> AssetSnapshot {
        if let existing = try snapshot(on: date, in: context) {
            if createMissingEntries, try ensureEntriesExist(for: existing, in: context) {
                existing.updatedAt = .now
                try context.save()
            }
            return existing
        }

        let normalizedDate = Calendar.current.startOfDay(for: date)
        let snapshot = AssetSnapshot(date: normalizedDate, note: note)
        context.insert(snapshot)

        if inheritPrevious, let previous = try latestSnapshot(before: normalizedDate, in: context) {
            let sortedEntries = previous.entries.sorted { lhs, rhs in
                lhs.item?.sortOrder ?? 0 < rhs.item?.sortOrder ?? 0
            }

            for previousEntry in sortedEntries {
                let entry = AssetEntry(
                    amount: previousEntry.amount,
                    quantity: previousEntry.quantity,
                    unitPrice: previousEntry.unitPrice,
                    note: previousEntry.note,
                    snapshot: snapshot,
                    item: previousEntry.item
                )
                entry.inheritedFromEntryID = previousEntry.id
                entry.amountEditedAt = previousEntry.amountEditedAt
                entry.quantityEditedAt = previousEntry.quantityEditedAt
                entry.unitPriceEditedAt = previousEntry.unitPriceEditedAt
                entry.noteEditedAt = previousEntry.noteEditedAt
                context.insert(entry)
            }
        }

        if createMissingEntries {
            _ = try ensureEntriesExist(for: snapshot, in: context)
        }

        snapshot.updatedAt = .now
        try context.save()
        return snapshot
    }

    @MainActor
    static func latestSnapshot(before date: Date, in context: ModelContext) throws -> AssetSnapshot? {
        let predicate = #Predicate<AssetSnapshot> { snapshot in
            snapshot.date < date
        }
        var descriptor = FetchDescriptor<AssetSnapshot>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Follow explicit copy links only; selecting descendants does not authorize
    /// changing them. The shared rebase checks their original values and clocks.
    @MainActor
    static func inheritedSnapshotIDs(dependingOn entryIDs: Set<UUID>, in context: ModelContext) throws -> Set<UUID> {
        var frontier = entryIDs, visited = entryIDs, snapshots: Set<UUID> = []
        while !frontier.isEmpty {
            let sources = Array(frontier)
            let rows = try context.fetch(FetchDescriptor<AssetEntry>(predicate: #Predicate { entry in
                if let source = entry.inheritedFromEntryID { return sources.contains(source) }
                else { return false }
            }))
            frontier.removeAll(keepingCapacity: true)
            for row in rows where visited.insert(row.id).inserted {
                if let snapshot = row.snapshot { snapshots.insert(snapshot.id) }
                frontier.insert(row.id)
            }
        }
        return snapshots
    }

    @MainActor
    private static func applyInheritedRebase(_ result: SyncMergeService.InheritedRebaseResult,
                                             in context: ModelContext) throws {
        guard !result.changedSnapshotIDs.isEmpty else { return }
        let ids = Array(result.changedSnapshotIDs)
        let snapshots = try context.fetch(FetchDescriptor<AssetSnapshot>(predicate: #Predicate { ids.contains($0.id) }))
        let payloads = Dictionary(result.payload.snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for snapshot in snapshots {
            guard let payload = payloads[snapshot.id] else { continue }
            let rows = Dictionary(grouping: snapshot.entries, by: \.id)
            for entry in payload.entries {
                guard let matches = rows[entry.id], matches.count == 1, let row = matches.first else { continue }
                row.amount = entry.amount; row.quantity = entry.quantity; row.unitPrice = entry.unitPrice
                row.note = entry.note; row.updatedAt = entry.updatedAt
                row.amountEditedAt = entry.amountEditedAt; row.quantityEditedAt = entry.quantityEditedAt
                row.unitPriceEditedAt = entry.unitPriceEditedAt; row.noteEditedAt = entry.noteEditedAt
            }
            snapshot.updatedAt = payload.updatedAt
        }
    }

    @MainActor
    @discardableResult
    static func ensureEntriesExist(for snapshot: AssetSnapshot, in context: ModelContext) throws -> Bool {
        let allItems = try context.fetch(FetchDescriptor<AssetItem>())
        let existingItemIDs = Set(snapshot.entries.compactMap { $0.item?.id })
        var didInsert = false

        for item in allItems where item.isActive && !existingItemIDs.contains(item.id) {
            let entry = AssetEntry(snapshot: snapshot, item: item)
            context.insert(entry)
            didInsert = true
        }
        return didInsert
    }

    @MainActor
    static func upsertEntry(
        snapshot: AssetSnapshot,
        item: AssetItem,
        amount: Double? = nil,
        quantity: Double? = nil,
        unitPrice: Double? = nil,
        note: String = "",
        saveChanges: Bool = true,
        in context: ModelContext
    ) throws {
        func valuesDiffer(_ lhs: Double?, _ rhs: Double?, tolerance: Double = 0.000_000_1) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return false
            case let (left?, right?):
                return abs(left - right) > tolerance
            default:
                return true
            }
        }

        let userEditTime = Date.now.timeIntervalSince1970
        if let existing = snapshot.entries.first(where: { $0.item?.id == item.id }) {
            let didChange = valuesDiffer(existing.amount, amount)
                || valuesDiffer(existing.quantity, quantity)
                || valuesDiffer(existing.unitPrice, unitPrice)
                || existing.note != note

            // Saving an inherited value confirms it even when the number is unchanged.
            guard didChange || existing.inheritedFromEntryID != nil else { return }

            let descendantDays = try inheritedSnapshotIDs(dependingOn: [existing.id], in: context)
            let before = descendantDays.isEmpty ? nil : try ImportExportService.exportDays([snapshot.id], from: context)

            let confirmingCopy = existing.inheritedFromEntryID != nil && !didChange
            if valuesDiffer(existing.amount, amount) || (confirmingCopy && amount != nil) { existing.amountEditedAt = userEditTime }
            if valuesDiffer(existing.quantity, quantity) || (confirmingCopy && quantity != nil) { existing.quantityEditedAt = userEditTime }
            if item.marketAssetSymbol == nil && valuesDiffer(existing.unitPrice, unitPrice) {
                existing.unitPriceEditedAt = userEditTime
            }
            if existing.note != note { existing.noteEditedAt = userEditTime }
            existing.amount = amount
            existing.quantity = quantity
            existing.unitPrice = unitPrice
            existing.note = note
            existing.inheritedFromEntryID = nil
            existing.updatedAt = .now
            if let before {
                let current = try ImportExportService.exportDays(descendantDays.union([snapshot.id]), from: context)
                try applyInheritedRebase(SyncMergeService.rebasedInheritance(in: current, provenBy: [before]), in: context)
            }
        } else {
            guard amount != nil || quantity != nil || unitPrice != nil || !note.isEmpty else {
                return
            }

            let entry = AssetEntry(
                amount: amount,
                quantity: quantity,
                unitPrice: unitPrice,
                note: note,
                snapshot: snapshot,
                item: item,
                amountEditedAt: amount == nil ? nil : userEditTime,
                quantityEditedAt: quantity == nil ? nil : userEditTime,
                unitPriceEditedAt: unitPrice == nil || item.marketAssetSymbol != nil ? nil : userEditTime,
                noteEditedAt: note.isEmpty ? nil : userEditTime
            )
            context.insert(entry)
        }

        snapshot.updatedAt = .now
        item.updatedAt = .now
        if saveChanges {
            try context.save()
        }
    }
}
