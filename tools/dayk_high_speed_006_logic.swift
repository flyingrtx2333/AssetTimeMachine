import Foundation

nonisolated struct DayKHighSpeed006Bar {
    let open: Double
    let high: Double
    let low: Double
    let close: Double
}

nonisolated struct DayKHighSpeed006Signal {
    let previousClose: Double
    let sma200: Double
    let atr14: Double
    let initialStopPrice: Double
}

nonisolated enum DayKHighSpeed006Logic {
    static let consecutiveRiseSessions = 3
    static let trendLookback = 200
    static let atrLookback = 14
    static let stopATRMultiple = 2.0

    static func simpleMovingAverage(
        bars: [DayKHighSpeed006Bar], endingBefore index: Int, lookback: Int
    ) -> Double? {
        guard lookback > 0, index >= lookback, index <= bars.count else { return nil }
        let values = bars[(index - lookback)..<index].map(\.close)
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func averageTrueRange(
        bars: [DayKHighSpeed006Bar], endingBefore index: Int, lookback: Int
    ) -> Double? {
        guard lookback > 0, index > lookback, index <= bars.count else { return nil }
        var values: [Double] = []
        for barIndex in (index - lookback)..<index {
            guard barIndex > 0 else { return nil }
            let bar = bars[barIndex]
            let priorClose = bars[barIndex - 1].close
            guard min(bar.open, bar.high, bar.low, bar.close, priorClose) > 0,
                  bar.high >= max(bar.open, bar.close, bar.low),
                  bar.low <= min(bar.open, bar.close, bar.high) else { return nil }
            values.append(max(bar.high - bar.low, abs(bar.high - priorClose), abs(bar.low - priorClose)))
        }
        let value = values.reduce(0, +) / Double(values.count)
        return value.isFinite && value > 0 ? value : nil
    }

    static func signal(
        bars: [DayKHighSpeed006Bar], executionIndex: Int, requireTrend: Bool = true
    ) -> DayKHighSpeed006Signal? {
        guard bars.indices.contains(executionIndex), executionIndex > trendLookback else { return nil }
        let current = bars[executionIndex]
        let c1 = bars[executionIndex - 1].close
        let c2 = bars[executionIndex - 2].close
        let c3 = bars[executionIndex - 3].close
        let c4 = bars[executionIndex - 4].close
        guard c1 > c2, c2 > c3, c3 > c4,
              let sma200 = simpleMovingAverage(bars: bars, endingBefore: executionIndex, lookback: trendLookback),
              let atr14 = averageTrueRange(bars: bars, endingBefore: executionIndex, lookback: atrLookback),
              current.open.isFinite, current.open > 0 else { return nil }
        if requireTrend, c1 <= sma200 { return nil }
        let stop = current.open - stopATRMultiple * atr14
        guard stop.isFinite, stop > 0, stop < current.open else { return nil }
        return .init(previousClose: c1, sma200: sma200, atr14: atr14, initialStopPrice: stop)
    }

    /// Called after a completed holding-session close. The returned stop is
    /// effective only on the next asset session and can never move downward.
    static func updatedTrailingStop(
        bars: [DayKHighSpeed006Bar],
        completedIndex: Int,
        highestCompletedClose: Double,
        previousStop: Double
    ) -> Double? {
        guard bars.indices.contains(completedIndex),
              let atr14 = averageTrueRange(
                bars: bars, endingBefore: completedIndex + 1, lookback: atrLookback
              ) else { return nil }
        let proposed = highestCompletedClose - stopATRMultiple * atr14
        guard proposed.isFinite, proposed > 0 else { return previousStop > 0 ? previousStop : nil }
        return max(previousStop, proposed)
    }
}
