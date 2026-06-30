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
                context.insert(entry)
            }
        }

        if createMissingEntries {
            try ensureEntriesExist(for: snapshot, in: context)
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

    @MainActor
    static func ensureEntriesExist(for snapshot: AssetSnapshot, in context: ModelContext) throws {
        let allItems = try context.fetch(FetchDescriptor<AssetItem>())
        let existingItemIDs = Set(snapshot.entries.compactMap { $0.item?.id })

        for item in allItems where item.isActive && !existingItemIDs.contains(item.id) {
            let entry = AssetEntry(snapshot: snapshot, item: item)
            context.insert(entry)
        }
    }

    @MainActor
    static func upsertEntry(
        snapshot: AssetSnapshot,
        item: AssetItem,
        amount: Double? = nil,
        quantity: Double? = nil,
        unitPrice: Double? = nil,
        note: String = "",
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

        if let existing = snapshot.entries.first(where: { $0.item?.id == item.id }) {
            let didChange = valuesDiffer(existing.amount, amount)
                || valuesDiffer(existing.quantity, quantity)
                || valuesDiffer(existing.unitPrice, unitPrice)
                || existing.note != note

            guard didChange else { return }

            existing.amount = amount
            existing.quantity = quantity
            existing.unitPrice = unitPrice
            existing.note = note
            existing.updatedAt = .now
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
                item: item
            )
            context.insert(entry)
        }

        snapshot.updatedAt = .now
        item.updatedAt = .now
        try context.save()
    }
}
