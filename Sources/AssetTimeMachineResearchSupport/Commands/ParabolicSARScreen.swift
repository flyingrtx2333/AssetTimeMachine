import Foundation
import AssetTimeMachineBacktestCore

/// One fixed single-indicator SAR policy, plus explicitly retained inverse and accounting controls.
public enum ParabolicSARScreen {
    public typealias Bar = SPYSessionInput.Bar
    public struct Signal: Codable, Equatable {
        public let date: Date
        public let open: Double
        public let high: Double
        public let low: Double
        public let close: Double
        public let sar: Double?
        public let rising: Bool?
        public let extreme: Double?
        public let acceleration: Double?
        public let weight: Double
    }
    public static func signals(bars: [Bar]) throws -> [Signal] {
        guard bars.count >= 2, zip(bars,bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
            bars.allSatisfy({ b in [b.open,b.high,b.low,b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                && b.high >= max(b.open,b.close) && b.low <= min(b.open,b.close) }) else {
            throw BacktestConfigurationError.invalidParameter("SAR complete observed bars")
        }
        let first = bars[0]
        var result = [Signal(date:first.date,open:first.open,high:first.high,low:first.low,close:first.close,
            sar:nil,rising:nil,extreme:nil,acceleration:nil,weight:0)]
        var rising = bars[1].close > bars[0].close
        var sar = rising ? min(bars[0].low,bars[1].low) : max(bars[0].high,bars[1].high)
        var extreme = rising ? max(bars[0].high,bars[1].high) : min(bars[0].low,bars[1].low)
        var acceleration = 0.02
        for i in 1..<bars.count {
            let b = bars[i]
            if i >= 2 {
                if rising {
                    let projected = min(sar+acceleration*(extreme-sar),bars[i-1].low,bars[i-2].low)
                    if b.low <= projected {
                        rising = false
                        sar = max(extreme,b.high,bars[i-1].high)
                        extreme = b.low
                        acceleration = 0.02
                    } else {
                        sar = projected
                        if b.high > extreme { extreme = b.high; acceleration = min(0.2,acceleration+0.02) }
                    }
                } else {
                    let projected = max(sar+acceleration*(extreme-sar),bars[i-1].high,bars[i-2].high)
                    if b.high >= projected {
                        rising = true
                        sar = min(extreme,b.low,bars[i-1].low)
                        extreme = b.high
                        acceleration = 0.02
                    } else {
                        sar = projected
                        if b.low < extreme { extreme = b.low; acceleration = min(0.2,acceleration+0.02) }
                    }
                }
            }
            result.append(.init(date:b.date,open:b.open,high:b.high,low:b.low,close:b.close,
                sar:sar,rising:rising,extreme:extreme,acceleration:acceleration,weight:b.close > sar ? 1 : 0))
        }
        return result
    }
    private struct Sources: Decodable {
        let schema: String; let files: [File]
        struct File: Decodable { let path: String; let sha256: String; let ids: [String] }
    }
    private struct Saved: Decodable { let id: String; let dailyStates: [BacktestDailyState] }
    public static func run(historyPath: String, accountsPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath:outputPath)
        guard !FileManager.default.fileExists(atPath:output.path) else { throw CocoaError(.fileWriteFileExists) }
        let history = try Data(contentsOf:URL(fileURLWithPath:historyPath))
        let accountRaw = try Data(contentsOf:URL(fileURLWithPath:accountsPath))
        let sources = try JSONDecoder().decode(Sources.self,from:accountRaw)
        guard sources.schema == "catalogue20-saved-for-sar-v1",sources.files.count == 2 else {
            throw BacktestConfigurationError.invalidParameter("SAR saved controls")
        }
        let dataset = try PublicBacktestCore.loadDataset(from:history,datasetHash:ResearchRunEvidence.sha256(history),dataStale:false)
        let end = BacktestSeriesAlignment.historicalSeriesDate(from:"2026-10-06")!
        guard let original = dataset.seriesBySymbol["nasdaq"], original.currency == "USD" else {
            throw BacktestConfigurationError.missingData("SAR original USD Nasdaq")
        }
        let allBars = original.dailyBars
        guard allBars.count == original.dates.count, allBars.map(\.dateText) == original.dates,
            zip(allBars,original.prices).allSatisfy({ $0.close == $1 }) else {
            throw BacktestConfigurationError.invalidParameter("SAR no missing or synthetic bar")
        }
        let bars = allBars.filter { $0.date <= end }.map { Bar(date:$0.date,open:$0.open,high:$0.high,low:$0.low,close:$0.close) }
        let signalEvidence = try signals(bars:bars)
        let reference = try StrategyRegistry.definition(id:"gold-nasdaq-dual-trend-barbell")
        let inputs = BacktestCoreStrategyDefaults.assetOptions(for:reference.template).map {
            MarketInputPreparation.advancedAssetInput(for:$0) { dataset.seriesBySymbol[$0] }
        }
        let lower = MarketInputPreparation.availableDateBounds(for:inputs.flatMap { [$0.assetSeries,$0.fxSeries].compactMap { $0 } })!.lowerBound
        // Gold only supplies the unchanged shared valuation calendar; no gold SAR signal or holdings.
        let nativeConfig = ResearchTargetStrategyConfig(symbol:"nasdaq-sar",title:"nasdaq-sar",warmupSessions:1,
            rebalanceSessions:1,zeroFillBeforeFirstSymbols:["gold_cny"],signalOnlySymbols:["gold_cny"])
        let legacyConfig = ResearchTargetStrategyConfig(symbol:"single-indicator",title:"single-indicator",warmupSessions:252,rebalanceSessions:1)
        guard let expanded = TargetProviderBacktest.researchMarketDataFrame(assetInputs:inputs,config:nativeConfig,dateBounds:lower...end),
            let legacy = TargetProviderBacktest.researchMarketDataFrame(assetInputs:inputs,config:legacyConfig,dateBounds:lower...end),
            let option = expanded.optionBySymbol["nasdaq"] else {
            throw BacktestConfigurationError.missingData("SAR full native and original frames")
        }
        // Seed cash on the very first usable CNY mark, not a chosen investment date.
        let native = MarketDataFrame(dates:expanded.dates,pricesBySymbol:["nasdaq":expanded.pricesBySymbol["nasdaq"]!],
            observedBySymbol:["nasdaq":expanded.observedBySymbol["nasdaq"]!],ohlcBySymbol:[:],
            tradableSymbols:["nasdaq"],optionBySymbol:["nasdaq":option],simulationRange:0...expanded.simulationRange.upperBound)
        guard native.dates[0] == BacktestSeriesAlignment.historicalSeriesDate(from:"2000-01-13")! else {
            throw BacktestConfigurationError.invalidParameter("SAR first available CNY mark")
        }
        let execution = BacktestExecutionConfig(initialCash:100000,feeRate:0.00025,slippageRate:0,
            rebalanceBand:0,financingAnnualRate:0,allowsFinancedExposure:false,buyReason:"fixed single-indicator research")
        struct Account { let id: String; let states: [BacktestDailyState]; let trades: [AdvancedBacktestTrade] }
        var accounts: [Account] = [], legacySignals: [String:[CloseIndicatorScreen.Signal]] = [:]
        var audits: [String:[String:Int]] = [:]
        let nativeIDs = ["nasdaq:sar002-020","nasdaq:sar002-020-inverse-diagnostic","nasdaq:buy-hold-native2000","cny-cash-native2000"]
        for id in nativeIDs {
            func desired(_ c: StrategyTargetContext) -> Double {
                guard c.index > native.simulationRange.lowerBound else { return 0 }
                if id == "cny-cash-native2000" { return 0 }
                if id == "nasdaq:buy-hold-native2000" { return 1 }
                var lo = 0, hi = signalEvidence.count
                while lo < hi { let mid = (lo+hi)/2; if signalEvidence[mid].date <= c.signalDate { lo = mid+1 } else { hi = mid } }
                guard lo > 0, signalEvidence[lo-1].sar != nil else { return 0 }
                let w = signalEvidence[lo-1].weight
                return id == "nasdaq:sar002-020" ? w : 1-w
            }
            var submitted: Double?
            guard let run = BacktestDailySimulator.run(frame:native,execution:execution,
                provider:.init { c in desired(c) == 1 ? ["nasdaq":1] : [:] },
                rebalanceDecision:{ _,_ in .init(shouldRebalance:false,refreshOverlay:false) },
                contextualRebalanceDecision:{ c in
                    let w=desired(c),changed=submitted == nil || submitted != w
                    if changed { submitted=w }
                    return .init(shouldRebalance:changed,refreshOverlay:false)
                }) else { throw BacktestConfigurationError.computationFailed }
            var mismatches=0
            for (offset,state) in run.dailyStates.enumerated() {
                let i=native.simulationRange.lowerBound+offset
                var known=0.0
                if offset>0 {
                    if id=="nasdaq:buy-hold-native2000" { known=1 }
                    else if id != "cny-cash-native2000",
                        let signal=signalEvidence.last(where:{ $0.date<=native.dates[i-1] }),signal.sar != nil {
                        known=id=="nasdaq:sar002-020" ? signal.weight : 1-signal.weight
                    }
                }
                if (state.targetWeights["nasdaq"] ?? 0) != known { mismatches+=1 }
            }
            guard mismatches==0 else { throw BacktestConfigurationError.invalidParameter("SAR prior target delivery") }
            audits[id]=["desired_accepted_mismatches":mismatches,"state_count":run.dailyStates.count]
            accounts.append(.init(id:id,states:run.dailyStates,trades:run.trades))
        }
        for symbol in ["gold_cny","nasdaq"] {
            guard let prices=legacy.pricesBySymbol[symbol],let raw=dataset.seriesBySymbol[symbol],
                let option=legacy.optionBySymbol[symbol] else { throw BacktestConfigurationError.missingData(symbol) }
            let rawDates=Set(raw.dates.compactMap { BacktestSeriesAlignment.historicalSeriesDate(from:$0) })
            let indices=legacy.dates.indices.filter { rawDates.contains(legacy.dates[$0]) }
            let dates=indices.map { legacy.dates[$0] },ownPrices=indices.map { prices[$0] }
            let frame=MarketDataFrame(dates:legacy.dates,pricesBySymbol:[symbol:prices],observedBySymbol:[symbol:legacy.observedBySymbol[symbol]!],
                ohlcBySymbol:[:],tradableSymbols:[symbol],optionBySymbol:[symbol:option],simulationRange:legacy.simulationRange)
            for ruleName in CloseIndicatorScreen.Rule.allCases.map(\.rawValue)+["buy-hold"] {
                let id=symbol+":"+ruleName
                let signals=try CloseIndicatorScreen.Rule(rawValue:ruleName).map { try CloseIndicatorScreen.signals(dates:dates,prices:ownPrices,
                    rule:$0,start:frame.dates[frame.simulationRange.lowerBound]) }
                    ?? dates.indices.map { CloseIndicatorScreen.Signal(date:dates[$0],close:ownPrices[$0],value:nil,weight:1) }
                legacySignals[id]=signals
                func desired(_ c: StrategyTargetContext) -> Double {
                    guard c.index > frame.simulationRange.lowerBound else { return 0 }
                    var lo=0,hi=signals.count
                    while lo<hi { let mid=(lo+hi)/2; if signals[mid].date<=c.signalDate { lo=mid+1 } else { hi=mid } }
                    return lo>0 ? signals[lo-1].weight : 0
                }
                var submitted: Double?
                guard let run=BacktestDailySimulator.run(frame:frame,execution:execution,
                    provider:.init { c in desired(c)==1 ? [symbol:1] : [:] },
                    rebalanceDecision:{ _,_ in .init(shouldRebalance:false,refreshOverlay:false) },
                    contextualRebalanceDecision:{ c in
                        let w=desired(c),changed=submitted == nil || submitted != w
                        if changed { submitted=w }
                        return .init(shouldRebalance:changed,refreshOverlay:false)
                    }) else { throw BacktestConfigurationError.computationFailed }
                var mismatches=0
                for (offset,state) in run.dailyStates.enumerated() {
                    let i=frame.simulationRange.lowerBound+offset
                    let known=offset==0 ? 0 : signals.last(where:{ $0.date<=frame.dates[i-1] })?.weight ?? 0
                    if (state.targetWeights[symbol] ?? 0) != known { mismatches+=1 }
                }
                guard mismatches==0 else { throw BacktestConfigurationError.invalidParameter("SAR legacy target delivery") }
                audits[id]=["desired_accepted_mismatches":mismatches,"state_count":run.dailyStates.count]
                accounts.append(.init(id:id,states:run.dailyStates,trades:run.trades))
            }
        }
        guard let cash=BacktestDailySimulator.run(frame:legacy,execution:execution,provider:.init { _ in [:] },
            rebalanceDecision:{ _,_ in .init(shouldRebalance:false,refreshOverlay:false) }) else { throw BacktestConfigurationError.computationFailed }
        accounts.append(.init(id:"cny-cash-diagnostic",states:cash.dailyStates,trades:cash.trades))
        guard accounts.count==13 else { throw BacktestConfigurationError.invalidParameter("1SAR+inverse+2nativecontrols+9legacy budget") }
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        var savedIDs: [String]=[]
        for file in sources.files {
            let data=try Data(contentsOf:URL(fileURLWithPath:file.path))
            guard ResearchRunEvidence.sha256(data)==file.sha256 else { throw BacktestConfigurationError.invalidParameter("SAR saved hash") }
            let saved=try decoder.decode([Saved].self,from:data)
            for id in file.ids {
                let matching=saved.filter { $0.id==id }
                guard matching.count==1,!matching[0].dailyStates.isEmpty else { throw BacktestConfigurationError.missingData(id) }
                savedIDs.append(id);accounts.append(.init(id:id,states:matching[0].dailyStates,trades:[]))
            }
        }
        guard savedIDs==BacktestProductStrategyCatalog.curatedTemplateIDs+BacktestProductStrategyCatalog.basicTemplateIDs+["nfci-dual-core-v11-qual-role"],
            accounts.count==33 else { throw BacktestConfigurationError.invalidParameter("all20 SAR control scope") }
        let text=BacktestSeriesAlignment.historicalSeriesDateString(from:)
        func compare(_ selected: [Account]) throws -> ([DailyScreenOutput.Row],[Date]) {
            let common=selected.reduce(Set(selected[0].states.map(\.date))) { $0.intersection(Set($1.states.map(\.date))) }.sorted()
            guard common.count>252 else { throw BacktestConfigurationError.missingData("SAR common calendar") }
            let set=Set(common),first=common.first!,last=common.last!
            let ten=BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding:.year,value:-10,to:last)!
            let windows=[("full",text(first),text(last)),("trailing10Y",text(ten),text(last)),("since2020","2020-01-01",text(last)),
                ("since2022","2022-01-01",text(last)),("crisis2008","2008-01-01","2008-12-31"),("crisis2020","2020-01-01","2020-12-31"),
                ("crisis2022","2022-01-01","2022-12-31")]
            return (try selected.map { try DailyScreenOutput.row($0.id,states:$0.states.filter { set.contains($0.date) },trades:$0.trades,windows:windows) },common)
        }
        let (long,longDates)=try compare(Array(accounts.dropLast())),(all20,all20Dates)=try compare(accounts)
        let nativeRows=try accounts.map { try DailyScreenOutput.row($0.id,states:$0.states,trades:$0.trades,
            windows:[("native_full",text($0.states.first!.date),text($0.states.last!.date))]) }
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let result=try encoder.encode(long)
        let evidence: [String:Any]=["completed_at":ISO8601DateFormatter().string(from:Date()),
            "evidence_class":"D0_FIXED_SINGLE_INDICATOR_NASDAQ_SAR","formal_validation":false,"objective_complete":false,
            "recommendation_eligible":false,"source_commit":sourceCommit,"execution_version":BacktestExecutionVersion.defaultEngineVersion,
            "history_sha256":ResearchRunEvidence.sha256(history),"accounts_sha256":ResearchRunEvidence.sha256(accountRaw),
            "result_sha256":ResearchRunEvidence.sha256(result),"candidate_count":1,"policy_specifications":1,"inverse_controls":1,
            "native_new_accounts":4,"funded_accounts":13,"old_rule_controls":6,"saved_control_count":20,"annual_selectors":0,
            "parameter_search_budget":0,"fee_percent":0.025,"slippage_percent":0,"long_dates":longDates.map(text),"all20_dates":all20Dates.map(text),
            "native_ids":nativeIDs,"target_audits":audits,
            "binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "limitations":["All one candidate and inverse/accounting controls retained; no post-result threshold grid.",
                "SAR USD bars start2000-01-03; RMB funding begins2000-01-13 first actually available FX. Eight earlier USD bars are signal-only.",
                "Gold only supplies the existing calendar, is never a SAR signal or held; missing12goldOHLCbars are not fabricated.",
                "Index price proxy and App historic FX; no funded total return/quote-vintage/USD wallet certification, formalG0-G6 or independent OOS.",
                "Original long2002 calendar retained; QUAL lacks2509earlydates and all20comparison is supplemental."]]
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for(name,data)in [("result.json",result),("all20.json",try encoder.encode(all20)),("native-full.json",try encoder.encode(nativeRows)),
            ("signals.json",try encoder.encode(signalEvidence)),("legacy-signals.json",try encoder.encode(legacySignals))] {
            try data.write(to:output.appendingPathComponent(name))
        }
        for(name,frame)in [("native-frame.json",native),("frame.json",legacy)] {
            try JSONSerialization.data(withJSONObject:["dates":frame.dates.map(text),"prices":frame.pricesBySymbol,
                "observed":frame.observedBySymbol,"simulation_first":frame.simulationRange.lowerBound,"simulation_last":frame.simulationRange.upperBound],
                options:[.sortedKeys]).write(to:output.appendingPathComponent(name))
        }
        try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("evidence.json"))
        print("Fixed SAR:1candidate,1inverse,13fundedaccounts,20savedcontrols;native\(nativeRows[0].dailyStates.count)/long\(longDates.count)/all20\(all20Dates.count) dates.")
    }
}
