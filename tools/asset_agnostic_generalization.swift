import Foundation

private struct ValidationFold: Codable {
    let name: String
    let symbols: [String]
    let strategy: AssetAgnosticPerformance
    let benchmark: AssetAgnosticPerformance
    let sharpeImprovement: Double
    let drawdownImprovement: Double
}

private struct GeneralizationCriteria: Codable {
    let minimumUnseenAssets: Int
    let minimumPositiveSharpeFraction: Double
    let minimumMedianSingleAssetSharpe: Double
    let minimumBasketSharpe: Double
    let maximumBasketDrawdown: Double
    let requireBasketSharpeAtLeastBenchmark: Bool
    let requireBasketDrawdownBelowBenchmark: Bool
    let requireSymbolRenameInvariant: Bool
}

private struct GeneralizationValidationReport: Codable {
    let generatedAtUTC: String
    let fixturePath: String
    let strategyVersion: String
    let developmentReferenceSymbols: [String]
    let availableUnseenSymbols: [String]
    let missingPreferredUnseenSymbols: [String]
    let criteria: GeneralizationCriteria
    let developmentReference: ValidationFold?
    let unseenSingleAssetFolds: [ValidationFold]
    let unseenBasket: ValidationFold?
    let positiveSharpeFraction: Double
    let medianSingleAssetSharpe: Double
    let symbolRenameInvariant: Bool
    let passed: Bool
    let failures: [String]
}

@main
private enum AssetAgnosticGeneralizationMain {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let fixturePath = argumentValue("--fixture", arguments: arguments)
            ?? ProcessInfo.processInfo.environment["ATM_HISTORY_FIXTURE"]
            ?? "tools/fixtures/backtest-history/public_history.json"
        let outputPath = argumentValue("--output", arguments: arguments)
            ?? "tools/research-results/asset-agnostic-generalization-v1.json"

        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let history = try JSONDecoder().decode(PublicHistoryResponse.self, from: data)
        let available = Set(history.series.map(\.symbol))

        // This is the universe that influenced the existing production low-noise strategy.
        // It is shown only as a reference and is deliberately excluded from the asset-OOS gate.
        let developmentReference = [
            firstAvailable(["gold_cny"], in: available),
            firstAvailable(["nasdaq", "nasdaq_composite"], in: available),
            firstAvailable(["sp500"], in: available),
            firstAvailable(["csi300"], in: available),
            firstAvailable(["shanghai_composite"], in: available),
        ].compactMap { $0 }

        // Preferred unseen assets. Alias groups mirror the public-history endpoint names while
        // keeping the validation independent of whichever canonical naming the backend returns.
        let preferredUnseenGroups = [
            ["dowjones", "dow_jones"],
            ["hsi", "hang_seng"],
            ["nikkei", "nikkei225"],
            ["shenzhen_component"],
            ["chinext"],
            ["oil_wti_cny"],
            ["kospi"],
            ["kospi200", "kospi_200"],
        ]
        let unseen = preferredUnseenGroups.compactMap { firstAvailable($0, in: available) }
        let missing = preferredUnseenGroups
            .filter { firstAvailable($0, in: available) == nil }
            .map { $0.joined(separator: "/") }

        let criteria = GeneralizationCriteria(
            minimumUnseenAssets: 4,
            minimumPositiveSharpeFraction: 0.60,
            minimumMedianSingleAssetSharpe: 0.25,
            minimumBasketSharpe: 0.45,
            maximumBasketDrawdown: 0.25,
            requireBasketSharpeAtLeastBenchmark: true,
            requireBasketDrawdownBelowBenchmark: true,
            requireSymbolRenameInvariant: true
        )

        let developmentFold = makeFold(name: "development_reference", symbols: developmentReference, history: history)
        let singleFolds = unseen.compactMap { symbol in
            makeFold(name: "unseen_\(symbol)", symbols: [symbol], history: history)
        }
        let basketFold = makeFold(name: "unseen_cross_market_basket", symbols: unseen, history: history)
        let positiveSharpeCount = singleFolds.filter { $0.strategy.sharpeRatio > 0 }.count
        let positiveSharpeFraction = singleFolds.isEmpty ? 0 : Double(positiveSharpeCount) / Double(singleFolds.count)
        let medianSharpe = median(singleFolds.map { $0.strategy.sharpeRatio })
        let renameInvariant = symbolRenameInvariant(history: history, symbols: developmentReference)

        var failures: [String] = []
        if unseen.count < criteria.minimumUnseenAssets {
            failures.append("Only \(unseen.count) unseen assets are available; need at least \(criteria.minimumUnseenAssets).")
        }
        if positiveSharpeFraction + 1e-12 < criteria.minimumPositiveSharpeFraction {
            failures.append(String(format: "Positive-Sharpe unseen fraction %.2f is below %.2f.", positiveSharpeFraction, criteria.minimumPositiveSharpeFraction))
        }
        if medianSharpe + 1e-12 < criteria.minimumMedianSingleAssetSharpe {
            failures.append(String(format: "Median unseen single-asset Sharpe %.3f is below %.3f.", medianSharpe, criteria.minimumMedianSingleAssetSharpe))
        }
        if let basketFold {
            if basketFold.strategy.sharpeRatio + 1e-12 < criteria.minimumBasketSharpe {
                failures.append(String(format: "Unseen basket Sharpe %.3f is below %.3f.", basketFold.strategy.sharpeRatio, criteria.minimumBasketSharpe))
            }
            if basketFold.strategy.maxDrawdown - 1e-12 > criteria.maximumBasketDrawdown {
                failures.append(String(format: "Unseen basket max drawdown %.2f%% exceeds %.2f%%.", basketFold.strategy.maxDrawdown * 100, criteria.maximumBasketDrawdown * 100))
            }
            if criteria.requireBasketSharpeAtLeastBenchmark,
               basketFold.strategy.sharpeRatio + 1e-12 < basketFold.benchmark.sharpeRatio {
                failures.append(String(format: "Unseen basket Sharpe %.3f is below buy-and-hold %.3f.", basketFold.strategy.sharpeRatio, basketFold.benchmark.sharpeRatio))
            }
            if criteria.requireBasketDrawdownBelowBenchmark,
               basketFold.strategy.maxDrawdown > basketFold.benchmark.maxDrawdown + 1e-12 {
                failures.append(String(format: "Unseen basket drawdown %.2f%% is worse than buy-and-hold %.2f%%.", basketFold.strategy.maxDrawdown * 100, basketFold.benchmark.maxDrawdown * 100))
            }
        } else {
            failures.append("Unable to build an unseen cross-market basket result.")
        }
        if criteria.requireSymbolRenameInvariant && !renameInvariant {
            failures.append("Symbol-renaming invariance failed; strategy behavior is not demonstrably asset-name independent.")
        }

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let report = GeneralizationValidationReport(
            generatedAtUTC: formatter.string(from: Date()),
            fixturePath: fixturePath,
            strategyVersion: "asset-agnostic-frozen-v2",
            developmentReferenceSymbols: developmentReference,
            availableUnseenSymbols: unseen,
            missingPreferredUnseenSymbols: missing,
            criteria: criteria,
            developmentReference: developmentFold,
            unseenSingleAssetFolds: singleFolds,
            unseenBasket: basketFold,
            positiveSharpeFraction: positiveSharpeFraction,
            medianSingleAssetSharpe: medianSharpe,
            symbolRenameInvariant: renameInvariant,
            passed: failures.isEmpty,
            failures: failures
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportData = try encoder.encode(report)
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try reportData.write(to: outputURL, options: .atomic)

        print("Asset-agnostic frozen-v1 generalization validation")
        print("Fixture: \(fixturePath)")
        print("Unseen assets: \(unseen.joined(separator: ", "))")
        if !missing.isEmpty { print("Preferred assets absent from fixture: \(missing.joined(separator: ", "))") }
        for fold in singleFolds {
            print(formatFold(fold))
        }
        if let basketFold {
            print(formatFold(basketFold))
        }
        print(String(format: "Positive unseen Sharpe fraction: %.1f%%", positiveSharpeFraction * 100))
        print(String(format: "Median unseen Sharpe: %.3f", medianSharpe))
        print("Symbol rename invariant: \(renameInvariant ? "PASS" : "FAIL")")
        print("GENERALIZATION: \(failures.isEmpty ? "PASS" : "FAIL")")
        if !failures.isEmpty {
            failures.forEach { print("- \($0)") }
        }
        print("Report: \(outputPath)")

        if !failures.isEmpty {
            Foundation.exit(2)
        }
    }

    private static func makeFold(name: String, symbols: [String], history: PublicHistoryResponse) -> ValidationFold? {
        guard !symbols.isEmpty,
              let result = AssetAgnosticBacktestEngine.run(history: history, symbols: symbols)
        else { return nil }
        return ValidationFold(
            name: name,
            symbols: symbols,
            strategy: result.performance,
            benchmark: result.benchmark,
            sharpeImprovement: result.performance.sharpeRatio - result.benchmark.sharpeRatio,
            drawdownImprovement: result.benchmark.maxDrawdown - result.performance.maxDrawdown
        )
    }

    private static func symbolRenameInvariant(history: PublicHistoryResponse, symbols: [String]) -> Bool {
        guard symbols.count >= 2,
              let baseline = AssetAgnosticBacktestEngine.run(history: history, symbols: symbols)
        else { return false }

        let mapping = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { index, symbol in
            (symbol, "asset_\(symbols.count - index)")
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
        guard let renamed = AssetAgnosticBacktestEngine.run(history: renamedHistory, symbols: aliases) else { return false }

        let tolerance = 1e-9
        let matches = abs(baseline.performance.annualizedReturn - renamed.performance.annualizedReturn) <= tolerance
            && abs(baseline.performance.maxDrawdown - renamed.performance.maxDrawdown) <= tolerance
            && abs(baseline.performance.annualizedVolatility - renamed.performance.annualizedVolatility) <= tolerance
            && abs(baseline.performance.sharpeRatio - renamed.performance.sharpeRatio) <= tolerance
            && baseline.performance.tradeCount == renamed.performance.tradeCount
        if !matches {
            print(String(format: "Rename debug: CAGR %.12f vs %.12f | MDD %.12f vs %.12f | vol %.12f vs %.12f | Sharpe %.12f vs %.12f | trades %d vs %d",
                         baseline.performance.annualizedReturn, renamed.performance.annualizedReturn,
                         baseline.performance.maxDrawdown, renamed.performance.maxDrawdown,
                         baseline.performance.annualizedVolatility, renamed.performance.annualizedVolatility,
                         baseline.performance.sharpeRatio, renamed.performance.sharpeRatio,
                         baseline.performance.tradeCount, renamed.performance.tradeCount))
        }
        return matches
    }

    private static func firstAvailable(_ candidates: [String], in available: Set<String>) -> String? {
        candidates.first(where: { available.contains($0) })
    }

    private static func argumentValue(_ key: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func formatFold(_ fold: ValidationFold) -> String {
        String(
            format: "%@ | CAGR %.2f%% | MDD %.2f%% | Sharpe %.3f | BH Sharpe %.3f | trades %d",
            fold.name,
            fold.strategy.annualizedReturn * 100,
            fold.strategy.maxDrawdown * 100,
            fold.strategy.sharpeRatio,
            fold.benchmark.sharpeRatio,
            fold.strategy.tradeCount
        )
    }
}
