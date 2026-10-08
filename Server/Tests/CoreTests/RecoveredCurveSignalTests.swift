import XCTest
@testable import AssetTimeMachineResearchSupport

final class RecoveredCurveSignalTests: XCTestCase {
    func testOriginalFrozenSignalContract() throws {
        XCTAssertEqual(try CurveSignals.selfTest(),18)
    }
    func testOnlyLatestJointPriorObservationAndStalenessAreUsable() throws {
        let rows=[CurveRow(date:"2007-12-28",vix:30,vix3m:20),CurveRow(date:"2008-01-02",vix:10,vix3m:20)]
        XCTAssertEqual(try CurveSignals.known(rows,before:"2008-01-02"),rows[0])
        XCTAssertEqual(try CurveSignals.known(rows,before:"2008-01-03"),rows[1])
        XCTAssertNil(try CurveSignals.known(rows,before:"2008-01-10"))
        let poisoned=rows+[CurveRow(date:"2099-01-01",vix:999,vix3m:1)]
        XCTAssertEqual(try CurveSignals.known(poisoned,before:"2008-01-03"),rows[1])
    }
}
