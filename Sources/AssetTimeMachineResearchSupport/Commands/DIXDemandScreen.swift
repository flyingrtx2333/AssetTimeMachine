import Foundation
import AssetTimeMachineBacktestCore

/// Diagnostic capital-account interpretation of SqueezeMetrics' March2018 paper.
/// Dated aggregate data cannot certify historical publication time or vintage.
public enum DIXDemandScreen {
    public struct Decision: Codable, Equatable {
        public let sourceIndex: Int
        public let observation: Double?
        public let weight: Double
        public let event: String
    }
    struct Bar: Codable { let date: String; let open: Double; let high: Double; let low: Double; let close: Double }
    struct Series: Codable { let symbol: String; let bars: [Bar] }
    struct Input: Codable { let schema: String; let series: [Series]; let dix: [Double?] }

    public static func decisions(dix: [Double?], firstExecutionIndex: Int,
                                 inverse: Bool = false) throws -> [Decision] {
        guard firstExecutionIndex >= 2, firstExecutionIndex < dix.count,
              dix.compactMap({ $0 }).allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              dix[(firstExecutionIndex - 2)...].allSatisfy({ $0 != nil }) else {
            throw BacktestConfigurationError.missingData("observed dated DIX")
        }
        var entry: Int? = nil
        return dix.indices.map { i in
            // Leave a complete matched market session after the reference day.
            // This is a conservative timing assumption, not vendor PIT evidence.
            let observation = i >= 2 ? dix[i - 2] : nil
            var event = "hold"
            if i < firstExecutionIndex { event = "warmup" }
            else if let entered = entry, i - entered == 60 {
                entry = nil; event = "exit"
            } else if entry == nil, let observation,
                      inverse ? observation < 0.45 : observation >= 0.45 {
                entry = i; event = "enter"
            }
            return .init(sourceIndex: i - 2, observation: observation,
                         weight: entry == nil ? 0 : 1, event: event)
        }
    }

    public static func run(pricesPath: String, historyPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        guard input.schema == "dix-demand-observed-ohlc-v1", input.series.map(\.symbol) == ["SPY", "QQQ"] else {
            throw BacktestConfigurationError.invalidParameter("frozen demand instruments")
        }
        let days = input.series[0].bars.map(\.date)
        guard days.first == "2003-01-02", days.last == "2026-10-02", input.dix.count == days.count,
              zip(days, days.dropFirst()).allSatisfy({ $0 < $1 }),
              input.series.allSatisfy({ s in s.bars.map(\.date) == days && s.bars.allSatisfy({ b in
                  BacktestSeriesAlignment.historicalSeriesDate(from: b.date) != nil
                      && [b.open, b.high, b.low, b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                      && b.high >= max(b.open, b.close) && b.low <= min(b.open, b.close)
              }) }), let first = days.firstIndex(of: "2011-05-04") else {
            throw BacktestConfigurationError.missingData("matched demand real OHLC")
        }
        let schedules = try [false, true].map { try decisions(dix: input.dix, firstExecutionIndex: first, inverse: $0) }
        let controls = try IndustryTrendScreen.loadControlSeries(from: history)
        let fx = controls["usd_per_cny"]!
        let conversion = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates, prices: fx.prices, asOf: $0)) }
        let dates = days.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        let symbols = input.series.map(\.symbol)
        let closes = Dictionary(uniqueKeysWithValues: input.series.map { s in
            (s.symbol, zip(s.bars, conversion).map { $0.close * $1 })
        })
        let opens = Dictionary(uniqueKeysWithValues: input.series.map { s in
            (s.symbol, zip(s.bars, conversion).map { $0.open * $1 })
        })
        let options = Dictionary(uniqueKeysWithValues: symbols.map { ($0,
            BacktestInstrument(symbol: $0, title: $0, requiresHistoricalFX: false, historicalFXSymbol: nil)) })
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: closes,
            observedBySymbol: Dictionary(uniqueKeysWithValues: symbols.map { ($0, Array(repeating: true, count: days.count)) }),
            ohlcBySymbol: [:], tradableSymbols: symbols, optionBySymbol: options,
            simulationRange: first...(days.count - 1))
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025,
            slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0,
            allowsFinancedExposure: false, buyReason: "frozen DIX demand / 60-session hold")
        let ids = ["dix-qqq-demand60", "dix-qqq-low60-control", "dix-spy-demand60-control", "qqq-buyhold", "cny-cash-control"]
        let windows = [("full", "2011-05-04"), ("since_paper", "2018-04-01"),
                       ("since2020", "2020-01-01"), ("since2022", "2022-01-01"), ("since2025", "2025-01-01")].map { name, lower in
            (name, days.last(where: { $0 < lower && $0 >= "2011-05-04" }) ?? "2011-05-03", "2026-10-02")
        }
        var rows: [DailyScreenOutput.Row] = [], traces: [String: [[String: Double]]] = [:]
        for (mode, id) in ids.enumerated() {
            let schedule = schedules[mode == 1 ? 1 : 0]
            func desired(_ index: Int) -> [String: Double] {
                let weight = mode < 3 ? schedule[index].weight : mode == 3 ? 1.0 : 0
                return weight > 0 ? [mode == 2 ? "SPY" : "QQQ": weight] : [:]
            }
            guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                provider: .init { desired($0.index) },
                rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
                contextualRebalanceDecision: { context in
                    .init(shouldRebalance: context.index == first || (mode < 3 && schedule[context.index].event != "hold"),
                          refreshOverlay: false)
                }, executionPricesBySymbol: opens) else { throw BacktestConfigurationError.missingData(id) }
            let seed = BacktestDailyState(date: dates[first].addingTimeInterval(-86400), targetWeights: [:],
                cash: 100000, holdingsBySymbol: [:], portfolioValue: 100000)
            rows.append(try DailyScreenOutput.row(id, states: [seed] + run.dailyStates, trades: run.trades, windows: windows))
            traces[id] = frame.simulationRange.map { desired($0) }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence: [String: Any] = ["evidence_class": "D0_DATED_AGGREGATE_TIMING_ASSUMPTION",
            "formal_validation": false, "recommendation_eligible": false, "pit_certified": false,
            "source": "https://squeezemetrics.com/monitor/download/pdf/short_is_long.pdf", "source_version": "March2018",
            "source_commit": sourceCommit, "run_count": 5, "parameter_search_count": 0,
            "data_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": ResearchRunEvidence.sha256(history),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "result_sha256": ResearchRunEvidence.sha256(result),
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "execution_version": "settlement-v4/next-open/symbol-order-v1", "fee_percent": 0.025,
            "slippage_percent": 0, "cash": "CashYieldCNY", "maximum_target_gross": 1,
            "threshold": 0.45, "holding_sessions": 60, "signal_lag_sessions": 2,
            "limitations": ["DIX is dated aggregate flow, not short interest or observed dealer/customer holdings.",
                "No immutable historical available_at or composition/vintage evidence. Two-session lag is an assumption; formal eligibility blocked.",
                "2011+ only: no2005-2010 or2008 financial-crisis factor history.",
                "Paper reports overlapping conditional60day returns, not this funded flat-only open-to-open strategy.",
                "QQQ transfer of broad SP500 demand is unvalidated; same SPY rule retained as source-asset control.",
                "Signal observations while held ignored; mandatory60session exit, no same-open reentry or weight maintenance.",
                "All funded accounts PRICE ONLY, no distributions; strict-prior FX, no FX fees/taxes/capacity.",
                "Historical public pattern exposed; postpaper slice is retrospective, not pristine OOS.",
                "Cash control Sharpe economically uninformative; no first-day cash interest."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try encoder.encode(traces).write(to: output.appendingPathComponent("desired-targets.json"), options: .atomic)
        try encoder.encode(schedules).write(to: output.appendingPathComponent("features.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("DIX demand: one frozen funded diagnostic and four controls saved; PIT not certified.")
    }
}
