import XCTest
@testable import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport

final class BacktestRunConfigurationTests: XCTestCase {
    private func input() throws -> BacktestRunInput {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("tools/fixtures/backtest-history/generalization_public_history.json"))
        let dataset = try PublicBacktestCore.loadDataset(from: data, datasetHash: ResearchRunEvidence.sha256(data), dataStale: false)
        return BacktestRunInput(seriesBySymbol: dataset.seriesBySymbol, datasetHash: dataset.datasetHash)
    }
    private func configuration(_ definition: StrategyDefinition, parameters: BacktestResearchParameters = .frozen,
                               purpose: BacktestRunConfiguration.Purpose = .research,
                               range: BacktestRunRange? = nil) -> BacktestRunConfiguration {
        .init(strategy: definition.reference, purpose: purpose, settings: definition.defaultSettings,
              evaluationRange: range, parameters: parameters)
    }
    private func compare(_ lhs: BacktestRunResult, _ rhs: BacktestRunResult) {
        XCTAssertEqual(lhs.dailyStates.count, rhs.dailyStates.count)
        for (a, b) in zip(lhs.dailyStates, rhs.dailyStates) {
            XCTAssertEqual(a.date, b.date)
            XCTAssertEqual(Set(a.targetWeights.keys), Set(b.targetWeights.keys))
            XCTAssertEqual(Set(a.holdingsBySymbol.keys), Set(b.holdingsBySymbol.keys))
            for (symbol, weight) in a.targetWeights { XCTAssertEqual(weight, b.targetWeights[symbol] ?? -.infinity, accuracy: 1e-12) }
            for (symbol, amount) in a.holdingsBySymbol { XCTAssertEqual(amount, b.holdingsBySymbol[symbol] ?? -.infinity, accuracy: max(1e-8, abs(amount) * 1e-12)) }
            XCTAssertEqual(a.cash, b.cash, accuracy: max(1e-8, abs(a.cash) * 1e-12))
            XCTAssertEqual(a.portfolioValue, b.portfolioValue, accuracy: max(1e-8, abs(a.portfolioValue) * 1e-12))
        }
        XCTAssertEqual(lhs.report.trades.map(\.date), rhs.report.trades.map(\.date))
        XCTAssertEqual(lhs.report.trades.map(\.assetSymbol), rhs.report.trades.map(\.assetSymbol))
        XCTAssertEqual(lhs.report.trades.map(\.action), rhs.report.trades.map(\.action))
        XCTAssertEqual(lhs.report.annualizedReturn ?? 0, rhs.report.annualizedReturn ?? 0, accuracy: 1e-12)
        XCTAssertEqual(lhs.report.sharpeRatio ?? 0, rhs.report.sharpeRatio ?? 0, accuracy: 1e-12)
    }

    func testConfigurationRoundTripAndUnknownKeysFailBeforeRun() throws {
        let definition = try StrategyRegistry.definition(id: "risk-contribution-cash-confidence-low-noise")
        let source = ResearchConfiguration(run: configuration(definition, parameters: .init(lowNoiseTradeBand: 0.1)))
        let data = try source.encoded()
        let decoded = try ResearchConfiguration.decode(data)
        XCTAssertEqual(decoded.run.strategy, source.run.strategy)
        XCTAssertEqual(decoded.run.parameters, source.run.parameters)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var run = try XCTUnwrap(object["run"] as? [String: Any])
        run["parameters"] = ["lowNoiseTradeBnad": 0.1]
        object["run"] = run
        XCTAssertThrowsError(try ResearchConfiguration.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try ResearchConfiguration.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try BacktestResearchParameters(ohlcRiskOverlayVariant: "typo").validate())
        XCTAssertThrowsError(try BacktestResearchParameters(lowNoiseTradeBand: .nan).validate())
    }

    func testProductOverridesAndMissingMacroAreRejected() throws {
        let lowNoise = try StrategyRegistry.definition(id: "risk-contribution-cash-confidence-low-noise")
        XCTAssertThrowsError(try lowNoise.run(input: input(), configuration: configuration(lowNoise,
            parameters: .init(lowNoiseTradeBand: 0.1), purpose: .product))) { error in
            XCTAssertEqual(error as? BacktestConfigurationError, .researchOverrideOnProduct)
        }
        let nfci = try StrategyRegistry.definition(id: "nfci-dual-core-v11")
        XCTAssertThrowsError(try nfci.run(input: input(), configuration: configuration(nfci))) { error in
            XCTAssertEqual(error as? BacktestConfigurationError, .missingData("NFCI as-of snapshot"))
        }
        XCTAssertThrowsError(try StrategyRegistry.definition(reference: .init(id: lowNoise.reference.id, version: "missing")))
    }

    func testExistingLeveragedCatalogDefaultRunsThroughSharedInterface() throws {
        let definition = try StrategyRegistry.definition(id: "risk-contribution-regime-router")
        XCTAssertGreaterThan(definition.defaultSettings.maxPositionRatio, 100)
        let result = try definition.makeRunner().run(input: input(),
            configuration: configuration(definition, purpose: .product))
        XCTAssertFalse(result.dailyStates.isEmpty)
        for state in result.dailyStates {
            let held = state.holdingsBySymbol.values.reduce(0, +)
            XCTAssertEqual(held + state.cash, state.portfolioValue,
                           accuracy: max(1e-8, abs(state.portfolioValue) * 1e-12))
        }
    }

    func testConcurrentParametersAndMacroSnapshotsMatchSerialRuns() async throws {
        let dataset = try input()
        let definition = try StrategyRegistry.definition(id: "nfci-dual-core-v1")
        let first = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "1999-01-01"))
        func macro(sign: Double) -> BacktestNFCIAsOfData {
            let points = (0..<1500).map { index in
                let date = first.addingTimeInterval(Double(index) * 7 * 86400)
                return BacktestNFCIPoint(releaseDate: date.backtestDateString,
                    referenceDate: date.backtestDateString, availableAt: date,
                    value: sign * Double(index) * 0.01)
            }
            return .init(source: "synthetic", credit: points, leverage: points)
        }
        let a = BacktestRunInput(seriesBySymbol: dataset.seriesBySymbol, nfciAsOf: macro(sign: 1))
        let b = BacktestRunInput(seriesBySymbol: dataset.seriesBySymbol, nfciAsOf: macro(sign: -1))
        let ca = configuration(definition, parameters: .init(lowNoiseTradeBand: 0.10, nfciDualCoreHighCoreBand: 0.15))
        let cb = configuration(definition, parameters: .init(lowNoiseTradeBand: 0.35, nfciDualCoreHighCoreBand: 0.35))
        let serialA = try definition.run(input: a, configuration: ca)
        let serialB = try definition.run(input: b, configuration: cb)
        async let parallelA = Task.detached { try definition.run(input: a, configuration: ca) }.value
        async let parallelB = Task.detached { try definition.run(input: b, configuration: cb) }.value
        let results = try await (parallelA, parallelB)
        compare(serialA, results.0)
        compare(serialB, results.1)
        XCTAssertNotEqual(serialA.report.finalPortfolioValue, serialB.report.finalPortfolioValue)
        XCTAssertEqual(BacktestRunScope.parameters, .frozen)
    }

    func testStatefulSliceRetainsTargetsAndRebasesAllMonetaryValues() throws {
        let definition = try StrategyRegistry.definition(id: "gold-nasdaq-dual-trend-barbell")
        let full = try definition.run(input: input(), configuration: configuration(definition))
        let range = BacktestRunRange(startDate: full.dailyStates[full.dailyStates.count / 2].date,
                                     endDate: try XCTUnwrap(full.dailyStates.last?.date))
        let slice = try definition.run(input: input(), configuration: configuration(definition, range: range))
        let first = try XCTUnwrap(full.report.points.first { $0.date >= range.startDate })
        let scale = 100_000 / first.portfolioValue
        for (original, rebased) in zip(full.dailyStates.filter { $0.date >= range.startDate }, slice.dailyStates) {
            XCTAssertEqual(original.targetWeights, rebased.targetWeights)
            XCTAssertEqual(original.cash * scale, rebased.cash, accuracy: 1e-8)
            XCTAssertEqual(rebased.cash + rebased.holdingsBySymbol.values.reduce(0, +), rebased.portfolioValue, accuracy: 1e-7)
        }
        XCTAssertEqual(slice.report.finalPortfolioValue, try XCTUnwrap(slice.dailyStates.last?.portfolioValue), accuracy: 1e-8)
    }

    func testEvidenceIsCanonicalAndCannotReplacePreviousOutput() throws {
        let definition = try StrategyRegistry.definition(id: "gold-nasdaq-dual-trend-barbell")
        XCTAssertEqual(try definition.frozenParametersJSON, try definition.frozenParametersJSON)
        let result = try definition.run(input: input(), configuration: configuration(definition))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ResearchRunEvidence.write(result, to: directory)
        let before = try Data(contentsOf: directory.appendingPathComponent("evidence.json"))
        XCTAssertThrowsError(try ResearchRunEvidence.write(result, to: directory))
        XCTAssertEqual(before, try Data(contentsOf: directory.appendingPathComponent("evidence.json")))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        XCTAssertEqual(object["source_commit"] as? String, "unknown")
        XCTAssertEqual(object["execution_version"] as? String, BacktestExecutionVersion.defaultEngineVersion)
        XCTAssertEqual((object["parameters_sha256"] as? String)?.count, 64)
    }

    func testSavedRecordPayloadUsesUnchangedJSONKeys() throws {
        let data = Data("[{\"date\":0,\"value\":12345.67,\"sequence\":0}]".utf8)
        let record = BacktestStoredRecord(kindRawValue: "allocation", title: "legacy record",
            totalReturn: 0, maxDrawdown: 0, pointsJSON: data)
        let points = BacktestRecordCodec.decodePoints(from: record)
        XCTAssertEqual(points.first?.portfolioValue, 12345.67)
        XCTAssertEqual(BacktestRecordCodec.kind(for: record), .allocation)
        XCTAssertEqual(try JSONDecoder().decode([BacktestRecordPointPayload].self,
            from: BacktestRecordCodec.pointsData(from: points)).first?.value, 12345.67)
        let legacy = try JSONDecoder().decode(BacktestRecordConfigPayload.self,
            from: Data("{\"kind\":\"advanced\",\"feeRate\":1}".utf8))
        XCTAssertNil(legacy.runtimeProvenance)
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with:
            BacktestRecordCodec.configData(from: legacy)) as? [String: Any])
        XCTAssertNil(legacyObject["runtimeProvenance"])
        let reference = try StrategyRegistry.definition(id: "gold-nasdaq-dual-trend-barbell").reference
        let current = BacktestRecordConfigPayload(kind: .advanced, runtimeProvenance:
            .init(strategy: reference, executionVersion: BacktestExecutionVersion.defaultEngineVersion,
                  frozenParametersJSON: Data("{}".utf8)))
        let restored = try JSONDecoder().decode(BacktestRecordConfigPayload.self,
            from: BacktestRecordCodec.configData(from: current))
        XCTAssertEqual(restored.runtimeProvenance?.strategy, reference)
        XCTAssertEqual(restored.runtimeProvenance?.sourceCommit, "unknown")
    }

    func testRuleTraceAndSliceUseTheSameCalculationAsCompatibilityFacade() throws {
        let definition = try StrategyRegistry.definition(id: "basic-gold-nasdaq-hold")
        let data = try input()
        let options = BacktestCoreStrategyDefaults.assetOptions(for: definition.template)
        let inputs = options.map { MarketInputPreparation.advancedAssetInput(for: $0) { data.seriesBySymbol[$0] } }
        let original = try XCTUnwrap(BacktestCoreEngine.runAdvancedStrategies(assetInputs: inputs,
            initialCash: 100_000, tradeAmount: 100_000 * definition.template.tradeAmountRatio,
            buyRule: definition.template.buyRule, sellRule: definition.template.sellRule,
            settings: definition.defaultSettings))
        let full = try definition.run(input: data, configuration: configuration(definition))
        XCTAssertEqual(original.points.map(\.portfolioValue), full.report.points.map(\.portfolioValue))
        XCTAssertEqual(original.trades.map(\.cashAmount), full.report.trades.map(\.cashAmount))
        XCTAssertEqual(full.dailyStates.count, full.report.points.count)
        for state in full.dailyStates {
            XCTAssertEqual(state.cash + state.holdingsBySymbol.values.reduce(0, +), state.portfolioValue, accuracy: 1e-7)
        }
        let range = BacktestRunRange(startDate: full.dailyStates[full.dailyStates.count / 2].date,
                                    endDate: full.dailyStates[full.dailyStates.count - 20].date)
        let slice = try definition.run(input: data, configuration: configuration(definition, range: range))
        XCTAssertEqual(slice.report.points.first?.portfolioValue ?? 0, 100_000, accuracy: 1e-8)
        XCTAssertEqual(slice.report.finalCash, try XCTUnwrap(slice.dailyStates.last?.cash), accuracy: 1e-7)
        XCTAssertLessThanOrEqual(try XCTUnwrap(slice.dailyStates.last?.date), range.endDate)
    }

    func testObservationMasksAndEmptyEvaluationRangeFailExplicitly() throws {
        let definition = try StrategyRegistry.definition(id: "basic-buy-and-hold")
        let data = try input()
        let symbol = try XCTUnwrap(definition.dataRequirements.priceSymbols.first)
        let source = try XCTUnwrap(data.seriesBySymbol[symbol])
        let invalid = BacktestRunInput(seriesBySymbol: data.seriesBySymbol,
            realObservationsBySymbol: [symbol: [true]])
        XCTAssertThrowsError(try definition.run(input: invalid, configuration: configuration(definition)))
        let noQuotes = BacktestRunInput(seriesBySymbol: data.seriesBySymbol,
            realObservationsBySymbol: [symbol: Array(repeating: false, count: source.dates.count)])
        XCTAssertThrowsError(try definition.run(input: noQuotes, configuration: configuration(definition)))
        let end = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "1901-01-01"))
        XCTAssertThrowsError(try definition.run(input: data, configuration: configuration(definition,
            range: .init(startDate: end.addingTimeInterval(-86400), endDate: end))))
        var mask = Array(repeating: true, count: source.dates.count)
        mask[100] = false
        let masked = try definition.run(input: .init(seriesBySymbol: data.seriesBySymbol,
            realObservationsBySymbol: [symbol: mask]), configuration: configuration(definition))
        let excludedDate = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: source.dates[100]))
        XCTAssertFalse(masked.report.trades.contains { $0.assetSymbol == symbol && $0.date == excludedDate })
    }

    func testCancelledRunDoesNotReturnOrPersistAResult() async throws {
        let definition = try StrategyRegistry.definition(id: "nfci-dual-core-v11")
        let data = try input()
        let configuration = configuration(definition)
        let task = Task.detached { () throws -> BacktestRunResult in
            while !Task.isCancelled { await Task.yield() }
            // Cancellation is checked before a potentially expensive simulation.
            let barbell = try StrategyRegistry.definition(id: "gold-nasdaq-dual-trend-barbell")
            return try barbell.run(input: data, configuration: .init(strategy: barbell.reference,
                purpose: configuration.purpose, settings: barbell.defaultSettings))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled run returned a report") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
