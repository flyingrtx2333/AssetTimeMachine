import Foundation
import AssetTimeMachineBacktestCore

/// One fixed public rule, with executable next-open fills on raw price observations.
/// This is exploratory research, not a product strategy or a formal acceptance run.
public enum IBSOpenScreen {
    public typealias Bar = SPYSessionInput.Bar

    /// Rolling windows include the signal session. Start flat at the evaluation boundary.
    public static func desiredWeights(bars: [Bar], start: Date) throws -> [Double] {
        guard bars.count >= 25, zip(bars, bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
              bars.allSatisfy({ b in
                  [b.open, b.high, b.low, b.close].allSatisfy { $0.isFinite && $0 > 0 }
                      && b.high >= max(b.open, b.close) && b.low <= min(b.open, b.close)
              }) else { throw BacktestConfigurationError.invalidParameter("IBS OHLC") }
        var held = false
        var weights = Array(repeating: 0.0, count: bars.count)
        for i in bars.indices where i >= 24 && bars[i].date >= start {
            let b = bars[i]
            if held {
                if b.close > bars[i - 1].high { held = false }
            } else if b.high > b.low {
                let meanRange = bars[(i - 24)...i].reduce(0) { $0 + $1.high - $1.low } / 25
                let rollingHigh = bars[(i - 9)...i].map(\.high).max()!
                let ibs = (b.close - b.low) / (b.high - b.low)
                if b.close < rollingHigh - 2.5 * meanRange && ibs < 0.3 { held = true }
            }
            weights[i] = held ? 1 : 0
        }
        return weights
    }

    public static func run(spyPath: String, historyPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: spyPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2008-01-02")!
        let end = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-08-20")!
        let input = try SPYSessionInput(raw: raw, history: history, start: start, end: end)
        let bars = input.bars, opens = input.opens, frame = input.frame, first = input.first
        let dataset = input.dataset
        let weights = try desiredWeights(bars: bars, start: start)
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "IBS fixed public base rule")
        var rows: [DailyScreenOutput.Row] = []
        let windows = [("full", "2008-01-02", "2026-08-20"),
            ("since2020", "2020-01-01", "2026-08-20"), ("since2022", "2022-01-01", "2026-08-20"),
            ("post_publication", "2024-05-21", "2026-08-20"),
            ("crisis2008", "2008-01-02", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"),
            ("crisis2022", "2022-01-01", "2022-12-31")]
        func append(_ id: String, states: [BacktestDailyState], trades: [AdvancedBacktestTrade]) throws {
            rows.append(try DailyScreenOutput.row(id, states: states, trades: trades, windows: windows))
        }
        for id in ["ibs-spy-next-open-rmb-v1", "ibs-spy-next-close-clock-control", "spy-buy-hold-open-control"] {
            var submitted: Double? = nil
            func desired(_ c: StrategyTargetContext) -> Double {
                guard c.index > first else { return 0 } // Baseline close before the first fill.
                return id == "spy-buy-hold-open-control" ? 1 : weights[c.signalIndex]
            }
            guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                provider: .init { c in desired(c) == 1 ? ["SPY": 1] : [:] },
                rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
                contextualRebalanceDecision: { c in
                    let w = desired(c), changed = submitted == nil || submitted != w
                    if changed { submitted = w }
                    return .init(shouldRebalance: changed, refreshOverlay: false)
                }, executionPricesBySymbol: id == "ibs-spy-next-close-clock-control" ? nil : ["SPY": opens]) else {
                throw BacktestConfigurationError.missingData(id)
            }
            try append(id, states: run.dailyStates, trades: run.trades)
        }
        let baseline = try StrategyRegistry.definition(id: "gold-nasdaq-dual-trend-barbell")
        let baselineRun = try baseline.run(input: .init(seriesBySymbol: dataset.seriesBySymbol,
            datasetHash: dataset.datasetHash, sourceCommit: sourceCommit),
            configuration: .init(strategy: baseline.reference, purpose: .research,
                settings: .init(feeRate: 0.025, slippageRate: 0, maxPositionRatio: 100,
                    cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0),
                evaluationRange: .init(startDate: start, endDate: end)))
        try append(baseline.reference.id, states: baselineRun.dailyStates, trades: baselineRun.report.trades)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(rows)
        let parameters: [String: Any] = ["candidate_count": 1, "control_count": 3,
            "fee_percent": 0.025, "slippage_percent": 0, "initial_cny": 100000,
            "range_sessions": 25, "high_sessions": 10, "range_multiplier": 2.5, "ibs_below": 0.3,
            "start": "2008-01-02", "end": "2026-08-20", "fx_max_age_days": 14,
            "fx_policy": "strict-prior-calendar-date-for-open-and-close", "cash": "CashYieldCNY",
            "dividends": "not_included_price_only", "signal_adjustment": "Yahoo raw OHLC"]
        let p = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
        let evidence: [String: Any] = ["evidence_class": "D0_EXPLORATORY_PUBLIC_RULE_ADAPTATION",
            "formal_validation": false, "recommendation_eligible": false,
            "source_commit": sourceCommit, "execution_version": "settlement-v4-with-explicit-session-quotes-v1",
            "spy_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": dataset.datasetHash,
            "parameters": parameters, "parameters_sha256": ResearchRunEvidence.sha256(p),
            "result_sha256": ResearchRunEvidence.sha256(data),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "limitations": ["Opening auction availability and all-in costs assumed, not broker-verified.",
                "Author comments specify next-open adjusted-price execution and invested-day Sharpe. This screen uses raw quotes and full-account metrics; see the source clarification addendum.",
                "SPY is a real ETF, but cash dividends are omitted; no adjustment of raw trade prices by future dividends.",
                "FX uses prior calendar-date quotes, without a separate USD settlement wallet or conversion charges.",
                "Archive ends 2026-08-20, not current October data; single provider, not independently price-certified.",
                "Publication-after slice is retrospective; no pristine holdout or prospective OOS.",
                "Gold/Nasdaq control uses native index data and normal next-close execution, not SPY ETF prices."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("IBS fixed rule: 1 candidate, 3 controls; immutable outputs saved.")
    }
}
