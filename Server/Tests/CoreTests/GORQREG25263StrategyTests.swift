import XCTest
@testable import AssetTimeMachineBacktestCore

final class GORQREG25263StrategyTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func option(_ symbol: String) -> BacktestAssetOption {
        BacktestAssetOption(
            symbol: symbol,
            title: symbol,
            color: .blue,
            requiresHistoricalFX: false,
            historicalFXSymbol: nil
        )
    }

    private func frame(
        ratios: [Double],
        falseObservations: [String: Set<Int>] = [:],
        endIndex: Int? = nil
    ) throws -> MarketDataFrame {
        let count = endIndex.map { min($0 + 1, ratios.count) } ?? ratios.count
        let start = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2020-01-01"))
        let dates = try (0..<count).map { offset in
            try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
        }
        let symbols = [
            GORQREG25263Strategy.goldSymbol,
            GORQREG25263Strategy.oilSymbol,
            GORQREG25263Strategy.nasdaqSymbol,
            GORQREG25263Strategy.fxSymbol
        ]
        var observed: [String: [Bool]] = [:]
        for symbol in symbols {
            observed[symbol] = (0..<count).map { !(falseObservations[symbol]?.contains($0) ?? false) }
        }
        return MarketDataFrame(
            dates: dates,
            pricesBySymbol: [
                GORQREG25263Strategy.goldSymbol: Array(ratios.prefix(count)),
                GORQREG25263Strategy.oilSymbol: Array(repeating: 1, count: count),
                GORQREG25263Strategy.nasdaqSymbol: Array(repeating: 100, count: count),
                GORQREG25263Strategy.fxSymbol: Array(repeating: 7, count: count)
            ],
            observedBySymbol: observed,
            ohlcBySymbol: [:],
            tradableSymbols: [GORQREG25263Strategy.goldSymbol, GORQREG25263Strategy.nasdaqSymbol],
            optionBySymbol: [
                GORQREG25263Strategy.goldSymbol: option(GORQREG25263Strategy.goldSymbol),
                GORQREG25263Strategy.nasdaqSymbol: option(GORQREG25263Strategy.nasdaqSymbol)
            ],
            simulationRange: 1...(count - 1)
        )
    }

    private func run(
        frame: MarketDataFrame,
        schedule: FrozenTargetSchedule,
        fee: Double,
        slippage: Double
    ) throws -> BacktestDailySimulationResult {
        try XCTUnwrap(BacktestDailySimulator.run(
            frame: frame,
            execution: BacktestExecutionConfig(
                initialCash: 100_000,
                feeRate: fee,
                slippageRate: slippage,
                rebalanceBand: 0,
                financingAnnualRate: 0,
                allowsFinancedExposure: false,
                buyReason: "GOR-QREG frozen schedule test"
            ),
            provider: StrategyTargetProvider { context in
                schedule.event(signalIndex: context.signalIndex)?.targetWeights ?? [:]
            },
            rebalanceDecision: { _, _ in
                BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
            },
            contextualRebalanceDecision: { context in
                BacktestRebalanceDecision(
                    shouldRebalance: schedule.event(signalIndex: context.signalIndex) != nil,
                    refreshOverlay: false
                )
            }
        ))
    }

    func testReview252UsesExactlyPrior252RatiosExcludingCurrent() throws {
        var ratios = Array(repeating: 1.0, count: 253)
        ratios[252] = 100
        let schedule = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(frame: frame(ratios: ratios)))
        let event = try XCTUnwrap(schedule.events.first)
        XCTAssertEqual(event.signalIndex, 252)
        XCTAssertEqual(event.targetWeights, [GORQREG25263Strategy.goldSymbol: 1])
        XCTAssertEqual(event.reason, "ratio_gt_prior_252_mean")
    }

    func testFixed63CommonObservationAnchorsAndSameStateProducesNoEvent() throws {
        var changing = Array(repeating: 1.0, count: 380)
        changing[252] = 2
        changing[315] = 0.5
        changing[378] = 2
        let changingSchedule = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(frame: frame(ratios: changing)))
        XCTAssertEqual(changingSchedule.events.map(\.signalIndex), [252, 315, 378])

        var sameState = Array(repeating: 1.0, count: 380)
        sameState[252] = 2
        sameState[315] = 2
        sameState[378] = 2
        let sameSchedule = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(frame: frame(ratios: sameState)))
        XCTAssertEqual(sameSchedule.events.map(\.signalIndex), [252])
    }

    func testCommonObservationRequiresAllFourObservedAndPositive() throws {
        let required = [
            GORQREG25263Strategy.goldSymbol,
            GORQREG25263Strategy.oilSymbol,
            GORQREG25263Strategy.nasdaqSymbol,
            GORQREG25263Strategy.fxSymbol
        ]
        for symbol in required {
            var ratios = Array(repeating: 1.0, count: 254)
            ratios[253] = 2
            let shifted = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(
                frame: frame(ratios: ratios, falseObservations: [symbol: [252]])
            ))
            XCTAssertEqual(shifted.events.map(\.signalIndex), [253], symbol)
        }

        var nonPositiveRatios = Array(repeating: 1.0, count: 254)
        nonPositiveRatios[252] = 0
        nonPositiveRatios[253] = 2
        let shifted = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(frame: frame(ratios: nonPositiveRatios)))
        XCTAssertEqual(shifted.events.map(\.signalIndex), [253])
    }

    func testEqualityTargetsNasdaqAndControlsAreFrozen() throws {
        let allEqual = Array(repeating: 1.0, count: 320)
        let candidate = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(frame: frame(ratios: allEqual)))
        XCTAssertEqual(candidate.events.count, 1)
        XCTAssertEqual(candidate.events[0].targetWeights, [GORQREG25263Strategy.nasdaqSymbol: 1])
        XCTAssertEqual(candidate.events[0].reason, "ratio_le_prior_252_mean")

        let equalWeight = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(
            frame: frame(ratios: allEqual), variant: .stateIndependentEqualWeightControl
        ))
        XCTAssertEqual(equalWeight.events.count, 1)
        XCTAssertEqual(equalWeight.events[0].targetWeights, [
            GORQREG25263Strategy.goldSymbol: 0.5,
            GORQREG25263Strategy.nasdaqSymbol: 0.5
        ])

        let reversed = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(
            frame: frame(ratios: allEqual), variant: .signReversalFalsificationControl
        ))
        XCTAssertEqual(reversed.events[0].targetWeights, [GORQREG25263Strategy.goldSymbol: 1])
        XCTAssertTrue(reversed.events[0].reason.hasPrefix("sign_reversal_"))
    }

    func testStrictTMinusOneAndSellThenNextCommonDayBuy() throws {
        var ratios = Array(repeating: 1.0, count: 320)
        ratios[252] = 0.5 // Nasdaq first.
        ratios[315] = 2.0 // Then gold.
        let marketFrame = try frame(ratios: ratios)
        let schedule = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(frame: marketFrame))
        let result = try run(frame: marketFrame, schedule: schedule, fee: 0, slippage: 0)

        let nasdaqBuy = try XCTUnwrap(result.trades.first { $0.assetSymbol == GORQREG25263Strategy.nasdaqSymbol && $0.action == .buy })
        let nasdaqSell = try XCTUnwrap(result.trades.first { $0.assetSymbol == GORQREG25263Strategy.nasdaqSymbol && $0.action == .sell })
        let goldBuy = try XCTUnwrap(result.trades.first { $0.assetSymbol == GORQREG25263Strategy.goldSymbol && $0.action == .buy })
        XCTAssertEqual(nasdaqBuy.date, marketFrame.dates[253])
        XCTAssertEqual(nasdaqSell.date, marketFrame.dates[316])
        XCTAssertEqual(goldBuy.date, marketFrame.dates[317])
        XCTAssertLessThan(nasdaqSell.date, goldBuy.date)
    }

    func testOneScheduleIsCostIndependentAndQueriesCannotMutateIt() throws {
        var ratios = Array(repeating: 1.0, count: 320)
        ratios[252] = 0.5
        ratios[315] = 2
        let marketFrame = try frame(ratios: ratios)
        let schedule = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(frame: marketFrame))
        let fingerprint = schedule.fingerprint

        XCTAssertEqual(schedule.event(signalIndex: 315), schedule.event(signalIndex: 315))
        XCTAssertNil(schedule.event(signalIndex: 300))
        XCTAssertEqual(schedule.event(signalIndex: 252), schedule.events.first)
        XCTAssertEqual(schedule.fingerprint, fingerprint)

        let bps25 = try run(frame: marketFrame, schedule: schedule, fee: 0.00025, slippage: 0)
        let app = try run(frame: marketFrame, schedule: schedule, fee: 0.01, slippage: 0.0005)
        XCTAssertEqual(schedule.fingerprint, fingerprint)
        XCTAssertEqual(bps25.dailyStates.map(\.targetWeights), app.dailyStates.map(\.targetWeights))
    }

    func testSchedulePrefixIsInvariant() throws {
        var ratios = Array(repeating: 1.0, count: 420)
        ratios[252] = 2
        ratios[315] = 0.5
        ratios[378] = 2
        let fullFrame = try frame(ratios: ratios)
        let prefixFrame = try frame(ratios: ratios, endIndex: 350)
        let full = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(frame: fullFrame))
        let prefix = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(frame: prefixFrame))
        XCTAssertEqual(full.events.filter { $0.signalIndex <= 350 }, prefix.events)
    }

    func testFingerprintIncludesIndexDateWeightsAndReasonAndConstraintsHold() throws {
        let date = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-01-01"))
        let baseEvent = FrozenTargetEvent(signalIndex: 252, signalDate: date, targetWeights: ["gold_cny": 1], reason: "a")
        let base = try XCTUnwrap(FrozenTargetSchedule(events: [baseEvent]))
        let changedReason = try XCTUnwrap(FrozenTargetSchedule(events: [
            FrozenTargetEvent(signalIndex: 252, signalDate: date, targetWeights: ["gold_cny": 1], reason: "b")
        ]))
        let changedWeight = try XCTUnwrap(FrozenTargetSchedule(events: [
            FrozenTargetEvent(signalIndex: 252, signalDate: date, targetWeights: ["nasdaq": 1], reason: "a")
        ]))
        XCTAssertNotEqual(base.fingerprint, changedReason.fingerprint)
        XCTAssertNotEqual(base.fingerprint, changedWeight.fingerprint)
        XCTAssertNil(FrozenTargetSchedule(events: [
            FrozenTargetEvent(signalIndex: 1, signalDate: date, targetWeights: ["gold_cny": 1.01], reason: "invalid")
        ]))

        var ratios = Array(repeating: 1.0, count: 320)
        ratios[252] = 0.5
        ratios[315] = 2
        let marketFrame = try frame(ratios: ratios)
        let schedule = try XCTUnwrap(GORQREG25263Strategy.makeSchedule(frame: marketFrame))
        let result = try run(frame: marketFrame, schedule: schedule, fee: 0.01, slippage: 0.0005)
        for state in result.dailyStates {
            XCTAssertGreaterThanOrEqual(state.cash, -1e-8)
            XCTAssertLessThanOrEqual(state.targetWeights.values.reduce(0, +), 1 + 1e-12)
            XCTAssertTrue(state.targetWeights.values.allSatisfy { $0 >= 0 })
            let actualGross = state.portfolioValue > 0
                ? max(state.portfolioValue - state.cash, 0) / state.portfolioValue
                : 0
            XCTAssertLessThanOrEqual(actualGross, 1 + 1e-12)
        }
        XCTAssertTrue(result.trades.allSatisfy { $0.assetSymbol != GORQREG25263Strategy.oilSymbol && $0.assetSymbol != GORQREG25263Strategy.fxSymbol })
    }
}
