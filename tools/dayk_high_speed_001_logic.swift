import Foundation

nonisolated struct DayKHighSpeed001Bar {
    let open: Double
    let high: Double
    let low: Double
    let close: Double
}

nonisolated struct DayKHighSpeed001Signal {
    let previousClose: Double
    let trendSMA: Double
    let atr: Double
    let gapDown: Double
    let takeProfitPrice: Double
}

nonisolated enum DayKHighSpeed001Logic {
    static let trendLookback = 50
    static let atrLookback = 14
    static let gapATRMultiple = 0.25
    static let takeProfitATRMultiple = 0.25

    static func simpleMovingAverage(
        bars: [DayKHighSpeed001Bar],
        endingBefore index: Int,
        lookback: Int
    ) -> Double? {
        guard lookback > 0, index >= lookback, index <= bars.count else { return nil }
        let values = bars[(index - lookback)..<index].map(\.close)
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func averageTrueRange(
        bars: [DayKHighSpeed001Bar],
        endingBefore index: Int,
        lookback: Int
    ) -> Double? {
        guard lookback > 0, index > lookback, index <= bars.count else { return nil }
        var trueRanges: [Double] = []
        trueRanges.reserveCapacity(lookback)
        for barIndex in (index - lookback)..<index {
            guard barIndex > 0 else { return nil }
            let bar = bars[barIndex]
            let previousClose = bars[barIndex - 1].close
            guard min(bar.open, bar.high, bar.low, bar.close, previousClose) > 0,
                  bar.high >= max(bar.open, bar.close, bar.low),
                  bar.low <= min(bar.open, bar.close, bar.high) else { return nil }
            trueRanges.append(max(
                bar.high - bar.low,
                abs(bar.high - previousClose),
                abs(bar.low - previousClose)
            ))
        }
        guard !trueRanges.isEmpty else { return nil }
        let value = trueRanges.reduce(0, +) / Double(trueRanges.count)
        return value.isFinite && value > 0 ? value : nil
    }

    /// Returns the exact open-time signal. All trend and volatility inputs end at T-1;
    /// only today's opening print is read from T before the entry decision.
    static func signal(
        bars: [DayKHighSpeed001Bar],
        executionIndex: Int,
        requireTrend: Bool
    ) -> DayKHighSpeed001Signal? {
        guard bars.indices.contains(executionIndex), executionIndex > trendLookback else { return nil }
        let current = bars[executionIndex]
        let previousClose = bars[executionIndex - 1].close
        guard current.open.isFinite, current.open > 0,
              previousClose.isFinite, previousClose > 0,
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
        let gapDown = previousClose - current.open
        guard gapDown >= gapATRMultiple * atr else { return nil }
        let takeProfitPrice = current.open + takeProfitATRMultiple * atr
        guard takeProfitPrice.isFinite, takeProfitPrice > current.open else { return nil }
        return DayKHighSpeed001Signal(
            previousClose: previousClose,
            trendSMA: trendSMA,
            atr: atr,
            gapDown: gapDown,
            takeProfitPrice: takeProfitPrice
        )
    }
}
