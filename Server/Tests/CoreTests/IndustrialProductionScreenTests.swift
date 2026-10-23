import XCTest
import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport

final class IndustrialProductionScreenTests:XCTestCase {
    private func date(_ s:String)->Date { BacktestSeriesAlignment.historicalSeriesDate(from:s)! }
    private func observation(_ release:String,_ yoy:Double)->IndustrialProductionScreen.Observation {
        .init(releaseDate:release,knownAfter:date(release).addingTimeInterval(2*86400),referenceMonth:"2001-12",yoy:yoy)
    }
    private func days()->[Date] { (0..<20).map { date("2002-01-01").addingTimeInterval(Double($0)*86400) } }
    func testPublicationBufferT1SignEqualityAndUnchangedHold() throws {
        let d=days(),o=[observation("2002-01-01",1),observation("2002-01-05",-1),observation("2002-01-09",0)]
        let s=try IndustrialProductionScreen.schedule(dates:d,observations:o,startIndex:0,inverse:false)
        XCTAssertTrue(s[0].weights.isEmpty);XCTAssertTrue(s[2].weights.isEmpty)
        XCTAssertEqual(s[3].weights,["nasdaq":1]);XCTAssertEqual(s[6].weights,["nasdaq":1])
        XCTAssertEqual(s[7].weights,["gold_cny":1]);XCTAssertTrue(s[11].weights.isEmpty)
        let inverse=try IndustrialProductionScreen.schedule(dates:d,observations:o,startIndex:0,inverse:true)
        XCTAssertEqual(inverse[3].weights,["gold_cny":1]);XCTAssertEqual(inverse[7].weights,["nasdaq":1]);XCTAssertTrue(inverse[11].weights.isEmpty)
        for x in s { if !x.weights.isEmpty { XCTAssertLessThanOrEqual(x.knownAfter!,x.signalDate) } }
    }
    func testPrefixFutureRevisionDoesNotAffectEarlierDecisions() throws {
        let d=days(),o=[observation("2002-01-01",1),observation("2002-01-05",-1),observation("2002-01-14",2)]
        for inverse in [false,true] {
            let a=try IndustrialProductionScreen.schedule(dates:d,observations:o,startIndex:0,inverse:inverse)
            let b=try IndustrialProductionScreen.schedule(dates:Array(d.prefix(10)),observations:Array(o.prefix(2)),startIndex:0,inverse:inverse)
            let shock=try IndustrialProductionScreen.schedule(dates:d,observations:Array(o.prefix(2))+[observation("2002-01-14",-49)],startIndex:0,inverse:inverse)
            XCTAssertEqual(Array(a.prefix(10)),b);XCTAssertEqual(Array(a.prefix(16)),Array(shock.prefix(16)))
        }
    }
    func testRapidAtoBtoAAndCashExitDuringQuoteWaitAreDeliveredWithoutMaintenance() throws {
        let d=days(),o=[observation("2002-01-01",1),observation("2002-01-05",-1),observation("2002-01-06",1),observation("2002-01-10",0)]
        let s=try IndustrialProductionScreen.schedule(dates:d,observations:o,startIndex:0,inverse:false)
        let symbols=["gold_cny","nasdaq"],options=Dictionary(uniqueKeysWithValues:BacktestCoreDefaults.strategyAssetOptions.filter { symbols.contains($0.symbol) }.map { ($0.symbol,$0) })
        let observed=d.indices.map { ![7,8,11,12].contains($0) }
        let frame=MarketDataFrame(dates:d,pricesBySymbol:["gold_cny":Array(repeating:100,count:d.count),"nasdaq":Array(repeating:100,count:d.count)],observedBySymbol:["gold_cny":observed,"nasdaq":observed],ohlcBySymbol:[:],tradableSymbols:symbols,optionBySymbol:options,simulationRange:0...19)
        let (run,trace)=try IndustrialProductionScreen.simulate(frame:frame,signals:s)
        XCTAssertEqual(trace.filter(\.submitted).map(\.index),[0,3,7,8,12])
        XCTAssertFalse(run.trades.contains { $0.assetSymbol=="gold_cny" })
        XCTAssertEqual(run.trades.filter { $0.action == .sell }.first!.date,d[13])
        XCTAssertTrue(run.dailyStates.last!.holdingsBySymbol.isEmpty)
        for (i,state) in run.dailyStates.enumerated() {
            XCTAssertEqual(state.targetWeights,s[i].weights);XCTAssertGreaterThanOrEqual(state.cash,0)
            XCTAssertLessThanOrEqual(state.holdingsBySymbol.values.reduce(0,+),state.portfolioValue+1e-8)
        }
        let buys=run.trades.filter { $0.action == .buy };XCTAssertEqual(buys.count,1)
        XCTAssertEqual(buys[0].units*buys[0].price,buys[0].cashAmount*0.99975,accuracy:1e-8)
    }
    func testOrdinarySwitchWaitsForSettledSaleAndRejectsBadClockInput() throws {
        let d=days(),o=[observation("2002-01-01",1),observation("2002-01-05",-1)]
        let s=try IndustrialProductionScreen.schedule(dates:d,observations:o,startIndex:0,inverse:false)
        let symbols=["gold_cny","nasdaq"],options=Dictionary(uniqueKeysWithValues:BacktestCoreDefaults.strategyAssetOptions.filter { symbols.contains($0.symbol) }.map { ($0.symbol,$0) })
        let frame=MarketDataFrame(dates:d,pricesBySymbol:["gold_cny":Array(repeating:100,count:d.count),"nasdaq":Array(repeating:100,count:d.count)],observedBySymbol:["gold_cny":Array(repeating:true,count:d.count),"nasdaq":Array(repeating:true,count:d.count)],ohlcBySymbol:[:],tradableSymbols:symbols,optionBySymbol:options,simulationRange:0...19)
        let (run,_)=try IndustrialProductionScreen.simulate(frame:frame,signals:s)
        XCTAssertEqual(run.trades.first { $0.action == .sell }!.date,d[7])
        XCTAssertEqual(run.trades.first { $0.assetSymbol=="gold_cny" && $0.action == .buy }!.date,d[8])
        XCTAssertThrowsError(try IndustrialProductionScreen.schedule(dates:d,observations:Array(o.reversed()),startIndex:0,inverse:false))
        XCTAssertThrowsError(try IndustrialProductionScreen.schedule(dates:d,observations:[.init(releaseDate:"2002-01-01",knownAfter:d[0],referenceMonth:"2001-12",yoy:1)],startIndex:0,inverse:false))
        XCTAssertThrowsError(try IndustrialProductionScreen.schedule(dates:d,observations:[observation("2002-01-01",.nan)],startIndex:0,inverse:false))
    }
}
