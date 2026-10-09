import Foundation
import AssetTimeMachineBacktestCore

/// Fixed original total-industry utilization versus its own-report mean; inverse is diagnostic only.
public enum CapacityTightnessScreen {
    public struct Observation:Decodable,Equatable {
        public let releaseDate:String;public let referenceMonth:String;public let knownAfter:Date
        public let utilization:Double?;public let average:Double?
        public let averagingStartYear:Int;public let averagingEndYear:Int
        public init(releaseDate:String,referenceMonth:String,knownAfter:Date,utilization:Double?,average:Double?,averagingStartYear:Int,averagingEndYear:Int) {
            self.releaseDate=releaseDate;self.referenceMonth=referenceMonth;self.knownAfter=knownAfter
            self.utilization=utilization;self.average=average;self.averagingStartYear=averagingStartYear;self.averagingEndYear=averagingEndYear
        }
        enum CodingKeys:String,CodingKey {
            case releaseDate="release_date",referenceMonth="reference_month",knownAfter="availability_date"
            case utilization="current_capacity_utilization_percent",average="same_report_long_run_average_percent"
            case averagingStartYear="averaging_start_year",averagingEndYear="averaging_end_year"
        }
        public init(from decoder:Decoder) throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            releaseDate=try c.decode(String.self,forKey:.releaseDate);referenceMonth=try c.decode(String.self,forKey:.referenceMonth)
            utilization=try c.decodeIfPresent(Double.self,forKey:.utilization);average=try c.decodeIfPresent(Double.self,forKey:.average)
            averagingStartYear=try c.decode(Int.self,forKey:.averagingStartYear);averagingEndYear=try c.decode(Int.self,forKey:.averagingEndYear)
            let value=try c.decode(String.self,forKey:.knownAfter)
            guard let d=BacktestSeriesAlignment.historicalSeriesDate(from:value),BacktestSeriesAlignment.historicalSeriesDateString(from:d)==value else {
                throw BacktestConfigurationError.invalidParameter("Capacity tightness availability date")
            }
            knownAfter=d
        }
    }
    public struct Signal:Codable,Equatable {
        public let date:Date;public let signalDate:Date;public let latestReportDate:String?
        public let releaseDate:String?;public let referenceMonth:String?;public let knownAfter:Date?
        public let utilization:Double?;public let average:Double?;public let averagingStartYear:Int?;public let averagingEndYear:Int?
        public let weights:[String:Double]
    }
    public static func schedule(dates:[Date],observations:[Observation],startIndex:Int,inverse:Bool) throws -> [Signal] {
        guard startIndex>=0,startIndex+1<dates.count,!observations.isEmpty,
              zip(dates,dates.dropFirst()).allSatisfy({ $0<$1 }),
              zip(observations,observations.dropFirst()).allSatisfy({ $0.knownAfter<$1.knownAfter && $0.releaseDate<$1.releaseDate && $0.referenceMonth<$1.referenceMonth }),
              observations.allSatisfy({ o in
                  guard let release=BacktestSeriesAlignment.historicalSeriesDate(from:o.releaseDate),
                        BacktestSeriesAlignment.historicalSeriesDateString(from:release)==o.releaseDate,
                        let reference=BacktestSeriesAlignment.historicalSeriesDate(from:o.referenceMonth+"-01"),
                        BacktestSeriesAlignment.historicalSeriesDateString(from:reference)==o.referenceMonth+"-01",
                        o.referenceMonth<String(o.releaseDate.prefix(7)),let referenceYear=Int(o.referenceMonth.prefix(4)),
                        o.averagingStartYear>0,o.averagingStartYear<o.averagingEndYear,o.averagingEndYear<=referenceYear,
                        o.knownAfter==BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding:.day,value:2,to:release) else { return false }
                  if let current=o.utilization,let average=o.average {
                      return current.isFinite && average.isFinite && (0...100).contains(current) && (0...100).contains(average)
                  }
                  return o.utilization==nil && o.average==nil
              }) else { throw BacktestConfigurationError.invalidParameter("Capacity tightness ordered original fields/reference/period/release clock") }
        var cursor=0,latestReport:Observation?,latest:Observation?
        return dates.indices.map { i in
            let known=dates[max(0,i-1)]
            while cursor<observations.count && observations[cursor].knownAfter<=known {
                latestReport=observations[cursor]
                if observations[cursor].utilization != nil { latest=observations[cursor] }
                cursor+=1
            }
            let w:[String:Double]
            if i<=startIndex || latest==nil || latest!.utilization==latest!.average { w=[:] }
            else { w=[(latest!.utilization!>latest!.average!) != inverse ? "gold_cny":"nasdaq":1] }
            return .init(date:dates[i],signalDate:known,latestReportDate:latestReport?.releaseDate,
                         releaseDate:latest?.releaseDate,referenceMonth:latest?.referenceMonth,knownAfter:latest?.knownAfter,
                         utilization:latest?.utilization,average:latest?.average,
                         averagingStartYear:latest?.averagingStartYear,averagingEndYear:latest?.averagingEndYear,weights:w)
        }
    }
    public struct Decision: Codable {
        public let index:Int;public let date:Date;public let signalDate:Date
        public let latestReportDate:String?;public let releaseDate:String?;public let desired:[String:Double];public let submitted:Bool
    }
    public static func simulate(frame:MarketDataFrame,signals:[Signal]) throws -> (BacktestDailySimulationResult,[Decision]) {
        guard signals.count==frame.dates.count,zip(signals,frame.dates).allSatisfy({ $0.date==$1 }),
              signals.allSatisfy({ $0.weights.isEmpty || ($0.weights.count==1 && $0.weights.allSatisfy { ["gold_cny","nasdaq"].contains($0.key) && $0.value==1 }) }) else {
            throw BacktestConfigurationError.invalidParameter("Capacity tightness signal/frame and unlevered target invariants")
        }
        var submitted:[String:Double]?,trace:[Decision]=[]
        let execution=BacktestExecutionConfig(initialCash:100000,feeRate:0.00025,slippageRate:0,rebalanceBand:0,
            financingAnnualRate:0,allowsFinancedExposure:false,buyReason:"fixed original capacity utilization versus own-report average")
        guard let run=BacktestDailySimulator.run(frame:frame,execution:execution,provider:.init { signals[$0.index].weights },
            rebalanceDecision:{ _,_ in .init(shouldRebalance:false,refreshOverlay:false) },
            contextualRebalanceDecision:{ c in
                let s=signals[c.index],changed=submitted==nil || submitted != s.weights
                if changed { submitted=s.weights }
                trace.append(.init(index:c.index,date:c.date,signalDate:c.signalDate,latestReportDate:s.latestReportDate,releaseDate:s.releaseDate,desired:s.weights,submitted:changed))
                return .init(shouldRebalance:changed,refreshOverlay:false)
            }) else { throw BacktestConfigurationError.computationFailed }
        guard run.dailyStates.count==frame.simulationRange.count,
              run.dailyStates.enumerated().allSatisfy({ $0.element.targetWeights==signals[frame.simulationRange.lowerBound+$0.offset].weights }),
              run.dailyStates.allSatisfy({ $0.cash.isFinite && $0.cash>=0 && $0.portfolioValue.isFinite && $0.portfolioValue>0 && $0.holdingsBySymbol.values.allSatisfy { $0.isFinite && $0>=0 } && $0.holdingsBySymbol.values.reduce(0,+)<=$0.portfolioValue+1e-8 }) else {
            throw BacktestConfigurationError.invalidParameter("capacity tightness target transport")
        }
        return (run,trace)
    }
    private struct Input:Decodable { let schema_version:Int;let records:[Observation] }
    private struct Controls:Decodable { let schema:String;let path:String;let sha256:String;let ids:[String] }
    private struct Saved:Decodable {
        let id:String;let dailyStates:[BacktestDailyState];let trades:[Trade]
        struct Trade:Decodable {
            let date:Date;let symbol:String;let action:String;let price:Double;let cashAmount:Double;let units:Double
            func restored() throws -> AdvancedBacktestTrade {
                guard let a=AdvancedBacktestTradeAction(rawValue:action) else { throw BacktestConfigurationError.invalidParameter("Saved control fill") }
                return .init(assetSymbol:symbol,assetTitle:symbol,date:date,action:a,price:price,cashAmount:cashAmount,units:units,
                    reason:"Saved immutable control fill",realizedProfit:nil,realizedReturn:nil,holdingDays:nil)
            }
        }
    }
    public static func run(historyPath:String,observationsPath:String,accountsPath:String,outputPath:String,sourceCommit:String) throws {
        let output=URL(fileURLWithPath:outputPath)
        guard !FileManager.default.fileExists(atPath:output.path) else { throw CocoaError(.fileWriteFileExists) }
        let history=try Data(contentsOf:URL(fileURLWithPath:historyPath)),obsRaw=try Data(contentsOf:URL(fileURLWithPath:observationsPath)),controlsRaw=try Data(contentsOf:URL(fileURLWithPath:accountsPath))
        guard ResearchRunEvidence.sha256(history)=="86c62407994fdc49ec41ba891a44373201335a4ff0670310a6098c2b1de2dedb",
              ResearchRunEvidence.sha256(obsRaw)=="e6aad971a449a7204fad016d3c71be074c9c58d7cefe9c521c8014186f28e8c7" else {
            throw BacktestConfigurationError.invalidParameter("Capacity tightness frozen history/source hashes")
        }
        let obs=try JSONDecoder().decode(Input.self,from:obsRaw);guard obs.schema_version==1,obs.records.count==291,obs.records.allSatisfy({ $0.utilization != nil }) else { throw BacktestConfigurationError.invalidParameter("capacity tightness frozen source coverage") }
        let sources=try JSONDecoder().decode(Controls.self,from:controlsRaw)
        guard sources.schema=="capacity-saved40-controls-v1",sources.ids.count==40 else { throw BacktestConfigurationError.invalidParameter("capacity tightness saved control budget") }
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let savedRaw=try Data(contentsOf:URL(fileURLWithPath:sources.path))
        guard sources.sha256=="aaa0c9a2dc95f59fe4172647d138007e5096185702fb555c4c1d408936fe69a1",ResearchRunEvidence.sha256(savedRaw)==sources.sha256 else { throw BacktestConfigurationError.invalidParameter("capacity tightness controls hash") }
        let saved=try decoder.decode([Saved].self,from:savedRaw)
        guard saved.map(\.id)==sources.ids,Set(sources.ids).count==40,sources.ids.suffix(20)==BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs + ["nfci-dual-core-v11-qual-role"] else { throw BacktestConfigurationError.invalidParameter("capacity tightness all prior 20 and saved App20") }
        let dataset=try PublicBacktestCore.loadDataset(from:history,datasetHash:ResearchRunEvidence.sha256(history),dataStale:false)
        let reference=try StrategyRegistry.definition(id:"gold-nasdaq-dual-trend-barbell")
        let inputs=BacktestCoreStrategyDefaults.assetOptions(for:reference.template).map { MarketInputPreparation.advancedAssetInput(for:$0) { dataset.seriesBySymbol[$0] } }
        let lower=MarketInputPreparation.availableDateBounds(for:inputs.flatMap { [$0.assetSeries,$0.fxSeries].compactMap { $0 } })!.lowerBound
        let end=BacktestSeriesAlignment.historicalSeriesDate(from:"2026-10-06")!
        let config=ResearchTargetStrategyConfig(symbol:"single-indicator",title:"single-indicator",warmupSessions:252,rebalanceSessions:1)
        guard let frame=TargetProviderBacktest.researchMarketDataFrame(assetInputs:inputs,config:config,dateBounds:lower...end) else { throw BacktestConfigurationError.missingData("capacity tightness original full frame") }
        guard frame.simulationRange.count==6032 else { throw BacktestConfigurationError.invalidParameter("Capacity tightness frozen native frame") }
        struct Account { let id:String;let states:[BacktestDailyState];let trades:[AdvancedBacktestTrade] }
        var accounts:[Account]=[],schedules:[String:[Signal]]=[:],decisions:[String:[Decision]]=[:]
        for (id,inverse) in [("gold-nasdaq:capacity-tightness-sign",false),("gold-nasdaq:capacity-tightness-inverse-diagnostic",true)] {
            let signals=try schedule(dates:frame.dates,observations:obs.records,startIndex:frame.simulationRange.lowerBound,inverse:inverse)
            let (run,trace)=try simulate(frame:frame,signals:signals)
            accounts.append(.init(id:id,states:run.dailyStates,trades:run.trades));schedules[id]=signals;decisions[id]=trace
        }
        for a in saved { accounts.append(.init(id:a.id,states:a.dailyStates,trades:try a.trades.map { try $0.restored() })) }
        let text=BacktestSeriesAlignment.historicalSeriesDateString(from:)
        func compare(_ selected:[Account]) throws -> ([DailyScreenOutput.Row],[Date]) {
            let common=selected.reduce(Set(selected[0].states.map(\.date))) { $0.intersection(Set($1.states.map(\.date))) }.sorted()
            guard common.count>252 else { throw BacktestConfigurationError.missingData("capacity tightness full common calendar") }
            let set=Set(common),first=common.first!,last=common.last!,ten=BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding:.year,value:-10,to:last)!
            let windows=[("full",text(first),text(last)),("trailing10Y",text(ten),text(last)),("since2020","2020-01-01",text(last)),("since2022","2022-01-01",text(last)),("crisis2008","2008-01-01","2008-12-31"),("crisis2020","2020-01-01","2020-12-31"),("crisis2022","2022-01-01","2022-12-31")]
            return (try selected.map { try DailyScreenOutput.row($0.id,states:$0.states.filter { set.contains($0.date) },trades:$0.trades,windows:windows) },common)
        }
        let (long,longDates)=try compare(Array(accounts.dropLast())),(all20,allDates)=try compare(accounts)
        guard accounts.count==42,long.count==41,all20.count==42,longDates.count==5595,allDates.count==3086 else {
            throw BacktestConfigurationError.invalidParameter("Capacity tightness frozen account and matched-calendar counts")
        }
        let native=try accounts.map { try DailyScreenOutput.row($0.id,states:$0.states,trades:$0.trades,windows:[("native_full",text($0.states.first!.date),text($0.states.last!.date))]) }
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let result=try encoder.encode(long)
        let evidence:[String:Any]=["completed_at":ISO8601DateFormatter().string(from:Date()),"source_commit":sourceCommit,"evidence_class":"D0_FIXED_ORIGINAL_CAPACITY_TIGHTNESS","formal_validation":false,"candidate_count":1,"inverse_controls":1,"new_funded_accounts":2,"saved_controls":40,"saved_App_controls":20,"parameter_search_budget":0,"annual_selectors":0,"fee_percent":0.025,"slippage_percent":0,"execution_version":BacktestExecutionVersion.defaultEngineVersion,"history_sha256":ResearchRunEvidence.sha256(history),"observations_sha256":ResearchRunEvidence.sha256(obsRaw),"accounts_sha256":ResearchRunEvidence.sha256(controlsRaw),"result_sha256":ResearchRunEvidence.sha256(result),"long_dates":longDates.map(text),"all20_dates":allDates.map(text),"binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath())),"limitations":["Previously exposed history, not pristine OOS or formal G0-G6 validation.","Original latest-reference total-industry capacity utilization versus the same-report historical mean. Original release date+2 and T1; changing original averaging periods retained. Historical mean is descriptive, not a binding capacity or inflation threshold. Three malformed original timezone labels retain date-only availability.","Original index price/FX proxies, no independently certified tradable total-return history.","One raw-field comparison policy; inverse is diagnostic, never selectable. No post-result sector, baseline, threshold, ratio, lag, direction, weight, asset, execution or time-crop rescue."]]
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for (name,data) in [("result.json",result),("all20.json",try encoder.encode(all20)),("native-full.json",try encoder.encode(native)),("signals.json",try encoder.encode(schedules)),("decisions.json",try encoder.encode(decisions))] { try data.write(to:output.appendingPathComponent(name)) }
        try JSONSerialization.data(withJSONObject:["dates":frame.dates.map(text),"prices":frame.pricesBySymbol,"observed":frame.observedBySymbol,"simulation_first":frame.simulationRange.lowerBound,"simulation_last":frame.simulationRange.upperBound],options:[.sortedKeys]).write(to:output.appendingPathComponent("frame.json"))
        try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("evidence.json"))
        print("Capacity tightness:1candidate+1inverse,40savedcontrols;long\(longDates.count),all20\(allDates.count)")
    }
}
