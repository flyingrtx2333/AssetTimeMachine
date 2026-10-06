import Foundation
import XCTest
@testable import AssetTimeMachineResearchSupport

final class MarketMindLightTests: XCTestCase {
    private func input(_ n: Int) -> ([SPYSessionInput.Bar], [[Double]]) {
        let values = (0..<n).map { i -> Double in
            let x = Double(i)
            return 100 * exp(0.0004 * x + 0.04 * sin(x / 11) + 0.01 * cos(x / 3))
        }
        let bars = values.enumerated().map { i, v in
            SPYSessionInput.Bar(date: Date(timeIntervalSince1970: Double(i) * 86400),
                open: v, high: v + 2, low: v - 2, close: v)
        }
        let sectors = (0..<9).map { j in values.enumerated().map { i, v in
            v * (1 + 0.01 * sin(Double(i) / 8 + Double(j)))
        } }
        return (bars, sectors)
    }

    func testAuthorFeatureAndNineSignalReference() throws {
        // Frozen author0.1.0 pandas signal/feature values, no account returns.
        // Exact normal-CDF erfc identity; input formula documented in feature_reference.py.
        let reference: [(Int, Double, Double, Double, Double)] = [
            (256, 0.09745775579632605, 1.0 / 3, 2.0 / 3, 0),
            (300, 0.8352799903708632, 1, 0, 2.0 / 3),
            (499, 0.7720947141570121, 1, 0, 1.0 / 3),
            (649, 0.491658743510081, 1, 1.0 / 3, 1.0 / 3),
            (699, 0.6810818920891536, 1, 0, 2.0 / 3),
            (850, 0.7527898716647659, 1, 0, 1.0 / 3),
            (999, 0.7262181440473294, 1, 1.0 / 3, 0),
        ]
        let (bars, sectors) = input(1000)
        let points = try MarketMindLightScreen.features(bars: bars, sectorCloses: sectors)
        for (index, score, trend, reversal, breakout) in reference {
            XCTAssertEqual(try XCTUnwrap(points[index].score), score, accuracy: 1e-10)
            XCTAssertEqual(points[index].trend, trend, accuracy: 1e-12)
            XCTAssertEqual(points[index].reversal, reversal, accuracy: 1e-12)
            XCTAssertEqual(points[index].breakout, breakout, accuracy: 1e-12)
        }
    }

    func testHistoryPrefixAndFutureDisturbancePreserveAllEarlierTargets() throws {
        let (bars, sectors) = input(1000)
        let full = try MarketMindLightScreen.features(bars: bars, sectorCloses: sectors)
        let prefix = try MarketMindLightScreen.features(bars: Array(bars.prefix(650)),
            sectorCloses: sectors.map { Array($0.prefix(650)) })
        XCTAssertEqual(prefix, Array(full.prefix(650)))
        let changedBars = bars.enumerated().map { i, b in
            let scale = i >= 650 ? 2.0 : 1.0
            return SPYSessionInput.Bar(date: b.date, open: b.open * scale, high: b.high * scale,
                low: b.low * scale, close: b.close * scale)
        }
        let changedSectors = sectors.map { prices in prices.enumerated().map { i, v in i >= 650 ? v * 3 : v } }
        let changed = try MarketMindLightScreen.features(bars: changedBars, sectorCloses: changedSectors)
        XCTAssertEqual(Array(changed.prefix(650)), prefix)
        XCTAssertTrue(full.allSatisfy { $0.unconditional >= 0 && $0.unconditional <= 1
            && $0.weight(category: $0.category) >= 0 && $0.weight(category: $0.category) <= 1 })
    }

    func testInvalidInputsAndUndefinedScoreDoNotProduceInventedRegimes() throws {
        let (bars, sectors) = input(300)
        XCTAssertThrowsError(try MarketMindLightScreen.features(bars: bars, sectorCloses: Array(sectors.prefix(8))))
        var bad = sectors; bad[0][0] = -.infinity
        XCTAssertThrowsError(try MarketMindLightScreen.features(bars: bars, sectorCloses: bad))
        let flat = bars.map { SPYSessionInput.Bar(date: $0.date, open: 100, high: 101, low: 99, close: 100) }
        let points = try MarketMindLightScreen.features(bars: flat,
            sectorCloses: Array(repeating: Array(repeating: 100, count: 300), count: 9))
        XCTAssertTrue(points.allSatisfy { $0.score == nil && $0.category == nil
            && $0.weight(category: $0.category) == 0 })
    }
}
