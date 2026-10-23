import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

/// Frozen actual-input engineering checks only: no accounts or return metrics.
final class FRAMAAdaptiveScreenTests: XCTestCase {
    typealias Screen = FRAMAAdaptiveScreen
    typealias Bar = Screen.Bar
    private let expectedSHA = "2f941ed6a88b3d970743396c76b89b0588e4dbab22d57b01ed50eb831c2663a2"
    private let names: Set<String> = ["count", "n1", "n2", "n3", "hh", "ll", "dimen", "alpha", "filt"]
    private struct Input: Decodable {
        let schema: String; let bars: [Row]; let splits: [Split]
        struct Row: Decodable { let date: String; let open: Double; let high: Double; let low: Double; let close: Double; let volume: Double }
        struct Split: Decodable { let date: String; let ratio: Double }
    }
    private func day(_ text: String) throws -> Date {
        try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: text))
    }
    private func frozenInput() throws -> ([Bar], [Date: Double]) {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ATM_FRAMA_PRICES_PATH"], "Root must supply the frozen real-input path")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(ResearchRunEvidence.sha256(data), expectedSHA)
        let input = try JSONDecoder().decode(Input.self, from: data)
        XCTAssertEqual(input.schema, "fixed-frama16-v1")
        let bars = try input.bars.map { row in
            Bar(date: try day(row.date), open: row.open, high: row.high, low: row.low, close: row.close, volume: row.volume)
        }
        let splits = try Dictionary(uniqueKeysWithValues: input.splits.map { (try day($0.date), $0.ratio) })
        return (bars, splits)
    }
    private func evidence(_ bars: [Bar], splits: [Date: Double]) throws -> [Screen.Signal] {
        try Screen.signals(bars: bars, splits: splits, stateEligibleFrom: day("2000-01-13"))
    }

    func testRealPrefixMBBSeedOverrideAndStrictPriorClock() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(34)), splits: splits)
        XCTAssertEqual(s.count, 34)
        for i in 0...15 {
            XCTAssertEqual(s[i].sourceOrdinal, i)
            XCTAssertEqual(s[i].currentBar, i - 15)
            XCTAssertFalse(s[i].computed)
            XCTAssertFalse(s[i].warmOverride)
            XCTAssertEqual(s[i].states, Screen.States())
            XCTAssertEqual(s[i].previousStates, Screen.States())
            XCTAssertNil(s[i].stateSourceDate)
        }
        XCTAssertEqual(s[16].currentBar, 1)
        XCTAssertEqual(s[16].previousStates, Screen.States())
        for i in 16...31 {
            XCTAssertTrue(s[i].computed)
            XCTAssertTrue(s[i].warmOverride)
            XCTAssertEqual(s[i].states.filt, s[i].price)
            XCTAssertEqual(s[i].states.count, 15)
            XCTAssertEqual(s[i].stateSourceDate, s[i].date)
            XCTAssertGreaterThanOrEqual(s[i].states.alpha, 0.01)
            XCTAssertLessThanOrEqual(s[i].states.alpha, 1)
        }
        XCTAssertTrue(s[32].computed)
        XCTAssertEqual(s[32].currentBar, 17)
        XCTAssertFalse(s[32].warmOverride)
        XCTAssertEqual(s[32].previousStates, s[31].states)
        XCTAssertTrue(s.allSatisfy { !$0.fundingEligible && $0.weight == 0 && $0.stateReason == "pre-funding-cash" })
        XCTAssertNil(Screen.latestSignal(s, before: s[0].date))
        XCTAssertEqual(Screen.latestSignal(s, before: s[32].date), s[31])
        XCTAssertEqual(Screen.latestSignal(s, before: s[32].date.addingTimeInterval(1)), s[32])
        XCTAssertEqual(ISO8601DateFormatter().string(from: s[0].date), "1999-03-09T16:00:00Z")
        XCTAssertEqual(s[0].sourceDate, "1999-03-10")
    }

    func testRealEffectiveSplitTransportKeepsEmittedPrefixAndPriorClock() throws {
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
        let linear: [KeyPath<Screen.States, Double>] = [\.n1, \.n2, \.n3, \.hh, \.ll, \.filt]
        for key in linear { XCTAssertEqual(current.previousStates[keyPath: key], previous.states[keyPath: key] / 2) }
        XCTAssertEqual(current.previousStates.count, previous.states.count)
        XCTAssertEqual(current.previousStates.dimen, previous.states.dimen)
        XCTAssertEqual(current.previousStates.alpha, previous.states.alpha)
        XCTAssertEqual(Screen.latestSignal(through, before: splitDate), previous)
        XCTAssertEqual(BacktestSeriesAlignment.historicalSeriesDateString(from: previous.date), "2000-03-17")
        XCTAssertEqual(ISO8601DateFormatter().string(from: splitDate), "2000-03-19T16:00:00Z")
        XCTAssertTrue(current.computed)
        XCTAssertFalse(current.warmOverride)
    }

    func testRealPrefixArrayCodecAllNineStatesAndExplicitNull() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(34)), splits: splits)
        let encoded = try Screen.signalData(s)
        XCTAssertEqual(encoded, try Screen.signalData(s))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        XCTAssertEqual(objects.count, 34)
        for row in objects {
            for key in ["states", "previousStates", "previousStatesBeforeSplit"] {
                XCTAssertEqual(Set(try XCTUnwrap(row[key] as? [String: Any]).keys), names)
            }
            XCTAssertNotNil(row["currentUSDBar"])
            XCTAssertNotNil(row["warmOverride"])
        }
        XCTAssertTrue(objects[0]["stateSourceDate"] is NSNull)
        XCTAssertEqual(objects[16]["stateSourceDate"] as? String, objects[16]["date"] as? String)
        XCTAssertEqual(objects[0]["date"] as? String, "1999-03-09T16:00:00Z")
    }

    func testActualInputClockRejectsReorderedAndRepeatedRealBars() throws {
        let (bars, splits) = try frozenInput()
        XCTAssertThrowsError(try evidence([bars[1], bars[0]], splits: splits))
        XCTAssertThrowsError(try evidence([bars[0], bars[0]], splits: splits))
    }
}
