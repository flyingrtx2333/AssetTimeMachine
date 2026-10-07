import XCTest
import AssetTimeMachineResearchSupport

final class CreditLeadTests: XCTestCase {
    func testPinnedIndexingCadenceAndNextOpenStopPriority() throws {
        // k=5: source numerator leader[4]=102, denominator leader[0]=100.
        // leader[5]=1 must not affect this review's return. QQQ signal close100
        // sets stop95; next held close90 queues an exit at the following open.
        let leader = [100.0, 100, 100, 100, 102, 1, 102, 102, 102, 102, 102, 102]
        let follower = [100.0, 100, 100, 100, 100, 100, 90, 100, 100, 100, 100, 100]
        let d = try CreditLeadScreen.decisions(leader: leader, follower: follower, firstExecutionIndex: 6)
        XCTAssertEqual(d[6].leaderReturn!, 0.02, accuracy: 1e-14)
        XCTAssertEqual(d[6].event, "enter"); XCTAssertEqual(d[6].weight, 0.8)
        XCTAssertEqual(d[6].stopPrice, 95)
        XCTAssertEqual(d[7].event, "stop"); XCTAssertEqual(d[7].weight, 0)
        XCTAssertFalse(d[7].review); XCTAssertTrue(d[11].review)
        XCTAssertTrue(d[8...10].allSatisfy { $0.event == "hold" && $0.weight == 0 })
    }

    func testSourceSignalPrefixCausalityAndLongOnlyOpposite() throws {
        let leader = [100.0, 100, 100, 100, 98, 98, 98, 98, 98, 98, 98, 98]
        let follower = Array(repeating: 100.0, count: leader.count)
        let normal = try CreditLeadScreen.decisions(leader: leader, follower: follower, firstExecutionIndex: 6)
        let inverse = try CreditLeadScreen.decisions(leader: leader, follower: follower, firstExecutionIndex: 6, inverse: true)
        XCTAssertEqual(normal[6].weight, 0); XCTAssertEqual(inverse[6].weight, 0.8)
        let prefix = try CreditLeadScreen.decisions(leader: Array(leader.prefix(9)),
            follower: Array(follower.prefix(9)), firstExecutionIndex: 6, inverse: true)
        XCTAssertEqual(Array(inverse.prefix(9)), prefix)
        let changed = try CreditLeadScreen.decisions(leader: Array(leader.prefix(8)) + [1, 999, 1, 999],
            follower: Array(follower.prefix(8)) + [1, 999, 1, 999], firstExecutionIndex: 6, inverse: true)
        XCTAssertEqual(Array(changed.prefix(9)), prefix)
        XCTAssertThrowsError(try CreditLeadScreen.decisions(leader: [1, 0], follower: [1, 1], firstExecutionIndex: 1))
    }
}
