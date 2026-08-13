import Foundation

@main
private enum Main {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let country = try JSONDecoder().decode(PublicHistoryResponse.self, from: Data(contentsOf: root.appendingPathComponent("tools/fixtures/backtest-history/asset_agnostic_final_holdout.json")))
        let diagnostic = try JSONDecoder().decode(PublicHistoryResponse.self, from: Data(contentsOf: root.appendingPathComponent("tools/fixtures/backtest-history/generalization_public_history.json")))
        let diagnosticAvailable = Set(diagnostic.series.map(\.symbol))
        let diagnosticSymbols = [["dow_jones","dowjones"],["hang_seng","hsi"],["nikkei225","nikkei"],["shenzhen_component"],["chinext"],["oil_wti_cny"]].compactMap { group in group.first(where: { diagnosticAvailable.contains($0) }) }
        for (name, history, symbols) in [("country", country, country.series.map(\.symbol)), ("diagnostic", diagnostic, diagnosticSymbols)] {
            for (version, config) in [("v1", AssetAgnosticStrategyConfig.frozenV1), ("v2", AssetAgnosticStrategyConfig.frozenV2)] {
                guard let r = AssetAgnosticBacktestEngine.run(history: history, symbols: symbols, config: config) else { continue }
                print(String(format: "%@ %@ | CAGR %.2f%% MDD %.2f%% Sharpe %.3f Vol %.2f%% turnover %.2fx trades %d", name, version, r.performance.annualizedReturn*100, r.performance.maxDrawdown*100, r.performance.sharpeRatio, r.performance.annualizedVolatility*100, r.performance.turnover, r.performance.tradeCount))
            }
        }
    }
}
