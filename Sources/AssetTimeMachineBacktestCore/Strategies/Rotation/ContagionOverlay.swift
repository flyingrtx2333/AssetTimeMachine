import Foundation

nonisolated enum ContagionOverlay {
    static func contagionGlobalBreadth(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        symbols: [String]
    ) -> (checked: Int, healthy: Int) {
        var checked = 0
        var healthy = 0
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let ma60 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 60),
                  let momentum20 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 20) else { continue }
            checked += 1
            if prices[signalIndex] > ma60 && momentum20 > -0.015 {
                healthy += 1
            }
        }
        return (checked, healthy)
    }

    static func bubbleRolloverSymbol(
        _ symbol: String,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Bool {
        guard let prices = pricesBySymbol[symbol],
              prices.indices.contains(signalIndex),
              prices[signalIndex] > 0,
              let momentum20 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 20),
              let momentum60 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 60),
              let momentum120 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 120),
              let drawdown20 = TechnicalIndicators.rollingDrawdownFromHigh(values: prices, at: signalIndex, period: 20),
              let drawdown60 = TechnicalIndicators.rollingDrawdownFromHigh(values: prices, at: signalIndex, period: 60),
              let ma40 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 40),
              let ma120 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 120) else { return false }
        let hot = momentum120 > 0.30 || momentum60 > 0.18 || prices[signalIndex] > ma120 * 1.18
        let rollover = momentum20 < -0.025 || drawdown20 < -0.055 || drawdown60 < -0.10 || prices[signalIndex] < ma40
        return hot && rollover
    }

    static func weakContagionSymbol(
        _ symbol: String,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Bool {
        guard let prices = pricesBySymbol[symbol],
              prices.indices.contains(signalIndex),
              prices[signalIndex] > 0,
              let ma60 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 60),
              let momentum20 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 20),
              let momentum60 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 60),
              let drawdown60 = TechnicalIndicators.rollingDrawdownFromHigh(values: prices, at: signalIndex, period: 60) else { return false }
        return prices[signalIndex] < ma60 || momentum20 < -0.035 || momentum60 < -0.055 || drawdown60 < -0.105
    }

    static func contagionTriggered(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        control: RotationParameters.AdvancedRotationContagionControl
    ) -> Bool {
        let bubbleCount = control.chinaHkSymbols.filter {
            bubbleRolloverSymbol($0, pricesBySymbol: pricesBySymbol, signalIndex: signalIndex)
        }.count
        let weakCount = control.chinaHkSymbols.filter {
            weakContagionSymbol($0, pricesBySymbol: pricesBySymbol, signalIndex: signalIndex)
        }.count
        let breadth = contagionGlobalBreadth(
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            symbols: control.globalCheckSymbols
        )
        let globalWeak = breadth.checked >= 5 && breadth.healthy <= 2
        switch control.triggerMode {
        case "bubble_only":
            return bubbleCount >= 1
        case "bubble_or_breadth":
            return bubbleCount >= 1 || (weakCount >= 2 && globalWeak)
        case "cluster":
            return bubbleCount >= 1 && (weakCount >= 2 || globalWeak)
        default:
            return false
        }
    }

    static func contagionReleaseOK(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        control: RotationParameters.AdvancedRotationContagionControl
    ) -> Bool {
        guard control.releaseMode != "time_only" else { return false }
        let usGood = ["nasdaq", "sp500"].reduce(0) { partial, symbol in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let ma60 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 60),
                  let momentum20 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 20),
                  let momentum60 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 60),
                  prices[signalIndex] > ma60,
                  momentum20 > 0,
                  momentum60 > -0.01 else { return partial }
            return partial + 1
        }
        if control.releaseMode == "us_repair" {
            return usGood >= 2
        }
        let breadth = contagionGlobalBreadth(
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            symbols: control.globalCheckSymbols
        )
        return usGood >= 2 && breadth.checked >= 5 && breadth.healthy >= 4
    }

    static func applyContagionControl(
        to rawWeights: [String: Double],
        stack: RotationParameters.AdvancedRotationGlobalRepairStack,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        state: inout RotationState.AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard let control = stack.contagion,
              signalIndex >= 0 else { return WeightMath.normalizedWeightMap(rawWeights) }
        if contagionTriggered(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex, control: control) {
            state.contagionUntilIndex = max(state.contagionUntilIndex, signalIndex + control.cooldownSessions)
        }
        var active = state.contagionUntilIndex >= signalIndex
        if active && contagionReleaseOK(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex, control: control) {
            active = false
            state.contagionUntilIndex = signalIndex - 1
        }
        guard active else { return WeightMath.normalizedWeightMap(rawWeights) }

        let equitySymbols: Set<String> = [
            "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite",
            "shenzhen_component", "chinext", "hsi", "nikkei",
        ]
        let globalSymbols = Set(stack.globalSymbols)
        var output = rawWeights
        var removed = 0.0
        for symbol in output.keys.sorted() {
            guard equitySymbols.contains(symbol) else { continue }
            let scale = globalSymbols.contains(symbol) ? control.globalOverlayScale : control.equityScale
            let oldWeight = max(output[symbol] ?? 0, 0)
            let newWeight = oldWeight * min(max(scale, 0), 1)
            output[symbol] = newWeight
            removed += max(oldWeight - newWeight, 0)
        }
        if removed > 0,
           control.redeployGoldRatio > 0,
           PortfolioIndicators.goldTrendOK(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex) {
            output["gold_cny", default: 0] += removed * min(max(control.redeployGoldRatio, 0), 1)
        }
        return WeightMath.normalizedWeightMap(output)
    }
}
