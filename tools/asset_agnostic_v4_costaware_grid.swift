import Foundation

private struct DevSet {
    let name: String
    let history: PublicHistoryResponse
    let symbols: [String]
}

private struct Row {
    let config: AssetAgnosticStrategyConfig
    let results: [(String, AssetAgnosticBacktestResult)]
    var worstSharpe: Double { results.map { $0.1.performance.sharpeRatio }.min() ?? -.infinity }
    var worstMDD: Double { results.map { $0.1.performance.maxDrawdown }.max() ?? .infinity }
    var worstCAGR: Double { results.map { $0.1.performance.annualizedReturn }.min() ?? -.infinity }
    var turnover: Double { results.reduce(0) { $0 + $1.1.performance.turnover } }
    var score: Double { worstSharpe - 1.5 * max(worstMDD - 0.25, 0) - 0.001 * turnover }
}

@main
private enum Main {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let h1 = try load(root.appendingPathComponent("tools/fixtures/backtest-history/asset_agnostic_final_holdout.json"))
        let h2 = try load(root.appendingPathComponent("tools/fixtures/backtest-history/asset_agnostic_final_holdout_v3.json"))
        let hd = try load(root.appendingPathComponent("tools/fixtures/backtest-history/generalization_public_history.json"))
        let available = Set(hd.series.map(\.symbol))
        let ds = [["dow_jones","dowjones"],["hang_seng","hsi"],["nikkei225","nikkei"],["shenzhen_component"],["chinext"],["oil_wti_cny"]].compactMap { $0.first(where: { available.contains($0) }) }
        let sets = [
            DevSet(name: "country_v2", history: h1, symbols: h1.series.map(\.symbol)),
            DevSet(name: "country_v3", history: h2, symbols: h2.series.map(\.symbol)),
            DevSet(name: "diagnostic", history: hd, symbols: ds),
        ]

        var rows: [Row] = []
        for review in [42, 63, 84, 105] {
            for targetVol in [0.075, 0.09] {
                for band in [0.42, 0.55, 0.68] {
                    for threshold in [0.24, 0.36, 0.48] {
                        let c = AssetAgnosticStrategyConfig(
                            warmupSessions: 252,
                            reviewSessions: review,
                            shortMomentumSessions: 63,
                            mediumMomentumSessions: 126,
                            longMomentumSessions: 252,
                            trendMASessions: 200,
                            volatilitySessions: 63,
                            covarianceSessions: 63,
                            targetAnnualizedVolatility: targetVol,
                            maxAssetWeight: 0.20,
                            maxAssets: 8,
                            rebalanceBand: band,
                            targetTurnoverThreshold: threshold,
                            feeRate: 0.01,
                            slippageRate: 0.0005
                        )
                        let results = sets.compactMap { set -> (String, AssetAgnosticBacktestResult)? in
                            guard let r = AssetAgnosticBacktestEngine.runSparseV3(history: set.history, symbols: set.symbols, config: c) else { return nil }
                            return (set.name, r)
                        }
                        if results.count == sets.count { rows.append(.init(config: c, results: results)) }
                    }
                }
            }
        }
        let ranked = rows.sorted {
            if abs($0.score - $1.score) > 1e-12 { return $0.score > $1.score }
            if abs($0.worstSharpe - $1.worstSharpe) > 1e-12 { return $0.worstSharpe > $1.worstSharpe }
            return $0.turnover < $1.turnover
        }
        print("V4_COST_AWARE_GRID candidates=\(ranked.count)")
        for (rank, row) in ranked.prefix(20).enumerated() {
            let c = row.config
            let detail = row.results.map { name, r in
                String(format: "%@ S %.3f MDD %.2f%% CAGR %.2f%% turn %.2fx", name, r.performance.sharpeRatio, r.performance.maxDrawdown*100, r.performance.annualizedReturn*100, r.performance.turnover)
            }.joined(separator: " | ")
            print(String(format: "#%02d score %.3f review %d vol %.3f band %.2f threshold %.2f | worstS %.3f worstMDD %.2f%% worstCAGR %.2f%% totalTurn %.2fx | %@", rank+1, row.score, c.reviewSessions, c.targetAnnualizedVolatility, c.rebalanceBand, c.targetTurnoverThreshold, row.worstSharpe, row.worstMDD*100, row.worstCAGR*100, row.turnover, detail))
        }
    }

    private static func load(_ url: URL) throws -> PublicHistoryResponse {
        try JSONDecoder().decode(PublicHistoryResponse.self, from: Data(contentsOf: url))
    }
}
