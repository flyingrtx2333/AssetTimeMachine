import Foundation

@main
enum DayKHighSpeed001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        var rising = (0..<60).map { index -> DayKHighSpeed001Bar in
            let close = 100.0 + Double(index) * 0.20
            return DayKHighSpeed001Bar(open: close - 0.05, high: close + 0.50, low: close - 0.50, close: close)
        }
        let priorClose = rising.last!.close
        rising.append(.init(open: priorClose - 0.40, high: priorClose + 1.0, low: priorClose - 0.60, close: priorClose + 0.20))
        let signal = DayKHighSpeed001Logic.signal(bars: rising, executionIndex: 60, requireTrend: true)
        require(signal != nil, "rising-trend gap must trigger")
        require(abs(signal!.gapDown - 0.40) < 1e-10, "gap must use today's open and T-1 close")
        require(signal!.takeProfitPrice > rising[60].open, "take-profit must be above entry")

        var noGap = rising
        noGap[60] = .init(open: priorClose, high: priorClose + 1, low: priorClose - 0.5, close: priorClose + 0.2)
        require(DayKHighSpeed001Logic.signal(bars: noGap, executionIndex: 60, requireTrend: true) == nil, "flat open must not trigger")

        var falling = (0..<60).map { index -> DayKHighSpeed001Bar in
            let close = 120.0 - Double(index) * 0.20
            return DayKHighSpeed001Bar(open: close + 0.05, high: close + 0.50, low: close - 0.50, close: close)
        }
        let fallingPriorClose = falling.last!.close
        falling.append(.init(open: fallingPriorClose - 0.40, high: fallingPriorClose + 1, low: fallingPriorClose - 0.60, close: fallingPriorClose))
        require(DayKHighSpeed001Logic.signal(bars: falling, executionIndex: 60, requireTrend: true) == nil, "falling trend must be filtered")
        require(DayKHighSpeed001Logic.signal(bars: falling, executionIndex: 60, requireTrend: false) != nil, "matched gap control must ignore only the trend gate")

        var futureRangeChanged = rising
        futureRangeChanged[60] = .init(open: rising[60].open, high: rising[60].high + 50, low: rising[60].low - 50, close: rising[60].close)
        let changed = DayKHighSpeed001Logic.signal(bars: futureRangeChanged, executionIndex: 60, requireTrend: true)
        require(changed != nil, "current intraday range must not invalidate an open-time signal")
        require(abs(changed!.atr - signal!.atr) < 1e-12, "ATR must exclude today's high/low")
        require(abs(changed!.takeProfitPrice - signal!.takeProfitPrice) < 1e-12, "target must be fixed at the open")

        print("DAYK_HIGH_SPEED_001_LOGIC_TEST_OK")
    }
}
