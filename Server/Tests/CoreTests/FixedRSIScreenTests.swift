import XCTest
import AssetTimeMachineResearchSupport

final class FixedRSIScreenTests: XCTestCase {
    private func dates(_ count: Int) -> [Date] { (0..<count).map { Date(timeIntervalSince1970:Double($0)*86400) } }
    func testWilderSeedAndRecurrenceByHand() throws {
        let v = try FixedRSIScreen.values(prices:[100,102,101,103,99],period:2)
        XCTAssertNil(v[0]); XCTAssertNil(v[1])
        XCTAssertEqual(v[2]!,100*2/3,accuracy:1e-12)
        XCTAssertEqual(v[3]!,100*6/7,accuracy:1e-12)
        XCTAssertEqual(v[4]!,100*6/23,accuracy:1e-12)
    }
    func testDegenerateAndMonotoneInputs() throws {
        for n in [2,14] {
            let flat = try FixedRSIScreen.values(prices:Array(repeating:100,count:50),period:n)
            let up = try FixedRSIScreen.values(prices:(0..<50).map { 100+Double($0) },period:n)
            let down = try FixedRSIScreen.values(prices:(0..<50).map { 100-Double($0) },period:n)
            XCTAssertTrue(flat.prefix(n).allSatisfy { $0 == nil })
            XCTAssertTrue(flat.dropFirst(n).allSatisfy { $0 == 50 })
            XCTAssertTrue(up.dropFirst(n).allSatisfy { $0 == 100 })
            XCTAssertTrue(down.dropFirst(n).allSatisfy { $0 == 0 })
        }
    }
    func testFixedBoundariesWarmupAndInvalidInputs() throws {
        for r in FixedRSIScreen.Rule.allCases {
            let v: [Double?] = [nil,r.entry,r.entry+1,r.exit-1,r.exit,r.entry,r.exit]
            XCTAssertEqual(try FixedRSIScreen.weights(values:v,rule:r,active:Array(repeating:true,count:v.count)),[0,1,1,1,0,1,0])
            XCTAssertEqual(try FixedRSIScreen.weights(values:v,rule:r,active:[false,false,true,true,true,true,true]),[0,0,0,0,0,1,0])
        }
        XCTAssertThrowsError(try FixedRSIScreen.values(prices:[100,0,101],period:2))
        XCTAssertThrowsError(try FixedRSIScreen.values(prices:[100,101,102],period:3))
        XCTAssertThrowsError(try FixedRSIScreen.signals(dates:dates(20).reversed(),prices:Array(repeating:100,count:20),rule:.classic,start:dates(20)[0]))
        XCTAssertThrowsError(try FixedRSIScreen.weights(values:[Double.nan],rule:.fast,active:[true]))
    }
    func testBothRulesCausalAndScaleInvariant() throws {
        let d = dates(450), p = (0..<450).map { 100 + 20*sin(Double($0)/6) }
        for r in FixedRSIScreen.Rule.allCases {
            let s = try FixedRSIScreen.signals(dates:d,prices:p,rule:r,start:d[70])
            let prefix = try FixedRSIScreen.signals(dates:Array(d.prefix(300)),prices:Array(p.prefix(300)),rule:r,start:d[70])
            let shock = try FixedRSIScreen.signals(dates:d,prices:p.enumerated().map { $0.offset < 300 ? $0.element : $0.element*100 },rule:r,start:d[70])
            let scaled = try FixedRSIScreen.signals(dates:d,prices:p.map { $0*7 },rule:r,start:d[70])
            XCTAssertEqual(Array(s.prefix(300)),prefix)
            XCTAssertEqual(Array(s.prefix(300)),Array(shock.prefix(300)))
            XCTAssertEqual(s.map(\.weight),scaled.map(\.weight))
            for (a,b) in zip(s,scaled) { if let x=a.value,let y=b.value { XCTAssertEqual(x,y,accuracy:1e-10) } }
            XCTAssertTrue(s.prefix(70).allSatisfy { $0.weight == 0 })
        }
    }
}
