import Foundation
import AssetTimeMachineBacktestCore

/// Post-hoc cash-distribution replay of the unchanged stress decisions.
public enum CrossMarketCashScreen {
    struct Bar: Codable {
        let date: String
        let open: Double; let high: Double; let low: Double; let close: Double; let adjustedClose: Double
    }
    struct Series: Codable { let symbol: String; let bars: [Bar] }
    struct Input: Codable { let schema: String; let series: [Series] }
    struct CashEvent: Codable { let symbol: String; let ex_date: String; let payment_date: String; let amount_usd: Double }
    struct CashInput: Codable { let schema: String; let events: [CashEvent] }

    public static func run(pricesPath: String, historyPath: String, cashPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let cashRaw = try Data(contentsOf: URL(fileURLWithPath: cashPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        let cash = try JSONDecoder().decode(CashInput.self, from: cashRaw)
        guard input.schema == "cross-market-extreme-observed-ohlc-v1",
              input.series.map(\.symbol) == CrossMarketStressScreen.symbols,
              cash.schema == "qqq-issuer-cash-fixed-diagnostic-v1", cash.events.count == 77,
              Set(cash.events.map(\.ex_date)).count == 77,
              cash.events.allSatisfy({ $0.symbol == "QQQ" && $0.ex_date >= "2008-03-03" && $0.ex_date <= "2026-10-02"
                  && $0.payment_date >= $0.ex_date && $0.amount_usd.isFinite && $0.amount_usd > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("frozen stress and issuer cash input")
        }
        let bars = input.series[0].bars, days = bars.map(\.date)
        guard days.last == "2026-10-02", let first = days.firstIndex(of: "2008-03-03"), first >= 252,
              input.series.allSatisfy({ row in row.bars.map(\.date) == days && row.bars.allSatisfy({ b in
                  [b.open,b.high,b.low,b.close,b.adjustedClose].allSatisfy({ $0.isFinite && $0 > 0 })
                      && b.high >= max(b.open,b.close) && b.low <= min(b.open,b.close)
              }) }) else { throw BacktestConfigurationError.missingData("observed ETF OHLC and complete warmup") }
        let schedule = try CrossMarketStressScreen.decisions(days: days, closes: Dictionary(uniqueKeysWithValues:
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
            buyReason: "Unchanged stress rule, issuer cash entitlement after prior close")
        let ids = ["cross-market-extreme-qqq-cash","inverse-stress-control","qqq-buyhold","cny-cash-control"]
        let windows = [("full","2008-03-03"),("since2020","2020-01-01"),
                       ("since2022","2022-01-01"),("since2025","2025-01-01")].map { name,lower in
            (name,days.last(where: { $0 < lower && $0 >= "2008-03-03" }) ?? "2008-03-02","2026-10-02")
        }
        var rows: [DailyScreenOutput.Row] = [], traces: [String:[[String:Double]]] = [:]
        var claims: [String:[BacktestDistributionEntitlement]] = [:]
        for (taxID,tax) in [("gross",0.0),("withhold30",0.3)] {
            let distributions = try cash.events.map { d -> BacktestCashDistribution in
                guard let ex = BacktestSeriesAlignment.historicalSeriesDate(from: d.ex_date),
                      let pay = BacktestSeriesAlignment.historicalSeriesDate(from: d.payment_date) else {
                    throw BacktestConfigurationError.invalidParameter("issuer ex/pay dates")
                }
                return .init(id: "QQQ:" + d.ex_date, symbol: "QQQ", exDate: ex, paymentDate: pay,
                             currencyCode: "USD", amountPerUnit: d.amount_usd, withholdingRate: tax)
            }
            for (mode,baseID) in ids.enumerated() {
                let id = baseID + ":" + taxID
                func target(_ index: Int) -> [String:Double] {
                    let weight = mode == 0 ? schedule[index].weight : mode == 1 ? 1 - schedule[index].weight : mode == 2 ? 1.0 : 0
                    return weight > 0 ? ["QQQ":weight] : [:]
                }
                guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
                    provider: .init { target($0.index) },
                    rebalanceDecision: { _,_ in .init(shouldRebalance: false, refreshOverlay: false) },
                    contextualRebalanceDecision: { context in
                        .init(shouldRebalance: context.index == first || (mode < 2 && schedule[context.index].changed), refreshOverlay: false)
                    }, executionPricesBySymbol: ["QQQ":opens], cashDistributions: distributions,
                    distributionFXToBaseBySymbol: ["QQQ":factors]) else { throw BacktestConfigurationError.missingData(id) }
                let seed = BacktestDailyState(date: dates[first].addingTimeInterval(-86400), targetWeights: [:],
                    cash: 100000, holdingsBySymbol: [:], portfolioValue: 100000)
                rows.append(try DailyScreenOutput.row(id, states: [seed] + run.dailyStates, trades: run.trades, windows: windows))
                traces[id] = frame.simulationRange.map { target($0) }
                claims[id] = run.distributionEntitlements
            }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let result = try encoder.encode(rows), features = try encoder.encode(schedule)
        let evidence: [String:Any] = ["completed_at":ISO8601DateFormatter().string(from: Date()),
            "evidence_class":"POST_HOC_FIXED_RULE_ISSUER_CORPORATE_CASH_DIAGNOSTIC", "formal_validation":false,
            "recommendation_eligible":false, "source_commit":sourceCommit, "candidate_count":1, "run_count":8,
            "parameter_search_count":0,"data_sha256":ResearchRunEvidence.sha256(raw),
            "history_sha256":ResearchRunEvidence.sha256(history), "cash_sha256":ResearchRunEvidence.sha256(cashRaw),
            "result_sha256":ResearchRunEvidence.sha256(result), "features_sha256":ResearchRunEvidence.sha256(features),
            "binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "execution_version":"settlement-v4/dividend-cash-v1/next-open/symbol-order-v1", "fee_percent":0.025,"slippage_percent":0,
            "cash":"CashYieldCNY","maximum_target_gross":1,"withholding_scenarios":[0,0.3],
            "limitations":["Final-vintage adjusted signal inputs preserved; not historical quote/announcement PIT certification.",
                "Gross and uniform30% withholding are diagnostics, not personal tax advice; cash components unknown are preserved in source evidence.",
                "No formal G0-G6 PASS or matched total-return product superiority certification.",
                "Single-asset switch, fractional shares; cash payments credited after first observed session on/after payment date with prior FX.",
                "No funded-period split, no auto reinvestment, no leverage; cash balances accrue only CashYieldCNY."]]
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"),options: .atomic)
        try features.write(to: output.appendingPathComponent("features.json"),options: .atomic)
        try encoder.encode(traces).write(to: output.appendingPathComponent("desired-targets.json"),options: .atomic)
        try encoder.encode(claims).write(to: output.appendingPathComponent("entitlements.json"),options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence,options: [.sortedKeys,.prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"),options: .atomic)
        print("Unchanged stress decisions: eight issuer-cash diagnostic accounts saved.")
    }
}
