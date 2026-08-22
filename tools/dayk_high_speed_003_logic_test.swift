import Foundation

@main
enum DayKHighSpeed003LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        var rising = (0..<210).map { index -> DayKHighSpeed003Bar in
            let close = 100.0 + Double(index) * 0.10
            return .init(open: close - 0.05, high: close + 0.60, low: close - 0.60, close: close)
        }
        let base = rising[207].close
        rising[208] = .init(open: base, high: base + 0.25, low: base - 0.75, close: base - 0.60)
        rising[209] = .init(open: base - 0.60, high: base - 0.35, low: base - 1.55, close: base - 1.35)
        rising.append(.init(open: base - 1.25, high: base, low: base - 1.50, close: base - 0.20))

        let signal = DayKHighSpeed003Logic.signal(bars: rising, executionIndex: 210, requireTrend: true)
        require(signal != nil, "two-session ATR pullback above SMA200 must trigger")
        require(signal!.twoSessionPullback >= signal!.atr, "pullback must be at least one ATR")
        require(signal!.takeProfitPrice > rising[210].open, "take-profit must be frozen above entry")

        var shallow = rising
        shallow[209] = .init(open: base - 0.10, high: base + 0.20, low: base - 0.30, close: base - 0.15)
        require(DayKHighSpeed003Logic.signal(bars: shallow, executionIndex: 210, requireTrend: true) == nil, "shallow pullback must not trigger")

        var falling = (0..<210).map { index -> DayKHighSpeed003Bar in
            let close = 140.0 - Double(index) * 0.10
            return .init(open: close + 0.05, high: close + 0.60, low: close - 0.60, close: close)
        }
        let fallingBase = falling[207].close
        falling[208] = .init(open: fallingBase, high: fallingBase + 0.2, low: fallingBase - 0.8, close: fallingBase - 0.6)
        falling[209] = .init(open: fallingBase - 0.6, high: fallingBase - 0.3, low: fallingBase - 1.6, close: fallingBase - 1.4)
        falling.append(.init(open: fallingBase - 1.3, high: fallingBase, low: fallingBase - 1.5, close: fallingBase - 0.4))
        require(DayKHighSpeed003Logic.signal(bars: falling, executionIndex: 210, requireTrend: true) == nil, "falling trend must be filtered")
        require(DayKHighSpeed003Logic.signal(bars: falling, executionIndex: 210, requireTrend: false) != nil, "matched pullback control must remove only trend gate")

        var currentPathChanged = rising
        currentPathChanged[210] = .init(open: rising[210].open, high: rising[210].high + 50, low: rising[210].low - 50, close: rising[210].close - 20)
        let changed = DayKHighSpeed003Logic.signal(bars: currentPathChanged, executionIndex: 210, requireTrend: true)
        require(changed != nil, "execution-day path must not affect the entry signal")
        require(abs(changed!.atr - signal!.atr) < 1e-12, "ATR must exclude execution-day range")
        require(abs(changed!.takeProfitPrice - signal!.takeProfitPrice) < 1e-12, "profit target must depend only on entry open and prior ATR")

        print("DAYK_HIGH_SPEED_003_LOGIC_TEST_OK")
    }
}
