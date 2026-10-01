import Foundation

/// Frozen rules shared by the V1, simplified V11 and QUAL research role.
public struct NFCIFrozenParameters: Codable, Equatable, Sendable {
    public let creditLookbackReleases: Int
    public let leverageLookbackReleases: Int
    public let releaseChangeThreshold: Double
    public let usDecreaseThreshold: Double
    public let grossDecreaseWithUS: Double
    public let grossDecreaseThreshold: Double
    public let singleTriggerRetention: Double
    public let bothTriggerRetention: Double
    public let highRiskScale: Double
    public let balancedRiskScale: Double
    public let balancedRebalanceBand: Double
    public let simplifiedHighCoreBand: Double
    public let finalRebalanceBand: Double
    public let highCoreShare: Double
    public let balancedCoreShare: Double
    public let warmupSessions: Int
    public let rebalanceSessions: Int
    public let grossCap: Double
    public let qualSubstitutionStart: String
    public static let frozenV1 = NFCIFrozenParameters(
        creditLookbackReleases: 8,
        leverageLookbackReleases: 4,
        releaseChangeThreshold: -0.03,
        usDecreaseThreshold: 0.05,
        grossDecreaseWithUS: 0.03,
        grossDecreaseThreshold: 0.05,
        singleTriggerRetention: 0.5,
        bothTriggerRetention: 1.0,
        highRiskScale: 1.0,
        balancedRiskScale: 1.30,
        balancedRebalanceBand: 0.20,
        simplifiedHighCoreBand: 0.25,
        finalRebalanceBand: 0.25,
        highCoreShare: 0.5,
        balancedCoreShare: 0.5,
        warmupSessions: 21,
        rebalanceSessions: 1,
        grossCap: 1,
        qualSubstitutionStart: "2013-07-19"
    )
}
