import XCTest
import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport

final class AbsoluteMomentumScreenTests: XCTestCase {
    private func fixture() -> ([Date],[Double],[Double]) {
        let start=BacktestSeriesAlignment.historicalSeriesDate(from:"2000-01-01")!
        let dates=(0..<420).map { start.addingTimeInterval(Double($0)*86400) }
        var g=Array(repeating:100.0,count:420),n=g
        g[252]=120;n[252]=110
        for i in 253..<420 { g[i]=50;n[i]=140 }
        return (dates,g,n)
    }
    func testOwnPositiveSlotsAndNoInactiveSlotTransfer() throws {
        let (d,g,n)=fixture()
        let s=try MonthlyMomentumScreen.schedule(dates:d,gold:g,nasdaq:n,startIndex:252,rule:.absoluteEqual)
        XCTAssertTrue(s[252].weights.isEmpty)
        XCTAssertEqual(s[253].weights,["gold_cny":0.5,"nasdaq":0.5])
        XCTAssertEqual(s[254].weights,s[253].weights)
        let next=try XCTUnwrap(s.indices.first { $0>253 && s[$0].review })
        XCTAssertEqual(s[next].weights,["nasdaq":0.5])
        let opposite=try MonthlyMomentumScreen.schedule(dates:d,gold:g,nasdaq:n,startIndex:252,rule:.negativeEqual)
        XCTAssertTrue(opposite[253].weights.isEmpty)
        XCTAssertEqual(opposite[next].weights,["gold_cny":0.5])
        let flat=try MonthlyMomentumScreen.schedule(dates:d,gold:Array(repeating:100,count:d.count),nasdaq:Array(repeating:100,count:d.count),startIndex:252,rule:.absoluteEqual)
        XCTAssertTrue(flat.allSatisfy { $0.weights.isEmpty })
    }
    func testActualSlotExitSettlesAndRetainsOtherHalfWithoutFinancing() throws {
        let (d,g,n)=fixture()
        let s=try MonthlyMomentumScreen.schedule(dates:d,gold:g,nasdaq:n,startIndex:252,rule:.absoluteEqual)
        let change=try XCTUnwrap(s.indices.first { $0>253 && s[$0].review })
        let symbols=["gold_cny","nasdaq"]
        let options=Dictionary(uniqueKeysWithValues:BacktestCoreDefaults.strategyAssetOptions.filter { symbols.contains($0.symbol) }.map { ($0.symbol,$0) })
        let observed=d.indices.map { $0 != change }
        let frame=MarketDataFrame(dates:d,pricesBySymbol:["gold_cny":g,"nasdaq":n],observedBySymbol:["gold_cny":observed,"nasdaq":observed],ohlcBySymbol:[:],tradableSymbols:symbols,optionBySymbol:options,simulationRange:252...(change+4))
        let result=try XCTUnwrap(BacktestDailySimulator.run(frame:frame,execution:.init(initialCash:100000,feeRate:0.00025,slippageRate:0,rebalanceBand:0,financingAnnualRate:0,allowsFinancedExposure:false,buyReason:"absolute slots regression"),provider:.init { s[$0.index].weights },rebalanceDecision:{ _,_ in .init(shouldRebalance:false,refreshOverlay:false) },contextualRebalanceDecision:{ .init(shouldRebalance:s[$0.index].review,refreshOverlay:false) }))
        let sale=try XCTUnwrap(result.trades.first { $0.assetSymbol=="gold_cny" && $0.action == .sell })
        XCTAssertEqual(sale.date,d[change+1])
        XCTAssertNil(result.dailyStates.last?.holdingsBySymbol["gold_cny"])
        XCTAssertEqual(result.dailyStates.last?.targetWeights,["nasdaq":0.5])
        XCTAssertGreaterThan(result.dailyStates.last!.cash,0)
        for (offset,state) in result.dailyStates.enumerated() {
            XCTAssertEqual(state.targetWeights,s[252+offset].weights)
            XCTAssertGreaterThanOrEqual(state.cash,-1e-8)
            XCTAssertLessThanOrEqual(state.holdingsBySymbol.values.reduce(0,+),state.portfolioValue+1e-8)
        }
    }
}
