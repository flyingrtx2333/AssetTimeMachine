import XCTest
import AssetTimeMachineResearchSupport

final class CrossMarketStressTests: XCTestCase {
    func testLinearQuantileAndWaitDecay() {
        XCTAssertEqual(CrossMarketStressScreen.firstPercentile((0..<187).map(Double.init)),1.86,accuracy: 1e-12)
        XCTAssertEqual(CrossMarketStressScreen.firstPercentile([0,0,0]),0)
        XCTAssertEqual(CrossMarketStressScreen.nextWait(previous: 15,flip: false),15)
        XCTAssertEqual(CrossMarketStressScreen.nextWait(previous: 15,flip: true),225)
        XCTAssertEqual(CrossMarketStressScreen.nextWait(previous: 225,flip: false),112)
        XCTAssertEqual(CrossMarketStressScreen.nextWait(previous: 112,flip: false),56)
    }
    func testPriorDayClockFuturePoisonPrefixAndScaling() throws {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let first = formatter.date(from: "2024-01-01")!
        let days = (0..<400).map { formatter.string(from: first.addingTimeInterval(Double($0)*86400)) }
        var closes = Dictionary(uniqueKeysWithValues: CrossMarketStressScreen.symbols.map { ($0,Array(repeating: 100.0,count: 400)) })
        closes["DBB"]![320] = 50
        let original = try CrossMarketStressScreen.decisions(days: days,closes: closes)
        XCTAssertTrue(original[252..<321].allSatisfy { $0.weight == 1 && $0.extremes.isEmpty })
        XCTAssertEqual(original[321].weight,0); XCTAssertEqual(original[321].extremes,["DBB"])
        XCTAssertEqual(original[321].signalDate,days[320]); XCTAssertEqual(original[335].weight,0)
        XCTAssertEqual(original[336].weight,1)
        var poisoned = closes
        for symbol in CrossMarketStressScreen.symbols { for i in 321..<400 { poisoned[symbol]![i] = Double(i*100) } }
        let alternative = try CrossMarketStressScreen.decisions(days: days,closes: poisoned)
        XCTAssertEqual(Array(original.prefix(322)),Array(alternative.prefix(322)))
        let prefix = try CrossMarketStressScreen.decisions(days: Array(days.prefix(322)),closes: closes.mapValues { Array($0.prefix(322)) })
        XCTAssertEqual(Array(original.prefix(322)),prefix)
        let scaled = try CrossMarketStressScreen.decisions(days: days,closes: closes.mapValues { $0.map { $0*4 } })
        XCTAssertEqual(original,scaled)
        var missing = closes; missing.removeValue(forKey: "SHY")
        XCTAssertThrowsError(try CrossMarketStressScreen.decisions(days: days,closes: missing))
    }
}
