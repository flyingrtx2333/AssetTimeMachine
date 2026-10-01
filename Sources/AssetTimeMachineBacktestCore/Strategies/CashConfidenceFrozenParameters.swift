import Foundation

public struct CashConfidenceFrozenParameters: Codable, Equatable, Sendable {
    public let frozenDecisionFeeRatePercent: Double
    public let frozenDecisionSlippageRatePercent: Double
    public let grossCap: Double
    public let lowConfidenceChinaGrossMaximum: Double
    public let matureNasdaqGrossMinimum: Double
    public let matureNasdaqMinimumWeight: Double
    public let matureNasdaqMAPeriod: Int
    public let matureNasdaqScale: Double
    public let matureOtherAssetScale: Double
    public let residualNasdaqGrossMaximum: Double
    public let residualNasdaqMinimumWeight: Double
    public let leadershipEvaluationSessions: Int
    public let leadershipPriorEvidence: Double
    public let minimumLeadershipMigration: Double
    public let nearPeakDeRiskDrawdownThreshold: Double
    public let nearPeakDeRiskMaximumRetention: Double
    public static let frozenV1 = CashConfidenceFrozenParameters(frozenDecisionFeeRatePercent: 1.00, frozenDecisionSlippageRatePercent: 0.05, grossCap: 1.0, lowConfidenceChinaGrossMaximum: 0.50, matureNasdaqGrossMinimum: 0.70, matureNasdaqMinimumWeight: 0.20, matureNasdaqMAPeriod: 40, matureNasdaqScale: 0.88, matureOtherAssetScale: 0.80, residualNasdaqGrossMaximum: 0.20, residualNasdaqMinimumWeight: 0.01, leadershipEvaluationSessions: 10, leadershipPriorEvidence: 2.0, minimumLeadershipMigration: 0.50, nearPeakDeRiskDrawdownThreshold: 0.04, nearPeakDeRiskMaximumRetention: 0.25)
}
