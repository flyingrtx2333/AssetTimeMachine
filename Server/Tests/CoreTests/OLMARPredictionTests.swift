import XCTest
import AssetTimeMachineResearchSupport

final class OLMARPredictionTests: XCTestCase {
    func testProjectionKnownUpdateAndFlatForecast() throws {
        XCTAssertEqual(OLMARPredictionScreen.project([2,-1,0.5]),[1,0,0])
        let shifted = OLMARPredictionScreen.project([1002,999,1000.5])
        XCTAssertEqual(shifted,[1,0,0])
        let (weights,multiplier) = try OLMARPredictionScreen.update(previous: [0.5,0.5],prediction: [1.02,0.98])
        XCTAssertEqual(weights,[1,0]); XCTAssertEqual(multiplier,11250,accuracy: 1e-8)
        let (flat,zero) = try OLMARPredictionScreen.update(previous: [0.3,0.7],prediction: [1,1])
        XCTAssertEqual(flat,[0.3,0.7]); XCTAssertEqual(zero,0)
        let mixed = OLMARPredictionScreen.project([-0.2,0.5,0.7])
        XCTAssertEqual(mixed[0],0); XCTAssertEqual(mixed[1],0.4,accuracy: 1e-12); XCTAssertEqual(mixed[2],0.6,accuracy: 1e-12)
    }
    func testPastClosePrefixFuturePoisonAndScale() throws {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let first = formatter.date(from: "2024-01-01")!
        let days = (0..<30).map { formatter.string(from: first.addingTimeInterval(Double($0)*86400)) }
        func series(poison: Bool = false,scale: Double = 1,count: Int = 30) -> [OLMARPredictionScreen.Series] {
            SectorMonthstartScreen.symbols.enumerated().map { k,symbol in
                .init(symbol: symbol,bars: (0..<count).map { i in
                    let price = scale*(poison && i >= 10 ? 1000+Double(i*k) : 100+Double((i*7+k*3)%11))
                    return .init(date: days[i],open: price,high: price,low: price,close: price)
                })
            }
        }
        let result = try OLMARPredictionScreen.forecasts(series: series())
        XCTAssertEqual(Array(result.prefix(11)),Array(try OLMARPredictionScreen.forecasts(series: series(poison: true)).prefix(11)))
        XCTAssertEqual(Array(result.prefix(11)),try OLMARPredictionScreen.forecasts(series: series(count: 11)))
        XCTAssertEqual(result,try OLMARPredictionScreen.forecasts(series: series(scale: 4)))
        XCTAssertEqual(result[10].signalDate,days[9]); XCTAssertTrue(result[5].eligible)
        XCTAssertTrue(result.allSatisfy { abs($0.weights.reduce(0,+)-1)<1e-12 && $0.weights.allSatisfy { $0>=0 } })
    }
}
