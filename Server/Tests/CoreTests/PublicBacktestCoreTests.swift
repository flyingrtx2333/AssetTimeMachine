import XCTest
@testable import AssetTimeMachineBacktestCore

final class PublicBacktestCoreTests: XCTestCase {
    func testPublicBacktestFixedCostsUseCurrentProductDefaults() {
        let costs = PublicBacktestFixedCosts()

        XCTAssertEqual(costs.transactionFeeRate, 0.00025, accuracy: 0.000_000_000_1)
        XCTAssertEqual(costs.slippageRate, 0.0005, accuracy: 0.000_000_000_1)
        XCTAssertEqual(BacktestDefaults.advancedFeeRatePercent, 0.025, accuracy: 0.000_000_000_1)
        XCTAssertEqual(BacktestDefaults.advancedSlippageRatePercent, 0.05, accuracy: 0.000_000_000_1)
    }

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
        XCTAssertEqual(PublicBacktestCore.defaultEngineVersion, "atm-swift-clock-v3-2026-08-31")
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

    func testHistoricalDateParserRejectsImpossibleAndNonCanonicalDates() throws {
        XCTAssertNil(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-02-31"))
        XCTAssertNil(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-2-01"))
        XCTAssertNotNil(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-02-29"))
        let canonicalDate = try XCTUnwrap(
            BacktestSeriesAlignment.historicalSeriesDate(from: "2026-08-31")
        )
        XCTAssertEqual(canonicalDate.backtestDateString, "2026-08-31")
    }

    func testRotationDecisionClockIgnoresWeekendDatesFromAuxiliarySeries() throws {
        func date(_ value: String) throws -> Date {
            try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: value))
        }
        func prepared(
            symbol: String,
            rows: [(String, Double)]
        ) throws -> PreparedAdvancedSeries {
            let points = try rows.map { (date: try date($0.0), cnyPrice: $0.1) }
            return PreparedAdvancedSeries(
                assetOption: BacktestAssetOption(
                    symbol: symbol,
                    title: symbol,
                    color: .blue,
                    requiresHistoricalFX: false,
                    historicalFXSymbol: nil
                ),
                pricePoints: points,
                executionObservationDates: Set(points.map(\.date)),
                ohlcPoints: [],
                hypotheticalDecisionDate: nil,
                ma20: Array(repeating: nil, count: points.count),
                ma60: Array(repeating: nil, count: points.count),
                boll20: Array(repeating: nil, count: points.count)
            )
        }

        let sp500 = try prepared(
            symbol: "sp500",
            rows: [("2026-08-28", 100), ("2026-08-31", 101)]
        )
        let gold = try prepared(
            symbol: "gold_cny",
            rows: [
                ("2026-08-28", 200),
                ("2026-08-29", 201),
                ("2026-08-30", 202),
                ("2026-08-31", 203),
            ]
        )

        XCTAssertEqual(
            BacktestSeriesAlignment.rotationDecisionDates(from: [gold, sp500])
                .map(\.recordDateString),
            ["2026-08-28", "2026-08-31"]
        )

        let goldWithoutMonday = try prepared(
            symbol: "gold_cny",
            rows: [
                ("2026-08-28", 200),
                ("2026-08-29", 250),
                ("2026-08-30", 260),
            ]
        )
        let aligned = BacktestEngine.alignedRotationPriceSeries(from: [goldWithoutMonday, sp500])
        XCTAssertEqual(aligned.dates.map(\.recordDateString), ["2026-08-28"])
        XCTAssertEqual(aligned.pricesBySymbol["gold_cny"], [200])
        XCTAssertEqual(aligned.observedBySymbol["gold_cny"], [true])
    }

    func testClosedMarketDefersPendingTargetUntilARealObservation() throws {
        let dates = try ["2026-08-28", "2026-08-31", "2026-09-01"].map {
            try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: $0))
        }
        let option = BacktestAssetOption(
            symbol: "gold_cny",
            title: "黄金",
            color: .blue,
            requiresHistoricalFX: false,
            historicalFXSymbol: nil
        )
        let frame = MarketDataFrame(
            dates: dates,
            pricesBySymbol: ["gold_cny": [100, 100, 102]],
            observedBySymbol: ["gold_cny": [true, false, true]],
            ohlcBySymbol: [:],
            tradableSymbols: ["gold_cny"],
            optionBySymbol: ["gold_cny": option],
            simulationRange: 0...2
        )
        let execution = BacktestExecutionConfig(
            initialCash: 100_000,
            feeRate: 0,
            slippageRate: 0,
            rebalanceBand: 0,
            financingAnnualRate: 0,
            allowsFinancedExposure: false,
            buyReason: "test"
        )

        let result = try XCTUnwrap(BacktestDailySimulator.run(
            frame: frame,
            execution: execution,
            provider: StrategyTargetProvider { _ in ["gold_cny": 1] },
            rebalanceDecision: { index, _ in
                BacktestRebalanceDecision(shouldRebalance: index == 1, refreshOverlay: false)
            }
        ))

        XCTAssertEqual(result.trades.count, 1)
        XCTAssertEqual(result.trades.first?.date, dates[2])
        XCTAssertEqual(result.trades.first?.action, .buy)
        XCTAssertEqual(result.dailyStates[1].holdingsBySymbol["gold_cny"], nil)
        XCTAssertNotNil(result.dailyStates[2].holdingsBySymbol["gold_cny"])
    }

    func testCrossMarketRotationSettlesSellsBeforeFundingBuys() throws {
        let dates = try ["2026-08-27", "2026-08-28", "2026-08-31", "2026-09-01"].map {
            try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: $0))
        }
        func option(_ symbol: String) -> BacktestAssetOption {
            BacktestAssetOption(
                symbol: symbol,
                title: symbol,
                color: .blue,
                requiresHistoricalFX: false,
                historicalFXSymbol: nil
            )
        }
        let frame = MarketDataFrame(
            dates: dates,
            pricesBySymbol: ["china": [100, 100, 100, 100], "us": [100, 100, 100, 100]],
            observedBySymbol: ["china": [true, true, true, true], "us": [true, true, true, true]],
            ohlcBySymbol: [:],
            tradableSymbols: ["china", "us"],
            optionBySymbol: ["china": option("china"), "us": option("us")],
            simulationRange: 0...3
        )
        let execution = BacktestExecutionConfig(
            initialCash: 100_000,
            feeRate: 0,
            slippageRate: 0,
            rebalanceBand: 0,
            financingAnnualRate: 0,
            allowsFinancedExposure: false,
            buyReason: "test"
        )
        var completedIndices: [Int] = []
        let result = try XCTUnwrap(BacktestDailySimulator.run(
            frame: frame,
            execution: execution,
            provider: StrategyTargetProvider { context in
                context.index == 1 ? ["china": 1] : ["us": 1]
            },
            rebalanceDecision: { index, _ in
                BacktestRebalanceDecision(shouldRebalance: index == 1 || index == 2, refreshOverlay: false)
            },
            didExecuteTarget: { completedIndices.append($0) }
        ))

        XCTAssertEqual(completedIndices, [1, 3])
        XCTAssertEqual(result.trades.map(\.action), [.buy, .sell, .buy])
        XCTAssertEqual(result.trades[1].date, dates[2])
        XCTAssertEqual(result.trades[2].date, dates[3])
        XCTAssertEqual(result.trades[2].assetSymbol, "us")
    }

    func testHypotheticalDecisionSessionCannotExecute() throws {
        let cutoff = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-08-28"))
        let decisionDate = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-08-31"))
        let source = historySeries(
            symbol: "gold_cny",
            dates: ["2026-08-27", "2026-08-28"],
            prices: [100, 101]
        )
        let extended = try XCTUnwrap(BacktestSeriesAlignment.appendingFlatDecisionSession(
            to: source,
            cutoff: cutoff,
            decisionDate: decisionDate
        ))
        let prepared = try XCTUnwrap(BacktestAdvancedSeriesPreparer.preparedAdvancedSeries(
            assetSeries: extended,
            assetOption: BacktestAssetOption(
                symbol: "gold_cny",
                title: "黄金",
                color: .blue,
                requiresHistoricalFX: false,
                historicalFXSymbol: nil
            ),
            fxSeries: nil,
            movingAverage: { values, _ in Array(repeating: nil, count: values.count) },
            bollingerBands: { values, _, _ in Array(repeating: nil, count: values.count) }
        ))
        let aligned = BacktestEngine.alignedRotationPriceSeries(from: [prepared])
        XCTAssertEqual(aligned.dates.map(\.recordDateString), ["2026-08-27", "2026-08-28", "2026-08-31"])
        XCTAssertEqual(aligned.observedBySymbol["gold_cny"], [true, true, false])
    }

    func testLateInceptionBenchmarkKeepsReservedSleeve() throws {
        let dates = try ["2026-08-27", "2026-08-28", "2026-08-31"].map {
            try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: $0))
        }
        func option(_ symbol: String) -> BacktestAssetOption {
            BacktestAssetOption(
                symbol: symbol,
                title: symbol,
                color: .blue,
                requiresHistoricalFX: false,
                historicalFXSymbol: nil
            )
        }
        let result = try XCTUnwrap(BacktestDailySimulator.run(
            frame: MarketDataFrame(
                dates: dates,
                pricesBySymbol: ["a": [100, 101, 102], "b": [0, 50, 55]],
                observedBySymbol: ["a": [true, true, true], "b": [false, true, true]],
                ohlcBySymbol: [:],
                tradableSymbols: ["a", "b"],
                optionBySymbol: ["a": option("a"), "b": option("b")],
                simulationRange: 0...2
            ),
            execution: BacktestExecutionConfig(
                initialCash: 100_000,
                feeRate: 0,
                slippageRate: 0,
                rebalanceBand: 0,
                financingAnnualRate: 0,
                allowsFinancedExposure: false,
                buyReason: "test"
            ),
            provider: StrategyTargetProvider { _ in [:] },
            rebalanceDecision: { _, _ in
                BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
            }
        ))
        XCTAssertEqual(result.benchmarkPoints[0].portfolioValue, 100_000, accuracy: 0.000001)
        XCTAssertEqual(result.benchmarkPoints[2].portfolioValue, 106_000, accuracy: 0.000001)
    }

    func testMarketFreshnessUsesCutoffAge() throws {
        let cutoff = "2026-08-28"
        let fresh = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-03T01:00:00Z"))
        let stale = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-20T01:00:00Z"))
        XCTAssertTrue(PublicBacktestCore.isMarketDataFresh(cutoff: cutoff, asOf: fresh))
        XCTAssertFalse(PublicBacktestCore.isMarketDataFresh(cutoff: cutoff, asOf: stale))
    }

    func testMacroFreshnessUsesReleaseAvailabilityAge() throws {
        let release = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T01:00:00Z"))
        let fresh = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-22T01:00:00Z"))
        let stale = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-23T01:00:00Z"))
        XCTAssertTrue(PublicBacktestCore.isMacroDataFresh(availableAt: release, asOf: fresh))
        XCTAssertFalse(PublicBacktestCore.isMacroDataFresh(availableAt: release, asOf: stale))
    }

    func testTargetProviderCannotSeeExecutionDayPortfolioMove() throws {
        let dates = try ["2026-08-28", "2026-08-31", "2026-09-01"].map {
            try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: $0))
        }
        let option = BacktestAssetOption(
            symbol: "gold_cny",
            title: "黄金",
            color: .blue,
            requiresHistoricalFX: false,
            historicalFXSymbol: nil
        )

        func run(finalPrice: Double) throws -> (BacktestDailySimulationResult, [Double]) {
            var observedSignalValues: [Double] = []
            let frame = MarketDataFrame(
                dates: dates,
                pricesBySymbol: ["gold_cny": [100, 100, finalPrice]],
                observedBySymbol: ["gold_cny": [true, true, true]],
                ohlcBySymbol: [:],
                tradableSymbols: ["gold_cny"],
                optionBySymbol: ["gold_cny": option],
                simulationRange: 0...2
            )
            let execution = BacktestExecutionConfig(
                initialCash: 100_000,
                feeRate: 0,
                slippageRate: 0,
                rebalanceBand: 0,
                financingAnnualRate: 0,
                allowsFinancedExposure: false,
                buyReason: "test"
            )
            let result = try XCTUnwrap(BacktestDailySimulator.run(
                frame: frame,
                execution: execution,
                provider: StrategyTargetProvider { context in
                    observedSignalValues.append(context.signalPortfolioValue)
                    if context.index == 1 { return ["gold_cny": 1] }
                    return context.signalPortfolioValue >= 150_000 ? ["gold_cny": 1] : [:]
                },
                rebalanceDecision: { index, _ in
                    BacktestRebalanceDecision(shouldRebalance: index > 0, refreshOverlay: false)
                }
            ))
            return (result, observedSignalValues)
        }

        let doubled = try run(finalPrice: 200)
        let tripled = try run(finalPrice: 300)
        XCTAssertEqual(doubled.1.count, 2)
        XCTAssertEqual(tripled.1.count, 2)
        XCTAssertEqual(doubled.1[1], tripled.1[1], accuracy: 0.000001)
        XCTAssertLessThan(doubled.1[1], 150_000)
        XCTAssertTrue(doubled.0.dailyStates.last?.targetWeights.isEmpty == true)
        XCTAssertTrue(tripled.0.dailyStates.last?.targetWeights.isEmpty == true)
        XCTAssertEqual(doubled.0.trades.last?.action, .sell)
        XCTAssertEqual(tripled.0.trades.last?.action, .sell)
    }

    func testOHLCFeaturePreparationKeepsIndependentCloseWithoutChangingCanonicalPrices() throws {
        let series = historySeries(
            symbol: "gold_cny",
            dates: ["2026-08-28", "2026-08-31", "2026-09-01"],
            prices: [100, 101, 102],
            opens: [100, 101, 102],
            highs: [101, 111, 101],
            lows: [99, 100, 100],
            closes: [100, 110, 102]
        )
        let option = BacktestAssetOption(
            symbol: "gold_cny",
            title: "黄金",
            color: .blue,
            requiresHistoricalFX: false,
            historicalFXSymbol: nil
        )
        let prepared = try XCTUnwrap(BacktestAdvancedSeriesPreparer.preparedAdvancedSeries(
            assetSeries: series,
            assetOption: option,
            fxSeries: nil,
            movingAverage: { values, _ in Array(repeating: nil, count: values.count) },
            bollingerBands: { values, _, _ in Array(repeating: nil, count: values.count) }
        ))

        XCTAssertEqual(prepared.pricePoints.count, 3)
        XCTAssertEqual(prepared.pricePoints.map(\.cnyPrice), [100, 101, 102])
        XCTAssertEqual(prepared.ohlcPoints.count, 2)
        XCTAssertEqual(prepared.ohlcPoints.map(\.close), [100, 110])
    }

    func testPublicHistoryFixtureKeepsGoldCanonicalPricesAndIndependentOHLCBars() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let historyURL = root.appendingPathComponent("tools/fixtures/backtest-history/public_history.json")
        let response = try JSONDecoder().decode(
            PublicHistoryResponse.self,
            from: Data(contentsOf: historyURL)
        )
        let gold = try XCTUnwrap(response.series.first(where: { $0.symbol == "gold_cny" }))
        let prepared = try XCTUnwrap(BacktestAdvancedSeriesPreparer.preparedAdvancedSeries(
            assetSeries: gold,
            assetOption: BacktestAssetOption(
                symbol: "gold_cny",
                title: "黄金",
                color: .blue,
                requiresHistoricalFX: false,
                historicalFXSymbol: nil
            ),
            fxSeries: nil,
            movingAverage: { values, _ in Array(repeating: nil, count: values.count) },
            bollingerBands: { values, _, _ in Array(repeating: nil, count: values.count) }
        ))

        XCTAssertEqual(gold.prices.count, 6_398)
        XCTAssertEqual(prepared.pricePoints.count, 6_398)
        XCTAssertEqual(prepared.pricePoints.map(\.cnyPrice), gold.prices)
        XCTAssertEqual(gold.dailyBars.count, 6_386)
        XCTAssertEqual(prepared.ohlcPoints.count, 6_386)

        let canonicalPriceByDate = Dictionary(
            uniqueKeysWithValues: zip(prepared.pricePoints.map(\.date), prepared.pricePoints.map(\.cnyPrice))
        )
        XCTAssertTrue(prepared.ohlcPoints.contains { bar in
            guard let canonicalPrice = canonicalPriceByDate[bar.date] else { return false }
            return abs(bar.close - canonicalPrice) / canonicalPrice > 0.001
        })
    }

    func testCashAccrualUsesCalendarTimeRatherThanFrameCount() throws {
        let friday = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-08-28"))
        let saturday = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-08-29"))
        let monday = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-08-31"))
        let direct = CashYieldCNY.periodReturn(from: friday, to: monday)
        let split = (1 + CashYieldCNY.periodReturn(from: friday, to: saturday))
            * (1 + CashYieldCNY.periodReturn(from: saturday, to: monday)) - 1
        XCTAssertEqual(direct, split, accuracy: 1e-12)
        XCTAssertNotEqual(direct, CashYieldCNY.dailyReturn(on: friday), accuracy: 1e-12)
    }

    func testMetricsAnnualizeUsingObservedFrequency() throws {
        let dates = try ["2025-01-01", "2025-07-01", "2026-01-01"].map {
            try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: $0))
        }
        let values = [100.0, 110.0, 99.0]
        let points = zip(dates, values).enumerated().map { index, pair in
            BacktestSeriesPoint(date: pair.0, portfolioValue: pair.1, sequence: index)
        }
        let metrics = try XCTUnwrap(BacktestMetricsCalculator.performanceMetrics(from: points))
        let returns = [0.10, -0.10]
        let mean = returns.reduce(0, +) / Double(returns.count)
        let sampleVariance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count - 1)
        let years = 365.0 / 365.25
        let expected = sqrt(sampleVariance) * sqrt(Double(returns.count) / years)

        XCTAssertEqual(try XCTUnwrap(metrics.annualizedVolatility), expected, accuracy: 1e-12)
        XCTAssertNotEqual(try XCTUnwrap(metrics.annualizedVolatility), sqrt(sampleVariance) * sqrt(252), accuracy: 1e-6)
    }

    func testFXConverterRejectsAnIndefinitelyStaleRate() throws {
        let fxDate = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-01-02"))
        let freshDate = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2024-01-05"))
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
        XCTAssertFalse(BacktestFXConverter.hasSameSessionFXObservation(on: freshDate, fxLookup: lookup))
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
        XCTAssertNil(v1.executionDateHint)
        XCTAssertNil(v11.executionDateHint)
        XCTAssertEqual(v1.datasetHash, "forward-test-fixture")
        XCTAssertEqual(v11.datasetHash, v1.datasetHash)
        XCTAssertFalse(v1.targetFingerprint.isEmpty)
        XCTAssertFalse(v11.targetFingerprint.isEmpty)
        XCTAssertNotEqual(v1.strategyVersion, v11.strategyVersion)
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

        XCTAssertTrue(sliced.trades.isEmpty)
    }

    func testIncrementalHistoryMergePreservesEarlyRowsAndRevisesOverlap() throws {
        let existing = historySeries(
            dates: ["2026-07-01", "2026-07-02", "2026-07-03"],
            prices: [100, 101, 102],
            opens: [99, 100, 101],
            highs: [101, 102, 103],
            lows: [98, 99, 100],
            closes: [100, 101, 102],
            volumes: [10, 11, 12]
        )
        let incoming = historySeries(
            dates: ["2026-07-03", "2026-07-04"],
            prices: [102.5, 103.5],
            opens: [102, 103],
            highs: [103, 104],
            lows: [101, 102],
            closes: [102.5, 103.5],
            volumes: [22, 23]
        )

        let merged = MarketHistorySeriesMerger.merge(existing: existing, incoming: incoming)

        XCTAssertEqual(merged.dates, ["2026-07-01", "2026-07-02", "2026-07-03", "2026-07-04"])
        XCTAssertEqual(merged.prices, [100, 101, 102.5, 103.5])
        XCTAssertEqual(merged.openPrices ?? [], [99, 100, 102, 103])
        XCTAssertEqual(merged.volumes ?? [], [10, 11, 22, 23])
        XCTAssertEqual(merged.ohlcCoverageRatio, 1)
    }

    func testHistoryMergeRejectsCanonicalOutlierButKeepsIndependentValidOHLC() throws {
        let existing = historySeries(
            symbol: "test_index",
            dates: ["2026-08-27", "2026-08-28"],
            prices: [100, 101],
            opens: [100, 101],
            highs: [101, 102],
            lows: [99, 100],
            closes: [100, 101]
        )
        let incoming = PublicHistorySeries(
            symbol: "test_index",
            category: "index",
            label: "Index",
            currency: "CNY",
            unit: "index",
            source: "test",
            dates: ["2026-08-28"],
            prices: [170],
            hasOHLC: true,
            ohlcSource: "test",
            ohlcCoverageRatio: 1,
            openPrices: [50],
            highPrices: [52],
            lowPrices: [49],
            closePrices: [51],
            volumes: [1]
        )
        let merged = MarketHistorySeriesMerger.merge(existing: existing, incoming: incoming)
        XCTAssertEqual(merged.dates, ["2026-08-27", "2026-08-28"])
        XCTAssertEqual(merged.prices, [100, 101])
        XCTAssertEqual(merged.openPrices?[1], 50)
        XCTAssertEqual(merged.highPrices?[1], 52)
        XCTAssertEqual(merged.lowPrices?[1], 49)
        XCTAssertEqual(merged.closePrices?[1], 51)
    }

    func testHistoryMergeKeepsValidCachedPointWhenOverlapRevisionIsAnOutlier() throws {
        let existing = historySeries(
            symbol: "test_index",
            dates: ["2026-08-27", "2026-08-28"],
            prices: [100, 101]
        )
        let incoming = historySeries(
            symbol: "test_index",
            dates: ["2026-08-28", "2026-08-31"],
            prices: [170, 102]
        )

        let merged = MarketHistorySeriesMerger.merge(existing: existing, incoming: incoming)

        XCTAssertEqual(merged.dates, ["2026-08-27", "2026-08-28", "2026-08-31"])
        XCTAssertEqual(merged.prices, [100, 101, 102])
    }

    func testIncrementalHistoryMergeDoesNotEraseExistingOHLCWithCloseOnlyOverlap() throws {
        let existing = historySeries(
            dates: ["2026-07-01"],
            prices: [100],
            opens: [99],
            highs: [101],
            lows: [98],
            closes: [100],
            volumes: [10]
        )
        let incoming = historySeries(dates: ["2026-07-01", "2026-07-02"], prices: [100, 106])

        let merged = MarketHistorySeriesMerger.merge(existing: existing, incoming: incoming)

        XCTAssertEqual(merged.prices, [100, 106])
        XCTAssertEqual(merged.openPrices ?? [], [99, nil])
        XCTAssertEqual(merged.closePrices ?? [], [100, nil])
        XCTAssertEqual(merged.ohlcCoverageRatio, 0.5)
    }

    func testHistoryRefreshPlannerUsesOverlapOnlyWhenEverySymbolHasCache() throws {
        let cached = [
            "nasdaq": historySeries(
                symbol: "nasdaq",
                dates: (1...30).map { String(format: "2026-07-%02d", $0) },
                prices: (1...30).map(Double.init)
            ),
            "gold_cny": historySeries(
                symbol: "gold_cny",
                dates: (1...31).map { String(format: "2026-07-%02d", $0) },
                prices: (1...31).map(Double.init)
            ),
        ]

        XCTAssertEqual(
            MarketHistoryRefreshPlanner.startDate(
                symbols: ["nasdaq", "gold_cny"],
                seriesBySymbol: cached,
                overlapCalendarDays: 45
            ),
            "2026-06-15"
        )
        XCTAssertEqual(
            MarketHistoryRefreshPlanner.startDate(
                symbols: ["nasdaq", "qual"],
                seriesBySymbol: cached,
                overlapCalendarDays: 45
            ),
            "2000-01-01"
        )
    }

    func testStrategyHistorySymbolsFollowSelectedTemplateDependencies() throws {
        let standard = try XCTUnwrap(StrategyRebalanceDefaults.template(for: "nfci-dual-core-v1"))
        let quality = try XCTUnwrap(StrategyRebalanceDefaults.template(for: "nfci-dual-core-v11-qual-role"))

        XCTAssertEqual(
            StrategyRebalanceDefaults.historySymbols(for: standard),
            Set(["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite", "usd_per_cny"])
        )
        XCTAssertFalse(StrategyRebalanceDefaults.historySymbols(for: standard).contains("qual"))
        XCTAssertTrue(StrategyRebalanceDefaults.historySymbols(for: quality).contains("qual"))
    }

    func testHistoryRefreshPlannerUsesPerSymbolFreshness() throws {
        let now = try XCTUnwrap(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 8, day: 23)
            )
        )
        let dates = (1...30).map { String(format: "2026-07-%02d", $0) }
        let cached = [
            "nasdaq": historySeries(symbol: "nasdaq", dates: dates, prices: (1...30).map(Double.init)),
            "qual": historySeries(symbol: "qual", dates: dates, prices: (1...30).map(Double.init)),
        ]

        XCTAssertEqual(
            MarketHistoryRefreshPlanner.symbolsNeedingRefresh(
                requestedSymbols: Set(["nasdaq", "qual"]),
                seriesBySymbol: cached,
                refreshedAtBySymbol: [
                    "nasdaq": now,
                    "qual": now.addingTimeInterval(-13 * 60 * 60),
                ],
                now: now,
                refreshInterval: 12 * 60 * 60
            ),
            ["qual"]
        )
    }

    private func historySeries(
        symbol: String = "nasdaq",
        dates: [String],
        prices: [Double],
        opens: [Double?]? = nil,
        highs: [Double?]? = nil,
        lows: [Double?]? = nil,
        closes: [Double?]? = nil,
        volumes: [Double?]? = nil
    ) -> PublicHistorySeries {
        PublicHistorySeries(
            symbol: symbol,
            category: "index",
            label: symbol,
            currency: "USD",
            unit: "point",
            source: "fixture",
            dates: dates,
            prices: prices,
            hasOHLC: opens != nil,
            ohlcSource: opens == nil ? nil : "fixture",
            ohlcCoverageRatio: opens == nil ? nil : 1,
            openPrices: opens,
            highPrices: highs,
            lowPrices: lows,
            closePrices: closes,
            volumes: volumes
        )
    }
}
