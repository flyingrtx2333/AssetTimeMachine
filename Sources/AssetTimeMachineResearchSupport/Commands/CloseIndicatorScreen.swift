import Foundation
import AssetTimeMachineBacktestCore

/// Fixed single-indicator discovery; three published arithmetic specifications, no parameter grid.
/// Price-index research only; no product registration or formal promotion.
public enum CloseIndicatorScreen {
    public enum Rule: String, CaseIterable {
        case kama = "kama10-2-30", trix = "trix15-zero", cmo = "cmo20-reentry"
    }
    public struct Signal: Codable, Equatable {
        public let date: Date
        public let close: Double
        public let value: Double?
        public let weight: Double
    }
    public static func values(prices: [Double], rule: Rule) throws -> [Double?] {
        guard prices.count >= 44, prices.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("fixed indicator prices")
        }
        var result = Array<Double?>(repeating:nil,count:prices.count)
        switch rule {
        case .kama:
            var value = prices.prefix(10).reduce(0,+) / 10
            result[9] = value
            for i in 10..<prices.count {
                let volatility = ((i-9)...i).reduce(0.0) { $0 + abs(prices[$1]-prices[$1-1]) }
                let er = volatility > 0 ? abs(prices[i]-prices[i-10]) / volatility : 0
                let sc = pow(er * (2.0/3 - 2.0/31) + 2.0/31,2)
                value += sc * (prices[i]-value)
                result[i] = value
            }
        case .trix:
            func ema15(_ input: [Double?]) -> [Double?] {
                var output = Array<Double?>(repeating:nil,count:input.count)
                var seed: [Double] = [], last: Double?
                for i in input.indices {
                    guard let current = input[i] else { continue }
                    if let previous = last { last = previous + 0.125 * (current-previous) }
                    else {
                        seed.append(current)
                        if seed.count == 15 { last = seed.reduce(0,+)/15 }
                    }
                    output[i] = last
                }
                return output
            }
            let triple = ema15(ema15(ema15(prices.map { Optional($0) })))
            for i in 1..<prices.count {
                if let current = triple[i], let previous = triple[i-1] { result[i] = 100 * (current/previous-1) }
            }
        case .cmo:
            for i in 20..<prices.count {
                var up = 0.0, down = 0.0
                for j in (i-19)...i {
                    let change = prices[j]-prices[j-1]
                    up += max(change,0); down += max(-change,0)
                }
                result[i] = up+down > 0 ? 100 * (up-down)/(up+down) : 0
            }
        }
        return result
    }
    public static func signals(dates: [Date], prices: [Double], rule: Rule, start: Date) throws -> [Signal] {
        guard dates.count == prices.count, zip(dates,dates.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw BacktestConfigurationError.invalidParameter("fixed indicator observations")
        }
        let indicator = try values(prices:prices,rule:rule)
        var held = false, result: [Signal] = []
        for i in prices.indices {
            if dates[i] >= start, let value = indicator[i] {
                switch rule {
                case .kama: held = prices[i] > value
                case .trix: held = value > 0
                case .cmo:
                    if held { if value >= 0 { held = false } }
                    else if i > 0, let previous = indicator[i-1] {
                        held = previous <= -50 && value > -50 && value < 0
                    }
                }
            }
            result.append(.init(date:dates[i],close:prices[i],value:indicator[i],weight:held ? 1 : 0))
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
        guard sources.schema == "catalogue20-saved-for-close-indicators-v1", sources.files.count == 2 else {
            throw BacktestConfigurationError.invalidParameter("Close-indicator saved controls")
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
            throw BacktestConfigurationError.missingData("Close-indicator original full frame")
        }
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed single-indicator research")
        struct Account { let id: String; let states: [BacktestDailyState]; let trades: [AdvancedBacktestTrade] }
        var accounts: [Account] = [], signalEvidence: [String:[Signal]] = [:]
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
            for ruleName in Rule.allCases.map(\.rawValue) + ["buy-hold"] {
                let id = symbol + ":" + ruleName
                let signals = try Rule(rawValue:ruleName).map { try self.signals(dates:ownDates,prices:ownPrices,
                    rule:$0,start:frame.dates[frame.simulationRange.lowerBound]) }
                    ?? ownDates.indices.map { Signal(date:ownDates[$0],close:ownPrices[$0],value:nil,weight:1) }
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
                guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("Close-indicator target fidelity") }
                audits[id] = ["desired_accepted_mismatches":mismatches,"state_count":run.dailyStates.count]
                accounts.append(.init(id:id,states:run.dailyStates,trades:run.trades))
            }
        }
        guard let cash = BacktestDailySimulator.run(frame: fullFrame, execution: execution,
            provider: .init { _ in [:] }, rebalanceDecision: { _,_ in .init(shouldRebalance: false, refreshOverlay: false) }) else {
            throw BacktestConfigurationError.computationFailed
        }
        accounts.append(.init(id:"cny-cash-diagnostic",states:cash.dailyStates,trades:cash.trades))
        guard accounts.count == 9 else { throw BacktestConfigurationError.invalidParameter("6 fixed indicators plus3 controls budget") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var savedIDs: [String] = []
        for file in sources.files {
            let data = try Data(contentsOf: URL(fileURLWithPath:file.path))
            guard ResearchRunEvidence.sha256(data) == file.sha256 else { throw BacktestConfigurationError.invalidParameter("Close-indicator control hash") }
            let saved = try decoder.decode([Saved].self,from:data)
            for id in file.ids {
                let matching = saved.filter { $0.id == id }
                guard matching.count == 1, !matching[0].dailyStates.isEmpty else { throw BacktestConfigurationError.missingData(id) }
                savedIDs.append(id); accounts.append(.init(id:id,states:matching[0].dailyStates,trades:[]))
            }
        }
        guard savedIDs == BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs
            + ["nfci-dual-core-v11-qual-role"], accounts.count == 29 else { throw BacktestConfigurationError.invalidParameter("Close-indicator all20 control scope") }
        let text = BacktestSeriesAlignment.historicalSeriesDateString(from:)
        func compare(_ selected: [Account]) throws -> ([DailyScreenOutput.Row],[Date]) {
            let common = selected.reduce(Set(selected[0].states.map(\.date))) { $0.intersection(Set($1.states.map(\.date))) }.sorted()
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("Close-indicator full common calendar") }
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
            "evidence_class":"D0_FIXED_CLOSE_INDICATOR_DISCOVERY", "formal_validation":false,"objective_complete":false,
            "recommendation_eligible":false,"source_commit":sourceCommit,"execution_version":BacktestExecutionVersion.defaultEngineVersion,
            "history_sha256":ResearchRunEvidence.sha256(history),"accounts_sha256":ResearchRunEvidence.sha256(accountRaw),
            "result_sha256":ResearchRunEvidence.sha256(result),"candidate_count":6,"parameter_search_budget":0,
            "funded_accounts":9,"saved_control_count":20,"annual_selectors":0,"fee_percent":0.025,"slippage_percent":0,
            "long_dates":longDates.map(text),"all20_dates":all20Dates.map(text),"target_audits":audits,
            "binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "limitations":["Previously exposed history; fixed family counted completely but no independent OOS or formal G0-G6.",
                "Original full 2002 long calendar retained; QUAL lacks2509earlydates and all20comparison is supplemental.",
                "Same unlevered index/gold price proxies, observed closes, prior information and RMB cash; not independently funded instrument total-return certification.",
                "All6results retained; best historic indicator is not a guaranteed future winner; stop at this budget."]]
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for (name,data) in [("result.json",result),("all20.json",try encoder.encode(all20)),
            ("native-full.json",try encoder.encode(native)),("signals.json",try encoder.encode(signalEvidence))] {
            try data.write(to:output.appendingPathComponent(name))
        }
        try JSONSerialization.data(withJSONObject:["dates":fullFrame.dates.map(text),"prices":fullFrame.pricesBySymbol,
            "observed":fullFrame.observedBySymbol,"simulation_first":fullFrame.simulationRange.lowerBound],options:[.sortedKeys])
            .write(to:output.appendingPathComponent("frame.json"))
        try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("evidence.json"))
        print("Fixed close indicators:6candidates,9fundedaccounts,20savedcontrols;long\(longDates.count)/all20\(all20Dates.count) dates.")
    }
}
