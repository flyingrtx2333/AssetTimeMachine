import Foundation

@main
enum AnnualWinner001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let dates = [
            "2024-01-02", "2024-06-28", "2024-12-31",
            "2025-01-02", "2025-06-30", "2025-12-31",
            "2026-01-02"
        ]
        let prices: [String: [Double]] = [
            "gold_cny": [100, 110, 120, 120, 118, 121, 121],
            "nasdaq": [100, 120, 140, 140, 160, 182, 182],
            "sp500": [100, 108, 116, 116, 125, 128, 128],
            "csi300": [100, 95, 90, 90, 94, 99, 99],
            "shanghai_composite": [100, 102, 103, 103, 101, 100, 100]
        ]
        let symbols = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]

        let winner2025 = AnnualWinner001Logic.winner(
            executionDateKey: "2025-01-02",
            signalIndex: 2,
            dateKeys: dates,
            pricesBySymbol: prices,
            symbols: symbols
        )
        require(winner2025 == "nasdaq", "2024 winner must own 2025")

        let winner2026 = AnnualWinner001Logic.winner(
            executionDateKey: "2026-01-02",
            signalIndex: 5,
            dateKeys: dates,
            pricesBySymbol: prices,
            symbols: symbols
        )
        require(winner2026 == "nasdaq", "2025 winner must own 2026")

        var futureChanged = prices
        futureChanged["gold_cny"]![6] = 9_999
        let invariant = AnnualWinner001Logic.winner(
            executionDateKey: "2026-01-02",
            signalIndex: 5,
            dateKeys: dates,
            pricesBySymbol: futureChanged,
            symbols: symbols
        )
        require(invariant == winner2026, "current execution-date future price must not affect prior-year selection")

        let allNegative: [String: [Double]] = Dictionary(uniqueKeysWithValues: symbols.map { symbol in
            (symbol, [100, 95, 90, 90, 85, 80, 80])
        })
        let cash = AnnualWinner001Logic.winner(
            executionDateKey: "2026-01-02",
            signalIndex: 5,
            dateKeys: dates,
            pricesBySymbol: allNegative,
            symbols: symbols
        )
        require(cash == nil, "all-negative prior year must select cash")
        print("ANNUAL_WINNER_001_LOGIC_TEST_OK")
    }
}
