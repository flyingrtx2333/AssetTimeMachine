import XCTest
import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport

final class SessionExecutionTests: XCTestCase {
    private func run(closes: [Double], opens: [Double]? = nil, fee: Double = 0,
                     weights: [Int: Double]) throws -> BacktestDailySimulationResult? {
        let start = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-01-01"))
        let dates = closes.indices.map { start.addingTimeInterval(Double($0) * 86400) }
        let option = BacktestInstrument(symbol: "SPY", title: "SPY", requiresHistoricalFX: false, historicalFXSymbol: nil)
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: ["SPY": closes],
            observedBySymbol: ["SPY": Array(repeating: true, count: closes.count)], ohlcBySymbol: [:],
            tradableSymbols: ["SPY"], optionBySymbol: ["SPY": option], simulationRange: 1...(closes.count - 1))
        return BacktestDailySimulator.run(frame: frame,
            execution: .init(initialCash: 1000, feeRate: fee, slippageRate: 0, rebalanceBand: 0,
                financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "test"),
            provider: .init { c in (weights[c.signalIndex] ?? 0) == 1 ? ["SPY": 1] : [:] },
            rebalanceDecision: { _, signal in .init(shouldRebalance: weights[signal] != nil, refreshOverlay: false) },
            executionPricesBySymbol: opens.map { ["SPY": $0] })
    }

    func testOpenFillCloseMarkAndExitFeeHandCalculation() throws {
        let result = try XCTUnwrap(run(closes: [100, 200, 900], opens: [100, 100, 120],
            fee: 0.001, weights: [0: 1, 1: 0]))
        XCTAssertEqual(result.trades.map(\.action), [.buy, .sell])
        XCTAssertEqual(result.trades[0].price, 100)
        XCTAssertEqual(result.trades[0].units, 9.99, accuracy: 1e-12)
        XCTAssertEqual(result.dailyStates[0].portfolioValue, 1998, accuracy: 1e-9)
        XCTAssertEqual(result.trades[1].price, 120)
        XCTAssertEqual(result.dailyStates[1].portfolioValue, 9.99 * 120 * 0.999, accuracy: 1e-9)
        XCTAssertEqual(result.dailyStates[0].cash, 0, accuracy: 1e-12)
    }

    func testExecutionDayCloseCannotChangeOpenSizing() throws {
        let a = try XCTUnwrap(run(closes: [100, 80, 100], opens: [100, 110, 100], weights: [0: 1]))
        let b = try XCTUnwrap(run(closes: [100, 800, 100], opens: [100, 110, 100], weights: [0: 1]))
        XCTAssertEqual(a.trades[0].units, b.trades[0].units)
        XCTAssertEqual(a.trades[0].cashAmount, b.trades[0].cashAmount)
        XCTAssertNotEqual(a.dailyStates[0].portfolioValue, b.dailyStates[0].portfolioValue)
    }

    func testMissingOpenDefersWithoutCloseFallbackAndLatestTargetWins() throws {
        let deferred = try XCTUnwrap(run(closes: [100, 500, 200, 300], opens: [100, 0, 120, 150], weights: [0: 1]))
        XCTAssertEqual(deferred.trades.count, 1)
        XCTAssertEqual(deferred.trades[0].price, 120)
        XCTAssertEqual(deferred.trades[0].date, deferred.dailyStates[1].date)
        let cancelled = try XCTUnwrap(run(closes: [100, 500, 200, 300], opens: [100, 0, 120, 150], weights: [0: 1, 1: 0]))
        XCTAssertTrue(cancelled.trades.isEmpty)
        XCTAssertTrue(cancelled.dailyStates.last!.holdingsBySymbol.isEmpty)
    }

    func testMalformedExecutionSeriesFails() throws {
        XCTAssertNil(try run(closes: [100, 100, 100], opens: [100], weights: [0: 1]))
        XCTAssertNil(try run(closes: [100, 100, 100], opens: [100, .nan, 100], weights: [0: 1]))
        XCTAssertNil(try run(closes: [100, 100, 100], opens: [100, -1, 100], weights: [0: 1]))
    }

    func testHeldPortfolioRebalanceUsesOpenNAVAndPreservesSettlement() throws {
        let start = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-01-01"))
        let dates = (0..<4).map { start.addingTimeInterval(Double($0) * 86400) }
        let symbols = ["A", "B"]
        let options = Dictionary(uniqueKeysWithValues: symbols.map { s in
            (s, BacktestInstrument(symbol: s, title: s, requiresHistoricalFX: false, historicalFXSymbol: nil))
        })
        let frame = MarketDataFrame(dates: dates,
            pricesBySymbol: ["A": [100, 100, 2000, 200], "B": [100, 100, 500, 100]],
            observedBySymbol: ["A": [true, true, true, true], "B": [true, true, true, true]],
            ohlcBySymbol: [:], tradableSymbols: symbols, optionBySymbol: options, simulationRange: 1...3)
        let result = try XCTUnwrap(BacktestDailySimulator.run(frame: frame,
            execution: .init(initialCash: 1000, feeRate: 0, slippageRate: 0, rebalanceBand: 0,
                financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "test"),
            provider: .init { $0.signalIndex == 0 ? ["A": 1] : ["A": 0.5, "B": 0.5] },
            rebalanceDecision: { _, signal in .init(shouldRebalance: signal < 2, refreshOverlay: false) },
            executionPricesBySymbol: ["A": [100, 100, 200, 200], "B": [100, 100, 100, 100]]))
        XCTAssertEqual(Array(result.trades.prefix(2)).map(\.action), [.buy, .sell])
        XCTAssertEqual(result.trades[1].units, 5, accuracy: 1e-12) // 2000 opening NAV, half sold.
        XCTAssertEqual(result.trades[1].price, 200)
        XCTAssertEqual(result.dailyStates[1].holdingsBySymbol["A"]!, 10000, accuracy: 1e-9) // Closing mark.
        let buyB = try XCTUnwrap(result.trades.first { $0.assetSymbol == "B" && $0.action == .buy })
        XCTAssertEqual(buyB.date, dates[3]) // Sale funds cannot buy at the same open.
    }

    func testExplicitCloseQuotesPreserveDefaultPathExactly() throws {
        let prices: [Double] = [100, 110, 90, 150, 80]
        let a = try XCTUnwrap(run(closes: prices, fee: 0.00025, weights: [0: 1, 2: 0]))
        let b = try XCTUnwrap(run(closes: prices, opens: prices, fee: 0.00025, weights: [0: 1, 2: 0]))
        XCTAssertEqual(a.dailyStates.map(\.portfolioValue), b.dailyStates.map(\.portfolioValue))
        XCTAssertEqual(a.dailyStates.map(\.cash), b.dailyStates.map(\.cash))
        XCTAssertEqual(a.trades.map(\.cashAmount), b.trades.map(\.cashAmount))
        XCTAssertEqual(a.trades.map(\.units), b.trades.map(\.units))
        XCTAssertEqual(a.trades.map(\.price), b.trades.map(\.price))
    }

    func testIBSExactEntryExitAndFutureIndependence() throws {
        let start = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2020-01-01"))
        var bars = (0..<40).map { i in IBSOpenScreen.Bar(date: start.addingTimeInterval(Double(i) * 86400),
            open: 109, high: 110, low: 108, close: 109) }
        bars[25] = .init(date: bars[25].date, open: 104, high: 104, low: 100, close: 100.5)
        bars[26] = .init(date: bars[26].date, open: 101, high: 105, low: 101, close: 103)
        bars[27] = .init(date: bars[27].date, open: 106, high: 109, low: 106, close: 108)
        let original = try IBSOpenScreen.desiredWeights(bars: bars, start: start)
        XCTAssertEqual(Array(original[24...28]), [0, 1, 1, 0, 0])
        XCTAssertEqual(Array(original.prefix(28)), try IBSOpenScreen.desiredWeights(bars: Array(bars.prefix(28)), start: start))
        for i in 28..<40 { bars[i] = .init(date: bars[i].date, open: 3, high: 4, low: 2, close: 3) }
        XCTAssertEqual(Array(original.prefix(28)), Array(try IBSOpenScreen.desiredWeights(bars: bars, start: start).prefix(28)))
    }
}
