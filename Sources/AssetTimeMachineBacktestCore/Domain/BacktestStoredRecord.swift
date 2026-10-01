import Foundation

public struct BacktestStoredRecord: Sendable {
    public var kindRawValue: String
    public var title: String
    public var subtitle: String
    public var configSummary: String
    public var createdAt: Date
    public var startDate: Date?
    public var endDate: Date?
    public var totalReturn: Double
    public var annualizedReturn: Double?
    public var maxDrawdown: Double
    public var annualizedVolatility: Double?
    public var sharpeRatio: Double?
    public var finalValue: Double?
    public var totalInvested: Double?
    public var profitLoss: Double?
    public var tradeCount: Int
    public var pointsJSON: Data
    public var configJSON: Data

    public init(
        kindRawValue: String,
        title: String,
        subtitle: String = "",
        configSummary: String = "",
        createdAt: Date = .now,
        startDate: Date? = nil,
        endDate: Date? = nil,
        totalReturn: Double,
        annualizedReturn: Double? = nil,
        maxDrawdown: Double,
        annualizedVolatility: Double? = nil,
        sharpeRatio: Double? = nil,
        finalValue: Double? = nil,
        totalInvested: Double? = nil,
        profitLoss: Double? = nil,
        tradeCount: Int = 0,
        pointsJSON: Data = Data(),
        configJSON: Data = Data()
    ) {
        self.kindRawValue = kindRawValue
        self.title = title
        self.subtitle = subtitle
        self.configSummary = configSummary
        self.createdAt = createdAt
        self.startDate = startDate
        self.endDate = endDate
        self.totalReturn = totalReturn
        self.annualizedReturn = annualizedReturn
        self.maxDrawdown = maxDrawdown
        self.annualizedVolatility = annualizedVolatility
        self.sharpeRatio = sharpeRatio
        self.finalValue = finalValue
        self.totalInvested = totalInvested
        self.profitLoss = profitLoss
        self.tradeCount = tradeCount
        self.pointsJSON = pointsJSON
        self.configJSON = configJSON
    }
}

