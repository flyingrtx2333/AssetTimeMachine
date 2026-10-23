import Foundation
import AssetTimeMachineBacktestCore

/// Three fixed published short-reversal rules. No parameter search or promotion.
public enum QQQReversalScreen {
    public typealias Bar = SPYSessionInput.Bar
    public struct Signal: Codable, Equatable {
        public let date: Date
        public let splitContinuousClose: Double
        public let rsi3: Double?
        public let ibs: Double
        public let weights: [String: Double]
    }
    private struct Split: Decodable {
        let effective_date: String
        let new_units_per_old_unit: Double
    }
    private struct Input: Decodable {
        let schema: String
        let symbol: String
        let bars: [SectorMonthstartScreen.Bar]
        let splits: [Split]
    }

    /// Cutler's simple three-change RSI, not Wilder smoothing. A latent RSI
    /// position persists independently of IBS-filtered exposure. Split factors
    /// affect the signal index only at their effective session, never earlier.
    public static func signals(bars: [Bar], splits: [Date: Double]) throws -> [Signal] {
        guard bars.count >= 4, zip(bars, bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
              bars.allSatisfy({ b in
                  [b.open, b.high, b.low, b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                  && b.high >= max(b.open, b.close) && b.low <= min(b.open, b.close)
              }), splits.values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("QQQ RSI/IBS observed bars")
        }
        var index = [100.0], held = false, result: [Signal] = []
        for i in bars.indices {
            let b = bars[i]
            if i > 0 { index.append(index[i - 1] * b.close * (splits[b.date] ?? 1) / bars[i - 1].close) }
            let ibs = b.high > b.low ? (b.close - b.low) / (b.high - b.low) : 0.5
            var rsi: Double?
            if i >= 3 {
                let changes = ((i - 2)...i).map { index[$0] - index[$0 - 1] }
                let gains = changes.reduce(0) { $0 + max($1, 0) }
                let losses = changes.reduce(0) { $0 + max(-$1, 0) }
                rsi = losses == 0 ? 100 : 100 * gains / (gains + losses)
                if held { if rsi! > 40 { held = false } }
                else if rsi! < 10 { held = true }
            }
            result.append(.init(date: b.date, splitContinuousClose: index[i], rsi3: rsi, ibs: ibs,
                weights: ["rsi3": held ? 1 : 0, "ibs02": ibs <= 0.2 ? 1 : 0,
                          "rsi3-ibs05": held && ibs <= 0.5 ? 1 : 0]))
        }
        return result
    }

    public static func run(pricesPath: String, historyPath: String, controlHistoryPath: String, macroPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let controlHistory = try Data(contentsOf: URL(fileURLWithPath: controlHistoryPath))
        let macroData = try Data(contentsOf: URL(fileURLWithPath: macroPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        guard input.schema == "qqq-short-reversal-v1", input.symbol == "QQQ",
              input.bars.first?.date == "1999-03-10", input.bars.last?.date == "2026-10-02",
              input.splits.count == 1, input.splits[0].effective_date == "2000-03-20",
              input.splits[0].new_units_per_old_unit == 2 else {
            throw BacktestConfigurationError.invalidParameter("QQQ frozen inception/split coverage")
        }
        let days = input.bars.map(\.date)
        let dates = try days.map { day -> Date in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: day) else {
                throw BacktestConfigurationError.invalidParameter("QQQ session date")
            }
            return date
        }
        let bars = input.bars.indices.map { i in
            Bar(date: dates[i], open: input.bars[i].open, high: input.bars[i].high,
                low: input.bars[i].low, close: input.bars[i].close)
        }
        let splits = try input.splits.map { s -> BacktestShareSplit in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: s.effective_date) else {
                throw BacktestConfigurationError.invalidParameter("QQQ split date")
            }
            return .init(id: "QQQ:" + s.effective_date, symbol: "QQQ", effectiveDate: date,
                         newUnitsPerOldUnit: s.new_units_per_old_unit)
        }
        let signalEvidence = try signals(bars: bars, splits: Dictionary(uniqueKeysWithValues:
            splits.map { ($0.effectiveDate, $0.newUnitsPerOldUnit) }))
        let dataset = try PublicBacktestCore.loadDataset(from: history, datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        let controlDataset = try PublicBacktestCore.loadDataset(from: controlHistory,
            datasetHash: ResearchRunEvidence.sha256(controlHistory), dataStale: false)
        let macro = try ResearchRunEvidence.macroSnapshot(from: macroData)
        guard let fx = dataset.seriesBySymbol["usd_per_cny"] else { throw BacktestConfigurationError.missingData("QQQ prior FX") }
        let conversion = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates, prices: fx.prices, asOf: $0)) }
        let closes = zip(bars, conversion).map { $0.close * $1 }
        let opens = zip(bars, conversion).map { $0.open * $1 }
        let option = BacktestInstrument(symbol: "QQQ", title: "QQQ funded CNY research", requiresHistoricalFX: false, historicalFXSymbol: nil)
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: ["QQQ": closes],
            observedBySymbol: ["QQQ": Array(repeating: true, count: dates.count)], ohlcBySymbol: [:],
            tradableSymbols: ["QQQ"], optionBySymbol: ["QQQ": option], simulationRange: 0...(dates.count - 1))
        let end = dates.last!
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed QQQ short reversal")
        let settings = AdvancedBacktestRiskSettings(feeRate: 0.025, slippageRate: 0,
            maxPositionRatio: 100, cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0)
        struct Account { let id: String; let states: [BacktestDailyState]; let trades: [AdvancedBacktestTrade] }
        var accounts: [Account] = [], splitEvidence: [String: [BacktestSplitAdjustment]] = [:]
        var targetAudits: [String: [String: Int]] = [:]
        for rule in ["rsi3", "ibs02", "rsi3-ibs05", "buy-hold", "cash"] {
            for clock in (rule == "buy-hold" || rule == "cash" ? ["open"] : ["open", "close"]) {
                let id = "QQQ:" + rule + ":" + clock
                func desired(_ c: StrategyTargetContext) -> Double {
                    guard c.index > 0 else { return 0 }
                    if rule == "cash" { return 0 }
                    if rule == "buy-hold" { return 1 }
                    return signalEvidence[c.signalIndex].weights[rule]!
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
                    shareSplits: splits) else { throw BacktestConfigurationError.computationFailed }
                var mismatches = 0
                for (i, state) in run.dailyStates.enumerated() {
                    let expected = i == 0 || rule == "cash" ? 0 : rule == "buy-hold" ? 1 : signalEvidence[i - 1].weights[rule]!
                    if (state.targetWeights["QQQ"] ?? 0) != expected { mismatches += 1 }
                }
                guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("QQQ desired/accepted target mismatch") }
                targetAudits[id] = ["desired_accepted_mismatches": mismatches, "state_count": run.dailyStates.count]
                splitEvidence[id] = run.splitAdjustments
                accounts.append(.init(id: id, states: run.dailyStates, trades: run.trades))
            }
        }
        var frozenProductParameters: [String: String] = [:]
        for id in BacktestProductStrategyCatalog.curatedTemplateIDs {
            let definition = try StrategyRegistry.definition(id: id)
            let productInputs = BacktestCoreStrategyDefaults.assetOptions(for: definition.template).map {
                MarketInputPreparation.advancedAssetInput(for: $0) { controlDataset.seriesBySymbol[$0] }
            }
            let productLower = MarketInputPreparation.availableDateBounds(for: productInputs.flatMap { [$0.assetSeries, $0.fxSeries].compactMap { $0 } })!.lowerBound
            guard let run = BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(assetInputs: productInputs,
                initialCash: 100000, settings: settings, mode: definition.template.mode, nfciAsOf: macro, dateBounds: productLower...end) else {
                throw BacktestConfigurationError.missingData(id)
            }
            frozenProductParameters[id] = String(decoding: try definition.frozenParametersJSON, as: UTF8.self)
            accounts.append(.init(id: id, states: run.dailyStates, trades: run.report.trades))
        }
        guard accounts.count == 14 else { throw BacktestConfigurationError.invalidParameter("run budget") }
        let commonDates = accounts.reduce(Set(accounts[0].states.map(\.date))) { $0.intersection(Set($1.states.map(\.date))) }.sorted()
        guard let first = commonDates.first, let last = commonDates.last, commonDates.count > 252 else {
            throw BacktestConfigurationError.missingData("full common history")
        }
        let formatter = DateFormatter(); formatter.calendar = BacktestSeriesAlignment.historicalSeriesCalendar
        formatter.timeZone = formatter.calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let lastText = formatter.string(from: last)
        let tenYears = formatter.calendar.date(byAdding: .year, value: -10, to: last)!
        let windows = [("full", formatter.string(from: first), lastText), ("trailing10Y", formatter.string(from: tenYears), lastText),
            ("since2020", "2020-01-01", lastText), ("since2022", "2022-01-01", lastText),
            ("post_paper", "2014-04-01", lastText), ("dotcom", "2000-01-01", "2002-12-31"),
            ("crisis2008", "2008-01-01", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"), ("crisis2022", "2022-01-01", "2022-12-31")]
        let commonSet = Set(commonDates)
        let rows = try accounts.map { a in
            try DailyScreenOutput.row(a.id, states: a.states.filter { commonSet.contains($0.date) }, trades: a.trades, windows: windows)
        }
        let native = try accounts.map { a in
            try DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", formatter.string(from: a.states.first!.date), formatter.string(from: a.states.last!.date))] + windows.filter { $0.0 != "full" })
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence: [String: Any] = ["completed_at": ISO8601DateFormatter().string(from: Date()),
            "evidence_class": "D0_FIXED_QQQ_SHORT_REVERSAL_SCREEN", "formal_validation": false, "recommendation_eligible": false,
            "source_commit": sourceCommit, "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "history_sha256": ResearchRunEvidence.sha256(history), "macro_sha256": ResearchRunEvidence.sha256(macroData),
            "control_history_sha256": ResearchRunEvidence.sha256(controlHistory),
            "result_sha256": ResearchRunEvidence.sha256(result),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "candidate_count": 3, "single_indicator_candidate_count": 2, "control_count": 11, "parameter_search_budget": 0,
            "fee_percent": 0.025, "slippage_percent": 0, "common_dates": commonDates.map { formatter.string(from: $0) },
            "date_basis": "America/New_York sessions stored at Asia/Shanghai midnight", "prices_sha256": ResearchRunEvidence.sha256(raw), "primary_metric": "full common daily NAV Sharpe Rf=0",
            "common_start": formatter.string(from: first), "common_end": lastText, "target_audits": targetAudits,
            "limitations": ["QQQ historical split denomination reconstructed; funded price-only returns omit dividends/tax/FX conversion fees.",
                "No fresh holdout or prospective OOS; all three fixed rules and two execution clocks retained.",
                "QQQ account begins at inception close, initially flat; native product accounts use their natural warmup dates; common window is mechanical.",
                "All current curated controls included; proxy-based experimental frontier is not certified.",
                "Full raw states retained; common-calendar metrics exclude noncommon calendar rows."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"))
        try encoder.encode(native).write(to: output.appendingPathComponent("native-full.json"))
        try encoder.encode(splitEvidence).write(to: output.appendingPathComponent("splits.json"))
        try JSONSerialization.data(withJSONObject: ["dates": days, "opens_cny": opens, "closes_cny": closes, "cny_per_usd": conversion], options: [.sortedKeys]).write(to: output.appendingPathComponent("quotes.json"))
        try encoder.encode(signalEvidence).write(to: output.appendingPathComponent("signals.json"))
        try JSONSerialization.data(withJSONObject: frozenProductParameters, options: [.sortedKeys]).write(to: output.appendingPathComponent("product-parameters.json"))
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("evidence.json"))
        print("QQQ reversal: 3 rules, 2 clocks, 8 QQQ accounts plus 6 controls, zero parameter search; \(commonDates.count) common dates saved.")
    }
}
