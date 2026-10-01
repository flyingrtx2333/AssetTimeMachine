import Foundation
import AssetTimeMachineBacktestCore

/// Regression verification of frozen decision costs; no search or change in validation status.
public enum StrategyCostVerification {
    public static func run(historyPath: String, strategyID: String, macroPath: String? = nil) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let dataset = try PublicBacktestCore.loadDataset(from: data, datasetHash: ResearchRunEvidence.sha256(data), dataStale: false)
        let macro = try macroPath.map { try ResearchRunEvidence.macroSnapshot(from: Data(contentsOf: URL(fileURLWithPath: $0))) }
        let definition = try StrategyRegistry.definition(id: strategyID)
        let input = BacktestRunInput(seriesBySymbol: dataset.seriesBySymbol, nfciAsOf: macro, datasetHash: dataset.datasetHash)
        let fees = [1.0, 0.75, 0.50, 0.25, 0.10, 0.03, 0.0]
        var reference: [BacktestDailyState]?
        print("APP_LOW_NOISE_FEE_SENSITIVITY")
        print("fee_percent,kind,annualized,max_drawdown,volatility,sharpe,trades,average_cash_ratio,target_fingerprint")
        for fee in fees {
            var settings = definition.defaultSettings
            settings.feeRate = fee
            settings.slippageRate = 0.05
            let configuration = BacktestRunConfiguration(strategy: definition.reference, settings: settings)
            let result = try definition.makeRunner().run(input: input, configuration: configuration)
            if let reference {
                guard reference.count == result.dailyStates.count else { throw BacktestConfigurationError.computationFailed }
                for (lhs, rhs) in zip(reference, result.dailyStates) {
                    guard lhs.date == rhs.date, Set(lhs.targetWeights.keys) == Set(rhs.targetWeights.keys),
                          lhs.targetWeights.allSatisfy({ abs($0.value - (rhs.targetWeights[$0.key] ?? -.infinity)) <= 1e-12 }) else {
                        throw BacktestConfigurationError.invalidParameter("execution costs changed frozen targets")
                    }
                }
            } else { reference = result.dailyStates }
            let report = result.report
            print([String(format: "%.2f", fee), "endogenous",
                number(report.annualizedReturn, percent: true), number(report.maxDrawdown, percent: true),
                number(report.annualizedVolatility, percent: true), number(report.sharpeRatio, percent: false),
                String(report.trades.count), number(report.averageCashRatio, percent: false), fingerprint(result.dailyStates)].joined(separator: ","))
        }
    }
    private static func number(_ value: Double?, percent: Bool) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.6f", value * (percent ? 100 : 1))
    }
    private static func fingerprint(_ states: [BacktestDailyState]) -> String {
        var hash: UInt64 = 1469598103934665603
        for state in states {
            for symbol in ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"] {
                var value = UInt64(bitPattern: Int64(((state.targetWeights[symbol] ?? 0) * 1_000_000).rounded()))
                for _ in 0..<8 { hash ^= value & 0xff; hash &*= 1099511628211; value >>= 8 }
            }
        }
        return String(format: "%016llx", hash)
    }
}
