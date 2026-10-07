import Foundation
import AssetTimeMachineBacktestCore

/// Fixed single-market-factor, pure-long ETF adaptation; never a product registration.
public enum SectorResidualMomentumScreen {
    public typealias Series = SectorMonthstartScreen.Series
    private struct Input: Decodable { let schema: String; let series: [Series] }
    public struct Review: Codable, Equatable {
        public let month: String
        public let signalDate: String?
        public let marketGate: Bool
        public let residualScores: [String: Double]
        public let rawScores: [String: Double]
    }

    /// Fit the known 36 months; omit fitted alpha from the formation residual.
    /// Score the preceding eleven months, excluding the most recent month.
    public static func residualScore(asset: [Double], market: [Double]) throws -> Double {
        guard asset.count == 36, market.count == 36,
              (asset + market).allSatisfy(\.isFinite) else {
            throw BacktestConfigurationError.invalidParameter("36 monthly return pairs")
        }
        let x = market.reduce(0, +) / 36, y = asset.reduce(0, +) / 36
        let variance = market.reduce(0) { $0 + pow($1 - x, 2) }
        guard variance > 1e-20 else {
            throw BacktestConfigurationError.invalidParameter("constant market regression")
        }
        let beta = zip(asset, market).reduce(0) { $0 + ($1.0 - y) * ($1.1 - x) } / variance
        let formation = (24..<35).map { asset[$0] - beta * market[$0] }
        let mean = formation.reduce(0, +) / 11
        let sd = sqrt(formation.reduce(0) { $0 + pow($1 - mean, 2) } / 10)
        guard sd > 1e-14 else {
            throw BacktestConfigurationError.invalidParameter("degenerate residual formation")
        }
        return mean / sd
    }

    /// Current calendar month is known; current open/close and later bars are not used.
    /// Only a month transition certifies the preceding month's last observed quote.
    public static func reviews(series: [Series]) throws -> [Review] {
        let expected = SectorMonthstartScreen.symbols + ["SPY"]
        guard series.map(\.symbol) == expected, let first = series.first, !first.bars.isEmpty,
              zip(first.bars, first.bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
              series.allSatisfy({ s in s.bars.map(\.date) == first.bars.map(\.date)
                  && s.bars.allSatisfy({ b in
                      BacktestSeriesAlignment.historicalSeriesDate(from: b.date) != nil
                          && [b.open, b.high, b.low, b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                          && b.high >= max(b.open, b.close) && b.low <= min(b.open, b.close)
                  }) }) else {
            throw BacktestConfigurationError.invalidParameter("fixed sector/SPY observed calendar")
        }
        var ends: [Int] = [], month = "", out: [Review] = []
        var current = Review(month: "", signalDate: nil, marketGate: false,
                             residualScores: [:], rawScores: [:])
        let market = series.last!
        for i in first.bars.indices {
            let m = String(first.bars[i].date.prefix(7))
            if m != month {
                if i > 0 { ends.append(i - 1) }
                month = m
                current = .init(month: m, signalDate: i > 0 ? first.bars[i - 1].date : nil,
                                marketGate: false, residualScores: [:], rawScores: [:])
                if ends.count >= 37 {
                    let e = Array(ends.suffix(37))
                    func returns(_ s: Series) -> [Double] {
                        zip(e, e.dropFirst()).map { s.bars[$1].close / s.bars[$0].close - 1 }
                    }
                    let factor = returns(market)
                    var residual: [String: Double] = [:], raw: [String: Double] = [:]
                    for s in series.dropLast() {
                        let r = returns(s)
                        residual[s.symbol] = try residualScore(asset: r, market: factor)
                        raw[s.symbol] = r[24..<35].reduce(1) { $0 * (1 + $1) } - 1
                    }
                    let gatePrices = ends.suffix(10).map { market.bars[$0].close }
                    current = .init(month: m, signalDate: first.bars[i - 1].date,
                        marketGate: gatePrices.last! > gatePrices.reduce(0, +) / 10,
                        residualScores: residual, rawScores: raw)
                }
            }
            out.append(current)
        }
        return out
    }

    public static func weights(_ review: Review, mode: Int) -> [String: Double] {
        guard review.marketGate else { return [:] }
        if mode == 3 { return Dictionary(uniqueKeysWithValues: SectorMonthstartScreen.symbols.map { ($0, 1.0 / 9) }) }
        let scores = mode == 2 ? review.rawScores : review.residualScores
        let rank = scores.keys.sorted {
            if scores[$0] == scores[$1] { return $0 < $1 }
            return mode == 1 ? scores[$0]! < scores[$1]! : scores[$0]! > scores[$1]!
        }
        return Dictionary(uniqueKeysWithValues: rank.prefix(3).map { ($0, 1.0 / 3) })
    }

    public static func run(pricesPath: String, historyPath: String, outputPath: String,
                           sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        guard input.schema == "sector-residual-observed-v1" else {
            throw BacktestConfigurationError.invalidParameter("sector residual schema")
        }
        let review = try reviews(series: input.series)
        let controls = try IndustryTrendScreen.loadControlSeries(from: history)
        let fx = controls["usd_per_cny"]!
        let days = input.series[0].bars.map(\.date)
        let dates = days.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2008-01-02")!
        let end = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-10-02")!
        guard let first = dates.firstIndex(of: start), first > 0, dates.last == end,
              review[first].residualScores.count == 9 else {
            throw BacktestConfigurationError.missingData("full frozen window and 36-month warmup")
        }
        let conversion = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates, prices: fx.prices, asOf: $0)) }
        let symbols = input.series.map(\.symbol)
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
            allowsFinancedExposure: false, buyReason: "fixed sector residual monthly review")
        let windows = [("full", "2008-01-01", "2026-10-02"),
            ("since2020", "2019-12-30", "2026-10-02"),
            ("since2022", "2021-12-30", "2026-10-02"),
            ("since2025", "2024-12-30", "2026-10-02")]
        let seed = BacktestDailyState(date: start.addingTimeInterval(-86400), targetWeights: [:],
            cash: 100000, holdingsBySymbol: [:], portfolioValue: 100000)
        var rows: [DailyScreenOutput.Row] = [], traces: [String: [[String: Double]]] = [:]
        for (mode, id) in ["sector-residual-top3", "sector-residual-bottom3", "sector-raw-top3",
                           "sector-gated-equal9", "spy-buyhold-open"].enumerated() {
            var submittedMonth: String? = nil
            func desired(_ context: StrategyTargetContext) -> [String: Double] {
                mode == 4 ? ["SPY": 1] : weights(review[context.index], mode: mode)
            }
            guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                provider: .init { desired($0) },
                rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
                contextualRebalanceDecision: { context in
                    let month = review[context.index].month
                    let due = submittedMonth == nil || (mode != 4 && submittedMonth != month)
                    if due { submittedMonth = month }
                    return .init(shouldRebalance: due, refreshOverlay: false)
                }, executionPricesBySymbol: opens) else {
                throw BacktestConfigurationError.missingData(id)
            }
            rows.append(try DailyScreenOutput.row(id, states: [seed] + run.dailyStates,
                                                 trades: run.trades, windows: windows))
            traces[id] = frame.simulationRange.map { mode == 4 ? ["SPY": 1] : weights(review[$0], mode: mode) }
        }
        let gold = controls["gold_cny"]!, nasdaq = controls["nasdaq_composite"]!
        let goldOption = BacktestInstrument(symbol: "gold_cny", title: "gold_cny", requiresHistoricalFX: false, historicalFXSymbol: nil)
        let nasdaqOption = BacktestInstrument(symbol: "nasdaq", title: "nasdaq", requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny", currency: "USD")
        let settings = AdvancedBacktestRiskSettings(feeRate: 0.025, slippageRate: 0,
            maxPositionRatio: 100, cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0)
        guard let baseline = BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(
            assetInputs: [(assetSeries: Optional(gold), assetOption: goldOption, fxSeries: Optional<PublicHistorySeries>.none),
                          (assetSeries: Optional(nasdaq), assetOption: nasdaqOption, fxSeries: Optional(fx))],
            initialCash: 100000, settings: settings, mode: .goldNasdaqDualTrendBarbell,
            dateBounds: start...end) else { throw BacktestConfigurationError.missingData("native reference") }
        rows.append(try DailyScreenOutput.row("gold-nasdaq-dual-trend-barbell",
            states: [seed] + baseline.dailyStates, trades: baseline.report.trades, windows: windows))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence: [String: Any] = ["completed_at": ISO8601DateFormatter().string(from: Date()),
            "evidence_class": "D0_SINGLE_FACTOR_SECTOR_PRICE_ADAPTATION", "formal_validation": false,
            "recommendation_eligible": false, "funded_accounts": 6, "parameter_search_count": 0,
            "source_commit": sourceCommit, "input_sha256": ResearchRunEvidence.sha256(raw),
            "history_sha256": ResearchRunEvidence.sha256(history), "result_sha256": ResearchRunEvidence.sha256(result),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "execution_version": "settlement-v4/next-open/symbol-order-v1", "fee_percent": 0.025,
            "slippage_percent": 0, "cash": "CashYieldCNY", "baseline_execution": "native instruments/current core/close fills; diagnostic reference only"]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try encoder.encode(traces).write(to: output.appendingPathComponent("desired-targets.json"), options: .atomic)
        try encoder.encode(review).write(to: output.appendingPathComponent("reviews.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("Sector residual: fixed candidate and five controls saved.")
    }
}
