import Foundation
import AssetTimeMachineBacktestCore

/// Fixed long-only price adaptation of the published post-month-turn sector reversal.
/// Uses observed past sessions, genuine next opens and the shared funded simulator.
public enum SectorMonthstartScreen {
    public static let symbols = ["XLB", "XLE", "XLF", "XLI", "XLK", "XLP", "XLU", "XLV", "XLY"]
    public struct Bar: Codable {
        public let date: String
        public let open: Double
        public let high: Double
        public let low: Double
        public let close: Double
        public init(date: String, open: Double, high: Double, low: Double, close: Double) {
            self.date = date; self.open = open; self.high = high; self.low = low; self.close = close
        }
    }
    public struct Series: Codable {
        public let symbol: String
        public let bars: [Bar]
        public init(symbol: String, bars: [Bar]) { self.symbol = symbol; self.bars = bars }
    }
    private struct Input: Codable { let schema: String; let series: [Series] }

    /// Returns targets known at each close, not positions retroactively earned that day.
    /// Rank at the preceding month-end; enter after observed D1, exit after D3.
    public static func targets(series: [Series], lookback: Int = 252,
                               selection: String = "bottom") throws -> [[String: Double]] {
        guard series.count >= 3, lookback > 0, ["bottom", "top", "all"].contains(selection),
              Set(series.map(\.symbol)).count == series.count, let first = series.first,
              !first.bars.isEmpty,
              zip(first.bars, first.bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
              series.allSatisfy({ s in
                  s.bars.map(\.date) == first.bars.map(\.date) && s.bars.allSatisfy({ b in
                      BacktestSeriesAlignment.historicalSeriesDate(from: b.date) != nil
                          && [b.open, b.high, b.low, b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                          && b.high >= max(b.open, b.close) && b.low <= min(b.open, b.close)
                  })
              }) else { throw BacktestConfigurationError.invalidParameter("sector observations or selection") }
        var out = Array(repeating: [String: Double](), count: first.bars.count)
        var month = "", session = 0, ranking: [String] = []
        for i in first.bars.indices {
            let current = String(first.bars[i].date.prefix(7))
            if current != month {
                month = current; session = 1; ranking = []
                let rankIndex = i - 1
                if rankIndex >= lookback {
                    let returns = Dictionary(uniqueKeysWithValues: series.map {
                        ($0.symbol, $0.bars[rankIndex].close / $0.bars[rankIndex - lookback].close - 1)
                    })
                    ranking = returns.keys.sorted {
                        returns[$0]! == returns[$1]! ? $0 < $1 : returns[$0]! < returns[$1]!
                    }
                }
            } else { session += 1 }
            if !ranking.isEmpty && session <= 2 {
                let chosen = selection == "all" ? ranking
                    : selection == "bottom" ? Array(ranking.prefix(3)) : Array(ranking.suffix(3))
                out[i] = Dictionary(uniqueKeysWithValues: chosen.map { ($0, 1 / Double(chosen.count)) })
            }
        }
        return out
    }

    static func priorFX(dates: [String], prices: [Double], asOf: String) throws -> Double {
        var low = 0, high = dates.count
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] < asOf { low = mid + 1 } else { high = mid }
        }
        guard low > 0, prices.indices.contains(low - 1), prices[low - 1] > 0,
              let a = BacktestSeriesAlignment.historicalSeriesDate(from: dates[low - 1]),
              let b = BacktestSeriesAlignment.historicalSeriesDate(from: asOf),
              b.timeIntervalSince(a) <= 14 * 86400 else {
            throw BacktestConfigurationError.missingData("strictly prior FX \(asOf)")
        }
        return prices[low - 1]
    }

    public static func run(sectorsPath: String, historyPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: sectorsPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        guard input.schema == "sector-session-price-v1", input.series.map(\.symbol) == symbols else {
            throw BacktestConfigurationError.invalidParameter("frozen nine-sector basket")
        }
        let schedules = try ["bottom", "top", "all"].map { try targets(series: input.series, selection: $0) }
        let controls = try IndustryTrendScreen.loadControlSeries(from: history)
        let fx = controls["usd_per_cny"]!
        let days = input.series[0].bars.map(\.date)
        let dates = days.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2005-01-03")!
        let end = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-10-02")!
        guard let first = dates.firstIndex(where: { $0 >= start }), first > 252,
              dates.last == end else { throw BacktestConfigurationError.missingData("sector window") }
        let conversion = try days.map { 1 / (try priorFX(dates: fx.dates, prices: fx.prices, asOf: $0)) }
        let options = Dictionary(uniqueKeysWithValues: symbols.map {
            ($0, BacktestInstrument(symbol: $0, title: $0, requiresHistoricalFX: false, historicalFXSymbol: nil))
        })
        let closes = Dictionary(uniqueKeysWithValues: input.series.map { s in
            (s.symbol, zip(s.bars, conversion).map { $0.close * $1 })
        })
        let opens = Dictionary(uniqueKeysWithValues: input.series.map { s in
            (s.symbol, zip(s.bars, conversion).map { $0.open * $1 })
        })
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: closes,
            observedBySymbol: Dictionary(uniqueKeysWithValues: symbols.map { ($0, Array(repeating: true, count: dates.count)) }),
            ohlcBySymbol: [:], tradableSymbols: symbols, optionBySymbol: options,
            simulationRange: first...(dates.count - 1))
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025,
            slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0,
            allowsFinancedExposure: false, buyReason: "fixed post-month-start reversal")
        var rows: [DailyScreenOutput.Row] = [], traces: [String: [[String: Double]]] = [:]
        let ranges = [("full", "2005-01-03"), ("since2020", "2020-01-01"),
                      ("since2022", "2022-01-01"), ("since2025", "2025-01-01")]
        let windows = ranges.map { name, lower -> (String, String, String) in
            let anchor = days.last(where: { $0 < lower && $0 >= "2005-01-03" }) ?? "2005-01-02"
            return (name, anchor, "2026-10-02")
        }
        for (j, id) in ["sector-monthstart-bottom3-open", "sector-monthstart-top3-falsification",
                        "sector-monthstart-all9-calendar", "sector-all9-buyhold-open"].enumerated() {
            var lastSubmitted: [String: Double]? = nil
            func desired(_ context: StrategyTargetContext) -> [String: Double] {
                j == 3 ? Dictionary(uniqueKeysWithValues: symbols.map { ($0, 1.0 / 9) })
                    : schedules[j][context.signalIndex]
            }
            guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                provider: .init { desired($0) },
                rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
                contextualRebalanceDecision: { context in
                    let w = desired(context), changed = lastSubmitted == nil || lastSubmitted != w
                    if changed { lastSubmitted = w }
                    return .init(shouldRebalance: changed, refreshOverlay: false)
                }, executionPricesBySymbol: opens) else { throw BacktestConfigurationError.missingData(id) }
            let seed = BacktestDailyState(date: start.addingTimeInterval(-86400), targetWeights: [:],
                cash: 100000, holdingsBySymbol: [:], portfolioValue: 100000)
            rows.append(try DailyScreenOutput.row(id, states: [seed] + run.dailyStates,
                trades: run.trades, windows: windows))
            traces[id] = frame.simulationRange.map { index in
                j == 3 ? Dictionary(uniqueKeysWithValues: symbols.map { ($0, 1.0 / 9) }) : schedules[j][index - 1]
            }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence: [String: Any] = ["evidence_class": "D0_PRICE_ONLY_LONG_ONLY_CLOCK_ADAPTATION",
            "formal_validation": false, "recommendation_eligible": false, "run_count": 4,
            "parameter_search_count": 0, "source_commit": sourceCommit,
            "data_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": ResearchRunEvidence.sha256(history),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "result_sha256": ResearchRunEvidence.sha256(result),
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "execution_version": "settlement-v4/next-open/symbol-order-v1",
            "fx_policy": "strict-prior-calendar-date/max14days/same-factor-open-close",
            "fee_percent": 0.025, "slippage_percent": 0, "cash": "CashYieldCNY",
            "window_anchor_policy": "Full includes synthetic initial NAV preceding first session; slices include preceding actual state.",
            "limitations": ["Price only, no cash dividends; price momentum instead of author total-return rank.",
                "Only long reversal leg; no shorts or borrowed capital, not author composite replication.",
                "D2 open to D4 open instead of D1 close to D3 close; opening auction and costs assumed.",
                "No pristine OOS; source discovery and historical slice selection not formal acceptance.",
                "Prior-date FX account abstraction, no separate USD cash wallet or conversion charges."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try encoder.encode(traces).write(to: output.appendingPathComponent("desired-targets.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("Sector reversal: fixed long-only candidate and three controls saved.")
    }
}
