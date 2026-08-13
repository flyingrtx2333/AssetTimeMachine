import Foundation

private struct DatasetSummary {
    let name: String
    let symbols: [String]
    let basket: AssetAgnosticBacktestResult
    let singleResults: [AssetAgnosticBacktestResult]

    var positiveSharpeFraction: Double {
        guard !singleResults.isEmpty else { return 0 }
        return Double(singleResults.filter { $0.performance.sharpeRatio > 0 }.count) / Double(singleResults.count)
    }

    var medianSingleSharpe: Double {
        let values = singleResults.map { $0.performance.sharpeRatio }.sorted()
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}

@main
private enum AssetAgnosticV3DevelopmentMain {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let v2HoldoutURL = root.appendingPathComponent("tools/fixtures/backtest-history/asset_agnostic_final_holdout.json")
        let diagnosticURL = root.appendingPathComponent("tools/fixtures/backtest-history/generalization_public_history.json")
        let v2Holdout = try load(v2HoldoutURL)
        let diagnostic = try load(diagnosticURL)

        let diagnosticAvailable = Set(diagnostic.series.map(\.symbol))
        let diagnosticSymbols = [
            ["dow_jones", "dowjones"],
            ["hang_seng", "hsi"],
            ["nikkei225", "nikkei"],
            ["shenzhen_component"],
            ["chinext"],
            ["oil_wti_cny"],
        ].compactMap { group in group.first(where: { diagnosticAvailable.contains($0) }) }

        let config = AssetAgnosticStrategyConfig.frozenV3
        guard let countrySummary = summarize(name: "v2_country_holdout_now_development", history: v2Holdout, symbols: v2Holdout.series.map(\.symbol), config: config),
              let diagnosticSummary = summarize(name: "legacy_unseen_diagnostic", history: diagnostic, symbols: diagnosticSymbols, config: config)
        else {
            throw NSError(domain: "AssetAgnosticV3Development", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to build one or more development summaries"])
        }

        print("ASSET_AGNOSTIC_V3_DEVELOPMENT")
        printConfig(config)
        printSummary(countrySummary)
        printSummary(diagnosticSummary)
        let countryRenameInvariant = symbolRenameInvariant(history: v2Holdout, symbols: v2Holdout.series.map(\.symbol), config: config)
        let diagnosticRenameInvariant = symbolRenameInvariant(history: diagnostic, symbols: diagnosticSymbols, config: config)
        print("RENAME country=\(countryRenameInvariant ? "PASS" : "FAIL") diagnostic=\(diagnosticRenameInvariant ? "PASS" : "FAIL")")

        let worstBasketSharpe = min(countrySummary.basket.performance.sharpeRatio, diagnosticSummary.basket.performance.sharpeRatio)
        let worstBasketDrawdown = max(countrySummary.basket.performance.maxDrawdown, diagnosticSummary.basket.performance.maxDrawdown)
        let worstMedianSingleSharpe = min(countrySummary.medianSingleSharpe, diagnosticSummary.medianSingleSharpe)
        let worstPositiveFraction = min(countrySummary.positiveSharpeFraction, diagnosticSummary.positiveSharpeFraction)
        print(String(format: "ROBUSTNESS worst_basket_sharpe=%.3f worst_basket_mdd=%.2f%% worst_median_single=%.3f worst_positive_fraction=%.1f%%",
                     worstBasketSharpe,
                     worstBasketDrawdown * 100,
                     worstMedianSingleSharpe,
                     worstPositiveFraction * 100))
    }

    private static func summarize(
        name: String,
        history: PublicHistoryResponse,
        symbols: [String],
        config: AssetAgnosticStrategyConfig
    ) -> DatasetSummary? {
        guard let basket = AssetAgnosticBacktestEngine.runSparseV3(history: history, symbols: symbols, config: config) else { return nil }
        let singles = symbols.compactMap { symbol in
            AssetAgnosticBacktestEngine.runSparseV3(history: history, symbols: [symbol], config: config)
        }
        return .init(name: name, symbols: symbols, basket: basket, singleResults: singles)
    }

    private static func load(_ url: URL) throws -> PublicHistoryResponse {
        try JSONDecoder().decode(PublicHistoryResponse.self, from: Data(contentsOf: url))
    }

    private static func printSummary(_ summary: DatasetSummary) {
        let p = summary.basket.performance
        let b = summary.basket.benchmark
        print(String(format: "%@ BASKET | CAGR %.2f%% | MDD %.2f%% | Sharpe %.3f | Vol %.2f%% | turnover %.2fx | trades %d | BH MDD %.2f%% | BH Sharpe %.3f",
                     summary.name,
                     p.annualizedReturn * 100,
                     p.maxDrawdown * 100,
                     p.sharpeRatio,
                     p.annualizedVolatility * 100,
                     p.turnover,
                     p.tradeCount,
                     b.maxDrawdown * 100,
                     b.sharpeRatio))
        print(String(format: "%@ SINGLES | positiveSharpe %.1f%% | medianSharpe %.3f",
                     summary.name,
                     summary.positiveSharpeFraction * 100,
                     summary.medianSingleSharpe))
        for result in summary.singleResults {
            let item = result.performance
            print(String(format: "  %@ | CAGR %.2f%% | MDD %.2f%% | Sharpe %.3f | trades %d",
                         result.symbols.first ?? "?",
                         item.annualizedReturn * 100,
                         item.maxDrawdown * 100,
                         item.sharpeRatio,
                         item.tradeCount))
        }
    }

    private static func symbolRenameInvariant(
        history: PublicHistoryResponse,
        symbols: [String],
        config: AssetAgnosticStrategyConfig
    ) -> Bool {
        guard let baseline = AssetAgnosticBacktestEngine.runSparseV3(history: history, symbols: symbols, config: config) else { return false }
        let mapping = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { index, symbol in
            (symbol, "blind_\(symbols.count - index)")
        })
        let renamedSeries = history.series.map { series -> PublicHistorySeries in
            guard let alias = mapping[series.symbol] else { return series }
            return PublicHistorySeries(
                symbol: alias,
                category: series.category,
                label: alias,
                currency: series.currency,
                unit: series.unit,
                source: series.source,
                dates: series.dates,
                prices: series.prices,
                hasOHLC: series.hasOHLC,
                ohlcSource: series.ohlcSource,
                ohlcCoverageRatio: series.ohlcCoverageRatio,
                openPrices: series.openPrices,
                highPrices: series.highPrices,
                lowPrices: series.lowPrices,
                closePrices: series.closePrices,
                volumes: series.volumes
            )
        }
        let renamedHistory = PublicHistoryResponse(
            success: history.success,
            series: renamedSeries,
            availableSymbols: history.availableSymbols?.map { mapping[$0] ?? $0 },
            catalog: history.catalog
        )
        let aliases = symbols.compactMap { mapping[$0] }
        guard let renamed = AssetAgnosticBacktestEngine.runSparseV3(history: renamedHistory, symbols: aliases, config: config) else { return false }
        let tolerance = 1e-9
        return abs(baseline.performance.annualizedReturn - renamed.performance.annualizedReturn) <= tolerance
            && abs(baseline.performance.maxDrawdown - renamed.performance.maxDrawdown) <= tolerance
            && abs(baseline.performance.annualizedVolatility - renamed.performance.annualizedVolatility) <= tolerance
            && abs(baseline.performance.sharpeRatio - renamed.performance.sharpeRatio) <= tolerance
            && baseline.performance.tradeCount == renamed.performance.tradeCount
    }

    private static func printConfig(_ config: AssetAgnosticStrategyConfig) {
        print("CONFIG review=\(config.reviewSessions) targetVol=\(config.targetAnnualizedVolatility) maxAsset=\(config.maxAssetWeight) maxAssets=\(config.maxAssets) band=\(config.rebalanceBand) targetTurnover=\(config.targetTurnoverThreshold) fee=\(config.feeRate) slippage=\(config.slippageRate)")
    }
}
