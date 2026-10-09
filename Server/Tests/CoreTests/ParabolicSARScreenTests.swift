import XCTest
import AssetTimeMachineResearchSupport

final class ParabolicSARScreenTests: XCTestCase {
    typealias Bar = ParabolicSARScreen.Bar
    private func bars(_ rows: [[Double]]) -> [Bar] {
        rows.enumerated().map { i,r in Bar(date:Date(timeIntervalSince1970:Double(i)*86400),open:r[0],high:r[1],low:r[2],close:r[3]) }
    }
    func testHandRecurrenceClampAndBothReversals() throws {
        let b=bars([[100,101,99,100],[101,103,100,102],[102,104,101,103],[104,106,102,105],
            [100,102,98,99],[100,104,97,98],[106,108,105,107]])
        let s=try ParabolicSARScreen.signals(bars:b)
        XCTAssertNil(s[0].sar);XCTAssertEqual(s[0].weight,0)
        XCTAssertEqual(s.map(\.weight),[0,1,1,1,0,0,1])
        XCTAssertEqual(s[1].sar!,99);XCTAssertEqual(s[1].extreme!,103);XCTAssertEqual(s[1].acceleration!,0.02)
        XCTAssertEqual(s[2].sar!,99);XCTAssertEqual(s[2].extreme!,104);XCTAssertEqual(s[2].acceleration!,0.04)
        XCTAssertEqual(s[3].sar!,99.2,accuracy:1e-12);XCTAssertEqual(s[3].acceleration!,0.06,accuracy:1e-12)
        XCTAssertEqual(s[4].sar!,106);XCTAssertEqual(s[4].extreme!,98);XCTAssertEqual(s[4].acceleration!,0.02)
        XCTAssertEqual(s[5].sar!,106);XCTAssertEqual(s[5].extreme!,97);XCTAssertEqual(s[5].acceleration!,0.04)
        XCTAssertEqual(s[6].sar!,97);XCTAssertEqual(s[6].extreme!,108);XCTAssertEqual(s[6].acceleration!,0.02)
    }
    func testAccelerationCapFlatAndEqualTouch() throws {
        let up: [[Double]]=(0..<80).map { i in
            let x=Double(i)
            return [100.0+x,101.0+x,99.0+x,100.5+x]
        }
        let s=try ParabolicSARScreen.signals(bars:bars(up))
        XCTAssertEqual(s.last!.acceleration!,0.2)
        XCTAssertTrue(s.dropFirst().allSatisfy { $0.rising==true && $0.weight==1 && $0.acceleration!<=0.2 })
        let flat=try ParabolicSARScreen.signals(bars:bars(Array(repeating:[100,100,100,100],count:20)))
        XCTAssertTrue(flat.allSatisfy { $0.weight==0 })
        let touch=try ParabolicSARScreen.signals(bars:bars([[100,101,99,100],[101,103,100,102],[100,103,99,100]]))
        XCTAssertEqual(touch[2].rising,false);XCTAssertEqual(touch[2].sar!,103)
    }
    func testPrefixFutureShockAndPriceScale() throws {
        let b=(0..<400).map { i -> Bar in
            let c=100+20*sin(Double(i)/7),o=c+cos(Double(i))
            return Bar(date:Date(timeIntervalSince1970:Double(i)*86400),open:o,high:max(o,c)+2,low:min(o,c)-2,close:c)
        }
        let s=try ParabolicSARScreen.signals(bars:b)
        let prefix=try ParabolicSARScreen.signals(bars:Array(b.prefix(280)))
        let shocked=try ParabolicSARScreen.signals(bars:b.enumerated().map { i,x in
            let f=i<280 ? 1.0 : 20.0
            return Bar(date:x.date,open:x.open*f,high:x.high*f,low:x.low*f,close:x.close*f)
        })
        let scaled=try ParabolicSARScreen.signals(bars:b.map { Bar(date:$0.date,open:$0.open*7,high:$0.high*7,low:$0.low*7,close:$0.close*7) })
        XCTAssertEqual(Array(s.prefix(280)),prefix);XCTAssertEqual(Array(s.prefix(280)),Array(shocked.prefix(280)))
        XCTAssertEqual(s.map(\.weight),scaled.map(\.weight));XCTAssertEqual(s.map(\.rising),scaled.map(\.rising))
        for(a,z)in zip(s.dropFirst(),scaled.dropFirst()) { XCTAssertEqual(a.sar!*7,z.sar!,accuracy:1e-10) }
    }
    func testIncompleteBarsAndUnorderedDatesFailClosed() throws {
        XCTAssertThrowsError(try ParabolicSARScreen.signals(bars:bars([[100,101,99,100]])))
        XCTAssertThrowsError(try ParabolicSARScreen.signals(bars:bars([[100,101,99,100],[100,99,98,100]])))
        XCTAssertThrowsError(try ParabolicSARScreen.signals(bars:bars([[100,101,99,100],[100,101,Double.nan,100]])))
        let b=bars([[100,101,99,100],[100,101,99,100]])
        XCTAssertThrowsError(try ParabolicSARScreen.signals(bars:Array(b.reversed())))
    }
}
