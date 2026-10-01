import Foundation

nonisolated enum GoldSatelliteOverlay {
    static func applyGoldSatelliteOverlay(
        to rawWeights: [String: Double],
        signalIndex: Int,
        signalDate: Date,
        pricesBySymbol: [String: [Double]],
        portfolioValues: [Double]? = nil,
        config: RotationParameters.AdvancedRotationConfig
    ) -> [String: Double] {
        guard let overlay = config.goldSatelliteOverlay else { return rawWeights }
        var finalWeights = WeightMath.clampedScaledWeightMap(rawWeights, by: min(max(overlay.coreScale, 0), 1))

        func priceMomentum(symbol: String, lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: lookback)
        }

        func isAboveMovingAverage(symbol: String, period: Int) -> Bool {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let movingAverage = TechnicalIndicators.movingAverage(values: prices, period: period)[signalIndex] else { return false }
            return prices[signalIndex] >= movingAverage
        }

        func satellitePassesTrendFilter() -> Bool {
            guard let satelliteMomentum = priceMomentum(
                symbol: overlay.satelliteSymbol,
                lookback: overlay.satelliteMomentumLookbackSessions
            ),
                  satelliteMomentum > overlay.satelliteMomentumThreshold,
                  isAboveMovingAverage(symbol: overlay.satelliteSymbol, period: overlay.satelliteMovingAveragePeriod),
                  let satellitePrices = pricesBySymbol[overlay.satelliteSymbol],
                  let relativePrices = pricesBySymbol[overlay.relativeSymbol],
                  signalIndex - overlay.relativeLookbackSessions >= 0,
                  satellitePrices.indices.contains(signalIndex),
                  satellitePrices.indices.contains(signalIndex - overlay.relativeLookbackSessions),
                  relativePrices.indices.contains(signalIndex),
                  relativePrices.indices.contains(signalIndex - overlay.relativeLookbackSessions) else { return false }
            let previousSatellitePrice = satellitePrices[signalIndex - overlay.relativeLookbackSessions]
            let previousRelativePrice = relativePrices[signalIndex - overlay.relativeLookbackSessions]
            let currentSatellitePrice = satellitePrices[signalIndex]
            let currentRelativePrice = relativePrices[signalIndex]
            guard previousSatellitePrice > 0,
                  previousRelativePrice > 0,
                  currentSatellitePrice > 0,
                  currentRelativePrice > 0 else { return false }
            let relativeMomentum = (currentSatellitePrice / previousSatellitePrice) / (currentRelativePrice / previousRelativePrice) - 1
            return relativeMomentum > overlay.relativeMomentumThreshold
        }

        let canUseSatellite = satellitePassesTrendFilter()
        if canUseSatellite {
            finalWeights[overlay.satelliteSymbol, default: 0] += max(overlay.satelliteWeight, 0)
        }

        if let portfolioEquityBrake = overlay.portfolioEquityBrake,
           let portfolioValues,
           portfolioValues.indices.contains(signalIndex) {
            let lookbackSessions = max(portfolioEquityBrake.lookbackSessions, 1)
            let startIndex = max(0, signalIndex - lookbackSessions + 1)
            if startIndex <= signalIndex,
               let recentPeak = portfolioValues[startIndex...signalIndex].max(),
               recentPeak > 0 {
                let drawdownFromPeak = portfolioValues[signalIndex] / recentPeak - 1
                if drawdownFromPeak < -max(portfolioEquityBrake.drawdownThreshold, 0) {
                    let scale = min(max(portfolioEquityBrake.equityScale, 0), 1)
                    for symbol in portfolioEquityBrake.equitySymbols {
                        guard let originalWeight = finalWeights[symbol], originalWeight > 0 else { continue }
                        finalWeights[symbol] = originalWeight * scale
                    }
                }
            }
        }

        if let weakMonthEquityBrake = overlay.weakMonthEquityBrake,
           weakMonthEquityBrake.months.contains(BacktestSeriesAlignment.historicalSeriesCalendar.component(.month, from: signalDate)) {
            let equitySymbolsToBrake = weakMonthEquityBrake.equitySymbols.filter { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let momentum = priceMomentum(symbol: symbol, lookback: weakMonthEquityBrake.momentumLookbackSessions) else { return false }
                return momentum < weakMonthEquityBrake.momentumThreshold
            }
            let currentEquityExposure = weakMonthEquityBrake.equitySymbols.reduce(0.0) { $0 + max(finalWeights[$1] ?? 0, 0) }
            let maxEquityExposure = min(max(weakMonthEquityBrake.maxEquityExposure, 0), 1)
            if !equitySymbolsToBrake.isEmpty,
               currentEquityExposure > maxEquityExposure,
               currentEquityExposure > 0 {
                let scale = maxEquityExposure / currentEquityExposure
                for symbol in weakMonthEquityBrake.equitySymbols {
                    guard let originalWeight = finalWeights[symbol], originalWeight > 0 else { continue }
                    finalWeights[symbol] = originalWeight * scale
                }
            }
        }

        var clippedExcess = 0.0
        var cappedEquitySymbols = Set<String>()
        if let singleAssetExposureCap = overlay.singleAssetExposureCap {
            let cap = min(max(singleAssetExposureCap.maxWeight, 0), 1)
            for symbol in singleAssetExposureCap.symbols {
                guard let originalWeight = finalWeights[symbol], originalWeight > cap else { continue }
                clippedExcess += originalWeight - cap
                finalWeights[symbol] = cap
                cappedEquitySymbols.insert(symbol)
            }
        }

        if let confirmedExcessRotation = overlay.confirmedExcessRotation,
           clippedExcess > 0 {
            let equitySymbols = Set(confirmedExcessRotation.equitySymbols)
            let cap = min(max(overlay.singleAssetExposureCap?.maxWeight ?? 1, 0), 1)
            let addBudget = min(clippedExcess, max(confirmedExcessRotation.maxAdd, 0))

            if addBudget > 0, canUseSatellite {
                let currentWeight = max(finalWeights[overlay.satelliteSymbol] ?? 0, 0)
                let room = max(overlay.maxTotalExposure - currentWeight, 0)
                let addition = min(addBudget, room)
                if addition > 0 {
                    finalWeights[overlay.satelliteSymbol, default: 0] += addition
                }
            } else if addBudget > 0 {
                let scoredCandidates: [(score: Double, symbol: String, room: Double)] = confirmedExcessRotation.candidateSymbols.compactMap { symbol -> (score: Double, symbol: String, room: Double)? in
                    guard let prices = pricesBySymbol[symbol],
                          prices.indices.contains(signalIndex),
                          let momentum = priceMomentum(symbol: symbol, lookback: confirmedExcessRotation.momentumLookbackSessions),
                          momentum > confirmedExcessRotation.minimumMomentum,
                          isAboveMovingAverage(symbol: symbol, period: confirmedExcessRotation.movingAveragePeriod) else { return nil }
                    let currentWeight = max(finalWeights[symbol] ?? 0, 0)
                    let room: Double
                    if equitySymbols.contains(symbol) {
                        guard !cappedEquitySymbols.contains(symbol), currentWeight < cap else { return nil }
                        room = max(cap - currentWeight, 0)
                    } else {
                        room = max(overlay.maxTotalExposure - currentWeight, 0)
                    }
                    guard room > 0 else { return nil }
                    let volatilitySeries = TechnicalIndicators.rollingAnnualizedVolatility(
                        values: prices,
                        period: confirmedExcessRotation.volatilityLookbackSessions
                    )
                    let volatility = volatilitySeries.indices.contains(signalIndex) ? (volatilitySeries[signalIndex] ?? 0.20) : 0.20
                    let denominator = max(volatility, confirmedExcessRotation.volatilityFloor)
                    guard denominator > 0 else { return nil }
                    return (score: momentum / denominator, symbol: symbol, room: room)
                }
                if let winner = scoredCandidates.max(by: { lhs, rhs in lhs.score < rhs.score }) {
                    finalWeights[winner.symbol, default: 0] += min(addBudget, winner.room)
                }
            }
        }

        var goldRolloverSignal = false
        if let goldRolloverCap = overlay.goldRolloverCap,
           let longMomentum = priceMomentum(symbol: goldRolloverCap.symbol, lookback: goldRolloverCap.longMomentumLookbackSessions),
           let shortMomentum = priceMomentum(symbol: goldRolloverCap.symbol, lookback: goldRolloverCap.shortMomentumLookbackSessions),
           longMomentum > goldRolloverCap.longMomentumThreshold,
           shortMomentum < goldRolloverCap.shortMomentumThreshold {
            goldRolloverSignal = true
            let maxWeight = min(max(goldRolloverCap.maxWeight, 0), 1)
            if let originalWeight = finalWeights[goldRolloverCap.symbol], originalWeight > maxWeight {
                finalWeights[goldRolloverCap.symbol] = maxWeight
            }
        }

        if goldRolloverSignal,
           let handoff = overlay.goldRolloverConfirmedHandoff {
            let maniaVetoActive = handoff.maniaVetoSymbols.contains { symbol in
                guard let momentum = priceMomentum(symbol: symbol, lookback: handoff.maniaMomentumLookbackSessions),
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex),
                      let donchianPosition = TechnicalIndicators.donchianRangePosition(
                        values: prices,
                        at: signalIndex,
                        period: handoff.maniaDonchianLookbackSessions
                      ) else { return false }
                return momentum > handoff.maniaMomentumThreshold
                    && donchianPosition > handoff.maniaDonchianPositionThreshold
            }

            if !maniaVetoActive {
                let candidates: [(momentum: Double, symbol: String)] = handoff.candidateSymbols.compactMap { symbol in
                    guard let momentum = priceMomentum(symbol: symbol, lookback: handoff.confirmationMomentumLookbackSessions),
                          momentum > 0,
                          isAboveMovingAverage(symbol: symbol, period: handoff.confirmationMovingAveragePeriod) else { return nil }
                    return (momentum: momentum, symbol: symbol)
                }
                if let winner = candidates.max(by: { lhs, rhs in lhs.momentum < rhs.momentum }) {
                    finalWeights[winner.symbol, default: 0] += max(handoff.replacementMaxAdd, 0)
                }
            }
        }

        if let diversificationCredit = overlay.diversificationCredit,
           !finalWeights.isEmpty,
           let goldPrices = pricesBySymbol[diversificationCredit.goldSymbol],
           goldPrices.indices.contains(signalIndex) {
            let strategyIsHealthy: Bool
            if let portfolioValues,
               portfolioValues.indices.contains(signalIndex) {
                let recentReturn = PortfolioIndicators.portfolioRollingReturn(
                    values: portfolioValues,
                    at: signalIndex,
                    lookback: diversificationCredit.strategyHealthLookbackSessions
                )
                let recentDrawdown = PortfolioIndicators.portfolioRollingDrawdown(
                    values: portfolioValues,
                    at: signalIndex,
                    lookback: diversificationCredit.strategyHealthLookbackSessions
                )
                strategyIsHealthy = (recentReturn ?? 0) >= 0
                    && (recentDrawdown ?? 0) >= -max(diversificationCredit.strategyDrawdownThreshold, 0)
            } else {
                strategyIsHealthy = true
            }

            let hasUSEquity = diversificationCredit.usEquitySymbols.contains { symbol in
                (finalWeights[symbol] ?? 0) > 0.0001
            }
            let usTrendValues = diversificationCredit.usEquitySymbols.compactMap { symbol -> Double? in
                guard let prices = pricesBySymbol[symbol] else { return nil }
                return TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: diversificationCredit.trendLookbackSessions)
            }
            let usTrend = usTrendValues.isEmpty ? nil : usTrendValues.reduce(0, +) / Double(usTrendValues.count)
            let correlation = PortfolioIndicators.rollingCorrelation(
                leftValues: goldPrices,
                rightValueSets: diversificationCredit.usEquitySymbols.compactMap { pricesBySymbol[$0] },
                at: signalIndex,
                lookback: diversificationCredit.correlationLookbackSessions
            )
            if strategyIsHealthy,
               hasUSEquity,
               let goldTrend = TechnicalIndicators.priceMomentum(values: goldPrices, at: signalIndex, lookback: diversificationCredit.trendLookbackSessions),
               let goldShortReturn = TechnicalIndicators.priceMomentum(values: goldPrices, at: signalIndex, lookback: diversificationCredit.goldShortLookbackSessions),
               let usTrend,
               let correlation,
               goldTrend > 0,
               usTrend > 0,
               goldShortReturn > diversificationCredit.goldShortReturnFloor,
               correlation < diversificationCredit.correlationCeiling {
                finalWeights[diversificationCredit.goldSymbol] = max(
                    finalWeights[diversificationCredit.goldSymbol] ?? 0,
                    min(max(diversificationCredit.goldFloor, 0), 1)
                )
            }
        }

        let totalExposure = WeightMath.positiveWeightSum(finalWeights)
        let maxTotalExposure = min(max(overlay.maxTotalExposure, 0), 1)
        if totalExposure > maxTotalExposure, totalExposure > 0 {
            let scale = maxTotalExposure / totalExposure
            finalWeights = WeightMath.clampedScaledWeightMap(finalWeights, by: scale)
        }

        return finalWeights.filter { $0.value > 0.0001 }
    }
}
