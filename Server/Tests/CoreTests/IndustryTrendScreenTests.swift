import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class IndustryTrendScreenTests: XCTestCase {
    func testControlLoaderRequiresOnlyFrozenResearchDependenciesAndRejectsMissingData() throws {
        let required = ["usd_per_cny", "sp500", "gold_cny", "nasdaq_composite"]
        let series = required.map { symbol in
            PublicHistorySeries(symbol: symbol, category: "test", label: symbol,
                currency: "USD", unit: "price", source: "fixture",
                dates: ["2026-10-01", "2026-10-02"], prices: [100, 101],
                hasOHLC: nil, ohlcSource: nil, ohlcCoverageRatio: nil,
                openPrices: nil, highPrices: nil, lowPrices: nil, closePrices: nil, volumes: nil)
        }
        let response = PublicHistoryResponse(success: true, series: series, availableSymbols: nil, catalog: nil)
        XCTAssertEqual(Set(try IndustryTrendScreen.loadControlSeries(from: JSONEncoder().encode(response)).keys), Set(required))
        let missing = PublicHistoryResponse(success: true, series: Array(series.dropLast()), availableSymbols: nil, catalog: nil)
        XCTAssertThrowsError(try IndustryTrendScreen.loadControlSeries(from: JSONEncoder().encode(missing)))
        let duplicate = PublicHistoryResponse(success: true, series: series + [series[0]], availableSymbols: nil, catalog: nil)
        XCTAssertThrowsError(try IndustryTrendScreen.loadControlSeries(from: JSONEncoder().encode(duplicate)))
    }

    private func dates(_ count: Int) -> [String] {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let start = Date(timeIntervalSince1970: 1577836800)
        return (0..<count).map { formatter.string(from: start.addingTimeInterval(Double($0) * 86400)) }
    }

    func testFuturePricesCannotChangeEarlierStateOrWeights() throws {
        let p = (0..<180).map { 100 + Double($0) * 0.2 + sin(Double($0) / 4) * 2 }
        let original = try IndustryTrendScreen.signals(prices: p)
        let prefix = try IndustryTrendScreen.signals(prices: Array(p.prefix(110)))
        let changed = try IndustryTrendScreen.signals(prices:
            p.enumerated().map { $0.offset < 110 ? $0.element : $0.element * 0.01 })
        XCTAssertEqual(Array(original.prefix(110)), prefix)
        XCTAssertEqual(Array(changed.prefix(110)), prefix)
        let d = dates(p.count)
        let a = IndustryTrendScreen.Series(symbol: "A", dates: d, prices: p)
        let b = IndustryTrendScreen.Series(symbol: "A", dates: d,
            prices: p.enumerated().map { $0.offset < 110 ? $0.element : $0.element * 0.01 })
        XCTAssertEqual(IndustryTrendScreen.weights(series: [a], indicators: [original], asOf: d[109]),
            IndustryTrendScreen.weights(series: [b], indicators: [changed], asOf: d[109]))
    }

    func testWarmupLaggedEntryCrashExitAndRatchetingStop() throws {
        let prices: [Double] = (0..<90).map { index -> Double in
            if index < 70 { return 100.0 + Double(index) }
            return 40.0 + Double(index - 70) * 0.1
        }
        let signals = try IndustryTrendScreen.signals(prices: prices)
        XCTAssertFalse(signals[39].long)
        XCTAssertTrue(signals[40].long)
        XCTAssertTrue(signals[69].long)
        XCTAssertFalse(signals[70].long)
        XCTAssertNil(signals[70].stop)
        for i in 41..<70 {
            XCTAssertGreaterThanOrEqual(signals[i].stop!, signals[i - 1].stop!)
        }
    }

    func testUnlistedAssetsNeverAffectEarlierWeightsAndGrossCap() throws {
        let p = (0..<120).map { 100 + Double($0) * 0.2 + sin(Double($0)) * 0.02 }
        let d = dates(p.count), indicators = try IndustryTrendScreen.signals(prices: p)
        let existing = IndustryTrendScreen.Series(symbol: "A", dates: d, prices: p)
        let future = IndustryTrendScreen.Series(symbol: "B", dates: Array(d.suffix(10)), prices: Array(p.suffix(10)))
        let futureSignals = try IndustryTrendScreen.signals(prices: future.prices)
        let before = IndustryTrendScreen.weights(series: [existing], indicators: [indicators], asOf: d[80])
        XCTAssertEqual(before, IndustryTrendScreen.weights(series: [existing, future],
            indicators: [indicators, futureSignals], asOf: d[80]))
        XCTAssertNil(IndustryTrendScreen.weights(series: [existing, future],
            indicators: [indicators, futureSignals], asOf: d[115])["B"])
        let many = (0..<10).map { IndustryTrendScreen.Series(symbol: "S\($0)", dates: d, prices: p) }
        let weights = IndustryTrendScreen.weights(series: many,
            indicators: Array(repeating: indicators, count: many.count), asOf: d[119])
        XCTAssertFalse(weights.isEmpty)
        XCTAssertLessThanOrEqual(weights.values.reduce(0, +), 1 + 1e-12)
        XCTAssertTrue(weights.values.allSatisfy { $0 <= 0.2 && $0 >= 0 })
    }

    func testFlatAndInvalidPricesDoNotCreateFinancedExposure() throws {
        let signals = try IndustryTrendScreen.signals(prices: Array(repeating: 100, count: 100))
        XCTAssertTrue(signals.allSatisfy { !$0.long })
        XCTAssertThrowsError(try IndustryTrendScreen.signals(prices: [100, 0]))
        XCTAssertThrowsError(try IndustryTrendScreen.signals(prices: [100, .nan]))
    }

    func testCashOnlyExcessSharpeDoesNotBecomeAStrategyWin() {
        let d = dates(40).map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        var cash = 100000.0
        var states: [BacktestDailyState] = []
        for i in d.indices {
            if i > 0 { cash *= 1 + CashYieldCNY.periodReturn(from: d[i - 1], to: d[i]) }
            states.append(.init(date: d[i], targetWeights: [:], cash: cash,
                holdingsBySymbol: [:], portfolioValue: cash))
        }
        let sharpe = IndustryTrendScreen.excessSharpe(states: states)
        // Floating point rounding can create tiny variance; it must not certify 1.2.
        XCTAssertTrue(sharpe == nil || abs(sharpe!) < 1.2)
    }
}
