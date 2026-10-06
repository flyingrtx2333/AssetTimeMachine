import Foundation
import AssetTimeMachineBacktestCore

/// One fixed public rule, with an explicitly different, executable next-open clock.
/// This is exploratory research, not a product strategy or a formal acceptance run.
public enum IBSOpenScreen {
    public struct Bar {
        public let date: Date
        public let open: Double
        public let high: Double
        public let low: Double
        public let close: Double
        public init(date: Date, open: Double, high: Double, low: Double, close: Double) {
            self.date = date; self.open = open; self.high = high; self.low = low; self.close = close
        }
    }

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
        let dataset = try PublicBacktestCore.loadDataset(from: history,
            datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        let document = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        guard let chart = document?["chart"] as? [String: Any],
              let root = (chart["result"] as? [[String: Any]])?.first,
              let meta = root["meta"] as? [String: Any], meta["symbol"] as? String == "SPY",
              meta["currency"] as? String == "USD",
              let times = root["timestamp"] as? [Double],
              let indicators = root["indicators"] as? [String: Any],
              let quote = (indicators["quote"] as? [[String: Any]])?.first,
              let open = quote["open"] as? [Double], let high = quote["high"] as? [Double],
              let low = quote["low"] as? [Double], let close = quote["close"] as? [Double],
              [open.count, high.count, low.count, close.count].allSatisfy({ $0 == times.count }),
              let fx = dataset.seriesBySymbol["usd_per_cny"] else {
            throw BacktestConfigurationError.missingData("SPY real OHLC and historical FX")
        }
        let ny = DateFormatter()
        ny.locale = Locale(identifier: "en_US_POSIX")
        ny.timeZone = TimeZone(identifier: "America/New_York")
        ny.dateFormat = "yyyy-MM-dd"
        let bars = try times.indices.map { i -> Bar in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: ny.string(from: Date(timeIntervalSince1970: times[i]))) else {
                throw BacktestConfigurationError.invalidParameter("SPY trade date")
            }
            return .init(date: date, open: open[i], high: high[i], low: low[i], close: close[i])
        }
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2008-01-02")!
        let end = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-08-20")!
        let weights = try desiredWeights(bars: bars, start: start)
        let dates = bars.map(\.date)
        guard let first = dates.firstIndex(where: { $0 >= start }),
              let last = dates.lastIndex(where: { $0 <= end }), first >= 25, last > first,
              dates[first] == start, dates[last] == end,
              fx.dates.count == fx.prices.count,
              zip(fx.dates, fx.dates.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw BacktestConfigurationError.missingData("frozen coverage")
        }
        let fxDates = try fx.dates.map { day -> Date in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: day) else {
                throw BacktestConfigurationError.invalidParameter("FX trade date")
            }
            return date
        }
        // Strictly prior calendar-date FX for both open sizing and close marks.
        // No execution-day final FX quote can enter an opening-auction fill.
        let knownFX = try dates.map { date -> Double in
            var lo = 0, hi = fxDates.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if fxDates[mid] < date { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0, date.timeIntervalSince(fxDates[lo - 1]) <= 14 * 86400,
                  fx.prices[lo - 1].isFinite, fx.prices[lo - 1] > 0 else {
                throw BacktestConfigurationError.missingData("prior FX within 14 days")
            }
            return fx.prices[lo - 1]
        }
        let closes = bars.indices.map { bars[$0].close / knownFX[$0] }
        let opens = bars.indices.map { bars[$0].open / knownFX[$0] }
        let option = BacktestInstrument(symbol: "SPY", title: "SPY", requiresHistoricalFX: true,
            historicalFXSymbol: "usd_per_cny", currency: "USD")
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: ["SPY": closes],
            observedBySymbol: ["SPY": Array(repeating: true, count: dates.count)], ohlcBySymbol: [:],
            tradableSymbols: ["SPY"], optionBySymbol: ["SPY": option], simulationRange: first...last)
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "IBS fixed public base rule")
        struct Metric: Encodable {
            let annualizedReturn: Double?
            let maxDrawdown: Double
            let sharpeRF0: Double?
            let excessSharpeCNYCash: Double?
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
            let dailyStates: [BacktestDailyState]
            let trades: [Trade]
            let slices: [String: Metric]
            let meanExposure: Double
        }
        var rows: [Row] = []
        func append(_ id: String, states: [BacktestDailyState], trades: [AdvancedBacktestTrade]) throws {
            guard !states.isEmpty else { throw BacktestConfigurationError.missingData(id) }
            for s in states {
                let held = s.holdingsBySymbol.values.reduce(0, +)
                guard s.portfolioValue > 0, s.portfolioValue.isFinite, s.cash >= -1e-8,
                      abs(held + s.cash - s.portfolioValue) <= max(1e-8, abs(s.portfolioValue) * 1e-12),
                      held / s.portfolioValue <= 1 + 1e-12,
                      s.targetWeights.values.allSatisfy({ $0 >= 0 && $0.isFinite }),
                      s.targetWeights.values.reduce(0, +) <= 1 + 1e-12 else {
                    throw BacktestConfigurationError.invalidParameter("accounting or leverage \(id)")
                }
            }
            var slices: [String: Metric] = [:]
            for (name, a, b) in [("full", "2008-01-02", "2026-08-20"),
                ("since2020", "2020-01-01", "2026-08-20"), ("since2022", "2022-01-01", "2026-08-20"),
                ("post_publication", "2024-05-21", "2026-08-20"),
                ("crisis2008", "2008-01-02", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"),
                ("crisis2022", "2022-01-01", "2022-12-31")] {
                let lower = BacktestSeriesAlignment.historicalSeriesDate(from: a)!
                let upper = BacktestSeriesAlignment.historicalSeriesDate(from: b)!
                let slice = states.filter { $0.date >= lower && $0.date <= upper }
                let points = slice.enumerated().map { BacktestSeriesPoint(date: $0.element.date,
                    portfolioValue: $0.element.portfolioValue, sequence: $0.offset) }
                guard let m = BacktestMetricsCalculator.performanceMetrics(from: points), slice.count > 2 else { continue }
                let excess = zip(slice, slice.dropFirst()).map { previous, current in
                    current.portfolioValue / previous.portfolioValue - 1
                        - CashYieldCNY.periodReturn(from: previous.date, to: current.date)
                }
                let mean = excess.reduce(0, +) / Double(excess.count)
                let variance = excess.reduce(0) { $0 + pow($1 - mean, 2) } / Double(excess.count - 1)
                let days = BacktestSeriesAlignment.historicalSeriesCalendar.dateComponents([.day], from: slice.first!.date, to: slice.last!.date).day!
                let excessSharpe = variance > 0 ? mean / sqrt(variance) * sqrt(Double(excess.count) / (Double(days) / 365.25)) : nil
                slices[name] = .init(annualizedReturn: m.annualizedReturn, maxDrawdown: m.maxDrawdown,
                    sharpeRF0: m.sharpeRatio, excessSharpeCNYCash: excessSharpe,
                    start: slice.first!.date, end: slice.last!.date, pointCount: slice.count)
            }
            rows.append(.init(id: id, dailyStates: states,
                trades: trades.map { .init(date: $0.date, symbol: $0.assetSymbol, action: $0.action.rawValue,
                    price: $0.price, cashAmount: $0.cashAmount, units: $0.units) }, slices: slices,
                meanExposure: states.reduce(0) { $0 + $1.holdingsBySymbol.values.reduce(0, +) / $1.portfolioValue } / Double(states.count)))
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
                "Published article does not specify fill clock; next-open is an explicit adaptation, not exact author replication.",
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
