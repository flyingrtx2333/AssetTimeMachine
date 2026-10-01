import Foundation

public struct BacktestSeriesPoint: Identifiable, Sendable {
    public let id: Int
    public let date: Date
    public let portfolioValue: Double

    public init(date: Date, portfolioValue: Double, sequence: Int = 0) {
        self.id = sequence
        self.date = date
        self.portfolioValue = portfolioValue
    }
}

