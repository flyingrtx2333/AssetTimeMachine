import XCTest
import AssetTimeMachineResearchSupport

final class PublishedRuleScreenTests: XCTestCase {
    func testFuturePriceChangesDoNotChangeEarlierRSITargets() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1577836800)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let dates = (0..<500).map { formatter.string(from: calendar.date(byAdding: .day, value: $0, to: start)!) }
        let prices = (0..<500).map { 100 + Double($0) * 0.08 + sin(Double($0) / 4) * 3 }
        let original = try PublishedRuleScreen.signals(dates: dates, prices: prices)
        let prefix = try PublishedRuleScreen.signals(dates: Array(dates.prefix(320)), prices: Array(prices.prefix(320)))
        let changed = try PublishedRuleScreen.signals(dates: dates,
            prices: prices.enumerated().map { $0.offset < 320 ? $0.element : $0.element * 20 })
        for date in dates.prefix(320) {
            XCTAssertEqual(original.rsi2DesiredByDate[date], prefix.rsi2DesiredByDate[date])
            XCTAssertEqual(original.rsi2DesiredByDate[date], changed.rsi2DesiredByDate[date])
        }
        XCTAssertTrue(original.rsi2DesiredByDate.values.contains(1))
        XCTAssertTrue(original.rsi2DesiredByDate.values.contains(0))
    }

    func testFaberCannotReadTheExecutionMonthOrLaterCloses() {
        let previous = (1...10).map { (month: String(format: "2020-%02d", $0), close: 100 + Double($0)) }
        let weight = PublishedRuleScreen.faberWeight(executionMonth: "2020-11", months: previous)
        XCTAssertEqual(weight, 1)
        XCTAssertEqual(weight, PublishedRuleScreen.faberWeight(executionMonth: "2020-11",
            months: previous + [(month: "2020-11", close: 0.1), (month: "2020-12", close: 10000)]))
        XCTAssertEqual(PublishedRuleScreen.faberWeight(executionMonth: "2020-10", months: previous), 0)
    }
}
