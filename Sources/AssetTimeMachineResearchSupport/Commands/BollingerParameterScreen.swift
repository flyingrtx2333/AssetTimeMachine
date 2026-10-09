import Foundation
import AssetTimeMachineBacktestCore

/// User-authorized, bounded 36-point parameter study of the existing three rules.
/// No annual selector, added filter, new economic mechanism or product promotion.
public enum BollingerParameterScreen {
    public static func signals(dates: [Date], prices: [Double], rule: SingleIndicatorScreen.Rule,
                               start: Date, period: Int, multiplier: Double) throws -> [SingleIndicatorScreen.Signal] {
        guard [10,20,40].contains(period), [1.5,2.0].contains(multiplier),
              dates.count == prices.count, dates.count >= period + 1,
              zip(dates, dates.dropFirst()).allSatisfy({ $0 < $1 }),
              prices.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("bounded Bollinger configuration")
        }
        var held = false, result: [SingleIndicatorScreen.Signal] = []
        for i in prices.indices {
            var band: (middle: Double, lower: Double, upper: Double)?
            if i >= period - 1 {
                let window = prices[(i - period + 1)...i]
                let mean = window.reduce(0, +) / Double(period)
                let sigma = sqrt(window.reduce(0) { $0 + pow($1 - mean, 2) } / Double(period))
                band = (mean, mean - multiplier * sigma, mean + multiplier * sigma)
            }
            if i >= period, dates[i] >= start, let current = band,
               let previousMiddle = result[i - 1].middle,
               let previousLower = result[i - 1].lower, let previousUpper = result[i - 1].upper {
                let exit = rule == .upperBreakout
                    ? prices[i - 1] >= previousMiddle && prices[i] < current.middle
                    : prices[i - 1] <= previousMiddle && prices[i] > current.middle
                if held { if exit { held = false } }
                else {
                    switch rule {
                    case .lowerDowncross: held = prices[i - 1] > previousLower && prices[i] <= current.lower
                    case .lowerReentry: held = prices[i - 1] <= previousLower && prices[i] > current.lower && prices[i] <= current.middle
                    case .upperBreakout: held = prices[i - 1] < previousUpper && prices[i] >= current.upper
                    }
                }
            }
            result.append(.init(date: dates[i], close: prices[i], middle: band?.middle,
                lower: band?.lower, upper: band?.upper, weight: held ? 1 : 0))
        }
        return result
    }
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
        guard sources.schema == "catalogue20-saved-for-bollinger36-v1", sources.files.count == 2 else {
            throw BacktestConfigurationError.invalidParameter("Bollinger saved controls")
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
            throw BacktestConfigurationError.missingData("Bollinger original full frame")
        }
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed single-indicator research")
        struct Account { let id: String; let states: [BacktestDailyState]; let trades: [AdvancedBacktestTrade] }
        var accounts: [Account] = [], signalEvidence: [String:[SingleIndicatorScreen.Signal]] = [:]
        var audits: [String:[String:Int]] = [:]
        for symbol in ["gold_cny","nasdaq"] {
            guard let prices = fullFrame.pricesBySymbol[symbol], let original = dataset.seriesBySymbol[symbol],
                  let option = fullFrame.optionBySymbol[symbol] else { throw BacktestConfigurationError.missingData(symbol) }
            let originalDates = Set(original.dates.compactMap { BacktestSeriesAlignment.historicalSeriesDate(from: $0) })
            let ownIndices = fullFrame.dates.indices.filter { originalDates.contains(fullFrame.dates[$0]) }
            let ownDates = ownIndices.map { fullFrame.dates[$0] }, ownPrices = ownIndices.map { prices[$0] }
            let frame = MarketDataFrame(dates: fullFrame.dates, pricesBySymbol: [symbol:prices],
                observedBySymbol: [symbol:fullFrame.observedBySymbol[symbol]!], ohlcBySymbol: [:],
                tradableSymbols: [symbol], optionBySymbol: [symbol:option], simulationRange: fullFrame.simulationRange)
            var settings: [(String,SingleIndicatorScreen.Rule?,Int,Double)] = []
            for rule in SingleIndicatorScreen.Rule.allCases {
                for period in [10,20,40] { for sigma in [1.5,2.0] {
                    settings.append((symbol + ":" + rule.rawValue + ":P\(period):K\(sigma == 2 ? "2" : "1.5")",rule,period,sigma))
                } }
            }
            settings.append((symbol + ":buy-hold",nil,20,2))
            for (id,rule,period,sigma) in settings {
                let signals = try rule.map { try self.signals(dates: ownDates, prices: ownPrices, rule: $0,
                    start: frame.dates[frame.simulationRange.lowerBound], period: period, multiplier: sigma) }
                    ?? ownDates.indices.map { SingleIndicatorScreen.Signal(date: ownDates[$0], close: ownPrices[$0],
                        middle: nil, lower: nil, upper: nil, weight: 1) }
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
                guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("Bollinger target fidelity") }
                audits[id] = ["desired_accepted_mismatches":mismatches,"state_count":run.dailyStates.count]
                accounts.append(.init(id:id,states:run.dailyStates,trades:run.trades))
            }
        }
        guard let cash = BacktestDailySimulator.run(frame: fullFrame, execution: execution,
            provider: .init { _ in [:] }, rebalanceDecision: { _,_ in .init(shouldRebalance: false, refreshOverlay: false) }) else {
            throw BacktestConfigurationError.computationFailed
        }
        accounts.append(.init(id:"cny-cash-diagnostic",states:cash.dailyStates,trades:cash.trades))
        guard accounts.count == 39 else { throw BacktestConfigurationError.invalidParameter("36 parameters plus3 controls budget") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var savedIDs: [String] = []
        for file in sources.files {
            let data = try Data(contentsOf: URL(fileURLWithPath:file.path))
            guard ResearchRunEvidence.sha256(data) == file.sha256 else { throw BacktestConfigurationError.invalidParameter("Bollinger control hash") }
            let saved = try decoder.decode([Saved].self,from:data)
            for id in file.ids {
                let matching = saved.filter { $0.id == id }
                guard matching.count == 1, !matching[0].dailyStates.isEmpty else { throw BacktestConfigurationError.missingData(id) }
                savedIDs.append(id); accounts.append(.init(id:id,states:matching[0].dailyStates,trades:[]))
            }
        }
        guard savedIDs == BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs
            + ["nfci-dual-core-v11-qual-role"], accounts.count == 59 else { throw BacktestConfigurationError.invalidParameter("Bollinger all20 control scope") }
        let text = BacktestSeriesAlignment.historicalSeriesDateString(from:)
        func compare(_ selected: [Account]) throws -> ([DailyScreenOutput.Row],[Date]) {
            let common = selected.reduce(Set(selected[0].states.map(\.date))) { $0.intersection(Set($1.states.map(\.date))) }.sorted()
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("Bollinger full common calendar") }
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
            "evidence_class":"D0_USER_AUTHORIZED_BOUNDED_BOLLINGER36", "formal_validation":false,"objective_complete":false,
            "recommendation_eligible":false,"source_commit":sourceCommit,"execution_version":BacktestExecutionVersion.defaultEngineVersion,
            "history_sha256":ResearchRunEvidence.sha256(history),"accounts_sha256":ResearchRunEvidence.sha256(accountRaw),
            "result_sha256":ResearchRunEvidence.sha256(result),"parameter_configuration_count":36,"new_variants":30,
            "funded_accounts":39,"saved_control_count":20,"annual_selectors":0,"fee_percent":0.025,"slippage_percent":0,
            "long_dates":longDates.map(text),"all20_dates":all20Dates.map(text),"target_audits":audits,
            "binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "limitations":["Previously exposed history; parameter family counted completely but no independent OOS or formal G0-G6.",
                "Original full 2002 long calendar retained; QUAL lacks2509earlydates and all20comparison is supplemental.",
                "Same unlevered index/gold price proxies, observed closes, prior information and RMB cash; not independently funded instrument total-return certification.",
                "All36results retained; best historic parameter is not a guaranteed future winner; stop at this budget."]]
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for (name,data) in [("result.json",result),("all20.json",try encoder.encode(all20)),
            ("native-full.json",try encoder.encode(native)),("signals.json",try encoder.encode(signalEvidence))] {
            try data.write(to:output.appendingPathComponent(name))
        }
        try JSONSerialization.data(withJSONObject:["dates":fullFrame.dates.map(text),"prices":fullFrame.pricesBySymbol,
            "observed":fullFrame.observedBySymbol,"simulation_first":fullFrame.simulationRange.lowerBound],options:[.sortedKeys])
            .write(to:output.appendingPathComponent("frame.json"))
        try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("evidence.json"))
        print("Bounded Bollinger study:36configurations,39fundedaccounts,20savedcontrols;long\(longDates.count)/all20\(all20Dates.count) dates.")
    }
}
