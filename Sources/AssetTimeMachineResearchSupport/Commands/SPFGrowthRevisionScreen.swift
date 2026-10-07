import Foundation
import AssetTimeMachineBacktestCore

/// Independent, frozen SPF same-target-quarter revision hypothesis.
/// Official dated releases do not certify the downloaded original numeric vintage.
public enum SPFGrowthRevisionScreen {
    public struct Survey: Codable {
        public let year: Int
        public let quarter: Int
        public let releaseDate: String
        public let deadlineDate: String
        public let currentGrowth: Double
        public let nextGrowth: Double
        public init(year: Int, quarter: Int, releaseDate: String, deadlineDate: String,
                    currentGrowth: Double, nextGrowth: Double) {
            self.year = year; self.quarter = quarter; self.releaseDate = releaseDate
            self.deadlineDate = deadlineDate; self.currentGrowth = currentGrowth; self.nextGrowth = nextGrowth
        }
    }
    public struct Decision: Codable, Equatable {
        public let surveyIndex: Int?
        public let releaseDate: String?
        public let revisionPP: Double?
        public let weight: Double
        public let changed: Bool
    }
    struct Bar: Codable { let date: String; let open: Double; let high: Double; let low: Double; let close: Double }
    struct Series: Codable { let symbol: String; let bars: [Bar] }
    struct Input: Codable { let schema: String; let series: [Series]; let surveys: [Survey] }

    public static func decisions(days: [String], surveys: [Survey], inverse: Bool = false) throws -> [Decision] {
        guard !days.isEmpty, surveys.count >= 2,
              days.allSatisfy({ BacktestSeriesAlignment.historicalSeriesDate(from: $0) != nil }),
              zip(days, days.dropFirst()).allSatisfy({ $0 < $1 }),
              surveys.allSatisfy({ (1900...2100).contains($0.year) && (1...4).contains($0.quarter)
                  && $0.currentGrowth.isFinite && $0.nextGrowth.isFinite
                  && BacktestSeriesAlignment.historicalSeriesDate(from: $0.releaseDate) != nil
                  && BacktestSeriesAlignment.historicalSeriesDate(from: $0.deadlineDate) != nil
                  && $0.deadlineDate <= $0.releaseDate }),
              zip(surveys, surveys.dropFirst()).allSatisfy({ previous, current in
                  current.year * 4 + current.quarter == previous.year * 4 + previous.quarter + 1
                      && previous.releaseDate < current.releaseDate
              }) else { throw BacktestConfigurationError.missingData("adjacent SPF surveys and real release dates") }
        var cursor = 0
        var weight = 0.0
        var latestIndex: Int? = nil
        var revision: Double? = nil
        return days.map { day in
            let previousWeight = weight
            while cursor < surveys.count && surveys[cursor].releaseDate < day {
                if cursor > 0 {
                    // current quarter of NEW survey == next quarter of OLD survey.
                    let value = surveys[cursor].currentGrowth - surveys[cursor - 1].nextGrowth
                    revision = value; latestIndex = cursor
                    if value != 0 { weight = (inverse ? value < 0 : value > 0) ? 1 : 0 }
                }
                cursor += 1
            }
            return .init(surveyIndex: latestIndex, releaseDate: latestIndex.map { surveys[$0].releaseDate },
                         revisionPP: revision, weight: weight, changed: weight != previousWeight)
        }
    }

    public static func run(pricesPath: String, historyPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        guard input.schema == "spf-growth-revision-observed-ohlc-v1", input.series.map(\.symbol) == ["SPY"],
              input.surveys.count == 91, input.surveys.first?.year == 2004,
              input.surveys.last?.year == 2026, input.surveys.last?.quarter == 3 else {
            throw BacktestConfigurationError.invalidParameter("frozen SPF input")
        }
        let bars = input.series[0].bars, days = bars.map(\.date)
        guard days.first == "2003-01-02", days.last == "2026-10-02",
              let first = days.firstIndex(of: "2005-01-03"), bars.allSatisfy({ b in
                  [b.open,b.high,b.low,b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                      && b.high >= max(b.open,b.close) && b.low <= min(b.open,b.close)
              }) else { throw BacktestConfigurationError.missingData("observed SPY OHLC") }
        let schedules = try [false,true].map { try decisions(days: days, surveys: input.surveys, inverse: $0) }
        let fx = try IndustryTrendScreen.loadControlSeries(from: history)["usd_per_cny"]!
        let factors = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates, prices: fx.prices, asOf: $0)) }
        let dates = days.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        let closes = zip(bars,factors).map { $0.close * $1 }, opens = zip(bars,factors).map { $0.open * $1 }
        let instrument = BacktestInstrument(symbol: "SPY", title: "SPY", requiresHistoricalFX: false, historicalFXSymbol: nil)
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: ["SPY":closes],
            observedBySymbol: ["SPY":Array(repeating: true, count: days.count)],
            ohlcBySymbol: [:], tradableSymbols: ["SPY"], optionBySymbol: ["SPY":instrument],
            simulationRange: first...(days.count - 1))
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025,
            slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0,
            allowsFinancedExposure: false, buyReason: "SPF same-quarter growth revision / public-day next-open")
        let ids = ["spf-growth-revision-positive", "spf-growth-revision-negative-control", "spy-buyhold", "cny-cash-control"]
        let windows = [("full","2005-01-03"),("since2020","2020-01-01"),
                       ("since2022","2022-01-01"),("since2025","2025-01-01")].map { name, lower in
            (name, days.last(where: { $0 < lower && $0 >= "2005-01-03" }) ?? "2005-01-02", "2026-10-02")
        }
        var rows: [DailyScreenOutput.Row] = [], traces: [String:[[String:Double]]] = [:]
        for (mode,id) in ids.enumerated() {
            func target(_ index: Int) -> [String:Double] {
                let weight = mode < 2 ? schedules[mode][index].weight : mode == 2 ? 1.0 : 0
                return weight > 0 ? ["SPY":weight] : [:]
            }
            guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                provider: .init { target($0.index) },
                rebalanceDecision: { _,_ in .init(shouldRebalance: false, refreshOverlay: false) },
                contextualRebalanceDecision: { context in
                    .init(shouldRebalance: context.index == first || (mode < 2 && schedules[mode][context.index].changed),
                          refreshOverlay: false)
                }, executionPricesBySymbol: ["SPY":opens]) else { throw BacktestConfigurationError.missingData(id) }
            let seed = BacktestDailyState(date: dates[first].addingTimeInterval(-86400), targetWeights: [:],
                cash: 100000, holdingsBySymbol: [:], portfolioValue: 100000)
            rows.append(try DailyScreenOutput.row(id, states: [seed] + run.dailyStates, trades: run.trades, windows: windows))
            traces[id] = frame.simulationRange.map { target($0) }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence: [String:Any] = ["completed_at":ISO8601DateFormatter().string(from: Date()),
            "evidence_class":"D0_SPF_PUBLIC_DATED_REVISION_CNY_ADAPTATION", "formal_validation":false,
            "recommendation_eligible":false, "source_commit":sourceCommit, "candidate_count":1, "run_count":4,
            "parameter_search_count":0, "data_sha256":ResearchRunEvidence.sha256(raw),
            "history_sha256":ResearchRunEvidence.sha256(history), "result_sha256":ResearchRunEvidence.sha256(result),
            "binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "execution_version":"settlement-v4/next-open/symbol-order-v1", "fee_percent":0.025, "slippage_percent":0,
            "cash":"CashYieldCNY", "maximum_target_gross":1, "signal":"new DRGDP2 minus adjacent previous DRGDP3",
            "clock":"first observed SPY session strictly after official news release date; never deadline",
            "limitations":["Independent hypothesis, not a replication of FEDS2024-049 or GDPNow.",
                "Corrected current SPF numeric vintage, original-release errata not certified; intraday release times unknown.",
                "Survey panel changes and 2025Q4 projected historical jump-off values retained.",
                "SPY PRICE ONLY; dividends omitted, retrospective quotes; prior-day FX, no FX costs or tax model.",
                "No pristine OOS or formal G0-G6 pass; slice performance does not establish a superior current strategy.",
                "Single symbol binary entry/exit, hold units between state changes; not daily weight maintenance."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try encoder.encode(schedules).write(to: output.appendingPathComponent("features.json"), options: .atomic)
        try encoder.encode(traces).write(to: output.appendingPathComponent("desired-targets.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys,.prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("SPF growth revision: one frozen candidate and three controls saved.")
    }
}
