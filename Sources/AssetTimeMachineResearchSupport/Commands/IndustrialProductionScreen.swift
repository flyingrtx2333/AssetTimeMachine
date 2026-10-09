import Foundation
import AssetTimeMachineBacktestCore

/// One preregistered real-output sign policy and a non-selectable inverse diagnostic.
public enum IndustrialProductionScreen {
    public struct Observation: Decodable, Equatable {
        public let releaseDate: String
        public let knownAfter: Date
        public let referenceMonth: String
        public let yoy: Double
        public init(releaseDate: String, knownAfter: Date, referenceMonth: String, yoy: Double) {
            self.releaseDate=releaseDate; self.knownAfter=knownAfter; self.referenceMonth=referenceMonth; self.yoy=yoy
        }
        enum CodingKeys: String,CodingKey {
            case releaseDate="release_date",knownAfter="conservative_signal_not_before",referenceMonth="reference_month",yoy="yoy_percent"
        }
        public init(from decoder: Decoder) throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            releaseDate=try c.decode(String.self,forKey:.releaseDate)
            referenceMonth=try c.decode(String.self,forKey:.referenceMonth)
            yoy=try c.decode(Double.self,forKey:.yoy)
            guard let d=BacktestSeriesAlignment.historicalSeriesDate(from:try c.decode(String.self,forKey:.knownAfter)) else {
                throw BacktestConfigurationError.invalidParameter("G17 known date")
            }
            knownAfter=d
        }
    }
    public struct Signal: Codable,Equatable {
        public let date: Date; public let signalDate: Date
        public let releaseDate: String?; public let referenceMonth: String?; public let knownAfter: Date?
        public let yoy: Double?; public let weights: [String:Double]
    }
    public static func schedule(dates:[Date],observations:[Observation],startIndex:Int,inverse:Bool) throws -> [Signal] {
        guard startIndex>=0,startIndex+1<dates.count,!observations.isEmpty,
              zip(dates,dates.dropFirst()).allSatisfy({ $0<$1 }),
              zip(observations,observations.dropFirst()).allSatisfy({ $0.knownAfter<$1.knownAfter }),
              observations.allSatisfy({ o in
                  guard o.yoy.isFinite,abs(o.yoy)<50,let release=BacktestSeriesAlignment.historicalSeriesDate(from:o.releaseDate) else { return false }
                  return o.knownAfter==BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding:.day,value:2,to:release)
              }) else {
            throw BacktestConfigurationError.invalidParameter("G17 ordered finite input")
        }
        var cursor=0,latest:Observation?
        return dates.indices.map { i in
            let known=dates[max(0,i-1)]
            while cursor<observations.count && observations[cursor].knownAfter<=known { latest=observations[cursor];cursor+=1 }
            let w:[String:Double]
            if i<=startIndex || latest==nil || latest!.yoy==0 { w=[:] }
            else { w=[(latest!.yoy>0) != inverse ? "nasdaq":"gold_cny":1] }
            return .init(date:dates[i],signalDate:known,releaseDate:latest?.releaseDate,referenceMonth:latest?.referenceMonth,
                         knownAfter:latest?.knownAfter,yoy:latest?.yoy,weights:w)
        }
    }
    public struct Decision: Codable {
        public let index:Int;public let date:Date;public let signalDate:Date
        public let releaseDate:String?;public let desired:[String:Double];public let submitted:Bool
    }
    public static func simulate(frame:MarketDataFrame,signals:[Signal]) throws -> (BacktestDailySimulationResult,[Decision]) {
        var submitted:[String:Double]?,trace:[Decision]=[]
        let execution=BacktestExecutionConfig(initialCash:100000,feeRate:0.00025,slippageRate:0,rebalanceBand:0,
            financingAnnualRate:0,allowsFinancedExposure:false,buyReason:"fixed G17 real-output sign")
        guard let run=BacktestDailySimulator.run(frame:frame,execution:execution,provider:.init { signals[$0.index].weights },
            rebalanceDecision:{ _,_ in .init(shouldRebalance:false,refreshOverlay:false) },
            contextualRebalanceDecision:{ c in
                let s=signals[c.index],changed=submitted==nil || submitted != s.weights
                if changed { submitted=s.weights }
                trace.append(.init(index:c.index,date:c.date,signalDate:c.signalDate,releaseDate:s.releaseDate,desired:s.weights,submitted:changed))
                return .init(shouldRebalance:changed,refreshOverlay:false)
            }) else { throw BacktestConfigurationError.computationFailed }
        guard run.dailyStates.enumerated().allSatisfy({ $0.element.targetWeights==signals[frame.simulationRange.lowerBound+$0.offset].weights }) else {
            throw BacktestConfigurationError.invalidParameter("G17 target transport")
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
        let obs=try JSONDecoder().decode(Input.self,from:obsRaw);guard obs.schema_version==1,obs.records.count==291 else { throw BacktestConfigurationError.invalidParameter("G17 frozen source coverage") }
        let sources=try JSONDecoder().decode(Controls.self,from:controlsRaw)
        guard sources.schema=="g17-saved34-controls-v1",sources.ids.count==34 else { throw BacktestConfigurationError.invalidParameter("G17 saved control budget") }
        let dataset=try PublicBacktestCore.loadDataset(from:history,datasetHash:ResearchRunEvidence.sha256(history),dataStale:false)
        let reference=try StrategyRegistry.definition(id:"gold-nasdaq-dual-trend-barbell")
        let inputs=BacktestCoreStrategyDefaults.assetOptions(for:reference.template).map { MarketInputPreparation.advancedAssetInput(for:$0) { dataset.seriesBySymbol[$0] } }
        let lower=MarketInputPreparation.availableDateBounds(for:inputs.flatMap { [$0.assetSeries,$0.fxSeries].compactMap { $0 } })!.lowerBound
        let end=BacktestSeriesAlignment.historicalSeriesDate(from:"2026-10-06")!
        let config=ResearchTargetStrategyConfig(symbol:"single-indicator",title:"single-indicator",warmupSessions:252,rebalanceSessions:1)
        guard let frame=TargetProviderBacktest.researchMarketDataFrame(assetInputs:inputs,config:config,dateBounds:lower...end) else { throw BacktestConfigurationError.missingData("G17 original full frame") }
        struct Account { let id:String;let states:[BacktestDailyState];let trades:[AdvancedBacktestTrade] }
        var accounts:[Account]=[],schedules:[String:[Signal]]=[:],decisions:[String:[Decision]]=[:]
        for (id,inverse) in [("gold-nasdaq:g17-yoy-sign",false),("gold-nasdaq:g17-yoy-inverse-diagnostic",true)] {
            let signals=try schedule(dates:frame.dates,observations:obs.records,startIndex:frame.simulationRange.lowerBound,inverse:inverse)
            let (run,trace)=try simulate(frame:frame,signals:signals)
            accounts.append(.init(id:id,states:run.dailyStates,trades:run.trades));schedules[id]=signals;decisions[id]=trace
        }
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let savedRaw=try Data(contentsOf:URL(fileURLWithPath:sources.path))
        guard ResearchRunEvidence.sha256(savedRaw)==sources.sha256 else { throw BacktestConfigurationError.invalidParameter("G17 controls hash") }
        let saved=try decoder.decode([Saved].self,from:savedRaw)
        guard saved.map(\.id)==sources.ids,Set(sources.ids).count==34,sources.ids.suffix(20)==BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs + ["nfci-dual-core-v11-qual-role"] else { throw BacktestConfigurationError.invalidParameter("G17 all prior 14 and saved App20") }
        for a in saved { accounts.append(.init(id:a.id,states:a.dailyStates,trades:try a.trades.map { try $0.restored() })) }
        let text=BacktestSeriesAlignment.historicalSeriesDateString(from:)
        func compare(_ selected:[Account]) throws -> ([DailyScreenOutput.Row],[Date]) {
            let common=selected.reduce(Set(selected[0].states.map(\.date))) { $0.intersection(Set($1.states.map(\.date))) }.sorted()
            guard common.count>252 else { throw BacktestConfigurationError.missingData("G17 full common calendar") }
            let set=Set(common),first=common.first!,last=common.last!,ten=BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding:.year,value:-10,to:last)!
            let windows=[("full",text(first),text(last)),("trailing10Y",text(ten),text(last)),("since2020","2020-01-01",text(last)),("since2022","2022-01-01",text(last)),("crisis2008","2008-01-01","2008-12-31"),("crisis2020","2020-01-01","2020-12-31"),("crisis2022","2022-01-01","2022-12-31")]
            return (try selected.map { try DailyScreenOutput.row($0.id,states:$0.states.filter { set.contains($0.date) },trades:$0.trades,windows:windows) },common)
        }
        let (long,longDates)=try compare(Array(accounts.dropLast())),(all20,allDates)=try compare(accounts)
        let native=try accounts.map { try DailyScreenOutput.row($0.id,states:$0.states,trades:$0.trades,windows:[("native_full",text($0.states.first!.date),text($0.states.last!.date))]) }
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let result=try encoder.encode(long)
        let evidence:[String:Any]=["completed_at":ISO8601DateFormatter().string(from:Date()),"source_commit":sourceCommit,"evidence_class":"D0_FIXED_ORIGINAL_G17_REAL_OUTPUT_SIGN","formal_validation":false,"candidate_count":1,"inverse_controls":1,"new_funded_accounts":2,"saved_controls":34,"saved_App_controls":20,"parameter_search_budget":0,"annual_selectors":0,"fee_percent":0.025,"slippage_percent":0,"execution_version":BacktestExecutionVersion.defaultEngineVersion,"history_sha256":ResearchRunEvidence.sha256(history),"observations_sha256":ResearchRunEvidence.sha256(obsRaw),"accounts_sha256":ResearchRunEvidence.sha256(controlsRaw),"result_sha256":ResearchRunEvidence.sha256(result),"long_dates":longDates.map(text),"all20_dates":allDates.map(text),"binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath())),"limitations":["Previously exposed history, not pristine OOS or formal G0-G6 validation.","Official dated monthly releases, date+2 buffer and T1 execution; three malformed source clock labels retained as unknown. Annual revisions ignored until next monthly report.","Original index price/FX proxies, no independently certified tradable total-return history.","One zero-axis sign policy; inverse is a diagnostic, never selectable. No post-result threshold, lag, transformation, allocation or execution rescue."]]
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for (name,data) in [("result.json",result),("all20.json",try encoder.encode(all20)),("native-full.json",try encoder.encode(native)),("signals.json",try encoder.encode(schedules)),("decisions.json",try encoder.encode(decisions))] { try data.write(to:output.appendingPathComponent(name)) }
        try JSONSerialization.data(withJSONObject:["dates":frame.dates.map(text),"prices":frame.pricesBySymbol,"observed":frame.observedBySymbol,"simulation_first":frame.simulationRange.lowerBound,"simulation_last":frame.simulationRange.upperBound],options:[.sortedKeys]).write(to:output.appendingPathComponent("frame.json"))
        try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("evidence.json"))
        print("G17:1candidate+1inverse,34savedcontrols;long\(longDates.count),all20\(allDates.count)")
    }
}
