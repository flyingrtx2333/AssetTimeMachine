import Foundation
import SwiftData

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
