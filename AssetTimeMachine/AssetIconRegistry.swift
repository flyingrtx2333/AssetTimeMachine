import SwiftUI

struct AssetIconDefinition: Identifiable, Hashable {
    let key: String
    let label: String
    let symbolName: String
    let imageAssetName: String?

    var id: String { key }
}

enum AssetIconRegistry {
    static let definitions: [AssetIconDefinition] = [
        AssetIconDefinition(key: "icon_wechat", label: "微信", symbolName: "message.circle.fill", imageAssetName: "icon_wechat"),
        AssetIconDefinition(key: "icon_alipay", label: "支付宝", symbolName: "yensign.circle.fill", imageAssetName: "icon_alipay"),
        AssetIconDefinition(key: "icon_bank_card", label: "银行卡", symbolName: "creditcard.fill", imageAssetName: "icon_bank_card"),
        AssetIconDefinition(key: "icon_cash", label: "现金", symbolName: "banknote.fill", imageAssetName: "icon_cash"),
        AssetIconDefinition(key: "icon_btc", label: "BTC", symbolName: "bitcoinsign.circle.fill", imageAssetName: nil),
        AssetIconDefinition(key: "icon_gold", label: "黄金", symbolName: "seal.fill", imageAssetName: nil),
        AssetIconDefinition(key: "icon_mortgage", label: "房贷", symbolName: "house.fill", imageAssetName: nil),
        AssetIconDefinition(key: "icon_car_loan", label: "车贷", symbolName: "car.fill", imageAssetName: nil),
        AssetIconDefinition(key: "icon_credit_card", label: "信用卡", symbolName: "creditcard.and.123", imageAssetName: nil),
        AssetIconDefinition(key: "icon_huabei", label: "花呗", symbolName: "sparkles", imageAssetName: nil)
    ]

    private static let definitionsByKey = Dictionary(uniqueKeysWithValues: definitions.map { ($0.key, $0) })

    static func definition(for key: String) -> AssetIconDefinition? {
        definitionsByKey[key]
    }

    static func symbolName(for key: String, categoryGroup: AssetGroup?) -> String {
        if let definition = definition(for: key) {
            return definition.symbolName
        }
        return fallbackSymbolName(for: categoryGroup)
    }

    static func fallbackSymbolName(for categoryGroup: AssetGroup?) -> String {
        switch categoryGroup {
        case .financial: return "wallet.pass.fill"
        case .physical: return "shippingbox.fill"
        case .liability: return "minus.circle.fill"
        case nil: return "circle.fill"
        }
    }
}
