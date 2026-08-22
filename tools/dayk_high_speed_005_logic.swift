import Foundation

nonisolated struct DayKHighSpeed005Bar {
    let open: Double
    let high: Double
    let low: Double
    let close: Double
}

nonisolated struct DayKHighSpeed005Signal {
    let previousClose: Double
    let sma50: Double
    let sma200: Double
    let atr14: Double
    let atr60: Double
    let rsi3: Double
    let twoSessionPullback: Double
    let factorVotes: Int
    let trendAlignmentVote: Bool
    let oversoldVote: Bool
    let volatilityExpansionVote: Bool
    let bullishRejectionVote: Bool
    let takeProfitPrice: Double
}

nonisolated enum DayKHighSpeed005Logic {
    static let fastTrendLookback = 50
    static let slowTrendLookback = 200
    static let fastATRLookback = 14
    static let slowATRLookback = 60
    static let rsiLookback = 3
    static let pullbackATRMultiple = 1.0
    static let oversoldRSIThreshold = 30.0
    static let bullishCloseLocationThreshold = 0.60
    static let minimumFactorVotes = 2
    static let takeProfitATRMultiple = 0.75
    static let maximumHoldingSessions = 5

    static func simpleMovingAverage(
        bars: [DayKHighSpeed005Bar], endingBefore index: Int, lookback: Int
    ) -> Double? {
        guard lookback > 0, index >= lookback, index <= bars.count else { return nil }
        let values = bars[(index - lookback)..<index].map(\.close)
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func averageTrueRange(
        bars: [DayKHighSpeed005Bar], endingBefore index: Int, lookback: Int
    ) -> Double? {
        guard lookback > 0, index > lookback, index <= bars.count else { return nil }
        var values: [Double] = []
        values.reserveCapacity(lookback)
        for barIndex in (index - lookback)..<index {
            guard barIndex > 0 else { return nil }
            let bar = bars[barIndex]
            let priorClose = bars[barIndex - 1].close
            guard min(bar.open, bar.high, bar.low, bar.close, priorClose) > 0,
                  bar.high >= max(bar.open, bar.close, bar.low),
                  bar.low <= min(bar.open, bar.close, bar.high) else { return nil }
            values.append(max(
                bar.high - bar.low,
                abs(bar.high - priorClose),
                abs(bar.low - priorClose)
            ))
        }
        let atr = values.reduce(0, +) / Double(values.count)
        return atr.isFinite && atr > 0 ? atr : nil
    }

    static func relativeStrengthIndex(
        bars: [DayKHighSpeed005Bar], endingBefore index: Int, lookback: Int
    ) -> Double? {
        guard lookback > 0, index > lookback, index <= bars.count else { return nil }
        var gains = 0.0
        var losses = 0.0
        for barIndex in (index - lookback)..<index {
            let change = bars[barIndex].close - bars[barIndex - 1].close
            if change > 0 { gains += change } else { losses -= change }
        }
        if losses == 0 { return gains > 0 ? 100 : 50 }
        let rs = gains / losses
        let value = 100 - 100 / (1 + rs)
        return value.isFinite ? value : nil
    }

    /// T is the execution day. Every factor ends at T-1; only T open freezes
    /// the entry and profit-limit prices. `minimumVotes=0` is the matched 004 base control.
    static func signal(
        bars: [DayKHighSpeed005Bar],
        executionIndex: Int,
        minimumVotes: Int
    ) -> DayKHighSpeed005Signal? {
        guard bars.indices.contains(executionIndex), executionIndex > slowTrendLookback else { return nil }
        let current = bars[executionIndex]
        let previous = bars[executionIndex - 1]
        let closeTwoSessionsEarlier = bars[executionIndex - 3].close
        guard current.open.isFinite, current.open > 0,
              let sma50 = simpleMovingAverage(bars: bars, endingBefore: executionIndex, lookback: fastTrendLookback),
              let sma200 = simpleMovingAverage(bars: bars, endingBefore: executionIndex, lookback: slowTrendLookback),
              let atr14 = averageTrueRange(bars: bars, endingBefore: executionIndex, lookback: fastATRLookback),
              let atr60 = averageTrueRange(bars: bars, endingBefore: executionIndex, lookback: slowATRLookback),
              let rsi3 = relativeStrengthIndex(bars: bars, endingBefore: executionIndex, lookback: rsiLookback) else { return nil }

        guard previous.close > sma200 else { return nil }
        let pullback = closeTwoSessionsEarlier - previous.close
        guard pullback >= pullbackATRMultiple * atr14 else { return nil }

        let trendAlignment = sma50 > sma200
        let oversold = rsi3 <= oversoldRSIThreshold
        let volatilityExpansion = atr14 > atr60
        let range = previous.high - previous.low
        let closeLocation = range > 0 ? (previous.close - previous.low) / range : 0
        let bullishRejection = previous.close > previous.open
            && closeLocation >= bullishCloseLocationThreshold
        let votes = [trendAlignment, oversold, volatilityExpansion, bullishRejection].filter { $0 }.count
        guard votes >= max(minimumVotes, 0) else { return nil }

        let takeProfitPrice = current.open + takeProfitATRMultiple * atr14
        guard takeProfitPrice.isFinite, takeProfitPrice > current.open else { return nil }
        return DayKHighSpeed005Signal(
            previousClose: previous.close,
            sma50: sma50,
            sma200: sma200,
            atr14: atr14,
            atr60: atr60,
            rsi3: rsi3,
            twoSessionPullback: pullback,
            factorVotes: votes,
            trendAlignmentVote: trendAlignment,
            oversoldVote: oversold,
            volatilityExpansionVote: volatilityExpansion,
            bullishRejectionVote: bullishRejection,
            takeProfitPrice: takeProfitPrice
        )
    }
}
