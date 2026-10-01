import Foundation

/// Versioned values used when research supplies no override.
public enum BacktestResearchParameterDefaults {
    public static let frozenV1 = BacktestResearchParameters(
        riskBudgetLowScale: 1.0,
        riskBudgetMultiplier: 1.0,
        riskBudgetDefensiveShare: 0.50,
        riskBudgetVolatilityScaleFloor: 0.50,
        riskBudgetReturnLookbackSessions: 420,
        riskBudgetRebalanceBand: 0.08,
        equityCurveOffensiveShare: 1.0,
        equityCurveDefensiveShare: 0.70,
        equityCurveLowScale: 0.70,
        equityCurveEnterDrawdown: 0.025,
        equityCurveExitReturn: 0.02,
        lowNoiseTradeBand: 0.244,
        lowNoiseTradeToBandBoundary: false,
        lowNoiseNearPeakExecutionFraction: 0.80,
        lowNoiseBroadUnwindTurnoverThreshold: 0.40,
        lowNoiseVolatilityTarget: 0.09,
        lowNoiseVolatilityScaleCap: 1.15,
        lowNoiseActiveReturnScale: 1.22,
        lowNoiseChinaActiveReturnScale: 1.30,
        lowNoiseConfirmedUSActiveReturnScale: 1.24,
        lowNoiseDisableNearPeakBuffer: false,
        lowNoiseDisableExitSentinel: false,
        lowNoiseDisableDynamicTurnoverSuppression: false,
        lowNoiseUseSqrtVolRiskBudget: false,
        lowNoiseUseGeometricHeadroomRiskBudget: false,
        nfciDualCoreHighCoreBand: 0.244
    )
}
