import Foundation
import AssetTimeMachineBacktestCore

/// Bounded price-proxy discovery. No product registration or formal promotion.
public enum SingleIndicatorScreen {
    public enum Rule: String, CaseIterable { case lowerDowncross = "lower-downcross", lowerReentry = "lower-reentry", upperBreakout = "upper-breakout" }
    public struct Signal: Codable, Equatable {
        public let date: Date
        public let close: Double
        public let middle: Double?
        public let lower: Double?
        public let upper: Double?
        public let weight: Double
    }

    /// Exactly one natural 20/2 specification. Use observed closes, not filled holidays.
    public static func signals(dates: [Date], prices: [Double], rule: Rule, start: Date) throws -> [Signal] {
        guard dates.count == prices.count, dates.count >= 21,
              zip(dates, dates.dropFirst()).allSatisfy({ $0 < $1 }),
              prices.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("single-indicator observations")
        }
        var held = false
        var result: [Signal] = []
        for i in prices.indices {
            var band: (middle: Double, lower: Double, upper: Double)?
            if i >= 19 {
                let window = prices[(i - 19)...i]
                let mean = window.reduce(0, +) / 20
                let sigma = sqrt(window.reduce(0) { $0 + pow($1 - mean, 2) } / 20)
                band = (mean, mean - 2 * sigma, mean + 2 * sigma)
            }
            if i >= 20, dates[i] >= start, let current = band,
               let previousMiddle = result[i - 1].middle,
               let previousLower = result[i - 1].lower,
               let previousUpper = result[i - 1].upper {
                let exit = rule == .upperBreakout
                    ? prices[i - 1] >= previousMiddle && prices[i] < current.middle
                    : prices[i - 1] <= previousMiddle && prices[i] > current.middle
                if held {
                    if exit { held = false }
                } else {
                    switch rule {
                    case .lowerDowncross:
                        held = prices[i - 1] > previousLower && prices[i] <= current.lower
                    case .lowerReentry:
                        held = prices[i - 1] <= previousLower && prices[i] > current.lower && prices[i] <= current.middle
                    case .upperBreakout:
                        held = prices[i - 1] < previousUpper && prices[i] >= current.upper
                    }
                }
            }
            result.append(.init(date: dates[i], close: prices[i], middle: band?.middle,
                                lower: band?.lower, upper: band?.upper, weight: held ? 1 : 0))
        }
        return result
    }

    public static func run(historyPath: String, macroPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let macroData = try Data(contentsOf: URL(fileURLWithPath: macroPath))
        let dataset = try PublicBacktestCore.loadDataset(from: history, datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        let macro = try ResearchRunEvidence.macroSnapshot(from: macroData)
        let end = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-10-06")!
        let settings = AdvancedBacktestRiskSettings(feeRate: 0.025, slippageRate: 0,
            maxPositionRatio: 100, cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0)
        let reference = try StrategyRegistry.definition(id: "gold-nasdaq-dual-trend-barbell")
        let inputs = BacktestCoreStrategyDefaults.assetOptions(for: reference.template).map {
            MarketInputPreparation.advancedAssetInput(for: $0) { dataset.seriesBySymbol[$0] }
        }
        let lower = MarketInputPreparation.availableDateBounds(for: inputs.flatMap { [$0.assetSeries, $0.fxSeries].compactMap { $0 } })!.lowerBound
        let config = ResearchTargetStrategyConfig(symbol: "single-indicator", title: "single-indicator", warmupSessions: 252, rebalanceSessions: 1)
        guard let fullFrame = TargetProviderBacktest.researchMarketDataFrame(assetInputs: inputs, config: config, dateBounds: lower...end) else {
            throw BacktestConfigurationError.missingData("single-indicator common frame")
        }
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed single-indicator research")
        struct Account { let id: String; let states: [BacktestDailyState]; let trades: [AdvancedBacktestTrade] }
        var accounts: [Account] = []
        var signalEvidence: [String: [Signal]] = [:]
        var targetAudits: [String: [String: Int]] = [:]
        for symbol in ["gold_cny", "nasdaq"] {
            guard let prices = fullFrame.pricesBySymbol[symbol], let original = dataset.seriesBySymbol[symbol],
                  let option = fullFrame.optionBySymbol[symbol] else { throw BacktestConfigurationError.missingData(symbol) }
            let originalDates = Set(original.dates.compactMap { BacktestSeriesAlignment.historicalSeriesDate(from: $0) })
            let ownIndices = fullFrame.dates.indices.filter { originalDates.contains(fullFrame.dates[$0]) }
            let ownDates = ownIndices.map { fullFrame.dates[$0] }
            let ownPrices = ownIndices.map { prices[$0] }
            let frame = MarketDataFrame(dates: fullFrame.dates, pricesBySymbol: [symbol: prices],
                observedBySymbol: [symbol: fullFrame.observedBySymbol[symbol]!], ohlcBySymbol: [:],
                tradableSymbols: [symbol], optionBySymbol: [symbol: option], simulationRange: fullFrame.simulationRange)
            for ruleName in Rule.allCases.map(\.rawValue) + ["buy-hold"] {
                let id = symbol + ":" + ruleName
                let signals = try Rule(rawValue: ruleName).map {
                    try self.signals(dates: ownDates, prices: ownPrices, rule: $0, start: frame.dates[frame.simulationRange.lowerBound])
                } ?? ownDates.indices.map { Signal(date: ownDates[$0], close: ownPrices[$0], middle: nil, lower: nil, upper: nil, weight: 1) }
                signalEvidence[id] = signals
                func desired(_ c: StrategyTargetContext) -> Double {
                    guard c.index > frame.simulationRange.lowerBound else { return 0 }
                    var lo = 0, hi = signals.count
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if signals[mid].date <= c.signalDate { lo = mid + 1 } else { hi = mid }
                    }
                    return lo > 0 ? signals[lo - 1].weight : 0
                }
                var submitted: Double?
                guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                    provider: .init { c in desired(c) == 1 ? [symbol: 1] : [:] },
                    rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
                    contextualRebalanceDecision: { c in
                        let w = desired(c), changed = submitted == nil || submitted != w
                        if changed { submitted = w }
                        return .init(shouldRebalance: changed, refreshOverlay: false)
                    }) else { throw BacktestConfigurationError.computationFailed }
                // Independently resolve every previous-date target, including holidays.
                var mismatches = 0
                for (offset, state) in run.dailyStates.enumerated() {
                    let i = frame.simulationRange.lowerBound + offset
                    let known = signals.last(where: { $0.date <= frame.dates[i - 1] })?.weight ?? 0
                    let expected = i == frame.simulationRange.lowerBound ? 0 : known
                    if (state.targetWeights[symbol] ?? 0) != expected { mismatches += 1 }
                }
                guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("desired/accepted target mismatch: \(id)") }
                targetAudits[id] = ["desired_accepted_mismatches": mismatches, "state_count": run.dailyStates.count]
                accounts.append(.init(id: id, states: run.dailyStates, trades: run.trades))
            }
        }
        guard let cash = BacktestDailySimulator.run(frame: fullFrame, execution: execution,
            provider: .init { _ in [:] }, rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) }) else {
            throw BacktestConfigurationError.computationFailed
        }
        accounts.append(.init(id: "cny-cash-diagnostic", states: cash.dailyStates, trades: cash.trades))
        var frozenProductParameters: [String: String] = [:]
        for id in BacktestProductStrategyCatalog.curatedTemplateIDs {
            let definition = try StrategyRegistry.definition(id: id)
            let productInputs = BacktestCoreStrategyDefaults.assetOptions(for: definition.template).map {
                MarketInputPreparation.advancedAssetInput(for: $0) { dataset.seriesBySymbol[$0] }
            }
            let productLower = MarketInputPreparation.availableDateBounds(for: productInputs.flatMap { [$0.assetSeries, $0.fxSeries].compactMap { $0 } })!.lowerBound
            guard let run = BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(assetInputs: productInputs,
                initialCash: 100000, settings: settings, mode: definition.template.mode, nfciAsOf: macro, dateBounds: productLower...end) else {
                throw BacktestConfigurationError.missingData(id)
            }
            frozenProductParameters[id] = String(decoding: try definition.frozenParametersJSON, as: UTF8.self)
            accounts.append(.init(id: id, states: run.dailyStates, trades: run.report.trades))
        }
        guard accounts.count == 15 else { throw BacktestConfigurationError.invalidParameter("run budget") }
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
            ("crisis2008", "2008-01-01", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"), ("crisis2022", "2022-01-01", "2022-12-31")]
        let commonSet = Set(commonDates)
        let rows = try accounts.map { a in
            try DailyScreenOutput.row(a.id, states: a.states.filter { commonSet.contains($0.date) }, trades: a.trades, windows: windows)
        }
        let native = try accounts.map { a in
            try DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", formatter.string(from: a.states.first!.date), formatter.string(from: a.states.last!.date))])
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence: [String: Any] = ["completed_at": ISO8601DateFormatter().string(from: Date()),
            "evidence_class": "D0_FIXED_SINGLE_INDICATOR_SCREEN", "formal_validation": false, "recommendation_eligible": false,
            "source_commit": sourceCommit, "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "history_sha256": ResearchRunEvidence.sha256(history), "macro_sha256": ResearchRunEvidence.sha256(macroData),
            "result_sha256": ResearchRunEvidence.sha256(result),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "candidate_count": 6, "control_count": 9, "parameter_search_budget": 0,
            "fee_percent": 0.025, "slippage_percent": 0, "common_dates": commonDates.map { formatter.string(from: $0) },
            "date_basis": "Asia/Shanghai", "primary_metric": "full common daily NAV Sharpe Rf=0",
            "common_start": formatter.string(from: first), "common_end": lastText, "target_audits": targetAudits,
            "limitations": ["Exposed price-index proxies; not independently funded ETF/gold total returns.",
                "No fresh holdout or prospective OOS; all six candidates retained.",
                "Continuous accounts start at their natural warmup dates; common window fixed mechanically.",
                "All current curated controls included; proxy-based experimental frontier is not certified.",
                "Full raw states retained; common-calendar metrics exclude noncommon calendar rows."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"))
        try encoder.encode(native).write(to: output.appendingPathComponent("native-full.json"))
        try encoder.encode(signalEvidence).write(to: output.appendingPathComponent("signals.json"))
        try JSONSerialization.data(withJSONObject: frozenProductParameters, options: [.sortedKeys]).write(to: output.appendingPathComponent("product-parameters.json"))
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("evidence.json"))
        print("Single indicator: 6 candidates, 9 controls, zero parameter search; \(commonDates.count) common dates saved.")
    }
}
