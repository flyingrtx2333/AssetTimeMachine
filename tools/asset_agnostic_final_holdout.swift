import Foundation

private struct FinalHoldoutFold: Codable {
    let name: String
    let symbols: [String]
    let strategy: AssetAgnosticPerformance
    let benchmark: AssetAgnosticPerformance
}

private struct FinalHoldoutReport: Codable {
    let generatedAtUTC: String
    let fixturePath: String
    let strategyVersion: String
    let symbols: [String]
    let singleAssetFolds: [FinalHoldoutFold]
    let basket: FinalHoldoutFold?
    let positiveSharpeFraction: Double
    let medianSingleAssetSharpe: Double
    let symbolRenameInvariant: Bool
    let passed: Bool
    let failures: [String]
}

@main
private enum AssetAgnosticFinalHoldoutMain {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let fixturePath = value("--fixture", in: args)
            ?? "tools/fixtures/backtest-history/asset_agnostic_final_holdout.json"
        let outputPath = value("--output", in: args)
            ?? "tools/research-results/asset-agnostic-final-holdout-v2.json"

        let payload = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let history = try JSONDecoder().decode(PublicHistoryResponse.self, from: payload)
        let symbols = history.series.map(\.symbol)
        let singleFolds = symbols.compactMap { symbol -> FinalHoldoutFold? in
            guard let result = AssetAgnosticBacktestEngine.run(history: history, symbols: [symbol], config: .frozenV2) else { return nil }
            return .init(name: symbol, symbols: [symbol], strategy: result.performance, benchmark: result.benchmark)
        }
        let basket: FinalHoldoutFold?
        if let result = AssetAgnosticBacktestEngine.run(history: history, symbols: symbols, config: .frozenV2) {
            basket = .init(name: "final_cross_market_basket", symbols: symbols, strategy: result.performance, benchmark: result.benchmark)
        } else {
            basket = nil
        }

        let positiveSharpeFraction = singleFolds.isEmpty
            ? 0
            : Double(singleFolds.filter { $0.strategy.sharpeRatio > 0 }.count) / Double(singleFolds.count)
        let medianSharpe = median(singleFolds.map { $0.strategy.sharpeRatio })
        let renameInvariant = symbolRenameInvariant(history: history, symbols: symbols)

        // Preregistered before this holdout fixture is fetched. Keep in sync with
        // docs/strategies/asset-agnostic-generalization-v2.md.
        var failures: [String] = []
        if singleFolds.count < 6 {
            failures.append("Need at least 6 final holdout markets; only \(singleFolds.count) produced valid backtests.")
        }
        if positiveSharpeFraction + 1e-12 < 0.625 {
            failures.append(String(format: "Positive-Sharpe fraction %.3f is below 0.625.", positiveSharpeFraction))
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
                failures.append(String(format: "Basket drawdown %.2f%% is worse than buy-and-hold %.2f%%.", basket.strategy.maxDrawdown * 100, basket.benchmark.maxDrawdown * 100))
            }
        } else {
            failures.append("Unable to build the final cross-market basket.")
        }
        if !renameInvariant {
            failures.append("Symbol-renaming invariance failed.")
        }

        let timeFormatter = ISO8601DateFormatter()
        timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let report = FinalHoldoutReport(
            generatedAtUTC: timeFormatter.string(from: Date()),
            fixturePath: fixturePath,
            strategyVersion: "asset-agnostic-frozen-v2",
            symbols: symbols,
            singleAssetFolds: singleFolds,
            basket: basket,
            positiveSharpeFraction: positiveSharpeFraction,
            medianSingleAssetSharpe: medianSharpe,
            symbolRenameInvariant: renameInvariant,
            passed: failures.isEmpty,
            failures: failures
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let outputData = try encoder.encode(report)
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try outputData.write(to: outputURL, options: .atomic)

        print("FINAL ASSET-OOS HOLDOUT — frozen v2")
        print("Markets: \(symbols.joined(separator: ", "))")
        for fold in singleFolds {
            print(format(fold))
        }
        if let basket {
            print(format(basket))
        }
        print(String(format: "Positive single-asset Sharpe fraction: %.1f%%", positiveSharpeFraction * 100))
        print(String(format: "Median single-asset Sharpe: %.3f", medianSharpe))
        print("Symbol rename invariant: \(renameInvariant ? "PASS" : "FAIL")")
        print("FINAL_GENERALIZATION: \(failures.isEmpty ? "PASS" : "FAIL")")
        failures.forEach { print("- \($0)") }
        print("Report: \(outputPath)")

        if !failures.isEmpty { Foundation.exit(2) }
    }

    private static func symbolRenameInvariant(history: PublicHistoryResponse, symbols: [String]) -> Bool {
        guard symbols.count >= 2,
              let baseline = AssetAgnosticBacktestEngine.run(history: history, symbols: symbols, config: .frozenV2)
        else { return false }
        let mapping = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { index, symbol in
            (symbol, "blind_asset_\(symbols.count - index)")
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
        guard let renamed = AssetAgnosticBacktestEngine.run(history: renamedHistory, symbols: aliases, config: .frozenV2) else { return false }
        let tolerance = 1e-9
        return abs(baseline.performance.annualizedReturn - renamed.performance.annualizedReturn) <= tolerance
            && abs(baseline.performance.maxDrawdown - renamed.performance.maxDrawdown) <= tolerance
            && abs(baseline.performance.annualizedVolatility - renamed.performance.annualizedVolatility) <= tolerance
            && abs(baseline.performance.sharpeRatio - renamed.performance.sharpeRatio) <= tolerance
            && baseline.performance.tradeCount == renamed.performance.tradeCount
    }

    private static func value(_ key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func format(_ fold: FinalHoldoutFold) -> String {
        String(
            format: "%@ | CAGR %.2f%% | MDD %.2f%% | Sharpe %.3f | BH MDD %.2f%% | BH Sharpe %.3f | trades %d",
            fold.name,
            fold.strategy.annualizedReturn * 100,
            fold.strategy.maxDrawdown * 100,
            fold.strategy.sharpeRatio,
            fold.benchmark.maxDrawdown * 100,
            fold.benchmark.sharpeRatio,
            fold.strategy.tradeCount
        )
    }
}
