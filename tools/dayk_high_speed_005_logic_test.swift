import Foundation

@main
enum DayKHighSpeed005LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        var bars = (0..<210).map { index -> DayKHighSpeed005Bar in
            let close = 100.0 + Double(index) * 0.10
            return .init(open: close - 0.05, high: close + 0.60, low: close - 0.60, close: close)
        }
        let base = bars[207].close
        bars[208] = .init(open: base + 0.10, high: base + 0.20, low: base - 0.80, close: base - 0.65)
        bars[209] = .init(open: base - 0.65, high: base - 0.30, low: base - 1.60, close: base - 1.35)
        bars.append(.init(open: base - 1.25, high: base, low: base - 1.50, close: base - 0.20))

        let candidate = DayKHighSpeed005Logic.signal(
            bars: bars, executionIndex: 210, minimumVotes: DayKHighSpeed005Logic.minimumFactorVotes
        )
        require(candidate != nil, "deep uptrend pullback with at least two votes must trigger")
        require(candidate!.factorVotes >= 2, "candidate requires at least two factor votes")
        require(candidate!.trendAlignmentVote, "aligned 50/200 trend should vote")
        require(candidate!.oversoldVote, "three-session RSI should identify the pullback")

        var weakFactors = bars
        for index in 150..<207 {
            let close = 120.0 - Double(index - 150) * 0.02
            weakFactors[index] = .init(open: close, high: close + 0.60, low: close - 0.60, close: close)
        }
        let baseControl = DayKHighSpeed005Logic.signal(bars: weakFactors, executionIndex: 210, minimumVotes: 0)
        let filtered = DayKHighSpeed005Logic.signal(bars: weakFactors, executionIndex: 210, minimumVotes: 4)
        require(baseControl != nil, "matched base control must retain the core pullback setup")
        require(filtered == nil, "insufficient factor votes must filter the candidate")

        var currentPathChanged = bars
        currentPathChanged[210] = .init(open: bars[210].open, high: bars[210].high + 50, low: bars[210].low - 50, close: bars[210].close - 20)
        let changed = DayKHighSpeed005Logic.signal(
            bars: currentPathChanged, executionIndex: 210, minimumVotes: DayKHighSpeed005Logic.minimumFactorVotes
        )
        require(changed != nil, "execution-day path must not affect factor votes")
        require(changed!.factorVotes == candidate!.factorVotes, "all votes must end at T-1")
        require(abs(changed!.takeProfitPrice - candidate!.takeProfitPrice) < 1e-12, "target must be frozen at the open")

        print("DAYK_HIGH_SPEED_005_LOGIC_TEST_OK")
    }
}
