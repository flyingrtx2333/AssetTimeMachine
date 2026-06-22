import Foundation
import SwiftData
import UserNotifications

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

    private static let defaultFinancialItems = ["微信", "支付宝", "银行卡", "现金"]
    private static let defaultPhysicalItems = ["房产", "车辆", "车位"]
    private static let defaultLiabilityItems = ["花呗", "白条", "房贷"]

    @MainActor
    static func seedDefaultCategoriesIfNeeded(in context: ModelContext) throws {
        let descriptor = FetchDescriptor<AssetCategory>()
        let existingCategories = try context.fetch(descriptor)

        guard existingCategories.isEmpty else { return }

        for category in defaultCategories {
            let model = AssetCategory(
                name: category.name,
                group: category.group,
                createdAt: .now
            )
            context.insert(model)

            for (index, config) in defaultItems(for: category.group).enumerated() {
                let item = AssetItem(
                    name: config.name,
                    note: config.note,
                    iconName: AssetItemService.suggestedIconName(for: config.name, autoPricedAssetKind: nil),
                    valuationMethod: .directAmount,
                    sortOrder: index,
                    category: model
                )
                context.insert(item)
            }
        }

        try context.save()
    }

    @MainActor
    static func ensureDefaultFinancialItems(in context: ModelContext) throws {
        let categories = try context.fetch(FetchDescriptor<AssetCategory>())
        var didChange = false

        for category in categories {
            let existingNames = Set(category.items.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
            var nextSortOrder = (category.items.map(\AssetItem.sortOrder).max() ?? -1) + 1

            for config in defaultItems(for: category.group) where !existingNames.contains(config.name) {
                let item = AssetItem(
                    name: config.name,
                    note: config.upgradeNote,
                    iconName: AssetItemService.suggestedIconName(for: config.name, autoPricedAssetKind: nil),
                    valuationMethod: .directAmount,
                    sortOrder: nextSortOrder,
                    category: category
                )
                context.insert(item)
                nextSortOrder += 1
                didChange = true
            }
        }

        if didChange {
            try context.save()
        }
    }

    private static func defaultItems(for group: AssetGroup) -> [DefaultItemConfig] {
        switch group {
        case .financial:
            return defaultFinancialItems.map {
                DefaultItemConfig(name: $0, note: "默认资金项目，可编辑或删除", upgradeNote: "系统补齐的默认资金项目，可编辑或删除")
            }
        case .physical:
            return defaultPhysicalItems.map {
                DefaultItemConfig(name: $0, note: "示例项目，可编辑或删除", upgradeNote: "系统补齐的默认实物项目，可编辑或删除")
            }
        case .liability:
            return defaultLiabilityItems.map {
                DefaultItemConfig(name: $0, note: "默认负债项目，可编辑或删除", upgradeNote: "系统补齐的默认负债项目，可编辑或删除")
            }
        }
    }
}

private struct DefaultItemConfig {
    let name: String
    let note: String
    let upgradeNote: String
}

enum AssetItemService {
    @MainActor
    static func createItem(
        name: String,
        category: AssetCategory,
        valuationMethod: ValuationMethod = .directAmount,
        autoPricedAssetKind: AutoPricedAssetKind? = nil,
        note: String = "",
        iconName: String? = nil,
        in context: ModelContext
    ) throws -> AssetItem {
        let nextSortOrder = (category.items.map(\AssetItem.sortOrder).max() ?? -1) + 1
        let item = AssetItem(
            name: name,
            note: note,
            iconName: iconName ?? suggestedIconName(for: name, autoPricedAssetKind: autoPricedAssetKind),
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
        iconName: String? = nil,
        valuationMethod: ValuationMethod? = nil,
        autoPricedAssetKind: AutoPricedAssetKind?? = nil,
        isActive: Bool? = nil,
        category: AssetCategory? = nil,
        in context: ModelContext
    ) throws {
        if let name { item.name = name }
        if let note { item.note = note }
        if let iconName { item.iconName = iconName }
        if let valuationMethod { item.valuationMethod = valuationMethod }
        if let autoPricedAssetKind { item.autoPricedAssetKind = autoPricedAssetKind }
        if let isActive { item.isActive = isActive }
        if let category { item.category = category }
        item.updatedAt = .now
        try context.save()
    }

    @MainActor
    static func migrateLegacyAutoPricedItemsIfNeeded(in context: ModelContext) throws {
        let items = try context.fetch(FetchDescriptor<AssetItem>())
        var didChange = false

        for item in items {
            guard item.autoPricedAssetKind == nil,
                  let inferredKind = inferLegacyAutoPricedAssetKind(for: item.name) else {
                continue
            }
            item.autoPricedAssetKind = inferredKind
            item.updatedAt = .now
            didChange = true
        }

        if didChange {
            try context.save()
        }
    }

    static func suggestedIconName(for name: String, autoPricedAssetKind: AutoPricedAssetKind?) -> String {
        if let autoPricedAssetKind {
            switch autoPricedAssetKind {
            case .gold: return "icon_gold"
            case .btc: return "icon_btc"
            default: break
            }
        }

        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("微信") { return "icon_wechat" }
        if normalized.contains("支付宝") { return "icon_alipay" }
        if normalized.contains("现金") { return "icon_cash" }
        if normalized.contains("银行卡") || normalized.contains("储蓄卡") { return "icon_bank_card" }
        if normalized.contains("房产") || normalized.contains("房子") || normalized.contains("住宅") || normalized.contains("公寓") {
            return "icon_house"
        }
        if normalized.contains("房贷") || normalized.contains("贷款") { return "icon_mortgage" }
        if normalized.contains("车位") || normalized.contains("停车位") {
            return "icon_parking"
        }
        if normalized.contains("车辆") || normalized.contains("汽车") || normalized.contains("车子") {
            return "icon_car"
        }
        if normalized.contains("车贷") { return "icon_car_loan" }
        if normalized.contains("信用卡") { return "icon_credit_card" }
        if normalized.contains("花呗") { return "icon_huabei" }
        if normalized.contains("白条") { return "icon_credit_card" }
        return ""
    }

    static func resolvedIconKey(for item: AssetItem) -> String {
        let explicitIcon = (item.iconName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitIcon.isEmpty {
            return explicitIcon
        }
        return suggestedIconName(for: item.name, autoPricedAssetKind: item.autoPricedAssetKind)
    }

    static func displaySymbolName(for item: AssetItem) -> String {
        AssetIconRegistry.symbolName(for: resolvedIconKey(for: item), categoryGroup: item.category?.group)
    }

    private static func inferLegacyAutoPricedAssetKind(for name: String) -> AutoPricedAssetKind? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        if trimmedName == "黄金" || trimmedName.caseInsensitiveCompare("gold") == .orderedSame {
            return .gold
        }

        let uppercasedName = trimmedName.uppercased()
        let cryptoMappings: [(AutoPricedAssetKind, [String])] = [
            (.btc, ["BTC", "BITCOIN"]),
            (.eth, ["ETH", "ETHEREUM"]),
            (.bnb, ["BNB"]),
            (.sol, ["SOL", "SOLANA"]),
            (.xrp, ["XRP"]),
            (.doge, ["DOGE", "DOGECOIN"]),
        ]

        for (kind, candidates) in cryptoMappings {
            if candidates.contains(uppercasedName) {
                return kind
            }
        }

        for currencyCode in ["USD", "EUR", "GBP", "JPY", "HKD", "SGD", "AUD", "CAD", "KRW"] {
            if uppercasedName.hasSuffix(" \(currencyCode)") || uppercasedName == currencyCode {
                return AutoPricedAssetKind(rawValue: currencyCode.lowercased())
            }
        }

        return nil
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

enum AssetNotificationService {
    static let notificationIdentifier = "assettimemachine.asset-report"
    static let strategyNotificationIdentifier = "assettimemachine.strategy-rebalance"
    static let intervalOptions: [Double] = [1, 2, 4, 6, 8, 12, 24]
    static let strategyHourOptions: [Int] = [8, 9, 12, 18, 21]

    static func refreshSchedule(isEnabled: Bool, intervalHours: Double, snapshot: AssetSnapshot?) async throws -> Bool {
        let center = UNUserNotificationCenter.current()

        if !isEnabled {
            center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
            return true
        }

        let granted = try await ensureAuthorization(for: center)
        guard granted else {
            center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
            return false
        }

        guard let snapshot else { return true }

        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])

        let content = UNMutableNotificationContent()
        content.title = AppLocalization.string("资产播报")
        content.subtitle = subtitle(for: snapshot)
        content.body = body(for: snapshot)
        content.sound = .default

        let interval = max(3600, intervalHours * 3600)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: true)
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: trigger)
        try await center.add(request)
        return true
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func refreshStrategySchedule(
        isEnabled: Bool,
        hour: Int,
        strategyTitle: String,
        body: String?
    ) async throws -> Bool {
        let center = UNUserNotificationCenter.current()

        if !isEnabled {
            center.removePendingNotificationRequests(withIdentifiers: [strategyNotificationIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [strategyNotificationIdentifier])
            return true
        }

        let granted = try await ensureAuthorization(for: center)
        guard granted else {
            center.removePendingNotificationRequests(withIdentifiers: [strategyNotificationIdentifier])
            return false
        }

        center.removePendingNotificationRequests(withIdentifiers: [strategyNotificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [strategyNotificationIdentifier])

        let content = UNMutableNotificationContent()
        content.title = AppLocalization.string("今日调仓提醒")
        content.subtitle = strategyTitle
        content.body = body ?? AppLocalization.string("打开资产时光机，更新最新策略信号。")
        content.sound = .default
        content.threadIdentifier = strategyNotificationIdentifier

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        components.hour = min(max(hour, 0), 23)
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: strategyNotificationIdentifier, content: content, trigger: trigger)
        try await center.add(request)
        return true
    }

    private static func ensureAuthorization(for center: UNUserNotificationCenter) async throws -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func subtitle(for snapshot: AssetSnapshot) -> String {
        let totalAssets = PortfolioCalculator.totalAssets(for: snapshot)
        let netAssets = PortfolioCalculator.netAssets(for: snapshot)
        return AppLocalization.format("总资产 %@ · 净资产 %@", currencyString(totalAssets), currencyString(netAssets))
    }

    private static func body(for snapshot: AssetSnapshot) -> String {
        let liabilities = PortfolioCalculator.totalLiabilities(for: snapshot)
        let breakdown = PortfolioCalculator.breakdown(for: snapshot)
        let financial = breakdown[.financial] ?? 0
        let physical = breakdown[.physical] ?? 0
        return AppLocalization.format(
            "负债 %@。金融 %@ · 实物 %@",
            currencyString(liabilities),
            currencyString(financial),
            currencyString(physical)
        )
    }

    private static func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "¥0.00"
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
        var totalAssets: Double = 0
        var totalLiabilities: Double = 0

        for entry in snapshot.entries {
            if (entry.item?.category?.group ?? .financial) == .liability {
                totalLiabilities += entry.resolvedAmount
            } else {
                totalAssets += entry.resolvedAmount
            }
        }

        return SnapshotMetrics(
            date: snapshot.date,
            totalAssets: totalAssets,
            totalLiabilities: totalLiabilities,
            netAssets: totalAssets - totalLiabilities
        )
    }

    static func totalAssets(for snapshot: AssetSnapshot) -> Double {
        metrics(for: snapshot).totalAssets
    }

    static func totalLiabilities(for snapshot: AssetSnapshot) -> Double {
        metrics(for: snapshot).totalLiabilities
    }

    static func netAssets(for snapshot: AssetSnapshot) -> Double {
        metrics(for: snapshot).netAssets
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
