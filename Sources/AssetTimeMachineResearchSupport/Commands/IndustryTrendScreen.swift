import Foundation
import AssetTimeMachineBacktestCore

/// Bounded, price-only adaptation of the published industry notebook.
/// Calls the shared settlement simulator; does not register a product strategy.
public enum IndustryTrendScreen {
    public static let symbols = ["XLF", "XLK", "XLE", "XLV", "XLI", "XBI", "XLU", "XLP", "XLY",
        "KRE", "XLB", "XLC", "XRT", "XOP", "XLRE", "XHB", "KBE", "XME", "KIE", "XSD",
        "XAR", "XES", "KCE", "XNTK", "XHE", "XSW", "XPH", "XTN", "XHS", "XITK", "XTL"]

    public struct Series: Codable {
        public let symbol: String
        public let dates: [String]
        public let prices: [Double]
        public init(symbol: String, dates: [String], prices: [Double]) {
            self.symbol = symbol; self.dates = dates; self.prices = prices
        }
    }
    private struct Input: Decodable { let schema: String; let series: [Series] }
    public struct Signal: Equatable, Codable {
        public let long: Bool
        public let upper: Double?
        public let lower: Double?
        public let stop: Double?
        public let volatility: Double?
    }

    /// EMA uses the first observed close and adjust=false. Volatility is the
    /// population standard deviation of 20 actual session returns.
    public static func signals(prices: [Double]) throws -> [Signal] {
        guard !prices.isEmpty, prices.allSatisfy({ $0 > 0 && $0.isFinite }) else {
            throw BacktestConfigurationError.invalidParameter("industry prices")
        }
        var ema20 = prices[0], ema40 = prices[0]
        var changes = [0.0], returns = [0.0], out: [Signal] = []
        var held = false, stop: Double? = nil
        for i in prices.indices {
            if i > 0 {
                ema20 += 2.0 / 21 * (prices[i] - ema20)
                ema40 += 2.0 / 41 * (prices[i] - ema40)
                changes.append(abs(prices[i] - prices[i - 1]))
                returns.append(prices[i] / prices[i - 1] - 1)
            }
            func band(_ n: Int, upper: Bool) -> Double? {
                guard i >= n - 1 else { return nil }
                let observations = prices[(i - n + 1)...i]
                // pandas rolling(n,min_periods=n-1) excludes the initial NaN.
                let deltas = changes[max(1, i - n + 1)...i]
                let width = 2.8 * deltas.reduce(0, +) / Double(deltas.count)
                return upper ? min(observations.max()!, ema20 + width)
                    : max(observations.min()!, ema40 - width)
            }
            let up = band(20, upper: true), down = band(40, upper: false)
            var volatility: Double? = nil
            if i >= 20 {
                let r = returns[(i - 19)...i]
                let mean = r.reduce(0, +) / 20
                volatility = sqrt(r.reduce(0) { $0 + pow($1 - mean, 2) } / 20)
            }
            if let lower = down {
                if held {
                    let threshold = max(stop ?? lower, lower)
                    held = prices[i] > threshold
                    stop = held ? threshold : nil
                } else if i > 0, let previousUpper = out.last?.upper,
                          let previousLower = out.last?.lower,
                          prices[i] >= previousUpper, previousUpper > previousLower {
                    held = true; stop = lower
                }
            }
            out.append(.init(long: held, upper: up, lower: down, stop: stop, volatility: volatility))
        }
        return out
    }

    public static func weights(series: [Series], indicators: [[Signal]],
                               asOf: String, equalWeight: Bool = false) -> [String: Double] {
        var available: [(Series, Int, Signal)] = []
        for (s, signals) in zip(series, indicators) {
            var lo = 0, hi = s.dates.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if s.dates[mid] <= asOf { lo = mid + 1 } else { hi = mid }
            }
            // One actual return must exist. Before the first available quote an
            // instrument contributes neither a target nor a synthetic observation.
            if lo > 1 { available.append((s, lo - 1, signals[lo - 1])) }
        }
        guard !available.isEmpty else { return [:] }
        let count = Double(available.count)
        var result: [String: Double] = [:]
        for (s, _, signal) in available {
            if equalWeight { result[s.symbol] = 1 / count }
            else if signal.long, let vol = signal.volatility, vol > 0 {
                result[s.symbol] = min(0.20, 0.015 / (count * vol))
            }
        }
        let gross = result.values.reduce(0, +)
        if gross > 1 { result = result.mapValues { $0 / gross } }
        return result
    }

    public static func excessSharpe(states: [BacktestDailyState]) -> Double? {
        guard let first = states.first, let last = states.last, states.count > 2 else { return nil }
        var excess: [Double] = []
        for (a, b) in zip(states, states.dropFirst()) {
            excess.append(b.portfolioValue / a.portfolioValue - 1
                - CashYieldCNY.periodReturn(from: a.date, to: b.date))
        }
        let mean = excess.reduce(0, +) / Double(excess.count)
        let variance = excess.reduce(0) { $0 + pow($1 - mean, 2) } / Double(excess.count - 1)
        let years = last.date.timeIntervalSince(first.date) / (86400 * 365.25)
        guard variance > 0, years > 0 else { return nil }
        return mean / sqrt(variance) * sqrt(Double(excess.count) / years)
    }

    private struct Submission: Codable {
        let executionDate: Date
        let signalDate: Date
        let weights: [String: Double]
    }
    private struct Metrics: Codable {
        let annualizedReturn: Double?
        let maxDrawdown: Double
        let sharpeRF0: Double?
        let excessSharpeCNYCash: Double?
        let start: Date
        let end: Date
        let points: Int
    }
    private struct Fill: Codable {
        let date: Date
        let symbol: String
        let action: String
        let price: Double
        let cashAmount: Double
        let units: Double
    }
    private struct Result: Codable {
        let id: String
        let dailyStates: [BacktestDailyState]
        let trades: [Fill]
        let submissions: [Submission]
        let slices: [String: Metrics]
        let accountingMaxError: Double
        let minimumCash: Double
        let maximumActualGross: Double
        let maximumTargetGross: Double
        let buyDelayReviewEpisodes: Int
        let longestUnheldTargetOpportunities: Int
    }

    static func preQuoteZeroFillSymbols(series: [Series], start: String) -> Set<String> {
        // Existing instruments anchor the observed calendar. Only later first
        // quotes need unavailable pre-quote slots; marking all optional removes
        // every calendar anchor in the shared aligner.
        Set(series.filter { ($0.dates.first ?? start) > start }.map(\.symbol))
    }

    // Research needs these four original provider symbols, not the complete
    // public product catalogue or its normalized Nasdaq alias.
    static func loadControlSeries(from data: Data) throws -> [String: PublicHistorySeries] {
        let response = try JSONDecoder().decode(PublicHistoryResponse.self, from: data)
        guard response.success else { throw BacktestConfigurationError.missingData("control response") }
        let required: Set<String> = ["usd_per_cny", "sp500", "gold_cny", "nasdaq_composite"]
        var series: [String: PublicHistorySeries] = [:]
        for s in response.series where required.contains(s.symbol) {
            guard series[s.symbol] == nil, s.dates.count == s.prices.count, s.dates.count >= 2,
                  zip(s.dates, s.dates.dropFirst()).allSatisfy({ $0 < $1 }),
                  s.dates.allSatisfy({ BacktestSeriesAlignment.historicalSeriesDate(from: $0) != nil }),
                  s.prices.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw BacktestConfigurationError.invalidParameter("control observations \(s.symbol)")
            }
            series[s.symbol] = s
        }
        guard required.isSubset(of: Set(series.keys)) else {
            throw BacktestConfigurationError.missingData("controls and historical FX")
        }
        return series
    }

    public static func run(etfPath: String, historyPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: etfPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        guard input.schema == "industry-price-observations-v1",
              input.series.map(\.symbol) == symbols else {
            throw BacktestConfigurationError.missingData("complete frozen 31 ETF basket")
        }
        for s in input.series {
            guard s.dates.count == s.prices.count, s.dates.count >= 50,
                  zip(s.dates, s.dates.dropFirst()).allSatisfy({ $0 < $1 }),
                  s.dates.allSatisfy({ BacktestSeriesAlignment.historicalSeriesDate(from: $0) != nil }),
                  s.prices.allSatisfy({ $0.isFinite && $0 > 0 }),
                  s.dates.last == "2026-10-02" else {
                throw BacktestConfigurationError.invalidParameter("industry observations \(s.symbol)")
            }
        }
        let indicators = try input.series.map { try signals(prices: $0.prices) }
        let root = try JSONSerialization.jsonObject(with: history) as? [String: Any]
        guard root?["history_quality_policy"] as? String == "provider-trade-date-v1" else {
            throw BacktestConfigurationError.missingData("provider trade dates")
        }
        let controls = try loadControlSeries(from: history)
        guard let fx = controls["usd_per_cny"],
              let sp = controls["sp500"],
              let gold = controls["gold_cny"],
              let nasdaq = controls["nasdaq_composite"] else {
            throw BacktestConfigurationError.missingData("controls and historical FX")
        }
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2005-01-03")!
        let end = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-10-02")!
        let settings = AdvancedBacktestRiskSettings(feeRate: 0.025, slippageRate: 0,
            maxPositionRatio: 100, cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0)
        func option(_ symbol: String) -> BacktestInstrument {
            .init(symbol: symbol, title: symbol, requiresHistoricalFX: true,
                historicalFXSymbol: "usd_per_cny", currency: "USD")
        }
        func publicSeries(_ s: Series) -> PublicHistorySeries {
            .init(symbol: s.symbol, category: "industry_etf", label: s.symbol, currency: "USD",
                unit: "USD", source: "Yahoo daily split-adjusted close; dividends not reinvested",
                dates: s.dates, prices: s.prices, hasOHLC: nil, ohlcSource: nil,
                ohlcCoverageRatio: nil, openPrices: nil, highPrices: nil,
                lowPrices: nil, closePrices: nil, volumes: nil)
        }
        let inputs = input.series.map { (assetSeries: Optional(publicSeries($0)),
            assetOption: option($0.symbol), fxSeries: Optional(fx)) }
        func dayString(_ date: Date) -> String {
            let c = BacktestSeriesAlignment.historicalSeriesCalendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        var rows: [Result] = []
        func append(_ id: String, states: [BacktestDailyState], trades: [AdvancedBacktestTrade],
                    submissions: [Submission]) throws {
            guard let first = states.first else { throw BacktestConfigurationError.missingData("daily states") }
            var maxError = 0.0, minCash = Double.infinity, maxGross = 0.0, maxTarget = 0.0
            var delays: [String: Int] = [:], longest = 0, episodes = 0
            let observed = Dictionary(uniqueKeysWithValues: input.series.map { ($0.symbol, Set($0.dates)) })
            for state in states {
                let held = state.holdingsBySymbol.values.reduce(0, +)
                let error = abs(state.cash + held - state.portfolioValue)
                let gross = held / state.portfolioValue
                let targetGross = state.targetWeights.values.reduce(0, +)
                guard state.portfolioValue.isFinite, state.portfolioValue > 0,
                      error <= max(1e-8, abs(state.portfolioValue) * 1e-12),
                      state.cash >= -1e-8, gross <= 1 + 1e-12,
                      state.targetWeights.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
                      targetGross <= 1 + 1e-12 else {
                    throw BacktestConfigurationError.invalidParameter("accounting or gross exposure \(id)")
                }
                maxError = max(maxError, error); minCash = min(minCash, state.cash)
                maxGross = max(maxGross, gross); maxTarget = max(maxTarget, targetGross)
                let d = dayString(state.date)
                for s in symbols where observed[s]?.contains(d) == true {
                    if (state.targetWeights[s] ?? 0) > 1e-8,
                       (state.holdingsBySymbol[s] ?? 0) < 1e-8 {
                        delays[s, default: 0] += 1
                        longest = max(longest, delays[s]!)
                        if delays[s] == 3 { episodes += 1 }
                    } else { delays[s] = 0 }
                }
            }
            // An explicit seed includes the initial entry fee in all full-window metrics.
            let seedDate = BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding: .day, value: -1, to: first.date)!
            let seed = BacktestDailyState(date: seedDate, targetWeights: [:], cash: 100000,
                holdingsBySymbol: [:], portfolioValue: 100000)
            let seeded = [seed] + states
            var slices: [String: Metrics] = [:]
            let windows = [("full", "2005-01-03", "2026-10-02"),
                ("paper_2005_2024", "2005-01-03", "2024-03-28"),
                ("since2020", "2020-01-01", "2026-10-02"),
                ("since2022", "2022-01-01", "2026-10-02"),
                ("since2025", "2025-01-01", "2026-10-02"),
                ("crisis2008", "2008-01-01", "2008-12-31"),
                ("crisis2020", "2020-01-01", "2020-12-31"),
                ("crisis2022", "2022-01-01", "2022-12-31")]
            for (name, lower, upper) in windows {
                let a = BacktestSeriesAlignment.historicalSeriesDate(from: lower)!
                let b = BacktestSeriesAlignment.historicalSeriesDate(from: upper)!
                var slice = seeded.filter { $0.date >= a && $0.date <= b }
                if let previous = seeded.last(where: { $0.date < a }) { slice.insert(previous, at: 0) }
                let points = slice.enumerated().map { BacktestSeriesPoint(date: $0.element.date,
                    portfolioValue: $0.element.portfolioValue, sequence: $0.offset) }
                if let m = BacktestMetricsCalculator.performanceMetrics(from: points), let last = slice.last {
                    slices[name] = .init(annualizedReturn: m.annualizedReturn, maxDrawdown: m.maxDrawdown,
                        sharpeRF0: m.sharpeRatio, excessSharpeCNYCash: excessSharpe(states: slice),
                        start: slice.first!.date, end: last.date, points: slice.count)
                }
            }
            for fill in trades where symbols.contains(fill.assetSymbol) {
                let d = dayString(fill.date)
                guard observed[fill.assetSymbol]?.contains(d) == true,
                      let s = submissions.last(where: { $0.executionDate <= fill.date }),
                      s.signalDate < fill.date else {
                    throw BacktestConfigurationError.invalidParameter("real observed later fill \(id)")
                }
            }
            rows.append(.init(id: id, dailyStates: states,
                trades: trades.map { .init(date: $0.date, symbol: $0.assetSymbol,
                    action: $0.action.rawValue, price: $0.price, cashAmount: $0.cashAmount, units: $0.units) },
                submissions: submissions, slices: slices, accountingMaxError: maxError,
                minimumCash: minCash, maximumActualGross: maxGross, maximumTargetGross: maxTarget,
                buyDelayReviewEpisodes: episodes, longestUnheldTargetOpportunities: longest))
        }
        for (id, equal) in [("industry-notebook-100-rmb-price", false), ("industry-equal-weight-rmb-price", true)] {
            var submissions: [Submission] = []
            let config = ResearchTargetStrategyConfig(symbol: id, title: id, warmupSessions: 41,
                rebalanceSessions: 1, zeroFillBeforeFirstSymbols:
                    preQuoteZeroFillSymbols(series: input.series, start: "2005-01-03"))
            guard let run = TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
                assetInputs: inputs, initialCash: 100000, settings: settings, config: config,
                dateBounds: start...end, targetWeights: { context, _ in
                    let weights = weights(series: input.series, indicators: indicators,
                        asOf: dayString(context.signalDate), equalWeight: equal)
                    submissions.append(.init(executionDate: context.date,
                        signalDate: context.signalDate, weights: weights))
                    return weights
                }) else { throw BacktestConfigurationError.missingData(id) }
            try append(id, states: run.dailyStates, trades: run.report.trades, submissions: submissions)
        }
        let goldOption = BacktestInstrument(symbol: "gold_cny", title: "gold_cny",
            requiresHistoricalFX: false, historicalFXSymbol: nil)
        let spInputs = [(assetSeries: Optional(sp), assetOption: option("sp500"), fxSeries: Optional(fx)),
            (assetSeries: Optional(gold), assetOption: goldOption, fxSeries: Optional<PublicHistorySeries>.none)]
        var submitted = false
        let spConfig = ResearchTargetStrategyConfig(symbol: "sp500-buy-hold-rmb-price",
            title: "sp500 price control", warmupSessions: 41, rebalanceSessions: 1,
            signalOnlySymbols: ["gold_cny"])
        guard let spRun = TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
            assetInputs: spInputs, initialCash: 100000, settings: settings, config: spConfig,
            dateBounds: start...end, contextualRebalanceDecision: { _, _ in
                defer { submitted = true }
                return .init(shouldRebalance: !submitted, refreshOverlay: false)
            }, targetWeights: { _, _ in ["sp500": 1] }) else {
            throw BacktestConfigurationError.missingData("sp500 control")
        }
        try append("sp500-buy-hold-rmb-price", states: spRun.dailyStates,
            trades: spRun.report.trades, submissions: [])
        let barbellInputs = [(assetSeries: Optional(gold), assetOption: goldOption,
            fxSeries: Optional<PublicHistorySeries>.none),
            (assetSeries: Optional(nasdaq), assetOption: option("nasdaq"), fxSeries: Optional(fx))]
        guard let barbell = BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(
            assetInputs: barbellInputs, initialCash: 100000, settings: settings,
            mode: .goldNasdaqDualTrendBarbell, dateBounds: start...end) else {
            throw BacktestConfigurationError.missingData("gold Nasdaq control")
        }
        try append("gold-nasdaq-dual-trend-barbell", states: barbell.dailyStates,
            trades: barbell.report.trades, submissions: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let result = try encoder.encode(rows)
        let evidence: [String: Any] = [
            "evidence_class": "D0_PRICE_ONLY_NOTEBOOK_ADAPTATION",
            "formal_validation": false, "recommendation_eligible": false,
            "source_commit": sourceCommit, "execution_version": "settlement-v4",
            "dataset_sha256": ResearchRunEvidence.sha256(raw),
            "control_history_sha256": ResearchRunEvidence.sha256(history),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "run_count": rows.count, "parameter_search_count": 0,
            "limitations": ["Price-only closes: ETF and stock dividends are NOT credited; not total-return replication.",
                "Notebook defaults use 20-session volatility; paper describes 14. This command freezes the notebook defaults.",
                "USD signals, CNY historical valuation, RMB demand cash, no leverage, 0.025% per fill.",
                "Next real observed close with settlement instead of instantaneous end-of-day target returns.",
                "Retrospectively selected published basket; no pristine holdout or full G0-G6 certification.",
                "Daily maintenance rebalances retained; unheld target episodes require execution review.",
                "Metric windows include a preceding NAV anchor; full window includes initial entry costs."]
        ]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("Industry study: one fixed candidate, three controls; immutable outputs saved.")
    }
}
