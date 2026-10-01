import Foundation

nonisolated enum OHLCRiskOverlay {
    static func ohlcRiskFeatures(
        bars: [RotationParameters.AdvancedRotationOHLCBar]
    ) -> [Date: RotationParameters.AdvancedRotationOHLCRiskFeature] {
        guard !bars.isEmpty else { return [:] }
        let closes = bars.map(\.close)
        let highs = bars.map(\.high)
        let lows = bars.map(\.low)
        let opens = bars.map(\.open)
        let trueRanges = bars.indices.map { index -> Double in
            let previousClose = index > 0 ? closes[index - 1] : closes[index]
            guard previousClose > 0 else { return 0 }
            let range = max(
                highs[index] - lows[index],
                abs(highs[index] - previousClose),
                abs(lows[index] - previousClose)
            ) / previousClose
            return range.isFinite ? range : 0
        }

        func average(_ values: [Double], at index: Int, period: Int) -> Double? {
            guard period > 0, index - period + 1 >= 0 else { return nil }
            let window = values[(index - period + 1)...index]
            guard window.allSatisfy({ $0.isFinite }) else { return nil }
            return window.reduce(0, +) / Double(period)
        }

        var output: [Date: RotationParameters.AdvancedRotationOHLCRiskFeature] = [:]
        for index in bars.indices {
            let close = closes[index]
            let previousClose = index > 0 ? closes[index - 1] : close
            guard close > 0, previousClose > 0 else { continue }
            let rangePercent = (highs[index] - lows[index]) / previousClose
            let atr20 = average(trueRanges, at: index, period: 20)
            let atr120 = average(trueRanges, at: index, period: 120)
            let atrRatio: Double?
            if let atr20, let atr120, atr120 > 0 {
                atrRatio = atr20 / atr120
            } else {
                atrRatio = nil
            }
            let closeLocation = highs[index] > lows[index]
                ? (close - lows[index]) / (highs[index] - lows[index])
                : nil
            let momentum20 = TechnicalIndicators.priceMomentum(values: closes, at: index, lookback: 20)
            let momentum60 = TechnicalIndicators.priceMomentum(values: closes, at: index, lookback: 60)
            let momentum120 = TechnicalIndicators.priceMomentum(values: closes, at: index, lookback: 120)
            let ma40 = PortfolioIndicators.movingAverageAt(values: closes, at: index, period: 40)
            let ma60 = PortfolioIndicators.movingAverageAt(values: closes, at: index, period: 60)
            let ma120 = PortfolioIndicators.movingAverageAt(values: closes, at: index, period: 120)
            let low20 = index >= 19 ? lows[(index - 19)...index].min() : nil
            let low60 = index >= 59 ? lows[(index - 59)...index].min() : nil

            var score = 0
            if close / previousClose - 1 < -0.035 {
                score += 2
            }
            if opens[index] / previousClose - 1 < -0.025 {
                score += 1
            }
            if let low20, lows[index] <= low20, let atrRatio, atrRatio > 1.12 {
                score += 1
            }
            if let low60, lows[index] <= low60, let atrRatio, atrRatio > 1.03 {
                score += 1
            }
            if let closeLocation, let atr20, closeLocation < 0.28, rangePercent > atr20 * 1.08 {
                score += 1
            }
            let hot = (momentum120.map { $0 > 0.28 } ?? false)
                || (momentum60.map { $0 > 0.16 } ?? false)
                || (ma120.map { close > $0 * 1.16 } ?? false)
            let rollover = (momentum20.map { $0 < -0.025 } ?? false)
                || (ma40.map { close < $0 } ?? false)
                || (low20.map { lows[index] <= $0 } ?? false)
            if hot && rollover {
                score += 2
            }
            if let ma60,
               let momentum20,
               let momentum60,
               close < ma60,
               momentum20 < -0.02,
               momentum60 < -0.03 {
                score += 1
            }
            output[bars[index].date] = .init(score: score)
        }
        return output
    }

    static func alignedOHLCRiskFeatures(
        from preparedSeries: [PreparedAdvancedSeries],
        commonDates: [Date]
    ) -> [String: [RotationParameters.AdvancedRotationOHLCRiskFeature?]] {
        let calendar = BacktestSeriesAlignment.historicalSeriesCalendar
        var output: [String: [RotationParameters.AdvancedRotationOHLCRiskFeature?]] = [:]
        for prepared in preparedSeries where !prepared.ohlcPoints.isEmpty {
            let bars = prepared.ohlcPoints
                .filter { BacktestSeriesAlignment.isStrategySessionDate($0.date) }
                .map {
                RotationParameters.AdvancedRotationOHLCBar(date: $0.date, open: $0.open, high: $0.high, low: $0.low, close: $0.close)
            }
            let featuresByDate = ohlcRiskFeatures(bars: bars)
            let featureDates = featuresByDate.keys.sorted()
            var cursor = 0
            var latestDate: Date?
            var latestFeature: RotationParameters.AdvancedRotationOHLCRiskFeature?
            var values: [RotationParameters.AdvancedRotationOHLCRiskFeature?] = []
            values.reserveCapacity(commonDates.count)

            for currentDate in commonDates {
                while cursor < featureDates.count && featureDates[cursor] <= currentDate {
                    latestDate = featureDates[cursor]
                    latestFeature = featuresByDate[featureDates[cursor]]
                    cursor += 1
                }
                if let latestDate,
                   let latestFeature,
                   (calendar.dateComponents([.day], from: latestDate, to: currentDate).day ?? 999) <= 7 {
                    values.append(latestFeature)
                } else {
                    values.append(nil)
                }
            }
            output[prepared.assetOption.symbol] = values
        }
        return output
    }

    static func ohlcClusterIsActive(
        featuresBySymbol: [String: [RotationParameters.AdvancedRotationOHLCRiskFeature?]],
        symbols: [String],
        signalIndex: Int,
        overlay: RotationParameters.AdvancedRotationOHLCRiskOverlay
    ) -> Bool {
        var totalScore = 0
        var weak = 0
        for symbol in symbols {
            guard let features = featuresBySymbol[symbol],
                  features.indices.contains(signalIndex),
                  let feature = features[signalIndex] else { continue }
            totalScore += feature.score
            if feature.score >= 2 {
                weak += 1
            }
        }
        return totalScore >= overlay.minClusterScore && weak >= overlay.minClusterWeak
    }

    static func ohlcRiskReleaseOK(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        overlay: RotationParameters.AdvancedRotationOHLCRiskOverlay
    ) -> Bool {
        var checked = 0
        var healthy = 0
        for symbol in overlay.usSymbols + overlay.chinaSymbols {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let ma60 = PortfolioIndicators.movingAverageAt(values: prices, at: signalIndex, period: 60),
                  let momentum20 = TechnicalIndicators.priceMomentum(values: prices, at: signalIndex, lookback: 20) else { continue }
            checked += 1
            if prices[signalIndex] > ma60 && momentum20 > 0 {
                healthy += 1
            }
        }
        return checked >= 5 && healthy >= overlay.releaseHealthyCount
    }

    static func applyOHLCRiskOverlay(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        ohlcFeaturesBySymbol: [String: [RotationParameters.AdvancedRotationOHLCRiskFeature?]]?,
        config: RotationParameters.AdvancedRotationConfig,
        state: inout RotationState.AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard let overlay = config.ohlcRiskOverlay,
              let ohlcFeaturesBySymbol,
              signalIndex >= 0 else {
            return WeightMath.normalizedWeightMap(rawWeights)
        }
        let usActive = ohlcClusterIsActive(
            featuresBySymbol: ohlcFeaturesBySymbol,
            symbols: overlay.usSymbols,
            signalIndex: signalIndex,
            overlay: overlay
        )
        let chinaActive = ohlcClusterIsActive(
            featuresBySymbol: ohlcFeaturesBySymbol,
            symbols: overlay.chinaSymbols,
            signalIndex: signalIndex,
            overlay: overlay
        )
        if usActive || chinaActive {
            state.ohlcRiskUntilIndex = max(state.ohlcRiskUntilIndex, signalIndex + overlay.cooldownSessions)
        }

        var active = state.ohlcRiskUntilIndex >= signalIndex
        if active && ohlcRiskReleaseOK(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex, overlay: overlay) {
            active = false
            state.ohlcRiskUntilIndex = signalIndex - 1
        }
        guard active else { return WeightMath.normalizedWeightMap(rawWeights) }

        let usSymbols = Set(overlay.usSymbols)
        let chinaSymbols = Set(overlay.chinaSymbols)
        let otherEquitySymbols = Set(overlay.otherEquitySymbols)
        var output = rawWeights
        var removed = 0.0
        for symbol in output.keys.sorted() {
            let scale: Double
            if usSymbols.contains(symbol) {
                scale = overlay.usScale
            } else if chinaSymbols.contains(symbol) {
                scale = overlay.chinaScale
            } else if otherEquitySymbols.contains(symbol) {
                scale = overlay.otherEquityScale
            } else {
                continue
            }
            let originalWeight = max(output[symbol] ?? 0, 0)
            let scaledWeight = originalWeight * min(max(scale, 0), 1)
            output[symbol] = scaledWeight
            removed += max(originalWeight - scaledWeight, 0)
        }
        if removed > 0,
           overlay.redeployGoldRatio > 0,
           PortfolioIndicators.goldTrendOK(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex) {
            output["gold_cny", default: 0] += removed * min(max(overlay.redeployGoldRatio, 0), 1)
        }
        return WeightMath.normalizedWeightMap(output)
    }
}
