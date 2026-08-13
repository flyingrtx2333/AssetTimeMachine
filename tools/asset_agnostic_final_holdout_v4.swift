import Foundation

private struct V4Fold: Codable {
    let name: String
    let symbols: [String]
    let strategy: AssetAgnosticPerformance
    let benchmark: AssetAgnosticPerformance
}

private struct V4Report: Codable {
    let generatedAtUTC: String
    let fixturePath: String
    let strategyVersion: String
    let symbols: [String]
    let singleAssetFolds: [V4Fold]
    let basket: V4Fold?
    let positiveSharpeFraction: Double
    let medianSingleAssetSharpe: Double
    let symbolRenameInvariant: Bool
    let passed: Bool
    let failures: [String]
}

@main
private enum AssetAgnosticFinalHoldoutV4Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let fixturePath = argument("--fixture", in: args)
            ?? "tools/fixtures/backtest-history/asset_agnostic_final_holdout_v4.json"
        let outputPath = argument("--output", in: args)
            ?? "tools/research-results/asset-agnostic-final-holdout-v4.json"
        let history = try JSONDecoder().decode(
            PublicHistoryResponse.self,
            from: Data(contentsOf: URL(fileURLWithPath: fixturePath))
        )
        let symbols = history.series.map(\.symbol)
        let config = AssetAgnosticStrategyConfig.frozenV4

        let singles: [V4Fold] = symbols.compactMap { symbol in
            guard let result = AssetAgnosticBacktestEngine.runSparseV3(
                history: history,
                symbols: [symbol],
                config: config
            ) else { return nil }
            return .init(name: symbol, symbols: [symbol], strategy: result.performance, benchmark: result.benchmark)
        }
        let basket: V4Fold? = AssetAgnosticBacktestEngine.runSparseV3(
            history: history,
            symbols: symbols,
            config: config
        ).map {
            .init(name: "final_cross_market_basket_v4", symbols: symbols, strategy: $0.performance, benchmark: $0.benchmark)
        }

        let positiveFraction = singles.isEmpty
            ? 0
            : Double(singles.filter { $0.strategy.sharpeRatio > 0 }.count) / Double(singles.count)
        let medianSharpe = median(singles.map { $0.strategy.sharpeRatio })
        let renameInvariant = symbolRenameInvariant(history: history, symbols: symbols, config: config)

        var failures: [String] = []
        if singles.count < 6 {
            failures.append("Need at least 6 valid final holdout markets; got \(singles.count).")
        }
        if positiveFraction + 1e-12 < 0.625 {
            failures.append(String(format: "Positive-Sharpe fraction %.3f is below 0.625.", positiveFraction))
        }
        if medianSharpe + 1e-12 < 0.20 {
            failures.append(String(format: "Median single-asset Sharpe %.3f is below 0.200.", medianSharpe))
        }
        if let basket {
            if basket.strategy.annualizedReturn <= 0 {
                failures.append(String(format: "Basket CAGR %.2f%% is not positive.", basket.strategy.annualizedReturn * 100))
            }
            if basket.strategy.sharpeRatio + 1e-12 < 0.45 {
                failures.append(String(format: "Basket Sharpe %.3f is below 0.450.", basket.strategy.sharpeRatio))
            }
            if basket.strategy.maxDrawdown - 1e-12 > 0.25 {
                failures.append(String(format: "Basket max drawdown %.2f%% exceeds 25%%.", basket.strategy.maxDrawdown * 100))
            }
            if basket.strategy.maxDrawdown > basket.benchmark.maxDrawdown + 1e-12 {
                failures.append(String(
                    format: "Basket drawdown %.2f%% is worse than buy-and-hold %.2f%%.",
                    basket.strategy.maxDrawdown * 100,
                    basket.benchmark.maxDrawdown * 100
                ))
            }
        } else {
            failures.append("Unable to build final cross-market basket.")
        }
        if !renameInvariant { failures.append("Symbol-renaming invariance failed.") }

        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        let report = V4Report(
            generatedAtUTC: iso.string(from: Date()),
            fixturePath: fixturePath,
            strategyVersion: "asset-agnostic-sparse-frozen-v4",
            symbols: symbols,
            singleAssetFolds: singles,
            basket: basket,
            positiveSharpeFraction: positiveFraction,
            medianSingleAssetSharpe: medianSharpe,
            symbolRenameInvariant: renameInvariant,
            passed: failures.isEmpty,
            failures: failures
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: outputURL, options: .atomic)

        print("FINAL ASSET-OOS HOLDOUT — sparse frozen V4")
        print("Markets: \(symbols.joined(separator: ", "))")
        for fold in singles { print(format(fold)) }
        if let basket { print(format(basket)) }
        print(String(format: "Positive single-asset Sharpe fraction: %.1f%%", positiveFraction * 100))
        print(String(format: "Median single-asset Sharpe: %.3f", medianSharpe))
        print("Symbol rename invariant: \(renameInvariant ? "PASS" : "FAIL")")
        print("FINAL_GENERALIZATION_V4: \(failures.isEmpty ? "PASS" : "FAIL")")
        failures.forEach { print("- \($0)") }
        print("Report: \(outputPath)")
        if !failures.isEmpty { Foundation.exit(2) }
    }

    private static func symbolRenameInvariant(
        history: PublicHistoryResponse,
        symbols: [String],
        config: AssetAgnosticStrategyConfig
    ) -> Bool {
        guard symbols.count >= 2,
              let baseline = AssetAgnosticBacktestEngine.runSparseV3(history: history, symbols: symbols, config: config)
        else { return false }
        let mapping = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { index, symbol in
            (symbol, "blind_v4_\(symbols.count - index)")
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
        guard let renamed = AssetAgnosticBacktestEngine.runSparseV3(
            history: renamedHistory,
            symbols: aliases,
            config: config
        ) else { return false }
        let tolerance = 1e-9
        return abs(baseline.performance.annualizedReturn - renamed.performance.annualizedReturn) <= tolerance
            && abs(baseline.performance.maxDrawdown - renamed.performance.maxDrawdown) <= tolerance
            && abs(baseline.performance.annualizedVolatility - renamed.performance.annualizedVolatility) <= tolerance
            && abs(baseline.performance.sharpeRatio - renamed.performance.sharpeRatio) <= tolerance
            && baseline.performance.tradeCount == renamed.performance.tradeCount
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func argument(_ key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func format(_ fold: V4Fold) -> String {
        String(
            format: "%@ | CAGR %.2f%% | MDD %.2f%% | Sharpe %.3f | BH MDD %.2f%% | BH Sharpe %.3f | turnover %.2fx | trades %d",
            fold.name,
            fold.strategy.annualizedReturn * 100,
            fold.strategy.maxDrawdown * 100,
            fold.strategy.sharpeRatio,
            fold.benchmark.maxDrawdown * 100,
            fold.benchmark.sharpeRatio,
            fold.strategy.turnover,
            fold.strategy.tradeCount
        )
    }
}
