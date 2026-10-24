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

@main struct DynamicCurrentRuleStudy {
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


    typealias Input = (assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)
    static let settings = AdvancedBacktestRiskSettings(feeRate:0.025,slippageRate:0,maxPositionRatio:100,cooldownDays:0,stopLossRatio:0,takeProfitRatio:0)
    static let arms = ["original-band04","boundary08-only","scaling115-only","dynamic115-boundary08-primary"]
    static func prepare(_ ds:PublicBacktestDataset, _ folder:URL)throws->(inputs:[Input],frame:MarketDataFrame,native:Data,q:[String:Data]) {
        let template=AdvancedBacktestStrategyTemplate.productCatalog.first{$0.id=="kvo"}!
        let opts=BacktestCoreStrategyDefaults.assetOptions(for:template)
        let inputs=MarketInputPreparation.publicIndexHistoryInputs(opts.map{MarketInputPreparation.advancedAssetInput(for:$0){ds.seriesBySymbol[$0]}})
        let ordered=KE25LiveStrategy.symbols.map{s in inputs.first{$0.assetOption.symbol==s}!}
        let anchor=BacktestSeriesAlignment.historicalSeriesDate(from:KE25LiveStrategy.anchorDate)!
        let bounded=MarketInputPreparation.filteredAdvancedAssetInputs(ordered,within:anchor...Date.distantFuture)
        let config=ResearchTargetStrategyConfig(symbol:"ke25",title:"KVO",warmupSessions:21,rebalanceSessions:1,rebalanceBand:0.04,tradeToBandBoundary:false,zeroFillBeforeFirstSymbols:["csi300"],maxGrossExposure:1,allowsFinancedExposure:false,financingAnnualRate:0,buyReason:"KVO")
        guard let frame=TargetProviderBacktest.researchMarketDataFrame(assetInputs:bounded,config:config) else {throw error("prepare frame")}
        var rows=[[String:Any]](),q=[String:Data]()
        for input in ordered where input.assetOption.symbol != "gold_cny" {
            let x=input.assetSeries!,n=x.dates.count,s=input.assetOption.symbol
            rows.append(["symbol":s=="nasdaq" ? "nasdaq_composite":s,"dates":x.dates,
                         "open_prices":(x.openPrices ?? Array(repeating:nil,count:n)).map{$0 as Any? ?? NSNull()},
                         "high_prices":(x.highPrices ?? Array(repeating:nil,count:n)).map{$0 as Any? ?? NSNull()},
                         "low_prices":(x.lowPrices ?? Array(repeating:nil,count:n)).map{$0 as Any? ?? NSNull()},
                         "close_prices":(x.closePrices ?? Array(repeating:nil,count:n)).map{$0 as Any? ?? NSNull()}])
            if ["csi300","shanghai_composite"].contains(s) {
                var quantities=[[String:Any]]()
                for(i,date) in x.dates.enumerated() where date<=civil(frame.dates.last!) {
                    var row:[String:Any]=["day":date,"volume":NSNull()]
                    if let volumes=x.volumes,let v=volumes[i] {
                        try require(v.isFinite && v>=0 && v<=9_007_199_254_740_992 && UInt64(exactly:v) != nil,"quantity integer")
                        row["volume"]=String(UInt64(v))
                    }
                    quantities.append(row)
                }
                q[s]=try JSONSerialization.data(withJSONObject:quantities,options:[.sortedKeys])
            }
        }
        let native=try JSONSerialization.data(withJSONObject:["series":rows],options:[.sortedKeys])
        try native.write(to:folder.appendingPathComponent("prepared-native-history.json"))
        for(s,data) in q {try data.write(to:folder.appendingPathComponent("quantity-"+s+".json"))}
        return (inputs,frame,native,q)
    }
    static func simulate(_ frame:MarketDataFrame,_ source:[Int:[String:Double]],_ scaleOn:Bool,_ boundary:Bool,_ folder:URL)throws->AdvancedRotationStrategyRun {
        var latest:[String:Double]?,submitted:[String:Double]?,pending=false,queued:Int?,peakNAV=100000.0
        var trace=[[String:Any]]()
        func target(_ w:[String:Double],_ nav:Double)->[String:Double] {
            if !scaleOn{return w}
            let dd=(peakNAV-nav)/peakNAV,s=dd<=0.020 ? 1.15:1.0
            var out=[String:Double]();for(k,v) in w {out[k]=v*s}
            let g=out.values.reduce(0,+);if g>1 {for k in out.keys {out[k]=out[k]!/g}}
            return out
        }
        let provider=StrategyTargetProvider {c in
            precondition(!pending && latest != nil && c.signalDate<c.date)
            if scaleOn && c.signalPortfolioValue>peakNAV {peakNAV=c.signalPortfolioValue}
            let t=target(latest!,c.signalPortfolioValue);submitted=t;pending=true;queued=nil
            return t
        }
        let execution=BacktestExecutionConfig(initialCash:100000,feeRate:0.00025,slippageRate:0,rebalanceBand:boundary ? 0.08:0.04,tradeToBandBoundary:boundary,financingAnnualRate:0,allowsFinancedExposure:false,buyReason:"KVO")
        guard let sim=BacktestDailySimulator.run(frame:frame,execution:execution,provider:provider,
            rebalanceDecision:{_,_ in .init(shouldRebalance:false,refreshOverlay:false)},
            contextualRebalanceDecision:{c in
                if let t=source[c.signalIndex] {latest=t;if scaleOn && c.signalPortfolioValue>peakNAV {peakNAV=c.signalPortfolioValue};queued=c.signalIndex}
                let candidate=latest.map{target($0,c.signalPortfolioValue)}
                let changed=candidate.map{submitted==nil || $0 != submitted!} ?? false
                let submit = !pending && candidate != nil && (changed || queued != nil)
                trace.append(["date":iso(c.date),"signalDate":iso(c.signalDate),"signalIndex":c.signalIndex,"signalNAV":c.signalPortfolioValue,"peakNAV":peakNAV,"pendingBefore":pending,"shouldSubmit":submit,"candidate":candidate as Any? ?? NSNull()])
                return .init(shouldRebalance:submit,refreshOverlay:false)
            },didExecuteTarget:{_ in pending=false},buyBudgetPolicy:.symbolOrder) else {throw error("simulator")}
        try write(trace,folder.appendingPathComponent("decisions.json"))
        try write(["pendingAtEnd":pending,"instantTargetHoldingsClaim":false],folder.appendingPathComponent("pending.json"))
        guard let m=BacktestMetricsCalculator.performanceMetrics(from:sim.points) else{throw error("metrics")}
        let report=AdvancedBacktestReport(points:sim.points,benchmarkPoints:sim.benchmarkPoints,benchmarkSeries:[],trades:sim.trades.sorted{$0.date<$1.date},assetReports:[],finalPortfolioValue:sim.points.last!.portfolioValue,finalCash:sim.finalCash,finalUnits:sim.finalUnits,totalReturn:m.totalReturn,annualizedReturn:m.annualizedReturn,maxDrawdown:m.maxDrawdown,annualizedVolatility:m.annualizedVolatility,sharpeRatio:m.sharpeRatio,cashYieldSummary:sim.cashYieldSummary,riskSignalSummary:nil)
        return AdvancedRotationStrategyRun(report:report,dailyStates:sim.dailyStates)
    }
    static func main(){do{try execute()}catch{fputs("DYNAMIC_STUDY_FAILED: \(error)\n",stderr);exit(1)}}
    static func execute()throws {
        let p=URL(fileURLWithPath:CommandLine.arguments[1]),storage=try obj(p.appendingPathComponent("STORAGE.json")),b=URL(fileURLWithPath:storage["artifactRoot"] as! String)
        let auth=try obj(p.appendingPathComponent("RUN_AUTHORIZATION.json")),bindings=auth["files"] as! [String:String]
        func check()throws{for(path,h) in bindings {try require(sha(read(URL(fileURLWithPath:path)))==h,"changed "+path)}}
        try check();let out=b.appendingPathComponent("run");try require((try FileManager.default.contentsOfDirectory(atPath:out.path)).isEmpty,"nonempty run")
        let ids=arms+["original-product-runner-parity"]
        var full=[String:[String:Any]](),fullSources=[[String:Any]](),prefixChecks=[[String:Any]](),rows=[[String:Any]](),calls=0
        for context in 0...3 {
            let name=context==0 ? "full":"prefix-\(context)",folder=out.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            let raw=try read(b.appendingPathComponent(context==0 ? "raw/public-history.json":"raw/\(name).json"))
            let ds=try PublicBacktestCore.loadDataset(from:raw,datasetHash:sha(raw),dataStale:false)
            let prep=try prepare(ds,folder),frame=prep.frame
            let source=try KE25LiveStrategy.targets(frame:frame,nativeHistory:prep.native,quantityRawBySymbol:prep.q)
            let sourceRows=source.keys.sorted().map{["signalIndex":$0,"signalDate":iso(frame.dates[$0]),"targetWeights":source[$0]!] as [String:Any]}
            try write(sourceRows,folder.appendingPathComponent("source-targets.json"))
            if context==0 {fullSources=sourceRows} else {try require(same(sourceRows,fullSources.filter{($0["signalIndex"] as! Int)<frame.dates.count}),"regenerated source prefix")}
            var accounts=[String:[String:Any]]()
            for (index,id) in ids.enumerated() {
                calls+=1;try write(["call":calls,"context":name,"id":id],out.appendingPathComponent("TOP_REPLAY_\(calls).json"))
                let armFolder=folder.appendingPathComponent(id);try FileManager.default.createDirectory(at:armFolder,withIntermediateDirectories:false)
                let run:AdvancedRotationStrategyRun
                if index<4 {run=try simulate(frame,source,index>=2,index==1 || index==3,armFolder)}
                else {
                    let def=try StrategyRegistry.definition(id:"kvo"),config=BacktestRunConfiguration(strategy:def.reference,purpose:.product,initialCash:100000,settings:settings)
                    let r=try def.makeRunner().run(input:.init(seriesBySymbol:ds.seriesBySymbol,datasetHash:sha(raw),sourceCommit:storage["baseAppHEAD"] as? String),configuration:config)
                    run=AdvancedRotationStrategyRun(report:r.report,dailyStates:r.dailyStates)
                }
                let account=try payload(run);try write(account,armFolder.appendingPathComponent("account.json"));try write(try ledger(run),armFolder.appendingPathComponent("ledger.json"))
                accounts[id]=account
                if context==0 {
                    full[id]=account
                    if index<4 {rows.append(["id":id,"annualized_return":run.report.annualizedReturn as Any? ?? NSNull(),"sharpe_rf0":run.report.sharpeRatio as Any? ?? NSNull(),"max_drawdown":run.report.maxDrawdown,"start":civil(run.report.points.first!.date),"end":civil(run.report.points.last!.date),"states":run.dailyStates.count,"trades":run.report.trades.count,"joint7_14":(run.report.annualizedReturn ?? 0)>=0.07 && (run.report.sharpeRatio ?? 0)>=1.4])}
                } else {
                    let end=iso(run.dailyStates.last!.date),original=full[id]!
                    for key in ["daily_states","points","trades"] {
                        let wanted=(original[key] as! [[String:Any]]).filter{($0["date"] as! String)<=end}
                        try require(same(account[key]!,wanted,excluding:key=="trades" ? ["id","reason"]:[]),"financial prefix "+id+" "+key)
                    }
                    prefixChecks.append(["id":id,"context":name,"allFinancialBitsExact":true])
                }
                print("SAVED \(calls) \(name) \(id)");fflush(stdout)
            }
            for (original,parity) in [(arms[0],ids[4])] {
                for key in ["daily_states","points","trades","annualized_return","sharpe_rf0","max_drawdown","ending_value","ending_cash"] {
                    try require(same(accounts[original]![key]!,accounts[parity]![key]!,excluding:key=="trades" ? ["id","reason"]:[]),"native parity "+key+" "+original)
                }
            }
        }
        try check();try require(calls==20 && prefixChecks.count==15,"budget")
        let result:[String:Any]=["status":"COMPLETE_CURRENT_INPUT_FIXED_DYNAMIC_2X2","rows":rows,"topLevelAccounts":calls,"fullAccounts":5,"prefixAccounts":15,"prefixChecks":prefixChecks,"publicParityContexts":4,"sourceRegeneratedEveryPhysicalPrefix":true,"inputBindingsUnchanged":bindings.count,"goalCAGR":0.07,"goalSharpeRf0":1.4,"formalSVP":false,"PITCertified":false,"OOSCertified":false]
        try write(result,b.appendingPathComponent("RESULT.json"));try write(result,p.appendingPathComponent("RESULT.json"));print("STUDY_COMPLETE");fflush(stdout)
    }
}
