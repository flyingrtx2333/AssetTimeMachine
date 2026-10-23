import XCTest
import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport

final class MonthlyMomentumScreenTests: XCTestCase {
    private func fixture() -> ([Date],[Double],[Double]) {
        let start=BacktestSeriesAlignment.historicalSeriesDate(from:"2000-01-01")!
        let dates=(0..<420).map { start.addingTimeInterval(Double($0)*86400) }
        var g=Array(repeating:100.0,count:420),n=g
        g[252]=120;n[252]=110
        for i in 253..<420 { g[i]=50;n[i]=140 }
        return (dates,g,n)
    }
    func testHandROCMonthlyHoldAndNextMonthSwitch() throws {
        let (d,g,n)=fixture()
        let s=try MonthlyMomentumScreen.schedule(dates:d,gold:g,nasdaq:n,startIndex:252,rule:.strongest)
        XCTAssertTrue(s[252].weights.isEmpty);XCTAssertFalse(s[252].review)
        XCTAssertEqual(s[253].scores["gold_cny"]!,0.2,accuracy:1e-12)
        XCTAssertEqual(s[253].scores["nasdaq"]!,0.1,accuracy:1e-12)
        XCTAssertEqual(s[253].weights,["gold_cny":1]);XCTAssertTrue(s[253].review)
        XCTAssertEqual(s[253].signalDate,d[252])
        XCTAssertEqual(s[254].weights,s[253].weights);XCTAssertFalse(s[254].review)
        let next=try XCTUnwrap(s.indices.first { $0>253 && s[$0].review })
        XCTAssertEqual(s[next].weights,["nasdaq":1]);XCTAssertEqual(s[next].reviewSignalDate,d[next-1])
        XCTAssertNotEqual(BacktestSeriesAlignment.historicalSeriesCalendar.component(.month,from:d[next]),BacktestSeriesAlignment.historicalSeriesCalendar.component(.month,from:d[next-1]))
    }
    func testPositiveEligibilityTieAndControls() throws {
        let (d,g,n)=fixture()
        let weak=try MonthlyMomentumScreen.schedule(dates:d,gold:g,nasdaq:n,startIndex:252,rule:.weaker)
        XCTAssertEqual(weak[253].weights,["nasdaq":1])
        let tied=try MonthlyMomentumScreen.schedule(dates:d,gold:g,nasdaq:g,startIndex:252,rule:.strongest)
        XCTAssertEqual(tied[253].weights,["gold_cny":1])
        let flat=try MonthlyMomentumScreen.schedule(dates:d,gold:Array(repeating:100,count:d.count),nasdaq:Array(repeating:100,count:d.count),startIndex:252,rule:.strongest)
        XCTAssertTrue(flat.allSatisfy { $0.weights.isEmpty })
        let mix=try MonthlyMomentumScreen.schedule(dates:d,gold:g,nasdaq:n,startIndex:252,rule:.equalMix)
        XCTAssertEqual(mix[253].weights,["gold_cny":0.5,"nasdaq":0.5])
        XCTAssertEqual(mix[254].weights,mix[253].weights);XCTAssertFalse(mix[254].review)
    }
    func testPrefixFutureShockAndIndependentPriceScales() throws {
        let (d,g,n)=fixture()
        for rule in MonthlyMomentumScreen.Rule.allCases {
            let s=try MonthlyMomentumScreen.schedule(dates:d,gold:g,nasdaq:n,startIndex:252,rule:rule)
            let short=try MonthlyMomentumScreen.schedule(dates:Array(d.prefix(320)),gold:Array(g.prefix(320)),nasdaq:Array(n.prefix(320)),startIndex:252,rule:rule)
            let future=try MonthlyMomentumScreen.schedule(dates:d,gold:g.enumerated().map { $0.offset<320 ? $0.element : $0.element*100 },nasdaq:n,startIndex:252,rule:rule)
            let scaled=try MonthlyMomentumScreen.schedule(dates:d,gold:g.map { $0*7 },nasdaq:n.map { $0*19 },startIndex:252,rule:rule)
            XCTAssertEqual(Array(s.prefix(320)),short);XCTAssertEqual(Array(s.prefix(320)),Array(future.prefix(320)))
            XCTAssertEqual(s.map(\.weights),scaled.map(\.weights))
            XCTAssertTrue(s.allSatisfy { $0.weights.values.reduce(0,+)<=1 && $0.weights.values.allSatisfy { $0>=0 } })
        }
    }
    func testActualRotationWaitsForQuotesAndSettledSales() throws {
        let (d,g,n)=fixture()
        let s=try MonthlyMomentumScreen.schedule(dates:d,gold:g,nasdaq:n,startIndex:252,rule:.strongest)
        let switchIndex=try XCTUnwrap(s.indices.first { $0>253 && s[$0].review })
        let symbols=["gold_cny","nasdaq"]
        let options=Dictionary(uniqueKeysWithValues:BacktestCoreDefaults.strategyAssetOptions.filter { symbols.contains($0.symbol) }.map { ($0.symbol,$0) })
        let observed=d.indices.map { $0 != switchIndex && $0 != switchIndex+1 }
        let frame=MarketDataFrame(dates:d,pricesBySymbol:["gold_cny":g,"nasdaq":n],observedBySymbol:["gold_cny":observed,"nasdaq":observed],ohlcBySymbol:[:],tradableSymbols:symbols,optionBySymbol:options,simulationRange:252...(switchIndex+4))
        let run=try XCTUnwrap(BacktestDailySimulator.run(frame:frame,execution:.init(initialCash:100000,feeRate:0.00025,slippageRate:0,rebalanceBand:0,financingAnnualRate:0,allowsFinancedExposure:false,buyReason:"monthly regression"),provider:.init { s[$0.index].weights },rebalanceDecision:{ _,_ in .init(shouldRebalance:false,refreshOverlay:false) },contextualRebalanceDecision:{ .init(shouldRebalance:s[$0.index].review,refreshOverlay:false) }))
        let sale=try XCTUnwrap(run.trades.first { $0.assetSymbol=="gold_cny" && $0.action == .sell })
        let purchase=try XCTUnwrap(run.trades.first { $0.assetSymbol=="nasdaq" && $0.action == .buy })
        XCTAssertEqual(sale.date,d[switchIndex+2]);XCTAssertEqual(purchase.date,d[switchIndex+3])
        for (offset,state) in run.dailyStates.enumerated() {
            XCTAssertEqual(state.targetWeights,s[252+offset].weights)
            XCTAssertGreaterThanOrEqual(state.cash,-1e-8)
            XCTAssertEqual(state.cash+state.holdingsBySymbol.values.reduce(0,+),state.portfolioValue,accuracy:1e-7)
        }
    }
    func testBadInputFailsClosed() {
        let (d,g,n)=fixture()
        XCTAssertThrowsError(try MonthlyMomentumScreen.schedule(dates:Array(d.reversed()),gold:g,nasdaq:n,startIndex:252,rule:.strongest))
        XCTAssertThrowsError(try MonthlyMomentumScreen.schedule(dates:d,gold:g,nasdaq:n,startIndex:251,rule:.strongest))
        XCTAssertThrowsError(try MonthlyMomentumScreen.schedule(dates:d,gold:g.dropLast().map { $0 },nasdaq:n,startIndex:252,rule:.strongest))
        var bad=g;bad[255]=Double.nan
        XCTAssertThrowsError(try MonthlyMomentumScreen.schedule(dates:d,gold:bad,nasdaq:n,startIndex:252,rule:.strongest))
    }
}
