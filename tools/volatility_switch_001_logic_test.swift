import Foundation

@main
enum VolatilitySwitch001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        var calm = (0..<254).map { 100.0 + Double($0) * 0.05 }
        require(VolatilitySwitch001Logic.owner(nasdaqPrices: calm, signalIndex: 252) == "nasdaq", "calm regime must own Nasdaq")

        var stressed = calm
        for i in 232...252 {
            stressed[i] += (i % 2 == 0 ? 8.0 : -8.0)
        }
        require(VolatilitySwitch001Logic.owner(nasdaqPrices: stressed, signalIndex: 252) == "gold_cny", "recent volatility spike must own gold")

        let before = VolatilitySwitch001Logic.owner(nasdaqPrices: stressed, signalIndex: 252)
        stressed[253] = 10_000
        require(VolatilitySwitch001Logic.owner(nasdaqPrices: stressed, signalIndex: 252) == before, "future execution price must not affect T-1 volatility state")

        require(VolatilitySwitch001Logic.owner(nasdaqPrices: calm, signalIndex: 200) == nil, "insufficient long window must not produce a state")
        print("VOLATILITY_SWITCH_001_LOGIC_TEST_OK")
    }
}
