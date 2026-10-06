import Foundation
import AssetTimeMachineBacktestCore

/// Frozen price-only, sector-breadth adaptation of MarketMind 0.1.0 MII-Light.
/// Research only: no product registry or production strategy is modified.
public enum MarketMindLightScreen {
    public struct Point: Codable, Equatable {
        public let score: Double?
        public let trend: Double
        public let reversal: Double
        public let breakout: Double
        public var category: Int? {
            guard let score else { return nil }
            return score > 0.7 ? 0 : score < 0.3 ? 1 : 2
        }
        public var unconditional: Double { (trend + reversal + breakout) / 3 }
        public func weight(category: Int?) -> Double {
            guard let category else { return 0 }
            return category == 0 ? trend : category == 1 ? reversal : breakout
        }
    }

    static func ema(_ values: [Double?], alpha: Double, minimum: Int = 1) -> [Double?] {
        var state: Double?, count = 0
        return values.map { value in
            if let value {
                state = state.map { (1 - alpha) * $0 + alpha * value } ?? value
                count += 1
            }
            return count >= minimum ? state : nil
        }
    }

    static func mean(_ values: [Double?], window: Int) -> [Double?] {
        var sum = 0.0, count = 0
        return values.indices.map { i in
            if let v = values[i] { sum += v; count += 1 }
            if i >= window, let v = values[i - window] { sum -= v; count -= 1 }
            return count == window ? sum / Double(window) : nil
        }
    }

    public static func features(bars: [SPYSessionInput.Bar], sectorCloses: [[Double]]) throws -> [Point] {
        guard bars.count >= 257, sectorCloses.count == 9,
              zip(bars, bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
              bars.allSatisfy({ [ $0.open, $0.high, $0.low, $0.close ].allSatisfy({ $0.isFinite && $0 > 0 })
                  && $0.high >= max($0.open, $0.close) && $0.low <= min($0.open, $0.close) }),
              sectorCloses.allSatisfy({ $0.count == bars.count && $0.allSatisfy({ $0.isFinite && $0 > 0 }) }) else {
            throw BacktestConfigurationError.invalidParameter("MII-Light matched observations")
        }
        let close = bars.map(\.close), n = bars.count
        let prices = close.map(Optional.some)
        let e20 = ema(prices, alpha: 2.0 / 21), e100 = ema(prices, alpha: 2.0 / 101)
        let e100Ready = ema(prices, alpha: 2.0 / 101, minimum: 100)
        let m20 = mean(prices, window: 20), m50 = mean(prices, window: 50)
        let m100 = mean(prices, window: 100), m200 = mean(prices, window: 200)
        let differential = close.indices.map { e20[$0]! / e100[$0]! - 1 }
        let slope: [Double?] = close.indices.map { $0 >= 5 ? (differential[$0] - differential[$0 - 5]) / 5 : nil }
        let slopeMean = mean(slope, window: 252)
        let differences: [Double?] = close.indices.map { $0 > 0 ? close[$0] - close[$0 - 1] : nil }
        let gain = ema(differences.map { $0.map { max($0, 0) } }, alpha: 1.0 / 14, minimum: 14)
        let loss = ema(differences.map { $0.map { max(-$0, 0) } }, alpha: 1.0 / 14, minimum: 14)
        let absMean = mean(differences.map { $0.map(abs) }, window: 14)
        let volatility: [Double?] = close.indices.map { i in absMean[i].map { $0 / close[i] } }
        let trueRange: [Double?] = bars.indices.map { i in
            max(bars[i].high - bars[i].low, i > 0 ? max(abs(bars[i].high - close[i - 1]), abs(bars[i].low - close[i - 1])) : 0)
        }
        let atr = ema(trueRange, alpha: 1.0 / 14, minimum: 14)
        let atrMean = mean(atr, window: 20)
        let sectorMeans = sectorCloses.map { mean($0.map(Optional.some), window: 50) }
        let breadth: [Double?] = close.indices.map { i in
            guard sectorMeans.allSatisfy({ $0[i] != nil }) else { return nil }
            return Double(sectorCloses.indices.filter { sectorCloses[$0][i] > sectorMeans[$0][i]! }.count) / 9
        }
        let breadthEMA = ema(breadth, alpha: 2.0 / 6)
        var rsiHeld = false, bandHeld = false, channelHeld = false
        var points: [Point] = []
        points.reserveCapacity(n)
        for i in close.indices {
            var score: Double?
            if let center = slopeMean[i], i >= 256, let vol = volatility[i], let breadth = breadthEMA[i] {
                let samples = slope[(i - 251)...i].compactMap { $0 }
                let sd = sqrt(samples.reduce(0) { $0 + pow($1 - center, 2) } / 251)
                let priorVol = volatility[(i - 62)...i].compactMap { $0 }
                if sd > 0, samples.count == 252, priorVol.count == 63 {
                    let z = (slope[i]! - center) / sd
                    let trendScore = 0.5 * erfc(-z / sqrt(2))
                    let less = priorVol.filter { $0 < vol }.count
                    let equal = priorVol.filter { $0 == vol }.count
                    let rank = (Double(less) + (Double(equal) + 1) / 2) / 63
                    score = min(1, max(0, 0.4 * trendScore + 0.3 * (1 - rank) + 0.3 * breadth))
                }
            }
            if let g = gain[i], let l = loss[i] {
                let rsi = l == 0 ? 100 : 100 - 100 / (1 + g / l)
                if !rsiHeld && rsi < 30 { rsiHeld = true }
                else if rsiHeld && rsi > 50 { rsiHeld = false }
            }
            if let center = m20[i] {
                let sd = sqrt(close[(i - 19)...i].reduce(0) { $0 + pow($1 - center, 2) } / 19)
                if !bandHeld && close[i] <= center - 2 * sd { bandHeld = true }
                else if bandHeld && close[i] >= center { bandHeld = false }
            }
            var breaksOut = false
            if i >= 20 {
                let prior = close[(i - 20)..<i]
                breaksOut = close[i] > prior.max()!
                if !channelHeld && breaksOut { channelHeld = true }
                else if channelHeld && close[i] < prior.min()! { channelHeld = false }
            }
            let threeDown = i >= 3 && close[i] < close[i - 1] && close[i - 1] < close[i - 2] && close[i - 2] < close[i - 3]
            let trendFlags = [m200[i] != nil && m50[i]! > m200[i]!,
                              i >= 104 && m100[i]! > m100[i - 5]!,
                              e100Ready[i] != nil && close[i] > e100Ready[i]!]
            let expansion = atrMean[i] != nil && atr[i]! > 1.5 * atrMean[i]!
            points.append(.init(score: score,
                trend: Double(trendFlags.filter { $0 }.count) / 3,
                reversal: Double([rsiHeld, bandHeld, threeDown].filter { $0 }.count) / 3,
                breakout: Double([breaksOut, channelHeld, expansion].filter { $0 }.count) / 3))
        }
        return points
    }

    public static func run(spyPath: String, sectorsPath: String, historyPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let spy = try Data(contentsOf: URL(fileURLWithPath: spyPath))
        let sectors = try Data(contentsOf: URL(fileURLWithPath: sectorsPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2008-01-02")!
        let end = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-08-20")!
        let input = try SPYSessionInput(raw: spy, history: history, start: start, end: end)
        struct SectorInput: Decodable { let schema: String; let series: [SectorMonthstartScreen.Series] }
        let sectorInput = try JSONDecoder().decode(SectorInput.self, from: sectors)
        guard sectorInput.schema == "sector-session-price-v1" else {
            // Accept the existing explicitly versioned nine-sector input only.
            throw BacktestConfigurationError.invalidParameter("sector schema")
        }
        guard sectorInput.series.map(\.symbol) == SectorMonthstartScreen.symbols else {
            throw BacktestConfigurationError.invalidParameter("fixed sector breadth basket")
        }
        let days = sessionDays(input.bars.map(\.date))
        let closes = try sectorInput.series.map { series -> [Double] in
            guard Set(series.bars.map(\.date)).count == series.bars.count,
                  zip(series.bars, series.bars.dropFirst()).allSatisfy({ $0.date < $1.date }) else {
                throw BacktestConfigurationError.invalidParameter("sector dates")
            }
            let byDate = Dictionary(uniqueKeysWithValues: series.bars.map { ($0.date, $0.close) })
            return try days.map { day in
                guard let value = byDate[day] else { throw BacktestConfigurationError.missingData("sector breadth \(day)") }
                return value
            }
        }
        let points = try features(bars: input.bars, sectorCloses: closes)
        let ranges = [("full", "2008-01-02"), ("since2020", "2020-01-01"),
                      ("since2022", "2022-01-01"), ("since2025", "2025-01-01")]
        let windows = ranges.map { name, lower -> (String, String, String) in
            let anchor = days.last(where: { $0 < lower && $0 >= "2008-01-02" }) ?? "2008-01-01"
            return (name, anchor, "2026-08-20")
        }
        let seed = BacktestDailyState(date: start.addingTimeInterval(-86400), targetWeights: [:],
            cash: 100000, holdingsBySymbol: [:], portfolioValue: 100000)
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025,
            slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0,
            allowsFinancedExposure: false, buyReason: "fixed MII-Light family selector")
        var rows: [DailyScreenOutput.Row] = [], traces: [String: [Double]] = [:]
        let ids = ["mii-light-sector-family", "mii-unconditional-nine", "mii-state-lag21",
                   "mii-wrong-family", "spy-buyhold-open"]
        for (mode, id) in ids.enumerated() {
            let weights = points.indices.map { i -> Double in
                if mode == 4 { return 1 }
                guard points[i].score != nil else { return 0 }
                if mode == 1 { return points[i].unconditional }
                let category = mode == 2 ? (i >= 21 ? points[i - 21].category : nil)
                    : mode == 3 ? points[i].category.map { ($0 + 1) % 3 } : points[i].category
                return points[i].weight(category: category)
            }
            var submitted: Double?
            func desired(_ context: StrategyTargetContext) -> Double {
                context.index > input.first ? weights[context.signalIndex] : 0
            }
            guard let run = BacktestDailySimulator.run(frame: input.frame, execution: execution,
                provider: .init { c in let w = desired(c); return w > 0 ? ["SPY": w] : [:] },
                rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
                contextualRebalanceDecision: { context in
                    let w = desired(context), changed = submitted == nil || submitted != w
                    if changed { submitted = w }
                    return .init(shouldRebalance: changed, refreshOverlay: false)
                }, executionPricesBySymbol: ["SPY": input.opens]) else {
                throw BacktestConfigurationError.missingData(id)
            }
            rows.append(try DailyScreenOutput.row(id, states: [seed] + run.dailyStates, trades: run.trades, windows: windows))
            traces[id] = input.frame.simulationRange.map { $0 > input.first ? weights[$0 - 1] : 0 }
        }
        let baseline = try StrategyRegistry.definition(id: "gold-nasdaq-dual-trend-barbell")
        let control = try baseline.run(input: .init(seriesBySymbol: input.dataset.seriesBySymbol,
            datasetHash: input.dataset.datasetHash, sourceCommit: sourceCommit),
            configuration: .init(strategy: baseline.reference, purpose: .research,
                settings: .init(feeRate: 0.025, slippageRate: 0, maxPositionRatio: 100,
                    cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0),
                evaluationRange: .init(startDate: start, endDate: end)))
        rows.append(try DailyScreenOutput.row(baseline.reference.id, states: [seed] + control.dailyStates,
            trades: control.report.trades, windows: windows))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence: [String: Any] = ["completed_at": ISO8601DateFormatter().string(from: Date()),
            "evidence_class": "D0_PRICE_ONLY_SECTOR_BREADTH_MII_LIGHT_ADAPTATION",
            "formal_validation": false, "recommendation_eligible": false, "account_runs": 6,
            "parameter_search_count": 0, "source_commit": sourceCommit,
            "signal_version": "author0.1.0-light-cdf-sector-sma50-v1",
            "execution_version": "settlement-v4/next-open/symbol-order-v1",
            "spy_sha256": ResearchRunEvidence.sha256(spy), "sector_sha256": ResearchRunEvidence.sha256(sectors),
            "history_sha256": ResearchRunEvidence.sha256(history), "result_sha256": ResearchRunEvidence.sha256(result),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "cash": "CashYieldCNY", "fee_percent": 0.025, "slippage_percent": 0,
            "limitations": ["No dividends; software CDF/close-volatility and sector breadth adaptations, not exact paper/fullMII.",
                "Archive through2026-08-20; no pristineOOS; native benchmark uses different quotes/FX/fill clocks.",
                "Fixed .3/.7 thresholds; no full-dataset-length-dependent warmup or return-based selection."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try encoder.encode(points).write(to: output.appendingPathComponent("features.json"), options: .atomic)
        try encoder.encode(traces).write(to: output.appendingPathComponent("desired-targets.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("MII-Light fixed sector proxy: one candidate, five controls saved.")
    }

    static func sessionDays(_ dates: [Date]) -> [String] {
        let formatter = DateFormatter()
        formatter.timeZone = BacktestSeriesAlignment.historicalSeriesCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return dates.map { formatter.string(from: $0) }
    }
}
