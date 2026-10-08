import Foundation

/// Shares received for each previously held share at the effective session's
/// open. Input prices must use the share denomination actually traded then.
nonisolated public struct BacktestShareSplit: Codable, Sendable {
    public let id: String
    public let symbol: String
    public let effectiveDate: Date
    public let newUnitsPerOldUnit: Double

    public init(id: String, symbol: String, effectiveDate: Date, newUnitsPerOldUnit: Double) {
        self.id = id
        self.symbol = symbol
        self.effectiveDate = effectiveDate
        self.newUnitsPerOldUnit = newUnitsPerOldUnit
    }
}

nonisolated public struct BacktestSplitAdjustment: Codable, Sendable {
    public let split: BacktestShareSplit
    public let previousUnits: Double
    public let resultingUnits: Double
}
