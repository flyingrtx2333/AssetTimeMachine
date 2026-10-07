import XCTest
@testable import AssetTimeMachineResearchSupport

final class SectorResidualMomentumScreenTests: XCTestCase {
    func testFormationSkipsLastMonthAndDoesNotSubtractFittedAlpha() throws {
        let market = (0..<36).map { $0 % 2 == 0 ? -0.02 : 0.02 }
        let noise = [0.002, -0.001, 0.003, 0.002, -0.001, 0.003]
        let asset = market.indices.map { 0.01 + 2 * market[$0] + noise[$0 % 6] }
        // Noise is orthogonal to market over all36 points, hence beta exactly2.
        let expectedResidual = (24..<35).map { 0.01 + noise[$0 % 6] }
        let mean = expectedResidual.reduce(0, +) / 11
        let sd = sqrt(expectedResidual.reduce(0) { $0 + pow($1 - mean, 2) } / 10)
        XCTAssertEqual(try SectorResidualMomentumScreen.residualScore(asset: asset, market: market), mean / sd, accuracy: 1e-10)
        XCTAssertThrowsError(try SectorResidualMomentumScreen.residualScore(asset: asset, market: Array(repeating: 0, count: 36)))
    }

    private func input(count: Int = 112, shock: Int? = nil) -> [SectorMonthstartScreen.Series] {
        (SectorMonthstartScreen.symbols + ["SPY"]).enumerated().map { j, symbol in
            var price = 100.0
            let bars = (0..<count).map { i -> SectorMonthstartScreen.Bar in
                let month = i / 2
                if i % 2 == 0 {
                    let factor = month % 2 == 0 ? 0.01 : 0.03
                    let residual = 0.001 * Double(j + 1) * (month % 3 == 0 ? -1 : 1)
                    price *= 1 + factor + (symbol == "SPY" ? 0 : residual)
                }
                let p = shock.map { i >= $0 ? price * 3 : price } ?? price
                let date = String(format: "%04d-%02d-%02d", 2000 + month / 12, month % 12 + 1, i % 2 == 0 ? 1 : 28)
                return .init(date: date, open: p, high: p + 1, low: p - 1, close: p)
            }
            return .init(symbol: symbol, bars: bars)
        }
    }

    func testPrefixCausalityAndCurrentQuoteCannotEnterMonthlyReview() throws {
        let full = try SectorResidualMomentumScreen.reviews(series: input())
        let prefix = try SectorResidualMomentumScreen.reviews(series: input(count: 100))
        let changed = try SectorResidualMomentumScreen.reviews(series: input(shock: 100))
        XCTAssertEqual(Array(full.prefix(100)), prefix)
        XCTAssertEqual(Array(full.prefix(101)), Array(changed.prefix(101)))
        XCTAssertTrue(full.prefix(74).allSatisfy { $0.residualScores.isEmpty })
        XCTAssertEqual(full[74].residualScores.count, 9)
        XCTAssertEqual(full[74].signalDate, "2003-01-28")
        let weights = SectorResidualMomentumScreen.weights(full[100], mode: 0)
        XCTAssertEqual(weights.count, 3)
        XCTAssertEqual(weights.values.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertThrowsError(try SectorResidualMomentumScreen.reviews(series: Array(input().dropLast())))
    }
}
