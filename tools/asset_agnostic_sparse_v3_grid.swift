import Foundation

private struct CandidateResult {
    let config: AssetAgnosticStrategyConfig
    let country: AssetAgnosticBacktestResult
    let diagnostic: AssetAgnosticBacktestResult

    var worstSharpe: Double { min(country.performance.sharpeRatio, diagnostic.performance.sharpeRatio) }
    var worstDrawdown: Double { max(country.performance.maxDrawdown, diagnostic.performance.maxDrawdown) }
    var worstCAGR: Double { min(country.performance.annualizedReturn, diagnostic.performance.annualizedReturn) }
    var totalTurnover: Double { country.performance.turnover + diagnostic.performance.turnover }

    var robustScore: Double {
        worstSharpe
            + 0.25 * min(worstCAGR, 0.10)
            - 2.0 * max(worstDrawdown - 0.22, 0)
            - 0.002 * totalTurnover
    }
}

@main
private enum SparseV3GridMain {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let country = try load(root.appendingPathComponent("tools/fixtures/backtest-history/asset_agnostic_final_holdout.json"))
        let diagnostic = try load(root.appendingPathComponent("tools/fixtures/backtest-history/generalization_public_history.json"))
        let countrySymbols = country.series.map(\.symbol)
        let available = Set(diagnostic.series.map(\.symbol))
        let diagnosticSymbols = [["dow_jones","dowjones"],["hang_seng","hsi"],["nikkei225","nikkei"],["shenzhen_component"],["chinext"],["oil_wti_cny"]]
            .compactMap { group in group.first(where: { available.contains($0) }) }

        var results: [CandidateResult] = []
        for review in [42] {
            for targetVol in [0.075, 0.080, 0.085] {
                for maxAsset in [0.18, 0.20, 0.22] {
                    for maxAssets in [8] {
                        for band in [0.42, 0.45, 0.48] {
                            for targetTurnover in [0.22, 0.24, 0.26] {
                            let config = AssetAgnosticStrategyConfig(
                                warmupSessions: 252,
                                reviewSessions: review,
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
                                targetTurnoverThreshold: targetTurnover,
                                feeRate: 0.01,
                                slippageRate: 0.0005
                            )
                            guard let countryResult = AssetAgnosticBacktestEngine.runSparseV3(history: country, symbols: countrySymbols, config: config),
                                  let diagnosticResult = AssetAgnosticBacktestEngine.runSparseV3(history: diagnostic, symbols: diagnosticSymbols, config: config)
                            else { continue }
                            results.append(.init(config: config, country: countryResult, diagnostic: diagnosticResult))
                            }
                        }
                    }
                }
            }
        }

        let ranked = results.sorted {
            if abs($0.robustScore - $1.robustScore) > 1e-12 { return $0.robustScore > $1.robustScore }
            if abs($0.worstSharpe - $1.worstSharpe) > 1e-12 { return $0.worstSharpe > $1.worstSharpe }
            if abs($0.worstDrawdown - $1.worstDrawdown) > 1e-12 { return $0.worstDrawdown < $1.worstDrawdown }
            return $0.totalTurnover < $1.totalTurnover
        }

        print("SPARSE_V3_GRID candidates=\(ranked.count)")
        for (rank, item) in ranked.prefix(15).enumerated() {
            let c = item.config
            print(String(format: "#%02d score %.3f | review %d targetVol %.2f maxAsset %.2f maxAssets %d band %.2f threshold %.2f | worstSharpe %.3f worstMDD %.2f%% worstCAGR %.2f%% turnover %.2fx | country S %.3f MDD %.2f%% CAGR %.2f%% | diag S %.3f MDD %.2f%% CAGR %.2f%%",
                         rank + 1,
                         item.robustScore,
                         c.reviewSessions,
                         c.targetAnnualizedVolatility,
                         c.maxAssetWeight,
                         c.maxAssets,
                         c.rebalanceBand,
                         c.targetTurnoverThreshold,
                         item.worstSharpe,
                         item.worstDrawdown * 100,
                         item.worstCAGR * 100,
                         item.totalTurnover,
                         item.country.performance.sharpeRatio,
                         item.country.performance.maxDrawdown * 100,
                         item.country.performance.annualizedReturn * 100,
                         item.diagnostic.performance.sharpeRatio,
                         item.diagnostic.performance.maxDrawdown * 100,
                         item.diagnostic.performance.annualizedReturn * 100))
        }
    }

    private static func load(_ url: URL) throws -> PublicHistoryResponse {
        try JSONDecoder().decode(PublicHistoryResponse.self, from: Data(contentsOf: url))
    }
}
