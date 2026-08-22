import Foundation

@main
enum DayKHighSpeed006LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1)
        }
    }

    static func main() {
        var bars = (0..<210).map { index -> DayKHighSpeed006Bar in
            let close = 100.0 + Double(index) * 0.08
            return .init(open: close - 0.05, high: close + 0.55, low: close - 0.55, close: close)
        }
        bars.append(.init(open: bars[209].close + 0.05, high: bars[209].close + 0.8, low: bars[209].close - 0.4, close: bars[209].close + 0.5))
        let signal = DayKHighSpeed006Logic.signal(bars: bars, executionIndex: 210)
        require(signal != nil, "three consecutive rising closes above SMA200 must trigger")
        require(signal!.initialStopPrice < bars[210].open, "initial stop must be below entry")

        var broken = bars
        broken[208] = .init(open: broken[208].open, high: broken[208].high, low: broken[208].low, close: broken[207].close - 0.1)
        require(DayKHighSpeed006Logic.signal(bars: broken, executionIndex: 210) == nil, "broken consecutive rise must not trigger")

        var pathChanged = bars
        pathChanged[210] = .init(open: bars[210].open, high: bars[210].high + 50, low: bars[210].low - 50, close: bars[210].close - 20)
        let unchanged = DayKHighSpeed006Logic.signal(bars: pathChanged, executionIndex: 210)
        require(unchanged != nil, "entry-day path must not affect the open signal")
        require(abs(unchanged!.initialStopPrice - signal!.initialStopPrice) < 1e-12, "initial stop must be frozen at entry")

        let raised = DayKHighSpeed006Logic.updatedTrailingStop(
            bars: bars, completedIndex: 210, highestCompletedClose: bars[210].close, previousStop: signal!.initialStopPrice
        )
        require(raised != nil && raised! >= signal!.initialStopPrice, "trailing stop must never decrease")
        print("DAYK_HIGH_SPEED_006_LOGIC_TEST_OK")
    }
}
