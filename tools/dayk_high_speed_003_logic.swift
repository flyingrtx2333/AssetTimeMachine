import Foundation

nonisolated struct DayKHighSpeed003Bar {
    let open: Double
    let high: Double
    let low: Double
    let close: Double
}

nonisolated struct DayKHighSpeed003Signal {
    let previousClose: Double
    let trendSMA: Double
    let atr: Double
    let twoSessionPullback: Double
    let takeProfitPrice: Double
}

nonisolated enum DayKHighSpeed003Logic {
    static let trendLookback = 200
    static let atrLookback = 14
    static let pullbackATRMultiple = 1.0
    static let takeProfitATRMultiple = 0.75
    static let maximumHoldingSessions = 5

    static func simpleMovingAverage(
        bars: [DayKHighSpeed003Bar],
        endingBefore index: Int,
        lookback: Int
    ) -> Double? {
        guard lookback > 0, index >= lookback, index <= bars.count else { return nil }
        let values = bars[(index - lookback)..<index].map(\.close)
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func averageTrueRange(
        bars: [DayKHighSpeed003Bar],
        endingBefore index: Int,
        lookback: Int
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

    /// T is the execution day. The signal uses T-1 and earlier daily bars;
    /// only T's open is read to freeze the entry and profit-limit prices.
    static func signal(
        bars: [DayKHighSpeed003Bar],
        executionIndex: Int,
        requireTrend: Bool
    ) -> DayKHighSpeed003Signal? {
        guard bars.indices.contains(executionIndex), executionIndex > trendLookback else { return nil }
        let current = bars[executionIndex]
        let previousClose = bars[executionIndex - 1].close
        let closeTwoSessionsEarlier = bars[executionIndex - 3].close
        guard current.open.isFinite, current.open > 0,
              let trendSMA = simpleMovingAverage(
                bars: bars,
                endingBefore: executionIndex,
                lookback: trendLookback
              ),
              let atr = averageTrueRange(
                bars: bars,
                endingBefore: executionIndex,
                lookback: atrLookback
              ) else { return nil }

        if requireTrend, previousClose <= trendSMA { return nil }
        let pullback = closeTwoSessionsEarlier - previousClose
        guard pullback >= pullbackATRMultiple * atr else { return nil }
        let takeProfitPrice = current.open + takeProfitATRMultiple * atr
        guard takeProfitPrice.isFinite, takeProfitPrice > current.open else { return nil }
        return DayKHighSpeed003Signal(
            previousClose: previousClose,
            trendSMA: trendSMA,
            atr: atr,
            twoSessionPullback: pullback,
            takeProfitPrice: takeProfitPrice
        )
    }
}
