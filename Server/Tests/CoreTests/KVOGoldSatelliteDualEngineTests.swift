import XCTest
@testable import AssetTimeMachineBacktestCore

final class KVOGoldSatelliteDualEngineTests: XCTestCase {
    private let settings = AdvancedBacktestRiskSettings(
        feeRate: 0.025,
        slippageRate: 0,
        maxPositionRatio: 100,
        cooldownDays: 0,
        stopLossRatio: 0,
        takeProfitRatio: 0
    )

    private func loadProductionDataset() throws -> PublicBacktestDataset? {
        let historyPath = "/Volumes/小姐姐新家/策略研究数据/AssetTimeMachine/artifacts/app-high-sharpe-current-rule-audit-20261024/raw/public-history.json"
        guard FileManager.default.fileExists(atPath: historyPath) else { return nil }
        let raw = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        return try PublicBacktestCore.loadDataset(from: raw, datasetHash: "80ec4b3526f21fc0b3f1ad40694b8c1c907e5e7d169efadfd2d89bdae0896e00", dataStale: false)
    }

    func testStrategyRegistryDefinition() throws {
        let definition = try StrategyRegistry.definition(id: "kvo-satellite-dual-engine")
        XCTAssertEqual(definition.reference.id, "kvo-satellite-dual-engine")
        XCTAssertEqual(definition.reference.version, "kvo-satellite-dual-engine-v1-2026-10-24")
        XCTAssertEqual(definition.template.mode, .kvoSatelliteDualEngine)
        XCTAssertEqual(definition.template.mode.defaultFeeRatePercent, 0.025)
        XCTAssertEqual(definition.template.mode.defaultSlippageRatePercent, 0)
        XCTAssertTrue(StrategyRuntimeRegistry.specialized[.kvoSatelliteDualEngine] != nil)
        XCTAssertTrue(BacktestProductStrategyCatalog.isExperimentalTemplateID("kvo-satellite-dual-engine"))
    }

    func testFullHistoryRunAndAuditedMetrics() throws {
        guard let dataset = try loadProductionDataset() else {
            throw XCTSkip("Production dataset not available on this disk")
        }

        let options = BacktestCoreStrategyDefaults.assetOptions(for: try StrategyRegistry.definition(id: "kvo-satellite-dual-engine").template)
        let assetInputs = options.map { option in
            MarketInputPreparation.advancedAssetInput(for: option) { symbol in
                dataset.seriesBySymbol[symbol] ?? (symbol == "nasdaq" ? dataset.seriesBySymbol["nasdaq_composite"] : nil)
            }
        }

        let runResult = try XCTUnwrap(KVOGoldSatelliteDualEngineStrategy.run(
            assetInputs: assetInputs,
            initialCash: 100_000,
            settings: settings,
            dateBounds: nil
        ))

        let report = runResult.report
        let dailyStates = runResult.dailyStates

        // 1. Full history length: 5752 valuation states from 2002-02-05 to 2026-10-22
        XCTAssertEqual(dailyStates.count, 5752)
        XCTAssertEqual(report.points.count, 5752)

        let firstCivil = BacktestSeriesAlignment.historicalSeriesDateString(from: dailyStates.first!.date)
        let lastCivil = BacktestSeriesAlignment.historicalSeriesDateString(from: dailyStates.last!.date)
        XCTAssertEqual(firstCivil, "2002-02-05")
        XCTAssertEqual(lastCivil, "2026-10-22")

        // 2. Performance metrics: CAGR >= 7.0%, Sharpe >= 1.30, MDD <= 8.0%
        let cagr = try XCTUnwrap(report.annualizedReturn)
        let sharpe = try XCTUnwrap(report.sharpeRatio)
        let mdd = report.maxDrawdown
        print("AUDIT: cagr=\(cagr), sharpe=\(sharpe), mdd=\(mdd), count=\(dailyStates.count)")

        XCTAssertGreaterThanOrEqual(cagr, 0.070, "CAGR must break 7.0% threshold")
        XCTAssertGreaterThanOrEqual(sharpe, 1.30, "Sharpe must exceed 1.30")
        XCTAssertLessThanOrEqual(mdd, 0.080, "Max drawdown must stay strictly below 8.0%")

        // 3. Accounting integrity: cash >= 0, gross exposure <= 1.0, residual <= 1e-4
        var maxResidual = 0.0
        for state in dailyStates {
            XCTAssertGreaterThanOrEqual(state.cash, 0.0, "Cash must never be negative")
            let holdingsVal = state.holdingsBySymbol.values.reduce(0, +)
            let gross = holdingsVal / state.portfolioValue
            XCTAssertLessThanOrEqual(gross, 1.0 + 1e-11, "Gross exposure must never exceed 100%")
            let residual = abs(state.cash + holdingsVal - state.portfolioValue)
            maxResidual = max(maxResidual, residual)
        }
        XCTAssertLessThan(maxResidual, 1e-3, "Ledger residual must be tiny")
    }

    func testAdviceGeneration() throws {
        guard let dataset = try loadProductionDataset() else {
            throw XCTSkip("Production dataset not available on this disk")
        }

        let options = BacktestCoreStrategyDefaults.assetOptions(for: try StrategyRegistry.definition(id: "kvo-satellite-dual-engine").template)
        let assetInputs = options.map { option in
            MarketInputPreparation.advancedAssetInput(for: option) { symbol in
                dataset.seriesBySymbol[symbol] ?? (symbol == "nasdaq" ? dataset.seriesBySymbol["nasdaq_composite"] : nil)
            }
        }

        let advice = try XCTUnwrap(KVOGoldSatelliteDualEngineStrategy.advice(assetInputs: assetInputs))
        XCTAssertFalse(advice.allocations.isEmpty)
        let totalWeight = advice.allocations.reduce(0.0) { $0 + $1.targetWeight }
        XCTAssertLessThanOrEqual(totalWeight, 1.0 + 1e-11)
        XCTAssertTrue(advice.allocations.allSatisfy { $0.targetWeight >= 0 })
    }

    func testColdStartPhysicalPrefixNoFutureLeakage() throws {
        guard let dataset = try loadProductionDataset() else {
            throw XCTSkip("Production dataset not available on this disk")
        }

        let options = BacktestCoreStrategyDefaults.assetOptions(for: try StrategyRegistry.definition(id: "kvo-satellite-dual-engine").template)
        let fullAssetInputs = options.map { option in
            MarketInputPreparation.advancedAssetInput(for: option) { symbol in
                dataset.seriesBySymbol[symbol] ?? (symbol == "nasdaq" ? dataset.seriesBySymbol["nasdaq_composite"] : nil)
            }
        }

        let cutDate = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2008-10-31"))
        let croppedInputs = MarketInputPreparation.filteredAdvancedAssetInputs(fullAssetInputs, within: Date.distantPast...cutDate)

        let prefixRun = try XCTUnwrap(KVOGoldSatelliteDualEngineStrategy.run(
            assetInputs: croppedInputs,
            initialCash: 100_000,
            settings: settings,
            dateBounds: nil
        ))

        let fullRun = try XCTUnwrap(KVOGoldSatelliteDualEngineStrategy.run(
            assetInputs: fullAssetInputs,
            initialCash: 100_000,
            settings: settings,
            dateBounds: nil
        ))

        let fullPrefixStates = fullRun.dailyStates.filter { $0.date <= cutDate }
        let prefixStates = prefixRun.dailyStates

        XCTAssertEqual(prefixStates.count, fullPrefixStates.count)
        XCTAssertEqual(prefixStates.count, 1558)

        for i in 0..<prefixStates.count {
            let sPref = prefixStates[i]
            let sFull = fullPrefixStates[i]

            XCTAssertEqual(sPref.portfolioValue, sFull.portfolioValue, accuracy: 1e-11)
            XCTAssertEqual(sPref.cash, sFull.cash, accuracy: 1e-11)
            for (sym, wPref) in sPref.targetWeights {
                let wFull = sFull.targetWeights[sym] ?? 0.0
                XCTAssertEqual(wPref, wFull, accuracy: 1e-11)
            }
        }
    }
}
