import Foundation
import AssetTimeMachineBacktestCore

/// Accounting correction only: the original RSI/IBS signals and clocks remain frozen.
public enum QQQReversalCashCorrection {
    private struct Input: Decodable {
        let schema: String; let symbol: String; let bars: [SectorMonthstartScreen.Bar]
        let splits: [Split]
        struct Split: Decodable { let effective_date: String; let new_units_per_old_unit: Double }
    }
    private struct Cash: Decodable {
        let schema: String; let events: [Event]
        struct Event: Decodable { let symbol: String; let ex_date: String; let payment_date: String; let amount_usd: Double }
    }
    private struct Sources: Decodable {
        let schema: String; let files: [File]
        struct File: Decodable { let path: String; let sha256: String; let ids: [String] }
    }
    private struct Saved: Decodable { let id: String; let dailyStates: [BacktestDailyState] }

    public static func run(pricesPath: String, historyPath: String, cashPath: String,
                           accountsPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let cashRaw = try Data(contentsOf: URL(fileURLWithPath: cashPath))
        let savedRaw = try Data(contentsOf: URL(fileURLWithPath: accountsPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        let cash = try JSONDecoder().decode(Cash.self, from: cashRaw)
        let sources = try JSONDecoder().decode(Sources.self, from: savedRaw)
        guard input.schema == "qqq-short-reversal-v1", input.symbol == "QQQ", input.bars.count == 6935,
              input.bars.first?.date == "1999-03-10", input.bars.last?.date == "2026-10-02",
              input.splits.count == 1, input.splits[0].effective_date == "2000-03-20",
              input.splits[0].new_units_per_old_unit == 2,
              cash.schema == "qqq-inception-issuer-cash-diagnostic-v1", cash.events.count == 89,
              Set(cash.events.map(\.ex_date)).count == 89,
              cash.events.first?.ex_date == "2003-12-24", cash.events.last?.ex_date == "2026-09-21",
              cash.events.allSatisfy({ $0.symbol == "QQQ" && $0.ex_date <= "2026-10-02"
                  && $0.payment_date >= $0.ex_date && $0.amount_usd.isFinite && $0.amount_usd > 0 }),
              sources.schema == "catalogue20-saved-for-qqq-cash-v1", sources.files.count == 2 else {
            throw BacktestConfigurationError.invalidParameter("frozen QQQ correction input scope")
        }
        func date(_ day: String) throws -> Date {
            guard let value = BacktestSeriesAlignment.historicalSeriesDate(from: day) else {
                throw BacktestConfigurationError.invalidParameter("QQQ correction date")
            }
            return value
        }
        let days = input.bars.map(\.date), dates = try days.map(date)
        let bars = input.bars.indices.map { i in QQQReversalScreen.Bar(date: dates[i], open: input.bars[i].open,
            high: input.bars[i].high, low: input.bars[i].low, close: input.bars[i].close) }
        let splits = try input.splits.map { s in BacktestShareSplit(id: "QQQ:" + s.effective_date,
            symbol: "QQQ", effectiveDate: try date(s.effective_date), newUnitsPerOldUnit: s.new_units_per_old_unit) }
        let signals = try QQQReversalScreen.signals(bars: bars,
            splits: Dictionary(uniqueKeysWithValues: splits.map { ($0.effectiveDate, $0.newUnitsPerOldUnit) }))
        let dataset = try PublicBacktestCore.loadDataset(from: history,
            datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        guard let fx = dataset.seriesBySymbol["usd_per_cny"], cash.events.allSatisfy({ days.contains($0.ex_date) }) else {
            throw BacktestConfigurationError.missingData("QQQ ex sessions and historical FX")
        }
        let conversion = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates, prices: fx.prices, asOf: $0)) }
        let closes = zip(bars, conversion).map { $0.close * $1 }, opens = zip(bars, conversion).map { $0.open * $1 }
        let instrument = BacktestInstrument(symbol: "QQQ", title: "QQQ cash correction", requiresHistoricalFX: false, historicalFXSymbol: nil)
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: ["QQQ": closes],
            observedBySymbol: ["QQQ": Array(repeating: true, count: days.count)], ohlcBySymbol: [:],
            tradableSymbols: ["QQQ"], optionBySymbol: ["QQQ": instrument], simulationRange: 0...(days.count - 1))
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed QQQ short reversal")
        struct Account { let id: String; let states: [BacktestDailyState]; let trades: [AdvancedBacktestTrade] }
        var accounts: [Account] = [], claims: [String: [BacktestDistributionEntitlement]] = [:]
        var splitEvidence: [String: [BacktestSplitAdjustment]] = [:]
        var targets: [String: [String: Int]] = [:]
        for (scenario, tax) in [("price-only", 0.0), ("gross", 0.0), ("withhold30", 0.3)] {
            let distributions = try (scenario == "price-only" ? [] : cash.events).map { d in
                BacktestCashDistribution(id: "QQQ:" + d.ex_date, symbol: "QQQ", exDate: try date(d.ex_date),
                    paymentDate: try date(d.payment_date), currencyCode: "USD", amountPerUnit: d.amount_usd, withholdingRate: tax)
            }
            for rule in ["rsi3", "ibs02", "rsi3-ibs05", "buy-hold", "cash"] {
                for clock in (rule == "buy-hold" || rule == "cash" ? ["open"] : ["open", "close"]) {
                    let id = "QQQ:" + rule + ":" + clock + ":" + scenario
                    func desired(_ c: StrategyTargetContext) -> Double {
                        guard c.index > 0, rule != "cash" else { return 0 }
                        return rule == "buy-hold" ? 1 : signals[c.signalIndex].weights[rule]!
                    }
                    var submitted: Double?
                    guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                        provider: .init { c in desired(c) == 1 ? ["QQQ": 1] : [:] },
                        rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
                        contextualRebalanceDecision: { c in
                            let w = desired(c), changed = submitted == nil || submitted != w
                            if changed { submitted = w }
                            return .init(shouldRebalance: changed, refreshOverlay: false)
                        }, executionPricesBySymbol: clock == "open" ? ["QQQ": opens] : nil,
                        cashDistributions: distributions, distributionFXToBaseBySymbol: ["QQQ": conversion],
                        shareSplits: splits) else { throw BacktestConfigurationError.computationFailed }
                    let mismatches = run.dailyStates.enumerated().filter { i, state in
                        let expected = i == 0 || rule == "cash" ? 0 : rule == "buy-hold" ? 1 : signals[i - 1].weights[rule]!
                        return (state.targetWeights["QQQ"] ?? 0) != expected
                    }.count
                    guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("cash correction target mismatch") }
                    targets[id] = ["desired_accepted_mismatches": mismatches, "state_count": run.dailyStates.count]
                    claims[id] = run.distributionEntitlements; splitEvidence[id] = run.splitAdjustments
                    accounts.append(.init(id: id, states: run.dailyStates, trades: run.trades))
                }
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var savedIDs: [String] = []
        for file in sources.files {
            let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
            guard ResearchRunEvidence.sha256(data) == file.sha256 else { throw BacktestConfigurationError.invalidParameter("saved catalogue hash") }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }
                guard matches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }) else {
                    throw BacktestConfigurationError.invalidParameter("saved catalogue state order")
                }
                savedIDs.append(id); accounts.append(.init(id: id, states: matches[0].dailyStates, trades: []))
            }
        }
        guard savedIDs == BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs
            + ["nfci-dual-core-v11-qual-role"], accounts.count == 44 else {
            throw BacktestConfigurationError.invalidParameter("QQQ24 and catalogue20 budget")
        }
        let common = accounts.reduce(Set(accounts[0].states.map(\.date))) { $0.intersection(Set($1.states.map(\.date))) }.sorted()
        guard common.count > 252 else { throw BacktestConfigurationError.missingData("cash correction common calendar") }
        let text = BacktestSeriesAlignment.historicalSeriesDateString(from:)
        let windows = [("full", text(common.first!), text(common.last!)), ("since2020", "2020-01-01", text(common.last!)),
            ("since2022", "2022-01-01", text(common.last!)), ("post_paper", "2014-04-01", text(common.last!)),
            ("dotcom", "2000-01-01", "2002-12-31"), ("crisis2008", "2008-01-01", "2008-12-31"),
            ("crisis2020", "2020-01-01", "2020-12-31"), ("crisis2022", "2022-01-01", "2022-12-31")]
        let commonSet = Set(common)
        let rows = try accounts.map { a in try DailyScreenOutput.row(a.id,
            states: a.states.filter { commonSet.contains($0.date) }, trades: a.trades, windows: windows) }
        let native = try accounts.map { a in try DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
            windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))] + windows.filter { $0.0 != "full" }) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence: [String: Any] = ["completed_at": ISO8601DateFormatter().string(from: Date()),
            "evidence_class": "POST_HOC_UNCHANGED_QQQ_RULE_CASH_CORRECTION", "formal_validation": false,
            "objective_complete": false, "recommendation_eligible": false, "source_commit": sourceCommit,
            "new_economic_rules": 0, "parameter_search_budget": 0, "funded_account_count": 24, "saved_control_count": 20,
            "primary_metric": "App daily NAV Sharpe Rf=0; native full history plus mechanical common supplement",
            "common_history_is_primary_user_choice": false, "common_dates": common.map(text),
            "common_start": text(common.first!), "common_end": text(common.last!), "target_audits": targets,
            "prices_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": ResearchRunEvidence.sha256(history),
            "cash_sha256": ResearchRunEvidence.sha256(cashRaw), "accounts_sha256": ResearchRunEvidence.sha256(savedRaw),
            "signals_sha256": ResearchRunEvidence.sha256(try encoder.encode(signals)), "result_sha256": ResearchRunEvidence.sha256(result),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "fee_percent": 0.025, "slippage_percent": 0, "cash": "CashYieldCNY", "withholding_scenarios": [0, 0.3],
            "limitations": ["Final issuer cash facts and vendor histories are not complete announcement or quote vintage certification.",
                "Pre-2003 absence is consistent across issuer/vendor; no complete contemporaneous inception archive certificate.",
                "Uniform30% withholding is an accounting scenario, not a personal tax estimate; unknown components retained separately.",
                "Same original OHLC and signals; receivables at ex date, usable cash after pay-session trading; no automatic reinvestment.",
                "Saved App index/proxy controls retain original dividends/FX/execution limitations; no matched total-return frontier certification.",
                "All history previously exposed; accounting repair is not new alpha, holdout, or formal G0-G6 validation."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, bytes) in [("result.json", result), ("native-full.json", try encoder.encode(native)),
            ("signals.json", try encoder.encode(signals)), ("entitlements.json", try encoder.encode(claims)),
            ("splits.json", try encoder.encode(splitEvidence))] {
            try bytes.write(to: output.appendingPathComponent(name))
        }
        try JSONSerialization.data(withJSONObject: ["dates": days, "opens_cny": opens, "closes_cny": closes, "cny_per_usd": conversion], options: [.sortedKeys])
            .write(to: output.appendingPathComponent("quotes.json"))
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"))
        print("QQQ cash accounting correction: 24 unchanged-rule accounts and 20 saved controls, \(common.count) common dates.")
    }
}
