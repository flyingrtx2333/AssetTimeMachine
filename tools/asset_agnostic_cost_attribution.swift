import Foundation

@main
private enum AssetAgnosticCostAttributionMain {
    static func main() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tools/fixtures/backtest-history/asset_agnostic_final_holdout_v3.json")
        let history = try JSONDecoder().decode(PublicHistoryResponse.self, from: Data(contentsOf: url))
        let symbols = history.series.map(\.symbol)
        let frozen = AssetAgnosticStrategyConfig.frozenV3
        let variants: [(String, AssetAgnosticStrategyConfig)] = [
            ("production_cost", frozen),
            ("zero_cost", AssetAgnosticStrategyConfig(
                warmupSessions: frozen.warmupSessions,
                reviewSessions: frozen.reviewSessions,
                shortMomentumSessions: frozen.shortMomentumSessions,
                mediumMomentumSessions: frozen.mediumMomentumSessions,
                longMomentumSessions: frozen.longMomentumSessions,
                trendMASessions: frozen.trendMASessions,
                volatilitySessions: frozen.volatilitySessions,
                covarianceSessions: frozen.covarianceSessions,
                targetAnnualizedVolatility: frozen.targetAnnualizedVolatility,
                maxAssetWeight: frozen.maxAssetWeight,
                maxAssets: frozen.maxAssets,
                rebalanceBand: frozen.rebalanceBand,
                targetTurnoverThreshold: frozen.targetTurnoverThreshold,
                feeRate: 0,
                slippageRate: 0
            )),
        ]
        for (name, config) in variants {
            guard let result = AssetAgnosticBacktestEngine.runSparseV3(history: history, symbols: symbols, config: config) else { continue }
            let p = result.performance
            print(String(format: "%@ CAGR %.2f%% MDD %.2f%% Sharpe %.3f Vol %.2f%% turnover %.2fx trades %d", name, p.annualizedReturn*100, p.maxDrawdown*100, p.sharpeRatio, p.annualizedVolatility*100, p.turnover, p.tradeCount))
        }
    }
}
