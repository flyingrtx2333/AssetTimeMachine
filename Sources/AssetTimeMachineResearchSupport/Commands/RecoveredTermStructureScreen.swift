import Foundation
import AssetTimeMachineBacktestCore

/// Existing 2008 curve family resumed after its original source contract passed.
/// No new strategy, parameter search, product registration or blind OOS claim.
public enum RecoveredTermStructureScreen {
    struct CurveInput: Decodable { let schema: String; let rows: [CurveRow] }
    struct Decision: Codable {
        let index: Int; let date: Date; let signalDate: Date
        let desired: [String:Double]; let submitted: Bool
    }
    static func date(_ text: String) throws -> Date { try CurveSignals.date(text) }
    static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
    }
    public static func run(mode: String, curvePath: String, historyPath: String,
                           preparedPath: String, outputPath: String, sourceCommit: String) throws {
        let output=URL(fileURLWithPath:outputPath)
        guard ["prepare","run"].contains(mode), !FileManager.default.fileExists(atPath:output.path) else {
            throw BacktestConfigurationError.invalidParameter("preserve recovered term output / mode")
        }
        let history=try Data(contentsOf:URL(fileURLWithPath:historyPath))
        let curveRaw=try Data(contentsOf:URL(fileURLWithPath:curvePath))
        let response=try JSONDecoder().decode(PublicHistoryResponse.self,from:history)
        let input=try JSONDecoder().decode(CurveInput.self,from:curveRaw)
        guard input.schema=="original-term-curve-recovered-v1",input.rows.first?.date=="2007-12-04",
              input.rows.last?.date=="2026-09-04",input.rows.count==4718,response.success,
              Set(response.series.map(\.symbol))==Set(["gold_cny","nasdaq_composite","usd_per_cny"]),
              response.series.allSatisfy({ $0.dates.last=="2026-09-04" && $0.dates.count==$0.prices.count }) else {
            throw BacktestConfigurationError.missingData("original recovered curve/native source contract")
        }
        try CurveSignals.validate(input.rows)
        let signalChecks=try CurveSignals.selfTest()
        let product=try StrategyRegistry.definition(id:"gold-nasdaq-dual-trend-barbell")
        // The original study has exactly three source series. The general public
        // dataset loader requires unrelated full-catalogue symbols; do not add data.
        var native:[String:PublicHistorySeries]=[:]
        for series in response.series {
            guard zip(series.dates,series.dates.dropFirst()).allSatisfy({ $0<$1 }),
                  series.prices.allSatisfy({ $0.isFinite && $0>0 }),
                  series.dates.allSatisfy({ BacktestSeriesAlignment.historicalSeriesDate(from:$0) != nil }) else {
                throw BacktestConfigurationError.invalidParameter("original native observations")
            }
            native[series.symbol=="nasdaq_composite" ? "nasdaq" : series.symbol]=series
        }
        guard native["gold_cny"]?.currency=="CNY",native["nasdaq"]?.currency=="USD",
              let fx=native["usd_per_cny"] else { throw BacktestConfigurationError.missingData("original native FX") }
        let options=BacktestCoreStrategyDefaults.assetOptions(for:product.template)
        guard Set(options.map(\.symbol))==Set(CurveSignals.symbols) else {
            throw BacktestConfigurationError.invalidParameter("original gold/Nasdaq instrument domain")
        }
        let assets=options.map { (assetSeries:native[$0.symbol],assetOption:$0,fxSeries:$0.requiresHistoricalFX ? fx : nil) }
        let start=try date("2008-01-01"),end=try date("2026-09-04")
        let config=ResearchTargetStrategyConfig(symbol:"recovered-term",title:"recovered-term",
            warmupSessions:1,rebalanceSessions:1,rebalanceBand:0,tradeToBandBoundary:false,
            maxGrossExposure:1,allowsFinancedExposure:false,financingAnnualRate:0,buyReason:"original term ratio")
        guard let frame=TargetProviderBacktest.researchMarketDataFrame(assetInputs:assets,config:config,dateBounds:start...end) else {
            throw BacktestConfigurationError.missingData("original 2008 shared frame")
        }
        let days=frame.dates.map(\.backtestDateString),indices=Array(frame.simulationRange)
        guard frame.dates[indices[0]]>start,days[indices.last!]=="2026-09-04" else {
            throw BacktestConfigurationError.invalidParameter("frozen funded range")
        }
        var plans:[String:[CurveOrder]]=[:],planJSON:[String:[[String:Any]]]=[:],audits:[String:[[String:Any]]]=[:]
        for variant in CurveSignals.variants where variant != "product" {
            let (orders,audit)=try CurveSignals.orders(days:days,indices:indices,rows:input.rows,variant:variant)
            let shortDays=days.filter { $0 <= "2020-12-31" }
            let (prefix,_)=try CurveSignals.orders(days:shortDays,indices:indices.filter { $0<shortDays.count },
                rows:input.rows.filter { $0.date<="2020-12-31" },variant:variant)
            guard prefix==orders.filter({ $0.signalDate<="2020-12-31" }) else {
                throw BacktestConfigurationError.invalidParameter("original curve prefix invariance")
            }
            plans[variant]=orders;planJSON[variant]=orders.map(\.json);audits[variant]=audit
        }
        let frameRaw=try data(["dates":days,"prices":frame.pricesBySymbol,"observed":frame.observedBySymbol,
            "first_index":indices[0],"last_index":indices.last!] as [String:Any])
        let planRaw=try data(planJSON)
        if mode=="prepare" {
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            try frameRaw.write(to:output.appendingPathComponent("frame.json"))
            try planRaw.write(to:output.appendingPathComponent("plans.json"))
            try data(audits).write(to:output.appendingPathComponent("signal-audit.json"))
            try data(["status":"PASS_SIGNALS_ONLY_NO_CAPITAL_PATH","prepared_at":ISO8601DateFormatter().string(from:Date()),
                "signal_checks":signalChecks,"prefix_checks":5,"funded_dates":indices.count,
                "history_sha256":ResearchRunEvidence.sha256(history),"curve_sha256":ResearchRunEvidence.sha256(curveRaw),
                "frame_sha256":ResearchRunEvidence.sha256(frameRaw),"plan_sha256":ResearchRunEvidence.sha256(planRaw),
                "historical_pnl_computed":false]).write(to:output.appendingPathComponent("evidence.json"))
            print("Recovered term: original 18 signal checks and five prefix checks; no capital path.")
            return
        }
        let prepared=URL(fileURLWithPath:preparedPath)
        guard try Data(contentsOf:prepared.appendingPathComponent("frame.json"))==frameRaw,
              try Data(contentsOf:prepared.appendingPathComponent("plans.json"))==planRaw else {
            throw BacktestConfigurationError.invalidParameter("pre-return frame/schedules changed")
        }
        let windows=[("full_2008","2008-01-01","2026-09-04"),("2008-2015","2008-01-01","2015-12-31"),
            ("2016-2019","2016-01-01","2019-12-31"),("since2016","2016-01-01","2026-09-04"),
            ("since2020","2020-01-01","2026-09-04"),("since2022","2022-01-01","2026-09-04")]
        let seed=BacktestDailyState(date:start,targetWeights:[:],cash:100000,holdingsBySymbol:[:],portfolioValue:100000)
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        var rows:[DailyScreenOutput.Row]=[],traces:[String:[Decision]]=[:],completed:[String:[Int]]=[:]
        for slip in [0.0,0.05] {
            let settings=AdvancedBacktestRiskSettings(feeRate:0.025,slippageRate:slip,maxPositionRatio:100,
                cooldownDays:0,stopLossRatio:0,takeProfitRatio:0)
            for variant in CurveSignals.variants {
                let id=variant+":slip"+String(slip)
                let states:[BacktestDailyState],trades:[AdvancedBacktestTrade]
                if variant=="product" {
                    guard let run=BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(assetInputs:assets,
                        initialCash:100000,settings:settings,mode:product.template.mode,dateBounds:start...end) else {
                        throw BacktestConfigurationError.missingData("original product control")
                    }
                    states=run.dailyStates;trades=run.report.trades
                } else {
                    let orders=plans[variant]!,changes=Dictionary(uniqueKeysWithValues:orders.map { ($0.index,$0) })
                    var trace:[Decision]=[],done:[Int]=[]
                    func desired(_ index:Int)->[String:Double] {
                        (orders.last(where:{ $0.index<=index })?.weights ?? [:]).filter { $0.value>0 }
                    }
                    let execution=BacktestExecutionConfig(initialCash:100000,feeRate:0.00025,slippageRate:slip/100,
                        rebalanceBand:0,financingAnnualRate:0,allowsFinancedExposure:false,buyReason:"original recovered term ratio")
                    guard let run=BacktestDailySimulator.run(frame:frame,execution:execution,
                        provider:.init { desired($0.signalIndex) },
                        rebalanceDecision:{ _,_ in .init(shouldRebalance:false,refreshOverlay:false) },
                        contextualRebalanceDecision:{ c in
                            let changed=changes[c.signalIndex] != nil
                            trace.append(.init(index:c.index,date:c.date,signalDate:c.signalDate,desired:desired(c.signalIndex),submitted:changed))
                            return .init(shouldRebalance:changed,refreshOverlay:false)
                        },didExecuteTarget:{ done.append($0) }) else {
                        throw BacktestConfigurationError.computationFailed
                    }
                    states=run.dailyStates;trades=run.trades;traces[id]=trace;completed[id]=done
                    guard zip(states,trace).allSatisfy({ $0.targetWeights==$1.desired }) else {
                        throw BacktestConfigurationError.invalidParameter("current desired/accepted curve target mismatch")
                    }
                }
                guard states.map(\.date)==indices.map({ frame.dates[$0] }) else {
                    throw BacktestConfigurationError.invalidParameter("all original account dates must match")
                }
                rows.append(try DailyScreenOutput.row(id,states:[seed]+states,trades:trades,windows:windows))
            }
        }
        let result=try encoder.encode(rows)
        let evidence:[String:Any]=["completed_at":ISO8601DateFormatter().string(from:Date()),"source_commit":sourceCommit,
            "evidence_class":"POSTHOC_EXISTING_FAMILY_SOURCE_RECOVERY_CURRENT_SHARED_ENGINE","formal_validation":false,
            "original_candidates":2,"original_controls":4,"new_economic_mechanisms":0,"funded_accounts":12,"parameter_searches":0,
            "history_sha256":ResearchRunEvidence.sha256(history),"curve_sha256":ResearchRunEvidence.sha256(curveRaw),
            "frame_sha256":ResearchRunEvidence.sha256(frameRaw),"plan_sha256":ResearchRunEvidence.sha256(planRaw),
            "result_sha256":ResearchRunEvidence.sha256(result),
            "binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]))),
            "execution_version":BacktestExecutionVersion.defaultEngineVersion,
            "product_parameters":String(decoding:try product.frozenParametersJSON,as:UTF8.self),
            "limitations":["Previously exposed 2010 diagnostics; no pristine OOS or formal promotion.",
                "Original App index price proxies/next observed quote, not funded ETF total returns or opening fills.",
                "Only original product benchmark; complete six-product frontier and original publication PIT not certified."]]
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try result.write(to:output.appendingPathComponent("result.json"))
        try encoder.encode(traces).write(to:output.appendingPathComponent("decisions.json"))
        try encoder.encode(completed).write(to:output.appendingPathComponent("completions.json"))
        try data(evidence).write(to:output.appendingPathComponent("evidence.json"))
        print("Original two curve candidates and four controls: all 12 frozen accounts retained.")
    }
}
