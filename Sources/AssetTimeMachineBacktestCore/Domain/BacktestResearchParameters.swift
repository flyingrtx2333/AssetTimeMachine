import Foundation

/// Explicit research input. Absence retains the frozen rule value; every run owns its copy.
public struct BacktestResearchParameters: Codable, Equatable, Sendable {
    public let assetRiskLowScale: Double?
    public let assetRiskMultiplier: Double?
    public let sharpeLowScale: Double?
    public let sharpeMultiplier: Double?
    public let riskBudgetLowScale: Double?
    public let riskBudgetMultiplier: Double?
    public let riskBudgetDefensiveShare: Double?
    public let riskBudgetVolatilityScaleFloor: Double?
    public let riskBudgetReturnLookbackSessions: Int?
    public let riskBudgetRebalanceBand: Double?
    public let ohlcRiskOverlayVariant: String?
    public let equityCurveOffensiveShare: Double?
    public let equityCurveDefensiveShare: Double?
    public let equityCurveLowScale: Double?
    public let equityCurveEnterDrawdown: Double?
    public let equityCurveExitReturn: Double?
    public let lowNoiseTradeBand: Double?
    public let lowNoiseTradeToBandBoundary: Bool?
    public let lowNoiseNearPeakExecutionFraction: Double?
    public let lowNoiseBroadUnwindTurnoverThreshold: Double?
    public let lowNoiseVolatilityTarget: Double?
    public let lowNoiseVolatilityScaleCap: Double?
    public let lowNoiseActiveReturnScale: Double?
    public let lowNoiseChinaActiveReturnScale: Double?
    public let lowNoiseConfirmedUSActiveReturnScale: Double?
    public let lowNoiseDisableNearPeakBuffer: Bool?
    public let lowNoiseDisableExitSentinel: Bool?
    public let lowNoiseDisableDynamicTurnoverSuppression: Bool?
    public let lowNoiseUseSqrtVolRiskBudget: Bool?
    public let lowNoiseUseGeometricHeadroomRiskBudget: Bool?
    public let nfciDualCoreHighCoreBand: Double?
    public init(
        assetRiskLowScale: Double? = nil,
        assetRiskMultiplier: Double? = nil,
        sharpeLowScale: Double? = nil,
        sharpeMultiplier: Double? = nil,
        riskBudgetLowScale: Double? = nil,
        riskBudgetMultiplier: Double? = nil,
        riskBudgetDefensiveShare: Double? = nil,
        riskBudgetVolatilityScaleFloor: Double? = nil,
        riskBudgetReturnLookbackSessions: Int? = nil,
        riskBudgetRebalanceBand: Double? = nil,
        ohlcRiskOverlayVariant: String? = nil,
        equityCurveOffensiveShare: Double? = nil,
        equityCurveDefensiveShare: Double? = nil,
        equityCurveLowScale: Double? = nil,
        equityCurveEnterDrawdown: Double? = nil,
        equityCurveExitReturn: Double? = nil,
        lowNoiseTradeBand: Double? = nil,
        lowNoiseTradeToBandBoundary: Bool? = nil,
        lowNoiseNearPeakExecutionFraction: Double? = nil,
        lowNoiseBroadUnwindTurnoverThreshold: Double? = nil,
        lowNoiseVolatilityTarget: Double? = nil,
        lowNoiseVolatilityScaleCap: Double? = nil,
        lowNoiseActiveReturnScale: Double? = nil,
        lowNoiseChinaActiveReturnScale: Double? = nil,
        lowNoiseConfirmedUSActiveReturnScale: Double? = nil,
        lowNoiseDisableNearPeakBuffer: Bool? = nil,
        lowNoiseDisableExitSentinel: Bool? = nil,
        lowNoiseDisableDynamicTurnoverSuppression: Bool? = nil,
        lowNoiseUseSqrtVolRiskBudget: Bool? = nil,
        lowNoiseUseGeometricHeadroomRiskBudget: Bool? = nil,
        nfciDualCoreHighCoreBand: Double? = nil
    ) {
        self.assetRiskLowScale = assetRiskLowScale
        self.assetRiskMultiplier = assetRiskMultiplier
        self.sharpeLowScale = sharpeLowScale
        self.sharpeMultiplier = sharpeMultiplier
        self.riskBudgetLowScale = riskBudgetLowScale
        self.riskBudgetMultiplier = riskBudgetMultiplier
        self.riskBudgetDefensiveShare = riskBudgetDefensiveShare
        self.riskBudgetVolatilityScaleFloor = riskBudgetVolatilityScaleFloor
        self.riskBudgetReturnLookbackSessions = riskBudgetReturnLookbackSessions
        self.riskBudgetRebalanceBand = riskBudgetRebalanceBand
        self.ohlcRiskOverlayVariant = ohlcRiskOverlayVariant
        self.equityCurveOffensiveShare = equityCurveOffensiveShare
        self.equityCurveDefensiveShare = equityCurveDefensiveShare
        self.equityCurveLowScale = equityCurveLowScale
        self.equityCurveEnterDrawdown = equityCurveEnterDrawdown
        self.equityCurveExitReturn = equityCurveExitReturn
        self.lowNoiseTradeBand = lowNoiseTradeBand
        self.lowNoiseTradeToBandBoundary = lowNoiseTradeToBandBoundary
        self.lowNoiseNearPeakExecutionFraction = lowNoiseNearPeakExecutionFraction
        self.lowNoiseBroadUnwindTurnoverThreshold = lowNoiseBroadUnwindTurnoverThreshold
        self.lowNoiseVolatilityTarget = lowNoiseVolatilityTarget
        self.lowNoiseVolatilityScaleCap = lowNoiseVolatilityScaleCap
        self.lowNoiseActiveReturnScale = lowNoiseActiveReturnScale
        self.lowNoiseChinaActiveReturnScale = lowNoiseChinaActiveReturnScale
        self.lowNoiseConfirmedUSActiveReturnScale = lowNoiseConfirmedUSActiveReturnScale
        self.lowNoiseDisableNearPeakBuffer = lowNoiseDisableNearPeakBuffer
        self.lowNoiseDisableExitSentinel = lowNoiseDisableExitSentinel
        self.lowNoiseDisableDynamicTurnoverSuppression = lowNoiseDisableDynamicTurnoverSuppression
        self.lowNoiseUseSqrtVolRiskBudget = lowNoiseUseSqrtVolRiskBudget
        self.lowNoiseUseGeometricHeadroomRiskBudget = lowNoiseUseGeometricHeadroomRiskBudget
        self.nfciDualCoreHighCoreBand = nfciDualCoreHighCoreBand
    }
    public static let frozen = BacktestResearchParameters()
    public var hasOverrides: Bool { self != .frozen }

    public func validate() throws {
        if let variant = ohlcRiskOverlayVariant, !["balanced", "risk_first"].contains(variant) {
            throw BacktestConfigurationError.invalidParameter("ohlcRiskOverlayVariant")
        }
        if let value = assetRiskLowScale, !value.isFinite { throw BacktestConfigurationError.invalidParameter("assetRiskLowScale") }
        if let value = assetRiskMultiplier, !value.isFinite { throw BacktestConfigurationError.invalidParameter("assetRiskMultiplier") }
        if let value = sharpeLowScale, !value.isFinite { throw BacktestConfigurationError.invalidParameter("sharpeLowScale") }
        if let value = sharpeMultiplier, !value.isFinite { throw BacktestConfigurationError.invalidParameter("sharpeMultiplier") }
        if let value = riskBudgetLowScale, !value.isFinite { throw BacktestConfigurationError.invalidParameter("riskBudgetLowScale") }
        if let value = riskBudgetMultiplier, !value.isFinite { throw BacktestConfigurationError.invalidParameter("riskBudgetMultiplier") }
        if let value = riskBudgetDefensiveShare, !value.isFinite { throw BacktestConfigurationError.invalidParameter("riskBudgetDefensiveShare") }
        if let value = riskBudgetVolatilityScaleFloor, !value.isFinite { throw BacktestConfigurationError.invalidParameter("riskBudgetVolatilityScaleFloor") }
        if let value = riskBudgetReturnLookbackSessions, !(1...100_000).contains(value) { throw BacktestConfigurationError.invalidParameter("riskBudgetReturnLookbackSessions") }
        if let value = riskBudgetRebalanceBand, !value.isFinite { throw BacktestConfigurationError.invalidParameter("riskBudgetRebalanceBand") }
        if let value = equityCurveOffensiveShare, !value.isFinite { throw BacktestConfigurationError.invalidParameter("equityCurveOffensiveShare") }
        if let value = equityCurveDefensiveShare, !value.isFinite { throw BacktestConfigurationError.invalidParameter("equityCurveDefensiveShare") }
        if let value = equityCurveLowScale, !value.isFinite { throw BacktestConfigurationError.invalidParameter("equityCurveLowScale") }
        if let value = equityCurveEnterDrawdown, !value.isFinite { throw BacktestConfigurationError.invalidParameter("equityCurveEnterDrawdown") }
        if let value = equityCurveExitReturn, !value.isFinite { throw BacktestConfigurationError.invalidParameter("equityCurveExitReturn") }
        if let value = lowNoiseTradeBand, !value.isFinite { throw BacktestConfigurationError.invalidParameter("lowNoiseTradeBand") }
        if let value = lowNoiseNearPeakExecutionFraction, !value.isFinite { throw BacktestConfigurationError.invalidParameter("lowNoiseNearPeakExecutionFraction") }
        if let value = lowNoiseBroadUnwindTurnoverThreshold, !value.isFinite { throw BacktestConfigurationError.invalidParameter("lowNoiseBroadUnwindTurnoverThreshold") }
        if let value = lowNoiseVolatilityTarget, !value.isFinite { throw BacktestConfigurationError.invalidParameter("lowNoiseVolatilityTarget") }
        if let value = lowNoiseVolatilityScaleCap, !value.isFinite { throw BacktestConfigurationError.invalidParameter("lowNoiseVolatilityScaleCap") }
        if let value = lowNoiseActiveReturnScale, !value.isFinite { throw BacktestConfigurationError.invalidParameter("lowNoiseActiveReturnScale") }
        if let value = lowNoiseChinaActiveReturnScale, !value.isFinite { throw BacktestConfigurationError.invalidParameter("lowNoiseChinaActiveReturnScale") }
        if let value = lowNoiseConfirmedUSActiveReturnScale, !value.isFinite { throw BacktestConfigurationError.invalidParameter("lowNoiseConfirmedUSActiveReturnScale") }
        if let value = nfciDualCoreHighCoreBand, !value.isFinite { throw BacktestConfigurationError.invalidParameter("nfciDualCoreHighCoreBand") }
    }
}

public enum BacktestConfigurationError: Error, Equatable {
    case invalidParameter(String)
    case unknownStrategy(String)
    case unknownVersion(String)
    case researchOverrideOnProduct
    case missingData(String)
    case computationFailed
}

/// Scoped immutable input also reaches nested shadow strategies; it cannot contaminate another task.
public enum BacktestRunScope {
    @TaskLocal public static var parameters = BacktestResearchParameters.frozen
}
