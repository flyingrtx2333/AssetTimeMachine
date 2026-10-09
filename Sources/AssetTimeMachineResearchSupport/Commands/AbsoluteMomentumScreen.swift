import Foundation
import AssetTimeMachineBacktestCore

/// Fixed own-asset positive momentum slots; related D0 allocation architecture, not new alpha.
public enum AbsoluteMomentumScreen {
    public typealias Signal = MonthlyMomentumScreen.Signal
    public typealias Rule = MonthlyMomentumScreen.Rule
    private struct Sources: Decodable {
        let schema: String; let files: [File]
        struct File: Decodable { let path: String; let sha256: String; let ids: [String] }
    }
    private struct Saved: Decodable { let id: String; let dailyStates: [BacktestDailyState] }
    public static func run(historyPath: String, accountsPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let accountRaw = try Data(contentsOf: URL(fileURLWithPath: accountsPath))
        let sources = try JSONDecoder().decode(Sources.self, from: accountRaw)
        guard sources.schema == "catalogue20-saved-for-absolute-momentum-v1", sources.files.count == 2 else {
            throw BacktestConfigurationError.invalidParameter("Absolute-momentum saved controls")
        }
        let dataset = try PublicBacktestCore.loadDataset(from: history,
            datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        let reference = try StrategyRegistry.definition(id: "gold-nasdaq-dual-trend-barbell")
        let inputs = BacktestCoreStrategyDefaults.assetOptions(for: reference.template).map {
            MarketInputPreparation.advancedAssetInput(for: $0) { dataset.seriesBySymbol[$0] }
        }
        let lower = MarketInputPreparation.availableDateBounds(for: inputs.flatMap { [$0.assetSeries, $0.fxSeries].compactMap { $0 } })!.lowerBound
        let end = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-10-06")!
        let config = ResearchTargetStrategyConfig(symbol: "single-indicator", title: "single-indicator", warmupSessions: 252, rebalanceSessions: 1)
        guard let fullFrame = TargetProviderBacktest.researchMarketDataFrame(assetInputs: inputs, config: config, dateBounds: lower...end) else {
            throw BacktestConfigurationError.missingData("Absolute-momentum original full frame")
        }
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed single-indicator research")
        struct Account { let id: String; let states: [BacktestDailyState]; let trades: [AdvancedBacktestTrade] }
        var accounts: [Account] = [], signalEvidence: [String:[CloseIndicatorScreen.Signal]] = [:], schedules: [String:[Signal]] = [:]
        var audits: [String:[String:Int]] = [:]
        let nativeIDs = ["gold-nasdaq:roc252-monthly-absolute-halves","gold-nasdaq:roc252-monthly-negative-halves-diagnostic","gold-nasdaq:roc252-monthly-strongest","gold-nasdaq:roc252-monthly-weaker-diagnostic","gold-nasdaq:monthly-50-50-control"]
        for (id,rule) in zip(nativeIDs,[Rule.absoluteEqual,.negativeEqual,.strongest,.weaker,.equalMix]) {
            let schedule = try MonthlyMomentumScreen.schedule(dates:fullFrame.dates,gold:fullFrame.pricesBySymbol["gold_cny"]!,
                nasdaq:fullFrame.pricesBySymbol["nasdaq"]!,startIndex:fullFrame.simulationRange.lowerBound,rule:rule)
            schedules[id] = schedule
            guard let run = BacktestDailySimulator.run(frame:fullFrame,execution:execution,
                provider:.init { c in schedule[c.index].weights },
                rebalanceDecision:{ _,_ in .init(shouldRebalance:false,refreshOverlay:false) },
                contextualRebalanceDecision:{ c in .init(shouldRebalance:schedule[c.index].review,refreshOverlay:false) })
                else { throw BacktestConfigurationError.computationFailed }
            let mismatches = run.dailyStates.enumerated().filter { offset,state in
                state.targetWeights != schedule[fullFrame.simulationRange.lowerBound+offset].weights
            }.count
            guard mismatches==0 else { throw BacktestConfigurationError.invalidParameter("Monthly target delivery") }
            audits[id] = ["desired_accepted_mismatches":mismatches,"state_count":run.dailyStates.count,
                "reviews":schedule[fullFrame.simulationRange].filter(\.review).count]
            accounts.append(.init(id:id,states:run.dailyStates,trades:run.trades))
        }
        for symbol in ["gold_cny","nasdaq"] {
            guard let prices = fullFrame.pricesBySymbol[symbol], let original = dataset.seriesBySymbol[symbol],
                  let option = fullFrame.optionBySymbol[symbol] else { throw BacktestConfigurationError.missingData(symbol) }
            let originalDates = Set(original.dates.compactMap { BacktestSeriesAlignment.historicalSeriesDate(from: $0) })
            let ownIndices = fullFrame.dates.indices.filter { originalDates.contains(fullFrame.dates[$0]) }
            let ownDates = ownIndices.map { fullFrame.dates[$0] }, ownPrices = ownIndices.map { prices[$0] }
            let frame = MarketDataFrame(dates: fullFrame.dates, pricesBySymbol: [symbol:prices],
                observedBySymbol: [symbol:fullFrame.observedBySymbol[symbol]!], ohlcBySymbol: [:],
                tradableSymbols: [symbol], optionBySymbol: [symbol:option], simulationRange: fullFrame.simulationRange)
            for ruleName in CloseIndicatorScreen.Rule.allCases.map(\.rawValue) + ["buy-hold"] {
                let id = symbol + ":" + ruleName
                let signals = try CloseIndicatorScreen.Rule(rawValue:ruleName).map { try CloseIndicatorScreen.signals(dates:ownDates,prices:ownPrices,
                    rule:$0,start:frame.dates[frame.simulationRange.lowerBound]) }
                    ?? ownDates.indices.map { CloseIndicatorScreen.Signal(date:ownDates[$0],close:ownPrices[$0],value:nil,weight:1) }
                signalEvidence[id] = signals
                func desired(_ c: StrategyTargetContext) -> Double {
                    guard c.index > frame.simulationRange.lowerBound else { return 0 }
                    var lo = 0, hi = signals.count
                    while lo < hi { let mid = (lo + hi) / 2; if signals[mid].date <= c.signalDate { lo = mid + 1 } else { hi = mid } }
                    return lo > 0 ? signals[lo - 1].weight : 0
                }
                var submitted: Double?
                guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                    provider: .init { c in desired(c) == 1 ? [symbol:1] : [:] },
                    rebalanceDecision: { _,_ in .init(shouldRebalance: false, refreshOverlay: false) },
                    contextualRebalanceDecision: { c in
                        let w = desired(c), changed = submitted == nil || submitted != w
                        if changed { submitted = w }
                        return .init(shouldRebalance: changed, refreshOverlay: false)
                    }) else { throw BacktestConfigurationError.computationFailed }
                var mismatches = 0
                for (offset,state) in run.dailyStates.enumerated() {
                    let i = frame.simulationRange.lowerBound + offset
                    let known = signals.last(where: { $0.date <= frame.dates[i - 1] })?.weight ?? 0
                    if (state.targetWeights[symbol] ?? 0) != (i == frame.simulationRange.lowerBound ? 0 : known) { mismatches += 1 }
                }
                guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("Absolute-momentum target fidelity") }
                audits[id] = ["desired_accepted_mismatches":mismatches,"state_count":run.dailyStates.count]
                accounts.append(.init(id:id,states:run.dailyStates,trades:run.trades))
            }
        }
        guard let cash = BacktestDailySimulator.run(frame: fullFrame, execution: execution,
            provider: .init { _ in [:] }, rebalanceDecision: { _,_ in .init(shouldRebalance: false, refreshOverlay: false) }) else {
            throw BacktestConfigurationError.computationFailed
        }
        accounts.append(.init(id:"cny-cash-diagnostic",states:cash.dailyStates,trades:cash.trades))
        guard accounts.count == 14 else { throw BacktestConfigurationError.invalidParameter("1absolute candidate+negative+3oldmonthly+9legacy budget") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var savedIDs: [String] = []
        for file in sources.files {
            let data = try Data(contentsOf: URL(fileURLWithPath:file.path))
            guard ResearchRunEvidence.sha256(data) == file.sha256 else { throw BacktestConfigurationError.invalidParameter("Absolute-momentum control hash") }
            let saved = try decoder.decode([Saved].self,from:data)
            for id in file.ids {
                let matching = saved.filter { $0.id == id }
                guard matching.count == 1, !matching[0].dailyStates.isEmpty else { throw BacktestConfigurationError.missingData(id) }
                savedIDs.append(id); accounts.append(.init(id:id,states:matching[0].dailyStates,trades:[]))
            }
        }
        guard savedIDs == BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs
            + ["nfci-dual-core-v11-qual-role"], accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("Absolute-momentum all20 control scope") }
        let text = BacktestSeriesAlignment.historicalSeriesDateString(from:)
        func compare(_ selected: [Account]) throws -> ([DailyScreenOutput.Row],[Date]) {
            let common = selected.reduce(Set(selected[0].states.map(\.date))) { $0.intersection(Set($1.states.map(\.date))) }.sorted()
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("Absolute-momentum full common calendar") }
            let set = Set(common), first = common.first!, last = common.last!
            let ten = BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding:.year,value:-10,to:last)!
            let windows = [("full",text(first),text(last)),("trailing10Y",text(ten),text(last)),("since2020","2020-01-01",text(last)),
                ("since2022","2022-01-01",text(last)),("crisis2008","2008-01-01","2008-12-31"),
                ("crisis2020","2020-01-01","2020-12-31"),("crisis2022","2022-01-01","2022-12-31")]
            return (try selected.map { try DailyScreenOutput.row($0.id,states:$0.states.filter { set.contains($0.date) },trades:$0.trades,windows:windows) },common)
        }
        let (long,longDates) = try compare(Array(accounts.dropLast()))
        let (all20,all20Dates) = try compare(accounts)
        let native = try accounts.map { try DailyScreenOutput.row($0.id,states:$0.states,trades:$0.trades,
            windows:[("native_full",text($0.states.first!.date),text($0.states.last!.date))]) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let result = try encoder.encode(long)
        let evidence: [String:Any] = ["completed_at":ISO8601DateFormatter().string(from:Date()),
            "evidence_class":"D0_FIXED_ABSOLUTE_MOMENTUM_ARCHITECTURE", "formal_validation":false,"objective_complete":false,
            "recommendation_eligible":false,"source_commit":sourceCommit,"execution_version":BacktestExecutionVersion.defaultEngineVersion,
            "history_sha256":ResearchRunEvidence.sha256(history),"accounts_sha256":ResearchRunEvidence.sha256(accountRaw),
            "result_sha256":ResearchRunEvidence.sha256(result),"candidate_count":1,"policy_specifications":1,"inverse_controls":1,"new_funded_accounts":2,"old_monthly_controls":3,"old_rule_controls":6,"parameter_search_budget":0,
            "funded_accounts":14,"saved_control_count":20,"annual_selectors":0,"fee_percent":0.025,"slippage_percent":0,
            "long_dates":longDates.map(text),"all20_dates":all20Dates.map(text),"target_audits":audits,
            "binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "limitations":["Previously exposed history; fixed family counted completely but no independent OOS or formal G0-G6.",
                "Original full 2002 long calendar retained; QUAL lacks2509earlydates and all20comparison is supplemental.",
                "Same unlevered index/gold price proxies, observed closes, prior information and RMB cash; not independently funded instrument total-return certification.",
                "One related absolute252day monthly architecture, fixed50%own-assetpositive slots; no redistribution. Negative diagnostic,3oldmonthly,9legacy and20savedApp all retained. No learnedweights,constantcashdilution,independentalpha or paperreplication.","Initial funding state cash; first review is first post-seed session, then first shared valuation date each new calendar month. Periodic unchanged-target maintenance is intentional; no daily maintenance.","All native6032 and long5595 history preserved; full family closes after one guarded run, no post-return horizon/weight rescue."]]
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for (name,data) in [("result.json",result),("all20.json",try encoder.encode(all20)),
            ("native-full.json",try encoder.encode(native)),("legacy-signals.json",try encoder.encode(signalEvidence)),("signals.json",try encoder.encode(schedules))] {
            try data.write(to:output.appendingPathComponent(name))
        }
        try JSONSerialization.data(withJSONObject:["dates":fullFrame.dates.map(text),"prices":fullFrame.pricesBySymbol,
            "observed":fullFrame.observedBySymbol,"simulation_first":fullFrame.simulationRange.lowerBound,"simulation_last":fullFrame.simulationRange.upperBound],options:[.sortedKeys])
            .write(to:output.appendingPathComponent("frame.json"))
        try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("evidence.json"))
        print("Fixed absolute momentum:1candidate,1newdiagnostic,3oldmonthly,14fundedaccounts,20savedcontrols;long\(longDates.count)/all20\(all20Dates.count) dates.")
    }
}
