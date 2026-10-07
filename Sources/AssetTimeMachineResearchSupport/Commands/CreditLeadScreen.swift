import Foundation
import AssetTimeMachineBacktestCore

/// Pinned 45ck/llm-quant LeadLag signal; stop execution is moved to next open.
/// Source MIT attribution and exact original code are retained with the study.
public enum CreditLeadScreen {
    public struct Decision: Codable, Equatable {
        public let signalIndex: Int
        public let leaderReturn: Double?
        public let review: Bool
        public let weight: Double
        public let stopPrice: Double?
        public let event: String
    }
    struct Bar: Codable { let date: String; let open: Double; let high: Double; let low: Double; let close: Double }
    struct Series: Codable { let symbol: String; let bars: [Bar] }
    struct Input: Codable { let schema: String; let series: [Series] }

    /// Preserve the source off-by-one: window5/lag1 uses k-1 versus k-5,
    /// four return intervals ending one observation before the review close.
    public static func decisions(leader: [Double], follower: [Double],
                                 firstExecutionIndex: Int, inverse: Bool = false) throws -> [Decision] {
        guard leader.count == follower.count, firstExecutionIndex >= 6,
              firstExecutionIndex < leader.count,
              (leader + follower).allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("credit lead observed prices")
        }
        var weight = 0.0, stop: Double? = nil
        return leader.indices.map { i in
            let k = i - 1
            let signal = k >= 5 ? leader[k - 1] / leader[k - 5] - 1 : nil
            let review = i >= firstExecutionIndex && (i - firstExecutionIndex) % 5 == 0
            var event = "hold"
            if i < firstExecutionIndex { event = "warmup" }
            else if let level = stop, follower[k] <= level {
                // Fixed USD entry-signal stop, observed at prior close. Stop wins
                // over review; its proceeds cannot buy again on this execution day.
                weight = 0; stop = nil; event = "stop"
            } else if review, let signal {
                let enter = inverse ? signal <= -0.005 : signal >= 0.005
                let exit = inverse ? signal >= 0.005 : signal <= -0.005
                if weight == 0 && enter {
                    weight = 0.8; stop = follower[k] * 0.95; event = "enter"
                } else if weight > 0 && exit {
                    weight = 0; stop = nil; event = "exit"
                }
            }
            return .init(signalIndex: k, leaderReturn: signal, review: review,
                         weight: weight, stopPrice: stop, event: event)
        }
    }

    public static func run(pricesPath: String, historyPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        guard input.schema == "credit-lead-observed-ohlc-v1", input.series.map(\.symbol) == ["LQD", "QQQ"] else {
            throw BacktestConfigurationError.invalidParameter("frozen credit instruments")
        }
        let days = input.series[0].bars.map(\.date)
        guard days.first == "2003-01-02", days.last == "2026-10-02",
              zip(days, days.dropFirst()).allSatisfy({ $0 < $1 }),
              input.series.allSatisfy({ s in s.bars.map(\.date) == days && s.bars.allSatisfy({ b in
                  BacktestSeriesAlignment.historicalSeriesDate(from: b.date) != nil
                      && [b.open, b.high, b.low, b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                      && b.high >= max(b.open, b.close) && b.low <= min(b.open, b.close)
              }) }), let first = days.firstIndex(of: "2005-01-03") else {
            throw BacktestConfigurationError.missingData("matched credit real session OHLC")
        }
        let leader = input.series[0].bars.map(\.close), follower = input.series[1].bars
        let schedules = try [false, true].map {
            try decisions(leader: leader, follower: follower.map(\.close), firstExecutionIndex: first, inverse: $0)
        }
        let controls = try IndustryTrendScreen.loadControlSeries(from: history)
        let fx = controls["usd_per_cny"]!
        let conversion = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates, prices: fx.prices, asOf: $0)) }
        let dates = days.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        let closes = zip(follower, conversion).map { $0.close * $1 }
        let opens = zip(follower, conversion).map { $0.open * $1 }
        let option = BacktestInstrument(symbol: "QQQ", title: "QQQ", requiresHistoricalFX: false, historicalFXSymbol: nil)
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: ["QQQ": closes],
            observedBySymbol: ["QQQ": Array(repeating: true, count: days.count)],
            ohlcBySymbol: [:], tradableSymbols: ["QQQ"], optionBySymbol: ["QQQ": option],
            simulationRange: first...(days.count - 1))
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025,
            slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0,
            allowsFinancedExposure: false, buyReason: "frozen LQD lead / next-open observed stop")
        let ids = ["lqd-qqq-lead-stop5", "lqd-qqq-opposite-stop5", "qqq-fixed80", "qqq-buyhold", "cny-cash-control"]
        let windows = [("full", "2005-01-03"), ("since2020", "2020-01-01"),
                       ("since2022", "2022-01-01"), ("since2025", "2025-01-01"),
                       ("since_source_commit", "2026-04-30")].map { name, lower in
            (name, days.last(where: { $0 < lower && $0 >= "2005-01-03" }) ?? "2005-01-02", "2026-10-02")
        }
        var rows: [DailyScreenOutput.Row] = [], traces: [String: [[String: Double]]] = [:]
        for (mode, id) in ids.enumerated() {
            func desired(_ index: Int) -> [String: Double] {
                let weight = mode < 2 ? schedules[mode][index].weight : mode == 2 ? 0.8 : mode == 3 ? 1.0 : 0
                return weight > 0 ? ["QQQ": weight] : [:]
            }
            guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                provider: .init { desired($0.index) },
                rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
                contextualRebalanceDecision: { context in
                    let rebalance = context.index == first || (mode < 2
                        ? schedules[mode][context.index].event != "hold"
                        : mode == 2 && (context.index - first) % 5 == 0)
                    return .init(shouldRebalance: rebalance, refreshOverlay: false)
                }, executionPricesBySymbol: ["QQQ": opens]) else { throw BacktestConfigurationError.missingData(id) }
            let seed = BacktestDailyState(date: dates[first].addingTimeInterval(-86400), targetWeights: [:],
                cash: 100000, holdingsBySymbol: [:], portfolioValue: 100000)
            rows.append(try DailyScreenOutput.row(id, states: [seed] + run.dailyStates,
                trades: run.trades, windows: windows))
            traces[id] = frame.simulationRange.map { desired($0) }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence: [String: Any] = ["evidence_class": "D0_PINNED_CODE_CAUSAL_STOP_CNY_ADAPTATION",
            "formal_validation": false, "recommendation_eligible": false,
            "source": "https://github.com/45ck/llm-quant", "author_commit": "c82725c9a67e99fa2c83a536369c3fe2345d379d",
            "source_commit": sourceCommit, "run_count": 5, "parameter_search_count": 0,
            "data_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": ResearchRunEvidence.sha256(history),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "result_sha256": ResearchRunEvidence.sha256(result),
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "execution_version": "settlement-v4/next-open/symbol-order-v1", "fee_percent": 0.025,
            "slippage_percent": 0, "cash": "CashYieldCNY", "maximum_target_gross": 1,
            "entry_weight": 0.8, "signal_window_source": 5, "actual_return_intervals": 4,
            "review_sessions": 5, "stop_fraction": 0.95,
            "fx_policy": "strict-prior-calendar-date/max14days/same-factor-open-close",
            "limitations": ["Pinned raw LQD signal and funded QQQ PRICE ONLY; distributions omitted.",
                "Source same-close observed stop moved to next-open; not original complete-account reproduction.",
                "Source window5 actually4 intervals ending one session before review; preserved without tuning.",
                "Fixed original entry-signal USD stop; candidate holds units without rebalancing while held.",
                "All input calendars observed and matched, allowing deterministic entry/exit state; verify actual fills in audit.",
                "Public source was selected from many author trials; historical data exposed, no pristine OOS or formal pass.",
                "Post-source-commit slice is retrospective diagnostic, not our forward observation.",
                "Current-vintage prices, no separate USD wallet, FX costs, market capacity or tax modelling.",
                "Cash control Sharpe economically uninformative; no first-day cash interest."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try encoder.encode(traces).write(to: output.appendingPathComponent("desired-targets.json"), options: .atomic)
        try encoder.encode(schedules).write(to: output.appendingPathComponent("features.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("Credit lead: one pinned candidate and four frozen controls saved.")
    }
}
