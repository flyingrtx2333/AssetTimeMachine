import XCTest
@testable import AssetTimeMachineBacktestCore

final class KVOResearchSnapshotTests: XCTestCase {
    private let settings = AdvancedBacktestRiskSettings(feeRate: 0.025, slippageRate: 0,
        maxPositionRatio: 100, cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0)

    func testOriginalRealAccountMetricsAndCausalPrefix() throws {
        let full = try XCTUnwrap(KVOResearchSnapshot.run(initialCash: 100_000, settings: settings))
        XCTAssertEqual(full.dailyStates.count, 5735)
        XCTAssertEqual(try XCTUnwrap(full.report.annualizedReturn), 0.06507971966997173, accuracy: 1e-11)
        XCTAssertEqual(try XCTUnwrap(full.report.sharpeRatio), 1.2745814030615343, accuracy: 1e-11)
        XCTAssertEqual(full.report.maxDrawdown, 0.07557506265754006, accuracy: 1e-11)
        XCTAssertEqual(full.report.trades.count, 12178)
        let cutoff = full.dailyStates[2479].date
        let prefix = try XCTUnwrap(KVOResearchSnapshot.run(initialCash: 100_000, settings: settings,
            dateBounds: full.dailyStates[0].date...cutoff))
        XCTAssertEqual(prefix.dailyStates.count, 2480)
        for (actual, expected) in zip(prefix.dailyStates, full.dailyStates) {
            XCTAssertEqual(actual.portfolioValue.bitPattern, expected.portfolioValue.bitPattern)
            XCTAssertEqual(actual.cash.bitPattern, expected.cash.bitPattern)
            XCTAssertEqual(actual.targetWeights, expected.targetWeights)
            XCTAssertEqual(actual.holdingsBySymbol, expected.holdingsBySymbol)
        }
    }

    func testCatalogAndNoStaleDailyAdvice() throws {
        let definition = try StrategyRegistry.definition(id: KVOResearchSnapshot.strategyID)
        XCTAssertEqual(definition.reference.version, "kvo-snapshot-2026-10-22")
        XCTAssertTrue(BacktestProductStrategyCatalog.isExperimentalTemplateID(definition.reference.id))
        XCTAssertFalse(BacktestCoreStrategyDefaults.eligibleTemplates.contains { $0.id == definition.reference.id })
        XCTAssertEqual(definition.template.mode.defaultFeeRatePercent, 0.025)
        XCTAssertEqual(definition.template.mode.defaultSlippageRatePercent, 0)
        XCTAssertNil(StrategyAdviceCalculator.advancedRotationRebalanceAdvice(assetInputs: [],
            mode: .kvoResearchSnapshot, settings: settings))
        let after = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-10-01"))
        XCTAssertNil(KVOResearchSnapshot.run(initialCash: 100_000, settings: settings, dateBounds: after...after))
    }
}
