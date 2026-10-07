import Foundation
import AssetTimeMachineBacktestCore

/// Funded verification stage; unchanged OLMAR predictions, actual v4 settlement.
public enum OLMARFundedScreen {
    private struct Input: Decodable { let schema: String; let series: [SectorMonthstartScreen.Series] }
    public static func run(pricesPath: String,historyPath: String,outputPath: String,sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let input = try JSONDecoder().decode(Input.self,from: raw)
        guard input.schema == "sector-residual-observed-v1",
              input.series.map(\.symbol) == SectorMonthstartScreen.symbols + ["SPY"] else {
            throw BacktestConfigurationError.invalidParameter("OLMAR unchanged sector basket and actual SPY")
        }
        let sectors = Array(input.series.dropLast()), forecasts = try OLMARPredictionScreen.forecasts(series: sectors)
        let days = sectors[0].bars.map(\.date), dates = days.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        guard let first = days.firstIndex(of: "2003-01-10"), days.last == "2026-10-02",
              input.series.last!.bars.map(\.date) == days,
              input.series.last!.bars.allSatisfy({ b in [b.open,b.high,b.low,b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                  && b.high >= max(b.open,b.close) && b.low <= min(b.open,b.close) }),
              let fx = try IndustryTrendScreen.loadControlSeries(from: history)["usd_per_cny"] else {
            throw BacktestConfigurationError.missingData("OLMAR actual control quotes/FX")
        }
        let conversion = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates,prices: fx.prices,asOf: $0)) }
        let symbols = input.series.map(\.symbol)
        let options = Dictionary(uniqueKeysWithValues: symbols.map {
            ($0,BacktestInstrument(symbol: $0,title: $0,requiresHistoricalFX: false,historicalFXSymbol: nil))
        })
        let closes = Dictionary(uniqueKeysWithValues: input.series.map { s in (s.symbol,zip(s.bars,conversion).map { $0.close*$1 }) })
        let opens = Dictionary(uniqueKeysWithValues: input.series.map { s in (s.symbol,zip(s.bars,conversion).map { $0.open*$1 }) })
        let frame = MarketDataFrame(dates: dates,pricesBySymbol: closes,
            observedBySymbol: Dictionary(uniqueKeysWithValues: symbols.map { ($0,Array(repeating: true,count: dates.count)) }),
            ohlcBySymbol: [:],tradableSymbols: symbols,optionBySymbol: options,simulationRange: first...(days.count-1))
        let execution = BacktestExecutionConfig(initialCash: 100000,feeRate: 0.00025,slippageRate: 0,
            rebalanceBand: 0,financingAnnualRate: 0,allowsFinancedExposure: false,buyReason: "OLMAR frozen next-open desired weights / settled cash only")
        let ids = ["olmar-sectors-next-open","sector-equal9-daily","sector-equal9-buyhold","spy-buyhold","cny-cash"]
        let windows = [("full","2003-01-09","2026-10-02"),("since2020","2019-12-30","2026-10-02"),
                       ("since2022","2021-12-30","2026-10-02"),("since2025","2024-12-30","2026-10-02")]
        let seed = BacktestDailyState(date: dates[first].addingTimeInterval(-86400),targetWeights: [:],
            cash: 100000,holdingsBySymbol: [:],portfolioValue: 100000)
        var rows: [DailyScreenOutput.Row] = [], targets: [String:[[String:Double]]] = [:]
        for (mode,id) in ids.enumerated() {
            func desired(_ i: Int) -> [String:Double] {
                if mode == 4 { return [:] }
                if mode == 3 { return ["SPY":1] }
                let weights = mode == 0 ? forecasts[i].weights : Array(repeating: 1.0/9,count: 9)
                return Dictionary(uniqueKeysWithValues: zip(SectorMonthstartScreen.symbols,weights).filter { $0.1 > 0 })
            }
            guard let run = BacktestDailySimulator.run(frame: frame,execution: execution,provider: .init { desired($0.index) },
                rebalanceDecision: { _,_ in .init(shouldRebalance: false,refreshOverlay: false) },
                contextualRebalanceDecision: { context in .init(shouldRebalance: mode <= 1 || context.index == first,refreshOverlay: false) },
                executionPricesBySymbol: opens) else { throw BacktestConfigurationError.missingData(id) }
            rows.append(try DailyScreenOutput.row(id,states: [seed]+run.dailyStates,trades: run.trades,windows: windows))
            targets[id] = frame.simulationRange.map(desired)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let result = try encoder.encode(rows), predictions = try encoder.encode(forecasts)
        let evidence: [String:Any] = ["completed_at":ISO8601DateFormatter().string(from: Date()),"source_commit":sourceCommit,
            "evidence_class":"D0_OLMAR_REAL_OPEN_SETTLEMENT_ADAPTATION","formal_validation":false,"recommendation_eligible":false,
            "funded_accounts":5,"primary_candidates":1,"parameter_searches":0,"fee_percent":0.025,"slippage_percent":0,
            "execution_version":"settlement-v4/next-open/symbol-order-v1","cash":"CashYieldCNY","financing":false,
            "result_sha256":ResearchRunEvidence.sha256(result),"predictions_sha256":ResearchRunEvidence.sha256(predictions),
            "input_sha256":ResearchRunEvidence.sha256(raw),"history_sha256":ResearchRunEvidence.sha256(history),
            "binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "limitations":["Actual v4 settled-cash fills differ from ideal paper weights; accepted and completed holdings audited separately.",
                "Model targets refresh daily, controls have explicit daily-maintenance or initial-only intent.",
                "Price-only ETF signals and accounts, distributions omitted; corrected quotes not original PIT vintages.",
                "Predictive gate was marginal nominal evidence, not multiple-testing certification or pristine OOS."]]
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"),options: .atomic)
        try predictions.write(to: output.appendingPathComponent("predictions.json"),options: .atomic)
        try encoder.encode(targets).write(to: output.appendingPathComponent("desired-targets.json"),options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence,options: [.sortedKeys,.prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"),options: .atomic)
        print("OLMAR same-rule actual capital verification saved: one candidate, four controls.")
    }
}
