import XCTest
@testable import AssetTimeMachineBacktestCore

final class SettlementExecutionTests: XCTestCase {
    private func run(rising: Bool = false, closed: Set<Int> = [], fee: Double = 0.00025,
                     slip: Double = 0, band: Double = 0, boundary: Bool = false,
                     targets: [Int: [String: Double]]) throws -> BacktestDailySimulationResult {
        let first = try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: "2026-09-01"))
        let dates = (0..<12).map { first.addingTimeInterval(Double($0) * 86400) }
        let symbols = ["gold_cny", "nasdaq"]
        let options = Dictionary(uniqueKeysWithValues: BacktestCoreDefaults.strategyAssetOptions.filter { symbols.contains($0.symbol) }.map { ($0.symbol, $0) })
        let frame = MarketDataFrame(dates: dates,
            pricesBySymbol: ["gold_cny": Array(repeating: 100, count: 12), "nasdaq": dates.indices.map { rising ? 100 + Double($0) : 100 }],
            observedBySymbol: Dictionary(uniqueKeysWithValues: symbols.map { ($0, dates.indices.map { !closed.contains($0) }) }),
            ohlcBySymbol: [:], tradableSymbols: symbols, optionBySymbol: options, simulationRange: 1...11)
        let result = try XCTUnwrap(BacktestDailySimulator.run(frame: frame,
            execution: BacktestExecutionConfig(initialCash: 100_000, feeRate: fee, slippageRate: slip,
                rebalanceBand: band, tradeToBandBoundary: boundary, financingAnnualRate: 0,
                allowsFinancedExposure: false, buyReason: "settlement regression"),
            provider: StrategyTargetProvider { targets[$0.signalIndex] ?? [:] },
            rebalanceDecision: { _, signal in .init(shouldRebalance: targets[signal] != nil, refreshOverlay: false) }))
        for state in result.dailyStates {
            XCTAssertGreaterThanOrEqual(state.cash, -1e-8)
            XCTAssertEqual(state.cash + state.holdingsBySymbol.values.reduce(0, +), state.portfolioValue, accuracy: 1e-7)
            XCTAssertLessThanOrEqual(state.holdingsBySymbol.values.reduce(0, +), state.portfolioValue + 1e-7)
            XCTAssertLessThanOrEqual(state.targetWeights.values.reduce(0, +), 1 + 1e-8)
        }
        XCTAssertTrue(result.trades.allSatisfy { trade in !closed.contains(dates.firstIndex(of: trade.date)!) })
        return result
    }

    func testExistingCashBuysDespiteRepeatedRisingAssetSales() throws {
        let result = try run(rising: true, targets: [0: ["nasdaq": 0.5], 1: ["nasdaq": 0.5, "gold_cny": 0.5]])
        let buy = try XCTUnwrap(result.trades.first { $0.assetSymbol == "gold_cny" && $0.action == .buy })
        XCTAssertEqual(buy.date, result.dailyStates[1].date)
        XCTAssertNotNil(result.dailyStates.last?.holdingsBySymbol["gold_cny"])
    }

    func testSaleProceedsCannotFundSameDayFullRotation() throws {
        let result = try run(fee: 0, targets: [0: ["nasdaq": 1], 1: ["gold_cny": 1]])
        XCTAssertEqual(result.trades.map(\.action), [.buy, .sell, .buy])
        XCTAssertLessThan(result.trades[1].date, result.trades[2].date)
        XCTAssertEqual(result.trades[2].date, result.dailyStates[2].date)
    }

    func testOneShotCashSignalDuringSettlementCancelsObsoleteBuy() throws {
        let result = try run(fee: 0, targets: [0: ["nasdaq": 1], 1: ["gold_cny": 1], 2: [:]])
        XCTAssertFalse(result.trades.contains { $0.assetSymbol == "gold_cny" && $0.action == .buy })
        XCTAssertEqual(result.dailyStates.last?.targetWeights, [:])
        XCTAssertTrue(result.dailyStates.last!.holdingsBySymbol.isEmpty)
    }

    func testNewOneShotTargetDuringClosureIsNotLost() throws {
        let result = try run(closed: [1, 2], fee: 0, targets: [0: ["nasdaq": 1], 1: ["gold_cny": 1]])
        XCTAssertEqual(result.trades.count, 1)
        XCTAssertEqual(result.trades.first?.assetSymbol, "gold_cny")
        XCTAssertEqual(result.dailyStates.last?.targetWeights, ["gold_cny": 1])
    }

    func testCostsAndBandsKeepAccountingAndCompletePurchases() throws {
        for fee in [0.00025, 0.01] {
            for band in [0.0, 0.05] {
                for boundary in [false, true] {
                    let result = try run(rising: true, fee: fee, slip: 0.0005, band: band, boundary: boundary,
                        targets: [0: ["nasdaq": 1], 1: ["nasdaq": 0.5, "gold_cny": 0.5]])
                    XCTAssertNotNil(result.dailyStates[2].holdingsBySymbol["gold_cny"])
                }
            }
        }
    }

    func testPendingBuyWaitsForNextObservedSession() throws {
        let result = try run(closed: [3, 4], fee: 0, targets: [0: ["nasdaq": 1], 1: ["gold_cny": 1]])
        let sale = try XCTUnwrap(result.trades.first { $0.action == .sell })
        let buy = try XCTUnwrap(result.trades.first { $0.assetSymbol == "gold_cny" && $0.action == .buy })
        XCTAssertLessThan(sale.date, buy.date)
        XCTAssertEqual(buy.date, result.dailyStates[4].date)
    }

    func testPriceOnlyPublicCatalogDoesNotRequireMissingMacroData() {
        XCTAssertFalse(PublicBacktestCore.strategyIDs.contains("nfci-dual-core-v11"))
        XCTAssertTrue(PublicBacktestCore.forwardStrategyIDs.contains("nfci-dual-core-v11"))
    }
}
