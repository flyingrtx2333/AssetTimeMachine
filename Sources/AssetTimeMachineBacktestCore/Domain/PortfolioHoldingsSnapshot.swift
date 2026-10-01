import Foundation

public enum PortfolioHoldingGroup: String, Codable, Sendable { case financial, physical, liability }
public struct PortfolioHolding: Sendable {
    public let name: String
    public let hasRecordedItem: Bool
    public let note: String
    public let group: PortfolioHoldingGroup
    public let amount: Double
    public let isAutoPricedGold: Bool
    public let marketAssetSymbol: String?
    public let quantStrategyProxySymbol: String?
    public init(name: String, hasRecordedItem: Bool = true, note: String = "", group: PortfolioHoldingGroup = .financial,
                amount: Double, isAutoPricedGold: Bool = false,
                marketAssetSymbol: String? = nil, quantStrategyProxySymbol: String? = nil) {
        self.name = name; self.hasRecordedItem = hasRecordedItem; self.note = note; self.group = group; self.amount = amount
        self.isAutoPricedGold = isAutoPricedGold; self.marketAssetSymbol = marketAssetSymbol
        self.quantStrategyProxySymbol = quantStrategyProxySymbol
    }
}
public struct PortfolioHoldingsSnapshot: Sendable {
    public let entries: [PortfolioHolding]
    public init(entries: [PortfolioHolding]) { self.entries = entries }
}
