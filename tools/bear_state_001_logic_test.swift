import Foundation

@main
enum BearState001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
    }
    static func main() {
        var normal = (0..<254).map { 100.0 + Double($0) * 0.10 }
        require(BearState001Logic.owner(nasdaqPrices: normal, signalIndex: 252) == "nasdaq", "near-high state must own Nasdaq")
        var bear = normal
        let peak = bear[220]
        for i in 221...252 { bear[i] = peak * (1.0 - 0.21 * Double(i - 220) / 32.0) }
        require(BearState001Logic.owner(nasdaqPrices: bear, signalIndex: 252) == "gold_cny", "20%+ drawdown must own gold")
        let before = BearState001Logic.owner(nasdaqPrices: bear, signalIndex: 252)
        bear[253] = 10_000
        require(BearState001Logic.owner(nasdaqPrices: bear, signalIndex: 252) == before, "future execution price must not affect T-1 state")
        require(BearState001Logic.owner(nasdaqPrices: normal, signalIndex: 200) == nil, "insufficient 252-session history must not emit state")
        print("BEAR_STATE_001_LOGIC_TEST_OK")
    }
}
