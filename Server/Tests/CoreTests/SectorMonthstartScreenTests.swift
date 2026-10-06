import XCTest
@testable import AssetTimeMachineResearchSupport
import AssetTimeMachineBacktestCore

final class SectorMonthstartScreenTests: XCTestCase {
    private func series(count: Int = 80, shockAt: Int? = nil) -> [SectorMonthstartScreen.Series] {
        let first = BacktestSeriesAlignment.historicalSeriesDate(from: "2025-01-01")!
        let calendar = BacktestSeriesAlignment.historicalSeriesCalendar
        return (0..<9).map { j in
            let bars = (0..<count).map { i -> SectorMonthstartScreen.Bar in
                let d = first.addingTimeInterval(Double(i) * 86400)
                let c = calendar.dateComponents([.year, .month, .day], from: d)
                let date = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
                let p = shockAt.map { i >= $0 ? 10.0 : 100 + Double(i * j) } ?? (100 + Double(i * j))
                return .init(date: date, open: p, high: p + 1, low: p - 1, close: p)
            }
            return .init(symbol: "S\(j)", bars: bars)
        }
    }

    func testRankingKnownAtPriorMonthEndAndTwoSessionWindow() throws {
        let s = series()
        let targets = try SectorMonthstartScreen.targets(series: s, lookback: 5)
        XCTAssertTrue(targets[30].isEmpty)
        XCTAssertEqual(Set(targets[31].keys), Set(["S0", "S1", "S2"]))
        XCTAssertEqual(targets[31], targets[32])
        XCTAssertTrue(targets[33].isEmpty)
        XCTAssertTrue(targets[34].isEmpty)
        XCTAssertEqual(targets[31].values.reduce(0, +), 1, accuracy: 1e-12)
        let top = try SectorMonthstartScreen.targets(series: s, lookback: 5, selection: "top")
        XCTAssertEqual(Set(top[31].keys), Set(["S6", "S7", "S8"]))
        let all = try SectorMonthstartScreen.targets(series: s, lookback: 5, selection: "all")
        XCTAssertEqual(all[31].count, 9)
    }

    func testFutureChangeAndTruncationDoNotChangeEarlierTargets() throws {
        let full = try SectorMonthstartScreen.targets(series: series(), lookback: 5)
        let prefix = try SectorMonthstartScreen.targets(series: series(count: 50), lookback: 5)
        let shocked = try SectorMonthstartScreen.targets(series: series(shockAt: 50), lookback: 5)
        XCTAssertEqual(Array(full.prefix(50)), prefix)
        XCTAssertEqual(Array(full.prefix(50)), Array(shocked.prefix(50)))
        let monthFirstShock = try SectorMonthstartScreen.targets(series: series(shockAt: 31), lookback: 5)
        XCTAssertEqual(full[31], monthFirstShock[31])
    }

    func testWarmupDoesNotInventMomentumOrExceedCapital() throws {
        let targets = try SectorMonthstartScreen.targets(series: series())
        XCTAssertTrue(targets.allSatisfy(\.isEmpty))
    }

    func testMissingDuplicateAndInvalidPriceFail() throws {
        let s = series()
        XCTAssertThrowsError(try SectorMonthstartScreen.targets(series: [s[0], s[0], s[1]]))
        XCTAssertThrowsError(try SectorMonthstartScreen.targets(series: s, selection: "optimize"))
        let shortened = Array(s.dropLast()) + [.init(symbol: "S8", bars: Array(s[8].bars.dropLast()))]
        XCTAssertThrowsError(try SectorMonthstartScreen.targets(series: shortened))
        let invalid = [.init(symbol: "S0", bars: [.init(date: "bad", open: 0, high: 0, low: 0, close: 0)])] as [SectorMonthstartScreen.Series]
        XCTAssertThrowsError(try SectorMonthstartScreen.targets(series: invalid))
    }

    func testFXIgnoresSameDateAndRejectsStaleOrFutureOnly() throws {
        XCTAssertEqual(try SectorMonthstartScreen.priorFX(dates: ["2026-01-02", "2026-01-05"],
            prices: [0.14, 100], asOf: "2026-01-05"), 0.14)
        XCTAssertThrowsError(try SectorMonthstartScreen.priorFX(dates: ["2026-01-05"], prices: [0.14], asOf: "2026-01-05"))
        XCTAssertThrowsError(try SectorMonthstartScreen.priorFX(dates: ["2025-12-01"], prices: [0.14], asOf: "2026-01-05"))
    }
}
