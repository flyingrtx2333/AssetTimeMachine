import XCTest
@testable import AssetTimeMachineBacktestCore

final class RecentWindowOverlayStrategyTests: XCTestCase {
    func testCorrVarCompletionUsesPublishedMonthAndMissingMonthMeansNoExtraDeployment() {
        let source = ["gold_cny": 0.2, "nasdaq": 0.2, "sp500": 0.2]
        let published = RecentWindowOverlayStrategy.corrVarCompletedTarget(source: source, dateKey: "2026-06-15")
        let missing = RecentWindowOverlayStrategy.corrVarCompletedTarget(source: source, dateKey: "2026-07-01")
        let fraction = RecentWindowCorrVarSchedule.completionFraction(for: "2026-06-15")
        let expectedGross = 0.6 + fraction * 0.4
        XCTAssertEqual(published.values.reduce(0, +), expectedGross, accuracy: 1e-12)
        XCTAssertEqual(missing.values.reduce(0, +), 0.6, accuracy: 1e-12)
        XCTAssertEqual(published["gold_cny"]! / published["nasdaq"]!, 1, accuracy: 1e-12)
    }

    private let base: [String: Double] = [
        "gold_cny": 0.20,
        "spy_tr": 0.20,
        "oneq_tr": 0.20,
        "etf510210_cny": 0.10,
        "etf510300_cny": 0.10,
        "money511990_cny": 0.20,
    ]

    func testVolatilityManagedIdleCashDeploysOnlyAndNeverExceedsOne() throws {
        let returns = (0..<63).map { $0.isMultiple(of: 2) ? -0.002 : 0.002 }
        let result = try XCTUnwrap(RecentWindowOverlayStrategy.volatilityManagedTarget(
            base: base,
            trailingBasketReturns: returns
        ))
        XCTAssertGreaterThanOrEqual(result.multiplier, 1)
        XCTAssertGreaterThan(result.target["gold_cny"] ?? 0, base["gold_cny"] ?? 0)
        XCTAssertLessThanOrEqual(result.target.values.reduce(0, +), 1 + 1e-12)
        XCTAssertGreaterThanOrEqual(result.target["money511990_cny"] ?? 0, 0)
        XCTAssertTrue(result.target.values.allSatisfy { $0 >= 0 })
    }

    func testPairOverlayPreservesPairTotalsAndMovesAwayFromExpensiveLeg() {
        let high = RecentWindowOverlayStrategy.pairOverlayTarget(base: base, usZ: 2, chinaZ: 2)
        XCTAssertEqual((high["spy_tr"] ?? 0) + (high["oneq_tr"] ?? 0), 0.40, accuracy: 1e-12)
        XCTAssertEqual((high["etf510210_cny"] ?? 0) + (high["etf510300_cny"] ?? 0), 0.20, accuracy: 1e-12)
        XCTAssertLessThan(high["oneq_tr"] ?? 0, base["oneq_tr"] ?? 0)
        XCTAssertLessThan(high["etf510300_cny"] ?? 0, base["etf510300_cny"] ?? 0)
        XCTAssertTrue(high.values.allSatisfy { $0 >= 0 })
    }

    func testGoldEquityOverlayPreservesGrossAndTransfersProRata() {
        let high = RecentWindowOverlayStrategy.goldEquityOverlayTarget(base: base, zScore: 2)
        let low = RecentWindowOverlayStrategy.goldEquityOverlayTarget(base: base, zScore: -2)
        XCTAssertEqual(high.values.reduce(0, +), base.values.reduce(0, +), accuracy: 1e-12)
        XCTAssertEqual(low.values.reduce(0, +), base.values.reduce(0, +), accuracy: 1e-12)
        XCTAssertLessThan(high["gold_cny"] ?? 0, base["gold_cny"] ?? 0)
        XCTAssertGreaterThan(low["gold_cny"] ?? 0, base["gold_cny"] ?? 0)
        XCTAssertTrue(high.values.allSatisfy { $0 >= 0 })
        XCTAssertTrue(low.values.allSatisfy { $0 >= 0 })
    }

    func testScheduleIsStrictTMinusOneAndIgnoresExecutionDayPrice() throws {
        let dates = try (0..<300).map { offset in
            try XCTUnwrap(Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: offset,
                to: XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2025-01-01"))
            ))
        }
        func frame(lastONEQ: Double) -> MarketDataFrame {
            let symbols = Array(Set(RecentWindowOverlayStrategy.riskSymbols + [RecentWindowOverlayStrategy.moneySymbol]))
            var prices = Dictionary(uniqueKeysWithValues: symbols.map { ($0, Array(repeating: 100.0, count: dates.count)) })
            for index in dates.indices {
                prices["oneq_tr"]?[index] = 100 * exp(Double(index) * 0.002)
                prices["spy_tr"]?[index] = 100 * exp(Double(index) * 0.001)
                prices["etf510300_cny"]?[index] = 100 * exp(Double(index) * 0.0015)
                prices["etf510210_cny"]?[index] = 100 * exp(Double(index) * 0.0005)
            }
            prices["oneq_tr"]?[dates.count - 1] = lastONEQ
            let observed = Dictionary(uniqueKeysWithValues: symbols.map { ($0, Array(repeating: true, count: dates.count)) })
            return MarketDataFrame(
                dates: dates,
                pricesBySymbol: prices,
                observedBySymbol: observed,
                ohlcBySymbol: [:],
                tradableSymbols: symbols,
                optionBySymbol: [:],
                simulationRange: 0...(dates.count - 1)
            )
        }
        let baseByExecutionIndex = Dictionary(uniqueKeysWithValues: (1..<dates.count).map { ($0, base) })
        let first = try XCTUnwrap(RecentWindowOverlayStrategy.makeSchedule(
            frame: frame(lastONEQ: 1),
            baseTargetByExecutionIndex: baseByExecutionIndex,
            mode: .pairSpreadZ252Shift25
        ))
        let second = try XCTUnwrap(RecentWindowOverlayStrategy.makeSchedule(
            frame: frame(lastONEQ: 1_000_000),
            baseTargetByExecutionIndex: baseByExecutionIndex,
            mode: .pairSpreadZ252Shift25
        ))
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.events.isEmpty)
        XCTAssertTrue(first.events.allSatisfy { $0.signalIndex < dates.count - 1 })
    }

    func testFrozenCandidateSchedulesLoadAsLongOnlyGrossCappedTargets() throws {
        let start = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2002-01-01"))
        let end = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-09-05"))
        var dates: [Date] = []
        var date = start
        while date <= end {
            dates.append(date)
            date = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding: .day, value: 1, to: date))
        }
        let expectations: [(RecentWindowOverlayStrategy.Mode, Int)] = [
            (.volatilityManagedIdleCash, 2266),
            (.pairSpreadZ252Shift25, 525),
            (.goldEquityRelativeZ252Shift25, 522),
        ]
        for (mode, expectedCount) in expectations {
            let schedule = try XCTUnwrap(RecentWindowFrozenCandidateSchedules.load(mode: mode, executionDates: dates))
            XCTAssertEqual(schedule.events.count, expectedCount)
            XCTAssertTrue(schedule.events.allSatisfy { event in
                event.targetWeights.values.allSatisfy { $0 >= 0 }
                    && event.targetWeights.values.reduce(0, +) <= 1 + 1e-12
            })
        }
    }

    func testRecentModesAreExploratoryWithoutChangingDefaults() {
        XCTAssertEqual(StrategyRebalanceDefaults.defaultTemplateID, "core-gold-satellite-equity-curve-state-gate-momentum")
        XCTAssertEqual(StrategyRebalanceDefaults.recommendedTemplateID, "gold-nasdaq-dual-trend-barbell")
        let recentIDs = Set(BacktestProductStrategyCatalog.experimentalTemplateIDs)
        XCTAssertTrue(recentIDs.isSuperset(of: [
            "recent-volatility-managed-idle-cash",
            "recent-pair-spread-z252-shift25",
            "recent-gold-equity-relative-z252-shift25",
        ]))
        for mode in [
            AdvancedBacktestStrategyMode.recentVolatilityManagedIdleCash,
            .recentPairSpreadZ252Shift25,
            .recentGoldEquityRelativeZ252Shift25,
        ] {
            XCTAssertEqual(mode.defaultFeeRatePercent, 0.025, accuracy: 1e-12)
            XCTAssertEqual(mode.defaultSlippageRatePercent, 0, accuracy: 1e-12)
        }
    }
}
