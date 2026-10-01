import Foundation

public struct GoldNasdaqBarbellParameters: Codable, Equatable, Sendable {
    public let warmupSessions: Int
    public let rebalanceSessions: Int
    public let rebalanceBand: Double
    public let movingAverageSessions: Int
    public let strongMomentumSessions: Int
    public let weakMomentumSessions: Int
    public let goldStrongScale: Double
    public let goldWeakScale: Double
    public let goldNeutralScale: Double
    public let nasdaqStrongScale: Double
    public let nasdaqWeakScale: Double
    public let nasdaqNeutralScale: Double
    public let goldWeight: Double
    public let nasdaqWeight: Double
    public static let frozenV1 = GoldNasdaqBarbellParameters(warmupSessions: 300, rebalanceSessions: 63, rebalanceBand: 0.10, movingAverageSessions: 200, strongMomentumSessions: 126, weakMomentumSessions: 252, goldStrongScale: 1.0, goldWeakScale: 0.15, goldNeutralScale: 0.65, nasdaqStrongScale: 1.0, nasdaqWeakScale: 0.10, nasdaqNeutralScale: 0.60, goldWeight: 0.55, nasdaqWeight: 0.45)
}
