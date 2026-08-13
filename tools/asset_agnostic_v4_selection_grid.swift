import Foundation

private struct DevSet {
    let name: String
    let history: PublicHistoryResponse
    let symbols: [String]
}

private struct CandidateResult {
    let config: AssetAgnosticStrategyConfig
    let results: [(String, AssetAgnosticBacktestResult)]

    var worstSharpe: Double { results.map { $0.1.performance.sharpeRatio }.min() ?? -.infinity }
    var worstDrawdown: Double { results.map { $0.1.performance.maxDrawdown }.max() ?? .infinity }
    var worstCAGR: Double { results.map { $0.1.performance.annualizedReturn }.min() ?? -.infinity }
    var totalTurnover: Double { results.reduce(0.0) { $0 + $1.1.performance.turnover } }
    var score: Double {
        worstSharpe
            + 0.20 * min(worstCAGR, 0.08)
            - 2.0 * max(worstDrawdown - 0.22, 0)
            - 0.001 * totalTurnover
    }
}

@main
private enum AssetAgnosticV4SelectionGridMain {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let country1 = try load(root.appendingPathComponent("tools/fixtures/backtest-history/asset_agnostic_final_holdout.json"))
        let country2 = try load(root.appendingPathComponent("tools/fixtures/backtest-history/asset_agnostic_final_holdout_v3.json"))
        let diagnostic = try load(root.appendingPathComponent("tools/fixtures/backtest-history/generalization_public_history.json"))
        let diagnosticAvailable = Set(diagnostic.series.map(\.symbol))
        let diagnosticSymbols = [["dow_jones","dowjones"],["hang_seng","hsi"],["nikkei225","nikkei"],["shenzhen_component"],["chinext"],["oil_wti_cny"]]
            .compactMap { group in group.first(where: { diagnosticAvailable.contains($0) }) }
        let sets = [
            DevSet(name: "country_v2", history: country1, symbols: country1.series.map(\.symbol)),
            DevSet(name: "country_v3", history: country2, symbols: country2.series.map(\.symbol)),
            DevSet(name: "diagnostic", history: diagnostic, symbols: diagnosticSymbols),
        ]

        var candidates: [CandidateResult] = []
        for targetVol in [0.075, 0.09, 0.105] {
            for maxAssets in [3, 4, 5, 6, 8] {
                for maxAsset in [0.25, 0.40] {
                    for band in [0.35, 0.42, 0.49] {
                        let config = AssetAgnosticStrategyConfig(
                            warmupSessions: 252,
                            reviewSessions: 42,
                            shortMomentumSessions: 63,
                            mediumMomentumSessions: 126,
                            longMomentumSessions: 252,
                            trendMASessions: 200,
                            volatilitySessions: 63,
                            covarianceSessions: 63,
                            targetAnnualizedVolatility: targetVol,
                            maxAssetWeight: maxAsset,
                            maxAssets: maxAssets,
                            rebalanceBand: band,
                            targetTurnoverThreshold: 0.24,
                            feeRate: 0.01,
                            slippageRate: 0.0005
                        )
                        var results: [(String, AssetAgnosticBacktestResult)] = []
                        for set in sets {
                            guard let result = AssetAgnosticBacktestEngine.runSparseV3(history: set.history, symbols: set.symbols, config: config) else { continue }
                            results.append((set.name, result))
                        }
                        if results.count == sets.count {
                            candidates.append(.init(config: config, results: results))
                        }
                    }
                }
            }
        }

        let ranked = candidates.sorted {
            if abs($0.score - $1.score) > 1e-12 { return $0.score > $1.score }
            if abs($0.worstSharpe - $1.worstSharpe) > 1e-12 { return $0.worstSharpe > $1.worstSharpe }
            if abs($0.worstDrawdown - $1.worstDrawdown) > 1e-12 { return $0.worstDrawdown < $1.worstDrawdown }
            return $0.totalTurnover < $1.totalTurnover
        }

        print("V4_SELECTION_GRID candidates=\(ranked.count)")
        for (rank, item) in ranked.prefix(20).enumerated() {
            let c = item.config
            let details = item.results.map { name, result in
                String(format: "%@ S %.3f MDD %.2f%% CAGR %.2f%%", name, result.performance.sharpeRatio, result.performance.maxDrawdown * 100, result.performance.annualizedReturn * 100)
            }.joined(separator: " | ")
            print(String(format: "#%02d score %.3f | targetVol %.3f maxAssets %d maxAsset %.2f band %.2f | worstS %.3f worstMDD %.2f%% worstCAGR %.2f%% turnover %.2fx | %@",
                         rank + 1,
                         item.score,
                         c.targetAnnualizedVolatility,
                         c.maxAssets,
                         c.maxAssetWeight,
                         c.rebalanceBand,
                         item.worstSharpe,
                         item.worstDrawdown * 100,
                         item.worstCAGR * 100,
                         item.totalTurnover,
                         details))
        }
    }

    private static func load(_ url: URL) throws -> PublicHistoryResponse {
        try JSONDecoder().decode(PublicHistoryResponse.self, from: Data(contentsOf: url))
    }
}
