import Foundation

@main
enum FaberGTAA001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let dates = [
            "2025-05-30", "2025-06-30", "2025-07-31", "2025-08-29", "2025-09-30",
            "2025-10-31", "2025-11-28", "2025-12-31", "2026-01-30", "2026-02-27",
            "2026-03-02", "2026-03-31", "2026-04-01"
        ]
        let symbols = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
        let rising = [100.0, 102, 104, 106, 108, 110, 112, 114, 116, 120, 120, 121, 121]
        let falling = [120.0, 118, 116, 114, 112, 110, 108, 106, 104, 100, 100, 99, 99]
        let flat = [100.0, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100]
        let prices: [String: [Double]] = [
            "gold_cny": rising,
            "nasdaq": rising,
            "sp500": falling,
            "csi300": flat,
            "shanghai_composite": falling
        ]

        let active = FaberGTAA001Logic.activeSymbols(
            signalIndex: 9,
            dateKeys: dates,
            pricesBySymbol: prices,
            symbols: symbols
        )
        require(active != nil, "ten completed month-end observations must be enough")
        require(active!.contains("gold_cny") && active!.contains("nasdaq"), "rising assets must be active")
        require(!active!.contains("sp500") && !active!.contains("shanghai_composite"), "falling assets must be inactive")
        require(!active!.contains("csi300"), "price equal to SMA must remain inactive under strict > rule")

        var futureChanged = prices
        futureChanged["sp500"]![10] = 10_000
        futureChanged["sp500"]![11] = 20_000
        futureChanged["sp500"]![12] = 30_000
        let invariant = FaberGTAA001Logic.activeSymbols(
            signalIndex: 9,
            dateKeys: dates,
            pricesBySymbol: futureChanged,
            symbols: symbols
        )
        require(invariant == active, "future-month prices must not affect completed-month signal")

        require(
            FaberGTAA001Logic.activeSymbols(
                signalIndex: 7,
                dateKeys: dates,
                pricesBySymbol: prices,
                symbols: symbols
            ) == nil,
            "fewer than ten completed month ends must not produce a signal"
        )
        print("FABER_GTAA_001_LOGIC_TEST_OK")
    }
}
