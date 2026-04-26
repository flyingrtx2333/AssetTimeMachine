import Foundation
import SwiftData

enum AssetGroup: String, Codable, CaseIterable, Identifiable {
    case financial
    case physical
    case liability

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .financial:
            return "金融资产"
        case .physical:
            return "实物资产"
        case .liability:
            return "负债"
        }
    }
}

enum ValuationMethod: String, Codable, CaseIterable, Identifiable {
    case directAmount
    case quantityAndUnitPrice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .directAmount:
            return "直接金额"
        case .quantityAndUnitPrice:
            return "数量 × 单价"
        }
    }
}

@Model
final class AssetCategory {
    var id: UUID
    var name: String
    var groupRawValue: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \AssetItem.category) var items: [AssetItem]

    init(
        id: UUID = UUID(),
        name: String,
        group: AssetGroup,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.groupRawValue = group.rawValue
        self.createdAt = createdAt
        self.items = []
    }

    var group: AssetGroup {
        get { AssetGroup(rawValue: groupRawValue) ?? .financial }
        set { groupRawValue = newValue.rawValue }
    }
}

@Model
final class AssetItem {
    var id: UUID
    var name: String
    var note: String
    var valuationMethodRawValue: String
    var sortOrder: Int
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    var category: AssetCategory?
    @Relationship(deleteRule: .cascade, inverse: \AssetEntry.item) var entries: [AssetEntry]

    init(
        id: UUID = UUID(),
        name: String,
        note: String = "",
        valuationMethod: ValuationMethod = .directAmount,
        sortOrder: Int = 0,
        isActive: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        category: AssetCategory? = nil
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.valuationMethodRawValue = valuationMethod.rawValue
        self.sortOrder = sortOrder
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.category = category
        self.entries = []
    }

    var valuationMethod: ValuationMethod {
        get { ValuationMethod(rawValue: valuationMethodRawValue) ?? .directAmount }
        set { valuationMethodRawValue = newValue.rawValue }
    }
}

@Model
final class AssetSnapshot {
    var id: UUID
    var date: Date
    var note: String
    var createdAt: Date
    var updatedAt: Date
    var goldAnchorPriceCNY: Double?
    var goldAnchorPriceDate: Date?
    var btcAnchorPriceUSD: Double?
    var btcAnchorPriceDate: Date?
    var nasdaqAnchorPriceUSD: Double?
    var nasdaqAnchorPriceDate: Date?
    var usdPerCNY: Double?
    var usdPerCNYDate: Date?
    var marketAnchorsUpdatedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \AssetEntry.snapshot) var entries: [AssetEntry]

    init(
        id: UUID = UUID(),
        date: Date,
        note: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        goldAnchorPriceCNY: Double? = nil,
        goldAnchorPriceDate: Date? = nil,
        btcAnchorPriceUSD: Double? = nil,
        btcAnchorPriceDate: Date? = nil,
        nasdaqAnchorPriceUSD: Double? = nil,
        nasdaqAnchorPriceDate: Date? = nil,
        usdPerCNY: Double? = nil,
        usdPerCNYDate: Date? = nil,
        marketAnchorsUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.goldAnchorPriceCNY = goldAnchorPriceCNY
        self.goldAnchorPriceDate = goldAnchorPriceDate
        self.btcAnchorPriceUSD = btcAnchorPriceUSD
        self.btcAnchorPriceDate = btcAnchorPriceDate
        self.nasdaqAnchorPriceUSD = nasdaqAnchorPriceUSD
        self.nasdaqAnchorPriceDate = nasdaqAnchorPriceDate
        self.usdPerCNY = usdPerCNY
        self.usdPerCNYDate = usdPerCNYDate
        self.marketAnchorsUpdatedAt = marketAnchorsUpdatedAt
        self.entries = []
    }

    var btcAnchorPriceCNY: Double? {
        guard let btcAnchorPriceUSD, let usdPerCNY, usdPerCNY > 0 else { return nil }
        return btcAnchorPriceUSD / usdPerCNY
    }

    var nasdaqAnchorPriceCNY: Double? {
        guard let nasdaqAnchorPriceUSD, let usdPerCNY, usdPerCNY > 0 else { return nil }
        return nasdaqAnchorPriceUSD / usdPerCNY
    }
}

@Model
final class AssetEntry {
    var id: UUID
    var amount: Double?
    var quantity: Double?
    var unitPrice: Double?
    var note: String
    var createdAt: Date
    var updatedAt: Date

    var snapshot: AssetSnapshot?
    var item: AssetItem?

    init(
        id: UUID = UUID(),
        amount: Double? = nil,
        quantity: Double? = nil,
        unitPrice: Double? = nil,
        note: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        snapshot: AssetSnapshot? = nil,
        item: AssetItem? = nil
    ) {
        self.id = id
        self.amount = amount
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.snapshot = snapshot
        self.item = item
    }

    var resolvedAmount: Double {
        if let amount {
            return amount
        }
        if let quantity, let unitPrice {
            return quantity * unitPrice
        }
        return 0
    }
}
