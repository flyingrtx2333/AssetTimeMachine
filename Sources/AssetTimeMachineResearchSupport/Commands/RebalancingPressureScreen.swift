import Foundation
import AssetTimeMachineBacktestCore

/// One frozen ETF, long-only adaptation of Harvey/Mazzoleni/Melone (2025-12-15).
/// Virtual stock/bond weights measure pressure; they are never funded holdings.
public enum RebalancingPressureScreen {
    public struct Point: Codable, Equatable {
        public let drift: Double
        public var longWeight: Double { min(1, max(0, -drift / 0.015)) }
        public var oppositeWeight: Double { min(1, max(0, drift / 0.015)) }
    }
    struct Bar: Codable {
        let date: String
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let dividend: Double
    }
    struct Series: Codable { let symbol: String; let bars: [Bar] }
    struct Input: Codable { let schema: String; let series: [Series] }

    /// At each close observe total returns, record drift, then reset breached
    /// virtual weights for the NEXT session. No current/next open enters signals.
    /// This explicit ETF reset convention is an adaptation, not literal B.1 replay.
    public static func features(equity: [Double], equityDividends: [Double],
                                bonds: [Double], bondDividends: [Double]) throws -> [Point] {
        guard equity.count > 1, [equityDividends.count, bonds.count, bondDividends.count]
            .allSatisfy({ $0 == equity.count }),
            (equity + bonds).allSatisfy({ $0.isFinite && $0 > 0 }),
            (equityDividends + bondDividends).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw BacktestConfigurationError.invalidParameter("rebalancing signal observations")
        }
        var virtual = Array(repeating: 0.6, count: 26)
        var out = [Point(drift: 0)]
        for i in 1..<equity.count {
            let stockGrowth = (equity[i] + equityDividends[i]) / equity[i - 1]
            let bondGrowth = (bonds[i] + bondDividends[i]) / bonds[i - 1]
            var totalDrift = 0.0
            for j in virtual.indices {
                let stock = virtual[j] * stockGrowth
                let weight = stock / (stock + (1 - virtual[j]) * bondGrowth)
                let drift = weight - 0.6
                totalDrift += drift
                virtual[j] = abs(drift) >= Double(j) * 0.001 ? 0.6 : weight
            }
            out.append(.init(drift: totalDrift / 26))
        }
        return out
    }

    public static func run(pricesPath: String, historyPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        guard input.schema == "rebalancing-session-dividend-v1",
              input.series.map(\.symbol) == ["SPY", "IEF", "QQQ"] else {
            throw BacktestConfigurationError.invalidParameter("frozen pressure instruments")
        }
        let days = input.series[0].bars.map(\.date)
        guard days.first == "2003-01-02", days.last == "2026-10-02",
              zip(days, days.dropFirst()).allSatisfy({ $0 < $1 }),
              input.series.allSatisfy({ s in
                  s.bars.map(\.date) == days && s.bars.allSatisfy({ b in
                      BacktestSeriesAlignment.historicalSeriesDate(from: b.date) != nil
                          && [b.open, b.high, b.low, b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                          && b.high >= max(b.open, b.close) && b.low <= min(b.open, b.close)
                          && b.dividend.isFinite && b.dividend >= 0
                  })
              }), let first = days.firstIndex(of: "2005-01-03") else {
            throw BacktestConfigurationError.missingData("matched real session OHLC")
        }
        let spy = input.series[0].bars, bonds = input.series[1].bars
        let points = try features(equity: spy.map(\.close), equityDividends: spy.map(\.dividend),
            bonds: bonds.map(\.close), bondDividends: bonds.map(\.dividend))
        let controls = try IndustryTrendScreen.loadControlSeries(from: history)
        let fx = controls["usd_per_cny"]!
        let conversion = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates, prices: fx.prices, asOf: $0)) }
        let held = input.series.filter { $0.symbol != "IEF" }
        let symbols = held.map(\.symbol)
        let dates = days.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        let closes = Dictionary(uniqueKeysWithValues: held.map { s in
            (s.symbol, zip(s.bars, conversion).map { $0.close * $1 })
        })
        let opens = Dictionary(uniqueKeysWithValues: held.map { s in
            (s.symbol, zip(s.bars, conversion).map { $0.open * $1 })
        })
        let options = Dictionary(uniqueKeysWithValues: symbols.map {
            ($0, BacktestInstrument(symbol: $0, title: $0, requiresHistoricalFX: false, historicalFXSymbol: nil))
        })
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: closes,
            observedBySymbol: Dictionary(uniqueKeysWithValues: symbols.map { ($0, Array(repeating: true, count: days.count)) }),
            ohlcBySymbol: [:], tradableSymbols: symbols, optionBySymbol: options,
            simulationRange: first...(days.count - 1))
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025,
            slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0,
            allowsFinancedExposure: false, buyReason: "frozen stock/bond rebalancing pressure")
        let ids = ["qqq-pressure-long", "qqq-pressure-opposite", "qqq-fixed-half",
                   "qqq-buyhold", "spy-pressure-transfer-control", "cny-cash-control"]
        let windows = [("full", "2005-01-03"), ("since2020", "2020-01-01"),
                       ("since2022", "2022-01-01"), ("since2025", "2025-01-01")].map { name, lower in
            (name, days.last(where: { $0 < lower && $0 >= "2005-01-03" }) ?? "2005-01-02", "2026-10-02")
        }
        var rows: [DailyScreenOutput.Row] = [], traces: [String: [[String: Double]]] = [:]
        for (mode, id) in ids.enumerated() {
            var lastSubmitted: [String: Double]? = nil
            func desired(_ context: StrategyTargetContext) -> [String: Double] {
                let p = points[context.signalIndex]
                let weight = mode == 1 ? p.oppositeWeight : mode == 2 ? 0.5
                    : mode == 3 ? 1 : mode == 5 ? 0 : p.longWeight
                return weight > 0 ? [mode == 4 ? "SPY" : "QQQ": weight] : [:]
            }
            guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                provider: .init { desired($0) },
                rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
                contextualRebalanceDecision: { context in
                    let w = desired(context), changed = mode == 2 || lastSubmitted == nil || lastSubmitted != w
                    if changed { lastSubmitted = w }
                    return .init(shouldRebalance: changed, refreshOverlay: false)
                }, executionPricesBySymbol: opens) else { throw BacktestConfigurationError.missingData(id) }
            let seed = BacktestDailyState(date: dates[first].addingTimeInterval(-86400), targetWeights: [:],
                cash: 100000, holdingsBySymbol: [:], portfolioValue: 100000)
            rows.append(try DailyScreenOutput.row(id, states: [seed] + run.dailyStates,
                trades: run.trades, windows: windows))
            traces[id] = frame.simulationRange.map { index in
                let weight = mode == 1 ? points[index - 1].oppositeWeight : mode == 2 ? 0.5
                    : mode == 3 ? 1 : mode == 5 ? 0 : points[index - 1].longWeight
                return weight > 0 ? [mode == 4 ? "SPY" : "QQQ": weight] : [:]
            }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence: [String: Any] = ["evidence_class": "D0_THRESHOLD_ONLY_ETF_LONG_ONLY_ADAPTATION",
            "formal_validation": false, "recommendation_eligible": false,
            "source": "https://afajof.org/management/viewp.php?n=144452", "source_version": "2025-12-15",
            "source_commit": sourceCommit, "run_count": 6, "parameter_search_count": 0,
            "data_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": ResearchRunEvidence.sha256(history),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "result_sha256": ResearchRunEvidence.sha256(result),
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "execution_version": "settlement-v4/next-open/symbol-order-v1", "fee_percent": 0.025,
            "slippage_percent": 0, "cash": "CashYieldCNY", "maximum_target_gross": 1,
            "signal_scale": 0.015, "virtual_thresholds": (0...25).map { Double($0) * 0.001 },
            "fx_policy": "strict-prior-calendar-date/max14days/same-factor-open-close",
            "limitations": ["ETF ex-date total-return SIGNALS; all funded accounts PRICE ONLY, no dividend cash.",
                "Explicit after-close virtual reset; no calendar leg, shorts, futures or IEF funded holding.",
                "QQQ transfer of SPY/IEF pressure is an unvalidated hypothesis, not author replication.",
                "Pinned author scale was calibrated in exposed history; not pristine OOS.",
                "No separate USD wallet, FX conversion fees, auction capacity or tax modelling.",
                "Cash control Sharpe is not economically informative; full seed includes no first-day cash interest."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try encoder.encode(traces).write(to: output.appendingPathComponent("desired-targets.json"), options: .atomic)
        try encoder.encode(points).write(to: output.appendingPathComponent("features.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("Rebalancing pressure: fixed QQQ candidate and five controls saved.")
    }
}
