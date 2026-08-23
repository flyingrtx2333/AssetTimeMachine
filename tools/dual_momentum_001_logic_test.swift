import Foundation

@main
enum DualMomentum001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let count = 254
        var nasdaq = Array(repeating: 100.0, count: count)
        var gold = Array(repeating: 100.0, count: count)
        nasdaq[0] = 100; nasdaq[252] = 130
        gold[0] = 100; gold[252] = 115
        let owner = DualMomentum001Logic.owner(
            signalIndex: 252,
            pricesBySymbol: ["nasdaq": nasdaq, "gold_cny": gold],
            symbols: ["nasdaq", "gold_cny"]
        )
        require(owner == "nasdaq", "higher positive 252-session momentum must win")

        nasdaq[252] = 90; gold[252] = 105
        require(DualMomentum001Logic.owner(
            signalIndex: 252,
            pricesBySymbol: ["nasdaq": nasdaq, "gold_cny": gold],
            symbols: ["nasdaq", "gold_cny"]
        ) == "gold_cny", "positive gold must win when Nasdaq momentum is negative")

        gold[252] = 95
        require(DualMomentum001Logic.owner(
            signalIndex: 252,
            pricesBySymbol: ["nasdaq": nasdaq, "gold_cny": gold],
            symbols: ["nasdaq", "gold_cny"]
        ) == nil, "all-negative momentum must select cash")

        var futureChanged = nasdaq
        futureChanged[253] = 10_000
        require(DualMomentum001Logic.owner(
            signalIndex: 252,
            pricesBySymbol: ["nasdaq": futureChanged, "gold_cny": gold],
            symbols: ["nasdaq", "gold_cny"]
        ) == nil, "execution/future price after signalIndex must not affect ownership")
        print("DUAL_MOMENTUM_001_LOGIC_TEST_OK")
    }
}
