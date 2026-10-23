import XCTest
import AssetTimeMachineResearchSupport

final class SingleIndicatorScreenTests: XCTestCase {
    private func dates(_ count: Int) -> [Date] { (0..<count).map { Date(timeIntervalSince1970: Double($0) * 86400) } }

    func testHandEntryExitAndPopulationBands() throws {
        let d = dates(25)
        // 20 flat closes, fall below band, partial recovery, cross middle.
        let p = Array(repeating: 100.0, count: 18) + [99, 101, 80, 90, 100, 100, 100]
        let down = try SingleIndicatorScreen.signals(dates: d, prices: p, rule: .lowerDowncross, start: d[0])
        let reentry = try SingleIndicatorScreen.signals(dates: d, prices: p, rule: .lowerReentry, start: d[0])
        XCTAssertEqual(down[20].middle!, 99, accuracy: 1e-12)
        XCTAssertEqual(down[20].lower!, 99 - 2 * sqrt(19.1), accuracy: 1e-12)
        XCTAssertEqual(down[20].weight, 1)
        XCTAssertEqual(down[21].weight, 1)
        XCTAssertEqual(down[22].weight, 0)
        XCTAssertEqual(reentry[20].weight, 0)
        XCTAssertEqual(reentry[21].weight, 1)
        XCTAssertEqual(reentry[22].weight, 0)
        let rally = Array(repeating: 100.0, count: 18) + [101, 99, 120, 110, 100, 100, 100]
        let breakout = try SingleIndicatorScreen.signals(dates: d, prices: rally, rule: .upperBreakout, start: d[0])
        XCTAssertEqual(breakout[20].weight, 1)
        XCTAssertEqual(breakout[21].weight, 1)
        XCTAssertEqual(breakout[22].weight, 0)
        let late = try SingleIndicatorScreen.signals(dates: d, prices: p, rule: .lowerDowncross, start: d[21])
        XCTAssertEqual(late[20].weight, 0)
        XCTAssertEqual(late[21].weight, 0)
    }

    func testFutureTruncationAndPerturbationLeaveAllPastSignalsIdentical() throws {
        let d = dates(500), p = (0..<500).map { 100 + Double($0) * 0.01 + 20 * sin(Double($0) / 6) }
        for rule in SingleIndicatorScreen.Rule.allCases {
            let original = try SingleIndicatorScreen.signals(dates: d, prices: p, rule: rule, start: d[40])
            let prefix = try SingleIndicatorScreen.signals(dates: Array(d.prefix(320)), prices: Array(p.prefix(320)), rule: rule, start: d[40])
            let changed = try SingleIndicatorScreen.signals(dates: d, prices: p.enumerated().map { $0.offset < 320 ? $0.element : $0.element * 100 }, rule: rule, start: d[40])
            XCTAssertEqual(Array(original.prefix(320)), prefix)
            XCTAssertEqual(Array(original.prefix(320)), Array(changed.prefix(320)))
            XCTAssertTrue(original.contains { $0.weight == 1 })
        }
    }
}
