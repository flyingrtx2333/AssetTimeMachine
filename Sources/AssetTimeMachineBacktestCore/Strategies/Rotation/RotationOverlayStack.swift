import Foundation

nonisolated enum RotationOverlayStack {
    static func applyAdvancedOverlayStack(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: RotationParameters.AdvancedRotationConfig,
        state: inout RotationState.AdvancedRotationOverlayState,
        refreshRepairOverlay: Bool,
        ohlcFeaturesBySymbol: [String: [RotationParameters.AdvancedRotationOHLCRiskFeature?]]? = nil,
        portfolioValues: [Double]? = nil
    ) -> [String: Double] {
        var weights = EquityRepairOverlays.applyGlobalRepairStack(
            to: rawWeights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            config: config,
            state: &state,
            refreshRepairOverlay: refreshRepairOverlay
        )
        weights = GoldPanicOverlay.applyGoldPanicLock(
            to: weights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            config: config,
            state: &state
        )
        weights = RiskEfficiencyOverlay.applyRiskEfficiencyGovernor(
            to: weights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            config: config
        )
        weights = CanaryRiskOverlay.applyCanaryRiskBrake(
            to: weights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            config: config
        )
        weights = EquityRiskOverlays.applyEquityCurveStateGate(
            to: weights,
            signalIndex: signalIndex,
            portfolioValues: portfolioValues,
            config: config,
            state: &state
        )
        weights = EquityRiskOverlays.applyAssetRiskStateGate(
            to: weights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            portfolioValues: portfolioValues,
            config: config,
            state: &state
        )
        weights = CurrencyCashOverlay.applyCurrencyCashSelector(
            to: weights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            config: config,
            state: state
        )
        weights = OHLCRiskOverlay.applyOHLCRiskOverlay(
            to: weights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            ohlcFeaturesBySymbol: ohlcFeaturesBySymbol,
            config: config,
            state: &state
        )
        return WeightMath.normalizedWeightMap(weights)
    }

    static func applyPostTargetOverlays(
        to rawWeights: [String: Double],
        signalIndex: Int,
        signalDate: Date,
        pricesBySymbol: [String: [Double]],
        volatilityBySymbol: [String: [Double?]],
        portfolioValues: [Double]?,
        config: RotationParameters.AdvancedRotationConfig
    ) -> [String: Double] {
        var weights = EquityRiskOverlays.applyConfirmedEquityBreadthOverlay(
            to: rawWeights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            volatilityBySymbol: volatilityBySymbol,
            config: config
        )
        weights = EquityRiskOverlays.applyConfirmedAccelerationSatelliteOverlay(
            to: weights,
            signalIndex: signalIndex,
            signalDate: signalDate,
            pricesBySymbol: pricesBySymbol,
            config: config
        )
        weights = EquityRiskOverlays.applyProfitLockBudget(
            to: weights,
            signalIndex: signalIndex,
            portfolioValues: portfolioValues,
            config: config
        )
        return WeightMath.normalizedWeightMap(weights)
    }
}
