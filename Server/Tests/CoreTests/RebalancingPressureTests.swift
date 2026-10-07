import XCTest
import AssetTimeMachineResearchSupport

final class RebalancingPressureTests: XCTestCase {
    func testDriftDirectionAndCashDividendContinuity() throws {
        // 60*1.1/(60*1.1+40)-.6 = 2.26415pp; clipped contrarian stays cash.
        let up = try RebalancingPressureScreen.features(equity: [100, 110], equityDividends: [0, 0],
            bonds: [100, 100], bondDividends: [0, 0])
        XCTAssertEqual(up[1].drift, 66.0 / 106 - 0.6, accuracy: 1e-14)
        XCTAssertEqual(up[1].longWeight, 0)
        XCTAssertEqual(up[1].oppositeWeight, 1)
        let exDate = try RebalancingPressureScreen.features(equity: [100, 99], equityDividends: [0, 1],
            bonds: [100, 100], bondDividends: [0, 0])
        XCTAssertEqual(exDate[1].drift, 0, accuracy: 1e-14)
        let down = try RebalancingPressureScreen.features(equity: [100, 90], equityDividends: [0, 0],
            bonds: [100, 100], bondDividends: [0, 0])
        XCTAssertEqual(down[1].longWeight, 1)
        XCTAssertEqual(down[1].oppositeWeight, 0)
    }

    func testAfterCloseResetAndPrefixCausality() throws {
        let equity = [100.0, 90, 90, 91, 92, 80]
        let bonds = Array(repeating: 100.0, count: equity.count)
        let zero = Array(repeating: 0.0, count: equity.count)
        let full = try RebalancingPressureScreen.features(equity: equity, equityDividends: zero,
            bonds: bonds, bondDividends: zero)
        // -2.55pp breaches every0..2.5pp virtual threshold; next flat day has0 drift.
        XCTAssertEqual(full[2].drift, 0, accuracy: 1e-14)
        let prefix = try RebalancingPressureScreen.features(equity: Array(equity.prefix(4)),
            equityDividends: Array(zero.prefix(4)), bonds: Array(bonds.prefix(4)), bondDividends: Array(zero.prefix(4)))
        XCTAssertEqual(Array(full.prefix(4)), prefix)
        let disturbed = try RebalancingPressureScreen.features(equity: [100, 90, 90, 91, 2000, 1],
            equityDividends: zero, bonds: bonds, bondDividends: [0, 0, 0, 0, 999, 999])
        XCTAssertEqual(Array(disturbed.prefix(4)), prefix)
        XCTAssertTrue(full.allSatisfy { (0...1).contains($0.longWeight) && (0...1).contains($0.oppositeWeight) })
        XCTAssertThrowsError(try RebalancingPressureScreen.features(equity: [100, 0], equityDividends: [0, 0],
            bonds: [100, 100], bondDividends: [0, 0]))
    }
}
