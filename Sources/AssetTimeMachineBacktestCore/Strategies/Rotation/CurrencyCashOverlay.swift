import Foundation

nonisolated enum CurrencyCashOverlay {
    static func globalRiskOffForCurrency(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        config: RotationParameters.AdvancedRotationConfig
    ) -> Bool {
        let symbols = config.globalRepairStack?.contagion?.globalCheckSymbols
            ?? ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "hsi"]
        let breadth = ContagionOverlay.contagionGlobalBreadth(
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            symbols: symbols
        )
        return breadth.checked >= 5 && breadth.healthy <= 2
    }

    static func usdCashOK(
        selector: RotationParameters.AdvancedRotationCurrencyCashSelector,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        config: RotationParameters.AdvancedRotationConfig,
        state: RotationState.AdvancedRotationOverlayState
    ) -> Bool {
        guard signalIndex >= 0,
              let prices = pricesBySymbol[selector.symbol],
              prices.indices.contains(signalIndex),
              let momentum = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: selector.lookbackSessions),
              let movingAverage = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: selector.movingAveragePeriod) else { return false }
        let trendOK = momentum > 0 && prices[signalIndex] >= movingAverage
        let hurdle = 0.0035 * Double(selector.lookbackSessions) / 252 * selector.cnyCashHurdleScale
        let hurdleOK = momentum > hurdle
        let contagionActive = state.contagionUntilIndex >= signalIndex
        let riskOff = globalRiskOffForCurrency(
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            config: config
        )
        switch selector.mode {
        case "idle_trend":
            return trendOK
        case "idle_hurdle":
            return trendOK && hurdleOK
        case "riskoff_trend":
            return trendOK && riskOff
        case "contagion_trend":
            return trendOK && contagionActive
        case "riskoff_or_contagion":
            return trendOK && (riskOff || contagionActive)
        default:
            return false
        }
    }

    static func applyCurrencyCashSelector(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: RotationParameters.AdvancedRotationConfig,
        state: RotationState.AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard let selector = config.currencyCashSelector else {
            return WeightMath.normalizedWeightMap(rawWeights)
        }
        var output = rawWeights
        let leftover = max(0, 1 - WeightMath.overlayTotalWeight(output))
        guard leftover > 0.0001,
              usdCashOK(
                selector: selector,
                pricesBySymbol: pricesBySymbol,
                signalIndex: signalIndex,
                config: config,
                state: state
              ) else { return WeightMath.normalizedWeightMap(output) }
        output[selector.symbol, default: 0] += min(leftover, max(selector.cap, 0))
        return WeightMath.normalizedWeightMap(output)
    }
}
