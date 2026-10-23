import XCTest
import AssetTimeMachineBacktestCore

final class GoldNasdaqBarbellSignalTests: XCTestCase {
    func testFrozenStrongWeakNeutralAndUnavailableInformation() {
        let rising = (0..<400).map { 100 + Double($0) }
        let falling = (0..<400).map { 500 - Double($0) }
        let flat = Array(repeating: 100.0, count: 400)
        let strongWeak = GoldNasdaqBarbellStrategy.frozenTargetWeights(goldPrices: rising, nasdaqPrices: falling, signalIndex: 300)
        XCTAssertEqual(strongWeak["gold_cny"]!, 0.55, accuracy: 1e-12)
        XCTAssertEqual(strongWeak["nasdaq"]!, 0.045, accuracy: 1e-12)
        let neutral = GoldNasdaqBarbellStrategy.frozenTargetWeights(goldPrices: flat, nasdaqPrices: flat, signalIndex: 300)
        XCTAssertEqual(neutral["gold_cny"]!, 0.3575, accuracy: 1e-12)
        XCTAssertEqual(neutral["nasdaq"]!, 0.27, accuracy: 1e-12)
        XCTAssertTrue(GoldNasdaqBarbellStrategy.frozenTargetWeights(goldPrices: rising, nasdaqPrices: flat, signalIndex: 251).isEmpty)
        XCTAssertTrue(GoldNasdaqBarbellStrategy.frozenTargetWeights(goldPrices: rising, nasdaqPrices: flat, signalIndex: -1).isEmpty)
    }
    func testLaterQuotesCannotChangeFrozenDecision() {
        let rising = (0..<400).map { 100 + Double($0) }
        let expected = GoldNasdaqBarbellStrategy.frozenTargetWeights(goldPrices: rising, nasdaqPrices: rising, signalIndex: 300)
        let poisoned = Array(rising.prefix(301)) + Array(repeating: 0.01, count: 99)
        XCTAssertEqual(expected, GoldNasdaqBarbellStrategy.frozenTargetWeights(goldPrices: poisoned, nasdaqPrices: poisoned, signalIndex: 300))
        XCTAssertEqual(expected, GoldNasdaqBarbellStrategy.frozenTargetWeights(goldPrices: Array(rising.prefix(301)), nasdaqPrices: Array(rising.prefix(301)), signalIndex: 300))
    }
}
