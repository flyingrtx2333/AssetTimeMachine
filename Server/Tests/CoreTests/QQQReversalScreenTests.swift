import XCTest
import AssetTimeMachineResearchSupport

final class QQQReversalScreenTests: XCTestCase {
    private func bars(_ closes: [Double], locations: [Double]? = nil) -> [QQQReversalScreen.Bar] {
        closes.indices.map { i in
            let close = closes[i], location = locations?[i] ?? 0.2
            return .init(date: Date(timeIntervalSince1970: Double(i) * 86400),
                         open: close, high: close + (1 - location) * 5,
                         low: close - location * 5, close: close)
        }
    }

    func testCutlerHandVectorAndLatentFilteredPosition() throws {
        let b = bars([100, 98, 96, 94, 95, 97, 100], locations: [0.5, 0.5, 0.5, 0.8, 0.2, 0.2, 0.2])
        let s = try QQQReversalScreen.signals(bars: b, splits: [:])
        XCTAssertNil(s[2].rsi3)
        XCTAssertEqual(s[3].rsi3!, 0, accuracy: 1e-12)
        XCTAssertEqual(s[4].rsi3!, 20, accuracy: 1e-12)
        XCTAssertEqual(s[5].rsi3!, 60, accuracy: 1e-12)
        XCTAssertEqual(s[3].weights["rsi3"], 1)
        XCTAssertEqual(s[3].weights["rsi3-ibs05"], 0)
        XCTAssertEqual(s[4].weights["rsi3-ibs05"], 1) // Latent RSI holding survives the IBS veto.
        XCTAssertEqual(s[5].weights["rsi3"], 0)
        XCTAssertEqual(s[4].weights["ibs02"], 1)
        let flat = (0..<4).map { i in QQQReversalScreen.Bar(date: b[i].date, open: 100, high: 100, low: 100, close: 100) }
        let f = try QQQReversalScreen.signals(bars: flat, splits: [:])
        XCTAssertEqual(f[3].rsi3, 100)
        XCTAssertEqual(f[3].ibs, 0.5)
        XCTAssertEqual(f[3].weights["rsi3"], 0)
        XCTAssertEqual(f[3].weights["ibs02"], 0)
    }

    func testEffectiveSplitDoesNotManufactureOversoldSignal() throws {
        let b = bars([100, 100, 100, 50, 50, 50])
        let s = try QQQReversalScreen.signals(bars: b, splits: [b[3].date: 2])
        XCTAssertTrue(s.allSatisfy { abs($0.splitContinuousClose - 100) < 1e-12 })
        XCTAssertEqual(s[3].rsi3, 100)
        XCTAssertEqual(s[3].weights["rsi3"], 0)
        let bad = try QQQReversalScreen.signals(bars: b, splits: [:])
        XCTAssertEqual(bad[3].rsi3, 0)
        XCTAssertEqual(bad[3].weights["rsi3"], 1)
    }

    func testFuturePricesAndFutureSplitsCannotChangePastSignals() throws {
        let b = bars((0..<400).map { 100 + 15 * sin(Double($0) / 5) })
        let original = try QQQReversalScreen.signals(bars: b, splits: [:])
        let prefix = try QQQReversalScreen.signals(bars: Array(b.prefix(280)), splits: [:])
        var changed = b
        for i in 280..<400 {
            changed[i] = .init(date: b[i].date, open: b[i].open * 10, high: b[i].high * 10,
                              low: b[i].low * 10, close: b[i].close * 10)
        }
        let future = try QQQReversalScreen.signals(bars: changed, splits: [b[300].date: 2])
        XCTAssertEqual(Array(original.prefix(280)), prefix)
        XCTAssertEqual(Array(original.prefix(280)), Array(future.prefix(280)))
        XCTAssertTrue(original.contains { $0.weights["rsi3"] == 1 })
    }
}
