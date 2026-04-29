import Foundation
import SwiftData

struct SnapshotMetrics {
    let date: Date
    let totalAssets: Double
    let totalLiabilities: Double
    let netAssets: Double
}

struct ChangeMetrics {
    let absoluteChange: Double
    let percentageChange: Double?
}

struct DrawdownMetrics {
    let peakValue: Double
    let troughValue: Double
    let drawdownRatio: Double
    let peakDate: Date
    let troughDate: Date
}

enum ComparisonPeriod: CaseIterable {
    case day
    case week
    case month
    case year

    var calendarComponent: Calendar.Component {
        switch self {
        case .day:
            return .day
        case .week:
            return .day
        case .month:
            return .month
        case .year:
            return .year
        }
    }

    var offsetValue: Int {
        switch self {
        case .day:
            return -1
        case .week:
            return -7
        case .month:
            return -1
        case .year:
            return -1
        }
    }
}

enum SeedDataService {
    static let defaultCategories: [(name: String, group: AssetGroup)] = [
        ("金融资产", .financial),
        ("实物资产", .physical),
        ("负债", .liability)
    ]

    @MainActor
    static func seedDefaultCategoriesIfNeeded(in context: ModelContext) throws {
        let descriptor = FetchDescriptor<AssetCategory>()
        let existingCategories = try context.fetch(descriptor)

        guard existingCategories.isEmpty else { return }

        for (index, category) in defaultCategories.enumerated() {
            let model = AssetCategory(
                name: category.name,
                group: category.group,
                createdAt: .now
            )
            context.insert(model)

            let placeholderItem = AssetItem(
                name: sampleItemName(for: category.group),
                note: "示例项目，可后续编辑或删除",
                valuationMethod: .directAmount,
                sortOrder: index,
                category: model
            )
            context.insert(placeholderItem)
        }

        try context.save()
    }

    private static func sampleItemName(for group: AssetGroup) -> String {
        switch group {
        case .financial:
            return "银行卡"
        case .physical:
            return "房产"
        case .liability:
            return "房贷"
        }
    }
}

enum AssetItemService {
    @MainActor
    static func createItem(
        name: String,
        category: AssetCategory,
        valuationMethod: ValuationMethod = .directAmount,
        autoPricedAssetKind: AutoPricedAssetKind? = nil,
        note: String = "",
        in context: ModelContext
    ) throws -> AssetItem {
        let nextSortOrder = (category.items.map(\AssetItem.sortOrder).max() ?? -1) + 1
        let item = AssetItem(
            name: name,
            note: note,
            valuationMethod: valuationMethod,
            autoPricedAssetKind: autoPricedAssetKind,
            sortOrder: nextSortOrder,
            category: category
        )
        context.insert(item)
        try context.save()
        return item
    }

    @MainActor
    static func updateItem(
        _ item: AssetItem,
        name: String? = nil,
        note: String? = nil,
        valuationMethod: ValuationMethod? = nil,
        autoPricedAssetKind: AutoPricedAssetKind?? = nil,
        isActive: Bool? = nil,
        category: AssetCategory? = nil,
        in context: ModelContext
    ) throws {
        if let name { item.name = name }
        if let note { item.note = note }
        if let valuationMethod { item.valuationMethod = valuationMethod }
        if let autoPricedAssetKind { item.autoPricedAssetKind = autoPricedAssetKind }
        if let isActive { item.isActive = isActive }
        if let category { item.category = category }
        item.updatedAt = .now
        try context.save()
    }

    @MainActor
    static func reorderItems(
        in category: AssetCategory,
        itemIDsInOrder: [UUID],
        context: ModelContext
    ) throws {
        let orderMap = Dictionary(uniqueKeysWithValues: itemIDsInOrder.enumerated().map { ($1, $0) })

        for item in category.items {
            if let order = orderMap[item.id] {
                item.sortOrder = order
                item.updatedAt = .now
            }
        }

        try context.save()
    }

    @MainActor
    static func activeItems(in category: AssetCategory, context: ModelContext) throws -> [AssetItem] {
        let allItems = try context.fetch(FetchDescriptor<AssetItem>())
        return allItems
            .filter { $0.category?.id == category.id && $0.isActive }
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.sortOrder < rhs.sortOrder
            }
    }
}

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
        let allSnapshots = try context.fetch(FetchDescriptor<AssetSnapshot>())
        return allSnapshots.first { Calendar.current.isDate($0.date, inSameDayAs: dayStart) }
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
        if let existing = snapshot.entries.first(where: { $0.item?.id == item.id }) {
            existing.amount = amount
            existing.quantity = quantity
            existing.unitPrice = unitPrice
            existing.note = note
            existing.updatedAt = .now
        } else {
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

enum TrendAnalysisService {
    static func nearestSnapshot(to targetDate: Date, in snapshots: [AssetSnapshot]) -> AssetSnapshot? {
        let sorted = snapshots.sorted { abs($0.date.timeIntervalSince(targetDate)) < abs($1.date.timeIntervalSince(targetDate)) }
        return sorted.first
    }

    static func comparisonMetrics(
        for current: AssetSnapshot,
        period: ComparisonPeriod,
        in snapshots: [AssetSnapshot],
        calendar: Calendar = .current
    ) -> ChangeMetrics? {
        let targetDate = calendar.date(byAdding: period.calendarComponent, value: period.offsetValue, to: current.date)
        guard let targetDate,
              let previous = nearestSnapshot(to: targetDate, in: snapshots.filter({ $0.id != current.id }))
        else {
            return nil
        }

        let previousMetrics = PortfolioCalculator.metrics(for: previous)
        let currentMetrics = PortfolioCalculator.metrics(for: current)
        return PortfolioCalculator.change(from: previousMetrics, to: currentMetrics)
    }

    static func dateRangeMetrics(
        from startDate: Date,
        to endDate: Date,
        in snapshots: [AssetSnapshot]
    ) -> [SnapshotMetrics] {
        snapshots
            .filter { $0.date >= startDate && $0.date <= endDate }
            .sorted { $0.date < $1.date }
            .map(PortfolioCalculator.metrics(for:))
    }

    static func latestMetrics(in snapshots: [AssetSnapshot]) -> SnapshotMetrics? {
        snapshots
            .max(by: { $0.date < $1.date })
            .map(PortfolioCalculator.metrics(for:))
    }
}

enum PortfolioCalculator {
    static func metrics(for snapshot: AssetSnapshot) -> SnapshotMetrics {
        let totalAssets = totalAssets(for: snapshot)
        let totalLiabilities = totalLiabilities(for: snapshot)
        return SnapshotMetrics(
            date: snapshot.date,
            totalAssets: totalAssets,
            totalLiabilities: totalLiabilities,
            netAssets: totalAssets - totalLiabilities
        )
    }

    static func totalAssets(for snapshot: AssetSnapshot) -> Double {
        snapshot.entries
            .filter { ($0.item?.category?.group ?? .financial) != .liability }
            .reduce(0) { $0 + $1.resolvedAmount }
    }

    static func totalLiabilities(for snapshot: AssetSnapshot) -> Double {
        snapshot.entries
            .filter { ($0.item?.category?.group ?? .financial) == .liability }
            .reduce(0) { $0 + $1.resolvedAmount }
    }

    static func netAssets(for snapshot: AssetSnapshot) -> Double {
        totalAssets(for: snapshot) - totalLiabilities(for: snapshot)
    }

    static func breakdown(for snapshot: AssetSnapshot) -> [AssetGroup: Double] {
        Dictionary(grouping: snapshot.entries) { entry in
            entry.item?.category?.group ?? .financial
        }
        .mapValues { entries in
            entries.reduce(0) { $0 + $1.resolvedAmount }
        }
    }

    static func historyMetrics(for snapshots: [AssetSnapshot]) -> [SnapshotMetrics] {
        snapshots
            .sorted { $0.date < $1.date }
            .map(metrics(for:))
    }

    static func change(from previous: SnapshotMetrics?, to current: SnapshotMetrics) -> ChangeMetrics? {
        guard let previous else { return nil }
        let absoluteChange = current.netAssets - previous.netAssets
        let percentageChange: Double?
        if previous.netAssets == 0 {
            percentageChange = nil
        } else {
            percentageChange = absoluteChange / previous.netAssets
        }
        return ChangeMetrics(absoluteChange: absoluteChange, percentageChange: percentageChange)
    }

    static func maxDrawdown(in metrics: [SnapshotMetrics]) -> DrawdownMetrics? {
        guard let first = metrics.first else { return nil }

        var peak = first
        var worst: DrawdownMetrics?

        for point in metrics {
            if point.netAssets > peak.netAssets {
                peak = point
            }

            guard peak.netAssets > 0 else { continue }
            let drawdownRatio = (peak.netAssets - point.netAssets) / peak.netAssets

            if let existingWorst = worst {
                if drawdownRatio > existingWorst.drawdownRatio {
                    worst = DrawdownMetrics(
                        peakValue: peak.netAssets,
                        troughValue: point.netAssets,
                        drawdownRatio: drawdownRatio,
                        peakDate: peak.date,
                        troughDate: point.date
                    )
                }
            } else {
                worst = DrawdownMetrics(
                    peakValue: peak.netAssets,
                    troughValue: point.netAssets,
                    drawdownRatio: drawdownRatio,
                    peakDate: peak.date,
                    troughDate: point.date
                )
            }
        }

        return worst
    }

    static func highestNetWorth(in metrics: [SnapshotMetrics]) -> SnapshotMetrics? {
        metrics.max { $0.netAssets < $1.netAssets }
    }

    static func lowestNetWorth(in metrics: [SnapshotMetrics]) -> SnapshotMetrics? {
        metrics.min { $0.netAssets < $1.netAssets }
    }
}
