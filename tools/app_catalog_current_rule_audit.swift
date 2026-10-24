import Foundation
import CryptoKit
import CoreFoundation
import AssetTimeMachineBacktestCore


// Encode/decode financial Double values directly. Foundation JSONSerialization can nudge their bits.
private enum ExactJSON: Codable {
    case object([String:ExactJSON]), array([ExactJSON]), string(String), number(Double), integer(Int64), bool(Bool), null
    init(any:Any) {
        if let x=any as? [String:Any] {self = .object(x.mapValues{ExactJSON(any:$0)})}
        else if let x=any as? [Any] {self = .array(x.map{ExactJSON(any:$0)})}
        else if let x=any as? String {self = .string(x)}
        else if let x=any as? NSNumber {
            if CFGetTypeID(x)==CFBooleanGetTypeID(){self = .bool(x.boolValue)}
            else if ["d","f"].contains(String(cString:x.objCType)){self = .number(x.doubleValue)}
            else {self = .integer(x.int64Value)}
        } else if any is NSNull {self = .null}
        else {preconditionFailure("Unsupported JSON value")}
    }
    init(from decoder:Decoder)throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil(){self = .null}
        else if let x=try? c.decode([String:ExactJSON].self){self = .object(x)}
        else if let x=try? c.decode([ExactJSON].self){self = .array(x)}
        else if let x=try? c.decode(String.self){self = .string(x)}
        else if let x=try? c.decode(Bool.self){self = .bool(x)}
        else {self = .number(try c.decode(Double.self))}
    }
    func encode(to encoder:Encoder)throws {
        var c=encoder.singleValueContainer()
        switch self {case .object(let x):try c.encode(x);case .array(let x):try c.encode(x);case .string(let x):try c.encode(x);case .number(let x):try c.encode(x);case .integer(let x):try c.encode(x);case .bool(let x):try c.encode(x);case .null:try c.encodeNil()}
    }
    var any:Any {
        switch self {case .object(let x):return x.mapValues{$0.any};case .array(let x):return x.map{$0.any};case .string(let x):return x;case .number(let x):return x;case .integer(let x):return x;case .bool(let x):return x;case .null:return NSNull()}
    }
}

@main struct CatalogCurrentRuleReplay {
    static let symbols = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
    static let encoder: JSONEncoder = { let e=JSONEncoder();e.dateEncodingStrategy = .iso8601;e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return e }()
    static func sha(_ d:Data)->String { SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined() }
    static func read(_ u:URL)throws->Data {try Data(contentsOf:u)}
    static func obj(_ u:URL)throws->[String:Any] {try JSONSerialization.jsonObject(with:read(u)) as! [String:Any]}
    static func write(_ x:Any,_ u:URL)throws { guard !FileManager.default.fileExists(atPath:u.path) else {throw error("existing "+u.path)};try encoder.encode(ExactJSON(any:x)).write(to:u,options:.atomic) }
    static func error(_ text:String)->NSError {NSError(domain:"PairCorrection",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
    static func require(_ ok:Bool,_ text:String)throws {if !ok {throw error(text)}}
    static func iso(_ d:Date)->String {ISO8601DateFormatter().string(from:d)}
    static func civil(_ d:Date)->String {BacktestSeriesAlignment.historicalSeriesDateString(from:d)}
    static func json<T:Encodable>(_ x:T)throws->Any {try JSONDecoder().decode(ExactJSON.self,from:encoder.encode(x)).any}
    static func same(_ a:Any,_ b:Any,excluding:Set<String>=[])->Bool {
        if let x=a as? [String:Any],let y=b as? [String:Any] {let keys=Set(x.keys).subtracting(excluding);return keys==Set(y.keys).subtracting(excluding) && keys.allSatisfy{same(x[$0]!,y[$0]!,excluding:excluding)}}
        if let x=a as? [Any],let y=b as? [Any] {return x.count==y.count && zip(x,y).allSatisfy{same($0,$1,excluding:excluding)}}
        if let x=a as? NSNumber,let y=b as? NSNumber {if CFGetTypeID(x)==CFBooleanGetTypeID() || CFGetTypeID(y)==CFBooleanGetTypeID(){return CFGetTypeID(x)==CFGetTypeID(y) && x.boolValue==y.boolValue};return x.doubleValue.bitPattern==y.doubleValue.bitPattern}
        if let x=a as? String,let y=b as? String{return x==y};return a is NSNull && b is NSNull
    }
    static func gross(_ w:[String:Double])->Double {symbols.sorted().reduce(0){$0+(w[$1] ?? 0)}}
    static func event(_ e:FrozenTargetEvent)->[String:Any] {["signalIndex":e.signalIndex,"signalDate":iso(e.signalDate),"targetWeights":e.targetWeights,"reason":e.reason]}
    static func z(_ frame:MarketDataFrame,_ n:String,_ d:String,_ j:Int)->Double? {
        guard j>=251,let np=frame.pricesBySymbol[n],let dp=frame.pricesBySymbol[d] else{return nil}
        var a:[Double]=[]
        for k in j-251...j {guard np[k]>0,dp[k]>0,np[k].isFinite,dp[k].isFinite else{return nil};a.append(log(np[k]/dp[k]))}
        let mean=a.reduce(0,+)/252;let dev=sqrt(max(a.reduce(0){$0+($1-mean)*($1-mean)}/251,0))
        return dev>1e-12 && dev.isFinite ? (a.last!-mean)/dev:nil
    }
    static func payload(_ run:AdvancedRotationStrategyRun)throws->[String:Any] {
        let r=run.report
        return ["annualized_return":r.annualizedReturn as Any? ?? NSNull(),"sharpe_rf0":r.sharpeRatio as Any? ?? NSNull(),"max_drawdown":r.maxDrawdown,"annualized_volatility":r.annualizedVolatility as Any? ?? NSNull(),"ending_value":r.finalPortfolioValue,"ending_cash":r.finalCash,"points":r.points.map{["date":iso($0.date),"value":$0.portfolioValue]},"trades":try json(r.trades.enumerated().map{BacktestRecordAdvancedTradePayload(trade:$0.element,sequence:$0.offset)}),"daily_states":try json(run.dailyStates)]
    }
    static func ledger(_ run:AdvancedRotationStrategyRun)throws->[String:Any] {
        var maxResidual=0.0,maxGross=0.0,totalFees=0.0,maxFeeError=0.0,firstRisk:String?;var earlyCash=0
        for s in run.dailyStates {
            try require(s.portfolioValue.isFinite && s.portfolioValue>0 && s.cash>=0,"cash/NAV invalid")
            try require(Set(s.holdingsBySymbol.keys).isSubset(of:Set(symbols)) && Set(s.targetWeights.keys).isSubset(of:Set(symbols)),"foreign instrument")
            try require(s.holdingsBySymbol.values.allSatisfy{$0.isFinite && $0>=0} && s.targetWeights.values.allSatisfy{$0.isFinite && $0>=0},"negative position")
            let held=s.holdingsBySymbol.values.reduce(0,+);maxResidual=max(maxResidual,abs(s.cash+held-s.portfolioValue));maxGross=max(maxGross,held/s.portfolioValue)
            try require(held/s.portfolioValue<=1+1e-12 && gross(s.targetWeights)<=1+1e-12,"leverage")
            if held>0.0001 && firstRisk==nil {firstRisk=iso(s.date)}
            if civil(s.date)<"2005-04-08" {try require((s.holdingsBySymbol["csi300"] ?? 0)==0 && (s.targetWeights["csi300"] ?? 0)==0,"prepublic CSI risk");if held==0 {earlyCash+=1}}
        }
        // Public daily holdings omit dust <=0.0001 per symbol; do not claim full unit-ledger exactness.
        try require(maxResidual<=0.00051,"cash+publishedholdings != NAV beyond documented dust")
        for t in run.report.trades {
            try require(symbols.contains(t.assetSymbol) && t.units>=0 && t.price>0,"invalid trade")
            if t.assetSymbol=="csi300" {try require(civil(t.date)>="2005-04-08","prepublic CSI trade")}
            let gross=t.units*t.price
            let mismatch=t.action == .buy ? abs(gross-t.cashAmount*0.99975):abs(t.cashAmount-gross*0.99975)
            maxFeeError=max(maxFeeError,mismatch);totalFees+=(t.action == .buy ? t.cashAmount:gross)*0.00025
        }
        try require(maxFeeError<1e-6,"actual fee/slippage formula")
        return ["status":"PASS_PUBLISHED_STATE_CASH_GROSS_ASSET_FEE_AND_DUST_BOUNDS","stateCount":run.dailyStates.count,"fills":run.report.trades.count,"firstRiskDate":firstRisk as Any? ?? NSNull(),"preCSIPublicAllCashStates":earlyCash,"maxPublishedLedgerResidual":maxResidual,"publishedDustLimitPerAsset":0.0001,"fullUnitsLedgerCertified":false,"maxActualGross":maxGross,"maxFeeCashFormulaError":maxFeeError,"sumFillFeesCNY":totalFees]
    }

    static func metric(_ points:[BacktestSeriesPoint])throws->[String:Any] {
        guard let m=BacktestMetricsCalculator.performanceMetrics(from:points) else {throw error("metrics")}
        return ["annualized_return":m.annualizedReturn as Any? ?? NSNull(),"sharpe_rf0":m.sharpeRatio as Any? ?? NSNull(),"max_drawdown":m.maxDrawdown,"start":iso(points.first!.date),"end":iso(points.last!.date),"points":points.count]
    }
    static func main(){do{try execute()}catch{fputs("CATALOG_AUDIT_FAILED: \(error)\n",stderr);exit(1)}}
    static func execute()throws {
        let p=URL(fileURLWithPath:CommandLine.arguments[1]);let storage=try obj(p.appendingPathComponent("STORAGE.json"));let b=URL(fileURLWithPath:storage["artifactRoot"] as! String)
        let admission=try obj(p.appendingPathComponent("RUN_AUTHORIZATION.json"));let bindings=admission["files"] as! [String:String]
        func check()throws {for(path,h) in bindings {try require(sha(read(URL(fileURLWithPath:path)))==h,"changed input "+path)}}
        try require(admission["status"] as? String=="ROOT_AUTHORIZED_APP_CATALOG_CURRENT_RULE_FINITE_REPLAY","admission");try check()
        let output=b.appendingPathComponent("run");try require(!FileManager.default.fileExists(atPath:output.path),"run exists");try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
        let raw=try read(b.appendingPathComponent("raw/public-history.json"));let fullDataset=try PublicBacktestCore.loadDataset(from:raw,datasetHash:sha(raw),dataStale:false)
        let all=AdvancedBacktestStrategyTemplate.productCatalog
        try require(all.count==25,"frozen product catalog count")
        let excluded=all.filter{$0.mode.requiresNFCIAsOf};let templates=all.filter{!$0.mode.requiresNFCIAsOf}
        try require(excluded.map(\.id).sorted()==["nfci-dual-core-v11","nfci-dual-core-v11-qual-role"] && templates.count==23,"frozen scope")
        let ids=templates.map(\.id);let overlays=["recent-volatility-managed-idle-cash","recent-pair-spread-z252-shift25","recent-gold-equity-relative-z252-shift25"]
        var manifest:[[String:Any]]=[]
        for t in all {
            let d=try StrategyRegistry.definition(id:t.id),options=BacktestCoreStrategyDefaults.assetOptions(for:t)
            if !t.mode.requiresNFCIAsOf {try require(Set(options.map(\.symbol)).isSubset(of:Set(symbols)),"out of scope option "+t.id)}
            manifest.append(["id":t.id,"title":t.title,"strategyVersion":d.reference.version,"priceSymbols":options.map(\.symbol),"fxSymbols":d.dataRequirements.fxSymbols,"macroRequired":t.mode.requiresNFCIAsOf,"scope":t.mode.requiresNFCIAsOf ? "EXCLUDED_MACRO_OR_QUAL_SCOPE" : (t.id=="kvo" ? "CONDITIONAL_EXISTING_SAME_ASSET_QUANTITY_SUPPLEMENT":"PRICE_COMPARISON_CANDIDATE_PENDING_RUNTIME_AUDIT"),"settingsMaxPositionRatio":t.maxPositionRatio])
        }
        try write(manifest,output.appendingPathComponent("catalog.json"))
        let fixedCuts=["2007-12-27","2016-07-20","2025-02-20"].map{BacktestSeriesAlignment.historicalSeriesDate(from:$0)!}
        var fullAccounts:[String:[String:Any]]=[:],fullPoints:[String:[BacktestSeriesPoint]]=[:],fullWitness:[String:[[String:Any]]]=[:],prefixChecks:[[String:Any]]=[]
        var topCalls=0
        typealias Input=(assetSeries:PublicHistorySeries?,assetOption:BacktestInstrument,fxSeries:PublicHistorySeries?)
        for context in 0...3 {
            let folder=output.appendingPathComponent(context==0 ? "full":"prefix-\(context)");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            let data:Data
            if context==0 {data=raw} else {
                let cutoff=fixedCuts[context-1];var envelope=try JSONSerialization.jsonObject(with:raw) as! [String:Any]
                let series=fullDataset.seriesBySymbol.values.sorted{$0.symbol<$1.symbol}.compactMap{BacktestSeriesAlignment.filteredHistorySeries($0,within:Date.distantPast...cutoff)}
                envelope["series"]=try json(series);let physical=folder.appendingPathComponent("physical-history.json");try encoder.encode(ExactJSON(any:envelope)).write(to:physical);data=try read(physical)
            }
            let ds=try PublicBacktestCore.loadDataset(from:data,datasetHash:sha(data),dataStale:false)
            if context>0 {
                for(symbol,series) in ds.seriesBySymbol {
                    let cropped=BacktestSeriesAlignment.filteredHistorySeries(fullDataset.seriesBySymbol[symbol],within:Date.distantPast...fixedCuts[context-1])!
                    try require(same(try json(series),try json(cropped)),"physical normalized full-field input prefix "+symbol)
                }
            }
            let sourceFolder=folder.appendingPathComponent("source");try FileManager.default.createDirectory(at:sourceFolder,withIntermediateDirectories:false)
            let parentMode=AdvancedBacktestStrategyMode.riskContributionCashConfidenceLowNoise
            let parentTemplate=all.first{$0.mode==parentMode}!,parentOptions=BacktestCoreStrategyDefaults.assetOptions(for:parentTemplate)
            let unordered:[Input]=parentOptions.map{MarketInputPreparation.advancedAssetInput(for:$0){ds.seriesBySymbol[$0]}}
            let ordered:[Input]=parentMode.requiredSignalAssetSymbols.map{s in unordered.first{$0.assetOption.symbol==s}!}
            let eligible=MarketInputPreparation.publicIndexHistoryInputs(ordered)
            let parentSettings=AdvancedBacktestRiskSettings(feeRate:0.025,slippageRate:0,maxPositionRatio:100,cooldownDays:0,stopLossRatio:0,takeProfitRatio:0)
            let cfg=ResearchTargetStrategyConfig(symbol:"catalog_overlay_witness",title:"Current overlay source witness",warmupSessions:21,rebalanceSessions:1,rebalanceBand:0.244,tradeToBandBoundary:false,zeroFillBeforeFirstSymbols:["csi300"],maxGrossExposure:1,allowsFinancedExposure:false,financingAnnualRate:0,buyReason:"Overlay witness")
            guard let frame=TargetProviderBacktest.researchMarketDataFrame(assetInputs:eligible,config:cfg),let parent=BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(assetInputs:eligible,initialCash:100000,settings:parentSettings,mode:parentMode) else{throw error("current original LowNoise witness")}
            try write(try payload(parent),sourceFolder.appendingPathComponent("internal-original-parent.json"))
            let byDate=Dictionary(uniqueKeysWithValues:parent.dailyStates.map{(civil($0.date),$0.targetWeights)})
            var bases:[Int:[String:Double]]=[:]
            for i in 1..<frame.dates.count {if let w=byDate[civil(frame.dates[i])] {bases[i]=w}}
            var schedules:[String:FrozenTargetSchedule]=[:]
            for id in overlays {
                let mode:RecentWindowOverlayStrategy.Mode=id==overlays[0] ? .volatilityManagedIdleCash:(id==overlays[1] ? .pairSpreadZ252Shift25:.goldEquityRelativeZ252Shift25)
                guard let schedule=RecentWindowOverlayStrategy.indexOverlaySchedule(frame:frame,baseByExecutionIndex:bases,mode:mode) else{throw error("raw source guard "+id)}
                schedules[id]=schedule;let rows=schedule.events.map(event)
                for row in schedule.events {try require(Set(row.targetWeights.keys)==Set(symbols) && row.targetWeights.values.allSatisfy{$0.isFinite && $0>=0} && gross(row.targetWeights)<=1 && row.signalIndex>=0 && row.signalDate<frame.dates[row.signalIndex+1],"raw source scope/clock "+id)}
                try write(rows,sourceFolder.appendingPathComponent(id+"-events.json"))
                if context==0 {fullWitness[id]=rows} else {try require(same(rows,fullWitness[id]!.filter{($0["signalIndex"] as! Int)<=frame.dates.count-2}),"complete overlay source event prefix "+id)}
            }
            for template in templates {
                let definition=try StrategyRegistry.definition(id:template.id)
                let settings=AdvancedBacktestRiskSettings(feeRate:0.025,slippageRate:0,maxPositionRatio:template.maxPositionRatio,cooldownDays:template.cooldownDays,stopLossRatio:template.stopLossRatio,takeProfitRatio:template.takeProfitRatio)
                let config=BacktestRunConfiguration(strategy:definition.reference,purpose:.product,initialCash:100000,settings:settings)
                topCalls+=1;try write(["topLevelReplay":topCalls,"context":context,"strategyID":template.id,"internalParentShadowCallsNotCounted":true],output.appendingPathComponent("TOP_REPLAY_\(topCalls).json"))
                let r=try definition.makeRunner().run(input:.init(seriesBySymbol:ds.seriesBySymbol,datasetHash:sha(data),sourceCommit:storage["baseAppHEAD"] as? String),configuration:config)
                let run=AdvancedRotationStrategyRun(report:r.report,dailyStates:r.dailyStates)
                var account=try payload(run);account["strategyID"]=template.id;account["strategyVersion"]=definition.reference.version;account["provenance"]=try json(r.provenance)
                try write(account,folder.appendingPathComponent(template.id+".json"));try write(try ledger(run),folder.appendingPathComponent(template.id+"-ledger.json"))
                if let schedule=schedules[template.id] {
                    var k=0;var latest:[String:Double]=[:]
                    let indices=Dictionary(uniqueKeysWithValues:frame.dates.enumerated().map{($0.element,$0.offset)})
                    for state in run.dailyStates {
                        let signal=indices[state.date]!-1
                        while k<schedule.events.count && schedule.events[k].signalIndex<=signal {latest=schedule.events[k].targetWeights;k+=1}
                        try require(same(state.targetWeights,latest.filter{$0.value>0}),"latest accepted overlay target "+template.id+" "+civil(state.date))
                    }
                    try write(["status":"PASS_LATEST_KNOWN_OVERLAY_TARGET_EQUALS_ACCEPTED_ALL_STATES","instantActualHoldingsClaim":false],folder.appendingPathComponent(template.id+"-delivery.json"))
                }
                if context==0 {fullAccounts[template.id]=account;fullPoints[template.id]=r.report.points} else {
                    let original=fullAccounts[template.id]!,end=run.dailyStates.last!.date
                    let states=(original["daily_states"] as! [[String:Any]]).filter{($0["date"] as! String)<=iso(end)}
                    let points=(original["points"] as! [[String:Any]]).filter{($0["date"] as! String)<=iso(end)}
                    let trades=(original["trades"] as! [[String:Any]]).filter{($0["date"] as! String)<=iso(end)}
                    try require(same(account["daily_states"]!,states),"state prefix "+template.id);try require(same(account["points"]!,points),"NAV prefix "+template.id);try require(same(account["trades"]!,trades,excluding:["id","reason"]),"economic fill prefix "+template.id)
                    prefixChecks.append(["context":context,"strategyID":template.id,"lastDate":iso(end),"stateCount":states.count,"tradeCount":trades.count,"allFinancialBitsExact":true])
                }
                print("TOP_REPLAY \(topCalls) \(template.id) SAVED");fflush(stdout)
            }
            print("CONTEXT \(context) COMPLETE");fflush(stdout)
        }
        try require(topCalls==92 && prefixChecks.count==69,"finite budget")
        let priceIDs=ids.filter{$0 != "kvo"};try require(priceIDs.count==22,"price ranking count")
        var common=Set(fullPoints[priceIDs[0]]!.map(\.date))
        for id in priceIDs.dropFirst(){common.formIntersection(fullPoints[id]!.map(\.date))}
        let commonDates=common.sorted();try require(commonDates.count>1000,"common full-history observations")
        try write(commonDates.map(iso),output.appendingPathComponent("common-observation-dates.json"))
        var rows:[[String:Any]]=[]
        for id in ids {
            let points=fullPoints[id]!,shared=points.filter{common.contains($0.date)}
            let original=fullAccounts[id]!
            let within=points.filter{$0.date>=commonDates.first! && $0.date<=commonDates.last!}
            var maximumGap=0
            for (a,b) in zip(shared,shared.dropFirst()){maximumGap=max(maximumGap,BacktestSeriesAlignment.historicalSeriesCalendar.dateComponents([.day],from:a.date,to:b.date).day ?? 0)}
            // Full-history headline metrics pass through the actual App report; only the common grid is recomputed.
            let full:[String:Any]=["annualized_return":original["annualized_return"]!,"sharpe_rf0":original["sharpe_rf0"]!,"max_drawdown":original["max_drawdown"]!,"start":iso(points.first!.date),"end":iso(points.last!.date),"points":points.count,"fills":(original["trades"] as! [Any]).count]
            let fullC=full["annualized_return"] as? Double ?? -.infinity,fullS=full["sharpe_rf0"] as? Double ?? -.infinity
            rows.append(["strategyID":id,"title":all.first{$0.id==id}!.title,"scope":id=="kvo" ? "CONDITIONAL_QUANTITY_SUPPLEMENT":"PRICE_RANKING","full":full,"common_observations":try metric(shared),"interiorObservationDatesExcluded":within.count-shared.count,"maxCommonGapCalendarDays":maximumGap,"fullHistoryCAGR6Sharpe13Pass":fullC>=0.06 && fullS>=1.3])
        }
        rows.sort {a,b in
            let am=a["common_observations"] as! [String:Any],bm=b["common_observations"] as! [String:Any]
            let av=am["sharpe_rf0"] as? Double ?? -.infinity,bv=bm["sharpe_rf0"] as? Double ?? -.infinity
            return av==bv ? (a["strategyID"] as! String)<(b["strategyID"] as! String):av>bv
        }
        try check()
        let result:[String:Any]=["status":"APP_CATALOG_CURRENT_RULE_FULL_AND_PREFIX_COMPLETE","completedAtUTC":iso(Date()),"rows":rows,"catalogCount":all.count,"excludedMacroOrQUALCount":excluded.count,"priceComparisonCount":22,"conditionalQuantitySupplementCount":1,"topLevelFullAccounts":23,"topLevelPrefixAccounts":69,"topLevelReplays":topCalls,"internalSimulatorCallCount":NSNull(),"internalOriginalParentAndShadowsRecomputed":true,"financialPrefixChecks":prefixChecks,"commonDatesCount":commonDates.count,"commonDatesStart":iso(commonDates.first!),"commonDatesEnd":iso(commonDates.last!),"commonDatesAreSavedObservationsNotFullDailyRisk":true,"formalValidation":false,"OOSCertified":false,"PITCertified":false,"recommended":false,"nativeInputBindingsUnchanged":bindings.count]
        try write(result,b.appendingPathComponent("RESULT.json"));print("APP_CATALOG_CURRENT_RULE_AUDIT COMPLETE");fflush(stdout)
    }
}
