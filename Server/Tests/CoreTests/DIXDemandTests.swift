import XCTest
import AssetTimeMachineResearchSupport

final class DIXDemandTests: XCTestCase {
    func testLagSixtyOpenIntervalsAndExitBeforeReentry() throws {
        var factor = Array<Double?>(repeating: 0.46, count: 66)
        factor[1] = 0.1
        let d = try DIXDemandScreen.decisions(dix: factor, firstExecutionIndex: 2)
        XCTAssertEqual(d[2].sourceIndex, 0); XCTAssertEqual(d[2].event, "enter")
        XCTAssertEqual(d[2].observation, 0.46)
        XCTAssertTrue(d[3..<62].allSatisfy { $0.weight == 1 && $0.event == "hold" })
        XCTAssertEqual(d[62].event, "exit"); XCTAssertEqual(d[62].weight, 0)
        XCTAssertEqual(d[63].event, "enter"); XCTAssertEqual(d[63].weight, 1)
    }

    func testPrefixThresholdComplementAndMissingDataError() throws {
        let factor: [Double?] = [nil, nil, 0.45, 0.449, 0.1, 0.99, 0.4, 0.3]
        let full = try DIXDemandScreen.decisions(dix: factor, firstExecutionIndex: 4)
        let prefix = try DIXDemandScreen.decisions(dix: Array(factor.prefix(6)), firstExecutionIndex: 4)
        XCTAssertEqual(Array(full.prefix(6)), prefix)
        let changed = try DIXDemandScreen.decisions(dix: Array(factor.prefix(4)) + [0.99, 0.01, 0.99, 0.01], firstExecutionIndex: 4)
        XCTAssertEqual(Array(changed.prefix(6)), prefix)
        XCTAssertEqual(full[4].event, "enter") // inclusive45% author threshold
        let inverse = try DIXDemandScreen.decisions(dix: factor, firstExecutionIndex: 4, inverse: true)
        XCTAssertEqual(inverse[4].weight, 0); XCTAssertEqual(inverse[5].event, "enter")
        XCTAssertThrowsError(try DIXDemandScreen.decisions(dix: [0.4, nil, 0.4, 0.4], firstExecutionIndex: 2))
    }
}
