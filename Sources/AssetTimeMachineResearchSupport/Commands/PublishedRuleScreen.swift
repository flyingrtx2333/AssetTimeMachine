import Foundation
import AssetTimeMachineBacktestCore

/// Fixed exploratory rule replications. This command does not register product strategies.
public enum PublishedRuleScreen {
    public struct Signals {
        public let rsi2DesiredByDate: [String: Double]
        public let completedMonthCloses: [(month: String, close: Double)]
    }

    /// Indicators use original USD closes, never FX-adjusted returns or later prices.
    public static func signals(dates: [String], prices: [Double]) throws -> Signals {
        guard dates.count == prices.count, dates.count >= 252,
              zip(dates, dates.dropFirst()).allSatisfy({ $0 < $1 }),
              prices.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("published-rule observations")
        }
        var desired: [String: Double] = [:]
        var monthCloses: [(month: String, close: Double)] = []
        var month = String(dates[0].prefix(7))
        var gain = 0.0
        var loss = 0.0
        var held = false
        var sum200 = 0.0
        var sum5 = 0.0
        for i in prices.indices {
            let currentMonth = String(dates[i].prefix(7))
            if currentMonth != month {
                monthCloses.append((month, prices[i - 1]))
                month = currentMonth
            }
            sum200 += prices[i]
            sum5 += prices[i]
            if i >= 200 { sum200 -= prices[i - 200] }
            if i >= 5 { sum5 -= prices[i - 5] }
            if i > 0 {
                let delta = prices[i] - prices[i - 1]
                if i <= 2 {
                    gain += max(delta, 0) / 2
                    loss += max(-delta, 0) / 2
                } else {
                    gain = (gain + max(delta, 0)) / 2
                    loss = (loss + max(-delta, 0)) / 2
                }
            }
            if i >= 199 {
                let rsi = gain + loss == 0 ? 50 : 100 * gain / (gain + loss)
                if held {
                    if prices[i] > sum5 / 5 { held = false }
                } else if prices[i] > sum200 / 200 && rsi < 5 {
                    held = true
                }
            }
            desired[dates[i]] = held ? 1 : 0
        }
        // The last observed month cannot be certified complete from future-free inputs.
        return .init(rsi2DesiredByDate: desired, completedMonthCloses: monthCloses)
    }

    public static func faberWeight(executionMonth: String, months: [(month: String, close: Double)]) -> Double {
        let completed = months.filter { $0.month < executionMonth }.suffix(10)
        guard completed.count == 10, let last = completed.last else { return 0 }
        return last.close > completed.reduce(0) { $0 + $1.close } / 10 ? 1 : 0
    }

    public static func run(historyPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        guard root?["history_quality_policy"] as? String == "provider-trade-date-v1" else {
            throw BacktestConfigurationError.missingData("provider-trade-date-v1")
        }
        let dataset = try PublicBacktestCore.loadDataset(from: raw,
            datasetHash: ResearchRunEvidence.sha256(raw), dataStale: false)
        guard let sp = dataset.seriesBySymbol["sp500"],
              let fx = dataset.seriesBySymbol["usd_per_cny"],
              let gold = dataset.seriesBySymbol["gold_cny"] else {
            throw BacktestConfigurationError.missingData("sp500, gold_cny, usd_per_cny")
        }
        let indicators = try signals(dates: sp.dates, prices: sp.prices)
        let day = BacktestSeriesAlignment.historicalSeriesCalendar
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2008-01-02")!
        let end = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-10-02")!
        let settings = AdvancedBacktestRiskSettings(feeRate: 0.025, slippageRate: 0,
            maxPositionRatio: 100, cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0)
        let spOption = BacktestInstrument(symbol: "sp500", title: "标普500价格指数", requiresHistoricalFX: true,
            historicalFXSymbol: "usd_per_cny", currency: "USD")
        let goldOption = BacktestInstrument(symbol: "gold_cny", title: "黄金", requiresHistoricalFX: false,
            historicalFXSymbol: nil)
        let inputs = [(assetSeries: Optional(sp), assetOption: spOption, fxSeries: Optional(fx)),
                      (assetSeries: Optional(gold), assetOption: goldOption, fxSeries: Optional<PublicHistorySeries>.none)]
        let dates = sp.dates.compactMap { BacktestSeriesAlignment.historicalSeriesDate(from: $0) }
        guard dates.count == sp.dates.count else { throw BacktestConfigurationError.invalidParameter("dates") }
        func lastKnown(_ date: Date) -> Int? {
            var lo = 0, hi = dates.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if dates[mid] <= date { lo = mid + 1 } else { hi = mid }
            }
            return lo > 0 ? lo - 1 : nil
        }
        struct Metric: Encodable {
            let annualizedReturn: Double?
            let maxDrawdown: Double
            let sharpeRF0: Double?
            let start: Date
            let end: Date
            let pointCount: Int
        }
        struct Trade: Encodable {
            let date: Date
            let symbol: String
            let action: String
            let price: Double
            let cashAmount: Double
            let units: Double
        }
        struct Row: Encodable {
            let id: String
            let trades: [Trade]
            let dailyStates: [BacktestDailyState]
            let slices: [String: Metric]
            let tradeCount: Int
            let accountingMaxError: Double
            let minimumCash: Double
            let maximumHeldGross: Double
        }
        var rows: [Row] = []
        func append(_ id: String, report: AdvancedBacktestReport, states: [BacktestDailyState]) throws {
            guard !states.isEmpty else { throw BacktestConfigurationError.missingData("daily states") }
            var maximumError = 0.0, minimumCash = Double.infinity, maximumGross = 0.0
            for state in states {
                let held = state.holdingsBySymbol.values.reduce(0, +)
                let error = abs(held + state.cash - state.portfolioValue)
                guard state.portfolioValue > 0, state.portfolioValue.isFinite,
                      error <= max(1e-8, abs(state.portfolioValue) * 1e-12),
                      state.cash >= -1e-8, held / state.portfolioValue <= 1 + 1e-12,
                      state.targetWeights.values.allSatisfy({ $0 >= 0 && $0.isFinite }),
                      state.targetWeights.values.reduce(0, +) <= 1 + 1e-12 else {
                    throw BacktestConfigurationError.invalidParameter("accounting or leverage: \(id)")
                }
                maximumError = max(maximumError, error)
                minimumCash = min(minimumCash, state.cash)
                maximumGross = max(maximumGross, held / state.portfolioValue)
            }
            let points = states.enumerated().map { BacktestSeriesPoint(date: $0.element.date,
                portfolioValue: $0.element.portfolioValue, sequence: $0.offset) }
            var slices: [String: Metric] = [:]
            let windows = [("full", "2008-01-02", "2026-10-02"), ("post_publication_2010", "2010-01-01", "2026-10-02"),
                ("since2020", "2020-01-01", "2026-10-02"), ("since2022", "2022-01-01", "2026-10-02"),
                ("crisis2008", "2008-01-02", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"),
                ("crisis2022", "2022-01-01", "2022-12-31")]
            for (name, a, b) in windows {
                let lower = BacktestSeriesAlignment.historicalSeriesDate(from: a)!
                let upper = BacktestSeriesAlignment.historicalSeriesDate(from: b)!
                let slice = points.filter { $0.date >= lower && $0.date <= upper }
                if let metric = BacktestMetricsCalculator.performanceMetrics(from: slice) {
                    slices[name] = .init(annualizedReturn: metric.annualizedReturn, maxDrawdown: metric.maxDrawdown,
                        sharpeRF0: metric.sharpeRatio, start: slice.first!.date, end: slice.last!.date, pointCount: slice.count)
                }
            }
            let trades = report.trades.map { Trade(date: $0.date, symbol: $0.assetSymbol,
                action: $0.action.rawValue, price: $0.price, cashAmount: $0.cashAmount, units: $0.units) }
            rows.append(.init(id: id, trades: trades, dailyStates: states, slices: slices,
                tradeCount: report.trades.count, accountingMaxError: maximumError,
                minimumCash: minimumCash, maximumHeldGross: maximumGross))
        }
        for id in ["faber-sp500-rmb-adaptation", "connors-rsi2-sp500-rmb-adaptation", "sp500-buy-hold-control"] {
            var submitted: Double? = nil
            func desired(_ context: StrategyTargetContext) -> Double {
                guard let known = lastKnown(context.signalDate) else { return 0 }
                if id == "sp500-buy-hold-control" { return 1 }
                if id == "connors-rsi2-sp500-rmb-adaptation" {
                    return indicators.rsi2DesiredByDate[sp.dates[known]] ?? 0
                }
                let components = day.dateComponents([.year, .month], from: context.date)
                let month = String(format: "%04d-%02d", components.year!, components.month!)
                // Only months completed before this execution month, and prices known by T-1.
                return faberWeight(executionMonth: month,
                    months: indicators.completedMonthCloses.filter { $0.month <= String(sp.dates[known].prefix(7)) })
            }
            let config = ResearchTargetStrategyConfig(symbol: id, title: id, warmupSessions: 252,
                rebalanceSessions: 1, signalOnlySymbols: ["gold_cny"])
            guard let run = TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
                assetInputs: inputs, initialCash: 100000, settings: settings, config: config,
                dateBounds: start...end, contextualRebalanceDecision: { context, _ in
                    let weight = desired(context)
                    let change = submitted == nil || weight != submitted
                    if change { submitted = weight }
                    return .init(shouldRebalance: change, refreshOverlay: false)
                }, targetWeights: { context, _ in desired(context) == 1 ? ["sp500": 1] : [:] }) else {
                throw BacktestConfigurationError.missingData(id)
            }
            try append(id, report: run.report, states: run.dailyStates)
        }
        let baseline = try StrategyRegistry.definition(id: "gold-nasdaq-dual-trend-barbell")
        let baselineRun = try baseline.run(input: .init(seriesBySymbol: dataset.seriesBySymbol,
            datasetHash: dataset.datasetHash, sourceCommit: sourceCommit),
            configuration: .init(strategy: baseline.reference, purpose: .research,
                settings: settings, evaluationRange: .init(startDate: start, endDate: end)))
        try append(baseline.reference.id, report: baselineRun.report, states: baselineRun.dailyStates)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(rows)
        let parameters: [String: Any] = ["candidate_count": 2, "control_count": 2,
            "fee_percent": 0.025, "slippage_percent": 0, "initial_cny": 100000,
            "rsi_period": 2, "rsi_entry_below": 5, "trend_sma": 200, "exit_sma": 5,
            "faber_months": 10, "start": "2008-01-02", "end": "2026-10-02"]
        let parameterData = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
        let evidence: [String: Any] = ["evidence_class": "D0_EXPLORATORY_PUBLIC_RULE_ADAPTATION",
            "formal_validation": false, "recommendation_eligible": false, "source_commit": sourceCommit,
            "execution_version": "settlement-v4", "history_quality_policy": "provider-trade-date-v1",
            "dataset_sha256": dataset.datasetHash, "parameters_sha256": ResearchRunEvidence.sha256(parameterData),
            "result_sha256": ResearchRunEvidence.sha256(data),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "completed_at": ISO8601DateFormatter().string(from: Date()), "parameters": parameters,
            "limitations": ["Price-index proxy for SPY; no dividend reinvestment or ETF tracking costs.",
                "USD signals; CNY valuation with historical FX; CashYieldCNY instead of USD T-bills.",
                "T-1 signal, next observed close execution; differs from published same-close execution.",
                "Previously exposed history; not pristine holdout or prospective OOS.",
                "RSI target state tracks desired exposure; pending settlement can delay actual holdings."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("Published rules: 2 candidates, 2 controls; immutable outputs saved.")
    }
}
