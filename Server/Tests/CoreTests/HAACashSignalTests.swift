import XCTest
import AssetTimeMachineResearchSupport
import AssetTimeMachineBacktestCore

final class HAACashSignalTests: XCTestCase {
    private var monthlyDates: [String] {
        let calendar = BacktestSeriesAlignment.historicalSeriesCalendar
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2000-01-20")!
        return (0..<30).map { BacktestSeriesAlignment.historicalSeriesDateString(from: calendar.date(byAdding: .month, value: $0, to: start)!) }
    }
    private func indices(tipGrowth: Double = 0.01, spyGrowth: Double = 0.02,
                         defensiveGrowth: Double = 0.002) -> [String: [Double]] {
        let days = monthlyDates
        return ["TIP": days.indices.map { 100 * exp(Double($0) * tipGrowth) },
                "SPY": days.indices.map { 100 * exp(Double($0) * spyGrowth) },
                "IEF": days.indices.map { 100 * exp(Double($0) * defensiveGrowth) },
                "BIL": Array(repeating: 100, count: days.count)]
    }
    func testPublished13612EqualWeightsStrictCanaryAndAbsoluteRule() throws {
        let schedule = try HAACashScreen.signals(dates: monthlyDates, indicesBySymbol: indices())
        XCTAssertEqual(schedule.first!.executionDate, monthlyDates[13])
        XCTAssertEqual(schedule.first!.signalDate, monthlyDates[12])
        XCTAssertEqual(schedule.first!.selected, "SPY")
        XCTAssertEqual(schedule.first!.momentum["SPY"]!, [1, 3, 6, 12].reduce(0.0) { $0 + (exp(Double($1) * 0.02) - 1) / 4 }, accuracy: 1e-12)
        XCTAssertEqual(try HAACashScreen.signals(dates: monthlyDates, indicesBySymbol: indices(tipGrowth: 0)).first!.selected, "IEF")
        XCTAssertEqual(try HAACashScreen.signals(dates: monthlyDates, indicesBySymbol: indices(spyGrowth: -0.01)).first!.selected, "IEF")
        XCTAssertEqual(try HAACashScreen.signals(dates: monthlyDates, indicesBySymbol: indices(tipGrowth: 0, defensiveGrowth: 0)).first!.selected, "BIL")
    }
    func testExCashAndEffectiveSplitNormalizeSignalWithoutFutureRewrite() throws {
        let days = (1...15).map { String(format: "2026-01-%02d", $0) }
        let closes = [100.0, 100.0, 99.0] + Array(repeating: 198.0, count: 12)
        let values = try HAACashScreen.totalReturnIndex(dates: days, closes: closes,
            distributionsByDate: [days[2]: 1], splitRatiosByDate: [days[3]: 0.5])
        for value in values { XCTAssertEqual(value, 100, accuracy: 1e-12) }
        var later = indices()
        for symbol in later.keys { later[symbol]![25] *= 10 }
        let original = try HAACashScreen.signals(dates: monthlyDates, indicesBySymbol: indices())
        let poisoned = try HAACashScreen.signals(dates: monthlyDates, indicesBySymbol: later)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(Array(original.prefix(12))), try encoder.encode(Array(poisoned.prefix(12))))
    }
}
