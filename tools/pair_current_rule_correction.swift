import Foundation
import CryptoKit
import CoreFoundation
import AssetTimeMachineBacktestCore

@main struct PairCorrectionReplay {
    static let symbols = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
    static let encoder: JSONEncoder = { let e=JSONEncoder();e.dateEncodingStrategy = .iso8601;e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return e }()
    static func sha(_ d:Data)->String { SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined() }
    static func read(_ u:URL)throws->Data {try Data(contentsOf:u)}
    static func obj(_ u:URL)throws->[String:Any] {try JSONSerialization.jsonObject(with:read(u)) as! [String:Any]}
    static func write(_ x:Any,_ u:URL)throws { guard !FileManager.default.fileExists(atPath:u.path) else {throw error("existing "+u.path)};try JSONSerialization.data(withJSONObject:x,options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes]).write(to:u,options:.atomic) }
    static func error(_ text:String)->NSError {NSError(domain:"PairCorrection",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
    static func require(_ ok:Bool,_ text:String)throws {if !ok {throw error(text)}}
    static func iso(_ d:Date)->String {ISO8601DateFormatter().string(from:d)}
    static func civil(_ d:Date)->String {BacktestSeriesAlignment.historicalSeriesDateString(from:d)}
    static func json<T:Encodable>(_ x:T)throws->Any {try JSONSerialization.jsonObject(with:encoder.encode(x))}
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
            if civil(s.date)<"2005-04-08" {try require(held==0 && s.targetWeights.isEmpty,"prepublic risk");earlyCash+=1}
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
    static func main(){do{try execute()}catch{fputs("PAIR_CORRECTION_FAILED: \(error)\n",stderr);exit(1)}}
    static func execute()throws {
        let p=URL(fileURLWithPath:CommandLine.arguments[1]);let storage=try obj(p.appendingPathComponent("STORAGE.json"));let b=URL(fileURLWithPath:storage["artifactRoot"] as! String)
        let admission=try obj(p.appendingPathComponent("RUN_AUTHORIZATION.json"));let bindings=admission["files"] as! [String:String]
        func check()throws {for(path,h) in bindings {try require(sha(read(URL(fileURLWithPath:path)))==h,"changed input "+path)}}
        try require(admission["status"] as? String=="ROOT_AUTHORIZED_PAIR_CORRECTION_FINITE_CURRENT_REPLAY","admission");try check()
        let output=b.appendingPathComponent("run");try require(!FileManager.default.fileExists(atPath:output.path),"run exists");try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
        let raw=try read(b.appendingPathComponent("raw/public-history.json"));let fullDataset=try PublicBacktestCore.loadDataset(from:raw,datasetHash:sha(raw),dataStale:false)
        let template=AdvancedBacktestStrategyTemplate.all.first{$0.id=="recent-pair-spread-z252-shift25"}!
        let options=BacktestCoreStrategyDefaults.assetOptions(for:template)
        let settings=AdvancedBacktestRiskSettings(feeRate:0.025,slippageRate:0,maxPositionRatio:100,cooldownDays:0,stopLossRatio:0,takeProfitRatio:0)
        let cfg=ResearchTargetStrategyConfig(symbol:"pair_index_correction_outer",title:"Current pair correction",warmupSessions:21,rebalanceSessions:1,rebalanceBand:0.244,tradeToBandBoundary:false,zeroFillBeforeFirstSymbols:["csi300"],maxGrossExposure:1,allowsFinancedExposure:false,financingAnnualRate:0,buyReason:"Current pair correction")
        typealias Input=(assetSeries:PublicHistorySeries?,assetOption:BacktestInstrument,fxSeries:PublicHistorySeries?)
        let publicDate=BacktestSeriesAlignment.historicalSeriesDate(from:"2005-04-08")!
        var fullFrame:MarketDataFrame?;var fullSources:[[String:Any]]=[];var fullEvents:[[String:Any]]=[];var fullBaseEvents:[[String:Any]]=[];var fullAccounts:[[String:Any]]=[];var prefixChecks:[[String:Any]]=[];var contexts=0,topCalls=0
        var cutDates:[Date]=[]
        for number in 0...3 {
            let folder=output.appendingPathComponent(number==0 ? "full":"prefix-\(number)");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            let data:Data
            if number==0 {data=raw} else {
                let cutoff=cutDates[number-1];var envelope=try JSONSerialization.jsonObject(with:raw) as! [String:Any]
                let series=fullDataset.seriesBySymbol.values.sorted{$0.symbol<$1.symbol}.compactMap {BacktestSeriesAlignment.filteredHistorySeries($0,within:Date.distantPast...cutoff)}
                envelope["series"]=try json(series);let generated=try JSONSerialization.data(withJSONObject:envelope,options:[.sortedKeys]);let physical=folder.appendingPathComponent("physical-history.json");try generated.write(to:physical);data=try read(physical);try require(data==generated,"physical consumed input bytes")
            }
            let dataset=try PublicBacktestCore.loadDataset(from:data,datasetHash:sha(data),dataStale:false)
            let originalInputs:[Input]=options.map{MarketInputPreparation.advancedAssetInput(for:$0){dataset.seriesBySymbol[$0]}}
            let eligibleInputs:[Input]=originalInputs.map {i in i.assetOption.symbol=="csi300" ? (BacktestSeriesAlignment.filteredHistorySeries(i.assetSeries,within:publicDate...Date.distantFuture),i.assetOption,i.fxSeries):i}
            guard let frame=TargetProviderBacktest.researchMarketDataFrame(assetInputs:eligibleInputs,config:cfg) else {throw error("frame")}
            if number==0 {fullFrame=frame;cutDates=[1500,3500,5500].map{frame.dates[$0]}}
            else {
                let f=fullFrame!;try require(frame.dates==Array(f.dates.prefix(frame.dates.count)),"frame date prefix")
                for symbol in symbols {try require(frame.pricesBySymbol[symbol]!.map(\.bitPattern)==Array(f.pricesBySymbol[symbol]!.prefix(frame.dates.count)).map(\.bitPattern),"frame price prefix");try require(frame.observedBySymbol[symbol]! == Array(f.observedBySymbol[symbol]!.prefix(frame.dates.count)),"frame observed prefix")}
            }
            // This is the original policy's required internal parent/shadow generation, not a scored third candidate.
            guard let parent=BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(assetInputs:eligibleInputs,initialCash:100000,settings:settings,mode:.riskContributionCashConfidenceLowNoise) else {throw error("original LowNoise parent")}
            try write(try payload(parent),folder.appendingPathComponent("internal-parent.json"))
            let byDate=Dictionary(uniqueKeysWithValues:parent.dailyStates.map{(civil($0.date),$0.targetWeights)})
            var baseByIndex:[Int:[String:Double]]=[:]
            for i in 1..<frame.dates.count {if let x=byDate[civil(frame.dates[i])] {baseByIndex[i]=x}}
            guard let schedule=RecentWindowOverlayStrategy.indexPairSchedule(frame:frame,baseByExecutionIndex:baseByIndex) else {
                let bad=baseByIndex.sorted{$0.key<$1.key}.first { i,w in let j=i-1;let uz=z(frame,"nasdaq","sp500",j);let cz=j>=251 && frame.dates[j-251]>=publicDate ? z(frame,"csi300","shanghai_composite",j):nil;return RecentWindowOverlayStrategy.indexPairTarget(base:w,usZ:uz,chinaZ:cz)==nil }
                try write(["status":"SOURCE_RAW_GUARD_STOP","index":bad?.key as Any? ?? NSNull(),"base":bad?.value as Any? ?? NSNull(),"gross":bad.map{gross($0.value)} as Any? ?? NSNull(),"executionDate":bad.map{iso(frame.dates[$0.key])} as Any? ?? NSNull(),"usZ":bad.flatMap{z(frame,"nasdaq","sp500",$0.key-1)} as Any? ?? NSNull(),"chinaZ":bad.flatMap { v -> Double? in let j=v.key-1;return j>=251 && frame.dates[j-251]>=publicDate ? z(frame,"csi300","shanghai_composite",j):nil } as Any? ?? NSNull()],folder.appendingPathComponent("SOURCE_FAILURE.json"));throw error("source raw target guard")
            }
            var rows:[[String:Any]]=[],baseEvents:[FrozenTargetEvent]=[];var current:[String:Double]?;var previous:[String:Double]?
            for i in 1..<frame.dates.count {
                if let x=baseByIndex[i] {current=x};guard let base=current else{continue};let j=i-1
                let uz=z(frame,"nasdaq","sp500",j);let cz=j>=251 && frame.dates[j-251]>=publicDate ? z(frame,"csi300","shanghai_composite",j):nil
                guard let target=RecentWindowOverlayStrategy.indexPairTarget(base:base,usZ:uz,chinaZ:cz),let neutral=RecentWindowOverlayStrategy.indexPairTarget(base:base,usZ:nil,chinaZ:nil) else{throw error("raw target")}
                rows.append(["signalIndex":j,"signalDate":iso(frame.dates[j]),"executionDate":iso(frame.dates[i]),"usZ":uz as Any? ?? NSNull(),"chinaZ":cz as Any? ?? NSNull(),"baseWeights":neutral,"targetWeights":target])
                let different=previous.map {old in Set(old.keys).union(neutral.keys).reduce(0.0){$0+abs((old[$1] ?? 0)-(neutral[$1] ?? 0))}>1e-10} ?? true
                if different {baseEvents.append(.init(signalIndex:j,signalDate:frame.dates[j],targetWeights:neutral,reason:"Matched original LowNoise target"));previous=neutral}
            }
            let events=schedule.events.map(event),neutralEvents=baseEvents.map(event)
            try write(rows,folder.appendingPathComponent("raw-source-rows.json"));try write(events,folder.appendingPathComponent("pair-source-events.json"));try write(neutralEvents,folder.appendingPathComponent("parent-control-source-events.json"))
            if number==0 {fullSources=rows;fullEvents=events;fullBaseEvents=neutralEvents}
            else {let last=frame.dates.count-2;try require(same(rows,fullSources.filter{($0["signalIndex"] as! Int)<=last}),"all raw source prefix");try require(same(events,fullEvents.filter{($0["signalIndex"] as! Int)<=last}),"pair event prefix");try require(same(neutralEvents,fullBaseEvents.filter{($0["signalIndex"] as! Int)<=last}),"control event prefix")}
            contexts+=1;print("SOURCE_RAW_SCOPE_AND_CAUSAL \(number) PASS");fflush(stdout)
            for role in 0...1 {
                let run:AdvancedRotationStrategyRun
                topCalls+=1;try write(["topLevelReplay":topCalls,"context":number,"role":role,"startedAt":iso(Date()),"internalParentShadowCallsNotCounted":true],output.appendingPathComponent("TOP_REPLAY_\(topCalls).json"))
                if role==0 {
                    guard let x=BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(assetInputs:originalInputs,initialCash:100000,settings:settings,mode:.recentPairSpreadZ252Shift25) else{throw error("App corrected pair")};run=x
                } else {
                    guard let x=TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(assetInputs:eligibleInputs,initialCash:100000,settings:settings,config:cfg,frozenSchedule:{_ in FrozenTargetSchedule(events:baseEvents)},targetWeights:{_,_ in [:]}) else{throw error("matched parent control")}
                    run=AdvancedRotationStrategyRun(report:x.report,dailyStates:x.dailyStates)
                }
                let account=try payload(run);let name=role==0 ? "corrected-pair":"matched-parent-control"
                try write(account,folder.appendingPathComponent(name+".json"));let audit=try ledger(run);try write(audit,folder.appendingPathComponent(name+"-ledger.json"))
                let wanted=role==0 ? schedule.events:baseEvents;var k=0;var latest:[String:Double]=[:]
                for state in run.dailyStates {
                    let j=frame.dates.firstIndex(of:state.date)!-1
                    while k<wanted.count && wanted[k].signalIndex<=j {latest=wanted[k].targetWeights;k+=1}
                    try require(same(state.targetWeights,latest.filter{$0.value>0}),"latest desired accepted weights mismatch "+name+" "+civil(state.date))
                }
                try write(["status":"PASS_LATEST_KNOWN_DESIRED_EQUALS_STATE_TARGET_ALL_DAYS","pendingUpdatesUseCurrentCoreV4":true,"instantActualHoldingsClaim":false],folder.appendingPathComponent(name+"-delivery.json"))
                if number==0 {fullAccounts.append(account)} else {
                    let original=fullAccounts[role],end=run.dailyStates.last!.date
                    let states=(original["daily_states"] as! [[String:Any]]).filter{($0["date"] as! String)<=iso(end)}
                    let points=(original["points"] as! [[String:Any]]).filter{($0["date"] as! String)<=iso(end)}
                    let trades=(original["trades"] as! [[String:Any]]).filter{($0["date"] as! String)<=iso(end)}
                    try require(same(account["daily_states"]!,states),"complete state prefix");try require(same(account["points"]!,points),"NAV prefix");try require(same(account["trades"]!,trades,excluding:["reason","id"]),"economic trade prefix")
                    prefixChecks.append(["context":number,"role":name,"lastDate":iso(end),"states":states.count,"trades":trades.count,"fullStateNAVHoldingsTargetAndEconomicFillsBitsExact":true])
                }
                print("TOP_REPLAY \(topCalls) \(name) SAVED");fflush(stdout)
            }
        }
        try check();try require(contexts==4 && topCalls==8 && prefixChecks.count==6,"fixed budget")
        let rows=fullAccounts.enumerated().map {i,a in ["id":i==0 ? "corrected-pair":"matched-parent-control","annualized_return":a["annualized_return"]!,"sharpe_rf0":a["sharpe_rf0"]!,"max_drawdown":a["max_drawdown"]!,"start":(a["points"] as! [[String:Any]]).first!["date"]!,"end":(a["points"] as! [[String:Any]]).last!["date"]!,"points":(a["points"] as! [Any]).count,"fills":(a["trades"] as! [Any]).count] as [String:Any]}
        let result:[String:Any]=["status":"PAIR_CURRENT_RULE_CORRECTION_FULL_REPLAY_AND_PREFIX_COMPLETE","completedAtUTC":iso(Date()),"rows":rows,"topLevelFullAccounts":2,"topLevelPrefixAccounts":6,"topLevelReplays":topCalls,"internalSimulatorCallCount":NSNull(),"internalParentAndShadowRecomputed":true,"sourceContexts":contexts,"financialPrefixChecks":prefixChecks,"inputBindingsUnchanged":bindings.count,"formalValidation":false,"OOSCertified":false,"PITCertified":false,"recommended":false,"executionVersion":BacktestExecutionVersion.defaultEngineVersion]
        try write(result,b.appendingPathComponent("RESULT.json"));print("PAIR_CURRENT_RULE_CORRECTION COMPLETE");fflush(stdout)
    }
}
