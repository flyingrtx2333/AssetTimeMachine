import Foundation

@main
enum DayKHighSpeed002LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        var bars = (0..<60).map { index -> DayKHighSpeed002Bar in
            let close = 100.0 + Double(index) * 0.20
            return .init(open: close - 0.10, high: close + 0.55, low: close - 0.55, close: close)
        }
        let compressedClose = bars[58].close + 0.20
        bars[59] = .init(
            open: compressedClose - 0.10,
            high: compressedClose + 0.05,
            low: compressedClose - 0.35,
            close: compressedClose
        )
        bars.append(.init(open: compressedClose + 0.05, high: compressedClose + 1.0, low: compressedClose - 0.3, close: compressedClose + 0.4))
        let signal = DayKHighSpeed002Logic.signal(bars: bars, executionIndex: 60, requireTrend: true)
        require(signal != nil, "bullish compression in an uptrend must trigger")
        require(signal!.previousCloseLocation >= 0.75, "compression bar must close in its upper quartile")
        require(signal!.previousTrueRange <= 0.75 * signal!.atr, "compression must be measured against prior ATR")

        var lowClose = bars
        lowClose[59] = .init(open: compressedClose, high: compressedClose + 0.20, low: compressedClose - 0.20, close: compressedClose - 0.15)
        require(DayKHighSpeed002Logic.signal(bars: lowClose, executionIndex: 60, requireTrend: true) == nil, "weak close must not trigger")

        var wide = bars
        wide[59] = .init(open: compressedClose - 0.5, high: compressedClose + 0.5, low: compressedClose - 1.5, close: compressedClose + 0.4)
        require(DayKHighSpeed002Logic.signal(bars: wide, executionIndex: 60, requireTrend: true) == nil, "wide prior bar must not trigger")

        var falling = (0..<60).map { index -> DayKHighSpeed002Bar in
            let close = 120.0 - Double(index) * 0.20
            return .init(open: close + 0.10, high: close + 0.55, low: close - 0.55, close: close)
        }
        let fallingClose = falling[58].close - 0.20
        falling[59] = .init(open: fallingClose - 0.10, high: fallingClose + 0.05, low: fallingClose - 0.35, close: fallingClose)
        falling.append(.init(open: fallingClose, high: fallingClose + 1, low: fallingClose - 0.2, close: fallingClose + 0.3))
        require(DayKHighSpeed002Logic.signal(bars: falling, executionIndex: 60, requireTrend: true) == nil, "falling trend must be filtered")
        require(DayKHighSpeed002Logic.signal(bars: falling, executionIndex: 60, requireTrend: false) != nil, "matched control must remove only the trend gate")

        var currentIntradayChanged = bars
        currentIntradayChanged[60] = .init(open: bars[60].open, high: bars[60].high + 50, low: bars[60].low - 50, close: bars[60].close - 20)
        let changed = DayKHighSpeed002Logic.signal(bars: currentIntradayChanged, executionIndex: 60, requireTrend: true)
        require(changed != nil, "current intraday path must not affect the open signal")
        require(abs(changed!.atr - signal!.atr) < 1e-12, "ATR must exclude T-1 compression and T intraday data")
        require(abs(changed!.takeProfitPrice - signal!.takeProfitPrice) < 1e-12, "target must be fixed at the open")

        print("DAYK_HIGH_SPEED_002_LOGIC_TEST_OK")
    }
}
