import XCTest
import AssetTimeMachineResearchSupport

final class BollingerParameterScreenTests: XCTestCase {
    private func dates(_ count: Int) -> [Date] { (0..<count).map { Date(timeIntervalSince1970:Double($0)*86400) } }
    func testOriginal20By2MatchesLegacyExactly() throws {
        let d = dates(450), p = (0..<450).map { 100 + 20 * sin(Double($0)/6) + Double($0)/100 }
        for rule in SingleIndicatorScreen.Rule.allCases {
            XCTAssertEqual(try BollingerParameterScreen.signals(dates:d,prices:p,rule:rule,start:d[40],period:20,multiplier:2),
                try SingleIndicatorScreen.signals(dates:d,prices:p,rule:rule,start:d[40]))
        }
    }
    func testTenSessionPopulationBandAndReentryExit() throws {
        let d = dates(14), p = Array(repeating:100.0,count:8) + [99,101,80,90,100,100]
        let down = try BollingerParameterScreen.signals(dates:d,prices:p,rule:.lowerDowncross,start:d[0],period:10,multiplier:1.5)
        XCTAssertNil(down[8].middle); XCTAssertEqual(down[10].middle!,98,accuracy:1e-12)
        XCTAssertEqual(down[10].lower!,98 - 1.5 * sqrt(36.2),accuracy:1e-12); XCTAssertEqual(down[10].weight,1)
        XCTAssertEqual(down[12].weight,0)
        let re = try BollingerParameterScreen.signals(dates:d,prices:p,rule:.lowerReentry,start:d[0],period:10,multiplier:1.5)
        XCTAssertEqual(re[10].weight,0); XCTAssertEqual(re[11].weight,1); XCTAssertEqual(re[12].weight,0)
        let flat = try BollingerParameterScreen.signals(dates:d,prices:Array(repeating:100.0,count:10) + [80,90,100,100],
            rule:.lowerDowncross,start:d[0],period:10,multiplier:1.5)
        XCTAssertEqual(flat[10].weight,0) // Previous close equals lower band; strict original downcross fails.
        XCTAssertThrowsError(try BollingerParameterScreen.signals(dates:d,prices:p,rule:.lowerDowncross,start:d[0],period:15,multiplier:2))
        XCTAssertThrowsError(try BollingerParameterScreen.signals(dates:d,prices:p,rule:.lowerDowncross,start:d[0],period:10,multiplier:3))
    }
    func testEveryPermittedConfigurationIsCausal() throws {
        let d = dates(450), p = (0..<450).map { 100 + 20 * sin(Double($0)/6) }
        for rule in SingleIndicatorScreen.Rule.allCases { for period in [10,20,40] { for sigma in [1.5,2.0] {
            let original = try BollingerParameterScreen.signals(dates:d,prices:p,rule:rule,start:d[50],period:period,multiplier:sigma)
            let prefix = try BollingerParameterScreen.signals(dates:Array(d.prefix(300)),prices:Array(p.prefix(300)),rule:rule,start:d[50],period:period,multiplier:sigma)
            let shock = try BollingerParameterScreen.signals(dates:d,prices:p.enumerated().map { $0.offset < 300 ? $0.element : $0.element*100 },rule:rule,start:d[50],period:period,multiplier:sigma)
            XCTAssertEqual(Array(original.prefix(300)),prefix); XCTAssertEqual(Array(original.prefix(300)),Array(shock.prefix(300)))
        } } }
    }
}
