import Foundation

nonisolated struct DayKHighSpeed002Bar {
    let open: Double
    let high: Double
    let low: Double
    let close: Double
}

nonisolated struct DayKHighSpeed002Signal {
    let previousClose: Double
    let trendSMA: Double
    let atr: Double
    let previousTrueRange: Double
    let previousCloseLocation: Double
    let takeProfitPrice: Double
}

nonisolated enum DayKHighSpeed002Logic {
    static let trendLookback = 50
    static let atrLookback = 14
    static let compressionATRMultiple = 0.75
    static let minimumCloseLocation = 0.75
    static let takeProfitATRMultiple = 0.25

    static func simpleMovingAverage(
        bars: [DayKHighSpeed002Bar],
        endingBefore index: Int,
        lookback: Int
    ) -> Double? {
        guard lookback > 0, index >= lookback, index <= bars.count else { return nil }
        let values = bars[(index - lookback)..<index].map(\.close)
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func trueRange(bars: [DayKHighSpeed002Bar], at index: Int) -> Double? {
        guard bars.indices.contains(index), index > 0 else { return nil }
        let bar = bars[index]
        let previousClose = bars[index - 1].close
        guard min(bar.open, bar.high, bar.low, bar.close, previousClose) > 0,
              bar.high >= max(bar.open, bar.close, bar.low),
              bar.low <= min(bar.open, bar.close, bar.high) else { return nil }
        let value = max(
            bar.high - bar.low,
            abs(bar.high - previousClose),
            abs(bar.low - previousClose)
        )
        return value.isFinite && value > 0 ? value : nil
    }

    /// ATR is frozen at T-2 so the T-1 compression bar is compared with a
    /// genuinely prior volatility baseline rather than partly with itself.
    static func averageTrueRangeBeforeCompressionBar(
        bars: [DayKHighSpeed002Bar],
        executionIndex: Int,
        lookback: Int
    ) -> Double? {
        let compressionIndex = executionIndex - 1
        guard lookback > 0, compressionIndex > lookback else { return nil }
        let first = compressionIndex - lookback
        let values = (first..<compressionIndex).compactMap { trueRange(bars: bars, at: $0) }
        guard values.count == lookback else { return nil }
        let value = values.reduce(0, +) / Double(values.count)
        return value.isFinite && value > 0 ? value : nil
    }

    /// Signal inputs end at T-1; only today's opening print is read from T.
    static func signal(
        bars: [DayKHighSpeed002Bar],
        executionIndex: Int,
        requireTrend: Bool
    ) -> DayKHighSpeed002Signal? {
        guard bars.indices.contains(executionIndex), executionIndex > trendLookback else { return nil }
        let current = bars[executionIndex]
        let previous = bars[executionIndex - 1]
        guard current.open.isFinite, current.open > 0,
              let trendSMA = simpleMovingAverage(
                bars: bars,
                endingBefore: executionIndex,
                lookback: trendLookback
              ),
              let atr = averageTrueRangeBeforeCompressionBar(
                bars: bars,
                executionIndex: executionIndex,
                lookback: atrLookback
              ),
              let previousTrueRange = trueRange(bars: bars, at: executionIndex - 1) else { return nil }

        if requireTrend, previous.close <= trendSMA { return nil }
        guard previousTrueRange <= compressionATRMultiple * atr else { return nil }
        let range = previous.high - previous.low
        guard range > 0 else { return nil }
        let closeLocation = (previous.close - previous.low) / range
        guard closeLocation >= minimumCloseLocation else { return nil }
        let takeProfitPrice = current.open + takeProfitATRMultiple * atr
        guard takeProfitPrice.isFinite, takeProfitPrice > current.open else { return nil }
        return DayKHighSpeed002Signal(
            previousClose: previous.close,
            trendSMA: trendSMA,
            atr: atr,
            previousTrueRange: previousTrueRange,
            previousCloseLocation: closeLocation,
            takeProfitPrice: takeProfitPrice
        )
    }
}
