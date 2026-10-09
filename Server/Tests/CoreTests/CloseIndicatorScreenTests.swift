import XCTest
import AssetTimeMachineResearchSupport

final class CloseIndicatorScreenTests: XCTestCase {
    private func dates(_ count: Int) -> [Date] { (0..<count).map { Date(timeIntervalSince1970:Double($0)*86400) } }
    func testHandFormulasAndWarmup() throws {
        let p = Array(repeating:100.0,count:10) + Array(repeating:110.0,count:40)
        let k = try CloseIndicatorScreen.values(prices:p,rule:.kama)
        XCTAssertNil(k[8]); XCTAssertEqual(k[9]!,100)
        XCTAssertEqual(k[10]!,100 + 40.0/9,accuracy:1e-12)
        let t = try CloseIndicatorScreen.values(prices:Array(repeating:100.0,count:43)+[164],rule:.trix)
        XCTAssertNil(t[42]); XCTAssertEqual(t[43]!,0.125,accuracy:1e-12)
        let c = try CloseIndicatorScreen.values(prices:(0..<21).map { 120-Double($0) } + [115,120] + Array(repeating:120,count:21),rule:.cmo)
        XCTAssertNil(c[19]); XCTAssertEqual(c[20]!,-100)
        XCTAssertEqual(c[21]!,-100.0*4/34,accuracy:1e-12)
        XCTAssertEqual(c[22]!,100.0*2/38,accuracy:1e-12)
    }
    func testReentryExitAndFlatBoundaries() throws {
        let p = (0..<21).map { 120-Double($0) } + [115,120] + Array(repeating:120.0,count:21)
        let d = dates(p.count)
        let s = try CloseIndicatorScreen.signals(dates:d,prices:p,rule:.cmo,start:d[0])
        XCTAssertEqual(s[20].weight,0); XCTAssertEqual(s[21].weight,1); XCTAssertEqual(s[22].weight,0)
        for r in CloseIndicatorScreen.Rule.allCases {
            let flat = try CloseIndicatorScreen.signals(dates:d,prices:Array(repeating:100,count:d.count),rule:r,start:d[0])
            XCTAssertTrue(flat.allSatisfy { $0.weight == 0 })
        }
        XCTAssertThrowsError(try CloseIndicatorScreen.signals(dates:d,prices:Array(repeating:-1,count:d.count),rule:.kama,start:d[0]))
        XCTAssertThrowsError(try CloseIndicatorScreen.signals(dates:Array(d.reversed()),prices:p,rule:.trix,start:d[0]))
    }
    func testEveryRulePrefixFutureShockScaleAndStart() throws {
        let d = dates(450), p = (0..<450).map { 100 + 20*sin(Double($0)/6) }
        for r in CloseIndicatorScreen.Rule.allCases {
            let s = try CloseIndicatorScreen.signals(dates:d,prices:p,rule:r,start:d[70])
            let prefix = try CloseIndicatorScreen.signals(dates:Array(d.prefix(300)),prices:Array(p.prefix(300)),rule:r,start:d[70])
            let shock = try CloseIndicatorScreen.signals(dates:d,prices:p.enumerated().map { $0.offset < 300 ? $0.element : $0.element*100 },rule:r,start:d[70])
            let scaled = try CloseIndicatorScreen.signals(dates:d,prices:p.map { $0*7 },rule:r,start:d[70])
            XCTAssertEqual(Array(s.prefix(300)),prefix); XCTAssertEqual(Array(s.prefix(300)),Array(shock.prefix(300)))
            XCTAssertEqual(s.map(\.weight),scaled.map(\.weight)); XCTAssertTrue(s.prefix(70).allSatisfy { $0.weight == 0 })
        }
    }
}
