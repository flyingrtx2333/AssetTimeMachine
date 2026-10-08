import XCTest
@testable import AssetTimeMachineBacktestCore

final class CashDistributionTests: XCTestCase {
    private let dayStrings = ["2026-08-28", "2026-08-31", "2026-09-01", "2026-09-02",
                              "2026-09-03", "2026-09-04", "2026-09-08"]
    private var dates: [Date] {
        let formatter = ISO8601DateFormatter()
        return dayStrings.map { formatter.date(from: $0 + "T12:00:00Z")! }
    }
    // Actual BIL ex/pay dates and cash amount from State Street's historical
    // distribution workbook. Prices below are synthetic accounting fixtures.
    // https://www.ssga.com/library-content/products/fund-data/etfs/us/spdr-etf-historical-distributions.xlsx
    private func event(id: String = "BIL:2026-09-01", exIndex: Int = 2,
                       payIndex: Int = 5, symbol: String = "BIL", tax: Double = 0) -> BacktestCashDistribution {
        .init(id: id, symbol: symbol, exDate: dates[exIndex], paymentDate: dates[payIndex],
              currencyCode: "USD", amountPerUnit: 0.279771, withholdingRate: tax)
    }

    private func run(events: [BacktestCashDistribution] = [], fx: [String: [Double]]? = nil,
                     targets: [Int: [String: Double]] = [0: ["BIL": 1]],
                     cutoff: Int = 6, futureFX: Bool = false) -> BacktestDailySimulationResult? {
        let days = dates
        let prices = days.indices.map { $0 < 2 ? 100.0 : 100.0 - 0.279771 }
        let symbols = ["BIL"]
        let frame = MarketDataFrame(dates: days, pricesBySymbol: ["BIL": prices],
            observedBySymbol: ["BIL": Array(repeating: true, count: days.count)],
            ohlcBySymbol: [:], tradableSymbols: symbols,
            optionBySymbol: ["BIL": .init(symbol: "BIL", title: "BIL", requiresHistoricalFX: false,
                                        historicalFXSymbol: nil)], simulationRange: 1...cutoff)
        var rates = Array(repeating: 1.0, count: days.count)
        if futureFX { rates[6] = 100 }
        return BacktestDailySimulator.run(frame: frame,
            execution: .init(initialCash: 10_000, feeRate: 0, slippageRate: 0, rebalanceBand: 0,
                             financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixture"),
            provider: .init { targets[$0.signalIndex] ?? [:] },
            rebalanceDecision: { _, signal in .init(shouldRebalance: targets[signal] != nil, refreshOverlay: false) },
            cashDistributions: events, distributionFXToBaseBySymbol: fx ?? ["BIL": rates])
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    func testPriceOnlyEncodingAndOldSavedStateRemainCompatible() throws {
        let result = try XCTUnwrap(run())
        XCTAssertTrue(result.distributionEntitlements.isEmpty)
        XCTAssertTrue(result.dailyStates.allSatisfy { $0.distributionReceivable == nil })
        let original = result.dailyStates[0]
        let bytes = try encoded(original)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("distributionReceivable"))
        let decoded = try JSONDecoder().decode(BacktestDailyState.self, from: bytes)
        XCTAssertNil(decoded.distributionReceivable)
        XCTAssertEqual(decoded.portfolioValue, original.portfolioValue)
    }

    func testExDateReceivablePreservesNAVWithoutSpendingOrInterest() throws {
        let result = try XCTUnwrap(run(events: [event()]))
        let exDay = result.dailyStates[1]
        XCTAssertEqual(exDay.distributionReceivable!, 100 * 0.279771, accuracy: 1e-10)
        XCTAssertEqual(exDay.portfolioValue, 10_000, accuracy: 1e-8)
        XCTAssertEqual(exDay.cash, 0)
        XCTAssertEqual(result.dailyStates[3].cash, 0)
        XCTAssertEqual(result.cashYieldSummary.totalCashInterest, result.dailyStates.last!.cash - 100 * 0.279771, accuracy: 1e-8)
        for state in result.dailyStates {
            XCTAssertEqual(state.cash + state.holdingsBySymbol.values.reduce(0, +)
                           + (state.distributionReceivable ?? 0), state.portfolioValue, accuracy: 1e-8)
        }
    }

    func testExDateSaleRetainsClaimAndExDatePurchaseDoesNotEarnIt() throws {
        let sold = try XCTUnwrap(run(events: [event()], targets: [0: ["BIL": 1], 1: [:]]))
        XCTAssertTrue(sold.dailyStates[1].holdingsBySymbol.isEmpty)
        XCTAssertEqual(sold.distributionEntitlements[0].eligibleUnits, 100)
        XCTAssertEqual(sold.distributionEntitlements[0].paidAmountInBaseCurrency!, 27.9771, accuracy: 1e-8)
        let bought = try XCTUnwrap(run(events: [event()], targets: [1: ["BIL": 1]]))
        XCTAssertTrue(bought.distributionEntitlements.isEmpty)
        XCTAssertEqual(bought.dailyStates[1].distributionReceivable, 0)
    }

    func testPayDateCashCannotFundSameSessionAndCanFundNextSession() throws {
        let result = try XCTUnwrap(run(events: [event()],
            targets: [0: ["BIL": 1], 4: ["BIL": 1], 5: ["BIL": 1]]))
        XCTAssertFalse(result.trades.contains { $0.action == .buy && $0.date == dates[5] })
        XCTAssertTrue(result.trades.contains { $0.action == .buy && $0.date == dates[6] })
        XCTAssertEqual(result.distributionEntitlements[0].paidOn, dates[5])
        XCTAssertEqual(result.dailyStates[4].cash, 27.9771, accuracy: 1e-8)
    }

    func testWithholdingFXAndUnpaidTerminalReceivable() throws {
        let result = try XCTUnwrap(run(events: [event(tax: 0.2)],
            fx: ["BIL": [1, 1, 2, 3, 4, 5, 6]], cutoff: 4))
        XCTAssertNil(result.distributionEntitlements[0].paidOn)
        XCTAssertEqual(result.dailyStates.last!.distributionReceivable!, 27.9771 * 0.8 * 4, accuracy: 1e-8)
        XCTAssertEqual(result.finalCash, 0)
        let paid = try XCTUnwrap(run(events: [event(tax: 0.2)], fx: ["BIL": [1, 1, 2, 3, 4, 5, 6]]))
        XCTAssertEqual(paid.distributionEntitlements[0].paidAmountInBaseCurrency!, 27.9771 * 0.8 * 5, accuracy: 1e-8)
    }

    func testInvalidOrDuplicateEventsAndMissingFXAreRejected() {
        XCTAssertNil(run(events: [event(), event()]))
        XCTAssertNil(run(events: [event(), event(id: "different-id")]))
        XCTAssertNil(run(events: [event(payIndex: 1)]))
        XCTAssertNil(run(events: [event(symbol: "UNKNOWN")]))
        XCTAssertNil(run(events: [event(tax: 1.1)]))
        XCTAssertNil(run(events: [event()], fx: [:]))
        XCTAssertNil(run(events: [event()], fx: ["BIL": [1, 1]]))
        XCTAssertNil(run(events: [event()], fx: ["BIL": [1, 1, 1, 1, 1, 1, .nan]]))
    }

    func testFutureFXDoesNotChangeEarlierTradesOrStates() throws {
        let baseline = try XCTUnwrap(run(events: [event()]))
        let shocked = try XCTUnwrap(run(events: [event()], futureFX: true))
        XCTAssertEqual(try encoded(Array(baseline.dailyStates.prefix(5))), try encoded(Array(shocked.dailyStates.prefix(5))))
        XCTAssertEqual(baseline.trades.map(\.date), shocked.trades.map(\.date))
        XCTAssertEqual(baseline.trades.map(\.cashAmount), shocked.trades.map(\.cashAmount))
        XCTAssertEqual(baseline.trades.map(\.units), shocked.trades.map(\.units))
    }

    func testClosingFXDoesNotChangeSameDayRebalance() throws {
        let targets = [0: ["BIL": 1.0], 2: ["BIL": 0.5]]
        let baseline = try XCTUnwrap(run(events: [event()], targets: targets))
        let shocked = try XCTUnwrap(run(events: [event()], fx: ["BIL": [1, 1, 1, 100, 1, 1, 1]], targets: targets))
        let originalTrades = baseline.trades.filter { $0.date == dates[3] }
        let shockedTrades = shocked.trades.filter { $0.date == dates[3] }
        XCTAssertFalse(originalTrades.isEmpty)
        XCTAssertEqual(originalTrades.map(\.cashAmount), shockedTrades.map(\.cashAmount))
        XCTAssertEqual(originalTrades.map(\.units), shockedTrades.map(\.units))
        XCTAssertGreaterThan(shocked.dailyStates[2].portfolioValue, baseline.dailyStates[2].portfolioValue)
    }

    func testSplitPreservesNAVAndCostBasisAndDoesNotResizeExistingClaim() throws {
        let days = dates
        let split = BacktestShareSplit(id: "BIL-split", symbol: "BIL", effectiveDate: days[3], newUnitsPerOldUnit: 0.5)
        let prices = [100.0, 100.0, 100.0 - 0.279771, 2 * (100.0 - 0.279771),
                      2 * (100.0 - 0.279771), 2 * (100.0 - 0.279771), 2 * (100.0 - 0.279771)]
        let frame = MarketDataFrame(dates: days, pricesBySymbol: ["BIL": prices],
            observedBySymbol: ["BIL": Array(repeating: true, count: days.count)], ohlcBySymbol: [:],
            tradableSymbols: ["BIL"], optionBySymbol: ["BIL": .init(symbol: "BIL", title: "BIL",
                requiresHistoricalFX: false, historicalFXSymbol: nil)], simulationRange: 1...6)
        func simulate(_ splits: [BacktestShareSplit]) -> BacktestDailySimulationResult? {
            BacktestDailySimulator.run(frame: frame, execution: .init(initialCash: 10_000, feeRate: 0,
                slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixture"),
                provider: .init { $0.signalIndex == 0 ? ["BIL": 1] : [:] },
                rebalanceDecision: { _, signal in .init(shouldRebalance: signal == 0 || signal == 3, refreshOverlay: false) },
                cashDistributions: [event()], distributionFXToBaseBySymbol: ["BIL": Array(repeating: 1, count: days.count)],
                shareSplits: splits)
        }
        let result = try XCTUnwrap(simulate([split]))
        XCTAssertEqual(result.dailyStates[2].portfolioValue, 10_000, accuracy: 1e-8)
        XCTAssertEqual(result.benchmarkPoints[2].portfolioValue, 10_000 - 27.9771, accuracy: 1e-8)
        XCTAssertEqual(result.splitAdjustments[0].previousUnits, 100)
        XCTAssertEqual(result.splitAdjustments[0].resultingUnits, 50)
        let sale = try XCTUnwrap(result.trades.first { $0.action == .sell })
        XCTAssertEqual(sale.units, 50)
        XCTAssertEqual(sale.realizedProfit!, -27.9771, accuracy: 1e-8)
        XCTAssertEqual(result.distributionEntitlements[0].eligibleUnits, 100)
        XCTAssertEqual(result.distributionEntitlements[0].paidAmountInBaseCurrency!, 27.9771, accuracy: 1e-8)
        XCTAssertNil(simulate([split, split]))
    }
}
