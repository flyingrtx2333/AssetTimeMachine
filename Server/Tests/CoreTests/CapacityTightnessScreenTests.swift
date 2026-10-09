import XCTest
import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport

final class CapacityTightnessScreenTests:XCTestCase {
    private func date(_ s:String)->Date { BacktestSeriesAlignment.historicalSeriesDate(from:s)! }
    private func days()->[Date] { (0..<20).map { date("2002-01-01").addingTimeInterval(Double($0)*86400) } }
    private func observation(_ release:String,_ gap:Double)->CapacityTightnessScreen.Observation {
        let calendar=BacktestSeriesAlignment.historicalSeriesCalendar
        let day=calendar.component(.day,from:date(release))
        let ref=calendar.date(byAdding:.month,value:day-1,to:date("2000-01-01"))!
        return .init(releaseDate:release,referenceMonth:String(BacktestSeriesAlignment.historicalSeriesDateString(from:ref).prefix(7)),
                     knownAfter:calendar.date(byAdding:.day,value:2,to:date(release))!,utilization:80+gap,average:80,averagingStartYear:1967,averagingEndYear:1999)
    }
    private func frame(_ d:[Date],missing:Set<Int>=[])->MarketDataFrame {
        let symbols=["gold_cny","nasdaq"]
        let options=Dictionary(uniqueKeysWithValues:BacktestCoreDefaults.strategyAssetOptions.filter { symbols.contains($0.symbol) }.map { ($0.symbol,$0) })
        let observed=d.indices.map { !missing.contains($0) }
        return .init(dates:d,pricesBySymbol:Dictionary(uniqueKeysWithValues:symbols.map { ($0,Array(repeating:100,count:d.count)) }),
                     observedBySymbol:Dictionary(uniqueKeysWithValues:symbols.map { ($0,observed) }),ohlcBySymbol:[:],tradableSymbols:symbols,
                     optionBySymbol:options,simulationRange:0...(d.count-1))
    }
    func testPublicationBufferT1RawComparisonEqualityAndHold() throws {
        let d=days(),o=[observation("2002-01-01",1),observation("2002-01-05",-1),observation("2002-01-09",0)]
        let s=try CapacityTightnessScreen.schedule(dates:d,observations:o,startIndex:0,inverse:false)
        XCTAssertTrue(s[0].weights.isEmpty);XCTAssertTrue(s[2].weights.isEmpty)
        XCTAssertEqual(s[3].weights,["gold_cny":1]);XCTAssertEqual(s[6].weights,["gold_cny":1])
        XCTAssertEqual(s[7].weights,["nasdaq":1]);XCTAssertTrue(s[11].weights.isEmpty)
        let inverse=try CapacityTightnessScreen.schedule(dates:d,observations:o,startIndex:0,inverse:true)
        XCTAssertEqual(inverse[3].weights,["nasdaq":1]);XCTAssertEqual(inverse[7].weights,["gold_cny":1]);XCTAssertTrue(inverse[11].weights.isEmpty)
        for x in s where !x.weights.isEmpty { XCTAssertLessThanOrEqual(x.knownAfter!,x.signalDate);XCTAssertLessThan(x.signalDate,x.date) }
        let (run,trace)=try CapacityTightnessScreen.simulate(frame:frame(d),signals:s)
        XCTAssertEqual(run.trades.first!.date,d[3]);XCTAssertEqual(trace.filter(\.submitted).map(\.index),[0,3,7,11])
        let raw=CapacityTightnessScreen.Observation(releaseDate:"2002-01-01",referenceMonth:"2000-01",knownAfter:d[2],
            utilization:79.5000001,average:79.5,averagingStartYear:1967,averagingEndYear:1999)
        XCTAssertEqual(try CapacityTightnessScreen.schedule(dates:d,observations:[raw],startIndex:0,inverse:false)[3].weights,["gold_cny":1])
    }
    func testPrefixAndFutureObservationShockLeaveEarlierSignalsUnchanged() throws {
        let d=days(),o=[observation("2002-01-01",1),observation("2002-01-05",-1),observation("2002-01-14",2)]
        for inverse in [false,true] {
            let a=try CapacityTightnessScreen.schedule(dates:d,observations:o,startIndex:0,inverse:inverse)
            let b=try CapacityTightnessScreen.schedule(dates:Array(d.prefix(10)),observations:Array(o.prefix(2)),startIndex:0,inverse:inverse)
            let shock=try CapacityTightnessScreen.schedule(dates:d,observations:Array(o.prefix(2))+[observation("2002-01-14",-49)],startIndex:0,inverse:inverse)
            XCTAssertEqual(Array(a.prefix(10)),b);XCTAssertEqual(Array(a.prefix(16)),Array(shock.prefix(16)))
        }
    }
    func testQuoteWaitAtoBtoAAndCashExitDeliverLatestTargetWithoutMaintenance() throws {
        let d=days(),o=[observation("2002-01-01",1),observation("2002-01-05",-1),observation("2002-01-06",1),observation("2002-01-10",0)]
        let s=try CapacityTightnessScreen.schedule(dates:d,observations:o,startIndex:0,inverse:false)
        let (run,trace)=try CapacityTightnessScreen.simulate(frame:frame(d,missing:[7,8,11,12]),signals:s)
        XCTAssertEqual(trace.filter(\.submitted).map(\.index),[0,3,7,8,12])
        XCTAssertFalse(run.trades.contains { $0.assetSymbol=="nasdaq" })
        XCTAssertEqual(run.trades.first { $0.action == .sell }!.date,d[13])
        XCTAssertTrue(run.dailyStates.last!.holdingsBySymbol.isEmpty)
        for (i,state) in run.dailyStates.enumerated() {
            XCTAssertEqual(state.targetWeights,s[i].weights);XCTAssertGreaterThanOrEqual(state.cash,0)
            XCTAssertLessThanOrEqual(state.holdingsBySymbol.values.reduce(0,+),state.portfolioValue+1e-8)
        }
        let buys=run.trades.filter { $0.action == .buy };XCTAssertEqual(buys.count,1)
        XCTAssertEqual(buys[0].units*buys[0].price,buys[0].cashAmount*0.99975,accuracy:1e-8)
        XCTAssertEqual(run.trades.count,2)
    }
    func testOrdinaryRotationWaitsForSettledSaleAndChargesBothFills() throws {
        let d=days(),s=try CapacityTightnessScreen.schedule(dates:days(),observations:[observation("2002-01-01",1),observation("2002-01-05",-1)],startIndex:0,inverse:false)
        let (run,trace)=try CapacityTightnessScreen.simulate(frame:frame(d),signals:s)
        let sale=run.trades.first { $0.action == .sell }!,buy=run.trades.first { $0.assetSymbol=="nasdaq" && $0.action == .buy }!
        XCTAssertEqual(sale.date,d[7]);XCTAssertEqual(buy.date,d[8]);XCTAssertEqual(run.trades.count,3)
        XCTAssertEqual(sale.cashAmount,sale.units*sale.price*0.99975,accuracy:1e-8)
        XCTAssertEqual(buy.units*buy.price,buy.cashAmount*0.99975,accuracy:1e-8)
        XCTAssertEqual(trace.filter(\.submitted).map(\.index),[0,3,7])
        XCTAssertTrue(run.dailyStates.allSatisfy { $0.cash>=0 && $0.holdingsBySymbol.values.reduce(0,+)<=$0.portfolioValue+1e-8 })
    }
    func testUnknownLatestReportCarriesValidPairAndPreSeedStartsInCash() throws {
        let d=days(),unknown=CapacityTightnessScreen.Observation(releaseDate:"2002-01-05",referenceMonth:"2000-05",knownAfter:d[6],
            utilization:nil,average:nil,averagingStartYear:1972,averagingEndYear:2000)
        let s=try CapacityTightnessScreen.schedule(dates:d,observations:[observation("2002-01-01",1),unknown],startIndex:4,inverse:false)
        XCTAssertTrue(s[4].weights.isEmpty);XCTAssertEqual(s[5].weights,["gold_cny":1])
        XCTAssertEqual(s[7].latestReportDate,"2002-01-05");XCTAssertEqual(s[7].releaseDate,"2002-01-01")
        XCTAssertEqual(s[7].referenceMonth,"2000-01");XCTAssertEqual(s[7].utilization,81);XCTAssertEqual(s[7].average,80)
        XCTAssertEqual(s[7].averagingStartYear,1967);XCTAssertEqual(s[7].averagingEndYear,1999)
        let only=try CapacityTightnessScreen.schedule(dates:d,observations:[unknown],startIndex:0,inverse:false)
        XCTAssertTrue(only.allSatisfy { $0.weights.isEmpty && $0.releaseDate==nil })
    }
    func testChangingOriginalMeanPeriodIsRetainedWithoutRecomputingEarlierState() throws {
        let d=days()
        let a=CapacityTightnessScreen.Observation(releaseDate:"2002-01-01",referenceMonth:"2000-01",knownAfter:d[2],utilization:80,average:79,averagingStartYear:1967,averagingEndYear:1999)
        let b=CapacityTightnessScreen.Observation(releaseDate:"2002-01-05",referenceMonth:"2000-05",knownAfter:d[6],utilization:80,average:81,averagingStartYear:1972,averagingEndYear:2000)
        let s=try CapacityTightnessScreen.schedule(dates:d,observations:[a,b],startIndex:0,inverse:false)
        let prefix=try CapacityTightnessScreen.schedule(dates:Array(d.prefix(7)),observations:[a],startIndex:0,inverse:false)
        XCTAssertEqual(Array(s.prefix(7)),prefix)
        XCTAssertEqual(s[6].weights,["gold_cny":1]);XCTAssertEqual(s[6].average,79);XCTAssertEqual(s[6].averagingStartYear,1967)
        XCTAssertEqual(s[7].weights,["nasdaq":1]);XCTAssertEqual(s[7].average,81);XCTAssertEqual(s[7].averagingStartYear,1972)
        XCTAssertEqual(s[7].utilization,80);XCTAssertEqual(s[7].referenceMonth,"2000-05")
    }
    func testRejectsPartialPairsNonfinitePercentBoundsAndBadOriginalMetadata() throws {
        let d=days(),good=observation("2002-01-01",1)
        func bad(_ current:Double?,_ average:Double?,ref:String="2000-01",start:Int=1967,end:Int=1999,known:Date?=nil)->CapacityTightnessScreen.Observation {
            .init(releaseDate:"2002-01-01",referenceMonth:ref,knownAfter:known ?? d[2],utilization:current,average:average,averagingStartYear:start,averagingEndYear:end)
        }
        for o in [bad(nil,80),bad(80,nil),bad(.nan,80),bad(80,.infinity),bad(-0.1,80),bad(80,100.1),bad(80,80,ref:""),
                  bad(80,80,ref:"2000-13"),bad(80,80,ref:"2002-01"),bad(80,80,start:1999,end:1999),bad(80,80,end:2001),bad(80,80,known:d[1])] {
            XCTAssertThrowsError(try CapacityTightnessScreen.schedule(dates:d,observations:[o],startIndex:0,inverse:false))
        }
        let later=observation("2002-01-05",-1)
        XCTAssertThrowsError(try CapacityTightnessScreen.schedule(dates:d,observations:[later,good],startIndex:0,inverse:false))
        let repeatedMonth=CapacityTightnessScreen.Observation(releaseDate:"2002-01-05",referenceMonth:good.referenceMonth,knownAfter:d[6],utilization:70,average:80,averagingStartYear:1967,averagingEndYear:1999)
        XCTAssertThrowsError(try CapacityTightnessScreen.schedule(dates:d,observations:[good,repeatedMonth],startIndex:0,inverse:false))
        XCTAssertThrowsError(try CapacityTightnessScreen.schedule(dates:[d[0],d[0],d[1]],observations:[good],startIndex:0,inverse:false))
        for boundary in [0.0,100.0] {
            let s=try CapacityTightnessScreen.schedule(dates:d,observations:[bad(boundary,boundary)],startIndex:0,inverse:false)
            XCTAssertTrue(s.allSatisfy { $0.weights.isEmpty })
        }
    }
    func testExactQualifiedSourceDecoderKeysIgnoreExtraEvidenceAndRejectBadAvailability() throws {
        let raw=Data("""
        {"release_date":"2002-01-01","reference_month":"2000-01","availability_date":"2002-01-03",
         "current_capacity_utilization_percent":81,"same_report_long_run_average_percent":80,
         "averaging_start_year":1967,"averaging_end_year":1999,"averaging_period":"1967-1999","extra_evidence":"ignored"}
        """.utf8)
        let o=try JSONDecoder().decode(CapacityTightnessScreen.Observation.self,from:raw)
        let s=try CapacityTightnessScreen.schedule(dates:days(),observations:[o],startIndex:0,inverse:false)
        XCTAssertEqual(s[3].weights,["gold_cny":1]);XCTAssertEqual(s[3].knownAfter,date("2002-01-03"))
        let malformed=Data(String(decoding:raw,as:UTF8.self).replacingOccurrences(of:"2002-01-03",with:"2002-01-99").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CapacityTightnessScreen.Observation.self,from:malformed))
    }
}
