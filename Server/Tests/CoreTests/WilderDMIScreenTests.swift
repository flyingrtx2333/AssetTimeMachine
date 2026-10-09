import XCTest
import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport

final class WilderDMIScreenTests: XCTestCase {
    typealias Bar = WilderDMIScreen.Bar
    private func bars(_ rows: [[Double]]) -> [Bar] {
        rows.enumerated().map { i,r in
            Bar(date:Date(timeIntervalSince1970:Double(i)*86400),open:r[0],high:r[1],low:r[2],close:r[3])
        }
    }
    // Hand arithmetic fixture for the standard TA-Lib PLUS_DI/MINUS_DI seed;
    // expected values are rational constants, not outputs from a TA-Lib runtime.
    private var handFixture: [Bar] {
        bars(Array(repeating:[9,10,8,9],count:14)+[[13,14,12,13],[8,9,7,8],[8,10,6,8],[8,9,7,8]])
    }
    func testStandardTAImplementationSeedAgainstHandArithmeticFixture() throws {
        let s=try WilderDMIScreen.signals(bars:handFixture)
        XCTAssertTrue(s.prefix(14).allSatisfy {
            $0.plusDI == nil && $0.minusDI == nil && $0.smoothedTR == nil && $0.weight == 0
        })
        // Seed TR=13*2; movement14 has +DM=4 and gap-aware TR=5.
        XCTAssertEqual(s[14].smoothedPlusDM!,4,accuracy:1e-12)
        XCTAssertEqual(s[14].smoothedMinusDM!,0,accuracy:1e-12)
        XCTAssertEqual(s[14].smoothedTR!,204.0/7,accuracy:1e-12)
        XCTAssertEqual(s[14].plusDI!,700.0/51,accuracy:1e-12)
        XCTAssertEqual(s[14].minusDI!,0,accuracy:1e-12)
        // Movement15 has -DM=5 and gap-aware TR=6.
        XCTAssertEqual(s[15].smoothedPlusDM!,26.0/7,accuracy:1e-12)
        XCTAssertEqual(s[15].smoothedMinusDM!,5,accuracy:1e-12)
        XCTAssertEqual(s[15].smoothedTR!,1620.0/49,accuracy:1e-12)
        XCTAssertEqual(s[15].plusDI!,910.0/81,accuracy:1e-12)
        XCTAssertEqual(s[15].minusDI!,1225.0/81,accuracy:1e-12)
        // The equal up/down outside movement16 contributes no directional movement.
        XCTAssertEqual(s[16].smoothedPlusDM!,169.0/49,accuracy:1e-12)
        XCTAssertEqual(s[16].smoothedMinusDM!,65.0/14,accuracy:1e-12)
        XCTAssertEqual(s[16].smoothedTR!,11902.0/343,accuracy:1e-12)
        // Movement17 is an inside bar: both directional sums decay without an addition.
        XCTAssertEqual(s[17].smoothedPlusDM!,2197.0/686,accuracy:1e-12)
        XCTAssertEqual(s[17].smoothedMinusDM!,845.0/196,accuracy:1e-12)
        XCTAssertEqual(s.map(\.weight),Array(repeating:0,count:14)+[1,0,0,0])
    }
    func testFirstOutputIndexAndStrictDIDirection() throws {
        let up=bars((0..<16).map { i in
            let x=Double(i)
            return [100+x,102+x,98+x,100+x]
        })
        let s=try WilderDMIScreen.signals(bars:up)
        XCTAssertEqual(s.firstIndex(where: { $0.plusDI != nil }),14)
        XCTAssertEqual(s[14].smoothedPlusDM!,183.0/14,accuracy:1e-12)
        XCTAssertEqual(s[14].smoothedTR!,366.0/7,accuracy:1e-12)
        XCTAssertEqual(s[14].plusDI!,25,accuracy:1e-12)
        XCTAssertEqual(s[14].minusDI!,0,accuracy:1e-12)
        XCTAssertEqual(s[14].weight,1)
        XCTAssertEqual(try WilderDMIScreen.signals(bars:Array(up.prefix(14))).map(\.weight),Array(repeating:0,count:14))
        XCTAssertNil(try WilderDMIScreen.signals(bars:Array(up.prefix(1)))[0].plusDI)
    }
    func testTiesInsideBarsFlatZeroTRAndEqualDIStayInCash() throws {
        let rows=Array(repeating:[100.0,102,98,100],count:14)+[
            [100,103,97,100],[100,102,98,100],[98,100,96,98]]
        let s=try WilderDMIScreen.signals(bars:bars(rows))
        for i in [14,15] {
            XCTAssertEqual(s[i].smoothedPlusDM!,0)
            XCTAssertEqual(s[i].smoothedMinusDM!,0)
            XCTAssertEqual(s[i].weight,0)
        }
        XCTAssertEqual(s[16].smoothedPlusDM!,0)
        XCTAssertEqual(s[16].smoothedMinusDM!,2)
        XCTAssertEqual(s[16].weight,0)
        let flat=try WilderDMIScreen.signals(bars:bars(Array(repeating:[100,100,100,100],count:30)))
        XCTAssertTrue(flat.dropFirst(14).allSatisfy { $0.plusDI==0 && $0.minusDI==0 && $0.smoothedTR==0 && $0.weight==0 })
        // Equal nonzero DI: seed13 contains +DM2 and -DM2, followed by no new movement.
        let tied=try WilderDMIScreen.signals(bars:bars([[100,102,98,100],[102,104,100,102],[100,102,98,100]] +
            Array(repeating:[100,102,98,100],count:12)))
        XCTAssertGreaterThan(tied[14].plusDI!,0)
        XCTAssertEqual(tied[14].plusDI,tied[14].minusDI)
        XCTAssertEqual(tied[14].weight,0)
    }
    func testPrefixFutureShockAndPriceScaling() throws {
        let b=(0..<400).map { i -> Bar in
            let c=100+20*sin(Double(i)/7),o=c+cos(Double(i))
            return Bar(date:Date(timeIntervalSince1970:Double(i)*86400),open:o,high:max(o,c)+2,low:min(o,c)-2,close:c)
        }
        let s=try WilderDMIScreen.signals(bars:b)
        let prefix=try WilderDMIScreen.signals(bars:Array(b.prefix(280)))
        let shocked=try WilderDMIScreen.signals(bars:b.enumerated().map { i,x in
            let f=i<280 ? 1.0 : 20.0
            return Bar(date:x.date,open:x.open*f,high:x.high*f,low:x.low*f,close:x.close*f)
        })
        let scaled=try WilderDMIScreen.signals(bars:b.map {
            Bar(date:$0.date,open:$0.open*7,high:$0.high*7,low:$0.low*7,close:$0.close*7)
        })
        XCTAssertEqual(Array(s.prefix(280)),prefix)
        XCTAssertEqual(Array(s.prefix(280)),Array(shocked.prefix(280)))
        XCTAssertEqual(s.map(\.weight),scaled.map(\.weight))
        for(a,z)in zip(s.dropFirst(14),scaled.dropFirst(14)) {
            XCTAssertEqual(a.plusDI!,z.plusDI!,accuracy:1e-10)
            XCTAssertEqual(a.minusDI!,z.minusDI!,accuracy:1e-10)
            XCTAssertEqual(a.smoothedPlusDM!*7,z.smoothedPlusDM!,accuracy:1e-10)
            XCTAssertEqual(a.smoothedTR!*7,z.smoothedTR!,accuracy:1e-10)
        }
    }
    func testLatestCompletedUSDOnlyObservationAndSameDayExclusion() throws {
        let s=try WilderDMIScreen.signals(bars:handFixture)
        // USD bar14 is omitted by the CNY execution calendar. Execution on day15
        // must use that completed USD bar, not day13 or the reversing same-day bar15.
        XCTAssertEqual(WilderDMIScreen.latestSignal(s,before:s[15].date),s[14])
        XCTAssertEqual(WilderDMIScreen.latestSignal(s,before:s[15].date)?.weight,1)
        XCTAssertEqual(s[15].weight,0)
        XCTAssertEqual(WilderDMIScreen.latestSignal(s,before:s[14].date),s[13])
        XCTAssertNil(WilderDMIScreen.latestSignal(s,before:s[0].date))
        XCTAssertEqual(WilderDMIScreen.latestSignal(s,before:s[15].date.addingTimeInterval(1)),s[15])
    }
    func testNativeFrameFundsFromFirstFXMarkAndUsesSimulationCutoffBeforeCachedFutureObservation() throws {
        let dates=["2000-01-13","2000-01-14","2026-10-06","2026-10-07"].map {
            BacktestSeriesAlignment.historicalSeriesDate(from:$0)!
        }
        let option=BacktestCoreDefaults.strategyAssetOptions.first { $0.symbol=="nasdaq" }!
        func expanded(_ dates:[Date],upper:Int)->MarketDataFrame {
            .init(dates:dates,pricesBySymbol:["nasdaq":Array(repeating:100,count:dates.count)],
                observedBySymbol:["nasdaq":Array(repeating:true,count:dates.count)],ohlcBySymbol:[:],
                tradableSymbols:["nasdaq"],optionBySymbol:["nasdaq":option],simulationRange:1...upper)
        }
        let native=try WilderDMIScreen.nativeFrame(expanded:expanded(dates,upper:2))
        XCTAssertEqual(native.simulationRange,0...2)
        XCTAssertEqual(native.dates,dates)
        XCTAssertEqual(native.dates[native.simulationRange.upperBound],dates[2])
        XCTAssertEqual(native.dates.last,dates[3])
        XCTAssertThrowsError(try WilderDMIScreen.nativeFrame(expanded:expanded(dates,upper:3)))
        XCTAssertThrowsError(try WilderDMIScreen.nativeFrame(expanded:expanded(Array(dates.dropFirst()),upper:1)))
    }
    func testIncompleteBarsAndUnorderedDatesFailClosed() throws {
        XCTAssertThrowsError(try WilderDMIScreen.signals(bars:[]))
        XCTAssertThrowsError(try WilderDMIScreen.signals(bars:bars([[100,99,98,100]])))
        XCTAssertThrowsError(try WilderDMIScreen.signals(bars:bars([[100,101,Double.nan,100]])))
        XCTAssertThrowsError(try WilderDMIScreen.signals(bars:bars([[100,Double.infinity,99,100]])))
        XCTAssertThrowsError(try WilderDMIScreen.signals(bars:bars([[0,1,0,1]])))
        let b=bars([[100,101,99,100],[100,101,99,100]])
        XCTAssertThrowsError(try WilderDMIScreen.signals(bars:Array(b.reversed())))
        XCTAssertThrowsError(try WilderDMIScreen.signals(bars:[b[0],b[0]]))
    }
}
