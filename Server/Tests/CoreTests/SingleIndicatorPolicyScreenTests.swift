import XCTest
import AssetTimeMachineResearchSupport

final class SingleIndicatorPolicyScreenTests: XCTestCase {
    private func dates(_ count: Int) -> [Date] { (0..<count).map { Date(timeIntervalSince1970:Double($0)*86400) } }
    func testCMOBoundariesHoldingAndExitPriority() throws {
        let v: [Double?] = [nil,-50,-49,-1,0,49,50,-50,50]
        let p = Array(repeating:100.0,count:v.count), a = Array(repeating:true,count:v.count)
        XCTAssertEqual(try SingleIndicatorPolicyScreen.weights(values:v,prices:p,rule:.cmoCycle,active:a),[0,1,1,1,1,1,0,1,0])
        XCTAssertEqual(try SingleIndicatorPolicyScreen.weights(values:v,prices:p,rule:.cmoReentry,active:a),[0,0,1,1,1,1,0,0,0])
    }
    func testTRIXOwnSignalSeedAndDirectionFlat() throws {
        let v: [Double?] = [nil,nil] + (1...9).map { Double($0) } + [10,5]
        let line = SingleIndicatorPolicyScreen.ema9(v)
        XCTAssertNil(line[9]); XCTAssertEqual(line[10]!,5)
        XCTAssertEqual(line[11]!,6); XCTAssertEqual(line[12]!,5.8,accuracy:1e-12)
        let p = Array(repeating:100.0,count:v.count), a = Array(repeating:true,count:v.count)
        let w = try SingleIndicatorPolicyScreen.weights(values:v,prices:p,rule:.trixSignal,active:a)
        XCTAssertEqual(Array(w.suffix(3)),[1,1,0])
        XCTAssertEqual(try SingleIndicatorPolicyScreen.weights(values:[nil,100,101,101,100],prices:Array(repeating:100,count:5),rule:.kamaDirection,active:Array(repeating:true,count:5)),[0,0,1,0,0])
    }
    func testAllPoliciesCausalScaleInvariantAndPreserveArithmetic() throws {
        let d = dates(450), p = (0..<450).map { 100 + 20*sin(Double($0)/6) }
        for r in SingleIndicatorPolicyScreen.Rule.allCases {
            let s = try SingleIndicatorPolicyScreen.signals(dates:d,prices:p,rule:r,start:d[70])
            let prefix = try SingleIndicatorPolicyScreen.signals(dates:Array(d.prefix(300)),prices:Array(p.prefix(300)),rule:r,start:d[70])
            let shock = try SingleIndicatorPolicyScreen.signals(dates:d,prices:p.enumerated().map { $0.offset < 300 ? $0.element : $0.element*100 },rule:r,start:d[70])
            let scale = try SingleIndicatorPolicyScreen.signals(dates:d,prices:p.map { $0*7 },rule:r,start:d[70])
            XCTAssertEqual(Array(s.prefix(300)),prefix); XCTAssertEqual(Array(s.prefix(300)),Array(shock.prefix(300)))
            XCTAssertEqual(s.map(\.weight),scale.map(\.weight)); XCTAssertTrue(s.prefix(70).allSatisfy { $0.weight == 0 })
            let base: CloseIndicatorScreen.Rule = r == .kamaDirection ? .kama : r == .trixSignal ? .trix : .cmo
            XCTAssertEqual(s.map(\.value),try CloseIndicatorScreen.values(prices:p,rule:base))
        }
    }
}
