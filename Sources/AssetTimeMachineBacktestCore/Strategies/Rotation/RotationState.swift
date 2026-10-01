import Foundation

nonisolated enum RotationState {
    struct AdvancedRotationTargetWeight {
        let symbol: String
        let weight: Double
        let momentum: Double
        let annualizedVolatility: Double?
    }

    struct AdvancedRotationSimulatedTrace {
        let values: [Double]
        let weightsByIndex: [[String: Double]]
    }

    struct AdvancedRotationOverlayState {
        var repairOverlay: [String: Double] = [:]
        var globalOverlay: [String: Double] = [:]
        var phaseLockedStartIndexBySymbol: [String: Int] = [:]
        var contagionUntilIndex: Int = -1
        var goldPanicArmed: Bool = false
        var goldPanicUntilIndex: Int = -1
        var ohlcRiskUntilIndex: Int = -1
        var equityCurveStateGateDefensive: Bool = false
        var assetRiskDefensiveUntilIndex: Int = -1
        var assetRiskRecoveryUntilIndex: Int = -1
    }
}
