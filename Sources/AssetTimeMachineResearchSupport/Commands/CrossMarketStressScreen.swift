import Foundation
import AssetTimeMachineBacktestCore

/// Frozen public extreme-stress rule; independent daily QQQ/CNY cash adaptation.
public enum CrossMarketStressScreen {
    public static let symbols = ["QQQ","SPY","XLI","DBB","IGE","SHY","UUP","GLD","SLV","XLU","FXF","FXA"]
    public static let keys = ["XLI","DBB","IGE","SHY","negative_UUP",
        "negative_GLD_minus_SLV","negative_XLU_minus_XLI","negative_FXF_minus_FXA"]
    public struct Decision: Codable, Equatable {
        public let signalDate: String?
        public let eligible: Bool
        public let weight: Double
        public let changed: Bool
        public let extremes: [String]
        public let current: [Double]
        public let thresholds: [Double]
        public let waitVariable: Int
        public let waitDays: Int
        public let dayCount: Int
        public let outDay: Int
    }
    struct Bar: Codable {
        let date: String
        let open: Double; let high: Double; let low: Double; let close: Double; let adjustedClose: Double
    }
    struct Series: Codable { let symbol: String; let bars: [Bar] }
    struct Input: Codable { let schema: String; let series: [Series] }

    public static func firstPercentile(_ values: [Double]) -> Double {
        precondition(!values.isEmpty && values.allSatisfy(\.isFinite))
        let sorted = values.sorted(), rank = Double(values.count - 1) * 0.01
        let lower = Int(floor(rank)), upper = Int(ceil(rank))
        return sorted[lower] + (rank - Double(lower)) * (sorted[upper] - sorted[lower])
    }
    public static func nextWait(previous: Int, flip: Bool) -> Int {
        Int(max(0.5 * Double(previous), Double(15 * (flip ? 15 : 1))))
    }

    public static func decisions(days: [String], closes: [String:[Double]]) throws -> [Decision] {
        guard days.count >= 253, zip(days,days.dropFirst()).allSatisfy({ $0 < $1 }),
              days.allSatisfy({ BacktestSeriesAlignment.historicalSeriesDate(from: $0) != nil }),
              Set(closes.keys) == Set(symbols), closes.values.allSatisfy({ prices in
                  prices.count == days.count && prices.allSatisfy({ $0.isFinite && $0 > 0 })
              }) else { throw BacktestConfigurationError.missingData("complete observed cross-market signal quotes") }
        var returns: [String:[Double]] = [:]
        for symbol in symbols {
            let prices = closes[symbol]!
            var values = Array(repeating: 0.0, count: days.count)
            for j in 65..<days.count {
                let base = (55...65).reduce(0.0) { $0 + prices[j - $1] } / 11
                values[j] = prices[j] / base - 1
            }
            returns[symbol] = values
        }
        func features(_ j: Int) -> [Double] {
            [returns["XLI"]![j],returns["DBB"]![j],returns["IGE"]![j],returns["SHY"]![j],-returns["UUP"]![j],
             -(returns["GLD"]![j] - returns["SLV"]![j]),
             -(returns["XLU"]![j] - returns["XLI"]![j]),
             -(returns["FXF"]![j] - returns["FXA"]![j])]
        }
        var inMarket = true, wait = 15, dayCount = 0, outDay = 0, previousWeight = 0.0
        var output: [Decision] = []
        for i in days.indices {
            guard i >= 252 else {
                output.append(.init(signalDate: i > 0 ? days[i - 1] : nil, eligible: false,
                    weight: 0, changed: false, extremes: [], current: [], thresholds: [],
                    waitVariable: wait, waitDays: min(60,wait), dayCount: dayCount, outDay: outDay))
                continue
            }
            // A fresh 252-row historical table discards its first 65 unavailable shifted rows.
            // Signal day is i-1. Every base price lies inside that already known table.
            let sample = ((i - 252 + 65)..<i).map(features)
            let current = sample.last!
            let thresholds = keys.indices.map { k in firstPercentile(sample.map { $0[k] }) }
            let extremes = keys.indices.filter { current[$0] < thresholds[$0] }.map { keys[$0] }
            let flip = [("GLD","SLV"),("XLU","XLI"),("FXF","FXA")].contains { safe, risk in
                returns[safe]![i - 1] > 0 && returns[risk]![i - 1] < 0 && returns[risk]![i - 2] > 0
            }
            wait = nextWait(previous: wait, flip: flip)
            if !extremes.isEmpty { inMarket = false; outDay = dayCount }
            if dayCount >= outDay + min(60,wait) { inMarket = true }
            let weight = inMarket ? 1.0 : 0
            output.append(.init(signalDate: days[i - 1], eligible: true, weight: weight,
                changed: weight != previousWeight, extremes: extremes, current: current, thresholds: thresholds,
                waitVariable: wait, waitDays: min(60,wait), dayCount: dayCount, outDay: outDay))
            previousWeight = weight; dayCount += 1
        }
        return output
    }

    public static func run(pricesPath: String, historyPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        guard input.schema == "cross-market-extreme-observed-ohlc-v1", input.series.map(\.symbol) == symbols else {
            throw BacktestConfigurationError.invalidParameter("frozen cross-market input")
        }
        let bars = input.series[0].bars, days = bars.map(\.date)
        guard days.last == "2026-10-02", let first = days.firstIndex(of: "2008-03-03"), first >= 252,
              input.series.allSatisfy({ row in row.bars.map(\.date) == days && row.bars.allSatisfy({ b in
                  [b.open,b.high,b.low,b.close,b.adjustedClose].allSatisfy({ $0.isFinite && $0 > 0 })
                      && b.high >= max(b.open,b.close) && b.low <= min(b.open,b.close)
              }) }) else { throw BacktestConfigurationError.missingData("observed ETF OHLC and complete warmup") }
        let schedule = try decisions(days: days, closes: Dictionary(uniqueKeysWithValues:
            input.series.map { ($0.symbol,$0.bars.map(\.adjustedClose)) }))
        guard let fx = try IndustryTrendScreen.loadControlSeries(from: history)["usd_per_cny"] else {
            throw BacktestConfigurationError.missingData("historical FX")
        }
        let factors = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates, prices: fx.prices, asOf: $0)) }
        let dates = days.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        let closes = zip(bars,factors).map { $0.close * $1 }, opens = zip(bars,factors).map { $0.open * $1 }
        let instrument = BacktestInstrument(symbol: "QQQ", title: "QQQ", requiresHistoricalFX: false, historicalFXSymbol: nil)
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: ["QQQ":closes],
            observedBySymbol: ["QQQ":Array(repeating: true,count: days.count)], ohlcBySymbol: [:],
            tradableSymbols: ["QQQ"], optionBySymbol: ["QQQ":instrument], simulationRange: first...(days.count - 1))
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025,
            slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false,
            buyReason: "Frozen cross-market stress / prior observed close to next real open")
        let ids = ["cross-market-extreme-qqq-cash","inverse-stress-control","qqq-buyhold","cny-cash-control"]
        let windows = [("full","2008-03-03"),("since2020","2020-01-01"),
                       ("since2022","2022-01-01"),("since2025","2025-01-01")].map { name,lower in
            (name,days.last(where: { $0 < lower && $0 >= "2008-03-03" }) ?? "2008-03-02","2026-10-02")
        }
        var rows: [DailyScreenOutput.Row] = [], traces: [String:[[String:Double]]] = [:]
        for (mode,id) in ids.enumerated() {
            func target(_ index: Int) -> [String:Double] {
                let weight = mode == 0 ? schedule[index].weight : mode == 1 ? 1 - schedule[index].weight : mode == 2 ? 1.0 : 0
                return weight > 0 ? ["QQQ":weight] : [:]
            }
            guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                provider: .init { target($0.index) },
                rebalanceDecision: { _,_ in .init(shouldRebalance: false, refreshOverlay: false) },
                contextualRebalanceDecision: { context in
                    .init(shouldRebalance: context.index == first || (mode < 2 && schedule[context.index].changed), refreshOverlay: false)
                }, executionPricesBySymbol: ["QQQ":opens]) else { throw BacktestConfigurationError.missingData(id) }
            let seed = BacktestDailyState(date: dates[first].addingTimeInterval(-86400), targetWeights: [:],
                cash: 100000, holdingsBySymbol: [:], portfolioValue: 100000)
            rows.append(try DailyScreenOutput.row(id, states: [seed] + run.dailyStates, trades: run.trades, windows: windows))
            traces[id] = frame.simulationRange.map { target($0) }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence: [String:Any] = ["completed_at":ISO8601DateFormatter().string(from: Date()),
            "evidence_class":"D0_RETROSPECTIVE_PUBLIC_RULE_CNY_ADAPTATION", "formal_validation":false,
            "recommendation_eligible":false, "source_commit":sourceCommit, "candidate_count":1, "run_count":4,
            "parameter_search_count":0,"data_sha256":ResearchRunEvidence.sha256(raw),
            "history_sha256":ResearchRunEvidence.sha256(history),"result_sha256":ResearchRunEvidence.sha256(result),
            "binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "execution_version":"settlement-v4/next-open/symbol-order-v1", "fee_percent":0.025,"slippage_percent":0,
            "cash":"CashYieldCNY","maximum_target_gross":1,"feature_keys":keys,
            "history_sessions":252,"reference_shifts":Array(55...65),"percentile":1,"wait_initial":15,"wait_cap":60,
            "adaptations":["CNY cash replaces TLT/IEF","Daily next-open re-entry replaces Friday intraday re-entry", "Warmup state carried into funded period"],
            "limitations":["Current adjusted signals, price-only account; original numeric quote vintage not certified.",
                "No pristine OOS or formal G0-G6 PASS; no superiority claim from selected slices.",
                "Signal-only ETFs do not enter holdings; no leverage, crypto, cash proxy or implicit bond income.",
                "Single-asset binary switch; hold units between target changes, not daily maintenance."]]
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"),options: .atomic)
        try encoder.encode(schedule).write(to: output.appendingPathComponent("features.json"),options: .atomic)
        try encoder.encode(traces).write(to: output.appendingPathComponent("desired-targets.json"),options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence,options: [.sortedKeys,.prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"),options: .atomic)
        print("Cross-market stress: frozen candidate and three controls saved.")
    }
}
