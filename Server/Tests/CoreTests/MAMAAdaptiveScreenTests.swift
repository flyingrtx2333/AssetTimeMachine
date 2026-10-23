import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

/// Engineering checks use only prefixes of the frozen, actual QQQ input.
/// They do not simulate accounts, calculate returns, or select a parameter.
final class MAMAAdaptiveScreenTests: XCTestCase {
    typealias Screen = MAMAAdaptiveScreen
    typealias Bar = Screen.Bar
    private let expectedSHA = "c527d2ed54c1916ccb93c89c26c8ad1b377e22095fefd426b39ab3c043be6412"
    private let names: Set<String> = ["smooth", "detrender", "i1", "q1", "jI", "jQ", "i2", "q2", "re", "im", "period", "smoothPeriod", "phase", "deltaPhase", "alpha", "mama", "fama"]
    private struct Input: Decodable {
        let schema: String; let bars: [Row]; let splits: [Split]
        struct Row: Decodable { let date: String; let open: Double; let high: Double; let low: Double; let close: Double; let volume: Double }
        struct Split: Decodable { let date: String; let ratio: Double }
    }
    private func day(_ text: String) throws -> Date {
        try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: text))
    }
    private func frozenInput() throws -> ([Bar], [Date: Double]) {
        let pricesPath = try XCTUnwrap(ProcessInfo.processInfo.environment["ATM_MAMA_PRICES_PATH"], "Root must supply the frozen real-input path")
        let data = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        XCTAssertEqual(ResearchRunEvidence.sha256(data), expectedSHA)
        let input = try JSONDecoder().decode(Input.self, from: data)
        XCTAssertEqual(input.schema, "fixed-mama05-005-v1")
        let bars = try input.bars.map { row in
            Bar(date: try day(row.date), open: row.open, high: row.high, low: row.low, close: row.close, volume: row.volume)
        }
        let splits = try Dictionary(uniqueKeysWithValues: input.splits.map { (try day($0.date), $0.ratio) })
        return (bars, splits)
    }
    private func evidence(_ bars: [Bar], splits: [Date: Double]) throws -> [Screen.Signal] {
        try Screen.signals(bars: bars, splits: splits, stateEligibleFrom: day("2000-01-13"))
    }

    func testRealPrefixZeroInitializationAndStrictPriorClock() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(14)), splits: splits)
        XCTAssertEqual(s.count, 14)
        for i in 0...10 {
            XCTAssertEqual(s[i].sourceOrdinal, i)
            XCTAssertEqual(s[i].currentBar, i - 5)
            XCTAssertFalse(s[i].computed)
            XCTAssertEqual(s[i].states, Screen.States())
            XCTAssertEqual(s[i].previousStates, Screen.States())
            XCTAssertNil(s[i].stateSourceDate)
        }
        XCTAssertTrue(s[11].computed)
        XCTAssertEqual(s[11].currentBar, 6)
        XCTAssertEqual(s[11].stateSourceDate, s[11].date)
        XCTAssertEqual(s[11].previousStates, Screen.States())
        XCTAssertTrue(s.allSatisfy { !$0.fundingEligible && $0.weight == 0 && $0.stateReason == "pre-funding-cash" })
        XCTAssertNil(Screen.latestSignal(s, before: s[0].date))
        XCTAssertEqual(Screen.latestSignal(s, before: s[11].date), s[10])
        XCTAssertEqual(Screen.latestSignal(s, before: s[11].date.addingTimeInterval(1)), s[11])
        XCTAssertEqual(ISO8601DateFormatter().string(from: s[0].date), "1999-03-09T16:00:00Z")
        XCTAssertEqual(s[0].sourceDate, "1999-03-10")
    }

    func testRealEffectiveSplitInternalTransportAndImmutableOldSignals() throws {
        let (bars, splits) = try frozenInput(), splitDate = try day("2000-03-20")
        let index = try XCTUnwrap(bars.firstIndex { $0.date >= splitDate })
        let before = try evidence(Array(bars.prefix(index)), splits: splits)
        let through = try evidence(Array(bars.prefix(index + 1)), splits: splits)
        XCTAssertEqual(Array(through.prefix(index)), before)
        let current = through[index], previous = try XCTUnwrap(before.last)
        XCTAssertEqual(current.previousStatesBeforeSplit, previous.states)
        XCTAssertEqual(current.appliedSplitDates, [splitDate])
        XCTAssertEqual(current.splitFactor, 2)
        XCTAssertEqual(current.previousWeight, previous.weight)
        let linear: [KeyPath<Screen.States, Double>] = [\.smooth, \.detrender, \.i1, \.q1, \.jI, \.jQ, \.i2, \.q2, \.mama, \.fama]
        for key in linear { XCTAssertEqual(current.previousStates[keyPath: key], previous.states[keyPath: key] / 2) }
        let quadratic: [KeyPath<Screen.States, Double>] = [\.re, \.im]
        for key in quadratic {
            XCTAssertEqual(current.previousStates[keyPath: key], previous.states[keyPath: key] / 4)
        }
        let dimensionless: [KeyPath<Screen.States, Double>] = [\.period, \.smoothPeriod, \.phase, \.deltaPhase, \.alpha]
        for key in dimensionless { XCTAssertEqual(current.previousStates[keyPath: key], previous.states[keyPath: key]) }
        XCTAssertEqual(Screen.latestSignal(through, before: splitDate), previous)
        XCTAssertEqual(BacktestSeriesAlignment.historicalSeriesDateString(from: previous.date), "2000-03-17")
        XCTAssertEqual(ISO8601DateFormatter().string(from: splitDate), "2000-03-19T16:00:00Z")
        XCTAssertTrue(current.computed)
    }

    func testRealPrefixSourceCodecKeepsAllStatesAndExplicitNull() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(14)), splits: splits)
        let encoded = try Screen.signalData(s)
        XCTAssertEqual(encoded, try Screen.signalData(s))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for row in objects {
            for key in ["states", "previousStates", "previousStatesBeforeSplit"] {
                XCTAssertEqual(Set(try XCTUnwrap(row[key] as? [String: Any]).keys), names)
            }
            XCTAssertNotNil(row["currentUSDBar"])
            XCTAssertNotNil(row["sourceDate"])
        }
        XCTAssertTrue(objects[0]["stateSourceDate"] is NSNull)
        XCTAssertEqual(objects[11]["stateSourceDate"] as? String, objects[11]["date"] as? String)
        XCTAssertEqual(objects[0]["date"] as? String, "1999-03-09T16:00:00Z")
    }

    func testActualInputClockRejectsReorderedOrRepeatedRealBars() throws {
        let (bars, splits) = try frozenInput()
        XCTAssertThrowsError(try evidence([bars[1], bars[0]], splits: splits))
        XCTAssertThrowsError(try evidence([bars[0], bars[0]], splits: splits))
    }
}
