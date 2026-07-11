import Foundation
import SwiftData

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

    private static func defaultItems(for group: AssetGroup) -> [DefaultItemConfig] {
        switch group {
        case .financial:
            return defaultFinancialItems.map {
                DefaultItemConfig(name: $0, note: "默认资金项目，可编辑或删除")
            }
        case .physical:
            return defaultPhysicalItems.map {
                DefaultItemConfig(name: $0, note: "示例项目，可编辑或删除")
            }
        case .liability:
            return defaultLiabilityItems.map {
                DefaultItemConfig(name: $0, note: "默认负债项目，可编辑或删除")
            }
        }
    }
}

private struct DefaultItemConfig {
    let name: String
    let note: String
}
