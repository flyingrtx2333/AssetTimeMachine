import Foundation
import AssetTimeMachineBacktestCore

/// A fixed published-rule replay. This command never adds a product strategy
/// or certifies source revisions, tax treatment, or prospective performance.
public enum HAACashScreen {
    private struct Distribution: Decodable {
        let symbol: String
        let ex_date: String
        let payment_date: String
        let amount_usd: Double
    }
    private struct Split: Decodable {
        let symbol: String
        let effective_date: String
        let new_units_per_old_unit: Double
    }
    private struct Input: Decodable {
        let schema: String
        let series: [SectorMonthstartScreen.Series]
        let distributions: [Distribution]
        let splits: [Split]
    }
    public struct Signal: Codable {
        public let executionDate: String
        public let signalDate: String
        public let momentum: [String: Double]
        public let selected: String
    }

    /// Signal-only total return: gross ex-date cash and effective share splits.
    /// This index does not simulate funded reinvestment or pretend cash is paid
    /// on the ex-date. Every update uses events effective on that date only.
    public static func totalReturnIndex(dates: [String], closes: [Double],
                                        distributionsByDate: [String: Double],
                                        splitRatiosByDate: [String: Double]) throws -> [Double] {
        guard dates.count == closes.count, dates.count > 13,
              zip(dates, dates.dropFirst()).allSatisfy({ $0 < $1 }),
              closes.allSatisfy({ $0.isFinite && $0 > 0 }),
              distributionsByDate.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              splitRatiosByDate.values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("HAA signal observations")
        }
        var index = Array(repeating: 100.0, count: dates.count)
        for i in 1..<dates.count {
            index[i] = index[i - 1] * (closes[i] + (distributionsByDate[dates[i]] ?? 0))
                * (splitRatiosByDate[dates[i]] ?? 1) / closes[i - 1]
        }
        return index
    }

    public static func signals(dates: [String], indicesBySymbol: [String: [Double]]) throws -> [Signal] {
        let symbols = ["SPY", "BIL", "IEF", "TIP"]
        guard symbols.allSatisfy({ indicesBySymbol[$0]?.count == dates.count }),
              dates.count > 13, zip(dates, dates.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw BacktestConfigurationError.invalidParameter("HAA four aligned signal series")
        }
        var completedMonthEnds: [Int] = [], result: [Signal] = []
        for i in 1..<dates.count where dates[i].prefix(7) != dates[i - 1].prefix(7) {
            completedMonthEnds.append(i - 1)
            guard completedMonthEnds.count >= 13 else { continue }
            let current = completedMonthEnds.count - 1
            var momentum: [String: Double] = [:]
            for symbol in symbols {
                let values = indicesBySymbol[symbol]!
                guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                    throw BacktestConfigurationError.invalidParameter("HAA finite total return")
                }
                momentum[symbol] = [1, 3, 6, 12].reduce(0.0) {
                    $0 + (values[completedMonthEnds[current]] / values[completedMonthEnds[current - $1]] - 1) / 4
                }
            }
            let defensive = momentum["BIL"]! >= momentum["IEF"]! ? "BIL" : "IEF"
            let selected = momentum["TIP"]! > 0 && momentum["SPY"]! > 0 ? "SPY" : defensive
            result.append(.init(executionDate: dates[i], signalDate: dates[i - 1], momentum: momentum, selected: selected))
        }
        return result
    }

    public static func run(pricesPath: String, historyPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        let symbols = ["SPY", "BIL", "IEF", "TIP"]
        guard input.schema == "haa-corporate-cash-v1", input.series.map(\.symbol) == symbols else {
            throw BacktestConfigurationError.invalidParameter("HAA frozen asset universe")
        }
        let days = input.series[0].bars.map(\.date)
        guard days.first == "2007-05-30", days.last == "2026-10-02",
              input.series.allSatisfy({ series in series.bars.map(\.date) == days && series.bars.allSatisfy({ b in
                  [b.open, b.high, b.low, b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                  && b.high >= max(b.open, b.close) && b.low <= min(b.open, b.close)
              }) }), let first = days.firstIndex(of: "2008-07-01"),
              let fx = try IndustryTrendScreen.loadControlSeries(from: history)["usd_per_cny"] else {
            throw BacktestConfigurationError.missingData("HAA full observed quotes/strict prior FX")
        }
        let dates = try days.map { day -> Date in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: day) else {
                throw BacktestConfigurationError.invalidParameter("HAA date \(day)")
            }
            return date
        }
        let conversion = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates, prices: fx.prices, asOf: $0)) }
        var signalIndices: [String: [Double]] = [:]
        for series in input.series {
            let dividends = input.distributions.filter { $0.symbol == series.symbol }
            let splits = input.splits.filter { $0.symbol == series.symbol }
            guard Set(dividends.map(\.ex_date)).count == dividends.count,
                  Set(splits.map(\.effective_date)).count == splits.count else {
                throw BacktestConfigurationError.invalidParameter("duplicate HAA corporate action")
            }
            signalIndices[series.symbol] = try totalReturnIndex(dates: days, closes: series.bars.map(\.close),
                distributionsByDate: Dictionary(uniqueKeysWithValues: dividends.map { ($0.ex_date, $0.amount_usd) }),
                splitRatiosByDate: Dictionary(uniqueKeysWithValues: splits.map { ($0.effective_date, $0.new_units_per_old_unit) }))
        }
        let schedule = try signals(dates: days, indicesBySymbol: signalIndices)
        guard schedule.first?.executionDate == days[first] else {
            throw BacktestConfigurationError.missingData("HAA thirteen completed month closes")
        }
        let signalByDate = Dictionary(uniqueKeysWithValues: schedule.map { ($0.executionDate, $0) })
        let tradable = ["SPY", "BIL", "IEF"]
        let options = Dictionary(uniqueKeysWithValues: tradable.map {
            ($0, BacktestInstrument(symbol: $0, title: $0, requiresHistoricalFX: false, historicalFXSymbol: nil))
        })
        let closes = Dictionary(uniqueKeysWithValues: input.series.filter { tradable.contains($0.symbol) }.map {
            ($0.symbol, zip($0.bars, conversion).map { $0.close * $1 })
        })
        let opens = Dictionary(uniqueKeysWithValues: input.series.filter { tradable.contains($0.symbol) }.map {
            ($0.symbol, zip($0.bars, conversion).map { $0.open * $1 })
        })
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: closes,
            observedBySymbol: Dictionary(uniqueKeysWithValues: tradable.map { ($0, Array(repeating: true, count: dates.count)) }),
            ohlcBySymbol: [:], tradableSymbols: tradable, optionBySymbol: options, simulationRange: first...(days.count - 1))
        let execution = BacktestExecutionConfig(initialCash: 100_000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "HAA frozen next-open target")
        let splits = try input.splits.map { split -> BacktestShareSplit in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: split.effective_date) else {
                throw BacktestConfigurationError.invalidParameter("HAA split date")
            }
            return .init(id: split.symbol + ":" + split.effective_date, symbol: split.symbol,
                         effectiveDate: date, newUnitsPerOldUnit: split.new_units_per_old_unit)
        }
        let windows = [("full", "2008-06-30", "2026-10-02"), ("since2020", "2019-12-30", "2026-10-02"),
                       ("since2022", "2021-12-30", "2026-10-02"), ("after_paper_2023_03_06", "2023-03-06", "2026-10-02"),
                       ("since2025", "2024-12-30", "2026-10-02")]
        let seed = BacktestDailyState(date: dates[first - 1], targetWeights: [:], cash: 100_000,
                                     holdingsBySymbol: [:], portfolioValue: 100_000)
        var rows: [DailyScreenOutput.Row] = [], entitlements: [String: [BacktestDistributionEntitlement]] = [:]
        var splitEvidence: [String: [BacktestSplitAdjustment]] = [:]
        for (taxID, tax) in [("gross", 0.0), ("withhold30", 0.3)] {
            let dividends = try input.distributions.filter { tradable.contains($0.symbol) && $0.ex_date >= days[first] }.map {
                d -> BacktestCashDistribution in
                guard let exDate = BacktestSeriesAlignment.historicalSeriesDate(from: d.ex_date),
                      let paymentDate = BacktestSeriesAlignment.historicalSeriesDate(from: d.payment_date),
                      d.payment_date >= d.ex_date else {
                    throw BacktestConfigurationError.invalidParameter("HAA funded cash date")
                }
                return .init(id: d.symbol + ":" + d.ex_date, symbol: d.symbol, exDate: exDate, paymentDate: paymentDate,
                             currencyCode: "USD", amountPerUnit: d.amount_usd, withholdingRate: tax)
            }
            for mode in 0..<4 {
                let id = ["haa-simple", "spy-monthly", "spy60-ief40-monthly", "cny-cash"][mode] + ":" + taxID
                guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                    provider: .init { context in
                        if mode == 3 { return [:] }
                        if mode == 2 { return ["SPY": 0.6, "IEF": 0.4] }
                        if mode == 1 { return ["SPY": 1] }
                        return signalByDate[days[context.index]].map { [$0.selected: 1] } ?? [:]
                    }, rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
                    contextualRebalanceDecision: { context in
                        .init(shouldRebalance: signalByDate[days[context.index]] != nil, refreshOverlay: false)
                    }, executionPricesBySymbol: opens,
                    cashDistributions: dividends,
                    distributionFXToBaseBySymbol: Dictionary(uniqueKeysWithValues: tradable.map { ($0, conversion) }),
                    shareSplits: splits) else { throw BacktestConfigurationError.missingData(id) }
                rows.append(try DailyScreenOutput.row(id, states: [seed] + run.dailyStates, trades: run.trades, windows: windows))
                entitlements[id] = run.distributionEntitlements
                splitEvidence[id] = run.splitAdjustments
            }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(rows), signalsData = try encoder.encode(schedule)
        let evidence: [String: Any] = ["completed_at": ISO8601DateFormatter().string(from: Date()), "source_commit": sourceCommit,
            "evidence_class": "D0_PUBLISHED_HAA_NEXT_OPEN_CORPORATE_CASH_REPLAY", "formal_validation": false,
            "recommendation_eligible": false, "funded_accounts": 8, "primary_candidates": 1, "parameter_searches": 0,
            "fee_percent": 0.025, "slippage_percent": 0, "withholding_scenarios": [0, 0.3],
            "execution_version": "settlement-v4/dividend-cash-v1/share-split-v1/next-open/symbol-order-v1",
            "signal_currency": "USD", "portfolio_currency": "CNY", "cash": "CashYieldCNY", "financing": false,
            "result_sha256": ResearchRunEvidence.sha256(result), "signals_sha256": ResearchRunEvidence.sha256(signalsData),
            "input_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": ResearchRunEvidence.sha256(history),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "limitations": ["Issuer/provider cash fact discrepancies require independent resolution; exploratory figures only.",
                "Final-vintage inputs, fractional units, conservative end-pay-session FX conversion; no personal tax certification.",
                "Paper same-close execution adapted to next-open with sale settlement and idle CNY cash.",
                "Existing-best product rules require matched actual-ETF total-return replay before an outperformance claim."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try signalsData.write(to: output.appendingPathComponent("signals.json"), options: .atomic)
        try encoder.encode(entitlements).write(to: output.appendingPathComponent("entitlements.json"), options: .atomic)
        try encoder.encode(splitEvidence).write(to: output.appendingPathComponent("split-adjustments.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("HAA published-rule replay saved: one rule, two cash-tax scenarios, explicit controls.")
    }
}
