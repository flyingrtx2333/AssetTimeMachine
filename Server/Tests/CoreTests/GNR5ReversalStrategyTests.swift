import XCTest
@testable import AssetTimeMachineBacktestCore

final class GNR5ReversalStrategyTests: XCTestCase {
    private func syntheticSpread(
        priorReturns: [Double],
        currentReturn: Double,
        insertedForwardFillAt: Int? = nil
    ) -> (gold: [Double], nasdaq: [Double], goldObserved: [Bool], nasdaqObserved: [Bool]) {
        var gold = [100.0]
        var nasdaq = [100.0]
        var goldObserved = [true]
        var nasdaqObserved = [true]
        for (offset, value) in (priorReturns + [currentReturn]).enumerated() {
            if insertedForwardFillAt == offset {
                gold.append(gold.last!)
                nasdaq.append(nasdaq.last!)
                goldObserved.append(false)
                nasdaqObserved.append(true)
            }
            gold.append(gold.last! * exp(value))
            nasdaq.append(nasdaq.last!)
            goldObserved.append(true)
            nasdaqObserved.append(true)
        }
        return (gold, nasdaq, goldObserved, nasdaqObserved)
    }

    private var variedPriorReturns: [Double] {
        (0..<60).map { index in index.isMultiple(of: 2) ? -0.01 : 0.01 }
    }

    func testSignalUsesExactlyPrevious60CommonReturnsExcludingCurrent() throws {
        let data = syntheticSpread(priorReturns: variedPriorReturns, currentReturn: 0.10)
        let audit = try XCTUnwrap(GNR5ReversalStrategy.signalAudit(
            signalIndex: data.gold.count - 1,
            goldPrices: data.gold,
            nasdaqPrices: data.nasdaq,
            goldObserved: data.goldObserved,
            nasdaqObserved: data.nasdaqObserved
        ))
        XCTAssertEqual(audit.priorReturnCount, 60)
        XCTAssertEqual(audit.priorMean, 0, accuracy: 1e-12)
        XCTAssertEqual(audit.currentSpreadReturn, 0.10, accuracy: 1e-12)
        XCTAssertGreaterThan(audit.zScore, 2)
    }

    func testForwardFilledDayIsExcludedFromCommonObservationWindow() throws {
        let clean = syntheticSpread(priorReturns: variedPriorReturns, currentReturn: 0.10)
        let filled = syntheticSpread(priorReturns: variedPriorReturns, currentReturn: 0.10, insertedForwardFillAt: 20)
        let cleanAudit = try XCTUnwrap(GNR5ReversalStrategy.signalAudit(
            signalIndex: clean.gold.count - 1,
            goldPrices: clean.gold,
            nasdaqPrices: clean.nasdaq,
            goldObserved: clean.goldObserved,
            nasdaqObserved: clean.nasdaqObserved
        ))
        let filledAudit = try XCTUnwrap(GNR5ReversalStrategy.signalAudit(
            signalIndex: filled.gold.count - 1,
            goldPrices: filled.gold,
            nasdaqPrices: filled.nasdaq,
            goldObserved: filled.goldObserved,
            nasdaqObserved: filled.nasdaqObserved
        ))
        XCTAssertEqual(filledAudit.priorReturnCount, 60)
        XCTAssertEqual(filledAudit.zScore, cleanAudit.zScore, accuracy: 1e-10)
    }

    func testEventIgnoresSignalsAndExitsAfterFiveSubsequentCommonObservations() throws {
        var returns = variedPriorReturns + [0.10, -0.20, 0.20, -0.20, 0.20, -0.20]
        let data = syntheticSpread(priorReturns: Array(returns.dropLast()), currentReturn: returns.removeLast())
        var runtime = GNR5ReversalStrategy.Runtime()
        _ = runtime.instruction(
            signalIndex: 0,
            goldPrices: data.gold,
            nasdaqPrices: data.nasdaq,
            goldObserved: data.goldObserved,
            nasdaqObserved: data.nasdaqObserved
        )
        let triggerIndex = 61
        let entry = try XCTUnwrap(runtime.instruction(
            signalIndex: triggerIndex,
            goldPrices: data.gold,
            nasdaqPrices: data.nasdaq,
            goldObserved: data.goldObserved,
            nasdaqObserved: data.nasdaqObserved
        ))
        XCTAssertEqual(entry.reason, .enterNasdaq)
        for index in (triggerIndex + 1)..<(triggerIndex + 5) {
            XCTAssertNil(runtime.instruction(
                signalIndex: index,
                goldPrices: data.gold,
                nasdaqPrices: data.nasdaq,
                goldObserved: data.goldObserved,
                nasdaqObserved: data.nasdaqObserved
            ))
        }
        let exit = try XCTUnwrap(runtime.instruction(
            signalIndex: triggerIndex + 5,
            goldPrices: data.gold,
            nasdaqPrices: data.nasdaq,
            goldObserved: data.goldObserved,
            nasdaqObserved: data.nasdaqObserved
        ))
        XCTAssertEqual(exit.reason, .exitToBaseline)
        XCTAssertEqual(runtime.enteredEvents, 1)
        XCTAssertEqual(runtime.exitedEvents, 1)
        XCTAssertGreaterThan(runtime.ignoredSignals, 0)
    }

    func testStrictTMinusOneTargetExecutionAndSellBeforeBuy() throws {
        let dates = try (0..<70).map { day in
            try XCTUnwrap(Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: day,
                to: XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-01-01"))
            ))
        }
        let data = syntheticSpread(
            priorReturns: variedPriorReturns + Array(repeating: 0.001, count: 8),
            currentReturn: 0.001
        )
        func option(_ symbol: String) -> BacktestAssetOption {
            BacktestAssetOption(symbol: symbol, title: symbol, color: .blue, requiresHistoricalFX: false, historicalFXSymbol: nil)
        }
        var runtime = GNR5ReversalStrategy.Runtime()
        var pending = [String: Double]()
        var targetSignalIndices: [Int] = []
        let simulation = try XCTUnwrap(BacktestDailySimulator.run(
            frame: MarketDataFrame(
                dates: dates,
                pricesBySymbol: ["gold_cny": Array(data.gold.prefix(70)), "nasdaq": Array(data.nasdaq.prefix(70))],
                observedBySymbol: ["gold_cny": Array(data.goldObserved.prefix(70)), "nasdaq": Array(data.nasdaqObserved.prefix(70))],
                ohlcBySymbol: [:],
                tradableSymbols: ["gold_cny", "nasdaq"],
                optionBySymbol: ["gold_cny": option("gold_cny"), "nasdaq": option("nasdaq")],
                simulationRange: 0...69
            ),
            execution: BacktestExecutionConfig(
                initialCash: 100_000,
                feeRate: 0,
                slippageRate: 0,
                rebalanceBand: 0,
                financingAnnualRate: 0,
                allowsFinancedExposure: false,
                buyReason: "GNR-5 test"
            ),
            provider: StrategyTargetProvider { _ in pending },
            rebalanceDecision: { _, _ in BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false) },
            contextualRebalanceDecision: { context in
                guard let instruction = runtime.instruction(
                    signalIndex: context.signalIndex,
                    goldPrices: data.gold,
                    nasdaqPrices: data.nasdaq,
                    goldObserved: data.goldObserved,
                    nasdaqObserved: data.nasdaqObserved
                ) else { return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false) }
                pending = instruction.weights
                targetSignalIndices.append(context.signalIndex)
                return BacktestRebalanceDecision(shouldRebalance: true, refreshOverlay: false)
            }
        ))
        XCTAssertFalse(targetSignalIndices.isEmpty)
        XCTAssertTrue(simulation.trades.allSatisfy { trade in
            guard let targetSignal = targetSignalIndices.last(where: { $0 < dates.firstIndex(of: trade.date)! }) else { return false }
            return targetSignal < dates.firstIndex(of: trade.date)!
        })
        let grouped = Dictionary(grouping: simulation.trades, by: { $0.date })
        XCTAssertTrue(grouped.values.allSatisfy { trades in
            let actions = trades.map(\.action)
            guard let firstBuy = actions.firstIndex(of: .buy), let lastSell = actions.lastIndex(of: .sell) else { return true }
            return lastSell < firstBuy
        })
    }

    func testTwoCostReplaysHaveSameTargetsAndRespectCashGrossConstraints() throws {
        let dates = try (0..<70).map { day in
            try XCTUnwrap(Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: day,
                to: XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-01-01"))
            ))
        }
        let data = syntheticSpread(priorReturns: variedPriorReturns + Array(repeating: 0.001, count: 8), currentReturn: 0.001)
        func run(fee: Double, slippage: Double) throws -> BacktestDailySimulationResult {
            func option(_ symbol: String) -> BacktestAssetOption {
                BacktestAssetOption(symbol: symbol, title: symbol, color: .blue, requiresHistoricalFX: false, historicalFXSymbol: nil)
            }
            var runtime = GNR5ReversalStrategy.Runtime()
            var pending = [String: Double]()
            return try XCTUnwrap(BacktestDailySimulator.run(
                frame: MarketDataFrame(
                    dates: dates,
                    pricesBySymbol: ["gold_cny": Array(data.gold.prefix(70)), "nasdaq": Array(data.nasdaq.prefix(70))],
                    observedBySymbol: ["gold_cny": Array(data.goldObserved.prefix(70)), "nasdaq": Array(data.nasdaqObserved.prefix(70))],
                    ohlcBySymbol: [:], tradableSymbols: ["gold_cny", "nasdaq"],
                    optionBySymbol: ["gold_cny": option("gold_cny"), "nasdaq": option("nasdaq")], simulationRange: 0...69
                ),
                execution: BacktestExecutionConfig(
                    initialCash: 100_000, feeRate: fee, slippageRate: slippage, rebalanceBand: 0,
                    financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "GNR-5 cost test"
                ),
                provider: StrategyTargetProvider { _ in pending },
                rebalanceDecision: { _, _ in BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false) },
                contextualRebalanceDecision: { context in
                    guard let instruction = runtime.instruction(
                        signalIndex: context.signalIndex, goldPrices: data.gold, nasdaqPrices: data.nasdaq,
                        goldObserved: data.goldObserved, nasdaqObserved: data.nasdaqObserved
                    ) else { return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false) }
                    pending = instruction.weights
                    return BacktestRebalanceDecision(shouldRebalance: true, refreshOverlay: false)
                }
            ))
        }
        let bps25 = try run(fee: 0.00025, slippage: 0)
        let app = try run(fee: 0.01, slippage: 0.0005)
        XCTAssertEqual(
            GNR5ReversalStrategy.targetFingerprint(bps25.dailyStates),
            GNR5ReversalStrategy.targetFingerprint(app.dailyStates)
        )
        for state in bps25.dailyStates + app.dailyStates {
            XCTAssertGreaterThanOrEqual(state.cash, -1e-8)
            XCTAssertLessThanOrEqual(state.targetWeights.values.reduce(0, +), 1.0 + 1e-12)
            XCTAssertTrue(state.targetWeights.values.allSatisfy { $0 >= 0 })
        }
    }
}
