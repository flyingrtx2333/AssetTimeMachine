import XCTest
import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport

final class FOMCCycleTests: XCTestCase {
    private func date(_ s: String) -> Date { BacktestSeriesAlignment.historicalSeriesDate(from: s)! }
    private func schedule(_ versions: [[String: Any]]) throws -> FOMCCycleScreen.Schedule {
        try .init(data: JSONSerialization.data(withJSONObject: ["versions": versions]))
    }
    private func event(_ id: String = "a", day: String = "2024-01-31",
                       available: String = "2023-06-01", cancelled: Bool = false) -> [String: Any] {
        ["event_id": id, "date": day, "available_date": available, "cancelled": cancelled]
    }

    func testNaturalWeekBoundariesAndExpiry() throws {
        let s = try schedule([event()])
        for (day, expected) in [("2024-01-29", 0.0), ("2024-01-30", 1), ("2024-01-31", 1),
            ("2024-02-05", 1), ("2024-02-06", 0), ("2024-02-12", 0), ("2024-02-13", 1),
            ("2024-02-19", 1), ("2024-02-20", 0), ("2024-02-27", 1),
            ("2024-03-12", 1), ("2024-03-18", 1), ("2024-03-19", 0), ("2024-04-01", 0)] {
            XCTAssertEqual(s.weight(on: date(day), asOf: date("2024-01-02")), expected, day)
        }
        XCTAssertEqual(s.weight(on: date("2024-02-03"), asOf: date("2024-01-02")), 0)
    }

    func testHolidayCountsInPhaseAndOddControlIsComplementWithinCycle() throws {
        let s = try schedule([event()])
        // Presidents Day is not removed from the paper's weekday clock.
        XCTAssertEqual(s.weight(on: date("2024-02-19"), asOf: date("2024-02-16")), 1)
        XCTAssertEqual(s.weight(on: date("2024-02-20"), asOf: date("2024-02-16"), oddControl: true), 1)
        XCTAssertEqual(s.weight(on: date("2024-02-20"), asOf: date("2024-02-16")), 0)
        XCTAssertEqual(s.weight(on: date("2024-04-01"), asOf: date("2024-03-29"), oddControl: true), 0)
    }

    func testFutureVersionCannotChangePastAndCancellationBecomesEffective() throws {
        let original = try schedule([event()])
        let revised = try schedule([event(), event(available: "2024-01-30", cancelled: true)])
        XCTAssertEqual(original.weight(on: date("2024-01-30"), asOf: date("2024-01-29")),
                       revised.weight(on: date("2024-01-30"), asOf: date("2024-01-29")))
        XCTAssertEqual(revised.weight(on: date("2024-01-31"), asOf: date("2024-01-30")), 0)
        XCTAssertEqual(revised.weight(on: date("2024-01-30"), asOf: date("2024-01-30")), 0)
    }

    func testDatedRevisionReplacesOriginalMeetingAndNextMeetingResetsCycle() throws {
        let s = try schedule([event(), event(day: "2024-02-01", available: "2024-01-29"),
                              event("b", day: "2024-02-20")])
        XCTAssertEqual(s.weight(on: date("2024-01-30"), asOf: date("2024-01-29")), 0)
        XCTAssertEqual(s.weight(on: date("2024-02-01"), asOf: date("2024-01-31")), 1)
        XCTAssertEqual(s.weight(on: date("2024-02-19"), asOf: date("2024-02-16")), 1)
    }

    func testMissingOrMalformedSchedulesFail() throws {
        XCTAssertThrowsError(try schedule([]))
        XCTAssertThrowsError(try schedule([event(day: "invalid")]))
        XCTAssertThrowsError(try schedule([event(day: "2024-02-03")]))
        XCTAssertThrowsError(try schedule([event(), event()]))
        let unavailable = try schedule([event(available: "2024-02-01")])
        XCTAssertEqual(unavailable.weight(on: date("2024-01-31"), asOf: date("2024-01-30")), 0)
    }
}
