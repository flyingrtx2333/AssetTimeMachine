import Foundation

nonisolated enum EquityRepairOverlays {
    static func addOverlayWeights(_ overlays: [[String: Double]], to base: [String: Double]) -> [String: Double] {
        var output = base
        for overlay in overlays {
            for symbol in overlay.keys.sorted() {
                output[symbol, default: 0] += max(overlay[symbol] ?? 0, 0)
            }
        }
        return output
    }

    static func repairEquityBreadthOK(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Bool {
        var checked = 0
        var healthy = 0
        for symbol in ["nasdaq", "sp500", "csi300", "shanghai_composite"] {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let ma60 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 60),
                  let momentum20 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 20) else { continue }
            checked += 1
            if prices[signalIndex] > ma60 && momentum20 > -0.02 {
                healthy += 1
            }
        }
        return checked >= 3 && healthy >= 2
    }

    static func repairScore(
        symbol: String,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        stack: RotationParameters.AdvancedRotationGlobalRepairStack
    ) -> Double? {
        guard let prices = pricesBySymbol[symbol],
              prices.indices.contains(signalIndex),
              prices[signalIndex] > 0,
              let drawdown = TechnicalIndicators.rollingDrawdownFromHigh(
                values: prices,
                at: signalIndex,
                period: stack.repairDrawdownLookbackSessions
              ),
              let rebound = PortfolioIndicators.rollingLowRebound(
                values: prices,
                at: signalIndex,
                lookback: stack.repairReboundLookbackSessions
              ),
              let momentum = TechnicalIndicators.priceMomentum(
                values: prices,
                at: signalIndex,
                lookback: stack.repairMomentumLookbackSessions
              ),
              let fastMomentum = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 10),
              let confirmationMA = PortfolioIndicators.movingAverageAt(
                values: prices,
                at: signalIndex,
                period: stack.repairConfirmationMAPeriod
              ),
              let ma20 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 20) else { return nil }
        guard drawdown <= -max(stack.repairDrawdownThreshold, 0),
              rebound >= max(stack.repairReboundThreshold, 0),
              prices[signalIndex] >= confirmationMA,
              prices[signalIndex] >= ma20,
              momentum >= 0,
              fastMomentum >= 0 else { return nil }

        let equitySymbols: Set<String> = ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "chinext"]
        if equitySymbols.contains(symbol), !repairEquityBreadthOK(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex) {
            return nil
        }
        if symbol == "gold_cny",
           let ma120 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 120),
           prices[signalIndex] < ma120 * 0.96 {
            return nil
        }

        let volatility = PortfolioIndicators.annualizedVolatilityAt(values: prices, at: signalIndex, lookback: 60) ?? 9.0
        let score = max(0, rebound * 1.2 + momentum * 0.8 + fastMomentum * 0.5 + max(drawdown, -0.60) * 0.20) / max(volatility, 0.03)
        return score > 0 ? score : nil
    }

    static func repairTargets(
        stack: RotationParameters.AdvancedRotationGlobalRepairStack,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        budget: Double,
        activeRepairSymbols: Set<String>
    ) -> [String: Double] {
        guard signalIndex >= 0, budget > 0 else { return [:] }
        let scored = stack.repairSymbols.compactMap { symbol -> (score: Double, symbol: String)? in
            guard !stack.globalSymbols.contains(symbol),
                  let score = repairScore(
                    symbol: symbol,
                    pricesBySymbol: pricesBySymbol,
                    signalIndex: signalIndex,
                    stack: stack
                  ) else { return nil }
            return (score, symbol)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
            return lhs.score > rhs.score
        }
        let selected = Array(scored.prefix(max(stack.repairTopCount, 1)))
        let scoreTotal = selected.reduce(0.0) { $0 + $1.score }
        guard scoreTotal > 0 else { return [:] }
        var output: [String: Double] = [:]
        for item in selected {
            output[item.symbol] = min(max(stack.repairPerAssetCap, 0), budget * item.score / scoreTotal)
        }
        return WeightMath.normalizedWeightMap(output, maxTotalExposure: budget)
    }

    static func globalBreadthOK(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Bool {
        var checked = 0
        var healthy = 0
        for symbol in ["nasdaq", "sp500", "hsi", "nikkei", "csi300", "shanghai_composite"] {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let ma60 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 60),
                  let momentum20 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 20) else { continue }
            checked += 1
            if prices[signalIndex] > ma60 && momentum20 > -0.025 {
                healthy += 1
            }
        }
        return checked >= 4 && healthy >= 3
    }

    static func globalRepairScore(
        symbol: String,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Double? {
        guard let prices = pricesBySymbol[symbol],
              prices.indices.contains(signalIndex),
              prices[signalIndex] > 0,
              let drawdown = TechnicalIndicators.rollingDrawdownFromHigh(values: prices, at: signalIndex, period: 120),
              let rebound = PortfolioIndicators.rollingLowRebound(values: prices, at: signalIndex, lookback: 30),
              let momentum20 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 20),
              let momentum60 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 60),
              let ma20 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 20),
              let ma40 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 40),
              let ma120 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 120) else { return nil }
        guard drawdown <= -0.10,
              rebound >= 0.055,
              prices[signalIndex] >= ma20,
              prices[signalIndex] >= ma40,
              momentum20 >= 0,
              momentum60 >= -0.02 else { return nil }

        if ["hsi", "nikkei"].contains(symbol),
           !globalBreadthOK(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex) {
            return nil
        }
        if symbol == "oil_wti_cny" {
            guard let goldPrices = pricesBySymbol["gold_cny"],
                  goldPrices.indices.contains(signalIndex),
                  let goldMomentum60 = TechnicalIndicators.priceMomentum(values: goldPrices, at: signalIndex, lookback: 60),
                  let goldMA120 = PortfolioIndicators.movingAverageAt(values: goldPrices, at: signalIndex, period: 120),
                  goldMomentum60 >= 0,
                  goldPrices[signalIndex] >= goldMA120,
                  momentum60 >= 0.04,
                  prices[signalIndex] >= ma120 else { return nil }
        }
        let volatility = PortfolioIndicators.annualizedVolatilityAt(values: prices, at: signalIndex, lookback: 60) ?? 9.0
        let score = max(0, rebound * 1.3 + momentum20 * 0.5 + momentum60 * 0.45 + max(drawdown, -0.50) * 0.15) / max(volatility, 0.04)
        return score > 0 ? score : nil
    }

    static func globalRepairTargets(
        stack: RotationParameters.AdvancedRotationGlobalRepairStack,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        budget: Double
    ) -> [String: Double] {
        guard signalIndex >= 0, budget > 0 else { return [:] }
        let scored = stack.globalSymbols.compactMap { symbol -> (score: Double, symbol: String)? in
            guard let score = globalRepairScore(
                symbol: symbol,
                pricesBySymbol: pricesBySymbol,
                signalIndex: signalIndex
            ) else { return nil }
            return (score, symbol)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
            return lhs.score > rhs.score
        }
        let selected = Array(scored.prefix(max(stack.globalTopCount, 1)))
        let scoreTotal = selected.reduce(0.0) { $0 + $1.score }
        guard scoreTotal > 0 else { return [:] }
        var output: [String: Double] = [:]
        for item in selected {
            let cap = stack.globalPerAssetCapBySymbol[item.symbol] ?? stack.globalPerAssetCap
            output[item.symbol] = min(max(cap, 0), budget * item.score / scoreTotal)
        }
        return WeightMath.normalizedWeightMap(output, maxTotalExposure: budget)
    }

    static func updatePhaseLocks(
        stack: RotationParameters.AdvancedRotationGlobalRepairStack,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        state: inout RotationState.AdvancedRotationOverlayState
    ) {
        guard signalIndex >= 0,
              let prices = pricesBySymbol["gold_cny"],
              prices.indices.contains(signalIndex) else { return }

        if let lockStart = state.phaseLockedStartIndexBySymbol["gold_cny"] {
            let momentum20 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 20)
            let ma40 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 40)
            if (signalIndex - lockStart >= stack.phaseMaxLockSessions && (momentum20 ?? -1) > 0)
                || (ma40 != nil && prices[signalIndex] > ma40! && (momentum20 ?? -1) > 0.025) {
                state.phaseLockedStartIndexBySymbol["gold_cny"] = nil
            }
            return
        }

        guard let hotReturn = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: stack.phaseHotLookbackSessions),
              let crackReturn = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: stack.phaseCrackLookbackSessions),
              let drawdown = TechnicalIndicators.rollingDrawdownFromHigh(values: prices, at: signalIndex, period: stack.phaseHotLookbackSessions),
              let ma20 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 20),
              let ma40 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 40),
              let ma120 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 120) else { return }
        let hot = hotReturn >= stack.phaseHotThreshold || prices[signalIndex] > ma120 * (1 + stack.phaseHotThreshold * 0.45)
        let rollover = crackReturn <= stack.phaseCrackThreshold || drawdown <= -max(stack.phaseRolloverDrawdown, 0)
        let broken = prices[signalIndex] < ma20 || prices[signalIndex] < ma40
        if hot && rollover && broken {
            state.phaseLockedStartIndexBySymbol["gold_cny"] = signalIndex
        }
    }

    static func applyPhaseLocks(
        to rawWeights: [String: Double],
        stack: RotationParameters.AdvancedRotationGlobalRepairStack,
        state: RotationState.AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard !state.phaseLockedStartIndexBySymbol.isEmpty else { return WeightMath.normalizedWeightMap(rawWeights) }
        var output = rawWeights
        let scale = min(max(stack.phaseLockScale, 0), 1)
        for symbol in state.phaseLockedStartIndexBySymbol.keys.sorted() {
            if let weight = output[symbol], weight > 0 {
                output[symbol] = weight * scale
            }
        }
        return WeightMath.normalizedWeightMap(output)
    }

    static func applyGlobalRepairStack(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: RotationParameters.AdvancedRotationConfig,
        state: inout RotationState.AdvancedRotationOverlayState,
        refreshRepairOverlay: Bool
    ) -> [String: Double] {
        guard let stack = config.globalRepairStack else {
            return WeightMath.normalizedWeightMap(rawWeights)
        }

        if refreshRepairOverlay {
            let repairBudget = min(max(stack.repairOverlayCap, 0), max(0, 1 - WeightMath.overlayTotalWeight(rawWeights)))
            state.repairOverlay = repairTargets(
                stack: stack,
                pricesBySymbol: pricesBySymbol,
                signalIndex: signalIndex,
                budget: repairBudget,
                activeRepairSymbols: Set(state.repairOverlay.keys)
            )
            let globalBudget = min(
                max(stack.globalOverlayCap, 0),
                max(0, 1 - WeightMath.overlayTotalWeight(rawWeights) - WeightMath.overlayTotalWeight(state.repairOverlay))
            )
            state.globalOverlay = globalRepairTargets(
                stack: stack,
                pricesBySymbol: pricesBySymbol,
                signalIndex: signalIndex,
                budget: globalBudget
            )
        }

        updatePhaseLocks(
            stack: stack,
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            state: &state
        )
        var output = addOverlayWeights(
            [state.repairOverlay, state.globalOverlay],
            to: rawWeights
        )
        output = applyPhaseLocks(to: output, stack: stack, state: state)
        output = ContagionOverlay.applyContagionControl(
            to: output,
            stack: stack,
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            state: &state
        )
        return WeightMath.normalizedWeightMap(output)
    }
}
