import Foundation
import AssetTimeMachineBacktestCore

/// An explicit instrument/clock adaptation of a benchmark, never product parity.
public enum StressBarbellETFComparison {
    struct Bar: Codable { let date: String; let open: Double; let high: Double; let low: Double; let close: Double; let adjustedClose: Double }
    struct Series: Codable { let symbol: String; let bars: [Bar] }
    struct Input: Codable { let schema: String; let series: [Series] }
    struct CashEvent: Codable { let symbol: String; let ex_date: String; let payment_date: String; let amount_usd: Double }
    struct CashInput: Codable { let schema: String; let events: [CashEvent] }
    struct Decision: Codable {
        let index: Int; let date: Date; let signalDate: Date; let proposed: [String: Double]; let shouldRebalance: Bool
    }
    public static func run(pricesPath: String, historyPath: String, cashPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let cashRaw = try Data(contentsOf: URL(fileURLWithPath: cashPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        let cash = try JSONDecoder().decode(CashInput.self, from: cashRaw)
        guard input.schema == "stress-barbell-etf-frozen-observed-v1", input.series.map(\.symbol) == ["GLD","QQQ"],
              cash.schema == "qqq-issuer-cash-fixed-diagnostic-v1", cash.events.count == 77 else {
            throw BacktestConfigurationError.invalidParameter("fixed ETF benchmark inputs")
        }
        let days = input.series[0].bars.map(\.date), parameters = GoldNasdaqBarbellParameters.frozenV1
        guard days.last == "2026-10-02", let first = days.firstIndex(of: "2008-03-03"), first >= parameters.warmupSessions,
              zip(days,days.dropFirst()).allSatisfy({ $0 < $1 }),
              input.series.allSatisfy({ row in row.bars.map(\.date) == days && row.bars.allSatisfy({ b in
                  [b.open,b.high,b.low,b.close,b.adjustedClose].allSatisfy({ $0.isFinite && $0 > 0 })
                      && b.high >= max(b.open,b.close) && b.low <= min(b.open,b.close)
              }) }), let fx = try IndustryTrendScreen.loadControlSeries(from: history)["usd_per_cny"] else {
            throw BacktestConfigurationError.missingData("ETF warmup/calendar/FX")
        }
        let factors = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates, prices: fx.prices, asOf: $0)) }
        let dates = days.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        let closes = Dictionary(uniqueKeysWithValues: input.series.map { row in (row.symbol,zip(row.bars,factors).map { $0.close * $1 }) })
        let opens = Dictionary(uniqueKeysWithValues: input.series.map { row in (row.symbol,zip(row.bars,factors).map { $0.open * $1 }) })
        let options = Dictionary(uniqueKeysWithValues: ["GLD","QQQ"].map { ($0,BacktestInstrument(symbol: $0,title: $0,requiresHistoricalFX: false,historicalFXSymbol: nil)) })
        let frame = MarketDataFrame(dates: dates,pricesBySymbol: closes,
            observedBySymbol: Dictionary(uniqueKeysWithValues: ["GLD","QQQ"].map { ($0,Array(repeating:true,count:days.count)) }),
            ohlcBySymbol: [:],tradableSymbols:["GLD","QQQ"],optionBySymbol:options,simulationRange:first...(days.count-1))
        let execution = BacktestExecutionConfig(initialCash:100000,feeRate:0.00025,slippageRate:0,
            rebalanceBand:parameters.rebalanceBand,financingAnnualRate:0,allowsFinancedExposure:false,
            buyReason:"Frozen gold/Nasdaq barbell ETF benchmark adaptation")
        func target(_ index: Int) -> [String:Double] {
            let native = GoldNasdaqBarbellStrategy.frozenTargetWeights(goldPrices:closes["GLD"]!,nasdaqPrices:closes["QQQ"]!,signalIndex:index-1)
            return ["GLD":native["gold_cny"] ?? 0,"QQQ":native["nasdaq"] ?? 0].filter { $0.value > 0 }
        }
        let windows = [("full","2008-03-03"),("since2020","2020-01-01"),
                       ("since2022","2022-01-01"),("since2025","2025-01-01")].map { name,lower in
            (name,days.last(where:{ $0 < lower && $0 >= "2008-03-03" }) ?? "2008-03-02","2026-10-02")
        }
        var rows:[DailyScreenOutput.Row]=[],claims:[String:[BacktestDistributionEntitlement]]=[:]
        var decisions:[String:[Decision]]=[:],completions:[String:[Int]]=[:]
        for (taxID,tax) in [("gross",0.0),("withhold30",0.3)] {
            let id = "barbell-gld-qqq-adaptation:" + taxID
            let distributions = try cash.events.map { d -> BacktestCashDistribution in
                guard d.symbol == "QQQ", d.ex_date >= "2008-03-03",d.ex_date <= "2026-10-02",d.payment_date >= d.ex_date,
                      let ex = BacktestSeriesAlignment.historicalSeriesDate(from:d.ex_date),
                      let pay = BacktestSeriesAlignment.historicalSeriesDate(from:d.payment_date) else {
                    throw BacktestConfigurationError.invalidParameter("issuer benchmark cash date")
                }
                return .init(id:"QQQ:"+d.ex_date,symbol:"QQQ",exDate:ex,paymentDate:pay,currencyCode:"USD",amountPerUnit:d.amount_usd,withholdingRate:tax)
            }
            var lastCompleted = Int.min/2, trace:[Decision]=[],completed:[Int]=[]
            guard let run = BacktestDailySimulator.run(frame:frame,execution:execution,
                provider:.init { target($0.index) },rebalanceDecision:{ _,_ in .init(shouldRebalance:false,refreshOverlay:false) },
                contextualRebalanceDecision:{ context in
                    let due = context.index == first || (context.index > first && context.index-lastCompleted >= parameters.rebalanceSessions)
                    trace.append(.init(index:context.index,date:context.date,signalDate:context.signalDate,proposed:target(context.index),shouldRebalance:due))
                    return .init(shouldRebalance:due,refreshOverlay:false)
                },didExecuteTarget:{ lastCompleted=$0;completed.append($0) },executionPricesBySymbol:opens,
                cashDistributions:distributions,distributionFXToBaseBySymbol:["QQQ":factors]) else {
                throw BacktestConfigurationError.missingData(id)
            }
            let seed = BacktestDailyState(date:dates[first].addingTimeInterval(-86400),targetWeights:[:],cash:100000,holdingsBySymbol:[:],portfolioValue:100000)
            rows.append(try DailyScreenOutput.row(id,states:[seed]+run.dailyStates,trades:run.trades,windows:windows))
            claims[id]=run.distributionEntitlements;decisions[id]=trace;completions[id]=completed
        }
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let result = try encoder.encode(rows)
        let evidence:[String:Any]=["completed_at":ISO8601DateFormatter().string(from:Date()),"source_commit":sourceCommit,
            "evidence_class":"POSTHOC_ETF_BENCHMARK_ADAPTATION_NOT_PRODUCT_PARITY","formal_validation":false,
            "new_economic_candidates":0,"funded_benchmark_accounts":2,"parameter_searches":0,
            "input_sha256":ResearchRunEvidence.sha256(raw),"history_sha256":ResearchRunEvidence.sha256(history),"cash_sha256":ResearchRunEvidence.sha256(cashRaw),
            "result_sha256":ResearchRunEvidence.sha256(result),"binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]))),
            "parameters":String(decoding:try encoder.encode(parameters),as:UTF8.self),"fee_percent":0.025,"slippage_percent":0,
            "execution_version":"settlement-v4/dividend-cash-v1/next-open/symbol-order-v1","cash":"CashYieldCNY",
            "limitations":["GLD/QQQ ETF/CNY signal and next-open benchmark adaptation; not original App source/clock parity.",
                "Complete existing six-product total-return frontier, final-vintage PIT, untouched OOS and formal G0-G6 not certified.",
                "QQQ cash gross/uniform30% diagnostics only; no capital-gain/FX tax estimates."]]
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try result.write(to:output.appendingPathComponent("result.json"))
        try encoder.encode(claims).write(to:output.appendingPathComponent("entitlements.json"))
        try encoder.encode(decisions).write(to:output.appendingPathComponent("decisions.json"))
        try encoder.encode(completions).write(to:output.appendingPathComponent("completions.json"))
        try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("evidence.json"))
        print("Two frozen GLD/QQQ barbell benchmark accounts saved; no product parity claim.")
    }
}
