import XCTest
@testable import AssetTimeMachineBacktestCore

final class PublicBacktestCoreTests: XCTestCase {
    func testQuantStrategyProxyOverridesRecordedMarketSymbol() throws {
        let category = AssetCategory(group: .financial)
        let item = AssetItem(
            name: "纳斯达克ETF",
            category: category,
            marketAssetSymbol: "record_etf:513100.sh",
            quantStrategyProxySymbol: "gold_cny"
        )
        let snapshot = AssetSnapshot(entries: [
            AssetEntry(amount: 100_000, item: item)
        ])
        let advice = StrategyRebalanceAdvice(
            strategyTitle: "测试策略",
            asOfDate: Date(timeIntervalSince1970: 1_750_000_000),
            lookbackSessions: 20,
            rebalanceSessions: 20,
            targetAnnualVolatility: nil,
            allocations: [
                .init(symbol: "gold_cny", title: "黄金", targetWeight: 0.5, momentum: nil, annualizedVolatility: nil),
                .init(symbol: "nasdaq", title: "纳指", targetWeight: 0.5, momentum: nil, annualizedVolatility: nil),
            ]
        )

        let actions = StrategyRebalanceActionBuilder.actions(
            for: advice,
            snapshot: snapshot,
            selectedAssetOptions: BacktestDefaults.dcaAssetOptions.filter { ["gold_cny", "nasdaq"].contains($0.symbol) },
            allAssetOptions: BacktestDefaults.dcaAssetOptions
        )

        let goldAction = try XCTUnwrap(actions.first(where: { $0.symbol == "gold_cny" }))
        let nasdaqAction = try XCTUnwrap(actions.first(where: { $0.symbol == "nasdaq" }))
        XCTAssertEqual(goldAction.currentAmount, 100_000)
        XCTAssertEqual(goldAction.currentWeight, 1)
        XCTAssertEqual(goldAction.matchedItemNames, ["纳斯达克ETF"])
        XCTAssertEqual(nasdaqAction.currentAmount, 0)
        XCTAssertTrue(nasdaqAction.matchedItemNames.isEmpty)
    }

    func testEngineVersionIsPinned() {
        XCTAssertFalse(PublicBacktestCore.engineVersion.isEmpty)
    }

    func testComputeInvocationRoundTripsWithoutLosingAcronymKeys() throws {
        let request = PublicBacktestRunRequest(
            strategyID: "risk-contribution-cash-confidence-low-noise",
            startDate: "2016-08-08",
            endDate: "2026-08-07",
            initialCash: 100_000
        )
        let invocation = PublicBacktestComputeInvocation(
            mode: .run,
            datasetPath: "/tmp/history.json",
            datasetHash: "fixture-hash",
            dataStale: false,
            request: request
        )

        let data = try PublicBacktestComputeCodec.makeEncoder().encode(invocation)
        let decoded = try PublicBacktestComputeCodec.makeDecoder().decode(
            PublicBacktestComputeInvocation.self,
            from: data
        )

        XCTAssertEqual(decoded.request, request)
        XCTAssertEqual(decoded.datasetHash, "fixture-hash")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"strategy_id\""))
    }

    func testBasicStrategyRequestRoundTripsWithoutLosingParameters() throws {
        let config = PublicBasicStrategyConfig(
            name: "黄金美股月度趋势",
            kind: .trendFollowing,
            allocations: [
                .init(symbol: "gold_cny", weight: 0.4),
                .init(symbol: "sp500", weight: 0.6),
            ],
            rebalance: .monthly,
            movingAverageDays: 200
        )
        let request = PublicBacktestRunRequest(
            strategyID: PublicBacktestCore.customStrategyID,
            startDate: "2016-08-08",
            endDate: "2026-08-07",
            initialCash: 100_000,
            strategyConfig: config
        )

        let data = try PublicBacktestComputeCodec.makeEncoder().encode(request)
        let decoded = try PublicBacktestComputeCodec.makeDecoder().decode(PublicBacktestRunRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"strategy_config\""))
        XCTAssertTrue(json.contains("\"moving_average_days\":200"))
    }

    func testFixedAllocationBasicStrategyRunsInsidePublicConstraints() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let historyURL = root.appendingPathComponent("tools/fixtures/backtest-history/generalization_public_history.json")
        let dataset = try PublicBacktestCore.loadDataset(
            from: Data(contentsOf: historyURL),
            datasetHash: "basic-strategy-fixture",
            dataStale: false
        )
        let request = PublicBacktestRunRequest(
            strategyID: PublicBacktestCore.customStrategyID,
            startDate: "2016-01-04",
            endDate: "2025-12-31",
            initialCash: 100_000,
            strategyConfig: .init(
                name: "黄金标普季度配置",
                kind: .fixedAllocation,
                allocations: [
                    .init(symbol: "gold_cny", weight: 0.4),
                    .init(symbol: "sp500", weight: 0.6),
                ],
                rebalance: .quarterly
            )
        )

        let result = try PublicBacktestCore.run(request: request, dataset: dataset)

        XCTAssertFalse(result.series.portfolio.isEmpty)
        XCTAssertTrue(result.metrics.endingValue.isFinite)
        XCTAssertLessThanOrEqual(result.metrics.averageGrossExposure, 1.000_001)
        XCTAssertEqual(result.requestedRange.startDate, "2016-01-04")
    }

    func testPrewarmInvocationRoundTripsStrategyID() throws {
        let invocation = PublicBacktestComputeInvocation(
            mode: .prewarm,
            datasetPath: "/tmp/history.json",
            datasetHash: "fixture-hash",
            dataStale: false,
            strategyID: "gold-nasdaq-dual-trend-barbell"
        )

        let data = try PublicBacktestComputeCodec.makeEncoder().encode(invocation)
        let decoded = try PublicBacktestComputeCodec.makeDecoder().decode(
            PublicBacktestComputeInvocation.self,
            from: data
        )

        XCTAssertEqual(decoded.strategyID, invocation.strategyID)
    }

    func testPublicCatalogUsesTheCuratedRotationRegistry() {
        XCTAssertEqual(
            PublicBacktestCore.strategyIDs,
            BacktestProductStrategyCatalog.curatedTemplateIDs
        )
        XCTAssertTrue(PublicBacktestCore.strategyIDs.contains("risk-contribution-cash-confidence-low-noise"))
        XCTAssertFalse(PublicBacktestCore.strategyIDs.contains("risk-contribution-reallocation"))
    }

    func testHistoricalDateParserRejectsImpossibleAndNonCanonicalDates() {
        XCTAssertNil(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-02-31"))
        XCTAssertNil(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-2-01"))
        XCTAssertNotNil(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-02-29"))
    }

    func testFXConverterRejectsAnIndefinitelyStaleRate() throws {
        let fxDate = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-01-02"))
        let freshDate = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-01-15"))
        let staleDate = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-03-15"))
        let lookup = BacktestHistoricalLookup(
            points: [.init(date: fxDate, price: 0.14)]
        )
        let option = BacktestAssetOption(
            symbol: "nasdaq",
            title: "纳指",
            color: .blue,
            requiresHistoricalFX: true,
            historicalFXSymbol: "usd_per_cny"
        )

        XCTAssertNotNil(BacktestFXConverter.cnyPrice(
            for: .init(date: freshDate, price: 100),
            assetOption: option,
            fxLookup: lookup
        ))
        XCTAssertNil(BacktestFXConverter.cnyPrice(
            for: .init(date: staleDate, price: 100),
            assetOption: option,
            fxLookup: lookup
        ))
    }

    func testForeignUnitsPerCNYSupportsHighJPYRates() throws {
        let date = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-01-02"))
        let lookup = BacktestHistoricalLookup(
            points: [.init(date: date, price: 20)]
        )
        let option = BacktestAssetOption(
            symbol: "nikkei",
            title: "日经225",
            color: .blue,
            requiresHistoricalFX: true,
            historicalFXSymbol: "jpy_per_cny"
        )

        XCTAssertEqual(
            try XCTUnwrap(BacktestFXConverter.cnyPrice(
                for: .init(date: date, price: 4_000),
                assetOption: option,
                fxLookup: lookup
            )),
            200,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(BacktestFXConverter.cnyMultiplier(on: date, assetOption: option, fxLookup: lookup)),
            0.05,
            accuracy: 0.000_001
        )
    }

    func testUSDAssetOHLCUsesTheSameCNYConversionAsClosePrices() throws {
        let dates = ["2024-01-02", "2024-01-03"]
        let asset = PublicHistorySeries(
            symbol: "nasdaq",
            category: "index",
            label: "Nasdaq",
            currency: "USD",
            unit: "points",
            source: "fixture",
            dates: dates,
            prices: [110, 121],
            hasOHLC: true,
            ohlcSource: "fixture",
            ohlcCoverageRatio: 1,
            openPrices: [100, 110],
            highPrices: [120, 132],
            lowPrices: [90, 99],
            closePrices: [110, 121],
            volumes: nil
        )
        let fx = PublicHistorySeries(
            symbol: "usd_per_cny",
            category: "fx",
            label: "USD/CNY",
            currency: "USD",
            unit: "rate",
            source: "fixture",
            dates: dates,
            prices: [0.2, 0.2],
            hasOHLC: false,
            ohlcSource: nil,
            ohlcCoverageRatio: nil,
            openPrices: nil,
            highPrices: nil,
            lowPrices: nil,
            closePrices: nil,
            volumes: nil
        )
        let option = BacktestAssetOption(
            symbol: "nasdaq",
            title: "纳指",
            color: .blue,
            requiresHistoricalFX: true,
            historicalFXSymbol: "usd_per_cny"
        )

        let prepared = try XCTUnwrap(BacktestAdvancedSeriesPreparer.preparedAdvancedSeries(
            assetSeries: asset,
            assetOption: option,
            fxSeries: fx,
            movingAverage: { values, _ in Array(repeating: nil, count: values.count) },
            bollingerBands: { values, _, _ in Array(repeating: nil, count: values.count) }
        ))

        XCTAssertEqual(try XCTUnwrap(prepared.pricePoints.first?.cnyPrice), 550, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(prepared.ohlcPoints.first?.open), 500, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(prepared.ohlcPoints.first?.close), 550, accuracy: 0.000_001)
    }

    func testAdvancedRecordRoundTripPreservesCombinedAndAssetCurves() throws {
        let firstDate = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-01-02"))
        let secondDate = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-01-03"))
        let strategyPoints = [
            BacktestSeriesPoint(date: firstDate, portfolioValue: 100_000, sequence: 0),
            BacktestSeriesPoint(date: secondDate, portfolioValue: 111_000, sequence: 1),
        ]
        let assetPoints = [
            BacktestSeriesPoint(date: firstDate, portfolioValue: 50_000, sequence: 0),
            BacktestSeriesPoint(date: secondDate, portfolioValue: 56_000, sequence: 1),
        ]
        let assetBenchmark = [
            BacktestSeriesPoint(date: firstDate, portfolioValue: 50_000, sequence: 0),
            BacktestSeriesPoint(date: secondDate, portfolioValue: 52_000, sequence: 1),
        ]
        let combinedBenchmark = [
            BacktestSeriesPoint(date: firstDate, portfolioValue: 100_000, sequence: 0),
            BacktestSeriesPoint(date: secondDate, portfolioValue: 105_000, sequence: 1),
        ]
        let assetReport = AdvancedBacktestAssetReport(
            symbol: "nasdaq",
            title: "纳指",
            points: assetPoints,
            benchmarkPoints: assetBenchmark,
            pricePoints: [],
            trades: [],
            finalPortfolioValue: 56_000,
            finalCash: 0,
            finalUnits: 1,
            exposureRatio: 0.5
        )
        var config = BacktestRecordConfigPayload(kind: .advanced)
        config.advancedAssetCharts = BacktestRecordCodec.advancedAssetChartPayloads(from: [assetReport])
        config.advancedBenchmarkSeries = BacktestRecordCodec.advancedBenchmarkSeriesPayloads(from: [
            AdvancedBacktestBenchmarkSeries(id: "nasdaq", title: "纳指", points: assetBenchmark)
        ])
        config.advancedCombinedBenchmarkPoints = BacktestRecordCodec.pointPayloads(from: combinedBenchmark)
        let record = BacktestRecord(
            kindRawValue: BacktestRecordKind.advanced.rawValue,
            title: "回测",
            totalReturn: 0.11,
            maxDrawdown: 0.03,
            finalValue: 111_000,
            pointsJSON: BacktestRecordCodec.pointsData(from: strategyPoints),
            configJSON: BacktestRecordCodec.configData(from: config)
        )

        let restored = try XCTUnwrap(BacktestRecordCodec.advancedReport(from: record))
        XCTAssertEqual(restored.benchmarkPoints.last?.portfolioValue, 105_000)
        XCTAssertEqual(restored.assetReports.first?.points.last?.portfolioValue, 56_000)
        XCTAssertNotEqual(
            restored.assetReports.first?.points.last?.portfolioValue,
            restored.assetReports.first?.benchmarkPoints.last?.portfolioValue
        )
    }

    func testForwardSnapshotsUseLatestRealSessionAsSignalAndKeepFrozenVersionsDistinct() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let historyURL = root.appendingPathComponent("tools/fixtures/backtest-history/generalization_public_history.json")
        let datasetData = try Data(contentsOf: historyURL)
        let dataset = try PublicBacktestCore.loadDataset(
            from: datasetData,
            datasetHash: "forward-test-fixture",
            dataStale: false
        )

        func csvPoints(_ name: String) throws -> [[String: Any]] {
            let url = root.appendingPathComponent("tools/research-results/\(name)_initial_release.csv")
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .dropFirst()
            return try lines.map { line in
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 3, let value = Double(fields[2]) else {
                    throw PublicBacktestCoreError.invalidMacroData("invalid CSV fixture")
                }
                let releaseDate = String(fields[0])
                return [
                    "release_date": releaseDate,
                    "reference_date": String(fields[1]),
                    "available_at": releaseDate + "T12:30:00Z",
                    "value": value,
                    "source": "test-initial-release",
                ]
            }
        }
        let macroObject: [String: Any] = [
            "success": true,
            "source": "test-initial-release",
            "series": [
                ["series_id": "NFCICREDIT", "points": try csvPoints("NFCICREDIT")],
                ["series_id": "NFCILEVERAGE", "points": try csvPoints("NFCILEVERAGE")],
            ],
        ]
        let macroData = try JSONSerialization.data(withJSONObject: macroObject, options: [.sortedKeys])
        let decisionAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-15T01:00:00Z"))

        let v1 = try PublicBacktestCore.forwardSnapshot(
            strategyID: "nfci-dual-core-v1",
            dataset: dataset,
            nfciData: macroData,
            decisionAt: decisionAt
        )
        let v11 = try PublicBacktestCore.forwardSnapshot(
            strategyID: "nfci-dual-core-v11",
            dataset: dataset,
            nfciData: macroData,
            decisionAt: decisionAt
        )

        XCTAssertEqual(v1.signalDate, dataset.dataCutoff)
        XCTAssertEqual(v11.signalDate, v1.signalDate)
        let cutoffDate = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: dataset.dataCutoff))
        var expectedExecutionDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: cutoffDate)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        while [1, 7].contains(calendar.component(.weekday, from: expectedExecutionDate)) {
            expectedExecutionDate = calendar.date(byAdding: .day, value: 1, to: expectedExecutionDate)!
        }
        let expectedExecutionDateText = expectedExecutionDate.recordDateString
        XCTAssertEqual(v1.executionDateHint, expectedExecutionDateText)
        XCTAssertEqual(v11.executionDateHint, v1.executionDateHint)
        XCTAssertEqual(v1.datasetHash, "forward-test-fixture")
        XCTAssertEqual(v11.datasetHash, v1.datasetHash)
        XCTAssertFalse(v1.targetFingerprint.isEmpty)
        XCTAssertFalse(v11.targetFingerprint.isEmpty)
        XCTAssertNotEqual(v1.targetFingerprint, v11.targetFingerprint)
        XCTAssertFalse(v1.causalInputFingerprint.isEmpty)
        XCTAssertEqual(v1.causalInputFingerprint, v11.causalInputFingerprint)
        XCTAssertLessThanOrEqual(v1.desiredGrossExposure, 1.000001)
        XCTAssertLessThanOrEqual(v11.desiredGrossExposure, 1.000001)
        XCTAssertLessThanOrEqual(v1.modelGrossExposure, 1.000001)
        XCTAssertLessThanOrEqual(v11.modelGrossExposure, 1.000001)
        XCTAssertEqual(v1.nfci.creditReleaseDate, v11.nfci.creditReleaseDate)
        XCTAssertEqual(v1.nfci.leverageReleaseDate, v11.nfci.leverageReleaseDate)
    }

    func testStatefulSliceDoesNotAttributePreWindowCostBasisToTheSelectedWindow() throws {
        let day0 = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-01-02"))
        let day1 = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-01-03"))
        let day2 = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-01-04"))
        let points = [
            BacktestSeriesPoint(date: day0, portfolioValue: 100_000, sequence: 0),
            BacktestSeriesPoint(date: day1, portfolioValue: 110_000, sequence: 1),
            BacktestSeriesPoint(date: day2, portfolioValue: 111_000, sequence: 2),
        ]
        let buy = AdvancedBacktestTrade(
            assetSymbol: "nasdaq",
            assetTitle: "纳指",
            date: day0,
            action: .buy,
            price: 100,
            cashAmount: 100_000,
            units: 1_000,
            reason: "买入",
            realizedProfit: nil,
            realizedReturn: nil,
            holdingDays: nil
        )
        let sell = AdvancedBacktestTrade(
            assetSymbol: "nasdaq",
            assetTitle: "纳指",
            date: day1,
            action: .sell,
            price: 110,
            cashAmount: 110_000,
            units: 1_000,
            reason: "卖出",
            realizedProfit: 10_000,
            realizedReturn: 0.10,
            holdingDays: 1
        )
        let assetReport = AdvancedBacktestAssetReport(
            symbol: "nasdaq",
            title: "纳指",
            points: points,
            benchmarkPoints: points,
            pricePoints: [],
            trades: [buy, sell],
            finalPortfolioValue: 111_000,
            finalCash: 111_000,
            finalUnits: 0,
            exposureRatio: 0.5
        )
        let report = AdvancedBacktestReport(
            points: points,
            benchmarkPoints: points,
            benchmarkSeries: [],
            trades: [buy, sell],
            assetReports: [assetReport],
            finalPortfolioValue: 111_000,
            finalCash: 111_000,
            finalUnits: 0,
            totalReturn: 0.11,
            annualizedReturn: nil,
            maxDrawdown: 0,
            annualizedVolatility: nil,
            sharpeRatio: nil,
            cashYieldSummary: CashYieldCNY.summary(
                startDate: day0,
                endDate: day2,
                totalCashInterest: 0,
                averageCashRatio: 0.5,
                averageAnnualRate: 0
            ),
            riskSignalSummary: nil
        )
        let states = [
            BacktestDailyState(
                date: day0,
                targetWeights: ["nasdaq": 1],
                cash: 0,
                holdingsBySymbol: ["nasdaq": 100_000],
                portfolioValue: 100_000
            ),
            BacktestDailyState(
                date: day1,
                targetWeights: [:],
                cash: 110_000,
                holdingsBySymbol: [:],
                portfolioValue: 110_000
            ),
            BacktestDailyState(
                date: day2,
                targetWeights: [:],
                cash: 111_000,
                holdingsBySymbol: [:],
                portfolioValue: 111_000
            ),
        ]

        let sliced = try XCTUnwrap(BacktestEngine.statefulAdvancedReport(
            from: report,
            dailyStates: states,
            within: day1...day2,
            rebasedTo: 100_000
        ))

        let inheritedSale = try XCTUnwrap(sliced.trades.first)
        XCTAssertNil(inheritedSale.realizedProfit)
        XCTAssertNil(inheritedSale.realizedReturn)
        XCTAssertNil(inheritedSale.holdingDays)
    }
}
