import Foundation

/// Cash per share on an unadjusted price series. The caller supplies the
/// distribution currency's base-currency conversion path explicitly.
nonisolated public struct BacktestCashDistribution: Codable, Sendable {
    public let id: String
    public let symbol: String
    public let exDate: Date
    public let paymentDate: Date
    public let currencyCode: String
    public let amountPerUnit: Double
    public let withholdingRate: Double

    public init(id: String, symbol: String, exDate: Date, paymentDate: Date,
                currencyCode: String, amountPerUnit: Double, withholdingRate: Double = 0) {
        self.id = id
        self.symbol = symbol
        self.exDate = exDate
        self.paymentDate = paymentDate
        self.currencyCode = currencyCode
        self.amountPerUnit = amountPerUnit
        self.withholdingRate = withholdingRate
    }
}

/// Retained even after the shares have been sold. A payment after the run's
/// horizon remains a receivable, rather than becoming spendable cash early.
nonisolated public struct BacktestDistributionEntitlement: Codable, Sendable {
    public let distribution: BacktestCashDistribution
    public let eligibleUnits: Double
    public let netAmountInDistributionCurrency: Double
    public internal(set) var paidOn: Date?
    public internal(set) var paidAmountInBaseCurrency: Double?
}
