import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

/// Frozen actual-input engineering checks only: no accounts or return metrics.
final class FisherTransformScreenTests: XCTestCase {
    typealias Screen = FisherTransformScreen
    typealias Bar = Screen.Bar
    private let expectedSHA = "7354b368850d5e6b587623de1a9539a758935288aff7838ecbf51bc8cf7c2b14"
    private let names: Set<String> = ["maxH", "minL", "value1", "fish"]
    private struct Input: Decodable {
        let schema: String; let bars: [Row]; let splits: [Split]
        struct Row: Decodable { let date: String; let open: Double; let high: Double; let low: Double; let close: Double; let volume: Double }
        struct Split: Decodable { let date: String; let ratio: Double }
    }
    private func day(_ text: String) throws -> Date {
        try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: text))
    }
    private func frozenInput() throws -> ([Bar], [Date: Double]) {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ATM_FISHER_PRICES_PATH"], "Root must supply the frozen real-input path")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(ResearchRunEvidence.sha256(data), expectedSHA)
        let input = try JSONDecoder().decode(Input.self, from: data)
        XCTAssertEqual(input.schema, "fixed-fisher10-v1")
        let bars = try input.bars.map { row in
            Bar(date: try day(row.date), open: row.open, high: row.high, low: row.low, close: row.close, volume: row.volume)
        }
        let splits = try Dictionary(uniqueKeysWithValues: input.splits.map { (try day($0.date), $0.ratio) })
        return (bars, splits)
    }
    private func evidence(_ bars: [Bar], splits: [Date: Double]) throws -> [Screen.Signal] {
        try Screen.signals(bars: bars, splits: splits, stateEligibleFrom: day("2000-01-13"))
    }

    func testRealPrefixMBBSeedAndStrictPriorClock() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(14)), splits: splits)
        XCTAssertEqual(s.count, 14)
        for i in 0...9 {
            XCTAssertEqual(s[i].sourceOrdinal, i)
            XCTAssertEqual(s[i].currentBar, i - 9)
            XCTAssertFalse(s[i].computed)
            XCTAssertEqual(s[i].states, Screen.States())
            XCTAssertEqual(s[i].previousStates, Screen.States())
            XCTAssertNil(s[i].stateSourceDate)
        }
        XCTAssertEqual(s[10].currentBar, 1)
        XCTAssertEqual(s[10].previousStates, Screen.States())
        for i in 10...13 {
            XCTAssertTrue(s[i].computed)
            XCTAssertEqual(s[i].stateSourceDate, s[i].date)
            XCTAssertGreaterThan(s[i].states.maxH, s[i].states.minL)
            XCTAssertTrue([s[i].states.maxH, s[i].states.minL, s[i].states.value1, s[i].states.fish].allSatisfy(\.isFinite))
            XCTAssertGreaterThanOrEqual(s[i].states.value1, -0.999)
            XCTAssertLessThanOrEqual(s[i].states.value1, 0.999)
        }
        XCTAssertEqual(s[11].previousStates, s[10].states)
        XCTAssertTrue(s.allSatisfy { !$0.warmOverride })
        XCTAssertTrue(s.allSatisfy { !$0.fundingEligible && $0.weight == 0 && $0.stateReason == "pre-funding-cash" })
        XCTAssertNil(Screen.latestSignal(s, before: s[0].date))
        XCTAssertEqual(Screen.latestSignal(s, before: s[11].date), s[10])
        XCTAssertEqual(Screen.latestSignal(s, before: s[11].date.addingTimeInterval(1)), s[11])
        XCTAssertEqual(ISO8601DateFormatter().string(from: s[0].date), "1999-03-09T16:00:00Z")
        XCTAssertEqual(s[0].sourceDate, "1999-03-10")
    }

    func testRealEffectiveSplitTransportKeepsDimensionlessStatesAndEmittedHistory() throws {
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
        XCTAssertEqual(current.previousStates.maxH, previous.states.maxH / 2)
        XCTAssertEqual(current.previousStates.minL, previous.states.minL / 2)
        XCTAssertEqual(current.previousStates.value1, previous.states.value1)
        XCTAssertEqual(current.previousStates.fish, previous.states.fish)
        XCTAssertEqual(Screen.latestSignal(through, before: splitDate), previous)
        XCTAssertEqual(BacktestSeriesAlignment.historicalSeriesDateString(from: previous.date), "2000-03-17")
        XCTAssertEqual(ISO8601DateFormatter().string(from: splitDate), "2000-03-19T16:00:00Z")
        XCTAssertTrue(current.computed)
        XCTAssertFalse(current.warmOverride)
        XCTAssertEqual(current.weight, current.states.fish > current.previousStates.fish ? 1 : 0)
    }

    func testRealPrefixArrayCodecAllFourStatesAndExplicitNull() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(14)), splits: splits)
        let encoded = try Screen.signalData(s)
        XCTAssertEqual(encoded, try Screen.signalData(s))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        XCTAssertEqual(objects.count, 14)
        for row in objects {
            for key in ["states", "previousStates", "previousStatesBeforeSplit"] {
                XCTAssertEqual(Set(try XCTUnwrap(row[key] as? [String: Any]).keys), names)
            }
            XCTAssertNotNil(row["currentUSDBar"])
            XCTAssertEqual(row["warmOverride"] as? Bool, false)
        }
        XCTAssertTrue(objects[0]["stateSourceDate"] is NSNull)
        XCTAssertEqual(objects[10]["stateSourceDate"] as? String, objects[10]["date"] as? String)
        XCTAssertEqual(objects[0]["date"] as? String, "1999-03-09T16:00:00Z")
    }

    func testActualInputClockRejectsEmptyReorderedAndRepeatedRealBars() throws {
        let (bars, splits) = try frozenInput()
        XCTAssertThrowsError(try evidence([], splits: splits))
        XCTAssertThrowsError(try evidence([bars[1], bars[0]], splits: splits))
        XCTAssertThrowsError(try evidence([bars[0], bars[0]], splits: splits))
    }
}
