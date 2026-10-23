import XCTest
import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport

final class WorldGrainBalanceScreenTests:XCTestCase {
    private func date(_ s:String)->Date { BacktestSeriesAlignment.historicalSeriesDate(from:s)! }
    private func observation(_ release:String,_ yoy:Double)->WorldGrainBalanceScreen.Observation {
        .init(releaseDate:release,selectedVersionDate:release,knownAfter:date(release).addingTimeInterval(2*86400),marketingYear:"2001/02",production:100+yoy,totalUse:100,endingStocks:40)
    }
    private func days()->[Date] { (0..<20).map { date("2002-01-01").addingTimeInterval(Double($0)*86400) } }
    func testPublicationBufferT1SignEqualityAndUnchangedHold() throws {
        let d=days(),o=[observation("2002-01-01",1),observation("2002-01-05",-1),observation("2002-01-09",0)]
        let s=try WorldGrainBalanceScreen.schedule(dates:d,observations:o,startIndex:0,inverse:false)
        XCTAssertTrue(s[0].weights.isEmpty);XCTAssertTrue(s[2].weights.isEmpty)
        XCTAssertEqual(s[3].weights,["nasdaq":1]);XCTAssertEqual(s[6].weights,["nasdaq":1])
        XCTAssertEqual(s[7].weights,["gold_cny":1]);XCTAssertTrue(s[11].weights.isEmpty)
        let inverse=try WorldGrainBalanceScreen.schedule(dates:d,observations:o,startIndex:0,inverse:true)
        XCTAssertEqual(inverse[3].weights,["gold_cny":1]);XCTAssertEqual(inverse[7].weights,["nasdaq":1]);XCTAssertTrue(inverse[11].weights.isEmpty)
        for x in s { if !x.weights.isEmpty { XCTAssertLessThanOrEqual(x.knownAfter!,x.signalDate) } }
    }
    func testPrefixFutureRevisionDoesNotAffectEarlierDecisions() throws {
        let d=days(),o=[observation("2002-01-01",1),observation("2002-01-05",-1),observation("2002-01-14",2)]
        for inverse in [false,true] {
            let a=try WorldGrainBalanceScreen.schedule(dates:d,observations:o,startIndex:0,inverse:inverse)
            let b=try WorldGrainBalanceScreen.schedule(dates:Array(d.prefix(10)),observations:Array(o.prefix(2)),startIndex:0,inverse:inverse)
            let shock=try WorldGrainBalanceScreen.schedule(dates:d,observations:Array(o.prefix(2))+[observation("2002-01-14",-49)],startIndex:0,inverse:inverse)
            XCTAssertEqual(Array(a.prefix(10)),b);XCTAssertEqual(Array(a.prefix(16)),Array(shock.prefix(16)))
        }
    }
    func testRapidAtoBtoAAndCashExitDuringQuoteWaitAreDeliveredWithoutMaintenance() throws {
        let d=days(),o=[observation("2002-01-01",1),observation("2002-01-05",-1),observation("2002-01-06",1),observation("2002-01-10",0)]
        let s=try WorldGrainBalanceScreen.schedule(dates:d,observations:o,startIndex:0,inverse:false)
        let symbols=["gold_cny","nasdaq"],options=Dictionary(uniqueKeysWithValues:BacktestCoreDefaults.strategyAssetOptions.filter { symbols.contains($0.symbol) }.map { ($0.symbol,$0) })
        let observed=d.indices.map { ![7,8,11,12].contains($0) }
        let frame=MarketDataFrame(dates:d,pricesBySymbol:["gold_cny":Array(repeating:100,count:d.count),"nasdaq":Array(repeating:100,count:d.count)],observedBySymbol:["gold_cny":observed,"nasdaq":observed],ohlcBySymbol:[:],tradableSymbols:symbols,optionBySymbol:options,simulationRange:0...19)
        let (run,trace)=try WorldGrainBalanceScreen.simulate(frame:frame,signals:s)
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
        let s=try WorldGrainBalanceScreen.schedule(dates:d,observations:o,startIndex:0,inverse:false)
        let symbols=["gold_cny","nasdaq"],options=Dictionary(uniqueKeysWithValues:BacktestCoreDefaults.strategyAssetOptions.filter { symbols.contains($0.symbol) }.map { ($0.symbol,$0) })
        let frame=MarketDataFrame(dates:d,pricesBySymbol:["gold_cny":Array(repeating:100,count:d.count),"nasdaq":Array(repeating:100,count:d.count)],observedBySymbol:["gold_cny":Array(repeating:true,count:d.count),"nasdaq":Array(repeating:true,count:d.count)],ohlcBySymbol:[:],tradableSymbols:symbols,optionBySymbol:options,simulationRange:0...19)
        let (run,_)=try WorldGrainBalanceScreen.simulate(frame:frame,signals:s)
        XCTAssertEqual(run.trades.first { $0.action == .sell }!.date,d[7])
        XCTAssertEqual(run.trades.first { $0.assetSymbol=="gold_cny" && $0.action == .buy }!.date,d[8])
        XCTAssertThrowsError(try WorldGrainBalanceScreen.schedule(dates:d,observations:Array(o.reversed()),startIndex:0,inverse:false))
        XCTAssertThrowsError(try WorldGrainBalanceScreen.schedule(dates:d,observations:[.init(releaseDate:"2002-01-01",selectedVersionDate:"2002-01-01",knownAfter:d[0],marketingYear:"2001/02",production:101,totalUse:100,endingStocks:40)],startIndex:0,inverse:false))
        XCTAssertThrowsError(try WorldGrainBalanceScreen.schedule(dates:d,observations:[observation("2002-01-01",.nan)],startIndex:0,inverse:false))
    }
    func testUnknownCarryPreSeedAndVersionReleaseClock() throws {
        let d=days(),unknown=WorldGrainBalanceScreen.Observation(releaseDate:"2002-01-05",selectedVersionDate:"2002-01-05",knownAfter:d[6],marketingYear:"2001/02",production:nil,totalUse:nil,endingStocks:nil)
        let s=try WorldGrainBalanceScreen.schedule(dates:d,observations:[observation("2002-01-01",1),unknown],startIndex:4,inverse:false)
        XCTAssertTrue(s[4].weights.isEmpty);XCTAssertEqual(s[5].weights,["nasdaq":1])
        XCTAssertEqual(s[7].latestReportDate,"2002-01-05");XCTAssertEqual(s[7].releaseDate,"2002-01-01")
        XCTAssertEqual(s[7].production,101);XCTAssertEqual(s[7].totalUse,100)
        let corrected=WorldGrainBalanceScreen.Observation(releaseDate:"2002-01-05",selectedVersionDate:"2002-01-08",knownAfter:d[9],marketingYear:"2001/02",production:90,totalUse:100,endingStocks:40)
        let later=try WorldGrainBalanceScreen.schedule(dates:d,observations:[observation("2002-01-01",1),corrected],startIndex:0,inverse:false)
        XCTAssertEqual(later[9].weights,["nasdaq":1]);XCTAssertEqual(later[10].weights,["gold_cny":1])
        XCTAssertEqual(later[10].selectedVersionDate,"2002-01-08")
        let badClock=WorldGrainBalanceScreen.Observation(releaseDate:"2002-01-05",selectedVersionDate:"2002-01-08",knownAfter:d[6],marketingYear:"2001/02",production:90,totalUse:100,endingStocks:40)
        XCTAssertThrowsError(try WorldGrainBalanceScreen.schedule(dates:d,observations:[badClock],startIndex:0,inverse:false))
        let only=try WorldGrainBalanceScreen.schedule(dates:d,observations:[unknown],startIndex:0,inverse:false)
        XCTAssertTrue(only.allSatisfy { $0.weights.isEmpty && $0.releaseDate==nil })
        for value in [0.0,Double.nan] {
            let bad=WorldGrainBalanceScreen.Observation(releaseDate:"2002-01-01",selectedVersionDate:"2002-01-01",knownAfter:d[2],marketingYear:"2001/02",production:value,totalUse:100,endingStocks:40)
            XCTAssertThrowsError(try WorldGrainBalanceScreen.schedule(dates:d,observations:[bad],startIndex:0,inverse:false))
        }
    }
    func testMarketingYearRollAndStockLevelDoNotOverrideRawProductionUseSign() throws {
        let d=days()
        let newYear=WorldGrainBalanceScreen.Observation(releaseDate:"2002-01-05",selectedVersionDate:"2002-01-05",knownAfter:d[6],marketingYear:"2002/03",production:90,totalUse:100,endingStocks:999)
        let s=try WorldGrainBalanceScreen.schedule(dates:d,observations:[observation("2002-01-01",1),newYear],startIndex:0,inverse:false)
        XCTAssertEqual(s[6].marketingYear,"2001/02");XCTAssertEqual(s[7].marketingYear,"2002/03")
        XCTAssertEqual(s[7].weights,["gold_cny":1]);XCTAssertEqual(s[7].endingStocks,999)
        let partial=WorldGrainBalanceScreen.Observation(releaseDate:"2002-01-01",selectedVersionDate:"2002-01-01",knownAfter:d[2],marketingYear:"2001/02",production:101,totalUse:nil,endingStocks:40)
        XCTAssertThrowsError(try WorldGrainBalanceScreen.schedule(dates:d,observations:[partial],startIndex:0,inverse:false))
    }
}
