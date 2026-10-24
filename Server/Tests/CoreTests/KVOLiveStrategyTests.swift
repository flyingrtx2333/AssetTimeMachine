import XCTest
@testable import AssetTimeMachineBacktestCore

final class KVOLiveStrategyTests: XCTestCase {
    private struct SavedFrame: Codable {
        let dates: [String], simulationRange: [Int], tradableSymbols: [String]
        let pricesBySymbol: [String: [Double]], observedBySymbol: [String: [Bool]]
        func frame(end: Int? = nil) -> MarketDataFrame {
            let end = end ?? dates.count - 1
            let options = BacktestCoreDefaults.strategyAssetOptions.filter { tradableSymbols.contains($0.symbol) }
            return .init(dates: dates.prefix(end + 1).map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! },
                pricesBySymbol: pricesBySymbol.mapValues { Array($0.prefix(end + 1)) },
                observedBySymbol: observedBySymbol.mapValues { Array($0.prefix(end + 1)) },
                ohlcBySymbol: [:], tradableSymbols: tradableSymbols,
                optionBySymbol: Dictionary(uniqueKeysWithValues: options.map { ($0.symbol, $0) }), simulationRange: 21...end)
        }
    }
    private struct SavedTarget: Decodable { let sourceFrameIndex: Int, targetWeights: [String: Double] }
    private let settings = AdvancedBacktestRiskSettings(feeRate: 0.025, slippageRate: 0,
        maxPositionRatio: 100, cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0)
    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "KVO")))
    }

    func testRealResearchTargetsAccountAndCausalPrefix() throws {
        let saved = try JSONDecoder().decode(SavedFrame.self, from: data("kvo-frame"))
        let native = try data("native-history")
        let q = try Dictionary(uniqueKeysWithValues: ["csi300", "shanghai_composite"].map { ($0, try data("quantity-" + $0)) })
        let frame = saved.frame()
        let expected = try JSONDecoder().decode([SavedTarget].self, from: data("kvo-targets"))
        let progress = Progress(totalUnitCount: 7)
        let reports = Progress(totalUnitCount: 8)
        let actual = try KE25LiveStrategy.targets(frame: frame, nativeHistory: native, quantityRawBySymbol: q,
            progress: { completed, total, message in
                XCTAssertEqual(total, 7)
                XCTAssertEqual(Int64(completed), reports.completedUnitCount)
                XCTAssertFalse(message.isEmpty)
                progress.completedUnitCount = Int64(completed)
                reports.completedUnitCount += 1
            })
        XCTAssertEqual(progress.completedUnitCount, 7)
        XCTAssertEqual(reports.completedUnitCount, 8)
        XCTAssertEqual(actual.count, expected.count)
        for row in expected {
            let weights = try XCTUnwrap(actual[row.sourceFrameIndex])
            XCTAssertEqual(Set(weights.keys), Set(row.targetWeights.keys))
            for (symbol, weight) in row.targetWeights { XCTAssertEqual(weights[symbol]?.bitPattern, weight.bitPattern) }
        }
        let run = try XCTUnwrap(KE25LiveStrategy.run(frame: frame, nativeHistory: native, initialCash: 100_000,
            settings: settings, quantityRawBySymbol: q))
        XCTAssertEqual(run.dailyStates.count, 5735)
        XCTAssertEqual(try XCTUnwrap(run.report.annualizedReturn), 0.06507971966997173, accuracy: 1e-11)
        XCTAssertEqual(try XCTUnwrap(run.report.sharpeRatio), 1.2745814030615343, accuracy: 1e-11)
        XCTAssertEqual(run.report.maxDrawdown, 0.07557506265754006, accuracy: 1e-11)
        XCTAssertEqual(run.report.trades.count, 12178)

        let cut = 744, civil = saved.dates[cut]
        var history = try XCTUnwrap(JSONSerialization.jsonObject(with: native) as? [String: Any])
        var series = try XCTUnwrap(history["series"] as? [[String: Any]])
        for i in series.indices {
            let dates = try XCTUnwrap(series[i]["dates"] as? [String])
            let n = dates.prefix(while: { $0 <= civil }).count
            for field in ["dates", "open_prices", "high_prices", "low_prices", "close_prices"] {
                series[i][field] = Array((series[i][field] as! [Any]).prefix(n))
            }
        }
        history["series"] = series
        let croppedNative = try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys])
        let croppedQ = try q.mapValues { raw in
            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [[String: Any]])
            return try JSONSerialization.data(withJSONObject: rows.filter { ($0["day"] as! String) <= civil }, options: [.sortedKeys])
        }
        let prefix = try KE25LiveStrategy.targets(frame: saved.frame(end: cut), nativeHistory: croppedNative, quantityRawBySymbol: croppedQ)
        for (index, weights) in prefix {
            XCTAssertEqual(Set(weights.keys), Set(actual[index]!.keys))
            for (symbol, weight) in weights { XCTAssertEqual(weight.bitPattern, actual[index]![symbol]!.bitPattern) }
        }
        let control = try XCTUnwrap(KE25LiveStrategy.run(frame: frame, nativeHistory: native, initialCash: 100_000, settings: settings))
        XCTAssertEqual(try XCTUnwrap(control.report.annualizedReturn), 0.06513367099281142, accuracy: 1e-11)
        XCTAssertEqual(try XCTUnwrap(control.report.sharpeRatio), 1.2604899693983074, accuracy: 1e-11)
    }

    func testCatalogAndExecutionDefaults() throws {
        let definition = try StrategyRegistry.definition(id: "kvo")
        XCTAssertEqual(definition.reference.version, "kvo-forward-v1-2026-10-22")
        XCTAssertTrue(BacktestProductStrategyCatalog.isExperimentalTemplateID("kvo"))
        XCTAssertTrue(BacktestCoreStrategyDefaults.eligibleTemplates.contains { $0.id == "kvo" })
        XCTAssertEqual(definition.template.mode.defaultFeeRatePercent, 0.025)
        XCTAssertEqual(definition.template.mode.defaultSlippageRatePercent, 0)
        XCTAssertEqual(StrategyRuntimeRegistry.specialized[.kvo] != nil, true)
    }

    func testLivePublicHistoryAdvice() throws {
        guard let path = ProcessInfo.processInfo.environment["ATM_KVO_LIVE_HISTORY"] else {
            throw XCTSkip("Requires a real public-history response, not simulated market data")
        }
        let response = try JSONDecoder().decode(PublicHistoryResponse.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let options = BacktestCoreDefaults.strategyAssetOptions.filter { KE25LiveStrategy.symbols.contains($0.symbol) }
        let inputs = options.map { option in
            MarketInputPreparation.advancedAssetInput(for: option) { symbol in
                response.series.first { $0.symbol == symbol || (symbol == "nasdaq" && $0.symbol == "nasdaq_composite") }
            }
        }
        let advice = try XCTUnwrap(StrategyAdviceCalculator.advancedRotationRebalanceAdvice(assetInputs: inputs, mode: .kvo, settings: settings))
        XCTAssertFalse(advice.allocations.isEmpty)
        XCTAssertLessThanOrEqual(advice.allocations.reduce(0) { $0 + $1.targetWeight }, 1 + 1e-12)
        XCTAssertTrue(advice.allocations.allSatisfy { KE25LiveStrategy.symbols.contains($0.symbol) && $0.targetWeight >= 0 })
        let latestGold = try XCTUnwrap(response.series.first { $0.symbol == "gold_cny" }?.dates.last)
        XCTAssertEqual(advice.asOfDate.backtestDateString, latestGold)
        let run = try XCTUnwrap(BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(
            assetInputs: inputs, initialCash: 100_000, settings: settings, mode: .kvo))
        XCTAssertEqual(run.dailyStates.last?.date, advice.asOfDate)
        XCTAssertFalse(run.report.trades.isEmpty)
        print("KVO_PRODUCTION_DATA_VERIFIED asOf=\(latestGold) states=\(run.dailyStates.count) fills=\(run.report.trades.count)")
    }
}
