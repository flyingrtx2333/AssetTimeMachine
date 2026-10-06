import XCTest
@testable import AssetTimeMachineBacktestCore

final class BuyBudgetPolicyTests: XCTestCase {
    private func run(policy: BacktestBuyBudgetPolicy? = nil,
                     labels: [String] = ["A", "B", "C"], count: Int = 8,
                     futureShock: Bool = false, financed: Bool = false) throws -> BacktestDailySimulationResult? {
        let start = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-09-01"))
        let dates = (0..<count).map { start.addingTimeInterval(Double($0) * 86400) }
        let prices = dates.indices.map { futureShock && $0 >= 5 ? 10.0 : 100.0 }
        let options = Dictionary(uniqueKeysWithValues: labels.map {
            ($0, BacktestInstrument(symbol: $0, title: $0, requiresHistoricalFX: false, historicalFXSymbol: nil))
        })
        let frame = MarketDataFrame(dates: dates,
            pricesBySymbol: Dictionary(uniqueKeysWithValues: labels.map { ($0, prices) }),
            observedBySymbol: Dictionary(uniqueKeysWithValues: labels.map { ($0, Array(repeating: true, count: count)) }),
            ohlcBySymbol: [:], tradableSymbols: labels, optionBySymbol: options, simulationRange: 1...(count - 1))
        let execution = BacktestExecutionConfig(initialCash: 100_000, feeRate: 0.00025,
            slippageRate: 0.0005, rebalanceBand: 0, financingAnnualRate: 0,
            allowsFinancedExposure: financed, buyReason: "allocation counterfactual")
        let provider = StrategyTargetProvider { context in
            context.signalIndex == 0 ? [labels[0]: 0.5]
                : [labels[0]: 0.2, labels[1]: 0.4, labels[2]: 0.4]
        }
        let decision: (Int, Int) -> BacktestRebalanceDecision = { _, signal in
            .init(shouldRebalance: signal <= 1, refreshOverlay: false)
        }
        if let policy {
            return BacktestDailySimulator.run(frame: frame, execution: execution,
                provider: provider, rebalanceDecision: decision, buyBudgetPolicy: policy)
        }
        return BacktestDailySimulator.run(frame: frame, execution: execution,
            provider: provider, rebalanceDecision: decision)
    }

    private func encoded(_ states: [BacktestDailyState]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(states)
    }

    func testDefaultRetainsSymbolOrderExactly() throws {
        let implicit = try XCTUnwrap(run()), explicit = try XCTUnwrap(run(policy: .symbolOrder))
        XCTAssertEqual(try encoded(implicit.dailyStates), try encoded(explicit.dailyStates))
        XCTAssertEqual(implicit.trades.map(\.cashAmount), explicit.trades.map(\.cashAmount))
        XCTAssertGreaterThan(implicit.dailyStates[1].holdingsBySymbol["B"]!,
                             implicit.dailyStates[1].holdingsBySymbol["C"]!)
    }

    func testLimitedSettledCashIsSharedAndSaleProceedsWait() throws {
        let result = try XCTUnwrap(run(policy: .proportionalGap))
        let state = result.dailyStates[1]
        XCTAssertEqual(state.holdingsBySymbol["B"]!, state.holdingsBySymbol["C"]!, accuracy: 1e-8)
        let sameDay = result.trades.filter { $0.date == state.date }
        let buys = sameDay.filter { $0.action == .buy }.reduce(0) { $0 + $1.cashAmount }
        let previousCash = result.dailyStates[0].cash
        let settled = previousCash * (1 + CashYieldCNY.periodReturn(from: result.dailyStates[0].date, to: state.date))
        XCTAssertEqual(buys, settled, accuracy: 1e-8)
        XCTAssertEqual(state.cash, sameDay.filter { $0.action == .sell }.reduce(0) { $0 + $1.cashAmount }, accuracy: 1e-8)
        XCTAssertTrue(result.trades.contains { $0.date == result.dailyStates[2].date && $0.action == .buy })
    }

    func testRenamingSymbolsCannotFavorOneDemand() throws {
        let a = try XCTUnwrap(run(policy: .proportionalGap))
        let labels = ["Z", "Y", "A"]
        let b = try XCTUnwrap(run(policy: .proportionalGap, labels: labels))
        for (lhs, rhs) in zip(a.dailyStates, b.dailyStates) {
            XCTAssertEqual(lhs.portfolioValue, rhs.portfolioValue, accuracy: 1e-8)
            XCTAssertEqual(lhs.cash, rhs.cash, accuracy: 1e-8)
            for (old, new) in zip(["A", "B", "C"], labels) {
                XCTAssertEqual(lhs.holdingsBySymbol[old] ?? 0, rhs.holdingsBySymbol[new] ?? 0, accuracy: 1e-8)
            }
        }
    }

    func testCostsAccountingPrefixAndActualGross() throws {
        let result = try XCTUnwrap(run(policy: .proportionalGap))
        let prefix = try XCTUnwrap(run(policy: .proportionalGap, count: 5))
        let shocked = try XCTUnwrap(run(policy: .proportionalGap, futureShock: true))
        XCTAssertEqual(try encoded(Array(result.dailyStates.prefix(4))), try encoded(prefix.dailyStates))
        XCTAssertEqual(try encoded(Array(result.dailyStates.prefix(4))), try encoded(Array(shocked.dailyStates.prefix(4))))
        for state in result.dailyStates {
            let held = state.holdingsBySymbol.values.reduce(0, +)
            XCTAssertGreaterThanOrEqual(state.cash, -1e-8)
            XCTAssertEqual(state.cash + held, state.portfolioValue, accuracy: 1e-8)
            XCTAssertLessThanOrEqual(held / state.portfolioValue, 1 + 1e-12)
        }
        for buy in result.trades where buy.action == .buy {
            XCTAssertEqual(buy.units * buy.price, buy.cashAmount * (1 - 0.00025), accuracy: 1e-8)
        }
    }

    func testProportionalExperimentRejectsFinancing() throws {
        XCTAssertNil(try run(policy: .proportionalGap, financed: true))
    }
}
