import Foundation

@main
enum ShortMomentum001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let dates = [
            "2026-01-30",
            "2026-02-02", "2026-02-13", "2026-02-27",
            "2026-03-02", "2026-03-31",
            "2026-04-01"
        ]
        let symbols = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
        let prices: [String: [Double]] = [
            "gold_cny": [100, 101, 103, 105, 105, 106, 106],
            "nasdaq": [100, 101, 108, 112, 112, 113, 113],
            "sp500": [100, 100, 103, 106, 106, 107, 107],
            "csi300": [100, 99, 98, 97, 97, 98, 98],
            "shanghai_composite": [100, 100, 101, 102, 102, 103, 103]
        ]

        let marchOwner = ShortMomentum001Logic.owner(
            signalIndex: 3,
            dateKeys: dates,
            pricesBySymbol: prices,
            symbols: symbols
        )
        require(marchOwner == "nasdaq", "February close-to-close leader must own March")

        var futureChanged = prices
        futureChanged["gold_cny"]![4] = 10_000
        futureChanged["gold_cny"]![5] = 20_000
        futureChanged["gold_cny"]![6] = 30_000
        let invariant = ShortMomentum001Logic.owner(
            signalIndex: 3,
            dateKeys: dates,
            pricesBySymbol: futureChanged,
            symbols: symbols
        )
        require(invariant == marchOwner, "future-month prices must not affect prior-month selection")

        let allNegative = Dictionary(uniqueKeysWithValues: symbols.map { symbol in
            (symbol, [100.0, 99.0, 97.0, 95.0, 95.0, 94.0, 94.0])
        })
        let cashOwner = ShortMomentum001Logic.owner(
            signalIndex: 3,
            dateKeys: dates,
            pricesBySymbol: allNegative,
            symbols: symbols
        )
        require(cashOwner == nil, "all-negative prior month must select cash")

        require(
            ShortMomentum001Logic.owner(
                signalIndex: 0,
                dateKeys: dates,
                pricesBySymbol: prices,
                symbols: symbols
            ) == nil,
            "owner requires a complete prior month base close"
        )
        print("SHORT_MOMENTUM_001_LOGIC_TEST_OK")
    }
}
